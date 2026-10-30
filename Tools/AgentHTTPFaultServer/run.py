#!/usr/bin/env -S uv run
"""Prepare ephemeral TLS, run loopback faults, and query/control one isolated case."""

from __future__ import annotations

import argparse
import http.client
import json
import os
from pathlib import Path
import signal
import ssl
import subprocess
import sys
import uuid

from server import FaultServer, SCENARIOS, SYNTHETIC_KEY, configuration


def save_json(path: Path, value: dict):
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(path)


def prepare(output: Path):
    output.mkdir(parents=True, mode=0o700, exist_ok=False)
    old_mask = os.umask(0o077)
    try:
        extensions = output / "server.ext"
        extensions.write_text("basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:127.0.0.1\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always\n")
        commands = [
            ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
             "-subj", "/CN=MoMoAgent J17 Temporary CA", "-addext", "basicConstraints=critical,CA:TRUE",
             "-addext", "keyUsage=critical,keyCertSign,cRLSign", "-addext", "subjectKeyIdentifier=hash",
             "-keyout", str(output / "ca-key.pem"), "-out", str(output / "ca.pem")],
            ["openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=127.0.0.1",
             "-keyout", str(output / "server-key.pem"), "-out", str(output / "server.csr")],
            ["openssl", "x509", "-req", "-in", str(output / "server.csr"), "-CA", str(output / "ca.pem"),
             "-CAkey", str(output / "ca-key.pem"), "-CAcreateserial", "-days", "2", "-sha256",
             "-extfile", str(extensions), "-out", str(output / "server.pem")],
        ]
        for command in commands:
            subprocess.run(command, check=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=30)
        # No further certificates need signing; retain only the public CA and serving key.
        for name in ("ca-key.pem", "ca.srl", "server.csr", "server.ext"):
            (output / name).unlink(missing_ok=True)
        save_json(output / "fixture-tls.json", {"kind": "momoagent-j17-temporary-tls", "version": 1})
    except BaseException:
        for name in ("ca-key.pem", "ca.srl", "ca.pem", "server.csr", "server.ext", "server.pem", "server-key.pem"):
            (output / name).unlink(missing_ok=True)
        raise
    finally:
        os.umask(old_mask)


def terminate(signum, frame):
    raise KeyboardInterrupt()


def serve(args):
    config = configuration(args.config)
    args.output.mkdir(parents=True, mode=0o700, exist_ok=False)
    server = FaultServer(args.port, args.tls / "server.pem", args.tls / "server-key.pem", args.output, config)
    port = server.server_address[1]
    ready = {"kind": "momoagent-j17-loopback-https", "pid": os.getpid(), "host": "127.0.0.1", "port": port,
             "caCertificate": str((args.tls / "ca.pem").resolve()), "scenarios": list(SCENARIOS),
             "baseURLTemplate": f"https://127.0.0.1:{port}/runs/<RUN_UUID>/<SCENARIO>/v1",
             "timing": config["timing"], "evidenceScope": "synthetic_endpoint_only"}
    previous = signal.getsignal(signal.SIGTERM)
    try:
        signal.signal(signal.SIGTERM, terminate)
        save_json(args.output / "ready.json", ready)
        print(json.dumps(ready), flush=True)
        server.serve_forever(poll_interval=0.05)
    except KeyboardInterrupt:
        pass
    finally:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        previous_int = signal.signal(signal.SIGINT, signal.SIG_IGN)
        server.stopping.set()
        server.server_close()
        save_json(args.output / "stopped.json", {"kind": ready["kind"], "pid": ready["pid"], "stopped": True})
        signal.signal(signal.SIGTERM, previous)
        signal.signal(signal.SIGINT, previous_int)


def control(args):
    ready = json.loads(args.ready.read_text())
    if ready.get("kind") != "momoagent-j17-loopback-https" or ready.get("host") != "127.0.0.1":
        raise ValueError("invalid_ready")
    run_id = str(uuid.UUID(args.run_id))
    context = ssl.create_default_context(cafile=ready["caCertificate"])
    connection = http.client.HTTPSConnection("127.0.0.1", ready["port"], context=context, timeout=5)
    try:
        path = f"/runs/{run_id}/{args.scenario}/{args.command}"
        connection.request("POST" if args.command == "release" else "GET", path,
                           headers={"Authorization": "Bearer " + SYNTHETIC_KEY})
        response = connection.getresponse()
        raw = response.read()
        if response.status not in (200, 204):
            raise ValueError("control_failed")
        print(raw.decode() if raw else json.dumps({"released": True, "runID": run_id, "scenario": args.scenario}))
    finally:
        connection.close()


def cleanup_tls(path: Path):
    marker = path / "fixture-tls.json"
    if path.is_symlink() or json.loads(marker.read_text()) != {"kind": "momoagent-j17-temporary-tls", "version": 1}:
        raise ValueError("unowned_tls_directory")
    expected = {"fixture-tls.json", "ca.pem", "server.pem", "server-key.pem"}
    if {entry.name for entry in path.iterdir()} != expected:
        raise ValueError("unexpected_tls_files")
    for name in sorted(expected):
        (path / name).unlink()
    path.rmdir()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare_parser = commands.add_parser("prepare")
    prepare_parser.add_argument("--output", type=Path, required=True)
    serve_parser = commands.add_parser("serve")
    serve_parser.add_argument("--tls", type=Path, required=True)
    serve_parser.add_argument("--output", type=Path, required=True)
    serve_parser.add_argument("--port", type=int, default=0)
    serve_parser.add_argument("--config", type=Path)
    for name in ("counts", "release"):
        command = commands.add_parser(name)
        command.add_argument("--ready", type=Path, required=True)
        command.add_argument("--run-id", required=True)
        command.add_argument("--scenario", choices=SCENARIOS, required=True)
    cleanup_parser = commands.add_parser("cleanup-tls")
    cleanup_parser.add_argument("--tls", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == "prepare":
            prepare(args.output)
        elif args.command == "serve":
            serve(args)
        elif args.command == "cleanup-tls":
            cleanup_tls(args.tls)
        else:
            control(args)
        return 0
    except KeyboardInterrupt:
        print('{"error":"interrupted"}', file=sys.stderr)
        return 130
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        # No raw exception can expose local paths, HTTP bodies, or configuration contents.
        print('{"error":"fixture_command_failed"}', file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
