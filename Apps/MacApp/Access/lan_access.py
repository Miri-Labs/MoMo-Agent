"""LAN pairing over a per-Mac self-signed TLS endpoint with a pinned fingerprint."""
import hashlib
import ipaddress
import socket
import ssl
from datetime import datetime, timedelta, timezone
from pathlib import Path

from aiohttp import web
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

from pairing_store import is_lan_address


def lan_addresses():
    """Return private IPv4 addresses, primary route first, without sending packets."""
    primary = None
    found = set()
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.connect(('192.0.2.1', 9))
            candidate = probe.getsockname()[0]
            if is_lan_address(candidate):
                primary = candidate
    except OSError:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            address = info[4][0]
            if is_lan_address(address):
                found.add(address)
    except OSError:
        pass
    if primary:
        found.add(primary)
    ordered = sorted(found)
    if primary in found:
        ordered.remove(primary)
        ordered.insert(0, primary)
    return ordered


def _issued_certificate(path):
    certificate = x509.load_pem_x509_certificate(path.read_bytes())
    if certificate.not_valid_after_utc <= datetime.now(timezone.utc) + timedelta(days=7):
        return None
    try:
        san = certificate.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
        return {str(value) for value in san.get_values_for_type(x509.IPAddress)}
    except x509.ExtensionNotFound:
        return set()


class LanAccess:
    """Owns the LAN TLS listener and the certificate fingerprint shown in the QR."""

    def __init__(self, directory, port):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.port = port
        self.state = {'state': 'stopped', 'endpoint': None, 'fingerprint': None, 'error': None}
        self._runner = None

    def certificate(self):
        cert_path = self.directory / 'lan-cert.pem'
        key_path = self.directory / 'lan-key.pem'
        addresses = lan_addresses()
        if not addresses:
            raise ValueError('没有可用的局域网地址，请连接 Wi-Fi 或有线网络')
        if cert_path.exists() and key_path.exists():
            present = _issued_certificate(cert_path)
            if present is not None and set(addresses) <= present:
                certificate = x509.load_pem_x509_certificate(cert_path.read_bytes())
                return cert_path, key_path, certificate
        key = ec.generate_private_key(ec.SECP256R1())
        now = datetime.now(timezone.utc)
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'MoMo Agent LAN')])
        san = x509.SubjectAlternativeName(
            [x509.IPAddress(ipaddress.IPv4Address(address)) for address in addresses],
        )
        certificate = (
            x509.CertificateBuilder()
            .subject_name(subject)
            .issuer_name(subject)
            .public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now - timedelta(minutes=5))
            .not_valid_after(now + timedelta(days=365))
            .add_extension(san, critical=False)
            .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
            .add_extension(
                x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]),
                critical=False,
            )
            .sign(key, hashes.SHA256())
        )
        key_path.write_bytes(
            key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            ),
        )
        cert_path.write_bytes(certificate.public_bytes(serialization.Encoding.PEM))
        key_path.chmod(0o600)
        cert_path.chmod(0o600)
        return cert_path, key_path, certificate

    def fingerprint(self):
        _, _, certificate = self.certificate()
        return hashlib.sha256(certificate.public_bytes(serialization.Encoding.DER)).hexdigest()

    async def start(self, app):
        cert_path, key_path, certificate = self.certificate()
        addresses = lan_addresses()
        if not addresses:
            raise ValueError('没有可用的局域网地址，请连接 Wi-Fi 或有线网络')
        fingerprint = hashlib.sha256(
            certificate.public_bytes(serialization.Encoding.DER),
        ).hexdigest()
        endpoint = f'https://{addresses[0]}:{self.port}'
        if (self._runner is not None and self.state['state'] == 'connected' and
                self.state['endpoint'] == endpoint and self.state['fingerprint'] == fingerprint):
            return endpoint
        if self._runner is not None:
            await self.stop()
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(cert_path, key_path)
        runner = web.AppRunner(app, access_log=None)
        await runner.setup()
        try:
            await web.TCPSite(runner, '0.0.0.0', self.port, ssl_context=context).start()
        except OSError:
            await runner.cleanup()
            self.state.update(state='stopped', endpoint=None, fingerprint=None,
                              error='局域网端口不可用，请检查防火墙或端口占用')
            raise ValueError('局域网端口不可用，请检查防火墙或端口占用')
        self._runner = runner
        self.state.update(state='connected', endpoint=endpoint, fingerprint=fingerprint, error=None)
        return endpoint

    async def stop(self):
        if self._runner is not None:
            await self._runner.cleanup()
            self._runner = None
        self.state.update(state='stopped', endpoint=None, fingerprint=None, error=None)
