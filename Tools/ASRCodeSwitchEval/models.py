"""Fetch, verify and run sherpa-onnx ASR candidates on the code-switching sample.

Subcommands (run from the repository root, each model in its own process so the
peak RSS belongs to that model only):

    uv run --python 3.12 --with sherpa-onnx==1.13.8 --with numpy==2.3.4 python -I \
        Tools/ASRCodeSwitchEval/models.py fetch MODEL_KEY --downloads DIR --models DIR
    uv run --python 3.12 --with sherpa-onnx==1.13.8 --with numpy==2.3.4 python -I \
        Tools/ASRCodeSwitchEval/models.py run MODEL_KEY --models DIR \
        --corpus tmp_agent_output/asr-code-switching-eval/corpus-ascend-v1 --output NEW_DIR

Downloaded archives are untrusted data: each archive is extracted with the
tarfile "data" filter into its own new, empty directory, and this script never
executes anything from those directories.
"""

import argparse
import hashlib
import json
import platform
import resource
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.request
import wave
from pathlib import Path

RELEASE = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/"
NANO_HF = ("https://huggingface.co/csukuangfj/sherpa-onnx-funasr-nano-int8-2025-12-30/resolve/"
           "6f16bd378457e13f36ccf3910df9017f96c346fb/")
THREADS = 2  # Same as the app's SpeechConfiguration default.

