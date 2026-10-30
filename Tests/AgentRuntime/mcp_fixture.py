"""A real MCP tool with a synthetic, sandboxed result for the runtime smoke test."""
import json
import os
from pathlib import Path
from mcp.server import MCPServer

server = MCPServer("MoMo embedded runtime verification")


@server.tool()
def record_probe() -> dict:
    """Record one MoMo runtime verification receipt; used only by the integration test."""
    destination = Path(os.environ["MOMO_PROBE_ARTIFACT"])
    previous = json.loads(destination.read_text()) if destination.exists() else {"executions": 0}
    receipt = {"executions": previous["executions"] + 1, "result": "MOMO_SOURCE_FORK_OK"}
    destination.write_text(json.dumps(receipt) + "\n")
    return receipt


if __name__ == "__main__":
    server.run()
