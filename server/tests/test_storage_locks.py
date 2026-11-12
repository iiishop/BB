"""Deterministic lock ownership in another process, not lucky load timing."""

import errno
import logging
import sqlite3
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager

import pytest
from fastapi.testclient import TestClient
from test_profile import login

from bb_server import app as app_module
from bb_server import storage
from bb_server.app import create_app


@contextmanager
def external_lock(path, mode="IMMEDIATE"):
    script = """
import sqlite3,sys
db=sqlite3.connect(sys.argv[1])
db.execute('BEGIN '+sys.argv[2])
db.execute('SELECT count(*) FROM users').fetchone()
print('LOCKED',flush=True)
sys.stdin.readline()
db.rollback();db.close()
"""
    child = subprocess.Popen(
        [sys.executable, "-c", script, str(path), mode],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    )
    assert child.stdout.readline().strip() == "LOCKED"
    released = threading.Event()

    def release():
        if not released.is_set():
            child.communicate("\n", timeout=5)
            assert child.returncode == 0
            released.set()

    try:
        yield release
    finally:
        release()


def test_users_read_succeeds_with_external_writer(tmp_path):
    path = tmp_path / "db"
    with TestClient(create_app(path, maintenance_interval=60)) as api:
        _, headers = login(api)
        peer, _ = login(api, "Peer")
        with external_lock(path):
            result = api.get("/users", headers=headers)
            assert result.status_code == 200
            assert result.json()["items"][0]["account"] == peer


def test_read_snapshot_acquisition_recovers_from_exclusive_lock(tmp_path, monkeypatch):
    path = tmp_path / "db"
    storage.migrate(path)
    original = storage._lock_statement
    calls = []
    with external_lock(path, "EXCLUSIVE") as release:
        timer = threading.Timer(1.3, release)

        def boundary(db, statement, deadline):
            if statement.startswith("SELECT"):
                timer.start()
            return original(db, statement, deadline)

        monkeypatch.setattr(storage, "_lock_statement", boundary)
        try:
            with storage.connection(path) as db:
                calls.append(1)
                assert db.execute("SELECT count(*) FROM users").fetchone()[0] == 0
                with pytest.raises(sqlite3.OperationalError) as error:
                    db.execute("DELETE FROM users")
                assert error.value.sqlite_errorcode == sqlite3.SQLITE_READONLY
        finally:
            timer.join()
    assert calls == [1]


def test_login_recovers_after_more_than_old_timeout(tmp_path, caplog, monkeypatch):
    path = tmp_path / "db"
    with TestClient(create_app(path, maintenance_interval=60)) as api:
        account, _ = login(api)
        # Start the release timer at the actual write entry, after password work.
        original = app_module.insert_session
        with external_lock(path) as release:
            timer = threading.Timer(1.3, release)

            def insert(*args):
                timer.start()
                return original(*args)

            monkeypatch.setattr(app_module, "insert_session", insert)
            try:
                with caplog.at_level(logging.WARNING):
                    result = api.post(
                        "/auth/login", json={"account": account, "password": "Abc123"}
                    )
            finally:
                timer.join()
            assert result.status_code == 200
        assert "storage_lock_recovered" in caplog.text
        with sqlite3.connect(path) as db:
            assert db.execute("SELECT count(*) FROM sessions").fetchone()[0] == 2


def test_busy_exhaustion_is_visible_and_has_no_success_fact(
    tmp_path, monkeypatch, caplog
):
    path = tmp_path / "db"
    with TestClient(create_app(path, maintenance_interval=60)) as api:
        account, _ = login(api)
        monkeypatch.setattr(storage, "LOCK_WAIT_SECONDS", 0.15)
        with external_lock(path), caplog.at_level(logging.WARNING):
            started = time.monotonic()
            result = api.post(
                "/auth/login?secret=DO_NOT_LOG",
                json={"account": account, "password": "Abc123"},
            )
            elapsed = time.monotonic() - started
        assert result.status_code == 503
        assert result.json()["error"]["code"] == "storage_busy"
        assert result.headers["retry-after"] == "1"
        assert 0.15 <= elapsed < 2
        assert "category=busy" in caplog.text and "route=/auth/login" in caplog.text
        assert "DO_NOT_LOG" not in caplog.text and "Abc123" not in caplog.text
        with sqlite3.connect(path) as db:
            assert db.execute("SELECT count(*) FROM sessions").fetchone()[0] == 1


