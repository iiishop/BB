import hashlib
import json
import sqlite3
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from bb_server.app import create_app
from bb_server.storage import SCHEMA_VERSION, migrate


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
        db.execute(f"PRAGMA user_version={SCHEMA_VERSION + 1}")
    with pytest.raises(RuntimeError, match="newer"):
        migrate(path)
    with sqlite3.connect(path) as db:
        assert db.execute("PRAGMA user_version").fetchone()[0] == SCHEMA_VERSION + 1


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
        assert db.execute("PRAGMA user_version").fetchone()[0] == SCHEMA_VERSION
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


def test_space_upgrade_preserves_v3_chat_and_rollback(tmp_path, monkeypatch):
    path = tmp_path / "v3.db"
    migrations = Path(__file__).parents[1] / "src/bb_server/migrations"
    with sqlite3.connect(path) as db:
        for name in ("001_auth.sql", "002_profile.sql", "003_chat.sql"):
            db.executescript((migrations / name).read_text())
        db.execute("PRAGMA user_version=3")
        db.execute(
            "INSERT INTO users(account,username,password) VALUES ('12345678','fixture','$argon2id$fixture')"
        )
        db.execute(
            "INSERT INTO messages VALUES ('m','12345678','12345678',1,'12345678','12345678','time','payload')"
        )
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
        assert db.execute("PRAGMA user_version").fetchone()[0] == 3
        assert (
            db.execute(
                "SELECT name FROM sqlite_master WHERE name LIKE 'space_%'"
            ).fetchall()
            == []
        )
        assert db.execute("SELECT payload FROM messages").fetchone()[0] == "payload"
    migrate(path)
    migrate(path)
    with sqlite3.connect(path) as db:
        assert db.execute("PRAGMA user_version").fetchone()[0] == SCHEMA_VERSION
        assert db.execute("SELECT payload FROM messages").fetchone()[0] == "payload"
        assert db.execute("SELECT count(*) FROM space_posts").fetchone()[0] == 0


@pytest.mark.parametrize(
    ("version", "migration"),
    [
        (8, "009_shared_chat.sql"),
        (8, "010_group_lifecycle.sql"),
        (9, "010_group_lifecycle.sql"),
    ],
)
def test_v8_chat_migration_rollback_and_retry_preserve_live_wire_state(
    tmp_path, monkeypatch, version, migration
):
    path = tmp_path / f"v{version}.db"
    migrations = Path(__file__).parents[1] / "src/bb_server/migrations"
    alice, bob = "10000001", "10000002"
    timestamp = "2026-11-27T20:00:00.000Z"
    request = {
        "target_account": bob,
        "client_nonce": "old-nonce",
        "content": [{"type": "text", "text": "old text"}],
    }
    message = {
        "id": "old-message",
        "sender_account": alice,
        "target_account": bob,
        "created_at": timestamp,
        "position": 4,
        "kind": "body",
        "content": request["content"],
        "attachment": None,
    }
    digest = hashlib.sha256(
        json.dumps(
            request, sort_keys=True, separators=(",", ":"), ensure_ascii=False
        ).encode()
    ).hexdigest()
    token = "synthetic-old-chat-session"
    headers = {"Authorization": f"Bearer {token}"}
    with sqlite3.connect(path) as db:
        for name in (
            "001_auth.sql",
            "002_profile.sql",
            "003_chat.sql",
            "004_space.sql",
            "005_follows.sql",
            "006_covers.sql",
        ):
            db.executescript((migrations / name).read_text())
        db.execute("PRAGMA user_version=8")
        db.executemany(
            "INSERT INTO users(account,username,password) VALUES (?,?,'$argon2id$fixture')",
            [(alice, "Alice"), (bob, "Bob")],
        )
        db.execute(
            """INSERT INTO sessions(token_hash,account,created_at,last_seen_at,status)
            VALUES (?,?,?,?,'online')""",
            (hashlib.sha256(token.encode()).hexdigest(), alice, timestamp, time.time()),
        )
        db.execute(
            "INSERT INTO messages VALUES (?,?,?,?,?,?,?,?)",
            (message["id"], alice, bob, 4, alice, bob, timestamp, json.dumps(message)),
        )
        db.execute(
            "INSERT INTO operations VALUES (?,?,?,?)",
            (alice, "old-nonce", digest, message["id"]),
        )
        db.execute(
            "INSERT INTO events VALUES (42,?,?,?,?,?)",
            (alice, message["id"], bob, 4, timestamp),
        )
        db.execute("UPDATE sqlite_sequence SET seq=55 WHERE name='events'")
        db.execute(
            "INSERT INTO media VALUES ('cover',?,?,'image/png','image','cover.png',5,NULL)",
            (alice, bob),
        )
        db.execute(
            "INSERT INTO media VALUES ('clip',?,?,'video/mp4','video','clip.mp4',9,'cover')",
            (alice, bob),
        )
        if version == 9:
            db.executescript((migrations / "009_shared_chat.sql").read_text())
            db.execute("PRAGMA user_version=9")

    read_text = Path.read_text
    with monkeypatch.context() as patch:

        def break_migration(file, *args, **kwargs):
            content = read_text(file, *args, **kwargs)
            return content + "\nINVALID SQL;" if file.name == migration else content

        patch.setattr(Path, "read_text", break_migration)
        with pytest.raises(sqlite3.OperationalError):
            migrate(path)
    with sqlite3.connect(path) as db:
        assert db.execute("PRAGMA user_version").fetchone()[0] == version
        if version == 8:
            assert db.execute("SELECT pair_low,pair_high FROM messages").fetchone() == (
                alice,
                bob,
            )
        else:
            assert (
                db.execute("SELECT conversation_id FROM messages").fetchone()[0]
                == f"dm:{alice}:{bob}"
            )
        assert (
            db.execute("SELECT 1 FROM sqlite_schema WHERE name='bb_notices'").fetchone()
            is None
        )
        assert db.execute("SELECT event_id FROM events").fetchone()[0] == 42
        assert (
            db.execute(
                "SELECT seq FROM sqlite_sequence WHERE name='events'"
            ).fetchone()[0]
            == 55
        )
        assert (
            db.execute("SELECT cover_id FROM media WHERE id='clip'").fetchone()[0]
            == "cover"
        )

    for _ in range(2):
        with TestClient(create_app(path)) as api:
            assert (
                api.get("/operations/old-nonce", headers=headers).json()["message"]
                == message
            )
            assert (
                api.post("/messages", headers=headers, json=request).json() == message
            )
            assert api.get("/events", headers=headers).json()["next_event_id"] == 42
            assert (
                api.get("/media/clip/metadata", headers=headers).json()[
                    "cover_media_id"
                ]
                == "cover"
            )
            assert (
                api.get(f"/conversations/{bob}/messages", headers=headers).json()[
                    "items"
                ][0]
                == message
            )
    with TestClient(create_app(path)) as api:
        item = api.post(
            "/messages", headers=headers, json={**request, "client_nonce": "new-nonce"}
        ).json()
        assert item["position"] == 5
        events = api.get("/events?after_event_id=42", headers=headers).json()
        assert events["items"][0]["event_id"] > 55
    with sqlite3.connect(path) as db:
        assert db.execute("PRAGMA foreign_key_check").fetchall() == []
        assert db.execute("SELECT COUNT(*) FROM messages").fetchone()[0] == 2
