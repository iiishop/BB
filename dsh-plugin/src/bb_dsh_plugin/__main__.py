import asyncio
import os

from mcp.server.stdio import stdio_server

from bb_dsh_plugin.plugin import LocalClient, create_server


async def run():
    client = LocalClient(
        os.environ["BB_CLIENT_BASE_URL"],
        float(os.getenv("BB_CLIENT_TIMEOUT_SECONDS", "10")),
    )
    server = create_server(client)
    async with stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream, write_stream, server.create_initialization_options()
        )


def main():
    asyncio.run(run())


if __name__ == "__main__":
    main()
