"""Outbound E2E connector. The relay never receives a device grant or plaintext API frame."""
import asyncio
import base64
import hashlib
import json
import os
import re
import secrets
import time

from aiohttp import ClientError, ClientSession, ClientTimeout, WSMsgType
from cryptography.exceptions import InvalidTag
from pairing_store import endpoint
from relay_crypto import RelayCipher, routing_token
from rtc_transport import permitted_route


class RelayTunnel:
    def __init__(self, directory, port, url, registration_key='', *, _allow_loopback=False):
        if not isinstance(url, str) or not (url.startswith('https://') or _allow_loopback and url.startswith('http://127.0.0.1:')):
            raise ValueError('Relay requires HTTPS')
        self.url = endpoint(url)
        if not isinstance(registration_key, str) or len(registration_key) > 4096 or any(ord(c) < 32 for c in registration_key):
            raise ValueError('Invalid registration key')
        self.registration_key = registration_key
        # Keep the room stable through restarts and switching back to this relay.
        file = directory / ('relay-' + hashlib.sha256(self.url.encode()).hexdigest()[:24] + '.json')
        if file.exists():
            self.code = json.loads(file.read_text())['code']
            if not re.fullmatch(r'[A-Za-z0-9_-]{43}', self.code):
                raise ValueError('Invalid relay identity')
        else:
            self.code = secrets.token_urlsafe(32)
            with open(file, 'x', opener=lambda path, flags: os.open(path, flags, 0o600)) as output:
                json.dump({'code': self.code}, output)
        self.port = port
        self.state = dict(state='stopped', endpoint=None, mode='relay', provider='alma-relay', error=None, configured_endpoint=self.url)
        self.worker = None

    async def start(self):
        if self.worker and not self.worker.done():
            return
        self.state.update(state='starting', endpoint=None, error=None)
        self.worker = asyncio.create_task(self.run())

    async def stop(self):
        if self.worker:
            self.worker.cancel()
            await asyncio.gather(self.worker, return_exceptions=True)
            self.worker = None
        self.state.update(state='stopped', endpoint=None, error=None)

    async def run(self):
        token_hash = hashlib.sha256(routing_token(self.code).encode()).hexdigest()
        delay = 1
        async with ClientSession(timeout=ClientTimeout(total=None, sock_connect=10), trust_env=False) as session:
            while True:
                try:
                    async with session.ws_connect(self.url.replace('https://', 'wss://', 1).replace('http://', 'ws://', 1) + '/agent?th=' + token_hash,
                                                  heartbeat=15, max_msg_size=1024 * 1024) as socket:
                        await socket.send_json(dict(t='register', tokenHash=token_hash, name='MoMo Agent', key=self.registration_key))
                        message = await asyncio.wait_for(socket.receive(), 15)
                        registration = message.json() if message.type == WSMsgType.TEXT else None
                        if not isinstance(registration, dict) or registration.get('t') != 'registered':
                            self.state.update(state='needs_setup', endpoint=None, error='中继拒绝连接，请检查地址与注册密钥。')
                            return
                        delay = 1
                        self.state.update(state='connected', endpoint=self.url, error=None)
                        await self.serve(socket, session)
                        if socket.close_code in (4000, 4002, 4003, 4401):
                            self.state.update(state='needs_setup', endpoint=None, error='中继身份被替换或拒绝，请检查配置后重新连接。')
                            return
                except (OSError, ClientError, asyncio.TimeoutError, ValueError):
                    pass
                self.state.update(state='reconnecting', error='中继连接中断，正在重试。')
                await asyncio.sleep(delay)
                delay = min(delay * 2, 30)

    async def serve(self, socket, session):
        rooms = {}

        async def close_room(room_id):
            room = rooms.pop(room_id, None)
            if room:
                for task in room['tasks'].values(): task.cancel()
                await asyncio.gather(*room['tasks'].values(), return_exceptions=True)

        async def prune():
            while True:
                await asyncio.sleep(5)
                for room_id, room in list(rooms.items()):
                    if not room['cipher'].ready and time.monotonic() - room['created'] > 15:
                        await close_room(room_id)
                        await socket.send_json(dict(t='wclose', id=room_id, code=1008))

        watchdog = asyncio.create_task(prune())
        try:
            async for message in socket:
                if message.type != WSMsgType.TEXT:
                    continue
                frame = message.json()
                if not isinstance(frame, dict): raise ValueError('Invalid relay frame')
                kind, room_id = frame.get('t'), frame.get('id')
                if not isinstance(room_id, str) or len(room_id) > 128:
                    continue
                if kind == 'wopen':
                    if frame.get('path') != '/__alma_e2e__' or room_id in rooms or len(rooms) >= 64:
                        await socket.send_json(dict(t='werr', id=room_id, message='E2E required'))
                        continue
                    rooms[room_id] = dict(cipher=RelayCipher(self.code), tasks={}, created=time.monotonic(), lock=asyncio.Lock())
                    await socket.send_json(dict(t='wopened', id=room_id))
                elif kind == 'wclose':
                    await close_room(room_id)
                elif kind == 'hreq':
                    # Never let a relay bypass encryption and impersonate a paired phone.
                    await socket.send_json(dict(t='hres', id=room_id, status=403, headers={}))
                    await socket.send_json(dict(t='hend', id=room_id))
                elif kind == 'wmsg' and room_id in rooms:
                    room = rooms[room_id]
                    try:
                        if 's' in frame:
                            if len(frame['s']) > 2048: raise ValueError('Handshake too large')
                            reply = room['cipher'].handshake(json.loads(frame['s']))
                            if reply: await socket.send_json(dict(t='wmsg', id=room_id, s=json.dumps(reply)))
                        else:
                            inner = room['cipher'].open(base64.b64decode(frame['b'], validate=True))
                            request_id = inner.get('id')
                            if not isinstance(request_id, str) or len(request_id) > 128: raise ValueError('Invalid request ID')
                            if inner.get('t') == 'hcancel':
                                task = room['tasks'].get(request_id)
                                if task: task.cancel()
                            elif inner.get('t') == 'hreq':
                                if request_id in room['tasks'] or len(room['tasks']) >= 32: raise ValueError('Request limit')
                                task = asyncio.create_task(self.forward(socket, session, room_id, room, inner))
                                room['tasks'][request_id] = task
                                task.add_done_callback(lambda _, tasks=room['tasks'], key=request_id: tasks.pop(key, None))
                            else: raise ValueError('Unsupported application frame')
                    except (ValueError, KeyError, TypeError, InvalidTag):
                        await close_room(room_id)
                        await socket.send_json(dict(t='wclose', id=room_id, code=1008))
        finally:
            watchdog.cancel()
            await asyncio.gather(watchdog, return_exceptions=True)
            for room_id in list(rooms): await close_room(room_id)

    async def forward(self, socket, session, room_id, room, request):
        async def send(frame):
            # Keep the directional counter and socket write in the same critical section.
            async with room['lock']:
                wire = room['cipher'].seal(dict(frame, id=request['id']))
                await asyncio.wait_for(socket.send_json(dict(t='wmsg', id=room_id, b=base64.b64encode(wire).decode())), 15)

        try:
            method, path = request.get('method'), request.get('path')
            pair = isinstance(path, str) and ((method == 'POST' and path == '/pair/requests') or
                   (method == 'GET' and (path == '/pair/identity' or re.fullmatch(r'/pair/requests/[a-f0-9-]{36}', path))))
            if not isinstance(path, str) or not path.startswith('/') or path.startswith('//') or '#' in path or '\\' in path:
                raise ValueError('Invalid path')
            if not pair and permitted_route(method, path) is None:
                raise ValueError('Route not permitted')
            body = base64.b64decode(request.get('b', ''), validate=True)
            if len(body) > 512 * 1024: raise ValueError('Request body exceeds relay limit')
            source = request.get('headers', {})
            if not isinstance(source, dict): raise ValueError('Invalid headers')
            allowed = {'authorization', 'content-type', 'accept', 'last-event-id', 'idempotency-key'}
            headers = {k: v for k, v in source.items() if k.lower() in allowed}
            headers['Accept-Encoding'] = 'identity'
            async with session.request(method, f'http://127.0.0.1:{self.port}' + path, data=body or None,
                                       headers=headers, allow_redirects=False,
                                       timeout=ClientTimeout(total=None, sock_connect=5, sock_read=65)) as response:
                outgoing = {k.lower(): v for k, v in response.headers.items() if k.lower() in ('content-type', 'retry-after', 'cache-control')}
                await send(dict(t='hres', status=response.status, headers=outgoing))
                async for chunk in response.content.iter_chunked(32768):
                    await send(dict(t='hchunk', b=base64.b64encode(chunk).decode()))
                await send(dict(t='hend'))
        except asyncio.CancelledError:
            raise
        except (OSError, ClientError, asyncio.TimeoutError, ValueError, KeyError, TypeError):
            # Do not echo URLs, credentials, headers or internal connection errors.
            try: await send(dict(t='herr', message='Request failed'))
            except (OSError, ClientError, asyncio.TimeoutError): pass
