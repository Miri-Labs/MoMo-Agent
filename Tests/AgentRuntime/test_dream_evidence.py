"""Exercise Dream evidence through the scheduler and the tools it gives the model."""
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / "Apps/MacApp/Context"), str(ROOT / "Apps/MacApp/Runtime")]
from context_store import ContextStore
from conversation_store import ProductStore
from health_store import sync_health
import memory_review
from momo_memory import memory_home
from phone_sources import sync_phone_source
from superagent_gateway import SuperAgentGateway


class DreamEvidenceTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.data = Path(temp.name)
        self.context = ContextStore(self.data / "context")
        self.addCleanup(self.context.close)
        (self.data / "runtime").mkdir()
        self.chat = ProductStore(self.data / "runtime/conversation.sqlite", {"assistant_id": "test"})
        self.addCleanup(self.chat.db.close)
        gateway = SuperAgentGateway.__new__(SuperAgentGateway)
        gateway.data = self.data
        _, specs, self.run_tool = gateway._build_memory_review_session("momo-review-test")
        self.phone_params = next(s["parameters"] for s in specs if s["name"] == "phone_context")
        self.now = int(time.time())
        self.phone = dict(device_id=str(uuid.uuid4()), state="enabled", observed_at=self.now,
                          window_start=self.now - 30, window_end=self.now, timezone="Asia/Shanghai")

    def tool(self, name, **args):
        return json.loads(self.run_tool(name, args))

    def reminders(self, revision, *ids, **fields):
        snapshot = dict(self.phone, revision=revision, kind="reminders", records=[
            {"id": str(i), "title": "Task " + str(i), "source_name": "Fixture"} for i in ids])
        sync_phone_source(self.context, dict(snapshot, **fields))

    def test_history_search_and_morning_briefing_share_daily_chat_evidence(self):
        db = self.chat.db
        with db:
            for state in ("applied", "not_applied", "pending"):
                db.execute("""INSERT INTO inputs(operation_id,content,run_id,owner_scope,intent,delivery_state)
                    VALUES(?,?,?,'test','steer',?)""", (state, state, state, state))
            for seq, (role, operation, key) in enumerate([
                ("user", "applied", None), ("user", "not_applied", None), ("user", "pending", None),
                ("assistant", None, "dream-briefing:today"), ("assistant", "dream-briefing:old", None),
                ("assistant", None, None), ("tool", None, None)
            ], start=1):
                db.execute("""INSERT INTO messages(seq,id,role,content,created_at,operation_id,source_key)
                    VALUES(?,?,?,?,?,?,?)""", (seq, str(seq), role, f"evidence {seq}", self.now, operation, key))
        daily = memory_review.chat_batch(self.context, self.data)
        self.assertEqual([m["seq"] for m in daily["messages"]], [1, 6])
        for query in ("", "evidence"):
            history = self.tool("session_search", query=query)
            self.assertEqual([m["seq"] for m in history["messages"]], [1, 6])
        summary, fallback = memory_review.morning_briefing_evidence(self.data, db)
        self.assertEqual([m["request_excerpt"] for m in json.loads(summary)], ["evidence 1"])
        self.assertIn("evidence 1", fallback)

    def test_phone_tool_follows_each_kind_cursor_and_detects_replaced_snapshots(self):
        self.reminders(1, *range(45))
        self.assertIn("after", self.phone_params["properties"])
        sources = self.tool("phone_context")
        self.assertEqual(set(sources), {"calendar", "visits", "reminders"})
        first = sources["reminders"]
        cursor = first["next_cursor"]
        self.assertEqual(len(first["items"][0]["records"]), 40)
        second = self.tool("phone_context", kind="reminders", after=cursor)["reminders"]
        self.assertEqual([r["id"] for r in second["items"][0]["records"]], [str(i) for i in range(40, 45)])
        self.assertIsNone(second["next_cursor"])
        self.assertIn("error", self.tool("phone_context", after=cursor))
        self.assertIn("error", self.tool("phone_context", kind="calendar", after=cursor))
        self.assertIn("error", self.tool("phone_context", kind="health", after=cursor))
        self.reminders(2, 7)
        self.assertIn("error", self.tool("phone_context", kind="reminders", after=cursor))

    def test_only_changed_phone_records_schedule_daily_review(self):
        def next_review(now):
            return memory_review.next_review(self.context, self.data, now)

        def finish(job):
            memory_review.finish(self.context, job, {"outcome": "no_change"}, memory_home(self.data))

        tomorrow = self.now + memory_review.DREAM_INTERVAL + 60
        self.reminders(1)
        step = dict(metric="steps", unit="count", value=100, start=self.now - 30, end=self.now,
                    source_bundle="test.fixture", source_name="Fixture")
        sync_health(self.context, dict(self.phone, revision=1, observations=[step]))
        health = self.tool("phone_context", kind="health")["health"]
        self.assertEqual(health["items"][0]["observations"][0]["value"], 100)
        self.assertIsNone(next_review(self.now))
        self.reminders(2, 1, 2)
        first = next_review(self.now)
        self.assertIsNotNone(first)
        # A new task arrives while the scheduled evidence is being processed.
        self.reminders(3, 1, 2, 3)
        finish(first)
        self.assertIsNone(next_review(self.now + 1))
        second = next_review(tomorrow)
        self.assertNotEqual(second["id"], first["id"])
        finish(second)
        self.reminders(4, 3, 2, 1, observed_at=self.now + 20, window_end=self.now + 20)
        self.assertIsNone(next_review(tomorrow + 60))
        self.reminders(5, state="disabled")
        self.assertIsNotNone(next_review(tomorrow + 60))

    def test_changed_calendar_and_visit_fields_each_trigger_a_review(self):
        calendar = dict(id="event", title="Meeting", source_name="Calendar",
                        start=self.now - 10, end=self.now, all_day=False)
        visit = dict(id="visit", source_name="iPhone", start=self.now - 15,
                     latitude=30, longitude=100, accuracy=50)
        for kind, revision, record in (
                ("calendar", 1, calendar), ("calendar", 2, dict(calendar, title="Rescheduled")),
                ("visits", 1, visit), ("visits", 2, dict(visit, end=self.now))):
            with self.subTest(kind=kind, revision=revision):
                sync_phone_source(self.context, dict(self.phone, kind=kind, revision=revision, records=[record]))
                job = memory_review.next_review(self.context, self.data, self.now + memory_review.DREAM_INTERVAL + 60)
                self.assertIsNotNone(job)
                memory_review.finish(self.context, job, {"outcome": "no_change"}, memory_home(self.data))
