"""Thin authenticated-UI adapter over Hermes' own file store. No second memory database."""
from contextlib import contextmanager
import hashlib
from pathlib import Path
import re

from context_store import Conflict


class HermesMemory:
    def __init__(self, home):
        self.home = Path(home)

    @contextmanager
    def store(self):
        from hermes_constants import set_hermes_home_override, reset_hermes_home_override
        from tools.memory_tool import load_on_disk_store
        token = set_hermes_home_override(self.home)
        try:
            # Surface unreadable content instead of showing an empty successful refresh.
            for name in ('MEMORY.md', 'USER.md'):
                path = self.home / 'memories' / name
                if path.exists(): path.read_text(encoding='utf-8')
            yield load_on_disk_store()
        finally:
            reset_hermes_home_override(token)

    @staticmethod
    def items(store):
        items = []
        for target, entries in (('memory', store.memory_entries), ('user', store.user_entries)):
            for text in entries:
                digest = hashlib.sha256(text.encode()).hexdigest()
                items.append({'id': f'hermes-{target}-{digest}', 'text': text, 'kind': target,
                              'basis': 'hermes', 'status': 'current', 'revision': int(digest[:15], 16), 'evidence': []})
        return sorted(items, key=lambda item: item['id'])

    def list(self, after='', limit=100, expected_revision=None):
        if not 1 <= limit <= 200: raise ValueError('limit must be 1...200')
        with self.store() as store:
            items = self.items(store)
        revision = int(hashlib.sha256('\n'.join(item['id'] for item in items).encode()).hexdigest()[:15], 16)
        if expected_revision is not None and revision != expected_revision:
            raise Conflict('Hermes memory changed; refresh the current entries')
        page = [item for item in items if item['id'] > after]
        return {'revision': revision, 'items': page[:limit], 'next_cursor': page[limit-1]['id'] if len(page)>limit else None}

    def forget(self, identity):
        if not isinstance(identity, str) or not re.fullmatch(r'hermes-(memory|user)-[0-9a-f]{64}', identity):
            raise Conflict('This is an old memory view; refresh Hermes memory before editing')
        with self.store() as store:
            item = next((item for item in self.items(store) if item['id'] == identity), None)
            if item:
                # Native matching, reload-under-lock, validation and atomic write stay in Hermes.
                result = store.remove(item['kind'], item['text'], matched_entry=item['text'])
                if not result.get('success'): raise Conflict(result.get('error', 'Memory changed; refresh and retry'))
        # A lost acknowledgement can retry the same content identity. Never delete a newer entry.
        return {'id': identity, 'status': 'forgotten'}
