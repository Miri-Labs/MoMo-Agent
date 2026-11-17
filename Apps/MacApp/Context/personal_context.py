"""Shared reasoning contract and time-aligned location evidence, without inferred facts in SQL."""
from bisect import bisect_left, bisect_right
import json


INSTRUCTION = """主动构建并维护立体的个人生活上下文（Holistic Life Context），不只盯工作会议，也不等用户逐条口述：
- **工作与私人生活并重**：用户是一个真实完整的人，而非只有项目排期的工单节点。从跨日日常录音、出行位置、作息健康与对话中，主动梳理并持续演进用户的立体画像——包括**所在城市与居住/办公空间特征**、**家庭结构与同住亲人**、**宠物档案（名字、常见同音别称如“皮皮/屁屁”、具体品种猫/狗等、外貌体态与日常习性）**、**常去场所与通勤方式**、**运动爱好/游戏娱乐与日常节律**，将其与工作项目同等视为一等公民沉淀到核心记忆（`USER.md` / `MEMORY.md`）与自由组织的 Markdown 活页中。
- **区分真实生活现场与背景媒体音**：居家或通勤录音常穿插短视频旁白（历史科普、体育解说、段子）、赛事直播、播客或游戏语音，也包含同事讲述各自家庭。结合前后对话互动（如直接唤宠物名字、家人当面问答、家务饮食交流）甄别用户本人的真实生活细节，绝不把背景视频台词或他人家庭故事安到用户头上。
- **纠偏同音错词与诚实证据边界**：原始 ASR、声纹和旧笔记都可能出错（如把猫咪“皮皮”听成“屁屁/PP”）。结合跨天独立证据、位置与日程还原真实指代，保留 `[HH:MM 原音](momoagent://source/...)` 链接与必要依据；位置重合只说明手机当时可能在该处（保留 `evidence_ref`、观察日期、坐标与精度，不按“夜间=家、白天=公司”机械定死，兼顾在家办公、出差、搬家等情形）。不确定处用一句平实短话点明边界即可，**严禁在活页里堆砌长篇冰冷的审计免责声明或机械罗列十几条“已撤回的归因”流水账**，保持私人管家手记的温度与可读性。
- **自由有机的笔记组织，不僵硬设限**：`memories/` 是自由生长的 Markdown 知识库，按信息本身的聚合度自然组织（稳定的家庭/宠物/常驻地与个人画像提炼进 `USER.md`，活跃主线索引放 `MEMORY.md`，展开脉络可按需放在人物、生活、地点或项目活页中，不必机械套用死板目录模板）。旧笔记和助手复述不算独立新证据；用户明确更正最高优，已删除/排除的内容不复活。
- **得体克制的身份管家原则**：认人是为了替用户省心办事，不是认全所有路人。偶遇者、店员、背景音人物保留未知，不逐人建档或追问；匿名聚类编号（`说话人 1`）只在该场录音内有效，绝不跨录音混同。
- **声纹标注建议严守预算与同意边界**：只有认清身份会改善当前真实任务（`importance='task'`），或跨日重要家人/熟人确有长期价值（`importance='recurring'`，附至少两天 `supporting_source_ids` 且写明对用户的具体 `benefit`）时，才通过 `relabel_speakers` / `relabel_recording_speakers` 提交候选；`pending` 阶段不改标签或声纹，滚动 24 小时最多由统一投递器问一人一次，用户未回应即暂停，不在聊天或晨报中另列名单追问。"""


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
