"""Run production archive/client/date projections and sync tests without installing an app."""
import argparse
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
output = args.output.resolve()
if not output.is_relative_to(ROOT / 'tmp_agent_output'):
    raise ValueError('Test products must stay inside this worktree/tmp_agent_output')
probe = output / 'probe'
(probe / 'Sources').mkdir(parents=True, exist_ok=True)
(probe / 'Tests').mkdir(exist_ok=True)

def link(destination, source):
    if not destination.exists():
        destination.symlink_to(source)

for name in ['CSQLite', 'MoMoContracts', 'MoMoArchive', 'MoMoRecording', 'MoMoLink']:
    link(probe / 'Sources' / name, ROOT / 'Packages/MoMoAgentKit/Sources' / name)
for name in ['MoMoContractsTests', 'MoMoArchiveTests']:
    link(probe / 'Tests' / name, ROOT / 'Packages/MoMoAgentKit/Tests' / name)
link(probe / 'Sources/MoMoAgentClient', ROOT / 'Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient')
link(probe / 'Tests/MoMoAgentClientTests', ROOT / 'Packages/MoMoAgentAgentClient/Tests/MoMoAgentClientTests')

source = probe / 'Sources/DailyTranscriptProbe'
source.mkdir(exist_ok=True)
for name in ['PhoneContextSync.swift', 'PhoneRecordingSummaries.swift']:
    link(source / name, ROOT / 'Apps/iPhoneApp/Features/RemoteAgent' / name)
link(source / 'TimelineModel.swift', ROOT / 'Apps/iPhoneApp/Features/Library/TimelineModel.swift')
link(source / 'MarkdownDocument.swift', ROOT / 'Apps/ClientUI/MarkdownDocument.swift')

# Compile the actual Foundation portions of the UI files, without a fake model or an app host.
desktop = (ROOT / 'Apps/MacApp/Desktop/DesktopTranscripts.swift').read_text()
assert '\nstruct DesktopSources: View {' in desktop
(source / 'DesktopTranscriptSnapshot.swift').write_text(desktop.split('\nstruct DesktopSources: View {')[0])
presentation = (ROOT / 'Apps/iPhoneApp/Features/Library/TimelinePresentation.swift').read_text()
assert '\n@MainActor\nenum TimelinePresentation {' in presentation
(source / 'TimelineDate.swift').write_text(presentation.split('\n@MainActor\nenum TimelinePresentation {')[0])
memory = (ROOT / 'Apps/iPhoneApp/Features/RemoteAgent/RemoteMemoryView.swift').read_text()
assert '\nstruct MemoryPreview {' in memory
(source / 'MemoryPreview.swift').write_text('import Foundation\nstruct MemoryPreview {' + memory.split('\nstruct MemoryPreview {', 1)[1])
tests = probe / 'Tests/DailyTranscriptProbeTests'
tests.mkdir(exist_ok=True)
for path in [ROOT / 'Tests/iPhoneIntegrationTests/RemoteContextSyncTests.swift', ROOT / 'Tests/Support/DailyTranscriptProjectionTests.swift']:
    (tests / path.name).write_text(path.read_text().replace('@testable import MoMoAgent', '@testable import DailyTranscriptProbe'))

(probe / 'Package.swift').write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "DailyTranscriptProbe", defaultLocalization: "en", platforms: [.macOS(.v14)], targets: [
.systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
.target(name: "MoMoContracts", resources: [.process("Resources")]),
.target(name: "MoMoArchive", dependencies: ["MoMoContracts", "CSQLite"]),
.target(name: "MoMoRecording", dependencies: ["MoMoContracts", "CSQLite"]),
.target(name: "MoMoLink", dependencies: ["MoMoContracts"]),
.target(name: "MoMoAgentClient", resources: [.copy("Resources/RelayKit-LICENSE")]),
.target(name: "DailyTranscriptProbe", dependencies: ["MoMoContracts", "MoMoArchive", "MoMoAgentClient"]),
.testTarget(name: "MoMoContractsTests", dependencies: ["MoMoContracts"]),
.testTarget(name: "MoMoArchiveTests", dependencies: ["MoMoContracts", "MoMoArchive", "MoMoLink"]),
.testTarget(name: "MoMoAgentClientTests", dependencies: ["MoMoAgentClient"]),
.testTarget(name: "DailyTranscriptProbeTests", dependencies: ["DailyTranscriptProbe"])
])
''')
subprocess.run(['swift', 'test', '--package-path', str(probe), '--jobs', '2', '--filter',
    'Timeline|LifeIllustration|TranscriptReadingBoundary|DailyTranscriptProjection|RemoteContextSync'], check=True, cwd=ROOT)
