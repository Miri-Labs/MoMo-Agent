"""Unit tests for read-only Feishu personal OAuth & Generic IMAP Email connectors."""
from __future__ import annotations

from email.message import EmailMessage
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[2]
for rel in ("Apps/MacApp/Context", "Apps/MacApp/Runtime"):
    p = str(ROOT / rel)
    if p not in sys.path:
        sys.path.insert(0, p)

import connectors
from context_store import ContextStore
from memory_search import MemorySearch


class _FakeIMAP:
    def __init__(self, messages: dict[bytes, bytes]):
        self.messages = messages
        self.readonly_selected = False

    def select(self, folder="INBOX", readonly=False):
        self.readonly_selected = bool(readonly)
        return "OK", [str(len(self.messages)).encode()]

    def uid(self, command, *args):
        cmd = command.lower()
        if cmd == "search":
            return "OK", [b" ".join(self.messages.keys())]
        if cmd == "fetch":
            uid = args[0]
            raw = self.messages.get(uid)
            if raw is None:
                return "NO", []
            return "OK", [(b"1 (BODY[] {100})", raw)]
        return "NO", []

    def logout(self):
        return "BYE", []


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

    def test_imap_readonly_sync_decodes_chinese_and_indexes_into_memory_search(self):
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

        fake = _FakeIMAP({b"101": msg.as_bytes(), b"102": msg_html.as_bytes()})
        connectors.save_connectors_config(
            self.data,
            {
                "email": {
                    "preset": "gmail",
                    "host": "imap.gmail.com",
                    "port": 993,
                    "username": "owner@example.com",
                    "password": "super-secret-app-password",
                    "folder": "INBOX",
                    "sync_days": 7,
                    "enabled": True,
                    "connected": True,
                },
                "feishu": {},
            },
        )

        res = connectors.sync_email_connector(self.data, self.store, imap_factory=lambda *_: fake)
        self.assertTrue(fake.readonly_selected)
        self.assertEqual(res["synced"], 2)
        self.assertEqual(res["changed"], 2)

        # Second sync is idempotent (0 changed)
        res2 = connectors.sync_email_connector(self.data, self.store, imap_factory=lambda *_: fake)
        self.assertEqual(res2["changed"], 0)

        # Status never leaks password
        status = connectors.connectors_status(self.data, self.store)
        serialized = json.dumps(status, ensure_ascii=False)
        self.assertNotIn("super-secret-app-password", serialized)
        self.assertEqual(status["connectors"]["email"]["item_count"], 2)
        self.assertTrue(status["connectors"]["email"]["has_password"])

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

    def test_infer_email_preset_from_domain(self):
        self.assertEqual(connectors.infer_email_preset("alice@gmail.com"), "gmail")
        self.assertEqual(connectors.infer_email_preset("bob@qq.com"), "qq")
        self.assertEqual(connectors.infer_email_preset("carol@icloud.com"), "icloud")
        self.assertEqual(connectors.infer_email_preset("dave@163.com"), "163")
        self.assertEqual(connectors.infer_email_preset("erin@feishu.cn"), "feishu_mail")
        self.assertEqual(connectors.infer_email_preset("frank@custom-corp.io"), "custom")

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


if __name__ == "__main__":
    unittest.main()
