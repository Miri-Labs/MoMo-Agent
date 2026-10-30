"""Print a source digest that includes uncommitted benchmark and SpeechEngine changes."""

import hashlib
from pathlib import Path

root = Path(__file__).resolve().parents[2]
package = root / "Packages/MoMoAgentKit"
tool = root / "Tools/SpeechQuality"
files = [package / "Package.swift", tool / "Package.swift"]
for directory in [package / "Sources/MoMoSpeech", package / "Sources/MoMoContracts", tool / "Sources"]:
    files.extend(directory.rglob("*.swift"))
files.extend(tool.glob("*.py"))
for path in [package / "Package.resolved", tool / "Package.resolved"]:
    if path.exists():
        files.append(path)
identity = hashlib.sha256()
for path in sorted(files):
    identity.update(str(path.relative_to(root)).encode() + b"\0")
    identity.update(hashlib.sha256(path.read_bytes()).digest())
print("sha256:" + identity.hexdigest())
