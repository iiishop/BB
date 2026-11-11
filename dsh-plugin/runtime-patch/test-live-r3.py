"""Foreground, real Dart/FastAPI/native-runtime integration; synthetic accounts/provider.

Run with server's uv environment. Never edits client or installed SDK. Evidence omits
the isolated credentials, ledger and database; only redacted HTTP checks/native traces.
Exit 1 means an asserted R3 contract mismatch, not an infrastructure PASS.
"""

import argparse
import json
import os
import select
import signal
import socket
import subprocess
import tempfile
import time
from pathlib import Path

import httpx
from bb_auth_contract.chat import LocalEventPage, ReadResult

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--client", required=True)
parser.add_argument("--runtime", required=True)
parser.add_argument("--dart", required=True)
parser.add_argument("--crypto", required=True)
args = parser.parse_args()
client = Path(args.client).resolve()
client_sha = subprocess.check_output(
    ["git", "-C", str(client), "rev-parse", "HEAD"], text=True
).strip()
assert client_sha == "c684e29371b0236dadecb05f8ff18802175502ef", (
    "Re-review/update this pinned client test before using another revision"
)
root = Path(tempfile.mkdtemp(prefix="r3-live-", dir=HERE.parent / ".evidence"))
private = root / "private"
private.mkdir()
results = []
owned = []
daemon_pid = json.loads(
    subprocess.check_output(
        [os.environ["MULTICA_CLI_PATH"], "daemon", "status", "--output", "json"]
    )
)["pid"]


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def launch(command, name, env=None):
    log = open(root / (name + ".log"), "w")  # noqa: SIM115 - owned until process teardown in finally
    process = subprocess.Popen(
        command,
        cwd=REPO,
        env=env,
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    owned.append((process, log))
    return process


def stop(process):
    # Only the exact new process group that this runner created, never daemon/name.
    assert process.pid != daemon_pid
    try:
        assert os.getpgid(daemon_pid) != process.pid
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)


def wait_http(origin, process):
    for _ in range(150):
        assert process.poll() is None, f"startup exited {process.returncode}"
        try:
            httpx.get(origin + "/", timeout=0.2)
            return
        except httpx.TransportError:
            time.sleep(0.1)
    raise AssertionError("HTTP startup timed out")


def post(origin, path, body, headers=None):
    return httpx.post(origin + path, json=body, headers=headers, timeout=15)


def check(name, condition, detail):
    results.append({"name": name, "pass": bool(condition), "detail": detail})
    print(json.dumps(results[-1]), flush=True)


