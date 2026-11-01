"""Device grants: QR invitations are public; only a local Mac approval grants access."""
import hashlib
from ipaddress import IPv4Address, IPv4Network
import secrets
import sqlite3
import time
import uuid
from pathlib import Path
from urllib.parse import urlsplit


def is_tailnet_endpoint(value):
    if not isinstance(value, str): return False
    try:
        u = urlsplit(value)
        return (u.scheme == 'http' and IPv4Address(u.hostname) in IPv4Network('100.64.0.0/10') and
                u.netloc == f'{u.hostname}:8767' and u.path in ('', '/') and not u.query and not u.fragment)
    except (ValueError, TypeError): return False


def endpoint(value, network=None):
    if network == 'relay':
        if not isinstance(value, str) or not value.startswith('https://'): raise ValueError('Relay requires HTTPS')
        return endpoint(value)
    if network is not None:
        if network != 'tailscale' or not is_tailnet_endpoint(value): raise ValueError('Invalid embedded endpoint')
        return value.rstrip('/')
    u = urlsplit(value)
    if (u.scheme != 'https' and not (u.scheme == 'http' and u.hostname in ('127.0.0.1', 'localhost', '::1'))) or not u.hostname or u.username or u.password or u.query or u.fragment or u.path not in ('', '/'):
        raise ValueError('需要 HTTPS 地址，本机测试可用 loopback HTTP')
    return value.rstrip('/')


def digest(token):
    if not isinstance(token, str) or not 40 <= len(token) <= 160 or not token.isascii() or not all(c.isalnum() or c in '-_' for c in token):
        raise ValueError('Invalid device credential')
    return hashlib.sha256(token.encode()).hexdigest()


class PairingStore:
    def __init__(self, directory, now=time.time):
        directory = Path(directory); directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.db = sqlite3.connect(directory / 'devices.sqlite3')
        (directory / 'devices.sqlite3').chmod(0o600)
        self.db.row_factory = sqlite3.Row; self.now = now
        self._last_seen_written = {}
        self.db.executescript('''
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS invitations(id TEXT PRIMARY KEY, endpoint TEXT NOT NULL, expires REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY, invitation TEXT NOT NULL, name TEXT NOT NULL, token_hash TEXT UNIQUE NOT NULL, code TEXT NOT NULL, state TEXT NOT NULL, expires REAL NOT NULL, created REAL NOT NULL, last_seen REAL, endpoint TEXT NOT NULL);
        ''')

    def invite(self, url, network=None):
        url = endpoint(url, network); now = self.now()
        with self.db:
            self.db.execute('DELETE FROM invitations')
            self.db.execute("UPDATE devices SET state='expired' WHERE state='pending'")
            value = {'id': str(uuid.uuid4()), 'endpoint': url, 'expires': now + 300}
            self.db.execute('INSERT INTO invitations VALUES(:id,:endpoint,:expires)', value)
        return value

    def invalidate_invitations(self):
        with self.db:
            self.db.execute('DELETE FROM invitations')
            self.db.execute("UPDATE devices SET state='expired' WHERE state='pending'")

    def request(self, invitation, name, token):
        hashed = digest(token); now = self.now()
        if not isinstance(name, str) or not 1 <= len(name.strip()) <= 80 or any(ord(c) < 32 for c in name):
            raise ValueError('Invalid device name')
        existing = self.db.execute('SELECT * FROM devices WHERE token_hash=?', (hashed,)).fetchone()
        if existing and existing['invitation'] == invitation:
            return self.claim(existing['id'], token)
        invite = self.db.execute('SELECT * FROM invitations WHERE id=? AND expires>?', (invitation, now)).fetchone()
        if not invite: raise ValueError('二维码已过期，请在 Mac 刷新')
        if existing and existing['state'] == 'approved':
            # Possession of the existing grant proves this is the same device.
            with self.db:
                self.db.execute('UPDATE devices SET invitation=?,name=?,endpoint=?,last_seen=? WHERE id=?',
                                (invitation, name.strip(), invite['endpoint'], now, existing['id']))
            self._last_seen_written[existing['id']] = now
            return self.claim(existing['id'], token)
        if self.db.execute("SELECT COUNT(*) FROM devices WHERE invitation=? AND state='pending'", (invitation,)).fetchone()[0] >= 4:
            raise ValueError('等待确认的设备过多，请刷新二维码')
        if existing:
            # Revoked/rejected grants keep their identity, but require fresh Mac approval.
            with self.db:
                self.db.execute("UPDATE devices SET invitation=?,name=?,endpoint=?,code=?,state='pending',expires=? WHERE id=?",
                                (invitation, name.strip(), invite['endpoint'], f'{secrets.randbelow(1000000):06d}',
                                 invite['expires'], existing['id']))
            return self.claim(existing['id'], token)
        value = (str(uuid.uuid4()), invitation, name.strip(), hashed, f'{secrets.randbelow(1000000):06d}', 'pending', invite['expires'], now, invite['endpoint'])
        with self.db: self.db.execute('INSERT INTO devices(id,invitation,name,token_hash,code,state,expires,created,endpoint) VALUES(?,?,?,?,?,?,?,?,?)', value)
        return self.claim(value[0], token)

    def claim(self, ident, token):
        row = self.db.execute('SELECT * FROM devices WHERE id=? AND token_hash=?', (ident, digest(token))).fetchone()
        if not row: raise PermissionError('Unknown pairing request')
        state = row['state']
        if state == 'pending' and row['expires'] <= self.now(): state = 'expired'
        return {'id': row['id'], 'name': row['name'], 'code': row['code'], 'state': state, 'expires': row['expires']}

    def decide(self, ident, allow):
        with self.db:
            row = self.db.execute('SELECT * FROM devices WHERE id=?', (ident,)).fetchone()
            if not row or row['state'] != 'pending' or row['expires'] <= self.now(): raise ValueError('配对请求已失效')
            self.db.execute('UPDATE devices SET state=? WHERE id=?', ('approved' if allow else 'rejected', ident))
            if allow:
                self.db.execute('DELETE FROM invitations WHERE id=?', (row['invitation'],))
                self.db.execute("UPDATE devices SET state='rejected' WHERE invitation=? AND state='pending'", (row['invitation'],))

    def authorized(self, token):
        try: hashed = digest(token)
        except ValueError: return False
        row = self.db.execute("SELECT id FROM devices WHERE token_hash=? AND state='approved'", (hashed,)).fetchone()
        if row:
            now = self.now()
            last = self._last_seen_written.get(row['id'])
            if last is None or abs(now - last) >= 10:
                with self.db: self.db.execute('UPDATE devices SET last_seen=? WHERE id=?', (now, row['id']))
                self._last_seen_written[row['id']] = now
        return bool(row)

    def device_id(self, token):
        try: hashed = digest(token)
        except ValueError: return None
        row = self.db.execute("SELECT id FROM devices WHERE token_hash=? AND state='approved'", (hashed,)).fetchone()
        return row[0] if row else None

    def revoke(self, ident):
        self._last_seen_written.pop(ident, None)
        with self.db: self.db.execute("UPDATE devices SET state='revoked' WHERE id=?", (ident,))

    def devices(self):
        with self.db: self.db.execute("UPDATE devices SET state='expired' WHERE state='pending' AND expires<=?", (self.now(),))
        return [dict(r) for r in self.db.execute('SELECT id,name,code,state,expires,created,last_seen,endpoint FROM devices ORDER BY created DESC LIMIT 100')]
