"""Real libwebrtc + two disposable embedded tailnets; no user profile or screen data.
Run with uv run python Tests/Support/run-desktop-rtc-smoke.py --webrtc <macOS framework parent>.
Requires the project's already-built TailscaleKit, cached WebRTC and installed Go/Swift.
"""
import argparse
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
args = argparse.ArgumentParser()
args.add_argument('--webrtc', type=Path, required=True)
args.add_argument('--capture', action='store_true', help='Only with an existing Screen Recording grant; never requests one')
options = args.parse_args()
webrtc = options.webrtc.resolve()
sdk = root / 'Vendor/TailscaleKit/Build/macos/Build/Products/Release'
out = root / 'tmp_agent_output/rtc'
out.mkdir(parents=True, exist_ok=True)
source = root / 'Packages/MoMoAgentAgentClient/Sources/MoMoAgentRTC'
subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', str(source/'DesktopSDP.swift'), str(root/'Tests/Support/desktop-sdp-check.swift'), '-o', str(out/'sdp-check')], check=True, cwd=root)
subprocess.run([str(out/'sdp-check')], check=True, cwd=root)
subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', str(source/'DesktopSDP.swift'), str(source/'DesktopRTC.swift'), str(root/'Tests/Support/desktop-rtc-smoke.swift'), str(root/'Apps/MacApp/Desktop/DesktopVideoCapture.swift'), str(root/'Apps/MacApp/Desktop/DesktopScreenStream.swift'), '-F', str(sdk), '-framework', 'TailscaleKit', '-F', str(webrtc), '-framework', 'WebRTC', '-Xlinker', '-rpath', '-Xlinker', str(sdk), '-Xlinker', '-rpath', '-Xlinker', str(webrtc), '-o', str(out/'desktop-rtc-smoke')], check=True, cwd=root)
subprocess.run(['go', 'build', '-o', str(out/'testcontrol'), './tstestcontrol'], check=True, cwd=root/'Vendor/TailscaleKit')
with (out/'control.log').open('w') as control_log:
    server = subprocess.Popen([str(out/'testcontrol')], stdout=subprocess.PIPE, stderr=control_log, text=True)
    try:
        control = server.stdout.readline().strip()
        if not control.startswith('http://127.0.0.1:'): raise RuntimeError('Local control server not ready')
        with (out/('rtc-capture.log' if options.capture else 'rtc-smoke.log')).open('w') as log:
            result = subprocess.run([str(out/'desktop-rtc-smoke'), control] + (['--capture'] if options.capture else []), stdout=log, stderr=log, timeout=40, cwd=root)
        result.check_returncode()
    finally:
        server.terminate(); server.wait(timeout=10)
print('\n'.join(line for line in (out/('rtc-capture.log' if options.capture else 'rtc-smoke.log')).read_text().splitlines() if line.startswith('{')))
