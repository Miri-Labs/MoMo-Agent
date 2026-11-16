"""Autonomous Life Pulse: semantic state quantization, uniform 1.5h throttling, and Unified Situation & Delta Briefs.

100% LLM-driven downstream: zero hardcoded business threshold rules live here. This module only
decides WHEN a new world-state frame is ready to deliver to SuperAgent's Orchestrator (`kind='life_signals'`).
"""
from __future__ import annotations

from collections.abc import Callable
import json
import time

from context_store import canonical, digest
from situational_context import read_situational_context

PULSE_STATE_KEY = "life_pulse_state"
PULSE_INTERVAL_SECONDS = 5400  # Uniform 1.5 hours (90 minutes) between emitted pulses


def has_situational_evidence(store) -> bool:
    row = store.db.execute(
        """SELECT 1 FROM device_telemetry_snapshots WHERE json_extract(payload, '$.state')='enabled'
           UNION ALL
           SELECT 1 FROM health_snapshots WHERE json_extract(payload, '$.state')='enabled'
           UNION ALL
           SELECT 1 FROM phone_source_snapshots WHERE json_extract(payload, '$.state') IN ('enabled', 'foreground_only')
           LIMIT 1"""
    ).fetchone()
    return row is not None


def _load_pulse_state(store) -> dict:
    row = store.db.execute(
        "SELECT value FROM memory_review_state WHERE key=?", (PULSE_STATE_KEY,)
    ).fetchone()
    if not row:
        return {}
    try:
        parsed = json.loads(row[0])
        return parsed if isinstance(parsed, dict) else {}
    except Exception:
        return {}


def _save_pulse_state(store, state: dict) -> None:
    with store.write():
        store.db.execute(
            "INSERT INTO memory_review_state VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            (PULSE_STATE_KEY, canonical(state)),
        )


def _battery_band(level: float | None) -> int | None:
    if level is None:
        return None
    return min(10, max(0, int(float(level) * 10)))


