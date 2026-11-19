"""Unified read-only external Connectors (Feishu personal OAuth & Generic IMAP Email) for MoMo Agent.

All synced items are stored locally in `context.sqlite` (`connector_items`), indexed into
`memory_search` (BM25 + RRF), and surfaced to Dream & Morning Briefing without ever
exposing credentials to the UI or LLM.
"""
from __future__ import annotations

from email import message_from_bytes
from email.header import decode_header, make_header
from email.utils import parsedate_to_datetime
import hashlib
from html.parser import HTMLParser
from http.server import BaseHTTPRequestHandler, HTTPServer
import imaplib
import json
import os
from pathlib import Path
import re
import secrets
import ssl
import threading
import time
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlencode, urlsplit
from urllib.request import Request, urlopen

CONNECTOR_KINDS = ("feishu", "email")
MAX_ITEM_CONTENT_CHARS = 16_000
DEFAULT_SYNC_DAYS = 7
DEFAULT_MAX_EMAILS = 80
DEFAULT_MAX_FEISHU_CHATS = 20
DEFAULT_MAX_FEISHU_MESSAGES_PER_CHAT = 20
DEFAULT_MAX_FEISHU_DOCS = 20

FEISHU_DOMAINS = {
    "feishu": {
        "label": "飞书 (中国大陆)",
        "auth_base": "https://accounts.feishu.cn",
        "api_base": "https://open.feishu.cn",
    },
    "lark": {
        "label": "Lark (海外)",
        "auth_base": "https://accounts.larksuite.com",
        "api_base": "https://open.larksuite.com",
    },
}

FEISHU_READONLY_SCOPES = (
    "im:chat:readonly "
    "im:message:readonly "
    "im:message.group_msg:get_as_user "
    "im:message.p2p_msg:get_as_user "
    "search:message "
    "docx:document:readonly "
    "drive:drive:readonly "
    "offline_access"
)

EMAIL_PRESETS: dict[str, dict[str, Any]] = {
    "gmail": {"label": "Gmail", "host": "imap.gmail.com", "port": 993, "note": "需使用 Google 应用专用密码"},
    "icloud": {"label": "iCloud 邮件", "host": "imap.mail.me.com", "port": 993, "note": "需使用 Apple ID 应用专用密码"},
    "outlook": {"label": "Outlook / Office 365", "host": "outlook.office365.com", "port": 993, "note": "需开启 IMAP 访问"},
    "qq": {"label": "QQ 邮箱", "host": "imap.qq.com", "port": 993, "note": "在 QQ 邮箱设置中开启 IMAP 并获取授权码"},
    "163": {"label": "网易 163 邮箱", "host": "imap.163.com", "port": 993, "note": "在 163 邮箱设置中开启 IMAP 并获取授权码"},
    "feishu_mail": {"label": "飞书邮箱", "host": "imap.feishu.cn", "port": 993, "note": "在飞书邮箱设置中生成第三方客户端专用密码"},
    "custom": {"label": "自定义 IMAP", "host": "", "port": 993, "note": "填写任意支持 IMAP over SSL (993) 的邮箱服务器"},
}


class ConnectorError(RuntimeError):
    """User-safe connector error message (never contains raw credentials)."""


class _HTMLTextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self._skip = 0
        self._parts: list[str] = []

    def handle_starttag(self, tag: str, attrs) -> None:
        t = tag.lower()
        if t in ("script", "style", "head"):
            self._skip += 1
        elif t in ("p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4"):
            self._parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() in ("script", "style", "head") and self._skip > 0:
            self._skip -= 1

    def handle_data(self, data: str) -> None:
        if self._skip == 0 and data:
            self._parts.append(data)

    def text(self) -> str:
        raw = "".join(self._parts)
        raw = re.sub(r"[ \t\r\f\v]+", " ", raw)
        raw = re.sub(r"\n{3,}", "\n\n", raw)
        return raw.strip()


def _html_to_text(html_str: str) -> str:
    parser = _HTMLTextExtractor()
    try:
        parser.feed(html_str or "")
        return parser.text()
    except Exception:
        return re.sub(r"<[^>]+>", " ", html_str or "").strip()


def _decode_mime_header(value: str | None) -> str:
    if not value:
        return ""
    try:
        return str(make_header(decode_header(value))).strip()
    except Exception:
        return str(value).strip()


def _extract_email_body(msg) -> str:
    plain_parts: list[str] = []
    html_parts: list[str] = []
    if msg.is_multipart():
        for part in msg.walk():
            if part.get_content_maintype() == "multipart":
                continue
            disp = str(part.get("Content-Disposition") or "").lower()
            if "attachment" in disp:
                continue
            ctype = str(part.get_content_type() or "").lower()
            payload = part.get_payload(decode=True)
            if not payload:
                continue
            charset = part.get_content_charset() or "utf-8"
            try:
                text = payload.decode(charset, errors="replace")
            except LookupError:
                text = payload.decode("utf-8", errors="replace")
            if ctype == "text/plain":
                plain_parts.append(text.strip())
            elif ctype == "text/html":
                html_parts.append(text)
    else:
        payload = msg.get_payload(decode=True)
        if payload:
            charset = msg.get_content_charset() or "utf-8"
            try:
                text = payload.decode(charset, errors="replace")
            except LookupError:
                text = payload.decode("utf-8", errors="replace")
            if str(msg.get_content_type() or "").lower() == "text/html":
                html_parts.append(text)
            else:
                plain_parts.append(text.strip())
    body = "\n\n".join(p for p in plain_parts if p).strip()
    if not body and html_parts:
        body = _html_to_text("\n".join(html_parts))
    return body[:MAX_ITEM_CONTENT_CHARS]


