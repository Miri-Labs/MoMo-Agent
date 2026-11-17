"""Synthesize a unified, factual Jarvis situational context snapshot across devices, mobility, body, and schedule."""
from __future__ import annotations

import datetime as _dt
import json
import time
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from device_telemetry import probe_mac_telemetry

WEEKDAYS_ZH = ("周一", "周二", "周三", "周四", "周五", "周六", "周日")

MOTION_LABELS_ZH = {
    "walking": "步行中",
    "running": "跑步中",
    "cycling": "骑行中",
    "automotive": "乘车中",
}

WATCH_ACTIVITY_LABELS_ZH = {
    "recording": "录音中",
    "syncing": "同步中",
    "workout": "运动中",
}

BUILTIN_AUDIO_PORTS = frozenset({
    "Receiver",
    "Speaker",
    "AVAudioSessionPortBuiltInReceiver",
    "AVAudioSessionPortBuiltInSpeaker",
    "Built-In Receiver",
    "Built-In Speaker",
})

VITAL_KEYS = (
    "heart_rate",
    "resting_heart_rate",
    "hrv_sdnn",
    "oxygen_saturation",
    "respiratory_rate",
    "wrist_temperature",
    "vo2_max",
    "environmental_audio_exposure",
    "headphone_audio_exposure",
)


def _resolve_timezone(candidates: list[str], now_ts: float) -> tuple[_dt.tzinfo, str]:
    for zone_name in candidates:
        if isinstance(zone_name, str) and zone_name.strip():
            try:
                return ZoneInfo(zone_name.strip()), zone_name.strip()
            except ZoneInfoNotFoundError:
                continue
    local_dt = _dt.datetime.fromtimestamp(now_ts).astimezone()
    return local_dt.tzinfo or _dt.timezone.utc, str(local_dt.tzname() or "local")


def _fmt_hm(ts: float, tz: _dt.tzinfo) -> str:
    return _dt.datetime.fromtimestamp(float(ts), tz).strftime("%H:%M")


def _fmt_iso(ts: float, tz: _dt.tzinfo) -> str:
    return _dt.datetime.fromtimestamp(float(ts), tz).isoformat(timespec="minutes")


def _age_tag(age_seconds: float) -> str | None:
    if age_seconds > 900:
        return f"{int(age_seconds // 60)}m前"
    return None


def _load_latest_snapshots(store, table: str, extra_where: str = "", params: tuple = ()) -> list[dict]:
    sql = f"SELECT payload, synced_at FROM {table}"
    if extra_where:
        sql += f" WHERE {extra_where}"
    rows = store.db.execute(sql, params).fetchall()
    docs = []
    for row in rows:
        try:
            doc = json.loads(row["payload"])
            doc["_synced_at"] = row["synced_at"]
            docs.append(doc)
        except Exception:
            continue
    docs.sort(key=lambda d: float(d.get("observed_at") or 0.0), reverse=True)
    return docs


