"""Actual v2 client + FastAPI + stock DSH; BB public-DI fault barriers only.

Collect counterexamples without treating expected defect reproduction as PASS.
No secret/header/request-body logging. A failed acceptance case exits nonzero.
"""

import hashlib
import json
import secrets
import sqlite3
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import httpx


def run(
    *,
    origin,
    api,
    control,
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
    dart_executable,
    packages,
):
    defects = []
    requests = []
    barrier_history = []
    pool = ThreadPoolExecutor(max_workers=4)

    def raw(path, body, owner=None, base=origin, timeout=20):
        value = httpx.post(
            base + path,
            json=body,
            headers={"X-BB-Consumer-Key": owner} if owner else {},
            timeout=timeout,
            trust_env=False,
        )
        requests.append({"path": path, "status": value.status_code})
        return value

    def ok(path, body, owner=None):
        value = raw(path, body, owner)
        assert value.status_code == 200, f"{path}: {value.status_code}"
        return value.json()

    def ctrl(path, body=None):
        response = raw(path, body or {}, base=control)
        assert response.status_code == 200, f"barrier {path}: {response.status_code}"
        return response.json()

    def assess(name, passed, **facts):
        record(name, status="PASS" if passed else "FAIL", **facts)
        if not passed:
            defects.append(name)

    def login(who):
        ok("/auth/login", {"account": who, "password": "Abc123"})

    def enroll(label):
        owner = secrets.token_urlsafe(32)
        auth = ok("/v2/status", {})["auth"]
        bound = ok(
            "/v2/consumers/create", {"expected_auth": auth, "session_id": label}, owner
        )
        return owner, bound["identity"]

    def bind(owner, identity, label):
        auth = ok("/v2/status", {})["auth"]
        current = ok(
            "/v2/consumers/get",
            {"expected_auth": auth, "consumer_id": identity["consumer_id"]},
            owner,
        )
        return ok(
            "/v2/consumers/bind",
            {
                "expected_auth": auth,
                "consumer_id": identity["consumer_id"],
                "expected_binding_revision": current["identity"]["binding_revision"],
                "session_id": label,
            },
            owner,
        )["identity"]

    def business(path, body, owner, identity, **kwargs):
        return raw(
            "/v2/" + path, {**body, "expected_identity": identity}, owner, **kwargs
        )

    def result(path, body, owner, identity):
        value = business(path, body, owner, identity)
        assert value.status_code == 200, f"{path}: {value.status_code}"
        assert value.json()["identity"] == identity
        return value.json()["result"]

    def read(owner, identity):
        return result(
            "chat/read_messages",
            {"account": peer, "after_position": 0, "limit": 100},
            owner,
            identity,
        )

    def confirmation(page, attempt):
        return {
            "attempt_id": attempt,
            "request_digest": "a" * 64,
            "receipt_ids": [x["presentation"]["receipt_id"] for x in page["items"]],
        }

    def ledger():
        return json.loads((private / "dart/chat-ledger.json").read_text())

    def incoming(nonce):
        token = httpx.post(
            api + "/auth/login",
            json={"account": peer, "password": "Abc123"},
            trust_env=False,
        ).json()["token"]
        value = httpx.post(
            api + "/messages",
            headers={"Authorization": "Bearer " + token},
            json={
                "target_account": account,
                "client_nonce": nonce,
                "content": [{"type": "text", "text": "synthetic " + nonce}],
            },
            trust_env=False,
        )
        assert value.status_code == 200
        return value.json()

    def case(name, fn):
        try:
            fn()
        except Exception as error:  # noqa: BLE001 - collect every failing case; final gate raises
            assess(
                name, False, failure_type=type(error).__name__, detail=str(error)[:200]
            )
        finally:
            ctrl("/release")

    try:
        ok("/v2/protocol/negotiate", {"supported_versions": [2]})
        incoming("seed")

        for mode in ["confirm-lost", "ack-lost"]:

            def settle(mode=mode):
                owner, identity = enroll(mode)
                config = private / f"{mode}.json"
                config.write_text(
                    json.dumps(
                        {
                            "origin": origin,
                            "owner_key": owner,
                            "identity": identity,
                            "peer": peer,
                        }
                    )
                )
                directory = root / mode
                directory.mkdir()
                child = launch(
                    [
                        "node",
                        str(Path(__file__).with_name("real-settlement.mjs")),
                        runtime,
                        str(directory),
                        str(config),
                        mode,
                    ],
                    mode,
                    pipe=True,
                )
                stdout, _ = child.communicate(timeout=30)
                assert child.returncode == 0, (
                    f"native settlement worker exit {child.returncode}; inspect private log"
                )
                record("real-" + mode, status="PASS", **json.loads(stdout))

            case("real-" + mode, settle)

        def admitted_send():
            owner, identity = enroll("admitted-send")
            ctrl("/arm", {"edge": "send-after-remote-commit"})
            pending = pool.submit(
                business,
                "chat/send_message",
                {
                    "target_account": peer,
                    "operation_id": "admitted-original",
                    "content": [{"type": "text", "text": "synthetic admitted send"}],
                },
                owner,
                identity,
            )
            ctrl("/wait")
            login(switched)
            ctrl("/release")
            response = pending.result(timeout=20)
            state = ledger()
            operation = state["accounts"][account]["operations"]["admitted-original"]
            other = state["accounts"].get(switched, {}).get("operations", {})
            with sqlite3.connect(
                f"file:{private / 'server.db'}?mode=ro", uri=True
            ) as database:
                row = database.execute(
                    "SELECT account FROM operations WHERE operation_id=?",
                    ("admitted-original",),
                ).fetchone()
            login(account)
            current = bind(owner, identity, "admitted-recovered")
            queried = result(
                "operations/get", {"operation_id": "admitted-original"}, owner, current
            )
            code = response.json().get("error", {}).get("code")
            assess(
                "admitted-send-switch",
                response.status_code == 409
                and code == "stale_identity"
                and operation["state"] == "succeeded"
                and row[0] == account
                and "admitted-original" not in other
                and queried["status"] == "succeeded",
                observed_status=response.status_code,
                observed_code=code,
                original_plan_state=operation["state"],
                committed_only_original=row[0] == account,
                new_account_has_plan="admitted-original" in other,
                query_status=queried["status"],
            )

        case("admitted-send-switch", admitted_send)

        for edge in ["confirm-before", "ack-before", "confirm-inside", "ack-inside"]:

            def stale_commit(edge=edge):
                owner, identity = enroll(edge)
                page = read(owner, identity)
                confirm = confirmation(page, edge)
                through = max(x["message"]["position"] for x in page["items"])
                if edge.startswith("ack"):
                    result("chat/confirm_presentation", confirm, owner, identity)
                ctrl("/arm", {"edge": edge})
                path = (
                    "chat/confirm_presentation"
                    if edge.startswith("confirm")
                    else "chat/ack_messages"
                )
                payload = (
                    confirm
                    if edge.startswith("confirm")
                    else {"account": peer, "through_position": through}
                )
                pending = pool.submit(business, path, payload, owner, identity)
                ctrl("/wait")
                if edge.endswith("inside"):
                    login(switched)
                else:
                    current = bind(owner, identity, edge + "-new-owner")
                ctrl("/release")
                response = pending.result(timeout=20)
                if edge.endswith("inside"):
                    login(account)
                    current = bind(owner, identity, edge + "-restored")
                cursor = result("chat/consumption", {"account": peer}, owner, current)[
                    "consumed_through"
                ]
                receipts = ledger()["accounts"][account]["receipts"]
                confirmed = sum(
                    receipts[key]["confirmed"] for key in confirm["receipt_ids"]
                )
                code = response.json().get("error", {}).get("code")
                unchanged = (
                    confirmed == 0 if edge.startswith("confirm") else cursor == 0
                )
                assess(
                    edge + "-rebind",
                    response.status_code == 409
                    and code
                    == (
                        "stale_identity" if edge.endswith("inside") else "stale_binding"
                    )
                    and unchanged,
                    observed_status=response.status_code,
                    observed_code=code,
                    durable_confirmed=confirmed,
                    durable_watermark=cursor,
                    expected_no_commit=True,
                    old_revision=identity["binding_revision"],
                    new_revision=current["binding_revision"],
                )

            case(edge + "-rebind", stale_commit)

        def notifications():
            owner, identity = enroll("wait-passive")
            page = read(owner, identity)
            through = max(x["message"]["position"] for x in page["items"])
            result(
                "chat/confirm_presentation",
                confirmation(page, "initial"),
                owner,
                identity,
            )
            result(
                "chat/ack_messages",
                {"account": peer, "through_position": through},
                owner,
                identity,
            )
            result("events/subscribe", {"peer_account": peer}, owner, identity)
            cursor = result("events/read", {"after_cursor": 0}, owner, identity)[
                "next_cursor"
            ]
            waiting = pool.submit(
                business,
                "chat/wait_messages",
                {"account": peer, "seen_position": through, "timeout": 30},
                owner,
                identity,
                timeout=35,
            )
            passive = pool.submit(
                business,
                "events/wait",
                {"after_cursor": cursor, "timeout": 30},
                owner,
                identity,
                timeout=35,
            )
            first = incoming("wait-first")
            waited, notified = waiting.result(timeout=40), passive.result(timeout=40)
            assert waited.status_code == 200 and notified.status_code == 200
            wait_page = waited.json()["result"]
            positions = [x["message"]["position"] for x in wait_page["items"]]
            event_positions = [
                x["event"].get("position") for x in notified.json()["result"]["items"]
            ]
            assert (
                first["position"] in positions and first["position"] in event_positions
            )
            assert (
                result("chat/consumption", {"account": peer}, owner, identity)[
                    "consumed_through"
                ]
                == through
            )
            later = incoming("wait-later")
            result(
                "chat/confirm_presentation",
                confirmation(wait_page, "wait-displayed"),
                owner,
                identity,
            )
            value = result(
                "chat/ack_messages",
                {"account": peer, "through_position": first["position"]},
                owner,
                identity,
            )
            assess(
                "real-wait-passive-contiguous",
                value["consumed_through"] == first["position"] < later["position"],
                wait_positions=positions,
                event_positions=event_positions,
                consumed=value["consumed_through"],
                later_position=later["position"],
                native_wake_arbitration="NOT RUN",
            )

        case("real-wait-passive-contiguous", notifications)

        def downloads(mode):
            owner, identity = enroll(mode)
            token = httpx.post(
                api + "/auth/login",
                json={"account": peer, "password": "Abc123"},
                trust_env=False,
            ).json()["token"]
            content = b"SYNTHETIC DEA467 DOWNLOAD\n"
            uploaded = httpx.post(
                api + "/media",
                headers={"Authorization": "Bearer " + token},
                data={"target_account": account},
                files={"file": ("synthetic.txt", content, "text/plain")},
                trust_env=False,
            )
            assert uploaded.status_code == 200
            media_id = uploaded.json()["media_id"]
            ctrl("/arm", {"edge": "download-after-fetch"})
            start = business(
                "downloads/start",
                {
                    "operation_id": mode,
                    "media_id": media_id,
                    "directory": str(private / "downloads"),
                },
                owner,
                identity,
            )
            assert start.status_code == 202
            task = start.json()["result"]
            ctrl("/wait")
            if mode == "download-restart":
                barrier_history.extend(ctrl("/trace")["trace"])
                restart(crash=True)
            else:
                current = bind(owner, identity, mode + "-new-owner")
                ctrl("/release")
            current = bind(owner, identity, mode + "-query-owner")
            deadline = time.monotonic() + 10
            while True:
                value = result(
                    "downloads/get", {"task_id": task["task_id"]}, owner, current
                )
                if value["status"] in ["succeeded", "failed", "uncertain"]:
                    break
                assert time.monotonic() < deadline, "download terminal deadline"
                time.sleep(0.05)
            other_key, other_identity = enroll(mode + "-other-consumer")
            wrong = business(
                "downloads/get", {"task_id": task["task_id"]}, other_key, other_identity
            )
            matches = (
                value["status"] == "succeeded"
                and value["actual_path"] == task["planned_path"]
            )
            if matches:
                matches = Path(value["actual_path"]).read_bytes() == content
            events = result("events/read", {"after_cursor": 0}, owner, current)
            related = [
                x["event"]
                for x in events["items"]
                if x["event"].get("task_id") == task["task_id"]
            ]
            origins_preserved = value["origin_identity"] == identity and all(
                x["origin_identity"] == identity for x in related
            )
            assess(
                mode,
                matches and wrong.status_code == 404 and origins_preserved,
                task_status=value["status"],
                same_reserved_path=value.get("actual_path") == task["planned_path"],
                content_sha256=hashlib.sha256(content).hexdigest(),
                bytes_verified=matches,
                other_consumer_status=wrong.status_code,
                origins_preserved=origins_preserved,
                origin_event_count=len(related),
                crash_after_actual_fetch=mode == "download-restart",
            )

        for mode in ["download-rebind", "download-restart"]:
            case(mode, lambda mode=mode: downloads(mode))

        for phase in ["prepare", "recover"]:

            def migration(phase=phase):
                child = launch(
                    [
                        dart_executable,
                        "--packages=" + packages,
                        str(Path(__file__).with_name("migration_probe.dart")),
                        str(private / "migration"),
                        phase,
                    ],
                    "migration-" + phase,
                    pipe=True,
                )
                stdout, _ = child.communicate(timeout=20)
                assert child.returncode in [0, 1], (
                    "migration worker failed before assertions"
                )
                values = json.loads(stdout)
                for value in values:
                    name, passed = value.pop("name"), value.pop("passed")
                    assess(name, passed, **value)

            case("migration-" + phase, migration)

        record(
            "fault-gate",
            status="FAIL" if defects else "PARTIAL",
            failed_cases=defects,
            NOT_RUN=[
                "native mixed-session arbitration",
                "migration interruption after backup before atomic rename",
                "real model",
                "Flutter",
                "CI",
            ],
        )
    finally:
        ctrl("/release")
        pool.shutdown(wait=True)
        (root / "request-trace.json").write_text(json.dumps(requests, indent=2) + "\n")
        barrier_history.extend(ctrl("/trace")["trace"])
        (root / "barriers.json").write_text(
            json.dumps({"trace": barrier_history}, indent=2) + "\n"
        )
    assert not defects, "real client gate failures: " + ", ".join(defects)
