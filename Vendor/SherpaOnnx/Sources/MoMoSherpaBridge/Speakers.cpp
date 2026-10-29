#include "MoMoSherpaBridge.h"
#include <onnxruntime/onnxruntime_cxx_api.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <exception>
#include <memory>
#include <stdexcept>
#include <vector>

namespace {

struct SpeakerCancelled : public std::exception {
  const char *what() const noexcept override { return "cancelled"; }
};

inline void CheckSpeakerCancel(MoMoCancelCallback cb, const void *ctx) {
  if (cb && cb(ctx) != 0) throw SpeakerCancelled();
}

void ExtractNormalizedEmbedding(const SherpaOnnxSpeakerEmbeddingExtractor *ext,
                                const float *clip48k, float out_emb[256]) {
  auto stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(ext);
  if (!stream) throw std::runtime_error("Cannot create embedding stream");
  std::unique_ptr<const SherpaOnnxOnlineStream,
                  decltype(&SherpaOnnxDestroyOnlineStream)>
      owner(stream, SherpaOnnxDestroyOnlineStream);
  SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, clip48k, 48000);
  SherpaOnnxOnlineStreamInputFinished(stream);
  if (!SherpaOnnxSpeakerEmbeddingExtractorIsReady(ext, stream)) {
    throw std::runtime_error("Incomplete embedding features");
  }
  auto vector = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(ext, stream);
  if (!vector) throw std::runtime_error("Missing embedding");
  std::unique_ptr<const float,
                  decltype(&SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding)>
      vector_owner(vector, SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding);
  double norm = 0.0;
  for (int j = 0; j < 256; ++j) norm += double(vector[j]) * vector[j];
  if (!std::isfinite(norm) || norm < 1e-12) {
    throw std::runtime_error("Invalid embedding");
  }
  const float inv_norm = static_cast<float>(1.0 / std::sqrt(norm));
  for (int j = 0; j < 256; ++j) out_emb[j] = vector[j] * inv_norm;
}

}  // namespace

struct MoMoSpeakerRuntime {
  Ort::Env env{ORT_LOGGING_LEVEL_ERROR, "MoMoSpeakers"};
  std::unique_ptr<Ort::Session> segmentation;
  const SherpaOnnxSpeakerEmbeddingExtractor *embedding = nullptr;
  int shift = 0, offset = 0;
  ~MoMoSpeakerRuntime() {
    if (embedding) SherpaOnnxDestroySpeakerEmbeddingExtractor(embedding);
  }
};

MoMoSpeakerRuntime *MoMoCreateSpeakerRuntime(const char *segmentation,
    const char *embedding, const char *provider, char *error, size_t capacity) {
  try {
    auto runtime = std::make_unique<MoMoSpeakerRuntime>();
    Ort::SessionOptions options;
    options.SetIntraOpNumThreads(2);
    options.SetInterOpNumThreads(1);
    options.AddConfigEntry("session.intra_op.allow_spinning", "0");
    options.AddConfigEntry("session.inter_op.allow_spinning", "0");
    runtime->segmentation =
        std::make_unique<Ort::Session>(runtime->env, segmentation, options);
    Ort::AllocatorWithDefaultOptions allocator;
    auto metadata = runtime->segmentation->GetModelMetadata();
    auto integer = [&](const char *key) {
      auto value = metadata.LookupCustomMetadataMapAllocated(key, allocator);
      if (!value) throw std::runtime_error("Missing segmentation metadata");
      return std::stoi(value.get());
    };
    if (integer("sample_rate") != 16000 || integer("window_size") != 160000 ||
        integer("num_speakers") != 3 || integer("num_classes") != 7) {
      throw std::runtime_error("Unsupported segmentation model");
    }
    runtime->shift = integer("receptive_field_shift");
    runtime->offset = integer("receptive_field_size") / 2;
    if (runtime->shift <= 0 || runtime->offset < 0) {
      throw std::runtime_error("Invalid frame clock");
    }
    SherpaOnnxSpeakerEmbeddingExtractorConfig config{};
    config.model = embedding;
    config.num_threads = 2;
    config.provider = provider;
    runtime->embedding = SherpaOnnxCreateSpeakerEmbeddingExtractor(&config);
    if (!runtime->embedding ||
        SherpaOnnxSpeakerEmbeddingExtractorDim(runtime->embedding) != 256) {
      throw std::runtime_error("Invalid WeSpeaker extractor");
    }
    return runtime.release();
  } catch (const std::exception &e) {
    if (error && capacity) std::snprintf(error, capacity, "%s", e.what());
  } catch (...) {
    if (error && capacity) {
      std::snprintf(error, capacity, "Speaker initialization failed");
    }
  }
  return nullptr;
}

