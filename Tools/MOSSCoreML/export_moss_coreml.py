#!/usr/bin/env python3
"""Export OpenMOSS-Team/MOSS-Transcribe-Diarize (0.9B) to Apple CoreML (ANE-native MLProgram).

Architecture exported (complete joint ASR + Speaker Diarization + Timestamps + Hotwords):
  1. MOSSAudioEncoder.mlmodelc
     - 24-layer Whisper-medium encoder + 4x time-merge + 2-layer VQAdaptor
     - Static 30s chunk input [1, 80, 3000] -> [1, 375, 1024] (12.5 audio tokens/sec)
     - 4D [1, C, 1, S] Conv2d projections for Apple Neural Engine execution
  2. MOSSDecoder.mlmodelc
     - 28-layer Qwen3-0.6B (hidden=1024, inter=3072, heads=16, kv_heads=8, head_dim=128)
     - 4D [1, C, 1, S] Conv2d 1x1 projections + overflow-free FP16 ANERMSNorm
     - GQA view fusion + 16-way split lm_head + symmetric INT8 weight compression
     - MultiFunction MLProgram sharing 100% weights & FP16 MLState KV cache:
         * prefill(S=128, write_pos) for fast chunked multi-minute audio prefill
         * decode(S=1, write_pos) for autoregressive transcript generation
  3. embedding.int8.bin
     - 64-byte aligned MOMO_EMB v1 mmap-ready per-row symmetric INT8 + FP16 scale table ([151936, 1024])
  4. whisper_mel_filters_80x201.bin + tokenizer files + moss_coreml_config.json

Usage:
    uv run --no-project --python 3.12 \
        --with "torch>=2.4,<2.8" --with "coremltools==9.0" --with "numpy<2.4" \
        --with "transformers>=4.51,<5" --with safetensors \
        python Tools/MOSSCoreML/export_moss_coreml.py \
        --source-dir /path/to/moss-hf \
        --output-dir /path/to/output/MOSSCoreML \
        --max-kv 4096 --prefill-len 128
"""

from __future__ import annotations

import argparse
import gc
import hashlib
import json
import math
import re
import shutil
import struct
import subprocess
import time
from pathlib import Path

import coremltools as ct
import coremltools.optimize.coreml as cto
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from safetensors.torch import load_file as load_safetensors

# Model geometry (OpenMOSS-Team/MOSS-Transcribe-Diarize 0.9B)
WHISPER_MELS = 80
WHISPER_FRAMES = 3000
WHISPER_SEQ = 1500
WHISPER_DIM = 1024
WHISPER_HEADS = 16
WHISPER_HEAD_DIM = 64
WHISPER_FFN = 4096
WHISPER_LAYERS = 24
AUDIO_MERGE_SIZE = 4
AUDIO_CHUNK_TOKENS = WHISPER_SEQ // AUDIO_MERGE_SIZE  # 375 tokens per 30s chunk

LLM_HIDDEN = 1024
LLM_INTERMEDIATE = 3072
LLM_HEADS = 16
LLM_KV_HEADS = 8
LLM_HEAD_DIM = 128
LLM_LAYERS = 28
LLM_VOCAB = 151936
LLM_SPLIT_HEAD = 16
ROPE_THETA = 1000000.0

DEFAULT_PROMPT = (
    "请将音频转写为文本，每一段需以起始时间戳和说话人编号"
    "（[S01]、[S02]、[S03]…）开头，正文为对应的语音内容，"
    "并在段末标注结束时间戳，以清晰标明该段语音范围。"
)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# =============================================================================
# 1. Whisper-Medium Encoder + 4x Time Merge + VQAdaptor (ANE-Native)
# =============================================================================


class ANELayerNorm4D(nn.Module):
    """Channels-first LayerNorm on [1, C, 1, S] via hardware LayerNorm over last dim."""

    def __init__(self, dim: int, eps: float = 1e-5):
        super().__init__()
        self.dim = dim
        self.eps = max(eps, 1e-5)
        self.weight = nn.Parameter(torch.ones(dim))
        self.bias = nn.Parameter(torch.zeros(dim))

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        xt = x.permute(0, 3, 2, 1)  # [1, S, 1, C]
        normed = F.layer_norm(xt, (self.dim,), self.weight, self.bias, self.eps)
        return normed.permute(0, 3, 2, 1)


class WhisperANEEncoderLayer(nn.Module):
    def __init__(self):
        super().__init__()
        self.self_attn_layer_norm = ANELayerNorm4D(WHISPER_DIM, eps=1e-5)
        self.q_proj = nn.Conv2d(WHISPER_DIM, WHISPER_DIM, 1, bias=True)
        self.k_proj = nn.Conv2d(WHISPER_DIM, WHISPER_DIM, 1, bias=False)
        self.v_proj = nn.Conv2d(WHISPER_DIM, WHISPER_DIM, 1, bias=True)
        self.out_proj = nn.Conv2d(WHISPER_DIM, WHISPER_DIM, 1, bias=True)
        self.final_layer_norm = ANELayerNorm4D(WHISPER_DIM, eps=1e-5)
        self.fc1 = nn.Conv2d(WHISPER_DIM, WHISPER_FFN, 1, bias=True)
        self.fc2 = nn.Conv2d(WHISPER_FFN, WHISPER_DIM, 1, bias=True)
        self.scale = WHISPER_HEAD_DIM ** (-0.5)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        # x: [1, 1024, 1, 1500]
        residual = x
        h = self.self_attn_layer_norm(x)
        q = self.q_proj(h).view(1, WHISPER_HEADS, WHISPER_HEAD_DIM, WHISPER_SEQ).transpose(2, 3)
        k = self.k_proj(h).view(1, WHISPER_HEADS, WHISPER_HEAD_DIM, WHISPER_SEQ)
        v = self.v_proj(h).view(1, WHISPER_HEADS, WHISPER_HEAD_DIM, WHISPER_SEQ).transpose(2, 3)

        scores = torch.matmul(q * self.scale, k)
        probs = F.softmax(scores, dim=-1)
        attn_out = torch.matmul(probs, v).transpose(2, 3).reshape(1, WHISPER_DIM, 1, WHISPER_SEQ)
        x = residual + self.out_proj(attn_out)

        residual = x
        h2 = self.final_layer_norm(x)
        x = residual + self.fc2(F.gelu(self.fc1(h2)))
        return x


class MOSSAudioEncoderANE(nn.Module):
    """Fused Whisper-medium encoder + 4x time-merge + 2-layer VQAdaptor.

    Input:  mel [1, 80, 3000]
    Output: audio_embeds [1, 375, 1024]
    """

    def __init__(self):
        super().__init__()
        self.conv1 = nn.Conv1d(WHISPER_MELS, WHISPER_DIM, kernel_size=3, stride=1, padding=1)
        self.conv2 = nn.Conv1d(WHISPER_DIM, WHISPER_DIM, kernel_size=3, stride=2, padding=1)
        self.register_buffer("embed_positions", torch.zeros(1, WHISPER_DIM, 1, WHISPER_SEQ))
        self.layers = nn.ModuleList([WhisperANEEncoderLayer() for _ in range(WHISPER_LAYERS)])
        self.layer_norm = ANELayerNorm4D(WHISPER_DIM, eps=1e-5)

        # VQAdaptor: Linear(4096 -> 1024) -> SiLU -> Linear(1024 -> 1024) -> LayerNorm(1024)
        self.vq_fc1 = nn.Conv2d(WHISPER_DIM * AUDIO_MERGE_SIZE, LLM_HIDDEN, 1, bias=True)
        self.vq_fc2 = nn.Conv2d(LLM_HIDDEN, LLM_HIDDEN, 1, bias=True)
        self.vq_norm = ANELayerNorm4D(LLM_HIDDEN, eps=1e-5)

    def forward(self, input_features: torch.Tensor) -> torch.Tensor:
        # input_features: [1, 80, 3000]
        x = F.gelu(self.conv1(input_features))
        x = F.gelu(self.conv2(x))  # [1, 1024, 1500]
        x = x.unsqueeze(2) + self.embed_positions  # [1, 1024, 1, 1500]
        for layer in self.layers:
            x = layer(x)
        x = self.layer_norm(x)  # [1, 1024, 1, 1500]

        # Exact match to modeling_moss_transcribe_diarize.time_merge:
        # (1, 1500, 1024) -> (1, 375, 4096), then to [1, 4096, 1, 375]
        x_seq = x.squeeze(2).transpose(1, 2)  # [1, 1500, 1024]
        merged = x_seq.reshape(1, AUDIO_CHUNK_TOKENS, WHISPER_DIM * AUDIO_MERGE_SIZE)
        m4d = merged.transpose(1, 2).unsqueeze(2)  # [1, 4096, 1, 375]

        y = self.vq_fc2(F.silu(self.vq_fc1(m4d)))
        y = self.vq_norm(y)  # [1, 1024, 1, 375]
        return y.squeeze(2).transpose(1, 2)  # [1, 375, 1024]


