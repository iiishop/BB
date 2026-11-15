"""All successful test traffic validates against the one shared wire authority."""
import uuid

from bb_auth_contract import space


def call(api, who, action, *, status=200, **body):
    model = space.REQUESTS[action]
    if issubclass(model, space.Mutation):
        body.setdefault("operation_id", uuid.uuid4().hex)
    model.model_validate(body)
    response = api.post("/space/" + action, headers=who[1], json=body)
    assert response.status_code == status, (action, response.status_code, response.text)
    value = response.json()
    if status == 200:
        space.RESPONSES[action].model_validate(value)
    return value


def register(api, name):
    response = api.post("/auth/register", json={"username": name, "password": "Abc123"})
    assert response.status_code == 201
    account = response.json()["account"]
    response = api.post("/auth/login", json={"account": account, "password": "Abc123"})
    assert response.status_code == 200
    return account, {"Authorization": "Bearer " + response.json()["token"]}


def publish(api, who, text="post", reference_id=None):
    draft = call(api, who, "create_draft", text=text, reference_id=reference_id)
    return call(api, who, "publish_draft", draft_id=draft["resource_id"], expected_version=1)["resource_id"]
