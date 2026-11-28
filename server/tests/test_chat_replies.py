import os
import sqlite3

from bb_auth_contract.chat_alerts import LIST_PATH, SEEN_PATH, SUMMARY_PATH
from bb_auth_contract.conversation import direct_id
from bb_auth_contract.replies import DIRECT_PATH, UNREAD_PATH
from test_admin_http import free_port, running
from test_chat import chat, send  # noqa: F401

from bb_server.chat_store import (
    create_group_conversation,
    group_ref,
    set_group_membership,
)
from bb_server.storage import connection


def post(api, who, path, body, status=200):
    result = api.post(path, headers=who[1], json=body)
    assert result.status_code == status, result.text
    return result.json()


def reply_body(target, original, nonce, **fields):
    return {
        "conversation": target,
        "reply_to_message_id": original["id"],
        "client_nonce": nonce,
        "content": [{"type": "text", "text": nonce}],
        **fields,
    }


def login(api, username):
    registered = api.post(
        "/auth/register", json={"username": username, "password": "Abc123"}
    )
    assert registered.status_code == 201, registered.text
    account = registered.json()["account"]
    logged_in = api.post("/auth/login", json={"account": account, "password": "Abc123"})
    assert logged_in.status_code == 200, logged_in.text
    return account, {"Authorization": "Bearer " + logged_in.json()["token"]}


def test_reply_cli_restart_rollback_replay_and_conversation_acl(tmp_path):
    port = free_port()
    url = f"http://127.0.0.1:{port}"
    database = tmp_path / "reply.db"
    env = {
        **os.environ,
        "BB_DATABASE_PATH": str(database),
        "BB_AVATAR_DIRECTORY": str(tmp_path / "avatar"),
        "BB_MEDIA_DIRECTORY": str(tmp_path / "media"),
        "BB_HOST": "127.0.0.1",
        "BB_PORT": str(port),
    }
    with running("bb-server", env, url, tmp_path / "first.log") as api:
        alice, bob, carol = [login(api, name) for name in ("Alice", "Bob", "Carol")]
        target = {"type": "direct", "id": direct_id(alice[0], bob[0])}
        original = send(api, alice, bob, "original", "测试原文").json()
        other = send(api, bob, carol, "other", "其他会话").json()
        body = reply_body(target, original, "reply")
        assert (
            post(
                api, bob, "/messages", {**body, "reply_to_message_id": other["id"]}, 404
            )["error"]["code"]
            == "not_found"
        )
        with sqlite3.connect(database) as db:
            db.execute(
                "CREATE TRIGGER fail_reply BEFORE INSERT ON operations "
                "BEGIN SELECT RAISE(ABORT,'injected'); END"
            )
        post(api, bob, "/messages", body, 503)
        with sqlite3.connect(database) as db:
            for table, count in {
                "messages": 2,
                "events": 4,
                "operations": 2,
                "chat_unread_alerts": 0,
                "chat_replies": 0,
            }.items():
                assert db.execute(f"SELECT count(*) FROM {table}").fetchone() == (
                    count,
                )
            db.execute("DROP TRIGGER fail_reply")
        sent = post(api, bob, "/messages", body)
        assert sent["position"] == original["position"] + 1
        assert sent["reply_to"] == {
            "message_id": original["id"],
            "sender_account": alice[0],
            "sender_username": "Alice",
            "preview": "测试原文",
        }

    with running("bb-server", env, url, tmp_path / "restart.log") as api:
        assert post(api, bob, "/messages", body) == sent
        operation = api.get("/operations/reply", headers=bob[1]).json()
        assert operation["message"] == sent
        assert (
            post(
                api, bob, "/messages", {**body, "reply_to_message_id": sent["id"]}, 409
            )["error"]["code"]
            == "conflict"
        )
        reply = post(api, alice, UNREAD_PATH, {"conversation_id": target["id"]})[
            "items"
        ]
        assert [(r["reply"]["id"], r["original"]) for r in reply] == [
            (sent["id"], original)
        ]
        listing = {"original_message_id": original["id"]}
        assert post(api, bob, DIRECT_PATH, listing)["items"][0]["id"] == sent["id"]
        post(api, carol, DIRECT_PATH, listing, 404)
        post(api, carol, UNREAD_PATH, {"conversation_id": target["id"]}, 404)
        summary = post(api, alice, SUMMARY_PATH, {})["items"]
        assert [
            (row["conversation_id"], row["unread_reply_count"]) for row in summary
        ] == [(target["id"], 1)]


