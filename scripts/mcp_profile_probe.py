"""Real MCP stdio probe for the STEP-2 six Profile tools.

Run through the actual plugin entry (`python -m bb_dsh_plugin`) with
`BB_CLIENT_BASE_URL` pointing at the Dart local control API. Prints one JSON
object so an orchestrating test can assert the tool-level results.

This is evidence tooling, not product code.
"""

import asyncio
import json
import os
import sys
from datetime import timedelta

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def main() -> int:
    base_url = os.environ["BB_CLIENT_BASE_URL"]
    png = os.environ["BB_PROBE_PNG_BASE64"]
    avatar_path = os.environ["BB_PROBE_AVATAR_PATH"]
    avatar_url = os.environ["BB_PROBE_AVATAR_URL"]
    other = os.environ["BB_PROBE_OTHER_ACCOUNT"]

    parameters = StdioServerParameters(
        command=sys.executable,
        args=["-m", "bb_dsh_plugin"],
        env={
            "BB_CLIENT_BASE_URL": base_url,
            "PYTHONDONTWRITEBYTECODE": "1",
        },
    )
    result: dict = {"steps": []}
    async with (
        stdio_client(parameters) as (read, write),
        ClientSession(
            read, write, read_timeout_seconds=timedelta(seconds=20)
        ) as session,
    ):
        await session.initialize()
        tools = (await session.list_tools()).tools
        result["tool_count"] = len(tools)
        result["tool_names"] = sorted(tool.name for tool in tools)
        result["update_tools_have_no_account"] = all(
            "account" not in tool.inputSchema.get("properties", {})
            for tool in tools
            if tool.name.startswith("update_")
        )

        async def call(name: str, arguments: dict) -> object:
            response = await session.call_tool(name, arguments)
            entry = {
                "tool": name,
                "is_error": bool(response.isError),
                "structured": response.structuredContent,
                "content_types": [item.type for item in response.content],
            }
            if response.content and response.content[0].type == "image":
                entry["image_mime"] = response.content[0].mimeType
                entry["image_length"] = len(response.content[0].data)
            result["steps"].append(entry)
            return response

        response = await call("view_nickname", {})
        self_name_before = response.structuredContent["username"]

        await call("update_nickname", {"value": "Muse Live"})
        response = await call("view_nickname", {})
        result["nickname_assigned"] = response.structuredContent["username"]

        await call("update_signature", {"value": "live signature"})
        response = await call("view_signature", {})
        result["signature_assigned"] = response.structuredContent["signature"]

        response = await call("view_avatar", {})
        result["avatar_self_version"] = response.structuredContent["avatar_version"]

        versions = []
        for arguments in (
            {"path": avatar_path},
            {"url": avatar_url},
            {"base64": "data:image/png;base64," + png},
            {"base64": png},
        ):
            response = await call("update_avatar", arguments)
            versions.append(response.structuredContent["avatar_version"])
        result["avatar_versions"] = versions

        response = await call("view_avatar", {"account": other})
        result["avatar_other_content"] = [
            item.type for item in response.content
        ]
        result["avatar_other_version"] = response.structuredContent["avatar_version"]

        for arguments in (
            {},
            {"path": "/x", "url": "https://example.invalid/x"},
            {"base64": png, "account": other},
            {"path": "relative.png"},
            {"url": "file:///tmp/x"},
        ):
            response = await call("update_avatar", arguments)
            result.setdefault("rejected", []).append(
                {
                    "arguments": sorted(arguments),
                    "is_error": bool(response.isError),
                    "status": (response.structuredContent or {}).get("status"),
                }
            )

        result["self_name_before"] = self_name_before

    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
