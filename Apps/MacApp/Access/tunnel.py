"""Replaceable reachability. Never owns pairing, session identity, or Agent tasks."""
import asyncio
import json
import time
from pathlib import Path
from pairing_store import endpoint, is_tailnet_endpoint
from tailscale_access import TailscaleTunnel


class EmbeddedTailscale:
    """The native app owns this node; local authenticated reports have a short lease."""
    def __init__(self):
        self.state = dict(state='stopped', endpoint=None, mode='embedded', provider='tailscale', error=None)
        self.reported_at = 0
    async def start(self): self.state.update(state='needs_setup', endpoint=None, error='请在 App 中连接 Tailscale。')
    async def stop(self): self.state.update(state='stopped', endpoint=None, error=None)

    def report(self, body, now):
        state = body.get('state')
        if state not in ('connected', 'starting', 'needs_setup', 'reconnecting'): raise ValueError('Invalid node state')
        url = body.get('endpoint')
        if state == 'connected':
            if not is_tailnet_endpoint(url):
                raise ValueError('Invalid embedded endpoint')
        else: url = None
        self.state.update(state=state, endpoint=url, error=str(body.get('error') or '')[:500] or None)
        self.reported_at = now


class ExistingHTTPSTunnel:
    """Use a stable HTTPS ingress managed by the user, outside the Agent runtime."""
    def __init__(self, url):
        if not isinstance(url, str) or not url.startswith('https://'): raise ValueError('HTTPS required')
        self.url = endpoint(url)
        self.state = {'state': 'stopped', 'endpoint': None, 'mode': 'external', 'provider': 'external', 'error': None}
    async def start(self): self.state.update(state='starting', endpoint=self.url, error=None)
    async def stop(self): self.state.update(state='stopped', endpoint=None, error=None)


class TunnelLifecycle:
    """Remember user intent; recover transport without changing device or run identity."""
    def __init__(self, directory, port, now=time.monotonic):
        self.directory = Path(directory); self.port = port; self.now = now
        self.file = self.directory / 'provider.json'
        saved = json.loads(self.file.read_text()) if self.file.exists() else {}
        mode = saved.get('provider', 'embedded')
        self.provider = ExistingHTTPSTunnel(saved['endpoint']) if mode == 'external' else TailscaleTunnel(port) if mode == 'tailscale' else EmbeddedTailscale()
        self.enabled = saved.get('enabled') is True and mode in ('tailscale', 'external', 'embedded')
        if self.enabled and isinstance(self.provider, EmbeddedTailscale): self.provider.state['state'] = 'needs_setup'
        if mode not in ('tailscale', 'external', 'embedded'):
            # Keep the notice across restarts until the user explicitly selects or starts a supported provider.
            self.provider.state['error'] = '原连接方式已停用。请选择 Tailscale 或自建服务器并重新扫码；已有任务和资料保留。'
        self.lock = asyncio.Lock(); self.unhealthy_since = None; self.retry_at = 0

    def persist(self):
        value = {'provider': self.provider.state['mode'], 'endpoint': getattr(self.provider, 'url', None), 'enabled': self.enabled}
        temporary = self.file.with_suffix('.tmp')
        temporary.touch(mode=0o600, exist_ok=True); temporary.chmod(0o600)
        temporary.write_text(json.dumps(value)); temporary.replace(self.file)

    async def configure(self, mode, url=None):
        if mode not in ('external', 'tailscale', 'embedded'): raise ValueError('Unsupported connection provider')
        provider = ExistingHTTPSTunnel(url) if mode == 'external' else TailscaleTunnel(self.port) if mode == 'tailscale' else EmbeddedTailscale()
        async with self.lock:
            await self.provider.stop(); self.provider = provider
            self.enabled = False; self.persist(); self.reset_retry()

    def reset_retry(self):
        self.unhealthy_since = None; self.retry_at = 0

    async def start(self):
        async with self.lock:
            self.enabled = True; self.persist(); self.reset_retry()
            await self.provider.start()

    async def stop(self):
        async with self.lock:
            self.enabled = False; self.persist(); self.reset_retry()
            await self.provider.stop()

    async def tick(self, probe):
        async with self.lock:
            if not self.enabled or self.now() < self.retry_at: return
            if isinstance(self.provider, EmbeddedTailscale):
                if self.now() - self.provider.reported_at > 15:
                    self.provider.state.update(state='needs_setup', endpoint=None, error='请在 App 中恢复 Tailscale 连接。')
                return
            try:
                if self.provider.state['state'] in ('stopped', 'failed', 'needs_setup'):
                    await self.provider.start()
                if self.provider.state['state'] == 'needs_setup':
                    self.retry_at = self.now() + 30; return
                url = self.provider.state['endpoint']
                if url and await probe(url):
                    self.provider.state.update(state='connected', error=None); self.reset_retry(); return
            except OSError:
                pass
            now = self.now()
            if self.provider.state['state'] == 'connected': self.provider.state['state'] = 'reconnecting'
            if self.unhealthy_since is None: self.unhealthy_since = now
            elapsed = now - self.unhealthy_since
            if elapsed < 30: return
            if self.provider.state['mode'] == 'tailscale':
                # Refresh DNS/login/Serve after a disconnect without ever falling back to a public tunnel.
                await self.provider.start()
                if self.provider.state['state'] == 'needs_setup':
                    self.retry_at = self.now() + 30; return
                error = 'Tailscale 入口暂不可达。请确认两端已连接同一网络，并检查 Serve 与访问规则。'
                self.unhealthy_since = None
            else:
                error = '固定入口暂不可达。请确认隧道连接器在运行，转发地址正确；App 会继续检查。'
            self.provider.state.update(state='reconnecting', error=error)