def test_group_direct_edges_and_unread_are_independent(chat):  # noqa: F811
    api, db_path, (alice, bob, carol) = chat
    now = "2026-11-28T12:00:00.000Z"
    with connection(db_path, write=True) as db:
        group = create_group_conversation(db, bob[0], "10000001", "Study", "", now)
        for member in (alice, carol):
            set_group_membership(db, group, member[0], True, now)
    ref = group_ref(group)
    scope = {"conversation_id": group}
    a = post(
        api,
        alice,
        "/messages",
        {
            "conversation": ref,
            "client_nonce": "a",
            "content": [{"type": "text", "text": "a"}],
        },
    )
    b = post(
        api, bob, "/messages", reply_body(ref, a, "b", mentioned_accounts=[alice[0]])
    )
    c = post(api, carol, "/messages", reply_body(ref, a, "c"))
    d = post(api, carol, "/messages", reply_body(ref, b, "d"))
    own = post(api, alice, "/messages", reply_body(ref, a, "own"))
    thread = {"original_message_id": a["id"]}
    newest = post(api, carol, DIRECT_PATH, {**thread, "limit": 1})
    assert [item["id"] for item in newest["items"]] == [own["id"]]
    rest = post(
        api, carol, DIRECT_PATH, {**thread, "before_position": newest["next_cursor"]}
    )
    assert [item["id"] for item in rest["items"]] == [c["id"], b["id"]]
    assert rest["next_cursor"] is None
    nested = post(api, alice, DIRECT_PATH, {"original_message_id": b["id"]})
    assert [item["id"] for item in nested["items"]] == [d["id"]]
    assert all(
        r["original"]["id"] == a["id"]
        for r in post(api, alice, UNREAD_PATH, scope)["items"]
    )
    first = post(api, alice, UNREAD_PATH, {**scope, "limit": 1})
    assert first["items"][0]["reply"]["id"] == c["id"]
    earlier = {**scope, "before_position": first["next_cursor"]}
    assert post(api, alice, UNREAD_PATH, earlier)["items"][0]["reply"]["id"] == b["id"]
    assert len(post(api, alice, UNREAD_PATH, scope)["items"]) == 2
    alerts = post(api, alice, LIST_PATH, scope)["items"]
    assert [
        (item["message_id"], item["mention"], item["reply"]) for item in alerts
    ] == [
        (c["id"], False, True),
        (b["id"], True, True),
    ]
    context = api.get(
        f"/messages/{b['id']}/context?before_limit=0&after_limit=0", headers=alice[1]
    )
    assert context.json()["items"][0]["reply_to"]["message_id"] == a["id"]
    assert context.json()["reply_relations"] == "inline"
    assert post(api, alice, SEEN_PATH, {**scope, "message_ids": [b["id"]]}) == {
        "unread_mention_count": 0,
        "unread_reply_count": 1,
    }
    assert [
        r["reply"]["id"] for r in post(api, alice, UNREAD_PATH, scope)["items"]
    ] == [c["id"]]
    assert len(post(api, alice, DIRECT_PATH, thread)["items"]) == 3
    assert [r["reply"]["id"] for r in post(api, bob, UNREAD_PATH, scope)["items"]] == [
        d["id"]
    ]

    with connection(db_path, write=True) as db:
        set_group_membership(db, group, alice[0], False, now)
    post(api, alice, UNREAD_PATH, scope, 404)
    post(api, alice, DIRECT_PATH, thread, 404)
    post(api, bob, "/messages", reply_body(ref, a, "absent"))
    with connection(db_path, write=True) as db:
        set_group_membership(db, group, alice[0], True, now)
    assert post(api, alice, UNREAD_PATH, scope)["items"] == []
    assert len(post(api, alice, DIRECT_PATH, thread)["items"]) == 4
