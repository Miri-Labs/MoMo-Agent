"""Desktop ownership and private IPC; no model/provider or tunnel implementation here."""
import asyncio
import base64
from contextlib import contextmanager
import fcntl
import hashlib
import hmac
import json
import os
from pathlib import Path
import time
import uuid


def socket_path(data):
    suffix = hashlib.sha256(str(Path(data).resolve()).encode()).hexdigest()[:20]
    return '/tmp/momo-desktop-' + suffix + '/control.sock'


class DesktopLease:
    def __init__(self, data, now=time.time):
        self.directory = Path(data) / 'desktop'
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.path = self.directory / 'lease.json'
        self.now = now

    @contextmanager
    def locked(self):
        fd = os.open(self.directory / 'lease.lock', os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN); os.close(fd)

    def read(self):
        if not self.path.exists(): return {'owner': 'agent', 'epoch': 0}
        value = json.loads(self.path.read_text())
        if value.get('owner') not in ('agent', 'human') or type(value.get('epoch')) is not int:
            raise ValueError('Invalid desktop ownership record')
        return value

    def write(self, value):
        temporary = self.directory / (str(uuid.uuid4()) + '.tmp')
        fd = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream); stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, self.path)

    def acquire(self, viewer, request_id):
        uuid.UUID(request_id)
        with self.locked():
            current = self.read()
            if current['owner'] == 'human' and current.get('viewer') != viewer and current.get('expires',0)>self.now():
                raise PermissionError('另一台设备正在控制电脑，请先交还控制权。')
            if current.get('viewer') == viewer and current.get('request_id') == request_id and current.get('expires',0)>self.now():
                return current
            value = dict(owner='human', viewer=viewer, session=str(uuid.uuid4()), request_id=request_id,
                         epoch=current['epoch'] + 1, expires=self.now() + 20)
            if current.get('agent_work'): value['agent_work']=current['agent_work']
            self.write(value); return value

    def heartbeat(self, viewer, session):
        with self.locked():
            value = self.require(viewer, session)
            value['expires'] = self.now() + 20; self.write(value); return value

    def require(self, viewer, session):
        value = self.read()
        if value['owner'] != 'human' or value.get('viewer') != viewer or value.get('session') != session or value.get('expires', 0) <= self.now():
            raise PermissionError('控制连接已失效，请重新接管。')
        return value

    def release(self, viewer, session):
        with self.locked():
            value = self.read()
            if value['owner'] == 'agent': return value
            if value.get('viewer') != viewer or value.get('session') != session:
                raise PermissionError('控制权已变化，不能结束另一台设备的控制。')
            value = dict(owner='agent', epoch=value['epoch'] + 1, **({'agent_work':value['agent_work']} if value.get('agent_work') else {}))
            self.write(value); return value


async def native_request(data, payload):
    data = Path(data)
    payload = {**payload, 'key': (data / 'api-key').read_text().strip()}
    reader, writer = await asyncio.wait_for(asyncio.open_unix_connection(socket_path(data), limit=3 * 1024 * 1024), 3)
    try:
        writer.write(json.dumps(payload, separators=(',', ':')).encode() + b'\n'); await writer.drain()
        response = await asyncio.wait_for(reader.readline(), 15)
        if not response or len(response) > 3 * 1024 * 1024: raise ValueError('Desktop response unavailable')
        return json.loads(response)
    finally:
        writer.close(); await writer.wait_closed()