def compute_semantic_vector(situation: dict, now: float | None = None) -> dict:
    now_ts = float(situation["clock"]["timestamp"] if now is None else now)
    devices = situation.get("devices") or {}
    mobility = situation.get("mobility_and_place") or {}
    body = situation.get("body_and_sleep") or {}
    schedule = situation.get("schedule") or {}

    phone = devices.get("phone")
    phone_vec = None
    if isinstance(phone, dict) and not phone.get("stale"):
        audio = phone.get("audio_route")
        phone_vec = {
            "battery_band": _battery_band(phone.get("battery_level")),
            "battery_state": phone.get("battery_state"),
            "low_power_mode": bool(phone.get("low_power_mode")),
            "audio_port_type": audio.get("port_type") if isinstance(audio, dict) else None,
        }

    watch = devices.get("watch")
    watch_vec = None
    if isinstance(watch, dict) and not watch.get("stale"):
        watch_vec = {
            "battery_band": _battery_band(watch.get("battery_level")),
            "battery_state": watch.get("battery_state"),
            "activity": watch.get("activity"),
        }

    mac = devices.get("mac") or {}
    mac_vec = {
        "battery_band": _battery_band(mac.get("battery_level")),
        "power_source": mac.get("power_source"),
        "user_active": mac.get("user_active_at_mac"),
    }

    motion = mobility.get("motion")
    motion_act = motion.get("activity") if isinstance(motion, dict) else None

    visit = mobility.get("visit")
    visit_vec = (
        {"id": visit.get("id"), "ongoing": bool(visit.get("ongoing"))}
        if isinstance(visit, dict)
        else None
    )

    sleep = body.get("latest_sleep")
    sleep_id = sleep.get("id") if isinstance(sleep, dict) else None

    workouts = body.get("recent_workouts") or []
    workout_id = workouts[0].get("id") if workouts else None

    upcoming = schedule.get("upcoming_events") or []
    reminders = schedule.get("due_reminders") or []
    schedule_sig = digest(
        canonical({
            "events": [(e["id"], e["title"], e["start"], e["end"]) for e in upcoming],
            "reminders": [(r["id"], r["title"], r.get("due_at")) for r in reminders],
        })
    )[:16]
    has_schedule = bool(upcoming or reminders)

    return {
        "structural": {
            "sleep_id": sleep_id,
            "workout_id": workout_id,
            "visit": visit_vec,
            "schedule_sig": schedule_sig,
        },
        "quantized": {
            "phone": phone_vec,
            "watch": watch_vec,
            "mac": mac_vec,
            "motion": motion_act,
            "horizon_bucket": int(now_ts // PULSE_INTERVAL_SECONDS) if has_schedule else None,
        },
    }


def semantic_fingerprint(vector: dict) -> str:
    return digest(canonical(vector))


def is_quiet_night_suppressed(situation: dict, now_ts: float, prev_vector: dict | None = None) -> bool:
    """Suppress pulses during 00:00–06:30 local sleep hours unless waking up or an event is within 90m."""
    hm = str(situation.get("clock", {}).get("time") or "12:00")
    try:
        hour_s, min_s = hm.split(":", 1)
        local_minutes = int(hour_s) * 60 + int(min_s)
    except ValueError:
        return False

    if local_minutes >= 6 * 60 + 30:
        return False

    schedule = situation.get("schedule") or {}
    for ev in schedule.get("upcoming_events") or []:
        if not ev.get("all_day") and (ev.get("ongoing") or 0 <= float(ev.get("starts_in_minutes") or 9999) <= 90):
            return False
    for rem in schedule.get("due_reminders") or []:
        due_at = rem.get("due_at")
        if due_at is not None and now_ts <= float(due_at) <= now_ts + PULSE_INTERVAL_SECONDS:
            return False

    mobility = situation.get("mobility_and_place") or {}
    motion = mobility.get("motion")
    if isinstance(motion, dict) and motion.get("activity") in ("walking", "running", "cycling", "automotive"):
        return False

    watch = (situation.get("devices") or {}).get("watch")
    if isinstance(watch, dict) and not watch.get("stale") and watch.get("activity") in ("recording", "workout"):
        return False

    sleep = (situation.get("body_and_sleep") or {}).get("latest_sleep")
    prev_sleep_id = (prev_vector or {}).get("structural", {}).get("sleep_id") if isinstance(prev_vector, dict) else None
    if (
        isinstance(sleep, dict)
        and local_minutes >= 5 * 60
        and sleep.get("id") != prev_sleep_id
        and float(sleep.get("age_seconds") or 99999) <= 1800
    ):
        return False

    return True


def describe_deltas(prev_vector: dict | None, curr_vector: dict) -> list[str]:
    if not isinstance(prev_vector, dict):
        return ["首次建立全维态势巡检基线"]

    deltas: list[str] = []
    p_struct = prev_vector.get("structural") or {}
    c_struct = curr_vector.get("structural") or {}
    p_quant = prev_vector.get("quantized") or {}
    c_quant = curr_vector.get("quantized") or {}

    if c_struct.get("sleep_id") and c_struct.get("sleep_id") != p_struct.get("sleep_id"):
        deltas.append("新增已完成睡眠记录")
    if c_struct.get("workout_id") and c_struct.get("workout_id") != p_struct.get("workout_id"):
        deltas.append("新增运动锻炼记录")
    if c_struct.get("visit") != p_struct.get("visit"):
        cv = c_struct.get("visit")
        if cv is None:
            deltas.append("到访地点快照状态变化")
        elif cv.get("ongoing"):
            deltas.append("新到达或停留地点更新（当前停留中）")
        else:
            deltas.append("离开上一个停留地点")
    if c_struct.get("schedule_sig") != p_struct.get("schedule_sig"):
        deltas.append("未来 12 小时日历日程或待办提醒发生变更")

    if c_quant.get("motion") != p_quant.get("motion"):
        deltas.append(f"出行/运动姿态变化：{p_quant.get('motion') or '无'} -> {c_quant.get('motion') or '无'}")

    p_phone = p_quant.get("phone") or {}
    c_phone = c_quant.get("phone") or {}
    if c_phone != p_phone:
        if c_phone.get("audio_port_type") != p_phone.get("audio_port_type"):
            deltas.append(
                f"手机音频输出路由切换：{p_phone.get('audio_port_type') or '默认'} -> {c_phone.get('audio_port_type') or '默认'}"
            )
        if (
            c_phone.get("battery_band") != p_phone.get("battery_band")
            or c_phone.get("battery_state") != p_phone.get("battery_state")
        ):
            cb = f"{c_phone['battery_band'] * 10}%档" if c_phone.get("battery_band") is not None else "未知"
            deltas.append(f"手机电量/充电状态变化：{cb} ({c_phone.get('battery_state') or '未知'})")

    p_watch = p_quant.get("watch") or {}
    c_watch = c_quant.get("watch") or {}
    if c_watch != p_watch:
        if c_watch.get("activity") != p_watch.get("activity"):
            deltas.append(f"手表工作状态变化：{p_watch.get('activity') or '无'} -> {c_watch.get('activity') or '无'}")
        elif c_watch.get("battery_band") != p_watch.get("battery_band") or c_watch.get("battery_state") != p_watch.get("battery_state"):
            wb = f"{c_watch['battery_band'] * 10}%档" if c_watch.get("battery_band") is not None else "未知"
            deltas.append(f"手表电量/充电状态变化：{wb} ({c_watch.get('battery_state') or '未知'})")

    p_mac = p_quant.get("mac") or {}
    c_mac = c_quant.get("mac") or {}
    if c_mac.get("user_active") != p_mac.get("user_active"):
        deltas.append("Mac 桌面活跃状态变化：" + ("用户在桌前活跃" if c_mac.get("user_active") else "用户离开桌面/空闲"))

    if not deltas:
        deltas.append("各设备与生理传感器状态平稳（例行 1.5 小时全维巡检，请重点审视临近日程、待办推进与精力匹配）")
    return deltas


def format_pulse_brief(situation: dict, deltas: list[str]) -> str:
    clock = situation["clock"]
    devices = situation["devices"]
    mobility = situation["mobility_and_place"]
    body = situation["body_and_sleep"]
    schedule = situation["schedule"]

    lines: list[str] = [
        f"[MoMo 全维生活态势脉搏 | 时间={clock['iso_local']} ({clock['weekday_zh']}) | 时区={clock['timezone']}]",
        "",
        "[当前全维态势]",
        f"- 概览：{situation['concise_summary'] or '暂无活跃实时摘要'}",
    ]

    mac = devices.get("mac") or {}
    mac_parts = []
    if mac.get("battery_level") is not None:
        mac_parts.append(f"电量 {round(mac['battery_level'] * 100)}% ({mac.get('battery_state') or mac.get('power_source') or 'unknown'})")
    elif mac.get("power_source"):
        mac_parts.append(f"电源 {mac['power_source']}")
    if mac.get("hid_idle_seconds") is not None:
        mac_parts.append(f"桌面空闲 {int(mac['hid_idle_seconds'])}s ({'活跃' if mac.get('user_active_at_mac') else '空闲'})")
    if mac_parts:
        lines.append(f"- Mac：{'，'.join(mac_parts)}")

    phone = devices.get("phone")
    if isinstance(phone, dict):
        p_parts = []
        if phone.get("battery_level") is not None:
            p_parts.append(f"电量 {round(phone['battery_level'] * 100)}% ({phone.get('battery_state')})")
        if phone.get("low_power_mode"):
            p_parts.append("低电量模式开启")
        if isinstance(phone.get("audio_route"), dict):
            ar = phone["audio_route"]
            p_parts.append(f"音频路由 {ar['port_name']} ({ar['port_type']})")
        p_parts.append(f"采样距今 {int(phone.get('age_seconds') or 0)}s" + (" [已陈旧]" if phone.get("stale") else ""))
        lines.append(f"- iPhone：{'，'.join(p_parts)}")

    watch = devices.get("watch")
    if isinstance(watch, dict):
        w_parts = [f"状态 {watch.get('activity')}"]
        if watch.get("battery_level") is not None:
            w_parts.append(f"电量 {round(watch['battery_level'] * 100)}% ({watch.get('battery_state')})")
        if (watch.get("pending_chunk_count") or 0) > 0:
            w_parts.append(f"待同步录音分片 {watch['pending_chunk_count']} 个")
        w_parts.append(f"采样距今 {int(watch.get('age_seconds') or 0)}s" + (" [已陈旧]" if watch.get("stale") else ""))
        lines.append(f"- Apple Watch：{'，'.join(w_parts)}")

    motion = mobility.get("motion")
    visit = mobility.get("visit")
    if isinstance(motion, dict) or isinstance(visit, dict):
        mp_parts = []
        if isinstance(motion, dict):
            mp_parts.append(f"实时运动状态={motion['activity']} (距今 {int(motion['age_seconds'])}s)")
        if isinstance(visit, dict):
            v_status = "停留中" if visit.get("ongoing") else f"已离开({visit.get('end_local')})"
            mp_parts.append(
                f"最近地点停留=({visit['latitude']:.4f}, {visit['longitude']:.4f}, ±{int(visit['accuracy'])}m, "
                f"到达 {visit.get('start_local') or '未知'}, {v_status})"
            )
        lines.append(f"- 出行与位置：{'；'.join(mp_parts)}")

    sleep = body.get("latest_sleep")
    if isinstance(sleep, dict):
        st = sleep["stages_hours"]
        lines.append(
            f"- 最近睡眠：{sleep['start_iso']} ~ {sleep['end_iso']}，"
            f"总入睡 {sleep['asleep_hours']:.2f}h / 卧床 {sleep['in_bed_hours']:.2f}h "
            f"(深睡 {st['deep']:.1f}h, 核心 {st['core']:.1f}h, REM {st['rem']:.1f}h, 清醒 {st['awake']:.1f}h)"
        )

    today_act = body.get("today_activity") or {}
    act_parts = []
    if today_act.get("steps") is not None:
        act_parts.append(f"今日步数 {int(round(today_act['steps']))}")
    ring = today_act.get("activity_summary")
    if isinstance(ring, dict):
        act_parts.append(
            f"活动圆环({ring['date']}) 活动能量 {int(ring['active_energy_kcal'])}/{int(ring['active_energy_goal_kcal'])}kcal、"
            f"锻炼 {int(ring['exercise_minutes'])}/{int(ring['exercise_goal_minutes'])}min、"
            f"站立 {int(ring['stand_hours'])}/{int(ring['stand_goal_hours'])}h"
        )
    if act_parts:
        lines.append(f"- 今日活动：{'；'.join(act_parts)}")

    workouts = body.get("recent_workouts") or []
    if workouts:
        wk_strs = [
            f"{w['activity_type']} ({w['start_local']}, {w['duration_minutes']}min"
            + (f", {int(w['active_energy_kcal'])}kcal" if w.get("active_energy_kcal") is not None else "")
            + ")"
            for w in workouts[:3]
        ]
        lines.append(f"- 近期运动：{'；'.join(wk_strs)}")

    vitals = body.get("vitals") or {}
    vital_strs = [
        f"{k}={v['value']}{v['unit']}({v['end_local']})"
        for k, v in vitals.items()
        if not v.get("stale")
    ]
    if vital_strs:
        lines.append(f"- 近期生理与环境指标：{'，'.join(vital_strs)}")

    lines.append("")
    lines.append("[较上次巡检的变化]")
    for d in deltas:
        lines.append(f"- {d}")

    lines.append("")
    lines.append("[未来 12 小时日程与待办]")
    upcoming = schedule.get("upcoming_events") or []
    if upcoming:
        for ev in upcoming[:10]:
            when = "全天" if ev["all_day"] else f"{ev['start_local']}–{ev['end_local']}"
            rel = "进行中" if ev["ongoing"] else f"{int(ev['starts_in_minutes'])}分钟后开始"
            lines.append(f"- [日程] {when} 《{ev['title']}》 ({ev['source_name']}, {rel})")
    else:
        lines.append("- 未来 12 小时内暂无日历日程快照")

    reminders = schedule.get("due_reminders") or []
    if reminders:
        for rem in reminders[:10]:
            due_note = (
                f"已逾期({rem['due_local']})"
                if rem["overdue"]
                else (f"截止 {rem['due_local']}" if rem["due_local"] else "无截止时间")
            )
            lines.append(f"- [待办] 《{rem['title']}》 ({rem['source_name']}, {due_note})")
    else:
        lines.append("- 暂无未完成待办提醒快照")

    return "\n".join(lines)


def maybe_emit_pulse(
    store,
    emit_fn: Callable[[dict], object] | None = None,
    *,
    data_dir=None,
    now: float | None = None,
) -> dict | None:
    """Evaluate situational state and emit at most once per uniform 1.5h (5400s) window."""
    now_ts = time.time() if now is None else float(now)
    if not has_situational_evidence(store):
        return None

    situation = read_situational_context(store, data_dir=data_dir, now=now_ts)
    vector = compute_semantic_vector(situation, now=now_ts)
    fp = semantic_fingerprint(vector)

    state = _load_pulse_state(store)
    last_emitted_at = float(state.get("last_emitted_at") or 0.0)
    last_fp = str(state.get("last_semantic_fingerprint") or "")
    last_vector = state.get("last_vector") if isinstance(state.get("last_vector"), dict) else None
    pending_since = state.get("pending_delta_since")

    if last_emitted_at > 0 and (now_ts - last_emitted_at) < PULSE_INTERVAL_SECONDS:
        if fp != last_fp and pending_since is None:
            state["pending_delta_since"] = now_ts
            _save_pulse_state(store, state)
        return None

    if is_quiet_night_suppressed(situation, now_ts, prev_vector=last_vector):
        if fp != last_fp and pending_since is None:
            state["pending_delta_since"] = now_ts
            _save_pulse_state(store, state)
        return None

    deltas = describe_deltas(last_vector, vector)
    day = situation["clock"]["date"]
    stamp = f"{int(now_ts)}-{fp[:8]}"
    summary_tail = situation["concise_summary"][:60] if situation["concise_summary"] else clock_title(situation)
    payload = {
        "kind": "life_signals",
        "id": f"pulse-{stamp}",
        "thread_id": f"momo:pulse:{day}",
        "title": f"生活态势脉搏 · {summary_tail}",
        "text": format_pulse_brief(situation, deltas),
    }

    if emit_fn is not None:
        emit_fn(payload)

    _save_pulse_state(
        store,
        {
            "last_emitted_at": now_ts,
            "last_semantic_fingerprint": fp,
            "last_vector": vector,
            "pending_delta_since": None,
        },
    )
    return {
        "payload": payload,
        "deltas": deltas,
        "semantic_fingerprint": fp,
        "emitted_at": now_ts,
    }


def clock_title(situation: dict) -> str:
    c = situation.get("clock") or {}
    return f"{c.get('date', '')} {c.get('time', '')}".strip()
