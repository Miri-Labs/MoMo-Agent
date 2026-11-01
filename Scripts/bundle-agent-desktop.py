#!/usr/bin/env python3
"""Pin, verify and embed agent-desktop's native FFI. No end-user download or Node dependency."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / 'Vendor/AgentDesktop'


def verified_archive(cache, name, digest, version):
    archive = cache / name
    if not archive.exists():
        cache.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=cache, delete=False) as download:
            temporary = Path(download.name)
            try:
                with urllib.request.urlopen(f'https://github.com/vercel-labs/agent-desktop/releases/download/{version}/{name}', timeout=60) as response:
                    shutil.copyfileobj(response, download)
                download.close()
                if hashlib.sha256(temporary.read_bytes()).hexdigest() != digest:
                    raise ValueError('agent-desktop archive checksum mismatch')
                temporary.replace(archive)
            finally:
                temporary.unlink(missing_ok=True)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
        raise ValueError(f'agent-desktop cache checksum mismatch: {archive}')
    return archive


def bundle(destination, architectures, cache, identity=None):
    manifest = json.loads((VENDOR / 'UPSTREAM.json').read_text())
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='momo-agent-desktop-') as staging:
        libraries = []
        for arch in dict.fromkeys(architectures):
            spec = manifest['archives'][arch]
            stem = f"agent-desktop-ffi-{manifest['version']}-{spec['target']}"
            archive = verified_archive(cache, stem + '.tar.gz', spec['sha256'], manifest['version'])
            with tarfile.open(archive) as package:
                package.extractall(staging, filter='data')
            source = Path(staging) / stem
            if (source / 'include/agent_desktop.h').read_bytes() != (VENDOR / 'agent_desktop.h').read_bytes():
                raise ValueError('agent-desktop release ABI header differs from the checked-in header')
            libraries.append(source / 'lib')
        for name in ('libagent_desktop_ffi.dylib', 'agent-desktop-macos-helper'):
            output = destination / name
            if len(libraries) == 1:
                shutil.copy2(libraries[0] / name, output)
            else:
                subprocess.run(['lipo', '-create', *(str(lib / name) for lib in libraries), '-output', str(output)], check=True)
            if identity:
                subprocess.run(['codesign', '--force', '--sign', identity, str(output)], check=True)
        for name in ('LICENSE', 'UPSTREAM.json'):
            shutil.copy2(VENDOR / name, destination / name)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', type=Path, default=Path(os.environ.get('TARGET_BUILD_DIR', '.')) / os.environ.get('UNLOCALIZED_RESOURCES_FOLDER_PATH', '.') / 'AgentDesktop')
    parser.add_argument('--archs', nargs='+', default=os.environ.get('ARCHS', 'arm64').split())
    parser.add_argument('--cache', type=Path, default=VENDOR / 'Cache')
    args = parser.parse_args()
    identity = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') if os.environ.get('CODE_SIGNING_ALLOWED') != 'NO' else None
    bundle(args.destination, args.archs, args.cache, identity)
