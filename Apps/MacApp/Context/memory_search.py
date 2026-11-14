"""Rebuildable local retrieval over Markdown, recordings and eligible chat evidence.

BM25 passage recall and reciprocal-rank fusion follow the retrieval patterns in
EverOS (489ac7e9); query expansion belongs to the calling Agent, not a second LLM.
"""
from collections import defaultdict
from contextlib import closing, contextmanager
import json
from pathlib import Path
import re
import sqlite3
import unicodedata

from context_store import ContextStore, Conflict, canonical, digest
from memory_review import eligible_chat_messages, readonly
from momo_memory import MoMoMemory, _file_lock

KINDS = ("note", "recording", "chat")
CHUNK_SIZE = 1200
CHUNK_OVERLAP = 160
QUERY_HELP = (
    "Search shared Markdown memory, original recording spans and chat by relevance. "
    "For vague wording, supply up to 3 focused alternative_queries (synonyms, names, technical terms, "
    "or separate missing aspects). Query variants are search hypotheses, never evidence. "
    "Read relevant hits with read_memory_evidence; if an aspect is missing, search again using grounded clues. "
    "Notes and assistant messages are derived claims, not independent confirmation of their sources."
)
SEARCH_SCHEMA = {
    "name": "search_memory", "description": QUERY_HELP,
    "parameters": {"type": "object", "properties": {
        "query": {"type": "string", "minLength": 1, "maxLength": 300},
        "alternative_queries": {"type": "array", "maxItems": 3,
                                "items": {"type": "string", "minLength": 1, "maxLength": 300}},
        "kind": {"type": "string", "enum": ["all", *KINDS]},
        "limit": {"type": "integer", "minimum": 1, "maximum": 30},
    }, "required": ["query"], "additionalProperties": False},
}
READ_SCHEMA = {
    "name": "read_memory_evidence",
    "description": "Read the complete current source of a search hit in pages. Pass its id and revision; "
                   "a changed or deleted source requires a fresh search. Follow next_offset until null.",
    "parameters": {"type": "object", "properties": {
        "id": {"type": "string", "minLength": 1},
        "revision": {"type": "string", "minLength": 1},
        "offset": {"type": "integer", "minimum": 0},
        "limit": {"type": "integer", "minimum": 1, "maximum": 24000},
    }, "required": ["id", "revision"], "additionalProperties": False},
}


def execute_search_tool(data, name, arguments):
    schema = {"search_memory": SEARCH_SCHEMA, "read_memory_evidence": READ_SCHEMA}[name]["parameters"]
    if not isinstance(arguments, dict) or set(arguments) - schema["properties"].keys() or set(schema["required"]) - arguments.keys():
        raise ValueError("Unexpected or missing search tool arguments")
    search = MemorySearch(data)
    return search.search(**arguments) if name == "search_memory" else search.read(**arguments)


def terms(text, *, indexing=False):
    """Unicode words plus CJK bigrams; index unigrams for single-character queries."""
    text = unicodedata.normalize("NFKC", text).casefold()
    result = []
    for part in re.split(r"([\u3400-\u9fff]+)", text):
        if part and "\u3400" <= part[0] <= "\u9fff":
            result.extend(part[i:i + 2] for i in range(len(part) - 1))
            if indexing or len(part) == 1:
                result.extend(part)
        else:
            result.extend(re.findall(r"[^\W_]+", part))
    return result


def _stamp(path):
    stat = path.stat()
    return f"{stat.st_ino}:{stat.st_size}:{stat.st_mtime_ns}:{stat.st_ctime_ns}"


def _document(identity, kind, text, metadata, title=""):
    return (identity, kind, text, canonical(metadata), title, digest(canonical([text, metadata])))


