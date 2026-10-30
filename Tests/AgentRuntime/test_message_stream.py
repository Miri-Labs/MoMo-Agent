"""Real HTTP delivery across the paired access proxy; no model/account/phone."""
import asyncio
import json
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest

from aiohttp import ClientSession, web
from aiohttp.test_utils import TestServer

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / 'Apps/MacApp/Runtime'), str(ROOT / 'Apps/MacApp/Access'), str(ROOT / 'Vendor/HermesAgent')]
from message_stream import stream_message
from access_server import AccessService
from gateway.platforms.api_server_runs import _RunStream


class MessageStreamTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.stream = _RunStream()
        self.calls = []
        async def upstream(request):
            self.calls.append((request.method, await request.json(), request.headers.get('X-MoMo-Device')))
            return await stream_message(request, {'run_id': 'fixture-run', 'session_id': 'fixture-session', 'status': 'running'}, {'fixture-run': self.stream})
        app = web.Application(); app.router.add_post('/momo/v1/conversation/messages', upstream)
        self.upstream = TestServer(app); await self.upstream.start_server()
        self.session = ClientSession()
        service = AccessService.__new__(AccessService)
        service.tunnel = SimpleNamespace(enabled=True)
        self.authorized = True
        service.store = SimpleNamespace(authorized=lambda token: self.authorized and token == 'paired', device_id=lambda token: 'device')
        async def forward(method, path, body=None, context=False, headers=None, streaming=False):
            self.assertTrue(streaming)
            return await self.session.request(method, self.upstream.make_url(path), data=body, headers=headers)
        service.upstream = forward
        app = web.Application(); app.router.add_route('*', '/{tail:.*}', service.public)
        self.public = TestServer(app); await self.public.start_server()

    async def asyncTearDown(self):
        self.stream.put_nowait(None)
        await self.session.close(); await self.public.close(); await self.upstream.close()

    async def frame(self, response):
        async with asyncio.timeout(1):
            while True:
                line = await response.content.readline()
                if not line: return None
                if line.startswith(b'data:'): return json.loads(line[5:])

    async def test_receipt_and_first_text_share_one_post_before_completion(self):
        async with self.session.post(self.public.make_url('/momo/v1/conversation/messages'),
                json={'operation_id': 'fixed', 'content': 'hello'}, headers={'Authorization': 'Bearer paired', 'Accept': 'text/event-stream'}) as response:
            receipt = await self.frame(response)
            self.assertEqual('run.accepted', receipt['event'])
            self.assertFalse(self.stream.terminal)
            self.stream.put_nowait({'event': 'message.delta', 'run_id': 'fixture-run', 'delta': '你好'})
            self.assertEqual('你好', (await self.frame(response))['delta'])
            self.stream.put_nowait(None)
            await response.read()
        self.assertEqual([('POST', {'operation_id': 'fixed', 'content': 'hello'}, 'device')], self.calls)
        self.assertEqual(0, len(self.stream.subscribers))

    async def test_existing_stream_replays_and_revocation_blocks_further_delivery(self):
        self.stream.put_nowait({'event': 'message.delta', 'run_id': 'fixture-run', 'delta': 'saved'})
        async with self.session.post(self.public.make_url('/momo/v1/conversation/messages'),
                json={'operation_id': 'fixed'}, headers={'Authorization': 'Bearer paired', 'Accept': 'text/event-stream'}) as response:
            await self.frame(response)
            self.assertEqual('saved', (await self.frame(response))['delta'])
            self.authorized = False
            self.stream.put_nowait({'event': 'message.delta', 'run_id': 'fixture-run', 'delta': 'revoked'})
            self.stream.put_nowait(None)
            self.assertNotIn(b'revoked', await response.read())
        async with self.session.post(self.public.make_url('/momo/v1/conversation/messages'), json={},
                headers={'Authorization': 'Bearer paired', 'Accept': 'text/event-stream'}) as response:
            self.assertEqual(401, response.status)

    async def test_completed_run_without_ephemeral_buffer_still_returns_receipt(self):
        async def old(request):
            return await stream_message(request, {'run_id': 'old', 'status': 'completed'}, {})
        app = web.Application(); app.router.add_post('/', old)
        server = TestServer(app); await server.start_server()
        try:
            async with self.session.post(server.make_url('/')) as response:
                self.assertEqual('old', (await self.frame(response))['receipt']['run_id'])
                self.assertNotIn(b'message.delta', await response.read())
        finally: await server.close()


if __name__ == '__main__': unittest.main()
