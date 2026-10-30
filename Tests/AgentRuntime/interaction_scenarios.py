"""Real native controls/work assertions shared by the local scripted-model harness."""
import json
import shlex
import sqlite3
import time
import urllib.error
import uuid


def model_reply(prompt,results,messages,workspace,python):
    if prompt.startswith('先停下刚才'):
        text=str(results)
        if 'task_control_' in text or 'stale_target' in text: return None,{},'CHAT_STOP_FAILED'
        if 'stopping' in text: return None,{},'CHAT_STOP_REQUESTED'
        if 'background_work' not in text: return 'conversation_task', {'action':'inspect'}, None
        target=json.loads((workspace/'conversation-stop-target.json').read_text())
        return 'conversation_task',dict(action='stop',work_id=target['work_id'],run_id=target['run_id'],generation=target['execution_generation']),None
    if prompt.startswith('GAP_APPROVAL'):
        command='rm -rf '+shlex.quote(str(workspace/'approval-target'))+' && touch '+shlex.quote(str(workspace/'approval-done'))
        return (None,{},'APPROVAL_DONE') if results else ('terminal',{'command':command},None)
    if prompt.startswith('GAP_HISTORY_BLUE'):return None,{},'HISTORY_BLUE_SAVED'
    if prompt.startswith('GAP_INDEPENDENT') or prompt.startswith('好的，继续'):
        return None,{},'INDEPENDENT_CONTEXT_OK' if 'GAP_HISTORY_BLUE' in str(messages) else 'CONTEXT_MISSING'
    return None,{},None


def run(api,data,workspace):
    def send(text,**kw):return api('/momo/v1/conversation/messages',dict(operation_id=str(uuid.uuid4()),content=text,**kw))
    def wait(check,label):
        for _ in range(240):
            value=check()
            if value:return value
            time.sleep(.1)
        raise AssertionError(label)
    def status(run):return api('/v1/runs/'+run['run_id'])
    shared=api('/momo/v1/conversation'); assert shared['capabilities']['independent_chat_while_waiting']
    seed=send('GAP_HISTORY_BLUE'); wait(lambda:status(seed)['status']=='completed','seed')
    clarify=send('MOMO_TEST_CLARIFY')
    snap=wait(lambda:(s if (s:=status(clarify))['pending_controls'] else None),'clarify prompt')
    prompts=snap['pending_controls']; assert snap['wait_reason']=='clarify'
    other=send('好的，继续')
    wait(lambda:status(other)['status']=='completed','independent reply while clarify waiting')
    assert status(clarify)['pending_controls']==prompts
    assert status(other)['output']=='INDEPENDENT_CONTEXT_OK'
    assert status(other)['session_id']==shared['session_id']
    assert status(other)['execution_session_id']!=status(clarify)['execution_session_id']
    refused=dict(operation_id=str(uuid.uuid4()),content='do not queue this',intent='steer',work_id=snap['work_id'],target_run_id=clarify['run_id'],execution_generation=snap['execution_generation'])
    try:api('/momo/v1/conversation/messages',refused)
    except urllib.error.HTTPError as e:assert e.code==409
    else:raise AssertionError('steer entered pending clarify')
    with sqlite3.connect(data/'runtime/conversation.sqlite') as db:assert db.execute('SELECT 1 FROM inputs WHERE operation_id=?',(refused['operation_id'],)).fetchone() is None
    api('/v1/runs/'+clarify['run_id']+'/clarify',dict(request_id=prompts[0]['prompt_id'],execution_generation=snap['execution_generation'],answer='BLUE'))
    wait(lambda:status(clarify)['status']=='completed','clarify completes')
    (workspace/'approval-target').mkdir()
    approval=send('GAP_APPROVAL')
    snap=wait(lambda:(s if (s:=status(approval))['pending_controls'] else None),'approval prompt')
    assert snap['wait_reason']=='approval'; prompt=snap['pending_controls'][0]
    other=send('GAP_INDEPENDENT'); wait(lambda:status(other)['status']=='completed','approval must not hold B')
    assert not (workspace/'approval-done').exists()
    assert status(approval)['pending_controls']==snap['pending_controls']
    api('/v1/runs/'+approval['run_id']+'/approval',dict(request_id=prompt['prompt_id'],execution_generation=snap['execution_generation'],choice='once'))
    wait(lambda:status(approval)['status']=='completed','approved A finishes')
    assert (workspace/'approval-done').exists()
    # Stale generation/settled target cannot admit an independent fallback.
    stale=dict(operation_id=str(uuid.uuid4()),content='never run this',intent='steer',work_id=snap['work_id'],target_run_id=approval['run_id'],execution_generation=snap['execution_generation'])
    try:api('/momo/v1/conversation/messages',stale)
    except urllib.error.HTTPError as e:assert e.code==409
    else:raise AssertionError('stale steer accepted')
    # Cancellation of a native pending clarify is exact and does not answer it.
    cancelled=send('MOMO_TEST_CLARIFY'); c=wait(lambda:(s if (s:=status(cancelled))['pending_controls'] else None),'cancel clarify')
    (workspace/'conversation-stop-target.json').write_text(json.dumps(c))
    stopped_by_chat=send('先停下刚才的确认任务')
    wait(lambda:status(stopped_by_chat)['status']=='completed','natural chat stop returns')
    assert status(stopped_by_chat)['output']=='CHAT_STOP_REQUESTED',status(stopped_by_chat)
    wait(lambda:status(cancelled)['status']=='cancelled','exact cancellation')
    assert status(other)['status']=='completed'
    for _ in range(2):
        page=api('/momo/v1/conversation/messages?after=0')
        assert len({m['id'] for m in page['data']})==len(page['data'])
        assert any(m['content']=='INDEPENDENT_CONTEXT_OK' for m in page['data'])
    print(json.dumps(dict(ok=True,independent_clarify=True,independent_approval=True,shared_history=True,strict_stale_steer=True,precise_cancel=True,stop_via_conversation_tool=True)))


