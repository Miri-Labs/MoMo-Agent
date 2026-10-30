"""UI reads and edits the native Hermes store, without a parallel memory engine."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT/'Apps/MacApp/Context'), str(ROOT/'Vendor/HermesAgent')]
from hermes_memory import HermesMemory
from context_store import Conflict


class HermesMemoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        (self.home/'config.yaml').write_text(json.dumps({'memory':{'memory_enabled':True,'user_profile_enabled':True}}))
        self.memory = HermesMemory(self.home)

    def test_native_writes_appear_in_ui_and_ui_delete_updates_native_store(self):
        with self.memory.store() as store:
            self.assertTrue(store.add('memory', '周五给小林发方案。')['success'])
            self.assertTrue(store.add('user', '喜欢清淡的食物。')['success'])
        items = self.memory.list()['items']; item = next(i for i in items if i['kind']=='memory')
        self.assertEqual('hermes', item['basis']); self.assertEqual([],item['evidence'])
        self.memory.forget(item['id']); self.memory.forget(item['id'])
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
        with HermesMemory(other).store() as store: self.assertEqual([], store.user_entries)
        self.assertEqual(1,len(self.memory.list()['items']))
