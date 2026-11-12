"""Independent remaining gates. Never runs/weakens the known 18-case failures."""

import hashlib
import json
import secrets
import select
import time
import traceback
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
    here = Path(__file__).parent
    failures, trace = [], []

    def raw(path, body, owner=None, base=origin):
        r = httpx.post(
            base + path,
            json=body,
            headers={"X-BB-Consumer-Key": owner} if owner else {},
            trust_env=False,
            timeout=20,
        )
        trace.append({"path": path, "status": r.status_code})
        return r

    def ok(path, body, owner=None, base=origin):
        r = raw(path, body, owner, base)
        assert r.status_code == 200, f"{path}: {r.status_code}"
        return r.json()

    def enroll(label):
        owner = secrets.token_urlsafe(32)
        auth = ok("/v2/status", {})["auth"]
        identity = ok(
            "/v2/consumers/create", {"expected_auth": auth, "session_id": label}, owner
        )["identity"]
        return owner, identity

    def result(path, body, owner, identity):
        v = ok("/v2/" + path, {**body, "expected_identity": identity}, owner)
        assert v["identity"] == identity
        return v["result"]

    def case(name, fn):
        try:
            facts = fn()
            record(name, status="PASS", **facts)
        except Exception as error:  # noqa: BLE001 - aggregate independent evidence
            failures.append(name)
            (private / (name + ".failure")).write_text(traceback.format_exc())
            record(
                name, status="FAIL", type=type(error).__name__, detail=str(error)[:250]
            )
        finally:
            ok("/release", {}, base=control)

    def checkpoint(child):
        assert select.select([child.stdout], [], [], 25)[0], "worker barrier deadline"
        value = json.loads(child.stdout.readline())
        assert child.poll() is None, "worker exited before barrier"
        return value

    def incoming(nonce):
        token = ok("/auth/login", {"account": peer, "password": "Abc123"}, base=api)[
            "token"
        ]
        r = httpx.post(
            api + "/messages",
            headers={"Authorization": "Bearer " + token},
            json={
                "target_account": account,
                "client_nonce": nonce,
                "content": [{"type": "text", "text": "synthetic " + nonce}],
            },
            trust_env=False,
        )
        assert r.status_code == 200
        return r.json()

    def config(label):
        owner, identity = enroll(label)
        p = private / (label + ".json")
        p.write_text(
            json.dumps(
                {
                    "origin": origin,
                    "owner_key": owner,
                    "identity": identity,
                    "peer": peer,
                }
            )
        )
        return p, owner, identity

    def native(mode, directory, cfg):
        return launch(
            [
                "node",
                str(here / "native-remaining.mjs"),
                runtime,
                str(directory),
                str(cfg),
                mode,
            ],
            mode,
            pipe=True,
        )

    def finish(child, label):
        stdout, stderr = child.communicate(timeout=30)
        (private / (label + ".stderr")).write_text(stderr)
        assert child.returncode == 0, (
            f"{label} exit {child.returncode}; inspect private stderr"
        )
        return json.loads(stdout.strip().splitlines()[-1])

    def native_wait():
        cfg, _, _ = config("native-wait")
        directory = root / "native-wait"
        directory.mkdir()
        child = native("wait", directory, cfg)
        assert checkpoint(child)["checkpoint"] == "native-wait-active"
        incoming("native-wait-input")
        return finish(child, "native-wait")

    def mixed():
        cfg, _, _ = config("mixed")
        directory = root / "mixed"
        directory.mkdir()
        child = native("mixed-prepare", directory, cfg)
        gate = checkpoint(child)
        assert gate["checkpoint"] == "mixed-pending-durable"
        assert len(gate["pending"]) == 2 and "foreign-before" in gate["pending"], str(
            gate
        )
        stop(child, crash=True)
        assert child.returncode == -9
        facts = finish(native("mixed-recover", directory, cfg), "mixed-recover")
        return {
            **facts,
            "original_pending": gate["pending"],
            "prepare_exit": -9,
            "concurrent_replays": 12,
            "unrelated_inputs_preserved": 2,
        }

    def busy():
        cfg, _, _ = config("busy")
        directory = root / "busy"
        directory.mkdir()
        child = native("busy", directory, cfg)
        assert checkpoint(child)["checkpoint"] == "busy-provider-held"
        incoming("busy-2")
        incoming("busy-3")
        (directory / "arrived").write_text("ready")
        return finish(child, "busy")

    def ownership():
        cfg, owner, identity = config("owner-race")
        auth = ok("/v2/status", {})["auth"]
        data = json.loads(cfg.read_text())
        data["auth"] = auth
        cfg.write_text(json.dumps(data))
        children = [
            launch(
                ["node", str(here / "owner-worker.mjs"), str(cfg), f"process-{i}"],
                f"owner-{i}",
                pipe=True,
            )
            for i in range(2)
        ]
        # Both processes must be ready before the shared release marker is written.
        for child in children:
            assert checkpoint(child)["ready"]
        (private / "owner-go").write_text("go")
        values = [finish(child, f"owner-{i}") for i, child in enumerate(children)]
        assert sorted(v["status"] for v in values) == [200, 409], str(values)
        winner = next(v["identity"] for v in values if v["status"] == 200)
        assert winner["binding_revision"] == identity["binding_revision"] + 1
        stale = raw(
            "/v2/chat/ack_messages",
            {"expected_identity": identity, "account": peer, "through_position": 1},
            owner,
        )
        assert (
            stale.status_code == 409
            and stale.json()["error"]["code"] == "stale_binding"
        )
        wrong = raw(
            "/v2/consumers/get",
            {"expected_auth": auth, "consumer_id": identity["consumer_id"]},
            secrets.token_urlsafe(32),
        )
        assert (
            wrong.status_code == 409
            and wrong.json()["error"]["code"] == "stale_binding"
        ), str(wrong.status_code)
        watermark = result("chat/consumption", {"account": peer}, owner, winner)[
            "consumed_through"
        ]
        assert watermark == 0
        return {
            "processes": 2,
            "statuses": [v["status"] for v in values],
            "stale_ack": 409,
            "wrong_owner": wrong.status_code,
            "watermark": watermark,
            "scope": "two independent plugin OS processes; one client authority",
        }

    def download_switch():
        _, owner, identity = config("download-switch")
        token = ok("/auth/login", {"account": peer, "password": "Abc123"}, base=api)[
            "token"
        ]
        content = b"SYNTHETIC SWITCH DOWNLOAD\n"
        upload = httpx.post(
            api + "/media",
            headers={"Authorization": "Bearer " + token},
            data={"target_account": account},
            files={"file": ("switch.txt", content, "text/plain")},
            trust_env=False,
        )
        assert upload.status_code == 200
        ok("/arm", {"edge": "download-after-fetch"}, base=control)
        response = raw(
            "/v2/downloads/start",
            {
                "expected_identity": identity,
                "operation_id": "download-switch",
                "media_id": upload.json()["media_id"],
                "directory": str(private / "download-target"),
            },
            owner,
        )
        assert response.status_code == 202
        task = response.json()["result"]
        ok("/wait", {}, base=control)
        ok("/auth/login", {"account": switched, "password": "Abc123"})
        other_key, other_identity = enroll("switched-download-owner")
        ok("/release", {}, base=control)
        deadline = time.monotonic() + 10
        while True:
            state = json.loads((private / "dart/chat-ledger.json").read_text())
            old = state["accounts"][account]["downloads"][task["task_id"]]
            if old["status"] == "succeeded":
                break
            assert time.monotonic() < deadline, (
                "original download did not settle after switch"
            )
            time.sleep(0.05)
        wrong = raw(
            "/v2/downloads/get",
            {"expected_identity": other_identity, "task_id": task["task_id"]},
            other_key,
        )
        assert wrong.status_code == 404
        assert old["origin_identity"] == identity
        assert old["actual_path"] == task["planned_path"]
        assert Path(old["actual_path"]).read_bytes() == content
        other = state["accounts"].get(switched, {})
        assert not other.get("downloads") and not other.get("download_operations")
        related = [
            v
            for v in other.get("events", {}).values()
            if v.get("task_id") == task["task_id"]
        ]
        assert not related
        assert task["task_id"] not in json.dumps(other), (
            "download leaked into switched account"
        )
        ok("/auth/login", {"account": account, "password": "Abc123"})
        return {
            "task_status": "succeeded",
            "origin_preserved": True,
            "new_account_tasks": 0,
            "new_account_events": 0,
            "other_account_query": 404,
            "content_sha256": hashlib.sha256(content).hexdigest(),
            "same_reserved_path": True,
        }

    try:
        ok("/v2/protocol/negotiate", {"supported_versions": [2]})
        for name, fn in [
            ("native-wait-passive", native_wait),
            ("mixed-pending-recovery", mixed),
            ("native-busy-real-settlement", busy),
            ("multiprocess-owner-cas", ownership),
            ("download-account-switch", download_switch),
        ]:
            case(name, fn)
        record(
            "remaining-gate",
            status="FAIL" if failures else "PARTIAL",
            failed_cases=failures,
            NOT_RUN=[
                "current fault suite (separate --faults invocation)",
                "real model/vision",
                "whole plugin lifecycle",
                "Flutter/CI/independent QA",
            ],
        )
    finally:
        (root / "request-trace.json").write_text(json.dumps(trace, indent=2) + "\n")
        (root / "barriers.json").write_text(
            json.dumps(ok("/trace", {}, base=control), indent=2) + "\n"
        )
    assert not failures, "remaining gates: " + ", ".join(failures)