def _build_concise_summary(
    *,
    devices: dict,
    mobility: dict,
    body: dict,
    schedule: dict,
    now_ts: float,
) -> str:
    parts: list[str] = []

    watch = devices.get("watch")
    if isinstance(watch, dict) and not watch.get("stale"):
        w_tags: list[str] = []
        act = str(watch.get("activity") or "").strip()
        if act in WATCH_ACTIVITY_LABELS_ZH:
            w_tags.append(WATCH_ACTIVITY_LABELS_ZH[act])
        elif act and act.lower() not in ("idle", "standby", "none", "unknown"):
            w_tags.append(act[:12])
        if watch.get("battery_state") == "charging":
            w_tags.append("充电中")
        if (watch.get("pending_chunk_count") or 0) > 0 and "录音中" not in w_tags:
            w_tags.append(f"待传{watch['pending_chunk_count']}段")
        w_age = _age_tag(float(watch.get("age_seconds") or 0.0))
        if w_age:
            w_tags.append(w_age)
        batt = watch.get("battery_level")
        head = f"手表 {round(batt * 100)}%" if batt is not None else "手表"
        parts.append(f"{head}({', '.join(w_tags)})" if w_tags else head)

    phone = devices.get("phone")
    motion = mobility.get("motion")
    if isinstance(phone, dict) and not phone.get("stale"):
        p_tags: list[str] = []
        audio = phone.get("audio_route")
        if isinstance(audio, dict):
            port_type = str(audio.get("port_type") or "")
            port_name = str(audio.get("port_name") or "").strip()
            if port_name and port_type not in BUILTIN_AUDIO_PORTS and port_name not in BUILTIN_AUDIO_PORTS:
                p_tags.append(port_name[:20])
        if isinstance(motion, dict):
            m_label = MOTION_LABELS_ZH.get(str(motion.get("activity") or ""))
            if m_label:
                p_tags.append(m_label)
        if phone.get("battery_state") == "charging":
            p_tags.append("充电中")
        elif phone.get("low_power_mode"):
            p_tags.append("低电量模式")
        p_age = _age_tag(float(phone.get("age_seconds") or 0.0))
        if p_age:
            p_tags.append(p_age)
        batt = phone.get("battery_level")
        head = f"手机 {round(batt * 100)}%" if batt is not None else "手机"
        parts.append(f"{head}({', '.join(p_tags)})" if p_tags else head)
    elif isinstance(motion, dict):
        m_label = MOTION_LABELS_ZH.get(str(motion.get("activity") or ""))
        if m_label:
            m_age = _age_tag(float(motion.get("age_seconds") or 0.0))
            parts.append(f"{m_label}({m_age})" if m_age else m_label)

    mac = devices.get("mac") or {}
    mac_batt = mac.get("battery_level")
    mac_active = mac.get("user_active_at_mac")
    if mac_batt is not None or mac_active is not None:
        m_tags: list[str] = []
        if mac.get("power_source") == "ac" and mac_batt is not None:
            m_tags.append("外接电源")
        elif mac.get("battery_state") == "charging":
            m_tags.append("充电中")
        if mac_active is True:
            m_tags.append("桌面活跃")
        elif mac_active is False and (mac.get("hid_idle_seconds") or 0) >= 900:
            m_tags.append(f"桌面空闲{int(mac['hid_idle_seconds'] // 60)}m")
        if mac_batt is not None:
            head = f"Mac {round(mac_batt * 100)}%"
            parts.append(f"{head}({', '.join(m_tags)})" if m_tags else head)
        elif m_tags:
            parts.append(f"Mac({', '.join(m_tags)})")

    sleep = body.get("latest_sleep")
    if isinstance(sleep, dict) and float(sleep.get("age_seconds") or 0.0) <= 20 * 3600 and (sleep.get("asleep_hours") or 0) > 0:
        parts.append(
            f"睡眠 {sleep['bedtime_local']}–{sleep['wake_time_local']}({sleep['asleep_hours']:.1f}h)"
        )

    today_act = body.get("today_activity") or {}
    steps = today_act.get("steps")
    if steps is not None and float(today_act.get("steps_age_seconds") or 0.0) <= 12 * 3600:
        steps_age = _age_tag(float(today_act.get("steps_age_seconds") or 0.0))
        step_str = f"今日 {int(round(steps))} 步"
        if steps_age and len(parts) < 3:
            step_str += f"({steps_age})"
        parts.append(step_str)

    visit = mobility.get("visit")
    if isinstance(visit, dict) and visit.get("title") and not visit.get("stale"):
        v_title = str(visit["title"]).strip()[:20]
        if v_title:
            parts.append(f"位置 {v_title}")

    upcoming = schedule.get("upcoming_events") or []
    if upcoming:
        ev0 = upcoming[0]
        mins = float(ev0.get("starts_in_minutes") or 0.0)
        if mins <= 120:
            title_short = str(ev0.get("title") or "日程")[:14]
            parts.append(f"日程 {ev0['start_local']} {title_short}")

    out: list[str] = []
    for seg in parts:
        candidate = " · ".join([*out, seg])
        if len(candidate) >= 240:
            break
        out.append(seg)
    return " · ".join(out)[:239]


