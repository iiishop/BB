"""R8 baseline evidence, not an implementation/acceptance test of the proposal.

Run from repo root: uv run --project server --locked python
docs/contracts/dea475-operation-association-evidence/baseline_probe.py
Starts the real Python and standalone Dart entries with disposable data.
Never prints credentials. Stops only its own exact child processes.
"""

import copy
import json
import os
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import httpx
from bb_auth_contract import chat_v2 as v2
from pydantic import ValidationError

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
results = {}


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def stop(process):
    if process.poll() is not None:
        return
    cli = os.environ.get("MULTICA_CLI_PATH")
    if cli:
        daemon = subprocess.run(
            [cli, "daemon", "status", "--output", "json"],
            capture_output=True, text=True, check=True,
        )
        state = json.loads(daemon.stdout)
        # Reject any matching numeric PID anywhere in the status structure.
        def pids(value):
            if isinstance(value, dict):
                for key, item in value.items():
                    if "pid" in key.lower():
                        yield str(item)
                    yield from pids(item)
            elif isinstance(value, list):
                for item in value:
                    yield from pids(item)
        assert str(process.pid) not in set(pids(state))
    process.terminate()
    process.wait(timeout=15)


def wait_ready(client, process, local=False):
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        assert process.poll() is None, "owned child exited before readiness"
        try:
            r = client.post("/v2/status", json={}) if local else client.get("/openapi.json")
            if r.status_code == 200:
                return
        except httpx.TransportError:
            pass
        time.sleep(0.05)
    raise AssertionError("owned child not ready")


def checked(response, status=200):
    assert response.status_code == status, (response.request.url.path, response.status_code)
    return response.json()


