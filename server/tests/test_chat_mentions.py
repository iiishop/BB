import sqlite3

import test_chat
from bb_auth_contract.chat_alerts import LIST_PATH, SEEN_PATH, SUMMARY_PATH
from bb_auth_contract.mentions import DETAIL_PATH
from fastapi.testclient import TestClient

from bb_server.app import create_app
from bb_server.chat_alerts import record_reply
from bb_server.chat_store import (
    create_group_conversation,
    group_ref,
    set_group_membership,
)
from bb_server.storage import connection

chat = test_chat.chat

NOW = "2026-11-28T12:00:00.000Z"


def make_group(path, owner, number, name, *members):
    with connection(path, write=True) as db:
        group = create_group_conversation(db, owner[0], number, name, "", NOW)
        for member in members:
            set_group_membership(db, group, member[0], True, NOW)
    return group


def test_mentions_scope_paging_exact_clear_and_restart(chat):
    api, path, (owner, recipient, other) = chat
    group = make_group(path, owner, "10000001", "Visible", recipient, other)
    second = make_group(path, owner, "10000002", "Also visible", recipient)
    hidden = make_group(path, other, "10000003", "Hidden", owner)

    def post(route, who, **body):
        response = api.post(route, headers=who[1], json=body)
        assert response.status_code == 200, response.text
        return response.json()

    def send(nonce, conversation_id, *accounts):
        return post(
            "/messages",
            owner,
            conversation=group_ref(conversation_id),
            client_nonce=nonce,
            content=[{"type": "text", "text": "@ same nickname"}],
            mentioned_accounts=list(accounts),
        )

    # Emulate a v11 database with an existing group message and operation digest.
    legacy_request = {
        "conversation": group_ref(group),
        "client_nonce": "historical",
        "content": [{"type": "text", "text": "@ same nickname"}],
    }
    historical = post("/messages", owner, **legacy_request)
    with sqlite3.connect(path) as db:
        db.execute("DROP TABLE chat_unread_alerts")
        db.execute("PRAGMA user_version=11")
    with TestClient(create_app(path)) as reopened:
        assert reopened.post(SUMMARY_PATH, headers=recipient[1], json={}).json() == {
            "items": [],
            "next_cursor": None,
        }
        replay = reopened.post("/messages", headers=owner[1], json=legacy_request)
        assert replay.status_code == 200 and replay.json() == historical

    old = send("old", group, recipient[0], other[0], owner[0])
    mid = send("mid", group, recipient[0])
    new = send("new", group, recipient[0])
    send("ordinary", group)
    second_message = send("second", second, recipient[0])
    send("private", hidden, other[0])
    assert post(SUMMARY_PATH, owner) == {"items": [], "next_cursor": None}

    first_page = post(SUMMARY_PATH, recipient, limit=1)
    next_page = post(
        SUMMARY_PATH,
        recipient,
        limit=1,
        after_conversation_id=first_page["next_cursor"],
    )
    assert next_page["next_cursor"] is None
    summary = {
        row["conversation_id"]: (row["display_name"], row["unread_mention_count"])
        for row in first_page["items"] + next_page["items"]
    }
    assert summary == {group: ("Visible", 3), second: ("Also visible", 1)}
    for route, extras in ((DETAIL_PATH, {}), (SEEN_PATH, {"message_ids": [old["id"]]})):
        assert (
            api.post(
                route, headers=recipient[1], json={"conversation_id": hidden, **extras}
            ).status_code
            == 404
        )
        assert (
            api.post(route, json={"conversation_id": group, **extras}).status_code
            == 401
        )
    assert [
        item["message_id"]
        for item in post(DETAIL_PATH, other, conversation_id=group)["items"]
    ] == [old["id"]]
    assert post(
        SEEN_PATH,
        recipient,
        conversation_id=group,
        message_ids=[mid["id"], second_message["id"]],
    ) == {"unread_mention_count": 2, "unread_reply_count": 0}
    assert send("mid", group, recipient[0]) == mid
    assert send("old", group, owner[0], other[0], recipient[0]) == old
    with TestClient(create_app(path)) as reopened:
        reply = reopened.post(
            DETAIL_PATH,
            headers=recipient[1],
            json={"conversation_id": group, "limit": 1},
        ).json()
        assert [item["message_id"] for item in reply["items"]] == [new["id"]]
        earlier = reopened.post(
            DETAIL_PATH,
            headers=recipient[1],
            json={"conversation_id": group, "before_position": reply["next_cursor"]},
        ).json()
        assert [item["message_id"] for item in earlier["items"]] == [old["id"]]
    assert post(
        SEEN_PATH, recipient, conversation_id=group, message_ids=[new["id"], old["id"]]
    ) == {"unread_mention_count": 0, "unread_reply_count": 0}
    assert post(SUMMARY_PATH, recipient)["items"] == [
        {
            "conversation_id": second,
            "display_name": "Also visible",
            "unread_mention_count": 1,
            "unread_reply_count": 0,
            "latest_alert": {
                "message_id": second_message["id"],
                "mention": True,
                "reply": False,
                "position": second_message["position"],
            },
        }
    ]
    assert send("old", group, other[0], recipient[0], owner[0]) == old
    assert post(DETAIL_PATH, recipient, conversation_id=group)["items"] == []
    assert len(post(DETAIL_PATH, other, conversation_id=group)["items"]) == 1