def _atomic_private_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.{secrets.token_hex(4)}.tmp")
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
        os.chmod(path, 0o600)
    except BaseException:
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass
        raise


def ensure_connector_tables(db) -> None:
    db.executescript(
        """
        CREATE TABLE IF NOT EXISTS connector_items (
            id TEXT PRIMARY KEY,
            connector TEXT NOT NULL,
            item_type TEXT NOT NULL,
            thread_id TEXT NOT NULL DEFAULT '',
            title TEXT NOT NULL DEFAULT '',
            sender TEXT NOT NULL DEFAULT '',
            channel TEXT NOT NULL DEFAULT '',
            content TEXT NOT NULL DEFAULT '',
            occurred_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            metadata TEXT NOT NULL DEFAULT '{}'
        );
        CREATE INDEX IF NOT EXISTS idx_connector_items_kind_time
            ON connector_items(connector, occurred_at DESC);
        """
    )


def _config_path(data_dir: Path) -> Path:
    return Path(data_dir) / "connectors" / "config.json"


_CONFIG_LOCK = threading.Lock()


def load_connectors_config(data_dir: Path) -> dict[str, Any]:
    path = _config_path(data_dir)
    if not path.is_file():
        return {"email": {}, "feishu": {}}
    try:
        parsed = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(parsed, dict):
            parsed.setdefault("email", {})
            parsed.setdefault("feishu", {})
            return parsed
    except (OSError, ValueError):
        pass
    return {"email": {}, "feishu": {}}


def save_connectors_config(data_dir: Path, config: dict[str, Any]) -> None:
    with _CONFIG_LOCK:
        _atomic_private_json(_config_path(data_dir), config)


def _update_connector_section(data_dir: Path, kind: str, updates: dict[str, Any]) -> dict[str, Any]:
    with _CONFIG_LOCK:
        cfg = load_connectors_config(data_dir)
        sec = dict(cfg.get(kind) or {})
        sec.update(updates)
        cfg[kind] = sec
        _atomic_private_json(_config_path(data_dir), cfg)
        return sec


def _upsert_connector_item(
    store,
    *,
    item_id: str,
    connector: str,
    item_type: str,
    thread_id: str,
    title: str,
    sender: str,
    channel: str,
    content: str,
    occurred_at: float,
    metadata: dict[str, Any] | None = None,
) -> bool:
    ensure_connector_tables(store.db)
    now = time.time()
    meta_json = json.dumps(metadata or {}, ensure_ascii=False, sort_keys=True)
    existing = store.db.execute(
        "SELECT title, sender, channel, content, occurred_at, metadata FROM connector_items WHERE id=?",
        (item_id,),
    ).fetchone()
    if (
        existing
        and existing["title"] == title
        and existing["sender"] == sender
        and existing["channel"] == channel
        and existing["content"] == content
        and abs(float(existing["occurred_at"]) - float(occurred_at)) < 1.0
        and existing["metadata"] == meta_json
    ):
        return False
    with store.write():
        store.db.execute(
            """
            INSERT INTO connector_items(id, connector, item_type, thread_id, title, sender, channel, content, occurred_at, updated_at, metadata)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
                item_type=excluded.item_type,
                thread_id=excluded.thread_id,
                title=excluded.title,
                sender=excluded.sender,
                channel=excluded.channel,
                content=excluded.content,
                occurred_at=excluded.occurred_at,
                updated_at=excluded.updated_at,
                metadata=excluded.metadata
            """,
            (
                item_id,
                connector,
                item_type,
                thread_id,
                title[:500],
                sender[:240],
                channel[:240],
                content[:MAX_ITEM_CONTENT_CHARS],
                float(occurred_at),
                now,
                meta_json,
            ),
        )
    return True


# ── Generic IMAP Email Connector (Read-Only) ───────────────────────────────────


def _imap_connect(host: str, port: int, username: str, password: str, timeout: float = 20.0) -> imaplib.IMAP4_SSL:
    if not host or not username or not password:
        raise ConnectorError("请填写完整的 IMAP 服务器地址、邮箱账号和密码/授权码。")
    if not (1 <= int(port) <= 65535):
        raise ConnectorError("IMAP 端口号无效。")
    ctx = ssl.create_default_context()
    try:
        conn = imaplib.IMAP4_SSL(host=host, port=int(port), ssl_context=ctx, timeout=timeout)
        conn.login(username, password)
        return conn
    except imaplib.IMAP4.error as exc:
        raise ConnectorError(f"IMAP 登录失败，请检查账号或应用专用密码/授权码。（{str(exc)[:120]}）") from exc
    except OSError as exc:
        raise ConnectorError(f"无法连接到 IMAP 服务器 {host}:{port}，请检查网络或服务器地址。") from exc