started = time.monotonic()
with tempfile.TemporaryDirectory(prefix="dea475-baseline-") as temporary:
    root = Path(temporary)
    server_port, local_port = free_port(), free_port()
    env = dict(os.environ, BB_DATABASE_PATH=str(root / "db.sqlite"),
               BB_AVATAR_DIRECTORY=str(root / "avatars"), BB_MEDIA_DIRECTORY=str(root / "media"),
               BB_HOST="127.0.0.1", BB_PORT=str(server_port))
    children = []
    with (root / "process.log").open("w") as log:
        try:
            server = subprocess.Popen([sys.executable, "-m", "bb_server"], env=env,
                                      stdout=log, stderr=log)
            children.append(server)
            with httpx.Client(base_url=f"http://127.0.0.1:{server_port}", trust_env=False) as api:
                wait_ready(api, server)
                people = []
                for name in ("R8Alice", "R8Bob", "R8Carol"):
                    account = checked(api.post("/auth/register", json={"username": name, "password": "Abc123"}), 201)["account"]
                    token = checked(api.post("/auth/login", json={"account": account, "password": "Abc123"}))["token"]
                    people.append((account, {"Authorization": "Bearer " + token}))
                a, b, c = people
                body = {"target_account": b[0], "client_nonce": "r8-one", "content": [{"type": "text", "text": "same"}]}
                first = checked(api.post("/messages", headers=a[1], json=body))
                second = checked(api.post("/messages", headers=a[1], json={**body, "client_nonce": "r8-two"}))
                assert first["id"] != second["id"]
                assert checked(api.post("/messages", headers=a[1], json=body))["id"] == first["id"]
                assert api.post("/messages", headers=a[1], json={**body, "target_account": c[0]}).status_code == 409
                assert "operation_id" not in first
                for who in (a, b):
                    assert "operation_id" not in checked(api.get(f"/messages/{first['id']}", headers=who[1]))
                    context = checked(api.get(f"/messages/{first['id']}/context", headers=who[1]))
                    assert len(context["items"]) == 2
                    assert all("operation_id" not in m for m in context["items"])
                    peer = b if who is a else a
                    history = checked(api.get(f"/conversations/{peer[0]}/messages", headers=who[1]))
                    assert len(history["items"]) == 2
                    assert all("operation_id" not in m for m in history["items"])
                    conversations = checked(api.get("/conversations", headers=who[1]))
                    assert "operation_id" not in conversations["items"][0]["last_message"]
                    events = checked(api.get("/events", headers=who[1]))
                    assert len(events["items"]) == 2
                    assert all("operation_id" not in e for e in events["items"])
                for endpoint in (f"/messages/{first['id']}", f"/messages/{first['id']}/context", "/operations/r8-one"):
                    assert api.get(endpoint, headers=c[1]).status_code == 404
                    assert api.get(endpoint).status_code == 401
                assert api.get("/operations/r8-one", headers=b[1]).status_code == 404
                op = checked(api.get("/operations/r8-one", headers=a[1]))
                assert op["status"] == "succeeded" and op["message"]["id"] == first["id"]
                assert api.get("/operations/absent", headers=a[1]).status_code == 404
                reverse = checked(api.post("/messages", headers=b[1], json={**body, "target_account": a[0]}))
                assert checked(api.get("/operations/r8-one", headers=b[1]))["message"]["id"] == reverse["id"]
                assert reverse["id"] != first["id"]
                media = checked(api.post("/media", headers=a[1], data={"target_account": b[0]}, files={"file": ("probe.txt", b"probe", "text/plain")}), 200)
                attached = checked(api.post("/messages/attachments", headers=a[1], json={"target_account": b[0], "client_nonce": "r8-attachment", "media_id": media["media_id"]}))
                assert attached["kind"] == "attachment" and "operation_id" not in attached
                with sqlite3.connect(root / "db.sqlite") as db:
                    assert db.execute("SELECT count(*) FROM operations").fetchone()[0] == 4
                    assert db.execute("SELECT count(*) FROM messages").fetchone()[0] == 4
                    assert db.execute("SELECT count(*) FROM events").fetchone()[0] == 8
                    assert db.execute("SELECT count(*) FROM operations WHERE account=? AND operation_id=? AND message_id=?", (a[0], "r8-one", first["id"])).fetchone()[0] == 1
                results["real_server_http"] = {"same_content_distinct_operation": True, "replay_same_message": True, "changed_target_409": True, "account_scoped_same_nonce": True, "third_party_404_unauthenticated_401": True, "message_surfaces_lack_association": ["send", "attachment", "history", "single", "context", "conversation_last_message"], "events_metadata_only": True, "operations": "succeeded or 404; not remote pending/uncertain"}
                stop(server)
                server = subprocess.Popen([sys.executable, "-m", "bb_server"], env=env, stdout=log, stderr=log)
                children.append(server)
                wait_ready(api, server)
                assert checked(api.post("/messages", headers=a[1], json=body))["id"] == first["id"]
                results["real_server_restart_replay"] = True

                dart = shutil.which("dart")
                assert dart is not None
                local = subprocess.Popen([dart, "--packages=.dart_tool/package_config.json", "bin/bb_client_api.dart", "--port", str(local_port), "--server-url", str(api.base_url), "--session-file", str(root / "client" / "session.json")], cwd=ROOT / "client", stdout=log, stderr=log)
                children.append(local)
                with httpx.Client(base_url=f"http://127.0.0.1:{local_port}", trust_env=False) as control:
                    wait_ready(control, local, local=True)
                    checked(control.post("/auth/login", json={"account": a[0], "password": "Abc123"}))
                    auth = checked(control.post("/v2/status", json={}))["auth"]
                    owner = {v2.OWNER_HEADER: "A" * 43}
                    other_owner = {v2.OWNER_HEADER: "B" * 43}
                    def enroll(session_id, headers):
                        return checked(control.post("/v2/consumers/create", headers=headers, json={"expected_auth": auth, "session_id": session_id}))["identity"]
                    identity, other = enroll("r8-one", owner), enroll("r8-two", other_owner)
                    assert identity["consumer_id"] != other["consumer_id"]
                    def call(name, payload, expected=identity):
                        path, _, response_model, status, _ = v2.BUSINESS[name]
                        response = control.post(path, headers=owner, json={"expected_identity": expected, **payload})
                        parsed = checked(response, status)
                        response_model.model_validate(parsed)
                        return parsed["result"]
                    sent = call("send_message", {"target_account": b[0], "operation_id": "r8-local", "content": [{"type": "text", "text": "local"}]})
                    assert "operation_id" not in sent
                    assert call("get_operation", {"operation_id": "r8-local"})["message"]["id"] == sent["id"]
                    missing = control.post("/v2/operations/get", headers=other_owner, json={"expected_identity": other, "operation_id": "r8-local"})
                    assert missing.status_code == 404, (missing.status_code, missing.json().get("error", {}).get("code"))
                    for name, payload in [("get_message", {"message_id": sent["id"]}), ("get_context", {"message_id": sent["id"]}), ("list_conversations", {}), ("read_messages", {"account": b[0]})]:
                        call(name, payload)
                    results["standalone_dart_real_http"] = {"entry": "client/bin/bb_client_api.dart", "response_models_validated": ["send_message", "get_operation", "get_message", "get_context", "list_conversations", "read_messages"], "same_account_other_consumer_operation_404": True}
        finally:
            for child in reversed(children):
                stop(child)

fixtures = json.loads((ROOT / "server/contract/chat-v2-cases.json").read_text())
rejected = []
for name in ("send_message", "send_attachment", "get_operation", "read_messages", "wait_messages", "get_message", "get_context", "list_conversations"):
    payload = copy.deepcopy(fixtures["outputs"][name])
    def extend(value):
        if isinstance(value, dict):
            if "sender_account" in value and "target_account" in value and "kind" in value:
                value["operation_id"] = "r8-added"
            for item in value.values():
                extend(item)
        elif isinstance(value, list):
            for item in value:
                extend(item)
    extend(payload)
    try:
        v2.BUSINESS[name][2].model_validate(payload)
    except ValidationError as error:
        assert any(e["type"] == "extra_forbidden" for e in error.errors())
        rejected.append(name)
    else:
        raise AssertionError(f"expected strict old schema rejection: {name}")
results["synthetic_added_field_rejected_by_baseline_contract"] = rejected
results["baseline_sha"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
results["python"] = sys.version.split()[0]
results["duration_seconds"] = round(time.monotonic() - started, 2)
results["proposal_implemented"] = False
(OUT / "baseline-results.json").write_text(json.dumps(results, indent=2) + "\n")
print(json.dumps(results, indent=2))