def load_moss_audio_encoder(state_dict: dict[str, torch.Tensor]) -> MOSSAudioEncoderANE:
    model = MOSSAudioEncoderANE()
    with torch.no_grad():
        wp = "model.whisper_encoder."
        model.conv1.weight.copy_(state_dict[wp + "conv1.weight"].float())
        model.conv1.bias.copy_(state_dict[wp + "conv1.bias"].float())
        model.conv2.weight.copy_(state_dict[wp + "conv2.weight"].float())
        model.conv2.bias.copy_(state_dict[wp + "conv2.bias"].float())
        pos = state_dict[wp + "embed_positions.weight"].float()  # [1500, 1024]
        model.embed_positions.copy_(pos.T.view(1, WHISPER_DIM, 1, WHISPER_SEQ))
        for i in range(WHISPER_LAYERS):
            lp = f"{wp}layers.{i}."
            layer = model.layers[i]
            layer.self_attn_layer_norm.weight.copy_(state_dict[lp + "self_attn_layer_norm.weight"].float())
            layer.self_attn_layer_norm.bias.copy_(state_dict[lp + "self_attn_layer_norm.bias"].float())
            layer.q_proj.weight.copy_(state_dict[lp + "self_attn.q_proj.weight"].float().unsqueeze(-1).unsqueeze(-1))
            layer.q_proj.bias.copy_(state_dict[lp + "self_attn.q_proj.bias"].float())
            layer.k_proj.weight.copy_(state_dict[lp + "self_attn.k_proj.weight"].float().unsqueeze(-1).unsqueeze(-1))
            layer.v_proj.weight.copy_(state_dict[lp + "self_attn.v_proj.weight"].float().unsqueeze(-1).unsqueeze(-1))
            layer.v_proj.bias.copy_(state_dict[lp + "self_attn.v_proj.bias"].float())
            layer.out_proj.weight.copy_(state_dict[lp + "self_attn.out_proj.weight"].float().unsqueeze(-1).unsqueeze(-1))
            layer.out_proj.bias.copy_(state_dict[lp + "self_attn.out_proj.bias"].float())
            layer.final_layer_norm.weight.copy_(state_dict[lp + "final_layer_norm.weight"].float())
            layer.final_layer_norm.bias.copy_(state_dict[lp + "final_layer_norm.bias"].float())
            layer.fc1.weight.copy_(state_dict[lp + "fc1.weight"].float().unsqueeze(-1).unsqueeze(-1))
            layer.fc1.bias.copy_(state_dict[lp + "fc1.bias"].float())
            layer.fc2.weight.copy_(state_dict[lp + "fc2.weight"].float().unsqueeze(-1).unsqueeze(-1))
            layer.fc2.bias.copy_(state_dict[lp + "fc2.bias"].float())

        model.layer_norm.weight.copy_(state_dict[wp + "layer_norm.weight"].float())
        model.layer_norm.bias.copy_(state_dict[wp + "layer_norm.bias"].float())

        vp = "model.vq_adaptor.layers."
        model.vq_fc1.weight.copy_(state_dict[vp + "0.weight"].float().unsqueeze(-1).unsqueeze(-1))
        model.vq_fc1.bias.copy_(state_dict[vp + "0.bias"].float())
        model.vq_fc2.weight.copy_(state_dict[vp + "2.weight"].float().unsqueeze(-1).unsqueeze(-1))
        model.vq_fc2.bias.copy_(state_dict[vp + "2.bias"].float())
        model.vq_norm.weight.copy_(state_dict[vp + "3.weight"].float())
        model.vq_norm.bias.copy_(state_dict[vp + "3.bias"].float())
    model.eval()
    return model


# =============================================================================
# 2. Stateful ANE-Native Qwen3-0.6B (MultiFunction: chunked prefill + decode)
# =============================================================================


class ANERMSNorm(nn.Module):
    """Exact overflow-free FP16 RMSNorm via ANE hardware LayerNorm([x, -x])."""

    def __init__(self, dim: int, eps: float = 1e-5, channel_first: bool = True):
        super().__init__()
        self.dim = dim
        # Clamp subnormal FP16 eps (1e-6 -> 1e-5) to prevent flush-to-zero on ANE.
        self.eps = max(float(eps), 1e-5)
        self.channel_first = channel_first
        self.weight = nn.Parameter(torch.ones(dim))

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        if self.channel_first:
            xt = x.permute(0, 3, 2, 1)
            doubled = torch.cat([xt, -xt], dim=-1)
            normed = F.layer_norm(doubled, (self.dim * 2,), eps=self.eps)[..., : self.dim]
            normed = normed * self.weight.view(1, 1, 1, self.dim)
            return normed.permute(0, 3, 2, 1)
        doubled = torch.cat([x, -x], dim=-1)
        normed = F.layer_norm(doubled, (self.dim * 2,), eps=self.eps)[..., : self.dim]
        return normed * self.weight.view(1, 1, 1, self.dim)


def rotate_half_static(x: torch.Tensor) -> torch.Tensor:
    d = int(x.shape[-1]) // 2
    return torch.cat([-x[..., d:], x[..., :d]], dim=-1)


class Qwen3ANEDecoderLayer(nn.Module):
    def __init__(self, max_kv: int, rms_eps: float = 1e-6):
        super().__init__()
        self.max_kv = max_kv
        self.input_layernorm = ANERMSNorm(LLM_HIDDEN, eps=rms_eps, channel_first=True)
        self.q_proj = nn.Conv2d(LLM_HIDDEN, LLM_HEADS * LLM_HEAD_DIM, 1, bias=False)
        self.k_proj = nn.Conv2d(LLM_HIDDEN, LLM_KV_HEADS * LLM_HEAD_DIM, 1, bias=False)
        self.v_proj = nn.Conv2d(LLM_HIDDEN, LLM_KV_HEADS * LLM_HEAD_DIM, 1, bias=False)
        self.o_proj = nn.Conv2d(LLM_HEADS * LLM_HEAD_DIM, LLM_HIDDEN, 1, bias=False)
        self.q_norm = ANERMSNorm(LLM_HEAD_DIM, eps=rms_eps, channel_first=False)
        self.k_norm = ANERMSNorm(LLM_HEAD_DIM, eps=rms_eps, channel_first=False)
        self.post_attention_layernorm = ANERMSNorm(LLM_HIDDEN, eps=rms_eps, channel_first=True)
        self.gate_proj = nn.Conv2d(LLM_HIDDEN, LLM_INTERMEDIATE, 1, bias=False)
        self.up_proj = nn.Conv2d(LLM_HIDDEN, LLM_INTERMEDIATE, 1, bias=False)
        self.down_proj = nn.Conv2d(LLM_INTERMEDIATE, LLM_HIDDEN, 1, bias=False)
        self.scale = LLM_HEAD_DIM ** (-0.5)

    def forward(self, x, cos, sin, attn_mask, k_cache, v_cache, layer_idx: int, write_pos):
        S = int(x.shape[-1])
        h = self.input_layernorm(x)
        q = self.q_proj(h).view(1, LLM_HEADS, LLM_HEAD_DIM, S).transpose(2, 3)
        k = self.k_proj(h).view(1, LLM_KV_HEADS, LLM_HEAD_DIM, S).transpose(2, 3)
        v = self.v_proj(h).view(1, LLM_KV_HEADS, LLM_HEAD_DIM, S).transpose(2, 3)

        q = self.q_norm(q)
        k = self.k_norm(k)

        q = (q * cos) + (rotate_half_static(q) * sin)
        k = (k * cos) + (rotate_half_static(k) * sin)

        k_cache[layer_idx : layer_idx + 1, :, write_pos : write_pos + S, :] = k
        v_cache[layer_idx : layer_idx + 1, :, write_pos : write_pos + S, :] = v

        k_full = k_cache[layer_idx : layer_idx + 1]
        v_full = v_cache[layer_idx : layer_idx + 1]

        gqa_rep = LLM_HEADS // LLM_KV_HEADS
        q_gqa = q.view(1, LLM_KV_HEADS, gqa_rep * S, LLM_HEAD_DIM)
        scores = torch.matmul(q_gqa * self.scale, k_full.transpose(-2, -1))
        scores = scores.view(1, LLM_HEADS, S, self.max_kv) + attn_mask
        probs = F.softmax(scores, dim=-1)
        probs_gqa = probs.view(1, LLM_KV_HEADS, gqa_rep * S, self.max_kv)
        attn_out = torch.matmul(probs_gqa, v_full)
        attn_out = attn_out.view(1, LLM_HEADS, S, LLM_HEAD_DIM).transpose(2, 3).reshape(1, LLM_HEADS * LLM_HEAD_DIM, 1, S)
        x = x + self.o_proj(attn_out)

        h2 = self.post_attention_layernorm(x)
        mlp = self.down_proj(F.silu(self.gate_proj(h2)) * self.up_proj(h2))
        return x + mlp


