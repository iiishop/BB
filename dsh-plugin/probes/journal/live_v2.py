"""Positive assertions for live.py --v2; no fake client or silent fallback.

Uses the outer runner's owned services/process cleanup. Until Muse's integration,
negotiate must fail visibly on the v1 client; that is NOT a passing product test.
"""

import json
import secrets
import select
import sqlite3
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import httpx
from bb_auth_contract import chat_v2 as wire


def run(
    *,
    origin,
    account,
    peer,
    switched,
    runtime,
    root,
    private,
    launch,
    stop,
    restart,
    record,
):
    def call(name, body, owner=None, status=200, code=None):
        path, request, response, _, needs_owner = wire.OPERATIONS[name]
        request.model_validate(body)
        assert not needs_owner or owner
        actual = httpx.post(
            origin + path,
            json=body,
            headers={wire.OWNER_HEADER: owner} if owner else {},
            timeout=10,
            trust_env=False,
        )
        assert actual.status_code == status, (
            f"{name}: expected {status}, got {actual.status_code}"
        )
        value = actual.json()
        if code:
            wire.ErrorEnvelope.model_validate(value)
            assert value["error"]["code"] == code
        else:
            response.model_validate(value)
        return value

    call("negotiate", {"supported_versions": [2]})
    auth = call("status", {})["auth"]
    assert auth["account"] == account
    # Capability persists before enrollment, independent of runtime session/attempt.
    owner = secrets.token_urlsafe(32)
    config = private / "v2-operation-config.json"
    config.write_text(json.dumps({"origin": origin, "owner_key": owner, "peer": peer}))
    binding = call(
        "consumer_create", {"expected_auth": auth, "session_id": "before-crash"}, owner
    )
    identity = binding["identity"]
    assert binding["active"] and binding["migration"] == "ready"
    again = call(
        "consumer_create", {"expected_auth": auth, "session_id": "ignored-retry"}, owner
    )
    assert again == binding, "enrollment retries must not rebind"
    config.write_text(
        json.dumps(
            {"origin": origin, "owner_key": owner, "peer": peer, "identity": identity}
        )
    )
    node_root = root / "v2-operation"
    node_root.mkdir()
    command = [
        "node",
        str(Path(__file__).with_name("v2-operation.mjs")),
        runtime,
        str(node_root),
        str(config),
    ]
    worker = launch([*command, "crash"], "v2-operation-crash", pipe=True)
    assert select.select([worker.stdout], [], [], 20)[0], (
        "v2 operation checkpoint deadline"
    )
    assert json.loads(worker.stdout.readline())["checkpoint"] == "sent-before-receipt"
    stop(worker, crash=True)
    assert worker.returncode == -9
    restart()
    auth = call("status", {})["auth"]
    assert (
        auth["account"] == account
        and auth["auth_generation"] != identity["auth_generation"]
    )
    call(
        "get_operation",
        {"expected_identity": identity, "operation_id": "old-context"},
        owner,
        409,
        "stale_identity",
    )
    current = call(
        "consumer_get",
        {"expected_auth": auth, "consumer_id": identity["consumer_id"]},
        owner,
    )
    assert not current["active"]
    binding = call(
        "consumer_bind",
        {
            "expected_auth": auth,
            "consumer_id": identity["consumer_id"],
            "expected_binding_revision": current["identity"]["binding_revision"],
            "session_id": "after-crash",
        },
        owner,
    )
    identity = binding["identity"]
    config.write_text(
        json.dumps(
            {"origin": origin, "owner_key": owner, "peer": peer, "identity": identity}
        )
    )
    recovered = launch([*command, "recover"], "v2-operation-recovered", pipe=True)
    stdout, _ = recovered.communicate(timeout=20)
    assert recovered.returncode == 0, (
        "v2 operation query failed; inspect private process log"
    )
    result = json.loads(stdout)
    assert result["sends_after_restart"] == 0
    record("v2-real-operation-recovery", status="PASS", **result)

    def business(name, payload, who=identity, key=owner, **kwargs):
        value = call(name, {"expected_identity": who, **payload}, key, **kwargs)
        if "identity" in value:
            assert value["identity"] == who
            return value["result"]
        return value

    second_key = secrets.token_urlsafe(32)
    second = call(
        "consumer_create",
        {"expected_auth": auth, "session_id": "consumer-two"},
        second_key,
    )["identity"]
    read = business(
        "read_messages", {"account": peer, "after_position": 0, "limit": 100}
    )
    receipts = [item["presentation"]["receipt_id"] for item in read["items"]]
    through = max(item["message"]["position"] for item in read["items"])
    confirm = {
        "attempt_id": "v2-display-one",
        "request_digest": "a" * 64,
        "receipt_ids": receipts,
    }
    business("confirm_presentation", confirm)
    assert (
        business("ack_messages", {"account": peer, "through_position": through})[
            "consumed_through"
        ]
        == through
    )
    assert (
        business("ack_messages", {"account": peer, "through_position": through})[
            "consumed_through"
        ]
        == through
    )
    business(
        "ack_messages",
        {"account": peer, "through_position": through},
        second,
        second_key,
        status=409,
        code="consumption_gap",
    )
    assert (
        business("get_consumption", {"account": peer}, second, second_key)[
            "consumed_through"
        ]
        == 0
    )
    business(
        "get_operation",
        {"operation_id": result["operation_id"]},
        second,
        second_key,
        status=404,
        code="not_found",
    )
    second_read = business(
        "read_messages", {"account": peer, "after_position": 0}, second, second_key
    )
    business(
        "confirm_presentation",
        {
            **confirm,
            "receipt_ids": [
                x["presentation"]["receipt_id"] for x in second_read["items"]
            ],
        },
        second,
        second_key,
    )
    assert (
        business(
            "ack_messages",
            {"account": peer, "through_position": through},
            second,
            second_key,
        )["consumed_through"]
        == through
    )
    record(
        "v2-consumer-isolation",
        status="PASS",
        first_cursor=through,
        second_before_confirmation=0,
        second_after_own_confirmation=through,
    )

    call(
        "consumer_get",
        {"expected_auth": auth, "consumer_id": identity["consumer_id"]},
        second_key,
        409,
        "stale_binding",
    )

    # Distinct owner processes competing at the exact same CAS revision.
    def bind(session):
        path = wire.BOOTSTRAP["consumer_bind"][0]
        return httpx.post(
            origin + path,
            json={
                "expected_auth": auth,
                "consumer_id": identity["consumer_id"],
                "expected_binding_revision": identity["binding_revision"],
                "session_id": session,
            },
            headers={wire.OWNER_HEADER: owner},
            timeout=10,
            trust_env=False,
        )

    with ThreadPoolExecutor(max_workers=2) as pool:
        bound = list(pool.map(bind, ["owner-process-one", "owner-process-two"]))
    assert sorted(x.status_code for x in bound) == [200, 409]
    conflict = next(x for x in bound if x.status_code == 409).json()
    assert conflict["error"]["code"] == "stale_binding"
    business(
        "ack_messages",
        {"account": peer, "through_position": through},
        status=409,
        code="stale_binding",
    )
    record(
        "v2-binding-cas",
        status="PASS",
        successes=1,
        conflicts=1,
        wrong_owner_rejected=True,
    )

    stale_send = {
        "target_account": peer,
        "operation_id": "must-not-send-after-switch",
        "content": [{"type": "text", "text": "synthetic stale intent"}],
    }
    for login_account in [switched, account]:
        response = httpx.post(
            origin + "/auth/login",
            json={"account": login_account, "password": "Abc123"},
            timeout=10,
            trust_env=False,
        )
        assert response.status_code == 200
        business("send_message", stale_send, status=409, code="stale_identity")
        business(
            "ack_messages",
            {"account": peer, "through_position": through},
            status=409,
            code="stale_identity",
        )
        business("confirm_presentation", confirm, status=409, code="stale_identity")
    # Independent business facts: an error reply alone cannot prove no side effect.
    with sqlite3.connect(f"file:{private / 'server.db'}?mode=ro", uri=True) as database:
        messages = [
            json.loads(row[0])
            for row in database.execute("SELECT payload FROM messages")
        ]
        assert len(messages) == 1 and messages[0]["sender_account"] == account
        assert database.execute("SELECT count(*) FROM operations").fetchone()[0] == 1
    record(
        "v2-switch-and-aba",
        status="PASS",
        old_send_ack_confirm_rejected=True,
        business_message_count=1,
        new_account_side_effects=0,
    )
    record(
        "v2-gate",
        status="PARTIAL",
        NOT_RUN=[
            "in-flight admitted send race",
            "wait/event competition",
            "download callback/recovery",
            "migration fault injection",
            "real models",
            "Flutter",
            "CI",
        ],
    )
