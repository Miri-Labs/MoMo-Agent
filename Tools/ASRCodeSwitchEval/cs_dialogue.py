"""Build the CS-Dialogue held-out corpus (test + dev short_wav) for the evaluation.

The 19 split parts of short_wav.tar.gz are read as one concatenated stream and
only the WAV members listed in the test/dev wav.scp files are written, under our
own file names, to a new output directory. Nothing is extracted by member name;
the archive is never unpacked to disk. Utterances are labelled from their
transcripts: Han + Latin -> mixed, Han only -> zh, Latin only -> en.

CS-Dialogue terms (CC BY-NC-SA 4.0 + access terms) forbid redistribution: the
output stays under tmp_agent_output and is never committed.

    uv run --python 3.12 python -I Tools/ASRCodeSwitchEval/cs_dialogue.py build \
        --dataset tmp_agent_output/asr-code-switching-eval/datasets/cs-dialogue \
        --output tmp_agent_output/asr-code-switching-eval/corpus-csd-v1
    # Evaluation manifest: every code-switched utterance up to 20 s plus a fixed-seed sample
    # of monolingual controls per split; audio paths point into the built corpus.
    uv run --python 3.12 python -I Tools/ASRCodeSwitchEval/cs_dialogue.py select \
        --corpus tmp_agent_output/asr-code-switching-eval/corpus-csd-v1 \
        --output tmp_agent_output/asr-code-switching-eval/corpus-csd-eval-v1 --controls 300 --max-seconds 20
"""

import argparse
import hashlib
import io
import json
import random
import re
import tarfile
import wave
from pathlib import Path

REVISION = "a84770fcdf14072252373a0227321227eaac7dc7"
SPLITS = ["test", "dev"]
PARTS = 19
UID = re.compile(r"^[A-Za-z0-9_-]+$")
TAG = re.compile(r"<[^>]*>")
FILLER = re.compile(r"\b(?:um|uh|uhm|hmm|mm|mhm|er|ah|oh|eh)\b|[呃嗯啊哦噢唉诶欸哎额呣]", re.I)
MAX_MEMBER_BYTES = 64 << 20
SEED = 20261027


class Concatenated(io.RawIOBase):
    """Read several files back to back as one stream."""

    def __init__(self, paths):
        self.paths = list(paths)
        self.handle = None

    def readable(self):
        return True

    def readinto(self, buffer):
        while True:
            if self.handle is None:
                if not self.paths:
                    return 0
                self.handle = open(self.paths.pop(0), "rb")
            count = self.handle.readinto(buffer)
            if count:
                return count
            self.handle.close()
            self.handle = None


def language(text):
    content = FILLER.sub("", TAG.sub("", text))
    han = bool(re.search(r"[㐀-鿿]", content))
    latin = bool(re.search(r"[A-Za-z]", content))
    return "mixed" if han and latin else "zh" if han else "en" if latin else None


def select(corpus, output, controls, max_seconds):
    if output.exists():
        raise SystemExit(f"Output directory must not exist: {output}")
    items = [json.loads(line) for line in (corpus / "manifest.jsonl").read_text().splitlines() if line.strip()]
    chosen, summary = [], {}
    for split in SPLITS:
        for label in ["mixed", "zh", "en"]:
            # The app never sends more than a 20 s window to ASR, and FunASR Nano's
            # 512-token context cannot hold much more than ~28 s of audio.
            pool = sorted((item for item in items if item["split"] == split and item["language"] == label
                           and item["seconds"] <= max_seconds),
                          key=lambda item: item["uid"])
            if label != "mixed":
                pool = sorted(random.Random(f"{SEED}:{split}:{label}").sample(pool, min(controls, len(pool))),
                              key=lambda item: item["uid"])
            chosen += pool
            summary[f"csd-{split}-{label}"] = dict(utterances=len(pool),
                                                   hours=sum(item["seconds"] for item in pool) / 3600,
                                                   ids=[item["uid"] for item in pool])
    output.mkdir(parents=True)
    relative = Path("..") / corpus.name
    with open(output / "manifest.jsonl", "w") as handle:
        for item in chosen:
            handle.write(json.dumps(dict(item, audio=str(relative / item["audio"])), ensure_ascii=False) + "\n")
    (output / "selection.json").write_text(json.dumps(dict(
        dataset="BAAI/CS-Dialogue", revision=REVISION, seed=SEED, controlsPerSplitAndLanguage=controls,
        maxSeconds=max_seconds,
        rule="all code-switched test/dev utterances; fixed-seed monolingual controls", subsets=summary), indent=1) + "\n")
    for name, value in summary.items():
        print(name, value["utterances"], f"{value['hours']:.2f} h")