# archiveSHA256 comes from the GitHub release asset digest when GitHub publishes one.
# fileSHA256 pins individual files (from the app manifests or from the Hugging Face LFS
# object IDs of the upstream mirror) when the archive itself has no published digest.
MODELS = {
    "sensevoice-int8-20240717": dict(
        archive="sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17",
        archiveSHA256="7d1efa2138a65b0b488df37f8b89e3d91a60676e416f515b952358d83dfd347e",
        fileSHA256={"model.int8.onnx": "c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51",
                    "tokens.txt": "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc"},
        kind="sense_voice", language="auto", use_itn=True, license="FunASR Model License v1.1",
        note="App default (Native/SpeechVendor/manifest.json hashes)"),
    "sensevoice-int8-20250909": dict(
        archive="sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09",
        archiveSHA256="7305f7905bfcf77fa0b39388a313f3da35c68d971661a65475b56fb2162c8e63",
        kind="sense_voice", language="auto", use_itn=True, license="FunASR Model License v1.1 (see archive README)",
        note="Newer SenseVoice export, same architecture as the app default"),
    "funasr-nano-int8-20251230": dict(
        files=NANO_HF,
        fileSHA256={"Qwen3-0.6B/merges.txt": "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5",
                    "Qwen3-0.6B/tokenizer.json": "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4",
                    "Qwen3-0.6B/vocab.json": "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910",
                    "embedding.int8.onnx": "95e61cd0c9c3b9543339a4cf973c95c116815e745ccc1e0285cbd81f76d18644",
                    "encoder_adaptor.int8.onnx": "f36dea2e30fbc33b5db1d7a7265cc976c5e5586c77b042d5adb1ad27c72db422",
                    "llm.int8.onnx": "dfbf9aa3be41bccc257587f151e15c63fbe1b549f2b517f5ccd5bdce3bf4322a"},
        kind="funasr_nano", license="Apache-2.0 (Fun-ASR-Nano-2512)",
        note="App optional download (funasr-nano-onnx-v1.json); app prompts/decoding"),
    "qwen3-asr-0.6b-int8-20260325": dict(
        archive="sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25",
        archiveSHA256="393f8a14e2f5fb96746aaab342997a40641001fbd5bf9592a080a8329178ee96",
        kind="qwen3_asr", license="Apache-2.0 (Qwen/Qwen3-ASR-0.6B)"),
    "fireredasr2-aed-int8-20260226": dict(
        archive="sherpa-onnx-fire-red-asr2-zh_en-int8-2026-02-26",
        archiveSHA256="43015b3f1643a5688b4821e8ed323473d38b798c4ec291471fe00df1bcfc4f1c",
        kind="fire_red_asr", license="Apache-2.0 (FireRedTeam/FireRedASR2-AED)"),
    "fireredasr2-ctc-int8-20260225": dict(
        archive="sherpa-onnx-fire-red-asr2-ctc-zh_en-int8-2026-02-25",
        archiveSHA256="1da8b737ecc5e29f36759a4460c754863e7c919a4ba325aea187331fbfc83274",
        kind="fire_red_asr_ctc", license="Apache-2.0 (FireRedTeam/FireRedASR2)"),
    "paraformer-zh-int8-20251007": dict(
        archive="sherpa-onnx-paraformer-zh-int8-2025-10-07",
        archiveSHA256="a071ee5419e14adb34d7f970ab98105a45e6608018b168f023ca2e4810744abe",
        kind="paraformer", license="FunASR Model License (see archive README)"),
    "paraformer-zh-int8-20240309": dict(
        archive="sherpa-onnx-paraformer-zh-2024-03-09",
        # HF LFS oid, csukuangfj/sherpa-onnx-paraformer-zh-2024-03-09 @ 906992d326ebf0c5171cde675aa0902be9e5bc6c
        fileSHA256={"model.int8.onnx": "90bc03034ae1bef9575f8cc798cd1519c8be8aa9e8b458a033e32017ff4d584c"},
        kind="paraformer", license="FunASR Model License (see archive README)"),
    "dolphin-small-ctc-int8-20250402": dict(
        archive="sherpa-onnx-dolphin-small-ctc-multi-lang-int8-2025-04-02",
        # HF LFS oid, csukuangfj/sherpa-onnx-dolphin-small-ctc-multi-lang-int8-2025-04-02 @ c8b66895
        fileSHA256={"model.int8.onnx": "c1afcb9265de0ebd853eb8f570b371f399a6f9b2b9af9a3cb17c2e509171e697"},
        kind="dolphin_ctc", license="Apache-2.0 (DataoceanAI/dolphin-small)"),
    "whisper-large-v3-turbo-int8": dict(
        archive="sherpa-onnx-whisper-turbo",
        # HF LFS oids, csukuangfj/sherpa-onnx-whisper-turbo @ 2ca6ff69fc878651b770880507669577ac41c2ff
        fileSHA256={"turbo-encoder.int8.onnx": "b02dcdf54f348741e93fe732b67d933c8dcb6735655f710640143081db38878b",
                    "turbo-decoder.int8.onnx": "20accd02388482eb3a46bd615631adfdc85e1eb2c7db9ea3f02a40ffe6b81547"},
        kind="whisper", prefix="turbo", language="", license="MIT (openai/whisper-large-v3-turbo)"),
    # X-ASR-zh-en (SJTU/SII et al., Gilgamesh-J/X-ASR, Apache-2.0): one Zipformer transducer checkpoint
    # ("fintuned_with_punctuation.pt", ~0.16B params) exported by sherpa-onnx as streaming models with
    # 160/480/960/1920 ms chunks and as a non-streaming model. 480 ms is the chunk sherpa-onnx uses for its
    # on-device (Android QNN) demo; the non-streaming export is the offline reference.
    "x-asr-streaming-480ms-punct-int8-20260605": dict(
        archive="sherpa-onnx-x-asr-480ms-streaming-zipformer-transducer-zh-en-punct-int8-2026-06-05",
        archiveSHA256="fa5f63d618e5a01526e275a358bb7772e403f84808a4769fba52cffd8160bf74",
        kind="online_transducer", tail_padding_seconds=2.0,
        license="Apache-2.0 (Gilgamesh-J/X-ASR, X-ASR-zh-en)",
        note="Streaming Zipformer transducer, 480 ms chunks, punctuation+casing checkpoint"),
    "x-asr-offline-punct-int8-20260603": dict(
        archive="sherpa-onnx-x-asr-zipformer-transducer-zh-en-punct-int8-2026-06-03",
        archiveSHA256="5d02c36d7b44e886b7c8f0d8e051f8713acab96c264bb6ef9e718be39a6a2224",
        # Note: the encoder in this GitHub archive (161,015,713 bytes) is not the file on the HF mirror
        # csukuangfj2/sherpa-onnx-x-asr-zipformer-transducer-zh-en-punct-int8-2026-06-03 @ ce812cc0
        # (161,744,450 bytes, oid fe0198b5...); the GitHub release digest is the pin used here.
        kind="offline_transducer", license="Apache-2.0 (Gilgamesh-J/X-ASR, X-ASR-zh-en)",
        note="Same checkpoint, non-streaming (full-context) export"),
}
# Language-setting variants reuse the extracted files of their base model.
VARIANTS = {
    "sensevoice-int8-20240717-lang-zh": ("sensevoice-int8-20240717", dict(language="zh")),
    "funasr-nano-int8-20251230-lang-zh": ("funasr-nano-int8-20251230", dict(language="中文")),
    "whisper-large-v3-turbo-int8-lang-zh": ("whisper-large-v3-turbo-int8", dict(language="zh")),
    "x-asr-streaming-480ms-punct-int8-20260605-tail1": ("x-asr-streaming-480ms-punct-int8-20260605", dict(tail_padding_seconds=1.0)),
    "x-asr-streaming-480ms-punct-int8-20260605-tail066": ("x-asr-streaming-480ms-punct-int8-20260605", dict(tail_padding_seconds=0.66)),
    "x-asr-streaming-480ms-punct-int8-20260605-tail3": ("x-asr-streaming-480ms-punct-int8-20260605", dict(tail_padding_seconds=3.0)),
}
for _name, (_base, _overrides) in VARIANTS.items():
    MODELS[_name] = dict(MODELS[_base], dir=_base, **_overrides)