class Qwen3ANEBase(nn.Module):
    def __init__(self, max_kv: int, rms_eps: float = 1e-6, sink_start_layer: int = 2, residual_scale: float = 0.0625):
        super().__init__()
        self.max_kv = max_kv
        self.sink_start_layer = sink_start_layer
        self.residual_scale = residual_scale
        self.layers = nn.ModuleList([Qwen3ANEDecoderLayer(max_kv=max_kv, rms_eps=rms_eps) for _ in range(LLM_LAYERS)])
        self.norm = ANERMSNorm(LLM_HIDDEN, eps=rms_eps, channel_first=True)
        chunk = LLM_VOCAB // LLM_SPLIT_HEAD
        assert chunk * LLM_SPLIT_HEAD == LLM_VOCAB
        self.lm_heads = nn.ModuleList([nn.Conv2d(LLM_HIDDEN, chunk, 1, bias=False) for _ in range(LLM_SPLIT_HEAD)])


class Qwen3ChunkPrefillWrapper(nn.Module):
    def __init__(self, base: Qwen3ANEBase, max_kv: int | None = None, state_suffix: str = ""):
        super().__init__()
        self.layers = base.layers
        self.sink_start_layer = base.sink_start_layer
        self.residual_scale = base.residual_scale
        self.max_kv = int(max_kv or base.max_kv)
        self.k_name = f"k_cache{state_suffix}"
        self.v_name = f"v_cache{state_suffix}"
        self.register_buffer(self.k_name, torch.zeros((LLM_LAYERS, LLM_KV_HEADS, self.max_kv, LLM_HEAD_DIM), dtype=torch.float32))
        self.register_buffer(self.v_name, torch.zeros((LLM_LAYERS, LLM_KV_HEADS, self.max_kv, LLM_HEAD_DIM), dtype=torch.float32))

    def forward(self, inputs_embeds, cos, sin, attn_mask, write_pos):
        kc = getattr(self, self.k_name)
        vc = getattr(self, self.v_name)
        x = inputs_embeds
        for idx, layer in enumerate(self.layers):
            if idx == self.sink_start_layer and self.residual_scale != 1.0:
                x = x * self.residual_scale
            layer.max_kv = self.max_kv
            x = layer(x, cos, sin, attn_mask, kc, vc, idx, write_pos)
        return x[:, :1, :1, :1]


class Qwen3DecodeWrapper(nn.Module):
    def __init__(self, base: Qwen3ANEBase, max_kv: int | None = None, state_suffix: str = ""):
        super().__init__()
        self.layers = base.layers
        self.norm = base.norm
        self.lm_heads = base.lm_heads
        self.sink_start_layer = base.sink_start_layer
        self.residual_scale = base.residual_scale
        self.max_kv = int(max_kv or base.max_kv)
        self.k_name = f"k_cache{state_suffix}"
        self.v_name = f"v_cache{state_suffix}"
        self.register_buffer(self.k_name, torch.zeros((LLM_LAYERS, LLM_KV_HEADS, self.max_kv, LLM_HEAD_DIM), dtype=torch.float32))
        self.register_buffer(self.v_name, torch.zeros((LLM_LAYERS, LLM_KV_HEADS, self.max_kv, LLM_HEAD_DIM), dtype=torch.float32))

    def forward(self, inputs_embeds, cos, sin, attn_mask, write_pos):
        kc = getattr(self, self.k_name)
        vc = getattr(self, self.v_name)
        x = inputs_embeds
        for idx, layer in enumerate(self.layers):
            if idx == self.sink_start_layer and self.residual_scale != 1.0:
                x = x * self.residual_scale
            layer.max_kv = self.max_kv
            x = layer(x, cos, sin, attn_mask, kc, vc, idx, write_pos)
        x = self.norm(x)
        chunks = [head(x) for head in self.lm_heads]
        return torch.cat(chunks, dim=1).squeeze(-1).squeeze(-1)


def build_rope_tables(max_seq: int, head_dim: int = LLM_HEAD_DIM, theta: float = ROPE_THETA):
    inv_freq = 1.0 / (theta ** (np.arange(0, head_dim, 2, dtype=np.float64) / head_dim))
    t = np.arange(max_seq, dtype=np.float64)
    freqs = np.outer(t, inv_freq)
    emb = np.concatenate([freqs, freqs], axis=-1)
    return np.cos(emb).astype(np.float16), np.sin(emb).astype(np.float16)


def load_qwen3_into_ane_base(
    state_dict: dict[str, torch.Tensor],
    text_cfg: dict,
    max_kv: int,
    sink_start_layer: int,
    residual_scale: float,
) -> Qwen3ANEBase:
    assert text_cfg["num_hidden_layers"] == LLM_LAYERS
    assert text_cfg["hidden_size"] == LLM_HIDDEN
    assert text_cfg["intermediate_size"] == LLM_INTERMEDIATE
    assert text_cfg["num_attention_heads"] == LLM_HEADS
    assert text_cfg["num_key_value_heads"] == LLM_KV_HEADS
    assert text_cfg["head_dim"] == LLM_HEAD_DIM
    assert text_cfg["vocab_size"] == LLM_VOCAB

    mlp_up_scale = math.sqrt(residual_scale)
    mlp_down_scale = math.sqrt(residual_scale)

    base = Qwen3ANEBase(
        max_kv=max_kv,
        rms_eps=float(text_cfg.get("rms_norm_eps", 1e-6)),
        sink_start_layer=sink_start_layer,
        residual_scale=residual_scale,
    )
    prefix = "model.language_model."
    with torch.no_grad():
        for i in range(LLM_LAYERS):
            p = f"{prefix}layers.{i}."
            layer = base.layers[i]
            layer.input_layernorm.weight.copy_(state_dict[p + "input_layernorm.weight"].float())
            layer.q_proj.weight.copy_(state_dict[p + "self_attn.q_proj.weight"].float().unsqueeze(-1).unsqueeze(-1))
            layer.k_proj.weight.copy_(state_dict[p + "self_attn.k_proj.weight"].float().unsqueeze(-1).unsqueeze(-1))
            layer.v_proj.weight.copy_(state_dict[p + "self_attn.v_proj.weight"].float().unsqueeze(-1).unsqueeze(-1))
            layer.o_proj.weight.copy_(state_dict[p + "self_attn.o_proj.weight"].float().unsqueeze(-1).unsqueeze(-1))
            layer.q_norm.weight.copy_(state_dict[p + "self_attn.q_norm.weight"].float())
            layer.k_norm.weight.copy_(state_dict[p + "self_attn.k_norm.weight"].float())
            layer.post_attention_layernorm.weight.copy_(state_dict[p + "post_attention_layernorm.weight"].float())
            layer.gate_proj.weight.copy_(state_dict[p + "mlp.gate_proj.weight"].float().unsqueeze(-1).unsqueeze(-1))
            layer.up_proj.weight.copy_(state_dict[p + "mlp.up_proj.weight"].float().unsqueeze(-1).unsqueeze(-1))
            layer.down_proj.weight.copy_(state_dict[p + "mlp.down_proj.weight"].float().unsqueeze(-1).unsqueeze(-1))
            if i >= sink_start_layer and residual_scale != 1.0:
                layer.o_proj.weight.mul_(residual_scale)
                layer.up_proj.weight.mul_(mlp_up_scale)
                layer.down_proj.weight.mul_(mlp_down_scale)

        base.norm.weight.copy_(state_dict[prefix + "norm.weight"].float())
        if "lm_head.weight" in state_dict:
            lm_w = state_dict["lm_head.weight"].float()
        else:
            lm_w = state_dict[prefix + "embed_tokens.weight"].float()
        chunk = LLM_VOCAB // LLM_SPLIT_HEAD
        for c in range(LLM_SPLIT_HEAD):
            base.lm_heads[c].weight.copy_(lm_w[c * chunk : (c + 1) * chunk].unsqueeze(-1).unsqueeze(-1))

    base.eval()
    return base


