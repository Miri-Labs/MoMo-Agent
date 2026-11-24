#import <CoreML/CoreML.h>
#import <Foundation/Foundation.h>

#include "CMoMoMacSpeechCoreML.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>
#include <unordered_map>

namespace {

constexpr int32_t kNumMels = 72;
constexpr int32_t kEmbedDim = 192;
constexpr int32_t kBuckets[3] = {200, 400, 600};

inline void WriteErr(char *buf, size_t size, const std::string &msg) {
    if (buf && size > 0) {
        std::snprintf(buf, size, "%s", msg.c_str());
    }
}

API_AVAILABLE(macos(15.0))
MLModel *LoadFunctionModel(NSURL *url, NSString *fnName, bool *outANE) {
    NSArray<NSNumber *> *candidates = @[
        @(MLComputeUnitsCPUAndNeuralEngine),
        @(MLComputeUnitsAll),
        @(MLComputeUnitsCPUOnly)
    ];
    NSError *lastErr = nil;
    for (NSNumber *cu in candidates) {
        MLModelConfiguration *cfg = [[MLModelConfiguration alloc] init];
        cfg.computeUnits = static_cast<MLComputeUnits>(cu.integerValue);
        cfg.functionName = fnName;
        NSError *err = nil;
        MLModel *m = [MLModel modelWithContentsOfURL:url configuration:cfg error:&err];
        if (m) {
            *outANE = (cfg.computeUnits != MLComputeUnitsCPUOnly);
            return m;
        }
        lastErr = err;
    }
    std::string desc = lastErr ? [[lastErr localizedDescription] UTF8String] : "unknown error";
    throw std::runtime_error("Failed to load ReDimNet2+ function " + std::string([fnName UTF8String]) + ": " + desc);
}

}  // namespace

struct ReDimNetBucketSlot {
    int32_t frames = 0;
    MLModel *model = nil;
    MLMultiArray *mel = nil;
    MLMultiArray *emb_backing = nil;
    MLDictionaryFeatureProvider *provider = nil;
    MLPredictionOptions *options = nil;
};

struct MoMoReDimNetCoreMLHandle {
    std::unordered_map<int32_t, ReDimNetBucketSlot> slots;
    int32_t accelerator_mask = 0;
};