# Local 4-bit builds of FireRedASR2-AED made by quantize_firered.py (not fetched; see quantize.json in each
# directory). Same sherpa-onnx FireRed AED runtime and greedy decoding as the released int8 model.
for _name, _note in {
    "fireredasr2-aed-int4-b32": "encoder+decoder MatMulNBits 4-bit, block 32, accuracy_level 4",
    "fireredasr2-aed-int4-b128": "encoder+decoder MatMulNBits 4-bit, block 128, accuracy_level 4",
    "fireredasr2-aed-int8enc-int4dec-b32": "released int8 encoder + MatMulNBits 4-bit decoder, block 32",
}.items():
    MODELS[_name] = dict(kind="fire_red_asr", encoder="encoder.onnx", decoder="decoder.onnx", local_build=True,
                         license="Apache-2.0 (FireRedTeam/FireRedASR2-AED)", note=_note)
# The per-file HF mirror of the X-ASR non-streaming export, which the app's file-by-file installer can pin.
# Encoder and decoder differ from the GitHub archive above (another export run); downloaded file by file
# and checked against these HF LFS oids by the caller (not fetched here).
MODELS["x-asr-offline-punct-int8-20260603-hf"] = dict(
    kind="offline_transducer", local_build=True, license="Apache-2.0 (Gilgamesh-J/X-ASR, X-ASR-zh-en)",
    note="csukuangfj2/sherpa-onnx-x-asr-zipformer-transducer-zh-en-punct-int8-2026-06-03 @ ce812cc0")


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def download(url, path):
    if path.exists():
        return
    partial = path.with_suffix(path.suffix + ".partial")
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["curl", "-sSL", "--fail", "-C", "-", "-o", str(partial), url], check=True)
    partial.rename(path)


