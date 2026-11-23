#ifndef C_MOMO_MAC_SPEECH_COREML_H
#define C_MOMO_MAC_SPEECH_COREML_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MoMoMOSSCoreMLHandle MoMoMOSSCoreMLHandle;
typedef struct MoMoReDimNetCoreMLHandle MoMoReDimNetCoreMLHandle;

// ============================================================================
// MOSS-Transcribe-Diarize 0.9B CoreML (ANE + GPU) Runtime
// ============================================================================

/// Creates a stateful CoreML runtime for MOSSAudioEncoder + MOSSDecoder + embedding.int8.bin.
/// Returns NULL and writes an error message on failure.
MoMoMOSSCoreMLHandle *MoMoMOSSCreate(
    const char *encoder_mlmodelc_path,
    const char *decoder_mlmodelc_path,
    const char *embedding_int8_path,
    int32_t max_kv_len,
    int32_t prefill_len,
    char *error_buf,
    size_t error_buf_size);

void MoMoMOSSDestroy(MoMoMOSSCoreMLHandle *handle);

/// Bit 0 (1): AudioEncoder ANE/GPU, Bit 1 (2): Decoder ANE/GPU.
int32_t MoMoMOSSAcceleratorMask(const MoMoMOSSCoreMLHandle *handle);
int32_t MoMoMOSSMaxKvLen(const MoMoMOSSCoreMLHandle *handle);
int32_t MoMoMOSSPrefillLen(const MoMoMOSSCoreMLHandle *handle);

/// Runs MOSSAudioEncoder on one 30s Whisper log-mel chunk [1, 80, 3000] (row-major float32).
/// Writes 375 x 1024 float32 embeddings to out_embeds (capacity >= 375 * 1024 floats).
/// Returns 0 on success, -1 on error.
int32_t MoMoMOSSEncodeAudioChunk(
    MoMoMOSSCoreMLHandle *handle,
    const float *mel_80x3000,
    float *out_embeds_375x1024,
    char *error_buf,
    size_t error_buf_size);

/// Runs full prompt prefill + greedy autoregressive decoding with repetition guard.
/// - token_ids: full prompt sequence including expanded audio_token_id & time markers (length = prompt_len).
/// - audio_embeds: flattened [num_audio_tokens, 1024] float32 embeddings to inject at audio_token_id positions.
/// - out_token_ids: buffer of capacity max_new_tokens.
/// - out_generated_count: actual generated token count.
/// - out_possibly_truncated: 1 if generation stopped due to max_new_tokens or max_kv_len instead of EOS/IM_END.
/// Returns 0 on success, -1 on error.
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
    size_t error_buf_size);

// ============================================================================
// ReDimNet2+ LMFT B6 CoreML (ANE) Speaker Embedding Runtime
// ============================================================================

MoMoReDimNetCoreMLHandle *MoMoReDimNetCreate(
    const char *mlmodelc_path,
    char *error_buf,
    size_t error_buf_size);

void MoMoReDimNetDestroy(MoMoReDimNetCoreMLHandle *handle);

/// Bit 0 (1): ReDimNet2+ loaded on ANE/GPU.
int32_t MoMoReDimNetAcceleratorMask(const MoMoReDimNetCoreMLHandle *handle);

/// Runs ReDimNet2Plus.mlmodelc on a 72-band mel spectrogram [1, 1, 72, num_frames] (row-major float32).
/// num_frames must match one of the exported buckets (200, 300, 400, 600).
/// Writes 192 L2-normalized float32 values into out_embedding.
/// Returns 0 on success, -1 on error.
int32_t MoMoReDimNetEmbed(
    MoMoReDimNetCoreMLHandle *handle,
    const float *mel_72xT,
    int32_t num_frames,
    float *out_embedding_192,
    char *error_buf,
    size_t error_buf_size);

#ifdef __cplusplus
}
#endif

#endif // C_MOMO_MAC_SPEECH_COREML_H
