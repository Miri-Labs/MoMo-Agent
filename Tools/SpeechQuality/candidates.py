"""Freeze negative/overlap candidates. Human listening and interval labels remain pending."""

import argparse
import csv
import hashlib
import io
import json
from pathlib import Path
import re
import urllib.request

from corpus import BASE, check_space, digest, parse_tsv, select, write_json

ESC_REVISION = "33c8ce9eb2cf0b1c2f8bcf322eb349b6be34dbb6"
ESC_BASE = f"https://raw.githubusercontent.com/karolpiczak/ESC-50/{ESC_REVISION}/"
ENVIRONMENT_CLASSES = {"rain", "sea_waves", "crackling_fire", "clock_tick", "helicopter", "chainsaw"}


def metadata(url, expected, destination):
    if destination.exists():
        data = destination.read_bytes()
    else:
        with urllib.request.urlopen(url, timeout=60) as response:
            data = response.read(1_000_001)
        if len(data) > 1_000_000 or hashlib.sha256(data).hexdigest() != expected:
            raise ValueError(f"Candidate metadata checksum mismatch: {url}")
        destination.write_bytes(data)
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError(f"Candidate metadata checksum mismatch: {destination}")
    return data


def plan(directory):
    directory.mkdir(parents=True, exist_ok=True)
    check_space(directory)
    source_dir = directory / "metadata"
    source_dir.mkdir(exist_ok=True)
    csv_data = metadata(ESC_BASE + "meta/esc50.csv",
        "ca660da60191a97de289983a05821c9382d852a38a2ba8428980816b68cf6246", source_dir / "esc50.csv")
    license_data = metadata(ESC_BASE + "LICENSE",
        "f6aec3a3283a2efdcbb1feff334adad7ab17c097bdec0cbb4eebdb9e16886074", source_dir / "ESC-LICENSE")
    licenses = {}
    for line in license_data.decode().splitlines():
        match = re.search(r"\[([^\]]+)\.ogg\].*\[([^\]]+)\]\s*$", line)
        if match:
            licenses[match[1]] = (match[2], line)
    environment = []
    for row in csv.DictReader(io.StringIO(csv_data.decode())):
        if row["esc10"] != "True" or row["category"] not in ENVIRONMENT_CLASSES:
            continue
        license_name, attribution = licenses[row["filename"].rsplit("-", 1)[0]]
        if license_name not in {"CC0", "CC-BY"}:
            raise ValueError("Unexpected source license in the environmental subset")
        environment.append(dict(id=row["filename"], filename=row["filename"], category=row["category"],
            url=ESC_BASE + "audio/" + row["filename"], byteCount=441_044, durationSeconds=5,
            datasetLicense="CC-BY-3.0", sourceLicenseLabel=license_name, attribution=attribution,
            srcFile=row["src_file"], fold=int(row["fold"]), sha256=None))
    if len(environment) != 240:
        raise ValueError("The pinned ESC-10 subset must contain 240 files")
    dev = metadata(BASE + "data/cmn_hans_cn/dev.tsv",
        "6b4efd804b543048feb278db06f3b58b5ea171cdd4ba072e328ad630ca25384b", source_dir / "dev.tsv")
    overlap_sources = select(parse_tsv(dev), seconds_per_gender=300)
    music_data = metadata("https://incompetech.com/music/royalty-free/pieces.json",
        "54802ad340562624b9d1c9c97aa9f005e2b9bf79001f8a1a07ed857e68b2164a", source_dir / "music-catalog.json")
    catalog = {item["title"]: item for item in json.loads(music_data)}
    music = []
    for title, filename, size, end in [("Cipher", "Cipher2.mp3", 9_252_699, 180),
                                        ("Sneaky Snitch", "Sneaky Snitch.mp3", 5_466_943, 120)]:
        entry = catalog[title]
        if entry["filename"] != filename:
            raise ValueError("Music filename differs from the pinned catalog")
        music.append(dict(id=entry["isrc"], filename=filename,
            url="https://incompetech.com/music/royalty-free/mp3-royaltyfree/" + filename.replace(" ", "%20"),
            byteCount=size, cropStartSeconds=0, cropEndSeconds=end, license="CC-BY-4.0",
            attribution=f'"{title}" Kevin MacLeod (incompetech.com), CC BY 4.0; crop and resampling must be recorded',
            licenseSource="https://static.incompetech.com/music/royalty-free/music.html",
            catalogEntry=entry, sha256=None, contentPinStatus="freeze_on_first_download"))
    result = dict(schemaVersion=1, status="candidates_only", humanListening="pending",
        humanSpeechIntervals="pending", referenceText=None, vadMissRate=None,
        environment=dict(revision=ESC_REVISION, durationSeconds=1200, items=environment),
        music=dict(durationSeconds=300, items=music),
        overlap=dict(status="source_selection_only; mixing_and_human_intervals_pending", durationSeconds=300,
            sourceDurationSeconds=600, sourceLicense="CC-BY-4.0", sourceItems=overlap_sources,
            archiveURL=BASE + "data/cmn_hans_cn/audio/dev.tar.gz",
            archiveSHA256="3bc33212d5974eef7feb04bc4792458d6cd7e14ff10a1a24772f3c45ea87a822",
            archiveByteCount=217_347_747,
            recipe="Separate distinct female and male utterances into two 300s tracks; record gains and offsets; annotate audible intervals before calculating overlap"),
        uncovered=["television dialogue", "vocal music", "natural conversational overlap", "wrist microphone and movement"])
    write_json(directory / "candidates.json", result)
    return result


def fetch(directory, candidates):
    prepared_path = directory / "downloaded.json"
    if prepared_path.exists():
        previous = json.loads(prepared_path.read_text())
        if previous["candidateSHA256"] != digest(directory / "candidates.json"):
            raise ValueError("Candidate selection changed")
        for item in previous["items"]:
            if digest(directory / "audio" / item["filename"]) != item["sha256"]:
                raise ValueError("Downloaded candidate checksum mismatch")
        return
    audio = directory / "audio"
    audio.mkdir(exist_ok=True)
    prepared = []
    for item in candidates["environment"]["items"] + candidates["music"]["items"]:
        check_space(directory, item["byteCount"])
        path = audio / item["filename"]
        partial = path.with_suffix(".part")
        try:
            with urllib.request.urlopen(item["url"], timeout=120) as response, partial.open("wb") as output:
                count = 0
                while block := response.read(64 * 1024):
                    count += len(block)
                    if count > item["byteCount"]:
                        raise ValueError("Candidate exceeds its recorded size")
                    output.write(block)
            if count != item["byteCount"]:
                raise ValueError("Candidate size changed")
            actual = digest(partial)
            if path.exists() and digest(path) != actual:
                raise ValueError("Existing candidate differs; use a new version")
            partial.replace(path)
            prepared.append({**item, "sha256": actual})
        finally:
            partial.unlink(missing_ok=True)
    write_json(prepared_path, dict(status="downloaded_but_unreviewed", humanListening="pending",
        humanSpeechIntervals="pending", candidateSHA256=digest(directory / "candidates.json"), items=prepared))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--fetch-environment-and-music", action="store_true",
                        help="Download about 115 MiB of unreviewed candidates; no overlap audio is generated")
    args = parser.parse_args()
    root = args.destination.resolve()
    selected = plan(root)
    if args.fetch_environment_and_music:
        fetch(root, selected)
    print("Candidate manifest prepared. Human listening and speech intervals remain pending.")
