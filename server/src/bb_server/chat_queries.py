"""ACL-filtered history, message lookup, context, listing and replay."""

import json
from itertools import pairwise

from bb_auth_contract import ContractError
from bb_auth_contract.conversation import direct_id

from .avatars import default_version
from .chat_store import authorize, group_ref, missing
from .storage import connection


def project_messages(db, account, items, association=False):
    for item in items:
        item.pop("operation_id", None)
    own = {m["id"] for m in items if m.get("sender_account") == account}
    if not association or not own:
        return items
    markers = ",".join("?" for _ in own)
    rows = db.execute(
        f"SELECT message_id, operation_id FROM operations WHERE account=? AND message_id IN ({markers})",
        (account, *own),
    )
    operations = {}
    for row in rows:
        if row["message_id"] in operations:
            raise ContractError(503, "storage_unavailable", "ambiguous association")
        operations[row["message_id"]] = row["operation_id"]
    for item in items:
        if item["id"] in operations:
            item["operation_id"] = operations[item["id"]]
    return items


def find_message(db, account, message_id, association=False):
    row = db.execute(
        "SELECT conversation_id,payload FROM messages WHERE id=?", (message_id,)
    ).fetchone()
    if row is None:
        missing()
    peer = authorize(db, account, row["conversation_id"])
    item = project_messages(db, account, [json.loads(row["payload"])], association)[0]
    return item, row["conversation_id"], peer


def message(path, account, message_id, association=False):
    with connection(path) as db:
        return find_message(db, account, message_id, association)[0]


def select_history(
    db, account, conversation_id, after, before, limit, association=False
):
    if after is not None and before is not None:
        raise ContractError(422, "validation_error", "exclusive history boundaries")
    backward = before is not None
    rows = db.execute(
        "SELECT payload FROM messages WHERE conversation_id=? AND position "
        + ("<? ORDER BY position DESC" if backward else ">? ORDER BY position ASC")
        + " LIMIT ?",
        (conversation_id, before if backward else (after or 0), limit + 1),
    ).fetchall()
    items = [json.loads(row[0]) for row in rows[:limit]]
    project_messages(db, account, items, association)
    if backward:
        items.reverse()
    return {
        "items": items,
        "next_position": (
            items[0 if backward else -1]["position"]
            if items
            else before
            if backward
            else (after or 0)
        ),
        "has_more": len(rows) > limit,
    }


def history(path, account, conversation_id, after, before, limit, association=False):
    with connection(path) as db:
        authorize(db, account, conversation_id)
        return select_history(
            db, account, conversation_id, after, before, limit, association
        )


DIRECT_CONVERSATIONS = """
 SELECT id,direct_high AS peer,last_position,created_at FROM chat_conversations
 WHERE direct_low=:account AND direct_high!=:account
 UNION ALL
 SELECT id,direct_low,last_position,created_at FROM chat_conversations
 WHERE direct_high=:account AND direct_low!=:account
"""
DIRECT_LIST = """
 SELECT d.id,d.peer,u.username AS name,d.last_position,d.created_at,
        NULL AS group_number,NULL AS avatar_version,NULL AS history_through,
        NULL AS membership_revision
 FROM direct d JOIN users u ON u.account=d.peer
"""
GROUP_LIST = """
 SELECT c.id,NULL,g.name,c.last_position,c.created_at,g.group_number,
        g.avatar_version,m.history_through,m.membership_revision
 FROM chat_group_members m JOIN chat_groups g USING(conversation_id)
 JOIN chat_conversations c ON c.id=m.conversation_id
 WHERE m.account=:account AND m.active=1 AND g.status='active'
"""


def conversations(path, account, after, limit, association=False, *, shared=False):
    own = DIRECT_LIST + (" UNION ALL " + GROUP_LIST if shared else "")
    key = "id" if shared else "peer"
    with connection(path) as db:
        rows = db.execute(
            f"""WITH direct AS ({DIRECT_CONVERSATIONS}), own AS ({own}),
            page AS (SELECT * FROM own WHERE {key}>:after ORDER BY {key} LIMIT :limit)
            SELECT page.*,m.payload FROM page LEFT JOIN messages m
            ON m.conversation_id=page.id AND m.position=page.last_position
            ORDER BY page.{key}""",
            {"account": account, "after": after, "limit": limit + 1},
        ).fetchall()
        messages = {}
        for row in rows[:limit]:
            if row["payload"] is not None:
                messages[row["id"]] = json.loads(row["payload"])
        project_messages(db, account, messages.values(), association)
    items = []
    for row in rows[:limit]:
        item = messages.get(row["id"])
        entry = {
            "display_name": row["name"],
            "last_message": item,
            "last_activity_at": item["created_at"] if item else row["created_at"],
            "latest_position": row["last_position"],
        }
        if row["peer"] is not None:
            entry["peer_account"] = row["peer"]
            if shared:
                entry["conversation"] = {"type": "direct", "id": row["id"]}
        else:
            number = row["group_number"]
            entry.update(
                conversation=group_ref(row["id"]),
                group_number=number,
                avatar_url=f"/chat/groups/{number}/avatar",
                avatar_version=row["avatar_version"] or default_version(number),
                history_through=row["history_through"],
                membership_revision=row["membership_revision"],
            )
        items.append(entry)
    return {
        "items": items,
        "next_cursor": rows[limit - 1][key] if len(rows) > limit else None,
    }


