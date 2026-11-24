"""Managed OAuth and read-only provider requests for the Mac mail connector."""
import base64
from datetime import datetime, timezone
from email.message import Message
import json
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qsl, quote, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

BASE = "https://backend.composio.dev/api/v3.1"
SCOPES = {
    "gmail": "https://www.googleapis.com/auth/gmail.readonly",
    "outlook": "offline_access,User.Read,Mail.Read",
}


class ConnectorError(RuntimeError):
    """Safe to display in the client."""


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def request(key, path, *, method="GET", body=None, missing_ok=False):
    if not key or not key.isascii() or any(ord(c) < 33 or ord(c) > 126 for c in key):
        raise ConnectorError("请输入有效的 Composio 项目 API key。")
    req = Request(BASE + path, method=method,
                  headers={"x-api-key": key, "Content-Type": "application/json"},
                  data=json.dumps(body).encode() if body is not None else None)
    try:
        with build_opener(_NoRedirect()).open(req, timeout=20) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except HTTPError as exc:
        exc.close()
        if missing_ok and exc.code == 404:
            return {}
        if exc.code in (401, 403):
            raise ConnectorError("请在 Composio 检查项目 API key 和访问权限。") from exc
        raise ConnectorError(f"Composio 请求失败（HTTP {exc.code}），请稍后重试。") from exc
    except (URLError, TimeoutError, ValueError) as exc:
        raise ConnectorError("无法读取 Composio 的响应，请检查网络后重试。") from exc


def create_config(key, provider):
    result = request(key, "/auth_configs", method="POST", body={
        "toolkit": {"slug": provider},
        "auth_config": {"type": "use_composio_managed_auth", "auth_scheme": "OAUTH2",
                        "name": f"MoMo {provider} read-only",
                        "credentials": {"scopes": SCOPES[provider]}},
    })
    return result["auth_config"]["id"]


def link(key, config_id, user_id):
    result = request(key, "/connected_accounts/link", method="POST",
                     body={"auth_config_id": config_id, "user_id": user_id})
    url = urlsplit(result["redirect_url"])
    if url.scheme != "https" or not url.hostname or not result["connected_account_id"]:
        raise ConnectorError("Composio 未返回有效的授权链接。")
    return result


def account_path(cfg):
    return "/connected_accounts/" + quote(cfg["account_id"], safe="")


def status(cfg, *, missing_ok=True):
    record = request(cfg["api_key"], account_path(cfg), missing_ok=missing_ok)
    if not record:
        return "EXPIRED"
    if (record["user_id"] != cfg["user_id"] or record["toolkit"]["slug"] != cfg["provider"]
            or record["auth_config"]["id"] != cfg["config_id"]):
        raise ConnectorError("Composio 返回的连接与本机授权不匹配。")
    return "EXPIRED" if record.get("is_disabled") else record["status"]


def revoke(cfg):
    request(cfg["api_key"], account_path(cfg), method="DELETE", missing_ok=True)


def read(cfg, endpoint, **query):
    result = request(cfg["api_key"], "/tools/execute/proxy", method="POST", body={
        "connected_account_id": cfg["account_id"], "user_id": cfg["user_id"],
        "method": "GET", "endpoint": endpoint,
        "parameters": [{"type": "query", "name": k, "value": str(v)} for k, v in query.items()],
    })
    if result["status"] != 200:
        raise ConnectorError(f"邮箱读取失败（HTTP {result['status']}）。请检查授权或稍后重试。")
    return result["data"]


def mailbox(cfg):
    if cfg["provider"] == "gmail":
        return read(cfg, "/gmail/v1/users/me/profile")["emailAddress"]
    profile = read(cfg, "/v1.0/me", **{"$select": "mail,userPrincipalName"})
    return profile.get("mail") or profile["userPrincipalName"]


def _gmail_text(part, plain, html):
    if part.get("filename") or part.get("body", {}).get("attachmentId"):
        return
    for child in part.get("parts", []):
        _gmail_text(child, plain, html)
    kind = part.get("mimeType")
    encoded = part.get("body", {}).get("data")
    if kind not in ("text/plain", "text/html") or not encoded:
        return
    headers = Message()
    for header in part.get("headers", []):
        headers[header["name"]] = header["value"]
    raw = base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))
    try:
        text = raw.decode(headers.get_content_charset() or "utf-8", errors="replace")
    except LookupError:
        text = raw.decode("utf-8", errors="replace")
    (plain if kind == "text/plain" else html).append(text)


def gmail_messages(cfg, since, limit, decode_header, html_to_text, known_ids):
    root = "/gmail/v1/users/me/messages"
    query = {"q": f"in:inbox after:{int(since)}", "maxResults": limit}
    while limit:
        page = read(cfg, root, **query)
        for entry in page.get("messages", [])[:limit]:
            limit -= 1
            # Gmail message content is immutable. Poll the inbox list, fetch each body once.
            if entry["id"] in known_ids:
                continue
            record = read(cfg, root + "/" + quote(entry["id"], safe=""), format="full")
            payload = record["payload"]
            headers = {h["name"].lower(): h["value"] for h in payload["headers"]}
            plain, html = [], []
            _gmail_text(payload, plain, html)
            body = "\n\n".join(plain).strip() or html_to_text("\n".join(html))
            yield (entry["id"], headers.get("message-id"), record["threadId"], decode_header(headers.get("subject")),
                   decode_header(headers.get("from")), decode_header(headers.get("to")), body,
                   int(record["internalDate"]) / 1000)
        if not page.get("messages") or not page.get("nextPageToken"):
            break
        if query.get("pageToken") == page["nextPageToken"]:
            raise ConnectorError("Gmail 返回了重复的分页标记。")
        query["pageToken"] = page["nextPageToken"]


def outlook_messages(cfg, since, limit, html_to_text):
    root = "/v1.0/me/mailFolders/inbox/messages"
    start = datetime.fromtimestamp(since, timezone.utc).isoformat().replace("+00:00", "Z")
    query = {"$top": limit, "$filter": "receivedDateTime ge " + start, "$orderby": "receivedDateTime desc",
             "$select": "id,internetMessageId,conversationId,subject,from,toRecipients,body,receivedDateTime"}
    endpoint = root
    while limit:
        page = read(cfg, endpoint, **query)
        for item in page["value"][:limit]:
            body = item["body"]
            content = html_to_text(body["content"]) if body["contentType"].lower() == "html" else body["content"]
            sender = (item.get("from") or {}).get("emailAddress", {}).get("address", "")
            to = ", ".join(r["emailAddress"]["address"] for r in item.get("toRecipients", []))
            yield (item["id"], item.get("internetMessageId"), item["conversationId"], item.get("subject", ""),
                   sender, to, content, datetime.fromisoformat(item["receivedDateTime"].replace("Z", "+00:00")).timestamp())
            limit -= 1
        if not page["value"] or not page.get("@odata.nextLink"):
            break
        next_url = urlsplit(page["@odata.nextLink"])
        if next_url.hostname != "graph.microsoft.com" or next_url.path.lower() != root.lower():
            raise ConnectorError("Outlook 返回了无法识别的分页链接。")
        next_query = dict(parse_qsl(next_url.query))
        if next_query == query:
            raise ConnectorError("Outlook 返回了重复的分页标记。")
        query = next_query
