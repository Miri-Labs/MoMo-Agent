import asyncio
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
import uuid
from unittest.mock import AsyncMock, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Apps/MacApp/Runtime'))
from superagent_computer import SuperAgentComputer, DesktopLease


def module_at(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ComputerTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.data = Path(self.temp.name)
        self.ticket = dict(state='open', assignments=[dict(id='run-1', state='running')])
        self.read = AsyncMock(side_effect=lambda _: self.ticket)
        self.bridge = SuperAgentComputer(self.data, self.read)
        self.lease = DesktopLease(self.data)
        self.native = AsyncMock(return_value={'result': {'ok': True, 'data': {'complete': False, 'snapshot_id': 's1'}}})
        self.patch = patch('superagent_computer.native_request', self.native); self.patch.start(); self.addCleanup(self.patch.stop)

    async def snapshot(self, ticket='ticket-1'):
        return await self.bridge.call(ticket, 'run-1', 'accessibility-snapshot', {})

    async def action(self, ticket='ticket-1'):
        return await self.bridge.call(ticket, 'run-1', 'accessibility-action', {'ref': '@s1:e1', 'action': 'click'})

    async def test_requires_observation_releases_between_calls_and_preserves_partial(self):
        with self.assertRaisesRegex(PermissionError, 'snapshot'): await self.action()
        self.native.assert_not_awaited()
        result = await self.snapshot()
        self.assertFalse(result['data']['complete'])
        self.assertNotIn('agent_work', self.lease.read())
        await self.action()
        self.assertNotIn('agent_work', self.lease.read())
        self.assertEqual('ticket-1', self.read.await_args.args[0])
        self.assertEqual('accessibility-action', self.native.await_args.args[1]['op'])

    async def test_takeover_and_other_task_invalidate_prior_observation(self):
        await self.snapshot()
        human = self.lease.acquire('phone', str(uuid.uuid4()))
        with self.assertRaises(PermissionError): await self.action()
        self.lease.release('phone', human['session'])
        with self.assertRaisesRegex(PermissionError, 'snapshot'): await self.action()
        await self.snapshot(); await self.snapshot('other-ticket')
        with self.assertRaisesRegex(PermissionError, 'snapshot'): await self.action()

    async def test_native_failure_never_retries_and_releases_lease(self):
        await self.snapshot()
        self.native.side_effect = TimeoutError('uncertain delivery')
        with self.assertRaises(TimeoutError): await self.action()
        self.assertEqual(2, self.native.await_count)
        self.assertNotIn('agent_work', self.lease.read())

    async def test_stopped_waiting_paused_or_old_assignments_cannot_dispatch(self):
        for change in ({'state': 'ended'}, {'paused': True}, {'attention': {'question': 'answer'}},
                       {'assignments': [{'id': 'run-2', 'state': 'running'}]},
                       {'assignments': [{'id': 'run-1', 'state': 'running', 'turnEndedAt': 'now'}]}):
            self.ticket = dict(state='open', assignments=[dict(id='run-1', state='running')], **{})
            self.ticket.update(change)
            with self.assertRaises(PermissionError): await self.snapshot()
        self.native.assert_not_awaited()

    async def test_takeover_during_read_discards_result(self):
        async def takeover(*_):
            self.lease.acquire('phone', str(uuid.uuid4()))
            return {'result': {'ok': True}}
        self.native.side_effect = takeover
        with self.assertRaisesRegex(PermissionError, 'changed'): await self.snapshot()
        self.assertEqual('human', self.lease.read()['owner'])
        self.assertNotIn('agent_work', self.lease.read())
        self.assertEqual({}, self.bridge.observations)

    async def test_existing_hermes_owner_is_not_stolen(self):
        with self.lease.locked(): self.lease.write(dict(owner='agent', epoch=1, agent_work={'work_id': 'hermes'}))
        with self.assertRaises(PermissionError): await self.snapshot()
        self.assertEqual({'work_id': 'hermes'}, self.lease.read()['agent_work'])
        self.native.assert_not_awaited()

    async def test_mcp_envelope_and_authority(self):
        with patch.dict(os.environ, {'MOMO_AGENT_DIRECTORY': str(self.data)}):
            module = module_at('agent_desktop_mcp_test', ROOT / 'Apps/MacApp/Runtime/desktop_mcp.py')
        from mcp.server.mcpserver.exceptions import ToolError
        with patch.object(module, 'native_request', self.native):
            for name in ('computer_snapshot', 'computer_action'):
                args = {} if name == 'computer_snapshot' else {'ref': '@s1:e1', 'action': 'click'}
                with self.assertRaises(ToolError): await module.server.call_tool(name, args)
            self.native.assert_not_awaited()
            control = dict(work_id='w', run_id='r', generation=1, epoch=3)
            self.lease.write(dict(owner='agent', epoch=3, agent_work={k: v for k, v in control.items() if k != 'epoch'}))
            await module.server.call_tool('computer_snapshot', {'momo_control': control})
            self.assertEqual(3, self.lease.read()['observed_epoch'])
            error = {'ok': False, 'error': {'code': 'STALE_REF', 'delivery': 'not_started'}}
            self.native.return_value = {'result': error}
            response = await module.computer_action('@s1:e1', 'click', momo_control=control)
            self.assertEqual(error, response)
            self.assertEqual(control, self.native.await_args.args[1]['control'])


class BundleTests(unittest.TestCase):
    def test_bad_checksum_is_rejected_without_loading(self):
        module = module_at('agent_desktop_bundle_test', ROOT / 'Scripts/bundle-agent-desktop.py')
        with tempfile.TemporaryDirectory() as temporary:
            cache = Path(temporary); (cache / 'bad.tar.gz').write_bytes(b'tampered')
            with self.assertRaisesRegex(ValueError, 'checksum'):
                module.verified_archive(cache, 'bad.tar.gz', '0' * 64, 'v1.0.2')


if __name__ == '__main__': unittest.main()
