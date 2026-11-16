"""Bounded iPhone/Watch device telemetry snapshots and fast zero-permission local Mac probe."""
from __future__ import annotations

import copy
import json
import math
import re
import shutil
import subprocess
import threading
import time
import uuid

BATTERY_STATES = ("unknown", "unplugged", "charging", "full")
MAC_PROBE_CACHE_TTL_SECONDS = 15.0

_MAC_CACHE_LOCK = threading.Lock()
_MAC_PROBE_CACHE: tuple[float, dict] | None = None


def _finite_number(value, label: str = "Telemetry number") -> float:
    if type(value) not in (int, float) or not math.isfinite(value):
        raise ValueError(f"{label} must be finite")
    return float(value)


def _validate_uuid_str(value, label: str = "UUID") -> str:
    if not isinstance(value, str):
        raise ValueError(f"Invalid {label}")
    return str(uuid.UUID(value))


def _validate_battery_level(value) -> float | None:
    if value is None:
        return None
    num = _finite_number(value, "battery_level")
    if not 0.0 <= num <= 1.0:
        raise ValueError("battery_level must be between 0.0 and 1.0")
    return num


def _validate_free_storage(value) -> int | None:
    if value is None:
        return None
    if type(value) is not int or value < 0:
        raise ValueError("free_storage_bytes must be a non-negative integer or null")
    return value


def _validate_phone(phone) -> dict | None:
    if phone is None:
        return None
    if not isinstance(phone, dict):
        raise ValueError("Invalid phone telemetry object")
    battery_level = _validate_battery_level(phone.get("battery_level"))
    battery_state = phone.get("battery_state")
    if battery_state not in BATTERY_STATES:
        raise ValueError("Invalid phone battery_state")
    low_power_mode = phone.get("low_power_mode")
    if type(low_power_mode) is not bool:
        raise ValueError("Invalid phone low_power_mode")
    thermal_state = phone.get("thermal_state")
    if type(thermal_state) is not int or not 0 <= thermal_state <= 3:
        raise ValueError("Invalid phone thermal_state")
    free_storage_bytes = _validate_free_storage(phone.get("free_storage_bytes"))
    audio_route = phone.get("audio_route")
    normalized_audio = None
    if audio_route is not None:
        if not isinstance(audio_route, dict):
            raise ValueError("Invalid audio_route")
        port_type = audio_route.get("port_type")
        port_name = audio_route.get("port_name")
        if not isinstance(port_type, str) or not 1 <= len(port_type) <= 100:
            raise ValueError("Invalid audio_route.port_type")
        if not isinstance(port_name, str) or not 1 <= len(port_name) <= 256:
            raise ValueError("Invalid audio_route.port_name")
        normalized_audio = {"port_type": port_type, "port_name": port_name}
    return {
        "battery_level": battery_level,
        "battery_state": battery_state,
        "low_power_mode": low_power_mode,
        "thermal_state": thermal_state,
        "free_storage_bytes": free_storage_bytes,
        "audio_route": normalized_audio,
    }


def _validate_watch(watch) -> dict | None:
    if watch is None:
        return None
    if not isinstance(watch, dict):
        raise ValueError("Invalid watch telemetry object")
    watch_device = _validate_uuid_str(watch.get("device_id"), "watch.device_id")
    sampled_at = _finite_number(watch.get("sampled_at"), "watch.sampled_at")
    if sampled_at <= 0:
        raise ValueError("watch.sampled_at must be positive")
    activity = watch.get("activity")
    if not isinstance(activity, str) or not 1 <= len(activity) <= 40:
        raise ValueError("Invalid watch.activity")
    pending_chunks = watch.get("pending_chunk_count")
    if type(pending_chunks) is not int or pending_chunks < 0:
        raise ValueError("Invalid watch.pending_chunk_count")
    pending_bytes = watch.get("pending_bytes")
    if type(pending_bytes) is not int or pending_bytes < 0:
        raise ValueError("Invalid watch.pending_bytes")
    battery_level = _validate_battery_level(watch.get("battery_level"))
    battery_state = watch.get("battery_state")
    if battery_state not in BATTERY_STATES:
        raise ValueError("Invalid watch.battery_state")
    low_power_mode = watch.get("low_power_mode")
    if type(low_power_mode) is not bool:
        raise ValueError("Invalid watch.low_power_mode")
    thermal_state = watch.get("thermal_state")
    if type(thermal_state) is not int or not 0 <= thermal_state <= 3:
        raise ValueError("Invalid watch.thermal_state")
    free_storage_bytes = _validate_free_storage(watch.get("free_storage_bytes"))
    return {
        "device_id": watch_device,
        "sampled_at": sampled_at,
        "activity": activity,
        "pending_chunk_count": pending_chunks,
        "pending_bytes": pending_bytes,
        "battery_level": battery_level,
        "battery_state": battery_state,
        "low_power_mode": low_power_mode,
        "thermal_state": thermal_state,
        "free_storage_bytes": free_storage_bytes,
    }


