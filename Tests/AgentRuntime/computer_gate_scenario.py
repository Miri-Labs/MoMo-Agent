"""Real Hermes + production MCP dispatch; synthetic private Mac IPC, never user's desktop."""
import base64
import io
import json
from pathlib import Path
import socketserver
import subprocess
import sys
import threading
import time
import uuid


def prepare(data,python,root):
    sys.path.insert(0,str(root/'Apps/MacApp/Access'))
    from desktop_control import DesktopLease,socket_path
    lease=DesktopLease(data)
    image=subprocess.check_output([str(python),'-c','from PIL import Image;import io,base64;b=io.BytesIO();Image.new("RGB",(8,8)).save(b,format="JPEG");print(base64.b64encode(b.getvalue()).decode())']).decode().strip()
    class Handler(socketserver.StreamRequestHandler):
        def handle(self):
            request=json.loads(self.rfile.readline()); control=request.get('control',{})
            with lease.locked():
                current=lease.read()
                valid=request.get('key')==(data/'api-key').read_text().strip() and current['owner']=='agent' and current['epoch']==control.get('epoch') and current.get('agent_work')=={k:v for k,v in control.items() if k!='epoch'}
                if not valid:result={'error':'invalid native authority'}
                else:
                    with (data/'runtime/computer-ipc.jsonl').open('a') as log:log.write(json.dumps(request)+'\n')
                    result={'jpeg':image} if request['op']=='frame' else {'ok':True}
            self.wfile.write(json.dumps(result).encode()+b'\n')
    path=Path(socket_path(data));path.parent.mkdir(mode=0o700,exist_ok=True)
    server=socketserver.ThreadingUnixStreamServer(str(path),Handler)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    return server,lease


def model(prompt,results,messages,data,lease):
    if prompt.startswith('GAP_COMPUTER_DELEGATE'):
        return (None,{},'COMPUTER_DELEGATED') if 'delegation_id' in str(results) else ('delegate_task',{'goal':'GAP_COMPUTER_CHILD','context':'Read the synthetic computer screenshot once; then reply CHILD_SCREEN_DONE.'},None)
    screen=input_count=0
    for m in messages:
        for call in m.get('tool_calls',[]):
            fn=call['function'];args=json.loads(fn['arguments'])
            names=[v['name'] for v in args.get('calls',[])] if fn['name']=='tool_call' else [fn['name']]
            screen+=sum(n.endswith('__computer_screenshot') for n in names)
            input_count+=sum(n.endswith('__computer_input') for n in names)
    if prompt.startswith('GAP_COMPUTER_CHILD'):
        return (None,{},'CHILD_SCREEN_DONE') if screen else ('mcp__momo_computer__computer_screenshot',{},None)
    if prompt.startswith('GAP_COMPUTER_PAUSE'):
        if not screen:return 'mcp__momo_computer__computer_screenshot',{},None
        if 'CLARIFY' not in str(results) and 'Choose the synthetic' not in str(results) and not any('clarify' in str(m.get('tool_calls',[])) for m in messages):
            return 'clarify',{'questions':[{'question':'Computer pause CLARIFY','choices':['BLUE','GREEN']}]},None
        if input_count==0:return 'mcp__momo_computer__computer_input',{'kind':'click','x':.15,'y':.15},None
        if screen<2:return 'mcp__momo_computer__computer_screenshot',{},None
        if input_count<2:return 'mcp__momo_computer__computer_input',{'kind':'click','x':.85,'y':.85},None
        return None,{},'PAUSE_RESUMED'
    if not screen:return 'mcp__momo_computer__computer_screenshot',{},None
    if prompt.startswith('GAP_COMPUTER_CANCEL'):return None,{},'CANCEL_MUST_NOT_FINISH'
    if input_count==0:
        if not (data/'runtime/computer-second-takeover.json').exists():
            value=lease.acquire('fixture-human',str(uuid.uuid4()))
            (data/'runtime/computer-second-takeover.json').write_text(json.dumps(value))
        return 'mcp__momo_computer__computer_input',{'kind':'click','x':.25,'y':.25},None
    if screen<2:
        assert 'desktop_changed' in str(results), 'stale coordinates must not be sent to native IPC'
        return 'mcp__momo_computer__computer_screenshot',{},None
    if input_count<2:return 'mcp__momo_computer__computer_input',{'kind':'click','x':.75,'y':.75},None
    return None,{},'COMPUTER_DONE'


