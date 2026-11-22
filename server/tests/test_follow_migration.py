"""V4 facts survive the additive follow migration and its failure boundaries."""

import sqlite3
from pathlib import Path

import pytest

from bb_server.storage import migrate


def test_v4_upgrade_rollback_retains_posts_chat_and_accounts(tmp_path, monkeypatch):
    path = tmp_path / "v4.db"
    root = Path(__file__).parents[1] / "src/bb_server/migrations"
    with sqlite3.connect(path) as db:
        for name in (
            "001_auth.sql",
            "002_profile.sql",
            "003_chat.sql",
            "004_space.sql",
        ):
            db.executescript((root / name).read_text())
        db.execute("PRAGMA user_version=4")
        db.execute(
            "INSERT INTO users(account,username,password) VALUES ('12345678','synthetic','$argon2id$fixture')"
        )
        db.execute(
            "INSERT INTO messages VALUES ('m','12345678','12345678',1,'12345678','12345678','time','payload')"
        )
        db.execute(
            "INSERT INTO space_posts VALUES ('p','12345678','2026-10-30T00:00:00.000000Z','old post',NULL,0,1)"
        )
        before = {
            t: db.execute(f"SELECT * FROM {t}").fetchall()
            for t in ("users", "messages", "space_posts")
        }
    original = Path.read_text
    with monkeypatch.context() as patch:
        patch.setattr(
            Path,
            "read_text",
            lambda self, **kw: original(self, **kw) + "; INVALID SQL;",
        )
        with pytest.raises(sqlite3.OperationalError):
            migrate(path)
    with sqlite3.connect(path) as db:
        assert db.execute("PRAGMA user_version").fetchone()[0] == 4
        assert (
            db.execute(
                "SELECT name FROM sqlite_schema WHERE name IN ('space_follows','space_follow_versions')"
            ).fetchall()
            == []
        )
        assert {
            t: db.execute(f"SELECT * FROM {t}").fetchall() for t in before
        } == before
    migrate(path)
    migrate(path)
    with sqlite3.connect(path) as db:
        db.execute("PRAGMA foreign_keys=ON")
        assert db.execute("PRAGMA user_version").fetchone()[0] == 7
        assert {
            t: db.execute(f"SELECT * FROM {t}").fetchall() for t in before
        } == before
        assert db.execute("SELECT * FROM space_follows").fetchall() == []
        with pytest.raises(sqlite3.IntegrityError):
            db.execute("INSERT INTO space_follows VALUES ('12345678','12345678')")
        with pytest.raises(sqlite3.IntegrityError):
            db.execute("INSERT INTO space_follows VALUES ('12345678','87654321')")
