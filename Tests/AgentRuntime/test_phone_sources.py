"""Synthetic source evidence: durable revocation, complete pagination and authenticated routes."""
import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
import uuid
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / 'Apps/MacApp/Context'), str(ROOT / 'Apps/MacApp/Access')]
from context_store import ContextStore, Conflict
from phone_sources import sync_phone_source, read_phone_sources
from rtc_transport import permitted_route
from context_server import ContextService


class PhoneSourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = ContextStore(Path(self.temp.name))
        self.payload = dict(device_id=str(uuid.uuid4()), kind='calendar', revision=1, state='enabled',
                            observed_at=1000000, window_start=950000, window_end=1100000, timezone='Asia/Shanghai',
                            records=[dict(id='fixture-event', source_name='Fixture Calendar', title='Synthetic appointment',
                                          start=1000010, end=1000100, all_day=False)])

    def tearDown(self):
        self.store.close(); self.temp.cleanup()

    def test_restart_lost_ack_replay_and_revocation(self):
        receipt = sync_phone_source(self.store, self.payload)
        self.store.close(); self.store = ContextStore(Path(self.temp.name))
        self.assertEqual(receipt, sync_phone_source(self.store, self.payload))
        changed = copy.deepcopy(self.payload); changed['records'][0]['title'] = 'Changed'
        with self.assertRaises(Conflict): sync_phone_source(self.store, changed)
        sync_phone_source(self.store, dict(self.payload, revision=2, state='disabled', records=[]))
        with self.assertRaises(Conflict): sync_phone_source(self.store, self.payload)
        item = read_phone_sources(self.store, 'calendar')['items'][0]
        self.assertEqual('disabled', item['state']); self.assertEqual([], item['records'])

    def test_all_three_sources_and_no_memory_ingestion(self):
        sync_phone_source(self.store, self.payload)
        sync_phone_source(self.store, dict(self.payload, kind='reminders', window_end=1000000, records=[
            dict(id='undated', title='Synthetic undated task', source_name='Fixture List'),
            dict(id='overdue', title='Synthetic overdue task', source_name='Fixture List', start=500000)]))
        sync_phone_source(self.store, dict(self.payload, kind='visits', state='foreground_only', window_end=1000000, records=[
            dict(id='visit', source_name='CoreLocation visits', start=999990, latitude=31.2, longitude=121.5, accuracy=50)]))
        for kind in ('visits', 'calendar', 'reminders'):
            self.assertTrue(read_phone_sources(self.store, kind)['items'][0]['records'])
        self.assertEqual(0, self.store.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0])
        self.assertEqual(0, self.store.db.execute('SELECT COUNT(*) FROM sources').fetchone()[0])

    def test_pages_cover_every_record_and_device_without_duplicates(self):
        records = [dict(self.payload['records'][0], id=str(n)) for n in range(125)]
        sync_phone_source(self.store, dict(self.payload, records=records))
        sync_phone_source(self.store, dict(self.payload, device_id=str(uuid.uuid4()), records=[]))
        after, seen, pages = '', [], 0
        while True:
            page = read_phone_sources(self.store, 'calendar', after, limit=40)
            seen += [record['id'] for item in page['items'] for record in item['records']]
            pages += 1
            after = page['next_cursor']
            if not after: break
            self.assertLess(pages, 6)
        self.assertEqual(len(seen), 125); self.assertEqual(len(set(seen)), 125); self.assertEqual(pages, 5)

    def test_changed_snapshot_invalidates_cursor(self):
        value = dict(self.payload, records=[dict(self.payload['records'][0], id=str(n)) for n in range(3)])
        sync_phone_source(self.store, value)
        cursor = read_phone_sources(self.store, 'calendar', limit=1)['next_cursor']
        sync_phone_source(self.store, dict(value, revision=2, records=[]))
        with self.assertRaises(Conflict): read_phone_sources(self.store, 'calendar', cursor)
        with self.assertRaises(ValueError): read_phone_sources(self.store, 'reminders', cursor)

    def test_read_failure_withdraws_old_values_and_freshness_is_explicit(self):
        sync_phone_source(self.store, self.payload)
        self.assertTrue(read_phone_sources(self.store, 'calendar', now=1004000)['items'][0]['stale'])
        self.assertTrue(read_phone_sources(self.store, 'calendar', now=990000)['items'][0]['clock_ahead'])
        sync_phone_source(self.store, dict(self.payload, revision=2, state='needs_permission', records=[]))
        self.assertEqual([], read_phone_sources(self.store, 'calendar')['items'][0]['records'])

    def test_invalid_and_oversized_snapshots_are_rejected_atomically(self):
        variants = [dict(self.payload, records=self.payload['records'] * 2001),
                    dict(self.payload, records=self.payload['records'] * 2),
                    dict(self.payload, state='disabled'), dict(self.payload, revision=True),
                    dict(self.payload, observed_at=float('nan')), dict(self.payload, timezone='invalid-zone')]
        for value in variants:
            with self.subTest(value=list(value)):
                with self.assertRaises(ValueError): sync_phone_source(self.store, value)
        self.assertEqual([], read_phone_sources(self.store, 'calendar')['items'])

    def test_private_location_fields_cannot_leak_through_calendar_and_unknown_fields_are_not_stored(self):
        value = copy.deepcopy(self.payload); value['records'][0]['latitude'] = 1
        with self.assertRaises(ValueError): sync_phone_source(self.store, value)
        value['records'][0].pop('latitude'); value['records'][0]['notes'] = 'not in the authorized snapshot scope'
        sync_phone_source(self.store, value)
        self.assertNotIn('notes', read_phone_sources(self.store, 'calendar')['items'][0]['records'][0])

    def test_network_routes_are_exact_and_read_only(self):
        self.assertIsNotNone(permitted_route('POST', '/context/v1/phone-sources'))
        self.assertIsNotNone(permitted_route('GET', '/context/v1/phone-sources?kind=calendar'))
        for method, path in [('DELETE', '/context/v1/phone-sources'), ('POST', '/context/v1/phone-sources/execute'),
                             ('POST', '/v1/phone-sources')]:
            self.assertIsNone(permitted_route(method, path))

    def test_real_authenticated_http_upload_and_read(self):
        data = Path(self.temp.name) / 'service'; data.mkdir()
        (data / 'api-key').write_text('fixture-only')
        service = ContextService(data, dict(data_url='http://127.0.0.1:0', workspace_id=str(uuid.uuid4())))
        service.start(); self.addCleanup(service.close)
        url = f'http://127.0.0.1:{service.server.server_port}/v1/phone-sources'
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with self.assertRaises(urllib.error.HTTPError) as denied: opener.open(url + '?kind=calendar')
        self.assertEqual(401, denied.exception.code)
        headers = {'Authorization': 'Bearer fixture-only'}
        with opener.open(urllib.request.Request(url, data=json.dumps(self.payload).encode(), headers=headers)) as response:
            self.assertEqual(1, json.load(response)['revision'])
        with opener.open(urllib.request.Request(url + '?kind=calendar', headers=headers)) as response:
            self.assertEqual('Synthetic appointment', json.load(response)['items'][0]['records'][0]['title'])


