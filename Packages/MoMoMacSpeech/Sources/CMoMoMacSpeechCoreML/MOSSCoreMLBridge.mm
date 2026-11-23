#import <CoreML/CoreML.h>
#import <Foundation/Foundation.h>

#include "CMoMoMacSpeechCoreML.h"

#if defined(__ARM_NEON) || defined(__aarch64__)
#include <arm_neon.h>
#endif

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

constexpr int32_t kWhisperMels = 80;
constexpr int32_t kWhisperFrames = 3000;
constexpr int32_t kAudioChunkTokens = 375;
constexpr int32_t kHiddenSize = 1024;
constexpr int32_t kVocabSize = 151936;
constexpr int32_t kHeadDim = 128;
constexpr double kRopeTheta = 1000000.0;

inline void WriteErr(char *buf, size_t size, const std::string &msg) {
    if (buf && size > 0) {
        std::snprintf(buf, size, "%s", msg.c_str());
    }
}

inline float HalfBitsToFloat(uint16_t h) noexcept {
    __fp16 fh;
    std::memcpy(&fh, &h, sizeof(fh));
    return static_cast<float>(fh);
}

inline uint16_t FloatToHalfBits(float f) noexcept {
    __fp16 fh = static_cast<__fp16>(f);
    uint16_t h = 0;
    std::memcpy(&h, &fh, sizeof(h));
    return h;
}

inline void ConvertFloatToHalf(const float *src, uint16_t *dst, size_t n) noexcept {
#if defined(__ARM_NEON) || defined(__aarch64__)
    size_t i = 0;
    for (; i + 8 <= n; i += 8) {
        float16x4_t lo = vcvt_f16_f32(vld1q_f32(src + i));
        float16x4_t hi = vcvt_f16_f32(vld1q_f32(src + i + 4));
        vst1q_u16(dst + i, vreinterpretq_u16_f16(vcombine_f16(lo, hi)));
    }
    for (; i < n; ++i) dst[i] = FloatToHalfBits(src[i]);
#else
    for (size_t i = 0; i < n; ++i) dst[i] = FloatToHalfBits(src[i]);
#endif
}

inline void ConvertHalfToFloat(const uint16_t *src, float *dst, size_t n) noexcept {
#if defined(__ARM_NEON) || defined(__aarch64__)
    size_t i = 0;
    for (; i + 8 <= n; i += 8) {
        uint16x8_t h = vld1q_u16(src + i);
        float16x8_t fh = vreinterpretq_f16_u16(h);
        vst1q_f32(dst + i, vcvt_f32_f16(vget_low_f16(fh)));
        vst1q_f32(dst + i + 4, vcvt_f32_f16(vget_high_f16(fh)));
    }
    for (; i < n; ++i) dst[i] = HalfBitsToFloat(src[i]);
#else
    for (size_t i = 0; i < n; ++i) dst[i] = HalfBitsToFloat(src[i]);
#endif
}

#pragma pack(push, 1)
struct MomoEmbHeader {
    char magic[8];
    uint32_t version;
    uint32_t vocab_size;
    uint32_t hidden_size;
    uint32_t quant_type;
    uint64_t scales_offset;
    uint64_t weights_offset;
    uint8_t reserved[24];
};
#pragma pack(pop)
static_assert(sizeof(MomoEmbHeader) == 64, "MomoEmbHeader must be 64 bytes");

class MmapEmbeddingTable {
 public:
    explicit MmapEmbeddingTable(const char *path) {
        if (!path || path[0] == '\0') {
            throw std::runtime_error("Missing embedding.int8.bin path");
        }
        int fd = ::open(path, O_RDONLY);
        if (fd < 0) throw std::runtime_error(std::string("Cannot open embedding table: ") + path);
        struct stat st {};
        if (::fstat(fd, &st) != 0 || st.st_size < static_cast<off_t>(sizeof(MomoEmbHeader))) {
            ::close(fd);
            throw std::runtime_error("Invalid embedding table size");
        }
        mapped_size_ = static_cast<size_t>(st.st_size);
        void *addr = ::mmap(nullptr, mapped_size_, PROT_READ, MAP_PRIVATE, fd, 0);
        ::close(fd);
        if (addr == MAP_FAILED || !addr) {
            throw std::runtime_error("mmap failed for embedding.int8.bin");
        }
        mapped_ = static_cast<const uint8_t *>(addr);
        MomoEmbHeader hdr{};
        std::memcpy(&hdr, mapped_, sizeof(MomoEmbHeader));
        if (std::memcmp(hdr.magic, "MOMO_EMB", 8) != 0 || hdr.version != 1 || hdr.quant_type != 1) {
            Unmap();
            throw std::runtime_error("Invalid MOMO_EMB header");
        }
        vocab_size_ = static_cast<int32_t>(hdr.vocab_size);
        hidden_size_ = static_cast<int32_t>(hdr.hidden_size);
        scales_fp16_ = reinterpret_cast<const uint16_t *>(mapped_ + hdr.scales_offset);
        weights_int8_ = reinterpret_cast<const int8_t *>(mapped_ + hdr.weights_offset);
    }

