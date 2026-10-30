"""Real native failed completion -> report-only retry, no original side-effect replay."""
import json
import sqlite3
import time
import uuid


def run(api,data,workspace):
    def wait(check,label):
        for _ in range(600):
            result=check()
            if result:return result
            time.sleep(.1)
        raise AssertionError(label)
    def send(text):return api('/momo/v1/conversation/messages',dict(operation_id=str(uuid.uuid4()),content=text,intent='new'))
    def receipts():
        with sqlite3.connect(data/'runtime/conversation.sqlite') as db:
            db.row_factory=sqlite3.Row
            return [dict(r) for r in db.execute('SELECT * FROM completions')]
    root=send('MOMO_TEST_PROCESS')
    wait(lambda:(workspace/'im-worker-started').exists(),'real process starts')
    wait(lambda:api('/v1/runs/'+root['run_id'])['status']=='completed','short reply completes')
    # No client event stream or read request is responsible for completion work.
    (workspace/'im-worker-release').touch()
    failed=wait(lambda:next((r for r in receipts() if r['state']=='failed'),None),'provider failure becomes failed report')
    children=api('/momo/v1/conversation/runs')['background_work']
    child=next(r for r in children if r['work_id']==root['work_id'])
    assert child['report_state']=='failed' and child['report_retry_available'] and child['state']=='completed',child
    question=send('我周五去上海')
    wait(lambda:api('/v1/runs/'+question['run_id'])['status']=='completed','other chat remains available')
    with sqlite3.connect(data/'runtime/conversation.sqlite') as db:
        snapshot=json.loads(db.execute('SELECT active_context FROM works WHERE id=?',(question['work_id'],)).fetchone()[0])
    assert any(r.get('report_state')=='failed' and r.get('id')==child['id'] for r in snapshot),snapshot
    body=dict(operation_id=str(uuid.uuid4()))
    path='/momo/v1/conversation/work/'+child['id']+'/report-retry'
    api(path,body);api(path,body)
    wait(lambda:any(r['state']=='reported' for r in receipts()),'saved result reports without replay')
    api(path,body) # lost ACK retry after the report has already settled
    with sqlite3.connect(data/'hermes/state.db') as db:
        admissions=db.execute("SELECT request_id,status,outcome FROM session_admissions WHERE principal_id='momo-completion'").fetchall()
    assert len(admissions)==2,admissions
    assert (workspace/'im-worker-finished').read_text().splitlines()==['done']
    assert not (workspace/'MUST_NOT_EXECUTE').exists(),'report retry executed a side-effect tool'
    pages=[api('/momo/v1/conversation/messages?after=0') for _ in range(2)]
    assert pages[0]==pages[1]
    finals=[m for m in pages[0]['data'] if m['content']=='REPORT_RECOVERED MOMO_BACKGROUND_DONE']
    assert len(finals)==1,pages[0]
    assert receipts()[0]['report_attempt']==1
    print(json.dumps(dict(ok=True,real_native_failed_report=True,saved_result_retry=True,idempotent_retry=True,side_effect_tool_blocked=True,original_process_executed_once=True,two_clients_same_report=True,active_context_readonly=True)))
