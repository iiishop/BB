"""Reply links, quote projection and read-only reply queries."""

import json

from bb_auth_contract.replies import (
    DIRECT_PATH,
    UNREAD_PATH,
    DirectRepliesQuery,
    DirectReplyPage,
    UnreadRepliesQuery,
    UnreadReplyPage,
)

from . import chat_alerts, chat_queries, chat_store
from .storage import connection

END_POSITION = 9007199254740992


def original_for_send(db, conversation_id, message_id):
    # The send transaction has already authorized this conversation.
    row = db.execute(
        """SELECT m.payload, u.username FROM messages m
        LEFT JOIN users u ON u.account=m.sender
        WHERE m.conversation_id=? AND m.id=?""",
        (conversation_id, message_id),
    ).fetchone()
    if row is None:
        chat_store.missing()
    item = json.loads(row["payload"])
    return item, item.get("sender_username", row["username"])


def record_reply(db, conversation_id, message, original_author):
    db.execute(
        "INSERT INTO chat_replies(message_id, original_message_id) VALUES (?, ?)",
        (message["id"], message["reply_to"]["message_id"]),
    )
    if original_author is not None:
        chat_alerts.record_reply(
            db,
            conversation_id,
            message["position"],
            message["sender_account"],
            original_author,
        )


def _reply(account, db, row):
    item = chat_queries.project_messages(db, account, [json.loads(row["payload"])])[0]
    item.setdefault("sender_username", row["username"])
    # The result already has conversation scope from the request.
    item.pop("target_account", None)
    item.pop("conversation", None)
    return item


def unread_replies(path, account, query):
    with connection(path) as db:
        chat_store.authorize(db, account, query.conversation_id)
        rows = db.execute(
            """SELECT m.position, m.payload, u.username, original.payload AS original
            FROM chat_unread_alerts a
            JOIN messages m USING (conversation_id, position)
            JOIN chat_replies r ON r.message_id=m.id
            JOIN messages original ON original.id=r.original_message_id
            JOIN users u ON u.account=m.sender
            WHERE a.account=? AND a.conversation_id=? AND a.reply=1 AND a.position<?
            ORDER BY a.position DESC LIMIT ?""",
            (
                account,
                query.conversation_id,
                query.before_position or END_POSITION,
                query.limit + 1,
            ),
        ).fetchall()
        selected = rows[: query.limit]
        return {
            "items": [
                {
                    "reply": _reply(account, db, row),
                    "original": chat_queries.project_messages(
                        db, account, [json.loads(row["original"])]
                    )[0],
                }
                for row in selected
            ],
            "next_cursor": selected[-1]["position"]
            if len(rows) > query.limit
            else None,
        }


def direct_replies(path, account, query):
    with connection(path) as db:
        _, conversation_id, _ = chat_queries.find_message(
            db, account, query.original_message_id
        )
        rows = db.execute(
            """SELECT m.position, m.payload, u.username
            FROM chat_replies r
            JOIN messages m ON m.id=r.message_id
            JOIN users u ON u.account=m.sender
            WHERE r.original_message_id=? AND m.conversation_id=? AND m.position<?
            ORDER BY m.position DESC LIMIT ?""",
            (
                query.original_message_id,
                conversation_id,
                query.before_position or END_POSITION,
                query.limit + 1,
            ),
        ).fetchall()
        selected = rows[: query.limit]
        return {
            "items": [_reply(account, db, row) for row in selected],
            "next_cursor": selected[-1]["position"]
            if len(rows) > query.limit
            else None,
        }


ROUTES = {
    UNREAD_PATH: (UnreadRepliesQuery, UnreadReplyPage, unread_replies),
    DIRECT_PATH: (DirectRepliesQuery, DirectReplyPage, direct_replies),
}
