"""Run Sentinel's unchanged load with SQL/HTTP observation and optional bounded recovery.

Only relocates the fixture's HERE path and adds post-load checks. No reduction of
122 messages, 8 workers, HTTP/SQLite timeouts or original five assertions.
Use server's uv environment. Pass original runner arguments after '--'.
"""

import argparse
import hashlib
import json
import os
import sqlite3
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import httpx

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--evidence", type=Path, required=True)
parser.add_argument("--recover", action="store_true")
parser.add_argument("runner_args", nargs=argparse.REMAINDER)
args = parser.parse_args()
args.evidence.mkdir(parents=True, exist_ok=False)
evidence = args.evidence.resolve()
os.environ["BB_SQL_TRACE"] = str(evidence / "sql.jsonl")
os.environ["PYTHONPATH"] = str(HERE / "sql_trace")
raw_post = httpx.post
http_log = []
log_lock = threading.Lock()


def record(kind, nonce, response, started, error=None):
    entry = {
        "kind": kind,
        "nonce": nonce,
        "status": response.status_code if response is not None else None,
        "ms": round((time.monotonic() - started) * 1000, 3),
        "error": error,
    }
    with log_lock:
        http_log.append(entry)
        with (evidence / "http.jsonl").open("a") as stream:
            stream.write(json.dumps(entry) + "\n")


def request_send(url, kwargs, kind):
    started = time.monotonic()
    nonce = kwargs["json"]["client_nonce"]
    try:
        response = raw_post(url, **kwargs)
        record(kind, nonce, response, started)
        return response
    except httpx.TransportError as exc:
        record(kind, nonce, None, started, type(exc).__name__)
        if not args.recover:
            raise
        return None


def reconcile_send(url, kwargs, response):
    nonce = kwargs["json"]["client_nonce"]
    # At most three reconciliation rounds, each with at most one same-key send.
    # Unknown query results never authorize another submission in that round.
    for delay in (0.05, 0.1, 0.2):
        if response is not None and response.status_code not in (502, 503, 504):
            return response
        time.sleep(delay)
        started = time.monotonic()
        try:
            query = httpx.get(
                url.removesuffix("/messages") + "/operations/" + nonce,
                headers=kwargs["headers"],
                timeout=15,
            )
        except httpx.TransportError as exc:
            record("query", nonce, None, started, type(exc).__name__)
            continue
        record("query", nonce, query, started)
        if query.status_code == 200:
            value = query.json()
            assert value["operation_id"] == nonce and value["status"] == "succeeded"
            return httpx.Response(200, json=value["message"], request=query.request)
        if query.status_code == 404:
            response = request_send(url, kwargs, "retry")
        elif query.status_code not in (502, 503, 504):
            return query
    if response is None:
        raise RuntimeError("Bounded recovery exhausted with unknown result")
    return response


def observed_post(url, **kwargs):
    if not str(url).endswith("/messages"):
        return raw_post(url, **kwargs)
    response = request_send(url, kwargs, "initial")
    return reconcile_send(url, kwargs, response) if args.recover else response


def verify_facts(namespace):
    private = namespace["private"]
    with sqlite3.connect(private / "api.db") as db:
        counts = {
            table: db.execute(f"SELECT count(*) FROM {table}").fetchone()[0]
            for table in ("messages", "operations", "events")
        }
        assert counts == {"messages": 122, "operations": 122, "events": 244}, counts
        assert (
            db.execute(
                "SELECT count(*) FROM (SELECT account,operation_id FROM operations GROUP BY account,operation_id HAVING count(*)!=1)"
            ).fetchone()[0]
            == 0
        )
        assert (
            db.execute(
                "SELECT count(*) FROM (SELECT account,message_id FROM events GROUP BY account,message_id HAVING count(*)!=1)"
            ).fetchone()[0]
            == 0
        )
        assert [
            r[0] for r in db.execute("SELECT position FROM messages ORDER BY position")
        ] == list(range(1, 123))
    return counts


