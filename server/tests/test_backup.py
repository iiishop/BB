import sqlite3

import pytest
from bb_server.app import create_app
from bb_server.backup import backup
from fastapi.testclient import TestClient


def test_restore_account_and_session_from_backup(tmp_path):
    source, restored = tmp_path / "source.db", tmp_path / "restored.db"
    with TestClient(create_app(source)) as api:
        identity = api.post(
            "/auth/register", json={"username": "Alice", "password": "Abc123"}
        ).json()
        token = api.post(
            "/auth/login", json={"account": identity["account"], "password": "Abc123"}
        ).json()["token"]
        backup(source, restored)
    with sqlite3.connect(source) as db:
        db.execute("DELETE FROM sessions")
    with TestClient(create_app(restored)) as api:
        response = api.get(
            "/auth/session", headers={"Authorization": f"Bearer {token}"}
        )
        assert response.status_code == 200
        assert response.json() == identity
    with pytest.raises(FileExistsError):
        backup(source, restored)
    with pytest.raises(FileNotFoundError):
        backup(tmp_path / "absent.db", tmp_path / "invalid.db")
    assert not (tmp_path / "invalid.db").exists()
