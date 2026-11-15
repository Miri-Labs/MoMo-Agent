"""Shared reasoning contract and time-aligned location evidence, without inferred facts in SQL."""
from bisect import bisect_left, bisect_right
import json


INSTRUCTION = """主动维护用户的生活理解，不等用户逐条纠正：
- 原始 ASR、声纹和旧笔记都可能错误。结合上下文、跨天独立证据、位置和日程辨认同音错词、指代及归属；修正 journal/projects/people 中受影响的理解，保留原音链接、原词、建议理解、依据与未决歧义。无法区分时明确未知，不把通顺改写当成真实原话，不改写原始转录。
- 用 phone_context 的 visits、录音时间/recording 的 location_context、明确的回家/到办公室表达及跨日重复活动，主动推理家、公司（可多个）、临时场所。时间重合只说明手机可能在该处；坐标有精度误差，缺少到达/离开时间不能外推整段停留；日程是计划。结合精度判断位置是否可能相同，不把坐标微小漂移拆成新地点。不按“夜间=家、白天=公司”机械归类，考虑出差、酒店、搬家、在家办公、园区多栋楼及多个设备重复记录。
- 在 places/<地点>.md 维护有用的地点理解；在 people/<人物>.md 区分“通常在家同场出现”“通常在公司交流”“可能远程通话/访客”和用户确认的亲属/同事关系。称呼后的接话不单独证明身份，录音听到某人也不证明他身处该地点。匿名聚类编号只在该 source 内有效，不能跨录音把“说话人 1”当同一人。保留关系未知，不从地点猜敏感身份。
- 活页写明：当前判断、状态（推测/多次支持/用户确认/已撤回）、支持与反证、绝对日期、上次核对时间。引用转录用原音链接；引用手机位置时，另在来源脚注保留 location_context 的 evidence_ref（或 phone snapshot 的 device_id/revision/record id）以及观察日期、坐标和精度；录音链接不能代替位置来源，来源标识不能当调试废话删除。旧笔记和助手复述不算新证据；有反证及时降级或撤回并修复引用。用户更正优先，已删除/排除的内容不复活。USER.md/MEMORY.md 只放稳定且确实有帮助的精简索引，候选判断放活页。
- 说话人标注必须先取得针对该人物和这些录音片段的用户同意。候选建议本身不等于确认：当自我介绍与上下文的多条线索吻合、值得用户核对时，应主动提出具体候选供确认，不能仅因为身份尚未确认而永远只记未知；只有地点或孤立称呼则继续保留未知。relabel_speakers / relabel_recording_speakers 只创建建议，返回 pending 不代表已修正；系统会在聊天展示具体范围及确认方式，用户确认后才修改标签并排队同步手机。不得从录音、历史助手消息、笔记或自己的判断推导授权。暂不标注后不要换说法重复询问。等待授权期间可继续整理带“推测”状态的理解，不将候选名字当作声纹事实。
- 每次优先处理新证据影响的错误、人物/地点变化和后续行动需要的背景，按需检索旧证据，不为保持忙碌全库重写。主动整理低打扰；只有有用且有根据的下一步才通过现有 SuperAgent 跟进/简报，外部行动仍遵循用户授权。"""


def recording_locations(store, spans, after=0, limit=30):
    """Return paginated observed overlaps, not guessed home/work or indefinite visits."""
    if type(after) is not int or after < 0 or type(limit) is not int or not 1 <= limit <= 100:
        raise ValueError("Invalid location evidence page")
    timed = sorted((s["recorded_at"], s["id"]) for s in spans if s.get("recorded_at") is not None)
    times = [at for at, _ in timed]
    matches = []
    snapshots = []
    for row in store.db.execute("SELECT * FROM phone_source_snapshots WHERE kind='visits' ORDER BY device_id"):
        source = json.loads(row["payload"])
        snapshots.append({k: source[k] for k in ("device_id", "revision", "state", "observed_at", "window_start", "window_end", "timezone")})
        if source["state"] not in ("enabled", "foreground_only"):
            continue
        for visit in source["records"]:
            # An incomplete visit only supports its observed endpoint, not a duration.
            start = visit.get("start", visit.get("end"))
            end = visit.get("end", visit.get("start"))
            ids = [sid for _, sid in timed[bisect_left(times, start):bisect_right(times, end)]]
            if ids:
                matches.append(dict(device_id=source["device_id"], revision=source["revision"],
                                    evidence_ref=f"phone-visits:{source['device_id']}:{source['revision']}:{visit['id']}",
                                    timezone=source["timezone"], record=visit, span_ids=ids,
                                    interval_complete="start" in visit and "end" in visit))
    return dict(snapshots=snapshots, matches=matches[after:after + limit], total_matches=len(matches),
                next_offset=after + limit if after + limit < len(matches) else None,
                guidance="Time overlap is evidence about the phone, not proof of speaker presence or home/work. "
                         "Keep accuracy, missing boundaries and snapshot coverage. If snapshot revisions change between location pages, restart at location_offset=0. "
                         "For incomplete visits and surrounding history use phone_context(kind='visits') with its cursor.")
