import json
from pathlib import Path

import httpx
import pytest
from bb_auth_contract.profile import PROFILE_RESPONSES, PROFILE_TOOLS
from bb_dsh_plugin.plugin import LocalClient, invoke

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

    client = LocalClient(
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
        assert calls == [case["normalized"]]


def test_local_schema_snapshot():
    expected = {
        name: {
            "method": "POST",
            "path": f"/profile/{name}",
            "input": model.model_json_schema(),
            "output": PROFILE_RESPONSES[name].model_json_schema(),
        }
        for name, model in PROFILE_TOOLS.items()
    }
    assert expected == json.loads(
        (ROOT / "server/contract/profile-local-schema.json").read_text(encoding="utf-8")
    )
