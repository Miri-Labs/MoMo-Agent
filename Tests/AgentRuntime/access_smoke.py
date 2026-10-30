"""Opt-in public-tunnel smoke; use only a disposable synthetic runtime."""
import argparse, asyncio, hashlib, json, time, uuid
from pathlib import Path
from aiohttp import ClientSession, ClientTimeout

async def main(data, hold_reply=0):
    connection = json.loads((data/'connection.json').read_text()); root = (data/'api-key').read_text().strip()
    control = f'http://127.0.0.1:{connection["port"]+3}'
    token = uuid.uuid4().hex + uuid.uuid4().hex
    async with ClientSession(timeout=ClientTimeout(total=20)) as session:
        async def call(base, path, body=None, key=token, expected=200):
            async with session.request('GET' if body is None else 'POST',base+path,json=body,headers={'Authorization':'Bearer '+key},allow_redirects=False) as r:
                raw = await r.read()
                assert r.status==expected, (path,r.status,raw[:180])
                return json.loads(raw)
        state = await call(control,'/status',key=root)
        assert state['tunnel']['state']=='connected', state['tunnel']
        public = state['tunnel']['endpoint']
        state = await call(control,'/pair/invite',{},key=root)
        invite=state['invitation']
        phone=await call(public,'/pair/requests',{'invitation_id':invite['id'],'name':'Synthetic remote probe'})
        await call(public,'/v1/capabilities',expected=401)
        await call(public,'/status',expected=401)
        await call(control,'/pair/decide',{'id':phone['id'],'allow':True},key=root)
        approved=await call(public,'/pair/requests/'+phone['id'])
        assert approved['connection']['instance_id']==connection['instance_id']
        await call(public,'/status',expected=404)
        await call(public,'/v1/capabilities',key=root,expected=401)
        text='周五给小林发一份方案草稿。手机负责采集，Mac 负责执行。聚餐还没有定。'
        source=dict(library_id=str(uuid.uuid4()),session_id=str(uuid.uuid4()),device_id=str(uuid.uuid4()),generation=0,version=1,deleted=False,recorded_at=time.time(),spans=[dict(id=str(uuid.uuid4()),text=text,recorded_at=time.time())],text_sha256=hashlib.sha256(text.encode()).hexdigest())
        receipt=await call(public,'/context/v1/sources',source)
        listing=await call(public,'/context/v1/sources')
        assert receipt['source_id'] in [s['id'] for s in listing['items']]
        from urllib.parse import urlencode
        page=await call(public,'/context/v1/source?'+urlencode({'source_id':receipt['source_id'],'revision':receipt['source_revision']}))
        assert page['text']==text and page['next_offset'] is None
        operation=str(uuid.uuid4()); body={'input':'根据录音，给小林写一份方案草稿。','session_id':'probe-'+str(uuid.uuid4())}
        headers={'Authorization':'Bearer '+token,'Idempotency-Key':operation}
        async with session.post(public+'/v1/runs',json=body,headers=headers) as response:
            assert response.status in (200,202), await response.text()
            run=await response.json()
        run_id=run['run_id']; started=time.monotonic(); received=[]; first=None
        async with session.get(public+f'/v1/runs/{run_id}/events',headers={'Authorization':'Bearer '+token,'Accept':'text/event-stream'},timeout=ClientTimeout(total=None,sock_read=45)) as stream:
            assert stream.status==200 and stream.content_type=='text/event-stream'
            await asyncio.sleep(hold_reply)
            (data/'runtime/reply-ready').touch()
            async for raw in stream.content:
                line=raw.decode().strip()
                if line.startswith('data:'):
                    event=json.loads(line[5:]); received.append(event)
                    if event.get('event')=='message.interim':
                        first=time.monotonic()-started
                        snapshot=await call(public,'/v1/runs/'+run_id)
                        assert snapshot['status'] not in ['completed','succeeded'], snapshot['status']
                        break
        assert first is not None, received
        # Phone can detach while the Mac's real MCP tool writes the file.
        (data/'runtime/phone-detached').touch()
        for _ in range(60):
            snapshot=await call(public,'/v1/runs/'+run_id)
            if snapshot['status'] in ['completed','succeeded','failed','cancelled']: break
            await asyncio.sleep(1)
        assert snapshot['status'] == 'completed' and '方案草稿已保存在 Mac' in (snapshot.get('output') or ''), snapshot
        assert list((data/'context/results').glob('*.md'))
        async with session.post(public+'/v1/runs',json=body,headers=headers) as r: assert (await r.json())['run_id']==run_id
        await call(control,'/devices/revoke',{'id':phone['id']},key=root)
        await call(public,'/v1/runs/'+run_id,expected=401)
        result={'public_https':True,'provider':state['tunnel']['provider'],'real_sse_before_completion':True,'first_reply_seconds':round(first,2),'paired_and_revoked':True,'root_admin_rejected_public':True,'source_roundtrip':True,'remote_task_and_artifact':True,'idempotent_resubmission':True,'model':'synthetic fixture; actual Hermes and MCP','run_id':run_id,'physical_phone':False}
        (data.parent/'access-smoke.json').write_text(json.dumps(result,indent=2)); print(json.dumps(result))

p=argparse.ArgumentParser();p.add_argument('--data-dir',type=Path,required=True);p.add_argument('--hold-reply',type=int,default=0,choices=range(31))
args=p.parse_args()
asyncio.run(main(args.data_dir.resolve(), args.hold_reply))
