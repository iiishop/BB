import importlib.util
import json
from pathlib import Path

import pytest
from bb_auth_contract import space
from pydantic import ValidationError

ROOT = Path(__file__).parents[1] / "contract"


def test_generated_space_schema_matches_authority():
    spec = importlib.util.spec_from_file_location(
        "export_space", ROOT / "export_space.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    assert json.loads((ROOT / "space-v1.json").read_text()) == module.schema()
    assert space.REQUESTS.keys() == space.RESPONSES.keys()
    assert space.REQUESTS.keys() == space.LOCAL_REQUESTS.keys()

    # Every schema reference resolves within the standalone schema.
    def walk(node, root):
        if isinstance(node, dict):
            if "$ref" in node:
                value = root
                for part in node["$ref"].removeprefix("#/").split("/"):
                    value = value[part]
            for value in node.values():
                walk(value, root)
        elif isinstance(node, list):
            for value in node:
                walk(value, root)

    for action in module.schema()["actions"].values():
        for key in ("request", "response", "local_request", "local_response"):
            walk(action[key], action[key])


@pytest.mark.parametrize("name", space.REQUESTS)
def test_no_author_spoof_or_unbound_local_requests(name):
    model = space.REQUESTS[name]
    with pytest.raises(ValidationError):
        model.model_validate({"author": "12345678", "unexpected": True})
    with pytest.raises(ValidationError):
        space.LOCAL_REQUESTS[name].model_validate({})


@pytest.mark.parametrize("value", [True, "1", 0, -1])
def test_strict_versions(value):
    with pytest.raises(ValidationError):
        space.DraftMutation(operation_id="op", draft_id="draft", expected_version=value)


def test_images_have_no_nine_image_cap_and_reject_duplicates():
    body = {
        "operation_id": "op",
        "draft_id": "draft",
        "expected_version": 1,
        "text": "",
        "image_ids": [f"image_{i}" for i in range(12)],
    }
    assert len(space.UpdateDraft(**body).image_ids) == 12
    with pytest.raises(ValidationError):
        space.UpdateDraft(**{**body, "image_ids": ["one", "one"]})
