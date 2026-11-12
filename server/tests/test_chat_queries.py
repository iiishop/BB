"""Real SQLite/FastAPI ACL, bidirectional pagination and one-query-layer evidence."""

import json
import sqlite3
from pathlib import Path

import pytest
from test_chat import chat as real_chat  # noqa: F401
from test_chat import send


@pytest.fixture
def chat(real_chat):  # noqa: F811
    return real_chat


CASES = json.loads(
    (Path(__file__).parents[1] / "contract/chat-v2-cases.json").read_text()
)


def test_existing_conversations_keyset_does_not_reorder_on_activity(chat):
    api, path, (a, b, c) = chat
    assert api.get("/conversations", headers=a[1]).json() == {
        "items": [],
        "next_cursor": None,
    }
    ab = send(api, a, b).json()
    assert send(api, b, c, "private").status_code == 200
    first = api.get("/conversations?limit=1", headers=a[1]).json()
    assert [x["peer_account"] for x in first["items"]] == [b[0]]
    assert first["items"][0]["last_message"] == ab
    assert first["next_cursor"] is None
    send(api, a, c, "second-peer")
    page = api.get("/conversations?limit=1", headers=a[1]).json()
    send(api, a, b, "new-activity")
    next_page = api.get(
        "/conversations",
        params={"after_account": page["next_cursor"], "limit": 1},
        headers=a[1],
    ).json()
    assert [x["peer_account"] for x in page["items"] + next_page["items"]] == sorted(
        [b[0], c[0]]
    )
    assert next_page["next_cursor"] is None
    # A query cannot create a consumption ledger or outbox entries.
    with sqlite3.connect(path) as db:
        assert db.execute("SELECT count(*) FROM events").fetchone()[0] == 8
    assert api.get("/conversations").status_code == 401


def test_shared_pagination_fixtures_and_legacy_default(chat):
    api, _, (a, b, _) = chat
    for position in range(1, 7):
        send(api, a if position % 2 else b, b if position % 2 else a, str(position))
    url = f"/conversations/{b[0]}/messages"
    for case in CASES["query_pagination"]:
        actual = api.get(url, params=case["request"], headers=a[1])
        assert actual.status_code == 200
        page = actual.json()
        assert [x["position"] for x in page["items"]] == case["positions"]
        assert page["next_position"] == case["next_position"]
        assert page["has_more"] == case["has_more"]
    assert len(api.get(url, headers=a[1]).json()["items"]) == 6
    assert (
        api.get(
            url, params={"before_position": 2, "after_position": 0}, headers=a[1]
        ).status_code
        == 422
    )
    assert api.get(url, params={"before_position": 0}, headers=a[1]).status_code == 422


def test_message_context_acl_consistency_limits_and_gaps(chat):
    api, path, (a, b, c) = chat
    messages = [send(api, a, b, str(n)).json() for n in range(1, 7)]
    anchor = messages[2]
    for who in (a, b):
        assert api.get("/messages/" + anchor["id"], headers=who[1]).json() == anchor
        value = api.get(
            "/messages/" + anchor["id"] + "/context",
            params={"before_limit": 1, "after_limit": 1},
            headers=who[1],
        ).json()
        assert value["items"] == messages[1:4]
        assert value["before_has_more"] and value["after_has_more"]
        assert value["reply_relations"] == "unsupported"
        assert value["missing_positions"] == []
        assert value["range"] == {"start_position": 2, "end_position": 4}
    for suffix in ("", "/context"):
        denied = api.get("/messages/" + anchor["id"] + suffix, headers=c[1])
        absent = api.get("/messages/absent" + suffix, headers=c[1])
        assert denied.status_code == absent.status_code == 404
        assert denied.json() == absent.json()
    assert (
        api.get(
            "/messages/" + anchor["id"] + "/context?before_limit=50", headers=a[1]
        ).status_code
        == 422
    )
    only = api.get(
        "/messages/" + anchor["id"] + "/context?before_limit=0&after_limit=0",
        headers=a[1],
    ).json()
    assert only["items"] == [anchor]
    assert only["before_has_more"] and only["after_has_more"]
    with sqlite3.connect(path) as db:
        db.execute("DELETE FROM messages WHERE position=2")
    gap = api.get("/messages/" + anchor["id"] + "/context", headers=a[1]).json()
    assert gap["missing_positions"] == [2] and gap["missing_truncated"] is False
