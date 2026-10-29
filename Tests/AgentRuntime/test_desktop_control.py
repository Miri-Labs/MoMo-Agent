import asyncio
import base64
import json
import importlib.util
import os
from pathlib import Path
import secrets
import sys
import tempfile
import unittest
from unittest.mock import AsyncMock, patch
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Apps/MacApp/Access'))
from desktop_control import DesktopLease, DesktopBridge, DesktopFrameFeed, socket_path
from pairing_store import PairingStore
from rtc_transport import permitted_route


class OwnershipTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.now = 100; self.lease = DesktopLease(self.temp.name, now=lambda: self.now)

    def test_takeover_is_exclusive_and_same_request_is_idempotent(self):
        request = str(uuid.uuid4()); first = self.lease.acquire('phone-a', request)
        self.assertEqual(first, self.lease.acquire('phone-a', request))
        with self.assertRaises(PermissionError): self.lease.acquire('phone-b', str(uuid.uuid4()))
        self.assertEqual(first, self.lease.require('phone-a', first['session']))
        self.assertEqual(0o600, self.lease.path.stat().st_mode & 0o777)

    def test_expiry_stops_input_but_never_silently_returns_control_to_agent(self):
        first = self.lease.acquire('phone', str(uuid.uuid4())); self.now += 21
        with self.assertRaises(PermissionError): self.lease.require('phone', first['session'])
        self.assertEqual('human', self.lease.read()['owner'])
        self.assertEqual('agent', self.lease.release('phone', first['session'])['owner'])

    def test_old_session_cannot_release_or_renew_replacement(self):
        old = self.lease.acquire('phone', str(uuid.uuid4()))
        current = self.lease.acquire('phone', str(uuid.uuid4()))
        with self.assertRaises(PermissionError): self.lease.release('phone', old['session'])
        with self.assertRaises(PermissionError): self.lease.heartbeat('phone', old['session'])
        self.assertEqual(current, self.lease.read())

    def test_corrupt_record_fails_closed(self):
        self.lease.path.write_text('{"owner":"unknown"}')
        with self.assertRaises(ValueError): self.lease.acquire('phone', str(uuid.uuid4()))

    def test_only_explicit_desktop_routes_are_allowed(self):
        self.assertIsNotNone(permitted_route('POST', '/desktop/v1/input'))
        self.assertIsNotNone(permitted_route('GET', '/desktop/v1/frame'))
        for method, path in [('GET', '/desktop/v1/input'), ('POST', '/desktop/v1/frame'), ('POST', '/desktop/v1/shell'), ('GET', '/desktop/v1/frame?target=other')]:
            self.assertIsNone(permitted_route(method, path))
        self.assertLess(len(socket_path('/a/' * 200).encode()), 104)


