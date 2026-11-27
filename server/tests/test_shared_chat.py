import io
import os
from concurrent.futures import ThreadPoolExecutor

import pytest
from bb_auth_contract import ContractError
from bb_auth_contract.chat_association import HEADER, VERSION
from bb_auth_contract.conversation import direct_id
from PIL import Image
from test_admin_http import free_port, running
from test_chat import chat as real_chat  # noqa: F401
from test_chat import send

from bb_server.avatars import default_version, identicon
from bb_server.chat_store import (
    append_system_message,
    create_group_conversation,
    group_ref,
    set_group_membership,
)
from bb_server.storage import connection

NOW = "2026-11-27T12:00:00.000Z"


@pytest.fixture
def chat(real_chat):  # noqa: F811
    return real_chat


def group_send(api, who, group_id, nonce, content=None):
    return api.post(
        "/messages",
        headers=who[1],
        json={
            "conversation": group_ref(group_id),
            "client_nonce": nonce,
            "content": content or [{"type": "text", "text": nonce}],
        },
    )


def shared_list(api, who, **params):
    response = api.get("/chat/conversations", headers=who[1], params=params)
    assert response.status_code == 200, response.text
    return response.json()


def test_empty_group_and_colliding_user_number_are_distinct(chat):
    api, path, (owner, peer, stranger) = chat
    with connection(path, write=True) as db:
        group_id = create_group_conversation(db, owner[0], peer[0], "Group", "", NOW)
    group_item = shared_list(api, owner)["items"][0]
    assert group_item == {
        "conversation": group_ref(group_id),
        "group_number": peer[0],
        "display_name": "Group",
        "avatar_url": f"/chat/groups/{peer[0]}/avatar",
        "avatar_version": default_version(peer[0]),
        "last_message": None,
        "last_activity_at": NOW,
        "latest_position": 0,
        "history_through": 0,
        "membership_revision": 1,
    }
    with pytest.raises(ContractError) as error, connection(path, write=True) as db:
        set_group_membership(db, group_id, owner[0], False, NOW)
    assert error.value.status == 403
    url = group_item["avatar_url"]
    profile = api.get(url, headers=stranger[1])
    assert profile.content == identicon(peer[0])
    assert (
        api.get(
            url, headers={**stranger[1], "If-None-Match": profile.headers["etag"]}
        ).status_code
        == 304
    )
    assert api.get(url).status_code == 401
    assert shared_list(api, peer)["items"] == []
    with connection(path) as db:
        members = db.execute("SELECT account FROM chat_group_members").fetchall()
        assert [row[0] for row in members] == [owner[0]]

    direct = send(api, owner, peer, "dedupe").json()
    direct_ref = {"type": "direct", "id": direct_id(owner[0], peer[0])}
    explicit = api.post(
        "/messages",
        headers=owner[1],
        json={
            "conversation": direct_ref,
            "client_nonce": "dedupe",
            "content": direct["content"],
        },
    )
    assert explicit.json() == direct
    assert group_send(api, owner, group_id, "dedupe").status_code == 409
    first = shared_list(api, owner, limit=1)
    assert first["next_cursor"] == direct_ref["id"]
    assert first["items"][0]["conversation"] == direct_ref
    assert shared_list(api, owner, after_id=first["next_cursor"])["items"] == [
        group_item
    ]
    assert len(api.get("/conversations", headers=owner[1]).json()["items"]) == 1


