# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = []
# ///
"""Prepare the pinned SenseVoice ONNX, Silero VAD, and speaker recognition/segmentation bundle."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

RELEASE = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/'
MODEL = 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17'
ARCHIVE_SHA = '7d1efa2138a65b0b488df37f8b89e3d91a60676e416f515b952358d83dfd347e'
VAD_URL = 'https://raw.githubusercontent.com/snakers4/silero-vad/v6.2.3/src/silero_vad/data/silero_vad.onnx'
ROOT = Path(__file__).resolve().parent


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def download(url, destination, expected):
    subprocess.run(['curl', '--fail', '--location', '--http1.1', '--show-error', '--connect-timeout', '30',
                    '--max-time', '1800', '--retry', '2', '--retry-all-errors', '--output', str(destination), url], check=True)
    if digest(destination) != expected:
        raise ValueError(f'Checksum mismatch: {destination.name}')


def prepare(destination, scratch_directory):
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    speakers = json.loads((ROOT / 'speaker-manifest.json').read_text())
    hashes = {'model.int8.onnx': manifest['asrSHA256'], 'tokens.txt': manifest['tokensSHA256'],
              'silero_vad.onnx': manifest['vadSHA256']}
    destination.mkdir(parents=True, exist_ok=True)
    speakers_destination = destination / 'Speakers'
    speakers_destination.mkdir(parents=True, exist_ok=True)
    scratch_directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='speech-download-', dir=scratch_directory) as scratch:
        scratch = Path(scratch)
        if any(not (destination / name).exists() or digest(destination / name) != hashes[name]
               for name in ['model.int8.onnx', 'tokens.txt']):
            archive = scratch / (MODEL + '.tar.bz2')
            download(RELEASE + archive.name, archive, ARCHIVE_SHA)
            with tarfile.open(archive, 'r:bz2') as source:
                for name in ['model.int8.onnx', 'tokens.txt', 'LICENSE']:
                    member = source.getmember(MODEL + '/' + name)
                    if not member.isfile():
                        raise ValueError(f'Expected regular file: {name}')
                    target = scratch / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with source.extractfile(member) as stream, target.open('wb') as output:
                        shutil.copyfileobj(stream, output)
                    if name in hashes and digest(target) != hashes[name]:
                        raise ValueError(f'Checksum mismatch: {name}')
                    (destination / name).parent.mkdir(parents=True, exist_ok=True)
                    target.replace(destination / name)
        if not (destination / 'silero_vad.onnx').exists() or digest(destination / 'silero_vad.onnx') != hashes['silero_vad.onnx']:
            vad = scratch / 'silero_vad.onnx'
            download(VAD_URL, vad, hashes[vad.name])
            vad.replace(destination / vad.name)
        for name, expected in speakers['files'].items():
            target = speakers_destination / name
            if not target.exists() or digest(target) != expected:
                staged = scratch / name
                download(speakers['sources'][name]['url'], staged, expected)
                staged.replace(target)
        for name, expected in hashes.items():
            if digest(destination / name) != expected:
                raise ValueError(f'Checksum mismatch: {name}')
        for name, expected in speakers['files'].items():
            if digest(speakers_destination / name) != expected:
                raise ValueError(f'Checksum mismatch: Speakers/{name}')
        shutil.copyfile(ROOT / 'manifest.json', scratch / 'manifest.json')
        (scratch / 'manifest.json').replace(destination / 'manifest.json')
        shutil.copytree(ROOT / 'Licenses', destination / 'Licenses', dirs_exist_ok=True)
    print(f'Verified SenseVoice INT8, Silero VAD, and speaker models: {destination}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path, help='Model directory, for example Models/Speech')
    parser.add_argument('--scratch-directory', required=True, type=Path, help='Task directory under tmp_agent_output')
    args = parser.parse_args()
    prepare(args.destination.resolve(), args.scratch_directory.resolve())