    ~MmapEmbeddingTable() { Unmap(); }
    MmapEmbeddingTable(const MmapEmbeddingTable &) = delete;
    MmapEmbeddingTable &operator=(const MmapEmbeddingTable &) = delete;

    int32_t vocab_size() const noexcept { return vocab_size_; }
    int32_t hidden_size() const noexcept { return hidden_size_; }

    void LookupFp16(int32_t token_id, uint16_t *dst) const noexcept {
        const size_t H = static_cast<size_t>(hidden_size_);
        if (token_id < 0 || token_id >= vocab_size_) {
            std::memset(dst, 0, H * sizeof(uint16_t));
            return;
        }
        const float scale = HalfBitsToFloat(scales_fp16_[token_id]);
        const int8_t *row = weights_int8_ + static_cast<size_t>(token_id) * H;
#if defined(__ARM_NEON) || defined(__aarch64__)
        const float32x4_t vscale = vdupq_n_f32(scale);
        size_t d = 0;
        for (; d + 16 <= H; d += 16) {
            const int8x16_t q8 = vld1q_s8(row + d);
            const int16x8_t lo16 = vmovl_s8(vget_low_s8(q8));
            const int16x8_t hi16 = vmovl_s8(vget_high_s8(q8));
            const float16x4_t f0 = vcvt_f16_f32(vmulq_f32(vcvtq_f32_s32(vmovl_s16(vget_low_s16(lo16))), vscale));
            const float16x4_t f1 = vcvt_f16_f32(vmulq_f32(vcvtq_f32_s32(vmovl_s16(vget_high_s16(lo16))), vscale));
            const float16x4_t f2 = vcvt_f16_f32(vmulq_f32(vcvtq_f32_s32(vmovl_s16(vget_low_s16(hi16))), vscale));
            const float16x4_t f3 = vcvt_f16_f32(vmulq_f32(vcvtq_f32_s32(vmovl_s16(vget_high_s16(hi16))), vscale));
            vst1q_u16(dst + d, vreinterpretq_u16_f16(vcombine_f16(f0, f1)));
            vst1q_u16(dst + d + 8, vreinterpretq_u16_f16(vcombine_f16(f2, f3)));
        }
        for (; d < H; ++d) dst[d] = FloatToHalfBits(static_cast<float>(row[d]) * scale);
#else
        for (size_t d = 0; d < H; ++d) dst[d] = FloatToHalfBits(static_cast<float>(row[d]) * scale);
#endif
    }

 private:
    void Unmap() noexcept {
        if (mapped_ && mapped_size_ > 0) {
            ::munmap(const_cast<uint8_t *>(mapped_), mapped_size_);
        }
        mapped_ = nullptr;
        mapped_size_ = 0;
    }

    const uint8_t *mapped_ = nullptr;
    size_t mapped_size_ = 0;
    int32_t vocab_size_ = 0;
    int32_t hidden_size_ = 0;
    const uint16_t *scales_fp16_ = nullptr;
    const int8_t *weights_int8_ = nullptr;
};

API_AVAILABLE(macos(15.0))
MLModel *LoadCoreMLModel(NSURL *url, NSString *functionName, bool *outAccelerated) {
    NSArray<NSNumber *> *candidates = @[
        @(MLComputeUnitsCPUAndNeuralEngine),
        @(MLComputeUnitsAll),
        @(MLComputeUnitsCPUOnly)
    ];
    NSError *lastErr = nil;
    for (NSNumber *cu in candidates) {
        MLModelConfiguration *cfg = [[MLModelConfiguration alloc] init];
        cfg.computeUnits = static_cast<MLComputeUnits>(cu.integerValue);
        if (functionName != nil) {
            cfg.functionName = functionName;
        }
        NSError *err = nil;
        MLModel *model = [MLModel modelWithContentsOfURL:url configuration:cfg error:&err];
        if (model) {
            *outAccelerated = (cfg.computeUnits != MLComputeUnitsCPUOnly);
            return model;
        }
        lastErr = err;
    }
    std::string desc = lastErr ? [[lastErr localizedDescription] UTF8String] : "unknown error";
    throw std::runtime_error("Failed to load CoreML model: " + desc);
}

MLMultiArray *MakeArray(NSArray<NSNumber *> *shape, MLMultiArrayDataType dtype, const char *label) {
    NSError *err = nil;
    MLMultiArray *arr = [[MLMultiArray alloc] initWithShape:shape dataType:dtype error:&err];
    if (!arr) {
        throw std::runtime_error(std::string("Failed to alloc MLMultiArray ") + label + ": " +
                                 (err ? [[err localizedDescription] UTF8String] : "unknown"));
    }
    return arr;
}

