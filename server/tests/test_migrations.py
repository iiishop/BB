import hashlib
import sqlite3
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from bb_server.app import create_app
from bb_server.storage import migrate


def test_failed_migration_rolls_back_entire_schema(tmp_path, monkeypatch):
    path = tmp_path / "failed.db"
    monkeypatch.setattr(
        Path,
        "read_text",
        lambda *args, **kwargs: "CREATE TABLE partial(id INTEGER); INVALID SQL;",
    )
    with pytest.raises(sqlite3.OperationalError):
        migrate(path)
    with sqlite3.connect(path) as db:
        assert db.execute("PRAGMA user_version").fetchone()[0] == 0
        assert (
            db.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()
            == []
        )


def test_newer_schema_is_never_downgraded(tmp_path):
    path = tmp_path / "future.db"
    with sqlite3.connect(path) as db:
        db.execute("PRAGMA user_version=4")
    with pytest.raises(RuntimeError, match="newer"):
        migrate(path)
    with sqlite3.connect(path) as db:
        assert db.execute("PRAGMA user_version").fetchone()[0] == 4


def test_upgrade_step1_preserves_old_accounts_and_sessions(tmp_path):
    path = tmp_path / "v1.db"
    schema = Path(__file__).parents[1] / "src/bb_server/migrations/001_auth.sql"
    token = "synthetic-migration-token"
    with sqlite3.connect(path) as db:
        db.executescript(schema.read_text())
        db.execute("PRAGMA user_version=1")
        db.execute(
            "INSERT INTO users VALUES ('12345678', 'Old user', '$argon2id$fixture')"
        )
        db.execute(
            "INSERT INTO sessions VALUES (?, '12345678', '2020-01-01T00:00:00.000Z')",
            (hashlib.sha256(token.encode()).hexdigest(),),
        )
    before = time.time()
    with TestClient(create_app(path)) as api:
        headers = {"Authorization": "Bearer " + token}
        assert api.get("/auth/session", headers=headers).json() == {
            "account": "12345678",
            "username": "Old user",
        }
        assert (
            api.get("/users/12345678/profile", headers=headers).json()["signature"]
            is None
        )
    migrate(path)
    with sqlite3.connect(path) as db:
        assert db.execute("PRAGMA user_version").fetchone()[0] == 3
        assert db.execute("SELECT last_seen_at FROM sessions").fetchone()[0] >= int(
            before
        )
        assert db.execute("SELECT avatar_path FROM users").fetchone()[0] is None


def test_failed_step2_migration_leaves_step1_unchanged(tmp_path, monkeypatch):
    path = tmp_path / "v1.db"
    schema = Path(__file__).parents[1] / "src/bb_server/migrations/001_auth.sql"
    with sqlite3.connect(path) as db:
        db.executescript(schema.read_text())
        db.execute("PRAGMA user_version=1")
    monkeypatch.setattr(
        Path,
        "read_text",
        lambda *args, **kwargs: (
            "ALTER TABLE users ADD COLUMN partial TEXT; INVALID SQL;"
        ),
    )
    with pytest.raises(sqlite3.OperationalError):
        migrate(path)
    with sqlite3.connect(path) as db:
        assert db.execute("PRAGMA user_version").fetchone()[0] == 1
        assert [row[1] for row in db.execute("PRAGMA table_info(users)")] == [
            "account",
            "username",
            "password",
        ]