def build(dataset, output):
    args = argparse.Namespace(dataset=dataset, output=output)
    if args.output.exists():
        raise SystemExit(f"Output directory must not exist: {args.output}")
    index = args.dataset / "data" / "index" / "short_wav"
    wanted, items, skipped = {}, {}, {}
    for split in SPLITS:
        texts = dict(line.rstrip("\n").split(" ", 1) for line in (index / split / "text").read_text().splitlines())
        for line in (index / split / "wav.scp").read_text().splitlines():
            uid, path = line.split(" ", 1)
            if not UID.match(uid) or uid in items:
                raise SystemExit(f"Unexpected utterance ID: {uid!r}")
            label = language(texts[uid])
            if label is None:
                skipped[uid] = "no content after removing tags and fillers"
                continue
            wanted[path.strip().lstrip("./")] = uid
            items[uid] = dict(uid=uid, subset=f"csd-{split}-{label}", split=split, id=uid, language=label,
                              reference=texts[uid], speaker=uid.split("_")[1], session=uid.rsplit("_", 1)[0])
    parts = [args.dataset / "data" / "short_wav" / f"short_wav.tar.gz{index:02d}" for index in range(PARTS)]
    audio_dir = args.output / "audio"
    audio_dir.mkdir(parents=True)
    found = 0
    with tarfile.open(fileobj=io.BufferedReader(Concatenated(parts), 1 << 20), mode="r|gz") as tar:
        for member in tar:
            name = member.name.lstrip("./")
            uid = wanted.get(name)
            if uid is None:
                continue
            if not member.isfile() or member.size > MAX_MEMBER_BYTES:
                raise SystemExit(f"Unexpected member type or size: {member.name}")
            data = tar.extractfile(member).read()
            with wave.open(io.BytesIO(data)) as reader:
                fmt = (reader.getnchannels(), reader.getsampwidth(), reader.getframerate())
                frames = reader.getnframes()
            if fmt != (1, 2, 16000):
                raise SystemExit(f"Unexpected audio format {fmt} for {uid}")
            (audio_dir / f"{uid}.wav").write_bytes(data)
            items[uid].update(seconds=frames / 16000, audio=f"audio/{uid}.wav",
                              sha256=hashlib.sha256(data).hexdigest())
            found += 1
            if found == len(wanted):
                break
    missing = sorted(uid for uid in items if "audio" not in items[uid])
    if missing:
        raise SystemExit(f"{len(missing)} utterances missing from the archive, e.g. {missing[:3]}")
    order = sorted(items.values(), key=lambda item: (SPLITS.index(item["split"]), item["uid"]))
    with open(args.output / "manifest.jsonl", "w") as handle:
        for item in order:
            handle.write(json.dumps(item, ensure_ascii=False) + "\n")
    subsets = {}
    for item in order:
        entry = subsets.setdefault(item["subset"], dict(utterances=0, seconds=0.0, speakers=set()))
        entry["utterances"] += 1
        entry["seconds"] += item["seconds"]
        entry["speakers"].add(item["speaker"])
    summary = dict(dataset="BAAI/CS-Dialogue", revision=REVISION, license="CC BY-NC-SA 4.0 + access terms",
                   splits=SPLITS, skipped=skipped,
                   subsets={name: dict(utterances=value["utterances"], hours=value["seconds"] / 3600,
                                       speakers=len(value["speakers"])) for name, value in sorted(subsets.items())})
    (args.output / "selection.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary["subsets"], indent=2), f"skipped={len(skipped)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    b = sub.add_parser("build")
    b.add_argument("--dataset", type=Path, required=True)
    b.add_argument("--output", type=Path, required=True)
    s = sub.add_parser("select")
    s.add_argument("--corpus", type=Path, required=True)
    s.add_argument("--output", type=Path, required=True)
    s.add_argument("--controls", type=int, default=300)
    s.add_argument("--max-seconds", type=float, default=20.0)
    args = parser.parse_args()
    if args.command == "build":
        build(args.dataset, args.output)
    else:
        select(args.corpus.resolve(), args.output.resolve(), args.controls, args.max_seconds)


if __name__ == "__main__":
    main()