class BridgeTests(unittest.IsolatedAsyncioTestCase):
    async def test_mcp_preserves_native_permission_reason_for_agent(self):
        from mcp.server.mcpserver.exceptions import ToolError
        spec = importlib.util.spec_from_file_location('desktop_mcp_fixture', ROOT / 'Apps/MacApp/Runtime/desktop_mcp.py')
        module = importlib.util.module_from_spec(spec)
        with patch.dict(os.environ, {'MOMO_AGENT_DIRECTORY': self.temp.name}): spec.loader.exec_module(module)
        reason = '屏幕录制权限尚未生效，请在 Mac 的权限设置中检查。'
        with patch.object(module, 'native_request', new=AsyncMock(return_value={'error': reason})) as request:
            with self.assertRaisesRegex(ToolError, reason) as failure:
                await module.server.call_tool('computer_screenshot', {'momo_control': {'epoch': 1}})
            self.assertTrue(str(failure.exception).endswith(reason))
            self.assertEqual(request.await_args.args[1]['op'], 'frame')

    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        class Service: pass
        self.service = Service(); self.service.data = Path(self.temp.name)
        from types import SimpleNamespace
        self.service.tunnel = SimpleNamespace(enabled=True)
        self.service.store = PairingStore(self.service.data / 'access'); self.addCleanup(self.service.store.db.close)
        invitation = self.service.store.invite('https://fixture.invalid'); self.token = secrets.token_urlsafe(48)
        self.device = self.service.store.request(invitation['id'], 'Phone', self.token)
        self.service.store.decide(self.device['id'], True)
        self.bridge = DesktopBridge(self.service)

    async def test_video_offer_is_bound_to_pairing_and_revocation_is_rechecked(self):
        offer = dict(version=1, nonce=str(uuid.uuid4()), sdp='synthetic-offer', viewer='spoofed', paired=False)
        async def native(data, payload):
            self.assertEqual(self.device['id'], payload['viewer'])
            self.assertTrue(payload['paired'])
            self.assertEqual('video-offer', payload['op'])
            self.service.store.revoke(self.device['id'])
            return dict(version=1, nonce=offer['nonce'], sdp='synthetic-answer')
        with patch('desktop_control.native_request', side_effect=native):
            code, _ = await self.bridge.handle('POST', '/desktop/v2/offer', json.dumps(offer), self.token)
            self.assertEqual(403, code)

    async def test_bad_or_oversized_video_offer_never_reaches_native(self):
        for offer in [dict(version=2, nonce=str(uuid.uuid4()), sdp='x'), dict(version=1, nonce='bad', sdp='x'),
                      dict(version=1, nonce=str(uuid.uuid4()), sdp='x'*131073)]:
            with patch('desktop_control.native_request', new=AsyncMock()) as forwarded:
                code, _ = await self.bridge.handle('POST', '/desktop/v2/offer', json.dumps(offer), self.token)
                self.assertEqual(400, code); forwarded.assert_not_awaited()

    async def test_data_channel_retains_lease_and_rejects_revoked_or_disabled_viewer(self):
        with patch('desktop_control.native_request', new=AsyncMock(return_value=dict(approved=True, screen=True, input=True))) as native:
            viewer = self.device['id']
            code, _ = await self.bridge.control_device(viewer, 'claim', json.dumps(dict(request_id=str(uuid.uuid4()))))
            self.assertEqual(200, code)
            lease = self.bridge.lease.read()
            code, _ = await self.bridge.control_device(viewer, 'input', json.dumps(dict(session='old', event_id=str(uuid.uuid4()), event={})))
            self.assertEqual(409, code)
            code, _ = await self.bridge.control_device(viewer, 'input', json.dumps(dict(session=lease['session'], event_id=str(uuid.uuid4()), event=dict(kind='reset', sequence=1))))
            self.assertEqual(200, code)
            before = native.await_count
            code, _ = await self.bridge.control_device(viewer, 'shell', '{}'); self.assertEqual(400, code)
            self.service.tunnel.enabled = False
            code, _ = await self.bridge.control_device(viewer, 'status', '{}'); self.assertEqual(403, code)
            self.service.tunnel.enabled = True; self.service.store.revoke(viewer)
            code, _ = await self.bridge.control_device(viewer, 'status', '{}'); self.assertEqual(403, code)
            self.assertEqual(before, native.await_count)

    async def test_claim_requires_both_os_permissions(self):
        with patch('desktop_control.native_request', new=AsyncMock(return_value=dict(approved=True, screen=True, input=False))) as forwarded:
            code, result = await self.bridge.handle('POST', '/desktop/v1/claim', json.dumps(dict(request_id=str(uuid.uuid4()))), self.token)
        self.assertEqual(409, code); self.assertEqual('agent', self.bridge.lease.read()['owner'])
        self.assertIn('权限尚未生效', result['error']['message'])
        self.assertEqual('status', forwarded.await_args.args[1]['op'])
        forwarded.assert_awaited_once()

    async def test_token_is_resolved_to_trusted_device_and_stale_input_is_never_forwarded(self):
        owner = self.bridge.lease.acquire(self.device['id'], str(uuid.uuid4()))
        forwarded = AsyncMock(return_value={'ok': True})
        with patch('desktop_control.native_request', new=forwarded):
            code, result = await self.bridge.handle('POST', '/desktop/v1/input', json.dumps(dict(session='stale', event_id=str(uuid.uuid4()), event=dict(kind='click', x=0, y=0))), self.token)
            self.assertEqual(409, code); forwarded.assert_not_awaited()
            code, result = await self.bridge.handle('POST', '/desktop/v1/input', json.dumps(dict(session=owner['session'], event_id=str(uuid.uuid4()), event=dict(kind='click', x=0, y=0), viewer='spoofed')), self.token)
            self.assertEqual(200, code)
            self.assertEqual(self.device['id'], forwarded.await_args.args[1]['viewer'])
            self.assertTrue(forwarded.await_args.args[1]['paired'])

    async def test_paired_device_needs_no_second_host_grant_even_after_bridge_restart(self):
        forwarded = AsyncMock(return_value=dict(approved=True, screen=True, input=True, owner='you'))
        with patch('desktop_control.native_request', new=forwarded):
            for bridge in (self.bridge, DesktopBridge(self.service)):
                code, _ = await bridge.handle('POST', '/desktop/v1/claim', json.dumps(dict(request_id=str(uuid.uuid4()), paired=False)), self.token)
                self.assertEqual(200, code)
                self.assertTrue(forwarded.await_args.args[1]['paired'])
                self.assertEqual(self.device['id'], forwarded.await_args.args[1]['viewer'])

    async def test_revoked_device_has_no_desktop_access(self):
        self.service.store.revoke(self.device['id'])
        with patch('desktop_control.native_request', new=AsyncMock()) as forwarded:
            code, _ = await self.bridge.handle('GET', '/desktop/v1/frame', b'', self.token)
            self.assertEqual(403, code); forwarded.assert_not_awaited()

    async def test_feed_is_binary_bounded_and_rechecks_revocation_each_frame(self):
        jpeg = b'\xff\xd8synthetic\xff\xd9'
        feed = DesktopFrameFeed(self.bridge, self.token)
        with patch('desktop_control.native_request', new=AsyncMock(return_value=dict(jpeg=base64.b64encode(jpeg).decode(), width=10, height=10))) as native:
            code, frame = await feed.next()
            self.assertEqual(200, code); self.assertTrue(frame.endswith(jpeg + b'\r\n'))
            self.assertIn(b'Content-Length: 13\r\n', frame)
            self.assertTrue(native.await_args.args[1]['preview'])
            self.assertEqual(640, native.await_args.args[1]['edge'])
            feed.drained(1); self.assertEqual(480, feed.edge)
            self.service.store.revoke(self.device['id'])
            code, _ = await feed.next(); self.assertEqual(403, code)
            self.assertEqual(1, native.await_count)

    async def test_pending_capture_does_not_block_takeover_or_heartbeat(self):
        entered, release = asyncio.Event(), asyncio.Event()
        async def native(data, payload):
            if payload['op'] == 'frame':
                entered.set(); await release.wait()
                return dict(jpeg=base64.b64encode(b'\xff\xd8synthetic\xff\xd9').decode())
            return dict(approved=True, screen=True, input=True, owner='you')
        with patch('desktop_control.native_request', side_effect=native):
            media = asyncio.create_task(DesktopFrameFeed(self.bridge, self.token).next())
            await entered.wait()
            code, _ = await asyncio.wait_for(self.bridge.handle('POST', '/desktop/v1/claim', json.dumps(dict(request_id=str(uuid.uuid4()))), self.token), .5)
            self.assertEqual(200, code)
            session = self.bridge.lease.read()['session']
            code, _ = await asyncio.wait_for(self.bridge.handle('POST', '/desktop/v1/heartbeat', json.dumps(dict(session=session)), self.token), .5)
            self.assertEqual(200, code)
            release.set(); await media

    async def test_malformed_native_picture_never_enters_stream(self):
        with patch('desktop_control.native_request', new=AsyncMock(return_value=dict(jpeg='invalid'))):
            code, _ = await DesktopFrameFeed(self.bridge, self.token).next()
            self.assertEqual(502, code)

    async def test_no_third_frame_until_decoded_ack_and_ack_is_bound_to_device(self):
        feed = DesktopFrameFeed(self.bridge, self.token); self.bridge.feeds[feed.id] = feed
        with patch('desktop_control.native_request', new=AsyncMock(return_value=dict(jpeg=base64.b64encode(b'\xff\xd8test\xff\xd9').decode()))) as native:
            await feed.next(); await feed.next()
            third = asyncio.create_task(feed.next())
            await asyncio.sleep(.03)
            self.assertFalse(third.done()); self.assertEqual(2, native.await_count)
            with self.assertRaises(ValueError): feed.acknowledge(99)
            body = json.dumps(dict(stream_id=feed.id, sequence=2))
            code, _ = await self.bridge.handle('POST', '/desktop/v1/frame-ack', body, secrets.token_urlsafe(48))
            self.assertEqual(403, code); self.assertFalse(third.done())
            code, _ = await self.bridge.handle('POST', '/desktop/v1/frame-ack', body, self.token)
            self.assertEqual(200, code)
            code, _ = await asyncio.wait_for(third, .5); self.assertEqual(200, code)

    async def test_http_stream_delivers_changing_frames_and_closes_on_revoke(self):
        from aiohttp import web
        from aiohttp.test_utils import TestServer, TestClient
        from access_server import AccessService
        from types import SimpleNamespace
        svc = SimpleNamespace(desktop=self.bridge, store=self.service.store,
                              tunnel=SimpleNamespace(enabled=True), token=lambda request: self.token)
        count = 0
        async def native(data, payload):
            nonlocal count
            count += 1
            return dict(jpeg=base64.b64encode(b'\xff\xd8' + str(count).encode() + b'\xff\xd9').decode())
        app = web.Application()
        async def handler(request): return await AccessService.desktop_frames(svc, request)
        app.router.add_get('/desktop/v1/frames', handler)
        with patch('desktop_control.native_request', side_effect=native):
            async with TestClient(TestServer(app)) as client:
                response = await client.get('/desktop/v1/frames')
                self.assertEqual(200, response.status)
                self.assertEqual('multipart/x-mixed-replace', response.content_type)
                async def picture():
                    header = await response.content.readuntil(b'\r\n\r\n')
                    length = int(next(line.split(b':')[1] for line in header.split(b'\r\n') if line.startswith(b'Content-Length:')))
                    data = await response.content.readexactly(length + 2)
                    sequence = int(next(line.split(b':')[1] for line in header.split(b'\r\n') if line.startswith(b'X-Frame-Sequence:')))
                    identifier = next(line.split(b':')[1].strip().decode() for line in header.split(b'\r\n') if line.startswith(b'X-Stream-ID:'))
                    code, _ = await self.bridge.handle('POST', '/desktop/v1/frame-ack', json.dumps(dict(stream_id=identifier, sequence=sequence)), self.token)
                    self.assertEqual(200, code)
                    return data
                first, second = await picture(), await picture()
                self.assertNotEqual(first, second)
                self.service.store.revoke(self.device['id'])
                await asyncio.wait_for(response.read(), 1)


if __name__ == '__main__': unittest.main()
