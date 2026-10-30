"""FireRedASR2-AED on Core ML (4-bit) with the same greedy decoding as sherpa-onnx.

Subcommands (run from the repository root; downloads and outputs stay under tmp_agent_output/):

  convert   Build Core ML models from the official PyTorch checkpoint (FireRedTeam/FireRedASR2-AED) and the
            official model code (FireRedTeam/FireRedASR2S, passed with --code). Mirrors the sherpa-onnx export:
              encoder.mlpackage   x [1, T, 80] (CMVN-normalized fbank) -> cross_k, cross_v [16, 1, T', 1280],
                                  mask [1, T'] (1 = valid encoder frame)
              decoder.mlpackage   tokens [1, L] (sos + tokens so far), cross_k, cross_v -> logits [1, 8667]
                                  for the last position. No self-attention cache: every step recomputes the
                                  whole prefix (the official decoder's cache holds layer outputs, so this is
                                  the same function).
            fp16 compute, flexible T and L, minimum deployment target macOS 15.
  compress  4-bit weights: --method linear (int4, symmetric, per block of --block-size input channels) or
            --method palettize (4-bit LUT, per grouped channel of --group-size).
  run       Decode a corpus with sherpa-onnx's greedy loop (FireRed: start from sos, argmax, stop at eos, at most
            frames/100*8 tokens capped at 512). Features match sherpa: kaldi fbank 80 bins, dither 0,
            snip_edges, int16-scale samples, CMVN from the released ONNX metadata.
            --backend onnx runs the released sherpa ONNX files through the same Python loop (to check the loop
            against sherpa itself); --backend coreml runs the .mlpackage pair.

    uv run --python 3.12 --with torch==2.7.1 --with coremltools==9.0 --with numpy==2.3.4 \
        --with kaldi-native-fbank==1.22.4 --with onnx==1.19.1 --with onnxruntime==1.28.0 --with kaldiio==2.18.1 \
        --with sentencepiece==0.2.1 --with torchaudio==2.7.1 python -I Tools/ASRCodeSwitchEval/firered_coreml.py ...
"""

import argparse
import gc
import json
import platform
import resource
import sys
import time
import wave
from pathlib import Path

import numpy as np

SOS, EOS, MAX_LEN, TOKENS_PER_SECOND = 3, 4, 1024, 8


# ----------------------------------------------------------------------------- features and tokens
def read_wav(path):
    with wave.open(str(path)) as reader:
        if (reader.getnchannels(), reader.getsampwidth(), reader.getframerate()) != (1, 2, 16000):
            raise ValueError(f"Expected 16 kHz mono PCM16: {path}")
        data = reader.readframes(reader.getnframes())
    return np.frombuffer(data, dtype="<i2").astype("float32") / 32768.0


def load_cmvn(int8_dir):
    import onnx

    meta = {p.key: p.value for p in onnx.load(str(int8_dir / "encoder.int8.onnx"), load_external_data=False).metadata_props}
    mean = np.array([float(v) for v in meta["cmvn_mean"].split(",")], dtype="float32")
    inv_std = np.array([float(v) for v in meta["cmvn_inv_stddev"].split(",")], dtype="float32")
    return mean, inv_std


def fbank(samples, mean, inv_std):
    import kaldi_native_fbank as knf

    opts = knf.FbankOptions()
    opts.frame_opts.dither = 0.0
    opts.frame_opts.snip_edges = True
    opts.frame_opts.samp_freq = 16000
    opts.mel_opts.num_bins = 80
    opts.mel_opts.high_freq = 0
    computer = knf.OnlineFbank(opts)
    computer.accept_waveform(16000, (samples * 32768.0).tolist())  # sherpa: normalize_samples = false
    computer.input_finished()
    frames = np.stack([computer.get_frame(i) for i in range(computer.num_frames_ready)]).astype("float32")
    return (frames - mean) * inv_std


def load_tokens(path):
    table = {}
    for line in Path(path).read_text().splitlines():
        if line.strip():
            symbol, index = line.rsplit(maxsplit=1)
            table[int(index)] = symbol
    return table


def detokenize(ids, table):
    return "".join(table[i] for i in ids if i in table).replace("▁", " ").strip()


