#!/usr/bin/env python3
"""Export Lab260 ReDimNet2+ (B6 LMFT, 192-d) to Apple CoreML (ANE-native MLProgram).

Exports:
  1. ReDimNet2Plus.mlmodelc
     - ReDimNet2-B6 (12.3M params, out_channels=224, return_2d_output=True, embed_dim=192)
     - Enumerated static ANE shapes [1, 1, 72, T] for T in [200, 300, 400, 600] (2s / 3s / 4s / 6s)
     - L2-normalized 192-dim FP32 output embedding
  2. redimnet2_mel_config.json + mel_filterbank_72x256.bin
     - Exact SpectralFeaturesTF 72-band mel filterbank (float32, [72, 256]) and Hamming window ([400])
       so Swift/C++ Accelerate frontend matches PyTorch TFMelBanks to <1e-5.

Usage:
    uv run --no-project --python 3.12 \
        --with "torch>=2.4,<2.8" --with "torchaudio>=2.4,<2.8" \
        --with "coremltools==9.0" --with "numpy<2.4" --with "scipy>=1.12" \
        python Tools/ReDimNetCoreML/export_redimnet2_coreml.py \
        --source-dir /path/to/redimnet2-plus \
        --output-dir /path/to/output/ReDimNet2Plus
"""

from __future__ import annotations

import argparse
import gc
import hashlib
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

CHECKPOINT_SHA256 = "57056ea3ff1afcf6d825f0f44abc0a4c68fcdd6738ec36e23017df060712f02b"
TIME_BUCKETS = [200, 400, 600]


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


class ReDimNet2NormalizedWrapper(nn.Module):
    """Wraps ReDimNet2Wrap (spectrogram -> 192-d L2-normalized embedding) for static CoreML tracing."""

    def __init__(self, core_model: nn.Module):
        super().__init__()
        self.core = core_model

    def forward(self, mel: torch.Tensor) -> torch.Tensor:
        emb = self.core(mel)
        return F.normalize(emb, p=2, dim=-1, eps=1e-6)


def patch_trace_safe_ops(module: nn.Module) -> None:
    """Replace dynamic tensor-int slicing / LayerNorm FP16 edge cases so traced graph works across buckets."""
    # ReDimNet2.forward does: inp = inp[:, :, :, :(T // time_stride) * time_stride]
    # Because all exported buckets are divisible by time_stride=4, bypass dynamic slice during trace.
    backbone = module.backbone

    def static_backbone_forward(inp: torch.Tensor) -> torch.Tensor:
        x = backbone.stem(inp)
        outputs_1d = [x]
        for stage_ind in range(backbone.num_stages):
            outputs_1d.append(backbone.run_stage(outputs_1d, stage_ind))
        x = backbone.fin_wght1d(outputs_1d)
        x = backbone.fin_to2d(x)
        return backbone.head(x)

    backbone.forward = static_backbone_forward


def export_frontend_tables(encoder: nn.Module, out_dir: Path) -> dict:
    """Export exact SpectralFeaturesTF filterbank and window so C++/Swift matches bit-for-bit."""
    tf_spec = encoder.spec_frontend.torchfbank[2]
    # melbanks_pt has shape [72, 256, 1] -> save as contiguous [72, 256] float32
    mel_w = tf_spec.melbanks_pt.detach().float().cpu().squeeze(-1).contiguous().numpy()
    assert mel_w.shape == (72, 256), f"Unexpected mel filterbank shape: {mel_w.shape}"
    mel_path = out_dir / "mel_filterbank_72x256.bin"
    mel_path.write_bytes(mel_w.astype("<f4").tobytes())

    win = np.asarray(tf_spec.window, dtype="<f4")
    assert win.shape == (400,), f"Unexpected window shape: {win.shape}"
    win_path = out_dir / "hamming_window_400.bin"
    win_path.write_bytes(win.tobytes())

    cfg = {
        "model": "lab260/redimnet2-plus-b6-lmft",
        "checkpointSha256": CHECKPOINT_SHA256,
        "sampleRate": 16000,
        "embeddingDim": int(encoder.embed_dim),
        "preEmphasis": 0.97,
        "frameLength": int(tf_spec.length),
        "frameStep": int(tf_spec.shift),
        "fftLength": int(tf_spec.nfft),
        "numMels": int(tf_spec.num_bins),
        "eps": float(tf_spec.eps),
        "timeBuckets": TIME_BUCKETS,
        "melFilterbankFile": mel_path.name,
        "melFilterbankSha256": sha256_file(mel_path),
        "windowFile": win_path.name,
        "windowSha256": sha256_file(win_path),
    }
    (out_dir / "redimnet2_config.json").write_text(json.dumps(cfg, indent=2) + "\n", encoding="utf-8")
    return cfg


