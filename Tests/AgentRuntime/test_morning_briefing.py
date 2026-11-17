"""Tests for 4-dimensional holistic Morning Briefing synthesis, pre-dawn refresh, and multi-batch Dream context."""
from __future__ import annotations

from datetime import datetime
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
import uuid

from aiohttp.test_utils import TestClient, TestServer

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
import daily_review
from device_telemetry import sync_device_telemetry
from health_store import sync_health
import morning_briefing
from phone_sources import sync_phone_source
from rtc_transport import permitted_route
from superagent_gateway import SuperAgentGateway


class HolisticMorningBriefingTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.data = Path(self.tmp.name) / "Agent"
        self.conn = momo_agent.initialize(self.data, 19865)
        self.now_dt = datetime(2026, 11, 17, 8, 5, 0)
        self.now_ts = self.now_dt.timestamp()

    def _seed_rich_context(self) -> None:
        dev = str(uuid.uuid4())
        lib = str(uuid.uuid4())
        store = ContextStore(self.data / "context")
        try:
            # 1. Recent recording with owner + colleague turns
            spans = [
                {"id": str(uuid.uuid4()), "text": "[我] 概念测试灰度白名单今天上午要定下来", "recorded_at": self.now_ts - 14 * 3600},
                {"id": str(uuid.uuid4()), "text": "[继超] 好，P0 客户问题我们按 4 小时内响应执行", "recorded_at": self.now_ts - 14 * 3600 + 25},
            ]
            joined = "\n".join(s["text"] for s in spans)
            store.sync_source({
                "library_id": lib,
                "session_id": str(uuid.uuid4()),
                "device_id": dev,
                "generation": 1,
                "version": 1,
                "deleted": False,
                "recorded_at": self.now_ts - 14 * 3600,
                "title": "灰度与分级响应对齐",
                "text_sha256": digest(joined),
                "spans": spans,
            })

            # 2. HealthSnapshot v2 with overnight sleep + 7d HRV/RHR baselines
            win_start = self.now_ts - 7 * 86400
            sync_health(store, {
                "device_id": dev,
                "revision": 1,
                "state": "enabled",
                "observed_at": self.now_ts - 120,
                "window_start": win_start,
                "window_end": self.now_ts - 120,
                "timezone": "Asia/Shanghai",
                "observations": [
                    {
                        "metric": "hrv_sdnn",
                        "unit": "ms",
                        "value": 45.0,
                        "start": self.now_ts - 2 * 86400,
                        "end": self.now_ts - 86400,
                        "source_name": "Apple Health · 每日均值",
                        "source_bundle": "com.apple.Health.daily_avg",
                    },
                    {
                        "metric": "hrv_sdnn",
                        "unit": "ms",
                        "value": 55.0,
                        "start": self.now_ts - 600,
                        "end": self.now_ts - 300,
                        "source_name": "Apple Watch",
                        "source_bundle": "com.apple.health.watch",
                    },
                    {
                        "metric": "resting_heart_rate",
                        "unit": "count/min",
                        "value": 56.0,
                        "start": self.now_ts - 86400,
                        "end": self.now_ts - 200,
                        "source_name": "Apple Health · 每日均值",
                        "source_bundle": "com.apple.Health.daily_avg",
                    },
                    {
                        "metric": "steps",
                        "unit": "count",
                        "value": 6840.0,
                        "start": self.now_ts - 86400,
                        "end": self.now_ts - 200,
                        "source_name": "Apple Health · 每日合计",
                        "source_bundle": "com.apple.Health",
                    },
                ],
                "sleep_sessions": [
                    {
                        "id": "sleep-last-night",
                        "start": self.now_ts - 7.5 * 3600,
                        "end": self.now_ts - 0.8 * 3600,
                        "asleep_seconds": 6.8 * 3600,
                        "in_bed_seconds": 7.2 * 3600,
                        "deep_seconds": 1.1 * 3600,
                        "core_seconds": 4.1 * 3600,
                        "rem_seconds": 1.6 * 3600,
                        "awake_seconds": 0.4 * 3600,
                        "source_name": "Apple Watch",
                        "source_bundle": "com.apple.health.watch",
                    }
                ],
                "workouts": [],
                "activity_summaries": [],
            })

            # 3. Calendar + Reminders + Device Telemetry
            sync_phone_source(store, {
                "device_id": dev,
                "kind": "reminders",
                "revision": 1,
                "state": "enabled",
                "observed_at": self.now_ts - 60,
                "window_start": self.now_ts - 86400,
                "window_end": self.now_ts - 60,
                "timezone": "Asia/Shanghai",
                "records": [
                    {
                        "id": "rem-investor",
                        "title": "定稿投资人 Coffee Chat 提纲",
                        "source_name": "待办事项",
                        "start": self.now_ts + 4 * 3600,
                        "all_day": False,
                    }
                ],
            })
            sync_device_telemetry(store, {
                "device_id": dev,
                "revision": 1,
                "state": "enabled",
                "observed_at": self.now_ts - 30,
                "timezone": "Asia/Shanghai",
                "phone": {
                    "battery_level": 0.92,
                    "battery_state": "unplugged",
                    "low_power_mode": False,
                    "thermal_state": 0,
                    "free_storage_bytes": 50_000_000_000,
                    "audio_route": None,
                },
                "watch": None,
            })
        finally:
            store.close()

        vault = self.data / "memories"
        (vault / "journal/2026-11").mkdir(parents=True, exist_ok=True)
        (vault / "journal/2026-11/2026-11-16.md").write_text(
            "# 2026-11-16 · 灰度白名单与分级响应\n\n- 讨论了概念测试解耦与 P0 4 小时响应。",
            encoding="utf-8",
        )

    async def test_pre_dawn_briefing_regenerates_at_morning_gate_with_all_four_dimensions(self) -> None:
        self._seed_rich_context()
        briefing_file = self.data / "memories/BRIEFING.md"
        briefing_file.write_text("# 晨间简报 · 2026-11-17\n\n半夜一点半尚未睡觉时的旧简报。", encoding="utf-8")
        pre_dawn_ts = datetime(2026, 11, 17, 1, 31, 0).timestamp()
        os.utime(briefing_file, (pre_dawn_ts, pre_dawn_ts))

        gateway = SuperAgentGateway.__new__(SuperAgentGateway)
        gateway.data = self.data
        gateway.store = ProductStore(self.data / "runtime/conversation.sqlite", {"assistant_id": "test"})
        self.addCleanup(gateway.store.db.close)
        gateway.push = Mock()
        gateway.push.briefing_alerts_enabled.return_value = False
        gateway._call_configured_llm_oneshot = Mock(
            return_value=(
                "# 晨间简报 · 2026-11-17\n\n"
                "## 状态与节律\n"
                "昨晚睡满 6.8 小时（深睡 1.1h），今早 HRV 升至 55 ms（高于均值），精力充沛适合上午推进关键决策。\n\n"
                "## 昨日原音与推进脉络\n"
                "- **灰度与分级响应**：已对齐 P0 4 小时响应机制与概念测试白名单 · `journal/2026-11/2026-11-16.md`\n\n"
                "## 今日焦点与必办\n"
                "- **定稿投资人提纲**：中午前收口明日 Coffee Chat 三分钟核心案例。\n\n"
                "## 卡片：梳理提纲\n"
                "- 纹样：记忆回环\n"
                "- 语境：投资人会面\n\n"
                "帮我把投资人会面提纲压成一页重点。"
            )
        )

        with patch("superagent_gateway.datetime", wraps=datetime) as mock_dt, patch("morning_briefing.time.time", return_value=self.now_ts):
            mock_dt.now.return_value = self.now_dt
            delivered = await gateway._deliver_morning_briefing()

        self.assertIsNotNone(delivered)
        gateway._call_configured_llm_oneshot.assert_called_once()
        prompt_sent = gateway._call_configured_llm_oneshot.call_args.args[0]
        self.assertIn("概念测试灰度白名单", prompt_sent)
        self.assertIn("P0 客户问题我们按 4 小时内响应", prompt_sent)
        self.assertIn("sleep-last-night" if "sleep-last-night" in prompt_sent else "asleep_hours", prompt_sent)
        self.assertIn("hrv_sdnn", prompt_sent)
        self.assertIn("定稿投资人 Coffee Chat 提纲", prompt_sent)

        # BRIEFING.md updated with full markdown (including card), while chat message strips the raw card block
        saved_briefing = briefing_file.read_text(encoding="utf-8")
        self.assertIn("昨晚睡满 6.8 小时", saved_briefing)
        self.assertIn("## 卡片：梳理提纲", saved_briefing)
        self.assertNotIn("## 卡片：", delivered["chat_content"])
        self.assertIn("[📔 journal/2026-11/2026-11-16.md]", delivered["chat_content"])

    async def test_regenerate_endpoint_and_webrtc_allowlist(self) -> None:
        self.assertEqual(
            permitted_route("POST", "/momo/v1/briefing/regenerate"),
            ("/momo/v1/briefing/regenerate", False, False),
        )
        self._seed_rich_context()
        api_key = (self.data / "api-key").read_text(encoding="utf-8").strip()
        gateway = SuperAgentGateway(
            self.data,
            self.conn,
            python_executable=Path(sys.executable),
            base_env={},
            manage_dsh=False,
        )
        gateway._call_configured_llm_oneshot = Mock(
            return_value="## 状态与节律\n状态平稳。\n\n## 今日焦点与必办\n- **收口白名单**：上午拍板。"
        )
        client = TestClient(TestServer(gateway.create_app()))
        await client.start_server()
        try:
            resp = await client.post(
                "/momo/v1/briefing/regenerate",
                headers={"Authorization": f"Bearer {api_key}"},
                json={},
            )
            self.assertEqual(resp.status, 200)
            body = await resp.json()
            self.assertTrue(body["ok"])
            self.assertIn("# 晨间简报 ·", body["briefing_markdown"])
            self.assertIn("收口白名单", body["chat_content"])
        finally:
            await client.close()
            gateway.bridge.close()
            gateway.store.db.close()

    def test_multi_batch_dream_final_page_includes_final_synthesis_context(self) -> None:
        self._seed_rich_context()
        store = ContextStore(self.data / "context")
        try:
            job, created = daily_review.enqueue(store, self.data, self.now_ts, manual=True)
            self.assertTrue(created)
            with store.write():
                payload = json.loads(job["input"])
                payload["continuation_of"] = "prev-batch-id"
                store.db.execute(
                    "UPDATE memory_reviews SET first_attempt=?, input=? WHERE id=?",
                    (self.now_ts, json.dumps(payload), job["id"]),
                )
            prompt_text = daily_review.prompt(store, store.db.execute("SELECT * FROM memory_reviews WHERE id=?", (job["id"],)).fetchone())
            self.assertIn("final_synthesis_context", prompt_text)
            self.assertIn("hrv_sdnn", prompt_text)
        finally:
            store.close()


if __name__ == "__main__":
    unittest.main()
