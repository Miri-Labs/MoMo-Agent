"""Synthetic model for the simulator E2E. Exercises real Hermes/MCP, not model intelligence."""
import json
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def objects(value):
    if isinstance(value, dict):
        yield value
        for child in value.values(): yield from objects(child)
    elif isinstance(value, list):
        for child in value: yield from objects(child)
    elif isinstance(value, str):
        try: decoded = json.loads(value)
        except (ValueError, TypeError):
            # Hermes labels MCP data with an untrusted_tool_result XML envelope.
            decoder=json.JSONDecoder()
            for index,char in enumerate(value):
                if char != '{': continue
                try: decoded,_=decoder.raw_decode(value[index:])
                except ValueError: continue
                yield from objects(decoded)
                return
            return
        if isinstance(decoded, (dict, list)): yield from objects(decoded)


def start_model(directory):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def respond(self, value):
            if getattr(self, 'request_stream', False) and value.get('object') == 'chat.completion':
                choice = value['choices'][0]; message = dict(choice['message'])
                for index, call in enumerate(message.get('tool_calls', [])): call['index'] = index
                chunk = {**value, 'object': 'chat.completion.chunk', 'choices': [{'index': 0, 'delta': message, 'finish_reason': choice['finish_reason']}]}
                raw = ('data: ' + json.dumps(chunk) + '\n\ndata: [DONE]\n\n').encode()
                self.send_response(200); self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw); self.wfile.flush(); return
            raw=json.dumps(value).encode(); self.send_response(200)
            self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(raw)))
            self.end_headers(); self.wfile.write(raw)
        def do_GET(self):
            if self.path == '/test/status':
                marker=directory/'phone-detached'
                self.respond({'artifact': marker.exists() and any(f.stat().st_mtime > marker.stat().st_mtime for f in (directory.parent/'context/results').glob('*.md'))}); return
            self.respond({'object':'list','data':[{'id':'momo-remote-fixture','object':'model'}]})
        def do_POST(self):
            if self.path in ['/test/phone-detached', '/test/reply-ready']:
                self.rfile.read(int(self.headers.get('Content-Length','0'))); (directory/self.path.rsplit('/',1)[-1]).touch(); self.respond({'ok': True}); return
            body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            self.request_stream = body.get('stream') is True
            messages=body['messages']; start=max(i for i,m in enumerate(messages) if m['role']=='user')
            prompt=str(messages[start]['content']); results=[m for m in messages[start:] if m['role']=='tool']
            if prompt == 'Reply OK.':
                self.respond({'choices': [{'index': 0, 'message': {'role': 'assistant', 'content': 'OK'}, 'finish_reason': 'stop'}]}); return
            memory='source_id=' in prompt
            tools=[t['function']['name'] for t in body.get('tools',[])]
            deferred='tool_call' in tools
            stage=len(results); offset=2 if deferred else 0
            known=list(objects(results)); source=next((v for v in reversed(known) if 'source_id' in v and 'text_sha256' in v and 'text' in v),None)
            name=None; args={}; final=None
            prefix='mcp__momo_recordings__' if memory else 'mcp__momo_context__'
            names=['read_recording'] if memory else ['list_recordings','read_recording','save_recording_result']
            if deferred and stage==0: name='tool_search'; args={'queries':['MoMoAgent '+n for n in names],'limit':6}
            elif deferred and stage==1: name='tool_describe'; args={'names':[prefix+n for n in names]}
            else:
                step=stage-offset
                if memory:
                    if step==0:
                        batch=json.loads(prompt.split('TRANSCRIPT_BATCH_JSON=',1)[1])
                        quote=batch['passages'][0]['text'].split('。')[0]+'。'
                        name='memory'; args=dict(action='add', target='memory', content=quote+' 来源：'+batch['passages'][0]['citation_url'])
                    else: final='录音记忆已整理，待办仅为建议。'
                else:
                    if step==0: name='list_recordings'
                    elif step==1:
                        listings=[v for v in known if isinstance(v.get('items'),list) and v['items'] and 'total_characters' in v['items'][0]]
                        if listings:
                            item=listings[-1]['items'][0]; name='read_recording'; args={'source_id':item['id'],'source_revision':item['revision']}
                    elif step==2 and source:
                        # Wait until the UI test has terminated the phone before the Mac writes its artifact.
                        deadline=time.time()+90
                        while not (directory/'phone-detached').exists() and time.time()<deadline: time.sleep(.2)
                        name='save_recording_result'; args=dict(source_id=source['source_id'],source_revision=source['source_revision'],title='给小林的方案草稿',text='根据录音：'+source['text']+'\n\n需要准备方案，周五交付；聚餐未定，不代为安排。')
                    else:
                        artifact=next((v for v in reversed(known) if 'artifact_id' in v and 'path' in v),None)
                        final='方案草稿已保存在 Mac。里面写清了手机负责采集、Mac 负责执行的分工；聚餐还没定，没有替你安排。'
                        if not artifact: final='MISSING_ARTIFACT'
                        if source and source.get('spans'): final+='\n[录音依据]('+source['spans'][0]['citation_url']+')'
                if name and name != 'memory' and deferred:
                    args={'calls':[{'name':prefix+name,'arguments':args}]}; name='tool_call'
                elif name: name=next((n for n in tools if n.endswith(name)),name)
            if name:
                acknowledgement=None
                if not memory and stage==0:
                    deadline=time.time()+60
                    while not (directory/'reply-ready').exists() and time.time()<deadline: time.sleep(.1)
                    acknowledgement='我先读一下录音，整理给小林的方案，再把草稿保存在 Mac 上。'
                message={'role':'assistant','content':acknowledgement,'tool_calls':[{'id':f'fixture_{stage}','type':'function','function':{'name':name,'arguments':json.dumps(args)}}]}; finish='tool_calls'
            else: message={'role':'assistant','content':final or 'FIXTURE_MISSING_SOURCE'}; finish='stop'
            with (directory/'fixture-events.jsonl').open('a') as log: log.write(json.dumps({'memory':memory,'stage':stage,'tool':name,'source_seen':bool(source), 'tools':tools, 'native_memory_visible':any('小林' in str(m.get('content','')) and 'MEMORY' in str(m.get('content','')) for m in messages if m['role']=='system')})+'\n')
            self.respond({'id':f'fixture-{time.time_ns()}','object':'chat.completion','created':int(time.time()),'model':'momo-remote-fixture',
                'choices':[{'index':0,'message':message,'finish_reason':finish}],'usage':{'prompt_tokens':100,'completion_tokens':30,'total_tokens':130}})
    server=ThreadingHTTPServer(('127.0.0.1',18777),Handler)
    threading.Thread(target=server.serve_forever,daemon=True).start(); return server
