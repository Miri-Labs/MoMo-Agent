"""Run the official Qwen3-ASR inference package (qwen-asr, transformers backend) on a corpus.

Writes the run format that score.py consumes (hypotheses.jsonl + run.json), resumable with --resume.
Language is left to the model (auto); no context prompt, transcription only, greedy decoding.

    uv run --python 3.12 --with qwen-asr==0.0.6 --with torch==2.9.1 python -I \
        Tools/ASRCodeSwitchEval/qwen3_asr_hf.py --model DIR --device mps \
        --corpus tmp_agent_output/asr-code-switching-eval/corpus-ascend-v1 --output NEW_DIR [--subsets a,b] [--resume]

Besides the package's text (after its built-in `detect_and_fix_repetitions`), each row keeps the raw
generated string (`raw`) so runaway output can be inspected before that fix.
"""

import argparse
import ctypes
import json
import platform
import resource
import sys
import time
import wave
from pathlib import Path


def read_wav(path):
    import numpy as np

    with wave.open(str(path)) as reader:
        if (reader.getnchannels(), reader.getsampwidth(), reader.getframerate()) != (1, 2, 16000):
            raise ValueError(f"Expected 16 kHz mono PCM16: {path}")
        data = reader.readframes(reader.getnframes())
    return np.frombuffer(data, dtype="<i2").astype("float32") / 32768.0


class RusageInfoV4(ctypes.Structure):
    # <sys/resource.h> rusage_info_v4: 16-byte uuid followed by uint64 fields; index 7 is ri_phys_footprint,
    # index 28 is ri_lifetime_max_phys_footprint.
    _fields_ = [("uuid", ctypes.c_uint8 * 16), ("values", ctypes.c_uint64 * 40)]


def footprint_bytes():
    """(current, lifetime max) physical footprint on macOS; includes Metal/MPS allocations."""
    if sys.platform != "darwin":
        return None, None
    info = RusageInfoV4()
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    import os

    if libc.proc_pid_rusage(os.getpid(), 4, ctypes.byref(info)) != 0:
        return None, None
    return int(info.values[7]), int(info.values[28])


def peak_rss_bytes():
    value = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return value if sys.platform == "darwin" else value * 1024


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", type=Path, required=True, help="Local Qwen/Qwen3-ASR-* snapshot")
    parser.add_argument("--name", default="qwen3-asr-1.7b-hf")
    parser.add_argument("--device", default="mps", choices=["mps", "cpu"])
    parser.add_argument("--dtype", default="bfloat16", choices=["bfloat16", "float16", "float32"])
    parser.add_argument("--max-new-tokens", type=int, default=512)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--subsets")
    parser.add_argument("--limit", type=int, help="Only the first N utterances (pilot)")
    parser.add_argument("--resume", action="store_true")
    args = parser.parse_args()

    import torch
    import qwen_asr
    from qwen_asr.inference import qwen3_asr as qwen_module

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

    # Keep the raw generation next to the package's parsed text.
    raw_outputs = []
    original_parse = qwen_module.parse_asr_output

    def parse_and_keep(raw, user_language=None):
        raw_outputs.append(raw)
        return original_parse(raw, user_language=user_language)

    qwen_module.parse_asr_output = parse_and_keep

    rss_before_load = peak_rss_bytes()
    started = time.perf_counter()
    dtype = getattr(torch, args.dtype)
    model = qwen_asr.Qwen3ASRModel.from_pretrained(str(args.model), dtype=dtype, device_map=args.device,
                                                   max_inference_batch_size=1, max_new_tokens=args.max_new_tokens)
    generation = model.model.generation_config
    load_seconds = time.perf_counter() - started

    def decode(samples):
        raw_outputs.clear()
        (result,) = model.transcribe(audio=(samples, 16000), language=None)
        if args.device == "mps":
            torch.mps.synchronize()
        return result, list(raw_outputs)

    started = time.perf_counter()
    decode(read_wav(args.corpus / items[0]["audio"]))
    warmup_seconds = time.perf_counter() - started
    seconds = {item["uid"]: item["seconds"] for item in items}
    total_audio = sum(seconds[uid] for uid in done if uid in seconds)
    total_decode = sum(row["decodeSeconds"] for uid, row in done.items() if uid in seconds)
    errors = sum(row["status"] != "completed" for uid, row in done.items() if uid in seconds)
    with open(hypotheses, "a") as handle:
        for index, item in enumerate(items):
            if item["uid"] in done:
                continue
            samples = read_wav(args.corpus / item["audio"])
            row = dict(uid=item["uid"], subset=item["subset"])
            started = time.perf_counter()
            try:
                result, raw = decode(samples)
                row.update(status="completed", text=result.text, lang=result.language, raw=raw)
            except Exception as error:  # Keep going; failures are scored as empty hypotheses.
                errors += 1
                row.update(status="error", text="", error=repr(error))
            row["decodeSeconds"] = time.perf_counter() - started
            total_decode += row["decodeSeconds"]
            total_audio += item["seconds"]
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
            handle.flush()
            if index % 100 == 0:
                print(f"{index}/{len(items)} rtf={total_decode / total_audio:.3f}", file=sys.stderr, flush=True)
    size = sum(path.stat().st_size for path in args.model.rglob("*") if path.is_file() and ".cache" not in path.parts)
    footprint, max_footprint = footprint_bytes()
    summary = dict(model=args.name, settings=dict(language="auto (None)", context="", backend="transformers",
                                                  device=args.device, dtype=args.dtype,
                                                  max_new_tokens=args.max_new_tokens, batch=1,
                                                  do_sample=bool(getattr(generation, "do_sample", False)),
                                                  num_beams=getattr(generation, "num_beams", 1)),
                   qwenAsr=getattr(qwen_asr, "__version__", "0.0.6"), torch=torch.__version__,
                   python=platform.python_version(), machine=platform.machine(), platform=platform.platform(),
                   utterances=len(items), resumedUtterances=len(done), subsets=sorted((args.subsets or "").split(",")),
                   errors=errors, audioSeconds=total_audio, decodeSeconds=total_decode,
                   rtf=total_decode / total_audio, loadSeconds=load_seconds, warmupSeconds=warmup_seconds,
                   peakRSSBytesBeforeLoad=rss_before_load, peakRSSBytes=peak_rss_bytes(),
                   physFootprintBytes=footprint, lifetimeMaxPhysFootprintBytes=max_footprint,
                   mpsDriverAllocatedBytes=(torch.mps.driver_allocated_memory() if args.device == "mps" else None),
                   modelBytesOnDisk=size)
    (args.output / "run.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({k: summary[k] for k in ["model", "utterances", "errors", "rtf", "loadSeconds", "peakRSSBytes",
                                              "lifetimeMaxPhysFootprintBytes", "modelBytesOnDisk"]}, indent=2))


if __name__ == "__main__":
    main()
