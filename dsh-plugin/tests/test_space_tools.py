"""Shared-schema transport doubles; real process/host gates live in probes/space*.py."""

import base64
import json
import subprocess
import sys

import httpx
import pytest
from bb_auth_contract import ContractError, space
from mcp.types import CallToolRequest, CallToolRequestParams, ListToolsRequest

from bb_dsh_plugin.guarded import AwaitingBinding, GuardedTransport
from bb_dsh_plugin.plugin import LocalClient, create_server
from bb_dsh_plugin.space_tools import SPACE_TOOLS, TOOL_SCHEMAS, invoke_space

# Authorized legacy surface, independently frozen to catch substitutions as well
# as count growth. Field protocols continue to come from bb_auth_contract.
LEGACY_SPACE_ACTIONS = {
    "get_image",
    "overview",
    "list_posts",
    "get_post",
    "create_draft",
    "get_draft",
    "list_drafts",
    "update_draft",
    "add_image",
    "publish_draft",
    "delete_draft",
    "delete_post",
    "set_like",
    "create_comment",
    "delete_comment",
    "list_comments",
    "get_comment_context",
    "list_likes",
    "mark_read",
    "list_notifications",
    "ack_notifications",
    "get_view_summary",
    "list_visitors",
    "get_operation",
}
PROFILE_SPACE_ACTIONS = {
    "get_follow",
    "set_follow",
    "list_profile_posts",
    "list_profile_months",
}
HTTP_ONLY_SPACE_ACTIONS = ("read_events",)

IDENTITY = {
    "account": "10000001",
    "auth_generation": "test-generation",
    "consumer_id": "test-consumer",
    "binding_revision": 1,
}


@pytest.mark.asyncio
async def test_discovery_exact_contract_and_no_internal_replay():
    server = create_server(LocalClient("http://127.0.0.1"))
    reply = await server.request_handlers[ListToolsRequest](
        ListToolsRequest(method="tools/list")
    )
    tools = {t.name: t for t in reply.root.tools if t.name.startswith("space_")}
    assert set(tools) == set(SPACE_TOOLS)
    assert len(tools) == 28
    assert set(tools) == {
        "space_" + action for action in (LEGACY_SPACE_ACTIONS | PROFILE_SPACE_ACTIONS)
    }
    assert tools["space_get_follow"].annotations.readOnlyHint is True
    assert tools["space_set_follow"].annotations.readOnlyHint is False
    assert tools["space_set_follow"].annotations.idempotentHint is True
    assert set(TOOL_SCHEMAS) == set(tools)
    for name, model in SPACE_TOOLS.items():
        assert model is space.REQUESTS[name.removeprefix("space_")]
        if name == "space_add_image":
            # The single tool whose input is not the wire shape: a model cannot
            # push megabytes of base64 through a tool call, so it hands over a
            # path and the adapter reads the bytes. Every contract field must
            # still be offered, plus the file source.
            properties = tools[name].inputSchema["properties"]
            assert set(model.model_json_schema()["properties"]) <= set(properties)
            assert {"path", "base64", "filename"} <= set(properties)
            continue
        if name == "space_list_profile_posts":
            schema = model.model_json_schema()
            schema["title"] = tools[name].inputSchema["title"]
            schema["properties"]["limit"].update(default=1, maximum=3)
            assert "Maximum 3 posts per call" in tools[name].description
            assert tools[name].inputSchema == schema
        else:
            assert tools[name].inputSchema == model.model_json_schema()
        assert "untrusted" in tools[name].description
        assert "expected_identity" not in tools[name].inputSchema["properties"]
    result = await invoke_space(AwaitingBinding(), "space_overview", {})
    assert (
        result.isError and result.structuredContent["error"]["code"] == "stale_binding"
    )


@pytest.mark.parametrize("limit", [0, 4, 100])
async def test_profile_timeline_rejects_out_of_bounds_limit_before_dispatch(limit):
    class NoDispatch:
        async def call(self, operation, payload):
            raise AssertionError("Invalid limit must not dispatch")

    result = await invoke_space(
        NoDispatch(),
        "space_list_profile_posts",
        {"target_account": "10000002", "timezone_offset_minutes": 0, "limit": limit},
    )
    assert result.isError and result.structuredContent["status"] == 422
    assert result.structuredContent["error"]["code"] == "validation_error"


