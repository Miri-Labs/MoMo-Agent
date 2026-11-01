import asyncio
import base64
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import AsyncMock
from aiohttp import ClientSession

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Apps/MacApp/Access'))
from relay_access import RelayTunnel
from relay_crypto import RelayCipher, routing_token
from tunnel import TunnelLifecycle


class RelayTests(unittest.IsolatedAsyncioTestCase):
    async def test_default_switch_restart_and_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            manager = TunnelLifecycle(directory, 8767)
            self.assertEqual('embedded', manager.provider.state['mode'])
            await manager.configure('relay', 'https://relay.example', 'registration-secret')
            code = manager.provider.code
            manager.enabled = True; manager.persist()
            restored = TunnelLifecycle(directory, 8767)
            self.assertEqual(code, restored.provider.code)
            self.assertEqual('registration-secret', restored.provider.registration_key)
            self.assertNotIn('registration-secret', json.dumps(restored.provider.state))
            self.assertNotIn(code, json.dumps(restored.provider.state))
            self.assertEqual(0o600, manager.file.stat().st_mode & 0o777)
            await restored.configure('embedded')
            await restored.configure('relay', 'https://relay.example')
            self.assertEqual(code, restored.provider.code)
            restored.provider.state['state'] = 'needs_setup'
            restored.provider.start = AsyncMock()
            restored.enabled = True
            await restored.tick(AsyncMock())
            restored.provider.start.assert_not_awaited()  # Never fight a replacement agent.

    async def test_invalid_configuration_preserves_previous_route(self):
        with tempfile.TemporaryDirectory() as directory:
            manager = TunnelLifecycle(directory, 8767)
            previous = manager.provider
            for address in ['http://relay.example', 'http://127.0.0.1:8787', 'https://relay.example/path', 'https://u:p@relay.example']:
                with self.assertRaises(ValueError): await manager.configure('relay', address)
                self.assertIs(previous, manager.provider)

    async def test_webcrypto_interop_replay_and_authentication(self):
        reference = os.environ.get('MOMO_RELAY_KIT_REFERENCE')
        if not reference: self.skipTest('Set MOMO_RELAY_KIT_REFERENCE to upstream checkout')
        code = 'BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc'
        process = await asyncio.create_subprocess_exec('node', str(Path(__file__).with_name('relay_reference_crypto.mjs')),
            reference, code, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE)
        async def read(): return json.loads(await asyncio.wait_for(process.stdout.readline(), 10))
        async def send(frame):
            process.stdin.write((json.dumps(frame) + '\n').encode()); await process.stdin.drain()
        try:
            self.assertEqual(routing_token(code), (await read())['routing'])
            cipher = RelayCipher(code)
            hello = json.loads((await read())['s'])
            reply = cipher.handshake(hello)
            await send({'s': json.dumps(reply)})
            confirmation = json.loads((await read())['s'])
            with self.assertRaises(ValueError): cipher.open(bytes(40))
            cipher.handshake(confirmation)
            wire = base64.b64decode((await read())['b'])
            self.assertEqual('/pair/identity', cipher.open(wire)['path'])
            with self.assertRaisesRegex(ValueError, 'Replayed'): cipher.open(wire)
            await send({'b': base64.b64encode(cipher.seal({'t': 'hres', 'id': 'fixture', 'status': 200})).decode()})
            self.assertEqual(200, (await read())['result']['status'])
            await process.wait()
            self.assertEqual(0, process.returncode)
            forged = RelayCipher(code)
            forged.handshake(hello)
            with self.assertRaises(ValueError): forged.handshake({'t': 'ok', 'ci': 'A' * 43})
        finally:
            if process.returncode is None: process.terminate(); await process.wait()

    async def test_real_alma_relay_cannot_send_plaintext_to_mac(self):
        fixture_path = os.environ.get('MOMO_ALMA_RELAY_FIXTURE')
        if not fixture_path: self.skipTest('Run the Alma interop fixture')
        fixture = json.loads(Path(fixture_path).read_text())
        url = fixture['endpoint'] + '/c/' + routing_token(fixture['code']) + '/v1/capabilities'
        async with ClientSession() as session:
            async with session.get(url, headers={'Authorization': 'Bearer fixture-phone'}) as response:
                self.assertEqual(403, response.status, 'Even a valid device grant cannot bypass E2E')

    async def test_real_relay_preemption_stops_redial_and_explicit_restart_keeps_identity(self):
        fixture_path = os.environ.get('MOMO_ALMA_RELAY_FIXTURE')
        if not fixture_path: self.skipTest('Run the Alma interop fixture')
        url = json.loads(Path(fixture_path).read_text())['endpoint']
        async def state(provider, wanted):
            async with asyncio.timeout(5):
                while provider.state['state'] != wanted: await asyncio.sleep(.02)
        with tempfile.TemporaryDirectory() as directory:
            first = RelayTunnel(Path(directory), 1, url, 'fixture-key', _allow_loopback=True)
            second = RelayTunnel(Path(directory), 1, url, 'fixture-key', _allow_loopback=True)
            self.assertEqual(first.code, second.code)
            try:
                await first.start(); await state(first, 'connected')
                await second.start(); await state(second, 'connected'); await state(first, 'needs_setup')
                await asyncio.sleep(1.1)
                self.assertEqual('needs_setup', first.state['state'])
                await first.start(); await state(first, 'connected'); await state(second, 'needs_setup')
                await first.stop(); await first.start(); await state(first, 'connected')
                self.assertEqual(first.code, second.code)
            finally:
                await first.stop(); await second.stop()


if __name__ == '__main__': unittest.main()
