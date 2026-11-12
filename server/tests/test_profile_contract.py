import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from test_profile import login

from bb_server.app import create_app

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


def canonical_status_descriptions(schema):
    # HTTPStatus renamed these reason phrases in Python 3.13. Preserve every
    # other field and unexpected description so real contract drift still fails.
    for operations in schema["paths"].values():
        for operation in operations.values():
            for status, old, new in (
                ("422", "Unprocessable Entity", "Unprocessable Content"),
                ("413", "Request Entity Too Large", "Content Too Large"),
            ):
                response = operation.get("responses", {}).get(status, {})
                if response.get("description") == old:
                    response["description"] = new
    return schema


def test_status_normalization_preserves_contract_changes():
    responses = {
        "422": {
            "description": "Custom validation contract",
            "content": {"changed": True},
        },
        "413": {"description": "Custom upload limit"},
        "400": {"description": "Unprocessable Entity"},
    }
    schema = {"paths": {"/test": {"post": {"responses": responses}}}}
    expected = json.loads(json.dumps(schema))
    assert canonical_status_descriptions(schema) == expected


def test_openapi_snapshot_and_security_do_not_drift():
    schema = create_app(Path("unused-schema-database")).openapi()
    expected = json.loads((ROOT / "openapi.json").read_text(encoding="utf-8"))
    assert canonical_status_descriptions(schema) == canonical_status_descriptions(
        expected
    )
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