def test_member_history_and_replay_use_the_current_membership_epoch(chat):
    api, path, (owner, member, stranger) = chat
    with connection(path, write=True) as db:
        group_id = create_group_conversation(db, owner[0], "10000001", "Study", "", NOW)
    url = f"/chat/conversations/{group_id}/messages"
    first = group_send(api, owner, group_id, "old-text").json()
    assert first["sender_account"] == owner[0]
    assert first["sender_username"] == "Alice"
    assert first["conversation"] == group_ref(group_id)
    assert "target_account" not in first

    image = io.BytesIO()
    Image.new("RGB", (3, 3), "red").save(image, format="PNG")
    image_bytes = image.getvalue()
    uploaded = api.post(
        "/media",
        headers=owner[1],
        data={"conversation_id": group_id},
        files={"file": ("cover.png", image_bytes, "image/png")},
    )
    assert uploaded.status_code == 200, uploaded.text
    cover_id = uploaded.json()["media_id"]
    video_bytes = b"0000ftyp-synthetic"
    video = api.post(
        "/media",
        headers=owner[1],
        data={"conversation_id": group_id, "cover_media_id": cover_id},
        files={"file": ("clip.mp4", video_bytes, "video/mp4")},
    )
    assert video.status_code == 200, video.text
    video_id = video.json()["media_id"]
    media_url = f"/media/{video_id}"
    post = api.post(
        "/messages/attachments",
        headers=owner[1],
        json={
            "conversation": group_ref(group_id),
            "client_nonce": "video",
            "media_id": video_id,
        },
    )
    assert post.status_code == 200, post.text
    content = [
        {"type": "text", "text": "before"},
        {"type": "image", "media_id": cover_id},
        {"type": "text", "text": "after"},
    ]
    assert (
        group_send(api, owner, group_id, "mixed", content).json()["content"] == content
    )
    anchor = "/messages/" + first["id"]
    for endpoint in (
        url,
        anchor,
        anchor + "/context",
        media_url,
        media_url + "/metadata",
    ):
        assert api.get(endpoint, headers=member[1]).status_code == 404
    assert group_send(api, member, group_id, "unauthorized").status_code == 404

    with ThreadPoolExecutor(max_workers=1) as pool:
        with connection(path, write=True) as db:
            new_message = pool.submit(group_send, api, owner, group_id, "new-text")
            assert set_group_membership(db, group_id, member[0], True, NOW)
            assert not set_group_membership(db, group_id, member[0], True, NOW)
            joined = append_system_message(
                db,
                group_id,
                {"type": "member.joined", "account": member[0], "username": "Bob"},
                "Bob 加入群",
                NOW,
            )
        sent = new_message.result().json()
    assert sent["position"] == joined["position"] + 1
    assert "sender_account" not in joined
    assert (
        shared_list(api, member)["items"][0]["history_through"] == first["position"] + 2
    )

    result = api.get(url, headers=member[1]).json()
    assert [row["kind"] for row in result["items"]] == [
        "body",
        "attachment",
        "body",
        "system",
        "body",
    ]
    assert result["items"][2]["content"] == content
    assert result["items"][3] == joined
    context = api.get(anchor + "/context", headers=member[1]).json()
    assert (
        context["conversation"] == group_ref(group_id) and "peer_account" not in context
    )
    assert api.get(media_url, headers=member[1]).content == video_bytes
    assert api.get(f"/media/{cover_id}", headers=member[1]).content == image_bytes
    assert api.get(media_url, headers=stranger[1]).status_code == 404

    messages = api.get("/events", headers=member[1]).json()["items"]
    assert messages == []
    replay = api.get("/events?include_groups=true", headers=member[1]).json()
    assert [item["type"] for item in replay["items"]] == [
        "conversation.access_changed",
        "message.available",
        "message.available",
    ]
    assert [item["position"] for item in replay["items"][1:]] == [
        joined["position"],
        sent["position"],
    ]
    assert all(item["membership_revision"] == 1 for item in replay["items"])
    with api.websocket_connect(
        "/events?include_groups=true", headers=member[1]
    ) as socket:
        assert socket.receive_json() == replay["items"][0]
        assert socket.receive_json() == replay["items"][1]
        assert socket.receive_json() == replay["items"][2]

    member_post = group_send(api, member, group_id, "member-message").json()
    association = {**member[1], HEADER: VERSION}
    assert (
        api.get("/messages/" + member_post["id"], headers=association).json()[
            "operation_id"
        ]
        == "member-message"
    )
    assert (
        "operation_id"
        not in api.get(
            "/messages/" + member_post["id"], headers={**owner[1], HEADER: VERSION}
        ).json()
    )
    with connection(path, write=True) as db:
        assert set_group_membership(db, group_id, member[0], False, NOW)
    for endpoint in (
        url,
        anchor,
        anchor + "/context",
        media_url,
        "/operations/member-message",
    ):
        assert api.get(endpoint, headers=member[1]).status_code == 404
    assert group_send(api, member, group_id, "member-message").status_code == 404
    assert shared_list(api, member)["items"] == []
    revoked = api.get("/events?include_groups=true", headers=member[1]).json()["items"]
    assert (
        len(revoked) == 1
        and not revoked[0]["active"]
        and revoked[0]["membership_revision"] == 2
    )

    during = group_send(api, owner, group_id, "during-absence").json()
    with connection(path, write=True) as db:
        assert set_group_membership(db, group_id, member[0], True, NOW)
        rename = append_system_message(
            db,
            group_id,
            {"type": "group.renamed", "old_name": "Study", "new_name": "Work"},
            "群名称从 Study 改为 Work",
            NOW,
        )
    assert shared_list(api, member)["items"][0]["history_through"] == during["position"]
    assert [item["id"] for item in api.get(url, headers=member[1]).json()["items"]][
        -2:
    ] == [
        during["id"],
        rename["id"],
    ]
    assert api.get(media_url, headers=member[1]).content == video_bytes
    rejoined = api.get("/events?include_groups=true", headers=member[1]).json()["items"]
    assert len(rejoined) == 2
    assert rejoined[0]["active"] and rejoined[0]["membership_revision"] == 3
    assert rejoined[1]["message_id"] == rename["id"]

    with connection(path, write=True) as db:
        # Establish the dissolved state before deleting group messages, as in DEA-501.
        db.execute(
            "UPDATE chat_groups SET status='dissolved' WHERE conversation_id=?",
            (group_id,),
        )
        set_group_membership(db, group_id, owner[0], False, NOW)
        set_group_membership(db, group_id, member[0], False, NOW)
        db.execute("DELETE FROM messages WHERE conversation_id=?", (group_id,))
        assert db.execute("SELECT COUNT(*) FROM chat_message_media").fetchone()[0] == 0
    assert api.get(media_url, headers=owner[1]).status_code == 404
    assert api.get("/operations/member-message", headers=member[1]).status_code == 404
    assert send(api, member, owner, "member-message").status_code == 409
    owner_events = api.get("/events?include_groups=true", headers=owner[1]).json()[
        "items"
    ]
    assert len(owner_events) == 1 and owner_events[0]["active"] is False