MLDictionaryFeatureProvider *MakeProvider(NSDictionary<NSString *, MLFeatureValue *> *dict, const char *label) {
    NSError *err = nil;
    MLDictionaryFeatureProvider *p = [[MLDictionaryFeatureProvider alloc] initWithDictionary:dict error:&err];
    if (!p) {
        throw std::runtime_error(std::string("Failed to create FeatureProvider ") + label + ": " +
                                 (err ? [[err localizedDescription] UTF8String] : "unknown"));
    }
    return p;
}

}  // namespace

struct MoMoMOSSCoreMLHandle {
    std::unique_ptr<MmapEmbeddingTable> embedding;
    int32_t max_kv_len = 4096;
    int32_t prefill_len = 128;
    int32_t accelerator_mask = 0;

    MLModel *encoder_model = nil;
    MLMultiArray *enc_mel = nil;
    MLDictionaryFeatureProvider *enc_provider = nil;
    MLPredictionOptions *enc_options = nil;

    MLModel *prefill_model = nil;
    MLModel *decode_model = nil;
    id llm_state = nil;  // MLState *

    MLMultiArray *prefill_embeds = nil;
    MLMultiArray *prefill_cos = nil;
    MLMultiArray *prefill_sin = nil;
    MLMultiArray *prefill_mask = nil;
    MLMultiArray *prefill_write_pos = nil;
    MLDictionaryFeatureProvider *prefill_provider = nil;
    MLPredictionOptions *prefill_options = nil;

    MLMultiArray *decode_embeds = nil;
    MLMultiArray *decode_cos = nil;
    MLMultiArray *decode_sin = nil;
    MLMultiArray *decode_mask = nil;
    MLMultiArray *decode_write_pos = nil;
    MLMultiArray *decode_logits_backing = nil;
    MLDictionaryFeatureProvider *decode_provider = nil;
    MLPredictionOptions *decode_options = nil;

    std::vector<uint16_t> rope_cos_fp16;
    std::vector<uint16_t> rope_sin_fp16;
    std::vector<float> scratch_logits;
    std::array<uint16_t, kHiddenSize> scratch_tok_fp16{};

    API_AVAILABLE(macos(15.0))
    void RunChunkPrefill(const uint16_t *embeds_fp16, int32_t start_pos) {
        const uint16_t *cos_ptr = rope_cos_fp16.data();
        const uint16_t *sin_ptr = rope_sin_fp16.data();
        const int32_t S = prefill_len;
        const int32_t maxKV = max_kv_len;

        // inputs_embeds shape: [1, 1024, 1, S]
        [prefill_embeds getMutableBytesWithHandler:^(void *mutableBytes, NSInteger, NSArray<NSNumber *> *strides) {
            auto *dst = static_cast<uint16_t *>(mutableBytes);
            const ptrdiff_t s1 = strides[1].integerValue;
            const ptrdiff_t s3 = strides[3].integerValue;
            for (int32_t t = 0; t < S; ++t) {
                const uint16_t *srcRow = embeds_fp16 + static_cast<size_t>(t) * kHiddenSize;
                for (int32_t c = 0; c < kHiddenSize; ++c) {
                    dst[c * s1 + t * s3] = srcRow[c];
                }
            }
        }];
        [prefill_cos getMutableBytesWithHandler:^(void *mutableBytes, NSInteger, NSArray<NSNumber *> *strides) {
            auto *dst = static_cast<uint16_t *>(mutableBytes);
            const ptrdiff_t s2 = strides[2].integerValue;
            const ptrdiff_t s3 = strides[3].integerValue;
            for (int32_t i = 0; i < S; ++i) {
                const uint16_t *srcRow = cos_ptr + static_cast<size_t>(start_pos + i) * kHeadDim;
                uint16_t *dstRow = dst + i * s2;
                if (s3 == 1) std::memcpy(dstRow, srcRow, kHeadDim * sizeof(uint16_t));
                else for (int32_t d = 0; d < kHeadDim; ++d) dstRow[d * s3] = srcRow[d];
            }
        }];
        [prefill_sin getMutableBytesWithHandler:^(void *mutableBytes, NSInteger, NSArray<NSNumber *> *strides) {
            auto *dst = static_cast<uint16_t *>(mutableBytes);
            const ptrdiff_t s2 = strides[2].integerValue;
            const ptrdiff_t s3 = strides[3].integerValue;
            for (int32_t i = 0; i < S; ++i) {
                const uint16_t *srcRow = sin_ptr + static_cast<size_t>(start_pos + i) * kHeadDim;
                uint16_t *dstRow = dst + i * s2;
                if (s3 == 1) std::memcpy(dstRow, srcRow, kHeadDim * sizeof(uint16_t));
                else for (int32_t d = 0; d < kHeadDim; ++d) dstRow[d * s3] = srcRow[d];
            }
        }];
        const uint16_t negMask = FloatToHalfBits(-10000.0f);
        [prefill_mask getMutableBytesWithHandler:^(void *mutableBytes, NSInteger, NSArray<NSNumber *> *strides) {
            auto *dst = static_cast<uint16_t *>(mutableBytes);
            const ptrdiff_t s2 = strides[2].integerValue;
            const ptrdiff_t s3 = strides[3].integerValue;
            for (int32_t i = 0; i < S; ++i) {
                const int32_t allowed = start_pos + i + 1;
                uint16_t *dstRow = dst + i * s2;
                if (s3 == 1) {
                    std::memset(dstRow, 0, static_cast<size_t>(allowed) * sizeof(uint16_t));
                    for (int32_t j = allowed; j < maxKV; ++j) dstRow[j] = negMask;
                } else {
                    for (int32_t j = 0; j < maxKV; ++j) dstRow[j * s3] = (j < allowed) ? uint16_t(0) : negMask;
                }
            }
        }];
        [prefill_write_pos getMutableBytesWithHandler:^(void *mutableBytes, NSInteger, NSArray<NSNumber *> *) {
            static_cast<int32_t *>(mutableBytes)[0] = start_pos;
        }];

        NSError *err = nil;
        MLState *st = (MLState *)llm_state;
        id<MLFeatureProvider> out = [prefill_model predictionFromFeatures:prefill_provider
                                                               usingState:st
                                                                  options:prefill_options
                                                                    error:&err];
        if (!out) {
            throw std::runtime_error(err ? [[err localizedDescription] UTF8String] : "MOSS prefill failed");
        }
    }

