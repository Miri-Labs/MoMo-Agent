"""Personal-context evidence and user consent across model, chat, restart and phone queue."""
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / p) for p in ('Apps/MacApp/Runtime', 'Apps/MacApp/Context', 'Apps/MacApp/Access', 'Vendor/HermesAgent')]
from aiohttp.test_utils import TestClient, TestServer
from context_store import ContextStore, Conflict, digest
from phone_sources import sync_phone_source
import speaker_proposals
import momo_agent
from superagent_gateway import SuperAgentGateway


def source(store):
    spans = [dict(id=str(uuid.uuid4()), text=f'[说话人 {i}] 我叫小林。', recorded_at=100+i, is_owner=False) for i in (1, 2)]
    value = dict(library_id=str(uuid.uuid4()), session_id=str(uuid.uuid4()), device_id=str(uuid.uuid4()),
                 generation=0, version=1, deleted=False, recorded_at=101, spans=spans,
                 text_sha256=digest('\n'.join(s['text'] for s in spans)))
    saved = store.sync_source(value)
    return value, dict(source_id=saved['source_id'], target_speaker='小林', span_ids=[spans[0]['id']],
                       scope='selection', reason='该片段自我介绍为小林')


class ConsentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.data = Path(self.temp.name)
        self.store = ContextStore(self.data / 'context')
        self.addCleanup(lambda: self.store.close())
        self.payload, self.args = source(self.store)

    def delivered(self):
        p = self.store.relabel_speakers(**self.args)
        self.store.db.execute('UPDATE speaker_proposals SET delivered=1 WHERE id=?', (p['proposal_id'],))
        return p['proposal_id']

    def test_no_write_before_permission_and_restart_dedup_exact_scope(self):
        original = self.store.read_source(self.args['source_id'])['text']
        first = self.store.relabel_speakers(**self.args)
        self.assertFalse(first['changed'])
        self.assertEqual([], self.store.pending_speaker_relabels())
        self.assertEqual(original, self.store.read_source(self.args['source_id'])['text'])
        with self.assertRaises(Conflict):
            speaker_proposals.decide(self.store, first['proposal_id'], True, 'not-delivered')
        self.store.close()
        self.store = ContextStore(self.data / 'context')
        self.assertEqual(first['proposal_id'], self.store.relabel_speakers(**self.args)['proposal_id'])
        identifier = self.delivered()
        result = speaker_proposals.decide(self.store, identifier, True, 'owner-confirmed')
        self.assertTrue(result['changed'])
        self.assertEqual(result, speaker_proposals.decide(self.store, identifier, True, 'retry'))
        pending = self.store.pending_speaker_relabels()
        self.assertEqual(1, len(pending))
        self.assertEqual(self.args['span_ids'], pending[0]['span_ids'])
        self.assertEqual('selection', pending[0]['scope'])
        self.assertIn('[说话人 2]', self.store.read_source(self.args['source_id'])['text'])
        self.assertEqual(self.payload['spans'], json.loads(self.store.source(self.args['source_id'])['payload'])['spans'])

    def test_rejection_is_persistent_and_not_resurrected_by_new_reason(self):
        identifier = self.delivered()
        self.assertEqual('rejected', speaker_proposals.decide(self.store, identifier, False, 'owner-no')['state'])
        self.assertEqual('rejected', self.store.relabel_speakers(**dict(self.args, reason='再换一种说法'))['state'])
        self.assertIsNone(speaker_proposals.next_question(self.store, now=1000000))
        self.assertEqual('rejected', speaker_proposals.decide(self.store, identifier, True, 'late-yes')['state'])
        self.assertFalse(self.store.pending_speaker_relabels())

    def test_source_enrichment_or_exclusion_invalidates_consent(self):
        identifier = self.delivered()
        self.payload['spans'][0]['is_owner'] = True
        self.store.sync_source(self.payload)  # Same text revision; speaker evidence changed.
        self.assertEqual('obsolete', speaker_proposals.decide(self.store, identifier, True, 'stale')['state'])
        identifier = self.delivered()
        self.store.exclude_speaker('说话人 1', source_id=self.args['source_id'], span_ids=self.args['span_ids'])
        self.assertEqual('obsolete', speaker_proposals.decide(self.store, identifier, True, 'excluded')['state'])
        with self.assertRaises(Conflict):
            self.store.relabel_speakers(**self.args)
        self.assertFalse(self.store.pending_speaker_relabels())

    def test_named_cluster_and_partial_missing_selection_are_rejected(self):
        for args in (dict(self.args, span_ids=self.args['span_ids'] + [str(uuid.uuid4())]),
                     dict(self.args, scope='cluster', from_speaker='小林'), dict(self.args, span_ids=[])):
            with self.assertRaises(ValueError): self.store.relabel_speakers(**args)

    def test_deleted_source_never_applies_an_old_confirmation(self):
        identifier = self.delivered()
        self.store.sync_source(dict(self.payload, version=2, deleted=True, spans=[], text_sha256=digest('')))
        self.assertEqual('obsolete', speaker_proposals.decide(self.store, identifier, True, 'deleted')['state'])
        self.assertFalse(self.store.pending_speaker_relabels())

    def test_question_is_scoped_and_rate_limited(self):
        first = self.store.relabel_speakers(**self.args)
        question = speaker_proposals.next_question(self.store, now=1000)
        self.assertIn(f"确认标注 {first['proposal_id']}", question['message'])
        self.assertIn(self.payload['session_id'] + '/' + self.args['span_ids'][0], question['message'])
        self.store.db.execute('UPDATE speaker_proposals SET delivered=1000 WHERE id=?', (first['proposal_id'],))
        self.store.relabel_speakers(**dict(self.args, span_ids=[self.payload['spans'][1]['id']]))
        self.assertIsNone(speaker_proposals.next_question(self.store, now=1001))
        self.assertIsNotNone(speaker_proposals.next_question(self.store, now=87401))

    def test_location_overlap_paging_uncertain_boundaries_and_disabled_access(self):
        device = str(uuid.uuid4())
        value = dict(device_id=device, kind='visits', revision=1, state='enabled', observed_at=200,
                     window_start=1, window_end=200, timezone='Asia/Shanghai', records=[
                         dict(id=str(i), source_name='Phone visits', start=90, end=110, latitude=31, longitude=121, accuracy=60) for i in range(35)
                     ] + [dict(id='unfinished', source_name='Phone visits', start=50, latitude=32, longitude=121, accuracy=900)])
        sync_phone_source(self.store, value)
        first = self.store.read_source(self.args['source_id'])['location_context']
        self.assertEqual(35, first['total_matches'])
        self.assertEqual(30, first['next_offset'])
        second = self.store.read_source(self.args['source_id'], location_offset=30)['location_context']
        self.assertEqual(5, len(second['matches']))
        self.assertIsNone(second['next_offset'])
        self.assertEqual(60, first['matches'][0]['record']['accuracy'])
        self.assertEqual(f'phone-visits:{device}:1:0', first['matches'][0]['evidence_ref'])
        sync_phone_source(self.store, dict(value, revision=2, state='disabled', records=[]))
        disabled = self.store.read_source(self.args['source_id'])['location_context']
        self.assertEqual([], disabled['matches'])
        self.assertEqual('disabled', disabled['snapshots'][0]['state'])