# ----------------------------------------------------------------------------- torch wrappers
def build_torch_model(checkpoint, code):
    import types

    import torch

    # Import only the AED model modules: the package __init__ files pull in the LLM, VAD and punctuation stacks.
    root = Path(code) / "fireredasr2s" / "fireredasr2"
    for name, path in [("fr_aed", root), ("fr_aed.models", root / "models"),
                       ("fr_aed.models.module", root / "models" / "module")]:
        package = types.ModuleType(name)
        package.__path__ = [str(path)]
        sys.modules[name] = package
    from fr_aed.models.fireredasr_aed import FireRedAsrAed

    package = torch.load(str(checkpoint), map_location="cpu", weights_only=False, mmap=True)
    model = FireRedAsrAed.from_args(package["args"])
    missing, unexpected = model.load_state_dict(package["model_state_dict"], strict=False)
    del package
    gc.collect()
    model.eval()
    return model, dict(missing=list(missing), unexpected=list(unexpected))


def encoder_wrapper(model):
    import torch
    import torch.nn.functional as F

    def rel_shift(x):  # Same as RelPosMultiHeadAttention._rel_shift, without view_as (no coremltools converter).
        n, h, t1, t2 = x.shape
        x = F.pad(x, (1, 0)).reshape(n, h, t2 + 1, t1)
        return x[:, :, 1:].reshape(n, h, t1, t2)[:, :, :, : t2 // 2 + 1]

    for layer in model.encoder.layer_stack:
        layer.mhsa._rel_shift = rel_shift

    class Encoder(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.encoder = model.encoder
            self.cross = model.decoder.layer_stack

        def forward(self, x):
            enc = self.encoder
            length = x.shape[1]
            padded = F.pad(x, (0, 0, 0, enc.input_preprocessor.context - 1), "constant", 0.0)
            mask = (torch.arange(padded.shape[1]) < length).to(torch.uint8).view(1, 1, -1)
            out, _, mask = enc.input_preprocessor(padded, mask)
            pos_emb = enc.positional_encoding(out)
            for layer in enc.layer_stack:
                out = layer(out, pos_emb, slf_attn_mask=mask, pad_mask=mask)
            cross_k = torch.stack([layer.cross_attn.w_ks(out) for layer in self.cross])
            cross_v = torch.stack([layer.cross_attn.w_vs(out) for layer in self.cross])
            return cross_k, cross_v, mask[:, 0, :].to(torch.float32)

    return Encoder().eval()


def decoder_wrapper(model):
    import torch

    decoder = model.decoder

    class Decoder(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.decoder = decoder

        def forward(self, tokens, cross_k, cross_v):
            d = self.decoder
            length = tokens.shape[1]
            x = d.tgt_word_emb(tokens) * d.scale + d.pe_slice(length)
            causal = torch.tril(torch.ones(length, length)).view(1, 1, length, length)
            for index, layer in enumerate(d.layer_stack):
                residual = x
                h = layer.self_attn_norm(x)
                x = residual + attend(layer.self_attn, h, layer.self_attn.w_ks(h), layer.self_attn.w_vs(h), causal)
                residual = x
                h = layer.cross_attn_norm(x)
                x = residual + attend(layer.cross_attn, h, cross_k[index], cross_v[index], None)
                residual = x
                x = residual + layer.mlp(layer.mlp_norm(x))
            out = d.layer_norm_out(x[:, -1])
            return d.tgt_word_prj(out)

    def attend(mha, q_in, k, v, mask):
        n_head, d_k = mha.n_head, mha.d_k
        q = mha.w_qs(q_in).view(1, -1, n_head, d_k).transpose(1, 2)
        k = k.view(1, -1, n_head, d_k).transpose(1, 2)
        v = v.view(1, -1, n_head, d_k).transpose(1, 2)
        scores = torch.matmul(q, k.transpose(2, 3)) / mha.attention.temperature
        if mask is not None:
            scores = scores.masked_fill(mask == 0, -1e4)  # fp16-safe large negative
        out = torch.matmul(torch.softmax(scores, dim=-1), v)
        return mha.fc(out.transpose(1, 2).reshape(1, -1, mha.d_model))

    pe = decoder.positional_encoding.pe
    decoder.pe_slice = lambda length: pe[:, :length]
    return Decoder().eval()


def convert(args):
    import coremltools as ct
    import torch

    torch.set_grad_enabled(False)
    model, load_info = build_torch_model(args.checkpoint, args.code)
    model.ctc = None
    if "decoder" not in args.parts:  # The encoder wrapper only needs the decoder's cross-attention K/V projections.
        for layer in model.decoder.layer_stack:
            layer.self_attn = layer.mlp = layer.cross_attn.w_qs = layer.cross_attn.fc = None
        model.decoder.tgt_word_emb = model.decoder.tgt_word_prj = None
    if "encoder" not in args.parts:
        model.encoder = None
    gc.collect()
    args.output.mkdir(parents=True, exist_ok=True)
    info = dict(checkpoint=str(args.checkpoint.name), precision=args.precision, load=load_info, torch=torch.__version__, coremltools=ct.__version__)
    target = ct.target.macOS15
    if "encoder" in args.parts:
        wrapper = encoder_wrapper(model)
        example = torch.randn(1, 400, 80)
        traced = torch.jit.trace(wrapper, (example,), check_trace=False)
        started = time.perf_counter()
        mlmodel = ct.convert(traced, inputs=[ct.TensorType(name="x", shape=(1, ct.RangeDim(16, 3000, 400), 80), dtype=np.float32)],
                             outputs=[ct.TensorType(name="cross_k"), ct.TensorType(name="cross_v"), ct.TensorType(name="mask")],
                             compute_precision=getattr(ct.precision, args.precision.upper()), minimum_deployment_target=target,
                             convert_to="mlprogram")
        mlmodel.save(str(args.output / "encoder.mlpackage"))
        info["encoderConvertSeconds"] = time.perf_counter() - started
        del mlmodel, traced, wrapper
        gc.collect()
    if "decoder" in args.parts:
        wrapper = decoder_wrapper(model)
        tokens = torch.tensor([[SOS, 100, 200, 300]], dtype=torch.int32)
        cross = torch.randn(16, 1, 100, 1280)
        traced = torch.jit.trace(wrapper, (tokens, cross, cross), check_trace=False)
        started = time.perf_counter()
        frames = ct.RangeDim(1, 800, 100)
        mlmodel = ct.convert(traced, inputs=[ct.TensorType(name="tokens", shape=(1, ct.RangeDim(1, 512, 4)), dtype=np.int32),
                                             ct.TensorType(name="cross_k", shape=(16, 1, frames, 1280), dtype=np.float32),
                                             ct.TensorType(name="cross_v", shape=(16, 1, frames, 1280), dtype=np.float32)],
                             outputs=[ct.TensorType(name="logits")],
                             compute_precision=getattr(ct.precision, args.precision.upper()), minimum_deployment_target=target,
                             convert_to="mlprogram")
        mlmodel.save(str(args.output / "decoder.mlpackage"))
        info["decoderConvertSeconds"] = time.perf_counter() - started
    (args.output / f"convert-{'-'.join(args.parts)}.json").write_text(json.dumps(info, indent=2) + "\n")
    print(json.dumps(info, indent=2))


def check_torch(args):
    """Compare the wrappers (torch fp32) with the released int8 ONNX on one utterance (sanity check)."""
    import torch

    torch.set_grad_enabled(False)
    model, _ = build_torch_model(args.checkpoint, args.code)
    mean, inv_std = load_cmvn(args.int8)
    table = load_tokens(args.int8 / "tokens.txt")
    feats = fbank(read_wav(args.wav), mean, inv_std)
    cross_k, cross_v, mask = encoder_wrapper(model)(torch.from_numpy(feats)[None])
    valid = int(mask.sum())
    cross_k, cross_v = cross_k[:, :, :valid], cross_v[:, :, :valid]
    dec = decoder_wrapper(model)
    ids = [SOS]
    for _ in range(min(int(len(feats) / 100 * TOKENS_PER_SECOND), MAX_LEN // 2)):
        token = int(dec(torch.tensor([ids], dtype=torch.int32), cross_k, cross_v)[0].argmax())
        if token == EOS:
            break
        ids.append(token)
    print("torch wrappers:", detokenize(ids[1:], table), "| frames", len(feats), "valid", valid)


def compress(args):
    import coremltools as ct
    import coremltools.optimize.coreml as cto

    model = ct.models.MLModel(str(args.input), skip_model_load=True)
    if args.method == "linear":
        op = cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int4", granularity="per_block",
                                         block_size=args.block_size, weight_threshold=2048)
        model = cto.linear_quantize_weights(model, cto.OptimizationConfig(global_config=op))
    else:
        op = cto.OpPalettizerConfig(mode=args.palette_mode, nbits=4, granularity="per_grouped_channel",
                                    group_size=args.group_size, weight_threshold=2048,
                                    num_kmeans_workers=args.workers)
        model = cto.palettize_weights(model, cto.OptimizationConfig(global_config=op))
    model.save(str(args.output))
    print(f"saved {args.output}")


# ----------------------------------------------------------------------------- decoding
class OnnxBackend:
    """The released sherpa ONNX files (self-attention KV cache interface), driven like sherpa does."""

    def __init__(self, directory, threads):
        import onnxruntime as ort

        options = ort.SessionOptions()
        options.intra_op_num_threads = threads
        options.inter_op_num_threads = 1
        self.encoder = ort.InferenceSession(str(directory / "encoder.int8.onnx"), options, providers=["CPUExecutionProvider"])
        self.decoder = ort.InferenceSession(str(directory / "decoder.int8.onnx"), options, providers=["CPUExecutionProvider"])

    def decode(self, feats, max_tokens):
        cross_k, cross_v = self.encoder.run(None, {"x": feats[None], "x_len": np.array([len(feats)], dtype="int64")})
        cache_len = min(MAX_LEN, max_tokens + 4)
        k_cache = np.zeros((16, 1, cache_len, 20, 64), dtype="float32")
        v_cache = np.zeros_like(k_cache)
        token, offset, ids = SOS, 0, []
        for _ in range(max_tokens):
            logits, k_cache, v_cache = self.decoder.run(None, {
                "tokens": np.array([[token]], dtype="int64"), "in_n_layer_self_k_cache": k_cache,
                "in_n_layer_self_v_cache": v_cache, "n_layer_cross_k": cross_k, "n_layer_cross_v": cross_v,
                "offset": np.array([offset], dtype="int64")})
            token = int(np.argmax(logits[0, -1]))
            if token == EOS:
                break
            ids.append(token)
            offset += 1
        return ids


class CoreMLBackend:
    def __init__(self, directory, compute_units):
        import coremltools as ct

        units = getattr(ct.ComputeUnit, compute_units)
        self.encoder = ct.models.MLModel(str(directory / "encoder.mlpackage"), compute_units=units)
        self.decoder = ct.models.MLModel(str(directory / "decoder.mlpackage"), compute_units=units)

    def decode(self, feats, max_tokens):
        out = self.encoder.predict({"x": feats[None]})
        valid = int(round(float(out["mask"].sum())))
        cross_k = np.ascontiguousarray(out["cross_k"][:, :, :valid]).astype("float32")
        cross_v = np.ascontiguousarray(out["cross_v"][:, :, :valid]).astype("float32")
        ids = [SOS]
        for _ in range(max_tokens):
            logits = self.decoder.predict({"tokens": np.array([ids], dtype="int32"), "cross_k": cross_k, "cross_v": cross_v})["logits"]
            token = int(np.argmax(logits.reshape(-1)))
            if token == EOS:
                break
            ids.append(token)
        return ids[1:]


def peak_rss_bytes():
    value = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return value if sys.platform == "darwin" else value * 1024


def footprint_bytes():
    import ctypes
    import os

    class Info(ctypes.Structure):
        _fields_ = [("uuid", ctypes.c_uint8 * 16), ("values", ctypes.c_uint64 * 40)]

    info = Info()
    if ctypes.CDLL("/usr/lib/libSystem.B.dylib").proc_pid_rusage(os.getpid(), 4, ctypes.byref(info)) != 0:
        return None
    return int(info.values[28])  # ri_lifetime_max_phys_footprint


def run(args):
    if args.output.exists() and not args.resume:
        raise SystemExit(f"Output directory must not exist: {args.output}")
    items = [json.loads(line) for line in (args.corpus / "manifest.jsonl").read_text().splitlines() if line.strip()]
    if args.subsets:
        items = [item for item in items if item["subset"] in set(args.subsets.split(","))]
    if args.limit:
        items = items[:args.limit]
    hypotheses = args.output / "hypotheses.jsonl"
    done = {}
    if args.resume and hypotheses.exists():
        for line in hypotheses.read_text().splitlines():
            if line.strip():
                row = json.loads(line)
                done[row["uid"]] = row
    args.output.mkdir(parents=True, exist_ok=True)
    mean, inv_std = load_cmvn(args.int8)
    table = load_tokens(args.int8 / "tokens.txt")
    rss_before = peak_rss_bytes()
    started = time.perf_counter()
    backend = OnnxBackend(args.int8, args.threads) if args.backend == "onnx" else CoreMLBackend(args.models, args.compute_units)
    load_seconds = time.perf_counter() - started

    def decode(samples):
        feats = fbank(samples, mean, inv_std)
        max_tokens = max(0, min(int(len(feats) / 100.0 * TOKENS_PER_SECOND), MAX_LEN // 2))
        return detokenize(backend.decode(feats, max_tokens), table)

    started = time.perf_counter()
    decode(read_wav(args.corpus / items[0]["audio"]))
    warmup = time.perf_counter() - started
    seconds = {item["uid"]: item["seconds"] for item in items}
    total_audio = sum(seconds[u] for u in done if u in seconds)
    total_decode = sum(r["decodeSeconds"] for u, r in done.items() if u in seconds)
    errors = sum(r["status"] != "completed" for u, r in done.items() if u in seconds)
    with open(hypotheses, "a") as handle:
        for index, item in enumerate(items):
            if item["uid"] in done:
                continue
            samples = read_wav(args.corpus / item["audio"])
            row = dict(uid=item["uid"], subset=item["subset"])
            started = time.perf_counter()
            try:
                row.update(status="completed", text=decode(samples), lang="")
            except Exception as error:
                errors += 1
                row.update(status="error", text="", error=repr(error))
            row["decodeSeconds"] = time.perf_counter() - started
            total_decode += row["decodeSeconds"]
            total_audio += item["seconds"]
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
            handle.flush()
            if index % 100 == 0:
                print(f"{index}/{len(items)} rtf={total_decode / total_audio:.3f}", file=sys.stderr, flush=True)
    model_dir = args.int8 if args.backend == "onnx" else args.models
    size = sum(p.stat().st_size for p in model_dir.rglob("*") if p.is_file() and (
        args.backend == "coreml" and ".mlpackage" in str(p) or p.suffix == ".onnx" or p.name == "tokens.txt"))
    summary = dict(model=args.name, settings=dict(backend=args.backend, computeUnits=args.compute_units,
                                                  decoding="greedy (sherpa-onnx FireRed loop)", maxTokensPerSecond=8,
                                                  threads=args.threads if args.backend == "onnx" else None),
                   python=platform.python_version(), platform=platform.platform(), utterances=len(items),
                   resumedUtterances=len(done), subsets=sorted((args.subsets or "").split(",")), errors=errors,
                   audioSeconds=total_audio, decodeSeconds=total_decode, rtf=total_decode / total_audio,
                   loadSeconds=load_seconds, warmupSeconds=warmup, peakRSSBytesBeforeLoad=rss_before,
                   peakRSSBytes=peak_rss_bytes(), lifetimeMaxPhysFootprintBytes=footprint_bytes(),
                   modelBytesOnDisk=size)
    (args.output / "run.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({k: summary[k] for k in ["model", "utterances", "errors", "rtf", "loadSeconds", "peakRSSBytes",
                                              "lifetimeMaxPhysFootprintBytes", "modelBytesOnDisk"]}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("convert")
    p.add_argument("--checkpoint", type=Path, required=True)
    p.add_argument("--code", type=Path, required=True, help="FireRedASR2S checkout (official model code)")
    p.add_argument("--parts", nargs="+", default=["encoder", "decoder"], choices=["encoder", "decoder"])
    p.add_argument("--precision", choices=["float16", "float32"], default="float16", help="Core ML compute precision")
    p.add_argument("--output", type=Path, required=True)
    p = sub.add_parser("check-torch")
    p.add_argument("--checkpoint", type=Path, required=True)
    p.add_argument("--code", type=Path, required=True)
    p.add_argument("--int8", type=Path, required=True)
    p.add_argument("--wav", type=Path, required=True)
    p = sub.add_parser("compress")
    p.add_argument("--input", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--method", choices=["linear", "palettize"], default="linear")
    p.add_argument("--block-size", type=int, default=32)
    p.add_argument("--group-size", type=int, default=16)
    p.add_argument("--palette-mode", choices=["kmeans", "uniform"], default="uniform",
                   help="uniform is fast but destroys accuracy here; kmeans needs --workers")
    p.add_argument("--workers", type=int, default=8, help="k-means worker processes")
    p = sub.add_parser("run")
    p.add_argument("--backend", choices=["onnx", "coreml"], required=True)
    p.add_argument("--int8", type=Path, required=True, help="Released int8 sherpa dir (tokens, CMVN, ONNX backend)")
    p.add_argument("--models", type=Path, help="Directory with encoder.mlpackage and decoder.mlpackage")
    p.add_argument("--compute-units", default="ALL", choices=["ALL", "CPU_AND_GPU", "CPU_AND_NE", "CPU_ONLY"])
    p.add_argument("--threads", type=int, default=2)
    p.add_argument("--name", required=True)
    p.add_argument("--corpus", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--subsets")
    p.add_argument("--limit", type=int)
    p.add_argument("--resume", action="store_true")
    args = parser.parse_args()
    {"convert": convert, "check-torch": check_torch, "compress": compress, "run": run}[args.command](args)


if __name__ == "__main__":
    main()
