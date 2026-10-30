"""Run the phone's Foundation-only sync/cache tests on macOS, without booting an iPhone."""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='momo-recording-summary-') as directory:
    probe = Path(directory)
    source = probe / 'Sources/RemoteSummaryProbe'; source.mkdir(parents=True)
    tests = probe / 'Tests/RemoteSummaryProbeTests'; tests.mkdir(parents=True)
    for name in ['PhoneContextSync.swift', 'PhoneRecordingSummaries.swift']:
        (source / name).symlink_to(ROOT / 'Apps/iPhoneApp/Features/RemoteAgent' / name)
    (probe / 'Sources/MoMoAgentClient').symlink_to(ROOT / 'Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient')
    (tests / 'RemoteContextSyncTests.swift').write_text(
        (ROOT / 'Tests/iPhoneIntegrationTests/RemoteContextSyncTests.swift').read_text()
        .replace('@testable import MoMoAgent', '@testable import RemoteSummaryProbe'))
    manifest = '''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "RemoteSummaryProbe", platforms: [.macOS(.v14)], dependencies: [
.package(path: ARCHIVE_PATH)], targets: [
.target(name: "MoMoAgentClient"),
.target(name: "RemoteSummaryProbe", dependencies: [.product(name: "MoMoArchive", package: "MoMoAgentKit"), "MoMoAgentClient"]),
.testTarget(name: "RemoteSummaryProbeTests", dependencies: ["RemoteSummaryProbe", .product(name: "MoMoContracts", package: "MoMoAgentKit")])])
'''
    (probe / 'Package.swift').write_text(manifest.replace('ARCHIVE_PATH', json.dumps(str(ROOT / 'Packages/MoMoAgentKit'))))
    subprocess.run(['swift', 'test', '--package-path', str(probe), '--jobs', '2'], check=True)