void MoMoDestroySpeakerRuntime(MoMoSpeakerRuntime *runtime) { delete runtime; }

int MoMoAnalyzeSpeakers(MoMoSpeakerRuntime *runtime, const float *samples,
    int32_t count, MoMoCancelCallback is_cancelled, const void *cancel_context,
    MoMoSpeakerTurn *turns, int32_t capacity,
    char *error, size_t error_capacity) {
  try {
    if (!runtime || !samples || !turns || count <= 0 || count > 640000 ||
        capacity < 1) {
      throw std::runtime_error("Invalid speaker input");
    }
    CheckSpeakerCancel(is_cancelled, cancel_context);

    for (int32_t i = 0; i < count; ++i) {
      if (!std::isfinite(samples[i])) {
        throw std::runtime_error("Nonfinite speaker input");
      }
    }

    if (count <= runtime->offset) return 0;
    const int total_frames =
        (count - 1 - runtime->offset) / runtime->shift + 1;
    if (total_frames <= 0) return 0;

    // Exact frame-aligned ~5 s step (50% overlap on 10 s PyAnnote window).
    const int step_frames = std::max(1, 80000 / runtime->shift);
    const int win_step = step_frames * runtime->shift;

    std::vector<float> global_probs(static_cast<size_t>(total_frames) * 7, 0.0f);
    std::vector<float> global_weights(static_cast<size_t>(total_frames), 0.0f);

    std::vector<float> padded(160000, 0.0f);
    int64_t shape[] = {1, 1, 160000};
    auto memory =
        Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    Ort::AllocatorWithDefaultOptions allocator;
    auto in_name = runtime->segmentation->GetInputNameAllocated(0, allocator);
    auto out_name = runtime->segmentation->GetOutputNameAllocated(0, allocator);
    const char *inputs[] = {in_name.get()}, *outputs[] = {out_name.get()};

    constexpr int kPerms[6][3] = {
        {0, 1, 2}, {0, 2, 1}, {1, 0, 2}, {1, 2, 0}, {2, 0, 1}, {2, 1, 0}};

    // Map PyAnnote 7-class powerset index under speaker permutation pi:
    // 0: sil, 1..3: spk 0..2, 4: 0+1, 5: 0+2, 6: 1+2.
    auto map_powerset_class = [](int c, const int pi[3]) -> int {
      if (c == 0) return 0;
      if (c <= 3) return 1 + pi[c - 1];
      if (c == 4) return pi[0] + pi[1] + 3;
      if (c == 5) return pi[0] + pi[2] + 3;
      return pi[1] + pi[2] + 3;
    };

    for (int win_idx = 0;; ++win_idx) {
      CheckSpeakerCancel(is_cancelled, cancel_context);
      const int win_start = win_idx * win_step;
      if (win_start >= count) break;

      const int copy_n = std::min(160000, count - win_start);
      std::copy(samples + win_start, samples + win_start + copy_n,
                padded.begin());
      if (copy_n < 160000) {
        std::fill(padded.begin() + copy_n, padded.end(), 0.0f);
      }

      auto input = Ort::Value::CreateTensor<float>(
          memory, padded.data(), padded.size(), shape, 3);
      auto result = runtime->segmentation->Run(
          Ort::RunOptions{nullptr}, inputs, &input, 1, outputs, 1);
      auto dims = result[0].GetTensorTypeAndShapeInfo().GetShape();
      if (dims.size() != 3 || dims[0] != 1 || dims[2] != 7 || dims[1] < 1 ||
          dims[1] > 1000) {
        throw std::runtime_error("Invalid segmentation output");
      }

      const float *scores = result[0].GetTensorData<float>();
      const int win_frames = static_cast<int>(dims[1]);
      int valid_local_frames = 0;
      while (valid_local_frames < win_frames &&
             win_start + valid_local_frames * runtime->shift + runtime->offset <
                 count) {
        ++valid_local_frames;
      }
      if (valid_local_frames <= 0) break;

      std::vector<std::array<float, 7>> local_probs(
          static_cast<size_t>(valid_local_frames));
      for (int f = 0; f < valid_local_frames; ++f) {
        const float *row = scores + f * 7;
        float max_s = row[0];
        for (int c = 1; c < 7; ++c) {
          if (!std::isfinite(row[c])) {
            throw std::runtime_error("Nonfinite segmentation output");
          }
          if (row[c] > max_s) max_s = row[c];
        }
        if (!std::isfinite(row[0])) {
          throw std::runtime_error("Nonfinite segmentation output");
        }
        float sum = 0.0f;
        for (int c = 0; c < 7; ++c) {
          float e = std::exp(row[c] - max_s);
          local_probs[static_cast<size_t>(f)][static_cast<size_t>(c)] = e;
          sum += e;
        }
        const float inv = sum > 0.0f ? (1.0f / sum) : (1.0f / 7.0f);
        for (int c = 0; c < 7; ++c) {
          local_probs[static_cast<size_t>(f)][static_cast<size_t>(c)] *= inv;
        }
      }

      const int base_global_frame = win_idx * step_frames;
      int best_perm = 0;
      if (win_idx > 0) {
        double best_cost = 1e30;
        for (int p = 0; p < 6; ++p) {
          const int *pi = kPerms[p];
          double cost = 0.0;
          for (int f = 0; f < valid_local_frames; ++f) {
            const int g = base_global_frame + f;
            if (g >= total_frames) break;
            const float gw = global_weights[static_cast<size_t>(g)];
            if (gw <= 0.0f) continue;
            const float inv_gw = 1.0f / gw;
            const float *gp = global_probs.data() + static_cast<size_t>(g) * 7;
            // Marginal speaker posteriors in accumulated reference vs permuted window.
            const float ref_s[3] = {
                (gp[1] + gp[4] + gp[5]) * inv_gw,
                (gp[2] + gp[4] + gp[6]) * inv_gw,
                (gp[3] + gp[5] + gp[6]) * inv_gw};
            const auto &lp = local_probs[static_cast<size_t>(f)];
            const float loc_raw[3] = {
                lp[1] + lp[4] + lp[5],
                lp[2] + lp[4] + lp[6],
                lp[3] + lp[5] + lp[6]};
            float permuted_s[3] = {0.0f, 0.0f, 0.0f};
            for (int s = 0; s < 3; ++s) permuted_s[pi[s]] = loc_raw[s];
            for (int s = 0; s < 3; ++s) {
              cost += std::abs(double(ref_s[s]) - double(permuted_s[s]));
            }
          }
          if (cost < best_cost) {
            best_cost = cost;
            best_perm = p;
          }
        }
      }

      const int *pi = kPerms[best_perm];
      constexpr double kTwoPi = 6.28318530717958647692;
      for (int f = 0; f < valid_local_frames; ++f) {
        const int g = base_global_frame + f;
        if (g >= total_frames) break;
        // Raised-cosine window weight emphasizes central frames and blends overlaps smoothly.
        const float hann = static_cast<float>(
            0.5 - 0.5 * std::cos(kTwoPi * (f + 0.5) /
                                 std::max(1, valid_local_frames)));
        const float w = std::max(0.05f, hann);
        float *gp = global_probs.data() + static_cast<size_t>(g) * 7;
        const auto &lp = local_probs[static_cast<size_t>(f)];
        for (int c = 0; c < 7; ++c) {
          const int gc = map_powerset_class(c, pi);
          gp[gc] += w * lp[static_cast<size_t>(c)];
        }
        global_weights[static_cast<size_t>(g)] += w;
      }

      if (win_start + 160000 >= count) break;
    }

    std::vector<int> labels(static_cast<size_t>(total_frames), 0);
    for (int g = 0; g < total_frames; ++g) {
      const float *gp = global_probs.data() + static_cast<size_t>(g) * 7;
      int best_c = static_cast<int>(std::max_element(gp, gp + 7) - gp);
      // Pyannote powerset: 0=silence, 1..3=speaker 1/2/3, 4..6=overlap pairs.
      labels[static_cast<size_t>(g)] = (best_c > 3) ? -1 : best_c;
    }

    // Bridge micro-silence closures (<= ~85 ms) within the exact same exclusive speaker
    // so stop-consonant closures do not shatter turns into < 250 ms fragments.
    const int max_micro_gap_frames = std::max(1, 1360 / runtime->shift);
    for (int g = 0; g < total_frames;) {
      if (labels[static_cast<size_t>(g)] != 0) {
        ++g;
        continue;
      }
      int gap_start = g;
      while (g < total_frames && labels[static_cast<size_t>(g)] == 0) ++g;
      const int gap_len = g - gap_start;
      if (gap_start > 0 && g < total_frames &&
          gap_len <= max_micro_gap_frames) {
        const int prev_lbl = labels[static_cast<size_t>(gap_start - 1)];
        const int next_lbl = labels[static_cast<size_t>(g)];
        if (prev_lbl >= 1 && prev_lbl == next_lbl) {
          for (int k = gap_start; k < g; ++k) {
            labels[static_cast<size_t>(k)] = prev_lbl;
          }
        }
      }
    }

    int written = 0;
    std::array<std::vector<std::pair<int, int>>, 4> clean_spans_by_track;
    std::array<int, 4> total_clean_samples_by_track{0, 0, 0, 0};

    for (int i = 0; i < total_frames;) {
      int begin = i;
      const int label = labels[static_cast<size_t>(i)];
      while (i < total_frames && labels[static_cast<size_t>(i)] == label) ++i;
      const int start = begin * runtime->shift + runtime->offset;
      const int end = std::min<int>(count, i * runtime->shift + runtime->offset);
      if (label == 0 || end - start < 4000) continue;
      if (written == capacity) {
        throw std::runtime_error("Speaker output capacity exceeded");
      }
      auto &turn = turns[written++];
      turn = {};
      turn.start_sample = start;
      turn.end_sample = end;
      turn.local_speaker = label;

      if (label >= 1 && label <= 3) {
        clean_spans_by_track[static_cast<size_t>(label)].emplace_back(start, end);
        total_clean_samples_by_track[static_cast<size_t>(label)] += (end - start);
      }

      // Only contiguous, exclusive speech >= 1.5 s directly supplies a turn voiceprint.
      if (label < 1 || end - start < 24000) continue;
      CheckSpeakerCancel(is_cancelled, cancel_context);
      turn.clean_seconds = std::min(10.0f, float(end - start) / 16000.0f);
      std::vector<float> clip(48000);
      const int span_len = end - start;
      const int origin = start + std::max(0, (span_len - 48000) / 2);
      const int tile_len = std::min(48000, span_len);
      for (int j = 0; j < 48000; ++j) {
        clip[static_cast<size_t>(j)] = samples[origin + (j % tile_len)];
      }
      ExtractNormalizedEmbedding(runtime->embedding, clip.data(),
                                 turn.embedding);
    }

    // 1. Inherit voiceprint from the longest >= 1.5 s turn on the same stitched track.
    for (int i = 0; i < written; ++i) {
      if (turns[i].local_speaker < 1 || turns[i].clean_seconds > 0.0f) continue;
      int best = -1;
      for (int j = 0; j < written; ++j) {
        if (turns[j].local_speaker == turns[i].local_speaker &&
            turns[j].clean_seconds >= 1.5f &&
            (best < 0 || turns[j].clean_seconds > turns[best].clean_seconds)) {
          best = j;
        }
      }
      if (best >= 0) {
        std::copy(turns[best].embedding, turns[best].embedding + 256,
                  turns[i].embedding);
      }
    }

    // 2. If a stitched track had multiple short clean turns (< 1.5 s individually) whose
    // combined exclusive speech is >= 1.5 s, pool them with raised-cosine crossfade for
    // accurate clustering/matching while keeping clean_seconds = 0 so it never trains anchors.
    for (int spk = 1; spk <= 3; ++spk) {
      bool any_missing = false;
      bool any_has_emb = false;
      for (int i = 0; i < written; ++i) {
        if (turns[i].local_speaker != spk) continue;
        bool non_zero = false;
        for (int d = 0; d < 256; ++d) {
          if (turns[i].embedding[d] != 0.0f) {
            non_zero = true;
            break;
          }
        }
        if (non_zero) any_has_emb = true;
        else any_missing = true;
      }
      if (!any_missing || any_has_emb ||
          total_clean_samples_by_track[static_cast<size_t>(spk)] < 24000) {
        continue;
      }

      CheckSpeakerCancel(is_cancelled, cancel_context);
      std::vector<float> pooled;
      pooled.reserve(static_cast<size_t>(
          total_clean_samples_by_track[static_cast<size_t>(spk)]));
      constexpr int kFade = 64;
      for (const auto &[s, e] :
           clean_spans_by_track[static_cast<size_t>(spk)]) {
        const int seg_len = e - s;
        if (seg_len <= 0) continue;
        if (pooled.size() >= static_cast<size_t>(kFade) && seg_len >= kFade) {
          const size_t base = pooled.size() - kFade;
          for (int k = 0; k < kFade; ++k) {
            const float alpha = static_cast<float>(k + 1) / (kFade + 1);
            pooled[base + static_cast<size_t>(k)] =
                (1.0f - alpha) * pooled[base + static_cast<size_t>(k)] +
                alpha * samples[s + k];
          }
          pooled.insert(pooled.end(), samples + s + kFade, samples + e);
        } else {
          pooled.insert(pooled.end(), samples + s, samples + e);
        }
      }
      if (static_cast<int>(pooled.size()) < 24000) continue;

      std::vector<float> clip(48000);
      const int p_len = static_cast<int>(pooled.size());
      const int origin = std::max(0, (p_len - 48000) / 2);
      const int tile_len = std::min(48000, p_len);
      for (int j = 0; j < 48000; ++j) {
        clip[static_cast<size_t>(j)] =
            pooled[static_cast<size_t>(origin + (j % tile_len))];
      }
      float pooled_emb[256]{};
      ExtractNormalizedEmbedding(runtime->embedding, clip.data(), pooled_emb);
      for (int i = 0; i < written; ++i) {
        if (turns[i].local_speaker == spk) {
          std::copy(pooled_emb, pooled_emb + 256, turns[i].embedding);
        }
      }
    }

    return written;
  } catch (const SpeakerCancelled &) {
    return -2;
  } catch (const std::exception &e) {
    if (error && error_capacity) {
      std::snprintf(error, error_capacity, "%s", e.what());
    }
  } catch (...) {
    if (error && error_capacity) {
      std::snprintf(error, error_capacity, "Speaker inference failed");
    }
  }
  return -1;
}
