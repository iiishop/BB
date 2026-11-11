import shutil
import sqlite3

import pytest
from fastapi.testclient import TestClient
from test_profile import image_bytes, login, upload

from bb_server.app import create_app
from bb_server.backup import backup


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


def test_stopped_backup_and_avatar_directory_restore(tmp_path):
    source, restored = tmp_path / "source.db", tmp_path / "restored.db"
    media, restored_media = tmp_path / "media", tmp_path / "restored-media"
    with TestClient(create_app(source, media)) as api:
        account, headers = login(api)
        assert upload(api, headers, image_bytes()).status_code == 200
        profile = api.get(f"/users/{account}/profile", headers=headers).json()
        png = api.get(profile["avatar_url"], headers=headers).content
    # Stop writes, snapshot the database and copy its companion directory.
    backup(source, restored)
    shutil.copytree(media, restored_media)
    with TestClient(create_app(restored, restored_media)) as api:
        assert api.get(f"/users/{account}/profile", headers=headers).json() == profile
        assert api.get(profile["avatar_url"], headers=headers).content == png
