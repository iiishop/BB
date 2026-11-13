import asyncio
import json
import os
from pathlib import Path

from mcp.server.stdio import stdio_server

from bb_dsh_plugin.plugin import LocalClient, create_server


async def run():
    client = LocalClient(
        os.environ["BB_CLIENT_BASE_URL"],
        float(os.getenv("BB_CLIENT_TIMEOUT_SECONDS", "10")),
    )
    from bb_dsh_plugin.guarded import AwaitingBinding

    guarded = AwaitingBinding()
    state_path = os.getenv("BB_CONSUMER_STATE_FILE")
    if state_path:
        from bb_dsh_plugin.guarded import GuardedTransport

        state = json.loads(Path(state_path).read_text())
        guarded = GuardedTransport(
            client.base_url,
            state["owner_key"],
            state["identity"],
            timeout=client.timeout,
        )
    server = create_server(client, guarded)
    async with stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream, write_stream, server.create_initialization_options()
        )


def main():
    asyncio.run(run())


if __name__ == "__main__":
    main()