@pytest.mark.asyncio
@pytest.mark.parametrize("action", HTTP_ONLY_SPACE_ACTIONS)
async def test_http_only_actions_cannot_be_called_through_mcp_or_guarded_transport(
    action,
):
    name = "space_" + action

    def unreachable(request):
        raise AssertionError("HTTP-only action must not reach the client")

    class NoDispatch:
        async def call(self, operation, payload):
            raise AssertionError("Unexposed tool must not dispatch")

    guarded = GuardedTransport(
        "http://127.0.0.1",
        "A" * 43,
        IDENTITY,
        transport=httpx.MockTransport(unreachable),
    )
    assert name not in SPACE_TOOLS and name not in TOOL_SCHEMAS
    direct = await invoke_space(NoDispatch(), name, {})
    assert direct.isError and direct.structuredContent["status"] == 404
    assert direct.structuredContent["error"]["code"] == "unknown_tool"
    # Use the actual MCP call handler, including its unknown-name dispatch.
    server = create_server(
        LocalClient("http://127.0.0.1", transport=httpx.MockTransport(unreachable)),
        NoDispatch(),
    )
    reply = await server.request_handlers[CallToolRequest](
        CallToolRequest(
            method="tools/call", params=CallToolRequestParams(name=name, arguments={})
        )
    )
    assert reply.root.isError and reply.root.structuredContent["status"] == 404
    assert reply.root.structuredContent["error"]["code"] == "unknown_tool"
    # GuardedTransport is a separate internal admission path. It must deny a
    # direct attempt too, instead of reaching /v2/space or raising KeyError.
    with pytest.raises(ContractError) as error:
        await guarded.call(name, {})
    assert error.value.status == 404
    assert error.value.body["error"]["code"] == "unknown_tool"


def test_future_http_request_does_not_become_an_mcp_tool():
    # Fresh interpreter re-runs the real registry construction with a synthetic
    # future HTTP extension; no installed dependency or host is modified.
    probe = subprocess.run(
        [
            sys.executable,
            "-c",
            """
import asyncio
from bb_auth_contract import space
space.REQUESTS['future_extension'] = space.Empty
from bb_dsh_plugin.plugin import LocalClient, create_server
from bb_dsh_plugin.space_tools import SPACE_TOOLS, TOOL_SCHEMAS, invoke_space
from mcp.types import ListToolsRequest

class NoDispatch:
    async def call(self, operation, payload):
        raise AssertionError('unexposed tool dispatched')

async def check():
    reply = await create_server(LocalClient('http://127.0.0.1')).request_handlers[ListToolsRequest](
        ListToolsRequest(method='tools/list'))
    names = {t.name for t in reply.root.tools if t.name.startswith('space_')}
    assert len(names) == 28
    assert names == set(SPACE_TOOLS) == set(TOOL_SCHEMAS)
    assert 'space_future_extension' not in names
    result = await invoke_space(NoDispatch(), 'space_future_extension', {})
    assert result.isError and result.structuredContent['error']['code'] == 'unknown_tool'

asyncio.run(check())
""",
        ],
        capture_output=True,
        check=False,
        text=True,
        timeout=15,
    )
    assert probe.returncode == 0, probe.stdout + probe.stderr


@pytest.mark.asyncio
async def test_image_bytes_and_stale_identity_fence():
    for stale in [False, True]:

        def handle(request, stale=stale):
            assert request.url.path == "/v2/space/get_image"
            body = json.loads(request.content)
            space.LOCAL_REQUESTS["get_image"].model_validate(body)
            identity = {**IDENTITY, "binding_revision": 2} if stale else IDENTITY
            result = {
                "identity": identity,
                "result": {
                    "image_id": "img",
                    "mime_type": "image/png",
                    "base64": "iVBORw0KGgo=",
                },
            }
            space.LOCAL_RESPONSES["get_image"].model_validate(result)
            return httpx.Response(200, json=result)

        client = GuardedTransport(
            "http://127.0.0.1",
            "A" * 43,
            IDENTITY,
            transport=httpx.MockTransport(handle),
        )
        result = await invoke_space(client, "space_get_image", {"image_id": "img"})
        assert result.isError == stale
        assert any(b.type == "image" for b in result.content) == (not stale)
        assert "base64" not in result.structuredContent