extern "C" {

MoMoReDimNetCoreMLHandle *MoMoReDimNetCreate(
    const char *mlmodelc_path,
    char *error_buf,
    size_t error_buf_size) {
    if (@available(macOS 15.0, *)) {
        @autoreleasepool {
            try {
                if (!mlmodelc_path || mlmodelc_path[0] == '\0') {
                    throw std::runtime_error("Empty ReDimNet2Plus.mlmodelc path");
                }
                NSString *nsPath = [NSString stringWithUTF8String:mlmodelc_path];
                BOOL isDir = NO;
                if (![[NSFileManager defaultManager] fileExistsAtPath:nsPath isDirectory:&isDir]) {
                    throw std::runtime_error(std::string("Missing ReDimNet2Plus.mlmodelc: ") + mlmodelc_path);
                }
                NSURL *url = [NSURL fileURLWithPath:nsPath isDirectory:isDir];
                auto handle = std::make_unique<MoMoReDimNetCoreMLHandle>();

                // Load all 3 static buckets in parallel to minimize startup latency
                __block MLModel *m0 = nil, *m1 = nil, *m2 = nil;
                __block bool ane0 = false, ane1 = false, ane2 = false;
                std::string loadErrors[3];
                std::string *pErrors = loadErrors;

                dispatch_group_t grp = dispatch_group_create();
                dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
                dispatch_group_async(grp, q, ^{
                    @autoreleasepool {
                        try {
                            bool ane = false;
                            m0 = LoadFunctionModel(url, @"embed_200", &ane);
                            ane0 = ane;
                        } catch (const std::exception &e) { pErrors[0] = e.what(); }
                    }
                });
                dispatch_group_async(grp, q, ^{
                    @autoreleasepool {
                        try {
                            bool ane = false;
                            m1 = LoadFunctionModel(url, @"embed_400", &ane);
                            ane1 = ane;
                        } catch (const std::exception &e) { pErrors[1] = e.what(); }
                    }
                });
                dispatch_group_async(grp, q, ^{
                    @autoreleasepool {
                        try {
                            bool ane = false;
                            m2 = LoadFunctionModel(url, @"embed_600", &ane);
                            ane2 = ane;
                        } catch (const std::exception &e) { pErrors[2] = e.what(); }
                    }
                });
                dispatch_group_wait(grp, DISPATCH_TIME_FOREVER);

                MLModel *loadedModels[3] = {m0, m1, m2};
                const bool loadedANE[3] = {ane0, ane1, ane2};

                bool allANE = true;
                for (int idx = 0; idx < 3; ++idx) {
                    if (!loadErrors[idx].empty()) {
                        throw std::runtime_error(loadErrors[idx]);
                    }
                    const int32_t frames = kBuckets[idx];
                    allANE = allANE && loadedANE[idx];
                    NSError *err = nil;
                    MLMultiArray *mel = [[MLMultiArray alloc]
                        initWithShape:@[ @1, @1, @(kNumMels), @(frames) ]
                             dataType:MLMultiArrayDataTypeFloat32
                                error:&err];
                    if (!mel) {
                        throw std::runtime_error(err ? [[err localizedDescription] UTF8String] : "MLMultiArray alloc failed");
                    }
                    MLMultiArray *embBacking = [[MLMultiArray alloc]
                        initWithShape:@[ @1, @(kEmbedDim) ]
                             dataType:MLMultiArrayDataTypeFloat32
                                error:&err];
                    if (!embBacking) {
                        throw std::runtime_error(err ? [[err localizedDescription] UTF8String] : "Embedding backing alloc failed");
                    }
                    MLDictionaryFeatureProvider *prov = [[MLDictionaryFeatureProvider alloc]
                        initWithDictionary:@{@"mel" : [MLFeatureValue featureValueWithMultiArray:mel]}
                                     error:&err];
                    if (!prov) {
                        throw std::runtime_error(err ? [[err localizedDescription] UTF8String] : "FeatureProvider init failed");
                    }
                    MLPredictionOptions *opts = [[MLPredictionOptions alloc] init];
                    opts.outputBackings = @{@"embedding" : embBacking};

                    ReDimNetBucketSlot slot;
                    slot.frames = frames;
                    slot.model = loadedModels[idx];
                    slot.mel = mel;
                    slot.emb_backing = embBacking;
                    slot.provider = prov;
                    slot.options = opts;
                    handle->slots.emplace(frames, slot);
                }
                handle->accelerator_mask = allANE ? 1 : 0;
                return handle.release();
            } catch (const std::exception &e) {
                WriteErr(error_buf, error_buf_size, e.what());
                return nullptr;
            }
        }
    }
    WriteErr(error_buf, error_buf_size, "macOS 15.0 or newer is required for CoreML MultiFunction");
    return nullptr;
}

void MoMoReDimNetDestroy(MoMoReDimNetCoreMLHandle *handle) {
    if (!handle) return;
    @autoreleasepool {
        delete handle;
    }
}

int32_t MoMoReDimNetAcceleratorMask(const MoMoReDimNetCoreMLHandle *handle) {
    return handle ? handle->accelerator_mask : 0;
}

int32_t MoMoReDimNetEmbed(
    MoMoReDimNetCoreMLHandle *handle,
    const float *mel_72xT,
    int32_t num_frames,
    float *out_embedding_192,
    char *error_buf,
    size_t error_buf_size) {
    if (!handle || !mel_72xT || !out_embedding_192) {
        WriteErr(error_buf, error_buf_size, "Invalid null argument to MoMoReDimNetEmbed");
        return -1;
    }
    auto it = handle->slots.find(num_frames);
    if (it == handle->slots.end()) {
        WriteErr(error_buf, error_buf_size, "Unsupported ReDimNet2+ frame bucket: " + std::to_string(num_frames));
        return -1;
    }
    @autoreleasepool {
        try {
            ReDimNetBucketSlot &slot = it->second;
            [slot.mel getMutableBytesWithHandler:^(void *mutableBytes, NSInteger, NSArray<NSNumber *> *strides) {
                auto *dst = static_cast<float *>(mutableBytes);
                const ptrdiff_t s2 = strides[2].integerValue;
                const ptrdiff_t s3 = strides[3].integerValue;
                for (int32_t m = 0; m < kNumMels; ++m) {
                    const float *srcRow = mel_72xT + static_cast<size_t>(m) * static_cast<size_t>(num_frames);
                    float *dstRow = dst + m * s2;
                    if (s3 == 1) {
                        std::memcpy(dstRow, srcRow, static_cast<size_t>(num_frames) * sizeof(float));
                    } else {
                        for (int32_t t = 0; t < num_frames; ++t) {
                            dstRow[t * s3] = srcRow[t];
                        }
                    }
                }
            }];

            NSError *err = nil;
            id<MLFeatureProvider> out = [slot.model predictionFromFeatures:slot.provider options:slot.options error:&err];
            if (!out) {
                throw std::runtime_error(err ? [[err localizedDescription] UTF8String] : "ReDimNet2+ prediction failed");
            }
            MLMultiArray *emb = [out featureValueForName:@"embedding"].multiArrayValue ?: slot.emb_backing;
            if (!emb || emb.count < kEmbedDim) {
                throw std::runtime_error("Missing or short ReDimNet2+ embedding output");
            }
            [emb getBytesWithHandler:^(const void *bytes, NSInteger) {
                if (emb.dataType == MLMultiArrayDataTypeFloat32) {
                    std::memcpy(out_embedding_192, bytes, kEmbedDim * sizeof(float));
                } else {
                    const auto *src16 = static_cast<const __fp16 *>(bytes);
                    for (int32_t i = 0; i < kEmbedDim; ++i) {
                        out_embedding_192[i] = static_cast<float>(src16[i]);
                    }
                }
            }];
            double sq = 0.0;
            for (int32_t i = 0; i < kEmbedDim; ++i) {
                if (!std::isfinite(out_embedding_192[i])) {
                    throw std::runtime_error("Non-finite ReDimNet2+ embedding");
                }
                sq += static_cast<double>(out_embedding_192[i]) * static_cast<double>(out_embedding_192[i]);
            }
            if (sq <= 1e-12) {
                throw std::runtime_error("Zero-norm ReDimNet2+ embedding");
            }
            const float inv = static_cast<float>(1.0 / std::sqrt(sq));
            for (int32_t i = 0; i < kEmbedDim; ++i) {
                out_embedding_192[i] *= inv;
            }
            return 0;
        } catch (const std::exception &e) {
            WriteErr(error_buf, error_buf_size, e.what());
            return -1;
        }
    }
}

}  // extern "C"
