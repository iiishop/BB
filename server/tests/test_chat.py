import io
import sqlite3
from concurrent.futures import ThreadPoolExecutor

import pytest
from fastapi.testclient import TestClient
from PIL import Image

from bb_server.app import create_app


@pytest.fixture
def chat(tmp_path):
    path = tmp_path / "chat.db"
    with TestClient(create_app(path)) as api:
        accounts = []
        for name in ("Alice", "Bob", "Carol"):
            account = api.post(
                "/auth/register", json={"username": name, "password": "Abc123"}
            ).json()["account"]
            token = api.post(
                "/auth/login", json={"account": account, "password": "Abc123"}
            ).json()["token"]
            accounts.append((account, {"Authorization": "Bearer " + token}))
        yield api, path, accounts


def send(api, who, peer, nonce="nonce", text="hi"):
    return api.post(
        "/messages",
        headers=who[1],
        json={
            "target_account": peer[0],
            "client_nonce": nonce,
            "content": [{"type": "text", "text": text}],
        },
    )


def test_commit_lost_receipt_concurrent_replay_restart_and_acl(chat):
    api, path, (a, b, c) = chat
    # Discard original response (lost receipt); lookup and twelve concurrent retries.
    assert send(api, a, b).status_code == 200
    with ThreadPoolExecutor(max_workers=12) as pool:
        replies = list(pool.map(lambda _: send(api, a, b), range(12)))
    assert all(r.status_code == 200 for r in replies)
    message = replies[0].json()
    assert {r.json()["id"] for r in replies} == {message["id"]}
    assert send(api, a, c).status_code == 409
    assert send(api, a, b, text="changed").status_code == 409
    assert api.get("/operations/nonce", headers=b[1]).status_code == 404
    assert api.get("/operations/nonce", headers=a[1]).json()["message"] == message
    assert api.get("/operations/nonce").status_code == 401
    with TestClient(create_app(path)) as restarted:
        assert send(restarted, a, b).json() == message
    with sqlite3.connect(path) as db:
        assert db.execute("SELECT count(*) FROM messages").fetchone()[0] == 1
        assert db.execute("SELECT count(*) FROM operations").fetchone()[0] == 1
        assert db.execute("SELECT count(*) FROM events").fetchone()[0] == 2
    assert (
        api.get(f"/conversations/{a[0]}/messages", headers=c[1]).json()["items"] == []
    )
    assert api.get("/events", headers=c[1]).json()["items"] == []
    events = api.get("/events", headers=b[1]).json()
    assert events["items"][0]["peer_account"] == a[0]
    assert (
        api.get(
            "/events", params={"after_event_id": events["next_event_id"]}, headers=b[1]
        ).json()["items"]
        == []
    )
    with api.websocket_connect("/events", headers=b[1]) as ws:
        assert ws.receive_json() == events["items"][0]


def test_transaction_rollback_no_message_without_outbox(chat):
    api, path, (a, b, _) = chat
    with sqlite3.connect(path) as db:
        db.execute(
            "CREATE TRIGGER fail_outbox BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT,'injected'); END"
        )
    assert send(api, a, b).status_code == 503
    with sqlite3.connect(path) as db:
        for table in ("messages", "operations", "events"):
            assert db.execute(f"SELECT count(*) FROM {table}").fetchone()[0] == 0
        db.execute("DROP TRIGGER fail_outbox")
    assert send(api, a, b).json()["position"] == 1


def test_users_private_preview_unicode_and_paging(chat):
    api, _, (a, b, c) = chat
    text = "👨‍👩‍👧‍👦" * 21
    assert send(api, a, b, text=text).status_code == 200
    assert send(api, b, c, "secret", "private").status_code == 200
    users = api.get("/users", headers=a[1]).json()["items"]
    assert [u["account"] for u in users] == sorted([b[0], c[0]])
    assert (
        next(u for u in users if u["account"] == b[0])["last_message"]["preview_body"]
        == "👨‍👩‍👧‍👦" * 20 + "…"
    )
    assert next(u for u in users if u["account"] == c[0])["last_message"] is None
    page = api.get("/users?limit=1", headers=a[1]).json()
    assert (
        api.get(
            "/users", params={"after_account": page["next_cursor"]}, headers=a[1]
        ).json()["items"]
        == users[1:]
    )
    assert all(u["presence"] == "online" for u in users)


def test_media_order_range_pair_acl_and_attachments(chat):
    api, _, (a, b, c) = chat
    png = io.BytesIO()
    Image.new("RGB", (3, 3), "red").save(png, format="PNG")
    upload = api.post(
        "/media",
        headers=a[1],
        data={"target_account": b[0]},
        files={"file": ("../../secret.png", png.getvalue(), "image/png")},
    )
    assert upload.status_code == 200, upload.text
    media = upload.json()
    assert media["filename"] == "secret.png"
    mid = media["media_id"]
    body = {
        "target_account": b[0],
        "client_nonce": "mixed",
        "content": [
            {"type": "text", "text": "a"},
            {"type": "image", "media_id": mid},
            {"type": "text", "text": "b"},
        ],
    }
    assert (
        api.post("/messages", headers=a[1], json=body).json()["content"]
        == body["content"]
    )
    assert (
        api.post(
            "/messages",
            headers=a[1],
            json={**body, "target_account": c[0], "client_nonce": "wrong"},
        ).status_code
        == 404
    )
    assert api.get("/media/" + mid, headers=c[1]).status_code == 404
    assert (
        api.get("/media/" + mid, headers={**b[1], "Range": "bytes=0-7"}).content
        == png.getvalue()[:8]
    )
    assert (
        api.post(
            "/media",
            headers=a[1],
            data={"target_account": b[0]},
            files={"file": ("bad.png", b"bad", "image/png")},
        ).status_code
        == 415
    )
    assert (
        api.post(
            "/media",
            headers=a[1],
            data={"target_account": b[0]},
            files={"file": ("bad.html", b"<script>", "text/html")},
        ).status_code
        == 415
    )
    video = api.post(
        "/media",
        headers=a[1],
        data={"target_account": b[0]},
        files={"file": ("clip.mp4", b"0000ftypfake", "video/mp4")},
    )
    assert video.status_code == 422
    pdf = api.post(
        "/media",
        headers=a[1],
        data={"target_account": b[0]},
        files={"file": ("doc.pdf", b"%PDF-1.4 synthetic", "application/pdf")},
    ).json()
    result = api.post(
        "/messages/attachments",
        headers=a[1],
        json={
            "target_account": b[0],
            "client_nonce": "pdf",
            "media_id": pdf["media_id"],
        },
    )
    assert result.status_code == 200
    page = api.get(f"/conversations/{b[0]}/messages?limit=1", headers=a[1]).json()
    assert page["has_more"] and page["next_position"] == 1
    assert (
        api.get(
            f"/conversations/{b[0]}/messages?after_position=1", headers=a[1]
        ).json()["items"][0]["attachment"]
        == pdf
    )


def test_corrupt_image_is_a_safe_415_and_bounded_upload(chat):
    import base64

    api, _, (a, b, _) = chat
    corrupt = base64.b64decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a5XcAAAAASUVORK5CYII="
    )
    response = api.post(
        "/media",
        headers=a[1],
        data={"target_account": b[0]},
        files={"file": ("broken.png", corrupt, "image/png")},
    )
    assert response.status_code == 415
    assert (
        api.post(
            "/media",
            headers={**a[1], "Content-Length": str(34 * 1024 * 1024)},
            content=b"",
        ).status_code
        == 413
    )
