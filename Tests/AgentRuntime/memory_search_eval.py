"""Small synthetic recall comparison, with optional real-model query expansion.

This measures retrieval coverage, not answer correctness or a public benchmark.
Both retrievers receive exactly the same queries and corpus. The LIKE baseline
is deliberately granted access to notes too (the old implementation had none).
"""
import argparse
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / 'Apps/MacApp/Context'), str(ROOT / 'Apps/MacApp/Runtime')]
from context_store import ContextStore, digest
from memory_search import MemorySearch
from momo_memory import MoMoMemory

CASES = [
    {"id": "capacity", "kind": "recording", "text": "[小林] 数据库连接池已经从二十扩到八十，周五进行高并发压测。",
     "question": "之前上线怕扛不住的问题有进展吗？", "queries": ["上线 性能", "高并发 连接池", "压测"]},
    {"id": "contract", "kind": "note", "text": "# 客户合同\n合同规定 SLA 99.5%，可用性条款由陈总审核。",
     "question": "客户对服务不中断的要求是多少？", "queries": ["服务 可用性", "SLA", "客户 合同"]},
    {"id": "food", "kind": "chat", "text": "订餐请选不放辣椒的，我和家人都吃不了辣。",
     "question": "帮我选晚餐时需要避开什么口味？", "queries": ["订餐 偏好", "不放辣椒", "口味"]},
    {"id": "travel", "kind": "note", "text": "# 出差调整\n巴黎的安排取消了；新行程是十二月八日去东京，周四返回。",
     "question": "现在出差目的地改成哪里了？", "queries": ["出差 调整", "行程", "目的地"]},
    {"id": "deadline", "kind": "recording", "text": "[陈总] 下周一之前把修订合同发我，价格沿用上一版。",
     "question": "陈总等的合同什么时候要发？", "queries": ["陈总 合同", "修订 截止", "下周一"]},
    {"id": "style", "kind": "chat", "text": "以后给我汇报时先写结论，再给证据，不需要大段过程描述。",
     "question": "我希望工作汇报按什么顺序写？", "queries": ["汇报 顺序", "结论 证据", "汇报"]},
    {"id": "gift", "kind": "note", "text": "# 妈妈的生日\n妈妈生日是五月十六日，她喜欢园艺，家里已有两套修枝剪。",
     "question": "妈妈生日送什么可以避免重复？", "queries": ["妈妈 生日", "园艺 礼物", "修枝剪"]},
    {"id": "release", "kind": "recording", "text": "[小林] Android 测试完成了，iOS 还在等待审核，暂时不能一起发布。",
     "question": "两个客户端现在能一起上线吗？", "queries": ["客户端 发布", "Android iOS", "审核"]},
]


def evaluate(queries):
    with tempfile.TemporaryDirectory() as directory:
        data = Path(directory)
        (data / 'runtime').mkdir()
        memory = MoMoMemory(data)
        context = ContextStore(data / 'context')
        chat = sqlite3.connect(data / 'runtime/conversation.sqlite')
        try:
            chat.executescript('''CREATE TABLE messages(seq INTEGER PRIMARY KEY,role TEXT,content TEXT,created_at REAL,operation_id TEXT);
                                  CREATE TABLE inputs(operation_id TEXT,intent TEXT,delivery_state TEXT);''')
            expected, corpus = {}, {}
            for seq, case in enumerate(CASES, 1):
                text = case['text']
                if case['kind'] == 'note':
                    path = f"projects/{case['id']}.md"
                    memory.write_notebook(path=path, content=text)
                    identity = 'note:' + path
                elif case['kind'] == 'chat':
                    chat.execute('INSERT INTO messages VALUES(?,?,?,?,NULL)', (seq, 'user', text, seq))
                    identity = 'chat:' + str(seq)
                else:
                    span_id = str(uuid.uuid4())
                    source = context.sync_source(dict(library_id=str(uuid.uuid4()), session_id=str(uuid.uuid4()),
                        device_id=str(uuid.uuid4()), generation=0, version=1, deleted=False, recorded_at=seq,
                        spans=[dict(id=span_id, text=text, recorded_at=seq)], text_sha256=digest(text)))
                    identity = f"recording:{source['source_id']}:{span_id}"
                expected[case['id']], corpus[identity] = identity, text
            chat.commit()
        finally:
            chat.close()
            context.close()
        for index in range(100):
            path, text = f'noise/{index}.md', f'# 园区公告 {index}\n本月例行检查消防设施与停车场。'
            memory.write_notebook(path=path, content=text)
            corpus['note:' + path] = text
        search = MemorySearch(data)
        rows = []
        for case in CASES:
            variants = queries[case['id']]
            original = case['question']
            started = time.monotonic()
            hits = search.search(original, variants, limit=3)['matches']
            elapsed = time.monotonic() - started
            baseline = [key for key, text in corpus.items() if any(q.casefold() in text.casefold() for q in [original, *variants])][:3]
            rows.append({'id': case['id'], 'queries': variants, 'like_hit_at_3': expected[case['id']] in baseline,
                         'ranked_hit_at_3': expected[case['id']] in {hit['id'] for hit in hits},
                         'seconds': round(elapsed, 4)})
        return {'cases': len(rows), 'corpus_documents': len(CASES) + 100,
                'like_hits_at_3': sum(r['like_hit_at_3'] for r in rows),
                'ranked_hits_at_3': sum(r['ranked_hit_at_3'] for r in rows), 'results': rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live-config', type=Path, help='Use only model configuration from this profile; all search data remains synthetic')
    args = parser.parse_args()
    queries = {case['id']: case['queries'] for case in CASES}
    mode = 'supplied query variants'
    if args.live_config:
        from superagent_gateway import SuperAgentGateway
        from superagent_runtime import resolve_superagent_llm
        gateway = SuperAgentGateway.__new__(SuperAgentGateway)
        gateway.data = args.live_config
        prompt = ('For each Chinese personal-memory question, produce 1 to 3 short search queries using likely synonyms, '
                  'technical terms or distinct missing aspects. Do not invent specific names, dates or outcomes. '
                  'You have no access to the stored corpus. Return ONLY a JSON object mapping each id to a list of queries.\n'
                  + json.dumps([{k: c[k] for k in ('id', 'question')} for c in CASES], ensure_ascii=False))
        raw = gateway._call_configured_llm_oneshot(prompt).strip()
        if raw.startswith('```'):
            raw = raw.split('\n', 1)[1].rsplit('```', 1)[0]
        queries = json.loads(raw)
        if set(queries) != {c['id'] for c in CASES}:
            raise ValueError('Query expansion returned different case ids')
        mode = 'live query expansion: ' + resolve_superagent_llm(args.live_config)['model_id']
    print(json.dumps({'mode': mode, **evaluate(queries)}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
