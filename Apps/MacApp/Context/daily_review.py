"""Freeze chat and transcript evidence for one paginated daily Dream."""
from contextlib import closing
import json
import uuid
from pathlib import Path

from momo_memory import memory_home
from context_store import Conflict, canonical, digest
import memory_review as review
import transcript_ingestion as ingestion


# Each evidence page is at most ~32 KB. A fresh model session bounds replay
# and context growth while all batches share the original frozen snapshot.
PAGES_PER_RUN = 4


def enqueue(store, data, now, manual=False):
    with store.write():
        active = store.db.execute("""
            SELECT * FROM memory_reviews WHERE kind='dream' AND state IN ('pending','running')
            AND (first_attempt IS NOT NULL OR json_extract(input,'$.daily')=1)
            ORDER BY rowid LIMIT 1
        """).fetchone()
        if active:
            if manual and active["first_attempt"] is None:
                store.db.execute("UPDATE memory_reviews SET input=json_set(input,'$.manual_requested_at',?) WHERE id=?",
                                 (now, active["id"]))
            return active, False

        # Old, unadmitted chat and Dream jobs are represented by their original
        # evidence below. Admitted runs are reconciled before dispatch gets here.
        store.db.execute("""UPDATE memory_reviews SET state='superseded' WHERE state='pending'
                            AND first_attempt IS NULL AND json_extract(input,'$.daily') IS NULL""")
        cursor = review.state(store, "chat_cursor", [0, 0])
        through = 0
        db_path = Path(data) / "runtime/conversation.sqlite"
        if db_path.is_file():
            with closing(review.readonly(db_path)) as db:
                through = db.execute("SELECT COALESCE(MAX(seq),0) FROM messages").fetchone()[0]
        # The old chat job never advanced its cursor on failure. Include those
        # messages in the new combined review before any subsequent messages.
        chat = review.chat_batch(store, data, cursor, through)
        jobs = store.db.execute("SELECT * FROM jobs WHERE state='pending' AND first_attempt IS NULL ORDER BY rowid").fetchall()
        stamp = review.signature(memory_home(Path(data)), cursor, store.revision)
        last = review.state(store, "dream", {})
        if not manual and not chat and not jobs:
            if last.get("signature") == stamp:
                return None, False
            if not last and cursor == [0, 0]:
                has_source = store.db.execute("""SELECT 1 FROM sources WHERE deleted=0
                    UNION ALL SELECT 1 FROM phone_source_snapshots WHERE json_array_length(payload,'$.records')>0
                    LIMIT 1""").fetchone()
                if not has_source:
                    return None, False

        payload = {"daily": True, "signature": stamp, "source_revision": store.revision,
                   "chat_cursor": cursor, "chat_through": through if chat else None,
                   "recording_queue": digest(canonical([j["id"] for j in jobs]))}
        if manual:
            payload["manual_requested_at"] = now
        job = review.enqueue(store, "dream", payload)
        if job["state"] != "pending":
            return None, False

        page = 0

        def append(job_id, batch):
            nonlocal page
            page += 1
            store.db.execute("INSERT INTO daily_review_pages(review_id,page,job_id,evidence) VALUES(?,?,?,?)",
                             (job["id"], page, job_id, canonical(batch)))

        while chat:
            append(None, chat)
            if not chat["remaining"]:
                break
            chat = review.chat_batch(store, data, chat["cursor"], through)
        for source_job in jobs:
            job_id = source_job["id"]
            for batch in ingestion.batches(store, source_job):
                if batch["passages"]:
                    append(job_id, batch)
                else:
                    store.db.execute("UPDATE jobs SET input=? WHERE id=?", (canonical(batch), job_id))
                    ingestion.finish_in_transaction(store, source_job, None)
                job_id = ingestion.next_page_job_id(job_id)
        return job, True