def run(api,data,lease):
    def wait(check,label):
        for _ in range(300):
            val=check()
            if val:return val
            time.sleep(.1)
        raise AssertionError(label)
    def send(text):return api('/momo/v1/conversation/messages',dict(operation_id=str(uuid.uuid4()),content=text,intent='new'))
    def status(r):return api('/v1/runs/'+r['run_id'])
    def records():return [json.loads(line) for line in (data/'runtime/computer-ipc.jsonl').read_text().splitlines()] if (data/'runtime/computer-ipc.jsonl').exists() else []
    human=lease.acquire('fixture-human',str(uuid.uuid4()))
    a=send('GAP_COMPUTER')
    wait(lambda:status(a).get('wait_reason')=='computer_human','computer tool waits before MCP lock')
    assert not records()
    b=send('我周五去上海');wait(lambda:status(b)['status']=='completed','independent chat during computer wait')
    lease.release('fixture-human',human['session'])
    second=wait(lambda:json.loads((data/'runtime/computer-second-takeover.json').read_text()) if (data/'runtime/computer-second-takeover.json').exists() else None,'takeover after screenshot')
    wait(lambda:status(a).get('wait_reason')=='computer_human','input waits for human')
    lease.release('fixture-human',second['session'])
    wait(lambda:status(a)['status']=='completed','same native turn resumes after return')
    rows=records();assert [r['op'] for r in rows]==['frame','frame','input'],rows
    assert rows[-1]['event']['x']==.75, 'old .25 click must never execute'
    # A cancelled wait must not revive when ownership returns.
    human=lease.acquire('fixture-human',str(uuid.uuid4()));cancel=send('GAP_COMPUTER_CANCEL')
    c=wait(lambda:(s if (s:=status(cancel)).get('wait_reason')=='computer_human' else None),'cancel waiting tool')
    api('/momo/v1/conversation/work/'+c['work_id']+'/cancel',dict(operation_id=str(uuid.uuid4()),execution_generation=c['execution_generation']))
    wait(lambda:status(cancel)['status']=='cancelled','native claim cancelled')
    lease.release('fixture-human',human['session']);time.sleep(1)
    assert len(records())==3
    # Native async children inherit the same trusted product gate and lease.
    human=lease.acquire('fixture-human',str(uuid.uuid4()));d=send('GAP_COMPUTER_DELEGATE')
    def child_wait():
        import sqlite3
        with sqlite3.connect(data/'runtime/conversation.sqlite') as db:
            return db.execute("SELECT 1 FROM computer_waits WHERE run_id LIKE 'delegation:%' AND state='waiting'").fetchone()
    wait(child_wait,'delegated computer gate inherited');assert len(records())==3
    wait(lambda:any(r['work_id']==d['work_id'] and r.get('wait_reason')=='computer_human' for r in api('/momo/v1/conversation/runs')['background_work']),'child wait is visible to both clients')
    lease.release('fixture-human',human['session'])
    wait(lambda:len(records())==4,'delegated screenshot dispatched once')
    wait(lambda:any(r['kind']=='delegation' and r['work_id']==d['work_id'] and r['report_state']=='reported' for r in api('/momo/v1/conversation/runs')['background_work']),'delegated result reports')
    # A keeps its native admission while pending clarification, but releases the
    # computer only after its screenshot RPC has returned. B can use that resource.
    a=send('GAP_COMPUTER_PAUSE')
    paused=wait(lambda:(s if (s:=status(a))['pending_controls'] else None),'computer A clarifies')
    epoch=lease.read()['epoch']
    b=send('GAP_COMPUTER_CHILD')
    wait(lambda:status(b)['status']=='completed','B obtains computer while A awaits answer')
    assert lease.read()['epoch']>epoch
    prompt=paused['pending_controls'][0]
    api('/v1/runs/'+a['run_id']+'/clarify',dict(request_id=prompt['prompt_id'],execution_generation=paused['execution_generation'],answer='BLUE'))
    wait(lambda:status(a)['status']=='completed','A resumes its original claim')
    assert status(a)['execution_generation']==paused['execution_generation']
    inputs=[r['event']['x'] for r in records() if r['op']=='input']
    assert .15 not in inputs and .85 in inputs,inputs
    print(json.dumps(dict(ok=True,approval_releases_computer=True,real_hermes_mcp=True,synthetic_native_ipc=True,other_chat_unblocked=True,epoch_requires_fresh_screenshot=True,cancelled_wait_never_revives=True,delegation_inherits_gate=True)))
