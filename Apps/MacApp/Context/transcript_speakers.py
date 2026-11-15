"""Speaker attribution shared by source retrieval and runtime presentation."""
import re

_LEADING_SPEAKER_TAG_RE = re.compile(r"^\[([^\[\]\r\n]{1,32})\]\s*(.*)$", re.DOTALL)
_NON_SPEAKER_BRACKET_RE = re.compile(
    r"^(?:\d{4}-\d{2}-\d{2}|\d{1,2}:\d{2}(?::\d{2})?|MoMo\s|近期|日期参考|说话人归属提醒|本次新增|⚠️)"
)
_OWNER_SPEAKER_LABELS = frozenset({"我", "me", "本人", "owner", "user"})


def classify_transcript_span(span: dict) -> tuple[str | None, bool | None, str]:
    """Return (speaker_label, is_owner, body_text) for a ContextStore transcript span."""
    raw_text = str(span.get("text") or "").strip()
    if span.get("speaker_attribution_excluded") is True:
        return None, None, raw_text
    explicit_speaker = str(span.get("speaker") or "").strip()
    parsed_speaker: str | None = None
    body = raw_text
    if raw_text.startswith("["):
        m = _LEADING_SPEAKER_TAG_RE.match(raw_text)
        if m:
            candidate = m.group(1).strip()
            if candidate and not _NON_SPEAKER_BRACKET_RE.match(candidate):
                parsed_speaker = candidate
                body = m.group(2).strip()
    speaker_label = explicit_speaker or parsed_speaker or None
    raw_is_owner = span.get("is_owner")
    if isinstance(raw_is_owner, bool):
        is_owner: bool | None = raw_is_owner
    elif speaker_label:
        is_owner = speaker_label.casefold() in _OWNER_SPEAKER_LABELS
    else:
        is_owner = None
    return speaker_label, is_owner, body
