import asyncio
import json
from pathlib import Path
import sys
import tempfile
import unittest
from aiohttp import ClientSession, web
from aiohttp.test_utils import TestClient, TestServer

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Apps/MacApp/Access'))
from tunnel import TunnelLifecycle
from access_server import AccessService, errors


class FakeTunnel:
    def __init__(self):
        self.url = 'https://test.example'
        self.state = dict(state='stopped', endpoint=None, mode='external', error=None)
        self.starts = 0; self.stops = 0
    async def start(self):
        self.starts += 1; self.state.update(state='starting', endpoint='https://test.example')
    async def stop(self):
        self.stops += 1; self.state.update(state='stopped', endpoint=None)


class TunnelTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.time = 0
        self.manager = TunnelLifecycle(self.temp.name, 18887, now=lambda: self.time)
        self.manager.provider = FakeTunnel()
    async def no(self, _): return False
    async def yes(self, _): return True

    async def test_first_use_requires_choice_and_restart_restores_enabled_intent(self):
        await self.manager.tick(self.yes)
        self.assertEqual(0, self.manager.provider.starts)
        await self.manager.start()
        restored = TunnelLifecycle(self.temp.name, 18887)
        self.assertTrue(restored.enabled)
        restored.provider = FakeTunnel()
        await restored.tick(self.yes)
        self.assertEqual('connected', restored.provider.state['state'])
        await self.manager.stop()
        restored = TunnelLifecycle(self.temp.name, 18887)
        self.assertFalse(restored.enabled)
        await self.manager.tick(self.yes)
        self.assertEqual(1, self.manager.provider.starts)

    async def test_unreachable_fixed_ingress_recovers_without_replacing_connector(self):
        await self.manager.start(); await self.manager.tick(self.no)
        self.time = 31; await self.manager.tick(self.no)
        self.assertEqual(0, self.manager.provider.stops)
        await self.manager.tick(self.no)
        self.assertEqual(1, self.manager.provider.starts)
        self.time = 36; await self.manager.tick(self.yes)
        self.assertEqual(1, self.manager.provider.starts)
        self.assertEqual('connected', self.manager.provider.state['state'])
        await self.manager.tick(self.no)
        self.assertEqual('reconnecting', self.manager.provider.state['state'])
        await self.manager.tick(self.yes)
        self.assertEqual('connected', self.manager.provider.state['state'])

    async def test_fixed_ingress_preserves_endpoint_during_outage(self):
        await self.manager.configure('external', 'https://stable.example')
        await self.manager.start(); await self.manager.tick(self.no)
        self.time = 40; await self.manager.tick(self.no)
        self.assertEqual('https://stable.example', self.manager.provider.state['endpoint'])
        self.assertIn('固定入口', self.manager.provider.state['error'])
        await self.manager.tick(self.yes)
        self.assertEqual('connected', self.manager.provider.state['state'])
        self.assertEqual(0o600, self.manager.file.stat().st_mode & 0o777)

    async def test_invalid_configuration_does_not_replace_working_provider(self):
        await self.manager.start(); original = self.manager.provider
        for url in [None, 'http://public.example', 'https://example.com/admin']:
            with self.assertRaises(ValueError): await self.manager.configure('external', url)
        for mode in ['temporary', 'localhost.run', 'unknown', None]:
            with self.assertRaises(ValueError): await self.manager.configure(mode)
        self.assertIs(original, self.manager.provider); self.assertTrue(self.manager.enabled)
        self.assertEqual(0, original.stops)

    async def test_sse_has_no_whole_response_deadline(self):
        service = object.__new__(AccessService)
        service.connection = {'base_url': 'http://127.0.0.1:1', 'assistant_id': 'fixture'}; service.key = 'fixture'
        class Session:
            async def request(self, *args, **kwargs): return kwargs['timeout']
        service.session = Session()
        timeout = await service.upstream('GET', '/v1/runs/fixture/events', streaming=True)
        self.assertIsNone(timeout.total); self.assertEqual(45, timeout.sock_read)
        timeout = await service.upstream('GET', '/v1/capabilities')
        self.assertEqual(60, timeout.total)