try:
    api_port, local_port = free_port(), free_port()
    api, local = f"http://127.0.0.1:{api_port}", f"http://127.0.0.1:{local_port}"
    env = dict(
        os.environ,
        BB_DATABASE_PATH=str(private / "api.db"),
        BB_AVATAR_DIRECTORY=str(private / "avatars"),
        BB_MEDIA_DIRECTORY=str(private / "media"),
        BB_HOST="127.0.0.1",
        BB_PORT=str(api_port),
    )
    server = launch(
        [str(REPO / "server/.venv/bin/python"), "-m", "bb_server"], "server", env
    )
    wait_http(api, server)
    accounts = []
    for name in ("SyntheticAlice", "SyntheticBob"):
        value = post(api, "/auth/register", {"username": name, "password": "Abc123"})
        assert value.status_code == 201, value.status_code
        accounts.append(value.json()["account"])
    account, peer = accounts
    token = post(api, "/auth/login", {"account": peer, "password": "Abc123"}).json()[
        "token"
    ]
    peer_headers = {"Authorization": "Bearer " + token}
    config = private / "package_config.json"
    config.write_text(
        json.dumps(
            {
                "configVersion": 2,
                "packages": [
                    {
                        "name": "bb_client",
                        "rootUri": client.as_uri() + "/",
                        "packageUri": "lib/",
                        "languageVersion": "3.13",
                    },
                    {
                        "name": "crypto",
                        "rootUri": Path(args.crypto).resolve().as_uri() + "/",
                        "packageUri": "lib/",
                        "languageVersion": "3.4",
                    },
                ],
            }
        )
    )
    command = [
        args.dart,
        "--packages=" + str(config),
        str(client / "bin/bb_client_api.dart"),
        "--port",
        str(local_port),
        "--server-url",
        api,
        "--session-file",
        str(private / "dart/session.json"),
    ]
    dart = launch(command, "dart-first")
    wait_http(local, dart)
    assert (
        post(
            local, "/auth/login", {"account": account, "password": "Abc123"}
        ).status_code
        == 200
    )
    for session in ("live-events", "live-mcp", "live-continuation", "conflict-test"):
        assert (
            post(
                local,
                "/events/subscribe",
                {"consumer_session": session, "peer_account": peer},
            ).status_code
            == 200
        )
    for index in (1, 2):
        value = post(
            api,
            "/messages",
            {
                "target_account": account,
                "client_nonce": "incoming-" + str(index),
                "content": [
                    {"type": "text", "text": "synthetic incoming " + str(index)}
                ],
            },
            peer_headers,
        )
        assert value.status_code == 200

    def worker(phase, session, kill=False):
        cmd = [
            "node",
            str(HERE / "live-worker-r3.mjs"),
            str(Path(args.runtime).resolve()),
            str(root),
            local,
            account,
            peer,
            phase,
            session,
        ]
        if not kill:
            process = launch(cmd, session + "-" + phase)
            try:
                code = process.wait(timeout=60)
            finally:
                stop(process)
            check(session + ":" + phase, code == 0, {"exit": code})
            return code
        process = subprocess.Popen(
            cmd,
            cwd=REPO,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        owned.append((process, None))
        captured = b""
        deadline = time.monotonic() + 60
        try:
            while time.monotonic() < deadline and process.poll() is None:
                if select.select([process.stdout], [], [], 0.2)[0]:
                    captured += os.read(process.stdout.fileno(), 65536)
                    if b"KILL_CHECKPOINT" in captured:
                        assert (
                            process.pid != daemon_pid
                            and os.getpgid(daemon_pid) != process.pid
                        )
                        os.killpg(process.pid, signal.SIGKILL)
                        break
            process.wait(timeout=5)
        finally:
            stop(process)
            (root / (session + "-" + phase + ".log")).write_bytes(captured)
        check(
            "SIGKILL after actual business commit",
            process.returncode == -9 and b"KILL_CHECKPOINT" in captured,
            {"exit": process.returncode},
        )

    worker("control", "live-mcp")
    ack = post(
        local,
        "/chat/ack_messages",
        {"account": peer, "consumer_session": "live-mcp", "through_position": 1},
    )
    check(
        "actual receipt -> native MCP -> confirm -> explicit ACK",
        ack.status_code == 200 and ack.json().get("consumed_through") == 1,
        {"status": ack.status_code},
    )
    gap = post(
        local,
        "/chat/ack_messages",
        {"account": peer, "consumer_session": "live-mcp", "through_position": 2},
    )
    check(
        "unpresented B blocks ACK2", gap.status_code == 409, {"status": gap.status_code}
    )
    worker("control", "live-events")
    before_restart = post(
        local,
        "/events/read",
        {"consumer_session": "live-events", "after_cursor": 0, "limit": 50},
    ).json()
    LocalEventPage.model_validate(before_restart)
    worker("operation-after-submit-before-receipt", "live-continuation", True)
    stop(dart)
    dart = launch(command, "dart-restarted")
    wait_http(local, dart)
    after_restart = post(
        local,
        "/events/read",
        {"consumer_session": "live-events", "after_cursor": 0, "limit": 50},
    ).json()
    check(
        "Dart event page survives process restart",
        before_restart == after_restart,
        {"events": len(after_restart["items"])},
    )
    worker("recover", "live-continuation")
    worker("replay", "live-continuation")
    worker("replay", "live-continuation")
    page = httpx.get(
        api + f"/conversations/{account}/messages", headers=peer_headers
    ).json()
    outputs = [m for m in page["items"] if m["sender_account"] == account]
    check(
        "continuation and repeated restart preserve one original output",
        len(outputs) == 1,
        {"outputs": len(outputs)},
    )
    wait = post(
        local,
        "/events/wait",
        {
            "consumer_session": "live-events",
            "after_cursor": 0,
            "limit": 50,
            "timeout": 30,
        },
    )
    check(
        "R3 events/wait accepts inherited limit",
        wait.status_code == 200,
        {"status": wait.status_code, "body": wait.json()},
    )
    visible = post(
        local,
        "/chat/read_messages",
        {
            "account": peer,
            "consumer_session": "conflict-test",
            "after_position": 0,
            "limit": 2,
        },
    ).json()
    ReadResult.model_validate(visible)
    check(
        "actual Dart read/event responses validate shared R3 models",
        True,
        {"models": ["ReadResult", "LocalEventPage"]},
    )
    receipts = [item["presentation"]["receipt_id"] for item in visible["items"]]
    base = {
        "consumer_session": "conflict-test",
        "attempt_id": "stable-attempt",
        "request_digest": "request-A",
        "receipt_ids": receipts[:1],
    }
    assert post(local, "/chat/confirm_presentation", base).status_code == 200
    conflict = post(
        local,
        "/chat/confirm_presentation",
        {**base, "request_digest": "different-request", "receipt_ids": receipts[1:]},
    )
    check(
        "changed attempt membership/digest rejected",
        conflict.status_code == 409,
        {"status": conflict.status_code},
    )
    gap = post(
        local,
        "/chat/ack_messages",
        {"account": peer, "consumer_session": "conflict-test", "through_position": 2},
    )
    check(
        "rejected confirmation cannot enable ACK",
        gap.status_code == 409,
        {"status": gap.status_code},
    )
    wrong = post(
        local,
        "/chat/confirm_presentation",
        {**base, "consumer_session": "different-session"},
    )
    check(
        "same-account session identity conflict is 409",
        wrong.status_code == 409,
        {"status": wrong.status_code},
    )
    # Subscribing after another consumer has drained source events must still expose backlog.
    assert (
        post(
            local,
            "/events/subscribe",
            {"consumer_session": "late-consumer", "peer_account": peer},
        ).status_code
        == 200
    )
    time.sleep(2.2)
    late = post(
        local,
        "/events/read",
        {"consumer_session": "late-consumer", "after_cursor": 0, "limit": 50},
    ).json()
    check(
        "new consumer can recover existing incoming backlog",
        len(late.get("items", [])) == 2,
        {"items": len(late.get("items", []))},
    )
    (root / "wire-responses.json").write_text(
        json.dumps(
            {
                "visible": visible,
                "events": after_restart,
                "wait": wait.json(),
                "late": late,
            },
            indent=2,
        )
    )
finally:
    for process, log in reversed(owned):
        stop(process)
        if log:
            log.close()
    (root / "summary.json").write_text(
        json.dumps(
            {
                "checks": results,
                "client_sha": client_sha,
                "provider": "deterministic double",
                "real": "FastAPI, SQLite, unmodified Dart, Python MCP, native DSH/Cordis/JSONL",
            },
            indent=2,
        )
    )
    print(
        json.dumps(
            {"evidence": str(root), "failures": sum(not r["pass"] for r in results)}
        ),
        flush=True,
    )
raise SystemExit(1 if any(not r["pass"] for r in results) else 0)