class PhoneSourceMCPTests(unittest.IsolatedAsyncioTestCase):
    async def test_actual_mcp_tool_is_available_only_to_conversation_not_ingestion(self):
        from mcp import ClientSession, StdioServerParameters
        from mcp.client.stdio import stdio_client
        with tempfile.TemporaryDirectory() as directory:
            store = ContextStore(directory)
            sync_phone_source(store, dict(device_id=str(uuid.uuid4()), kind='reminders', revision=1, state='enabled',
                                         observed_at=1000000, window_start=950000, window_end=1000000, timezone='UTC',
                                         records=[dict(id='fixture', title='Synthetic task', source_name='Fixture List')]))
            store.close()
            for memory_only in ('0', '1'):
                params = StdioServerParameters(command=sys.executable, args=[str(ROOT / 'Apps/MacApp/Context/context_mcp.py')],
                    env={'PATH': os.defpath, 'MOMO_CONTEXT_DIRECTORY': directory, 'MOMO_MEMORY_ONLY': memory_only,
                         'PYTHONDONTWRITEBYTECODE': '1'})
                async with stdio_client(params) as (read, write):
                    async with ClientSession(read, write) as client:
                        await client.initialize()
                        self.assertEqual(memory_only == '0', 'read_phone_context' in {t.name for t in (await client.list_tools()).tools})
                        if memory_only == '0':
                            result = await client.call_tool('read_phone_context', arguments={'kind': 'reminders'})
                            self.assertFalse(result.is_error)
                            self.assertEqual('Synthetic task', json.loads(result.content[0].text)['items'][0]['records'][0]['title'])


if __name__ == '__main__': unittest.main()