def skip_superseded_in_transaction(store, job):
    """Remove unread pages whose frozen recording is gone or has been revised."""
    payload = json.loads(job["input"])
    snapshot = payload.get("snapshot_id", job["id"])
    revision = store.revision
    if payload.get("pages_checked_revision") == revision:
        return job
    if "snapshot_last_page" not in payload:
        payload["snapshot_last_page"] = store.db.execute(
            "SELECT COALESCE(MAX(page),0) FROM daily_review_pages WHERE review_id=?", (snapshot,)).fetchone()[0]
    skipped = store.db.execute("""
        DELETE FROM daily_review_pages WHERE review_id=? AND seen=0 AND job_id IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM sources
            WHERE id=json_extract(daily_review_pages.evidence,'$.source_id') AND deleted=0
            AND revision=json_extract(daily_review_pages.evidence,'$.source_revision'))
    """, (snapshot,)).rowcount
    payload["pages_checked_revision"] = revision
    payload["pages_skipped"] = payload.get("pages_skipped", 0) + skipped
    return store.db.execute("UPDATE memory_reviews SET input=? WHERE id=? RETURNING *",
                            (canonical(payload), job["id"])).fetchone()


def read_page(store, review_id, page, completed_page=None):
    if type(page) is not int or page < 1:
        raise ValueError("page must be a positive integer")
    with store.write():
        active = store.db.execute("""SELECT checkpoint_page, input FROM memory_reviews WHERE id=?
            AND state IN ('pending','running') AND first_attempt IS NOT NULL""", (review_id,)).fetchone()
        if not active:
            raise Conflict("Daily review is not active")
        payload = json.loads(active["input"])
        snapshot = payload.get("snapshot_id", review_id)
        pages = store.db.execute("""SELECT page,seen FROM daily_review_pages
            WHERE review_id=? ORDER BY page LIMIT ?""", (snapshot, PAGES_PER_RUN)).fetchall()
        # Pruning on retry may leave only the already-checkpointed prefix.
        if page == 1 and completed_page is None and (not pages or pages[-1]["page"] <= active["checkpoint_page"]):
            return {"total_pages": payload.get("snapshot_last_page", 0), "next_page": None, "has_more_batches": False}
        numbers = [row["page"] for row in pages]
        if page not in numbers:
            raise ValueError("Page outside the current Dream batch")
        index = numbers.index(page)
        if index and not pages[index - 1]["seen"]:
            raise ValueError("Read the preceding evidence page first")
        if completed_page is not None:
            if (type(completed_page) is not int or not index or completed_page != numbers[index - 1]
                    or (index >= 2 and numbers[index - 2] > active["checkpoint_page"])):
                raise ValueError("Only the preceding, processed page can be checkpointed, in order")
            review.check_last_write(memory_home(store.directory.parent), "momo-review-" + review_id)
            store.db.execute("UPDATE memory_reviews SET checkpoint_page=MAX(checkpoint_page,?) WHERE id=?",
                             (completed_page, review_id))
        row = store.db.execute("SELECT * FROM daily_review_pages WHERE review_id=? AND page=?", (snapshot, page)).fetchone()
        batch = json.loads(row["evidence"])
        if row["job_id"]:
            current = store.db.execute("SELECT revision,deleted FROM sources WHERE id=?", (batch["source_id"],)).fetchone()
            if not current or current["deleted"] or current["revision"] != batch["source_revision"]:
                batch = {"superseded": True}
        store.db.execute("UPDATE daily_review_pages SET seen=1 WHERE review_id=? AND page=?", (snapshot, page))
        last = store.db.execute("SELECT MAX(page) FROM daily_review_pages WHERE review_id=?", (snapshot,)).fetchone()[0]
        return {"page": page, "total_pages": payload.get("snapshot_last_page", last), "batch_end": numbers[-1],
                "has_more_batches": numbers[-1] < last,
                "next_page": numbers[index + 1] if index + 1 < len(numbers) else None, "evidence": batch}


def previous_writes(store, job):
    count, targets = 0, set()
    home = memory_home(store.directory.parent)
    while job is not None and job["attempt"]:
        parent = json.loads(job["input"]).get("retry_of")
        if not parent:
            # Pending retries from older versions carried only a deterministic ID.
            parents = store.db.execute("SELECT id FROM memory_reviews WHERE state='retrying' AND attempt=?",
                                       (job["attempt"] - 1,))
            parent = next((r["id"] for r in parents
                           if str(uuid.uuid5(uuid.NAMESPACE_URL, r["id"] + ":retry")) == job["id"]), None)
        if not parent:
            break
        for receipt in review.changed_write_receipts(home, "momo-review-" + parent):
            count += 1
            targets.update(receipt[key] for key in ("path", "from_path", "target", "source_id")
                           if isinstance(receipt.get(key), str))
        job = store.db.execute("SELECT * FROM memory_reviews WHERE id=? AND attempt=?",
                               (parent, job["attempt"] - 1)).fetchone()
    return count, sorted(targets)


