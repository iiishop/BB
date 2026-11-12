import json
from pathlib import Path

import httpx
import pytest
from bb_auth_contract import chat_v2 as v2
from guarded_fixture import IDENTITY, guarded_client

from bb_dsh_plugin.guarded import invoke_guarded as invoke

ROOT = Path(__file__).parents[2]
CASES = json.loads(
    (ROOT / "server/contract/profile-cases.json").read_text(encoding="utf-8")
)
PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1kAAAAASUVORK5CYII="


@pytest.mark.parametrize(
    "case",
    [case for case in CASES if case["operation"] != "patch_profile"],
    ids=lambda case: case["id"],
)
async def test_profile_shared_mcp_cases(case):
    calls = []

    def handler(request):
        calls.append(json.loads(request.content))
        return httpx.Response(
            200,
            json={
                "account": "12345678",
                "username": "Alice",
                "signature": None,
                "avatar_url": "/avatars/12345678.png",
                "avatar_version": "test-v1",
                "mime_type": "image/png",
                "data": PNG,
            },
        )

    client = guarded_client(
        "http://127.0.0.1:9187", transport=httpx.MockTransport(handler)
    )
    response = await invoke(client, case["operation"], case["input"])
    if "status" in case:
        assert response.isError
        assert response.structuredContent["status"] == case["status"]
        assert case["field_code"] in [
            f["code"] for f in response.structuredContent["error"]["fields"]
        ]
        assert not calls
    else:
        assert not response.isError
        assert calls == [{**case["normalized"], "expected_identity": IDENTITY}]


def test_profile_routes_use_the_shared_guarded_contract():
    schema = json.loads((ROOT / "server/contract/chat-v2-openapi.json").read_text())
    for name in v2.profile.PROFILE_TOOLS:
        path, request, _response, status, owner = v2.BUSINESS[name]
        assert owner and path == "/v2/profile/" + name and status == 200
        assert "expected_identity" in request.model_fields
        assert schema["paths"][path]["post"]["security"] == [{"consumerOwner": []}]
