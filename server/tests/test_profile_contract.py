import json
from pathlib import Path

import pytest
from bb_server.app import create_app
from fastapi.testclient import TestClient
from test_profile import login

ROOT = Path(__file__).parents[1]
CASES = json.loads((ROOT / "contract/profile-cases.json").read_text(encoding="utf-8"))


@pytest.mark.parametrize(
    "case",
    [case for case in CASES if case["operation"] == "patch_profile"],
    ids=lambda case: case["id"],
)
def test_profile_shared_http_cases(tmp_path, case):
    with TestClient(create_app(tmp_path / "db")) as api:
        _, headers = login(api)
        response = api.patch("/me/profile", headers=headers, json=case["input"])
    if "status" in case:
        assert response.status_code == case["status"]
        assert case["field_code"] in [
            f["code"] for f in response.json()["error"]["fields"]
        ]
    else:
        assert response.status_code == 200
        for key, value in case["normalized"].items():
            assert response.json()[key] == value


def test_openapi_snapshot_and_security_do_not_drift():
    schema = create_app(Path("unused-schema-database")).openapi()
    assert schema == json.loads((ROOT / "openapi.json").read_text(encoding="utf-8"))
    for path, operations in schema["paths"].items():
        if path not in ("/auth/register", "/auth/login"):
            assert all(
                operation["security"] == [{"HTTPBearer": []}]
                for operation in operations.values()
            )
    assert (
        "account" not in schema["components"]["schemas"]["ProfilePatch"]["properties"]
    )
    assert (
        schema["components"]["schemas"]["ProfilePatch"]["additionalProperties"] is False
    )