    API_AVAILABLE(macos(15.0))
    void RunSingleDecode(const uint16_t *embed_fp16, int32_t write_pos, float *out_logits) {
        const uint16_t *cos_row = rope_cos_fp16.data() + static_cast<size_t>(write_pos) * kHeadDim;
        const uint16_t *sin_row = rope_sin_fp16.data() + static_cast<size_t>(write_pos) * kHeadDim;
        const int32_t maxKV = max_kv_len;

        [decode_embeds getMutableBytesWithHandler:^(void *mutableBytes, NSInteger, NSArray<NSNumber *> *strides) {
            auto *dst = static_cast<uint16_t *>(mutableBytes);
            const ptrdiff_t s1 = strides[1].integerValue;
            if (s1 == 1) std::memcpy(dst, embed_fp16, kHiddenSize * sizeof(uint16_t));
            else for (int32_t c = 0; c < kHiddenSize; ++c) dst[c * s1] = embed_fp16[c];
        }];
        [decode_cos getMutableBytesWithHandler:^(void *mutableBytes, NSInteger, NSArray<NSNumber *> *strides) {
            auto *dst = static_cast<uint16_t *>(mutableBytes);
            const ptrdiff_t s3 = strides[3].integerValue;
            if (s3 == 1) std::memcpy(dst, cos_row, kHeadDim * sizeof(uint16_t));
            else for (int32_t d = 0; d < kHeadDim; ++d) dst[d * s3] = cos_row[d];
        }];
        [decode_sin getMutableBytesWithHandler:^(void *mutableBytes, NSInteger, NSArray<NSNumber *> *strides) {
            auto *dst = static_cast<uint16_t *>(mutableBytes);
            const ptrdiff_t s3 = strides[3].integerValue;
            if (s3 == 1) std::memcpy(dst, sin_row, kHeadDim * sizeof(uint16_t));
            else for (int32_t d = 0; d < kHeadDim; ++d) dst[d * s3] = sin_row[d];
        }];
        const uint16_t negMask = FloatToHalfBits(-10000.0f);
        const int32_t allowed = write_pos + 1;
        [decode_mask getMutableBytesWithHandler:^(void *mutableBytes, NSInteger, NSArray<NSNumber *> *strides) {
            auto *dst = static_cast<uint16_t *>(mutableBytes);
            const ptrdiff_t s3 = strides[3].integerValue;
            if (s3 == 1) {
                std::memset(dst, 0, static_cast<size_t>(allowed) * sizeof(uint16_t));
                for (int32_t j = allowed; j < maxKV; ++j) dst[j] = negMask;
            } else {
                for (int32_t j = 0; j < maxKV; ++j) dst[j * s3] = (j < allowed) ? uint16_t(0) : negMask;
            }
        }];
        [decode_write_pos getMutableBytesWithHandler:^(void *mutableBytes, NSInteger, NSArray<NSNumber *> *) {
            static_cast<int32_t *>(mutableBytes)[0] = write_pos;
        }];

        NSError *err = nil;
        MLState *st = (MLState *)llm_state;
        id<MLFeatureProvider> out = [decode_model predictionFromFeatures:decode_provider
                                                              usingState:st
                                                                 options:decode_options
                                                                   error:&err];
        if (!out) {
            throw std::runtime_error(err ? [[err localizedDescription] UTF8String] : "MOSS decode failed");
        }
        MLMultiArray *logitsArr = [out featureValueForName:@"logits"].multiArrayValue ?: decode_logits_backing;
        [logitsArr getBytesWithHandler:^(const void *bytes, NSInteger) {
            if (logitsArr.dataType == MLMultiArrayDataTypeFloat16) {
                ConvertHalfToFloat(static_cast<const uint16_t *>(bytes), out_logits, kVocabSize);
            } else {
                std::memcpy(out_logits, bytes, kVocabSize * sizeof(float));
            }
        }];
    }
};

