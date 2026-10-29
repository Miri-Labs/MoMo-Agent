import asyncio,json,pathlib,subprocess,sys,tempfile,uuid
ROOT=pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Apps/MacApp/Access'))
from desktop_control import native_request,DesktopLease,socket_path
async def main():
 with tempfile.TemporaryDirectory(prefix='momo-desktop-probe-') as directory:
  data=pathlib.Path(directory);(data/'api-key').write_text('synthetic-private-ipc-key');(data/'desktop').mkdir();viewer=str(uuid.uuid4())
  child=subprocess.Popen([str(ROOT/'tmp_agent_output/desktop-control-probe'),str(data)],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  try:
   for _ in range(100):
    if pathlib.Path(socket_path(data)).exists(): break
    if child.poll() is not None: raise AssertionError(child.stderr.read().decode())
    await asyncio.sleep(.05)
   assert pathlib.Path(socket_path(data)).exists(),'Native socket missing'
   status=await native_request(data,dict(op='status',actor='human',viewer=viewer,paired=True));assert status['approved'] and status['owner']=='agent';print('PASS native status uses authenticated Unix IPC',flush=True)
   lease=DesktopLease(data);owned=lease.acquire(viewer,str(uuid.uuid4()))
   blocked=await native_request(data,dict(op='frame',actor='agent'));assert '用户已接管' in blocked['error'];print('PASS agent capture denied during takeover',flush=True)
   stale=await native_request(data,dict(op='input',actor='human',viewer=viewer,paired=True,session='stale',event_id=str(uuid.uuid4()),event=dict(kind='click',x=0,y=0)));assert '控制连接已失效' in stale['error'];print('PASS stale input refused before any OS event',flush=True)
   other=await native_request(data,dict(op='frame',actor='human',viewer=str(uuid.uuid4()),paired=False));assert 'error' in other;print('PASS unpaired viewer cannot capture desktop',flush=True)
   lease.release(viewer,owned['session']);released=await native_request(data,dict(op='status',actor='human',viewer=viewer,paired=True));assert released['owner']=='agent';print('PASS explicit release restores agent ownership',flush=True)
   with lease.locked():
    current=lease.read();current['agent_work']=dict(work_id='work-a',run_id='run-a',generation=1);lease.write(current)
   for control in [dict(work_id='work-b',run_id='run-b',generation=1,epoch=current['epoch']),dict(work_id='work-a',run_id='run-a',generation=1,epoch=current['epoch']-1)]:
    refused=await native_request(data,dict(op='frame',actor='agent',control=control));assert '电脑任务已变化' in refused['error']
   print('PASS native host refuses a different work and stale epoch before screen capture',flush=True)
  finally:
   child.terminate();child.wait(timeout=5)
   socket=pathlib.Path(socket_path(data));socket.unlink(missing_ok=True)
   if socket.parent.exists():socket.parent.rmdir()
asyncio.run(main())