def fetch(key, downloads, models):
    spec = MODELS[key]
    target = models / key
    record = dict(model=key)
    if "files" in spec:
        staging = downloads / key
        for name, expected in spec["fileSHA256"].items():
            download(spec["files"] + name, staging / name)
            if sha256_file(staging / name) != expected:
                raise SystemExit(f"SHA256 mismatch: {name}")
        if not target.exists():
            shutil.copytree(staging, target)
        record.update(source=spec["files"], files=spec["fileSHA256"])
    else:
        archive = downloads / "archives" / f"{spec['archive']}.tar.bz2"
        download(RELEASE + archive.name, archive)
        actual = sha256_file(archive)
        if spec.get("archiveSHA256") and actual != spec["archiveSHA256"]:
            raise SystemExit(f"Archive SHA256 mismatch for {archive.name}: {actual}")
        record.update(archive=archive.name, archiveSHA256=actual,
                      archiveDigestPublished=bool(spec.get("archiveSHA256")))
        if not target.exists():
            staging = models / f".{key}.extracting"
            staging.mkdir(parents=True)  # Fails if a stale staging directory exists.
            with tarfile.open(archive, "r:bz2") as tar:
                tar.extractall(staging, filter="data")
            (root,) = list(staging.iterdir())
            root.rename(target)
            staging.rmdir()
    files = {str(path.relative_to(target)): dict(bytes=path.stat().st_size, sha256=sha256_file(path))
             for path in sorted(target.rglob("*")) if path.is_file()}
    for name, expected in spec.get("fileSHA256", {}).items():
        if files[name]["sha256"] != expected:
            raise SystemExit(f"Extracted file SHA256 mismatch: {name}")
    record["extractedFiles"] = files
    (models / f"{key}.fetch.json").write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps({k: v for k, v in record.items() if k != "extractedFiles"}, indent=2))


def one(directory, pattern):
    matches = sorted(directory.glob(pattern))
    if len(matches) != 1:
        raise SystemExit(f"Expected one {pattern} in {directory}, found {[m.name for m in matches]}")
    return str(matches[0])


