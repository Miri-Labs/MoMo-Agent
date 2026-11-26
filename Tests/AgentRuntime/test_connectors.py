"""Unit tests for read-only Feishu personal OAuth & Composio email connectors."""
from __future__ import annotations

from email.message import EmailMessage
import base64
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit
from urllib.error import HTTPError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[2]
for rel in ("Apps/MacApp/Context", "Apps/MacApp/Runtime"):
    p = str(ROOT / rel)
    if p not in sys.path:
        sys.path.insert(0, p)

import composio_mail
import connectors
from context_server import ContextService
from context_store import ContextStore
from memory_search import MemorySearch


class ConnectorsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.data = Path(self.tmp.name) / "Agent"
        (self.data / "context").mkdir(parents=True)
        (self.data / "hermes/memories").mkdir(parents=True)
        self.store = ContextStore(self.data / "context")

    def tearDown(self) -> None:
        connectors._FEISHU_OAUTH.stop()
        self.store.close()
        self.tmp.cleanup()

    def test_gmail_readonly_sync_decodes_chinese_and_indexes_into_memory_search(self):
        msg = EmailMessage()
        msg["Subject"] = "季度复盘会议纪要 - 浦东办公室"
        msg["From"] = "Alice <alice@example.com>"
        msg["To"] = "owner@example.com"
        msg["Message-ID"] = "<msg-q4-review@example.com>"
        msg["Date"] = "Thu, 19 Nov 2026 09:30:00 +0800"
        msg.set_content("请在下周五前确认预算方案，关键代号：ALPHA-QUARTZ-77。")

        msg_html = EmailMessage()
        msg_html["Subject"] = "航班确认单"
        msg_html["From"] = "Airline <notify@airline.example>"
        msg_html["Message-ID"] = "<msg-flight@example.com>"
        msg_html.add_alternative("<html><body><p>航班号 MU5101 已出票</p></body></html>", subtype="html")

        cfg = {"mode": "composio", "provider": "gmail", "user_id": "owner", "account_id": "account",
               "api_key": "test-project-key", "account_label": "owner@example.com", "enabled": True, "connected": True}
        connectors.save_connectors_config(self.data, {"email": cfg, "feishu": {}})
        messages = {"101": msg, "102": msg_html}

        fetched = []
        internal_date = str(int(time.time() * 1000))

        def proxy(key, path, *, method, body):
            self.assertEqual(body["method"], "GET")
            self.assertEqual(path, "/tools/execute/proxy")
            message_id = body["endpoint"].rsplit("/", 1)[1]
            if message_id == "messages":
                return {"status": 200, "data": {"messages": [{"id": i} for i in messages]}}
            self.assertEqual(body["parameters"][0]["value"], "full")
            fetched.append(message_id)
            msg = messages[message_id]
            part = msg.get_body()
            raw = base64.urlsafe_b64encode(part.get_payload(decode=True)).decode()
            payload = {"headers": [{"name": k, "value": str(v)} for k, v in msg.items()],
                       "parts": [{"mimeType": part.get_content_type(), "body": {"data": raw}},
                                 {"filename": "attachment.txt", "mimeType": "text/plain", "body": {"attachmentId": "id"}}]}
            return {"status": 200, "data": {"internalDate": internal_date, "payload": payload, "threadId": message_id}}

        with patch.object(composio_mail, "request", side_effect=proxy):
            res = connectors.sync_email_connector(self.data, self.store)
            self.assertEqual(res["synced"], 2)
            self.assertEqual(res["changed"], 2)
            self.assertEqual(connectors.sync_email_connector(self.data, self.store)["changed"], 0)
        status = connectors.connectors_status(self.data, self.store)
        self.assertEqual(fetched, ["101", "102"])
        self.assertNotIn("test-project-key", json.dumps(status))
        self.assertEqual(status["connectors"]["email"]["item_count"], 2)

        # Indexed into unified memory_search and readable via read_evidence
        searcher = MemorySearch(self.data)
        found = searcher.search("ALPHA-QUARTZ-77", kind="connector")
        self.assertEqual(len(found["matches"]), 1)
        hit = found["matches"][0]
        self.assertEqual(hit["connector"], "email")
        evidence = searcher.read(hit["id"], hit["revision"])
        self.assertIn("浦东办公室", evidence["text"])
        self.assertIn("ALPHA-QUARTZ-77", evidence["text"])

        # HTML-only email stripped cleanly
        found_flight = searcher.search("MU5101", kind="connector")
        self.assertEqual(len(found_flight["matches"]), 1)

    def test_upgrade_removes_legacy_password_and_keeps_existing_items(self):
        connectors.save_connectors_config(self.data, {
            "email": {"connected": True, "password": "old-value"}, "feishu": {"domain": "lark"}})
        connectors._upsert_connector_item(self.store, item_id="email:historical", connector="email",
            item_type="email", thread_id="1", title="旧邮件", sender="", channel="", content="旧邮件", occurred_at=1)
        status = connectors.connectors_status(self.data, self.store)["connectors"]
        self.assertFalse(status["email"]["connected"])
        self.assertTrue(status["email"]["needs_reconnect"])
        self.assertEqual(status["email"]["item_count"], 1)
        self.assertNotIn("old-value", connectors._config_path(self.data).read_text())
        self.assertEqual(status["feishu"]["domain"], "lark")

    def test_outlook_connect_resume_import_and_revoke(self):
        responses = []
        def request(key, path, *, method="GET", body=None, missing_ok=False):
            self.assertEqual(key, "project-key")
            responses.append((method, path))
            if path == "/auth_configs":
                self.assertEqual(body["auth_config"]["credentials"]["scopes"], "offline_access,User.Read,Mail.Read")
                return {"auth_config": {"id": "ac_test"}}
            if path == "/connected_accounts/link":
                self.user_id = body["user_id"]
                return {"connected_account_id": "ca_test", "redirect_url": "https://connect.composio.dev/test"}
            if path == "/connected_accounts/ca_test":
                if method == "DELETE":
                    return {}
                return {"status": self.remote_state, "user_id": self.user_id, "toolkit": {"slug": "outlook"},
                        "auth_config": {"id": "ac_test"}}
            self.assertEqual(path, "/tools/execute/proxy")
            self.assertEqual(body["method"], "GET")
            if body["endpoint"] == "/v1.0/me":
                return {"status": 200, "data": {"mail": "me@example.com"}}
            self.assertEqual(body["endpoint"], "/v1.0/me/mailFolders/inbox/messages")
            return {"status": 200, "data": {"value": [{"id": "msg", "internetMessageId": "<msg@example.com>",
                "conversationId": "thread", "subject": "预算", "receivedDateTime": "2026-11-22T15:03:11Z",
                "from": {"emailAddress": {"address": "me@example.com"}},
                "body": {"contentType": "html", "content": "<p>Q4 预算</p>"}}]}}

        with patch.object(composio_mail, "request", side_effect=request):
            args = {"provider": "outlook", "api_key": "project-key"}
            link = connectors.start_email_oauth(self.data, args)
            self.assertEqual(connectors.start_email_oauth(self.data, args), link)
            self.assertEqual(responses.count(("POST", "/connected_accounts/link")), 1)
            self.remote_state = "INITIATED"
            self.assertTrue(connectors.refresh_email_oauth(self.data)["pending"])
            self.remote_state = "ACTIVE"
            self.assertTrue(connectors.refresh_email_oauth(self.data)["connected"])
            self.assertEqual(connectors.sync_email_connector(self.data, self.store)["changed"], 1)
            connectors.disconnect_connector(self.data, self.store, "email")
            self.assertIn(("DELETE", "/connected_accounts/ca_test"), responses)
            state = connectors.connectors_status(self.data, self.store)["connectors"]["email"]
            self.assertFalse(state["connected"])
            self.assertEqual(state["item_count"], 1)

    def test_http_pending_denial_retry_and_failed_disconnect(self):
        (self.data / "api-key").write_text("test-local-key")
        service = ContextService(self.data, {"data_url": "http://127.0.0.1:0", "workspace_id": "test"})
        service.threads[0].start()
        self.addCleanup(service.close)
        base = f"http://127.0.0.1:{service.server.server_port}/v1/connectors"

        def call(path="", payload=None):
            req = Request(base + path, data=None if payload is None else json.dumps(payload).encode(),
                          headers={"Authorization": "Bearer test-local-key", "Content-Type": "application/json"})
            with urlopen(req) as response:
                return json.load(response)

        args = {"provider": "gmail", "api_key": "test-project"}
        with patch.object(composio_mail, "create_config", return_value="config"), patch.object(
            composio_mail, "link", return_value={"redirect_url": "https://connect.composio.dev/test",
                                                "connected_account_id": "account"}):
            call("/email/oauth/start", args)
            self.assertTrue(call()["connectors"]["email"]["pending"])
            with patch.object(composio_mail, "status", return_value="FAILED"), patch.object(composio_mail, "revoke"):
                with self.assertRaises(HTTPError) as denied:
                    call("/email/oauth/check", {})
                self.assertEqual(denied.exception.code, 400)
                denied.exception.close()
            self.assertFalse(call()["connectors"]["email"]["pending"])
            call("/email/oauth/start", args)
            with patch.object(composio_mail, "revoke", side_effect=connectors.ConnectorError("服务暂不可用")):
                with self.assertRaises(HTTPError) as unavailable:
                    call("/disconnect", {"connector": "email"})
                unavailable.exception.close()
                self.assertTrue(call()["connectors"]["email"]["pending"])
            with self.assertRaises(HTTPError) as removed:
                call("/email/configure", {})
            self.assertEqual(removed.exception.code, 404)
            removed.exception.close()

    def test_feishu_oauth_start_token_refresh_and_sync_chats_plus_docs(self):
        started = connectors.start_feishu_oauth(
            self.data,
            {"app_id": "cli_test_app", "app_secret": "sec_test_secret", "domain": "feishu"},
        )
        parsed = urlsplit(started["authorize_url"])
        self.assertEqual(parsed.hostname, "accounts.feishu.cn")
        qs = parse_qs(parsed.query)
        self.assertEqual(qs["client_id"], ["cli_test_app"])
        self.assertIn("im:message:readonly", qs["scope"][0])
        self.assertIn("im:message.group_msg:get_as_user", qs["scope"][0])
        self.assertIn("im:message.p2p_msg:get_as_user", qs["scope"][0])
        self.assertIn("search:message", qs["scope"][0])
        self.assertIn("docx:document:readonly", qs["scope"][0])
        connectors._FEISHU_OAUTH.stop()

        # Simulate connected Feishu account with expired access token requiring refresh
        connectors.save_connectors_config(
            self.data,
            {
                "email": {},
                "feishu": {
                    "domain": "feishu",
                    "app_id": "cli_test_app",
                    "app_secret": "sec_test_secret",
                    "access_token": "expired_tok",
                    "refresh_token": "ref_tok_1",
                    "expires_at": time.time() - 60,
                    "user_name": "测试主人",
                    "enabled": True,
                    "connected": True,
                },
            },
        )

        def fake_http(url, *, method="GET", headers=None, body=None, timeout=20.0):
            if url.endswith("/open-apis/authen/v2/oauth/token"):
                self.assertEqual(body["grant_type"], "refresh_token")
                return {"code": 0, "access_token": "fresh_tok_2", "refresh_token": "ref_tok_2", "expires_in": 7200}
            self.assertEqual(headers["Authorization"], "Bearer fresh_tok_2")
            if "/open-apis/im/v1/chats" in url:
                return {"code": 0, "data": {"items": [{"chat_id": "oc_1", "name": "产品核心群"}]}}
            if "/open-apis/search/v2/message" in url:
                return {"code": 0, "data": {"items": ["om_p2p_1"]}}
            if url.endswith("/open-apis/im/v1/messages/om_p2p_1"):
                return {"code": 0, "data": {"items": [{"message_id": "om_p2p_1", "chat_id": "oc_p2p_9"}]}}
            if "/open-apis/im/v1/messages" in url:
                if "container_id=oc_p2p_9" in url:
                    return {
                        "code": 0,
                        "data": {
                            "items": [
                                {
                                    "message_id": "om_p2p_1",
                                    "msg_type": "text",
                                    "create_time": str(int(time.time() * 1000)),
                                    "sender": {"id": "ou_boss"},
                                    "body": {"content": json.dumps({"text": "私聊同步验证：明天下午三点单聊对齐"})},
                                }
                            ]
                        },
                    }
                return {
                    "code": 0,
                    "data": {
                        "items": [
                            {
                                "message_id": "om_100",
                                "msg_type": "text",
                                "create_time": str(int(time.time() * 1000)),
                                "sender": {"id": "ou_pm"},
                                "body": {"content": json.dumps({"text": "下周二发布 MoMo Connectors 首期"})},
                            }
                        ]
                    },
                }
            if "/open-apis/drive/v1/files" in url:
                if "folder_token=fld_sub" in url:
                    return {
                        "code": 0,
                        "data": {
                            "files": [
                                {
                                    "token": "doxcn_sub",
                                    "type": "docx",
                                    "name": "子目录需求文档",
                                    "url": "https://feishu.cn/docx/doxcn_sub",
                                    "modified_time": str(int(time.time())),
                                }
                            ]
                        },
                    }
                return {
                    "code": 0,
                    "data": {
                        "files": [
                            {
                                "token": "doxcn_abc",
                                "type": "docx",
                                "name": "Q4 Roadmap",
                                "url": "https://feishu.cn/docx/doxcn_abc",
                                "modified_time": str(int(time.time())),
                            },
                            {
                                "token": "fld_sub",
                                "type": "folder",
                                "name": "产品资料",
                            },
                        ]
                    },
                }
            if "/open-apis/docx/v1/documents/doxcn_abc/raw_content" in url:
                return {"code": 0, "data": {"content": "核心里程碑：飞书个人只读同步上线。"}}
            if "/open-apis/docx/v1/documents/doxcn_sub/raw_content" in url:
                return {"code": 0, "data": {"content": "子目录文档正文：支持私聊与子目录。"}}
            raise AssertionError(f"Unexpected URL: {url}")

        res = connectors.sync_feishu_connector(self.data, self.store, http_fn=fake_http)
        self.assertEqual(res["synced"], 4)
        self.assertEqual(res["changed"], 4)

        # Verify secrets are redacted from status
        st = connectors.connectors_status(self.data, self.store)
        raw_st = json.dumps(st, ensure_ascii=False)
        self.assertNotIn("sec_test_secret", raw_st)
        self.assertNotIn("fresh_tok_2", raw_st)
        self.assertNotIn("ref_tok_2", raw_st)
        self.assertEqual(st["connectors"]["feishu"]["item_count"], 4)

        # Verify digest & search (group + P2P private chat + root doc + subfolder doc)
        digest = connectors.recent_connector_digest(self.store, hours=24.0, limit=10)
        self.assertEqual(len(digest), 4)
        searcher = MemorySearch(self.data)
        self.assertEqual(len(searcher.search("Connectors 首期", kind="connector")["matches"]), 1)
        self.assertEqual(len(searcher.search("单聊对齐", kind="connector")["matches"]), 1)
        self.assertEqual(len(searcher.search("Q4 Roadmap", kind="connector")["matches"]), 1)
        sub_hits = searcher.search("子目录需求", kind="connector")["matches"]
        self.assertTrue(any("doxcn_sub" in m["id"] for m in sub_hits))

        # Disconnect with clear_data removes mirrored items
        disc = connectors.disconnect_connector(self.data, self.store, "feishu", clear_data=True)
        self.assertEqual(disc["removed_items"], 4)
        self.assertEqual(connectors.connectors_status(self.data, self.store)["connectors"]["feishu"]["item_count"], 0)

    def test_feishu_bot_filtering_thread_grouping_mute_and_live_read_tools(self):
        connectors.save_connectors_config(
            self.data,
            {
                "email": {},
                "feishu": {
                    "domain": "feishu",
                    "app_id": "cli_test_app",
                    "app_secret": "sec_test_secret",
                    "access_token": "tok_live",
                    "refresh_token": "ref_live",
                    "expires_at": time.time() + 3600,
                    "user_name": "测试主人",
                    "enabled": True,
                    "connected": True,
                },
            },
        )
        now = time.time()
        # Seed a legacy bot alert card that should be purged automatically on sync
        connectors._upsert_connector_item(
            self.store,
            item_id="feishu:msg:om_legacy_bot",
            connector="feishu",
            item_type="feishu_message",
            thread_id="oc_alert",
            title="告警群 · 生产告警",
            sender="cli_alert_bot",
            channel="告警群",
            content="[告警群] 生产告警",
            occurred_at=now - 30,
            metadata={"chat_id": "oc_alert", "msg_type": "interactive", "sender_type": "app"},
        )

        def fake_http(url, *, method="GET", headers=None, body=None, timeout=20.0):
            if "/open-apis/im/v1/chats" in url:
                return {"code": 0, "data": {"items": [{"chat_id": "oc_team", "name": "核心产品群"}]}}
            if "/open-apis/search/v2/message" in url:
                return {"code": 0, "data": {"items": ["om_h1"]}}
            if url.endswith("/open-apis/im/v1/messages/om_h1"):
                return {
                    "code": 0,
                    "data": {
                        "items": [
                            {
                                "message_id": "om_h1",
                                "chat_id": "oc_team",
                                "msg_type": "text",
                                "create_time": str(int((now - 60) * 1000)),
                                "sender": {"id": "ou_alice", "sender_type": "user"},
                                "body": {"content": json.dumps({"text": "明天三点评审"})},
                            }
                        ]
                    },
                }
            if "/open-apis/im/v1/messages" in url:
                return {
                    "code": 0,
                    "data": {
                        "items": [
                            {
                                "message_id": "om_bot_1",
                                "msg_type": "interactive",
                                "create_time": str(int((now - 10) * 1000)),
                                "sender": {"id": "cli_deploy_bot", "sender_type": "app"},
                                "body": {"content": json.dumps({"title": "生产部署成功"})},
                            },
                            {
                                "message_id": "om_h2",
                                "msg_type": "text",
                                "create_time": str(int((now - 20) * 1000)),
                                "sender": {"id": "ou_alice", "sender_type": "user"},
                                "body": {"content": json.dumps({"text": "记得带上最新报价单"})},
                            },
                            {
                                "message_id": "om_h1",
                                "msg_type": "text",
                                "create_time": str(int((now - 60) * 1000)),
                                "sender": {"id": "ou_alice", "sender_type": "user"},
                                "body": {"content": json.dumps({"text": "明天三点评审"})},
                            },
                        ]
                    },
                }
            if "/open-apis/drive/v1/files" in url:
                return {"code": 0, "data": {"files": []}}
            if url.endswith("/open-apis/docx/v1/documents/doxcnLive12345"):
                return {"code": 0, "data": {"document": {"title": "实时文档标题"}}}
            if url.endswith("/open-apis/docx/v1/documents/doxcnLive12345/raw_content"):
                return {"code": 0, "data": {"content": "这是实时拉取的飞书文档正文。"}}
            raise AssertionError(f"Unexpected URL: {url}")

        res = connectors.sync_feishu_connector(self.data, self.store, http_fn=fake_http)
        self.assertEqual(res["purged_bots"], 1)
        self.assertEqual(res["synced"], 2)  # Only 2 human messages, bot message skipped

        # Digest groups the 2 messages in oc_team into 1 chronological thread entry
        digest = connectors.recent_connector_digest(self.store, hours=24.0, limit=10)
        self.assertEqual(len(digest), 1)
        self.assertEqual(digest[0]["message_count"], 2)
        self.assertIn("明天三点评审", digest[0]["preview"])
        self.assertIn("记得带上最新报价单", digest[0]["preview"])

        # Live read tools work in real time
        doc = connectors.read_feishu_doc_live(self.data, "https://example.feishu.cn/docx/doxcnLive12345?from=copy", http_fn=fake_http)
        self.assertEqual(doc["title"], "实时文档标题")
        self.assertIn("实时拉取", doc["content"])

        thread = connectors.read_feishu_thread_live(self.data, "oc_team", http_fn=fake_http)
        self.assertEqual(thread["count"], 2)
        self.assertEqual(thread["messages"][0]["text"], "明天三点评审")
        self.assertEqual(thread["messages"][1]["text"], "记得带上最新报价单")

        searched = connectors.search_feishu_live(self.data, "评审", http_fn=fake_http)
        self.assertEqual(searched["count"], 1)
        self.assertEqual(searched["matches"][0]["chat_id"], "oc_team")

        # Muting removes cached items and skips future sync
        muted = connectors.mute_connector_channel(self.data, self.store, "feishu", "核心产品群", mute=True)
        self.assertEqual(muted["removed_items"], 2)
        res_after_mute = connectors.sync_feishu_connector(self.data, self.store, http_fn=fake_http)
        self.assertEqual(res_after_mute["synced"], 0)

    def test_self_attribution_and_dynamic_connector_policy_engine(self):
        now = time.time()
        connectors.save_connectors_config(
            self.data,
            {
                "email": {},
                "feishu": {
                    "domain": "feishu",
                    "app_id": "cli_test",
                    "app_secret": "sec_test",
                    "access_token": "tok",
                    "refresh_token": "ref",
                    "expires_at": now + 3600,
                    "open_id": "ou_owner_me",
                    "user_name": "税昀昊",
                    "enabled": True,
                    "connected": True,
                },
            },
        )
        # Seed cached Feishu message sent by owner (before backfill) + marketing & VIP emails
        connectors._upsert_connector_item(
            self.store,
            item_id="feishu:msg:om_self_1",
            connector="feishu",
            item_type="feishu_message",
            thread_id="oc_dm_1",
            title="飞书私聊 · 这是我自己发给同事的",
            sender="ou_owner_me",
            channel="飞书私聊",
            content="[飞书私聊] 这是我自己发给同事的",
            occurred_at=now - 60,
            metadata={"chat_id": "oc_dm_1", "msg_type": "text", "sender_type": "user"},
        )
        connectors._upsert_connector_item(
            self.store,
            item_id="email:promo1",
            connector="email",
            item_type="email",
            thread_id="t1",
            title="限时折扣 5 折促销",
            sender="deals@promo.example",
            channel="me@gmail.com/INBOX",
            content="退订请点这里",
            occurred_at=now - 30,
            metadata={"account": "me@gmail.com"},
        )
        connectors._upsert_connector_item(
            self.store,
            item_id="email:bill1",
            connector="email",
            item_type="email",
            thread_id="t2",
            title="本月云服务账单",
            sender="billing@cloud.example",
            channel="me@gmail.com/INBOX",
            content="账单金额 100 元",
            occurred_at=now - 20,
            metadata={"account": "me@gmail.com"},
        )
        connectors._upsert_connector_item(
            self.store,
            item_id="email:vip1",
            connector="email",
            item_type="email",
            thread_id="t3",
            title="下周合作条款确认",
            sender="vip@partner.example",
            channel="me@gmail.com/INBOX",
            content="请确认最终条款",
            occurred_at=now - 100,
            metadata={"account": "me@gmail.com"},
        )

        # Backfill self-attribution on existing Feishu cache
        backfilled = connectors._backfill_feishu_self_attribution(self.store, "ou_owner_me", "税昀昊")
        self.assertEqual(backfilled, 1)
        item = connectors.read_connector_item(self.store, "feishu:msg:om_self_1")
        self.assertTrue(item["metadata"]["is_self"])
        self.assertEqual(item["sender"], "我（税昀昊）")
        self.assertIn("[我（税昀昊）]", item["content"])

        # Agent upserts 3 declarative policies: drop promo, archive_only billing, highlight VIP
        r_drop = connectors.upsert_connector_policy_rule(
            self.data,
            self.store,
            {"id": "drop-promo", "connector": "email", "action": "drop", "match": {"sender_contains": ["promo.example"]}},
        )
        self.assertGreaterEqual(r_drop["affected_cached_items"], 1)
        self.assertIsNone(connectors.read_connector_item(self.store, "email:promo1"))

        connectors.upsert_connector_policy_rule(
            self.data,
            self.store,
            {"id": "archive-billing", "connector": "email", "action": "archive_only", "match": {"sender_contains": ["billing@"]}},
        )
        connectors.upsert_connector_policy_rule(
            self.data,
            self.store,
            {"id": "vip-partner", "connector": "email", "action": "highlight", "match": {"sender_contains": ["vip@partner.example"]}},
        )

        # Digest excludes archive_only (bill1), excludes dropped (promo1), and boosts VIP (vip1) to #1 despite older timestamp!
        digest = connectors.recent_connector_digest(self.store, hours=24.0, limit=10)
        ids = [d["id"] for d in digest]
        self.assertNotIn("email:promo1", ids)
        self.assertNotIn("email:bill1", ids)
        self.assertEqual(ids[0], "email:vip1")
        self.assertTrue(digest[0]["highlighted"])

        # Policy stats & delete work cleanly
        stats = connectors.connector_policy_stats(self.data, self.store, days=7)
        self.assertGreaterEqual(stats["rule_count"], 5)
        deleted = connectors.delete_connector_policy_rule(self.data, self.store, "archive-billing")
        self.assertTrue(deleted["deleted"])


if __name__ == "__main__":
    unittest.main()
