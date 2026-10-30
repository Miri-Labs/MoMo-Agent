"""Durable conversation cursor; notifications wake readers but never carry truth.

Follows Rakazo's snapshot -> subscribe -> replay contract. SQLite belongs to the
single Mac product process; no second broker or agent execution loop is needed.
"""
import asyncio
import json
from aiohttp import web


class ConversationEvents:
    def __init__(self, db, conversation_id):
        self.db, self.conversation_id = db, conversation_id
        self.listeners = set()
        db.executescript('''
        CREATE TABLE IF NOT EXISTS conversation_events(cursor INTEGER PRIMARY KEY AUTOINCREMENT,
            kind TEXT NOT NULL, payload TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS conversation_event_state(key TEXT PRIMARY KEY, payload TEXT NOT NULL);
        ''')

    @property
    def cursor(self):
        return self.db.execute('SELECT coalesce(max(cursor),0) FROM conversation_events').fetchone()[0]

    def append(self, kind, payload):
        # Caller commits this row in the same transaction as the visible change.
        self.db.execute('INSERT INTO conversation_events(kind,payload) VALUES(?,?)',
                        (kind, json.dumps(payload, ensure_ascii=False, separators=(',', ':'))))
        for listener in self.listeners: listener.set()

    def publish(self, kind, payload):
        with self.db:
            self.append(kind, payload)
            event = payload.get('run_event', {})
            if kind == 'run.event' and event.get('event') in ('run.completed','run.failed','run.cancelled','run.interrupted'):
                # Settled canonical messages replace transient typing history; cursor IDs never recycle.
                self.db.execute("DELETE FROM conversation_events WHERE kind='run.event' AND json_extract(payload,'$.run_event.run_id')=? AND json_extract(payload,'$.run_event.event') IN ('message.delta','message.interim','replay.truncated')", (event['run_id'],))

    def changed(self, key, kind, payload):
        encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(',', ':'))
        previous = self.db.execute('SELECT payload FROM conversation_event_state WHERE key=?', (key,)).fetchone()
        if previous and previous[0] == encoded: return
        with self.db:
            self.db.execute('INSERT OR REPLACE INTO conversation_event_state VALUES(?,?)', (key, encoded))
            self.append(kind, payload)

    def after(self, cursor, limit=100):
        result = []
        for row in self.db.execute('SELECT * FROM conversation_events WHERE cursor>? ORDER BY cursor LIMIT ?', (cursor, limit)):
            value = dict(conversation_id=self.conversation_id, cursor=row['cursor'], kind=row['kind'], **json.loads(row['payload']))
            if 'run_event' in value:
                # Native per-run counters can restart. The durable conversation sequence cannot.
                value['run_event']['seq'] = row['cursor']
            result.append(value)
        return result

    async def subscribe(self, request, authorized, heartbeat=15):
        if set(request.query) != {'after'} or len(request.query.getall('after')) != 1:
            raise web.HTTPBadRequest(reason='Invalid event cursor')
        try: cursor = int(request.query['after'])
        except ValueError: raise web.HTTPBadRequest(reason='Invalid event cursor')
        if not 0 <= cursor <= self.cursor: raise web.HTTPConflict(reason='event_cursor_invalid')
        response = web.StreamResponse(headers={'Content-Type':'text/event-stream', 'Cache-Control':'no-store', 'X-Accel-Buffering':'no'})
        wake = asyncio.Event(); self.listeners.add(wake)

        async def send(value):
            if not authorized(): raise ConnectionError('Subscription revoked')
            async with asyncio.timeout(5):
                await response.write(('data: ' + json.dumps(value, ensure_ascii=False, separators=(',', ':')) + '\n\n').encode())

        try:
            await response.prepare(request)
            await send(dict(conversation_id=self.conversation_id, kind='ready'))
            while True:
                # Clear before reading: a commit while writing a batch cannot be lost.
                wake.clear()
                batch = self.after(cursor)
                if batch:
                    for value in batch:
                        await send(value); cursor = value['cursor']
                    continue
                try: await asyncio.wait_for(wake.wait(), heartbeat)
                except TimeoutError:
                    await send(dict(conversation_id=self.conversation_id, kind='heartbeat'))
        except (ConnectionError, TimeoutError): response.force_close()
        finally: self.listeners.discard(wake)
        return response
