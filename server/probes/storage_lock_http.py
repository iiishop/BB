"""Real HTTP + independent SQLite lock holder; no client/model or fake database.

Run with server's uv environment. Private credentials/database are not evidence.
No expected success assertion: retain before/after outcomes in summary.json.
"""

import argparse
import json
import os
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

import httpx

LOCKER = """
import sqlite3,sys
db=sqlite3.connect(sys.argv[1]);db.execute('BEGIN IMMEDIATE')
print('LOCKED',flush=True)
sys.stdin.readline()
db.rollback();db.close()
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--data-parent", type=Path)
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=False)
    evidence = args.evidence.resolve()
    private = Path(
        tempfile.mkdtemp(prefix="bb-storage-", dir=args.data_parent or evidence)
    )
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    origin = f"http://127.0.0.1:{port}"
    db = private / "data.db"
    env = dict(
        os.environ,
        BB_DATABASE_PATH=str(db),
        BB_AVATAR_DIRECTORY=str(private / "avatars"),
        BB_MEDIA_DIRECTORY=str(private / "media"),
        BB_HOST="127.0.0.1",
        BB_PORT=str(port),
    )
    results = []
    log = (evidence / "server.log").open("w")
    server = subprocess.Popen(
        [sys.executable, "-m", "bb_server"],
        env=env,
        stdout=log,
        stderr=subprocess.STDOUT,
    )
    try:
        with httpx.Client(base_url=origin, timeout=12) as api:
            for _ in range(100):
                if server.poll() is not None:
                    raise RuntimeError("server failed")
                try:
                    api.get("/")
                    break
                except httpx.TransportError:
                    time.sleep(0.05)
            account = api.post(
                "/auth/register",
                json={"username": "SyntheticAlice", "password": "Abc123"},
            ).json()["account"]
            peer = api.post(
                "/auth/register",
                json={"username": "SyntheticBob", "password": "Abc123"},
            ).json()["account"]
            login = {"account": account, "password": "Abc123"}
            token = api.post("/auth/login", json=login).json()["token"]
            headers = {"Authorization": "Bearer " + token}
            index = 0
            for hold in [None, 1.5]:
                for route in ["/auth/login", "/users", "/messages"]:
                    for repeat in range(3):
                        index += 1
                        locker = subprocess.Popen(
                            [sys.executable, "-c", LOCKER, str(db)],
                            stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE,
                            text=True,
                        )
                        assert locker.stdout.readline().strip() == "LOCKED"
                        timer = None

                        def release(child=locker):
                            if child.poll() is None:
                                try:
                                    child.stdin.write("\n")
                                    child.stdin.flush()
                                except BrokenPipeError:
                                    pass

                        if hold is not None:
                            timer = threading.Timer(hold, release)
                            timer.start()
                        try:
                            started = time.monotonic()
                            if route == "/auth/login":
                                response = api.post(route, json=login)
                            elif route == "/users":
                                response = api.get(route, headers=headers)
                            else:
                                response = api.post(
                                    route,
                                    headers=headers,
                                    json={
                                        "target_account": peer,
                                        "client_nonce": f"lock-{index}",
                                        "content": [
                                            {"type": "text", "text": "synthetic"}
                                        ],
                                    },
                                )
                            results.append(
                                {
                                    "route": route,
                                    "repeat": repeat,
                                    "hold_seconds": hold,
                                    "status": response.status_code,
                                    "error_code": response.json()
                                    .get("error", {})
                                    .get("code"),
                                    "seconds": round(time.monotonic() - started, 4),
                                }
                            )
                            print(json.dumps(results[-1]), flush=True)
                        finally:
                            if timer:
                                timer.cancel()
                                timer.join()
                            release()
                            locker.communicate(timeout=3)
            # Owner-shaped control: 14 concurrent callers, 15 seconds, mixed routes.
            from concurrent.futures import ThreadPoolExecutor

            until = time.monotonic() + 15

            def worker(n):
                counts = {}
                k = 0
                with httpx.Client(base_url=origin, timeout=12) as client:
                    while time.monotonic() < until:
                        k += 1
                        route = ["/messages", "/users", "/auth/session"][k % 3]
                        if route == "/messages":
                            r = client.post(
                                route,
                                headers=headers,
                                json={
                                    "target_account": peer,
                                    "client_nonce": f"control-{n}-{k}",
                                    "content": [{"type": "text", "text": "control"}],
                                },
                            )
                        else:
                            r = client.get(route, headers=headers)
                        key = f"{route}:{r.status_code}"
                        counts[key] = counts.get(key, 0) + 1
                return counts

            with ThreadPoolExecutor(max_workers=14) as pool:
                totals = {}
                for counts in pool.map(worker, range(14)):
                    for key, count in counts.items():
                        totals[key] = totals.get(key, 0) + count
            with sqlite3.connect(db) as conn:
                database = {
                    t: conn.execute(f"SELECT count(*) FROM {t}").fetchone()[0]
                    for t in ["messages", "operations", "events"]
                }
                journal = conn.execute("PRAGMA journal_mode").fetchone()[0]
            fs = subprocess.check_output(
                ["findmnt", "-T", str(db), "-no", "FSTYPE"], text=True
            ).strip()
            (evidence / "summary.json").write_text(
                json.dumps(
                    {
                        "holds": results,
                        "control_14_threads_15_seconds": totals,
                        "database": database,
                        "filesystem": fs,
                        "sqlite": sqlite3.sqlite_version,
                        "journal_mode": journal,
                    },
                    indent=2,
                )
            )
    finally:
        if server.poll() is None:
            cli = os.environ.get("MULTICA_CLI_PATH")
            if cli:
                status = json.loads(
                    subprocess.check_output(
                        [cli, "daemon", "status", "--output", "json"], text=True
                    )
                )
                assert server.pid != status["pid"]
            server.terminate()
        server.wait(timeout=10)
        log.close()


if __name__ == "__main__":
    main()
