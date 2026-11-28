"""Server-owned unread set for explicitly selected group recipients."""

import json

from bb_auth_contract import ContractError
from bb_auth_contract import mentions as wire

from .chat_store import active_membership
from .storage import connection


def recipients(db, conversation_id, sender, accounts):
    if not accounts:
        return []
    markers = ",".join("?" for _ in accounts)
    rows = db.execute(
        f"""SELECT account FROM chat_group_members
        WHERE conversation_id=? AND active=1 AND account IN ({markers})""",
        (conversation_id, *accounts),
    ).fetchall()
    if len(rows) != len(accounts):
        raise ContractError(
            422, "validation_error", "Mentioned account is not a group member"
        )
    return [account for account in accounts if account != sender]


def details(path, account, body):
    with connection(path) as db:
        active_membership(db, account, body.conversation_id)
        rows = db.execute(
            """SELECT m.id AS message_id,m.position,m.sender AS sender_account,
              m.created_at,m.payload
            FROM chat_unread_alerts u JOIN messages m USING(conversation_id,position)
            WHERE u.account=? AND u.conversation_id=? AND u.mention=1 AND u.position<?
            ORDER BY u.position DESC LIMIT ?""",
            (
                account,
                body.conversation_id,
                body.before_position or 2**63 - 1,
                body.limit + 1,
            ),
        ).fetchall()
    items = []
    for row in rows[: body.limit]:
        fields = dict(row)
        message = json.loads(fields.pop("payload"))
        items.append(
            {
                **fields,
                "sender_username": message["sender_username"],
                "content": message["content"],
            }
        )
    return {
        "items": items,
        "next_cursor": items[-1]["position"] if len(rows) > body.limit else None,
    }


ROUTES = {wire.DETAIL_PATH: (wire.MentionQuery, wire.MentionPage, details)}
