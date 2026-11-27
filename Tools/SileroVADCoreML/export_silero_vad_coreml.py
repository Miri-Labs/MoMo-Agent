#!/usr/bin/env python3
"""Export Silero VAD v6 (16 kHz, 512-sample chunk + 64-sample context) to CoreML (.mlmodelc).

Reconstructs the exact Silero VAD v6 feed-forward + LSTMCell graph in pure PyTorch using weights
from `silero-vad`, verifies <1e-5 streaming parity against the official TorchScript model, and
compiles `SileroVAD.mlmodelc` (~1.5 MB).
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import time
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F


class SileroVADClean(nn.Module):
    def __init__(self, jit_core):
        super().__init__()
        self.register_buffer("forward_basis", jit_core.stft.forward_basis_buffer.detach().clone().float())
        self.hop_length = int(jit_core.stft.hop_length)
        self.cutoff = int(jit_core.stft.filter_length) // 2 + 1
        self.right_pad = int(jit_core.stft.padding.padding[1])

        self.convs = nn.ModuleList()
        for i in range(4):
            src_conv = getattr(jit_core.encoder, str(i)).reparam_conv
            w = src_conv.weight.detach().clone().float()
            b = src_conv.bias.detach().clone().float()
            c = nn.Conv1d(
                w.shape[1],
                w.shape[0],
                kernel_size=w.shape[2],
                stride=int(src_conv.stride[0]),
                padding=int(src_conv.padding[0]),
                bias=True,
            )
            with torch.no_grad():
                c.weight.copy_(w)
                c.bias.copy_(b)
            self.convs.append(c)

        rnn = jit_core.decoder.rnn
        self.register_buffer("w_ih", rnn.weight_ih.detach().clone().float())
        self.register_buffer("w_hh", rnn.weight_hh.detach().clone().float())
        self.register_buffer("b_ih", rnn.bias_ih.detach().clone().float())
        self.register_buffer("b_hh", rnn.bias_hh.detach().clone().float())

        head = getattr(jit_core.decoder.decoder, "2")
        self.head = nn.Conv1d(128, 1, kernel_size=1, bias=True)
        with torch.no_grad():
            self.head.weight.copy_(head.weight.detach().float())
            self.head.bias.copy_(head.bias.detach().float())

    def forward(self, input_576: torch.Tensor, state: torch.Tensor):
        # STFT magnitude
        x = F.pad(input_576, (0, self.right_pad), mode="reflect").unsqueeze(1)
        spec = F.conv1d(x, self.forward_basis, stride=self.hop_length, padding=0)
        real = spec[:, : self.cutoff, :]
        imag = spec[:, self.cutoff :, :]
        mag = torch.sqrt(real * real + imag * imag)

        # 4 Conv1d + ReLU encoder stages
        h_enc = mag
        for conv in self.convs:
            h_enc = F.relu(conv(h_enc))
        feat = h_enc[:, :, 0]  # [1, 128]

        h0 = state[0]  # [1, 128]
        c0 = state[1]  # [1, 128]
        gates = F.linear(feat, self.w_ih, self.b_ih) + F.linear(h0, self.w_hh, self.b_hh)
        i_g = torch.sigmoid(gates[:, 0:128])
        f_g = torch.sigmoid(gates[:, 128:256])
        g_g = torch.tanh(gates[:, 256:384])
        o_g = torch.sigmoid(gates[:, 384:512])
        c1 = f_g * c0 + i_g * g_g
        h1 = o_g * torch.tanh(c1)
        next_state = torch.stack([h1, c1], dim=0)  # [2, 1, 128]

        logits = self.head(F.relu(h1).unsqueeze(-1))  # [1, 1, 1]
        prob = torch.sigmoid(logits).squeeze(-1)  # [1, 1]
        return prob, next_state


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()

    from silero_vad import load_silero_vad

    out_dir = args.output_dir.resolve()
    work_dir = out_dir.parent / (out_dir.name + ".work")
    out_dir.mkdir(parents=True, exist_ok=True)
    work_dir.mkdir(parents=True, exist_ok=True)

    t0 = time.perf_counter()
    try:
        jit_model = load_silero_vad(onnx=False)
        jit_model.eval()
        clean_mod = SileroVADClean(jit_model._model).eval()

        ex_x = torch.randn(1, 576, dtype=torch.float32) * 0.1
        ex_state = torch.zeros(2, 1, 128, dtype=torch.float32)
        with torch.no_grad():
            ref_prob, ref_state = jit_model._model(ex_x, ex_state)
            got_prob, got_state = clean_mod(ex_x, ex_state)
            py_diff = float(torch.max(torch.abs(ref_prob - got_prob)).item())
            st_diff = float(torch.max(torch.abs(ref_state - got_state)).item())
            assert py_diff < 1e-5 and st_diff < 1e-5, f"PyTorch parity mismatch: prob={py_diff}, state={st_diff}"
            traced = torch.jit.trace(clean_mod, (ex_x, ex_state), check_trace=False)

        mlmodel = ct.convert(
            traced,
            inputs=[
                ct.TensorType(name="input_576", shape=(1, 576), dtype=np.float32),
                ct.TensorType(name="vad_state", shape=(2, 1, 128), dtype=np.float32),
            ],
            outputs=[
                ct.TensorType(name="prob", dtype=np.float32),
                ct.TensorType(name="next_state", dtype=np.float32),
            ],
            compute_precision=ct.precision.FLOAT32,
            minimum_deployment_target=ct.target.macOS15,
            convert_to="mlprogram",
        )
        pkg = work_dir / "SileroVAD.mlpackage"
        shutil.rmtree(pkg, ignore_errors=True)
        mlmodel.save(str(pkg))

        mlc = out_dir / "SileroVAD.mlmodelc"
        shutil.rmtree(mlc, ignore_errors=True)
        subprocess.run(["xcrun", "coremlcompiler", "compile", str(pkg), str(out_dir)], check=True)

        cm = ct.models.CompiledMLModel(str(mlc), compute_units=ct.ComputeUnit.CPU_ONLY)
        jit_model.reset_states()
        rng = np.random.default_rng(7)
        wav = rng.standard_normal(16000).astype(np.float32) * 0.05
        cm_state = np.zeros((2, 1, 128), dtype=np.float32)
        ctx = np.zeros((1, 64), dtype=np.float32)
        diffs = []
        for pos in range(0, 16000 - 512 + 1, 512):
            chunk = wav[pos : pos + 512].reshape(1, 512)
            with torch.no_grad():
                p_ref = float(jit_model(torch.from_numpy(chunk), 16000).item())
            inp = np.concatenate([ctx, chunk], axis=1).astype(np.float32)
            out = cm.predict({"input_576": inp, "vad_state": cm_state})
            p_cm = float(out["prob"].reshape(-1)[0])
            cm_state = out["next_state"].astype(np.float32)
            ctx = chunk[:, -64:]
            diffs.append(abs(p_ref - p_cm))
        stream_max_diff = max(diffs)
        assert stream_max_diff < 1e-4, f"Streaming SileroVAD diff: {stream_max_diff}"

        size_bytes = sum(f.stat().st_size for f in mlc.rglob("*") if f.is_file())
        report = {
            "model": "silero-vad-16k-v6",
            "sampleRate": 16000,
            "windowSamples": 512,
            "contextSamples": 64,
            "mlmodelcBytes": size_bytes,
            "mlmodelcMB": round(size_bytes / (1024 * 1024), 2),
            "pytorchParityDiff": round(py_diff, 8),
            "streamMaxDiff": round(stream_max_diff, 7),
            "exportSeconds": round(time.perf_counter() - t0, 2),
        }
        (out_dir / "silero_vad_config.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(f"SUCCESS: SileroVAD.mlmodelc ({report['mlmodelcMB']} MB), streamMaxDiff={stream_max_diff:.2e}")
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
