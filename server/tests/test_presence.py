import hashlib
import sqlite3
import threading
import time
from concurrent.futures import ThreadPoolExecutor

from fastapi.testclient import TestClient
from test_profile import login

from bb_server.app import create_app
from bb_server.storage import cleanup_sessions


def test_heartbeat_offline_recovery_and_logout(tmp_path):
    now = [2_000_000_000.0]
    path = tmp_path / "auth.db"
    with TestClient(create_app(path, clock=lambda: now[0])) as api:
        _, headers = login(api)
        assert api.post("/auth/heartbeat", headers=headers).json()["status"] == "online"
        now[0] += 90
        assert api.get("/auth/session", headers=headers).status_code == 200
        with sqlite3.connect(path) as db:
            assert db.execute("SELECT status FROM sessions").fetchone()[0] == "offline"
        assert api.post("/auth/heartbeat", headers=headers).json()["status"] == "online"
        assert api.post("/auth/logout", headers=headers).status_code == 204
        assert api.get("/auth/session", headers=headers).status_code == 401
        with sqlite3.connect(path) as db:
            assert db.execute("SELECT count(*) FROM sessions").fetchone()[0] == 0


def test_offline_expiration_boundary_and_active_session_isolation(tmp_path):
    now = [2_000_000_000.0]
    path = tmp_path / "auth.db"
    with TestClient(create_app(path, clock=lambda: now[0])) as api:
        _, first = login(api)
        _, second = login(api)
        now[0] += 89
        cleanup_sessions(path, now[0])
        with sqlite3.connect(path) as db:
            assert db.execute("SELECT DISTINCT status FROM sessions").fetchall() == [
                ("online",)
            ]
        now[0] += 1
        cleanup_sessions(path, now[0])
        with sqlite3.connect(path) as db:
            assert db.execute(
                "SELECT DISTINCT status,offline_since FROM sessions"
            ).fetchall() == [("offline", now[0])]
        # Exactly 24h offline is retained, then only the heartbeat sender recovers.
        now[0] += 86400
        assert api.get("/auth/session", headers=first).status_code == 200
        assert api.post("/auth/heartbeat", headers=second).status_code == 200
        now[0] += 0.001
        assert api.post("/auth/heartbeat", headers=first).status_code == 401
        assert api.get("/auth/session", headers=second).status_code == 200
        with sqlite3.connect(path) as db:
            assert db.execute(
                "SELECT status,offline_since FROM sessions"
            ).fetchall() == [("online", None)]


def test_periodic_task_marks_offline_and_deletes_without_api_request(
    tmp_path, monkeypatch
):
    import bb_server.app as app_module

    now = [2_000_000_000.0]
    path = tmp_path / "auth.db"
    completed = threading.Event()

    def observe(database, timestamp):
        cleanup_sessions(database, timestamp)
        if timestamp == now[0]:
            completed.set()

    monkeypatch.setattr(app_module, "cleanup_sessions", observe)
    with TestClient(
        create_app(path, clock=lambda: now[0], maintenance_interval=0.02)
    ) as api:
        login(api)
        now[0] += 90
        completed.clear()
        assert completed.wait(timeout=3)
        with sqlite3.connect(path) as db:
            assert db.execute("SELECT status FROM sessions").fetchone()[0] == "offline"
        now[0] += 86401
        completed.clear()
        assert completed.wait(timeout=3)
        with sqlite3.connect(path) as db:
            assert db.execute("SELECT count(*) FROM sessions").fetchone()[0] == 0


def test_maintenance_retries_storage_failure_without_losing_session(
    tmp_path, monkeypatch
):
    import bb_server.app as app_module

    now = [time.time()]
    path = tmp_path / "auth.db"
    failed = threading.Event()
    recovered = threading.Event()
    attempts = []

    def intermittent(database, timestamp):
        attempts.append(timestamp)
        if len(attempts) == 2:
            failed.set()
            raise sqlite3.OperationalError("fake failure")
        cleanup_sessions(database, timestamp)
        if len(attempts) > 2:
            recovered.set()

    monkeypatch.setattr(app_module, "cleanup_sessions", intermittent)
    with TestClient(
        create_app(path, clock=lambda: now[0], maintenance_interval=0.1)
    ) as api:
        _, headers = login(api)
        assert failed.wait(timeout=3)
        assert recovered.wait(timeout=3)
        assert api.get("/auth/session", headers=headers).status_code == 200


def test_expired_heartbeat_racing_cleanup_cannot_resurrect(tmp_path):
    now = [2_000_000_000.0]
    path = tmp_path / "auth.db"
    with TestClient(create_app(path, clock=lambda: now[0])) as api:
        _, headers = login(api)
        now[0] += 90 + 86401
        with ThreadPoolExecutor(max_workers=2) as pool:
            cleanup = pool.submit(cleanup_sessions, path, now[0])
            response = pool.submit(api.post, "/auth/heartbeat", headers=headers)
            cleanup.result()
            assert response.result().status_code == 401
        assert api.get("/auth/session", headers=headers).status_code == 401


def test_logout_only_deletes_present_session_and_offline_survives_restart(tmp_path):
    now = [2_000_000_000.0]
    path = tmp_path / "auth.db"
    with TestClient(create_app(path, clock=lambda: now[0])) as api:
        account, first = login(api)
        token = api.post(
            "/auth/login", json={"account": account, "password": "Abc123"}
        ).json()["token"]
        second = {"Authorization": "Bearer " + token}
        assert api.post("/auth/logout", headers=first).status_code == 204
        assert api.post("/auth/logout", headers=first).status_code == 401
        assert api.post("/auth/heartbeat").status_code == 401
    now[0] += 120
    with TestClient(create_app(path, clock=lambda: now[0])) as api:
        assert api.get("/auth/session", headers=second).status_code == 200
        with sqlite3.connect(path) as db:
            assert db.execute("SELECT token_hash,status FROM sessions").fetchone() == (
                hashlib.sha256(token.encode()).hexdigest(),
                "offline",
            )
        assert api.post("/auth/heartbeat", headers=second).status_code == 200
