"""Source/memory boundaries independent of model output quality."""
import copy
from contextlib import contextmanager
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
import uuid


@contextmanager
def local_timezone(name):
    from unittest.mock import patch
    try:
        with patch.dict(os.environ, {'TZ': name}):
            time.tzset()
            yield
    finally:
        time.tzset()

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
    def test_speaker_exclusions_survive_upload_restart_and_ack(self):
        source = self.receipt['source_id']
        spans = [dict(id=str(uuid.uuid4()), speaker='Alex', text='[Alex] hi', recorded_at=t) for t in (999, 1000, 1001)]
        payload = dict(self.payload, version=2, spans=spans, text_sha256=digest('\n'.join(sp['text'] for sp in spans)))
        self.store.sync_source(payload)
        command = self.store.exclude_speaker('Alex', recorded_from='1970-01-01T00:16:40+00:00')
        self.assertEqual(command, self.store.exclude_speaker('Alex', recorded_from='1970-01-01T01:16:40+01:00'))
        self.assertEqual(self.store.read_source(source)['text'], '[Alex] hi\nhi\nhi')
        self.assertEqual(len(self.store.pending_speaker_exclusions()), 1)
        self.assertEqual(self.store.ack_speaker_relabels([command['exclusion_id']])['acknowledged'], 1)
        self.store.close()
        self.store = ContextStore(self.temporary.name)
        self.store.sync_source(dict(payload, version=3))
        self.assertEqual(self.store.pending_speaker_exclusions(), [])
        self.assertNotIn('speaker', self.store.read_source(source)['spans'][1])
        with self.assertRaises(ValueError):
            self.store.exclude_speaker('Alex', recorded_from='1970-01-01T00:16:40')
        with self.assertRaises(ValueError):
            self.store.exclude_speaker('Alex', source_id=source, span_ids=[str(uuid.uuid4())])
        self.store.exclude_speaker('Alex', source_id=source, span_ids=[spans[0]['id']])
        self.assertEqual(self.store.read_source(source)['text'], 'hi\nhi\nhi')

    def test_receipt_retry_is_idempotent_after_restart(self):
        self.store.close(); self.store = ContextStore(self.temporary.name)
        self.assertEqual(self.receipt, self.store.sync_source(self.payload))
        self.assertEqual(1, self.store.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0])
        # Out-of-order earlier Watch chunk arrival shifting session-level recorded_at or sub-ms end_at float rounding at same revision succeeds.
        earlier_session_start = copy.deepcopy(self.payload)
        span_ts = earlier_session_start['spans'][0]['recorded_at']
        earlier_session_start['recorded_at'] = span_ts - 50
        earlier_session_start['spans'][0]['end_at'] = span_ts + 4.123456
        self.assertEqual(self.receipt['source_revision'], self.store.sync_source(earlier_session_start)['source_revision'])
        float_drift = copy.deepcopy(earlier_session_start)
        float_drift['spans'][0]['end_at'] = span_ts + 4.1234564
        self.assertEqual(self.receipt['source_revision'], self.store.sync_source(float_drift)['source_revision'])
        saved_doc = json.loads(self.store.db.execute('SELECT payload FROM sources WHERE id=?', (self.receipt['source_id'],)).fetchone()[0])
        self.assertEqual(float(span_ts - 50), saved_doc['recorded_at'])
        # Mutating an actual span's recorded_at at the same revision still raises Conflict.
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

    def test_natural_dates_and_reading_boundary_are_independent(self):
        import datetime as dt, json
        zone = dt.timezone(dt.timedelta(hours=8))
        times = [dt.datetime(2026, 11, day, hour, minute, tzinfo=zone).timestamp()
                 for day, hour, minute in [(15, 23, 59), (16, 0, 1), (16, 7, 59), (16, 8, 0)]]
        spans = [dict(id=str(uuid.uuid4()), text=f'这是第 {i} 段，边界内容不能丢失。', recorded_at=at,
                      timezone_offset=28800) for i, at in enumerate(times)]
        payload = copy.deepcopy(self.payload)
        payload.update(version=3, spans=spans, text_sha256=digest('\n'.join(s['text'] for s in spans)))
        self.store.sync_source(payload)
        windows = self.store.list_sources()['items'][0]['windows']
        self.assertEqual(['2026-11-15', '2026-11-16', '2026-11-16', '2026-11-16'], [w['natural_day'] for w in windows])
        self.assertEqual(times, [w['recorded_at'] for w in windows])
        legacy = Path(self.temporary.name) / 'runtime/day-boundary.json'
        legacy.parent.mkdir(exist_ok=True)
        legacy.write_text('{"day_start_hour": 23}')
        self.assertEqual(windows, self.store.list_sources()['items'][0]['windows'])
        (legacy.parent / 'transcript-reading.json').write_text('{"early_transcript_hour": 0}')
        unfolded = self.store.list_sources()['items'][0]['windows']
        self.assertEqual(3, len(unfolded))
        self.assertEqual(times[-1], unfolded[-1]['end_at'])
        self.assertEqual('{"day_start_hour": 23}', legacy.read_text())

    def test_clock_evidence_enriches_same_revision_and_survives_old_clients(self):
        self.store.list_sources()  # Warm the old, unzoned projection first.
        payload = copy.deepcopy(self.payload)
        payload['spans'][0].update(timezone_offset=-18000, end_at=payload['spans'][0]['recorded_at'] + 30)
        self.store.sync_source(payload)
        projected = self.store.list_sources()['items'][0]['windows'][0]
        self.assertEqual(-18000, projected['timezone_offset'])
        detail = self.store.read_source(projected['source_id'])
        self.assertEqual(-18000, detail['spans'][0]['timezone_offset'])
        self.assertEqual(payload['spans'][0]['end_at'], detail['spans'][0]['end_at'])
        # An old client may omit enrichment; it must not erase evidence or reject identical text.
        self.store.sync_source(copy.deepcopy(self.payload))
        self.assertEqual(-18000, self.store.list_sources()['items'][0]['windows'][0]['timezone_offset'])
        payload['spans'][0]['timezone_offset'] = 28800
        with self.assertRaises(Conflict): self.store.sync_source(payload)

    def test_warm_cache_clock_enrichment_matches_read_and_both_window_builders(self):
        import datetime as dt
        from unittest.mock import patch
        for version, (hour, minute, second, days) in enumerate([(17, 0, 0, ['2026-11-16']),
                (15, 59, 59, ['2026-11-15', '2026-11-16'])], start=2):
            with self.subTest(clock=(hour, minute, second)):
                payload = copy.deepcopy(self.payload)
                payload['version'] = version
                at = dt.datetime(2026, 11, 15, hour, minute, second, tzinfo=dt.timezone.utc).timestamp()
                payload['spans'][0]['recorded_at'] = at
                if minute == 59:
                    payload['spans'].append(dict(id=str(uuid.uuid4()), recorded_at=at + 2, text='午夜后的下一句话'))
                    payload['text_sha256'] = digest('\n'.join(s['text'] for s in payload['spans']))
                receipt = self.store.sync_source(payload)
                old = self.store.list_sources()['items'][0]['windows']
                self.assertEqual(dt.datetime.fromtimestamp(at).date().isoformat(), old[0]['natural_day'])
                self.assertEqual('local_timezone', old[0]['date_evidence'])
                for span in payload['spans']:
                    span.update(timezone_offset=28800, end_at=span['recorded_at'] + 2)
                # Wall-clock rollback must not make the old cache entry valid.
                with patch('context_store.time.time', return_value=1):
                    enriched = self.store.sync_source(payload)
                self.assertEqual(receipt['source_revision'], enriched['source_revision'])
                self.assertNotEqual(receipt['revision'], enriched['revision'])
                reopened = ContextStore(self.temporary.name)
                try:
                    listed = reopened.list_sources()['items'][0]['windows']
                    detail = reopened.read_source(receipt['source_id'], receipt['source_revision'])
                    built = reopened.build_windows(receipt['source_id'], receipt['source_revision'],
                                                   payload, False, {}, {}, set())
                finally:
                    reopened.close()
                self.assertEqual(days, [w['natural_day'] for w in listed])
                self.assertEqual(listed, built)
                self.assertEqual(28800, detail['spans'][0]['timezone_offset'])
                self.assertEqual(at + 2, detail['spans'][0]['end_at'])
                self.assertEqual(listed, self.store.list_sources()['items'][0]['windows'])

    def test_desktop_reading_preference_is_read_from_runtime_beside_context(self):
        from context_store import read_early_transcript_hour
        root = Path(self.temporary.name)
        (root / 'runtime').mkdir(exist_ok=True)
        (root / 'runtime/transcript-reading.json').write_text('{"early_transcript_hour": 0}')
        self.assertEqual(0, read_early_transcript_hour(root / 'context'))

    def test_source_crossing_midnight_preserves_full_interval_without_repeating_text(self):
        import datetime as dt
        from context_store import natural_groups
        start = dt.datetime(2026, 11, 16, 23, 59, 59, tzinfo=dt.timezone.utc).timestamp()
        span = dict(id=str(uuid.uuid4()), text='跨午夜仍是同一句话', recorded_at=start, end_at=start + 2, timezone_offset=0)
        groups = natural_groups([span], 8)
        self.assertEqual(['2026-11-16'], [g['natural_day'] for g in groups])
        self.assertEqual([span['text']], [text for g in groups for text in g['texts']])
        self.assertEqual(start + 2, groups[0]['end_at'])
        self.assertEqual(0, groups[0]['offset'])
        self.assertEqual(len(span['text']), groups[0]['end'])

    def test_one_conversation_across_eight_is_not_folded_as_one_early_window(self):
        import datetime as dt
        from context_store import natural_groups
        start = dt.datetime(2026, 11, 16, 7, 59, tzinfo=dt.timezone.utc).timestamp()
        spans = [dict(id=str(uuid.uuid4()), text=text, recorded_at=start + offset, timezone_offset=0)
                 for text, offset in [('七点五十九的原文', 0), ('八点零一的原文', 120)]]
        folded = natural_groups(spans, 8)
        self.assertEqual([True, False], [g['key'][2] for g in folded])
        self.assertEqual([0, len(spans[0]['text']) + 1], [g['offset'] for g in folded])
        self.assertEqual(1, len(natural_groups(spans, 0)))

    def test_recorded_offsets_cover_dst_and_missing_evidence_is_explicit(self):
        from context_store import natural_groups, source_clock
        import datetime as dt
        spans = [dict(id=str(uuid.uuid4()), text='夏令时回拨两次一点半', recorded_at=1793511000 + i * 3600,
                      timezone_offset=offset) for i, offset in enumerate([-14400, -18000])]
        groups = natural_groups(spans, 8)
        self.assertEqual([-14400, -18000], [g['timezone_offset'] for g in groups])
        self.assertEqual(groups[0]['natural_day'], groups[1]['natural_day'])
        self.assertEqual(['01:30', '01:30'], [dt.datetime.fromtimestamp(sp['recorded_at'], source_clock(sp)[0]).strftime('%H:%M') for sp in spans])
        del spans[0]['timezone_offset']
        self.assertEqual('local_timezone', natural_groups(spans[:1], 8)[0]['date_evidence'])

    def test_legacy_local_projection_updates_warm_cache_without_changing_source(self):
        import datetime as dt
        payload = copy.deepcopy(self.payload)
        payload['version'] += 1
        start = dt.datetime(2026, 11, 15, 23, 59, tzinfo=dt.timezone(dt.timedelta(hours=8))).timestamp()
        payload['spans'] = [dict(id=str(uuid.uuid4()), recorded_at=start + delta, text=text)
                            for delta, text in [(0, '午夜前的原文'), (120, '午夜后的原文')]]
        payload['text_sha256'] = digest('\n'.join(s['text'] for s in payload['spans']))
        receipt = self.store.sync_source(payload)
        before = self.store.db.execute('SELECT payload FROM sources WHERE id=?', (receipt['source_id'],)).fetchone()[0]
        for zone, days, offsets in [('Asia/Shanghai', ['2026-11-15', '2026-11-16'], [28800, 28800]),
                                   ('America/New_York', ['2026-11-15'], [-18000])]:
            with local_timezone(zone):
                listed = self.store.list_sources()['items'][0]['windows']
                built = self.store.build_windows(receipt['source_id'], receipt['source_revision'], payload, False, {}, {}, set())
                self.assertEqual(listed, built)
                self.assertEqual(days, [w['natural_day'] for w in listed])
                self.assertEqual(offsets, [w['timezone_offset'] for w in listed])
                self.assertTrue(all(w['date_evidence'] == 'local_timezone' for w in listed))
        self.assertEqual(before, self.store.db.execute('SELECT payload FROM sources WHERE id=?', (receipt['source_id'],)).fetchone()[0])

    def test_legacy_local_clock_resolves_dst_at_recording_time(self):
        import datetime as dt
        from context_store import source_clock
        with local_timezone('America/New_York'):
            for month, expected in [(7, -14400), (11, -18000)]:
                span = dict(recorded_at=dt.datetime(2026, month, 15, 12, tzinfo=dt.timezone.utc).timestamp())
                zone, evidence = source_clock(span)
                self.assertEqual(expected, zone.utcoffset(None).total_seconds())
                self.assertEqual('local_timezone', evidence)
                span['timezone_offset'] = 0
                self.assertEqual((dt.timezone.utc, 'recorded_offset'), source_clock(span))

if __name__=='__main__': unittest.main()
