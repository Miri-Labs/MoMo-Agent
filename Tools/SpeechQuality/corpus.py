"""Prepare a pinned, sentence-disjoint Mandarin corpus without caching an archive."""

import argparse
from collections import Counter, defaultdict
import csv
import hashlib
import io
import json
import math
from pathlib import Path, PurePosixPath
import shutil
import struct
import tarfile
import urllib.request

REVISION = "70bb2e84b976b7e960aa89f1c648e09c59f894dd"
BASE = f"https://huggingface.co/datasets/google/fleurs/resolve/{REVISION}/"
SEED = "momoagent-fleurs-zh-v1"
RATE = 16_000
MAX_BYTES = 700 * 1024 * 1024
MIN_FREE_BYTES = 1024 * 1024 * 1024
ARCHIVE = {
    "url": BASE + "data/cmn_hans_cn/audio/test.tar.gz",
    "sha256": "09d19ad18f5d7e91076880807e866cd16abd924c7052b55f71cdae91714fc166",
    "byteCount": 525_346_466,
}
METADATA = {
    "README.md": "688f79f2a5c731af3796e9f683eb02f9b3f09d040decd8c5625d0f37098e71c6",
    "data/cmn_hans_cn/test.tsv": "5734461648f816181d7dab5fc79204b18c4b9bc2cd5138225b25c72d18385d21",
}


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode()


def write_json(path, value):
    data = json_bytes(value)
    if path.exists():
        if path.read_bytes() != data:
            raise ValueError(f"Existing evidence differs: {path}. Use a new destination.")
        return
    with path.open("xb") as output:
        output.write(data)


def order_key(value):
    return hashlib.sha256(f"{SEED}:{value}".encode()).hexdigest()


def parse_tsv(data):
    items = []
    for row in csv.reader(io.StringIO(data.decode("utf-8")), delimiter="\t"):
        if len(row) != 7:
            raise ValueError("Expected seven FLEURS TSV columns")
        sid, filename, raw, reference, _, frames, gender = row
        if not sid.isdigit() or not filename.endswith(".wav") or PurePosixPath(filename).name != filename:
            raise ValueError("Invalid FLEURS identity")
        if gender not in {"MALE", "FEMALE"} or int(frames) <= 0 or not reference.strip():
            raise ValueError("Invalid FLEURS metadata")
        items.append(dict(id=filename[:-4], sentenceID=sid, filename=filename,
                          frames=int(frames), reference=reference, rawReference=raw, gender=gender))
    if len({item["filename"] for item in items}) != len(items):
        raise ValueError("Duplicate audio filename")
    return items


