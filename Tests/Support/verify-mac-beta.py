"""Reject temporary signing identities that invalidate macOS privacy grants on every build."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--app', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
info = plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())


def codesign(*options):
    return subprocess.run(['codesign', *options, str(args.app)], capture_output=True, text=True)


signature = codesign('--verify', '--deep', '--strict')
requirement = codesign('-dr', '-')
requirement_text = requirement.stdout + requirement.stderr
details = codesign('-dv', '--verbose=4')
checks = {
    'beta_identity': info.get('CFBundleIdentifier') == 'com.momoagent.mac.beta',
    'beta_display_name': info.get('CFBundleDisplayName') == 'MoMo Agent Beta',
    'signature_valid': signature.returncode == 0,
    'stable_requirement': requirement.returncode == 0 and 'anchor apple generic' in requirement_text and 'cdhash' not in requirement_text,
    'not_adhoc': details.returncode == 0 and 'Signature=adhoc' not in details.stderr and 'TeamIdentifier=not set' not in details.stderr,
    'local_network_purpose': bool(info.get('NSLocalNetworkUsageDescription')),
}
report = {'version': info.get('CFBundleShortVersionString'), 'build': info.get('CFBundleVersion'), 'checks': checks,
          'passed': all(checks.values()), 'not_checked': ['system_permission_grants', 'actual_screen_capture']}
args.output.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report))
raise SystemExit(0 if report['passed'] else 1)
