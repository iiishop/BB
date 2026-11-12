"""Actual stdio MCP/independent Dart/FastAPI; no model or response double."""

import asyncio
import base64
import hashlib
import json
import secrets
import sys
from contextlib import asynccontextmanager
from pathlib import Path

import httpx
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

config = json.loads(Path(sys.argv[1]).read_text())
repo = Path(__file__).resolve().parents[3]
cases = json.loads((repo / "server/contract/chat-v2-cases.json").read_text())
owner = secrets.token_urlsafe(32)
identity = None


def record(name, **facts):
    print(json.dumps({"name": name, "status": "PASS", **facts}), flush=True)


async def post(path, body, key=None):
    async with httpx.AsyncClient(trust_env=False, timeout=15) as http:
        return await http.post(
            config["origin"] + path,
            json=body,
            headers={"X-BB-Consumer-Key": key} if key else {},
        )


async def bind():
    global identity
    auth = (await post("/v2/status", {})).json()["auth"]
    made = await post(
        "/v2/consumers/create",
        {"expected_auth": auth, "session_id": "profile-integration"},
        owner,
    )
    assert made.status_code == 200
    current = made.json()["identity"]
    response = await post(
        "/v2/consumers/bind",
        {
            "expected_auth": auth,
            "consumer_id": current["consumer_id"],
            "expected_binding_revision": current["binding_revision"],
            "session_id": "profile-integration",
        },
        owner,
    )
    assert response.status_code == 200
    identity = response.json()["identity"]
    path = Path(config["state"])
    path.write_text(json.dumps({"owner_key": owner, "identity": identity}))
    path.chmod(0o600)


@asynccontextmanager
async def mcp(bound=True):
    env = {"BB_CLIENT_BASE_URL": config["origin"]}
    if bound:
        env["BB_CONSUMER_STATE_FILE"] = config["state"]
    async with (
        stdio_client(
            StdioServerParameters(
                command=sys.executable, args=["-m", "bb_dsh_plugin"], env=env
            )
        ) as (read, write),
        ClientSession(read, write) as session,
    ):
        await session.initialize()
        yield session


async def call(session, name, args):
    reply = await session.call_tool(name, args)
    assert not reply.isError, (name, reply.structuredContent)
    return reply


async def race(session, tool, args, barrier_path, action, expected):
    async with httpx.AsyncClient(trust_env=False) as http:
        await http.post(config["proxy"] + "/probe/arm", json={"path": barrier_path})
        pending = asyncio.create_task(session.call_tool(tool, args))
        try:
            for _ in range(100):
                if (await http.get(config["proxy"] + "/probe/reached")).json()[
                    "reached"
                ]:
                    break
                await asyncio.sleep(0.025)
            else:
                raise AssertionError("real backend response barrier not reached")
            await action()
        finally:
            await http.post(config["proxy"] + "/probe/release", json={})
        response = await pending
        assert response.isError and response.structuredContent["status"] == 409, (
            response.structuredContent
        )
        assert response.structuredContent["error"]["code"] == expected, (
            response.structuredContent
        )
        assert all(x.type != "image" for x in response.content)
        assert (
            "result" not in response.structuredContent
            and "data" not in response.structuredContent
        )
        record(
            tool + "-" + expected,
            response_status=409,
            backend_response_delayed=True,
            result_disclosed=False,
        )


async def main():
    async with mcp(False) as session:
        a = (
            await call(
                session,
                "register_account",
                {"username": "ProfileProbe", "password": "Abc123"},
            )
        ).structuredContent["account"]
        await call(session, "login_account", {"account": a, "password": "Abc123"})
        denied = await session.call_tool("view_nickname", {})
        assert (
            denied.isError
            and denied.structuredContent["error"]["code"] == "stale_binding"
        )
    record(
        "mcp-register-login", auth_owned_by_client=True, unbound_business_rejected=True
    )
    await bind()
    async with mcp() as session:
        assert (
            await call(session, "update_nickname", {"value": "Guarded Profile"})
        ).structuredContent["username"] == "Guarded Profile"
        assert (await call(session, "view_nickname", {})).structuredContent[
            "username"
        ] == "Guarded Profile"
        await call(session, "update_signature", {"value": "actual-profile"})
        assert (await call(session, "view_signature", {})).structuredContent[
            "signature"
        ] == "actual-profile"
        await call(session, "update_signature", {})
        assert (await call(session, "view_signature", {})).structuredContent[
            "signature"
        ] is None
        avatar = await call(
            session,
            "update_avatar",
            {"base64": cases["inputs"]["update_avatar"]["base64"]},
        )
        viewed = await call(session, "view_avatar", {})
        image = next(x for x in viewed.content if x.type == "image")
        pixels = base64.b64decode(image.data, validate=True)
        assert pixels.startswith(b"\x89PNG\r\n\x1a\n")
        assert (
            viewed.structuredContent["avatar_version"]
            == avatar.structuredContent["avatar_version"]
        )
        record(
            "mcp-six-profile-tools",
            tools=6,
            avatar_bytes=len(pixels),
            avatar_sha256=hashlib.sha256(pixels).hexdigest(),
        )
        for entry in cases["retired_local_routes"]:
            assert (await post(entry["path"], {})).status_code == 404, entry
        for tool in [
            "view_avatar",
            "update_avatar",
            "view_nickname",
            "update_nickname",
            "view_signature",
            "update_signature",
        ]:
            body = {**cases["inputs"][tool], "expected_identity": identity}
            for key, expected in [
                ("B" * 43, "stale_binding"),
                (owner, "stale_identity"),
            ]:
                if expected == "stale_identity":
                    body = {
                        **body,
                        "expected_identity": {
                            **identity,
                            "auth_generation": "obsolete",
                        },
                    }
                rejected = await post("/v2/profile/" + tool, body, key)
                assert (
                    rejected.status_code == 409
                    and rejected.json()["error"]["code"] == expected
                )
                assert set(rejected.json()) == {"error"}
        record("profile-wire-denials", retired_routes=20, wrong_owner_and_generation=12)
        await race(
            session, "view_avatar", {}, "/avatars/" + a + ".png", bind, "stale_binding"
        )
    async with mcp() as session:

        async def switch():
            await call(
                session,
                "login_account",
                {"account": config["peer"], "password": "Abc123"},
            )

        await race(
            session,
            "update_nickname",
            {"value": "Original Account Only"},
            "/me/profile",
            switch,
            "stale_identity",
        )
    await bind()
    async with mcp() as session:
        assert (await call(session, "view_nickname", {})).structuredContent[
            "username"
        ] != "Original Account Only"
        await call(session, "login_account", {"account": a, "password": "Abc123"})
    await bind()
    async with mcp() as session:
        assert (await call(session, "view_nickname", {})).structuredContent[
            "username"
        ] == "Original Account Only"
    record(
        "profile-switch-fact-ownership",
        original_success_retained=True,
        new_account_unchanged=True,
    )


asyncio.run(main())