def exact_duration(items, frames):
    """Select whole utterances by integer frame count, without ASR-dependent choices."""
    if not items or frames <= 0:
        raise ValueError("A duration selection needs nonempty positive-length input")
    quantum = math.gcd(*(item["frames"] for item in items))
    if frames % quantum:
        raise ValueError("The requested duration is not reachable with whole utterances")
    target = frames // quantum
    states = [1]
    mask = (1 << (target + 1)) - 1
    for item in items:
        states.append((states[-1] | states[-1] << (item["frames"] // quantum)) & mask)
    if not (states[-1] >> target) & 1:
        raise ValueError("Insufficient distinct utterances for the requested duration")
    selected = []
    for index in range(len(items) - 1, -1, -1):
        if not (states[index] >> target) & 1:
            selected.append(items[index])
            target -= items[index]["frames"] // quantum
    return selected


def select(items, seconds_per_gender=1800):
    groups = defaultdict(list)
    for item in items:
        groups[item["sentenceID"]].append(item)
    if any(len({item["rawReference"] for item in group}) != 1 for group in groups.values()):
        raise ValueError("One sentence ID has conflicting references")
    pools = {"MALE": [], "FEMALE": []}
    totals = {gender: 0 for gender in pools}
    for sid in sorted(groups, key=order_key):
        available = {item["gender"] for item in groups[sid]}
        gender = min(available, key=lambda value: (totals[value], value))
        item = min((item for item in groups[sid] if item["gender"] == gender),
                   key=lambda item: order_key(item["filename"]))
        pools[gender].append(item)
        totals[gender] += item["frames"]
    selected = [item for gender in pools
                for item in exact_duration(pools[gender], seconds_per_gender * RATE)]
    if len({item["rawReference"] for item in selected}) != len(selected):
        raise ValueError("The selected set contains repeated sentence text")
    return sorted(selected, key=lambda item: order_key(item["filename"]))


def statistics(items):
    def bucket(item):
        seconds = item["frames"] / RATE
        return "under_8s" if seconds < 8 else "8_to_15s" if seconds < 15 else "at_least_15s"
    return {
        "count": len(items), "uniqueSentenceCount": len({item["sentenceID"] for item in items}),
        "totalFrames": sum(item["frames"] for item in items),
        "genderCounts": dict(Counter(item["gender"] for item in items)),
        "genderFrames": {gender: sum(item["frames"] for item in items if item["gender"] == gender)
                         for gender in ["MALE", "FEMALE"]},
        "durationCounts": dict(Counter(bucket(item) for item in items)),
        "containsLatinCount": sum(any("a" <= char.lower() <= "z" for char in item["reference"]) for item in items),
        "containsDigitCount": sum(any(char.isdigit() for char in item["reference"]) for item in items),
    }


def check_space(directory, additional=0):
    used = sum(path.stat().st_size for path in directory.rglob("*") if path.is_file())
    if used + additional > MAX_BYTES:
        raise ValueError("Corpus directory would exceed 700 MiB")
    if shutil.disk_usage(directory).free - additional < MIN_FREE_BYTES:
        raise ValueError("Preparation must leave at least 1 GiB free")


def get_metadata(directory):
    target = directory / "metadata"
    target.mkdir(exist_ok=True)
    for source, expected in METADATA.items():
        path = target / PurePosixPath(source).name
        if not path.exists():
            with urllib.request.urlopen(BASE + source, timeout=60) as response:
                data = response.read(1_000_001)
            if len(data) > 1_000_000 or hashlib.sha256(data).hexdigest() != expected:
                raise ValueError(f"Metadata checksum mismatch: {source}")
            with path.open("xb") as output:
                output.write(data)
        if digest(path) != expected:
            raise ValueError(f"Metadata checksum mismatch: {path}")
    return parse_tsv((target / "test.tsv").read_bytes())


class HashingReader:
    def __init__(self, stream, expected_bytes):
        self.stream, self.expected_bytes = stream, expected_bytes
        self.hash = hashlib.sha256()
        self.count = 0

    def read(self, size=-1):
        data = self.stream.read(min(size, 1024 * 1024) if size >= 0 else 1024 * 1024)
        self.count += len(data)
        if self.count > self.expected_bytes:
            raise ValueError("The archive exceeds its pinned size")
        self.hash.update(data)
        return data


def wav_info(path):
    """Read RIFF metadata only; the production AVAudioFile reader validates decoding."""
    with path.open("rb") as source:
        header = source.read(12)
        if len(header) != 12 or header[:4] != b"RIFF" or header[8:] != b"WAVE":
            raise ValueError("Expected RIFF WAVE")
        if struct.unpack("<I", header[4:8])[0] + 8 != path.stat().st_size:
            raise ValueError("RIFF length mismatch")
        fmt, audio_bytes = None, None
        while chunk := source.read(8):
            if len(chunk) != 8:
                raise ValueError("Truncated RIFF header")
            kind, size = struct.unpack("<4sI", chunk)
            if source.tell() + size > path.stat().st_size:
                raise ValueError("Truncated RIFF chunk")
            if kind == b"fmt ":
                if size > 1024:
                    raise ValueError("Invalid RIFF format chunk")
                fmt = source.read(size)
            else:
                if kind == b"data":
                    if audio_bytes is not None:
                        raise ValueError("Multiple data chunks")
                    audio_bytes = size
                source.seek(size, 1)
            source.seek(size % 2, 1)
        if fmt is None or len(fmt) < 16 or audio_bytes is None:
            raise ValueError("Missing RIFF format or data")
        tag, channels, rate, _, align, bits = struct.unpack("<HHIIHH", fmt[:16])
        if tag == 65534 and len(fmt) >= 40:
            tag = struct.unpack("<H", fmt[24:26])[0]
        if (tag, bits) not in {(1, 16), (3, 32)} or channels != 1 or rate != RATE:
            raise ValueError("Unexpected FLEURS WAV format")
        if align != channels * bits // 8 or audio_bytes % align:
            raise ValueError("Invalid WAV frame alignment")
        return {"frames": audio_bytes // align, "codec": "pcmInt16" if tag == 1 else "pcmFloat32"}


def validate_manifest(manifest, selection):
    if manifest.get("status") != "prepared":
        raise ValueError("The corpus is not prepared")
    for key, expected in selection.items():
        if key != "items" and manifest.get(key) != expected:
            raise ValueError(f"Prepared provenance differs from selection: {key}")
    if len(manifest["items"]) != len(selection["items"]):
        raise ValueError("Prepared item count differs from selection")
    for prepared, expected in zip(manifest["items"], selection["items"], strict=True):
        if any(prepared.get(key) != value for key, value in expected.items()):
            raise ValueError("Prepared reference or identity differs from the frozen selection")


def extract_selected(stream, archive, selected, directory):
    audio = directory / "audio"
    audio.mkdir(exist_ok=True)
    wanted = {item["filename"]: item for item in selected}
    found = {}
    reader = HashingReader(stream, archive["byteCount"])
    with tarfile.open(fileobj=reader, mode="r|gz") as source:
        for member in source:
            name = PurePosixPath(member.name)
            if name.name not in wanted:
                continue
            if name.is_absolute() or ".." in name.parts or not member.isfile() or member.issym() or member.islnk():
                raise ValueError("Unsafe selected archive member")
            if name.name in found or not 0 < member.size <= 16 * 1024 * 1024:
                raise ValueError("Duplicate or oversized selected archive member")
            check_space(directory, member.size)
            path = audio / name.name
            partial = path.with_suffix(".part")
            try:
                with source.extractfile(member) as incoming, partial.open("wb") as output:
                    shutil.copyfileobj(incoming, output, length=64 * 1024)
                info = wav_info(partial)
                if info["frames"] != wanted[name.name]["frames"]:
                    raise ValueError(f"WAV frames differ from TSV: {name.name}")
                actual = digest(partial)
                if path.exists() and digest(path) != actual:
                    raise ValueError(f"Existing audio differs: {path}")
                partial.replace(path)
            finally:
                partial.unlink(missing_ok=True)
            found[name.name] = {**wanted[name.name], **info, "sha256": actual,
                                "byteCount": member.size, "archiveMember": member.name}
            if len(found) % 25 == 0:
                print(f"Prepared {len(found)}/{len(wanted)} utterances", flush=True)
    while reader.read(1024 * 1024):
        pass
    if reader.count != archive["byteCount"] or reader.hash.hexdigest() != archive["sha256"]:
        raise ValueError("Full archive checksum mismatch; no prepared manifest was published")
    if found.keys() != wanted.keys():
        raise ValueError(f"Archive is missing {len(wanted.keys() - found.keys())} selected files")
    return [found[item["filename"]] for item in selected]


def prepare(directory, plan_only=False):
    directory.mkdir(parents=True, exist_ok=True)
    check_space(directory)
    selected = select(get_metadata(directory))
    plan = dict(schemaVersion=1, dataset="google/fleurs", config="cmn_hans_cn", split="test",
                revision=REVISION, seed=SEED, sampleRate=RATE, license="CC-BY-4.0",
                attribution="Google FLEURS; Conneau et al., 2022, https://arxiv.org/abs/2205.12446",
                archive=ARCHIVE, metadataSHA256=METADATA, selectionStats=statistics(selected),
                annotationStatus="reference_text_available; human_speech_intervals_pending",
                items=selected)
    write_json(directory / "selection.json", plan)
    if plan_only:
        print(json.dumps(plan["selectionStats"], ensure_ascii=False, indent=2))
        return
    path = directory / "manifest.json"
    if path.exists():
        manifest = json.loads(path.read_text())
        validate_manifest(manifest, plan)
        if manifest["selectionSHA256"] != digest(directory / "selection.json"):
            raise ValueError("Prepared manifest belongs to a different selection")
        for item in manifest["items"]:
            if digest(directory / "audio" / item["filename"]) != item["sha256"]:
                raise ValueError(f"Prepared audio checksum mismatch: {item['filename']}")
        print(f"Verified {len(manifest['items'])} prepared utterances")
        return
    with urllib.request.urlopen(ARCHIVE["url"], timeout=120) as response:
        prepared = extract_selected(response, ARCHIVE, selected, directory)
    manifest = {**plan, "status": "prepared", "selectionSHA256": digest(directory / "selection.json"),
                "items": prepared}
    write_json(path, manifest)
    print(f"Prepared {len(prepared)} distinct utterances; manifest SHA256: {digest(path)}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path, help="An ignored Models/Quality or tmp_agent_output directory")
    parser.add_argument("--plan-only", action="store_true", help="Fetch metadata and freeze the selection without audio")
    args = parser.parse_args()
    prepare(args.destination.resolve(), args.plan_only)
