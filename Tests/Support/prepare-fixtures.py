"""Prepare the pinned public speech fixture for iOS and Mac tests. Run with uv run."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

METADATA = Path(__file__).resolve().with_name('SpeechFixtureMetadata.json')


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def prepare(destination, scratch_directory, source_wav):
    metadata = json.loads(METADATA.read_text())
    destination.mkdir(parents=True, exist_ok=True)
    scratch_directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='speech-fixture-', dir=scratch_directory) as scratch:
        scratch = Path(scratch)
        prepared = scratch / metadata['file']
        if source_wav is not None:
            if digest(source_wav) != metadata['sha256']:
                raise ValueError('The supplied WAV does not match the pinned official fixture')
            shutil.copyfile(source_wav, prepared)
        elif (destination / metadata['file']).is_file() and digest(destination / metadata['file']) == metadata['sha256']:
            shutil.copyfile(destination / metadata['file'], prepared)
        else:
            archive = scratch / 'official-model.tar.bz2'
            subprocess.run(['curl', '--fail', '--location', '--show-error', '--connect-timeout', '30',
                            '--max-time', '1800', '--retry', '2', '--output', str(archive),
                            metadata['sourceURL']], check=True)
            if digest(archive) != metadata['archiveSHA256']:
                raise ValueError('The official release archive checksum does not match')
            with tarfile.open(archive, 'r:bz2') as source:
                member = source.getmember(metadata['archiveMember'])
                if not member.isfile():
                    raise ValueError('The official fixture must be a regular file')
                with source.extractfile(member) as stream, prepared.open('wb') as output:
                    shutil.copyfileobj(stream, output)
        if digest(prepared) != metadata['sha256']:
            raise ValueError('The extracted WAV checksum does not match')
        prepared.replace(destination / metadata['file'])
        shutil.copyfile(METADATA, scratch / 'fixture.json')
        (scratch / 'fixture.json').replace(destination / 'fixture.json')
    print(f'Verified public Chinese speech fixture: {destination}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path, help='For example Models/TestFixtures')
    parser.add_argument('--scratch-directory', required=True, type=Path, help='Directory under tmp_agent_output')
    parser.add_argument('--source-wav', type=Path, help='Reuse an existing official test_wavs/zh.wav without downloading')
    args = parser.parse_args()
    prepare(args.destination.resolve(), args.scratch_directory.resolve(),
            args.source_wav.resolve() if args.source_wav is not None else None)
