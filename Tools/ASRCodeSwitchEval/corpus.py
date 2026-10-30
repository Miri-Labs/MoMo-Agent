"""Build the fixed ASCEND code-switching evaluation sample.

Reads the pinned ASCEND parquet files (passed as arguments, treated as untrusted
data), selects utterances with a fixed seed, and writes 16 kHz mono PCM16 WAVs
plus a manifest into a new output directory.

Run (from the repository root):
    uv run --python 3.12 --with pyarrow==21.0.0 python -I \
        Tools/ASRCodeSwitchEval/corpus.py \
        --test PATH/test-00000-of-00001.parquet \
        --validation PATH/validation-00000-of-00001.parquet \
        --output tmp_agent_output/asr-code-switching-eval/corpus-ascend-v1
"""

import argparse
import hashlib
import io
import json
import random
import re
import wave
from pathlib import Path

import pyarrow.parquet as pq

REVISION = "737e9800ae31be9932ba8464c80366559bd28424"
PARQUET_SHA256 = {
    "test": "a4c81d2b5ed6124f052089a695972808c16e0ce0c365ec9773c5d1a8fcf043a7",
    "validation": "3bdec53d2abfd3dd4f0d86a6df4e27e60f20660edc9b66055ae0ef8ec05cf7e2",
}
SEED = 20261027
SELECTION_VERSION = "momo-ascend-cs-v1"
# (subset name, split, ASCEND language label, sample size)
SUBSETS = [
    ("ascend-test-mixed", "test", "mixed", 200),
    ("ascend-val-mixed", "validation", "mixed", 200),
    ("ascend-test-zh", "test", "zh", 50),
    ("ascend-test-en", "test", "en", 50),
]
# Fillers / tags that are removed before deciding whether an utterance has content.
CONTENT_PATTERN = re.compile(r"\[unk\]|[呃嗯啊哦噢唉诶欸哎呀嘛哈]|\b(?:um|uh|uhm|hmm|mm|er|ah|oh)\b", re.I)
MIN_SECONDS = 1.0


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def has_content(text):
    return bool(re.sub(r"[\s']", "", CONTENT_PATTERN.sub("", text)))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--test", type=Path, required=True)
    parser.add_argument("--validation", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise SystemExit(f"Output directory must not exist: {args.output}")
    paths = {"test": args.test, "validation": args.validation}
    for split, path in paths.items():
        actual = sha256_file(path)
        if actual != PARQUET_SHA256[split]:
            raise SystemExit(f"{split} parquet SHA256 mismatch: {actual}")

    columns = ["id", "path", "transcription", "duration", "language", "original_speaker_id", "session_id", "topic"]
    tables = {split: pq.read_table(path) for split, path in paths.items()}
    audio_dir = args.output / "audio"
    audio_dir.mkdir(parents=True)
    manifest, selection = [], {}
    for subset, split, language, size in SUBSETS:
        table = tables[split]
        rows = table.select(columns).to_pylist()
        eligible = [index for index, row in enumerate(rows)
                    if row["language"] == language and row["duration"] >= MIN_SECONDS
                    and has_content(row["transcription"])]
        # Sort by ID first so the sample depends only on the seed and the pinned data.
        eligible.sort(key=lambda index: rows[index]["id"])
        picked = sorted(random.Random(f"{SEED}:{subset}").sample(eligible, min(size, len(eligible))),
                        key=lambda index: rows[index]["id"])
        selection[subset] = dict(split=split, language=language, eligible=len(eligible),
                                 ids=[rows[index]["id"] for index in picked])
        audio = table.column("audio")
        for index in picked:
            row = rows[index]
            data = audio[index].as_py()["bytes"]
            with wave.open(io.BytesIO(data)) as reader:
                if (reader.getnchannels(), reader.getsampwidth(), reader.getframerate()) != (1, 2, 16000):
                    raise SystemExit(f"Unexpected audio format for {split}/{row['id']}")
                frames = reader.getnframes()
            uid = f"{split}-{row['id']}"
            (audio_dir / f"{uid}.wav").write_bytes(data)
            manifest.append(dict(uid=uid, subset=subset, split=split, id=row["id"], language=row["language"],
                                 reference=row["transcription"], seconds=frames / 16000,
                                 speaker=row["original_speaker_id"], session=row["session_id"],
                                 topic=row["topic"], sourcePath=row["path"],
                                 audio=f"audio/{uid}.wav", sha256=hashlib.sha256(data).hexdigest()))
    meta = dict(selectionVersion=SELECTION_VERSION, dataset="CAiRE/ASCEND", revision=REVISION,
                license="CC BY-SA 4.0", parquetSHA256=PARQUET_SHA256, seed=SEED, minSeconds=MIN_SECONDS,
                contentRule="non-empty after removing [UNK] and fillers", subsets=selection)
    (args.output / "selection.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n")
    with open(args.output / "manifest.jsonl", "w") as handle:
        for item in manifest:
            handle.write(json.dumps(item, ensure_ascii=False) + "\n")
    for subset, info in selection.items():
        seconds = sum(item["seconds"] for item in manifest if item["subset"] == subset)
        speakers = sorted({item["speaker"] for item in manifest if item["subset"] == subset})
        print(f"{subset}: {len(info['ids'])}/{info['eligible']} utterances, {seconds / 60:.1f} min, speakers {speakers}")


if __name__ == "__main__":
    main()
