"""Synthetic transcript -> real Hermes memory -> task -> UI deletion, with no phone required.
Run serve_remote_fixture.py against the same disposable prepared runtime first.
"""
import argparse
import hashlib
import json
from pathlib import Path
import time
import urllib.request
import uuid


def main(data):
    connection = json.loads((data / 'connection.json').read_text())
    key = (data / 'api-key').read_text().strip()
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    checks = []

    def call(path, body=None, context=False, operation=None):
        headers = {'Authorization':'Bearer '+key, 'Content-Type':'application/json'}
        if operation: headers['Idempotency-Key'] = operation
        request = urllib.request.Request(connection['data_url' if context else 'base_url'] + path,
            data=json.dumps(body).encode() if body is not None else None, headers=headers)
        with opener.open(request, timeout=10) as response: return json.load(response)

    def check(name, passed):
        checks.append({'name':name,'passed':bool(passed)})
        print(('PASS ' if passed else 'FAIL ')+name, flush=True)
        assert passed, name

    def until(predicate):
        for _ in range(90):
            result = predicate()
            if result: return result
            time.sleep(1)
        raise TimeoutError('Native memory POC did not complete; inspect gateway log')

    text = '周五给小林发一份方案草稿。手机负责采集，Mac 负责执行。聚餐还没有定。'
    source = dict(library_id=str(uuid.uuid4()),session_id=str(uuid.uuid4()),device_id=str(uuid.uuid4()),
                  generation=0,version=1,deleted=False,recorded_at=time.time(),
                  spans=[dict(id=str(uuid.uuid4()),text=text,recorded_at=time.time())],
                  text_sha256=hashlib.sha256(text.encode()).hexdigest())
    check('Memory owner is Hermes or SuperAgent',call('/v1/status',context=True)['memory_writer'] in ('Hermes', 'SuperAgent'))
    receipt = call('/v1/sources',source,context=True)
    check('Source retry returns the original receipt',call('/v1/sources',source,context=True)==receipt)
    page = until(lambda: (p if (p:=call('/v1/memories',context=True))['items'] else None))
    entry = next(item for item in page['items'] if '小林' in item['text'])
    check('Transcript was automatically written to Hermes native MEMORY.md',
          entry['basis']=='hermes' and entry['text'] in (data/'hermes/memories/MEMORY.md').read_text())
    until(lambda: call('/v1/status',context=True)['memory_pending']==0)
    events = [json.loads(line) for line in (data/'runtime/fixture-events.jsonl').read_text().splitlines()]
    ingestion = [event for event in events if event['memory']]
    forbidden = {'terminal','execute_code','browser_navigate','computer_use','send_message','write_file'}
    check('Transcript task has native memory without execution tools',
          any(event['tool']=='memory' for event in ingestion) and all(not forbidden.intersection(event['tools']) for event in ingestion))
    (data/'runtime/reply-ready').touch(); (data/'runtime/phone-detached').touch()
    operation = str(uuid.uuid4()); body = {'session_id':'native-memory-chat-'+str(uuid.uuid4()),'input':'根据录音，给小林写一份方案草稿。'}
    run = call('/v1/runs',body,operation=operation)
    final = until(lambda: (r if (r:=call('/v1/runs/'+run['run_id']))['status'] in {'completed','failed','cancelled'} else None))
    check('Mac continues the task and writes a real result',final['status']=='completed' and '方案草稿已保存在 Mac' in final.get('output','') and bool(list((data/'context/results').glob('*.md'))))
    check('Retry does not create a second run',call('/v1/runs',body,operation=operation)['run_id']==run['run_id'])
    events = [json.loads(line) for line in (data/'runtime/fixture-events.jsonl').read_text().splitlines()]
    check('Chat consumes the same native memory created from transcription',any(not event['memory'] and event['native_memory_visible'] for event in events))
    mutation = {'id':entry['id'],'operation_id':str(uuid.uuid4()),'base_revision':entry['revision']}
    call('/v1/memories/forget',mutation,context=True); call('/v1/memories/forget',mutation,context=True)
    check('UI delete updates Hermes memory and retains original transcript',
          entry['id'] not in [m['id'] for m in call('/v1/memories',context=True)['items']] and entry['text'] not in (data/'hermes/memories/MEMORY.md').read_text()
          and any(s['id']==receipt['source_id'] for s in call('/v1/sources',context=True)['items']))
    (data/'runtime/native-memory-smoke.json').write_text(json.dumps({'checks':checks,'physical_phone':False,'model':'scripted local fixture; real Hermes and MCP','run_id':run['run_id']},indent=2))


if __name__ == '__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--data-dir',type=Path,required=True)
    main(parser.parse_args().data_dir.resolve())
