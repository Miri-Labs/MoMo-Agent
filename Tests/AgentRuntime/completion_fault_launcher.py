"""Crash injection for synthetic real-Hermes smoke; never imported by the app."""
import importlib.util
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Apps/MacApp/Runtime'))
sys.path.insert(0, str(ROOT / 'Vendor/HermesAgent'))
import momo_agent

data, fault = Path(sys.argv[1]), sys.argv[2]
connection = momo_agent.read_connection(data)
os.environ.update(API_SERVER_ENABLED='true', API_SERVER_HOST='127.0.0.1', API_SERVER_PORT=str(connection['port']),
    API_SERVER_KEY=(data / 'api-key').read_text().strip())
os.chdir(data / 'workspace')
marker = data / 'runtime/fault-fired'
if not marker.exists():
    if fault == 'receipt':
        from personal_agent import PersonalAgent
        original = PersonalAgent.completion
        async def completion(self, *args):
            result = await original(self, *args)
            if result is True and args[2].get('type') == 'async_delegation':
                marker.touch(); os._exit(81)
            return result
        PersonalAgent.completion = completion
    elif fault == 'admission':
        import gateway.session_api_completion as seam
        original = seam.admit_api_completion
        async def admit(adapter, receipt):
            from gateway.session_authorities import require_active_authority
            authority = require_active_authority(adapter.gateway_runner)
            schedule = authority._schedule
            authority._schedule = lambda _: None
            try: row = await original(adapter, receipt)
            finally: authority._schedule = schedule
            marker.touch(); os._exit(82)
        seam.admit_api_completion = admit
momo_agent.gateway(data)
