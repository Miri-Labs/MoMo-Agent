"""Real Hermes -> production source MCP -> synthetic, authenticated phone health upload."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import urllib.request
import uuid
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT/'Apps/MacApp/Runtime'), str(ROOT/'Apps/MacApp/Context'), str(ROOT/'Vendor/HermesAgent')]


def main(output):
    captures = []
    class Model(BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            if 'messages' not in body:
                raw = b'{"error":{"message":"Fixture supports chat completions only"}}'
                self.send_response(400); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(raw)))
                self.end_headers(); self.wfile.write(raw); return
            captures.append(body)
            results = [m for m in body['messages'] if m['role'] == 'tool']
            names = [t['function']['name'] for t in body.get('tools', [])]
            observed = any('Synthetic Watch' in str(m['content']) and 'heart_rate' in str(m['content']) and '65' in str(m['content']) for m in results)
            if observed:
                message = dict(role='assistant', content='HEALTH_SYNCED_65'); finish = 'stop'
            else:
                target = 'mcp__momo_context__read_health'
                if target in names: tool, args = target, {}
                elif not results: tool, args = 'tool_search', {'queries': [target], 'limit': 1}
                elif len(results) == 1: tool, args = 'tool_describe', {'names': [target]}
                else: tool, args = 'tool_call', {'calls': [{'name': target, 'arguments': {}}]}
                message = dict(role='assistant', content=None, tool_calls=[dict(id='health-'+str(len(captures)), type='function',
                    function=dict(name=tool, arguments=json.dumps(args)))])
                finish = 'tool_calls'
            result = dict(id='fixture', object='chat.completion', created=int(time.time()), model='health-fixture',
                          choices=[dict(index=0, message=message, finish_reason=finish)],
                          usage=dict(prompt_tokens=100, completion_tokens=30, total_tokens=130))
            raw = json.dumps(result).encode()
            self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(raw)))
            self.end_headers(); self.wfile.write(raw)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Model)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix='momo-health-hermes-') as temp:
        data = Path(temp)/'agent'
        import momo_agent
        momo_agent.initialize(data, 18765)
        os.environ.clear(); os.environ.update(momo_agent.child_environment(data))
        os.environ.update(HOME=temp, PATH=os.defpath, HERMES_HOME=str(data/'hermes'), HERMES_RUNTIME_DIR=str(data/'runtime/tools'),
                          TERMINAL_CWD=str(data/'workspace'), HERMES_DISABLE_TOOL_USE_ENFORCEMENT='1', PYTHONDONTWRITEBYTECODE='1')
        config = json.loads((data/'hermes/config.yaml').read_text())
        config['model'] = dict(provider='custom', default='health-fixture', streaming=False, base_url=f'http://127.0.0.1:{server.server_port}/v1')
        with patch.object(momo_agent, 'prepared_python', return_value=Path(sys.executable)):
            momo_agent.configure_context(data, config, None)
        from context_server import ContextService
        service = ContextService(data, dict(data_url='http://127.0.0.1:0', workspace_id=str(uuid.uuid4())))
        service.start()
        try:
            now = time.time()
            payload = dict(device_id=str(uuid.uuid4()), revision=1, state='enabled', observed_at=now,
                           window_start=now-86400, window_end=now, timezone='Asia/Shanghai', observations=[
                               dict(metric='heart_rate', unit='count/min', value=65, start=now-60, end=now-59,
                                    source_name='Synthetic Watch', source_bundle='fixture.health')])
            key = (data/'api-key').read_text().strip()
            req = urllib.request.Request(f'http://127.0.0.1:{service.server.server_port}/v1/health', data=json.dumps(payload).encode(),
                                         headers={'Authorization':'Bearer '+key})
            with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req) as response:
                assert json.load(response)['revision'] == 1
            from tools.mcp_tool_discovery import discover_mcp_tools
            discover_mcp_tools(allowed_mcp_names=['momo_context'])
            from run_agent import AIAgent
            agent = AIAgent(model='health-fixture', provider='custom', api_key='fixture-not-secret', base_url=config['model']['base_url'],
                            api_mode='chat_completions', platform='api_server', enabled_toolsets=['momo_context'], max_iterations=8,
                            skip_background_review=True, quiet_mode=True, session_id='momo-health-synthetic')
            answer = agent.run_conversation('HEALTH_SMOKE: 读取同步的最新心率，核对来源和时间。')
            assert 'HEALTH_SYNCED_65' in str(answer), str(answer)
            assert 'Synthetic Watch' not in json.dumps(captures[0], ensure_ascii=False), 'Health value leaked into initial prompt'
            observed = any(m['role']=='tool' and 'Synthetic Watch' in str(m.get('content')) for c in captures for m in c['messages'])
            assert observed, 'No production MCP result reached Hermes'
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(json.dumps(dict(passed=True, model='local scripted provider', health='synthetic',
                chain='authenticated source HTTP -> SQLite -> production MCP -> real Hermes', turns=len(captures),
                initial_prompt_without_health_values=True, phone_device_used=False), indent=2)+'\n')
            print('PASS: real Hermes read synchronized synthetic health through production MCP; initial prompt contains no health values')
        finally:
            service.close()
    server.shutdown(); server.server_close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--output', type=Path, required=True)
    main(parser.parse_args().output.resolve())
