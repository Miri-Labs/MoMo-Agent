"""Run FireRedASR2-LLM (official FireRedTeam code and weights) on a corpus and write the score.py run format.

Works on a CUDA server (recommended) and, for a short pilot, on Apple Silicon (MPS). The corpus is read
from paths only (CORPUS/manifest.jsonl + the WAVs it lists); this script contains no corpus content.

Inputs
  --model-dir  FireRedTeam/FireRedASR2-LLM @ 2c5e0f415b9afb8f67cb8b00ea4c54959f70e824 (18.9 GB:
               Qwen2-7B-Instruct/, model.pth.tar, asr_encoder.pth.tar, cmvn.ark, ...)
  --code       FireRedTeam/FireRedASR2S checkout @ 4e7d9aaf4482a47cec1724807026b9b151926eb5

Decoding defaults follow the official LLM example (examples_infer/asr/inference_asr_llm.sh): batch 1,
beam 3, repetition_penalty 3.0, length_penalty 1.0, temperature 1.0, decode_max_len 0 (= number of speech
frames after the adapter), decode_min_len 0. The transcription path is the official FireRedAsr2.transcribe
LLM branch (feature extractor, prompt "<speech>请转写音频为文字", model.transcribe, batch_decode, lowercase).

--dtype float32 reproduces the official default (checkpoint args use_fp16=0; ~34 GB of accelerator memory);
--dtype bfloat16 equals the official use_half=True (~18 GB). On MPS the LLM is loaded straight to the device
in bf16 so the 7B model is never materialized in fp32.

Server example (one GPU with >= 24 GB for bf16, >= 40 GB for fp32):
    git clone https://github.com/FireRedTeam/FireRedASR2S && git -C FireRedASR2S checkout 4e7d9aaf4482a47cec1724807026b9b151926eb5
    huggingface-cli download FireRedTeam/FireRedASR2-LLM --revision 2c5e0f415b9afb8f67cb8b00ea4c54959f70e824 --local-dir FireRedASR2-LLM
    uv run --python 3.12 --with torch==2.7.1 --with torchaudio==2.7.1 --with transformers==4.51.3 \
        --with peft==0.15.2 --with kaldi-native-fbank==1.22.4 --with kaldiio==2.18.1 --with numpy==2.3.4 \
        --with sentencepiece==0.2.1 --with accelerate==1.12.0 python -I firered_llm.py \
        --model-dir FireRedASR2-LLM --code FireRedASR2S --device cuda --dtype bfloat16 \
        --corpus corpus-csd-eval-v1 --subsets csd-test-mixed,csd-test-zh,csd-test-en,csd-dev-mixed \
        --output runs-csd/fireredasr2-llm --resume
"""

import argparse
import json
import platform
import resource
import sys
import time
import types
from pathlib import Path


def import_official(code):
    """Import only the FireRedASR2 ASR modules (the package __init__ files also load VAD/LID/punctuation)."""
    root = Path(code) / "fireredasr2s" / "fireredasr2"
    for name, path in [("fr2", root), ("fr2.models", root / "models"), ("fr2.models.module", root / "models" / "module"),
                       ("fr2.tokenizer", root / "tokenizer"), ("fr2.data", root / "data")]:
        package = types.ModuleType(name)
        package.__path__ = [str(path)]
        sys.modules[name] = package
    import fr2.models.fireredasr_llm as llm_module
    from fr2.data.asr_feat import ASRFeatExtractor
    from fr2.tokenizer.llm_tokenizer import LlmTokenizerWrapper

    return llm_module, ASRFeatExtractor, LlmTokenizerWrapper


def load(args):
    import torch

    llm_module, ASRFeatExtractor, LlmTokenizerWrapper = import_official(args.code)
    dtype = getattr(torch, args.dtype)
    original = llm_module.AutoModelForCausalLM

    class LlmLoader:  # Load Qwen2-7B in the requested dtype, directly onto the device.
        @staticmethod
        def from_pretrained(path, **kwargs):
            kwargs["torch_dtype"] = dtype
            kwargs["device_map"] = args.device
            kwargs["low_cpu_mem_usage"] = True
            return original.from_pretrained(path, **kwargs)

    llm_module.AutoModelForCausalLM = LlmLoader
    if args.device == "mps":
        # transformers pre-allocates one buffer the size of the weights (14.2 GB for Qwen2-7B bf16) to warm its
        # allocator; Metal rejects a single buffer that large ("Invalid buffer size"). Loading works without it.
        import transformers.modeling_utils as modeling_utils

        if hasattr(modeling_utils, "caching_allocator_warmup"):
            modeling_utils.caching_allocator_warmup = lambda *args, **kwargs: None
    model_dir = Path(args.model_dir)
    package = torch.load(str(model_dir / "model.pth.tar"), map_location="cpu", weights_only=False, mmap=True)
    package["args"].encoder_path = str(model_dir / "asr_encoder.pth.tar")
    package["args"].llm_dir = str(model_dir / "Qwen2-7B-Instruct")
    model = llm_module.FireRedAsrLlm.from_args(package["args"])
    model.load_state_dict(package["model_state_dict"], strict=False)
    del package
    model.encoder.to(args.device)
    model.encoder_projector.to(args.device)
    model.to(dtype)  # Official use_half casts the whole model; fp32 keeps the checkpoint precision.
    model.eval()
    tokenizer = LlmTokenizerWrapper.build_llm_tokenizer(str(model_dir / "Qwen2-7B-Instruct"))
    features = ASRFeatExtractor(str(model_dir / "cmvn.ark"))
    return model, tokenizer, features, LlmTokenizerWrapper


