"""Model setup uses Hermes credentials and commits only a verified provider route."""
from contextlib import redirect_stdout, redirect_stderr
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import MagicMock, Mock, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Apps/MacApp/Runtime'))
import model_setup as setup
import momo_agent as runtime


def modules(**values):
    result = {}
    for name, attributes in values.items():
        module = ModuleType(name)
        module.__dict__.update(attributes)
        result[name] = module
    return patch.dict(sys.modules, result)


class ModelSetupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.data = Path(self.temporary.name) / 'agent'
        runtime.initialize(self.data, 8775)
        self.file = self.data / 'profile/config.yaml'
        config = json.loads(self.file.read_text())
        config['memory'] = {'user_profile_enabled': True}  # Existing profile with user-owned settings.
        config['model'] = {'provider': 'custom', 'base_url': 'https://old-provider.invalid/v1', 'default': 'old-model'}
        self.file.write_text(json.dumps(config))
        self.original = self.file.read_bytes()

    def test_subscription_commit_discards_old_custom_endpoint_and_preserves_data(self):
        credential = (self.data / 'api-key').read_bytes()
        connection = (self.data / 'connection.json').read_bytes()
        with patch.object(setup, 'resolve_credentials', return_value={'api_key': 'private-plan-secret'}), \
                patch.object(setup, 'probe') as probe:
            result = setup.verify_and_save(self.data, 'codex', 'selected-model')
        probe.assert_called_once_with('codex', 'selected-model', {'api_key': 'private-plan-secret'})
        config = json.loads(self.file.read_text())
        self.assertEqual(config['model'], {'provider': 'openai-codex', 'default': 'selected-model'})
        self.assertEqual(json.loads(self.original)['memory'], config['memory'])
        self.assertEqual(self.file.stat().st_mode & 0o777, 0o600)
        self.assertEqual(credential, (self.data / 'api-key').read_bytes())
        self.assertEqual(connection, (self.data / 'connection.json').read_bytes())
        self.assertNotIn('private-plan-secret', json.dumps(result))

    def test_failed_probe_preserves_working_configuration(self):
        with patch.object(setup, 'resolve_credentials', return_value={}), \
                patch.object(setup, 'probe', side_effect=RuntimeError('provider rejected the request')):
            with self.assertRaises(RuntimeError):
                setup.verify_and_save(self.data, 'claude', 'selected-model')
        self.assertEqual(self.original, self.file.read_bytes())

    def test_invalid_model_never_resolves_or_spends_credentials(self):
        with patch.object(setup, 'resolve_credentials') as resolve:
            for model in ['', '  ', 'unexpected model', 'x' * 201]:
                with self.assertRaises(setup.ModelSetupError):
                    setup.verify_and_save(self.data, 'codex', model)
        resolve.assert_not_called()
        self.assertEqual(self.original, self.file.read_bytes())

    def test_codex_does_not_silently_adopt_a_cli_refresh_token(self):
        resolve = Mock()
        with modules(**{
            'hermes_cli.auth_codex': {'resolve_codex_runtime_credentials': resolve},
            'hermes_cli.auth': {'get_codex_auth_status': lambda: {'logged_in': False}},
        }):
            with self.assertRaises(setup.ModelSetupError):
                setup.resolve_credentials('codex', 'model')
        resolve.assert_not_called()

    def test_claude_subscription_rejects_api_key_before_a_network_call(self):
        build = Mock()
        with modules(**{
            'agent.anthropic_adapter': {'build_anthropic_client': build, 'build_anthropic_kwargs': Mock()},
            'agent.anthropic_credentials': {'_is_oauth_token': lambda token: token.startswith('oauth-')},
        }):
            with self.assertRaises(setup.ModelSetupError):
                setup.probe('claude', 'model', {'api_key': 'api-key', 'base_url': 'https://api.anthropic.com'})
        build.assert_not_called()

    def test_claude_uses_official_login_and_only_exports_the_authorization_link(self):
        child = Mock()
        child.stdout = io.StringIO('private diagnostics\nhttps://evil.invalid/oauth/authorize\nhttps://claude.ai/oauth/authorize?state=test\n')
        child.wait.return_value = 0
        child.poll.return_value = 0
        authorize = Mock()
        with modules(**{'agent.anthropic_adapter': {'find_claude_code_cli': lambda command: '/official/claude'}}), \
                patch.object(setup.subprocess, 'Popen', return_value=child) as launch, \
                patch.object(setup, 'account', return_value={'connected': True}):
            self.assertTrue(setup.login('claude', authorize)['connected'])
        self.assertEqual(launch.call_args.args[0], ['/official/claude', 'auth', 'login', '--claudeai'])
        self.assertIs(launch.call_args.kwargs['stdout'], subprocess.PIPE)
        self.assertIs(launch.call_args.kwargs['stdin'], subprocess.DEVNULL)
        authorize.assert_called_once()
        self.assertEqual(authorize.call_args.kwargs['url'], 'https://claude.ai/oauth/authorize?state=test')

    def test_codex_exports_a_code_before_polling_and_saves_only_after_approval(self):
        events = []
        tokens = {'access_token': 'private-access', 'refresh_token': 'private-refresh'}
        poll = Mock(side_effect=lambda *a, **kw: events.append('poll') or {'authorization_code': 'approved'})
        save = Mock(side_effect=lambda *a, **kw: events.append('save'))
        with modules(**{
            'hermes_cli.auth_constants': {'CODEX_OAUTH_CLIENT_ID': 'public-client'},
            'hermes_cli.auth_codex': {
                '_codex_request_device_code': Mock(return_value={'user_code': 'ABCD-1234', 'device_auth_id': 'private-id', 'interval': 5}),
                '_codex_poll_authorization_code': poll,
                '_codex_exchange_authorization_code': Mock(return_value=tokens), '_save_codex_tokens': save,
            },
        }), patch.object(setup, 'account', return_value={'connected': True}):
            def authorize(**fields):
                self.assertEqual(fields['url'], 'https://auth.openai.com/codex/device')
                self.assertEqual(fields['code'], 'ABCD-1234')
                self.assertNotIn('private', json.dumps(fields))
                events.append('code')
            self.assertTrue(setup.login('codex', authorize)['connected'])
        self.assertEqual(events, ['code', 'poll', 'save'])
        save.assert_called_once_with(tokens)

    def test_login_links_cannot_escape_to_an_untrusted_origin(self):
        for url in ['http://claude.ai/oauth/authorize', 'https://claude.ai.evil.invalid/oauth/authorize',
                    'https://claude.ai@evil.invalid/oauth/authorize', 'https://claude.ai:444/oauth/authorize',
                    'https://claude.ai/other']:
            self.assertFalse(setup.authorization_url(url, 'claude'))

    def test_browser_fallback_uses_the_same_hermes_pkce_flow(self):
        authorize = Mock()
        def browser(**options):
            self.assertFalse(options['open_browser'])
            options['on_authorize']('https://auth.openai.com/oauth/authorize?state=test')
            return {'tokens': {'access_token': 'private'}, 'last_refresh': 'now'}
        save = Mock()
        with modules(**{'hermes_cli.auth_codex_browser': {'_codex_browser_login': browser},
                       'hermes_cli.auth_codex': {'_save_codex_tokens': save}}), \
                patch.object(setup, 'account', return_value={'connected': True}):
            self.assertTrue(setup.login('codex', authorize, 'browser')['connected'])
        self.assertEqual(authorize.call_args.kwargs['url'], 'https://auth.openai.com/oauth/authorize?state=test')
        save.assert_called_once_with({'access_token': 'private'}, last_refresh='now')

    def test_real_hermes_browser_helper_publishes_link_before_waiting(self):
        from urllib.parse import parse_qs, urlsplit
        with patch.object(sys, 'path', [str(setup.SOURCE), *sys.path]), \
                patch.dict(os.environ, {'HERMES_HOME': str(self.data / 'hermes')}):
            spec = importlib.util.spec_from_file_location('momo_browser_helper_probe', setup.SOURCE / 'hermes_cli/auth_codex_browser.py')
            browser = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(browser)
            callback, events = {}, []
            def authorize(url):
                query = parse_qs(urlsplit(url).query)
                self.assertEqual(query['code_challenge_method'], ['S256'])
                callback.update(code='approved', state=query['state'][0])
                events.append('link')
            def wait(*args, **kwargs):
                events.append('wait')
                return callback
            with patch.object(browser, '_make_loopback_callback_handler', return_value=(object, {})), \
                    patch.object(browser, '_bind_loopback_callback_server', return_value=Mock(server_address=('127.0.0.1', 1455))), \
                    patch.object(browser, '_serve_loopback_callback', side_effect=wait), \
                    patch.object(browser, '_codex_browser_exchange_code', return_value={'access_token': 'test-access'}), \
                    redirect_stdout(io.StringIO()):
                result = browser._codex_browser_login(open_browser=False, on_authorize=authorize)
            self.assertEqual(events, ['link', 'wait'])
            self.assertEqual(result['tokens']['access_token'], 'test-access')

    def test_codex_probe_requires_text_and_a_successful_stream_completion(self):
        delta = SimpleNamespace(type='response.output_text.delta', delta='OK')
        completed = SimpleNamespace(type='response.completed', response=SimpleNamespace(status='completed'))
        failed = SimpleNamespace(type='response.failed')
        for events, succeeds in [([delta, completed], True), ([delta, failed], False), ([delta], False), ([completed], False)]:
            with self.subTest(succeeds=succeeds, events=[event.type for event in events]):
                stream = MagicMock()
                stream.__enter__.return_value = events
                client = MagicMock()
                client.__enter__.return_value = client
                client.responses.create.return_value = stream
                factory = Mock(return_value=client)
                transport = Mock()
                with modules(**{'openai': {'OpenAI': factory},
                        'agent.process_bootstrap': {'build_keepalive_http_client': Mock(return_value=transport)},
                        'agent.codex_headers': {'apply_required_codex_headers': Mock()}}):
                    if succeeds:
                        setup.probe('codex', 'model', {'api_key': 'private-token', 'base_url': 'https://chatgpt.com/backend-api/codex'})
                    else:
                        with self.assertRaises(setup.ModelSetupError):
                            setup.probe('codex', 'model', {'api_key': 'private-token', 'base_url': 'https://chatgpt.com/backend-api/codex'})
                self.assertFalse(client.responses.create.call_args.kwargs['store'])
                self.assertTrue(client.responses.create.call_args.kwargs['stream'])
                self.assertEqual(factory.call_args.kwargs['max_retries'], 0)
                self.assertIs(factory.call_args.kwargs['http_client'], transport)

    def test_claude_probe_uses_hermes_oauth_adapter_without_tools(self):
        client = MagicMock()
        client.__enter__.return_value = client
        client.messages.create.return_value = SimpleNamespace(content=[SimpleNamespace(text='OK')])
        build = Mock(return_value=client)
        kwargs = Mock(return_value={'model': 'model', 'messages': []})
        with modules(**{'agent.anthropic_adapter': {'build_anthropic_client': build, 'build_anthropic_kwargs': kwargs},
                'agent.anthropic_credentials': {'_is_oauth_token': lambda token: token.startswith('oauth-')}}):
            setup.probe('claude', 'model', {'api_key': 'oauth-test', 'base_url': 'https://api.anthropic.com'})
        self.assertTrue(kwargs.call_args.kwargs['is_oauth'])
        self.assertIsNone(kwargs.call_args.kwargs['tools'])
        self.assertEqual(kwargs.call_args.kwargs['max_tokens'], 32)

    def test_claude_timeout_terminates_the_browser_callback_process(self):
        child = Mock(pid=12345)
        child.stdout = io.StringIO('')
        child.wait.side_effect = [subprocess.TimeoutExpired('claude auth login', 300),
                                 subprocess.TimeoutExpired('claude auth login', 1), 0]
        child.poll.return_value = None
        with modules(**{'agent.anthropic_adapter': {'find_claude_code_cli': lambda command: '/official/claude'}}), \
                patch.object(setup.subprocess, 'Popen', return_value=child), \
                patch.object(setup.os, 'killpg') as kill:
            with self.assertRaises(subprocess.TimeoutExpired):
                setup.login('claude')
        self.assertEqual([call.args for call in kill.call_args_list], [(12345, setup.signal.SIGTERM), (12345, setup.signal.SIGKILL)])

    def test_login_timeout_is_actionable_and_disarms_the_deadline(self):
        output = io.StringIO()
        argv = ['model_setup.py', 'login', '--provider', 'codex', '--data-dir', str(self.data)]
        with patch.object(sys, 'argv', argv), patch.dict(os.environ), \
                patch.object(setup.signal, 'signal'), patch.object(setup.signal, 'alarm') as alarm, \
                patch.object(setup, 'login', side_effect=setup.ModelSetupError('登录已超时，请重试。')), \
                redirect_stdout(output), redirect_stderr(io.StringIO()):
            self.assertEqual(setup.main(), 1)
        self.assertEqual(json.loads(output.getvalue())['error'], '登录已超时，请重试。')
        self.assertEqual([call.args for call in alarm.call_args_list], [(300,), (0,)])

    def test_untrusted_provider_error_text_never_reaches_ui(self):
        output = io.StringIO()
        argv = ['model_setup.py', 'status', '--provider', 'codex', '--data-dir', str(self.data)]
        with patch.object(sys, 'argv', argv), patch.dict(os.environ), \
                patch.object(setup, 'account', side_effect=RuntimeError('access-token-secret')), \
                redirect_stdout(output), redirect_stderr(io.StringIO()):
            code = setup.main()
        self.assertEqual(code, 1)
        self.assertIn('error', json.loads(output.getvalue()))
        self.assertNotIn('access-token-secret', output.getvalue())

    def test_provider_notice_classifies_quota_auth_and_rate_limit_without_secret_leakage(self):
        import provider_notice as pn

        secret_url = 'https://secret-gateway.internal/v1?key=sk-secret-999'

        # 1. Codex usage / quota limit (without secret leakage)
        codex_quota = pn.classify_provider_issue(
            f'Error code: 429 - {{"error": {{"code": "usage_limit_reached", "message": "You have hit your usage limit ({secret_url})"}}}}',
            provider='codex',
        )
        self.assertIsNotNone(codex_quota)
        self.assertEqual(codex_quota['kind'], 'quota')
        self.assertEqual(codex_quota['provider'], 'openai-codex')
        self.assertIn('Codex 当前额度已用完', codex_quota['title'])
        self.assertNotIn('sk-secret-999', json.dumps(codex_quota, ensure_ascii=False))
        self.assertNotIn('secret-gateway', json.dumps(codex_quota, ensure_ascii=False))

        # 3. Claude credit balance / auth expiration
        claude_quota = pn.classify_provider_issue(
            'AnthropicError: Your credit balance is too low to access the Anthropic API.',
            provider='anthropic',
        )
        self.assertEqual(claude_quota['kind'], 'quota')
        self.assertIn('Claude 当前额度已用完', claude_quota['title'])

        claude_auth = pn.classify_provider_issue(
            SimpleNamespace(status_code=401, message='OAuth token has expired sk-ant-oat01-secret'),
            provider='claude',
        )
        self.assertEqual(claude_auth['kind'], 'auth')
        self.assertIn('Claude 需要重新登录', claude_auth['title'])
        self.assertNotIn('sk-ant-oat01-secret', json.dumps(claude_auth, ensure_ascii=False))

        # 4. Short-term rate limit vs non-provider local errors
        rate_busy = pn.classify_provider_issue(
            SimpleNamespace(status_code=429, message='Too Many Requests'),
            provider='custom',
        )
        self.assertEqual(rate_busy['kind'], 'rate_limit')
        self.assertIn('请求较忙', rate_busy['title'])

        for local_err in (
            'PermissionError: [Errno 13] Permission denied: /tmp/local.txt',
            'Connection refused: 127.0.0.1:8779',
            'gateway_restarted',
            'The prepare command failed: git status 128',
        ):
            self.assertIsNone(pn.classify_provider_issue(local_err, provider='codex'))

    def test_provider_notice_coalesces_retries_and_clears_on_verified_model_save(self):
        import provider_notice as pn

        first = pn.record_provider_issue(
            self.data,
            'insufficient_quota: exceeded your current quota',
            provider='codex',
            now=1000.0,
        )
        second = pn.record_provider_issue(
            self.data,
            'insufficient_quota: retry #2 failed',
            provider='codex',
            now=1025.0,
        )
        self.assertEqual(first['id'], second['id'])
        self.assertEqual(pn.read_provider_notice(self.data, now=1030.0)['id'], first['id'])

        later = pn.record_provider_issue(
            self.data,
            'insufficient_quota: new turn 10 minutes later',
            provider='codex',
            now=1700.0,
        )
        self.assertEqual(first['id'], later['id'])

        with patch.object(setup, 'resolve_credentials', return_value={'api_key': 'sk-ant-oat01-x', 'base_url': 'https://api.anthropic.com'}), \
                patch.object(setup, 'probe'):
            setup.verify_and_save(self.data, 'claude', 'claude-sonnet-4-6')
        self.assertIsNone(pn.read_provider_notice(self.data, now=1705.0))
        fresh = pn.record_provider_issue(self.data, 'insufficient_quota', provider='codex', now=1710.0)
        self.assertNotEqual(first['id'], fresh['id'])

    def test_dismissed_quota_survives_expiry_upgrade_and_interleaved_failures(self):
        import provider_notice as pn

        original = pn.build_provider_notice('quota', provider='anthropic', now=1000)
        path = self.data / pn.PROVIDER_NOTICE_REL
        path.parent.mkdir(exist_ok=True)
        path.write_text(json.dumps(original))  # Installed version before quota episode tracking.
        tomorrow = 1000 + 86400
        self.assertIsNone(pn.read_provider_notice(self.data, now=tomorrow))
        other = pn.record_provider_issue(self.data, 'insufficient_quota', provider='codex', now=tomorrow)
        pn.record_provider_issue(self.data, 'rate limit', provider='claude', now=tomorrow)
        retry = pn.record_provider_issue(self.data, 'insufficient_quota', provider='claude', now=tomorrow + 1)
        self.assertEqual((retry['id'], retry['created_at']), (original['id'], original['created_at']))
        self.assertEqual(pn.read_provider_notice(self.data, now=tomorrow + 1), retry)

        self.assertTrue(pn.clear_provider_notice(self.data, provider='anthropic'))
        self.assertIsNone(pn.read_provider_notice(self.data, now=tomorrow + 1))
        other_retry = pn.record_provider_issue(self.data, 'insufficient_quota', provider='codex', now=tomorrow + 2)
        self.assertEqual(other['id'], other_retry['id'])
        new = pn.record_provider_issue(self.data, 'insufficient_quota', provider='claude', now=tomorrow + 3)
        self.assertNotEqual(new['id'], original['id'])

    def test_concurrent_quota_reports_share_one_notice(self):
        from concurrent.futures import ThreadPoolExecutor
        from threading import Barrier
        import provider_notice as pn

        start = Barrier(8)
        def report(_):
            start.wait(timeout=5)
            return pn.record_provider_issue(self.data, 'insufficient_quota', provider='codex')['id']

        with ThreadPoolExecutor(max_workers=8) as pool:
            self.assertEqual(set(pool.map(report, range(8))), {pn.read_provider_notice(self.data)['id']})

    def test_intermittent_model_success_cannot_repeat_the_quota_alert_within_a_day(self):
        import provider_notice as pn

        first = pn.record_provider_issue(self.data, 'insufficient_quota', provider='codex', now=1000)
        self.assertTrue(pn.clear_provider_notice(self.data, provider='codex'))
        self.assertIsNone(pn.read_provider_notice(self.data, now=2000))
        retry = pn.record_provider_issue(self.data, 'insufficient_quota', provider='codex', now=2000)
        self.assertEqual(first['id'], retry['id'])
        self.assertTrue(pn.clear_provider_notice(self.data, provider='codex'))
        self.assertFalse(pn.clear_provider_notice(self.data, provider='codex'))
        next_day = pn.record_provider_issue(self.data, 'insufficient_quota', provider='codex', now=1000 + 86400)
        self.assertNotEqual(first['id'], next_day['id'])

    def test_legacy_antigravity_config_is_rejected_cleanly(self):
        from superagent_runtime import resolve_superagent_llm

        self.file.write_text(json.dumps({'model': {'provider': 'antigravity', 'default': 'gemini-4-hydrogen-medium'}}))
        with self.assertRaises(ValueError):
            resolve_superagent_llm(self.data)


if __name__ == '__main__':
    unittest.main()