def context(path, account, message_id, before_limit, after_limit, association=False):
    with connection(path) as db:
        anchor, conversation_id, peer = find_message(
            db, account, message_id, association
        )
        before = select_history(
            db,
            account,
            conversation_id,
            None,
            anchor["position"],
            before_limit,
            association,
        )
        after = select_history(
            db,
            account,
            conversation_id,
            anchor["position"],
            None,
            after_limit,
            association,
        )
        items = before["items"] + [anchor] + after["items"]
        gaps = []
        gap_count = 0
        for left, right in pairwise(items):
            start, end = left["position"] + 1, right["position"]
            gap_count += max(0, end - start)
            gaps.extend(range(start, min(end, start + 100 - len(gaps))))
    target = (
        {"peer_account": peer} if peer else {"conversation": group_ref(conversation_id)}
    )
    return {
        **target,
        "items": items,
        "anchor_message_id": message_id,
        "range": {
            "start_position": items[0]["position"],
            "end_position": items[-1]["position"],
        },
        "before_has_more": before["has_more"],
        "after_has_more": after["has_more"],
        "missing_positions": gaps,
        "missing_truncated": gap_count > len(gaps),
        "reply_relations": "unsupported",
    }


_ACCOUNT_ONLINE = """EXISTS(SELECT 1 FROM sessions s WHERE s.account=a.account
    AND s.status='online' AND s.last_seen_at > ? - 90)"""


def directory_rows(db, account, after, limit, now, *, conversation_id=None):
    scope = "a.account!=?"
    identity = account
    if conversation_id is not None:
        scope = """EXISTS(SELECT 1 FROM chat_group_members m
            WHERE m.account=a.account AND m.conversation_id=? AND m.active=1)"""
        identity = conversation_id
    return db.execute(
        f"""SELECT a.account,a.username,a.avatar_version,{_ACCOUNT_ONLINE} AS online
        FROM users a WHERE {scope} AND a.account>? ORDER BY a.account LIMIT ?""",
        (now, identity, after, limit + 1),
    ).fetchall()


def group_member_counts(db, conversation_id, now):
    row = db.execute(
        f"""SELECT COALESCE(SUM({_ACCOUNT_ONLINE}),0) AS online, COUNT(*) AS total
        FROM chat_group_members a WHERE a.conversation_id=? AND a.active=1""",
        (now, conversation_id),
    ).fetchone()
    return {"online": row["online"], "total": row["total"]}


def user_card(row):
    account = row["account"]
    return {
        "account": account,
        "username": row["username"],
        "avatar_url": f"/avatars/{account}.png",
        "avatar_version": row["avatar_version"] or default_version(account),
        "presence": "online" if row["online"] else "offline",
    }


def latest_direct_message(db, account, peer):
    row = db.execute(
        "SELECT payload FROM messages WHERE conversation_id=? ORDER BY position DESC LIMIT 1",
        (direct_id(account, peer),),
    ).fetchone()
    return json.loads(row[0]) if row else None


def event_head(db, account, *, include_groups):
    return db.execute(
        "SELECT COALESCE(MAX(event_id),0) FROM events WHERE account=?"
        + ("" if include_groups else " AND peer IS NOT NULL"),
        (account,),
    ).fetchone()[0]


def event_page(path, account, after, limit, include_groups=False):
    group_filter = (
        """
        OR e.notification_id IS NOT NULL
        OR (m.membership_revision=e.membership_revision
            AND (e.active=0 OR
                 (m.active=1 AND g.status='active'
                  AND (e.active=1 OR e.position>m.history_through))))
    """
        if include_groups
        else ""
    )
    joins = (
        """
        LEFT JOIN chat_group_members m ON m.conversation_id=e.conversation_id AND m.account=e.account
        LEFT JOIN chat_groups g ON g.conversation_id=e.conversation_id
    """
        if include_groups
        else ""
    )
    with connection(path) as db:
        rows = db.execute(
            f"""SELECT e.* FROM events e {joins}
            WHERE e.account=? AND e.event_id>? AND (e.peer IS NOT NULL {group_filter})
            ORDER BY e.event_id LIMIT ?""",
            (account, after, limit + 1),
        ).fetchall()
        more = len(rows) > limit
        if more:
            cursor = rows[limit - 1]["event_id"]
        else:
            cursor = max(after, event_head(db, account, include_groups=include_groups))
    items = []
    for row in rows[:limit]:
        item = {
            "version": 1,
            "event_id": row["event_id"],
            "occurred_at": row["occurred_at"],
        }
        if row["notification_id"] is not None:
            item.update(
                type="notification.available", notification_id=row["notification_id"]
            )
        elif row["message_id"] is not None:
            item.update(
                type="message.available",
                message_id=row["message_id"],
                position=row["position"],
            )
            if row["peer"] is not None:
                item["peer_account"] = row["peer"]
            else:
                item["conversation"] = group_ref(row["conversation_id"])
                item["membership_revision"] = row["membership_revision"]
        else:
            item.update(
                type="conversation.access_changed",
                conversation=group_ref(row["conversation_id"]),
                active=bool(row["active"]),
                membership_revision=row["membership_revision"],
                history_through=row["position"],
            )
        items.append(item)
    return {"items": items, "next_event_id": cursor, "has_more": more}
