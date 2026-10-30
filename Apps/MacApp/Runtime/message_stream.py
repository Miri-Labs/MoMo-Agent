"""Admission and native run events on one response; disconnect never stops work."""
import asyncio
import json

from aiohttp import web


async def stream_message(request, receipt, streams):
    from gateway.platforms.api_server_runs import _RUN_STREAM_SUBSCRIBER_OVERFLOW

    response = web.StreamResponse(headers={'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-store', 'X-Accel-Buffering': 'no'})
    run_id = receipt['run_id']
    stream = streams.get(run_id)
    queue, replay = stream.attach(-1) if stream else (None, [])

    async def write(value):
        async with asyncio.timeout(5):
            await response.write(value)

    async def event(value):
        await write(('data: ' + json.dumps(value, ensure_ascii=False, separators=(',', ':')) + '\n\n').encode())

    try:
        await response.prepare(request)
        await event(dict(event='run.accepted', run_id=run_id, receipt=receipt))
        if stream is None:
            # Old completed runs survive process restarts; only the event buffer is ephemeral.
            return response
        if replay and replay[0][0] > 0:
            await event(dict(event='replay.truncated', run_id=run_id, oldest_retained_seq=replay[0][0]))
        for seq, value in replay:
            if value is None: return response
            await event({**value, 'seq': seq})
        while not (stream.terminal and queue.empty()):
            try:
                seq, value = await asyncio.wait_for(queue.get(), timeout=15)
            except TimeoutError:
                await write(b': keepalive\n\n')
                continue
            if value is None or value is _RUN_STREAM_SUBSCRIBER_OVERFLOW: break
            await event({**value, 'seq': seq})
    except (ConnectionError, TimeoutError):
        response.force_close()
    finally:
        if stream is not None: stream.detach(queue)
    return response
