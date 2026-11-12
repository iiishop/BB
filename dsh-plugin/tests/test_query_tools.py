"""MCP transport double only; actual client routing is implemented by Muse."""

import copy
import json
from pathlib import Path

import httpx
import pytest
from bb_auth_contract import chat_v2 as v2
from mcp.types import ListToolsRequest

from bb_dsh_plugin.guarded import GuardedTransport, invoke_guarded
from bb_dsh_plugin.plugin import LocalClient, create_server

CASES = json.loads(
    (Path(__file__).parents[2] / "server/contract/chat-v2-cases.json").read_text()
)
IDENTITY = CASES["inputs"]["read_messages"]["expected_identity"]
OWNER = "x" * 43


@pytest.mark.asyncio
async def test_query_tools_routes_identity_no_ack_and_ordered_images():
    calls = []

    def handle(request):
        calls.append(request)
        assert request.headers[v2.OWNER_HEADER] == OWNER
        body = json.loads(request.content)
        assert body["expected_identity"] == IDENTITY
        name = next(
            name for name, op in v2.BUSINESS.items() if op[0] == request.url.path
        )
        return httpx.Response(200, json=CASES["outputs"][name])

    transport = httpx.MockTransport(handle)
    guarded = GuardedTransport(
        "http://127.0.0.1:9187", OWNER, IDENTITY, transport=transport
    )
    for name in ["list_conversations", "get_message", "get_context", "read_messages"]:
        body = {
            k: v for k, v in CASES["inputs"][name].items() if k != "expected_identity"
        }
        result = await invoke_guarded(guarded, name, body)
        assert not result.isError
        assert result.structuredContent == CASES["outputs"][name]["result"]
        assert OWNER not in str(result) and "auth_generation" not in str(result)
        if name != "list_conversations":
            visible = CASES["outputs"][name]["result"].get(
                "items", [CASES["outputs"]["get_message"]["result"]["item"]]
            )
            assert [x.type for x in result.content[1:]] == [
                b["type"] for x in visible for b in x["blocks"]
            ]
    assert len(calls) == 4
    assert not any("ack" in str(x.url) or "confirm" in str(x.url) for x in calls)
    # One invalid request never reaches the client or exposes the capability.
    bad = await invoke_guarded(
        guarded,
        "read_messages",
        {"account": "10000002", "after_position": 0, "before_position": 2},
    )
    assert bad.isError and bad.structuredContent["status"] == 422 and len(calls) == 4


@pytest.mark.asyncio
async def test_stale_reply_no_retry_no_secret_echo():
    calls = []

    def handle(request):
        calls.append(request)
        value = copy.deepcopy(CASES["outputs"]["get_message"])
        value["identity"]["binding_revision"] += 1
        return httpx.Response(200, json=value)

    client = GuardedTransport(
        "http://127.0.0.1:9187", OWNER, IDENTITY, transport=httpx.MockTransport(handle)
    )
    value = await invoke_guarded(client, "get_message", {"message_id": "m1"})
    assert (
        value.isError and value.structuredContent["error"]["code"] == "stale_identity"
    )
    assert len(calls) == 1

    def unavailable(_):
        return httpx.Response(
            409,
            json={"error": {"code": "stale_binding", "message": OWNER, "fields": []}},
        )

    client.local.transport = httpx.MockTransport(unavailable)
    value = await invoke_guarded(client, "get_message", {"message_id": "m1"})
    assert value.structuredContent["error"]["code"] == "stale_binding"
    assert OWNER not in str(value)


@pytest.mark.asyncio
async def test_guarded_tool_inventory_keeps_auth_profile_and_hides_internal_commit():
    client = LocalClient("http://127.0.0.1:9187")
    guarded = GuardedTransport(client.base_url, OWNER, IDENTITY)
    server = create_server(client, guarded)
    listing = await server.request_handlers[ListToolsRequest](
        ListToolsRequest(method="tools/list")
    )
    tools = listing.root.tools
    names = {t.name for t in tools}
    assert {
        "register_account",
        "login_account",
        "view_avatar",
        "update_avatar",
        "view_nickname",
        "update_nickname",
        "view_signature",
        "update_signature",
        "list_users",
        "list_conversations",
        "get_message",
        "get_context",
        "read_messages",
        "wait_messages",
        "send_message",
        "send_attachment",
        "start_download",
        "get_download",
        "get_operation",
    } <= names
    assert not {"ack_messages", "confirm_presentation", "get_consumption"} & names
    assert all(
        "expected_identity" not in t.inputSchema.get("properties", {}) for t in tools
    )