EMAIL_DOMAIN_TO_PRESET: dict[str, str] = {
    "gmail.com": "gmail",
    "googlemail.com": "gmail",
    "icloud.com": "icloud",
    "me.com": "icloud",
    "mac.com": "icloud",
    "outlook.com": "outlook",
    "hotmail.com": "outlook",
    "live.com": "outlook",
    "msn.com": "outlook",
    "qq.com": "qq",
    "foxmail.com": "qq",
    "163.com": "163",
    "feishu.cn": "feishu_mail",
    "larksuite.com": "feishu_mail",
}


def infer_email_preset(username: str) -> str:
    addr = str(username or "").strip().lower()
    if "@" not in addr:
        return "custom"
    domain = addr.rsplit("@", 1)[-1].strip()
    return EMAIL_DOMAIN_TO_PRESET.get(domain, "custom")


def configure_email_connector(data_dir: Path, payload: dict[str, Any]) -> dict[str, Any]:
    username = str(payload.get("username") or "").strip()
    raw_preset = str(payload.get("preset") or "").strip().lower()
    if raw_preset in EMAIL_PRESETS and raw_preset != "custom":
        preset = raw_preset
    elif not payload.get("host"):
        preset = infer_email_preset(username)
    else:
        preset = raw_preset if raw_preset in EMAIL_PRESETS else "custom"
    preset_info = EMAIL_PRESETS[preset]
    host = str(payload.get("host") or preset_info["host"] or "").strip()
    port = int(payload.get("port") or preset_info["port"] or 993)
    existing = load_connectors_config(data_dir).get("email") or {}
    password = str(payload.get("password") or "").strip() or str(existing.get("password") or "").strip()
    folder = str(payload.get("folder") or existing.get("folder") or "INBOX").strip() or "INBOX"
    sync_days = max(1, min(30, int(payload.get("sync_days") or existing.get("sync_days") or DEFAULT_SYNC_DAYS)))
    enabled = bool(payload.get("enabled", True))

    if enabled:
        conn = _imap_connect(host, port, username, password)
        try:
            typ, _ = conn.select(folder, readonly=True)
            if typ != "OK":
                raise ConnectorError(f"无法以只读方式打开邮箱文件夹 `{folder}`。")
        finally:
            try:
                conn.logout()
            except Exception:
                pass

    _update_connector_section(
        data_dir,
        "email",
        {
            "preset": preset,
            "host": host,
            "port": port,
            "username": username,
            "password": password,
            "folder": folder,
            "sync_days": sync_days,
            "enabled": enabled,
            "connected": bool(host and username and password),
            "last_error": None,
            "updated_at": time.time(),
        },
    )
    return {"connector": "email", "connected": True, "enabled": enabled, "account_label": username}


def sync_email_connector(data_dir: Path, store, *, imap_factory=None) -> dict[str, Any]:
    cfg = load_connectors_config(data_dir).get("email") or {}
    if not cfg.get("enabled") or not cfg.get("connected"):
        return {"connector": "email", "skipped": True, "synced": 0}
    host = str(cfg.get("host") or "").strip()
    port = int(cfg.get("port") or 993)
    username = str(cfg.get("username") or "").strip()
    password = str(cfg.get("password") or "").strip()
    folder = str(cfg.get("folder") or "INBOX").strip() or "INBOX"
    sync_days = max(1, min(30, int(cfg.get("sync_days") or DEFAULT_SYNC_DAYS)))

    since_ts = time.time() - sync_days * 86400
    since_str = time.strftime("%d-%b-%Y", time.gmtime(since_ts))
    synced = 0
    changed = 0
    try:
        conn = imap_factory(host, port, username, password) if imap_factory else _imap_connect(host, port, username, password)
        try:
            typ, _ = conn.select(folder, readonly=True)
            if typ != "OK":
                raise ConnectorError(f"无法打开文件夹 {folder}")
            typ, data = conn.uid("search", None, "SINCE", since_str)
            if typ != "OK" or not data or not data[0]:
                uids: list[bytes] = []
            else:
                uids = data[0].split()[-DEFAULT_MAX_EMAILS:]

            for raw_uid in uids:
                uid_str = raw_uid.decode("ascii", errors="ignore")
                typ, fetched = conn.uid("fetch", raw_uid, "(BODY.PEEK[])")
                if typ != "OK" or not fetched:
                    continue
                raw_bytes = None
                for entry in fetched:
                    if isinstance(entry, tuple) and len(entry) >= 2 and isinstance(entry[1], (bytes, bytearray)):
                        raw_bytes = bytes(entry[1])
                        break
                if not raw_bytes:
                    continue
                msg = message_from_bytes(raw_bytes)
                subject = _decode_mime_header(msg.get("Subject")) or "(无主题邮件)"
                sender = _decode_mime_header(msg.get("From"))
                to_hdr = _decode_mime_header(msg.get("To"))
                msg_id_hdr = str(msg.get("Message-ID") or "").strip()
                date_hdr = msg.get("Date")
                occurred_at = time.time()
                if date_hdr:
                    try:
                        dt = parsedate_to_datetime(date_hdr)
                        if dt is not None:
                            occurred_at = dt.timestamp()
                    except Exception:
                        pass
                body = _extract_email_body(msg)
                stable_key = msg_id_hdr or f"{username}:{folder}:{uid_str}"
                item_id = "email:" + hashlib.sha256(stable_key.encode("utf-8")).hexdigest()[:24]
                thread_id = str(msg.get("In-Reply-To") or msg_id_hdr or item_id).strip()
                header_summary = f"主题：{subject}\n发件人：{sender}\n收件人：{to_hdr}\n\n{body}".strip()
                if _upsert_connector_item(
                    store,
                    item_id=item_id,
                    connector="email",
                    item_type="email",
                    thread_id=thread_id,
                    title=subject,
                    sender=sender,
                    channel=f"{username}/{folder}",
                    content=header_summary,
                    occurred_at=occurred_at,
                    metadata={"folder": folder, "uid": uid_str, "to": to_hdr[:240], "account": username},
                ):
                    changed += 1
                synced += 1
        finally:
            try:
                conn.logout()
            except Exception:
                pass
        _update_connector_section(data_dir, "email", {"last_synced": time.time(), "last_error": None})
        return {"connector": "email", "synced": synced, "changed": changed}
    except Exception as exc:
        err_msg = str(exc)[:300]
        _update_connector_section(data_dir, "email", {"last_error": err_msg})
        raise ConnectorError(err_msg) from exc


