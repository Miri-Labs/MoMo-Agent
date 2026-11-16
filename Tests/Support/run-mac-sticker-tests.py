"""Compile the production artwork cache and check display framing without an app or user data."""
import argparse
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
source = (root / 'Apps/ClientUI/LifeIllustrationView.swift').read_text()
cache = source.split('\nextension LifeIllustration {', 1)[0].replace('import MoMoAgentClient\n', '')
(output / 'ProductionArtworkCache.swift').write_text(cache)
binary = output / 'MacStickerArtworkTests'
subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6',
                str(output / 'ProductionArtworkCache.swift'),
                str(root / 'Tests/Support/MacStickerArtworkTests.swift'), '-o', str(binary)], check=True)
subprocess.run([str(binary)], check=True)
