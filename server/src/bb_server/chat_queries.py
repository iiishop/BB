"""One ACL-filtered SQLite query layer for history, direct lookup and context."""

import json
from itertools import pairwise

from bb_auth_contract import ContractError

from .storage import connection


def missing():
    raise ContractError(404, "not_found", "not_found")


def project_messages(db, account, items, association=False):
    """Project only an already authorized page, from the same read snapshot.

    Never store account-private metadata in the shared message payload.
    One batch lookup also covers context, summaries and submission replays.
    """
    for item in items:
        item.pop("operation_id", None)
    own = {m["id"] for m in items if m["sender_account"] == account}
    if not association or not own:
        return items
    markers = ",".join("?" for _ in own)
    rows = db.execute(
        f"SELECT message_id, operation_id FROM operations WHERE account=? AND message_id IN ({markers})",
        (account, *own),
    ).fetchall()
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
        "SELECT payload FROM messages WHERE id=? AND (sender=? OR target=?)",
        (message_id, account, account),
    ).fetchone()
    if row is None:
        missing()
    return project_messages(db, account, [json.loads(row[0])], association)[0]


def message(path, account, message_id, association=False):
    with connection(path) as db:
        return find_message(db, account, message_id, association)


def select_history(db, account, peer, after, before, limit, association=False):
    if after is not None and before is not None:
        raise ContractError(422, "validation_error", "exclusive history boundaries")
    backward = before is not None
    rows = db.execute(
        "SELECT payload FROM messages WHERE pair_low=? AND pair_high=? AND position "
        + ("<? ORDER BY position DESC" if backward else ">? ORDER BY position ASC")
        + " LIMIT ?",
        (*sorted([account, peer]), before if backward else (after or 0), limit + 1),
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


def history(path, account, peer, after, before, limit, association=False):
    with connection(path) as db:
        if (
            account == peer
            or not db.execute("SELECT 1 FROM users WHERE account=?", (peer,)).fetchone()
        ):
            missing()
        return select_history(db, account, peer, after, before, limit, association)


def conversations(path, account, after, limit, association=False):
    with connection(path) as db:
        # Peer keyset order does not move when a conversation gets new messages.
        rows = db.execute(
            "WITH own AS (SELECT *, CASE WHEN sender=? THEN target ELSE sender END AS peer "
            "FROM messages WHERE sender=? OR target=?), "
            "last AS (SELECT peer, MAX(position) AS pos FROM own GROUP BY peer) "
            "SELECT own.peer, own.payload, users.username FROM own JOIN last ON own.peer=last.peer AND own.position=last.pos JOIN users ON users.account=own.peer "
            "WHERE own.peer>? ORDER BY own.peer LIMIT ?",
            (account, account, account, after, limit + 1),
        ).fetchall()
        messages = project_messages(
            db, account, [json.loads(r["payload"]) for r in rows[:limit]], association
        )
    items = []
    for row, item in zip(rows[:limit], messages, strict=True):
        items.append(
            {
                "peer_account": row["peer"],
                "display_name": row["username"],
                "last_message": item,
                "last_activity_at": item["created_at"],
                "latest_position": item["position"],
            }
        )
    return {
        "items": items,
        "next_cursor": items[-1]["peer_account"] if len(rows) > limit else None,
    }


def context(path, account, message_id, before_limit, after_limit, association=False):
    with connection(path) as db:
        # One snapshot for the anchor and both pages. Read operations never consume.
        anchor = find_message(db, account, message_id, association)
        peer = (
            anchor["target_account"]
            if anchor["sender_account"] == account
            else anchor["sender_account"]
        )
        before = select_history(
            db, account, peer, None, anchor["position"], before_limit, association
        )
        after = select_history(
            db, account, peer, anchor["position"], None, after_limit, association
        )
        items = before["items"] + [anchor] + after["items"]
        gaps = []
        gap_count = 0
        for left, right in pairwise(items):
            start, end = left["position"] + 1, right["position"]
            gap_count += max(0, end - start)
            gaps.extend(range(start, min(end, start + 100 - len(gaps))))
    return {
        "items": items,
        "anchor_message_id": message_id,
        "peer_account": peer,
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