@pytest.mark.asyncio
async def test_add_image_reads_a_local_path_into_wire_base64(tmp_path):
    payload = b"\x89PNG\r\n\x1a\n" + b"pixels" * 512
    image = tmp_path / "shot.png"
    image.write_bytes(payload)
    seen = {}

    def handle(request):
        assert request.url.path == "/v2/space/add_image"
        body = json.loads(request.content)
        space.LOCAL_REQUESTS["add_image"].model_validate(body)
        seen.update(body)
        result = {
            "identity": IDENTITY,
            "result": {
                "operation_id": "operation-1",
                "action": "add_image",
                "resource_id": "img",
            },
        }
        space.LOCAL_RESPONSES["add_image"].model_validate(result)
        return httpx.Response(200, json=result)

    client = GuardedTransport(
        "http://127.0.0.1",
        "A" * 43,
        IDENTITY,
        transport=httpx.MockTransport(handle),
    )
    result = await invoke_space(
        client,
        "space_add_image",
        {
            "operation_id": "operation-1",
            "draft_id": "draft-1",
            "expected_version": 1,
            "path": str(image),
        },
    )
    assert not result.isError, result.model_dump_json()
    assert seen["base64"] == base64.b64encode(payload).decode()
    assert seen["filename"] == "shot.png"
    assert "path" not in seen


@pytest.mark.asyncio
async def test_add_image_rejects_unusable_path_and_ambiguous_source(tmp_path):
    def unreachable(request):
        raise AssertionError("no request may reach the client")

    client = GuardedTransport(
        "http://127.0.0.1",
        "A" * 43,
        IDENTITY,
        transport=httpx.MockTransport(unreachable),
    )
    base = {
        "operation_id": "operation-1",
        "draft_id": "draft-1",
        "expected_version": 1,
    }
    missing = await invoke_space(
        client, "space_add_image", {**base, "path": str(tmp_path / "nope.png")}
    )
    assert missing.isError
    assert missing.structuredContent["error"]["code"] == "validation_error"

    image = tmp_path / "shot.png"
    image.write_bytes(b"\x89PNG\r\n\x1a\n")
    both = await invoke_space(
        client, "space_add_image", {**base, "path": str(image), "base64": "AAAA"}
    )
    assert both.isError
    assert both.structuredContent["error"]["code"] == "validation_error"

    empty = tmp_path / "empty.png"
    empty.write_bytes(b"")
    blank = await invoke_space(client, "space_add_image", {**base, "path": str(empty)})
    assert blank.isError
    assert blank.structuredContent["error"]["code"] == "validation_error"


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("status", "code"),
    [
        (403, "forbidden"),
        (409, "version_conflict"),
        (404, "not_found"),
        (422, "attachments_not_ready"),
    ],
)
async def test_space_errors_preserved_without_private_echo(status, code):
    client = GuardedTransport(
        "http://127.0.0.1",
        "A" * 43,
        IDENTITY,
        transport=httpx.MockTransport(
            lambda r: httpx.Response(
                status,
                json={"error": {"code": code, "message": "secret", "fields": []}},
            )
        ),
    )
    result = await invoke_space(client, "space_list_visitors", {"post_id": "post"})
    assert result.isError and result.structuredContent["error"]["code"] == code
    assert "secret" not in result.model_dump_json()


def test_dart_validators_are_generated_from_the_same_authority():
    from pathlib import Path

    def compact(value):
        if isinstance(value, dict):
            return {
                k: compact(v)
                for k, v in value.items()
                if k not in ("title", "description")
            }
        if isinstance(value, list):
            return [compact(v) for v in value]
        return value

    repo = Path(__file__).resolve().parents[2]
    source = (repo / "client/lib/services/space_schema.g.dart").read_text()
    generated = json.loads(source.split("r'''", 1)[1].split("'''", 1)[0])
    expected = {
        name: {
            "request": compact(model.model_json_schema()),
            "response": compact(space.RESPONSES[name].model_json_schema()),
            "local_request": compact(space.LOCAL_REQUESTS[name].model_json_schema()),
        }
        for name, model in space.REQUESTS.items()
    }
    assert generated == expected