def export_embedding_int8(embed_weight: torch.Tensor, out_path: Path) -> dict:
    w = embed_weight.detach().float().cpu().numpy()
    vocab, hidden = w.shape
    assert (vocab, hidden) == (LLM_VOCAB, LLM_HIDDEN), f"Unexpected embed shape: {w.shape}"

    amax = np.max(np.abs(w), axis=1)
    scales_fp16 = np.maximum(amax / 127.0, np.float32(1e-8)).astype(np.float16)
    scales_fp32 = scales_fp16.astype(np.float32)
    q_int8 = np.clip(np.rint(w / scales_fp32[:, None]), -127, 127).astype(np.int8)

    rng = np.random.default_rng(42)
    sample_ids = rng.choice(vocab, size=1024, replace=False)
    recon = q_int8[sample_ids].astype(np.float32) * scales_fp32[sample_ids, None]
    ref = w[sample_ids]
    norms = np.linalg.norm(ref, axis=1) * np.linalg.norm(recon, axis=1)
    valid = norms > 1e-12
    row_cos = np.sum(ref[valid] * recon[valid], axis=1) / norms[valid]
    min_cos, mean_cos = float(np.min(row_cos)), float(np.mean(row_cos))
    assert mean_cos > 0.9995 and min_cos > 0.998, f"Embedding cosine low: mean={mean_cos}, min={min_cos}"

    header_size = 64
    scales_bytes = scales_fp16.tobytes()
    scales_offset = header_size
    weights_offset = ((scales_offset + len(scales_bytes) + 63) // 64) * 64
    pad_bytes = b"\x00" * (weights_offset - (scales_offset + len(scales_bytes)))

    header = struct.pack(
        "<8sIIIIQQ24s",
        b"MOMO_EMB",
        1,
        vocab,
        hidden,
        1,
        scales_offset,
        weights_offset,
        b"\x00" * 24,
    )
    with open(out_path, "wb") as f:
        f.write(header)
        f.write(scales_bytes)
        f.write(pad_bytes)
        f.write(q_int8.tobytes())

    return {
        "bytes": out_path.stat().st_size,
        "meanSampleCosine": round(mean_cos, 6),
        "minSampleCosine": round(min_cos, 6),
    }


def load_hf_state_dict(source_dir: Path) -> dict[str, torch.Tensor]:
    single = source_dir / "model.safetensors"
    if single.is_file():
        return load_safetensors(str(single), device="cpu")
    index_path = source_dir / "model.safetensors.index.json"
    if index_path.is_file():
        index = json.loads(index_path.read_text(encoding="utf-8"))
        shards = sorted(set(index["weight_map"].values()))
        merged: dict[str, torch.Tensor] = {}
        for shard in shards:
            merged.update(load_safetensors(str(source_dir / shard), device="cpu"))
        return merged
    raise FileNotFoundError(f"No safetensors checkpoint found in {source_dir}")


def probe_qwen3_activation_scale(
    state_dict: dict[str, torch.Tensor],
    text_cfg: dict,
    audio_encoder: MOSSAudioEncoderANE,
    source_dir: Path,
) -> tuple[int, float, float]:
    """Measure peak residual magnitude per layer in FP32 to choose exact power-of-two FP16 sink scaling."""
    from transformers import WhisperFeatureExtractor

    fe = WhisperFeatureExtractor.from_pretrained(str(source_dir))
    rng = np.random.default_rng(7)
    wav = (rng.standard_normal(16000 * 4).astype(np.float32) * 0.05)
    mel = fe(wav, sampling_rate=16000, return_tensors="pt").input_features  # [1, 80, 3000]
    with torch.no_grad():
        aud_emb = audio_encoder(mel)[0, :50]  # [50, 1024]
        tok_emb = state_dict["model.language_model.embed_tokens.weight"][[151644, 8948, 198, 151645]].float()
        seq = torch.cat([tok_emb, aud_emb], dim=0)  # [54, 1024]

    base_unscaled = load_qwen3_into_ane_base(state_dict, text_cfg, max_kv=128, sink_start_layer=999, residual_scale=1.0)
    cos_tab, sin_tab = build_rope_tables(128)
    S = seq.shape[0]
    x = seq.T.view(1, LLM_HIDDEN, 1, S)
    cos = torch.from_numpy(cos_tab[:S].astype(np.float32)).view(1, 1, S, LLM_HEAD_DIM)
    sin = torch.from_numpy(sin_tab[:S].astype(np.float32)).view(1, 1, S, LLM_HEAD_DIM)
    mask = torch.full((1, 1, S, 128), -1e4, dtype=torch.float32)
    for i in range(S):
        mask[0, 0, i, : i + 1] = 0.0
    k_cache = torch.zeros((LLM_LAYERS, LLM_KV_HEADS, 128, LLM_HEAD_DIM))
    v_cache = torch.zeros((LLM_LAYERS, LLM_KV_HEADS, 128, LLM_HEAD_DIM))
    pos = torch.tensor(0, dtype=torch.int32)

    layer_peaks = []
    with torch.no_grad():
        for idx, layer in enumerate(base_unscaled.layers):
            x = layer(x, cos, sin, mask, k_cache, v_cache, idx, pos)
            peak = float(x.abs().max().item())
            layer_peaks.append((idx, peak))
    max_layer, max_peak = max(layer_peaks, key=lambda pair: pair[1])
    print(f"Qwen3 activation probe: max_abs={max_peak:.1f} at layer {max_layer} (L0={layer_peaks[0][1]:.1f}, L1={layer_peaks[1][1]:.1f}, L2={layer_peaks[2][1]:.1f})")
    del base_unscaled
    gc.collect()
    if max_peak > 4000.0:
        # Find first layer exceeding 2000 and pick power-of-two scale keeping peak < 4000
        start_layer = next((idx for idx, pk in layer_peaks if pk > 2000.0), 2)
        scale = 0.0625 if max_peak * 0.0625 <= 8000.0 else 0.015625
        print(f"Applying exact FP16 residual scaling: start_layer={start_layer}, scale={scale}")
        return start_layer, scale, max_peak
    print("No FP16 residual overflow risk detected; keeping residual_scale=1.0")
    return 999, 1.0, max_peak


def export_audio_encoder(
    audio_encoder: MOSSAudioEncoderANE,
    out_dir: Path,
    work_dir: Path,
    encoder_quant: str,
    reuse_existing: bool,
) -> dict:
    t0 = time.perf_counter()
    mlc_path = out_dir / "MOSSAudioEncoder.mlmodelc"
    if not (reuse_existing and (mlc_path / "weights" / "weight.bin").is_file()):
        print(f"Tracing MOSSAudioEncoder [1, {WHISPER_MELS}, {WHISPER_FRAMES}] -> [1, {AUDIO_CHUNK_TOKENS}, {LLM_HIDDEN}]...")
        example = torch.randn(1, WHISPER_MELS, WHISPER_FRAMES, dtype=torch.float32)
        traced = torch.jit.trace(audio_encoder, (example,), check_trace=False)
        mlmodel = ct.convert(
            traced,
            inputs=[ct.TensorType(name="input_features", shape=(1, WHISPER_MELS, WHISPER_FRAMES), dtype=np.float32)],
            outputs=[ct.TensorType(name="audio_embeds", dtype=np.float16)],
            compute_precision=ct.precision.FLOAT16,
            minimum_deployment_target=ct.target.macOS15,
            convert_to="mlprogram",
            skip_model_load=True,
        )
        if encoder_quant == "int8":
            print("Quantizing MOSSAudioEncoder weights to INT8...")
            qcfg = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8"))
            mlmodel = cto.linear_quantize_weights(mlmodel, config=qcfg)

        pkg = work_dir / "MOSSAudioEncoder.mlpackage"
        shutil.rmtree(pkg, ignore_errors=True)
        mlmodel.save(str(pkg))
        del mlmodel, traced
        gc.collect()

        shutil.rmtree(mlc_path, ignore_errors=True)
        print("Compiling MOSSAudioEncoder.mlpackage -> MOSSAudioEncoder.mlmodelc...")
        subprocess.run(["xcrun", "coremlcompiler", "compile", str(pkg), str(out_dir)], check=True)
        shutil.rmtree(pkg, ignore_errors=True)

    # Verify CoreML vs PyTorch FP32 parity and latency
    cm = ct.models.CompiledMLModel(str(mlc_path), compute_units=ct.ComputeUnit.CPU_AND_NE)
    rng = np.random.default_rng(123)
    test_mel = rng.standard_normal((1, WHISPER_MELS, WHISPER_FRAMES)).astype(np.float32) * 0.5
    with torch.no_grad():
        ref = audio_encoder(torch.from_numpy(test_mel)).numpy()
    _ = cm.predict({"input_features": test_mel})["audio_embeds"]
    lat = []
    out_cm = None
    for _ in range(3):
        ts = time.perf_counter()
        out_cm = cm.predict({"input_features": test_mel})["audio_embeds"].astype(np.float32)
        lat.append((time.perf_counter() - ts) * 1000.0)
    assert np.all(np.isfinite(out_cm)), "Non-finite MOSSAudioEncoder CoreML output!"
    cos = float(np.dot(ref.ravel(), out_cm.ravel()) / (np.linalg.norm(ref) * np.linalg.norm(out_cm)))
    print(f"MOSSAudioEncoder CoreML ANE parity: cosine={cos:.6f}, 30s chunk median={np.median(lat):.1f} ms")
    assert cos >= 0.995, f"MOSSAudioEncoder cosine too low: {cos}"
    del cm
    gc.collect()

    total_bytes = sum(f.stat().st_size for f in mlc_path.rglob("*") if f.is_file())
    return {
        "bytes": total_bytes,
        "mb": round(total_bytes / (1024 * 1024), 2),
        "quant": encoder_quant,
        "coremlVsFp32Cosine": round(cos, 6),
        "chunk30sMedianMs": round(float(np.median(lat)), 1),
        "exportSeconds": round(time.perf_counter() - t0, 2),
    }


def _quantize_decoder_mlmodel(ml, quant_mode: str):
    if quant_mode in ("lut6", "lut4"):
        nbits = 6 if quant_mode == "lut6" else 4
        # NOTE: split lm_head chunk size is 151936 / 16 = 9496 = 8 * 1187 (NOT divisible by 16!).
        # Using group_size=16 silently skips palettizing all 16 lm_heads (leaving 311 MB in FP16).
        # group_size=8 divides 1024, 2048, 3072, AND 9496 cleanly.
        qcfg = cto.OptimizationConfig(
            global_config=cto.OpPalettizerConfig(
                mode="kmeans", nbits=nbits, granularity="per_grouped_channel", group_size=8
            )
        )
        return cto.palettize_weights(ml, config=qcfg)
    qcfg = cto.OptimizationConfig(
        global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8")
    )
    return cto.linear_quantize_weights(ml, config=qcfg)


def _convert_kv_pair(
    base: Qwen3ANEBase,
    work_dir: Path,
    kv_len: int,
    prefill_len: int,
    quant_mode: str,
    state_suffix: str,
    tag: str,
) -> tuple[Path, Path]:
    prefill_mod = Qwen3ChunkPrefillWrapper(base, max_kv=kv_len, state_suffix=state_suffix).eval()
    decode_mod = Qwen3DecodeWrapper(base, max_kv=kv_len, state_suffix=state_suffix).eval()

    ex_emb_p = torch.randn(1, LLM_HIDDEN, 1, prefill_len)
    ex_cos_p = torch.randn(1, 1, prefill_len, LLM_HEAD_DIM)
    ex_sin_p = torch.randn(1, 1, prefill_len, LLM_HEAD_DIM)
    ex_mask_p = torch.zeros(1, 1, prefill_len, kv_len)
    ex_pos_p = torch.tensor([0], dtype=torch.int32)
    traced_prefill = torch.jit.trace(
        prefill_mod, (ex_emb_p, ex_cos_p, ex_sin_p, ex_mask_p, ex_pos_p), check_trace=False
    )

    ex_emb_d = torch.randn(1, LLM_HIDDEN, 1, 1)
    ex_cos_d = torch.randn(1, 1, 1, LLM_HEAD_DIM)
    ex_sin_d = torch.randn(1, 1, 1, LLM_HEAD_DIM)
    ex_mask_d = torch.zeros(1, 1, 1, kv_len)
    ex_pos_d = torch.tensor([16], dtype=torch.int32)
    traced_decode = torch.jit.trace(
        decode_mod, (ex_emb_d, ex_cos_d, ex_sin_d, ex_mask_d, ex_pos_d), check_trace=False
    )

    states = [
        ct.StateType(
            wrapped_type=ct.TensorType(shape=(LLM_LAYERS, LLM_KV_HEADS, kv_len, LLM_HEAD_DIM), dtype=np.float16),
            name=f"k_cache{state_suffix}",
        ),
        ct.StateType(
            wrapped_type=ct.TensorType(shape=(LLM_LAYERS, LLM_KV_HEADS, kv_len, LLM_HEAD_DIM), dtype=np.float16),
            name=f"v_cache{state_suffix}",
        ),
    ]

    print(f"Converting MOSS Qwen3 {tag} prefill (S={prefill_len}, MAX_KV={kv_len}) to MLProgram...")
    ml_prefill = ct.convert(
        traced_prefill,
        inputs=[
            ct.TensorType(name="inputs_embeds", shape=(1, LLM_HIDDEN, 1, prefill_len), dtype=np.float16),
            ct.TensorType(name="cos", shape=(1, 1, prefill_len, LLM_HEAD_DIM), dtype=np.float16),
            ct.TensorType(name="sin", shape=(1, 1, prefill_len, LLM_HEAD_DIM), dtype=np.float16),
            ct.TensorType(name="attn_mask", shape=(1, 1, prefill_len, kv_len), dtype=np.float16),
            ct.TensorType(name="write_pos", shape=(1,), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="anchor", dtype=np.float16)],
        states=states,
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS15,
        convert_to="mlprogram",
        skip_model_load=True,
    )
    del traced_prefill, prefill_mod
    gc.collect()

    print(f"Converting MOSS Qwen3 {tag} decode (S=1, MAX_KV={kv_len}) to MLProgram...")
    ml_decode = ct.convert(
        traced_decode,
        inputs=[
            ct.TensorType(name="inputs_embeds", shape=(1, LLM_HIDDEN, 1, 1), dtype=np.float16),
            ct.TensorType(name="cos", shape=(1, 1, 1, LLM_HEAD_DIM), dtype=np.float16),
            ct.TensorType(name="sin", shape=(1, 1, 1, LLM_HEAD_DIM), dtype=np.float16),
            ct.TensorType(name="attn_mask", shape=(1, 1, 1, kv_len), dtype=np.float16),
            ct.TensorType(name="write_pos", shape=(1,), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="logits", dtype=np.float16)],
        states=states,
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS15,
        convert_to="mlprogram",
        skip_model_load=True,
    )
    del traced_decode, decode_mod
    gc.collect()

    print(f"Quantizing MOSS Qwen3 {tag} decoder ({quant_mode})...")
    ml_prefill = _quantize_decoder_mlmodel(ml_prefill, quant_mode)
    ml_decode = _quantize_decoder_mlmodel(ml_decode, quant_mode)

    prefill_pkg = work_dir / f"moss_prefill_{tag}.mlpackage"
    decode_pkg = work_dir / f"moss_decode_{tag}.mlpackage"
    shutil.rmtree(prefill_pkg, ignore_errors=True)
    shutil.rmtree(decode_pkg, ignore_errors=True)
    ml_prefill.save(str(prefill_pkg))
    ml_decode.save(str(decode_pkg))
    del ml_prefill, ml_decode
    gc.collect()
    return prefill_pkg, decode_pkg


def audit_moss_compute_plan(enc_mlc: Path, dec_mlc: Path) -> dict:
    """Subprocess MLComputePlan + per-function ANE load audit verifying >=99.5% ANE residency and 0 compile errors."""
    import sys as _sys

    code = f"""
import json
import coremltools as ct
from coremltools.models.compute_plan import MLComputePlan

out = {{}}
for name, path, fn_target in [
    ("MOSSAudioEncoder", {str(enc_mlc)!r}, "main"),
    ("MOSSDecoder", {str(dec_mlc)!r}, "decode"),
]:
    plan = MLComputePlan.load_from_path(path, compute_units=ct.ComputeUnit.CPU_AND_NE)
    prog_fns = plan.model_structure.program.functions
    fn = prog_fns[fn_target]
    total = 0
    ane = 0
    non_ane = {{}}
    for op in fn.block.operations:
        if op.operator_name == "const" or "constexpr_" in op.operator_name:
            continue
        total += 1
        u = plan.get_compute_device_usage_for_mlprogram_operation(op)
        dev = type(u.preferred_compute_device).__name__ if u and u.preferred_compute_device else "None"
        if "NeuralEngine" in dev:
            ane += 1
        else:
            non_ane[f"{{op.operator_name}}->{{dev}}"] = non_ane.get(f"{{op.operator_name}}->{{dev}}", 0) + 1
    out[name] = {{
        "auditedFunction": fn_target,
        "availableFunctions": sorted(prog_fns.keys()),
        "totalComputeOps": total,
        "aneComputeOps": ane,
        "aneResidencyPct": round(100.0 * ane / max(total, 1), 2),
        "nonAneOps": non_ane,
    }}
    if name == "MOSSDecoder":
        for fn_name in sorted(prog_fns.keys()):
            _cm = ct.models.CompiledMLModel(path, function_name=fn_name, compute_units=ct.ComputeUnit.CPU_AND_NE)
            del _cm
print(json.dumps(out))
"""
    proc = subprocess.run([_sys.executable, "-c", code], capture_output=True, text=True, check=True)
    anec_fails = proc.stderr.count("ANECCompile() FAILED")
    if anec_fails > 0:
        raise RuntimeError(f"MOSS ANECCompile() FAILED {anec_fails} times:\n{proc.stderr}")
    audit = json.loads(proc.stdout.strip().splitlines()[-1])
    for key, stats in audit.items():
        if stats["aneResidencyPct"] < 99.5:
            raise RuntimeError(f"{key} ANE residency too low: {stats}")
    audit["anecCompileFailures"] = anec_fails
    print(f"MOSS ANE ComputePlan audit: {json.dumps(audit)}")
    return audit


def export_decoder(
    base: Qwen3ANEBase,
    out_dir: Path,
    work_dir: Path,
    max_kv: int,
    short_kv: int,
    prefill_len: int,
    quant_mode: str,
    reuse_existing: bool,
) -> dict:
    t0 = time.perf_counter()
    mlc_path = out_dir / "MOSSDecoder.mlmodelc"
    if not (reuse_existing and (mlc_path / "weights" / "weight.bin").is_file()):
        temp_pkgs: list[Path] = []
        desc = ct.utils.MultiFunctionDescriptor()

        p_long, d_long = _convert_kv_pair(base, work_dir, max_kv, prefill_len, quant_mode, "", f"kv{max_kv}")
        desc.add_function(str(p_long), src_function_name="main", target_function_name="prefill")
        desc.add_function(str(d_long), src_function_name="main", target_function_name="decode")
        temp_pkgs.extend([p_long, d_long])

        if short_kv > 0 and short_kv < max_kv:
            p_short, d_short = _convert_kv_pair(base, work_dir, short_kv, prefill_len, quant_mode, "_s", f"kv{short_kv}")
            desc.add_function(str(p_short), src_function_name="main", target_function_name="prefill_short")
            desc.add_function(str(d_short), src_function_name="main", target_function_name="decode_short")
            temp_pkgs.extend([p_short, d_short])

        merged_pkg = work_dir / "MOSSDecoder.mlpackage"
        shutil.rmtree(merged_pkg, ignore_errors=True)
        print("Merging decoder functions into weight-deduplicated MultiFunction MLProgram...")
        desc.default_function_name = "decode"
        ct.utils.save_multifunction(desc, str(merged_pkg))
        for p in temp_pkgs:
            shutil.rmtree(p, ignore_errors=True)

        shutil.rmtree(mlc_path, ignore_errors=True)
        print("Compiling MOSSDecoder.mlpackage -> MOSSDecoder.mlmodelc...")
        subprocess.run(["xcrun", "coremlcompiler", "compile", str(merged_pkg), str(out_dir)], check=True)
        shutil.rmtree(merged_pkg, ignore_errors=True)

    total_bytes = sum(f.stat().st_size for f in mlc_path.rglob("*") if f.is_file())
    return {
        "bytes": total_bytes,
        "mb": round(total_bytes / (1024 * 1024), 2),
        "quantMode": quant_mode,
        "prefillLen": prefill_len,
        "shortKvLen": short_kv if (0 < short_kv < max_kv) else 0,
        "maxKvLen": max_kv,
        "splitLmHead": LLM_SPLIT_HEAD,
        "exportSeconds": round(time.perf_counter() - t0, 2),
    }


def expand_audio_token_ids(
    audio_token_count: int,
    audio_token_id: int,
    digit_token_ids: dict[str, int],
    audio_tokens_per_second: float = 12.5,
    time_marker_every_seconds: int = 5,
) -> list[int]:
    tokens_per_marker = int(audio_tokens_per_second * time_marker_every_seconds)
    duration = audio_token_count / float(audio_tokens_per_second)
    output: list[int] = []
    consumed = 0
    for sec in range(time_marker_every_seconds, int(duration) + 1, time_marker_every_seconds):
        pos = (sec // time_marker_every_seconds) * tokens_per_marker
        seg_len = pos - consumed
        if seg_len > 0:
            output.extend([audio_token_id] * seg_len)
            consumed += seg_len
        output.extend(digit_token_ids[d] for d in str(sec))
    rem = audio_token_count - consumed
    if rem > 0:
        output.extend([audio_token_id] * rem)
    return output


def _load_fast_tokenizer(source_dir: Path):
    from tokenizers import Tokenizer
    return Tokenizer.from_file(str(source_dir / "tokenizer.json"))


def _render_moss_prompt(prompt: str = DEFAULT_PROMPT) -> tuple[str, str]:
    before = (
        "<|im_start|>system\nYou are a helpful assistant.<|im_end|>\n"
        "<|im_start|>user\n<|audio_start|>"
    )
    after = f"<|audio_end|>\n{prompt.strip() or DEFAULT_PROMPT}<|im_end|>\n<|im_start|>assistant\n"
    return before, after


def verify_end_to_end_coreml(
    source_dir: Path,
    out_dir: Path,
    max_kv: int,
    short_kv: int,
    prefill_len: int,
    test_wavs: list[Path],
) -> dict:
    """Run real audio end-to-end through CoreML ANE MOSSAudioEncoder + MOSSDecoder and measure RTF."""
    import wave
    from transformers import WhisperFeatureExtractor

    tok = _load_fast_tokenizer(source_dir)
    fe = WhisperFeatureExtractor.from_pretrained(str(source_dir))
    cfg = json.loads((source_dir / "config.json").read_text(encoding="utf-8"))
    audio_token_id = int(cfg["audio_token_id"])
    digit_ids = {d: int(tok.encode(d, add_special_tokens=False).ids[0]) for d in "0123456789"}

    with open(out_dir / "embedding.int8.bin", "rb") as f:
        blob = f.read()
    magic, ver, vocab, hidden, qtype, s_off, w_off, _ = struct.unpack("<8sIIIIQQ24s", blob[:64])
    assert magic == b"MOMO_EMB" and ver == 1
    scales = np.frombuffer(blob, dtype=np.float16, count=vocab, offset=s_off).astype(np.float32)
    weights = np.frombuffer(blob, dtype=np.int8, count=vocab * hidden, offset=w_off).reshape(vocab, hidden)

    def embed_ids(ids: list[int]) -> np.ndarray:
        arr = np.asarray(ids, dtype=np.int64)
        return weights[arr].astype(np.float32) * scales[arr, None]

    # Try CPU_AND_NE first; fall back to ALL if ANE rejects a large MLState shape
    compute_used = "CPU_AND_NE"
    has_short = 0 < short_kv < max_kv
    pre_short_cm = None
    dec_short_cm = None
    try:
        enc_cm = ct.models.CompiledMLModel(str(out_dir / "MOSSAudioEncoder.mlmodelc"), compute_units=ct.ComputeUnit.CPU_AND_NE)
        pre_cm = ct.models.CompiledMLModel(str(out_dir / "MOSSDecoder.mlmodelc"), function_name="prefill", compute_units=ct.ComputeUnit.CPU_AND_NE)
        dec_cm = ct.models.CompiledMLModel(str(out_dir / "MOSSDecoder.mlmodelc"), function_name="decode", compute_units=ct.ComputeUnit.CPU_AND_NE)
        if has_short:
            pre_short_cm = ct.models.CompiledMLModel(str(out_dir / "MOSSDecoder.mlmodelc"), function_name="prefill_short", compute_units=ct.ComputeUnit.CPU_AND_NE)
            dec_short_cm = ct.models.CompiledMLModel(str(out_dir / "MOSSDecoder.mlmodelc"), function_name="decode_short", compute_units=ct.ComputeUnit.CPU_AND_NE)
    except Exception as exc:
        print(f"CPU_AND_NE load fallback to ComputeUnit.ALL: {exc}")
        compute_used = "ALL"
        enc_cm = ct.models.CompiledMLModel(str(out_dir / "MOSSAudioEncoder.mlmodelc"), compute_units=ct.ComputeUnit.ALL)
        pre_cm = ct.models.CompiledMLModel(str(out_dir / "MOSSDecoder.mlmodelc"), function_name="prefill", compute_units=ct.ComputeUnit.ALL)
        dec_cm = ct.models.CompiledMLModel(str(out_dir / "MOSSDecoder.mlmodelc"), function_name="decode", compute_units=ct.ComputeUnit.ALL)
        if has_short:
            pre_short_cm = ct.models.CompiledMLModel(str(out_dir / "MOSSDecoder.mlmodelc"), function_name="prefill_short", compute_units=ct.ComputeUnit.ALL)
            dec_short_cm = ct.models.CompiledMLModel(str(out_dir / "MOSSDecoder.mlmodelc"), function_name="decode_short", compute_units=ct.ComputeUnit.ALL)

    active_state = None
    active_state_kv = 0
    cos_tab, sin_tab = build_rope_tables(max_kv)

    before_text, after_text = _render_moss_prompt(DEFAULT_PROMPT)
    before_ids = list(tok.encode(before_text, add_special_tokens=False).ids)
    after_ids = list(tok.encode(after_text, add_special_tokens=False).ids)
    im_end_id = int(tok.token_to_id("<|im_end|>"))
    eos_id = int(tok.token_to_id("<|endoftext|>") or im_end_id)

    # Pre-allocate reusable input buffers so CoreML's async `MLE5ExecutionStream resetAfterLingering:`
    # never calls Python's `_PyObject_Free` on a non-GIL GCD thread via `libcoremlpython`.
    enc_mel_buf = np.zeros((1, 80, 3000), dtype=np.float32)
    pre_emb_buf = np.zeros((1, LLM_HIDDEN, 1, prefill_len), dtype=np.float16)
    pre_cos_buf = np.zeros((1, 1, prefill_len, LLM_HEAD_DIM), dtype=np.float16)
    pre_sin_buf = np.zeros((1, 1, prefill_len, LLM_HEAD_DIM), dtype=np.float16)
    pre_mask_bufs = {
        kv: np.full((1, 1, prefill_len, kv), -1e4, dtype=np.float16)
        for kv in ({max_kv, short_kv} if has_short else {max_kv})
    }
    dec_emb_buf = np.zeros((1, LLM_HIDDEN, 1, 1), dtype=np.float16)
    dec_cos_buf = np.zeros((1, 1, 1, LLM_HEAD_DIM), dtype=np.float16)
    dec_sin_buf = np.zeros((1, 1, 1, LLM_HEAD_DIM), dtype=np.float16)
    dec_mask_bufs = {
        kv: np.full((1, 1, 1, kv), -1e4, dtype=np.float16)
        for kv in ({max_kv, short_kv} if has_short else {max_kv})
    }
    wpos_buf = np.zeros((1,), dtype=np.int32)
    keepalive_refs: list = [
        enc_mel_buf, pre_emb_buf, pre_cos_buf, pre_sin_buf, pre_mask_bufs,
        dec_emb_buf, dec_cos_buf, dec_sin_buf, dec_mask_bufs, wpos_buf,
    ]

    results = []
    for wav_path in test_wavs:
        if not wav_path.is_file():
            continue
        with wave.open(str(wav_path), "rb") as w:
            assert w.getframerate() == 16000 and w.getnchannels() == 1
            pcm = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32) / 32768.0
        dur = len(pcm) / 16000.0
        t0 = time.perf_counter()

        # Chunk into 30s segments and run MOSSAudioEncoder
        n_chunk_samples = 16000 * 30
        stride = 160 * 2 * AUDIO_MERGE_SIZE  # 1280 samples per audio token
        aud_parts = []
        total_audio_tokens = 0
        for start in range(0, len(pcm), n_chunk_samples):
            chunk = pcm[start : start + n_chunk_samples]
            tok_len = (len(chunk) - 1) // stride + 1
            padded = chunk if len(chunk) == n_chunk_samples else np.pad(chunk, (0, n_chunk_samples - len(chunk)))
            mel = fe(padded, sampling_rate=16000, return_tensors="np").input_features.astype(np.float32)
            np.copyto(enc_mel_buf, mel)
            enc_out = enc_cm.predict({"input_features": enc_mel_buf})["audio_embeds"][0, :tok_len].astype(np.float32)
            aud_parts.append(enc_out)
            total_audio_tokens += tok_len
        all_aud_embeds = np.concatenate(aud_parts, axis=0)

        audio_span_ids = expand_audio_token_ids(total_audio_tokens, audio_token_id, digit_ids)
        full_ids = before_ids + audio_span_ids + after_ids
        ctx_embeds = embed_ids(full_ids)
        aud_idx = 0
        for i, tid in enumerate(full_ids):
            if tid == audio_token_id:
                ctx_embeds[i] = all_aud_embeds[aud_idx]
                aud_idx += 1
        assert aud_idx == total_audio_tokens

        ctx_len = len(full_ids)
        max_new = min(max_kv - ctx_len, max(128, int(dur * 20)))
        use_short = has_short and (ctx_len + max_new <= short_kv)
        active_pre = pre_short_cm if use_short else pre_cm
        active_dec = dec_short_cm if use_short else dec_cm
        active_kv = short_kv if use_short else max_kv
        if active_state is None or active_state_kv != active_kv:
            # Keep only ONE MLState alive at a time in MultiFunction CoreML bundles
            active_state = None
            gc.collect()
            active_state = active_pre.make_state()
            active_state_kv = active_kv
        t_enc = time.perf_counter()

        pre_mask = pre_mask_bufs[active_kv]
        dec_mask = dec_mask_bufs[active_kv]

        # Chunked prefill
        pos = 0
        while pos + prefill_len < ctx_len:
            pre_emb_buf[0, :, 0, :] = ctx_embeds[pos : pos + prefill_len].T.astype(np.float16)
            pre_cos_buf[0, 0, :, :] = cos_tab[pos : pos + prefill_len]
            pre_sin_buf[0, 0, :, :] = sin_tab[pos : pos + prefill_len]
            pre_mask.fill(np.float16(-1e4))
            for i in range(prefill_len):
                pre_mask[0, 0, i, : pos + i + 1] = 0.0
            wpos_buf[0] = pos
            active_pre.predict(
                {
                    "inputs_embeds": pre_emb_buf,
                    "cos": pre_cos_buf,
                    "sin": pre_sin_buf,
                    "attn_mask": pre_mask,
                    "write_pos": wpos_buf,
                },
                state=active_state,
            )
            pos += prefill_len

        # Tail prompt tokens through decode
        logits = None
        while pos < ctx_len:
            dec_emb_buf[0, :, 0, 0] = ctx_embeds[pos].astype(np.float16)
            dec_cos_buf[0, 0, 0, :] = cos_tab[pos]
            dec_sin_buf[0, 0, 0, :] = sin_tab[pos]
            dec_mask.fill(np.float16(-1e4))
            dec_mask[0, 0, 0, : pos + 1] = 0.0
            wpos_buf[0] = pos
            logits = active_dec.predict(
                {
                    "inputs_embeds": dec_emb_buf,
                    "cos": dec_cos_buf,
                    "sin": dec_sin_buf,
                    "attn_mask": dec_mask,
                    "write_pos": wpos_buf,
                },
                state=active_state,
            )["logits"][0].astype(np.float32)
            assert np.isfinite(logits).all(), "Non-finite logits during prefill tail!"
            pos += 1
        t_prefill = time.perf_counter()

        # Autoregressive greedy decode
        gen_ids: list[int] = []
        for _ in range(max_new):
            next_id = int(np.argmax(logits))
            if next_id in (eos_id, im_end_id):
                break
            gen_ids.append(next_id)
            if pos >= active_kv:
                break
            dec_emb_buf[0, :, 0, 0] = (weights[next_id].astype(np.float32) * scales[next_id]).astype(np.float16)
            dec_cos_buf[0, 0, 0, :] = cos_tab[pos]
            dec_sin_buf[0, 0, 0, :] = sin_tab[pos]
            dec_mask.fill(np.float16(-1e4))
            dec_mask[0, 0, 0, : pos + 1] = 0.0
            wpos_buf[0] = pos
            logits = active_dec.predict(
                {
                    "inputs_embeds": dec_emb_buf,
                    "cos": dec_cos_buf,
                    "sin": dec_sin_buf,
                    "attn_mask": dec_mask,
                    "write_pos": wpos_buf,
                },
                state=active_state,
            )["logits"][0].astype(np.float32)
            assert np.isfinite(logits).all(), "Non-finite logits during decode!"
            pos += 1

        t_end = time.perf_counter()
        elapsed = t_end - t0
        text = tok.decode(gen_ids, skip_special_tokens=True).strip()
        segs = re.findall(r"\[(\d+(?:\.\d+)?)\]\[(S\d+)\](.*?)\[(\d+(?:\.\d+)?)\]", text, re.DOTALL)
        row = {
            "file": wav_path.name,
            "kvBucket": active_kv,
            "durationSec": round(dur, 2),
            "encodeSec": round(t_enc - t0, 3),
            "prefillSec": round(t_prefill - t_enc, 3),
            "decodeSec": round(t_end - t_prefill, 3),
            "totalSec": round(elapsed, 3),
            "rtf": round(elapsed / max(dur, 1e-3), 4),
            "rtfx": round(dur / max(elapsed, 1e-4), 1),
            "tokens": len(gen_ids),
            "segments": len(segs),
            "text": text,
        }
        print(
            f"  [{wav_path.name} kv={active_kv}] {dur:.2f}s -> {elapsed:.3f}s ({row['rtfx']}x RTFx, "
            f"enc={row['encodeSec']}s prefill={row['prefillSec']}s dec={row['decodeSec']}s, "
            f"{len(segs)} segs): {text}"
        )
        results.append(row)

    del active_state, dec_short_cm, pre_short_cm, dec_cm, pre_cm, enc_cm
    gc.collect()
    keepalive_refs.clear()
    return {"computeUnits": compute_used, "examples": results}


def export_support_assets(
    source_dir: Path,
    out_dir: Path,
    max_kv: int,
    short_kv: int,
    prefill_len: int,
    sink_layer: int,
    sink_scale: float,
) -> None:
    from transformers import WhisperFeatureExtractor

    fe = WhisperFeatureExtractor.from_pretrained(str(source_dir))
    mel_filters = np.asarray(fe.mel_filters, dtype="<f4")  # [201, 80] in HF WhisperFeatureExtractor
    if mel_filters.shape == (201, 80):
        mel_filters = mel_filters.T.copy()  # save [80, 201] row-major
    assert mel_filters.shape == (80, 201), f"Unexpected whisper mel_filters shape: {mel_filters.shape}"
    mel_path = out_dir / "whisper_mel_filters_80x201.bin"
    mel_path.write_bytes(mel_filters.astype("<f4").tobytes())

    for fname in (
        "tokenizer.json",
        "vocab.json",
        "merges.txt",
        "added_tokens.json",
        "special_tokens_map.json",
        "tokenizer_config.json",
        "processor_config.json",
        "preprocessor_config.json",
    ):
        src_f = source_dir / fname
        if src_f.is_file():
            shutil.copy2(src_f, out_dir / fname)

    tok = _load_fast_tokenizer(source_dir)
    hf_cfg = json.loads((source_dir / "config.json").read_text(encoding="utf-8"))
    proc_cfg = json.loads((source_dir / "processor_config.json").read_text(encoding="utf-8"))
    digit_ids = {d: int(tok.encode(d, add_special_tokens=False).ids[0]) for d in "0123456789"}

    before_text, after_text = _render_moss_prompt(DEFAULT_PROMPT)
    im_end_id = int(tok.token_to_id("<|im_end|>"))
    eos_id = int(tok.token_to_id("<|endoftext|>") or im_end_id)

    coreml_cfg = {
        "model": "OpenMOSS-Team/MOSS-Transcribe-Diarize",
        "sourceRevision": "e6d68cdfcddbdad1a7e8454f0cb859cad76e2502",
        "sampleRate": 16000,
        "chunkSamples": 480000,
        "audioMergeSize": AUDIO_MERGE_SIZE,
        "audioTokensPerSecond": float(proc_cfg.get("audio_tokens_per_second", 12.5)),
        "timeMarkerEverySeconds": int(proc_cfg.get("time_marker_every_seconds", 5)),
        "enableTimeMarker": bool(proc_cfg.get("enable_time_marker", True)),
        "audioTokenId": int(hf_cfg["audio_token_id"]),
        "eosTokenId": eos_id,
        "imEndTokenId": im_end_id,
        "digitTokenIds": digit_ids,
        "promptPrefixTokenIds": list(tok.encode(before_text, add_special_tokens=False).ids),
        "promptSuffixTemplate": after_text,
        "defaultPrompt": DEFAULT_PROMPT,
        "maxKvLen": max_kv,
        "shortKvLen": short_kv if (0 < short_kv < max_kv) else 0,
        "prefillLen": prefill_len,
        "hiddenSize": LLM_HIDDEN,
        "vocabSize": LLM_VOCAB,
        "headDim": LLM_HEAD_DIM,
        "ropeTheta": ROPE_THETA,
        "sinkStartLayer": sink_layer,
        "residualScale": sink_scale,
        "melFiltersFile": mel_path.name,
        "melFiltersSha256": sha256_file(mel_path),
    }
    (out_dir / "moss_coreml_config.json").write_text(
        json.dumps(coreml_cfg, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--max-kv", type=int, default=4096)
    parser.add_argument("--short-kv", type=int, default=1536, help="Optional fast short-context KV bucket (0 to disable)")
    parser.add_argument("--prefill-len", type=int, default=128)
    parser.add_argument("--encoder-quant", choices=["fp16", "int8"], default="fp16")
    parser.add_argument("--decoder-quant", choices=["int8", "lut6", "lut4"], default="int8")
    parser.add_argument("--reuse-existing", action="store_true")
    parser.add_argument("--test-wav", type=Path, nargs="*", default=[])
    args = parser.parse_args()

    torch.set_grad_enabled(False)
    src = args.source_dir.resolve()
    out = args.output_dir.resolve()
    work = out.parent / (out.name + ".work")
    out.mkdir(parents=True, exist_ok=True)
    work.mkdir(parents=True, exist_ok=True)

    t0 = time.perf_counter()
    try:
        hf_cfg = json.loads((src / "config.json").read_text(encoding="utf-8"))
        print("Loading MOSS safetensors checkpoint...")
        sd = load_hf_state_dict(src)

        audio_encoder = load_moss_audio_encoder(sd)
        sink_layer, sink_scale, max_act = probe_qwen3_activation_scale(sd, hf_cfg["text_config"], audio_encoder, src)

        enc_report = export_audio_encoder(audio_encoder, out, work, args.encoder_quant, args.reuse_existing)
        del audio_encoder
        gc.collect()

        emb_report = export_embedding_int8(sd["model.language_model.embed_tokens.weight"], out / "embedding.int8.bin")
        qwen_base = load_qwen3_into_ane_base(sd, hf_cfg["text_config"], args.max_kv, sink_layer, sink_scale)
        del sd
        gc.collect()

        dec_report = export_decoder(
            qwen_base, out, work, args.max_kv, args.short_kv, args.prefill_len, args.decoder_quant, args.reuse_existing
        )
        del qwen_base
        gc.collect()

        export_support_assets(src, out, args.max_kv, args.short_kv, args.prefill_len, sink_layer, sink_scale)

        ane_audit = audit_moss_compute_plan(out / "MOSSAudioEncoder.mlmodelc", out / "MOSSDecoder.mlmodelc")
        e2e_report = verify_end_to_end_coreml(src, out, args.max_kv, args.short_kv, args.prefill_len, list(args.test_wav))

        report = {
            "totalExportSeconds": round(time.perf_counter() - t0, 2),
            "activationProbeMaxAbs": round(max_act, 2),
            "sinkStartLayer": sink_layer,
            "residualScale": sink_scale,
            "aneComputePlan": ane_audit,
            "audioEncoder": enc_report,
            "decoder": dec_report,
            "embedding": emb_report,
            "verification": e2e_report,
        }
        (out / "export_report.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        print(
            f"SUCCESS: MOSS CoreML bundle exported in {report['totalExportSeconds']}s "
            f"(enc={enc_report['mb']} MB, dec={dec_report['mb']} MB, compute={e2e_report['computeUnits']})"
        )
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
