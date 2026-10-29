"""Real Hermes async delegation + MCP + Swift journal, with a scripted local model."""
import argparse
import importlib.util
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import socket
import shlex
import subprocess
import sys
import threading
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--data-dir', type=Path, required=True)
    parser.add_argument('--dependency-python', type=Path, required=True)
    parser.add_argument('--probe', type=Path)
    parser.add_argument('--steering', action='store_true')
    parser.add_argument('--fault', choices=['receipt','admission','started'])
    parser.add_argument('--legacy', choices=['unreported','consumed'])
    parser.add_argument('--controls', action='store_true')
    parser.add_argument('--interactions', action='store_true')
    parser.add_argument('--computer', action='store_true')
    parser.add_argument('--report-recovery', action='store_true')
    parser.add_argument('--background-controls', action='store_true')
    parser.add_argument('--hold-seconds', type=int, default=0, help='Keep the isolated model/runtime available after a successful interaction scenario')
    parser.add_argument('--process', action='store_true', help='Exercise real terminal background completion instead of delegation')
    parser.add_argument('--latency', action='store_true', help='Measure first-text overhead with a timed local model and real Hermes SSE')
    args = parser.parse_args()
    if args.process and (args.fault or args.legacy or args.controls or args.steering or args.probe):
        parser.error('--process is an isolated scenario')
    data = args.data_dir.resolve()
    if data.exists():
        raise ValueError('Use a fresh synthetic runtime directory')
    spec = importlib.util.spec_from_file_location('momo_test_runtime', ROOT / 'Apps/MacApp/Runtime/momo_agent.py')
    runtime = importlib.util.module_from_spec(spec); spec.loader.exec_module(runtime)
    # Keep both ports reserved while the fixture model chooses its ephemeral port.
    while True:
        first, second = socket.socket(), socket.socket()
        first.bind(('127.0.0.1', 0)); port = first.getsockname()[1]
        try: second.bind(('127.0.0.1', port + 1)); break
        except OSError: first.close(); second.close()
    runtime.initialize(data, port)
    (data / 'runtime/venv').symlink_to(args.dependency_python.absolute().parents[1], target_is_directory=True)
    runtime.write_private(data / 'runtime/prepared.json', json.dumps(runtime.fingerprint()))
    workspace = data / 'workspace'
    if args.process or args.report_recovery:
        (workspace / 'synthetic_background.py').write_text('''import os, time
from pathlib import Path
workspace = Path(__file__).parent
(workspace / 'im-worker-pid').write_text(str(os.getpid()))
(workspace / 'im-worker-started').touch()
deadline = time.monotonic() + 90
while not (workspace / 'im-worker-release').exists():
    if time.monotonic() > deadline: raise TimeoutError('Test gate was not released')
    time.sleep(.05)
with (workspace / 'im-worker-finished').open('a') as stream: stream.write('done\\n')
print('MOMO_BACKGROUND_DONE', flush=True)
''')
    if args.background_controls:
        from interaction_scenarios import prepare_background
        prepare_background(workspace)
    computer_server=computer_lease=None
    if args.computer:
        from computer_gate_scenario import prepare
        computer_server,computer_lease=prepare(data,args.dependency_python,ROOT)
    request_log = data / 'runtime/model-requests.jsonl'

    class Model(BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_GET(self):
            self.answer({'object': 'list', 'data': [{'id': 'momo-im-fixture', 'object': 'model'}]})
        def answer(self, value):
            if getattr(self, 'stream', False) and value.get('object') == 'chat.completion':
                choice = value['choices'][0]; delta = dict(choice['message'])
                for index, call in enumerate(delta.get('tool_calls', [])): call['index'] = index
                chunk = {**value, 'object': 'chat.completion.chunk', 'choices': [
                    {'index': 0, 'delta': delta, 'finish_reason': choice['finish_reason']}]}
                raw = ('data: ' + json.dumps(chunk) + '\n\ndata: [DONE]\n\n').encode()
                self.send_response(200); self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Content-Length', str(len(raw))); self.end_headers()
                self.wfile.write(raw); self.wfile.flush(); return
            raw = json.dumps(value).encode()
            self.send_response(200); self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw)
        def do_POST(self):
            model_started = time.monotonic_ns()
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            self.stream = body.get('stream') is True
            messages = body['messages']
            start = max(i for i, message in enumerate(messages) if message['role'] == 'user')
            prompt = str(messages[start]['content'])
            if 'MOMO_CURRENT_REQUEST_BEGIN\n' in prompt:
                prompt=prompt.rsplit('MOMO_CURRENT_REQUEST_BEGIN\n',1)[1].split('\nMOMO_CURRENT_REQUEST_END',1)[0]
            if args.latency and prompt == 'MOMO_TEST_TTFT':
                threading.Event().wait(.25)
                first_text = time.monotonic_ns()
                with (data / 'runtime/model-latency.jsonl').open('a') as stream:
                    stream.write(json.dumps({'start_ns': model_started, 'first_text_ns': first_text}) + '\n')
                self.answer({'id': 'synthetic-ttft', 'object': 'chat.completion', 'created': int(time.time()),
                    'model': 'momo-im-fixture', 'choices': [{'index': 0, 'message': {'role': 'assistant', 'content': 'MOMO_TTFT_OK'}, 'finish_reason': 'stop'}],
                    'usage': {'prompt_tokens': 10, 'completion_tokens': 5, 'total_tokens': 15}})
                return
            results = [message for message in messages[start:] if message['role'] == 'tool']
            names = [tool['function']['name'] for tool in body.get('tools', [])]
            target = None; arguments = {}; final = None
            if args.report_recovery and '后台执行的结果已保存' in prompt:
                raw=json.dumps({'error':{'type':'invalid_request_error','code':'synthetic_report_failure','message':'Synthetic provider failure'}}).encode()
                self.send_response(400);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw);return
            if args.report_recovery and prompt.startswith('仅恢复结果汇报'):
                if 'report_only' in str(results):final='REPORT_RECOVERED MOMO_BACKGROUND_DONE'
                else:target='terminal';arguments={'command':'touch '+shlex.quote(str(workspace/'MUST_NOT_EXECUTE'))}
            elif args.computer and prompt.startswith('GAP_COMPUTER') and names:
                from computer_gate_scenario import model
                target,arguments,final=model(prompt,results,messages[start:],data,computer_lease)
            elif args.background_controls and prompt.startswith(('GAP_PROCESS_','GAP_CHILD_','GAP_DELEGATE_')) and names:
                from interaction_scenarios import background_model
                target,arguments,final=background_model(prompt,results,messages,workspace,args.dependency_python)
            elif args.interactions and prompt.startswith(('GAP_', '好的，继续', '先停下刚才')) and names:
                from interaction_scenarios import model_reply
                target,arguments,final=model_reply(prompt,results,messages,workspace,args.dependency_python)
            elif not names or prompt == 'Reply OK.': final = 'OK'
            elif args.legacy == 'unreported' and prompt.startswith('[ASYNC DELEGATION BATCH COMPLETE'):
                # This migration case deliberately has no old consumer receipt or
                # completion report. Native injected evidence is not itself a report.
                final = '知道了，你周五去上海。'
            elif '后台执行的结果已保存' in prompt or '后台委派的结果已进入' in prompt or 'ASYNC DELEGATION BATCH COMPLETE' in prompt:
                if args.fault == 'started' and not (data / 'runtime/fault-fired').exists():
                    (data / 'runtime/fault-fired').touch()
                    while not (data / 'runtime/restarted').exists(): time.sleep(.1)
                final = '后台任务完成：MOMO_BACKGROUND_DONE' if 'MOMO_BACKGROUND_DONE' in str(messages) else 'COMPUTER_CHILD_REPORTED' if args.computer and 'CHILD_SCREEN_DONE' in str(messages) else '后台任务已停止' if args.background_controls else 'MISSING_NATIVE_RESULT'
            elif prompt.startswith('我周五去上海'): final = '知道了，你周五去上海。'
            elif 'MOMO_STEER_NOTE' in prompt: final = 'STEER_APPLIED'
            elif 'MOMO_TEST_CLARIFY' in prompt:
                if results: final = 'CLARIFY_DONE'
                else: target = 'clarify'; arguments = {'questions': [{'question': 'Choose the synthetic answer', 'choices': ['BLUE','GREEN']}]}
            elif prompt.startswith('MOMO_TEST_SYNC'):
                if 'MOMO_BACKGROUND_DONE' in str(results): final = 'SYNC_DONE'
                else: target = 'mcp__momo_slow__long_work'; arguments = {}
            elif prompt.startswith('MOMO_TEST_PROCESS'):
                if 'session_id' in str(results): final = '后台进程已启动，完成后告诉你。'
                else:
                    target = 'terminal'; arguments = {'command': shlex.join([str(args.dependency_python.absolute()), str(workspace / 'synthetic_background.py')]),
                        'background': True, 'notify_on_complete': True}
            elif 'MOMO_TEST_START_BACKGROUND' in prompt:
                if 'delegation_id' in str(results): final = '任务已交给后台，你可以继续聊。'
                else:
                    target = 'delegate_task'; arguments = {'goal': 'MOMO_TEST_WORKER: 调用 long_work 工具一次，完成后回复实际结果。', 'context': '使用 momo_slow 提供的 long_work 合成测试工具。'}
            elif 'MOMO_TEST_WORKER' in prompt:
                if 'MOMO_BACKGROUND_DONE' in str(results): final = 'MOMO_BACKGROUND_DONE'
                else: target = 'mcp__momo_slow__long_work'; arguments = {}
            else: final = 'FIXTURE_UNEXPECTED_PROMPT'
            if target:
                if target in names: name = target; params = arguments
                elif not results: name = 'tool_search'; params = {'queries': [target], 'limit': 3}
                elif len(results) == 1: name = 'tool_describe'; params = {'names': [target]}
                else: name = 'tool_call'; params = {'calls': [{'name': target, 'arguments': arguments}]}
                message = {'role': 'assistant', 'content': '我先整理资料，完成后告诉你。' if name in ('delegate_task', 'terminal') else None,
                    'tool_calls': [{'id': f'call-{time.time_ns()}', 'type': 'function',
                        'function': {'name': name, 'arguments': json.dumps(params)}}]}
                finish = 'tool_calls'
            else: message = {'role': 'assistant', 'content': final}; finish = 'stop'
            with request_log.open('a') as log:
                log.write(json.dumps({'prompt': prompt[:200], 'tools': names, 'result_count': len(results), 'target': target, 'final': final}) + '\n')
            self.answer({'id': f'fixture-{time.time_ns()}', 'object': 'chat.completion', 'created': int(time.time()),
                'model': 'momo-im-fixture', 'choices': [{'index': 0, 'message': message, 'finish_reason': finish}],
                'usage': {'prompt_tokens': 100, 'completion_tokens': 30, 'total_tokens': 130}})

    server = ThreadingHTTPServer(('127.0.0.1', 0), Model)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    config = {'model': {'provider': 'custom', 'default': 'momo-im-fixture', 'streaming': args.latency,
                       'base_url': f'http://127.0.0.1:{server.server_port}/v1', 'context_length': 128000},
              'agent': {'max_turns': 12}, 'updates': {'check': False},
              'memory': {'memory_enabled': False, 'user_profile_enabled': False},
              'platform_toolsets': {'api_server': ['delegation', 'momo_slow', 'clarify'] + (['terminal'] if args.process or args.report_recovery or args.interactions or args.background_controls else [])},
              'terminal': {'cwd': str(workspace)},
              'mcp_servers': {'momo_slow': {'command': str(args.dependency_python.absolute()),
                  'args': [str(ROOT / 'Tests/AgentRuntime/nonblocking_mcp_fixture.py')],
                  'env': {'MOMO_IM_FIXTURE_WORKSPACE': str(workspace)}}},
              'delegation': {'max_iterations': 12}}
    (data / 'hermes/config.yaml').write_text(json.dumps(config))
    (data / 'hermes/.env').write_text('OPENAI_API_KEY=synthetic-local-only\n')
    log = (data / 'runtime/gateway.log').open('w')
    first.close(); second.close()
    command = [sys.executable, str(ROOT / 'Apps/MacApp/Runtime/momo_agent.py'), 'serve', '--data-dir', str(data)]
    if args.fault in ('receipt','admission'):
        command = [str(args.dependency_python.absolute()), '-I', '-X', f"pycache_prefix={data / 'runtime/bytecode'}",
            str(ROOT / 'Tests/AgentRuntime/completion_fault_launcher.py'), str(data), args.fault]
    child = subprocess.Popen(command, env=runtime.child_environment(data), stdout=log, stderr=subprocess.STDOUT)
    try:
        request = urllib.request.Request(f'http://127.0.0.1:{port}/v1/capabilities',
            headers={'Authorization': 'Bearer ' + (data / 'api-key').read_text().strip()})
        for _ in range(90):
            if child.poll() is not None: raise RuntimeError('Synthetic gateway exited; inspect its log')
            try:
                with urllib.request.urlopen(request, timeout=2) as response: json.load(response)
                break
            except OSError: time.sleep(.5)
        else: raise TimeoutError('Synthetic gateway did not start')
        if args.probe:
            subprocess.run([str(args.probe.resolve()), 'conversation-smoke', str(data)], check=True, timeout=180)
        else:
            def api(path, body=None):
                raw = None if body is None else json.dumps(body).encode()
                request = urllib.request.Request(f'http://127.0.0.1:{port}' + path, data=raw,
                    headers={'Authorization': 'Bearer ' + (data / 'api-key').read_text().strip(), 'Content-Type': 'application/json'})
                with urllib.request.urlopen(request, timeout=15) as response: return json.load(response)
            import uuid
            if args.latency:
                contract = api('/momo/v1/conversation')['capabilities']['message_idempotency']
                assert contract['durable'] and contract['retention_seconds'] >= 86400
                samples = []
                for _ in range(3):
                    started = time.monotonic_ns()
                    receipt = api('/momo/v1/conversation/messages', dict(operation_id=str(uuid.uuid4()), content='MOMO_TEST_TTFT'))
                    request = urllib.request.Request(f'http://127.0.0.1:{port}/v1/runs/{receipt["run_id"]}/events',
                        headers={'Authorization': 'Bearer ' + (data / 'api-key').read_text().strip(), 'Accept': 'text/event-stream'})
                    first = committed = None
                    with urllib.request.urlopen(request, timeout=30) as response:
                        assert response.status == 200
                        for line in response:
                            if not line.startswith(b'data: '): continue
                            event = json.loads(line[6:])
                            if first is None and event.get('event') == 'message.delta' and event.get('delta'):
                                first = time.monotonic_ns()
                            if event.get('event') == 'message.committed':
                                committed = event['message']
                            if event.get('event') == 'run.completed': break
                    assert first is not None, 'No first text on the native SSE endpoint'
                    assert committed and committed['role'] == 'assistant' and committed['run_id'] == receipt['run_id'], 'Canonical answer must precede completion'
                    assert committed['id'] in {m['id'] for m in api('/momo/v1/conversation/messages')['data']}
                    model = json.loads((data / 'runtime/model-latency.jsonl').read_text().splitlines()[-1])
                    model_ms = (model['first_text_ns'] - model['start_ns']) / 1e6
                    total_ms = (first - started) / 1e6
                    samples.append(dict(run_id=receipt['run_id'], total_ttft_ms=total_ms,
                                        model_ttft_ms=model_ms, application_overhead_ms=total_ms-model_ms,
                                        canonical_answer_before_completion=True))
                (data / 'latency.json').write_text(json.dumps({'scope':'Mac loopback, real Hermes, synthetic timed model; not phone Tailscale', 'samples':samples}, indent=2))
                print(json.dumps(samples), flush=True)
                assert all(s['application_overhead_ms'] < 500 for s in samples[1:]), 'Warm local first-text overhead exceeds 500 ms'
                return
            if args.report_recovery:
                from report_recovery_scenario import run
                run(api,data,workspace)
                return
            if args.computer:
                from computer_gate_scenario import run
                run(api,data,computer_lease)
                if args.hold_seconds: print('Fixture ready for UI',flush=True); time.sleep(args.hold_seconds)
                return
            if args.background_controls:
                from interaction_scenarios import run_background
                run_background(api,data,workspace)
                if args.hold_seconds: print("Fixture ready for UI",flush=True); time.sleep(args.hold_seconds)
                return
            if args.interactions:
                from interaction_scenarios import run
                run(api,data,workspace)
                if args.hold_seconds: print("Fixture ready for UI",flush=True); time.sleep(args.hold_seconds)
                return
            a, b = api('/momo/v1/conversation'), api('/momo/v1/conversation')
            assert a == b and a['capabilities']['server_owned_completion']
            payload = dict(operation_id=str(uuid.uuid4()), content='MOMO_TEST_PROCESS' if args.process else 'MOMO_TEST_START_BACKGROUND')
            legacy_id = 'momo-' + str(uuid.uuid4())
            if args.legacy:
                receipt = api('/v1/runs', dict(session_id=legacy_id, input=payload['content']))
            else:
                receipt = api('/momo/v1/conversation/messages', payload)
                assert api('/momo/v1/conversation/messages', payload)['run_id'] == receipt['run_id']
            for _ in range(160):
                if (workspace / 'im-worker-started').exists(): break
                time.sleep(.25)
            else: raise TimeoutError('Worker never started')
            if not args.legacy and not args.process:
                work = api('/momo/v1/conversation/runs')['background_work']
                assert len(work) == 1 and work[0]['state'] == 'running' and work[0]['report_state'] == 'pending', work
            import sqlite3
            with sqlite3.connect(data / 'runtime/conversation.sqlite') as db:
                ack = db.execute("SELECT created_at FROM messages WHERE content='我先整理资料，完成后告诉你。'").fetchone()
            if not args.legacy:
                assert ack and ack[0] <= (workspace / 'im-worker-started').stat().st_mtime, 'Model acknowledgement must be durable before work starts'
            second = api('/v1/runs', dict(session_id=legacy_id,input='我周五去上海')) if args.legacy else api('/momo/v1/conversation/messages', dict(operation_id=str(uuid.uuid4()), content='我周五去上海'))
            for _ in range(80):
                if api('/v1/runs/' + second['run_id'])['status'] == 'completed': break
                time.sleep(.25)
            else: raise TimeoutError('Independent chat did not complete during delegation')
            if args.controls:
                control_run = api('/momo/v1/conversation/messages', dict(operation_id=str(uuid.uuid4()), content='MOMO_TEST_CLARIFY'))
                for _ in range(120):
                    control_snapshot = api('/v1/runs/' + control_run['run_id'])
                    if control_snapshot['pending_controls']: break
                    time.sleep(.25)
                else: raise TimeoutError('Native clarify did not enter waiting state')
                prompts = control_snapshot['pending_controls']
                both = [api('/momo/v1/conversation/runs') for _ in range(2)]
                assert both[0] == both[1]
                queued = api('/momo/v1/conversation/messages', dict(operation_id=str(uuid.uuid4()), content='我周五去上海'))
                for _ in range(120):
                    if api('/v1/runs/'+queued['run_id'])['status']=='completed': break
                    time.sleep(.1)
                else: raise AssertionError('New work was blocked by clarify')
                assert api('/v1/runs/'+control_run['run_id'])['pending_controls']==prompts
            # All clients are now detached. Only the Mac coordinator may generate this reply.
            (workspace / 'im-worker-release').touch()
            import sqlite3
            if args.controls:
                for _ in range(120):
                    with sqlite3.connect(data / 'runtime/conversation.sqlite') as db:
                        saved = db.execute('SELECT state,admission_id FROM completions').fetchone()
                    if saved: break
                    time.sleep(.25)
                else: raise TimeoutError('Completion was not durably received while waiting')
                # Another work waiting for input must not block this completion.
                prompt = prompts[0]
                # Keep the real control open until the independent notification projection observes it.
                for _ in range(120):
                    with sqlite3.connect(data / 'runtime/conversation.sqlite') as db:
                        waiting = db.execute("SELECT payload FROM push_events WHERE kind='needs_input' AND active=1").fetchall()
                    if any(json.loads(row[0]).get('control_id') == prompt['prompt_id'] for row in waiting): break
                    time.sleep(.25)
                else: raise TimeoutError('Pending control did not produce a notification event')
                body = dict(request_id=prompt['prompt_id'],execution_generation=control_snapshot['execution_generation'] + 1,answer='GREEN')
                try: api('/v1/runs/' + control_run['run_id'] + '/clarify', body)
                except urllib.error.HTTPError as error: assert error.code == 409
                else: raise AssertionError('Stale generation was accepted')
                assert api('/v1/runs/' + control_run['run_id'])['pending_controls'] == prompts
                body['execution_generation'] -= 1
                api('/v1/runs/' + control_run['run_id'] + '/clarify', body)
            if args.legacy:
                for _ in range(120):
                    with sqlite3.connect(data / 'hermes/state.db') as db:
                        delivery_ids = [row[0] for row in db.execute("SELECT id FROM messages WHERE display_kind='async_delegation_complete' AND session_id=?", (legacy_id,))]
                    if delivery_ids: break
                    time.sleep(.25)
                else: raise TimeoutError('Native legacy delivery not persisted')
                old_wake = '后台委派的结果已进入本会话历史。请阅读实际结果，接着处理原任务，并向用户回复；不要把这条系统唤醒当作用户的新消息。'
                later = api('/v1/runs', dict(session_id=legacy_id,input=old_wake if args.legacy == 'consumed' else '我周五去上海'))
                for _ in range(120):
                    if api('/v1/runs/' + later['run_id'])['status'] == 'completed': break
                    time.sleep(.25)
                else: raise TimeoutError('Legacy follow-up did not settle')
                claims = [dict(run_id=later['run_id'],message_ids=delivery_ids)] if args.legacy == 'consumed' else []
                api('/momo/v1/conversation/adopt', dict(session_id=legacy_id,consumptions=claims))
                if args.legacy == 'consumed':
                    time.sleep(2)
                    with sqlite3.connect(data / 'runtime/conversation.sqlite') as db:
                        assert db.execute('SELECT count(*) FROM legacy_consumptions').fetchone()[0] == len(delivery_ids)
                        assert db.execute('SELECT count(*) FROM completions').fetchone()[0] == 0
                    assert (workspace / 'im-worker-finished').read_text().splitlines() == ['done']
                    page = api('/momo/v1/conversation/messages?after=0&limit=100')
                    assert all(row['source_session'] == legacy_id for row in page['data']), page
                    print(json.dumps(dict(ok=True, legacy=args.legacy, old_continuation_not_reactivated=True, no_duplicate_projection=True)))
                    return
            if args.fault:
                for _ in range(120):
                    if (data / 'runtime/fault-fired').exists(): break
                    time.sleep(.25)
                else: raise TimeoutError('Crash boundary not reached')
                if args.fault == 'started': child.kill()
                child.wait(timeout=20)
                with sqlite3.connect(data / 'runtime/conversation.sqlite') as db:
                    receipt_before = db.execute('SELECT admission_id,state FROM completions').fetchone()
                if args.fault in ('receipt','admission'): assert receipt_before[0] is None
                child = subprocess.Popen(command, env=runtime.child_environment(data), stdout=log, stderr=subprocess.STDOUT)
                (data / 'runtime/restarted').touch()
                for _ in range(120):
                    try:
                        if api('/momo/v1/conversation')['conversation_id'] == a['conversation_id']: break
                    except OSError: pass
                    time.sleep(.25)
                else: raise TimeoutError('Restart did not restore the shared identity')
                if args.fault == 'started':
                    for _ in range(80):
                        runs = api('/momo/v1/conversation/runs')['data']
                        unknown = next((run for run in runs if run['status'] == 'unknown'), None)
                        if unknown: break
                        time.sleep(.25)
                    assert unknown, runs
                    time.sleep(2)
                    assert not any(row['content'] == '后台任务完成：MOMO_BACKGROUND_DONE' for row in api('/momo/v1/conversation/messages')['data'])
                    api('/v1/runs/' + unknown['run_id'] + '/resolve-unknown', dict(admission_id=unknown['admission_id'], execution_generation=unknown['execution_generation']))
                    assert api('/v1/runs/' + unknown['run_id'])['status'] == 'cancelled'
                    for _ in range(80):
                        with sqlite3.connect(data / 'runtime/conversation.sqlite') as db:
                            settled = db.execute('SELECT admission_id,state FROM completions').fetchone()
                        work = api('/momo/v1/conversation/runs')['background_work']
                        if settled == (unknown['admission_id'], 'cancelled') and work and all(item['report_state'] == 'cancelled' for item in work): break
                        time.sleep(.25)
                    else: raise AssertionError(('Resolved completion still pending', settled, work))
                    time.sleep(2)
                    with sqlite3.connect(data / 'hermes/state.db') as db:
                        assert db.execute("SELECT count(*) FROM session_admissions WHERE principal_id='momo-completion'").fetchone()[0] == 1
                    assert not any(row['content'] == '后台任务完成：MOMO_BACKGROUND_DONE' for row in api('/momo/v1/conversation/messages')['data'])
                    assert (workspace / 'im-worker-finished').read_text().splitlines() == ['done']
                    print(json.dumps(dict(ok=True, fault=args.fault, unknown_not_replayed=True, resolved_without_retry=True, receipt_settled=True, background_work_settled=True)))
                    return
            for _ in range(240):
                with sqlite3.connect(data / 'runtime/conversation.sqlite') as db:
                    reported = db.execute("SELECT count(*) FROM completions WHERE state='reported'").fetchone()[0]
                if reported: break
                time.sleep(.25)
            else: raise TimeoutError('Mac did not report completion without clients')
            if args.process:
                time.sleep(3)
                with sqlite3.connect(data / 'runtime/conversation.sqlite') as db:
                    receipts = db.execute('SELECT event_json,origin_admission_id,admission_id,state FROM completions').fetchall()
                assert len(receipts) == 1 and receipts[0][3] == 'reported', receipts
                event = json.loads(receipts[0][0])
                assert event['type'] == 'completion' and event['started_at'] > 0 and event['parent_session_id'] == receipt['execution_session_id'], event
                with sqlite3.connect(data / 'hermes/state.db') as db:
                    assert db.execute('SELECT request_id FROM session_admissions WHERE admission_id=?', (receipts[0][1],)).fetchone() == (receipt['run_id'],)
                    assert db.execute("SELECT count(*) FROM session_admissions WHERE principal_id='momo-completion'").fetchone()[0] == 1
            pages = [api('/momo/v1/conversation/messages?after=0&limit=100') for _ in range(2)]
            assert pages[0] == pages[1]
            finals = [r for r in pages[0]['data'] if '后台任务完成：MOMO_BACKGROUND_DONE' == r['content']]
            assert len(finals) == 1, pages[0]
            if not args.process: assert api('/momo/v1/conversation/runs')['background_work'][0]['report_state'] == 'reported'
            if args.legacy:
                assert all(r['source_session'] == legacy_id or str(r['run_id']).startswith('momo_completion_') for r in pages[0]['data']), pages[0]
            assert len([r for r in pages[0]['data'] if r['role'] == 'user']) == (3 if args.legacy else 4 if args.controls else 2)
            assert api('/momo/v1/conversation')['capabilities']['system_push'] is False
            if not args.legacy:
                for _ in range(120):
                    with sqlite3.connect(data / 'runtime/conversation.sqlite') as db:
                        pushes = db.execute('SELECT e.kind,e.active,m.content FROM push_events e LEFT JOIN messages m ON m.seq=e.message_seq').fetchall()
                    if any(kind == 'final' and active and content == '后台任务完成：MOMO_BACKGROUND_DONE' for kind,active,content in pushes): break
                    time.sleep(.25)
                else: raise TimeoutError('The final Hermes report did not produce a notification event')
                assert not any(active and content in ('我先整理资料，完成后告诉你。','后台进程已启动，完成后告诉你。') for _,active,content in pushes), pushes
                if args.controls:
                    assert any(kind == 'needs_input' for kind,_,_ in pushes), pushes
                    assert not any(kind == 'needs_input' and active for kind,active,_ in pushes), pushes
            if args.steering:
                (workspace / 'im-worker-started').unlink()
                (workspace / 'im-worker-release').unlink()
                sync = api('/momo/v1/conversation/messages', dict(operation_id=str(uuid.uuid4()), content='MOMO_TEST_SYNC'))
                for _ in range(120):
                    if (workspace / 'im-worker-started').exists(): break
                    time.sleep(.25)
                else: raise TimeoutError('Synchronous worker did not start')
                active = api('/v1/runs/' + sync['run_id'])
                note = dict(operation_id=str(uuid.uuid4()), content='MOMO_STEER_NOTE', target_run_id=sync['run_id'], execution_generation=active['execution_generation'])
                steered = api('/momo/v1/conversation/messages', note)
                assert api('/momo/v1/conversation/messages', note)['run_id'] == steered['run_id']
                with sqlite3.connect(data / 'hermes/state.db') as db:
                    state = db.execute('SELECT status,outcome FROM session_admissions WHERE request_id=?', (steered['run_id'],)).fetchone()
                assert state == ('terminal', 'steering'), state
                (workspace / 'im-worker-release').touch()
                for _ in range(120):
                    with sqlite3.connect(data / 'hermes/state.db') as db:
                        state = db.execute('SELECT status,outcome FROM session_admissions WHERE request_id=?', (steered['run_id'],)).fetchone()
                    if state == ('terminal','steered'): break
                    time.sleep(.25)
                else: raise AssertionError(('Steer did not settle with the target turn', state))
            print(json.dumps(dict(ok=True, shared_conversation=a['conversation_id'], messages=len(pages[0]['data']), offline_completion=True, durable_steering=args.steering, restart_fault=args.fault, legacy=args.legacy, terminal_background=args.process)))
        assert (workspace / 'im-worker-finished').read_text().splitlines() == ['done'] * (2 if args.steering else 1), 'Tool side effect ran more than once'
    finally:
        for label in ('GAP_PROCESS_A','GAP_PROCESS_B','GAP_CHILD_A','GAP_CHILD_B'): (workspace/(label+'-release')).touch()
        (workspace / 'im-worker-release').touch()
        (data / 'runtime/restarted').touch()
        child.terminate()
        try: child.wait(timeout=20)
        except subprocess.TimeoutExpired: child.kill(); child.wait()
        server.shutdown(); server.server_close(); log.close()
        if computer_server:computer_server.shutdown();computer_server.server_close()


if __name__ == '__main__': main()