def finish_probe(namespace):
    before = verify_facts(namespace)
    api, token, target = namespace["api"], namespace["t"], namespace["account"]
    headers = {"Authorization": "Bearer " + token}
    # Query an already committed message before concurrent same-nonce replay.
    known = httpx.get(api + "/operations/qa-backfill-0", headers=headers, timeout=15)
    assert known.status_code == 200
    payload = {
        "target_account": target,
        "client_nonce": "qa-backfill-0",
        "content": [{"type": "text", "text": "item 0"}],
    }
    with ThreadPoolExecutor(max_workers=8) as pool:
        replies = list(
            pool.map(
                lambda _: observed_post(
                    api + "/messages", json=payload, headers=headers, timeout=15
                ),
                range(8),
            )
        )
    assert all(
        r.status_code == 200 and r.json() == known.json()["message"] for r in replies
    )
    assert verify_facts(namespace) == before
    # Actual reserved writer lock forces a bounded failed submit. No fake DB rows.
    payload = {
        **payload,
        "client_nonce": "lock-recovery",
        "content": [{"type": "text", "text": "lock recovery"}],
    }
    kwargs = {"json": payload, "headers": headers, "timeout": 15}
    blocker = sqlite3.connect(namespace["private"] / "api.db")
    try:
        blocker.execute("BEGIN IMMEDIATE")
        failed = request_send(api + "/messages", kwargs, "injected-lock")
        assert failed.status_code == 503
        query = httpx.get(
            api + "/operations/lock-recovery", headers=headers, timeout=15
        )
        assert query.status_code == 404
    finally:
        blocker.rollback()
        blocker.close()
    recovered = reconcile_send(api + "/messages", kwargs, failed)
    assert recovered.status_code == 200
    # Simulate loss of a committed HTTP receipt at the caller, then query first.
    payload = {
        **payload,
        "client_nonce": "lost-receipt",
        "content": [{"type": "text", "text": "lost receipt"}],
    }
    kwargs = {"json": payload, "headers": headers, "timeout": 15}
    discarded = request_send(api + "/messages", kwargs, "discarded-success")
    assert discarded.status_code == 200
    recovered = reconcile_send(api + "/messages", kwargs, None)
    assert recovered.status_code == 200 and recovered.json() == discarded.json()
    with sqlite3.connect(namespace["private"] / "api.db") as db:
        final = {
            table: db.execute(f"SELECT count(*) FROM {table}").fetchone()[0]
            for table in before
        }
    assert final == {"messages": 124, "operations": 124, "events": 248}, final
    namespace["check"](
        "bounded retry, lost receipt and 8-way replay retain one message/two account events",
        True,
        {"load": before, "after_two_fault_cases": final},
    )


source = (HERE / "fixtures/sentinel_qa_r3_extra.py").read_text()
assert (
    hashlib.sha256(source.encode()).hexdigest()
    == "df730d267e8d1c1c58c071656af03f8ba66465d7243dcc470f0854e7c4b4d1e5"
)
old = "HERE = Path(__file__).resolve().parent / 'BB/dsh-plugin/runtime-patch'"
assert source.count(old) == 1
source = source.replace(old, f"HERE = Path({str(REPO / 'dsh-plugin/runtime-patch')!r})")
assert source.count("\nfinally:\n") == 1
source = source.replace("\nfinally:\n", "\n    finish_probe(globals())\nfinally:\n")
runner_args = (
    args.runner_args[1:] if args.runner_args[:1] == ["--"] else args.runner_args
)
sys.argv = [str(HERE / "fixtures/sentinel_qa_r3_extra.py"), *runner_args]
httpx.post = observed_post
namespace = {
    "__name__": "__main__",
    "__file__": str(HERE / "fixtures/sentinel_qa_r3_extra.py"),
    "finish_probe": finish_probe,
}
try:
    exec(compile(source, sys.argv[0], "exec"), namespace)  # noqa: S102 - reviewed, vendored fixture
finally:
    httpx.post = raw_post
    (evidence / "summary.json").write_text(
        json.dumps(
            {
                "bounded_recovery": args.recover,
                "requests": http_log,
                "checks": namespace.get("results", []),
                "runner_evidence": str(namespace.get("root", "")),
            },
            indent=2,
        )
    )
