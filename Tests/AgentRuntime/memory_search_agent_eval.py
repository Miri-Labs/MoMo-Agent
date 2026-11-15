"""Controlled live-model answer evaluation over isolated synthetic personal data.

The LIKE control generously receives the new cross-source/read/variant tools.
Only search matching/ranking/snippets differ, not the model or answer prompt.
This is a small regression experiment, not a production accuracy estimate.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
from pathlib import Path
import sqlite3
import statistics
import tempfile
import time
import uuid

from memory_search_eval import CASES, ContextStore, MoMoMemory, digest
from memory_search import MemorySearch, SEARCH_SCHEMA, READ_SCHEMA
from superagent_gateway import SuperAgentGateway
from superagent_runtime import resolve_superagent_llm

EXTRA_CASES = [
    {"id": "combined", "question": "上线的承载能力处理进度和客户的可用性指标分别是什么？"},
    {"id": "long", "kind": "note", "text": "# 玄武迁移\n" + "历史讨论尚无最终结论。\n" * 1500
     + "最终批准：迁移窗口为周六 03:00；错误率超过 2% 就回滚。",
     "question": "玄武迁移定在什么时候，达到什么条件必须回滚？"},
    {"id": "uncertain", "kind": "chat", "role": "assistant",
     "text": "我猜海鸥计划的预算也许是五十万元，但没有见到用户确认。",
     "question": "海鸥计划已经确定的预算是多少？"},
    {"id": "absent", "question": "我养的宠物叫什么名字？"},
]
FACTS = {
    "capacity": [["八十", "80"], ["周五", "星期五"]],
    "contract": [["99.5"]], "food": [["辣"]],
    "travel": [["东京"]],
    "deadline": [["周一", "星期一"]], "style": [["结论"], ["证据"]],
    "gift": [["修枝剪"]], "release": [["ios"], ["审核", "审查"]],
    "combined": [["八十", "80"], ["周五", "星期五"], ["99.5"]],
    "long": [["周六", "星期六"], ["03:00", "3:00", "3点", "三点"], ["2%", "百分之二"]],
}
PROMPT = (
    "你是用户的个人助手。仅凭检索到的资料回答，查询变体只是搜索假设。"
    "先检索相关资料，再用 read_memory_evidence 核对原文；长文按 next_offset 继续读取。"
    "证据不足可换关键词或分方面补查；助手的猜测不能充当用户确认。"
    "不要把查不到理解为事实不存在，也不要猜出个人事实。"
    "最终只返回 JSON：{\"answer\":\"简短中文回答\",\"evidence_ids\":[\"引用的来源id\"],"
    "\"insufficient\":false}。没有足够依据回答时 insufficient=true。"
)


def seed(data):
    (data / "runtime").mkdir()
    memory = MoMoMemory(data)
    context = ContextStore(data / "context")
    chat = sqlite3.connect(data / "runtime/conversation.sqlite")
    identities = {}
    try:
        chat.executescript("""CREATE TABLE messages(seq INTEGER PRIMARY KEY,role TEXT,content TEXT,
                            created_at REAL,operation_id TEXT);
                            CREATE TABLE inputs(operation_id TEXT,intent TEXT,delivery_state TEXT);""")
        for seq, case in enumerate([*CASES, *EXTRA_CASES], 1):
            if "text" not in case:
                continue
            text = case["text"]
            if case["kind"] == "note":
                path = f"projects/{case['id']}.md"
                if len(text) > 12000:
                    # External Markdown edits are supported, including large documents.
                    target = memory.memories_dir / path
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_text(text, encoding="utf-8")
                else:
                    assert memory.write_notebook(path=path, content=text)["success"]
                identity = "note:" + path
            elif case["kind"] == "chat":
                chat.execute("INSERT INTO messages VALUES(?,?,?,?,NULL)",
                             (seq, case.get("role", "user"), text, seq))
                identity = f"chat:{seq}"
            else:
                def stable(key):
                    return str(uuid.uuid5(uuid.NAMESPACE_URL, case["id"] + key))
                span = stable("span")
                source = context.sync_source(dict(library_id=stable("library"), session_id=stable("session"),
                    device_id=stable("device"), generation=0, version=1, deleted=False, recorded_at=seq,
                    spans=[dict(id=span, text=text, recorded_at=seq)], text_sha256=digest(text)))
                identity = f"recording:{source['source_id']}:{span}"
            identities[case["id"]] = [identity]
        chat.commit()
    finally:
        context.close()
        chat.close()
    for i in range(100):
        assert memory.write_notebook(path=f"noise/{i}.md",
            content=f"# 园区公告 {i}\n本月例行检查消防设施与停车场。")["success"]
    identities["combined"] = [*identities["capacity"], *identities["contract"]]
    identities["absent"] = []
    return identities


def like_search(search, args):
    queries = [args["query"], *args.get("alternative_queries", [])]
    kind, limit = args.get("kind", "all"), args.get("limit", 10)
    with search._index() as db:
        rows = db.execute("SELECT * FROM documents WHERE (?='all' OR kind=?) AND ("
            + " OR ".join("lower(content) LIKE ?" for _ in queries)
            + ") ORDER BY rowid DESC LIMIT ?", (kind, kind, *[f"%{q.lower()}%" for q in queries], limit + 1)).fetchall()
        return {"queries": queries, "matches": [search._result(row, row["content"][:1200], 0,
            len(row["content"])) for row in rows[:limit]], "has_more": len(rows) > limit}


def score(case, answer, expected, trace):
    read_ids = {t["id"] for t in trace if t["name"] == "read_memory_evidence" and "error" not in t}
    citations = set(answer.get("evidence_ids", []))
    grounded = set(expected) <= citations <= read_ids
    text = str(answer.get("answer", "")).casefold()
    facts = all(any(word in text for word in group) for group in FACTS.get(case, []))
    uncertainty = answer.get("insufficient") is (case in ("uncertain", "absent"))
    return {"facts_present": facts, "citations_read": grounded, "uncertainty_correct": uncertainty,
            "passed": facts and grounded and uncertainty}


def run_case(config, case, mode, repetition):
    from openai import OpenAI
    from agent.auxiliary_client import _CodexCompletionsAdapter
    from agent.codex_headers import apply_required_codex_headers
    from agent.process_bootstrap import build_keepalive_http_client

    with tempfile.TemporaryDirectory(prefix="momo-answer-eval-") as directory:
        data = Path(directory)
        expected = seed(data)
        gateway = SuperAgentGateway.__new__(SuperAgentGateway)
        gateway.data = data
        _, _, execute = gateway._build_memory_review_session("synthetic-eval")
        search = MemorySearch(data)
        # Identical tools and prompt: neither agent knows its condition or the gold answers.
        specs = [{"type": "function", "function": spec} for spec in (SEARCH_SCHEMA, READ_SCHEMA)]
        messages = [{"role": "system", "content": PROMPT}, {"role": "user", "content": case["question"]}]
        kwargs = dict(api_key=config["env"]["MOMO_LLM_API_KEY"], base_url=config["base_url"],
                      timeout=90, max_retries=1)
        transport = build_keepalive_http_client(base_url=config["base_url"])
        if transport is not None:
            kwargs["http_client"] = transport
        apply_required_codex_headers(kwargs, access_token=kwargs["api_key"], base_url=config["base_url"])
        trace, answer, started, rounds = [], {}, time.monotonic(), 0
        with OpenAI(**kwargs) as client:
            completions = _CodexCompletionsAdapter(client, config["model_id"])
            # Equal evaluation budget; production retrieval has no new fixed call cap.
            while time.monotonic() - started < 240 and rounds < 12:
                rounds += 1
                resp = completions.create(model=config["model_id"], messages=messages, tools=specs, timeout=90)
                msg = resp.choices[0].message
                calls = getattr(msg, "tool_calls", None) or []
                if not calls:
                    raw = (msg.content or "").strip()
                    if raw.startswith("```"):
                        raw = raw.split("\n", 1)[1].rsplit("```", 1)[0]
                    answer = json.loads(raw)
                    break
                messages.append({"role": "assistant", "content": msg.content,
                    "tool_calls": [{"id": c.id, "type": "function", "function": {
                        "name": c.function.name, "arguments": c.function.arguments}} for c in calls]})
                for call in calls:
                    name, args = call.function.name, json.loads(call.function.arguments or "{}")
                    assert name in {"search_memory", "read_memory_evidence"}
                    result = (like_search(search, args) if mode == "like" and name == "search_memory"
                              else json.loads(execute(name, args)))
                    event = {"name": name, **args}
                    if "error" in result:
                        event["error"] = result["error"]
                    elif name == "search_memory":
                        event["hits"] = [m["id"] for m in result["matches"]]
                    else:
                        event.update(characters=len(result["text"]), next_offset=result["next_offset"])
                    trace.append(event)
                    messages.append({"role": "tool", "tool_call_id": call.id, "name": name,
                                     "content": json.dumps(result, ensure_ascii=False)})
        return {"case": case["id"], "mode": mode, "repetition": repetition,
                "seconds": round(time.monotonic() - started, 2), "rounds": rounds,
                "search_calls": sum(t["name"] == "search_memory" for t in trace),
                "read_calls": sum(t["name"] == "read_memory_evidence" for t in trace),
                "answer": answer, **score(case["id"], answer, expected[case["id"]], trace), "trace": trace}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live-config", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repeat", type=int, default=1)
    parser.add_argument("--cases", nargs="+")
    args = parser.parse_args()
    config = resolve_superagent_llm(args.live_config)
    if config["dsh_provider"] != "openai-codex":
        parser.error("This experiment currently uses the production Codex completion adapter")
    cases = [c for c in [*CASES, *EXTRA_CASES] if not args.cases or c["id"] in args.cases]
    assert score("absent", {"answer": "没有找到", "evidence_ids": [], "insufficient": True}, [], [])["passed"]
    assert not score("contract", {"answer": "99.5", "evidence_ids": ["x"], "insufficient": False}, ["x"], [])["passed"]
    results = []
    with ThreadPoolExecutor(max_workers=3) as pool:
        futures = [pool.submit(run_case, config, c, mode, repeat)
                   for repeat in range(args.repeat) for c in cases for mode in ("like", "ranked")]
        for future in as_completed(futures):
            row = future.result()
            results.append(row)
            print(json.dumps({k: row[k] for k in ("case", "mode", "passed", "search_calls", "read_calls", "seconds")}), flush=True)
            args.output.write_text(json.dumps({"model": config["model_id"], "results": results}, ensure_ascii=False, indent=2))
    summary = {}
    for mode in ("like", "ranked"):
        rows = [r for r in results if r["mode"] == mode]
        summary[mode] = {"passed": sum(r["passed"] for r in rows), "total": len(rows),
                         "search_calls": sum(r["search_calls"] for r in rows),
                         "read_calls": sum(r["read_calls"] for r in rows),
                         "median_seconds": round(statistics.median(r["seconds"] for r in rows), 2)}
    args.output.write_text(json.dumps({"model": config["model_id"], "summary": summary,
                                      "results": results}, ensure_ascii=False, indent=2))
    print(json.dumps(summary), flush=True)


if __name__ == "__main__":
    main()
