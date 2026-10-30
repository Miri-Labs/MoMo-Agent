"""Expose uv's own byte counters through a private terminal, without changing downloads."""
from __future__ import annotations

import codecs
import errno
import fcntl
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import termios
import time


def run_with_progress(command, *, cwd=None, env=None, timeout=1800):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 80, 240, 0, 0))
    environment = dict(os.environ if env is None else env)
    environment.update(TERM='xterm-256color', COLUMNS='240')
    environment.pop('NO_COLOR', None)
    environment.pop('RUST_LOG', None)
    environment.pop('UV_NO_PROGRESS', None)
    environment.pop('JPY_SESSION_NAME', None)
    process = None
    tail = ''
    decoder = codecs.getincrementaldecoder('utf-8')(errors='replace')
    deadline = time.monotonic() + timeout
    try:
        process = subprocess.Popen(command, cwd=cwd, env=environment, stdin=subprocess.DEVNULL,
                                   stdout=slave, stderr=slave, start_new_session=True)
        os.close(slave); slave = -1
        while True:
            if time.monotonic() >= deadline:
                raise subprocess.TimeoutExpired(command, timeout, stderr=tail)
            if not select.select([master], [], [], .2)[0]:
                continue
            try:
                chunk = os.read(master, 65536)
            except OSError as error:
                if error.errno != errno.EIO: raise
                chunk = b''
            text = decoder.decode(chunk, final=not chunk)
            tail = (tail + text)[-65536:]
            sys.stderr.write(text); sys.stderr.flush()
            if not chunk: break
        code = process.wait(timeout=max(.1, deadline - time.monotonic()))
        return subprocess.CompletedProcess(command, code, '', tail)
    except BaseException:
        if process is not None:
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            process.wait(timeout=5)
        raise
    finally:
        if slave >= 0: os.close(slave)
        os.close(master)
