"""Readable human_action tags over SuperAgent's existing string contract.

Old clients can display the same text; new consumers also receive structured metadata.
Untagged legacy requests stay unclassified rather than guessing from keywords.
"""
import ipaddress
import re
from urllib.parse import urlsplit


TAGS = {
    "【手机可完成·聊天回复】": ("phone", "chat_reply"),
    "【手机可完成·服务授权】": ("phone", "service_consent"),
    "【需要 Mac 操作】": ("mac", "local_action"),
}


def confirmation_message(question: str) -> tuple[str, dict]:
    text = question.strip()
    metadata = {"device": "unspecified", "kind": "legacy"}
    for tag, (device, kind) in TAGS.items():
        if not text.startswith(tag):
            continue
        metadata = {"device": device, "kind": kind}
        if kind == "chat_reply":
            text += "\n\n直接在这条聊天里回复你的选择，我会接着处理。"
        elif kind == "local_action":
            text += "\n\n请在运行 MoMo Agent 的 Mac 上完成上述操作，再回这条聊天告诉我，我会重新检查后继续。手机回复不能开启 Mac 的系统权限。"
        else:
            urls = []
            for candidate in re.findall(r'''https://[^\s<>\[\]()（）「」。，；！？"'`]+''', text):
                candidate = candidate.rstrip(").,;!?")
                try:
                    url = urlsplit(candidate)
                    host = url.hostname or ""
                    if not host or url.username or url.password or host == "localhost" or host.endswith((".localhost", ".local")):
                        continue
                    try:
                        if not ipaddress.ip_address(host).is_global:
                            continue
                    except ValueError:
                        pass
                    urls.append(candidate)
                except ValueError:
                    continue
            if urls:
                metadata["urls"] = list(dict.fromkeys(urls))
                text += "\n\n可在 iPhone 或 Mac 的 MoMo 聊天中打开上面的链接，核对权限范围并在服务页面同意；完成后回这里告诉我，我会检查连接后继续。聊天回复不代替服务授权。"
            else:
                metadata = {"device": "unspecified", "kind": "missing_consent_link"}
                text = text.removeprefix(tag).lstrip()
                text += "\n\n目前没有可用的 HTTPS 服务授权链接，还不能在手机上完成授权；聊天回复不代替服务商同意。"
        break
    return text, metadata


def active_attention(ticket: dict) -> dict | None:
    if ticket.get("ended") or ticket.get("state") in ("ended", "completed", "dropped", "failed", "stopped"):
        return None
    attention = ticket.get("attention")
    return attention if isinstance(attention, dict) and attention.get("id") else None


def ticket_strength(ticket: dict) -> str | None:
    return ticket.get("strength") or (ticket.get("mandate") or {}).get("strength")
