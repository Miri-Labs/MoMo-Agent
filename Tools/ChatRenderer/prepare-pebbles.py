"""Pack captured 2x Retina frames, or verify the bundled brand animation without a browser."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Tools/ChatRenderer/pebble-source.mjs"
WEB = ROOT / "Apps/iPhoneApp/Features/Assistant/Rendering/Web"
ATLAS = WEB / "brand-pebbles.webp"
STILL = WEB / "brand-pebbles-still.webp"
MANIFEST = SOURCE.with_name("pebble-manifest.json")
CONFIG = {"width": 64, "height": 56, "columns": 16, "frames": 174, "fps": 30}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def pack(frames):
    from PIL import Image

    atlas = Image.new("RGB", (1024, 616), (8, 8, 8))
    for index in range(CONFIG["frames"]):
        with Image.open(frames / f"{index:03}.png") as frame:
            assert frame.size == (CONFIG["width"], CONFIG["height"]), index
            atlas.paste(frame, ((index % 16) * 64, (index // 16) * 56))
            if index == 0:
                frame.convert("RGB").save(STILL, lossless=True, method=6)
    atlas.save(ATLAS, lossless=True, method=6)
    MANIFEST.write_text(json.dumps({**CONFIG, "sourceSHA256": digest(SOURCE), "atlasSHA256": digest(ATLAS), "stillSHA256": digest(STILL)}, indent=2) + "\n")


def verify():
    manifest = json.loads(MANIFEST.read_text())
    assert {key: manifest[key] for key in CONFIG} == CONFIG
    assert manifest["sourceSHA256"] == digest(SOURCE), "Regenerate the atlas after changing geometry or motion"
    assert manifest["atlasSHA256"] == digest(ATLAS), "Brand atlas changed without regeneration"
    assert manifest["stillSHA256"] == digest(STILL), "Brand still frame changed without regeneration"
    assert ATLAS.read_bytes()[:4] == b"RIFF" and ATLAS.read_bytes()[8:12] == b"WEBP"
    print(f"Verified brand pebble atlas: {CONFIG['frames']} frames, {ATLAS.stat().st_size:,} bytes")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--frames", type=Path, help="Directory containing 000.png through 173.png")
    args = parser.parse_args()
    if args.frames:
        pack(args.frames)
    verify()
