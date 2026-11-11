"""Real stdio/HTTP transport; logical-client responses are explicit test doubles."""

import json
import sys
import threading
from datetime import timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from test_profile_contract import PNG


async def test_six_profile_tools_via_stdio_without_credentials(tmp_path):
    calls = []
    state = {"username": "Alice", "signature": None, "version": 0}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            calls.append((self.path, dict(self.headers), payload))
            name = self.path.removeprefix("/profile/")
            body = {
                "account": payload.get("account") or "12345678",
                "token": "never-forward",
            }
            if name in ("view_nickname", "update_nickname"):
                if name == "update_nickname":
                    state["username"] = payload["value"]
                body["username"] = state["username"]
            elif name in ("view_signature", "update_signature"):
                if name == "update_signature":
                    state["signature"] = payload.get("value")
                body["signature"] = state["signature"]
            elif name == "update_avatar":
                state["version"] += 1
                body.update(
                    avatar_url="/avatars/12345678.png",
                    avatar_version=str(state["version"]),
                )
            else:
                body.update(
                    mime_type="image/png",
                    data=PNG,
                    avatar_version=str(state["version"]),
                )
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Set-Cookie", "session=never-forward")
            self.end_headers()
            self.wfile.write(json.dumps(body).encode())

    http = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    worker = threading.Thread(target=http.serve_forever)
    worker.start()
    try:
        parameters = StdioServerParameters(
            command=sys.executable,
            args=["-m", "bb_dsh_plugin"],
            cwd=str(tmp_path),
            env={
                "BB_CLIENT_BASE_URL": f"http://127.0.0.1:{http.server_port}",
                "PYTHONDONTWRITEBYTECODE": "1",
            },
        )
        async with (
            stdio_client(parameters) as (read, write),
            ClientSession(
                read, write, read_timeout_seconds=timedelta(seconds=10)
            ) as session,
        ):
            await session.initialize()
            tools = (await session.list_tools()).tools
            assert len(tools) == 17
            for tool in tools:
                if tool.name.startswith("update_"):
                    assert "account" not in tool.inputSchema["properties"]
                    assert tool.inputSchema["additionalProperties"] is False
            for tool, arguments, key, value in [
                ("view_nickname", {}, "username", "Alice"),
                ("update_nickname", {"value": "New name"}, "username", "New name"),
                ("view_nickname", {}, "username", "New name"),
                ("view_signature", {}, "signature", None),
                ("update_signature", {"value": "Hello"}, "signature", "Hello"),
                ("view_signature", {}, "signature", "Hello"),
                ("update_signature", {}, "signature", None),
            ]:
                response = await session.call_tool(tool, arguments)
                assert not response.isError and response.structuredContent[key] == value
                assert "never-forward" not in response.model_dump_json()
            for version, arguments in enumerate(
                [
                    {"path": "/synthetic/avatar.png"},
                    {"url": "https://example.invalid/avatar.png"},
                    {"base64": PNG},
                    {"base64": "data:image/png;base64," + PNG},
                ],
                start=1,
            ):
                response = await session.call_tool("update_avatar", arguments)
                assert not response.isError and response.structuredContent[
                    "avatar_version"
                ] == str(version)
                viewed = await session.call_tool("view_avatar", {"account": "87654321"})
                assert (
                    viewed.content[0].type == "image" and viewed.content[0].data == PNG
                )
                assert viewed.structuredContent["avatar_version"] == str(version)
                assert "never-forward" not in viewed.model_dump_json()
            previous_calls = len(calls)
            for arguments in (
                {},
                {"path": "/x", "url": "http://example.invalid"},
                {"base64": PNG, "account": "87654321"},
            ):
                response = await session.call_tool("update_avatar", arguments)
                assert response.isError and response.structuredContent["status"] == 422
            assert len(calls) == previous_calls
        assert all(path.startswith("/profile/") for path, _, _ in calls)
        assert all(
            "Authorization" not in headers and "Cookie" not in headers
            for _, headers, _ in calls
        )
        assert not list(tmp_path.iterdir())
    finally:
        http.shutdown()
        http.server_close()
        worker.join(timeout=5)
        assert not worker.is_alive()