def test_commit_busy_retries_same_body_and_expiry_rolls_back(tmp_path, monkeypatch):
    path = tmp_path / "db"
    storage.migrate(path)
    entered = threading.Event()
    original = storage._lock_statement

    def boundary(db, statement, deadline):
        if statement == "COMMIT":
            entered.set()
        return original(db, statement, deadline)

    monkeypatch.setattr(storage, "_lock_statement", boundary)
    calls = []

    def write():
        with storage.connection(path, write=True) as db:
            calls.append(1)
            db.execute(
                "INSERT INTO users(account,username,password) VALUES ('12345678','test','$argon2id$synthetic')"
            )

    with external_lock(path, "DEFERRED") as release, ThreadPoolExecutor(1) as pool:
        future = pool.submit(write)
        assert entered.wait(3)
        # Reader holds SHARED, writer owns RESERVED: COMMIT must wait.
        time.sleep(0.05)
        assert not future.done()
        release()
        future.result(timeout=3)
    assert calls == [1]
    monkeypatch.setattr(storage, "LOCK_WAIT_SECONDS", 0.1)
    with external_lock(path, "DEFERRED"):
        with (
            pytest.raises(sqlite3.OperationalError) as failure,
            storage.connection(path, write=True) as db,
        ):
            db.execute("UPDATE users SET username='uncommitted'")
        assert failure.value.storage_phase == "COMMIT"
    with sqlite3.connect(path) as db:
        assert db.execute("SELECT username FROM users").fetchall() == [("test",)]


def test_transient_message_lock_and_unknown_response_replay(tmp_path):
    path = tmp_path / "db"
    with TestClient(create_app(path, maintenance_interval=60)) as api:
        _, headers = login(api)
        peer, _ = login(api, "Peer")
        payload = {
            "target_account": peer,
            "client_nonce": "one-operation",
            "content": [{"type": "text", "text": "one message"}],
        }
        with external_lock(path) as release, ThreadPoolExecutor(8) as pool:
            futures = [
                pool.submit(api.post, "/messages", headers=headers, json=payload)
                for _ in range(8)
            ]
            time.sleep(0.1)
            release()
            replies = [future.result(timeout=5) for future in futures]
        assert all(
            r.status_code == 200 and r.json() == replies[0].json() for r in replies
        )
        known = api.get("/operations/one-operation", headers=headers)
        assert known.json()["message"] == replies[0].json()
        assert (
            api.post("/messages", headers=headers, json=payload).json()
            == replies[0].json()
        )
        with sqlite3.connect(path) as db:
            assert [
                db.execute(f"SELECT count(*) FROM {table}").fetchone()[0]
                for table in ["messages", "operations", "events"]
            ] == [1, 1, 2]


@pytest.mark.parametrize(
    "kind,code",
    [
        ("os", "storage_io_error"),
        ("sqlite_io", "storage_io_error"),
        ("other", "storage_unavailable"),
    ],
)
def test_error_classification_does_not_leak_exception_text(
    tmp_path, monkeypatch, caplog, kind, code
):
    with TestClient(create_app(tmp_path / "db", maintenance_interval=60)) as api:
        if kind == "os":
            error = OSError(errno.EIO, "SECRET_PATH")
        else:
            error = sqlite3.OperationalError("SECRET_PATH")
            error.sqlite_errorcode = (
                sqlite3.SQLITE_IOERR if kind == "sqlite_io" else sqlite3.SQLITE_ERROR
            )

        def fail(*args):
            raise error

        monkeypatch.setattr(app_module, "find_user", fail)
        with caplog.at_level(logging.WARNING):
            result = api.post(
                "/auth/login", json={"account": "12345678", "password": "Abc123"}
            )
        assert result.status_code == 503
        assert result.json()["error"]["code"] == code
        assert "SECRET_PATH" not in caplog.text + result.text
        assert "storage_failure" in caplog.text


def test_io_error_never_replays_body(tmp_path):
    path = tmp_path / "db"
    storage.migrate(path)
    calls = []
    with pytest.raises(OSError), storage.connection(path, write=True) as db:
        calls.append(1)
        db.execute(
            "INSERT INTO users(account,username,password) VALUES ('12345678','test','$argon2id$synthetic')"
        )
        raise OSError(errno.EIO, "synthetic")
    assert calls == [1]
    with sqlite3.connect(path) as db:
        assert db.execute("SELECT count(*) FROM users").fetchone()[0] == 0
