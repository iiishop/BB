"""General BB notice persistence. Space uses its existing independent store."""

import uuid

from bb_auth_contract import ContractError

from .chat_store import missing

INVITATION = "group_invitation"
APPLICATION = "group_application"
ACTIONS = {
    INVITATION: {"accept": "接受", "reject": "拒绝"},
    APPLICATION: {"approve": "同意", "reject": "拒绝"},
}


def insert(
    db, recipient, kind, title, text, now, *, link=None, request_id=None, initiator=None
):
    notice_id = uuid.uuid4().hex
    link_type, link_id = link or (None, None)
    db.execute(
        """INSERT INTO bb_notices
        (id,recipient,kind,title,text,created_at,link_type,link_id,request_id,initiator,state)
        VALUES (?,?,?,?,?,?,?,?,?,?,?)""",
        (
            notice_id,
            recipient,
            kind,
            title,
            text,
            now,
            link_type,
            link_id,
            request_id,
            initiator,
            "pending" if kind in ACTIONS else "informational",
        ),
    )
    db.execute(
        "INSERT INTO events(account,occurred_at,notification_id) VALUES (?,?,?)",
        (recipient, now, notice_id),
    )


def get(db, recipient, notice_id):
    row = db.execute(
        "SELECT * FROM bb_notices WHERE recipient=? AND id=?", (recipient, notice_id)
    ).fetchone()
    if row is None:
        missing()
    return row


def view(row):
    actions = (
        [
            {"id": action_id, "label": label, "available": True}
            for action_id, label in ACTIONS.get(row["kind"], {}).items()
        ]
        if row["state"] == "pending"
        else []
    )
    text = row["text"]
    if row["state"] == "processed":
        outcome = ACTIONS[row["kind"]][row["chosen_action"]]
        text += f"\n处理结果：已{outcome}"
    return {
        "id": row["id"],
        "type": row["kind"],
        "title": row["title"],
        "text": text,
        "created_at": row["created_at"],
        "read": bool(row["is_read"]),
        "state": row["state"],
        "actions": actions,
        "link": {"type": row["link_type"], "id": row["link_id"]}
        if row["link_type"] is not None
        else None,
    }


def page(db, recipient, body):
    before = get(db, recipient, body.cursor)["sequence"] if body.cursor else None
    bounds = " AND sequence<?" if before is not None else ""
    pending = " AND state='pending'" if body.filter == "pending" else ""
    params = (
        (recipient, before, body.limit + 1) if bounds else (recipient, body.limit + 1)
    )
    rows = db.execute(
        "SELECT * FROM bb_notices WHERE recipient=?"
        + bounds
        + pending
        + " ORDER BY sequence DESC LIMIT ?",
        params,
    ).fetchall()
    items = [view(row) for row in rows[: body.limit]]
    return {
        "items": items,
        "next_cursor": items[-1]["id"] if len(rows) > body.limit else None,
        "unread_count": db.execute(
            "SELECT count(*) FROM bb_notices WHERE recipient=? AND is_read=0",
            (recipient,),
        ).fetchone()[0],
        "pending_count": db.execute(
            "SELECT count(*) FROM bb_notices WHERE recipient=? AND state='pending'",
            (recipient,),
        ).fetchone()[0],
    }


def mark_read(db, recipient, notice_id):
    db.execute(
        "UPDATE bb_notices SET is_read=1 WHERE id=? AND recipient=? AND is_read=0",
        (notice_id, recipient),
    )
    return view(get(db, recipient, notice_id))


def check_action(row, action_id):
    if row["state"] == "processed" and row["chosen_action"] == action_id:
        return False
    if row["state"] != "pending" or action_id not in ACTIONS.get(row["kind"], {}):
        raise ContractError(409, "action_unavailable", "action_unavailable")
    return True
