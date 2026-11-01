"""relay-e2e/v1 responder, interoperable with relay-kit (see docs/implementation/relay-access.md)."""
import base64
import hashlib
import hmac
import json
import secrets

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

PROTOCOL = b'relay-e2e/v1'


def b64u(value):
    return base64.urlsafe_b64encode(value).decode().rstrip('=')


def unb64u(value):
    if not isinstance(value, str) or len(value) > 256:
        raise ValueError('Invalid handshake')
    return base64.b64decode(value + '=' * (-len(value) % 4), altchars=b'-_', validate=True)


def hkdf(key, salt, info, length=32):
    return HKDF(algorithm=hashes.SHA256(), length=length, salt=salt, info=info).derive(key)


def routing_token(code):
    return b64u(hkdf(code.encode(), PROTOCOL + b'/routing', b'', 16))


class RelayCipher:
    def __init__(self, code):
        self.code = code
        self.keys = None
        self.ready = False
        self.sent = 0
        self.received = -1

    def handshake(self, frame):
        if not isinstance(frame, dict):
            raise ValueError('Invalid handshake')
        if self.ready:
            raise ValueError('Handshake already complete')
        if self.keys is None and frame.get('t') == 'hi':
            peer = unb64u(frame['epk']); nonce = unb64u(frame['n'])
            if len(peer) != 65 or len(nonce) != 16:
                raise ValueError('Invalid handshake')
            key = ec.generate_private_key(ec.SECP256R1())
            public = key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
            own_nonce = secrets.token_bytes(16)
            shared = key.exchange(ec.ECDH(), ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), peer))
            transcript = hashlib.sha256(PROTOCOL + peer + public + nonce + own_nonce).digest()
            self.keys = {label: hkdf(shared, self.code.encode(), label.encode() + b'|' + transcript)
                         for label in ('c2s', 's2c', 'confirm-r', 'confirm-i')}
            return dict(t='hi', epk=b64u(public), n=b64u(own_nonce), cr=b64u(self.keys['confirm-r']))
        if self.keys is not None and frame.get('t') == 'ok':
            if not hmac.compare_digest(unb64u(frame['ci']), self.keys['confirm-i']):
                raise ValueError('Authentication failed')
            self.ready = True
            return None
        raise ValueError('Invalid handshake order')

    def seal(self, frame):
        if not self.ready or self.sent >= 2**64:
            raise ValueError('Invalid session')
        iv = bytes(4) + self.sent.to_bytes(8, 'big'); self.sent += 1
        return iv + AESGCM(self.keys['s2c']).encrypt(iv, json.dumps(frame, separators=(',', ':')).encode(), None)

    def open(self, wire):
        if not self.ready or len(wire) < 28 or wire[:4] != bytes(4):
            raise ValueError('Invalid encrypted frame')
        counter = int.from_bytes(wire[4:12], 'big')
        if counter <= self.received:
            raise ValueError('Replayed frame')
        plain = AESGCM(self.keys['c2s']).decrypt(wire[:12], wire[12:], None)
        self.received = counter
        frame = json.loads(plain)
        if not isinstance(frame, dict):
            raise ValueError('Invalid application frame')
        return frame
