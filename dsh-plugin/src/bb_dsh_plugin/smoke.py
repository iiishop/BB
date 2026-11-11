"""Run real MCP calls against an already running logical client; synthetic accounts only."""

import asyncio
import os
import secrets
import sys
from datetime import timedelta

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def check():
    parameters = StdioServerParameters(
        command=sys.executable,
        args=["-m", "bb_dsh_plugin"],
        env={"BB_CLIENT_BASE_URL": os.environ["BB_CLIENT_BASE_URL"]},
    )
    username = "smoke-" + secrets.token_hex(4)
    password = "Aa1" + secrets.token_hex(16)
    async with (
        stdio_client(parameters) as (read, write),
        ClientSession(
            read, write, read_timeout_seconds=timedelta(seconds=20)
        ) as session,
    ):
        await session.initialize()
        assert {t.name for t in (await session.list_tools()).tools} == {
            "register_account",
            "login_account",
            "view_avatar",
            "update_avatar",
            "view_nickname",
            "update_nickname",
            "view_signature",
            "update_signature",
        }
        accounts = []
        for _ in range(2):
            response = await session.call_tool(
                "register_account", {"username": username, "password": password}
            )
            assert not response.isError, "Registration failed (details withheld)"
            body = response.structuredContent
            assert set(body) == {"account", "username"}
            assert body["username"] == username
            assert (
                len(body["account"]) == 8
                and 10_000_000 <= int(body["account"]) <= 99_999_999
            )
            accounts.append(body["account"])
        assert accounts[0] != accounts[1]
        good = await session.call_tool(
            "login_account", {"account": accounts[0], "password": password}
        )
        assert not good.isError, "Login failed (details withheld)"
        assert good.structuredContent == {"account": accounts[0], "username": username}
        bad = await session.call_tool(
            "login_account", {"account": accounts[0], "password": "wrong"}
        )
        assert bad.isError and bad.structuredContent["status"] == 401
        assert bad.structuredContent["error"]["code"] == "invalid_credentials"
        invalid = await session.call_tool(
            "register_account", {"username": username, "password": "short"}
        )
        assert invalid.isError and invalid.structuredContent["status"] == 422
    print(
        "PASS: real MCP → configured logical client; duplicate-name registration, login, errors; no credentials printed"
    )


if __name__ == "__main__":
    asyncio.run(check())
