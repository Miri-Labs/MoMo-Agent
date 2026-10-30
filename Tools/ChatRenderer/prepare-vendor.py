"""Pin offline Markdown dependencies; download only with --download, otherwise verify."""
import argparse
import base64
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
DEST = ROOT / "Apps/iPhoneApp/Features/Assistant/Rendering/Web/vendor"
PACKAGES = {
    "marked": ("18.1.1", "zEGgrtUG8crk+TrMacJSVABU4DYDDkS8uqgU3ohrn/2fW9C2AEfUrO3m6IhpIpQpl7YcVpiXXC9cSMWDANT3dg==", {"lib/marked.umd.js": "marked.js"}),
    "dompurify": ("3.4.17", "B/pSlYVHQ58kqISD/yDjuJ1yfzI34m1gF4lAod2bwSRhiN4K5Cl3H8Af7hqB2PmTL911tdEudnnXn5FnhRoz0w==", {"dist/purify.min.js": "purify.js"}),
    "katex": ("0.19.0", "v6Tznz3zJ7u3niRCoDTsumM2+HA2XXcCu+WAacCeHD2z3p9A9Ks987o5FzfTGBN0e8A0vjEgIDvLbICrXpdw/Q==", {"dist/katex.min.js": "katex.js", "dist/katex.min.css": "katex.css"}),
    "remend": ("1.4.0", "mHiYhhwphs1IgIZmkToKLwJn0U99IjPXuutkA2acrNcG0vlEq2G4TGnd2eT0saIHwh2KjaCpvleHcsd5SAz96A==", {"dist/index.js": "remend.js"}),
    "@highlightjs/cdn-assets": ("11.12.0", "KvOKXODaiFmId9xaq3xc5xCL66wVLUuOngDbO9B/kewbFTqdGbn2nJxNhN3H5R1cgDTVj6R8vH0zgiNDEGjpDw==", {"highlight.min.js": "highlight.js"}),
}


def download():
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    manifest = {"packages": {}, "files": {}}
    DEST.mkdir(parents=True, exist_ok=True)
    for name, (version, integrity, paths) in PACKAGES.items():
        url = f"https://registry.npmjs.org/{name}/-/{name.split('/')[-1]}-{version}.tgz"
        payload = opener.open(url, timeout=45).read()
        assert base64.b64encode(hashlib.sha512(payload).digest()).decode() == integrity, name
        archive = tarfile.open(fileobj=io.BytesIO(payload))
        selected = {**paths, "LICENSE": f"licenses/{name.replace('/', '-').replace('@', '')}.txt"}
        if name == "dompurify": selected["LICENSE-MPL"] = "licenses/dompurify-MPL.txt"
        if name == "katex":
            selected.update({m.name.removeprefix("package/"): m.name.removeprefix("package/dist/")
                             for m in archive if m.isfile() and m.name.startswith("package/dist/fonts/") and m.name.endswith(".woff2")})
        for source, destination in selected.items():
            data = archive.extractfile("package/" + source).read()
            if name == "remend" and destination == "remend.js":
                text = data.decode()
                match = re.search(r"export\{([^}]+)\};?\s*$", text)
                assert match, "remend export format changed"
                default = re.search(r"(\w+) as default(?:,|$)", match[1])
                assert default
                data = (text[:match.start()] + f"globalThis.remend={default[1]};\n").encode()
            target = DEST / destination
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            manifest["files"][destination] = hashlib.sha256(data).hexdigest()
        manifest["packages"][name] = {"version": version, "url": url, "sha512": integrity}
    (DEST / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


def verify():
    brand = ROOT / "Apps/iPhoneApp/Resources/Assets.xcassets/PhoneBrandIcon.imageset/momoagent-icon.png"
    assert (DEST.parent / "brand-thinking.png").read_bytes() == brand.read_bytes(), "Thinking mark must match the original brand asset"
    manifest = json.loads((DEST / "manifest.json").read_text())
    for name, (version, integrity, _) in PACKAGES.items():
        assert manifest["packages"][name]["version"] == version
        assert manifest["packages"][name]["sha512"] == integrity
    for path, digest in manifest["files"].items():
        assert hashlib.sha256((DEST / path).read_bytes()).hexdigest() == digest, path
    # The procedural Avatar has its own reproducible source build and license.
    subprocess.run(["node", ROOT / "Vendor/BibleStrongAvatar/build.mjs", "--check"], check=True)
    subprocess.run(["uv", "run", ROOT / "Tools/ChatRenderer/prepare-pebbles.py"], check=True)
    avatar_files = {"momoagent-avatar.js", "momoagent-avatar.LICENSE.txt"}
    assert {p.relative_to(DEST).as_posix() for p in DEST.rglob("*") if p.is_file()} == set(manifest["files"]) | {"manifest.json"} | avatar_files
    print(f"Verified {len(manifest['files'])} pinned renderer resources")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--download", action="store_true")
    if parser.parse_args().download: download()
    verify()
