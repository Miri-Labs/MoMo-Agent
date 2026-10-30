"""Durable product inbox, visible messages, completion receipts and notification outbox.

Hermes SessionDB remains the only execution authority and memory store.
"""
import hashlib
import json
from pathlib import Path
import sqlite3
import time
from aiohttp import web
from conversation_events import ConversationEvents

class ProductStore:
    # Inputs survive restarts and are never pruned. Keep this minimum guarantee
    # stable for the lifetime of the paired instance, including across upgrades.
    MESSAGE_RETENTION_SECONDS = 86400

    def __init__(self, path, connection):
        self.notification_available = False
        self.db = sqlite3.connect(path)
        self.db.row_factory = sqlite3.Row
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.executescript('''
        CREATE TABLE IF NOT EXISTS identity(id TEXT PRIMARY KEY, root TEXT NOT NULL, created REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS messages(seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE NOT NULL,
            role TEXT NOT NULL, content TEXT NOT NULL, created_at REAL NOT NULL,
            operation_id TEXT, run_id TEXT, source_key TEXT UNIQUE);
        CREATE TABLE IF NOT EXISTS inputs(operation_id TEXT PRIMARY KEY, content TEXT NOT NULL,
            run_id TEXT UNIQUE NOT NULL, owner_scope TEXT NOT NULL, target_run_id TEXT, target_generation INTEGER, state TEXT NOT NULL DEFAULT 'pending');
        CREATE TABLE IF NOT EXISTS completions(event_key TEXT PRIMARY KEY, owner TEXT NOT NULL,
            event_json TEXT NOT NULL, source_message_id INTEGER NOT NULL, prompt TEXT NOT NULL, origin_admission_id TEXT,
            state TEXT NOT NULL DEFAULT 'pending', admission_id TEXT, reported_message_id TEXT, result_text TEXT NOT NULL DEFAULT '',
            last_error TEXT, created_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS notifications(message_id TEXT PRIMARY KEY, state TEXT NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0, next_attempt REAL NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS legacy_sessions(root TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS legacy_consumptions(source_message_id INTEGER PRIMARY KEY, admission_id TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS reads(device TEXT PRIMARY KEY, through_seq INTEGER NOT NULL);
        ''')
        if 'source_session' not in {row[1] for row in self.db.execute('PRAGMA table_info(messages)')}:
            self.db.execute('ALTER TABLE messages ADD COLUMN source_session TEXT')
        with self.db:
            if not self.db.execute('SELECT 1 FROM identity').fetchone():
                self.db.execute('INSERT INTO identity VALUES(?,?,?)',
                    ('conversation-' + connection['assistant_id'], 'momo-main-' + connection['assistant_id'], time.time()))
        self.identity = dict(self.db.execute('SELECT * FROM identity').fetchone())
        if self.identity['root'] != 'momo-main-' + connection['assistant_id']:
            self.db.close(); raise ValueError('Conversation belongs to another assistant')
        self.events = ConversationEvents(self.db, self.identity['id'])
        self.db.executescript("CREATE TABLE IF NOT EXISTS works(id TEXT PRIMARY KEY,native_root TEXT UNIQUE NOT NULL,origin_run_id TEXT,title TEXT NOT NULL,created_at REAL NOT NULL,context_through_seq INTEGER NOT NULL,context_json TEXT NOT NULL,cancel_requested INTEGER NOT NULL DEFAULT 0);\nCREATE TABLE IF NOT EXISTS work_children(id TEXT PRIMARY KEY,work_id TEXT NOT NULL,origin_run_id TEXT,kind TEXT NOT NULL,native_id TEXT NOT NULL,incarnation REAL NOT NULL,generation INTEGER NOT NULL,title TEXT NOT NULL,state TEXT NOT NULL,cancel_requested INTEGER NOT NULL DEFAULT 0);\nCREATE TABLE IF NOT EXISTS work_cancels(operation_id TEXT PRIMARY KEY,target TEXT NOT NULL,generation INTEGER NOT NULL,state TEXT NOT NULL DEFAULT 'pending');\nCREATE TABLE IF NOT EXISTS computer_waits(run_id TEXT PRIMARY KEY,work_id TEXT NOT NULL,generation INTEGER NOT NULL,tool_call_id TEXT,lease_epoch INTEGER,state TEXT NOT NULL);")
        for name, declaration in [('work_id','TEXT'),('intent',"TEXT NOT NULL DEFAULT 'legacy'"),('delivery_state',"TEXT NOT NULL DEFAULT 'pending'"),('attachments_json','TEXT')]:
            if name not in {row[1] for row in self.db.execute('PRAGMA table_info(inputs)')}:
                self.db.execute(f'ALTER TABLE inputs ADD COLUMN {name} {declaration}')
        for table, name, declaration in [('works','active_context',"TEXT NOT NULL DEFAULT '[]'"),
                ('work_cancels','target_run_id','TEXT'),('completions','report_attempt','INTEGER NOT NULL DEFAULT 0'),
                ('messages','attachments_json','TEXT')]:
            if name not in {row[1] for row in self.db.execute(f'PRAGMA table_info({table})')}:
                self.db.execute(f'ALTER TABLE {table} ADD COLUMN {name} {declaration}')
        self.db.executescript('''
        CREATE TABLE IF NOT EXISTS report_retries(operation_id TEXT PRIMARY KEY,event_key TEXT NOT NULL,attempt INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS completion_attempts(admission_id TEXT PRIMARY KEY,event_key TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS computer_calls(call_id TEXT PRIMARY KEY,run_id TEXT NOT NULL,work_id TEXT NOT NULL,
            generation INTEGER NOT NULL,state TEXT NOT NULL,wait_reason TEXT,blocking_work_id TEXT,lease_epoch INTEGER);
        ''')
        # No tool invocation survives a product process restart.
        self.db.execute("UPDATE computer_calls SET state='ended' WHERE state!='ended'")
        with self.db:
            self.db.execute('INSERT OR IGNORE INTO works(id,native_root,title,created_at,context_through_seq,context_json) VALUES(?,?,?,?,?,?)',
                (self.identity['root'],self.identity['root'],'之前的对话',time.time(),0,'[]'))
            self.db.execute('UPDATE inputs SET work_id=? WHERE work_id IS NULL',(self.identity['root'],))
        Path(path).chmod(0o600)

    def accept(self, operation, content, scope, target=None, generation=None, work_id=None, active_context=None, attachments=None):
        with self.db:
            existing = self.db.execute('SELECT * FROM inputs WHERE operation_id=?', (operation,)).fetchone()
            if existing:
                if (existing['content'],existing['target_run_id'],existing['target_generation']) != (content,target,generation) or (work_id and existing['work_id'] != work_id):
                    raise web.HTTPConflict(reason='operation_conflict')
                return dict(existing)
            run = 'run_momo_' + operation.replace('-', '')
            attachments_json = json.dumps(attachments, ensure_ascii=False) if attachments else None
            msg_attachments = [{k: v for k, v in item.items() if k != 'data' or not item.get('preview')} for item in attachments] if attachments else None
            msg_attachments_json = json.dumps(msg_attachments, ensure_ascii=False) if msg_attachments else None
            if target is None:
                work_id = 'work-' + operation
                rows = self.db.execute("""SELECT m.seq,m.role,m.content FROM messages m LEFT JOIN inputs i ON i.operation_id=m.operation_id
                    WHERE m.role IN ('user','assistant') AND (i.intent IS NULL OR i.intent!='steer' OR i.delivery_state='applied')
                    ORDER BY m.seq DESC LIMIT 40""").fetchall()
                history = []; size = 0
                for row in rows:
                    if not row['content']: continue
                    size += len(row['content'].encode())
                    if size > 24576: break
                    history.append({'role':row['role'],'content':row['content']})
                title = ' '.join(content.split())[:64] or (attachments[0]['name'][:64] if attachments else '任务')
                self.db.execute('INSERT INTO works(id,native_root,origin_run_id,title,created_at,context_through_seq,context_json) VALUES(?,?,?,?,?,?,?)',
                    (work_id,'momo-work-' + operation,run,title,time.time(), rows[0]['seq'] if rows else 0,json.dumps(history[::-1],ensure_ascii=False)))
                self.db.execute('UPDATE works SET active_context=? WHERE id=?',(json.dumps(active_context or [],ensure_ascii=False),work_id))
            self.db.execute('INSERT INTO inputs(operation_id,content,run_id,owner_scope,target_run_id,target_generation,work_id,intent,attachments_json) VALUES(?,?,?,?,?,?,?,?,?)',
                            (operation,content,run,scope,target,generation,work_id,'steer' if target else 'new',attachments_json))
            self.db.execute('INSERT INTO messages(id,role,content,created_at,operation_id,run_id,attachments_json) VALUES(?,?,?,?,?,?,?)',
                            ('user-' + operation, 'user', content, time.time(), operation, run, msg_attachments_json))
            self.message_event('user-' + operation)
        return dict(self.db.execute('SELECT * FROM inputs WHERE operation_id=?', (operation,)).fetchone())

    @staticmethod
    def _format_message(row):
        item = dict(row)
        raw = item.pop('attachments_json', None)
        if raw:
            try: item['attachments'] = json.loads(raw)
            except ValueError: pass
        return item

    def message_states(self):
        # Small mutable projection, independent of the immutable message cursor. An
        # already-read bubble can become not_applied without deletion or duplication.
        return {'user-'+r['operation_id']:r['delivery_state'] for r in self.db.execute("SELECT operation_id,delivery_state FROM inputs WHERE intent='steer'")}

    def page(self, after=0, before=None, limit=100):
        comparator, cursor, order = ('<', before, 'DESC') if before is not None else ('>', after, 'ASC')
        rows = self.db.execute(f'SELECT * FROM messages WHERE seq {comparator} ? ORDER BY seq {order} LIMIT ?',
                               (cursor, limit + 1)).fetchall()
        more = len(rows) > limit
        rows = rows[:limit]
        if before is not None: rows = rows[::-1]
        data = [self._format_message(row) for row in rows]
        return dict(data=data, next_cursor=(data[0 if before is not None else -1]['seq'] if data else cursor), has_more=more)

    def append_assistant(self, key, content, created, run_id=None):
        with self.db:
            found = self.db.execute('SELECT id FROM messages WHERE source_key=?', (key,)).fetchone()
            if found: return found[0]
            identifier = 'assistant-' + hashlib.sha256(key.encode()).hexdigest()[:32]
            self.db.execute('INSERT INTO messages(id,role,content,created_at,run_id,source_key) VALUES(?,?,?,?,?,?)',
                            (identifier, 'assistant', content, created, run_id, key))
            self.message_event(identifier)
        return identifier

    def append_legacy(self, key, role, content, created, run_id, session):
        # Backfill is presentation only: never replay old inputs or send new notifications.
        if self.db.execute('SELECT 1 FROM messages WHERE source_key=?', (key,)).fetchone(): return
        identifier = 'legacy-' + hashlib.sha256(key.encode()).hexdigest()[:32]
        with self.db:
            self.db.execute('INSERT OR IGNORE INTO messages(id,role,content,created_at,run_id,source_key,source_session) VALUES(?,?,?,?,?,?,?)',
                (identifier, role, content, created, run_id, key, session))
            self.message_event(identifier)

    def project_assistant(self, admission, ordinal, content, created, run_id):
        # Interim callbacks and native persisted messages have independent ordinals.
        # Never let the first acknowledgement consume the final answer's identity.
        key = f'native-turn:{admission}:{ordinal}'
        with self.db:
            found = self.db.execute('SELECT id FROM messages WHERE source_key=?', (key,)).fetchone()
            if found: return found['id']
            previous = self.db.execute('SELECT id,content FROM messages WHERE source_key=?',
                                       (f'turn:{admission}:{ordinal}',)).fetchone()
            if previous is None or previous['content'] != content:
                previous = self.db.execute("SELECT id,content FROM messages WHERE source_key LIKE ? AND run_id=? AND content=? ORDER BY seq LIMIT 1",
                                           (f'interim:{admission}:%', run_id, content)).fetchone()
            if previous is not None and previous['content'] == content:
                # Preserve already-rendered IDs and cursor positions when upgrading or
                # when Hermes persists an interim callback as a native assistant row.
                self.db.execute('UPDATE messages SET source_key=? WHERE id=?', (key, previous['id']))
                return previous['id']
        return self.append_assistant(key, content, created, run_id)

    def message_event(self, identifier):
        message = self.db.execute('SELECT * FROM messages WHERE id=?', (identifier,)).fetchone()
        self.events.append('message.created', {'message': self._format_message(message)})
