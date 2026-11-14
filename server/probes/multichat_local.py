"""Real FastAPI + standalone Dart probe; isolated synthetic accounts only.

Run from repo root: uv run --project server --locked python server/probes/multichat_local.py
No DSH/model claim. Every local request/reply uses the authoritative wire DTO.
"""

import json
import os
import secrets
import socket
import subprocess
import tempfile
import time
from pathlib import Path

import httpx
from bb_auth_contract import chat_v2 as v2

ROOT = Path(__file__).resolve().parents[2]


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait_ready(url, process):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        assert process.poll() is None, "entrypoint exited before readiness"
        try:
            httpx.get(url, timeout=1)
            return
        except httpx.TransportError:
            time.sleep(0.1)
    raise AssertionError("entrypoint readiness deadline")


def main():
    processes = []
    with tempfile.TemporaryDirectory(prefix="bb-multichat-live-") as directory:
        data = Path(directory)
        env = dict(os.environ)
        server_port, client_port = port(), port()
        env.update(
            BB_DATABASE_PATH=str(data / "server.db"),
            BB_AVATAR_DIRECTORY=str(data / "avatars"),
            BB_MEDIA_DIRECTORY=str(data / "media"),
            BB_HOST="127.0.0.1",
            BB_PORT=str(server_port),
        )
        upstream = f"http://127.0.0.1:{server_port}"
        local = f"http://127.0.0.1:{client_port}"
        with (
            (data / "server.log").open("w") as server_log,
            (data / "client.log").open("w") as client_log,
        ):

            def start_client():
                process = subprocess.Popen(
                    [
                        "dart",
                        "run",
                        "bin/bb_client_api.dart",
                        "--port",
                        str(client_port),
                        "--server-url",
                        upstream,
                        "--session-file",
                        str(data / "session.json"),
                    ],
                    cwd=ROOT / "client",
                    stdout=client_log,
                    stderr=client_log,
                )
                processes.append(process)
                wait_ready(local + "/v2/status", process)
                return process

            try:
                server = subprocess.Popen(
                    [
                        "uv",
                        "run",
                        "--project",
                        "server",
                        "--locked",
                        "python",
                        "-m",
                        "bb_server",
                    ],
                    cwd=ROOT,
                    env=env,
                    stdout=server_log,
                    stderr=server_log,
                )
                processes.append(server)
                wait_ready(upstream + "/health", server)
                with (
                    httpx.Client(base_url=upstream, timeout=15) as api,
                    httpx.Client(base_url=local, timeout=15) as client,
                ):
                    accounts = []
                    for name in ("Agent", "PeerB", "PeerC", "NewPeer"):
                        response = api.post(
                            "/auth/register",
                            json={"username": name, "password": "Synthetic123"},
                        )
                        assert response.status_code == 201
                        account = response.json()["account"]
                        token = api.post(
                            "/auth/login",
                            json={"account": account, "password": "Synthetic123"},
                        ).json()["token"]
                        accounts.append((account, {"Authorization": "Bearer " + token}))
                    a, b, c, d = accounts

                    def send(who, peer, nonce):
                        response = api.post(
                            "/messages",
                            headers=who[1],
                            json={
                                "target_account": peer[0],
                                "client_nonce": nonce,
                                "content": [{"type": "text", "text": nonce}],
                            },
                        )
                        assert response.status_code == 200
                        return response.json()

                    c_old = send(c, a, "c-old")
                    b_old = send(b, a, "b-old")
                    b_sparse = send(b, a, "b-sparse")
                    owner = secrets.token_urlsafe(32)
                    client.headers["X-BB-Consumer-Key"] = owner

                    def call(name, body):
                        path, request, response, status, _ = v2.OPERATIONS[name]
                        request.model_validate(body)
                        result = client.post(path, json=body)
                        assert result.status_code == status, (name, result.status_code)
                        value = result.json()
                        response.model_validate(value)
                        return value

                    child = start_client()
                    assert (
                        client.post(
                            "/auth/login",
                            json={"account": a[0], "password": "Synthetic123"},
                        ).status_code
                        == 200
                    )
                    auth = call("status", {})["auth"]
                    identity = call(
                        "consumer_create",
                        {"expected_auth": auth, "session_id": "live-session"},
                    )["identity"]

                    def business(name, **body):
                        return call(name, {"expected_identity": identity, **body})[
                            "result"
                        ]

                    business("events_subscribe", peer_account=b[0])
                    first = business("events_read")
                    assert len(first["items"]) == 2
                    business("events_subscribe", peer_account=c[0])
                    business("events_subscribe", peer_account=c[0])
                    later = business("events_read", after_cursor=first["next_cursor"])
                    assert [
                        entry["event"]["peer_account"] for entry in later["items"]
                    ] == [c[0]]
                    assert (
                        business("get_message", message_id=c_old["id"])["item"][
                            "message"
                        ]["id"]
                        == c_old["id"]
                    )
                    rows = {
                        row["peer_account"]: row
                        for row in business("list_conversations")["items"]
                    }
                    assert rows[b[0]]["incoming_unread"] == 2
                    assert rows[c[0]]["incoming_unread"] == 1
                    assert rows[b[0]]["display_name"] == "PeerB"
                    visible = business("get_message", message_id=b_sparse["id"])
                    receipt = visible["item"]["presentation"]["receipt_id"]
                    business(
                        "confirm_presentation",
                        attempt_id="shown-sparse",
                        request_digest="a" * 64,
                        receipt_ids=[receipt],
                    )
                    rows = {
                        row["peer_account"]: row
                        for row in business(
                            "list_conversations", unread_only=True, order="recent"
                        )["items"]
                    }
                    assert rows[b[0]]["incoming_unread"] == 1
                    assert rows[b[0]]["latest_unread"]["message_id"] == b_old["id"]
                    assert rows[b[0]]["consumed_through"] == 0
                    assert rows[c[0]]["incoming_unread"] == 1
                    business("events_subscribe", discover=True)
                    send(d, a, "first-contact")
                    business(
                        "events_subscribe", discover=True
                    )  # awaited discovery, no timer polling
                    all_events = business("events_read")
                    assert {
                        entry["event"]["peer_account"] for entry in all_events["items"]
                    } == {b[0], c[0], d[0]}
                    outgoing = business(
                        "send_message",
                        target_account=c[0],
                        operation_id="explicit-send",
                        content=[{"type": "text", "text": "explicit reply"}],
                    )
                    child.terminate()
                    child.wait(timeout=10)
                    start_client()
                    new_auth = call("status", {})["auth"]
                    assert new_auth and new_auth != auth
                    identity = call(
                        "consumer_bind",
                        {
                            "expected_auth": new_auth,
                            "consumer_id": identity["consumer_id"],
                            "expected_binding_revision": identity["binding_revision"],
                            "session_id": "live-session-restart",
                        },
                    )["identity"]
                    business("events_subscribe", discover=True)
                    assert (
                        business("events_read", after_cursor=all_events["next_cursor"])[
                            "items"
                        ]
                        == []
                    )
                    recovered = business("get_operation", operation_id="explicit-send")
                    assert (
                        recovered["status"] == "succeeded"
                        and recovered["message"]["id"] == outgoing["id"]
                    )
                    rows = {
                        row["peer_account"]: row
                        for row in business("list_conversations")["items"]
                    }
                    assert (
                        rows[b[0]]["incoming_unread"]
                        == rows[c[0]]["incoming_unread"]
                        == 1
                    )
                    assert rows[c[0]]["unconsumed_positions"] == 2
                    assert (
                        json.loads((data / "chat-ledger.json").read_text())["version"]
                        == 3
                    )
                    print(
                        json.dumps(
                            {
                                "result": "PASS",
                                "accounts": 4,
                                "entrypoints": ["bb_server", "bb_client_api"],
                                "checks": [
                                    "second-peer-backfill",
                                    "first-contact-discovery",
                                    "exact-incoming-unread",
                                    "sparse-confirmation",
                                    "explicit-send-recovery",
                                    "cold-restart-dedup",
                                ],
                                "dsh_model": "NOT_RUN",
                            }
                        )
                    )
            finally:
                for process in reversed(processes):
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=10)


if __name__ == "__main__":
    main()
