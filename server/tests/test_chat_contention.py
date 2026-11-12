"""Bounded lock failure, reconciliation and nonce replay with real SQLite locks."""

import sqlite3
from concurrent.futures import ThreadPoolExecutor

from fastapi.testclient import TestClient
from test_profile import login

from bb_server.app import create_app


def test_auth_read_during_writer_and_message_retry_is_atomic(tmp_path):
    path = tmp_path / "chat.db"
    with TestClient(create_app(path, maintenance_interval=60)) as api:
        sender, headers = login(api, "Sender")
        peer, _ = login(api, "Receiver")
        body = {
            "target_account": peer,
            "client_nonce": "stable-nonce",
            "content": [{"type": "text", "text": "one output"}],
        }
        blocker = sqlite3.connect(path)
        try:
            blocker.execute("BEGIN IMMEDIATE")
            # A reserved writer lock allows reads; authentication must not turn
            # every read into another writer while there is no maintenance due.
            assert api.get("/auth/session", headers=headers).status_code == 200
            blocked = api.post("/messages", headers=headers, json=body)
            assert blocked.status_code == 503
            assert blocked.json()["error"]["code"] == "storage_unavailable"
            assert (
                api.get("/operations/stable-nonce", headers=headers).status_code == 404
            )
        finally:
            blocker.rollback()
            blocker.close()
        # One bounded retry after reconciliation, then concurrent same-key replay.
        first = api.post("/messages", headers=headers, json=body)
        assert first.status_code == 200
        with ThreadPoolExecutor(max_workers=8) as pool:
            replies = list(
                pool.map(
                    lambda _: api.post("/messages", headers=headers, json=body),
                    range(8),
                )
            )
        assert all(r.status_code == 200 and r.json() == first.json() for r in replies)
        # Discard a successful response: query before retrying an unknown result.
        known = api.get("/operations/stable-nonce", headers=headers)
        assert known.status_code == 200 and known.json()["message"] == first.json()
        assert (
            api.post(
                "/messages",
                headers=headers,
                json={**body, "content": [{"type": "text", "text": "changed"}]},
            ).status_code
            == 409
        )
        with sqlite3.connect(path) as db:
            assert db.execute("SELECT count(*) FROM messages").fetchone()[0] == 1
            assert db.execute("SELECT count(*) FROM operations").fetchone()[0] == 1
            assert db.execute(
                "SELECT account,count(*) FROM events GROUP BY account ORDER BY account"
            ).fetchall() == [(a, 1) for a in sorted([sender, peer])]


def test_due_maintenance_remains_atomic_and_expiry_cannot_be_skipped(tmp_path):
    now = [2_000_000_000.0]
    path = tmp_path / "chat.db"
    with TestClient(
        create_app(path, clock=lambda: now[0], maintenance_interval=60)
    ) as api:
        _, headers = login(api)
        now[0] += 90
        blocker = sqlite3.connect(path)
        try:
            blocker.execute("BEGIN IMMEDIATE")
            assert api.get("/auth/session", headers=headers).status_code == 503
        finally:
            blocker.rollback()
            blocker.close()
        assert api.get("/auth/session", headers=headers).status_code == 200
        with sqlite3.connect(path) as db:
            assert db.execute(
                "SELECT status,offline_since FROM sessions"
            ).fetchone() == ("offline", now[0])
        now[0] += 86400
        assert api.get("/auth/session", headers=headers).status_code == 200
        now[0] += 0.001
        assert api.post("/auth/heartbeat", headers=headers).status_code == 401
        with sqlite3.connect(path) as db:
            assert db.execute("SELECT count(*) FROM sessions").fetchone()[0] == 0
