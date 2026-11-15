"""Retrieval quality, source freshness and production tool integration."""
import asyncio
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / 'Apps/MacApp/Context'), str(ROOT / 'Apps/MacApp/Runtime')]
from context_store import ContextStore, Conflict, canonical, digest
from memory_search import MemorySearch
from momo_memory import MoMoMemory


class MemorySearchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.data = Path(self.temp.name)
        (self.data / 'runtime').mkdir()
        self.memory = MoMoMemory(self.data)
        self.search = MemorySearch(self.data)
        self.context = ContextStore(self.data / 'context')
        self.addCleanup(self.context.close)
        self.chat = sqlite3.connect(self.data / 'runtime/conversation.sqlite')
        self.addCleanup(self.chat.close)
        self.chat.executescript('''CREATE TABLE messages(seq INTEGER PRIMARY KEY,role TEXT,content TEXT,created_at REAL,
                                  operation_id TEXT,source_key TEXT);
                                  CREATE TABLE inputs(operation_id TEXT,intent TEXT,delivery_state TEXT);''')

    def note(self, path, text):
        self.assertTrue(self.memory.write_notebook(path=path, content=text)['success'])

    def message(self, seq, text, role='user', operation=None, source=None):
        self.chat.execute('INSERT INTO messages VALUES(?,?,?,?,?,?)', (seq, role, text, seq, operation, source))
        self.chat.commit()

    def recording(self, text):
        span_id = str(uuid.uuid4())
        source = dict(library_id=str(uuid.uuid4()), session_id=str(uuid.uuid4()), device_id=str(uuid.uuid4()),
                      generation=0, version=1, deleted=False, recorded_at=100,
                      spans=[dict(id=span_id, text=text, recorded_at=100)], text_sha256=digest(text))
        receipt = self.context.sync_source(source)
        return receipt['source_id'], span_id, source

    def test_chinese_noncontiguous_words_rank_before_newer_partial_matches(self):
        self.note('projects/release.md', '# 访谈发布\n连接池耗尽导致高并发请求排队，周五扩大容量。')
        self.note('projects/unrelated.md', '# 本周活动\n周五下午去公园。')
        hits = self.search.search('周五 连接池', kind='note')['matches']
        self.assertEqual('projects/release.md', hits[0]['path'])
        self.assertIn('高并发', hits[0]['text'])

    def test_all_notes_and_late_passages_are_retrievable_and_readable(self):
        for i in range(90):
            self.note(f'zz-noise/{i}.md', '# Other project\nUnrelated garden notes.')
        text = '# 历史项目\n' + ('前面的背景段落。\n' * 1000) + '发布暗号为 cobalt42，负责人是小林。'
        self.note('aa/deep/old.md', text)
        hit = self.search.search('cobalt42')['matches'][0]
        self.assertEqual('aa/deep/old.md', hit['path'])
        self.assertIn('cobalt42', hit['text'])
        self.assertGreater(hit['offset'], 1200)
        self.assertTrue(hit['truncated'])
        chunks, offset = [], 0
        while offset is not None:
            page = self.search.read(hit['id'], hit['revision'], offset, 777)
            chunks.append(page['text'])
            offset = page['next_offset']
        self.assertEqual(text + '\n', ''.join(chunks))

    def test_query_variants_preserve_different_facets_and_deduplicate_hits(self):
        self.note('projects/performance.md', '# 容量\n高并发时连接池耗尽，已提高连接上限。')
        self.note('projects/contract.md', '# 合同\n客户要求 SLA 99.5%，负责人为小林。')
        for i in range(8):
            self.note(f'noise/{i}.md', '# 容量\n连接池扩容的背景资料。')
        result = self.search.search('上线扛不住和客户的保障条款', ['高并发 连接池', 'SLA 99.5'], limit=4)
        paths = [m['path'] for m in result['matches']]
        self.assertIn('projects/performance.md', paths)
        self.assertIn('projects/contract.md', paths)
        self.assertEqual(len(paths), len(set(paths)))
        self.assertEqual('bm25_multi_query_rrf', result['method'])

    def test_long_document_does_not_crowd_other_sources_out_of_candidate_pool(self):
        path = self.memory.memories_dir / 'long.md'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('# Notes\n' + 'Connections need tuning. ' * 15000)
        self.note('projects/small.md', '# Database\nWe tuned a connection yesterday.')
        hits = self.search.search('connections', kind='note', limit=2)['matches']
        self.assertEqual({'long.md', 'projects/small.md'}, {hit['path'] for hit in hits})

    def test_external_edits_moves_deletion_and_rebuild_remove_stale_hits(self):
        self.note('people/a.md', '# Alice\n喜欢抹茶。')
        old = self.search.search('抹茶')['matches'][0]
        path = self.memory.memories_dir / 'people/a.md'
        path.write_text('# Alice\n喜欢咖啡。')
        self.assertEqual([], self.search.search('抹茶')['matches'])
        with self.assertRaises(Conflict):
            self.search.read(old['id'], old['revision'])
        self.memory.move_notebook(path='people/a.md', to_path='people/team/a.md')
        hit = self.search.search('咖啡')['matches'][0]
        self.assertEqual('people/team/a.md', hit['path'])
        self.search.path.unlink()
        self.assertEqual(hit['revision'], self.search.search('咖啡')['matches'][0]['revision'])
        self.memory.remove_notebook(path='people/team/a.md', user_initiated=True)
        self.assertEqual([], self.search.search('咖啡')['matches'])
        with self.assertRaises(Conflict):
            self.search.read(hit['id'], hit['revision'])

    def test_recording_corrections_and_source_deletion_invalidate_evidence(self):
        source_id, span_id, source = self.recording('[佳辰] 本周扩大连接池。')
        old = self.search.search('佳辰', kind='recording')['matches'][0]
        self.context._relabel_speakers(source_id, '小林', span_ids=[span_id], scope='selection', is_owner=False)
        self.assertEqual([], self.search.search('佳辰', kind='recording')['matches'])
        hit = self.search.search('小林', kind='recording')['matches'][0]
        self.assertEqual('小林', hit['speaker'])
        self.assertFalse(hit['is_owner'])
        with self.assertRaises(Conflict):
            self.search.read(old['id'], old['revision'])
        self.context.exclude_speaker('小林', source_id=source_id, span_ids=[span_id])
        self.assertEqual([], self.search.search('小林', kind='recording')['matches'])
        self.assertEqual([], self.search.search('佳辰', kind='recording')['matches'])
        self.assertIsNone(self.search.search('连接池')['matches'][0]['speaker'])
        self.context.sync_source({**source, 'version': 2, 'deleted': True, 'spans': [], 'text_sha256': digest('')})
        self.assertEqual([], self.search.search('连接池')['matches'])

    def test_phone_owner_enrichment_at_same_source_revision_invalidates_cached_evidence(self):
        with patch('context_store.time.time', return_value=1000):
            source_id, _, source = self.recording('连接池扩容。')
            old = self.search.search('连接池')['matches'][0]
            self.assertIsNone(old['is_owner'])
            for owner in (True, False):
                enriched = {**source, 'spans': [{**span, 'is_owner': owner} for span in source['spans']]}
                receipt = self.context.sync_source(enriched)
                self.assertEqual(old['source_revision'], receipt['source_revision'])
                hit = self.search.search('连接池')['matches'][0]
                self.assertIs(hit['is_owner'], owner)
                with self.assertRaises(Conflict):
                    self.search.read(old['id'], old['revision'])
                old = hit

    def test_late_recording_passage_retains_full_span_speaker_attribution(self):
        from superagent_gateway import search_recording_evidence
        self.recording('[我] ' + '背景材料。' * 600 + '最终确认的暗号 cobalt42。')
        hit = search_recording_evidence(self.data, {'query': 'cobalt42'})['matches'][0]
        self.assertGreater(hit['offset'], 0)
        self.assertEqual('我', hit['speaker'])
        self.assertEqual('owner', hit['speaker_role'])
        self.assertIs(hit['is_owner'], True)
        raw = self.search.search('cobalt42')['matches'][0]
        self.assertEqual('我', raw['speaker'])
        self.assertIs(raw['is_owner'], True)

    def test_excluded_speaker_without_space_is_not_reinferred_from_body(self):
        from superagent_gateway import search_recording_evidence
        source_id, span_id, _ = self.recording('[小林][财务] 连接池成本讨论。')
        self.context.exclude_speaker('小林', source_id=source_id, span_ids=[span_id])
        self.assertEqual([], self.search.search('小林')['matches'])
        hit = search_recording_evidence(self.data, {'query': '连接池'})['matches'][0]
        self.assertIsNone(hit['speaker'])
        self.assertEqual('unattributed', hit['speaker_role'])

    def test_legacy_cli_search_retains_fifty_results_title_and_span_sequence(self):
        _, _, source = self.recording('兼容检索测试。')
        spans = [dict(id=str(uuid.uuid4()), text='兼容检索测试。', recorded_at=100 + i) for i in range(60)]
        receipt = self.context.sync_source({**source, 'version': 2, 'title': '录音兼容验收', 'spans': spans,
                                            'text_sha256': digest('\n'.join(s['text'] for s in spans))})
        command = [sys.executable, str(ROOT / 'Apps/MacApp/Runtime/momo_cli.py'), '--data-dir', str(self.data),
                   'search', '兼容检索', '--limit']
        for requested, expected in ((50, 50), (100, 50), (0, 1)):
            result = subprocess.run([*command, str(requested)], text=True, capture_output=True, check=True,
                                    env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
            response = json.loads(result.stdout)
            hits = response['matches']
            self.assertTrue(response['has_more'])
            self.assertEqual(expected, len(hits))
            for hit in hits:
                self.assertEqual('录音兼容验收', hit['title'])
                self.assertEqual(spans[hit['seq']]['id'], hit['span_id'])
                self.assertEqual(receipt['source_revision'], hit['revision'])
                self.assertEqual(hit['evidence_revision'], hit['read']['arguments']['revision'])

    def test_index_from_initial_release_refreshes_recording_metadata(self):
        source_id, _, _ = self.recording('[我] 连接池扩容。')
        hit = self.search.search('连接池')['matches'][0]
        legacy_signature = digest(canonical([hit['source_revision'], [], [], []]))
        with sqlite3.connect(self.search.path) as db:
            db.execute('UPDATE groups SET signature=? WHERE id=?', (legacy_signature, 'recording:' + source_id))
            db.execute('UPDATE documents SET metadata=?,revision=? WHERE id=?',
                       (canonical({'speaker': None, 'is_owner': None}), 'legacy-evidence', hit['id']))
        restored = self.search.search('连接池')['matches'][0]
        self.assertEqual('我', restored['speaker'])
        self.assertIs(restored['is_owner'], True)
        self.assertEqual(0, restored['seq'])
        self.assertEqual(source_id, restored['title'])
        with self.assertRaises(Conflict):
            self.search.read(hit['id'], 'legacy-evidence')

    def test_chat_eligibility_attribution_long_content_and_later_steer_application(self):
        self.message(1, '我喜欢雨天散步。')
        self.message(2, '可能喜欢雨天散步。', role='assistant')
        self.message(3, '隐藏暗号秘密。', operation='steer')
        self.chat.execute("INSERT INTO inputs VALUES('steer','steer','not_applied')")
        self.chat.commit()
        self.message(4, '隐藏暗号秘密。', role='assistant', source='dream-briefing:abc')
        self.assertEqual([], self.search.search('隐藏暗号')['matches'])
        hits = self.search.search('雨天', kind='chat')['matches']
        self.assertEqual({'user_statement', 'assistant_statement'}, {m['basis'] for m in hits})
        self.chat.execute("UPDATE inputs SET delivery_state='applied'")
        self.chat.commit()
        self.assertEqual(['chat:3'], [m['id'] for m in self.search.search('隐藏暗号')['matches']])
        self.message(5, '初始背景。' * 500 + '金丝雀部署的后续约定在这里。')
        hit = self.search.search('金丝雀 部署', kind='chat')['matches'][0]
        self.assertIn('金丝雀', hit['text'])
        self.assertGreater(hit['offset'], 1200)

    def test_chat_edit_and_delete_invalidate_previously_read_evidence(self):
        self.message(1, '出差去巴黎。')
        old = self.search.search('巴黎', kind='chat')['matches'][0]
        self.chat.execute("UPDATE messages SET content='出差改去东京。' WHERE seq=1")
        self.chat.commit()
        self.assertEqual([], self.search.search('巴黎', kind='chat')['matches'])
        updated = self.search.search('东京', kind='chat')['matches'][0]
        with self.assertRaises(Conflict):
            self.search.read(old['id'], old['revision'])
        self.chat.execute('DELETE FROM messages WHERE seq=1')
        self.chat.commit()
        self.assertEqual([], self.search.search('东京', kind='chat')['matches'])
        with self.assertRaises(Conflict):
            self.search.read(updated['id'], updated['revision'])

    def test_literals_validation_and_no_symlink_escape(self):
        self.note('people/a.md', '# Alice\n版本发布')
        for query in ('% _', '☃', '" OR * NEAR('):
            self.assertEqual([], self.search.search(query)['matches'])
        for kwargs in ({'query': ''}, {'query': 'x', 'limit': True}, {'query': 'x', 'alternative_queries': 'y'},
                       {'query': 'x', 'kind': 'private'}, {'query': 'x', 'alternative_queries': ['x'] * 4}):
            with self.assertRaises(ValueError):
                self.search.search(**kwargs)
        outside = self.data / 'outside.md'
        outside.write_text('Do not index externalcanary')
        (self.memory.memories_dir / 'escape.md').symlink_to(outside)
        self.assertEqual([], self.search.search('externalcanary')['matches'])

    def test_parallel_searches_and_incremental_refresh(self):
        self.note('projects/one.md', '# 并发测试\n并发查询保留同一份原始资料。')
        self.search.search('并发')
        with sqlite3.connect(self.search.path) as db:
            before = db.execute('SELECT rowid,* FROM passages').fetchall()
        with ThreadPoolExecutor(max_workers=6) as pool:
            hits = list(pool.map(lambda _: MemorySearch(self.data).search('并发')['matches'][0], range(12)))
        self.assertEqual(1, len({h['revision'] for h in hits}))
        with sqlite3.connect(self.search.path) as db:
            self.assertEqual(before, db.execute('SELECT rowid,* FROM passages').fetchall())

    def test_search_during_notebook_moves_preserves_one_current_source(self):
        self.note('projects/a.md', '# 并发\n连接池扩容。')

        def move():
            for i in range(100):
                a, b = ('a', 'b') if i % 2 == 0 else ('b', 'a')
                self.memory.move_notebook(path=f'projects/{a}.md', to_path=f'projects/{b}.md')

        with ThreadPoolExecutor(max_workers=2) as pool:
            writer = pool.submit(move)
            for _ in range(30):
                hits = self.search.search('连接池')['matches']
                self.assertEqual(1, len(hits))
                self.assertIn(hits[0]['path'], ('projects/a.md', 'projects/b.md'))
            writer.result()

    def test_external_deletion_between_stat_and_read_drops_cached_evidence(self):
        from memory_search import _stamp
        self.note('projects/a.md', '# 连接池\n旧内容。')
        old = self.search.search('连接池')['matches'][0]
        path = self.memory.memories_dir / 'projects/a.md'
        path.write_text('# 连接池\n新内容。')

        def remove_after_stat(candidate):
            signature = _stamp(candidate)
            if candidate == path:
                path.unlink()
            return signature

        with patch('memory_search._stamp', side_effect=remove_after_stat):
            self.assertEqual([], self.search.search('连接池')['matches'])
        with self.assertRaises(Conflict):
            self.search.read(old['id'], old['revision'])

    def test_dream_worker_and_cli_use_same_search_and_revision_contract(self):
        from superagent_gateway import SuperAgentGateway
        gateway = SuperAgentGateway.__new__(SuperAgentGateway)
        gateway.data, gateway.dsh_ready, gateway.bridge_secret = self.data, False, 'test-secret'
        self.note('projects/release.md', '# 发布\n连接池扩容已完成。')
        _, specs, tool = gateway._build_memory_review_session('momo-review-search')
        self.assertIn('search_memory', {s['name'] for s in specs})
        expected = json.loads(tool('search_memory', {'query': '连接池'}))
        self.assertIn('error', json.loads(tool('search_memory', {'query': '连接池', 'arbitrary': True})))
        self.assertIn('error', json.loads(tool('read_memory_evidence', {'id': 'note:projects/release.md'})))

        class Request:
            headers = {'X-MoMo-Bridge': 'test-secret'}
            async def read(self):
                return json.dumps({'op': 'search_memory', 'args': {'query': '连接池'}}).encode()

        response = asyncio.run(gateway.handle_internal_pim(Request()))
        self.assertEqual(200, response.status)
        self.assertEqual(expected, {k: v for k, v in json.loads(response.text).items() if k != 'ok'})
        result = subprocess.run([sys.executable, str(ROOT / 'Apps/MacApp/Runtime/momo_cli.py'),
                                 '--data-dir', str(self.data), 'search-memory', '连接池'],
                                text=True, capture_output=True, check=True, env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
        self.assertEqual(expected, json.loads(result.stdout))
        hit = expected['matches'][0]
        evidence = json.loads(tool('read_memory_evidence', {'id': hit['id'], 'revision': hit['revision']}))
        self.assertIn('扩容已完成', evidence['text'])
        self.note('projects/release.md', '# 发布\n扩容已回滚。')
        self.assertIn('error', json.loads(tool('read_memory_evidence', {'id': hit['id'], 'revision': hit['revision']})))


if __name__ == '__main__':
    unittest.main()
