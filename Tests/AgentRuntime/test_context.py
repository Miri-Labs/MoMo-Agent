"""Source/memory boundaries independent of model output quality."""
import copy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Apps/MacApp/Context'))
from context_store import ContextStore, Conflict, digest


class ContextTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.store = ContextStore(self.temporary.name)
        self.payload = dict(library_id=str(uuid.uuid4()), session_id=str(uuid.uuid4()), device_id=str(uuid.uuid4()),
                            generation=0, version=1, deleted=False, recorded_at=1000,
                            spans=[dict(id=str(uuid.uuid4()), text='下周五给小林发方案。火锅还没有定。', recorded_at=1000)])
        self.payload['text_sha256'] = digest(self.payload['spans'][0]['text'])
        self.receipt = self.store.sync_source(self.payload)
    def tearDown(self):
        self.store.close(); self.temporary.cleanup()
    def organize(self):
        return self.store.organize(self.receipt['source_id'], self.receipt['source_revision'], '下周五交方案，聚餐未定。',
                [dict(text='下周五给小林发方案', quote='下周五给小林发方案。', kind='commitment', basis='reported')],
                [dict(text='准备发给小林的方案', quote='下周五给小林发方案。')])
    def test_receipt_retry_is_idempotent_after_restart(self):
        self.store.close(); self.store = ContextStore(self.temporary.name)
        self.assertEqual(self.receipt, self.store.sync_source(self.payload))
        self.assertEqual(1, self.store.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0])
        changed = copy.deepcopy(self.payload); changed['spans'][0]['recorded_at'] = 999
        with self.assertRaises(Conflict): self.store.sync_source(changed)
    def test_full_pagination_never_silently_truncates(self):
        offset=0; pieces=[]
        while True:
            page=self.store.read_source(self.receipt['source_id'], self.receipt['source_revision'], offset, 5)
            pieces.append(page['text'])
            self.assertEqual(page['end'] < page['total_characters'], page['truncated'])
            if page['next_offset'] is None: break
            offset=page['next_offset']
        self.assertEqual(self.payload['spans'][0]['text'], ''.join(pieces))
    def test_wrong_checksum_or_owner_is_rejected(self):
        bad=copy.deepcopy(self.payload); bad['text_sha256']='0'*64
        with self.assertRaises(ValueError): self.store.sync_source(bad)
        bad=copy.deepcopy(self.payload); bad['device_id']=str(uuid.uuid4())
        with self.assertRaises(Conflict): self.store.sync_source(bad)
    def test_correction_invalidates_old_memory_and_old_writes(self):
        self.organize(); changed=copy.deepcopy(self.payload); changed['version']=2
        changed['spans'][0]['text']='改为下周三给小林发方案。'; changed['text_sha256']=digest(changed['spans'][0]['text'])
        self.store.sync_source(changed)
        self.assertEqual('stale', self.store.memories()['items'][0]['status'])
        with self.assertRaises(Conflict): self.organize()
        with self.assertRaises(Conflict): self.store.read_source(self.receipt['source_id'], self.receipt['source_revision'])
    def test_deletion_removes_source_evidence_and_cannot_resurrect(self):
        self.organize(); tombstone=copy.deepcopy(self.payload)
        tombstone.update(generation=1, version=0, deleted=True, spans=[], text_sha256=digest(''))
        self.store.sync_source(tombstone)
        self.assertEqual([], self.store.list_sources()['items'])
        self.assertEqual('stale', self.store.memories()['items'][0]['status'])
        with self.assertRaises(Conflict): self.store.sync_source(self.payload)
        with self.assertRaises(Conflict): self.store.read_source(self.receipt['source_id'])
    def test_evidence_is_required_and_actions_are_not_executed(self):
        with self.assertRaises(ValueError):
            self.store.organize(self.receipt['source_id'], self.receipt['source_revision'], 'bad',
                [dict(text='已经决定吃火锅', quote='决定吃火锅', kind='preference', basis='reported')], [])
        self.assertEqual([], self.store.memories()['items'])
        self.assertEqual('proposed_only', self.organize()['action_status'])
        self.assertFalse((Path(self.temporary.name)/'results').exists())
    def test_forget_receipt_retry_does_not_resurrect_fact(self):
        self.organize(); memory=self.store.memories()['items'][0]; op=str(uuid.uuid4())
        receipt=self.store.forget(memory['id'],op,memory['revision'])
        self.assertEqual(receipt,self.store.forget(memory['id'],op,memory['revision']))
        self.assertIsNone(self.store.list_sources()['items'][0]['summary'])
        with self.assertRaises(Conflict): self.organize()
        item=self.store.memories()['items'][0]
        self.assertEqual('forgotten', item['status']); self.assertEqual('',item['text'])
    def test_snapshot_pagination_detects_concurrent_change(self):
        self.organize(); revision=self.store.memories()['revision']; self.organize()
        with self.assertRaises(Conflict): self.store.memories(expected_revision=revision)
    def test_artifact_is_real_and_requires_current_source(self):
        value=self.store.write_result(self.receipt['source_id'],self.receipt['source_revision'],'给小林的方案','需要在周五发出。')
        self.assertTrue(Path(value['path']).is_file())
        self.assertEqual(value['sha256'],digest(Path(value['path']).read_text()))

    def test_multi_window_source_splits_by_gap_and_attaches_recording_summary(self):
        import recording_summary
        spans = [
            dict(id=str(uuid.uuid4()), text='第一段讨论晚上发布安排与回归测试验证计划。', recorded_at=1000),
            dict(id=str(uuid.uuid4()), text='补充确认了监控告警阈值。', recorded_at=1120),
            dict(id=str(uuid.uuid4()), text='第二天上午讨论客户反馈与移动端同步体验优化。', recorded_at=90_000),
        ]
        payload = copy.deepcopy(self.payload)
        payload.update(version=2, spans=spans, text_sha256=digest('\n'.join(s['text'] for s in spans)))
        receipt = self.store.sync_source(payload)
        items = self.store.list_sources(summarize=True)['items']
        self.assertEqual(1, len(items))
        windows = items[0]['windows']
        self.assertEqual(2, len(windows))
        self.assertEqual(1000, windows[0]['recorded_at'])
        self.assertEqual(1120, windows[0]['end_at'])
        self.assertEqual(90_000, windows[1]['recorded_at'])
        job = recording_summary.next_job(self.store)
        self.assertIsNotNone(job)
        recording_summary.accept_result(self.store, job, '总结：确认晚上发布安排与告警阈值。')
        refreshed = self.store.list_sources()['items'][0]['windows']
        self.assertEqual('总结：确认晚上发布安排与告警阈值。', refreshed[0]['summary'])
        page = self.store.read_source(receipt['source_id'], receipt['source_revision'], refreshed[0]['offset'], refreshed[0]['end'] - refreshed[0]['offset'])
        self.assertEqual([spans[0]['text'], spans[1]['text']], [s['text'] for s in page['spans']])

if __name__=='__main__': unittest.main()
