import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Apps/MacApp/Access'))
from tailscale_access import TailscaleTunnel, private_endpoint
from tunnel import TunnelLifecycle

STATUS = {'BackendState': 'Running', 'Self': {'DNSName': 'test-mac.tail123.ts.net.'}}
AUTHORITY = 'test-mac.tail123.ts.net:8767'


def serve_config():
    return {'TCP': {'8767': {'HTTPS': True}}, 'Web': {
        AUTHORITY: {'Handlers': {'/': {'Proxy': 'http://127.0.0.1:8767'}}}}}


class TailscaleTests(unittest.IsolatedAsyncioTestCase):
    def test_requires_login_own_dns_private_https_and_correct_local_target(self):
        self.assertEqual('https://' + AUTHORITY, private_endpoint(STATUS, serve_config(), 8767))
        for state in ['NeedsLogin', 'Stopped', 'NeedsMachineAuth']:
            with self.assertRaises(ValueError): private_endpoint({**STATUS, 'BackendState': state}, serve_config(), 8767)
        for dns in ['', 'test.ts.net.evil.example', 'test.example', 'test-mac.tail123.ts.net/path']:
            with self.assertRaises(ValueError): private_endpoint({**STATUS, 'Self': {'DNSName': dns}}, serve_config(), 8767)
        for proxy in ['http://127.0.0.1:8765', 'http://localhost:8767', 'http://127.0.0.1:8767/admin', 'http://example.com']:
            config = serve_config(); config['Web'][AUTHORITY]['Handlers']['/']['Proxy'] = proxy
            with self.assertRaises(ValueError): private_endpoint(STATUS, config, 8767)
        config = serve_config(); config['TCP']['8767'] = {'HTTP': True}
        with self.assertRaises(ValueError): private_endpoint(STATUS, config, 8767)
        for config in [dict(serve_config(), AllowFunnel={AUTHORITY: True}),
                       dict(serve_config(), Foreground={'session': {'AllowFunnel': {AUTHORITY: True}}})]:
            with self.assertRaisesRegex(ValueError, 'Funnel'): private_endpoint(STATUS, config, 8767)

    async def test_discovery_only_reads_cli_and_stop_does_not_change_user_vpn(self):
        with patch('tailscale_access.cli_path', return_value='/fixture/tailscale'), \
             patch('tailscale_access.cli_json', new_callable=AsyncMock) as command:
            command.side_effect = [STATUS, serve_config()]
            provider = TailscaleTunnel(8767); await provider.start()
            self.assertEqual('https://' + AUTHORITY, provider.state['endpoint'])
            self.assertEqual([('/fixture/tailscale', 'status', '--json'),
                              ('/fixture/tailscale', 'serve', 'status', '--json')],
                             [call.args for call in command.call_args_list])
            await provider.stop()
            self.assertEqual(2, command.await_count)

    async def test_missing_client_logged_out_daemon_failure_and_bad_json_are_actionable(self):
        with patch('tailscale_access.cli_path', return_value=None):
            provider = TailscaleTunnel(8767); await provider.start()
            self.assertEqual('needs_setup', provider.state['state'])
            self.assertIn('安装', provider.state['error'])
        with patch('tailscale_access.cli_path', return_value='/fixture/tailscale'), \
             patch('tailscale_access.cli_json', new_callable=AsyncMock) as command:
            command.return_value = {'BackendState': 'NeedsLogin'}
            await provider.start()
            self.assertEqual(1, command.await_count)
            self.assertIn('登录', provider.state['error'])
            for error in [OSError(), TimeoutError(), json.JSONDecodeError('bad', '', 0)]:
                command.side_effect = error; await provider.start()
                self.assertEqual('needs_setup', provider.state['state'])
                self.assertIsNone(provider.state['endpoint'])

    async def test_first_run_is_private_and_no_public_fallback_after_restart(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch('tailscale_access.cli_path', return_value='/fixture/tailscale'), \
             patch('tailscale_access.cli_json', new_callable=AsyncMock) as command:
            first = TunnelLifecycle(directory, 8767)
            self.assertEqual('embedded', first.provider.state['mode'])
            self.assertFalse(first.enabled)
            Path(directory, 'provider.json').write_text(json.dumps({'provider': 'tailscale', 'enabled': False}))
            manager = TunnelLifecycle(directory, 8767)
            self.assertEqual('tailscale', manager.provider.state['mode'])
            self.assertFalse(manager.enabled)
            command.side_effect = [STATUS, serve_config()]
            await manager.start(); await manager.tick(AsyncMock(return_value=True))
            self.assertEqual('connected', manager.provider.state['state'])
            restored = TunnelLifecycle(directory, 8767)
            self.assertTrue(restored.enabled)
            command.side_effect = OSError()
            await restored.tick(AsyncMock(return_value=False))
            self.assertEqual('needs_setup', restored.provider.state['state'])
            self.assertEqual('tailscale', restored.provider.state['mode'])

    def test_supported_choices_preserve_enabled_intent(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / 'provider.json'
            for mode in ['tailscale', 'external']:
                file.write_text(json.dumps(dict(provider=mode, endpoint='https://existing.example', enabled=True)))
                restored = TunnelLifecycle(directory, 8767)
                self.assertEqual(mode, restored.provider.state['mode'])
                self.assertTrue(restored.enabled)

    async def test_retired_or_unknown_config_requires_choice_even_after_restart(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch('tailscale_access.cli_json', new_callable=AsyncMock) as command:
            file = Path(directory) / 'provider.json'
            for mode in ['temporary', 'unknown']:
                file.write_text(json.dumps(dict(provider=mode, endpoint='https://old.example', enabled=True)))
                saved = file.read_bytes()
                for _ in range(2):
                    restored = TunnelLifecycle(directory, 8767)
                    await restored.tick(AsyncMock(return_value=True))
                    self.assertFalse(restored.enabled)
                    self.assertEqual('stopped', restored.provider.state['state'])
                    self.assertIsNone(restored.provider.state['endpoint'])
                    self.assertIn('原连接方式已停用', restored.provider.state['error'])
                    self.assertEqual(saved, file.read_bytes())
                command.assert_not_awaited()
                await restored.configure('tailscale')
                self.assertIsNone(TunnelLifecycle(directory, 8767).provider.state['error'])
                self.assertEqual('tailscale', json.loads(file.read_text())['provider'])

    async def test_reconnect_retries_after_login_without_changing_provider(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch('tailscale_access.cli_path', return_value='/fixture/tailscale'), \
             patch('tailscale_access.cli_json', new_callable=AsyncMock) as command:
            (Path(directory) / "provider.json").write_text(json.dumps(dict(provider="tailscale", enabled=False)))
            now = 0
            manager = TunnelLifecycle(directory, 8767, now=lambda: now)
            manager.enabled = True
            command.return_value = {'BackendState': 'Stopped'}
            await manager.tick(AsyncMock(return_value=False))
            await manager.tick(AsyncMock(return_value=False))
            self.assertEqual(1, command.await_count, 'Do not poll the CLI on every maintenance tick')
            now = 31; command.side_effect = [STATUS, serve_config()]
            await manager.tick(AsyncMock(return_value=True))
            self.assertEqual('connected', manager.provider.state['state'])


if __name__ == '__main__': unittest.main()