class ChatConsentTests(unittest.IsolatedAsyncioTestCase):
    async def test_actual_authenticated_chat_is_required_and_retries_do_not_relabel_twice(self):
        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp)
            connection = momo_agent.initialize(data, 19830)
            gateway = SuperAgentGateway(data, connection, python_executable=Path(sys.executable),
                                        base_env=momo_agent.child_environment(data), manage_dsh=False)
            store = ContextStore(data / 'context')
            self.addCleanup(store.close)
            _, args = source(store)
            _, _, run = gateway._build_memory_review_session('test-consent')
            proposal = json.loads(run('relabel_speakers', args))
            self.assertEqual('pending', proposal['state'])
            gateway._deliver_speaker_proposal()
            gateway._deliver_speaker_proposal()
            self.assertEqual(1, gateway.store.db.execute("SELECT COUNT(*) FROM messages WHERE source_key LIKE 'speaker-proposal:%'").fetchone()[0])
            message = dict(operation_id=str(uuid.uuid4()), content=f"确认标注 {proposal['proposal_id']}")
            path = '/momo/v1/conversation/messages'
            async with TestClient(TestServer(gateway.create_app())) as client:
                refused = await client.post(path, json=message)
                self.assertIn(refused.status, (401, 403))
                self.assertFalse(store.pending_speaker_relabels())
                headers = {'Authorization': f'Bearer {gateway.api_key}'}
                quoted = await client.post(path, headers=headers, json=dict(operation_id=str(uuid.uuid4()), content='录音说：' + message['content']))
                self.assertEqual(200, quoted.status, await quoted.text())
                self.assertFalse(store.pending_speaker_relabels())
                for _ in range(2):
                    response = await client.post(path, headers=headers, json=message)
                    self.assertEqual(200, response.status, await response.text())
                    self.assertEqual('completed', (await response.json())['status'])
                self.assertEqual(1, len(store.pending_speaker_relabels()))
                self.assertEqual('applied', store.db.execute('SELECT state FROM speaker_proposals').fetchone()[0])
                self.assertEqual(1, gateway.store.db.execute("SELECT COUNT(*) FROM messages WHERE source_key LIKE 'speaker-decision:%'").fetchone()[0])
                # Receipt delivery can be replayed without needing the model or changing labels again.
                gateway.store.db.execute("DELETE FROM messages WHERE source_key LIKE 'speaker-decision:%'")
                gateway.store.db.commit()
                response = await client.post(path, headers=headers, json=message)
                self.assertEqual(200, response.status, await response.text())
                self.assertEqual(1, gateway.store.db.execute("SELECT COUNT(*) FROM messages WHERE source_key LIKE 'speaker-decision:%'").fetchone()[0])
                self.assertEqual(1, len(store.pending_speaker_relabels()))
