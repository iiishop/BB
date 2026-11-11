import sqlite3
from pathlib import Path

import pytest
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
        db.execute("PRAGMA user_version=2")
    with pytest.raises(RuntimeError, match="newer"):
        migrate(path)
    with sqlite3.connect(path) as db:
        assert db.execute("PRAGMA user_version").fetchone()[0] == 2