def test_real_listener_group_authorization_after_restart(tmp_path):
    port = free_port()
    path = tmp_path / "business.db"
    env = {
        **os.environ,
        "BB_DATABASE_PATH": str(path),
        "BB_AVATAR_DIRECTORY": str(tmp_path / "avatars"),
        "BB_MEDIA_DIRECTORY": str(tmp_path / "media"),
        "BB_HOST": "127.0.0.1",
        "BB_PORT": str(port),
    }
    origin = f"http://127.0.0.1:{port}"
    with running("bb-server", env, origin, tmp_path / "first.log") as api:
        accounts = []
        for username in ("Owner", "Member"):
            credentials = {"username": username, "password": "Synthetic-Abc123"}
            account = api.post("/auth/register", json=credentials)
            assert account.status_code == 201
            account = account.json()["account"]
            login = api.post(
                "/auth/login",
                json={"account": account, "password": credentials["password"]},
            )
            assert login.status_code == 200
            accounts.append(
                (account, {"Authorization": "Bearer " + login.json()["token"]})
            )
        owner, member = accounts
        # This seeds the membership lifecycle owned by DEA-501.
        with connection(path, write=True) as db:
            group_id = create_group_conversation(
                db, owner[0], member[0], "Group", "", NOW
            )
            set_group_membership(db, group_id, member[0], True, NOW)
        message = group_send(api, owner, group_id, "real-listener")
        assert message.status_code == 200
        message_url = "/messages/" + message.json()["id"]
        assert api.get(message_url, headers=member[1]).json() == message.json()
        with connection(path, write=True) as db:
            set_group_membership(db, group_id, member[0], False, NOW)
    with running("bb-server", env, origin, tmp_path / "restart.log") as api:
        assert api.get(message_url, headers=member[1]).status_code == 404
        assert api.get(message_url, headers=owner[1]).json() == message.json()
        assert shared_list(api, member)["items"] == []
        events = api.get("/events?include_groups=true", headers=member[1]).json()[
            "items"
        ]
        assert len(events) == 1 and events[0]["active"] is False
        assert (
            group_send(api, owner, group_id, "real-listener").json() == message.json()
        )
