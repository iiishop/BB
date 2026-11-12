import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from bb_server.app import create_app

CASES = json.loads(
    (Path(__file__).parents[1] / "contract/cases.json").read_text(encoding="utf-8")
)


@pytest.mark.parametrize("case", CASES, ids=lambda case: case["id"])
def test_http_contract_cases(tmp_path, case):
    with TestClient(create_app(tmp_path / "contract.db")) as api:
        response = api.post(f"/auth/{case['operation']}", json=case["input"])
    if "fields" in case:
        assert response.status_code == 422
        assert response.json() == {
            "error": {
                "code": "validation_error",
                "message": "输入有误",
                "fields": case["fields"],
            }
        }
    elif case["operation"] == "register":
        assert response.status_code == 201
        assert response.json()["username"] == case["normalized"]["username"]
    else:
        assert response.status_code == 401
