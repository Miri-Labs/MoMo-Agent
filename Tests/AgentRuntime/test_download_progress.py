"""Real throttled uv download through the same PTY runner used by the product."""
import contextlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('download_progress', ROOT / 'Vendor/HermesAgent/pm/terminal_progress.py')
progress = importlib.util.module_from_spec(spec); spec.loader.exec_module(progress)


class DownloadProgressTests(unittest.TestCase):
    def test_real_uv_download_reports_bytes_before_exit(self):
        uv = os.environ.get('MOMO_PROGRESS_UV') or shutil.which('uv')
        self.assertIsNotNone(uv)
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            wheel = root / 'momo_progress_probe-1.0-py3-none-any.whl'
            with zipfile.ZipFile(wheel, 'w', compression=zipfile.ZIP_STORED) as archive:
                archive.writestr('momo_progress_probe/__init__.py', '')
                archive.writestr('momo_progress_probe/data.bin', os.urandom(2 * 1024 * 1024))
                archive.writestr('momo_progress_probe-1.0.dist-info/METADATA', 'Metadata-Version: 2.1\nName: momo-progress-probe\nVersion: 1.0\n')
                archive.writestr('momo_progress_probe-1.0.dist-info/WHEEL', 'Wheel-Version: 1.0\nGenerator: MoMo test\nRoot-Is-Purelib: true\nTag: py3-none-any\n')
                archive.writestr('momo_progress_probe-1.0.dist-info/RECORD', '')
            payload = wheel.read_bytes()

            class Handler(BaseHTTPRequestHandler):
                def do_HEAD(self):
                    self.send_response(200)
                    self.send_header('Content-Length', str(len(payload)))
                    self.send_header('Content-Type', 'application/octet-stream')
                    self.end_headers()
                def do_GET(self):
                    self.send_response(200)
                    self.send_header('Content-Length', str(len(payload)))
                    self.send_header('Content-Type', 'application/octet-stream')
                    self.end_headers()
                    try:
                        for offset in range(0, len(payload), 32768):
                            self.wfile.write(payload[offset:offset + 32768]); self.wfile.flush(); time.sleep(.04)
                    except (BrokenPipeError, ConnectionResetError): pass
                def log_message(self, *args): pass

            server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
            output = io.StringIO()
            try:
                with contextlib.redirect_stderr(output):
                    result = progress.run_with_progress([uv, 'pip', 'install', '--python', sys.executable,
                        '--target', str(root / 'site'), '--cache-dir', str(root / 'cache'), '--no-deps',
                        f'http://127.0.0.1:{server.server_port}/{wheel.name}'], timeout=30)
            finally:
                server.shutdown(); server.server_close(); thread.join()
            self.assertEqual(result.returncode, 0, result.stderr)
            raw = output.getvalue()
            self.assertRegex(raw, r'(?:KiB|MiB)\s*/\s*')
            self.assertGreater(raw.count('MiB'), 2)
            evidence = os.environ.get('MOMO_PROGRESS_EVIDENCE')
            if evidence: Path(evidence).write_text(raw)
            self.assertTrue((root / 'site/momo_progress_probe').is_dir())

    def test_process_failure_and_timeout_are_preserved(self):
        with contextlib.redirect_stderr(io.StringIO()):
            result = progress.run_with_progress([sys.executable, '-c', 'raise SystemExit(7)'], timeout=5)
            self.assertEqual(result.returncode, 7)
            with self.assertRaises(subprocess.TimeoutExpired):
                progress.run_with_progress([sys.executable, '-c', 'import time; time.sleep(30)'], timeout=.2)


if __name__ == '__main__': unittest.main()
