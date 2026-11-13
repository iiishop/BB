"""Shared wire checks, not proof the Dart service implements these semantics."""

import copy
import importlib.util
import json
from pathlib import Path

import pytest
from bb_auth_contract import chat_v2 as v2
from pydantic import TypeAdapter, ValidationError

ROOT = Path(__file__).parents[1] / "contract"
spec = importlib.util.spec_from_file_location(
    "export_chat_v2", ROOT / "export_chat_v2.py"
)
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)
CASES = json.loads((ROOT / "chat-v2-cases.json").read_text())


def test_generated_contract_is_current_and_all_refs_resolve():
    document = json.loads((ROOT / "chat-v2-openapi.json").read_text())
    assert document == exporter.schema()
    assert CASES == exporter.fixtures()

    def visit(value):
        if isinstance(value, dict):
            if "$ref" in value:
                node = document
                for part in value["$ref"].removeprefix("#/").split("/"):
                    node = node[part]
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(document)
    assert len(document["paths"]) == len(v2.OPERATIONS)


@pytest.mark.parametrize("name", v2.OPERATIONS)
def test_each_request_and_response_fixture(name):
    _, request, response, _, owner = v2.OPERATIONS[name]
    request.model_validate(CASES["inputs"][name])
    response.model_validate(CASES["outputs"][name])
    if name in v2.BUSINESS:
        assert owner
        assert "expected_identity" in request.model_json_schema()["required"]
        assert "consumer_session" not in request.model_fields
        value = copy.deepcopy(CASES["inputs"][name])
        value["expected_identity"]["token"] = "must-never-be-reflected"
        with pytest.raises(ValidationError) as failure:
            request.model_validate(value)
        assert "must-never-be-reflected" not in str(failure.value)


@pytest.mark.parametrize("case", CASES["invalid_inputs"], ids=lambda c: c["id"])
def test_invalid_fixture_rejected(case):
    with pytest.raises(ValidationError):
        v2.OPERATIONS[case["operation"]][1].model_validate(case["input"])


def test_identity_and_peer_are_separate_and_owner_is_not_in_payload():
    request = v2.Ack.model_validate(CASES["inputs"]["ack_messages"])
    assert request.account != request.expected_identity.account
    assert set(request.expected_identity.model_dump()) == {
        "account",
        "auth_generation",
        "consumer_id",
        "binding_revision",
    }
    TypeAdapter(v2.OwnerKey).validate_python(CASES["owner_header"]["value"])
    for value in ["consumer-A", "", "x" * 42, "x" * 44]:
        with pytest.raises(ValidationError):
            TypeAdapter(v2.OwnerKey).validate_python(value)


@pytest.mark.parametrize("name", v2.ERRORS)
def test_errors_have_no_binding_payload(name):
    body = CASES["errors"][name]["body"]
    v2.ErrorEnvelope.model_validate(body)
    assert set(body["error"]) == {"code", "message", "fields"}
    assert CASES["errors"][name]["status"] == v2.ERRORS[name][0]


def test_no_legacy_routes_or_migration_contract():
    assert all(path.startswith("/v2/") for path, *_ in v2.OPERATIONS.values())
    assert "migration_required" not in v2.ERRORS
    assert "migration" not in v2.Binding.model_fields
    assert "migration" not in v2.Consumption.model_fields
    assert all(item["status"] == 404 for item in CASES["retired_local_routes"])


def test_uncertain_is_not_terminal_failure_or_success():
    base = {"operation_id": "logical-1", "kind": "message", "status": "uncertain"}
    assert v2.Operation.model_validate(base).status == "uncertain"
    with pytest.raises(ValidationError):
        v2.Operation.model_validate({**base, "error_code": "timeout-is-not-terminal"})
    with pytest.raises(ValidationError):
        v2.Operation.model_validate({**base, "status": "succeeded"})
    with pytest.raises(ValidationError):
        v2.Operation.model_validate({**base, "status": "failed"})


def test_download_cannot_publish_path_before_success():
    pending = CASES["outputs"]["start_download"]["result"]
    with pytest.raises(ValidationError):
        v2.Download.model_validate({**pending, "actual_path": "/synthetic/not-yet"})
    with pytest.raises(ValidationError):
        v2.Download.model_validate({**pending, "status": "succeeded"})