def sync_device_telemetry(store, payload: dict) -> dict:
    if not isinstance(payload, dict):
        raise ValueError("Invalid device telemetry payload")
    device = _validate_uuid_str(payload.get("device_id"), "device_id")
    revision = payload.get("revision")
    if type(revision) is not int or revision < 1:
        raise ValueError("Device telemetry revision must be a positive integer")
    state = payload.get("state")
    if state not in ("enabled", "disabled"):
        raise ValueError("Invalid device telemetry state")
    observed = _finite_number(payload.get("observed_at"), "observed_at")
    if observed <= 0:
        raise ValueError("observed_at must be positive")
    zone = payload.get("timezone")
    if not isinstance(zone, str) or not 1 <= len(zone) <= 100:
        raise ValueError("Invalid timezone")
    raw_phone = payload.get("phone")
    raw_watch = payload.get("watch")
    if state == "disabled" and (raw_phone is not None or raw_watch is not None):
        raise ValueError("Disabled device telemetry snapshot must omit phone and watch data")
    phone = _validate_phone(raw_phone)
    watch = _validate_watch(raw_watch)
    normalized = {
        "device_id": device,
        "revision": revision,
        "state": state,
        "observed_at": observed,
        "timezone": zone,
        "phone": phone,
        "watch": watch,
    }
    encoded = json.dumps(normalized, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    with store.write():
        saved = store.db.execute(
            "SELECT * FROM device_telemetry_snapshots WHERE device_id=?", (device,)
        ).fetchone()
        if saved and (
            revision < saved["revision"]
            or (revision == saved["revision"] and encoded != saved["payload"])
        ):
            from context_store import Conflict
            raise Conflict("Device telemetry snapshot changed or was superseded")
        if not saved or revision > saved["revision"]:
            store.db.execute(
                "INSERT OR REPLACE INTO device_telemetry_snapshots VALUES (?,?,?,?)",
                (device, revision, encoded, time.time()),
            )
    return {"device_id": device, "revision": revision}


def parse_pmset_batt(output: str) -> dict:
    power_source: str | None = None
    if "Battery Power" in output:
        power_source = "battery"
    elif "AC Power" in output:
        power_source = "ac"

    pct_match = re.search(r"(\d{1,3})%", output)
    battery_level = min(1.0, max(0.0, int(pct_match.group(1)) / 100.0)) if pct_match else None

    battery_state: str | None = None
    lower = output.lower()
    if pct_match is not None:
        if "discharging" in lower:
            battery_state = "discharging"
        elif "finishing charge" in lower or ("charging" in lower and "not charging" not in lower):
            battery_state = "charging"
        elif "charged" in lower:
            battery_state = "full"
        elif "ac attached" in lower or "not charging" in lower:
            battery_state = "ac_attached"

    rem_match = re.search(r"(\d+):(\d{2})\s+remaining", output)
    time_remaining_minutes = (
        int(rem_match.group(1)) * 60 + int(rem_match.group(2)) if rem_match else None
    )
    return {
        "battery_level": battery_level,
        "power_source": power_source,
        "battery_state": battery_state,
        "time_remaining_minutes": time_remaining_minutes,
    }


def parse_ioreg_idle(output: str) -> float | None:
    match = re.search(r'"HIDIdleTime"\s*=\s*(\d+)', output)
    if not match:
        return None
    return round(int(match.group(1)) / 1_000_000_000.0, 2)


def clear_mac_telemetry_cache() -> None:
    global _MAC_PROBE_CACHE
    with _MAC_CACHE_LOCK:
        _MAC_PROBE_CACHE = None


def probe_mac_telemetry(now: float | None = None) -> dict:
    """Zero-permission fast local Mac probe cached in memory for 15s."""
    global _MAC_PROBE_CACHE
    mono = time.monotonic()
    ts = time.time() if now is None else float(now)
    with _MAC_CACHE_LOCK:
        if _MAC_PROBE_CACHE is not None and (mono - _MAC_PROBE_CACHE[0]) < MAC_PROBE_CACHE_TTL_SECONDS:
            cached = copy.deepcopy(_MAC_PROBE_CACHE[1])
            cached["as_of"] = ts
            return cached

    batt_info = {
        "battery_level": None,
        "power_source": None,
        "battery_state": None,
        "time_remaining_minutes": None,
    }
    pmset_bin = shutil.which("pmset") or "/usr/bin/pmset"
    try:
        proc = subprocess.run(
            [pmset_bin, "-g", "batt"],
            capture_output=True,
            text=True,
            timeout=1.5,
            check=False,
        )
        if proc.returncode == 0 and proc.stdout:
            batt_info = parse_pmset_batt(proc.stdout)
    except Exception:
        pass

    hid_idle_seconds: float | None = None
    ioreg_bin = shutil.which("ioreg") or "/usr/sbin/ioreg"
    try:
        proc = subprocess.run(
            [ioreg_bin, "-c", "IOHIDSystem", "-d", "4"],
            capture_output=True,
            text=True,
            timeout=1.5,
            check=False,
        )
        if proc.returncode == 0 and proc.stdout:
            hid_idle_seconds = parse_ioreg_idle(proc.stdout)
    except Exception:
        pass

    free_storage_bytes: int | None = None
    try:
        free_storage_bytes = int(shutil.disk_usage("/").free)
    except Exception:
        pass

    result = {
        **batt_info,
        "hid_idle_seconds": hid_idle_seconds,
        "user_active_at_mac": (hid_idle_seconds < 180.0) if hid_idle_seconds is not None else None,
        "free_storage_bytes": free_storage_bytes,
    }
    with _MAC_CACHE_LOCK:
        _MAC_PROBE_CACHE = (mono, copy.deepcopy(result))
    return {**result, "as_of": ts}


def read_device_telemetry(store, after: str = "", limit: int = 20, now: float | None = None) -> dict:
    if type(limit) is not int or not 1 <= limit <= 50:
        raise ValueError("Device telemetry page size must be between 1 and 50")
    now_ts = time.time() if now is None else float(now)
    rows = store.db.execute(
        "SELECT * FROM device_telemetry_snapshots WHERE device_id>? ORDER BY device_id LIMIT ?",
        (after, limit + 1),
    ).fetchall()
    items = []
    for row in rows[:limit]:
        item = json.loads(row["payload"])
        age = max(0.0, now_ts - item["observed_at"])
        item.update(
            synced_at=row["synced_at"],
            snapshot_age_seconds=age,
            stale=age > 1800,
            clock_ahead=item["observed_at"] > now_ts + 300,
        )
        if isinstance(item.get("watch"), dict):
            watch_age = max(0.0, now_ts - item["watch"]["sampled_at"])
            item["watch"]["age_seconds"] = watch_age
            item["watch"]["stale"] = watch_age > 1800
        items.append(item)
    return {
        "as_of": now_ts,
        "status": "available" if items else "not_synced",
        "mac": probe_mac_telemetry(now=now_ts),
        "items": items,
        "next_cursor": rows[limit - 1]["device_id"] if len(rows) > limit else None,
    }
