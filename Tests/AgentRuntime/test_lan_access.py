"""LAN TLS endpoint, certificate regeneration and pinned LAN invitations."""
import asyncio
import hashlib
import http.client
import json
import socket
import ssl
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Apps/MacApp/Access'))
from aiohttp import web
from cryptography.hazmat.primitives import serialization
from lan_access import LanAccess
from pairing_store import PairingStore, endpoint, is_lan_endpoint


class LanEndpointTests(unittest.TestCase):
    def test_accepts_private_https_and_rejects_everything_else(self):
        for value in ['https://192.168.1.10:8769', 'https://10.0.0.5:8769/', 'https://172.16.8.4:18769']:
            self.assertTrue(is_lan_endpoint(value), value)
            self.assertEqual(value.rstrip('/'), endpoint(value, network='lan'))
        for value in ['http://192.168.1.10:8769', 'https://8.8.8.8:8769', 'https://192.168.1.10',
                      'https://192.168.1.10:8769/admin', 'https://user:pass@192.168.1.10:8769',
                      'https://192.168.1.10:8769/?next=1']:
            with self.assertRaises(ValueError):
                endpoint(value, network='lan')

    def test_lan_invitation_keeps_network_and_does_not_accept_plain_http(self):
        with tempfile.TemporaryDirectory() as directory:
            store = PairingStore(directory, now=lambda: 1000)
            invite = store.invite('https://192.168.1.10:8769', network='lan')
            self.assertEqual('https://192.168.1.10:8769', invite['endpoint'])
            with self.assertRaises(ValueError):
                store.invite('http://192.168.1.10:8769', network='lan')
            store.db.close()


class LanCertificateTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        self.port = self.free_port()

    def tearDown(self):
        self.temp.cleanup()

    @staticmethod
    def free_port():
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            return probe.getsockname()[1]

    def test_certificate_is_private_and_regenerates_when_an_address_is_added(self):
        with patch('lan_access.lan_addresses', return_value=['192.168.1.10']):
            access = LanAccess(self.directory, self.port)
            cert_path, key_path, certificate = access.certificate()
            first = hashlib.sha256(
                certificate.public_bytes(serialization.Encoding.DER),
            ).hexdigest()
            self.assertTrue(cert_path.exists())
            self.assertTrue(key_path.exists())
            self.assertEqual(0o600, key_path.stat().st_mode & 0o777)
            self.assertEqual(0o600, cert_path.stat().st_mode & 0o777)
            self.assertEqual(64, len(first))
        with patch('lan_access.lan_addresses', return_value=['192.168.1.10', '10.0.0.5']):
            _, _, regenerated = access.certificate()
            second = hashlib.sha256(
                regenerated.public_bytes(serialization.Encoding.DER),
            ).hexdigest()
            self.assertNotEqual(first, second)

    @staticmethod
    def _fetch(port):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        connection = http.client.HTTPSConnection('127.0.0.1', port, context=context, timeout=5)
        try:
            connection.request('GET', '/ping')
            response = connection.getresponse()
            status = response.status
            body = json.loads(response.read())
            der = connection.sock.getpeercert(binary_form=True)
            return status, body, hashlib.sha256(der).hexdigest()
        finally:
            connection.close()

    async def test_listener_serves_the_pinned_certificate(self):
        app = web.Application()
        async def ping(_request): return web.json_response({'ok': True})
        app.router.add_get('/ping', ping)
        with patch('lan_access.lan_addresses', return_value=['192.168.1.10']):
            access = LanAccess(self.directory, self.port)
            url = await access.start(app)
            try:
                self.assertEqual(f'https://192.168.1.10:{self.port}', url)
                self.assertEqual('connected', access.state['state'])
                self.assertEqual(64, len(access.state['fingerprint']))
                status, body, fingerprint = await asyncio.to_thread(self._fetch, self.port)
                self.assertEqual(200, status)
                self.assertEqual({'ok': True}, body)
                self.assertEqual(access.state['fingerprint'], fingerprint)
            finally:
                await access.stop()
            self.assertEqual('stopped', access.state['state'])


if __name__ == '__main__':
    unittest.main()
