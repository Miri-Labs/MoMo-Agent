"""One bounded, synthetic slow tool; no shell commands or external services."""
import os
from pathlib import Path
import time
from mcp.server import MCPServer

server = MCPServer('MoMo nonblocking fixture')
workspace = Path(os.environ['MOMO_IM_FIXTURE_WORKSPACE'])


@server.tool()
def long_work() -> dict:
    """Wait for the local test gate, then record exactly one result."""
    (workspace / 'im-worker-started').touch()
    deadline = time.monotonic() + 90
    while not (workspace / 'im-worker-release').exists():
        if time.monotonic() > deadline:
            raise TimeoutError('Test gate was not released')
        time.sleep(.05)
    with (workspace / 'im-worker-finished').open('a') as stream:
        stream.write('done\n')
    return {'marker': 'MOMO_BACKGROUND_DONE'}


if __name__ == '__main__': server.run()
