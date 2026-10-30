"""Cross-check the Python sherpa-onnx path against the app's Swift SpeechEngine.

`prepare` writes a corpus in the format that Tools/SpeechQuality expects: the
first N utterances (by ID) of the ascend-test-mixed subset plus one all-zero
padding WAV. The padding exists only because SpeechQuality requires exactly
57,600,000 frames (its FLEURS hour); Silero VAD finds no speech in it, so it
produces no ASR window and is excluded from scoring.

`convert` turns SpeechQuality's utterances.jsonl into the hypotheses.jsonl
format used by models.py / score.py, so both paths are scored identically.

    uv run --python 3.12 python -I Tools/ASRCodeSwitchEval/swift_check.py prepare \
        --corpus tmp_agent_output/asr-code-switching-eval/corpus-ascend-v1 --output NEW_DIR --count 20
    uv run --python 3.12 python -I Tools/ASRCodeSwitchEval/swift_check.py convert \
        --swift-corpus NEW_DIR --swift-run SWIFT_RUN_DIR --output RUNS_DIR/NAME
"""

import argparse
import hashlib
import json
import shutil
import wave
from pathlib import Path

TOTAL_FRAMES = 57_600_000
PADDING_ID = "padding-silence"


def prepare(corpus, output, count):
    if output.exists():
        raise SystemExit(f"Output directory must not exist: {output}")
    items = [json.loads(line) for line in (corpus / "manifest.jsonl").read_text().splitlines() if line.strip()]
    chosen = [item for item in items if item["subset"] == "ascend-test-mixed"][:count]
    (output / "audio").mkdir(parents=True)
    entries, frames_used = [], 0
    for item in chosen:
        source = corpus / item["audio"]
        target = output / "audio" / f"{item['uid']}.wav"
        shutil.copyfile(source, target)
        with wave.open(str(target)) as reader:
            frames = reader.getnframes()
        frames_used += frames
        data = target.read_bytes()
        entries.append(dict(id=item["uid"], sentenceID=item["uid"], filename=target.name, frames=frames,
                            sha256=hashlib.sha256(data).hexdigest(), byteCount=len(data), codec="pcmInt16"))
    padding = output / "audio" / f"{PADDING_ID}.wav"
    with wave.open(str(padding), "wb") as writer:
        writer.setnchannels(1)
        writer.setsampwidth(2)
        writer.setframerate(16000)
        remaining = TOTAL_FRAMES - frames_used
        block = b"\0\0" * 160000
        while remaining > 0:
            step = min(remaining, 160000)
            writer.writeframes(block[: step * 2])
            remaining -= step
    data = padding.read_bytes()
    entries.append(dict(id=PADDING_ID, sentenceID=PADDING_ID, filename=padding.name,
                        frames=TOTAL_FRAMES - frames_used, sha256=hashlib.sha256(data).hexdigest(),
                        byteCount=len(data), codec="pcmInt16"))
    selection = dict(purpose="ASCEND swift cross-check", uids=[item["uid"] for item in chosen],
                     padding="all-zero PCM16 to satisfy the SpeechQuality 57,600,000-frame guard")
    selection_path = output / "selection.json"
    selection_path.write_text(json.dumps(selection, indent=2) + "\n")
    manifest = dict(schemaVersion=1, status="prepared", sampleRate=16000,
                    selectionSHA256=hashlib.sha256(selection_path.read_bytes()).hexdigest(),
                    annotationStatus="ascend-reference-text", items=entries)
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Prepared {len(chosen)} utterances + padding ({TOTAL_FRAMES - frames_used} frames)")


def convert(swift_corpus, swift_run, output):
    if output.exists():
        raise SystemExit(f"Output directory must not exist: {output}")
    selection = json.loads((swift_corpus / "selection.json").read_text())
    rows = [json.loads(line) for line in (swift_run / "utterances.jsonl").read_text().splitlines() if line.strip()]
    by_id = {row["id"]: row for row in rows}
    padding = by_id.get(PADDING_ID)
    if padding is None or padding["text"].strip():
        raise SystemExit("The padding file must exist and produce no text")
    output.mkdir(parents=True)
    with open(output / "hypotheses.jsonl", "w") as handle:
        for uid in selection["uids"]:
            row = by_id[uid]
            handle.write(json.dumps(dict(uid=uid, subset="ascend-test-mixed", status=row["status"],
                                         text=row["text"], windows=len(row["windows"]),
                                         decodeSeconds=row["elapsedSeconds"]), ensure_ascii=False) + "\n")
    print(f"Converted {len(selection['uids'])} utterances; padding windows: {len(padding['windows'])}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("prepare")
    p.add_argument("--corpus", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--count", type=int, default=20)
    c = sub.add_parser("convert")
    c.add_argument("--swift-corpus", type=Path, required=True)
    c.add_argument("--swift-run", type=Path, required=True)
    c.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args.corpus, args.output, args.count)
    else:
        convert(args.swift_corpus, args.swift_run, args.output)


if __name__ == "__main__":
    main()