# ── Feishu Personal OAuth 2.0 Connector (Read-Only) ───────────────────────────


def _feishu_endpoints(domain: str) -> dict[str, str]:
    key = domain if domain in FEISHU_DOMAINS else "feishu"
    return FEISHU_DOMAINS[key]


def _http_json(
    url: str,
    *,
    method: str = "GET",
    headers: dict[str, str] | None = None,
    body: dict[str, Any] | None = None,
    timeout: float = 20.0,
) -> dict[str, Any]:
    hdrs = {"Accept": "application/json", **(headers or {})}
    raw_body = None
    if body is not None:
        raw_body = json.dumps(body, ensure_ascii=False).encode("utf-8")
        hdrs.setdefault("Content-Type", "application/json; charset=utf-8")
    req = Request(url, data=raw_body, headers=hdrs, method=method)
    try:
        with urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except HTTPError as exc:
        detail = ""
        try:
            detail = exc.read().decode("utf-8", errors="replace")[:200]
        except Exception:
            pass
        raise ConnectorError(f"飞书接口返回 HTTP {exc.code}：{detail}") from exc
    except URLError as exc:
        raise ConnectorError(f"无法连接飞书接口：{exc.reason}") from exc


def _exchange_feishu_code(
    *,
    domain: str,
    app_id: str,
    app_secret: str,
    code: str,
    redirect_uri: str,
    http_fn=_http_json,
) -> dict[str, Any]:
    ep = _feishu_endpoints(domain)
    res = http_fn(
        f"{ep['api_base']}/open-apis/authen/v2/oauth/token",
        method="POST",
        body={
            "grant_type": "authorization_code",
            "client_id": app_id,
            "client_secret": app_secret,
            "code": code,
            "redirect_uri": redirect_uri,
        },
    )
    if res.get("code") not in (None, 0) or not res.get("access_token"):
        msg = res.get("error_description") or res.get("msg") or "OAuth token 换取失败"
        raise ConnectorError(f"飞书授权失败：{msg}")
    expires_in = int(res.get("expires_in") or 7200)
    return {
        "access_token": str(res["access_token"]),
        "refresh_token": str(res.get("refresh_token") or ""),
        "expires_at": time.time() + max(60, expires_in - 120),
        "scope": str(res.get("scope") or ""),
    }


def _refresh_feishu_token(data_dir: Path, cfg: dict[str, Any], *, http_fn=_http_json) -> str:
    access_token = str(cfg.get("access_token") or "").strip()
    expires_at = float(cfg.get("expires_at") or 0)
    if access_token and time.time() < expires_at:
        return access_token
    refresh_token = str(cfg.get("refresh_token") or "").strip()
    app_id = str(cfg.get("app_id") or "").strip()
    app_secret = str(cfg.get("app_secret") or "").strip()
    domain = str(cfg.get("domain") or "feishu").strip()
    if not (refresh_token and app_id and app_secret):
        raise ConnectorError("飞书个人授权已过期，请在设置中重新授权登录。")
    ep = _feishu_endpoints(domain)
    res = http_fn(
        f"{ep['api_base']}/open-apis/authen/v2/oauth/token",
        method="POST",
        body={
            "grant_type": "refresh_token",
            "client_id": app_id,
            "client_secret": app_secret,
            "refresh_token": refresh_token,
        },
    )
    if res.get("code") not in (None, 0) or not res.get("access_token"):
        raise ConnectorError("飞书登录态刷新失败，请在设置中重新授权登录。")
    new_token = str(res["access_token"])
    new_refresh = str(res.get("refresh_token") or refresh_token)
    expires_in = int(res.get("expires_in") or 7200)
    _update_connector_section(
        data_dir,
        "feishu",
        {
            "access_token": new_token,
            "refresh_token": new_refresh,
            "expires_at": time.time() + max(60, expires_in - 120),
            "last_error": None,
        },
    )
    return new_token


def _fetch_feishu_user_info(domain: str, access_token: str, *, http_fn=_http_json) -> dict[str, Any]:
    ep = _feishu_endpoints(domain)
    try:
        res = http_fn(
            f"{ep['api_base']}/open-apis/authen/v1/user_info",
            headers={"Authorization": f"Bearer {access_token}"},
        )
        data = res.get("data") if isinstance(res.get("data"), dict) else {}
        return {
            "user_name": str(data.get("name") or data.get("en_name") or "").strip(),
            "open_id": str(data.get("open_id") or "").strip(),
        }
    except Exception:
        return {"user_name": "", "open_id": ""}