extern "C" {

MoMoMOSSCoreMLHandle *MoMoMOSSCreate(
    const char *encoder_mlmodelc_path,
    const char *decoder_mlmodelc_path,
    const char *embedding_int8_path,
    int32_t max_kv_len,
    int32_t prefill_len,
    char *error_buf,
    size_t error_buf_size) {
    if (@available(macOS 15.0, *)) {
        @autoreleasepool {
            try {
                if (!encoder_mlmodelc_path || !decoder_mlmodelc_path || !embedding_int8_path) {
                    throw std::runtime_error("Null path passed to MoMoMOSSCreate");
                }
                auto h = std::make_unique<MoMoMOSSCoreMLHandle>();
                h->max_kv_len = max_kv_len > 0 ? max_kv_len : 4096;
                h->prefill_len = prefill_len > 0 ? prefill_len : 128;
                h->embedding = std::make_unique<MmapEmbeddingTable>(embedding_int8_path);
                if (h->embedding->hidden_size() != kHiddenSize || h->embedding->vocab_size() != kVocabSize) {
                    throw std::runtime_error("Unexpected MOSS embedding.int8.bin dimensions");
                }

                NSURL *encURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:encoder_mlmodelc_path] isDirectory:YES];
                NSURL *decURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:decoder_mlmodelc_path] isDirectory:YES];

                bool encAcc = false, decAcc = false;
                h->encoder_model = LoadCoreMLModel(encURL, nil, &encAcc);
                // Load prefill & decode on the exact same compute-unit tier so they share llm_state cleanly
                {
                    const MLComputeUnits tiers[] = {
                        MLComputeUnitsCPUAndNeuralEngine,
                        MLComputeUnitsAll,
                        MLComputeUnitsCPUAndGPU,
                        MLComputeUnitsCPUOnly,
                    };
                    NSError *lastErr = nil;
                    for (MLComputeUnits cu : tiers) {
                        MLModelConfiguration *preCfg = [[MLModelConfiguration alloc] init];
                        preCfg.computeUnits = cu;
                        preCfg.functionName = @"prefill";
                        NSError *err1 = nil;
                        MLModel *pm = [MLModel modelWithContentsOfURL:decURL configuration:preCfg error:&err1];
                        if (!pm) { lastErr = err1; continue; }

                        MLModelConfiguration *decCfg = [[MLModelConfiguration alloc] init];
                        decCfg.computeUnits = cu;
                        decCfg.functionName = @"decode";
                        NSError *err2 = nil;
                        MLModel *dm = [MLModel modelWithContentsOfURL:decURL configuration:decCfg error:&err2];
                        if (!dm) { lastErr = err2; continue; }

                        h->prefill_model = pm;
                        h->decode_model = dm;
                        decAcc = (cu != MLComputeUnitsCPUOnly);
                        break;
                    }
                    if (!h->prefill_model || !h->decode_model) {
                        throw std::runtime_error(lastErr ? [[lastErr localizedDescription] UTF8String] : "Failed to load MOSS decoder functions");
                    }
                }
                h->accelerator_mask = (encAcc ? 1 : 0) | (decAcc ? 2 : 0);

                h->enc_mel = MakeArray(@[ @1, @(kWhisperMels), @(kWhisperFrames) ], MLMultiArrayDataTypeFloat32, "enc_mel");
                h->enc_provider = MakeProvider(@{@"input_features" : [MLFeatureValue featureValueWithMultiArray:h->enc_mel]}, "enc_provider");
                h->enc_options = [[MLPredictionOptions alloc] init];

                h->llm_state = [h->prefill_model newState];
                if (!h->llm_state) throw std::runtime_error("Failed to allocate MOSS MLState");

                // Precompute RoPE cos/sin tables [max_kv_len, 128] in FP16
                constexpr int32_t kHalf = kHeadDim / 2;
                std::array<double, kHalf> inv_freq{};
                for (int32_t i = 0; i < kHalf; ++i) {
                    inv_freq[static_cast<size_t>(i)] = 1.0 / std::pow(kRopeTheta, static_cast<double>(2 * i) / static_cast<double>(kHeadDim));
                }
                h->rope_cos_fp16.resize(static_cast<size_t>(h->max_kv_len) * kHeadDim);
                h->rope_sin_fp16.resize(static_cast<size_t>(h->max_kv_len) * kHeadDim);
                for (int32_t pos = 0; pos < h->max_kv_len; ++pos) {
                    uint16_t *cr = h->rope_cos_fp16.data() + static_cast<size_t>(pos) * kHeadDim;
                    uint16_t *sr = h->rope_sin_fp16.data() + static_cast<size_t>(pos) * kHeadDim;
                    for (int32_t i = 0; i < kHalf; ++i) {
                        double angle = static_cast<double>(pos) * inv_freq[static_cast<size_t>(i)];
                        uint16_t ch = FloatToHalfBits(static_cast<float>(std::cos(angle)));
                        uint16_t sh = FloatToHalfBits(static_cast<float>(std::sin(angle)));
                        cr[i] = ch; cr[i + kHalf] = ch;
                        sr[i] = sh; sr[i + kHalf] = sh;
                    }
                }

                // Prefill inputs
                h->prefill_embeds = MakeArray(@[ @1, @(kHiddenSize), @1, @(h->prefill_len) ], MLMultiArrayDataTypeFloat16, "prefill_embeds");
                h->prefill_cos = MakeArray(@[ @1, @1, @(h->prefill_len), @(kHeadDim) ], MLMultiArrayDataTypeFloat16, "prefill_cos");
                h->prefill_sin = MakeArray(@[ @1, @1, @(h->prefill_len), @(kHeadDim) ], MLMultiArrayDataTypeFloat16, "prefill_sin");
                h->prefill_mask = MakeArray(@[ @1, @1, @(h->prefill_len), @(h->max_kv_len) ], MLMultiArrayDataTypeFloat16, "prefill_mask");
                h->prefill_write_pos = MakeArray(@[ @1 ], MLMultiArrayDataTypeInt32, "prefill_write_pos");
                h->prefill_provider = MakeProvider(@{
                    @"inputs_embeds" : [MLFeatureValue featureValueWithMultiArray:h->prefill_embeds],
                    @"cos" : [MLFeatureValue featureValueWithMultiArray:h->prefill_cos],
                    @"sin" : [MLFeatureValue featureValueWithMultiArray:h->prefill_sin],
                    @"attn_mask" : [MLFeatureValue featureValueWithMultiArray:h->prefill_mask],
                    @"write_pos" : [MLFeatureValue featureValueWithMultiArray:h->prefill_write_pos],
                }, "prefill_provider");
                h->prefill_options = [[MLPredictionOptions alloc] init];

                // Decode inputs
                h->decode_embeds = MakeArray(@[ @1, @(kHiddenSize), @1, @1 ], MLMultiArrayDataTypeFloat16, "decode_embeds");
                h->decode_cos = MakeArray(@[ @1, @1, @1, @(kHeadDim) ], MLMultiArrayDataTypeFloat16, "decode_cos");
                h->decode_sin = MakeArray(@[ @1, @1, @1, @(kHeadDim) ], MLMultiArrayDataTypeFloat16, "decode_sin");
                h->decode_mask = MakeArray(@[ @1, @1, @1, @(h->max_kv_len) ], MLMultiArrayDataTypeFloat16, "decode_mask");
                h->decode_write_pos = MakeArray(@[ @1 ], MLMultiArrayDataTypeInt32, "decode_write_pos");
                MLFeatureDescription *logitsDesc = h->decode_model.modelDescription.outputDescriptionsByName[@"logits"];
                MLMultiArrayDataType logitsDtype = (logitsDesc && logitsDesc.multiArrayConstraint)
                    ? logitsDesc.multiArrayConstraint.dataType : MLMultiArrayDataTypeFloat16;
                h->decode_logits_backing = MakeArray(@[ @1, @(kVocabSize) ], logitsDtype, "decode_logits");
                h->decode_provider = MakeProvider(@{
                    @"inputs_embeds" : [MLFeatureValue featureValueWithMultiArray:h->decode_embeds],
                    @"cos" : [MLFeatureValue featureValueWithMultiArray:h->decode_cos],
                    @"sin" : [MLFeatureValue featureValueWithMultiArray:h->decode_sin],
                    @"attn_mask" : [MLFeatureValue featureValueWithMultiArray:h->decode_mask],
                    @"write_pos" : [MLFeatureValue featureValueWithMultiArray:h->decode_write_pos],
                }, "decode_provider");
                h->decode_options = [[MLPredictionOptions alloc] init];
                h->decode_options.outputBackings = @{@"logits" : h->decode_logits_backing};
                h->scratch_logits.resize(kVocabSize);

                return h.release();
            } catch (const std::exception &e) {
                WriteErr(error_buf, error_buf_size, e.what());
                return nullptr;
            }
        }
    }
    WriteErr(error_buf, error_buf_size, "macOS 15.0 or newer is required for CoreML MOSS");
    return nullptr;
}