class MemorySearch:
    def __init__(self, data):
        self.data = Path(data)
        self.path = self.data / "runtime" / "memory-search.sqlite"

    @contextmanager
    def _index(self):
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        # CLI, Dream and foreground tools may index concurrently. No model/network
        # calls take place while this short-lived lock or a DB connection is held.
        with _file_lock(self.path.with_suffix(".lock")), closing(sqlite3.connect(self.path, timeout=10)) as db:
            self.path.chmod(0o600)
            db.row_factory = sqlite3.Row
            db.execute("PRAGMA foreign_keys=ON")
            db.execute("PRAGMA secure_delete=ON")
            db.executescript("""
                CREATE TABLE IF NOT EXISTS groups(id TEXT PRIMARY KEY, signature TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS documents(
                    id TEXT PRIMARY KEY, group_id TEXT NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL, content TEXT NOT NULL, metadata TEXT NOT NULL,
                    title TEXT NOT NULL, revision TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS passages(
                    id INTEGER PRIMARY KEY, document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                    start INTEGER NOT NULL, end INTEGER NOT NULL);
                CREATE INDEX IF NOT EXISTS passages_document ON passages(document_id);
                CREATE VIRTUAL TABLE IF NOT EXISTS recall USING fts5(title, body, tokenize='porter unicode61');
                CREATE TRIGGER IF NOT EXISTS delete_passage AFTER DELETE ON passages BEGIN
                    DELETE FROM recall WHERE rowid=old.id;
                END;
            """)
            with db:
                self._refresh(db)
            yield db

    def _refresh(self, db):
        known = dict(db.execute("SELECT id, signature FROM groups"))
        live = set()

        def sync(group, signature, load):
            live.add(group)
            if known.get(group) == signature:
                return
            documents = load()
            db.execute("DELETE FROM groups WHERE id=?", (group,))
            db.execute("INSERT INTO groups VALUES(?,?)", (group, signature))
            for identity, kind, text, metadata, title, revision in documents:
                db.execute("INSERT INTO documents VALUES(?,?,?,?,?,?,?)",
                           (identity, group, kind, text, metadata, title, revision))
                title_terms = " ".join(terms(title, indexing=True))
                for start in range(0, len(text), CHUNK_SIZE - CHUNK_OVERLAP):
                    end = min(len(text), start + CHUNK_SIZE)
                    cursor = db.execute("INSERT INTO passages(document_id,start,end) VALUES(?,?,?)", (identity, start, end))
                    db.execute("INSERT INTO recall(rowid,title,body) VALUES(?,?,?)",
                               (cursor.lastrowid, title_terms, " ".join(terms(text[start:end], indexing=True))))
                    if end == len(text):
                        break

        memory = MoMoMemory(self.data)
        root = memory.memories_dir.resolve()
        files = [p for _, _, p in memory._notebook_files()]
        files += [memory.memories_dir / name for name in ("USER.md", "MEMORY.md")]
        for path in files:
            if not path.is_file() or not path.resolve().is_relative_to(root):
                continue
            relative = path.relative_to(memory.memories_dir).as_posix()
            identity = "note:" + relative

            def load_note(path=path, relative=relative, identity=identity):
                text = path.read_text(encoding="utf-8")
                return [_document(identity, "note", text, {"path": relative, "basis": "derived"},
                                  relative + " " + next(iter(text.splitlines()), ""))]

            sync(identity, _stamp(path), load_note)

        context_path = self.data / "context" / "context.sqlite"
        if context_path.is_file():
            store = ContextStore(context_path.parent)
            updates = []
            try:
                store.db.execute("BEGIN")
                overrides = defaultdict(list)
                for row in store.db.execute("SELECT source_id,span_id,speaker,is_owner FROM span_speaker_overrides ORDER BY span_id"):
                    overrides[row["source_id"]].append(tuple(row))
                exclusions = defaultdict(list)
                for row in store.db.execute("SELECT source_id,speaker,span_ids,recorded_from FROM speaker_exclusions ORDER BY id"):
                    exclusions[row["source_id"]].append(tuple(row))
                rows = store.db.execute("SELECT id,revision FROM sources WHERE deleted=0").fetchall()
                for row in rows:
                    source_id = row["id"]
                    signature = digest(canonical([row["revision"], overrides[source_id], exclusions[source_id], exclusions[None]]))
                    group = "recording:" + source_id
                    live.add(group)
                    if known.get(group) != signature:
                        payload = json.loads(store.db.execute("SELECT payload FROM sources WHERE id=?", (row["id"],)).fetchone()[0])
                        spans = store._apply_speaker_overrides(row["id"], payload["spans"])
                        documents = [_document(f"recording:{row['id']}:{span['id']}", "recording", span["text"],
                                          {"source_id": row["id"], "source_revision": row["revision"],
                                           "span_id": span["id"], "recorded_at": span["recorded_at"],
                                           "speaker": span.get("speaker"), "is_owner": span.get("is_owner"),
                                           "basis": "transcript"}, span.get("speaker") or "") for span in spans]
                        updates.append((group, signature, documents))
            finally:
                store.close()
            for group, signature, documents in updates:
                sync(group, signature, lambda documents=documents: documents)

        chat_path = self.data / "runtime" / "conversation.sqlite"
        if chat_path.is_file():
            with closing(readonly(chat_path)) as chat:
                rows = chat.execute(eligible_chat_messages(chat)).fetchall()
            for row in rows:
                identity = "chat:" + str(row["seq"])
                doc = _document(identity, "chat", row["content"],
                                {"seq": row["seq"], "role": row["role"], "created_at": row["created_at"],
                                 "basis": "user_statement" if row["role"] == "user" else "assistant_statement"})
                sync(identity, doc[-1], lambda doc=doc: [doc])

        db.executemany("DELETE FROM groups WHERE id=?", ((key,) for key in known.keys() - live))

    def search(self, query, alternative_queries=None, kind="all", limit=10):
        if not isinstance(query, str) or not query.strip() or len(query) > 300:
            raise ValueError("query must contain 1...300 characters")
        alternatives = [] if alternative_queries is None else alternative_queries
        if not isinstance(alternatives, list) or len(alternatives) > 3 or any(
            not isinstance(q, str) or not q.strip() or len(q) > 300 for q in alternatives
        ):
            raise ValueError("alternative_queries must contain at most 3 queries of 1...300 characters")
        if kind not in ("all", *KINDS) or type(limit) is not int or not 1 <= limit <= 30:
            raise ValueError("Invalid kind or limit (1...30)")
        queries = list(dict.fromkeys(q.strip() for q in [query, *alternatives]))
        hits, scores, per_query = {}, defaultdict(float), []
        with self._index() as db:
            for q in queries:
                words = list(dict.fromkeys(terms(q)))
                expression = " OR ".join('"' + word.replace('"', '""') + '"' for word in words)
                if not expression:
                    per_query.append([])
                    continue
                rows = db.execute("""WITH ranked AS MATERIALIZED (
                        SELECT p.document_id, p.start, p.end, bm25(recall, 2.0, 1.0) AS rank
                        FROM recall JOIN passages p ON p.id=recall.rowid JOIN documents d ON d.id=p.document_id
                        WHERE recall MATCH ? AND (?='all' OR d.kind=?)
                    ), best AS (
                        SELECT *, row_number() OVER (PARTITION BY document_id ORDER BY rank,start) AS position FROM ranked
                    )
                    SELECT d.id,d.kind,d.metadata,d.revision,b.start,b.end,b.rank,
                           substr(d.content,b.start+1,b.end-b.start) AS snippet, length(d.content) AS total
                    FROM best b JOIN documents d ON d.id=b.document_id
                    WHERE b.position=1 ORDER BY b.rank,d.id LIMIT 50""",
                                  (expression, kind, kind)).fetchall()
                unique = {row["id"]: row for row in rows}
                ranked = list(unique)
                per_query.append(ranked)
                for rank, identity in enumerate(ranked, 1):
                    scores[identity] += 1 / (40 + rank)
                    if identity not in hits or unique[identity]["rank"] < hits[identity]["rank"]:
                        hits[identity] = unique[identity]
            # Reserve each query's best hit before filling by fused rank so a
            # single popular topic cannot crowd out a different question facet.
            order = list(dict.fromkeys([r[0] for r in per_query if r] + sorted(scores, key=lambda k: (-scores[k], k))))
            matches = []
            for identity in order[:limit]:
                row = hits[identity]
                match = self._result(row, row["snippet"], row["start"], row["total"])
                match["score"] = round(scores[identity], 6)
                match["matched_queries"] = [q for q, ids in zip(queries, per_query) if identity in ids]
                matches.append(match)
        return {"method": "bm25_multi_query_rrf", "queries": queries, "matches": matches,
                "has_more": len(order) > limit}

    @staticmethod
    def _result(row, text, offset, total):
        end = offset + len(text)
        return {"id": row["id"], "kind": row["kind"], "revision": row["revision"],
                **json.loads(row["metadata"]), "text": text, "offset": offset,
                "total_characters": total, "next_offset": end if end < total else None,
                "truncated": offset > 0 or end < total,
                "read": {"tool": "read_memory_evidence", "arguments": {"id": row["id"], "revision": row["revision"]}}}

    def read(self, id, revision, offset=0, limit=12000):
        if not isinstance(id, str) or not isinstance(revision, str) or not revision:
            raise ValueError("id and revision are required")
        if type(offset) is not int or offset < 0 or type(limit) is not int or not 1 <= limit <= 24000:
            raise ValueError("Invalid offset or limit (1...24000)")
        with self._index() as db:
            row = db.execute("SELECT * FROM documents WHERE id=?", (id,)).fetchone()
            if row is None or row["revision"] != revision:
                raise Conflict("Evidence changed or was deleted; search again for the current source")
            if offset > len(row["content"]):
                raise ValueError("offset exceeds source length")
            return self._result(row, row["content"][offset:offset + limit], offset, len(row["content"]))