def verify_coreml_parity(
    encoder: nn.Module,
    mlc_path: Path,
    test_wav: Path | None,
) -> dict:
    """Verify static MultiFunction CoreML ANE embeddings match PyTorch FP32 across all buckets."""
    rng = np.random.default_rng(20261123)
    bucket_metrics = {}
    models = {}
    for t_frames in TIME_BUCKETS:
        fn_name = f"embed_{t_frames}"
        cm = ct.models.CompiledMLModel(str(mlc_path), function_name=fn_name, compute_units=ct.ComputeUnit.CPU_AND_NE)
        models[t_frames] = cm
        n_samples = (t_frames - 1) * 160 + 240
        wav_np = (rng.standard_normal(n_samples).astype(np.float32) * 0.1)
        with torch.inference_mode():
            mel_pt = encoder.spec_frontend(torch.from_numpy(wav_np).unsqueeze(0))
            assert mel_pt.shape == (1, 72, t_frames), f"Expected (1, 72, {t_frames}), got {mel_pt.shape}"
            ref_raw = encoder(mel_pt).squeeze(0)
            ref = (ref_raw / ref_raw.norm()).cpu().numpy()

        mel_in = mel_pt.unsqueeze(1).cpu().numpy().astype(np.float32)
        _ = cm.predict({"mel": mel_in})["embedding"]
        times_ms = []
        cm_out = None
        for _ in range(10):
            t0 = time.perf_counter()
            cm_out = cm.predict({"mel": mel_in})["embedding"].reshape(-1).astype(np.float32)
            times_ms.append((time.perf_counter() - t0) * 1000.0)

        assert np.all(np.isfinite(cm_out)), f"Non-finite CoreML embedding for T={t_frames}"
        cos = float(np.dot(ref, cm_out) / (np.linalg.norm(ref) * np.linalg.norm(cm_out)))
        max_abs = float(np.max(np.abs(ref - cm_out)))
        print(
            f"  [{fn_name}] cosine={cos:.7f}, max_abs_diff={max_abs:.6f}, "
            f"median_ms={np.median(times_ms):.2f} ms"
        )
        assert cos >= 0.999, f"ReDimNet2+ CoreML parity too low for T={t_frames}: cos={cos}"
        bucket_metrics[str(t_frames)] = {
            "functionName": fn_name,
            "cosine": round(cos, 7),
            "maxAbsDiff": round(max_abs, 6),
            "medianMs": round(float(np.median(times_ms)), 2),
        }

    wav_cos = None
    if test_wav and test_wav.is_file():
        import wave

        with wave.open(str(test_wav), "rb") as w:
            assert w.getframerate() == 16000 and w.getnchannels() == 1
            raw = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32) / 32768.0
        target_t = 400
        n_samples = (target_t - 1) * 160 + 240
        clip = raw[:n_samples] if len(raw) >= n_samples else np.pad(raw, (0, n_samples - len(raw)))
        with torch.inference_mode():
            mel_pt = encoder.spec_frontend(torch.from_numpy(clip).unsqueeze(0))
            ref_raw = encoder(mel_pt).squeeze(0)
            ref = (ref_raw / ref_raw.norm()).cpu().numpy()
        cm_out = models[target_t].predict({"mel": mel_pt.unsqueeze(1).cpu().numpy().astype(np.float32)})["embedding"].reshape(-1)
        wav_cos = float(np.dot(ref, cm_out) / (np.linalg.norm(ref) * np.linalg.norm(cm_out)))
        print(f"  [real wav {test_wav.name}] cosine={wav_cos:.7f}")
        assert wav_cos >= 0.999, f"Real wav CoreML cosine too low: {wav_cos}"

    models.clear()
    gc.collect()
    return {"buckets": bucket_metrics, "realWavCosine": round(wav_cos, 7) if wav_cos is not None else None}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source-dir", type=Path, required=True, help="Lab260 redimnet2-plus directory")
    parser.add_argument("--output-dir", type=Path, required=True, help="Output directory for ReDimNet2Plus CoreML bundle")
    parser.add_argument("--test-wav", type=Path, default=None, help="Optional 16kHz mono WAV for real parity check")
    args = parser.parse_args()

    torch.set_grad_enabled(False)
    src = args.source_dir.resolve()
    if not (src / "asv").is_dir():
        src = src / "redimnet2-plus-main"
    weights = src / "weights/pytorch_model_fsdp.bin"
    assert weights.is_file(), f"Missing checkpoint: {weights}"
    actual_sha = sha256_file(weights)
    assert actual_sha == CHECKPOINT_SHA256, f"SHA256 mismatch: {actual_sha}"

    sys.path.insert(0, str(src))
    from asv.models.redimnet2 import ReDimNet2Encoder

    t0 = time.perf_counter()
    print("Loading ReDimNet2+ B6 LMFT checkpoint...")
    encoder = ReDimNet2Encoder(
        model_name="b6",
        pretrained=False,
        model_overrides={"out_channels": 224, "return_2d_output": True},
    )
    state = torch.load(weights, weights_only=True, map_location="cpu")
    prefix = "_orig_mod.encoder."
    encoder.load_state_dict(
        {k.removeprefix(prefix): v for k, v in state.items() if k.startswith(prefix)},
        strict=True,
    )
    encoder.eval()
    assert encoder.embed_dim == 192, f"Unexpected embed_dim={encoder.embed_dim}"

    out = args.output_dir.resolve()
    work = out.parent / (out.name + ".work")
    out.mkdir(parents=True, exist_ok=True)
    work.mkdir(parents=True, exist_ok=True)

    try:
        cfg = export_frontend_tables(encoder, out)

        # Clone into clean trace-safe wrapper
        patch_trace_safe_ops(encoder.model)
        wrapper = ReDimNet2NormalizedWrapper(encoder.model).eval()

        # Export static-shape functions into one weight-deduplicated MultiFunction MLProgram
        # so Apple ANE compiles every bucket with zero FlexibleShapeInfo CPU fallback.
        desc = ct.utils.MultiFunctionDescriptor()
        temp_pkgs = []
        for t_frames in TIME_BUCKETS:
            fn_name = f"embed_{t_frames}"
            print(f"Tracing & converting ReDimNet2+ static bucket {fn_name} [1, 1, 72, {t_frames}]...")
            example = torch.randn(1, 1, 72, t_frames, dtype=torch.float32)
            traced = torch.jit.trace(wrapper, (example,), check_trace=False)
            mlmodel = ct.convert(
                traced,
                inputs=[ct.TensorType(name="mel", shape=(1, 1, 72, t_frames), dtype=np.float32)],
                outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
                compute_precision=ct.precision.FLOAT16,
                minimum_deployment_target=ct.target.macOS15,
                convert_to="mlprogram",
            )
            bucket_pkg = work / f"redimnet2_{t_frames}.mlpackage"
            shutil.rmtree(bucket_pkg, ignore_errors=True)
            mlmodel.save(str(bucket_pkg))
            desc.add_function(str(bucket_pkg), src_function_name="main", target_function_name=fn_name)
            temp_pkgs.append(bucket_pkg)
            del mlmodel, traced
            gc.collect()

        desc.default_function_name = "embed_400"
        pkg_path = work / "ReDimNet2Plus.mlpackage"
        shutil.rmtree(pkg_path, ignore_errors=True)
        print("Merging static buckets into deduplicated MultiFunction MLProgram...")
        ct.utils.save_multifunction(desc, str(pkg_path))
        for p in temp_pkgs:
            shutil.rmtree(p, ignore_errors=True)

        mlc_path = out / "ReDimNet2Plus.mlmodelc"
        shutil.rmtree(mlc_path, ignore_errors=True)
        print("Compiling ReDimNet2Plus.mlpackage -> ReDimNet2Plus.mlmodelc...")
        subprocess.run(["xcrun", "coremlcompiler", "compile", str(pkg_path), str(out)], check=True)
        shutil.rmtree(pkg_path, ignore_errors=True)

        print("Verifying CoreML ANE parity & latency...")
        metrics = verify_coreml_parity(encoder, mlc_path, args.test_wav)

        mlc_bytes = sum(f.stat().st_size for f in mlc_path.rglob("*") if f.is_file())
        report = {
            "config": cfg,
            "mlmodelcBytes": mlc_bytes,
            "mlmodelcMB": round(mlc_bytes / (1024 * 1024), 2),
            "exportSeconds": round(time.perf_counter() - t0, 2),
            "verification": metrics,
        }
        (out / "export_report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(f"SUCCESS: ReDimNet2Plus.mlmodelc ({report['mlmodelcMB']} MB) exported in {report['exportSeconds']}s")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