void MoMoMOSSDestroy(MoMoMOSSCoreMLHandle *handle) {
    if (!handle) return;
    @autoreleasepool {
        delete handle;
    }
}

int32_t MoMoMOSSAcceleratorMask(const MoMoMOSSCoreMLHandle *handle) {
    return handle ? handle->accelerator_mask : 0;
}

int32_t MoMoMOSSMaxKvLen(const MoMoMOSSCoreMLHandle *handle) {
    return handle ? handle->max_kv_len : 0;
}

int32_t MoMoMOSSPrefillLen(const MoMoMOSSCoreMLHandle *handle) {
    return handle ? handle->prefill_len : 0;
}

int32_t MoMoMOSSEncodeAudioChunk(
    MoMoMOSSCoreMLHandle *handle,
    const float *mel_80x3000,
    float *out_embeds_375x1024,
    char *error_buf,
    size_t error_buf_size) {
    if (!handle || !mel_80x3000 || !out_embeds_375x1024) {
        WriteErr(error_buf, error_buf_size, "Null argument to MoMoMOSSEncodeAudioChunk");
        return -1;
    }
    @autoreleasepool {
        try {
            [handle->enc_mel getMutableBytesWithHandler:^(void *mutableBytes, NSInteger, NSArray<NSNumber *> *strides) {
                auto *dst = static_cast<float *>(mutableBytes);
                const ptrdiff_t s1 = strides[1].integerValue;
                const ptrdiff_t s2 = strides[2].integerValue;
                for (int32_t m = 0; m < kWhisperMels; ++m) {
                    const float *srcRow = mel_80x3000 + static_cast<size_t>(m) * kWhisperFrames;
                    float *dstRow = dst + m * s1;
                    if (s2 == 1) std::memcpy(dstRow, srcRow, kWhisperFrames * sizeof(float));
                    else for (int32_t t = 0; t < kWhisperFrames; ++t) dstRow[t * s2] = srcRow[t];
                }
            }];

            NSError *err = nil;
            id<MLFeatureProvider> out = [handle->encoder_model predictionFromFeatures:handle->enc_provider
                                                                              options:handle->enc_options
                                                                                error:&err];
            if (!out) {
                throw std::runtime_error(err ? [[err localizedDescription] UTF8String] : "MOSSAudioEncoder prediction failed");
            }
            MLMultiArray *arr = [out featureValueForName:@"audio_embeds"].multiArrayValue;
            if (!arr || arr.count < kAudioChunkTokens * kHiddenSize) {
                throw std::runtime_error("Invalid MOSSAudioEncoder output");
            }
            [arr getBytesWithHandler:^(const void *bytes, NSInteger) {
                const auto *strides = arr.strides;
                const ptrdiff_t s1 = strides[1].integerValue;
                const ptrdiff_t s2 = strides[2].integerValue;
                if (arr.dataType == MLMultiArrayDataTypeFloat16) {
                    const auto *src = static_cast<const uint16_t *>(bytes);
                    for (int32_t t = 0; t < kAudioChunkTokens; ++t) {
                        float *dstRow = out_embeds_375x1024 + static_cast<size_t>(t) * kHiddenSize;
                        if (s2 == 1) {
                            ConvertHalfToFloat(src + t * s1, dstRow, kHiddenSize);
                        } else {
                            for (int32_t d = 0; d < kHiddenSize; ++d) {
                                dstRow[d] = HalfBitsToFloat(src[t * s1 + d * s2]);
                            }
                        }
                    }
                } else {
                    const auto *src = static_cast<const float *>(bytes);
                    for (int32_t t = 0; t < kAudioChunkTokens; ++t) {
                        float *dstRow = out_embeds_375x1024 + static_cast<size_t>(t) * kHiddenSize;
                        if (s2 == 1) std::memcpy(dstRow, src + t * s1, kHiddenSize * sizeof(float));
                        else for (int32_t d = 0; d < kHiddenSize; ++d) dstRow[d] = src[t * s1 + d * s2];
                    }
                }
            }];
            return 0;
        } catch (const std::exception &e) {
            WriteErr(error_buf, error_buf_size, e.what());
            return -1;
        }
    }
}

