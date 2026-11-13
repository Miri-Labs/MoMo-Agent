"""Run the real loopback gateway and source sync for the synthetic recording UI test."""
import argparse
import json
from pathlib import Path
import sys

from aiohttp import web

REPOSITORY = Path(__file__).resolve().parents[2]
for directory in ("Runtime", "Context", "Access"):
    sys.path.insert(0, str(REPOSITORY / "Apps/MacApp" / directory))

import momo_agent
from context_server import ContextService
from superagent_gateway import SuperAgentGateway


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, help="Empty directory for the fixture and its pairing file")
    args = parser.parse_args()
    directory = args.directory.resolve()
    data = directory / "runtime"
    connection = momo_agent.initialize(data, 19317)
    gateway = SuperAgentGateway(data, connection, python_executable=Path(sys.executable),
                                base_env=momo_agent.child_environment(data), manage_dsh=False)
    context = ContextService(data, connection)
    app = gateway.create_app()

    async def recording_selection(_):
        row = gateway.store.db.execute(
            "SELECT attachments_json FROM inputs WHERE content='' AND state='admitted' ORDER BY rowid DESC LIMIT 1",
        ).fetchone()
        attachments = json.loads(row["attachments_json"] or "[]") if row else []
        return web.json_response([
            span for item in attachments if "recording" in item
            for session in item["recording"]["sessions"] for span in session["span_ids"]
        ])

    async def start(_):
        context.start()

    app.router.add_get("/test/recording-selection", recording_selection)
    app.on_startup.append(start)
    pairing = directory / "phone-pairing.json"
    if not pairing.exists():
        momo_agent.write_private(pairing, json.dumps({
            "runID": "5F12C378-A804-4E20-A46D-213FE37495AC",
            "connection": json.dumps(connection),
            "credential": gateway.api_key,
        }))
    try:
        web.run_app(app, host="127.0.0.1", port=connection["port"], access_log=None)
    finally:
        context.close()


if __name__ == "__main__":
    main()
