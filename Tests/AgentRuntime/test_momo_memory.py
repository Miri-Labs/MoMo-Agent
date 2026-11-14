"""UI reads and edits the native Hermes store, without a parallel memory engine."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT/'Apps/MacApp/Context'), str(ROOT/'Apps/MacApp/Runtime'), str(ROOT/'Vendor/HermesAgent')]
from context_store import Conflict, ContextStore, digest
from momo_memory import MoMoMemory, memory_home
import memory_review


class MoMoMemoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        (self.home/'config.yaml').write_text(json.dumps({'memory':{'memory_enabled':True,'user_profile_enabled':True}}))
        self.memory = MoMoMemory(self.home)

    def test_native_writes_appear_in_ui_and_ui_delete_updates_native_store(self):
        with self.memory.store() as store:
            self.assertTrue(store.add('memory', '周五给小林发方案。')['success'])
            self.assertTrue(store.add('user', '喜欢清淡的食物。')['success'])
        items = self.memory.list()['items']; item = next(i for i in items if i['kind']=='memory')
        self.assertEqual('momo', item['basis']); self.assertEqual([],item['evidence'])
        self.memory.forget(item['id'].replace('momo-', 'hermes-', 1)); self.memory.forget(item['id'])
        with self.memory.store() as store:
            self.assertEqual([],store.memory_entries); self.assertEqual(['喜欢清淡的食物。'],store.user_entries)

    def test_stale_identity_never_removes_newer_native_entry(self):
        with self.memory.store() as store: store.add('memory','周五交方案。')
        old = self.memory.list()['items'][0]
        with self.memory.store() as store: store.patch('memory','周五','周一')
        self.memory.forget(old['id'])
        self.assertEqual('周一交方案。',self.memory.list()['items'][0]['text'])
        with self.assertRaises(Conflict): self.memory.forget('old-momo-fact-id')

    def test_bounded_native_store_keeps_limits_and_changed_page_is_rejected(self):
        with self.memory.store() as store:
            store.add('memory','第一条。')
            self.assertFalse(store.add('memory','内容'*2000)['success'])
        page = self.memory.list()
        with self.memory.store() as store: store.add('memory','第二条。')
        with self.assertRaises(Conflict): self.memory.list(expected_revision=page['revision'])

    def test_other_home_is_not_read_or_modified(self):
        other = self.home/'other'; other.mkdir()
        with self.memory.store() as store: store.add('user','当前实例的用户。')
        with MoMoMemory(other).store() as store: self.assertEqual([], store.user_entries)
        self.assertEqual(1,len(self.memory.list()['items']))

    def test_markdown_notebook_briefing_journal_person_and_topic_roundtrip(self):
        # Reject raw JSON dumps; notebook files must be pure Markdown.
        bad = self.memory.write_notebook('topic', '{"not": "markdown"}', slug='bad-json')
        self.assertFalse(bad['success'])

        b_res = self.memory.write_notebook(
            'briefing',
            '# 晨间简报 · 2026-11-10\n\n## 今日脉络\n今天继续推进 Dream 闲时整合。\n\n## 卡片：梳理人物声纹与脉络\n- 纹样：关系交汇\n- 语境：承接昨日工作室讨论\n\n请帮我把最近录音里小林相关的讨论和待办整理出来。',
        )
        self.assertTrue(b_res['success'])
        p_res = self.memory.write_notebook('person', '协作伙伴，负责后端接口联调。', slug='小林', title='小林 · 协作脉络')
        self.assertTrue(p_res['success'])
        j_res = self.memory.write_notebook('journal', '# 2026-11-10 · 架构与地图优化\n\n- 上午完成了地图轨迹原生渲染。', slug='2026-11-10')
        self.assertTrue(j_res['success'])
        t_res = self.memory.write_notebook('topic', '# Dream 闲时记忆架构\n\n## 当前共识\n采用纯 Markdown 活页笔记本。', slug='dream-notebook')
        self.assertTrue(t_res['success'])

        notes = self.memory.list_notebook()
        self.assertEqual({'briefing', 'journal', 'person', 'topic'}, {n['category'] for n in notes})

        items = self.memory.list()['items']
        kinds = {i['kind'] for i in items}
        self.assertEqual({'briefing', 'journal', 'person', 'topic'}, kinds)
        person_item = next(i for i in items if i['kind'] == 'person')
        self.assertIn('# 小林 · 协作脉络', person_item['text'])
        self.assertEqual('dream', person_item['basis'])

        # Deleting a Markdown notebook item via forget() removes the underlying .md file
        # and records a tombstone so Dream will not recreate the deleted person/topic/project.
        self.memory.forget(person_item['id'])
        self.assertFalse((self.home / 'memories/people/小林.md').exists())
        recreate = self.memory.write_notebook('person', '重新创建的说话人', slug='小林', title='小林')
        self.assertFalse(recreate['success'])

    def test_notebook_identity_and_conditional_delete_survive_duplicate_content(self):
        paths = ["projects/a.md", "projects/b.md"]
        for path in paths:
            self.memory.write_notebook(path=path, content="# Common template")
        page = self.memory.list(limit=1)
        other = self.memory.list(after=page["next_cursor"], expected_revision=page["revision"])
        items = {item["path"]: item for item in page["items"] + other["items"]}
        a, b = (items[path] for path in paths)
        self.assertNotEqual(a["id"], b["id"])
        self.assertEqual(a["revision"], b["revision"])
        old_id = "momo-project-" + hashlib.sha256(a["text"].encode()).hexdigest()
        with self.assertRaises(Conflict):
            self.memory.forget(old_id, a["revision"])

        self.memory.write_notebook(path=paths[1], content="# New facts")
        with self.assertRaises(Conflict):
            self.memory.list(after=page["next_cursor"], expected_revision=page["revision"])
        with self.assertRaises(Conflict):
            self.memory.forget(b["id"], b["revision"])
        current_b = next(item for item in self.memory.list()["items"] if item["path"] == paths[1])
        self.assertEqual(current_b["id"], b["id"])
        self.memory.forget(b["id"], current_b["revision"])
        self.assertEqual([paths[0]], [note["path"] for note in self.memory.list_notebook()])
        self.assertFalse(self.memory.write_notebook(path=paths[1], content="# Recreated")["success"])

    def test_forget_http_compares_revision_and_preserves_legacy_sibling(self):
        from context_server import ContextService

        (self.home / "api-key").write_text("fixture-only")
        service = ContextService(self.home, {"data_url": "http://127.0.0.1:0", "workspace_id": "test"})
        service.threads[0].start()
        self.addCleanup(service.close)
        service.memory.write_notebook(path="projects/a.md", content="# Template")
        legacy_path = service.memory.memories_dir / "project/a.md"
        legacy_path.parent.mkdir()
        legacy_path.write_text("# Template")
        url = f"http://127.0.0.1:{service.server.server_port}/v1/memories"
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

        def request(body=None):
            req = urllib.request.Request(url if body is None else url + "/forget",
                                         data=json.dumps(body).encode() if body else None,
                                         headers={"Authorization": "Bearer fixture-only"})
            with opener.open(req, timeout=3) as response:
                return json.load(response)

        page = request()
        self.assertEqual("test", page["workspace_id"])
        item = next(row for row in page["items"] if row["path"] == "projects/a.md")
        service.memory.write_notebook(path="projects/a.md", content="# Revised")
        for body in ({"id": item["id"]}, {"id": item["id"], "base_revision": item["revision"]}):
            with self.assertRaises(urllib.error.HTTPError) as conflict:
                request(body)
            with conflict.exception as response:
                self.assertEqual(409, response.code)
                self.assertEqual("revision_conflict", json.load(response)["error"]["code"])
        item = next(row for row in request()["items"] if row["id"] == item["id"])
        self.assertEqual("forgotten", request({"id": item["id"], "base_revision": item["revision"]})["status"])
        self.assertEqual(["project/a.md"], [row["path"] for row in request()["items"]])

    def test_parallel_appends_preserve_unique_updates_and_retries(self):
        path = "projects/parallel.md"
        self.memory.write_notebook(path=path, content="# Concurrent edits")
        def append(section):
            return self.memory.write_notebook(path=path, content=section, mode="append", deduplicate_append=True)
        sections = [f"Section {i}" for i in range(12)]
        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(append, sections * 2))
        self.assertTrue(all(result["success"] for result in results))
        self.assertEqual(sum(result["changed"] for result in results), len(sections))
        blocks = self.memory.read_notebook(path=path)["content"].split("\n\n")
        self.assertCountEqual(blocks, ["# Concurrent edits"] + sections)

    def test_relabel_with_matching_name_can_resolve_unknown_owner(self):
        store = ContextStore(self.home / "context")
        self.addCleanup(store.close)
        span_id = str(uuid.uuid4())
        text = "[Sam] See you Friday"
        source_id = store.sync_source({
            "library_id": str(uuid.uuid4()), "session_id": str(uuid.uuid4()), "device_id": str(uuid.uuid4()),
            "generation": 0, "version": 1, "deleted": False, "recorded_at": 100, "text_sha256": digest(text),
            "spans": [{"id": span_id, "text": text, "recorded_at": 100}],
        })["source_id"]
        self.assertNotIn("is_owner", store.read_source(source_id)["spans"][0])
        target = {"source_id": source_id, "target_speaker": "Sam", "is_owner": False,
                  "span_ids": [span_id], "scope": "selection"}
        self.assertEqual(1, store.relabel_speakers(**target)["updated_span_count"])
        self.assertIs(False, store.read_source(source_id)["spans"][0]["is_owner"])
        self.assertEqual(0, store.relabel_speakers(**target)["updated_span_count"])

    def test_dream_counts_material_writes_and_preserves_speaker_ack(self):
        from superagent_gateway import SuperAgentGateway

        store = ContextStore(self.home / "context")
        self.addCleanup(store.close)
        span_id = str(uuid.uuid4())
        text = "[Speaker 1] See you Friday"
        source = store.sync_source({
            "library_id": str(uuid.uuid4()), "session_id": str(uuid.uuid4()), "device_id": str(uuid.uuid4()),
            "generation": 0, "version": 1, "deleted": False, "recorded_at": 100, "text_sha256": digest(text),
            "spans": [{"id": span_id, "text": text, "recorded_at": 100, "is_owner": False}],
        })
        gateway = SuperAgentGateway.__new__(SuperAgentGateway)
        gateway.data = self.home
        session = "momo-review-first"
        target = {"source_id": source["source_id"], "span_ids": [span_id], "scope": "selection", "target_speaker": "Sam"}
        _, _, call = gateway._build_memory_review_session(session)
        def write(name, args):
            return json.loads(call(name, args))

        memory = {"action": "add", "target": "user", "content": "Prefers tea"}
        notebook = {"action": "write", "path": "projects/sample.md", "content": "# Sample"}
        original = dict(target, target_speaker="Speaker 1")
        revision = store.revision
        self.assertFalse(write("relabel_speakers", original)["changed"])
        self.assertEqual(revision, store.revision)
        self.assertEqual([], store.pending_speaker_relabels())

        self.assertTrue(write("memory", memory)["changed"])
        self.assertTrue(write("notebook", notebook)["changed"])
        self.assertTrue(write("relabel_speakers", target)["changed"])
        relabel = store.pending_speaker_relabels()[0]
        store.ack_speaker_relabels([relabel["id"]])
        revision = store.revision
        home = memory_home(self.home)
        self.assertEqual(3, memory_review.successful_writes(home, session))

        session = "momo-review-replay"
        _, _, call = gateway._build_memory_review_session(session)
        self.assertFalse(write("memory", memory)["changed"])
        self.assertFalse(write("memory", {"target": "user", "operations": [memory]})["changed"])
        self.assertFalse(write("notebook", notebook)["changed"])
        move = {"action": "move", "path": notebook["path"], "to_path": notebook["path"]}
        self.assertFalse(write("notebook", move)["changed"])
        self.assertFalse(write("relabel_speakers", target)["changed"])
        self.assertEqual(revision, store.revision)
        self.assertEqual([], store.pending_speaker_relabels())
        no_change = json.dumps({"memory_review": {"outcome": "no_change", "reason": "Prior changes verified"}})
        self.assertEqual(0, memory_review.outcome(home, session, no_change)["native_writes"])
        with self.assertRaises(memory_review.InvalidReviewReceipt):
            memory_review.outcome(home, session, no_change.replace("no_change", "updated"))
        self.assertFalse(write("notebook", {"action": "write", "path": "../bad", "content": "bad"})["success"])
        with self.assertRaises(memory_review.InvalidReviewReceipt):
            memory_review.outcome(home, session, no_change)

        # The phone keeps delivery IDs forever. A -> B -> A must deliver A again.
        self.assertTrue(write("relabel_speakers", dict(target, target_speaker="Tina"))["changed"])
        store.ack_speaker_relabels([store.pending_speaker_relabels()[0]["id"]])
        restored = write("relabel_speakers", target)
        store.ack_speaker_relabels([relabel["id"]])
        self.assertNotEqual(relabel["id"], restored["relabel_id"])
        self.assertEqual([restored["relabel_id"]], [row["id"] for row in store.pending_speaker_relabels()])

    def test_multi_level_directories_custom_folders_and_move_reorganization(self):
        # 1. Write 2nd- and 3rd-level nested notes via `path` and `(category, nested_slug)`
        w1 = self.memory.write_notebook(
            path='projects/AI访谈/overview.md',
            content='# AI 访谈用研平台\n\n## 项目边界\n围绕异步主持人与日记法。',
        )
        self.assertTrue(w1['success'])
        self.assertEqual('project', w1['category'])
        self.assertEqual('projects/AI访谈/overview.md', w1['path'])

        w2 = self.memory.write_notebook(
            'project',
            '# 双月 OKR\n\n- O1：核心能力与 benchmark；O3：SLA 99.5%。',
            slug='AI访谈/架构与规划/双月OKR',
        )
        self.assertTrue(w2['success'])
        self.assertEqual('projects/AI访谈/架构与规划/双月OKR.md', w2['path'])

        # 2. Model-created custom top-level domain hierarchy
        w3 = self.memory.write_notebook(
            path='技术沉淀/语音链路/声纹聚类.md',
            content='# 声纹聚类与语义纠偏\n\n结合上下文称呼修正匿名说话人。',
        )
        self.assertTrue(w3['success'])
        self.assertEqual('note', w3['category'])
        self.assertEqual('技术沉淀/语音链路/声纹聚类.md', w3['path'])

        # 3. Move a flat note into a 2nd-level folder and verify empty parent cleanup
        w_flat = self.memory.write_notebook('topic', '# 并发压测排障\n\nMeta 3.1MB 体积优化。', slug='load-test')
        self.assertTrue(w_flat['success'])
        mv = self.memory.move_notebook(path='topics/load-test.md', to_path='projects/AI访谈/并发压测排障.md')
        self.assertTrue(mv['success'])
        self.assertFalse((self.home / 'memories/topics/load-test.md').exists())
        self.assertFalse((self.home / 'memories/topics').exists())
        self.assertTrue((self.home / 'memories/projects/AI访谈/并发压测排障.md').is_file())

        listed = self.memory.list_notebook(path_prefix='projects/AI访谈')
        self.assertEqual(
            {'projects/AI访谈/overview.md', 'projects/AI访谈/并发压测排障.md', 'projects/AI访谈/架构与规划/双月OKR.md'},
            {n['path'] for n in listed},
        )

        # 4. Items + forget() on custom nested note prunes empty parent directories
        items = self.memory.list()['items']
        custom_item = next(i for i in items if i.get('path') == '技术沉淀/语音链路/声纹聚类.md')
        self.assertEqual('note', custom_item['kind'])
        self.memory.forget(custom_item['id'])
        self.assertFalse((self.home / 'memories/技术沉淀').exists())


