"""Health source contract, replay safety, opt-out and authenticated HTTP/MCP boundaries."""
import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Apps/MacApp/Context'))
sys.path.insert(0, str(ROOT / 'Apps/MacApp/Access'))
from context_store import ContextStore, Conflict
from health_store import sync_health, read_health
from context_server import ContextService
from rtc_transport import permitted_route


class HealthTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        self.store = ContextStore(self.directory)
        self.payload = dict(device_id=str(uuid.uuid4()), revision=1, state='enabled', observed_at=100000,
                            window_start=10000, window_end=100000, timezone='Asia/Shanghai', observations=[
                                dict(metric='heart_rate', unit='count/min', value=65, start=99000, end=99001,
                                     source_name='Fixture Watch', source_bundle='com.example.fixture')])

    def tearDown(self):
        self.store.close(); self.temp.cleanup()

    def test_retry_after_restart_is_idempotent_and_opt_out_cannot_be_reversed_by_stale_upload(self):
        receipt = sync_health(self.store, self.payload)
        self.store.close(); self.store = ContextStore(self.directory)
        self.assertEqual(receipt, sync_health(self.store, self.payload))
        changed = copy.deepcopy(self.payload); changed['observations'][0]['value'] = 66
        with self.assertRaises(Conflict): sync_health(self.store, changed)
        disabled = dict(self.payload, revision=2, state='disabled', observations=[])
        sync_health(self.store, disabled)
        with self.assertRaises(Conflict): sync_health(self.store, self.payload)
        self.assertEqual([], read_health(self.store)['items'][0]['observations'])
        self.assertEqual('disabled', read_health(self.store)['items'][0]['state'])

    def test_empty_samples_are_not_zero_or_denial_and_no_automatic_memory_ingestion(self):
        sync_health(self.store, dict(self.payload, observations=[]))
        item = read_health(self.store, now=100001)['items'][0]
        self.assertEqual([], item['observations']); self.assertFalse(item['stale'])
        self.assertEqual(0, self.store.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0])
        self.assertEqual(0, self.store.db.execute('SELECT COUNT(*) FROM sources').fetchone()[0])

    def test_measurement_age_is_separate_from_upload_freshness_and_clock_skew(self):
        sync_health(self.store, self.payload)
        item = read_health(self.store, now=104000)['items'][0]
        self.assertTrue(item['stale']); self.assertEqual(4999, item['observations'][0]['age_seconds'])
        self.assertTrue(read_health(self.store, now=90000)['items'][0]['clock_ahead'])

    def test_invalid_units_nan_coverage_and_duplicates_are_rejected_without_mutation(self):
        for change in ({'unit': 'bpm-guess'}, {'value': float('nan')}, {'end': 100001}, {'source_name': ''}):
            bad = copy.deepcopy(self.payload); bad['observations'][0].update(change)
            with self.assertRaises(ValueError): sync_health(self.store, bad)
        bad = copy.deepcopy(self.payload); bad['observations'] *= 2
        with self.assertRaises(ValueError): sync_health(self.store, bad)
        self.assertEqual([], read_health(self.store)['items'])

    def test_device_pages_are_explicit_and_do_not_silently_merge_overlapping_data(self):
        sync_health(self.store, self.payload)
        sync_health(self.store, dict(self.payload, device_id=str(uuid.uuid4())))
        first = read_health(self.store, limit=1)
        second = read_health(self.store, after=first['next_cursor'], limit=1)
        self.assertIsNone(second['next_cursor'])
        self.assertNotEqual(first['items'][0]['device_id'], second['items'][0]['device_id'])

    def test_authenticated_http_sync_query_and_route_allowlist(self):
        data = self.directory / 'service'; data.mkdir()
        (data / 'api-key').write_text('fixture-only')
        service = ContextService(data, dict(data_url='http://127.0.0.1:0', workspace_id=str(uuid.uuid4())))
        service.start(); self.addCleanup(service.close)
        url = 'http://127.0.0.1:' + str(service.server.server_port) + '/v1/health'
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with self.assertRaises(urllib.error.HTTPError) as denied: opener.open(url)
        self.assertEqual(401, denied.exception.code)
        request = urllib.request.Request(url, data=json.dumps(self.payload).encode(), headers={'Authorization': 'Bearer fixture-only'})
        with opener.open(request) as response: self.assertEqual(1, json.load(response)['revision'])
        with opener.open(urllib.request.Request(url, headers={'Authorization': 'Bearer fixture-only'})) as response:
            self.assertEqual(65, json.load(response)['items'][0]['observations'][0]['value'])
        self.assertEqual(('/v1/health', True, False), permitted_route('POST', '/context/v1/health'))
        self.assertIsNone(permitted_route('POST', '/v1/health'))
        self.assertIsNone(permitted_route('DELETE', '/context/v1/health'))


class HealthMCPTests(unittest.IsolatedAsyncioTestCase):
    async def test_actual_stdio_tool_reads_the_synced_copy_and_is_absent_from_memory_ingestion(self):
        from mcp import ClientSession, StdioServerParameters
        from mcp.client.stdio import stdio_client
        with tempfile.TemporaryDirectory() as directory:
            store = ContextStore(directory)
            sync_health(store, dict(device_id=str(uuid.uuid4()), revision=1, state='enabled', observed_at=100000,
                                   window_start=10000, window_end=100000, timezone='UTC', observations=[]))
            store.close()
            for memory_only in ('0', '1'):
                params = StdioServerParameters(command=sys.executable, args=[str(ROOT / 'Apps/MacApp/Context/context_mcp.py')],
                    env={'PATH': os.defpath, 'MOMO_CONTEXT_DIRECTORY': directory, 'MOMO_MEMORY_ONLY': memory_only,
                         'PYTHONDONTWRITEBYTECODE': '1'})
                async with stdio_client(params) as (read, write):
                    async with ClientSession(read, write) as client:
                        await client.initialize()
                        tools = await client.list_tools()
                        self.assertEqual(memory_only == '0', 'read_health' in {t.name for t in tools.tools})
                        if memory_only == '0':
                            result = await client.call_tool('read_health', arguments={})
                            data = json.loads(result.content[0].text)
                            self.assertEqual('enabled', data['items'][0]['state'])
                            self.assertEqual([], data['items'][0]['observations'])


if __name__ == '__main__': unittest.main()
