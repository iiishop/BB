"""Real TCP + standalone Dart compatibility/restart probe, synthetic data only.

From repo root: uv run --project server --locked python server/probes/association_http.py
Requires the existing Dart SDK and client package configuration; no DSH host.
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import httpx
from bb_auth_contract import chat_v2 as v2
from bb_auth_contract.chat import Message
from bb_auth_contract.chat_association import HEADER, AssociatedMessage

ROOT = Path(__file__).resolve().parents[2]


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def stop(child):
    if child.poll() is not None:
        return
    cli = os.environ.get("MULTICA_CLI_PATH")
    if cli:
        status = subprocess.run(
            [cli, "daemon", "status", "--output", "json"],
            capture_output=True,
            text=True,
            check=True,
        )

        def pids(value):
            if isinstance(value, dict):
                for key, item in value.items():
                    if "pid" in key.lower():
                        yield str(item)
                    yield from pids(item)
            elif isinstance(value, list):
                for item in value:
                    yield from pids(item)

        assert str(child.pid) not in set(pids(json.loads(status.stdout)))
    child.terminate()
    child.wait(timeout=15)


def ready(api, child, local=False):
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        assert child.poll() is None, "child exited before readiness"
        try:
            response = (
                api.post("/v2/status", json={}) if local else api.get("/openapi.json")
            )
            if response.status_code == 200:
                return
        except httpx.TransportError:
            pass
        time.sleep(0.05)
    raise AssertionError("child readiness deadline")


def ok(response, status=200):
    assert response.status_code == status, (
        response.request.url.path,
        response.status_code,
    )
    return response.json()


def main():
    started = time.monotonic()
    dart = shutil.which("dart")
    assert dart and (ROOT / "client/.dart_tool/package_config.json").exists()
    with tempfile.TemporaryDirectory(prefix="bb-association-") as directory:
        root = Path(directory)
        server_port, local_port = port(), port()
        env = dict(
            os.environ,
            BB_DATABASE_PATH=str(root / "db"),
            BB_AVATAR_DIRECTORY=str(root / "avatars"),
            BB_MEDIA_DIRECTORY=str(root / "media"),
            BB_HOST="127.0.0.1",
            BB_PORT=str(server_port),
        )
        children = []
        with (root / "children.log").open("w") as log:

            def start_server():
                child = subprocess.Popen(
                    [sys.executable, "-m", "bb_server"], env=env, stdout=log, stderr=log
                )
                children.append(child)
                return child

            def start_local():
                child = subprocess.Popen(
                    [
                        dart,
                        "--packages=.dart_tool/package_config.json",
                        "bin/bb_client_api.dart",
                        "--port",
                        str(local_port),
                        "--server-url",
                        f"http://127.0.0.1:{server_port}",
                        "--session-file",
                        str(root / "client/session.json"),
                    ],
                    cwd=ROOT / "client",
                    stdout=log,
                    stderr=log,
                )
                children.append(child)
                return child

            try:
                server = start_server()
                with httpx.Client(
                    base_url=f"http://127.0.0.1:{server_port}", trust_env=False
                ) as api:
                    ready(api, server)
                    people = []
                    for name in ("ProbeAlice", "ProbeBob"):
                        account = ok(
                            api.post(
                                "/auth/register",
                                json={"username": name, "password": "Abc123"},
                            ),
                            201,
                        )["account"]
                        token = ok(
                            api.post(
                                "/auth/login",
                                json={"account": account, "password": "Abc123"},
                            )
                        )["token"]
                        people.append((account, {"Authorization": "Bearer " + token}))
                    a, b = people
                    body = {
                        "target_account": b[0],
                        "client_nonce": "direct",
                        "content": [{"type": "text", "text": "same"}],
                    }
                    direct = ok(
                        api.post("/messages", headers={**a[1], HEADER: "1"}, json=body)
                    )
                    AssociatedMessage.model_validate(direct)
                    assert direct["operation_id"] == "direct"
                    Message.model_validate(
                        ok(api.post("/messages", headers=a[1], json=body))
                    )
                    peer = ok(
                        api.get(
                            f"/messages/{direct['id']}", headers={**b[1], HEADER: "1"}
                        )
                    )
                    Message.model_validate(peer)
                    assert "operation_id" not in peer
                    local = start_local()
                    with httpx.Client(
                        base_url=f"http://127.0.0.1:{local_port}", trust_env=False
                    ) as control:
                        ready(control, local, True)
                        ok(
                            control.post(
                                "/auth/login",
                                json={"account": a[0], "password": "Abc123"},
                            )
                        )
                        auth = ok(control.post("/v2/status", json={}))["auth"]
                        owner = {v2.OWNER_HEADER: "A" * 43}
                        other_owner = {v2.OWNER_HEADER: "B" * 43}

                        def enroll(headers, alias):
                            return ok(
                                control.post(
                                    "/v2/consumers/create",
                                    headers=headers,
                                    json={"expected_auth": auth, "session_id": alias},
                                )
                            )["identity"]

                        identity, other = (
                            enroll(owner, "one"),
                            enroll(other_owner, "two"),
                        )

                        def call(name, payload):
                            path, request_model, response_model, status, _ = (
                                v2.BUSINESS[name]
                            )
                            request = {"expected_identity": identity, **payload}
                            request_model.model_validate(request)
                            data = ok(
                                control.post(path, headers=owner, json=request), status
                            )
                            response_model.model_validate(data)
                            return data["result"]

                        sent = call(
                            "send_message",
                            {
                                "target_account": b[0],
                                "operation_id": "local",
                                "content": [{"type": "text", "text": "same"}],
                            },
                        )
                        assert "operation_id" not in sent
                        attachment = call(
                            "send_attachment",
                            {
                                "target_account": b[0],
                                "operation_id": "local-attachment",
                                "source": {
                                    "base64": "c2FtZQ==",
                                    "mime_type": "text/plain",
                                    "filename": "same.txt",
                                },
                                "cover": None,
                            },
                        )
                        assert (
                            attachment["kind"] == "attachment"
                            and "operation_id" not in attachment
                        )
                        attachment_result = call(
                            "get_operation", {"operation_id": "local-attachment"}
                        )
                        assert attachment_result["kind"] == "message"
                        assert attachment_result["message"]["id"] == attachment["id"]
                        for name, payload in [
                            ("get_operation", {"operation_id": "local"}),
                            ("get_message", {"message_id": sent["id"]}),
                            ("get_context", {"message_id": sent["id"]}),
                            ("list_conversations", {}),
                            ("read_messages", {"account": b[0]}),
                            (
                                "wait_messages",
                                {"account": b[0], "seen_position": 0, "timeout": 30},
                            ),
                        ]:
                            call(name, payload)
                        missing = control.post(
                            "/v2/operations/get",
                            headers=other_owner,
                            json={"expected_identity": other, "operation_id": "local"},
                        )
                        assert missing.status_code == 404
                        ledger = json.loads(
                            (root / "client/chat-ledger.json").read_text()
                        )
                        stored = ledger["accounts"][a[0]]["operations"]["local"]
                        assert stored["message"]["operation_id"] == "local"
                        # Actual process restart, then restore the existing consumer under
                        # the new auth generation without transferring its owner.
                        stop(local)
                        local = start_local()
                        ready(control, local, True)
                        auth = ok(control.post("/v2/status", json={}))["auth"]
                        identity = ok(
                            control.post(
                                "/v2/consumers/bind",
                                headers=owner,
                                json={
                                    "expected_auth": auth,
                                    "consumer_id": identity["consumer_id"],
                                    "expected_binding_revision": identity[
                                        "binding_revision"
                                    ],
                                    "session_id": "reopened",
                                },
                            )
                        )["identity"]
                        restored = call("get_operation", {"operation_id": "local"})
                        assert restored["message"]["id"] == sent["id"]
                    stop(server)
                    server = start_server()
                    ready(api, server)
                    assert (
                        ok(
                            api.post(
                                "/messages", headers={**a[1], HEADER: "1"}, json=body
                            )
                        )["id"]
                        == direct["id"]
                    )
            finally:
                for child in reversed(children):
                    stop(child)
    print(
        json.dumps(
            {
                "result": "PASS",
                "real_server_tcp": True,
                "standalone_dart_bin": True,
                "local_strict_response_routes": 8,
                "consumer_isolation": True,
                "internal_association_persisted": True,
                "dart_process_restart": True,
                "server_process_restart": True,
                "duration_seconds": round(time.monotonic() - started, 2),
            }
        )
    )


if __name__ == "__main__":
    main()