class DesktopBridge:
    def __init__(self, service):
        self.service = service
        self.lease = DesktopLease(service.data)
        self.capture_lock = asyncio.Lock()
        self.feeds = {}

    async def handle(self, method, path, body, token, *, preview=False, edge=960):
        from pairing_store import digest
        device = self.service.store.db.execute("SELECT id,name FROM devices WHERE token_hash=? AND state='approved'", (digest(token),)).fetchone()
        if device is None: return 403, {'error': {'code': 'device_revoked', 'message': '设备尚未获准。'}}
        return await self._handle_device(method, path, body, device, lambda: self.service.store.authorized(token),
                                         token=token, preview=preview, edge=edge)

    async def control_device(self, viewer, operation, body):
        # This entry is reachable only on the API-key protected loopback control port.
        # Every DataChannel command is re-authorized, including after native IPC.
        if operation not in ('status', 'request', 'claim', 'release', 'heartbeat', 'input'):
            return 400, {'error': {'code': 'invalid_desktop_request', 'message': '电脑操作参数无效。'}}
        def approved():
            return self.service.tunnel.enabled and self.service.store.db.execute(
                "SELECT 1 FROM devices WHERE id=? AND state='approved'", (viewer,)).fetchone() is not None
        device = self.service.store.db.execute("SELECT id,name FROM devices WHERE id=? AND state='approved'", (viewer,)).fetchone()
        if device is None or not approved():
            return 403, {'error': {'code': 'device_revoked', 'message': '设备授权已撤销。'}}
        return await self._handle_device('POST', '/desktop/v1/' + operation, body, device, approved)

    async def _handle_device(self, method, path, body, device, authorized, *, token='', preview=False, edge=960):
        viewer = device['id']
        try:
            value = json.loads(body) if body else {}
            if not isinstance(value, dict): raise ValueError('Invalid desktop request')
            operation = path.rsplit('/', 1)[-1]
            if operation == 'frame-ack':
                feed = self.feeds.get(value.get('stream_id'))
                if feed is None or not hmac.compare_digest(feed.token, token):
                    return 409, {'error': {'code': 'preview_replaced', 'message': '画面连接已更新。'}}
                feed.acknowledge(value.get('sequence'))
                return 200, {'ok': True}
            # Pairing is the durable trust decision; clients cannot supply this private IPC assertion.
            payload = dict(op=operation, actor='human', viewer=viewer, paired=True, name=device['name'])
            if operation == 'offer':
                if value.get('version') != 1 or not isinstance(value.get('sdp'), str) or len(value['sdp'].encode()) > 131072:
                    raise ValueError('Invalid video offer')
                uuid.UUID(value['nonce'])
                payload.update(op='video-offer', sdp=value['sdp'], nonce=value['nonce'])
            if operation == 'frame' and preview:
                payload.update(preview=True, edge=edge)
            if operation == 'claim':
                status = await native_request(self.service.data, {**payload, 'op': 'status'})
                if not status.get('approved') or not status.get('screen') or not status.get('input'):
                    missing = [label for field, label in [('screen', '屏幕录制'), ('input', '辅助功能')] if not status.get(field)]
                    return 409, {'error': {'code': 'desktop_permissions', 'message': 'Mac 的' + '和'.join(missing) + '权限尚未生效，请在 Mac 的「屏幕与控制权限」中检查。'}}
                self.lease.acquire(viewer, value['request_id'])
            elif operation == 'release': self.lease.release(viewer, value['session'])
            elif operation == 'heartbeat': self.lease.heartbeat(viewer, value['session'])
            elif operation == 'input':
                self.lease.require(viewer, value['session'])
                uuid.UUID(value['event_id'])
                payload.update(session=value['session'], event=value['event'], event_id=value['event_id'])
            if operation in ('claim', 'release', 'heartbeat'): payload['op'] = 'status'
            if operation == 'frame':
                if self.capture_lock.locked(): return 429, {'error': {'code': 'capture_busy', 'message': '正在读取桌面，请稍后重试。'}}
                async with self.capture_lock: result = await native_request(self.service.data, payload)
            else: result = await native_request(self.service.data, payload)
            if 'error' in result: return 403, {'error': {'code': 'desktop_denied', 'message': result['error']}}
            if not authorized(): return 403, {'error': {'code': 'device_revoked', 'message': '设备授权已撤销。'}}
            if operation in ('status', 'request', 'claim', 'release', 'heartbeat'):
                result['preview_stream'] = True
            return 200, result
        except PermissionError as error: return 409, {'error': {'code': 'ownership_changed', 'message': str(error)}}
        except (ValueError, KeyError, TypeError): return 400, {'error': {'code': 'invalid_desktop_request', 'message': '电脑操作参数无效。'}}
        except (OSError, asyncio.TimeoutError): return 503, {'error': {'code': 'desktop_unavailable', 'message': '电脑桌面暂时不可用，请保持电脑上的 MoMo Agent 打开。'}}


class DesktopFrameFeed:
    """Demand-driven encoder: no frame backlog. Capture itself keeps only the newest image.

    The network writer awaits each write before requesting another frame. Slow viewers
    reduce resolution, not accumulate seconds of obsolete screenshots. Control RPCs
    have no dependency on this producer or its capture lock.
    """
    content_type = 'multipart/x-mixed-replace; boundary=momo-frame'

    def __init__(self, bridge, token):
        self.bridge = bridge
        self.token = token
        self.edge = 640  # Small first picture; raise quality only after successful drains.
        self.sequence = 0
        self.fast = 0
        self.id = str(uuid.uuid4())
        self.pending = {}
        self.available = asyncio.Event()
        self.closed = False

    async def next(self):
        if not self.bridge.service.store.authorized(self.token):
            return 403, {'error': {'code': 'device_revoked', 'message': '设备授权已撤销。'}}
        # Kernel/proxy buffers are not evidence of presentation. At most two
        # unacknowledged pictures may exist across the whole remote path.
        while len(self.pending) >= 2 and not self.closed:
            self.available.clear()
            await asyncio.wait_for(self.available.wait(), 5)
        if self.closed: return 409, {'error': {'code': 'preview_replaced', 'message': '画面连接已更新。'}}
        code, result = await self.bridge.handle('GET', '/desktop/v1/frame', b'', self.token,
                                                preview=True, edge=self.edge)
        if code != 200: return code, result
        try:
            jpeg = base64.b64decode(result['jpeg'], validate=True)
            if not jpeg.startswith(b'\xff\xd8') or not jpeg.endswith(b'\xff\xd9') or len(jpeg) > 512 * 1024:
                raise ValueError('Invalid desktop frame')
        except (ValueError, KeyError, TypeError):
            return 502, {'error': {'code': 'invalid_desktop_frame', 'message': '无法读取电脑画面。'}}
        self.sequence += 1
        self.pending[self.sequence] = time.monotonic()
        header = (f'--momo-frame\r\nContent-Type: image/jpeg\r\nContent-Length: {len(jpeg)}\r\n'
                  f'X-Frame-Sequence: {self.sequence}\r\nX-Stream-ID: {self.id}\r\n\r\n').encode('ascii')
        return 200, header + jpeg + b'\r\n'

    def acknowledge(self, sequence):
        if type(sequence) is not int or sequence < 1 or sequence > self.sequence:
            raise ValueError('Invalid frame acknowledgement')
        if sequence in self.pending: self.drained(time.monotonic() - self.pending[sequence])
        self.pending = {key: value for key, value in self.pending.items() if key > sequence}
        self.available.set()

    def drained(self, seconds):
        if seconds > 0.3:
            self.edge = max(320, int(self.edge * 0.75)); self.fast = 0
        elif seconds < 0.1:
            self.fast += 1
            if self.fast >= 12:
                self.edge = min(1280, self.edge + 160); self.fast = 0
        else: self.fast = 0
