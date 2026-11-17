"""Speaker attribution shared by source retrieval and runtime presentation."""
import re

_LEADING_SPEAKER_TAG_RE = re.compile(r"^\[([^\[\]\r\n]{1,32})\]\s*(.*)$", re.DOTALL)
_NON_SPEAKER_BRACKET_RE = re.compile(
    r"^(?:\d{4}-\d{2}-\d{2}|\d{1,2}:\d{2}(?::\d{2})?|MoMo\s|近期|日期参考|说话人归属提醒|本次新增|⚠️)"
)
_OWNER_SPEAKER_LABELS = frozenset({"我", "me", "本人", "owner", "user"})
_ANONYMOUS_SPEAKER_RE = re.compile(
    r"^(?:说话人|发言人|speaker|spk)\s*[-#]?\s*(?:\d+|[a-z])$|^身份待确认$",
    re.IGNORECASE,
)


def is_anonymous_speaker_label(label: str | None) -> bool:
    """Return True when label is an unverified diarization cluster placeholder (e.g. '说话人 1')."""
    if not label:
        return False
    return bool(_ANONYMOUS_SPEAKER_RE.match(label.strip()))


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
    if raw_is_owner is True:
        is_owner: bool | None = True
    elif is_anonymous_speaker_label(speaker_label):
        # Unmatched acoustic clusters ('说话人 1', 'Speaker 2') have unverified voiceprint identity
        # (including legacy phone sync payloads where personID == nil serialized is_owner=False).
        is_owner = None
    elif isinstance(raw_is_owner, bool):
        is_owner = raw_is_owner
    elif speaker_label:
        is_owner = speaker_label.casefold() in _OWNER_SPEAKER_LABELS
    else:
        is_owner = None
    return speaker_label, is_owner, body