class _FeishuOAuthCoordinator:
    """Manages a single localhost loopback OAuth callback server for Feishu personal sign-in."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._server: HTTPServer | None = None
        self._state: str = ""
        self._expires_at: float = 0.0

    def stop(self) -> None:
        with self._lock:
            srv = self._server
            self._server = None
            self._state = ""
        if srv is not None:
            try:
                srv.shutdown()
                srv.server_close()
            except Exception:
                pass

    def start(
        self,
        data_dir: Path,
        *,
        app_id: str,
        app_secret: str,
        domain: str = "feishu",
        callback_port: int = 0,
        on_connected=None,
    ) -> dict[str, Any]:
        app_id = app_id.strip()
        app_secret = app_secret.strip()
        domain = domain if domain in FEISHU_DOMAINS else "feishu"
        if not app_id or not app_secret:
            raise ConnectorError("请先填写飞书应用的 App ID 和 App Secret。")

        self.stop()
        state = secrets.token_urlsafe(24)
        ep = _feishu_endpoints(domain)

        # Save App credentials immediately so user doesn't have to re-enter them.
        _update_connector_section(
            data_dir,
            "feishu",
            {
                "app_id": app_id,
                "app_secret": app_secret,
                "domain": domain,
                "last_error": None,
            },
        )

        coordinator = self

        class _CallbackHandler(BaseHTTPRequestHandler):
            def log_message(self, fmt, *args):
                return

            def do_GET(self):
                parsed = urlsplit(self.path)
                if parsed.path != "/callback":
                    self.send_response(404)
                    self.end_headers()
                    return
                qs = parse_qs(parsed.query)
                got_state = (qs.get("state") or [""])[0]
                code = (qs.get("code") or [""])[0]
                err = (qs.get("error") or [""])[0]

                if err:
                    _update_connector_section(data_dir, "feishu", {"last_error": f"飞书授权已取消：{err}"})
                    self._html(400, "飞书授权未完成，你可以关闭此页面并返回 MoMo Agent。")
                    threading.Thread(target=coordinator.stop, daemon=True).start()
                    return
                if not got_state or got_state != state or not code:
                    self._html(400, "无效的授权回调参数，请返回 MoMo Agent 重试。")
                    return

                redirect_uri = f"http://127.0.0.1:{self.server.server_port}/callback"
                try:
                    tok = _exchange_feishu_code(
                        domain=domain,
                        app_id=app_id,
                        app_secret=app_secret,
                        code=code,
                        redirect_uri=redirect_uri,
                    )
                    user = _fetch_feishu_user_info(domain, tok["access_token"])
                    _update_connector_section(
                        data_dir,
                        "feishu",
                        {
                            **tok,
                            "user_name": user.get("user_name") or app_id,
                            "open_id": user.get("open_id") or "",
                            "connected": True,
                            "enabled": True,
                            "last_error": None,
                            "updated_at": time.time(),
                        },
                    )
                    if on_connected is not None:
                        threading.Thread(target=on_connected, daemon=True).start()
                    self._html(200, "飞书个人账号已授权成功！请关闭此页面返回 MoMo Agent。")
                except Exception as exc:
                    _update_connector_section(data_dir, "feishu", {"last_error": str(exc)[:300]})
                    self._html(500, f"授权完成失败：{str(exc)[:180]}")
                finally:
                    threading.Thread(target=coordinator.stop, daemon=True).start()

            def _html(self, status: int, message: str):
                body = (
                    "<!doctype html><html><meta charset='utf-8'>"
                    "<body style='font-family:-apple-system,sans-serif;padding:48px;text-align:center;color:#222'>"
                    f"<h2>MoMo Agent · 飞书连接器</h2><p>{message}</p></body></html>"
                ).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        server = HTTPServer(("127.0.0.1", int(callback_port)), _CallbackHandler)
        port = server.server_port
        redirect_uri = f"http://127.0.0.1:{port}/callback"

        with self._lock:
            self._server = server
            self._state = state
            self._expires_at = time.time() + 300.0

        def _serve():
            try:
                server.serve_forever(poll_interval=0.5)
            except Exception:
                pass

        threading.Thread(target=_serve, daemon=True, name="momo-feishu-oauth").start()

        def _auto_expire():
            time.sleep(305.0)
            with self._lock:
                if self._state == state:
                    threading.Thread(target=self.stop, daemon=True).start()

        threading.Thread(target=_auto_expire, daemon=True).start()

        query = urlencode(
            {
                "client_id": app_id,
                "redirect_uri": redirect_uri,
                "response_type": "code",
                "scope": FEISHU_READONLY_SCOPES,
                "state": state,
            }
        )
        authorize_url = f"{ep['auth_base']}/oauth/authorize?{query}"
        return {
            "connector": "feishu",
            "authorize_url": authorize_url,
            "redirect_uri": redirect_uri,
            "expires_at": self._expires_at,
        }


_FEISHU_OAUTH = _FeishuOAuthCoordinator()


def start_feishu_oauth(data_dir: Path, payload: dict[str, Any], *, on_connected=None) -> dict[str, Any]:
    existing = load_connectors_config(data_dir).get("feishu") or {}
    app_id = str(payload.get("app_id") or existing.get("app_id") or "").strip()
    app_secret = str(payload.get("app_secret") or existing.get("app_secret") or "").strip()
    domain = str(payload.get("domain") or existing.get("domain") or "feishu").strip().lower()
    callback_port = int(payload.get("callback_port") or 0)
    return _FEISHU_OAUTH.start(
        data_dir,
        app_id=app_id,
        app_secret=app_secret,
        domain=domain,
        callback_port=callback_port,
        on_connected=on_connected,
    )


def _extract_feishu_message_text(msg_type: str, raw_content: str) -> str:
    if not raw_content:
        return ""
    try:
        parsed = json.loads(raw_content)
    except ValueError:
        return raw_content.strip()
    if not isinstance(parsed, dict):
        return str(parsed).strip()
    if msg_type == "text":
        return str(parsed.get("text") or "").strip()
    if msg_type == "post":
        parts: list[str] = []
        title = str(parsed.get("title") or "").strip()
        if title:
            parts.append(title)
        for para in parsed.get("content") or []:
            if isinstance(para, list):
                line = "".join(str(el.get("text") or el.get("href") or "") for el in para if isinstance(el, dict))
                if line.strip():
                    parts.append(line.strip())
        return "\n".join(parts).strip()
    if msg_type in ("interactive", "share_chat", "share_user"):
        return json.dumps(parsed, ensure_ascii=False)[:1500]
    return f"[{msg_type}] {str(parsed.get('file_name') or parsed.get('title') or '').strip()}".strip()


def sync_feishu_connector(data_dir: Path, store, *, http_fn=_http_json) -> dict[str, Any]:
    cfg = load_connectors_config(data_dir).get("feishu") or {}
    if not cfg.get("enabled") or not cfg.get("connected"):
        return {"connector": "feishu", "skipped": True, "synced": 0}
    domain = str(cfg.get("domain") or "feishu").strip()
    ep = _feishu_endpoints(domain)
    synced = 0
    changed = 0
    try:
        token = _refresh_feishu_token(data_dir, cfg, http_fn=http_fn)
        headers = {"Authorization": f"Bearer {token}"}

        # 1. Sync recent group chats + discovered P2P (private) chats & messages (read-only)
        start_sec = int(time.time() - DEFAULT_SYNC_DAYS * 86400)
        chat_entries: list[tuple[str, str]] = []
        seen_chat_ids: set[str] = set()

        try:
            chats_res = http_fn(
                f"{ep['api_base']}/open-apis/im/v1/chats?page_size={DEFAULT_MAX_FEISHU_CHATS}",
                headers=headers,
            )
            for chat in ((chats_res.get("data") or {}).get("items") or [])[:DEFAULT_MAX_FEISHU_CHATS]:
                cid = str(chat.get("chat_id") or "").strip()
                if cid and cid not in seen_chat_ids:
                    seen_chat_ids.add(cid)
                    cname = str(chat.get("name") or chat.get("description") or "飞书群聊").strip()
                    chat_entries.append((cid, cname))
        except ConnectorError:
            pass

        # 1b. Discover private (P2P) chats via user-scoped message search + persisted known_p2p_chat_ids
        known_p2p = [str(c).strip() for c in (cfg.get("known_p2p_chat_ids") or []) if str(c).strip()]
        discovered_p2p: list[str] = []
        try:
            search_msg_ids: list[str] = []
            for query_seed in ("", "的", "好"):
                try:
                    search_res = http_fn(
                        f"{ep['api_base']}/open-apis/search/v2/message?page_size=50",
                        method="POST",
                        headers=headers,
                        body={
                            "query": query_seed,
                            "from_types": ["user"],
                            "start_time": str(start_sec),
                        },
                    )
                    found_ids = (search_res.get("data") or {}).get("items") or []
                    for mid in found_ids:
                        mid_str = str(mid).strip()
                        if mid_str and mid_str not in search_msg_ids:
                            search_msg_ids.append(mid_str)
                    if search_msg_ids:
                        break
                except ConnectorError:
                    continue
            for mid in search_msg_ids[:25]:
                try:
                    m_detail = http_fn(
                        f"{ep['api_base']}/open-apis/im/v1/messages/{mid}",
                        headers=headers,
                    )
                    m_items = (m_detail.get("data") or {}).get("items") or []
                    for m_obj in m_items:
                        cid = str(m_obj.get("chat_id") or "").strip()
                        if cid and cid not in seen_chat_ids and cid not in discovered_p2p:
                            discovered_p2p.append(cid)
                except ConnectorError:
                    continue
        except ConnectorError:
            pass

        merged_p2p: list[str] = []
        for cid in [*discovered_p2p, *known_p2p]:
            if cid and cid not in seen_chat_ids and cid not in merged_p2p:
                merged_p2p.append(cid)
        merged_p2p = merged_p2p[:30]
        if merged_p2p != known_p2p:
            _update_connector_section(data_dir, "feishu", {"known_p2p_chat_ids": merged_p2p})

        for cid in merged_p2p:
            seen_chat_ids.add(cid)
            chat_entries.append((cid, f"飞书私聊 ({cid[-6:]})"))

        for chat_id, chat_name in chat_entries:
            try:
                msg_res = http_fn(
                    f"{ep['api_base']}/open-apis/im/v1/messages?"
                    + urlencode(
                        {
                            "container_id_type": "chat",
                            "container_id": chat_id,
                            "start_time": str(start_sec),
                            "sort_type": "ByCreateTimeDesc",
                            "page_size": str(DEFAULT_MAX_FEISHU_MESSAGES_PER_CHAT),
                        }
                    ),
                    headers=headers,
                )
            except ConnectorError:
                continue
            items = (msg_res.get("data") or {}).get("items") or []
            for m in items:
                if m.get("deleted"):
                    continue
                mid = str(m.get("message_id") or "").strip()
                if not mid:
                    continue
                mtype = str(m.get("msg_type") or "text")
                body_content = str(((m.get("body") or {}).get("content")) or "")
                text = _extract_feishu_message_text(mtype, body_content)
                if not text:
                    continue
                sender_obj = m.get("sender") if isinstance(m.get("sender"), dict) else {}
                sender_id = str(sender_obj.get("id") or sender_obj.get("sender_type") or "unknown")
                create_ms = float(m.get("create_time") or 0)
                occurred_at = (create_ms / 1000.0) if create_ms > 1e11 else (create_ms or time.time())
                title = f"{chat_name} · {text.splitlines()[0][:60]}"
                if _upsert_connector_item(
                    store,
                    item_id=f"feishu:msg:{mid}",
                    connector="feishu",
                    item_type="feishu_message",
                    thread_id=chat_id,
                    title=title,
                    sender=sender_id,
                    channel=chat_name,
                    content=f"[{chat_name}] {text}",
                    occurred_at=occurred_at,
                    metadata={"chat_id": chat_id, "message_id": mid, "msg_type": mtype},
                ):
                    changed += 1
                synced += 1

        # 2. Sync recent personal cloud docs across root and subfolders (read-only, up to depth 2)
        try:
            doc_count = 0
            seen_folders: set[str] = {""}
            queue: list[tuple[str, int, str]] = [("", 0, "飞书云文档")]
            while queue and doc_count < DEFAULT_MAX_FEISHU_DOCS:
                folder_token, depth, folder_label = queue.pop(0)
                params = {"page_size": str(DEFAULT_MAX_FEISHU_DOCS), "order_by": "EditedTime", "direction": "DESC"}
                if folder_token:
                    params["folder_token"] = folder_token
                try:
                    files_res = http_fn(
                        f"{ep['api_base']}/open-apis/drive/v1/files?{urlencode(params)}",
                        headers=headers,
                    )
                except ConnectorError:
                    if depth == 0:
                        raise
                    continue
                files = (files_res.get("data") or {}).get("files") or []
                for f in files:
                    if doc_count >= DEFAULT_MAX_FEISHU_DOCS:
                        break
                    ftype = str(f.get("type") or "").lower()
                    ftoken = str(f.get("token") or "").strip()
                    fname = str(f.get("name") or "飞书文档").strip()
                    if ftype == "folder" and ftoken and depth < 2 and ftoken not in seen_folders:
                        seen_folders.add(ftoken)
                        queue.append((ftoken, depth + 1, f"{folder_label}/{fname}"))
                        continue
                    if ftype not in ("docx", "doc") or not ftoken:
                        continue
                    doc_url = str(f.get("url") or "").strip()
                    raw_text = ""
                    if ftype == "docx":
                        try:
                            doc_res = http_fn(
                                f"{ep['api_base']}/open-apis/docx/v1/documents/{ftoken}/raw_content",
                                headers=headers,
                            )
                            raw_text = str(((doc_res.get("data") or {}).get("content")) or "").strip()
                        except ConnectorError:
                            raw_text = ""
                    mod_ts = float(f.get("modified_time") or time.time())
                    content = f"# {fname}\n\n{raw_text}" if raw_text else f"# {fname}\n\n(飞书文档链接: {doc_url})"
                    if _upsert_connector_item(
                        store,
                        item_id=f"feishu:doc:{ftoken}",
                        connector="feishu",
                        item_type="feishu_doc",
                        thread_id=ftoken,
                        title=fname,
                        sender=str(cfg.get("user_name") or ""),
                        channel=folder_label,
                        content=content,
                        occurred_at=mod_ts,
                        metadata={"token": ftoken, "type": ftype, "url": doc_url, "folder": folder_label},
                    ):
                        changed += 1
                    synced += 1
                    doc_count += 1
        except ConnectorError:
            # Drive scope is optional if the user only granted IM scopes.
            pass

        _update_connector_section(data_dir, "feishu", {"last_synced": time.time(), "last_error": None})
        return {"connector": "feishu", "synced": synced, "changed": changed}
    except Exception as exc:
        err_msg = str(exc)[:300]
        _update_connector_section(data_dir, "feishu", {"last_error": err_msg})
        raise ConnectorError(err_msg) from exc


# ── Unified Status, Sync, Disconnect & Query APIs ─────────────────────────────


def connectors_status(data_dir: Path, store) -> dict[str, Any]:
    ensure_connector_tables(store.db)
    cfg = load_connectors_config(data_dir)
    counts = dict(store.db.execute("SELECT connector, COUNT(*) FROM connector_items GROUP BY connector").fetchall())

    feishu_cfg = cfg.get("feishu") or {}
    email_cfg = cfg.get("email") or {}

    return {
        "connectors": {
            "feishu": {
                "kind": "feishu",
                "mode": "readonly_oauth",
                "enabled": bool(feishu_cfg.get("enabled")),
                "connected": bool(feishu_cfg.get("connected")),
                "domain": str(feishu_cfg.get("domain") or "feishu"),
                "app_id": str(feishu_cfg.get("app_id") or ""),
                "has_secret": bool(feishu_cfg.get("app_secret")),
                "account_label": str(feishu_cfg.get("user_name") or ""),
                "last_synced": feishu_cfg.get("last_synced"),
                "last_error": feishu_cfg.get("last_error"),
                "item_count": int(counts.get("feishu") or 0),
            },
            "email": {
                "kind": "email",
                "mode": "readonly_imap",
                "enabled": bool(email_cfg.get("enabled")),
                "connected": bool(email_cfg.get("connected")),
                "preset": str(email_cfg.get("preset") or "gmail"),
                "host": str(email_cfg.get("host") or ""),
                "port": int(email_cfg.get("port") or 993),
                "username": str(email_cfg.get("username") or ""),
                "has_password": bool(email_cfg.get("password")),
                "folder": str(email_cfg.get("folder") or "INBOX"),
                "sync_days": int(email_cfg.get("sync_days") or DEFAULT_SYNC_DAYS),
                "account_label": str(email_cfg.get("username") or ""),
                "last_synced": email_cfg.get("last_synced"),
                "last_error": email_cfg.get("last_error"),
                "item_count": int(counts.get("email") or 0),
            },
        },
        "email_presets": [
            {"id": k, "label": v["label"], "host": v["host"], "port": v["port"], "note": v["note"]}
            for k, v in EMAIL_PRESETS.items()
        ],
    }


def disconnect_connector(data_dir: Path, store, connector: str, *, clear_data: bool = False) -> dict[str, Any]:
    if connector not in CONNECTOR_KINDS:
        raise ConnectorError("未知的连接器类型")
    if connector == "feishu":
        _FEISHU_OAUTH.stop()
        _update_connector_section(
            data_dir,
            "feishu",
            {
                "enabled": False,
                "connected": False,
                "access_token": "",
                "refresh_token": "",
                "expires_at": 0,
                "last_error": None,
            },
        )
    else:
        _update_connector_section(
            data_dir,
            "email",
            {
                "enabled": False,
                "connected": False,
                "password": "",
                "last_error": None,
            },
        )
    removed = 0
    if clear_data:
        ensure_connector_tables(store.db)
        with store.write():
            cur = store.db.execute("DELETE FROM connector_items WHERE connector=?", (connector,))
            removed = cur.rowcount
    return {"connector": connector, "disconnected": True, "removed_items": removed}


def sync_connectors(data_dir: Path, store, connector: str = "all") -> dict[str, Any]:
    targets = list(CONNECTOR_KINDS) if connector in ("", "all") else [connector]
    results: dict[str, Any] = {}
    for target in targets:
        if target not in CONNECTOR_KINDS:
            raise ConnectorError(f"不支持的连接器：{target}")
        try:
            if target == "email":
                results["email"] = sync_email_connector(data_dir, store)
            elif target == "feishu":
                results["feishu"] = sync_feishu_connector(data_dir, store)
        except ConnectorError as exc:
            results[target] = {"connector": target, "error": str(exc)}
    return {"results": results, "status": connectors_status(data_dir, store)}


def list_connector_items(
    store,
    *,
    connector: str = "all",
    limit: int = 30,
    since: float | None = None,
) -> list[dict[str, Any]]:
    ensure_connector_tables(store.db)
    limit = max(1, min(100, int(limit)))
    clauses: list[str] = []
    params: list[Any] = []
    if connector and connector != "all":
        clauses.append("connector=?")
        params.append(connector)
    if since is not None:
        clauses.append("occurred_at>=?")
        params.append(float(since))
    where = ("WHERE " + " AND ".join(clauses)) if clauses else ""
    rows = store.db.execute(
        f"SELECT id, connector, item_type, thread_id, title, sender, channel, substr(content, 1, 280) AS preview, occurred_at, updated_at "
        f"FROM connector_items {where} ORDER BY occurred_at DESC LIMIT ?",
        (*params, limit),
    ).fetchall()
    return [dict(r) for r in rows]


def read_connector_item(store, item_id: str) -> dict[str, Any] | None:
    ensure_connector_tables(store.db)
    row = store.db.execute("SELECT * FROM connector_items WHERE id=?", (item_id,)).fetchone()
    if not row:
        return None
    out = dict(row)
    try:
        out["metadata"] = json.loads(out.get("metadata") or "{}")
    except ValueError:
        out["metadata"] = {}
    return out


def recent_connector_digest(store, *, hours: float = 24.0, limit: int = 12) -> list[dict[str, Any]]:
    """Compact recent Feishu & Email items for Morning Briefing and Dream context."""
    since = time.time() - max(1.0, hours) * 3600.0
    items = list_connector_items(store, connector="all", limit=limit, since=since)
    return [
        {
            "id": it["id"],
            "connector": it["connector"],
            "type": it["item_type"],
            "channel": it["channel"],
            "sender": it["sender"],
            "title": it["title"],
            "preview": it["preview"],
            "occurred_at": it["occurred_at"],
        }
        for it in items
    ]
