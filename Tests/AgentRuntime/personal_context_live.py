"""Real Dream -> fresh-session recall, synthetic profile only; never copies credentials."""
import argparse
import datetime
import json
from pathlib import Path
import sys
import tempfile
import threading
import time
from unittest.mock import patch
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / p) for p in ('Apps/MacApp/Runtime', 'Apps/MacApp/Context', 'Apps/MacApp/Access', 'Vendor/HermesAgent')]
from context_store import ContextStore, digest
from momo_memory import MoMoMemory
from phone_sources import sync_phone_source
import memory_review
import speaker_proposals
from superagent_gateway import SuperAgentGateway
from superagent_runtime import resolve_superagent_llm


def seed(data):
    store = ContextStore(data / 'context')
    memory = MoMoMemory(data)
    memory.write_notebook(path='places/旧判断.md', content='# 旧地点判断\n青禾苑是公司，星河办公室是家；李工常在家里，是同住家人。出差酒店也是另一个家。')
    memory.write_notebook(path='projects/预算.md', content='# 预算\n预算五十万元已经定案。')
    day = datetime.datetime.now().replace(hour=0, minute=0, second=0, microsecond=0).timestamp() - 5 * 86400
    device = str(uuid.uuid4())
    visits = []
    entries = [
        (0, 21, 31.20, 121.40, '[我] 今天回到青禾苑的家了，小雨，今晚谁下厨？\n[说话人 1] 我是小雨，今晚我下厨，厨房菜已经热好了。\n[我] 好的小雨，谢谢，家里备用钥匙帮我放玄关。'),
        (1, 10, 31.23, 121.48, '[我] 已到星河办公室，李工来会议室讨论公司的接口。\n[李工] 我刚进会议室，今天先看接口。'),
        (2, 11, 31.2001, 121.4001, '[我] 今天在青禾苑家里办公。李工在公司，正在视频电话里。\n[李工] 我在星河办公室，视频里给你看接口图。\n[我] 预算无十万。先统计工时再报价，还没定数字，对方也没同意金额。'),
        (3, 22, 30.27, 120.15, '[我] 出差临时住云际酒店，只住这一晚，明天回青禾苑。'),
        (4, 15, 31.25, 121.49, '[我] 到北岸共享办公室了，这是第二个办公点，周三来和另一组开会。'),
    ]
    for index, (d, hour, lat, lon, text) in enumerate(entries):
        at = day + d * 86400 + hour * 3600
        spans = [dict(id=str(uuid.uuid4()), text=line, recorded_at=at + n * 10, is_owner=line.startswith('[我]')) for n, line in enumerate(text.splitlines())]
        store.sync_source(dict(library_id=str(uuid.uuid4()), session_id=str(uuid.uuid4()), device_id=device,
                              generation=0, version=1, deleted=False, title=f'生活片段 {index}', recorded_at=at,
                              spans=spans, text_sha256=digest(text)))
        visits.append(dict(id=f'visit-{index}', source_name='Synthetic phone visit', start=at-300, end=at+600,
                           latitude=lat, longitude=lon, accuracy=60))
    now = time.time()
    sync_phone_source(store, dict(device_id=device, kind='visits', revision=1, state='enabled', observed_at=now,
                                 window_start=day, window_end=now, timezone='Asia/Shanghai', records=visits))
    return store, memory


QUESTION = '''只根据这些持久记忆回答，不要用常识补空白。只返回 JSON：
{"home":"最有依据的家在哪里", "workplaces":["有哪些办公地点"], "hotel_is_home":true或false或null,
"li_lives_with_user":true或false或null, "li_present_at_home":true或false或null,
"budget_fixed":true或false或null, "xiaoyu_identity_status":"已确认或推测或未知", "explanation":"简述依据与不确定性"}'''


def main(args):
    config = resolve_superagent_llm(args.live_data)
    with tempfile.TemporaryDirectory(prefix='momo-personal-eval-') as folder:
        data = Path(folder)
        store, memory = seed(data)
        gateway = SuperAgentGateway.__new__(SuperAgentGateway)
        gateway.data = data
        def notes():
            return '\n\n'.join(f'文件 {p.relative_to(memory.memories_dir)}\n{p.read_text()}' for p in sorted(memory.memories_dir.rglob('*.md')))
        def recall():
            raw = gateway._call_configured_llm_oneshot(QUESTION + '\n\n' + notes()).strip()
            if raw.startswith('```'): raw = raw.split('\n', 1)[1].rsplit('```', 1)[0]
            return json.loads(raw)
        def score(result):
            return dict(home='青禾苑' in result.get('home', ''),
                        multiple_workplaces=all(any(n in w for w in result.get('workplaces', [])) for n in ('星河', '北岸')),
                        temporary_hotel=result.get('hotel_is_home') is False,
                        no_invented_family=result.get('li_lives_with_user') is not True,
                        remote_call_not_presence=result.get('li_present_at_home') is False,
                        repaired_budget=result.get('budget_fixed') is False,
                        candidate_identity=result.get('xiaoyu_identity_status') in ('推测', '未知'))
        raw_before = [tuple(r) for r in store.db.execute('SELECT id,payload FROM sources ORDER BY id')]
        traces = []
        build = gateway._build_memory_review_session
        def instrument(session):
            system, specs, run = build(session)
            def execute(name, args):
                result = run(name, args)
                traces.append({'tool': name, 'args': args, 'result': json.loads(result)})
                print('tool', name, flush=True)
                return result
            return system, specs, execute
        with patch('superagent_gateway.resolve_superagent_llm', return_value=config):
            before = recall()
            print('before', score(before), flush=True)
            job = memory_review.enqueue(store, 'dream', {'signature': 'synthetic-personal-context', 'source_revision': store.revision})
            stop = threading.Event()
            timer = threading.Timer(600, stop.set)
            timer.start()
            transient_errors = []
            try:
                with patch.object(gateway, '_build_memory_review_session', side_effect=instrument):
                    for attempt in range(2):
                        try:
                            output = gateway._call_configured_llm_memory_review('momo-review-' + job['id'], memory_review.prompt(job), stop=stop)
                            break
                        except TimeoutError as error:
                            transient_errors.append(str(error))
                            if attempt or stop.is_set(): raise
                            print('Retrying interrupted model stream with persisted evidence and writes', flush=True)
            finally:
                timer.cancel()
            after = recall()  # Separate call: only persistent Markdown, no Dream messages or source text.
        checks = score(after)
        checks['original_transcripts_preserved'] = raw_before == [tuple(r) for r in store.db.execute('SELECT id,payload FROM sources ORDER BY id')]
        checks['no_label_without_consent'] = not store.pending_speaker_relabels()
        checks['incidental_identity_stays_quiet'] = speaker_proposals.next_question(store) is None
        checks['traceable_notes'] = 'momoagent://source/' in notes() and ('visit-' in notes() or 'revision' in notes())
        result = dict(model=config['model_id'], synthetic_only=True, before=before, before_checks=score(before),
                      after=after, checks=checks, transient_errors=transient_errors, dream_receipt=output, notes=notes(), trace=traces)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2))
        store.close()
        print(json.dumps({'before': score(before), 'after': checks}, ensure_ascii=False), flush=True)
        if not all(checks.values()): raise SystemExit(1)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--live-data', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    main(parser.parse_args())