class AccessBoundaryTests(unittest.IsolatedAsyncioTestCase):
    async def test_ingress_change_preserves_identity_run_and_sse_cursor(self):
        """Exercise the HTTP boundary without a real tunnel or model account."""
        requests = []
        run = {'run_id': 'original-run', 'session_id': 'original-session', 'status': 'running'}

        async def agent(request):
            requests.append((request.method, request.path, dict(request.headers)))
            if request.path.endswith('/events'):
                sequence = int(request.headers.get('Last-Event-ID', '0')) + 1
                return web.Response(text=f'id: {sequence}\ndata: {{"run_id":"original-run","sequence":{sequence}}}\n\n',
                                    content_type='text/event-stream')
            return web.json_response(run)

        backend_app = web.Application(); backend_app.router.add_route('*', '/{tail:.*}', agent)
        async with TestServer(backend_app) as backend, ClientSession(trust_env=False) as session:
            with tempfile.TemporaryDirectory() as directory:
                data = Path(directory)
                identity = dict(workspace_id='workspace', assistant_id='assistant', instance_id='instance')
                connection = dict(identity, port=18885, base_url=str(backend.make_url('')).rstrip('/'))
                (data / 'connection.json').write_text(json.dumps(connection))
                (data / 'api-key').write_text('local-admin-only')
                service = AccessService(data); service.session = session
                service.tunnel.enabled = True  # The fixture supplies its own local HTTP listener.
                self.addCleanup(service.store.db.close)
                invitation = service.store.invite('https://first.example')
                token = 'a' * 64
                device = service.store.request(invitation['id'], 'Synthetic phone', token)
                service.store.decide(device['id'], True)
                public_app = web.Application(); public_app.router.add_route('*', '/{tail:.*}', service.public)
                async with TestClient(TestServer(public_app)) as client:
                    headers = {'Authorization': 'Bearer ' + token, 'Idempotency-Key': 'original-operation'}
                    async with client.post('/v1/runs', json={'input': 'keep working', 'session_id': run['session_id']}, headers=headers) as response:
                        self.assertEqual(200, response.status)
                        self.assertEqual(run, await response.json())
                    for mode, url in [('external', 'https://second.example'), ('tailscale', None), ('relay', 'https://relay.example')]:
                        await service.tunnel.configure(mode, url)
                        service.tunnel.enabled = True
                        self.assertTrue(service.store.authorized(token))
                        self.assertEqual(identity, {k: service.public_connection(url or 'https://third.example')[k] for k in identity})
                        async with client.get('/v1/runs/original-run', headers=headers) as response:
                            self.assertEqual(run, await response.json())
                        async with client.get('/v1/runs/original-run/events', headers={**headers, 'Last-Event-ID': '7'}) as response:
                            self.assertEqual('text/event-stream', response.content_type)
                            self.assertIn('id: 8\n', await response.text())
                    await service.tunnel.stop()
                    async with client.get('/v1/runs/original-run', headers=headers) as response:
                        self.assertEqual(503, response.status)
                    self.assertTrue(service.store.authorized(token), 'Disabling access must preserve pairing and tasks')
                self.assertEqual(1, sum(method == 'POST' for method, _, _ in requests))
                self.assertFalse(any(path.endswith('/stop') for _, path, _ in requests))
                self.assertEqual('original-operation', requests[0][2]['Idempotency-Key'])
                self.assertTrue(all(headers['Authorization'] == 'Bearer local-admin-only' for _, _, headers in requests))

    async def test_legacy_upgrade_disables_access_preserves_grants_and_rejects_removed_api(self):
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory)
            identity = dict(workspace_id='workspace', assistant_id='assistant', instance_id='instance')
            connection = dict(identity, port=18885, base_url='http://127.0.0.1:18885')
            (data / 'connection.json').write_text(json.dumps(connection))
            (data / 'api-key').write_text('local-admin-only')
            old = AccessService(data)
            invitation = old.store.invite('https://old.example')
            token = 'b' * 64
            device = old.store.request(invitation['id'], 'Existing phone', token)
            old.store.decide(device['id'], True)
            old.store.db.close()
            old.tunnel.file.write_text(json.dumps(dict(provider='temporary', enabled=True)))

            service = AccessService(data)
            self.addCleanup(service.store.db.close)
            self.assertFalse(service.tunnel.enabled)
            self.assertTrue(service.store.authorized(token))
            self.assertEqual(identity, {k: service.connection[k] for k in identity})
            public = web.Application(middlewares=[errors]); public.router.add_route('*', '/{tail:.*}', service.public)
            async with TestClient(TestServer(public)) as client:
                async with client.get('/v1/runs/original-run', headers={'Authorization': 'Bearer ' + token}) as response:
                    self.assertEqual(503, response.status)

            await service.tunnel.configure('external', 'https://stable.example')
            await service.tunnel.start()
            original = service.provider
            config = service.tunnel.file.read_bytes()
            control = web.Application(middlewares=[errors]); control.router.add_post('/tunnel/configure', service.control)
            async with TestClient(TestServer(control)) as client:
                async with client.post('/tunnel/configure', json={'provider': 'temporary'},
                                       headers={'Authorization': 'Bearer local-admin-only'}) as response:
                    self.assertEqual(400, response.status)
            self.assertIs(original, service.provider)
            self.assertTrue(service.tunnel.enabled)
            self.assertEqual(config, service.tunnel.file.read_bytes())
            self.assertTrue(service.store.authorized(token))

if __name__ == '__main__': unittest.main()