def footprint_bytes():
    if sys.platform != "darwin":
        return None
    import ctypes
    import os

    class Info(ctypes.Structure):
        _fields_ = [("uuid", ctypes.c_uint8 * 16), ("values", ctypes.c_uint64 * 40)]

    info = Info()
    if ctypes.CDLL("/usr/lib/libSystem.B.dylib").proc_pid_rusage(os.getpid(), 4, ctypes.byref(info)) != 0:
        return None
    return int(info.values[28])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--code", required=True)
    parser.add_argument("--device", default="cuda", choices=["cuda", "mps", "cpu"])
    parser.add_argument("--dtype", default="bfloat16", choices=["bfloat16", "float16", "float32"])
    parser.add_argument("--beam-size", type=int, default=3)
    parser.add_argument("--repetition-penalty", type=float, default=3.0)
    parser.add_argument("--length-penalty", type=float, default=1.0)
    parser.add_argument("--temperature", type=float, default=1.0)
    parser.add_argument("--decode-max-len", type=int, default=0)
    parser.add_argument("--decode-min-len", type=int, default=0)
    parser.add_argument("--name", default="fireredasr2-llm")
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--subsets")
    parser.add_argument("--limit", type=int)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--resume", action="store_true")
    args = parser.parse_args()

    import torch

    torch.set_grad_enabled(False)
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

    started = time.perf_counter()
    model, tokenizer, features, wrapper = load(args)
    load_seconds = time.perf_counter() - started

    def sync():
        if args.device == "cuda":
            torch.cuda.synchronize()
        elif args.device == "mps":
            torch.mps.synchronize()

    def transcribe(uid, wav_path):  # Official FireRedAsr2.transcribe, LLM branch, batch size 1.
        feats, lengths, _, _, _ = features([str(wav_path)], [uid])
        if feats is None:
            return ""
        feats, lengths = feats.to(args.device), lengths.to(args.device)
        if args.dtype != "float32":
            feats = feats.to(getattr(torch, args.dtype))
        input_ids, attention_mask, _, _ = wrapper.preprocess_texts(origin_texts=[""], tokenizer=tokenizer,
                                                                   max_len=128, decode=True)
        generated = model.transcribe(feats, lengths, input_ids.to(args.device), attention_mask.to(args.device),
                                     args.beam_size, args.decode_max_len, args.decode_min_len,
                                     args.repetition_penalty, args.length_penalty, args.temperature)
        sync()
        return tokenizer.batch_decode(generated, skip_special_tokens=True)[0].lower()

    started = time.perf_counter()
    transcribe(items[0]["uid"], args.corpus / items[0]["audio"])
    warmup = time.perf_counter() - started
    seconds = {item["uid"]: item["seconds"] for item in items}
    total_audio = sum(seconds[u] for u in done if u in seconds)
    total_decode = sum(r["decodeSeconds"] for u, r in done.items() if u in seconds)
    errors = sum(r["status"] != "completed" for u, r in done.items() if u in seconds)
    if args.device == "cuda":
        torch.cuda.reset_peak_memory_stats()
    with open(hypotheses, "a") as handle:
        for index, item in enumerate(items):
            if item["uid"] in done:
                continue
            row = dict(uid=item["uid"], subset=item["subset"])
            started = time.perf_counter()
            try:
                row.update(status="completed", text=transcribe(item["uid"], args.corpus / item["audio"]), lang="")
            except Exception as error:  # Scored as an empty hypothesis.
                errors += 1
                row.update(status="error", text="", error=repr(error))
            row["decodeSeconds"] = time.perf_counter() - started
            total_decode += row["decodeSeconds"]
            total_audio += item["seconds"]
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
            handle.flush()
            print(f"{index + 1}/{len(items)} rtf={total_decode / total_audio:.3f}", file=sys.stderr, flush=True)
    maxrss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    summary = dict(model=args.name, settings=dict(device=args.device, dtype=args.dtype, batch=1, beam=args.beam_size,
                                                  repetition_penalty=args.repetition_penalty,
                                                  length_penalty=args.length_penalty, temperature=args.temperature,
                                                  decode_max_len=args.decode_max_len, decode_min_len=args.decode_min_len),
                   torch=torch.__version__, python=platform.python_version(), platform=platform.platform(),
                   utterances=len(items), resumedUtterances=len(done), subsets=sorted((args.subsets or "").split(",")),
                   errors=errors, audioSeconds=total_audio, decodeSeconds=total_decode,
                   rtf=total_decode / total_audio if total_audio else None, loadSeconds=load_seconds, warmupSeconds=warmup,
                   peakRSSBytes=maxrss if sys.platform == "darwin" else maxrss * 1024,
                   lifetimeMaxPhysFootprintBytes=footprint_bytes(),
                   cudaMaxAllocatedBytes=torch.cuda.max_memory_allocated() if args.device == "cuda" else None,
                   modelBytesOnDisk=sum(p.stat().st_size for p in Path(args.model_dir).rglob("*")
                                        if p.is_file() and ".cache" not in p.parts))
    (args.output / "run.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
