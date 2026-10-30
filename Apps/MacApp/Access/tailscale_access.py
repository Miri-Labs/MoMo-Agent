"""Discover an existing private Serve endpoint; never change the user's VPN config."""
import asyncio
import json
import os
from pathlib import Path
import re
import shlex
import shutil


def cli_path():
    for path in ('/Applications/Tailscale.app/Contents/MacOS/Tailscale',
                 str(Path.home() / 'Applications/Tailscale.app/Contents/MacOS/Tailscale'),
                 '/opt/homebrew/bin/tailscale', '/usr/local/bin/tailscale', shutil.which('tailscale')):
        if path and os.access(path, os.X_OK): return path
    return None


async def cli_json(path, *args):
    process = await asyncio.create_subprocess_exec(
        path, *args, env={**os.environ, 'TAILSCALE_BE_CLI': '1'},
        stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    try:
        output, _ = await asyncio.wait_for(process.communicate(), 4)
    finally:
        if process.returncode is None:
            process.kill(); await process.wait()
    if process.returncode: raise OSError('Tailscale CLI unavailable')
    value = json.loads(output)
    if value is None: return {}
    if not isinstance(value, dict): raise ValueError('Invalid Tailscale status')
    return value


def private_endpoint(status, config, port):
    if status.get('BackendState') != 'Running':
        raise ValueError('请打开 Tailscale，完成登录并连接；手机也要加入同一个网络。')
    host = (status.get('Self') or {}).get('DNSName', '').rstrip('.').lower()
    if not re.fullmatch(r'[a-z0-9-]+\.[a-z0-9-]+\.ts\.net', host):
        raise ValueError('尚未取得 Tailscale 地址，请在 Tailscale 管理页面开启 MagicDNS。')
    authority = f'{host}:{port}'
    # Check foreground configurations too: a public Funnel may share the same listener.
    configs = [config, *(config.get('Foreground') or {}).values()]
    if any((entry.get('AllowFunnel') or {}).get(authority) for entry in configs):
        raise ValueError('这个入口启用了公网 Funnel。请先关闭它，再使用私网 Serve。')
    tcp = (config.get('TCP') or {}).get(str(port), {})
    handlers = ((config.get('Web') or {}).get(authority) or {}).get('Handlers') or {}
    proxy = (handlers.get('/') or {}).get('Proxy', '').rstrip('/')
    if tcp.get('HTTPS') is not True or proxy != f'http://127.0.0.1:{port}':
        raise ValueError('请先在终端完成下方 Serve 命令；已有端口用途请勿覆盖。完成后重新检查。')
    return f'https://{authority}'


class TailscaleTunnel:
    def __init__(self, port):
        self.port = port
        self.state = dict(state='stopped', endpoint=None, mode='tailscale', provider='tailscale', error=None)
        self.update_command()

    def update_command(self):
        path = cli_path()
        binary = path or '/Applications/Tailscale.app/Contents/MacOS/Tailscale'
        self.state['setup_command'] = f'TAILSCALE_BE_CLI=1 {shlex.quote(binary)} serve --bg --https={self.port} http://127.0.0.1:{self.port}'
        return path

    async def start(self):
        self.state.update(state='starting', endpoint=None, error=None)
        path = self.update_command()
        if not path:
            self.state.update(state='needs_setup', error='请先安装并打开 Mac 版 Tailscale，登录后再检查连接。'); return
        try:
            status = await cli_json(path, 'status', '--json')
            # Do not query Serve until login has completed.
            if status.get('BackendState') != 'Running': private_endpoint(status, {}, self.port)
            config = await cli_json(path, 'serve', 'status', '--json')
            self.state['endpoint'] = private_endpoint(status, config, self.port)
        except ValueError as error:
            message = str(error) if not isinstance(error, json.JSONDecodeError) else '无法读取 Tailscale 状态，请更新官方客户端后重试。'
            self.state.update(state='needs_setup', error=message)
        except (OSError, asyncio.TimeoutError):
            self.state.update(state='needs_setup', error='无法联系 Tailscale，请确认客户端已打开并连接，再重新检查。')

    async def stop(self):
        self.state.update(state='stopped', endpoint=None, error=None)
