"""Authorization lifecycle, retry safety and changeable network endpoints."""
import sys
import tempfile
import unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Apps/MacApp/Access'))
from pairing_store import PairingStore, endpoint

class PairingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.time = 1000
        self.store = PairingStore(self.temp.name, now=lambda: self.time)
        self.token = 'a' * 64; self.invite = self.store.invite('https://first.example')
    def tearDown(self): self.store.db.close(); self.temp.cleanup()
    def request(self, token=None): return self.store.request(self.invite['id'], 'Test phone', token or self.token)
    def test_approval_required_and_secret_is_hashed(self):
        r = self.request(); self.assertFalse(self.store.authorized(self.token))
        row = self.store.db.execute('SELECT token_hash FROM devices').fetchone()
        self.assertNotEqual(self.token, row[0]); self.store.decide(r['id'], True)
        self.assertTrue(self.store.authorized(self.token)); self.assertEqual('approved', self.store.claim(r['id'], self.token)['state'])
        self.store.revoke(r['id']); self.assertFalse(self.store.authorized(self.token))
    def test_lost_request_and_approval_receipt_resume_after_restart(self):
        r = self.request(); self.assertEqual(r, self.request()); self.store.decide(r['id'], True)
        self.store.db.close(); self.store = PairingStore(self.temp.name, now=lambda: self.time)
        self.assertEqual('approved', self.request()['state']); self.assertTrue(self.store.authorized(self.token))
    def test_expiry_refresh_and_provider_change_expire_pending_only(self):
        r = self.request(); self.time += 301
        with self.assertRaises(ValueError): self.store.decide(r['id'], True)
        self.assertEqual('expired', self.store.claim(r['id'], self.token)['state'])
        self.invite = self.store.invite('https://second.example'); r = self.request('b'*64); self.store.decide(r['id'], True)
        self.invite = self.store.invite('https://third.example'); pending = self.request('c'*64)
        self.store.invalidate_invitations(); self.assertTrue(self.store.authorized('b'*64))
        self.assertEqual('expired', self.store.claim(pending['id'], 'c'*64)['state'])
    def test_code_is_not_a_credential_and_other_requests_are_rejected(self):
        a = self.request(); b = self.request('b'*64)
        self.assertFalse(self.store.authorized(a['code'])); self.store.decide(a['id'], True)
        self.assertEqual('rejected', self.store.claim(b['id'], 'b'*64)['state'])
        with self.assertRaises(PermissionError): self.store.claim(a['id'], 'c'*64)
    def test_only_root_https_or_local_http(self):
        for url in ['http://external.example', 'https://user:pass@example.com', 'https://example.com/admin', 'https://example.com/?token=secret']:
            with self.assertRaises(ValueError): endpoint(url)
        self.assertEqual('http://127.0.0.1:18887', endpoint('http://127.0.0.1:18887/'))

    def test_rescanning_same_device_keeps_grant_and_device_id(self):
        first = self.request(); self.store.decide(first['id'], True)
        self.invite = self.store.invite('https://first.example')
        again = self.request()
        self.assertEqual(first['id'], again['id'])
        self.assertEqual('approved', again['state'])
        self.assertEqual(1, len(self.store.devices()))
        self.assertTrue(self.store.authorized(self.token))
        self.assertEqual(first['id'], self.store.device_id(self.token))

    def test_same_name_without_same_credential_is_not_the_same_phone(self):
        first = self.request(); self.store.decide(first['id'], True)
        self.invite = self.store.invite('https://first.example')
        other = self.request('b' * 64)
        self.assertNotEqual(first['id'], other['id'])
        self.assertEqual('pending', other['state'])
        self.assertFalse(self.store.authorized('b' * 64))

    def test_revoked_device_rescan_requires_approval_without_duplicating_device(self):
        first = self.request(); self.store.decide(first['id'], True); self.store.revoke(first['id'])
        self.assertEqual('revoked', self.request()['state'])
        self.invite = self.store.invite('https://first.example')
        again = self.request()
        self.assertEqual(first['id'], again['id'])
        self.assertEqual('pending', again['state'])
        self.assertFalse(self.store.authorized(self.token))
        self.store.decide(again['id'], True)
        self.assertTrue(self.store.authorized(self.token))
        self.assertEqual(1, len(self.store.devices()))

    def test_expired_new_invitation_does_not_modify_existing_grant(self):
        first = self.request(); self.store.decide(first['id'], True)
        self.invite = self.store.invite('https://second.example'); self.time += 301
        with self.assertRaises(ValueError): self.request()
        self.assertTrue(self.store.authorized(self.token))
        self.assertEqual('https://first.example', self.store.devices()[0]['endpoint'])

    def test_private_http_requires_explicit_network_and_keeps_device_approval(self):
        url = 'http://100.64.0.1:8767'
        with self.assertRaises(ValueError): self.store.invite(url)
        self.invite = self.store.invite(url, network='tailscale')
        pending = self.request()
        self.assertFalse(self.store.authorized(self.token))
        self.store.decide(pending['id'], True)
        self.assertTrue(self.store.authorized(self.token))
        for invalid in ['http://100.128.0.1:8767', 'http://192.168.0.1:8767', 'http://127.0.0.1:8767',
                        'http://100.64.0.1:80', 'http://user@100.64.0.1:8767', 'http://100.64.0.1:8767/a']:
            with self.assertRaises(ValueError): self.store.invite(invalid, network='tailscale')
        self.assertTrue(self.store.authorized(self.token))

    def test_authorized_throttles_last_seen_writes_without_delaying_revocation(self):
        req = self.request(); self.store.decide(req['id'], True)
        self.assertTrue(self.store.authorized(self.token))
        self.assertEqual(1000, self.store.devices()[0]['last_seen'])
        self.time = 1005
        self.assertTrue(self.store.authorized(self.token))
        self.assertEqual(1000, self.store.devices()[0]['last_seen'])
        self.time = 1010
        self.assertTrue(self.store.authorized(self.token))
        self.assertEqual(1010, self.store.devices()[0]['last_seen'])
        self.store.revoke(req['id'])
        self.assertFalse(self.store.authorized(self.token))

if __name__ == '__main__': unittest.main()
