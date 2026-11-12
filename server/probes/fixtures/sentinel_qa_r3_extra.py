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

HERE = Path(__file__).resolve().parent / 'BB/dsh-plugin/runtime-patch'
REPO = HERE.parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--client", required=True)
parser.add_argument(
    "--expected-client-sha",
    required=True,
    help="Full reviewed commit of the client checkout (no implicit HEAD pin)",
)
parser.add_argument("--runtime", required=True)
parser.add_argument("--dart", required=True)
parser.add_argument("--crypto", required=True)
args = parser.parse_args()
client = Path(args.client).resolve()
client_sha = subprocess.check_output(
    ["git", "-C", str(client), "rev-parse", "HEAD"], text=True
).strip()
if len(args.expected_client_sha) != 40 or client_sha != args.expected_client_sha:
    parser.error("Client HEAD does not match the explicitly reviewed full SHA")
if subprocess.check_output(
    ["git", "-C", str(client), "status", "--porcelain", "--", "."], text=True
).strip():
    parser.error("Client working tree must be clean for a pinned integration run")
evidence_parent = HERE.parent / ".evidence"
evidence_parent.mkdir(exist_ok=True)
root = Path(tempfile.mkdtemp(prefix="r3-live-", dir=evidence_parent))
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


def signal_owned_group(process, signum):
    # Only groups launched with start_new_session by this runner are eligible.
    assert any(child is process for child, _ in owned)
    assert process.pid != daemon_pid
    try:
        daemon_group = os.getpgid(daemon_pid)
    except ProcessLookupError:
        daemon_group = None
    assert daemon_group != process.pid
    try:
        os.killpg(process.pid, signum)
    except ProcessLookupError:
        pass


def stop(process):
    signal_owned_group(process, signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        signal_owned_group(process, signal.SIGKILL)
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
    from concurrent.futures import ThreadPoolExecutor
    third = post(api, "/auth/register", {"username":"QA backlog peer","password":"Abc123"}).json()["account"]
    t = post(api, "/auth/login", {"account":third,"password":"Abc123"}).json()["token"]
    def send_one(n):
        response = post(api, "/messages", {"target_account":account,"client_nonce":"qa-backfill-"+str(n),"content":[{"type":"text","text":"item "+str(n)}]}, {"Authorization":"Bearer "+t})
        assert response.status_code == 200, (response.status_code, response.text)
    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(send_one, range(120)))
        future = pool.submit(post, local, "/events/subscribe", {"consumer_session":"qa-backfill","peer_account":third})
        list(pool.map(send_one, range(120,122)))
        assert future.result().status_code == 200
    def all_events():
        items=[];cursor=0
        while True:
            page=post(local,"/events/read",{"consumer_session":"qa-backfill","after_cursor":cursor,"limit":50}).json()
            items.extend(page["items"]);cursor=page["next_cursor"]
            if not page["has_more"]:return items
    for _ in range(100):
        items=all_events()
        if len(items)==122:break
        time.sleep(.1)
    check("122-event paged registration concurrent arrival",len(items)==122 and len({i["event"]["event_id"] for i in items})==122,{"events":len(items)})
    before=items
    assert post(local,"/events/subscribe",{"consumer_session":"qa-backfill","peer_account":third}).status_code==200
    stop(dart);dart=launch(command,"dart-qa-backfill-restart");wait_http(local,dart)
    check("backfill repeat subscribe and Dart restart preserve exact feed",all_events()==before,{"events":len(all_events())})
    visible=post(local,"/chat/read_messages",{"account":third,"consumer_session":"qa-atomic","after_position":0,"limit":2}).json()
    receipts=[i["presentation"]["receipt_id"] for i in visible["items"]]
    invalid={"consumer_session":"qa-atomic","attempt_id":"qa-bad-group","request_digest":"qa-digest","receipt_ids":[receipts[0],"unknown-receipt"]}
    rejected=post(local,"/chat/confirm_presentation",invalid)
    gap=post(local,"/chat/ack_messages",{"account":third,"consumer_session":"qa-atomic","through_position":1})
    check("one invalid receipt rejects whole group without ACK side effect",rejected.status_code==404 and gap.status_code==409,{"confirm":rejected.status_code,"ack":gap.status_code})
    valid={"consumer_session":"qa-atomic","attempt_id":"qa-good-group","request_digest":"qa-digest","receipt_ids":receipts}
    with ThreadPoolExecutor(max_workers=12) as pool:
        codes=[r.status_code for r in pool.map(lambda _:post(local,"/chat/confirm_presentation",valid),range(12))]
    check("12 concurrent identical confirmations",codes==[200]*12,{"codes":codes})
    stop(dart);dart=launch(command,"dart-qa-confirm-restart");wait_http(local,dart)
    again=post(local,"/chat/confirm_presentation",valid)
    ack=post(local,"/chat/ack_messages",{"account":third,"consumer_session":"qa-atomic","through_position":2})
    check("confirmation idempotency after restart then explicit ACK",again.status_code==200 and ack.status_code==200,{"confirm":again.status_code,"ack":ack.status_code})
    (root/"qa-extra-wire.json").write_text(json.dumps({"checks":results,"events":items},indent=2))

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
