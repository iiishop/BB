import json
from pathlib import Path

import httpx
import pytest
from bb_dsh_plugin.plugin import LocalClient, invoke

CASES = json.loads(
    (Path(__file__).parents[2] / "server/contract/cases.json").read_text(
        encoding="utf-8"
    )
)


@pytest.mark.parametrize("case", CASES, ids=lambda case: case["id"])
async def test_mcp_contract_cases(case):
    calls = []

    def handler(request):
        calls.append(json.loads(request.content))
        return httpx.Response(
            201 if case["operation"] == "register" else 200,
            json={"account": "12345678", "username": "Alice"},
        )

    client = LocalClient(
        "http://127.0.0.1:9187", transport=httpx.MockTransport(handler)
    )
    result = await invoke(client, f"{case['operation']}_account", case["input"])
    if "fields" in case:
        assert result.isError
        assert result.structuredContent == {
            "status": 422,
            "error": {
                "code": "validation_error",
                "message": "输入有误",
                "fields": case["fields"],
            },
        }
        assert calls == []
    else:
        assert not result.isError
        assert calls == [case["normalized"]]
