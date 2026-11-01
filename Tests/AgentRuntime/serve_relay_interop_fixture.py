"""Synthetic MoMo responder behind the actual upstream Node relays; never touches user data."""
import argparse
import asyncio
import json
import os
from pathlib import Path
import signal
import socket
import sys
import tempfile

from aiohttp import web, ClientSession

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Apps/MacApp/Access'))
from relay_access import RelayTunnel


async def serve(args):
    received = []
    async def backend(request):
        if request.path == '/pair/identity':
            return web.json_response({'instance_id': 'fixture', 'requests': received})
        if request.headers.get('Authorization') != 'Bearer fixture-phone':
            raise web.HTTPUnauthorized()
        received.append(dict(path=request.path, method=request.method, cursor=request.headers.get('Last-Event-ID'),
                             operation=request.headers.get('Idempotency-Key')))
        if request.path.endswith('/events'):
            response = web.StreamResponse(headers={'Content-Type': 'text/event-stream'})
            await response.prepare(request)
            await response.write(b'id: 8\ndata: first\n\n')
            await asyncio.sleep(.1)
            await response.write(b'id: 9\ndata: second\n\n')
            return response
        if request.method == 'POST':
            return web.Response(status=201, body=await request.read(), content_type='application/json')
        return web.json_response({'ok': True})

    app = web.Application(); app.router.add_route('*', '/{tail:.*}', backend)
    runner = web.AppRunner(app, access_log=None); await runner.setup()
    site = web.TCPSite(runner, '127.0.0.1', 0); await site.start()
    local_port = site._server.sockets[0].getsockname()[1]
    if args.edition == 'kit':
        process = await asyncio.create_subprocess_exec('node', str(Path(__file__).with_name('relay_reference_server.mjs')),
            str(args.reference), stdout=asyncio.subprocess.PIPE)
        port = json.loads(await asyncio.wait_for(process.stdout.readline(), 10))['port']
    else:
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0)); port = reservation.getsockname()[1]
        process = await asyncio.create_subprocess_exec('node', str(args.reference / 'index.mjs'),
            env={**os.environ, 'PORT': str(port), 'HOST': '127.0.0.1', 'RELAY_REGISTRATION_KEY': 'fixture-key'},
            stdout=asyncio.subprocess.PIPE)
        await asyncio.wait_for(process.stdout.readline(), 10)
    with tempfile.TemporaryDirectory() as directory:
        provider = RelayTunnel(Path(directory), local_port, f'http://127.0.0.1:{port}', 'fixture-key', _allow_loopback=True)
        await provider.start()
        try:
            async with asyncio.timeout(10):
                while provider.state['state'] != 'connected': await asyncio.sleep(.05)
            args.output.write_text(json.dumps(dict(endpoint=provider.url, code=provider.code, edition=args.edition)))
            args.output.chmod(0o600)
            stop = asyncio.Event()
            for sig in (signal.SIGTERM, signal.SIGINT): asyncio.get_running_loop().add_signal_handler(sig, stop.set)
            print('Synthetic relay fixture ready', flush=True)
            await stop.wait()
        finally:
            await provider.stop()
            process.terminate(); await process.wait()
            await runner.cleanup()
            args.output.unlink(missing_ok=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--edition', choices=['kit', 'alma'], required=True)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    asyncio.run(serve(parser.parse_args()))