def prepare_background(workspace):
    (workspace/'gap_worker.py').write_text('''import sys,time,os
from pathlib import Path
root=Path(__file__).parent;label=sys.argv[1]
(root/(label+'-started')).touch()
deadline=time.monotonic()+80
while not (root/(label+'-release')).exists():
 if time.monotonic()>deadline:raise TimeoutError('fixture release')
 time.sleep(.05)
(root/(label+'-finished')).write_text('done')
print('MOMO_BACKGROUND_DONE '+label,flush=True)
''')


def background_model(prompt,results,messages,workspace,python):
    if prompt.startswith('GAP_PROCESS_') or prompt.startswith('GAP_CHILD_'):
        label=prompt.splitlines()[0].strip()
        if results:return None,{},'CHILD_DONE' if label.startswith('GAP_CHILD_') else 'PROCESS_STARTED'
        return 'terminal',{'command':shlex.join([str(python),str(workspace/'gap_worker.py'),label]),
            'background':label.startswith('GAP_PROCESS_'),'notify_on_complete':label.startswith('GAP_PROCESS_')},None
    if prompt.startswith('GAP_DELEGATE_'):
        label=prompt.splitlines()[0].replace('GAP_DELEGATE_','GAP_CHILD_')
        return (None,{},'DELEGATE_STARTED') if results else ('delegate_task',{'goal':label,'context':'Run the synthetic local terminal worker once.'},None)
    return None,{},None


def run_background(api,data,workspace):
    def wait(check,label):
        for _ in range(400):
            val=check()
            if val:return val
            time.sleep(.1)
        raise AssertionError(label)
    def send(text):return api('/momo/v1/conversation/messages',dict(operation_id=str(uuid.uuid4()),content=text,intent='new'))
    def rows():return api('/momo/v1/conversation/runs')['background_work']
    for kind,prefix in [('process','GAP_PROCESS_'),('delegation','GAP_DELEGATE_')]:
        a,b=send(prefix+'A'),send(prefix+'B')
        child_prefix='GAP_CHILD_' if kind=='delegation' else prefix
        wait(lambda:(workspace/(child_prefix+'A-started')).exists() and (workspace/(child_prefix+'B-started')).exists(),'both native children started')
        children=wait(lambda:[r for r in rows() if r['kind']==kind and r['work_id'] in (a['work_id'],b['work_id'])] or None,'children registered')
        first=next(r for r in children if r['work_id']==a['work_id']); second=next(r for r in children if r['work_id']==b['work_id'])
        assert first['id']!=second['id'] and first['origin_run_id']==a['run_id'] and second['origin_run_id']==b['run_id']
        body=dict(operation_id=str(uuid.uuid4()),execution_generation=first['execution_generation'])
        api('/momo/v1/conversation/work/'+first['id']+'/cancel',body)
        api('/momo/v1/conversation/work/'+first['id']+'/cancel',body)
        stopped=wait(lambda:next((r for r in rows() if r['id']==first['id'] and r['state'] in ('cancelled','failed')),None),'first child stops')
        assert stopped['cancel_requested'] and not (workspace/(child_prefix+'A-finished')).exists()
        assert next(r for r in rows() if r['id']==second['id'])['state']=='running'
        (workspace/(child_prefix+'B-release')).touch()
        wait(lambda:next((r for r in rows() if r['id']==second['id'] and r['report_state']=='reported'),None),'other child completes and reports')
        wait(lambda:next((r for r in rows() if r['id']==first['id'] and r['report_state']=='reported'),None),'cancelled child honestly reports')
    print(json.dumps(dict(ok=True,process_exact_cancel=True,delegation_exact_cancel=True,other_work_unaffected=True,cancelled_child_reported=True)))