def prompt(store, job):
    payload = json.loads(job["input"])
    snapshot = payload.get("snapshot_id", job["id"])
    # Keep admission replay anchored to the attempt's original resume position.
    page = store.db.execute("SELECT MIN(page) FROM daily_review_pages WHERE review_id=? AND page>?",
                            (snapshot, payload.get("resume_after", 0))).fetchone()[0]
    evidence = read_page(store, job["id"], page or 1)
    instruction = ("逐页处理本批证据。确认本页需要的写入均已成功，或确实无需写入后，再用 read_daily_evidence "
                   "传 review_id、page=next_page 和 completed_page=当前页码。最后一页用最终回执确认。")
    scope = "读完本批所有证据后，执行当天的全局整理。\n" + review.DREAM_INSTRUCTION
    if evidence["has_more_batches"]:
        scope = "本批只核对当前证据、订正归属、更新涉及的记忆和笔记。全局整理和晨报留给末批。"
    if job["attempt"]:
        instruction += "这是中断后的续跑。先核对之前已落盘的写入与目标笔记；保留已完成的修改。"
        _, targets = previous_writes(store, job)
        if targets:
            instruction += " 上次已有变更的目标：" + canonical(targets)
    return (review.prompt(job, scope) + "\n" + instruction + "\nreview_id=" + job["id"]
            + "\nDAILY_EVIDENCE=" + canonical(evidence))


def finish_in_transaction(store, job, receipt):
    payload = json.loads(job["input"])
    snapshot = payload.get("snapshot_id", job["id"])
    count, seen = store.db.execute("SELECT COUNT(*), COALESCE(SUM(seen),0) FROM daily_review_pages WHERE review_id=?",
                                   (snapshot,)).fetchone()
    if count and not seen:
        raise Conflict("Daily review has not received any evidence pages")
    receipt["pages_reviewed"], receipt["pages_remaining"] = seen, count - seen
    receipt["pages_skipped"] = payload.pop("pages_skipped", 0)
    prior_count, _ = previous_writes(store, job)
    if prior_count:
        receipt["recovered_writes"] = prior_count
        receipt["native_writes"] = prior_count + receipt.get("native_writes", 0)
        receipt["outcome"] = "updated"
        receipt["reason"] = f"此前中断时已保存 {prior_count} 项变更。" + receipt.get("reason", "")

    cursor = None
    for row in store.db.execute("SELECT * FROM daily_review_pages WHERE review_id=? AND seen=1 ORDER BY page", (snapshot,)):
        batch = json.loads(row["evidence"])
        if not row["job_id"]:
            cursor = batch["cursor"]
            continue
        source_job = store.db.execute("SELECT * FROM jobs WHERE id=? AND state='pending'", (row["job_id"],)).fetchone()
        source = store.db.execute("SELECT revision,deleted FROM sources WHERE id=?", (batch["source_id"],)).fetchone()
        if source_job and source and not source["deleted"] and source["revision"] == batch["source_revision"]:
            store.db.execute("UPDATE jobs SET input=? WHERE id=?", (row["evidence"], source_job["id"]))
            ingestion.finish_in_transaction(store, source_job, {"daily_review_id": job["id"], "page": row["page"]})
    if cursor is not None:
        review.set_state(store, "chat_cursor", cursor)
    store.db.execute("DELETE FROM daily_review_pages WHERE review_id=? AND seen=1", (snapshot,))
    if count > seen:
        # Claim the remaining frozen pages in the same commit as the acknowledged
        # source hashes, chat cursor and parent receipt. A restart can resume here.
        continuation = str(uuid.uuid5(uuid.NAMESPACE_URL, job["id"] + ":continue"))
        payload["snapshot_id"] = snapshot
        payload.pop("resume_after", None)
        payload.pop("manual_requested_at", None)
        payload.pop("retry_after", None)
        payload.pop("retry_of", None)
        payload["continuation_of"] = job["id"]
        if cursor is not None:
            payload["chat_cursor"] = cursor
        store.db.execute("INSERT INTO memory_reviews(id,kind,input) VALUES(?,'dream',?)",
                         (continuation, canonical(payload)))
    return cursor
