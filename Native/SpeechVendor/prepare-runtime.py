# /// script
# requires-python = ">=3.12"
# ///
"""Prepare pinned sherpa Apple libraries before SwiftPM resolves local binary targets."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def matches(directory, expected):
    if not directory.is_dir() or directory.is_symlink():
        return False
    actual = {}
    for path in sorted(directory.rglob("*")):
        name = str(path.relative_to(directory))
        if path.is_symlink():
            actual[name] = {"link": str(path.readlink())}
        elif path.is_file():
            actual[name] = {"sha256": digest(path)}
    return actual == expected


def prepare(scratch, output):
    manifest = json.loads((ROOT / "runtime-manifest.json").read_text())
    scratch.mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True, exist_ok=True)
    for platform, artifact in manifest["platforms"].items():
        target = output / (platform + ".xcframework")
        if matches(target, artifact["files"]):
            print(f"Verified existing {platform} speech runtime")
            continue
        with tempfile.TemporaryDirectory(prefix="sherpa-runtime-", dir=scratch) as temp:
            temp = Path(temp)
            # gh uses the caller's repository credentials; no token enters source or logs.
            subprocess.run(["gh", "release", "download", manifest["release"],
                "--repo", manifest["repository"], "--pattern", artifact["asset"],
                "--dir", str(temp)], check=True)
            archive = temp / artifact["asset"]
            if digest(archive) != artifact["sha256"]:
                raise ValueError("Speech runtime archive checksum mismatch")
            subprocess.run(["ditto", "-xk", str(archive), str(temp / "extracted")], check=True)
            extracted = temp / "extracted" / target.name
            if not matches(extracted, artifact["files"]):
                raise ValueError("Speech runtime file inventory mismatch")
            # Keep the previous cache until the complete verified replacement exists.
            with tempfile.TemporaryDirectory(prefix=".sherpa-install-", dir=output) as install:
                install = Path(install)
                replacement = install / target.name
                shutil.copytree(extracted, replacement, symlinks=True)
                previous = install / "previous"
                if target.exists() or target.is_symlink():
                    target.rename(previous)
                try:
                    replacement.rename(target)
                except BaseException:
                    if previous.exists() or previous.is_symlink():
                        previous.rename(target)
                    raise
        print(f"Prepared {platform} speech runtime")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scratch-directory", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=ROOT.parents[1] / "Vendor/SherpaOnnx/Binaries")
    args = parser.parse_args()
    prepare(args.scratch_directory.resolve(), args.output.resolve())
