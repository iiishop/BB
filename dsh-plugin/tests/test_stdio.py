"""Real MCP stdio + HTTP transport; the HTTP client endpoint here is a test double."""

import json
import sys
import threading
from datetime import timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from bb_auth_contract.chat import LOCAL
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def test_stdio_eight_tools_and_stateless_http(tmp_path):
    calls = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            calls.append((self.path, dict(self.headers), payload))
            self.send_response(201 if self.path == "/auth/register" else 200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Set-Cookie", "session=never-forward")
            self.send_header("Authorization", "Bearer never-forward")
            self.end_headers()
            self.wfile.write(
                json.dumps(
                    {
                        "account": "12345678",
                        "username": "Alice",
                        "token": "never-forward",
                    }
                ).encode()
            )

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
            tools = await session.list_tools()
            assert {tool.name for tool in tools.tools} == set(LOCAL) | {
                "register_account",
                "login_account",
                "view_avatar",
                "update_avatar",
                "view_nickname",
                "update_nickname",
                "view_signature",
                "update_signature",
            }
            for name, payload in [
                ("register_account", {"username": "Alice", "password": "Abc123"}),
                ("login_account", {"account": "12345678", "password": "Abc123"}),
                ("login_account", {"account": "12345678", "password": "Abc123"}),
            ]:
                response = await session.call_tool(name, payload)
                assert not response.isError
                assert response.structuredContent == {
                    "account": "12345678",
                    "username": "Alice",
                }
                assert "never-forward" not in response.model_dump_json()
            invalid = await session.call_tool("register_account", {"username": "Alice"})
            assert invalid.isError
            assert invalid.structuredContent["status"] == 422
        assert [path for path, _, _ in calls] == [
            "/auth/register",
            "/auth/login",
            "/auth/login",
        ]
        assert all(
            "Cookie" not in headers and "Authorization" not in headers
            for _, headers, _ in calls
        )
        assert list(tmp_path.iterdir()) == []
    finally:
        http.shutdown()
        http.server_close()
        worker.join(timeout=5)
        assert not worker.is_alive()
