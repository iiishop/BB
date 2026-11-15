"""Actual FastAPI/SQLite projection, including legacy strict response models."""

import json
import sqlite3
from pathlib import Path

import pytest
from bb_auth_contract.chat import Message, MessagePage, Operation
from bb_auth_contract.chat_association import (
    HEADER,
    AssociatedConversationPage,
    AssociatedMessage,
    AssociatedMessageContext,
    AssociatedMessagePage,
    AssociatedOperation,
)
from bb_auth_contract.chat_query import ConversationPage, MessageContext
from bb_server.app import create_app
from test_chat import chat as chat_fixture  # noqa: F401


@pytest.fixture
def chat(chat_fixture):  # noqa: F811
    return chat_fixture


def test_exported_association_schema_keeps_legacy_message_strict():
    stored = json.loads((Path(__file__).parents[1] / "openapi.json").read_text())
    assert stored == create_app(Path("unused-association-schema")).openapi()
    assert "operation_id" not in Message.model_fields
    assert Message.model_config["extra"] == "forbid"
    for path in [
        "/messages",
        "/messages/attachments",
        "/operations/{operation_id}",
        "/conversations/{account}/messages",
        "/conversations",
        "/messages/{message_id}",
        "/messages/{message_id}/context",
    ]:
        operation = next(iter(stored["paths"][path].values()))
        assert any(
            p["in"] == "header" and p["name"] == HEADER for p in operation["parameters"]
        )
        assert (
            operation["responses"]["200"]["headers"][HEADER]["schema"]["const"] == "1"
        )


@pytest.mark.parametrize("attachment", [False, True])
def test_all_message_surfaces_negotiate_owner_only_and_preserve_legacy(
    chat, attachment
):
    api, path, (a, b, c) = chat
    owner = {**a[1], HEADER: "1"}
    peer = {**b[1], HEADER: "1"}
    body = {"target_account": b[0], "client_nonce": "same-nonce"}
    route = "/messages"
    if attachment:
        media = api.post(
            "/media",
            headers=a[1],
            data={"target_account": b[0]},
            files={"file": ("x.txt", b"same", "text/plain")},
        ).json()
        body["media_id"] = media["media_id"]
        route += "/attachments"
    else:
        body["content"] = [{"type": "text", "text": "same"}]
    sent = api.post(route, headers=owner, json=body)
    assert sent.status_code == 200
    assert sent.headers[HEADER] == "1"
    message = AssociatedMessage.model_validate(sent.json()).model_dump(
        exclude_none=True
    )
    assert message["operation_id"] == "same-nonce"
    mid = message["id"]
    second = api.post(
        route, headers=owner, json={**body, "client_nonce": "second"}
    ).json()
    assert second["id"] != mid and second["operation_id"] == "second"
    legacy = api.post(route, headers=a[1], json=body)
    assert HEADER not in legacy.headers and "operation_id" not in legacy.json()
    Message.model_validate(legacy.json())
    assert legacy.json()["id"] == mid
    assert api.post(route, headers=owner, json=body).json()["id"] == mid
    endpoints = [
        (f"/messages/{mid}", Message, AssociatedMessage, lambda x: [x]),
        (
            f"/messages/{mid}/context",
            MessageContext,
            AssociatedMessageContext,
            lambda x: x["items"],
        ),
        (
            f"/conversations/{b[0]}/messages",
            MessagePage,
            AssociatedMessagePage,
            lambda x: x["items"],
        ),
        (
            "/conversations",
            ConversationPage,
            AssociatedConversationPage,
            lambda x: [i["last_message"] for i in x["items"]],
        ),
        (
            "/operations/same-nonce",
            Operation,
            AssociatedOperation,
            lambda x: [x["message"]],
        ),
    ]
    for endpoint, old_model, new_model, items in endpoints:
        for headers, negotiated in [
            (a[1], False),
            (owner, True),
            ({**a[1], HEADER: "999"}, False),
        ]:
            response = api.get(endpoint, headers=headers)
            assert response.status_code == 200
            (new_model if negotiated else old_model).model_validate(response.json())
            assert (response.headers.get(HEADER) == "1") == negotiated
            assert all(
                ("operation_id" in m) == negotiated for m in items(response.json())
            )
        if endpoint.startswith("/operations"):
            assert api.get(endpoint, headers=peer).status_code == 404
        else:
            peer_endpoint = endpoint.replace(
                f"/conversations/{b[0]}/", f"/conversations/{a[0]}/"
            )
            response = api.get(peer_endpoint, headers=peer)
            assert response.status_code == 200
            assert all("operation_id" not in m for m in items(response.json()))
            old_model.model_validate(response.json())
        assert api.get(endpoint, headers={HEADER: "1"}).status_code == 401
    for endpoint in [
        f"/messages/{mid}",
        f"/messages/{mid}/context",
        "/operations/same-nonce",
    ]:
        assert api.get(endpoint, headers={**c[1], HEADER: "1"}).status_code == 404
    # Other accounts may reuse a nonce: the mapping never crosses accounts.
    other = api.post(
        "/messages",
        headers=peer,
        json={
            "target_account": a[0],
            "client_nonce": "same-nonce",
            "content": [{"type": "text", "text": "same"}],
        },
    ).json()
    assert other["id"] != mid
    assert (
        api.get("/operations/same-nonce", headers=peer).json()["message"]["id"]
        == other["id"]
    )
    mixed = api.get(f"/conversations/{b[0]}/messages", headers=owner).json()["items"]
    assert all("operation_id" not in m for m in mixed if m["sender_account"] != a[0])
    with sqlite3.connect(path) as db:
        assert all(
            "operation_id" not in json.loads(row[0])
            for row in db.execute("SELECT payload FROM messages")
        )
    for headers in [owner, peer]:
        assert all(
            "operation_id" not in e
            for e in api.get("/events", headers=headers).json()["items"]
        )


def test_legacy_missing_and_ambiguous_association_never_guessed(chat):
    api, path, (a, b, _) = chat
    owner = {**a[1], HEADER: "1"}
    sent = api.post(
        "/messages",
        headers=a[1],
        json={
            "target_account": b[0],
            "client_nonce": "op",
            "content": [{"type": "text", "text": "same"}],
        },
    ).json()
    with sqlite3.connect(path) as db:
        original = db.execute("SELECT * FROM operations").fetchone()
        db.execute("DELETE FROM operations")
    result = api.get(f"/messages/{sent['id']}", headers=owner)
    assert result.status_code == 200 and "operation_id" not in result.json()
    with sqlite3.connect(path) as db:
        db.execute("INSERT INTO operations VALUES (?,?,?,?)", original)
        db.execute(
            "INSERT INTO operations VALUES (?,?,?,?)",
            (a[0], "ambiguous", original[2], sent["id"]),
        )
    assert api.get(f"/messages/{sent['id']}", headers=owner).status_code == 503
    assert api.get(f"/messages/{sent['id']}", headers=a[1]).status_code == 200
