"""Shared server-owned unread set, keyed by recipient and message position."""

from bb_auth_contract import ErrorResponse
from bb_auth_contract import chat_alerts as wire
from fastapi import Depends

from .chat_store import authorize
from .storage import connection

COUNTS = """
COALESCE(SUM(u.mention),0) AS unread_mention_count,
COALESCE(SUM(u.reply),0) AS unread_reply_count
"""


def record_mentions(db, conversation_id, position, accounts):
    db.executemany(
        """INSERT INTO chat_unread_alerts(account,conversation_id,position,mention)
        VALUES (?,?,?,1) ON CONFLICT(account,conversation_id,position) DO UPDATE SET mention=1""",
        ((account, conversation_id, position) for account in accounts),
    )


def record_reply(db, conversation_id, position, sender, original_author):
    """Record a reply in the original message-write transaction, after the new insert."""
    if original_author != sender:
        db.execute(
            """INSERT INTO chat_unread_alerts(account,conversation_id,position,reply)
            SELECT :recipient,c.id,:position,1 FROM chat_conversations c
            LEFT JOIN chat_group_members member ON member.conversation_id=c.id
              AND member.account=:recipient
            LEFT JOIN chat_groups g ON g.conversation_id=c.id
            WHERE c.id=:conversation AND (
              (c.kind='direct' AND :recipient IN (c.direct_low,c.direct_high))
              OR (g.status='active' AND member.active=1)
            )
            ON CONFLICT(account,conversation_id,position) DO UPDATE SET reply=1""",
            {
                "recipient": original_author,
                "conversation": conversation_id,
                "position": position,
            },
        )


def alert_item(row):
    return {
        "message_id": row["message_id"],
        "position": row["position"],
        "mention": bool(row["mention"]),
        "reply": bool(row["reply"]),
    }


def summary(path, account, body):
    with connection(path) as db:
        rows = db.execute(
            f"""WITH totals AS (
                SELECT u.conversation_id,{COUNTS},MAX(u.position) AS position
                FROM chat_unread_alerts u
                WHERE u.account=:account AND u.conversation_id>:after
                GROUP BY u.conversation_id
            )
            SELECT t.conversation_id,t.unread_mention_count,t.unread_reply_count,t.position,
                COALESCE(g.name,peer.username) AS display_name,
                latest.mention,latest.reply,m.id AS message_id
            FROM totals t JOIN chat_conversations c ON c.id=t.conversation_id
            JOIN chat_unread_alerts latest ON latest.account=:account
              AND latest.conversation_id=t.conversation_id AND latest.position=t.position
            JOIN messages m ON m.conversation_id=t.conversation_id AND m.position=t.position
            LEFT JOIN chat_groups g ON g.conversation_id=t.conversation_id
            LEFT JOIN chat_group_members gm ON gm.conversation_id=t.conversation_id AND gm.account=:account
            LEFT JOIN users peer ON peer.account=CASE WHEN c.direct_low=:account
                THEN c.direct_high WHEN c.direct_high=:account THEN c.direct_low END
            WHERE (c.kind='direct' AND peer.account IS NOT NULL)
               OR (g.status='active' AND gm.active=1)
            ORDER BY t.conversation_id LIMIT :limit""",
            {
                "account": account,
                "after": body.after_conversation_id or "",
                "limit": body.limit + 1,
            },
        ).fetchall()
    return {
        "items": [
            {
                "conversation_id": row["conversation_id"],
                "display_name": row["display_name"],
                "unread_mention_count": row["unread_mention_count"],
                "unread_reply_count": row["unread_reply_count"],
                "latest_alert": alert_item(row),
            }
            for row in rows[: body.limit]
        ],
        "next_cursor": rows[body.limit - 1]["conversation_id"]
        if len(rows) > body.limit
        else None,
    }


def details(path, account, body):
    with connection(path) as db:
        authorize(db, account, body.conversation_id)
        rows = db.execute(
            """SELECT m.id AS message_id,u.position,u.mention,u.reply
            FROM chat_unread_alerts u JOIN messages m USING(conversation_id,position)
            WHERE u.account=? AND u.conversation_id=? AND u.position<?
            ORDER BY u.position DESC LIMIT ?""",
            (
                account,
                body.conversation_id,
                body.before_position or 2**63 - 1,
                body.limit + 1,
            ),
        ).fetchall()
    items = [alert_item(row) for row in rows[: body.limit]]
    return {
        "items": items,
        "next_cursor": items[-1]["position"] if len(rows) > body.limit else None,
    }


def mark_seen(path, account, body):
    with connection(path, write=True) as db:
        authorize(db, account, body.conversation_id)
        markers = ",".join("?" for _ in body.message_ids)
        db.execute(
            f"""DELETE FROM chat_unread_alerts
            WHERE account=? AND conversation_id=? AND position IN (
                SELECT position FROM messages WHERE conversation_id=? AND id IN ({markers})
            )""",
            (account, body.conversation_id, body.conversation_id, *body.message_ids),
        )
        counts = db.execute(
            f"""SELECT {COUNTS} FROM chat_unread_alerts u
            WHERE u.account=? AND u.conversation_id=?""",
            (account, body.conversation_id),
        ).fetchone()
        return dict(counts)


def install(app, path, current_session, no_query, extra_routes):
    auth = Depends(current_session)
    routes = {
        wire.SUMMARY_PATH: (
            wire.AlertSummaryQuery,
            wire.ClientAlertSummaryPage,
            summary,
        ),
        wire.LIST_PATH: (wire.AlertQuery, wire.AlertPage, details),
        wire.SEEN_PATH: (wire.MarkAlertsSeen, wire.AlertCounts, mark_seen),
        **extra_routes,
    }

    def bind(request_model, handler, route):
        def endpoint(body: request_model, identity=auth):
            return handler(path, identity["account"], body)

        endpoint.__name__ = route.removeprefix("/chat/").replace("/", "_")
        return endpoint

    for route, (request_model, response_model, handler) in routes.items():
        app.add_api_route(
            route,
            bind(request_model, handler, route),
            methods=["POST"],
            response_model=response_model,
            responses={code: {"model": ErrorResponse} for code in (401, 404, 422, 503)},
            dependencies=[Depends(no_query)],
        )