def build(key, directory):
    import sherpa_onnx

    spec = MODELS[key]
    kind = spec["kind"]
    common = dict(num_threads=THREADS, provider="cpu", decoding_method="greedy_search")
    R = sherpa_onnx.OfflineRecognizer
    if kind == "sense_voice":
        settings = dict(language=spec["language"], use_itn=spec["use_itn"])
        return R.from_sense_voice(model=one(directory, "model.int8.onnx"), tokens=one(directory, "tokens.txt"),
                                  **settings, **common), settings
    if kind == "funasr_nano":
        # Same prompts and decoding values as SherpaRuntime.swift in the app.
        settings = dict(language=spec.get("language", ""), itn=True, system_prompt="You are a helpful assistant.",
                        user_prompt="语音转写：", max_new_tokens=384, temperature=0.0, top_p=0.8, seed=42)
        return R.from_funasr_nano(encoder_adaptor=one(directory, "encoder_adaptor.int8.onnx"),
                                  llm=one(directory, "llm.int8.onnx"), embedding=one(directory, "embedding.int8.onnx"),
                                  tokenizer=str(directory / "Qwen3-0.6B"), **settings, **common), settings
    if kind == "qwen3_asr":
        # Limits only matter for long inputs; ASCEND runs used 256/512 and never reached them.
        settings = dict(max_new_tokens=512, max_total_len=2048, hotwords="", language="not configurable (auto)")
        return R.from_qwen3_asr(conv_frontend=one(directory, "conv_frontend*.onnx"),
                                encoder=one(directory, "encoder*.onnx"), decoder=one(directory, "decoder*.onnx"),
                                tokenizer=one(directory, "tokenizer*"), max_new_tokens=512, max_total_len=2048,
                                **common), settings
    if kind == "fire_red_asr":
        return R.from_fire_red_asr(encoder=one(directory, spec.get("encoder", "encoder.int8.onnx")),
                                   decoder=one(directory, spec.get("decoder", "decoder.int8.onnx")),
                                   tokens=one(directory, "tokens.txt"), **common), dict(language="n/a (zh/en model)")
    if kind == "fire_red_asr_ctc":
        return R.from_fire_red_asr_ctc(model=one(directory, "model.int8.onnx"), tokens=one(directory, "tokens.txt"),
                                       **common), dict(language="n/a (zh/en model)")
    if kind == "paraformer":
        return R.from_paraformer(paraformer=one(directory, "model.int8.onnx"), tokens=one(directory, "tokens.txt"),
                                 **common), dict(language="n/a (zh/en model)")
    if kind == "dolphin_ctc":
        return R.from_dolphin_ctc(model=one(directory, "model.int8.onnx"), tokens=one(directory, "tokens.txt"),
                                  **common), dict(language="n/a (auto)")
    if kind == "offline_transducer":
        return R.from_transducer(encoder=one(directory, "encoder*.int8.onnx"), decoder=one(directory, "decoder*.onnx"),
                                 joiner=one(directory, "joiner*.int8.onnx"), tokens=one(directory, "tokens.txt"),
                                 **common), dict(language="n/a (zh/en model)")
    if kind == "online_transducer":
        # Whole utterance is pushed through the streaming encoder chunk by chunk, followed by silence
        # padding and input_finished(); only full chunks are decoded, so the tail must cover a chunk plus the
        # model's emission delay. 0.66 s (sherpa-onnx's online-decode-files.py) dropped the last 1-2 words with
        # 480 ms chunks; 2 s reaches the plateau (1 s / 2 s / 3 s sweep on the ASCEND controls).
        settings = dict(language="n/a (zh/en model)", tail_padding_seconds=spec["tail_padding_seconds"],
                        endpoint_detection=False)
        return sherpa_onnx.OnlineRecognizer.from_transducer(
            encoder=one(directory, "encoder*.int8.onnx"), decoder=one(directory, "decoder*.onnx"),
            joiner=one(directory, "joiner*.int8.onnx"), tokens=one(directory, "tokens.txt"),
            enable_endpoint_detection=False, **common), settings
    if kind == "whisper":
        prefix = spec["prefix"]
        settings = dict(language=spec["language"] or "auto-detect", task="transcribe")
        return R.from_whisper(encoder=one(directory, f"{prefix}-encoder.int8.onnx"),
                              decoder=one(directory, f"{prefix}-decoder.int8.onnx"),
                              tokens=one(directory, f"{prefix}-tokens.txt"), language=spec["language"],
                              task="transcribe", **common), settings
    raise SystemExit(f"Unknown kind {kind}")


def read_wav(path):
    import numpy as np

    with wave.open(str(path)) as reader:
        if (reader.getnchannels(), reader.getsampwidth(), reader.getframerate()) != (1, 2, 16000):
            raise ValueError(f"Expected 16 kHz mono PCM16: {path}")
        data = reader.readframes(reader.getnframes())
    return np.frombuffer(data, dtype="<i2").astype("float32") / 32768.0


def peak_rss_bytes():
    value = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return value if sys.platform == "darwin" else value * 1024  # macOS reports bytes, Linux KiB.