int32_t MoMoMOSSGenerate(
    MoMoMOSSCoreMLHandle *handle,
    const int32_t *token_ids,
    int32_t prompt_len,
    int32_t audio_token_id,
    const float *audio_embeds,
    int32_t num_audio_tokens,
    int32_t eos_token_id,
    int32_t im_end_token_id,
    int32_t max_new_tokens,
    int32_t *out_token_ids,
    int32_t *out_generated_count,
    int32_t *out_possibly_truncated,
    char *error_buf,
    size_t error_buf_size) {
    if (!handle || !token_ids || prompt_len <= 0 || !out_token_ids || !out_generated_count || !out_possibly_truncated) {
        WriteErr(error_buf, error_buf_size, "Invalid argument to MoMoMOSSGenerate");
        return -1;
    }
    if (prompt_len >= handle->max_kv_len) {
        WriteErr(error_buf, error_buf_size, "Prompt length exceeds MOSS max_kv_len");
        return -1;
    }
    if (@available(macOS 15.0, *)) {
        @autoreleasepool {
            try {
                // Build prompt embeddings in FP16 [prompt_len, 1024]
                std::vector<uint16_t> ctx_fp16(static_cast<size_t>(prompt_len) * kHiddenSize);
                int32_t audio_cursor = 0;
                for (int32_t i = 0; i < prompt_len; ++i) {
                    uint16_t *dst = ctx_fp16.data() + static_cast<size_t>(i) * kHiddenSize;
                    if (token_ids[i] == audio_token_id) {
                        if (!audio_embeds || audio_cursor >= num_audio_tokens) {
                            throw std::runtime_error("Audio token count mismatch during embedding injection");
                        }
                        ConvertFloatToHalf(audio_embeds + static_cast<size_t>(audio_cursor) * kHiddenSize, dst, kHiddenSize);
                        ++audio_cursor;
                    } else {
                        handle->embedding->LookupFp16(token_ids[i], dst);
                    }
                }
                if (audio_cursor != num_audio_tokens) {
                    throw std::runtime_error("Unused audio embeddings after injection");
                }

                // Chunked prefill up to prompt_len - 1 (last prompt token runs via decode to produce first logits)
                int32_t pos = 0;
                while (pos + handle->prefill_len < prompt_len) {
                    handle->RunChunkPrefill(ctx_fp16.data() + static_cast<size_t>(pos) * kHiddenSize, pos);
                    pos += handle->prefill_len;
                }

                float *logits = handle->scratch_logits.data();
                while (pos < prompt_len) {
                    handle->RunSingleDecode(ctx_fp16.data() + static_cast<size_t>(pos) * kHiddenSize, pos, logits);
                    ++pos;
                }

                const int32_t budget = std::min(max_new_tokens, handle->max_kv_len - pos);
                int32_t gen_count = 0;
                int32_t truncated = 0;

                for (int32_t step = 0; step < budget; ++step) {
                    // Greedy argmax with NaN guard
                    int32_t best_id = eos_token_id;
                    float best_val = -std::numeric_limits<float>::infinity();
                    for (int32_t v = 0; v < kVocabSize; ++v) {
                        float val = logits[v];
                        if (!std::isnan(val) && val > best_val) {
                            best_val = val;
                            best_id = v;
                        }
                    }
                    if (best_id == eos_token_id || best_id == im_end_token_id) {
                        truncated = 0;
                        break;
                    }
                    out_token_ids[gen_count++] = best_id;
                    // Fast repetition-loop guard: abort early if the last 12-token block repeats 3x consecutively
                    if (gen_count >= 36) {
                        bool loopFound = false;
                        for (int32_t period = 1; period <= 12; ++period) {
                            int32_t span = period * 3;
                            if (gen_count >= span) {
                                bool allMatch = true;
                                const int32_t base = gen_count - span;
                                for (int32_t k = 0; k < period * 2; ++k) {
                                    if (out_token_ids[base + k] != out_token_ids[base + k + period]) {
                                        allMatch = false;
                                        break;
                                    }
                                }
                                if (allMatch) {
                                    loopFound = true;
                                    break;
                                }
                            }
                        }
                        if (loopFound) {
                            truncated = 1;
                            break;
                        }
                    }
                    if (step + 1 >= budget || pos >= handle->max_kv_len) {
                        truncated = 1;
                        break;
                    }
                    handle->embedding->LookupFp16(best_id, handle->scratch_tok_fp16.data());
                    handle->RunSingleDecode(handle->scratch_tok_fp16.data(), pos, logits);
                    ++pos;
                }

                *out_generated_count = gen_count;
                *out_possibly_truncated = truncated;
                return 0;
            } catch (const std::exception &e) {
                WriteErr(error_buf, error_buf_size, e.what());
                return -1;
            }
        }
    }
    WriteErr(error_buf, error_buf_size, "macOS 15.0 or newer required");
    return -1;
}

}  // extern "C"
