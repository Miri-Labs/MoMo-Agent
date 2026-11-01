import asyncio
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Apps/MacApp/Access'))
from tunnel import TunnelLifecycle, EmbeddedTailscale
from access_server import AccessService, errors
from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer


class EmbeddedTests(unittest.IsolatedAsyncioTestCase):
    async def test_private_invitation_approval_and_receipt_keep_network_and_identity(self):
        await self.approval('tailscale')

    async def test_relay_invitation_approval_binds_encryption_code_and_identity(self):
        await self.approval('relay')

    async def approval(self, network):
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory)
            identity = dict(workspace_id='workspace', assistant_id='assistant', instance_id='instance')
            (data / 'connection.json').write_text(json.dumps(dict(identity, port=18885, base_url='http://127.0.0.1:18885')))
            (data / 'api-key').write_text('fixture-admin')
            service = AccessService(data)
            self.addCleanup(service.store.db.close)
            service.status = AsyncMock(return_value={})
            if network == 'relay':
                await service.tunnel.configure('relay', 'https://relay.example')
                service.tunnel.enabled = True
                service.provider.state.update(state='connected', endpoint='https://relay.example')
            else:
                await service.tunnel.start()
                service.provider.report({'state': 'connected', 'endpoint': 'http://100.64.0.1:8767'}, 1)
            control = web.Application(middlewares=[errors]); control.router.add_route('*', '/{tail:.*}', service.control)
            public = web.Application(middlewares=[errors]); public.router.add_route('*', '/{tail:.*}', service.public)
            admin = {'Authorization': 'Bearer fixture-admin'}
            phone = {'Authorization': 'Bearer ' + 'a' * 64, 'Host': 'untrusted.example'}
            async with TestClient(TestServer(control)) as local, TestClient(TestServer(public)) as remote:
                response = await local.post('/pair/invite', json={}, headers=admin)
                self.assertEqual(200, response.status)
                qr = json.loads(service.invitation['payload'])
                self.assertEqual(network, qr['network'])
                self.assertEqual(service.provider.state['endpoint'], qr['endpoint'])
                response = await remote.get('/v1/capabilities', headers=phone)
                self.assertEqual(401, response.status)
                response = await remote.post('/pair/requests', json={'invitation_id': qr['invitation_id'], 'name': 'Fixture'}, headers=phone)
                request = await response.json()
                self.assertEqual('pending', request['state'])
                response = await local.post('/pair/decide', json={'id': request['id'], 'allow': True}, headers=admin)
                self.assertEqual(200, response.status)
                response = await remote.get('/pair/requests/' + request['id'], headers=phone)
                receipt = await response.json()
                self.assertEqual('approved', receipt['state'])
                self.assertEqual(network, receipt['connection']['network'])
                if network == 'relay': self.assertEqual(qr['relay_code'], receipt['connection']['relay_code'])
                self.assertEqual(qr['endpoint'], receipt['connection']['base_url'])
                self.assertEqual(qr['endpoint'] + '/context', receipt['connection']['data_url'])
                self.assertEqual(identity, {key: receipt['connection'][key] for key in identity})
                self.assertNotIn('network', service.public_connection('http://127.0.0.1:18887'))
                self.assertNotIn('relay_code', service.public_connection('http://127.0.0.1:18887'))

    async def test_default_does_not_connect_or_probe_and_report_lease_expires(self):
        with tempfile.TemporaryDirectory() as directory:
            now = 100
            manager = TunnelLifecycle(directory, 8767, now=lambda: now)
            probe = AsyncMock(return_value=True)
            await manager.tick(probe)
            self.assertFalse(manager.enabled)
            self.assertIsInstance(manager.provider, EmbeddedTailscale)
            await manager.start()
            manager.provider.report({'state': 'connected', 'endpoint': 'http://100.64.0.1:8767'}, now)
            await manager.tick(probe)
            self.assertEqual('connected', manager.provider.state['state'])
            now += 16
            await manager.tick(probe)
            self.assertEqual('needs_setup', manager.provider.state['state'])
            self.assertIsNone(manager.provider.state['endpoint'])
            probe.assert_not_awaited()
            restored = TunnelLifecycle(directory, 8767)
            self.assertTrue(restored.enabled)
            self.assertEqual('needs_setup', restored.provider.state['state'])
            self.assertIsNone(restored.provider.state['endpoint'])

    def test_reports_only_accept_fixed_port_tailnet_ip_roots(self):
        provider = EmbeddedTailscale()
        for url in ['http://mac.tail123.ts.net', 'http://100.64.0.1:8767.evil.example',
                    'http://100.64.0.1:8767/path', 'https://user@mac.tail123.ts.net', 'https://example.com', 'http://100.128.0.1:8767', 'http://100.63.255.255:8767',
                    'http://127.0.0.1:8767', 'http://100.64.0.1:80', 'http://100.64.0.1:8767?key=secret', None]:
            with self.assertRaises(ValueError): provider.report({'state': 'connected', 'endpoint': url}, 1)
        self.assertIsNone(provider.state['endpoint'])
        provider.report({'state': 'connected', 'endpoint': 'http://100.64.0.1:8767'}, 1)
        provider.report({'state': 'needs_setup', 'error': '登录已过期'}, 2)
        self.assertIsNone(provider.state['endpoint'])
        self.assertEqual('登录已过期', provider.state['error'])

if __name__ == '__main__': unittest.main()