def read_situational_context(store, data_dir=None, now: float | None = None) -> dict:
    now_ts = time.time() if now is None else float(now)

    telemetry_docs = _load_latest_snapshots(store, "device_telemetry_snapshots")
    health_docs = _load_latest_snapshots(store, "health_snapshots")
    motion_docs = _load_latest_snapshots(store, "phone_source_snapshots", "kind=?", ("motion",))
    visit_docs = _load_latest_snapshots(store, "phone_source_snapshots", "kind=?", ("visits",))
    calendar_docs = _load_latest_snapshots(store, "phone_source_snapshots", "kind=?", ("calendar",))
    reminder_docs = _load_latest_snapshots(store, "phone_source_snapshots", "kind=?", ("reminders",))

    tz_candidates = [
        doc.get("timezone")
        for group in (telemetry_docs, motion_docs, calendar_docs, health_docs, visit_docs, reminder_docs)
        for doc in group
        if doc.get("state") in ("enabled", "foreground_only")
    ]
    tz, tz_name = _resolve_timezone(tz_candidates, now_ts)
    now_dt = _dt.datetime.fromtimestamp(now_ts, tz)
    today_str = now_dt.strftime("%Y-%m-%d")
    yesterday_str = (now_dt.date() - _dt.timedelta(days=1)).isoformat()

    clock = {
        "timestamp": now_ts,
        "iso_local": now_dt.isoformat(timespec="seconds"),
        "date": today_str,
        "time": now_dt.strftime("%H:%M"),
        "weekday": now_dt.strftime("%A"),
        "weekday_zh": WEEKDAYS_ZH[now_dt.weekday()],
        "timezone": tz_name,
    }

    # 2. Devices (Mac + iPhone + Watch)
    mac_info = probe_mac_telemetry(now=now_ts)
    enabled_telemetry = next((d for d in telemetry_docs if d.get("state") == "enabled"), None)
    telemetry_state = (
        "enabled"
        if enabled_telemetry is not None
        else (telemetry_docs[0]["state"] if telemetry_docs else "not_synced")
    )
    phone_info = None
    watch_info = None
    if enabled_telemetry is not None:
        obs_age = round(max(0.0, now_ts - float(enabled_telemetry["observed_at"])), 1)
        if isinstance(enabled_telemetry.get("phone"), dict):
            phone_info = {
                "device_id": enabled_telemetry["device_id"],
                "revision": enabled_telemetry["revision"],
                "observed_at": enabled_telemetry["observed_at"],
                "age_seconds": obs_age,
                "stale": obs_age > 1800,
                **enabled_telemetry["phone"],
            }
        if isinstance(enabled_telemetry.get("watch"), dict):
            w_raw = enabled_telemetry["watch"]
            w_age = round(max(0.0, now_ts - float(w_raw["sampled_at"])), 1)
            watch_info = {
                **w_raw,
                "age_seconds": w_age,
                "stale": w_age > 1800,
            }
    devices = {
        "telemetry_state": telemetry_state,
        "mac": mac_info,
        "phone": phone_info,
        "watch": watch_info,
    }

    # 3. Mobility & Place
    enabled_motion = next((d for d in motion_docs if d.get("state") == "enabled"), None)
    motion_state = (
        "enabled"
        if enabled_motion is not None
        else (motion_docs[0]["state"] if motion_docs else "not_synced")
    )
    motion_info = None
    if enabled_motion is not None and enabled_motion.get("records"):
        recs = sorted(
            enabled_motion["records"],
            key=lambda r: (float(r.get("end", r["start"])), float(r["start"])),
        )
        latest_m = recs[-1]
        snap_age = max(0.0, now_ts - float(enabled_motion["observed_at"]))
        rec_age = max(0.0, now_ts - float(latest_m["end"])) if "end" in latest_m else snap_age
        if snap_age < 1800 and rec_age < 1800:
            motion_info = {
                "id": latest_m["id"],
                "activity": latest_m["title"],
                "start": latest_m["start"],
                "end": latest_m.get("end"),
                "source_name": latest_m["source_name"],
                "age_seconds": round(rec_age, 1),
                "snapshot_age_seconds": round(snap_age, 1),
            }
        else:
            motion_state = "stale"

    enabled_visits = next((d for d in visit_docs if d.get("state") in ("enabled", "foreground_only")), None)
    visit_info = None
    if enabled_visits is not None and enabled_visits.get("records"):
        v_recs = sorted(
            enabled_visits["records"],
            key=lambda r: (
                float(r.get("end", float("inf")) if "start" in r and "end" not in r else max(r.get("start", 0), r.get("end", 0))),
                float(r.get("start", 0)),
            ),
        )
        latest_v = v_recs[-1]
        ongoing = "start" in latest_v and "end" not in latest_v
        v_title = (latest_v.get("title") or "").strip() or None
        visit_ref_ts = float(latest_v.get("end", latest_v.get("start", now_ts)))
        visit_age = round(max(0.0, now_ts - visit_ref_ts), 1)
        visit_snap_age = round(max(0.0, now_ts - float(enabled_visits["observed_at"])), 1)
        visit_stale = bool(not ongoing and (visit_age > 12 * 3600 or visit_snap_age > 24 * 3600))
        visit_info = {
            "id": latest_v["id"],
            **({"title": v_title} if v_title else {}),
            "latitude": latest_v["latitude"],
            "longitude": latest_v["longitude"],
            "accuracy": latest_v["accuracy"],
            "start": latest_v.get("start"),
            "end": latest_v.get("end"),
            "start_local": _fmt_iso(latest_v["start"], tz) if "start" in latest_v else None,
            "end_local": _fmt_iso(latest_v["end"], tz) if "end" in latest_v else None,
            "ongoing": ongoing,
            "source_name": latest_v["source_name"],
            "age_seconds": visit_age,
            "snapshot_age_seconds": visit_snap_age,
            "stale": visit_stale,
        }
    mobility_and_place = {
        "motion_state": motion_state,
        "motion": motion_info,
        "visit_state": enabled_visits["state"] if enabled_visits else (visit_docs[0]["state"] if visit_docs else "not_synced"),
        "visit": visit_info,
    }

    # 4. Body & Sleep
    enabled_health = next((d for d in health_docs if d.get("state") == "enabled"), None)
    health_state = (
        "enabled"
        if enabled_health is not None
        else (health_docs[0]["state"] if health_docs else "not_synced")
    )
    latest_sleep = None
    today_activity = {"date": today_str, "steps": None, "steps_age_seconds": None, "activity_summary": None}
    recent_workouts: list[dict] = []
    vitals: dict[str, dict] = {}

    if enabled_health is not None:
        sleep_list = sorted(enabled_health.get("sleep_sessions") or [], key=lambda s: float(s["end"]), reverse=True)
        if sleep_list:
            s0 = sleep_list[0]
            s_age = round(max(0.0, now_ts - float(s0["end"])), 1)
            latest_sleep = {
                "id": s0["id"],
                "start": s0["start"],
                "end": s0["end"],
                "bedtime_local": _fmt_hm(s0["start"], tz),
                "wake_time_local": _fmt_hm(s0["end"], tz),
                "start_iso": _fmt_iso(s0["start"], tz),
                "end_iso": _fmt_iso(s0["end"], tz),
                "asleep_hours": round(float(s0["asleep_seconds"]) / 3600.0, 2),
                "in_bed_hours": round(float(s0["in_bed_seconds"]) / 3600.0, 2),
                "stages_hours": {
                    "deep": round(float(s0["deep_seconds"]) / 3600.0, 2),
                    "core": round(float(s0["core_seconds"]) / 3600.0, 2),
                    "rem": round(float(s0["rem_seconds"]) / 3600.0, 2),
                    "awake": round(float(s0["awake_seconds"]) / 3600.0, 2),
                },
                "age_seconds": s_age,
                "age_hours": round(s_age / 3600.0, 1),
                "stale": s_age > 24 * 3600,
                "source_name": s0["source_name"],
            }

        rings = sorted(enabled_health.get("activity_summaries") or [], key=lambda a: a["date"], reverse=True)
        today_ring = next((a for a in rings if a["date"] == today_str), rings[0] if rings else None)
        today_activity["activity_summary"] = today_ring

        obs_sorted = sorted(
            enabled_health.get("observations") or [],
            key=lambda o: (float(o["end"]), float(o["start"])),
        )
        today_steps_obs = [
            o for o in obs_sorted
            if o["metric"] == "steps"
            and _dt.datetime.fromtimestamp(float(o["end"]), tz).strftime("%Y-%m-%d") == today_str
        ]
        if not today_steps_obs:
            today_steps_obs = [
                o for o in obs_sorted
                if o["metric"] == "steps" and (now_ts - float(o["end"])) <= 18 * 3600
            ]
        if today_steps_obs:
            st_obs = today_steps_obs[-1]
            today_activity["steps"] = st_obs["value"]
            today_activity["steps_age_seconds"] = round(max(0.0, now_ts - float(st_obs["end"])), 1)

        for obs in obs_sorted:
            metric = obs["metric"]
            if metric in VITAL_KEYS:
                age_s = round(max(0.0, now_ts - float(obs["end"])), 1)
                stale_cutoff = 86400 if metric in ("resting_heart_rate", "vo2_max", "wrist_temperature") else 7200
                vitals[metric] = {
                    "value": obs["value"],
                    "unit": obs["unit"],
                    "end": obs["end"],
                    "end_local": _fmt_hm(obs["end"], tz),
                    "age_seconds": age_s,
                    "stale": age_s > stale_cutoff,
                    "source_name": obs["source_name"],
                }

        for wk in sorted(enabled_health.get("workouts") or [], key=lambda w: float(w["end"]), reverse=True):
            wk_day = _dt.datetime.fromtimestamp(float(wk["end"]), tz).strftime("%Y-%m-%d")
            if wk_day in (today_str, yesterday_str) or (now_ts - float(wk["end"])) <= 48 * 3600:
                recent_workouts.append({
                    "id": wk["id"],
                    "activity_type": wk["activity_type"],
                    "start": wk["start"],
                    "end": wk["end"],
                    "start_local": _fmt_iso(wk["start"], tz),
                    "end_local": _fmt_iso(wk["end"], tz),
                    "duration_minutes": round(float(wk["duration_seconds"]) / 60.0, 1),
                    "active_energy_kcal": wk.get("active_energy_kcal"),
                    "distance_meters": wk.get("distance_meters"),
                    "age_seconds": round(max(0.0, now_ts - float(wk["end"])), 1),
                    "source_name": wk["source_name"],
                })

    body_and_sleep = {
        "health_state": health_state,
        "latest_sleep": latest_sleep,
        "today_activity": today_activity,
        "recent_workouts": recent_workouts[:10],
        "vitals": vitals,
    }

    # 5. Schedule (next 12h immediate calendar events + 12-36h extended horizon + due/overdue/incomplete reminders top 10)
    enabled_cal = next((d for d in calendar_docs if d.get("state") == "enabled"), None)
    upcoming_events: list[dict] = []
    extended_events: list[dict] = []
    if enabled_cal is not None:
        horizon_12h = now_ts + 12 * 3600
        horizon_36h = now_ts + 36 * 3600
        cal_records = enabled_cal.get("records") or []
        matching_events = [
            ev for ev in cal_records
            if float(ev["end"]) >= now_ts and float(ev["start"]) <= horizon_12h
        ]
        matching_events.sort(key=lambda ev: (bool(ev.get("all_day")), float(ev["start"])))
        for ev in matching_events[:20]:
            s_ts = float(ev["start"])
            e_ts = float(ev["end"])
            upcoming_events.append({
                "id": ev["id"],
                "title": ev.get("title") or "(无标题日程)",
                "source_name": ev["source_name"],
                "all_day": bool(ev.get("all_day")),
                "start": s_ts,
                "end": e_ts,
                "start_local": _fmt_hm(s_ts, tz) if not ev.get("all_day") else _dt.datetime.fromtimestamp(s_ts, tz).strftime("%Y-%m-%d"),
                "end_local": _fmt_hm(e_ts, tz) if not ev.get("all_day") else _dt.datetime.fromtimestamp(e_ts, tz).strftime("%Y-%m-%d"),
                "starts_in_minutes": round((s_ts - now_ts) / 60.0, 1),
                "ongoing": s_ts <= now_ts <= e_ts,
            })

        later_events = [
            ev for ev in cal_records
            if horizon_12h < float(ev["start"]) <= horizon_36h
        ]
        later_events.sort(key=lambda ev: (bool(ev.get("all_day")), float(ev["start"])))
        for ev in later_events[:15]:
            s_ts = float(ev["start"])
            e_ts = float(ev["end"])
            extended_events.append({
                "id": ev["id"],
                "title": ev.get("title") or "(无标题日程)",
                "source_name": ev["source_name"],
                "all_day": bool(ev.get("all_day")),
                "start": s_ts,
                "end": e_ts,
                "start_local": _fmt_iso(s_ts, tz) if not ev.get("all_day") else _dt.datetime.fromtimestamp(s_ts, tz).strftime("%Y-%m-%d"),
                "end_local": _fmt_iso(e_ts, tz) if not ev.get("all_day") else _dt.datetime.fromtimestamp(e_ts, tz).strftime("%Y-%m-%d"),
                "starts_in_hours": round((s_ts - now_ts) / 3600.0, 1),
            })

    enabled_rem = next((d for d in reminder_docs if d.get("state") == "enabled"), None)
    due_reminders: list[dict] = []
    if enabled_rem is not None:
        rem_records = list(enabled_rem.get("records") or [])
        rem_records.sort(
            key=lambda r: (
                0 if ("start" in r and float(r["start"]) <= now_ts + 36 * 3600) else (1 if "start" in r else 2),
                float(r.get("start", float("inf"))),
                str(r["id"]),
            )
        )
        for rem in rem_records[:10]:
            due_ts = float(rem["start"]) if "start" in rem else None
            due_reminders.append({
                "id": rem["id"],
                "title": rem.get("title") or "(无标题提醒)",
                "source_name": rem["source_name"],
                "due_at": due_ts,
                "due_local": _fmt_iso(due_ts, tz) if due_ts is not None else None,
                "due_in_hours": round((due_ts - now_ts) / 3600.0, 1) if due_ts is not None else None,
                "overdue": bool(due_ts is not None and due_ts < now_ts),
            })

    schedule = {
        "calendar_state": enabled_cal["state"] if enabled_cal else (calendar_docs[0]["state"] if calendar_docs else "not_synced"),
        "reminders_state": enabled_rem["state"] if enabled_rem else (reminder_docs[0]["state"] if reminder_docs else "not_synced"),
        "upcoming_events": upcoming_events,
        "extended_events": extended_events,
        "due_reminders": due_reminders,
    }

    concise_summary = _build_concise_summary(
        devices=devices,
        mobility=mobility_and_place,
        body=body_and_sleep,
        schedule=schedule,
        now_ts=now_ts,
    )

    return {
        "clock": clock,
        "devices": devices,
        "mobility_and_place": mobility_and_place,
        "body_and_sleep": body_and_sleep,
        "schedule": schedule,
        "concise_summary": concise_summary,
    }
