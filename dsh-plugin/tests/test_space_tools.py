"""Shared-schema transport doubles; real process/host gates live in probes/space*.py."""

import json

import httpx
import pytest
from bb_auth_contract import space
from mcp.types import ListToolsRequest

from bb_dsh_plugin.guarded import AwaitingBinding, GuardedTransport
from bb_dsh_plugin.plugin import LocalClient, create_server
from bb_dsh_plugin.space_tools import SPACE_TOOLS, invoke_space

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
    assert len(tools) == 24
    for name, model in SPACE_TOOLS.items():
        assert tools[name].inputSchema == model.model_json_schema()
        assert "untrusted" in tools[name].description
        assert "expected_identity" not in tools[name].inputSchema["properties"]
    result = await invoke_space(AwaitingBinding(), "space_overview", {})
    assert (
        result.isError and result.structuredContent["error"]["code"] == "stale_binding"
    )


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
