"""Isolated ticket -> gateway -> chat events/history -> existing push outbox regressions."""
import asyncio
from contextlib import closing
import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import AsyncMock, patch
import uuid

from aiohttp.test_utils import TestClient, TestServer

ROOT = Path(__file__).resolve().parents[2]
for folder in ("Apps/MacApp/Runtime", "Apps/MacApp/Context", "Apps/MacApp/Access"):
    sys.path.insert(0, str(ROOT / folder))
import momo_agent
from push_notifications import TOPIC
from superagent_gateway import SuperAgentGateway


class ConfirmationDeliveryTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.data = Path(self.temp.name)
        self.connection = momo_agent.initialize(self.data, 19830)
        await self.open_gateway()
        self.turn = await self.submit("帮我复查会议进展")
        self.trigger_id = self.gateway.bridge.db.execute("SELECT id FROM triggers").fetchone()[0]

    async def open_gateway(self):
        self.gateway = SuperAgentGateway(self.data, self.connection, python_executable=Path(sys.executable),
                                        base_env=momo_agent.child_environment(self.data), manage_dsh=False)
        self.client = TestClient(TestServer(self.gateway.create_app()))
        await self.client.start_server()
        # Keep tests deterministic; every tick below is explicit and every provider is a fake.
        for task in self.gateway._tasks:
            task.cancel()
        await asyncio.gather(*self.gateway._tasks, return_exceptions=True)

    async def asyncTearDown(self):
        await self.client.close()

    async def restart(self):
        await self.client.close()
        await self.open_gateway()

    async def submit(self, text):
        response = await self.client.post("/momo/v1/conversation/messages",
            headers={"Authorization": "Bearer " + self.gateway.api_key},
            json={"operation_id": str(uuid.uuid4()), "content": text})
        self.assertEqual(response.status, 200, await response.text())
        return await response.json()

    def ticket(self, question="【手机可完成·聊天回复】可以沿用原身份只读吗？", **changes):
        return {"id": "ticket", "state": "open", "stage": "person", "action": "answer", "strength": "explicit",
                "attention": {"id": "question", "question": question, "triggerId": self.trigger_id}, **changes}

    def project(self, ticket):
        self.gateway._apply_dsh_projections({}, [ticket], [
            {"kind": "accept", "triggerIds": [self.trigger_id], "ticketId": ticket["id"]}])

    async def messages(self):
        response = await self.client.get("/momo/v1/conversation/messages",
            headers={"Authorization": "Bearer " + self.gateway.api_key})
        return [row for row in (await response.json())["data"] if row["role"] == "assistant"]

    def state(self):
        return self.gateway.bridge.db.execute("SELECT status,wait_reason FROM chat_runs WHERE run_id=?",
                                             (self.turn["run_id"],)).fetchone()

    def count(self, table):
        return self.gateway.store.db.execute(f"SELECT count(*) FROM {table}").fetchone()[0]

    async def outbound(self, ticket, *, turn=None, **changes):
        turn = turn or self.turn
        attention = ticket.get("attention") or {}
        key = json.dumps(["attention-reply", attention.get("id")], separators=(",", ":"))
        return await self.client.post("/momo/internal/superagent/outbound",
            headers={"X-MoMo-Bridge": self.gateway.bridge_secret}, json={
                "id": hashlib.sha256(key.encode()).hexdigest()[:32], "kind": "reply", "ticket_id": ticket["id"],
                "attention_id": attention.get("id"), "text": attention.get("question") or "主 Agent 转达的确认",
                "channel": {"thread": "chat:" + turn["work_id"], "address": {"messageId": turn["message_id"]}},
                **changes})

    async def test_missing_message_delivered_to_chat_stream_history_and_existing_push(self):
        stream = asyncio.Queue()
        self.gateway._run_streams[self.turn["run_id"]] = [stream]
        self.project(self.ticket())  # No orchestrator_reply call.
        messages = await self.messages()
        self.assertEqual(len(messages), 1)
        self.assertEqual(messages[0]["run_id"], self.turn["run_id"])
        self.assertEqual(messages[0]["confirmation"], {"device": "phone", "kind": "chat_reply"})
        event = stream.get_nowait()
        self.assertEqual(event["event"], "message.committed")
        self.assertEqual(event["message"], messages[0])
        self.assertEqual(event["input"]["id"], self.turn["message_id"])
        self.assertEqual(tuple(self.state()), ("waiting_for_input", "clarify"))
        push = self.gateway.store.db.execute("SELECT payload FROM push_events").fetchone()[0]
        self.assertEqual(json.loads(push)["message_id"], messages[0]["id"])
        self.assertNotIn("只读", push)  # Push remains a private reference, not consent content.

    async def test_orchestrator_explanation_survives_question_canonicalization(self):
        ticket = self.ticket("Approve read-only?")
        self.gateway._cached_tickets = [ticket]
        text = "Use company identity not personal.\n\nApprove read-only?"
        self.assertEqual((await self.outbound(ticket, text=text)).status, 200)
        self.assertEqual((await self.messages())[0]["content"], text)
        self.project(ticket)
        await self.outbound(ticket, text=text)
        self.assertEqual(len(await self.messages()), 1)
        self.assertEqual(self.count("push_events"), 1)
        self.assertEqual(self.gateway.store.db.execute("SELECT sum(active) FROM push_events").fetchone()[0], 1)

    async def test_fallback_does_not_consume_later_explanation_or_explicit_followup_answer(self):
        ticket = self.ticket("Approve read-only?")
        self.project(ticket)
        followup = await self.submit("Which identity should I use?")
        text = "Use company identity not personal.\n\nApprove read-only?"
        await self.outbound(ticket, text=text)
        messages = await self.messages()
        self.assertEqual([m["content"] for m in messages], ["Approve read-only?", "Use company identity not personal."])
        self.assertEqual([m["run_id"] for m in messages], [self.turn["run_id"]] * 2)
        await self.restart()
        ticket["attention"]["id"] = "recovered"
        self.project(ticket)
        await self.outbound(ticket, text=text)
        self.assertEqual(len(await self.messages()), 2)
        self.assertEqual(self.count("push_events"), 2)
        # purpose=answer uses the follow-up's own channel and must remain independent of attention dedupe.
        answer = "Use company identity not personal."
        response = await self.outbound(ticket, turn=followup, id="explicit-answer", attention_id=None, text=answer)
        self.assertEqual(response.status, 200)
        await self.outbound(ticket, turn=followup, id="explicit-answer", attention_id=None, text=answer)
        self.assertEqual([(m["run_id"], m["content"]) for m in await self.messages()][-1], (followup["run_id"], answer))
        self.assertEqual(len(await self.messages()), 3)
        self.assertEqual(self.count("push_events"), 3)
        self.assertEqual(self.state()[0], "waiting_for_input")

    async def test_new_confirmation_episode_can_repeat_a_previously_cleared_question(self):
        for index, question in enumerate(("A?", "B?", "A?")):
            ticket = self.ticket(question)
            ticket["attention"]["id"] = f"fresh-{index}"
            self.project(ticket)
            self.assertEqual(len(await self.messages()), index + 1)
            self.assertEqual(self.count("push_events"), index + 1)
            await self.restart()
            ticket["attention"]["id"] = f"recovered-{index}"
            self.project(ticket)
            await self.outbound(ticket, text=question)
            self.assertEqual(len(await self.messages()), index + 1)
            self.assertEqual(self.count("push_events"), index + 1)
            if index < 2:
                self.project(self.ticket(attention=None, action="running"))
                self.assertIsNone(self.state()[1])
                await self.restart()  # The cleared episode boundary must survive downtime.
        messages = await self.messages()
        self.assertEqual([m["content"] for m in messages], ["A?", "B?", "A?"])
        self.assertEqual(len({m["id"] for m in messages}), 3)
        self.assertEqual(self.gateway.store.db.execute("SELECT sum(active) FROM push_events").fetchone()[0], 1)

    async def test_returning_to_question_without_clear_is_a_meaningful_update(self):
        for question in ("A?", "B?", "A?"):
            self.project(self.ticket(question))
            self.project(self.ticket(question))
        self.assertEqual([m["content"] for m in await self.messages()], ["A?", "B?", "A?"])
        self.assertEqual(self.count("push_events"), 3)

    async def test_explanation_partial_failure_recovered_by_fallback_does_not_duplicate(self):
        ticket = self.ticket("Approve read-only?")
        self.gateway._cached_tickets = [ticket]
        text = "Use company identity not personal.\n\nApprove read-only?"
        with patch.object(self.gateway.push, "emit", side_effect=OSError("fixture enqueue failure")):
            with self.assertLogs("aiohttp.server", level="ERROR"):
                self.assertEqual((await self.outbound(ticket, text=text)).status, 500)
        await self.restart()
        self.project(ticket)  # Recovers the already-written full message, including its explanation.
        await self.outbound(ticket, text=text)
        self.assertEqual([m["content"] for m in await self.messages()], [text])
        self.assertEqual(self.count("push_events"), 1)

    async def test_supplemental_explanation_enqueue_failure_retries_after_restart(self):
        ticket = self.ticket("Approve read-only?")
        self.project(ticket)
        text = "Use company identity not personal.\n\nApprove read-only?"
        with patch.object(self.gateway.push, "emit", side_effect=OSError("fixture enqueue failure")):
            with self.assertLogs("aiohttp.server", level="ERROR"):
                self.assertEqual((await self.outbound(ticket, text=text)).status, 500)
        self.assertEqual(self.count("push_events"), 1)
        await self.restart()
        self.project(ticket)
        await self.outbound(ticket, text=text)
        await self.outbound(ticket, text=text)
        self.assertEqual([m["content"] for m in await self.messages()], ["Approve read-only?", "Use company identity not personal."])
        self.assertEqual(self.count("push_events"), 2)

    async def test_ready_boundary_and_failed_delivery_keep_new_episode_retryable(self):
        ticket = self.ticket("A?")
        self.project(ticket)
        self.project(self.ticket(attention=None, state="ended", ended={"outcome": "completed"}))
        await self.restart()
        ticket["attention"]["id"] = "new-after-ready"
        with patch.object(self.gateway.push, "emit", side_effect=OSError("fixture enqueue failure")):
            with self.assertLogs("momo.superagent_gateway", level="ERROR"):
                self.project(ticket)
        self.assertEqual(len(await self.messages()), 2)
        await self.restart()
        ticket["attention"]["id"] = "regenerated-during-retry"
        self.project(ticket)
        self.project(ticket)
        self.assertEqual([m["content"] for m in await self.messages()], ["A?", "A?"])
        self.assertEqual(self.count("push_events"), 2)
        self.assertEqual(self.gateway.store.db.execute("SELECT sum(active) FROM push_events").fetchone()[0], 1)

    async def test_phone_choice_reply_clear_and_ready_resume_without_granting_consent(self):
        self.project(self.ticket())
        followup = await self.submit("可以，只读")
        trigger = self.gateway.bridge.db.execute("SELECT * FROM triggers WHERE run_id=?", (followup["run_id"],)).fetchone()
        self.assertIn("可以，只读", trigger["text"])
        self.assertEqual(self.state()[0], "waiting_for_input")
        self.assertFalse((self.data / "access/devices.sqlite3").exists())
        for action, ended in (("running", None), ("review", None), ("completed", {"outcome": "completed"})):
            with self.subTest(action=action):
                with self.gateway.bridge.db:
                    self.gateway.bridge.db.execute("UPDATE chat_runs SET status='waiting_for_input',wait_reason='clarify' WHERE run_id=?",
                                                   (self.turn["run_id"],))
                self.project(self.ticket(attention=None, action=action, ended=ended))
                self.assertEqual(tuple(self.state()), ("started", None))
        result = await self.outbound(self.ticket(attention=None), id="result", text="已核对会议记录。")
        self.assertEqual(result.status, 200)
        self.assertEqual(tuple(self.state()), ("completed", None))
        self.assertEqual(len(await self.messages()), 2)

    async def test_https_consent_is_preserved_and_actionable_on_both_devices(self):
        url = "https://consent.example.test/authorize?scope=read&state=fixture"
        self.project(self.ticket(f"【手机可完成·服务授权】请在[服务授权页面]({url})同意只读日历权限。"))
        message = (await self.messages())[0]
        self.assertEqual(message["confirmation"], {"device": "phone", "kind": "service_consent", "urls": [url]})
        self.assertIn(f"]({url})", message["content"])
        self.assertIn("iPhone 或 Mac", message["content"])
        self.assertIn("聊天回复不代替服务授权", message["content"])
        self.assertEqual(self.state()[0], "waiting_for_input")
        # iPhone and Mac use this same Markdown renderer and ChatWebCoordinator HTTPS opener.
        script = """
const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const context = vm.createContext({Intl, console});
const root = process.argv[1] + '/Apps/iPhoneApp/Features/Assistant/Rendering/Web/';
for (const file of ['vendor/marked.js', 'vendor/remend.js', 'chat-core.js'])
  vm.runInContext(fs.readFileSync(root + file, 'utf8'), context);
context.MoMoChatCore.installRecordingSourceLinks(context.marked);
const message = JSON.parse(fs.readFileSync(0, 'utf8'));
const html = context.marked.parse(message.content);
assert.ok(html.includes('href="' + message.confirmation.urls[0].replaceAll('&', '&amp;') + '"'));
assert.ok(html.includes('服务授权页面</a>'));
"""
        subprocess.run(["node", "-e", script, str(ROOT)], input=json.dumps(message), text=True,
                       capture_output=True, check=True)

    async def test_mac_accessibility_and_other_local_actions_never_become_phone_consent(self):
        for index, action in enumerate(("辅助功能", "屏幕录制", "安装", "交还电脑")):
            ticket = self.ticket(f"【需要 Mac 操作】请在 Mac 上为 MoMo Agent 完成{action}；这仅用于本次桌面操作。",
                                 attention={"id": f"q{index}", "triggerId": self.trigger_id,
                                            "question": f"【需要 Mac 操作】请在系统设置检查 MoMo Agent 的{action}，仅用于桌面操作。"})
            with patch("superagent_gateway.SuperAgentComputer.call", side_effect=AssertionError("No remote permission action")):
                self.project(ticket)
            message = (await self.messages())[-1]
            self.assertEqual(message["confirmation"], {"device": "mac", "kind": "local_action"})
            self.assertIn("运行 MoMo Agent 的 Mac", message["content"])
            self.assertIn("手机回复不能开启 Mac", message["content"])
        self.assertEqual(len(await self.messages()), 4)

    async def test_replay_new_runtime_id_and_restart_do_not_repeat(self):
        ticket = self.ticket()
        self.project(ticket)
        original = (await self.messages())[0]["id"]
        self.project(ticket)
        self.assertEqual((await self.outbound(ticket)).status, 200)
        await self.restart()
        ticket["attention"]["id"] = "regenerated-on-recovery"
        self.project(ticket)
        response = await self.outbound(ticket)
        self.assertTrue((await response.json())["duplicate"])
        self.assertEqual([row["id"] for row in await self.messages()], [original])
        self.assertEqual(self.count("push_events"), 1)

    async def test_meaningful_question_device_or_link_update_notifies(self):
        questions = ["【手机可完成·聊天回复】选 A 还是 B？", "【手机可完成·聊天回复】选 A 还是 C？",
                     "【需要 Mac 操作】请在本机确认 A。",
                     "【手机可完成·服务授权】[授权](https://service.example.test/consent/one)",
                     "【手机可完成·服务授权】[授权](https://service.example.test/consent/two)"]
        for question in questions:
            ticket = self.ticket(question)  # Even a legacy producer reusing the attention ID.
            self.project(ticket)
            self.project(ticket)
        self.assertEqual(len(await self.messages()), 5)
        self.assertEqual(self.count("push_events"), 5)
        self.assertEqual(self.gateway.store.db.execute("SELECT sum(active) FROM push_events").fetchone()[0], 1)

    async def test_failed_append_and_failed_push_enqueue_retry_across_restart(self):
        ticket = self.ticket()
        with patch.object(self.gateway.store, "append_assistant", side_effect=OSError("fixture write failure")):
            with self.assertLogs("momo.superagent_gateway", level="ERROR"):
                self.project(ticket)
        self.assertEqual(len(await self.messages()), 0)
        with patch.object(self.gateway.push, "emit", side_effect=OSError("fixture push enqueue failure")):
            with self.assertLogs("momo.superagent_gateway", level="ERROR"):
                self.project(ticket)
        self.assertEqual(len(await self.messages()), 1)
        self.assertEqual(self.gateway.bridge.db.execute("SELECT count(*) FROM outbound_receipts").fetchone()[0], 0)
        await self.restart()
        self.project(ticket)
        self.project(ticket)
        self.assertEqual(len(await self.messages()), 1)
        self.assertEqual(self.count("push_events"), 1)
        self.assertEqual(self.state()[0], "waiting_for_input")

    async def test_push_provider_failure_retries_same_delivery_after_restart(self):
        provider = type("Provider", (), {"ready": True, "environment": "development", "topic": TOPIC})()
        provider.send = AsyncMock(return_value={"state": "retry", "retry_after": 1})
        provider.register = AsyncMock(return_value={"state": "accepted"})
        provider.check = AsyncMock(return_value=True)
        provider.close = AsyncMock()
        pairing = self.data / "access/devices.sqlite3"
        pairing.parent.mkdir(exist_ok=True)
        with closing(sqlite3.connect(pairing)) as db, db:
            db.execute("CREATE TABLE devices(id TEXT,state TEXT)")
            db.execute("INSERT INTO devices VALUES('fixture-phone','approved')")
        self.gateway.push.provider = provider
        self.gateway.push.register("fixture-phone", {"token": "a" * 64, "topic": TOPIC,
            "environment": "development", "registration_id": str(uuid.uuid4())})
        self.project(self.ticket())
        await self.gateway.push.tick()
        self.assertEqual(self.gateway.store.db.execute("SELECT state FROM notification_deliveries").fetchone()[0], "retry")
        first = provider.send.call_args.args[0]
        await self.restart()
        self.gateway.push.provider = provider
        provider.send.return_value = {"state": "accepted"}
        with self.gateway.store.db:
            self.gateway.store.db.execute("UPDATE notification_deliveries SET next_attempt=0")
        self.project(self.ticket())
        await self.gateway.push.tick()
        self.assertEqual(provider.send.await_count, 2)
        self.assertEqual(provider.send.call_args.args[0], first)
        self.assertEqual(self.count("notification_deliveries"), 1)

    async def test_inferred_attention_blocker_and_dropped_stay_silent(self):
        for changes in ({}, {"attention": None, "action": "blocked"},
                        {"attention": None, "action": "failed"},
                        {"attention": None, "ended": {"outcome": "dropped"}}):
            ticket = self.ticket(strength="inferred", **changes)
            self.project(ticket)
            response = await self.outbound(ticket, id=str(uuid.uuid4()))
            self.assertEqual(response.status, 410)
        self.assertEqual(await self.messages(), [])
        self.assertEqual(self.count("push_events"), 0)
        self.assertNotEqual(self.state()[0], "waiting_for_input")

    async def test_original_trigger_and_followup_attribution_are_not_latest_chat(self):
        other = await self.submit("另查今天日程")
        self.project(self.ticket())
        self.assertEqual((await self.messages())[0]["run_id"], self.turn["run_id"])
        followup_trigger = self.gateway.bridge.db.execute("SELECT id FROM triggers WHERE run_id=?", (other["run_id"],)).fetchone()[0]
        ticket = self.ticket(attention={"id": "followup", "triggerId": followup_trigger,
                                       "question": "【手机可完成·聊天回复】只看今天还是本周？"})
        self.project(ticket)
        self.assertEqual((await self.messages())[-1]["run_id"], other["run_id"])
        ticket["attention"]["triggerId"] = "momo:missing-origin"
        self.project(ticket)
        self.assertEqual(len(await self.messages()), 2)

    async def test_legacy_metadata_missing_connector_and_invalid_links_are_not_guessed(self):
        for question in ("尚未接入邮件连接器，可以先整理现有资料吗？", "请在 Mac 开启辅助功能。"):
            self.project(self.ticket(question))
            message = (await self.messages())[-1]
            self.assertEqual(message["content"], question)
            self.assertEqual(message["confirmation"], {"device": "unspecified", "kind": "legacy"})
        for link in ("", "http://service.example.test/auth", "https://localhost/auth", "https://127.0.0.1/auth"):
            self.project(self.ticket(f"【手机可完成·服务授权】当前缺少服务入口。{link}"))
            message = (await self.messages())[-1]
            self.assertEqual(message["confirmation"]["kind"], "missing_consent_link")
            self.assertNotIn("【手机可完成", message["content"])
            self.assertNotIn("confirmation_json", message)

    async def test_legacy_receipt_adopted_and_missing_push_repaired(self):
        ticket = self.ticket("可以只读吗？")
        key = hashlib.sha256(b'["attention-reply","question"]').hexdigest()[:32]
        message_id = self.gateway.store.append_assistant("superagent:" + key, ticket["attention"]["question"], 1,
                                                       run_id=self.turn["run_id"])
        with self.gateway.bridge.db:
            self.gateway.bridge.db.execute("INSERT INTO outbound_receipts VALUES(?,?,?,?,?,?)",
                (key, "reply", "chat:" + self.turn["work_id"], "ticket", message_id, 1))
            self.gateway.bridge.db.execute("UPDATE chat_runs SET status='completed',ticket_id='ticket'")
        self.project(ticket)
        await self.restart()
        self.project(ticket)
        self.assertEqual([row["id"] for row in await self.messages()], [message_id])
        self.assertEqual(self.count("push_events"), 1)
        self.assertEqual(self.state()[0], "waiting_for_input")

    async def test_cleared_attention_rejects_delayed_outbox_without_reopening(self):
        ticket = self.ticket()
        self.project(ticket)
        self.project(self.ticket(attention=None, action="running"))
        self.assertEqual((await self.outbound(ticket)).status, 410)
        self.assertEqual(tuple(self.state()), ("started", None))
        self.assertEqual(len(await self.messages()), 1)
        self.assertEqual(self.gateway.store.db.execute("SELECT active FROM push_events").fetchone()[0], 0)

    async def test_live_outbox_before_snapshot_and_unavailable_state_retry(self):
        ticket = self.ticket()
        with patch.object(self.gateway, "manage_dsh", True):
            self.assertEqual((await self.outbound(ticket)).status, 503)
        self.assertEqual(await self.messages(), [])
        self.gateway.dsh_ready = True
        with patch.object(self.gateway, "_computer_ticket", AsyncMock(return_value=ticket)) as read:
            self.assertEqual((await self.outbound(ticket)).status, 200)
            read.assert_awaited_once_with("ticket")
        self.project(ticket)
        self.assertEqual(len(await self.messages()), 1)
        with patch.object(self.gateway, "_computer_ticket", AsyncMock(return_value=self.ticket(strength="inferred"))):
            self.assertEqual((await self.outbound(ticket)).status, 410)
        self.gateway.dsh_ready = False

    async def test_omitted_question_source_uses_mandate_not_latest_thread(self):
        other = await self.submit("另一个任务")
        summary = self.ticket(attention={"id": "question", "question": "【手机可完成·聊天回复】选 A 还是 B？"})
        detail = {**summary, "mandate": {"strength": "explicit", "basis": {"triggerId": self.trigger_id}}}
        def fetch(port, method, path, **kwargs):
            if path.endswith("state=open&limit=30"):
                return {"items": [summary]}
            if path.endswith("/tickets/ticket"):
                return detail
            return {"items": []}
        with patch("superagent_gateway.dsh_api_request", side_effect=fetch):
            self.gateway._apply_dsh_projections(*self.gateway._fetch_dsh_snapshots())
        self.assertEqual((await self.messages())[0]["run_id"], self.turn["run_id"])
        self.assertNotEqual((await self.messages())[0]["run_id"], other["run_id"])

    async def test_snapshot_pages_reach_older_pending_confirmation(self):
        calls = []
        def fetch(port, method, path, **kwargs):
            calls.append(path)
            if path.endswith("state=open&limit=30"):
                return {"items": [{"id": "other", "state": "open"}], "next_offset": 30}
            if "offset=30" in path:
                return {"items": [self.ticket()], "next_offset": None}
            return {"items": []}
        with patch("superagent_gateway.dsh_api_request", side_effect=fetch):
            self.gateway._apply_dsh_projections(*self.gateway._fetch_dsh_snapshots())
        self.assertTrue(any("offset=30" in path for path in calls))
        self.assertEqual(len(await self.messages()), 1)

    async def test_ready_outside_recent_ended_page_clears_persisted_wait(self):
        self.project(self.ticket())
        ready = self.ticket(attention=None, state="ended", ended={"outcome": "completed"})
        def fetch(port, method, path, **kwargs):
            return ready if path.endswith("/tickets/ticket") else {"items": []}
        await self.restart()
        with patch("superagent_gateway.dsh_api_request", side_effect=fetch):
            self.gateway._apply_dsh_projections(*self.gateway._fetch_dsh_snapshots())
        self.assertEqual(tuple(self.state()), ("started", None))
        self.assertEqual(len(await self.messages()), 1)
        self.assertEqual(self.gateway.store.db.execute("SELECT active FROM push_events").fetchone()[0], 0)


if __name__ == "__main__":
    unittest.main()