def run(key, models, corpus, output, subsets=None, resume=False):
    import sherpa_onnx

    if output.exists() and not resume:
        raise SystemExit(f"Output directory must not exist: {output}")
    items = [json.loads(line) for line in (corpus / "manifest.jsonl").read_text().splitlines() if line.strip()]
    if subsets:
        items = [item for item in items if item["subset"] in subsets]
    done = {}
    hypotheses = output / "hypotheses.jsonl"
    if resume and hypotheses.exists():
        for line in hypotheses.read_text().splitlines():
            if line.strip():
                row = json.loads(line)
                done[row["uid"]] = row
    output.mkdir(parents=True, exist_ok=True)
    # Audio is read lazily per utterance so long corpora do not stay in memory.
    rss_before_load = peak_rss_bytes()
    started = time.perf_counter()
    directory = models / MODELS[key].get("dir", key)
    recognizer, settings = build(key, directory)
    load_seconds = time.perf_counter() - started

    def decode(samples):
        stream = recognizer.create_stream()
        stream.accept_waveform(16000, samples)
        if isinstance(recognizer, sherpa_onnx.OnlineRecognizer):
            import numpy as np

            stream.accept_waveform(16000, np.zeros(int(settings["tail_padding_seconds"] * 16000), dtype="float32"))
            stream.input_finished()
            while recognizer.is_ready(stream):
                recognizer.decode_stream(stream)
            return recognizer.get_result_all(stream)
        recognizer.decode_stream(stream)
        return stream.result

    # One warm-up decode on the first utterance; it is excluded from the RTF.
    started = time.perf_counter()
    decode(read_wav(corpus / items[0]["audio"]))
    warmup_seconds = time.perf_counter() - started
    seconds = {item["uid"]: item["seconds"] for item in items}
    total_audio = sum(seconds[uid] for uid in done if uid in seconds)
    total_decode = sum(row["decodeSeconds"] for uid, row in done.items() if uid in seconds)
    errors = sum(row["status"] != "completed" for uid, row in done.items() if uid in seconds)
    with open(hypotheses, "a") as handle:
        for item in items:
            if item["uid"] in done:
                continue
            samples = read_wav(corpus / item["audio"])
            row = dict(uid=item["uid"], subset=item["subset"])
            started = time.perf_counter()
            try:
                result = decode(samples)
                row.update(status="completed", text=result.text, lang=getattr(result, "lang", "") or "")
            except Exception as error:  # Keep going; failures are scored as empty hypotheses.
                errors += 1
                row.update(status="error", text="", error=repr(error))
            row["decodeSeconds"] = time.perf_counter() - started
            total_decode += row["decodeSeconds"]
            total_audio += item["seconds"]
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
            handle.flush()
    size = sum(path.stat().st_size for path in directory.rglob("*") if path.is_file()
               and path.suffix in {".onnx", ".txt", ".json"} and "test_wavs" not in path.parts)
    summary = dict(model=key, spec={k: v for k, v in MODELS[key].items() if k not in {"fileSHA256"}},
                   settings=settings, threads=THREADS, provider="cpu", sherpaOnnx=sherpa_onnx.__version__,
                   python=platform.python_version(), machine=platform.machine(), platform=platform.platform(),
                   utterances=len(items), resumedUtterances=len(done), subsets=sorted(subsets or []),
                   errors=errors, audioSeconds=total_audio, decodeSeconds=total_decode,
                   rtf=total_decode / total_audio, loadSeconds=load_seconds, warmupSeconds=warmup_seconds,
                   peakRSSBytesBeforeLoad=rss_before_load, peakRSSBytes=peak_rss_bytes(),
                   modelBytesOnDisk=size)
    (output / "run.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({k: summary[k] for k in ["model", "utterances", "errors", "rtf", "loadSeconds",
                                              "peakRSSBytes", "modelBytesOnDisk"]}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    fetch_parser = sub.add_parser("fetch")
    fetch_parser.add_argument("model", choices=sorted(MODELS))
    fetch_parser.add_argument("--downloads", type=Path, required=True)
    fetch_parser.add_argument("--models", type=Path, required=True)
    run_parser = sub.add_parser("run")
    run_parser.add_argument("model", choices=sorted(MODELS))
    run_parser.add_argument("--models", type=Path, required=True)
    run_parser.add_argument("--corpus", type=Path, required=True)
    run_parser.add_argument("--output", type=Path, required=True)
    run_parser.add_argument("--subsets", help="Comma-separated manifest subsets to run (default: all)")
    run_parser.add_argument("--resume", action="store_true", help="Append to an existing hypotheses.jsonl")
    args = parser.parse_args()
    if args.command == "fetch":
        fetch(args.model, args.downloads.resolve(), args.models.resolve())
    else:
        run(args.model, args.models.resolve(), args.corpus.resolve(), args.output.resolve(),
            set(args.subsets.split(",")) if args.subsets else None, args.resume)


if __name__ == "__main__":
    main()
