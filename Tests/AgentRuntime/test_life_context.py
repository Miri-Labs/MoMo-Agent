"""Tests for holistic Life Context assembly, organic memory recall, Dream v10 policy, and illustration disambiguation."""
from __future__ import annotations

from datetime import datetime
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[2]
for extra in (
    ROOT / "Apps/MacApp/Runtime",
    ROOT / "Apps/MacApp/Context",
    ROOT / "Apps/MacApp/Access",
    ROOT / "Vendor/HermesAgent",
):
    if str(extra) not in sys.path:
        sys.path.insert(0, str(extra))

import momo_agent
from context_store import ContextStore, digest
from conversation_store import ProductStore
import life_context
from life_illustration_generator import CodexIllustrationGenerator, SCENE_POLICY
from life_illustrations import LifeIllustrations
import life_pulse
import memory_review
from momo_memory import MoMoMemory
import morning_briefing
import personal_context
from phone_sources import sync_phone_source
from rtc_transport import permitted_route
from situational_context import read_situational_context


class HolisticLifeContextTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.data = Path(self.tmp.name) / "Agent"
        self.conn = momo_agent.initialize(self.data, 19866)
        self.tz = ZoneInfo("Asia/Shanghai")
        self.now_dt = datetime(2026, 11, 17, 10, 15, 0, tzinfo=self.tz)
        self.now_ts = self.now_dt.timestamp()

    def _seed_recording(self, store: ContextStore, label: str, recorded_at: float, spans: list[tuple[str, str]]) -> str:
        span_objs = [
            {
                "id": str(uuid.uuid4()),
                "text": f"[{spk}] {txt}",
                "recorded_at": recorded_at + idx * 5,
            }
            for idx, (spk, txt) in enumerate(spans, start=1)
        ]
        joined = "\n".join(s["text"] for s in span_objs)
        result = store.sync_source({
            "library_id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"lib:{label}")),
            "session_id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"sess:{label}")),
            "device_id": str(uuid.uuid5(uuid.NAMESPACE_URL, "dev:watch")),
            "generation": 1,
            "version": 1,
            "deleted": False,
            "recorded_at": recorded_at,
            "title": label,
            "text_sha256": digest(joined),
            "spans": span_objs,
        })
        return result["source_id"]

    def test_dream_v10_and_personal_context_promote_holistic_life_and_organic_vault(self) -> None:
        self.assertEqual(memory_review.CURATION_POLICY_VERSION, "v10-holistic-life-context")
        self.assertIn("Holistic Life Context", personal_context.INSTRUCTION)
        self.assertIn("皮皮", personal_context.INSTRUCTION)
        self.assertIn("短视频旁白", personal_context.INSTRUCTION)
        self.assertIn("自由生长的 Markdown 知识库", personal_context.INSTRUCTION)
        self.assertIn("search_memory", memory_review.DREAM_INSTRUCTION)
        self.assertIn("家庭与同住成员", memory_review.DREAM_INSTRUCTION)

    def test_directory_agnostic_recall_surfaces_custom_vault_folders_and_excludes_window_and_assistant_echo(self) -> None:
        mem = MoMoMemory(self.data)
        with mem.store() as mstore:
            mstore.add("user", "**【家庭与宠物】**（2026-11-16）：妻子鼠子，家里养了猫咪皮皮（常被ASR听成屁屁）与小崽。")
            mstore.add("memory", "**【日常锚点】**（2026-11-16）：上海徐汇居家与办公双点通勤。")
        # Write into an arbitrary organic custom folder (`living/pets-and-home.md`) — NOT `people/` or `places/`.
        mem.write_notebook(
            "note",
            "# 居家生活与猫咪档案\n\n皮皮（ASR常作“屁屁”）是家里的成年猫咪，喜欢凑过来闻人和啃脚；刚换了新猫粮。\n",
            path="living/pets-and-home.md",
            mode="replace",
        )

        store = ContextStore(self.data / "context")
        try:
            # Past recording from 3 days ago mentioning Pipi the cat
            past_ts = self.now_ts - 3 * 86400
            past_sid = self._seed_recording(
                store,
                "rec-past-cat",
                past_ts,
                [("鼠子", "今天给猫咪皮皮洗了个澡，吹毛的时候特别乖，新买的猫粮它也很爱吃。")],
            )
            # Current episode recording (should be excluded when exclude_window or exclude_source_ids matches)
            cur_ts = self.now_ts - 600
            cur_sid = self._seed_recording(
                store,
                "rec-current-slot",
                cur_ts,
                [("说话人2", "皮皮你别啃自己的脚啦，过来摸摸。")],
            )
            sync_phone_source(
                store,
                {
                    "device_id": str(uuid.uuid4()),
                    "kind": "visits",
                    "revision": 1,
                    "state": "enabled",
                    "observed_at": self.now_ts - 60,
                    "window_start": self.now_ts - 86400,
                    "window_end": self.now_ts - 60,
                    "timezone": "Asia/Shanghai",
                    "records": [
                        {
                            "id": "visit-home",
                            "title": "徐汇家中",
                            "latitude": 31.1886,
                            "longitude": 121.4365,
                            "accuracy": 18.0,
                            "start": self.now_ts - 7200,
                            "source_name": "iPhone",
                        }
                    ],
                },
            )
            sit = read_situational_context(store, data_dir=self.data, now=self.now_ts)
            self.assertEqual(sit["mobility_and_place"]["visit"]["title"], "徐汇家中")
            self.assertIn("位置 徐汇家中", sit["concise_summary"])
        finally:
            store.close()

        # Seed chat with both user statement and assistant echo
        pstore = ProductStore(self.data / "runtime/conversation.sqlite", self.conn)
        try:
            with pstore.db:
                pstore.db.execute(
                    "INSERT INTO messages(id,role,content,created_at) VALUES(?,?,?,?)",
                    ("msg-user-1", "user", "我们家皮皮是一只猫咪，不是狗。", self.now_ts - 3600),
                )
                pstore.db.execute(
                    "INSERT INTO messages(id,role,content,created_at) VALUES(?,?,?,?)",
                    ("msg-asst-1", "assistant", "好的，记住了皮皮是狗。", self.now_ts - 3590),
                )
        finally:
            pstore.db.close()

        pack = life_context.build_life_context_pack(
            self.data,
            texts=["[说话人2] 皮皮，别啃脚啦"],
            exclude_window=(cur_ts - 10, cur_ts + 30),
            include_core_memory=True,
            include_situation=True,
            recall_limit=8,
            now=self.now_ts,
        )
        self.assertIn("猫咪皮皮", pack["user_profile"])
        self.assertIn("上海徐汇", pack["core_memory"])
        self.assertEqual(pack["ambient_situation"]["place"]["title"], "徐汇家中")

        recalled = pack["recalled_context"]
        recalled_paths = [r.get("path") for r in recalled if r["kind"] == "note"]
        self.assertIn("living/pets-and-home.md", recalled_paths)
        self.assertNotIn("USER.md", recalled_paths)
        self.assertNotIn("MEMORY.md", recalled_paths)

        recalled_sources = [r.get("source_id") for r in recalled if r["kind"] == "recording"]
        self.assertIn(past_sid, recalled_sources)
        self.assertNotIn(cur_sid, recalled_sources)

        for r in recalled:
            self.assertNotEqual(r.get("basis"), "assistant_statement")

        # Verify holistic morning briefing & life pulse also consume core memory
        conv_ro = memory_review.readonly(self.data / "runtime/conversation.sqlite")
        try:
            brief_bundle = morning_briefing.build_holistic_briefing_pack(self.data, conv_ro, now=self.now_ts)
        finally:
            conv_ro.close()
        self.assertIn("猫咪皮皮", brief_bundle["pack"]["user_and_core_memory"]["user_profile"])

        pulse_text = life_pulse.format_pulse_brief(sit, ["位置更新"], data_dir=self.data)
        self.assertIn("徐汇家中", pulse_text)
        self.assertIn("猫咪皮皮", pulse_text)

    def test_illustration_prepare_injects_life_context_and_supports_single_slot_regeneration(self) -> None:
        self.assertTrue(permitted_route("POST", "/context/v1/life-illustrations/regenerate"))
        self.assertFalse(permitted_route("GET", "/context/v1/life-illustrations/regenerate"))
        self.assertIn("猫咪‘皮皮’", SCENE_POLICY)

        mem = MoMoMemory(self.data)
        with mem.store() as mstore:
            mstore.add("user", "**【宠物】**：家里养有一只猫咪叫皮皮（有时转写为屁屁）。")
        mem.write_notebook(
            "note",
            "# 皮皮\n\n皮皮是一只圆润可爱的家猫，竖尖猫耳、细长尾巴，喜欢低头舔爪啃脚。\n",
            path="household/pipi.md",
            mode="replace",
        )

        slot_ts = datetime(2026, 11, 17, 9, 48, 0, tzinfo=self.tz).timestamp()
        ready_avail = {"supported": True, "reason": None, "provider": "antigravity"}
        store = ContextStore(self.data / "context")
        queue = LifeIllustrations(self.data)
        try:
            queue.update_settings({"enabled": True}, ready_avail, slot_ts)
            self._seed_recording(
                store,
                "rec-morning-pipi",
                slot_ts,
                [
                    ("说话人2", "皮皮，皮皮你又在啃脚啦，过来抱一下，咱们家的皮皮今天胃口真不错，刚把碗里的猫粮吃得干干净净。"),
                    ("说话人1", "你看皮皮尾巴摇来摇去的，今天精神真好，毛也顺滑了很多，一会儿拿逗猫棒陪它玩十分钟。"),
                ],
            )
            queue.scan(store, now=slot_ts + 3 * 3600 + 600)
            items = queue.status()["items"]
            self.assertEqual(len(items), 1)
            slot_id = items[0]["id"]

            # Simulate an old completed slot with misdrawn summary, then regenerate it
            with queue.write():
                queue.db.execute(
                    "UPDATE slots SET state='ready', summary='旧摘要：宠物皮皮', brief='旧简报', updated_at=? WHERE id=?",
                    (slot_ts + 400, slot_id),
                )
            regen = queue.regenerate(slot_id, store, ready_avail, now=slot_ts + 500)
            self.assertEqual(regen["id"], slot_id)
            self.assertEqual(regen["state"], "pending")
            refreshed = queue.status()["items"][0]
            self.assertEqual(refreshed["state"], "pending")
            self.assertIsNone(refreshed["summary"])
        finally:
            queue.close()
            store.close()

        gen = CodexIllustrationGenerator(self.data)
        captured_prompts: list[str] = []
        fake_llm = {
            "dsh_provider": "antigravity",
            "model_id": "gemini-test",
            "base_url": "http://127.0.0.1:9",
        }
        # Verify agentic tool call (`search_memory`) + final brief extraction
        responses = [
            {
                "choices": [
                    {
                        "message": {
                            "content": "",
                            "tool_calls": [
                                {
                                    "id": "call_search_1",
                                    "type": "function",
                                    "function": {
                                        "name": "search_memory",
                                        "arguments": json.dumps({"query": "皮皮 品种 猫"}, ensure_ascii=False),
                                    },
                                }
                            ],
                        }
                    }
                ]
            },
            {
                "choices": [
                    {
                        "message": {
                            "content": (
                                "SUMMARY: 说话人在室内轻声唤着猫咪“皮皮”，逗弄正低头啃脚的猫咪。\n"
                                "BRIEF: 画面聚焦说话人俯身逗弄家猫“皮皮”的安静瞬间：有着竖立尖三角猫耳、细胡须与细长弯尾的猫咪皮皮正低头舔啃后脚，说话人在旁注视并轻声呼唤它，室内保持最简居家背景。"
                            )
                        }
                    }
                ]
            },
        ]

        def fake_completion(*, messages, **kwargs):
            captured_prompts.append(json.dumps(messages, ensure_ascii=False))
            return responses.pop(0)

        evidence = {
            "window_start": slot_ts,
            "window_end": slot_ts + 120,
            "visits": [],
            "passages": [
                {
                    "source_id": "rec-morning-pipi",
                    "spans": [{"recorded_at": slot_ts, "speaker": "说话人2", "text": "皮皮，你又在啃脚啦"}],
                }
            ],
        }
        with patch.object(gen, "resolve", return_value=fake_llm), patch(
            "antigravity_bridge.run_antigravity_completion", side_effect=fake_completion
        ):
            out = gen.prepare(evidence)

        self.assertIn("猫咪“皮皮”", out)
        self.assertEqual(len(captured_prompts), 2)
        # First prompt already injected `life_context` with USER.md & household/pipi.md, and second turn carried `search_memory` result
        self.assertIn("life_context", captured_prompts[0])
        self.assertIn("household/pipi.md", captured_prompts[0])
        self.assertIn("竖尖猫耳", captured_prompts[1])


if __name__ == "__main__":
    unittest.main()
