import json
import time
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from public_fixture import FakeCloud, FakePlatform, FakeVerifier

from bb_server.admin import create_admin_app
from bb_server.public_runtime import PublicRuntime
from bb_server.storage import connection

ORIGIN = "http://127.0.0.1:9001"
BASE = "/admin/api"


@pytest.fixture
def api(tmp_path):
    path = tmp_path / "admin.db"
    runtime = PublicRuntime(
        path,
        business_port=8000,
        challenge_directory=tmp_path / "challenge",
        adapter=FakePlatform(tmp_path / "private"),
        cloud_factory=lambda token: FakeCloud(),
        verifier=FakeVerifier(),
    )
    ui = tmp_path / "dist"
    (ui / "assets").mkdir(parents=True)
    (ui / "index.html").write_text("<html>synthetic production build fixture</html>")
    (ui / "assets/app.js").write_text('console.log("fixture")')
    (tmp_path / "outside.txt").write_text("PRIVATE_FILE")
    (ui / "assets/leak.js").symlink_to(tmp_path / "outside.txt")
    with TestClient(
        create_admin_app(path, port=9001, public_runtime=runtime, ui_directory=ui),
        base_url=ORIGIN,
        client=("127.0.0.1", 12000),
    ) as client:
        headers = {"origin": ORIGIN, "x-bb-admin": "1"}
        session = client.post(
            BASE + "/login",
            json={"username": "admin", "password": "admin"},
            headers=headers,
        ).json()
        headers["x-csrf-token"] = session["csrf_token"]
        assert (
            client.post(
                BASE + "/password",
                json={"old_password": "admin", "new_password": "Synthetic-Secret-123"},
                headers=headers,
            ).status_code
            == 204
        )
        session = client.post(
            BASE + "/login",
            json={"username": "admin", "password": "Synthetic-Secret-123"},
            headers=headers,
        ).json()
        headers["x-csrf-token"] = session["csrf_token"]
        yield client, headers, runtime


def eventually(runtime, task_id, stage):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        result = runtime.store.get(task_id)
        if result.stage == stage:
            return result
        time.sleep(0.01)
    raise AssertionError(runtime.store.get(task_id))


def test_actual_api_refresh_authorization_and_sse_replay(api):
    client, headers, runtime = api
    assert client.get(BASE + "/public-config").json() == {
        "version": 0,
        "domain": None,
        "active": None,
    }
    saved = client.put(
        BASE + "/public-config",
        json={"expected_version": 0, "domain": "bb.example.com"},
        headers=headers,
    )
    assert saved.status_code == 200
    task = client.post(
        BASE + "/probes",
        json={"expected_version": 1, "idempotency_key": str(uuid4())},
        headers=headers,
    )
    assert task.status_code == 202
    task_id = task.json()["task_id"]
    awaiting = eventually(runtime, task_id, "awaiting_authorization")
    current = client.get(BASE + "/tasks/current").json()["task"]
    assert current["task_id"] == task_id
    token = "synthetic-api-token-private"
    authorized = client.post(
        BASE + f"/tasks/{task_id}/authorization",
        json={"management_token": token},
        headers=headers,
    )
    assert authorized.status_code == 202
    assert authorized.json()["task_id"] == task_id
    terminal = eventually(runtime, task_id, "finished")
    stream = client.get(
        BASE + f"/tasks/{task_id}/events?after_seq=0",
        headers={"Last-Event-ID": str(awaiting.seq)},
    )
    assert stream.status_code == 200
    assert stream.headers["content-type"].startswith("text/event-stream")
    assert stream.headers["cache-control"] == "no-store"
    ids = [
        int(line[4:]) for line in stream.text.splitlines() if line.startswith("id: ")
    ]
    assert ids == list(range(awaiting.seq + 1, terminal.seq + 1))
    for line in stream.text.splitlines():
        if line.startswith("data: "):
            assert json.loads(line[6:])["task_id"] == task_id
    assert token not in stream.text
    assert token.encode() not in runtime.store.path.read_bytes()
    assert (
        client.post(
            BASE + f"/tasks/{task_id}/authorization",
            json={"management_token": token},
            headers=headers,
        ).status_code
        == 409
    )
    assert (
        client.post(
            BASE + f"/tasks/{uuid4()}/authorization",
            json={"management_token": token},
            headers=headers,
        ).status_code
        == 404
    )
    assert (
        client.get(
            BASE + f"/tasks/{task_id}/events", headers={"Last-Event-ID": "future"}
        ).status_code
        == 422
    )
    assert (
        client.get(BASE + f"/tasks/{task_id}/events?after_seq=999999").status_code
        == 409
    )


def test_static_mount_is_inside_management_boundary_and_never_masks_api(api):
    client, _, _ = api
    for route in ("/admin/", "/admin/home", "/admin/config"):
        result = client.get(route)
        assert result.status_code == 200 and "<html>" in result.text
        assert "default-src 'self'" in result.headers["content-security-policy"]
    assert client.get("/admin/assets/app.js").status_code == 200
    assert client.get("/admin/assets/missing.js").status_code == 404
    assert client.get("/admin/assets/leak.js").status_code == 404
    assert (
        "PRIVATE_FILE" not in client.get("/admin/assets/%2e%2e/%2e%2e/outside.txt").text
    )
    assert client.get("/admin/api/does-not-exist").status_code == 404
    assert "<html>" not in client.get("/admin/api/does-not-exist").text
    assert client.get("/admin/", headers={"Host": "attacker.test"}).status_code == 403
    assert (
        client.get("/admin/", headers={"X-Forwarded-For": "127.0.0.1"}).status_code
        == 403
    )


def test_revocation_rechecked_inside_configuration_write_transaction(api, monkeypatch):
    client, headers, runtime = api
    original = runtime.store.save

    def revoke_then_save(*args, **kwargs):
        with connection(runtime.store.path, write=True) as db:
            db.execute("DELETE FROM admin_sessions")
        return original(*args, **kwargs)

    monkeypatch.setattr(runtime.store, "save", revoke_then_save)
    result = client.put(
        BASE + "/public-config",
        json={"expected_version": 0, "domain": "bb.example.com"},
        headers=headers,
    )
    assert result.status_code == 401
    assert runtime.store.config().version == 0


def test_authorization_secret_validation_never_echoes_payload(api):
    client, headers, _ = api
    value = "PRIVATE" * 1000
    result = client.post(
        BASE + f"/tasks/{uuid4()}/authorization",
        json={"management_token": value},
        headers=headers,
    )
    assert result.status_code == 422
    assert value not in result.text