def test_mention_send_and_unread_state_commit_together(chat):
    api, path, (owner, recipient, outsider) = chat
    group = make_group(path, owner, "10000001", "Atomic", recipient)
    body = {
        "conversation": group_ref(group),
        "client_nonce": "atomic",
        "content": [{"type": "text", "text": "@ recipient"}],
    }

    def send(*accounts):
        return api.post(
            "/messages",
            headers=owner[1],
            json={**body, "mentioned_accounts": list(accounts)},
        )

    assert send(outsider[0]).status_code == 422
    with sqlite3.connect(path) as db:
        db.execute(
            """CREATE TRIGGER fail_mentions BEFORE INSERT ON chat_unread_alerts
            BEGIN SELECT RAISE(ABORT,'injected'); END"""
        )
    assert send(recipient[0]).status_code == 503
    with sqlite3.connect(path) as db:
        for table in ("messages", "operations", "chat_unread_alerts"):
            assert db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0] == 0
        assert (
            db.execute(
                "SELECT COUNT(*) FROM events WHERE message_id IS NOT NULL"
            ).fetchone()[0]
            == 0
        )
        db.execute("DROP TRIGGER fail_mentions")
    assert send(recipient[0]).json()["position"] == 1
    assert send().status_code == 409
    assert (
        api.post(
            "/messages",
            headers=owner[1],
            json={
                "target_account": recipient[0],
                "client_nonce": "direct",
                "content": body["content"],
                "mentioned_accounts": [recipient[0]],
            },
        ).status_code
        == 422
    )


def test_shared_alerts_deduplicate_mixed_message_and_include_reply_only_direct(chat):
    api, path, (owner, recipient, outsider) = chat
    group = make_group(path, owner, "10000001", "Mixed", recipient)
    content = [{"type": "text", "text": "Synthetic message"}]
    group_message = api.post(
        "/messages",
        headers=owner[1],
        json={
            "conversation": group_ref(group),
            "content": content,
            "client_nonce": "mixed",
            "mentioned_accounts": [recipient[0]],
        },
    ).json()
    direct_message = test_chat.send(api, owner, recipient, "direct-reply").json()
    direct = "dm:" + ":".join(sorted((owner[0], recipient[0])))
    with connection(path, write=True) as db:
        for conversation, message in ((group, group_message), (direct, direct_message)):
            record_reply(db, conversation, message["position"], owner[0], recipient[0])
        record_reply(db, direct, direct_message["position"], owner[0], owner[0])

    def post(route, who=recipient, **data):
        response = api.post(route, headers=who[1], json=data)
        assert response.status_code == 200
        return response.json()

    summary = post(SUMMARY_PATH)["items"]
    assert [
        (row["conversation_id"], row["unread_mention_count"], row["unread_reply_count"])
        for row in summary
    ] == [(direct, 0, 1), (group, 1, 1)]
    assert summary[0]["display_name"] == "Alice"
    assert post(SUMMARY_PATH, who=owner)["items"] == []
    assert post(SUMMARY_PATH, who=outsider)["items"] == []
    assert (
        api.post(
            LIST_PATH, headers=outsider[1], json={"conversation_id": direct}
        ).status_code
        == 404
    )
    mixed = {
        "message_id": group_message["id"],
        "position": group_message["position"],
        "mention": True,
        "reply": True,
    }
    assert summary[1]["latest_alert"] == mixed
    assert post(LIST_PATH, conversation_id=group) == {
        "items": [mixed],
        "next_cursor": None,
    }
    assert post(SUMMARY_PATH)["items"] == summary
    assert post(
        SEEN_PATH, conversation_id=group, message_ids=[group_message["id"]]
    ) == {"unread_mention_count": 0, "unread_reply_count": 0}
    assert post(LIST_PATH, conversation_id=group)["items"] == []
    assert post(SUMMARY_PATH)["items"] == summary[:1]
    with connection(path, write=True) as db:
        set_group_membership(db, group, recipient[0], False, NOW)
    after_leave = api.post(
        "/messages",
        headers=owner[1],
        json={
            "conversation": group_ref(group),
            "content": content,
            "client_nonce": "after-leave",
        },
    )
    assert after_leave.status_code == 200
    with connection(path, write=True) as db:
        record_reply(db, group, after_leave.json()["position"], owner[0], recipient[0])
        set_group_membership(db, group, recipient[0], True, NOW)
    assert post(LIST_PATH, conversation_id=group)["items"] == []
