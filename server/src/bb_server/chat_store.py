"""Shared chat writes and authorization. Mutating callers hold BEGIN IMMEDIATE."""

import json
import uuid
from datetime import UTC, datetime

from bb_auth_contract import ContractError
from bb_auth_contract.chat import SystemMessage
from bb_auth_contract.conversation import ConversationRef, direct_id


def missing():
    raise ContractError(404, "not_found", "not_found")


def timestamp(clock):
    return (
        datetime.fromtimestamp(clock(), UTC)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def group_ref(conversation_id):
    return {"type": "group", "id": conversation_id}


def direct_peer(db, account, conversation_id):
    _, low, high = conversation_id.split(":")
    if low >= high or account not in (low, high):
        missing()
    peer = high if account == low else low
    if db.execute("SELECT 1 FROM users WHERE account=?", (peer,)).fetchone() is None:
        missing()
    return peer


def active_membership(db, account, conversation_id):
    membership = db.execute(
        """SELECT m.* FROM chat_group_members m
        JOIN chat_groups g USING (conversation_id)
        WHERE m.conversation_id=? AND m.account=? AND m.active=1 AND g.status='active'""",
        (conversation_id, account),
    ).fetchone()
    if membership is None:
        missing()
    return membership


def authorize(db, account, conversation_id):
    """Return a legacy direct peer or None for an authorized group."""
    if conversation_id.startswith("dm:"):
        return direct_peer(db, account, conversation_id)
    active_membership(db, account, conversation_id)
    return None


def resolve_send(db, account, peer, conversation: ConversationRef | None):
    if conversation is None:
        conversation_id = direct_id(account, peer)
    else:
        conversation_id = conversation.id
    return conversation_id, authorize(db, account, conversation_id)


def ensure_direct(db, account, peer, created_at):
    low, high = sorted((account, peer))
    db.execute(
        """INSERT INTO chat_conversations(id,kind,direct_low,direct_high,created_at)
        VALUES (?,'direct',?,?,?) ON CONFLICT(id) DO NOTHING""",
        (direct_id(account, peer), low, high, created_at),
    )


def create_group_conversation(db, owner, group_number, name, description, created_at):
    """Establish an empty group and its owner atomically with lifecycle writes."""
    conversation_id = "group:" + uuid.uuid4().hex
    db.execute(
        "INSERT INTO chat_conversations(id,kind,created_at) VALUES (?,'group',?)",
        (conversation_id, created_at),
    )
    db.execute(
        """INSERT INTO chat_groups(conversation_id,group_number,owner,name,description)
        VALUES (?,?,?,?,?)""",
        (conversation_id, group_number, owner, name, description),
    )
    set_group_membership(db, conversation_id, owner, True, created_at)
    return conversation_id


def set_group_membership(db, conversation_id, account, active, occurred_at):
    """Persist a membership epoch and publish its cache/sync boundary once."""
    group = db.execute(
        """SELECT g.owner,g.status,c.last_position FROM chat_groups g
        JOIN chat_conversations c ON c.id=g.conversation_id WHERE g.conversation_id=?""",
        (conversation_id,),
    ).fetchone()
    if group is None:
        missing()
    if active and group["status"] != "active":
        raise ContractError(409, "group_unavailable", "group_unavailable")
    if not active and account == group["owner"] and group["status"] == "active":
        raise ContractError(403, "forbidden", "forbidden")
    prior = db.execute(
        "SELECT * FROM chat_group_members WHERE conversation_id=? AND account=?",
        (conversation_id, account),
    ).fetchone()
    if (prior is None and not active) or (
        prior is not None and prior["active"] == active
    ):
        return False
    revision = prior["membership_revision"] + 1 if prior else 1
    boundary = group["last_position"] if active else prior["history_through"]
    db.execute(
        """INSERT INTO chat_group_members VALUES (?,?,?,?,?)
        ON CONFLICT(conversation_id,account) DO UPDATE SET
        active=excluded.active,history_through=excluded.history_through,
        membership_revision=excluded.membership_revision""",
        (conversation_id, account, active, boundary, revision),
    )
    if not active:
        db.execute(
            "DELETE FROM chat_unread_alerts WHERE conversation_id=? AND account=?",
            (conversation_id, account),
        )
    db.execute(
        """INSERT INTO events(account,conversation_id,position,occurred_at,membership_revision,active)
        VALUES (?,?,?,?,?,?)""",
        (account, conversation_id, boundary, occurred_at, revision, active),
    )
    return True


def append_entry(
    db, conversation_id, fields, created_at, *, direct_accounts=None, media_ids=()
):
    position = db.execute(
        """UPDATE chat_conversations SET last_position=last_position+1
        WHERE id=? RETURNING last_position""",
        (conversation_id,),
    ).fetchone()[0]
    item = {
        "id": uuid.uuid4().hex,
        "position": position,
        "created_at": created_at,
        **fields,
    }
    db.execute(
        "INSERT INTO messages VALUES (?,?,?,?,?,?)",
        (
            item["id"],
            conversation_id,
            position,
            item.get("sender_account"),
            created_at,
            json.dumps(item, ensure_ascii=False),
        ),
    )
    if direct_accounts is None:
        db.executemany(
            "INSERT INTO chat_message_media VALUES (?,?)",
            ((item["id"], media_id) for media_id in dict.fromkeys(media_ids)),
        )
        db.execute(
            """INSERT INTO events(account,message_id,conversation_id,position,occurred_at,membership_revision)
            SELECT account,?,conversation_id,?,?,membership_revision FROM chat_group_members
            WHERE conversation_id=? AND active=1""",
            (item["id"], position, created_at, conversation_id),
        )
    else:
        first, second = direct_accounts
        db.executemany(
            """INSERT INTO events(account,message_id,conversation_id,peer,position,occurred_at)
            VALUES (?,?,?,?,?,?)""",
            (
                (first, item["id"], conversation_id, second, position, created_at),
                (second, item["id"], conversation_id, first, position, created_at),
            ),
        )
    return item


def append_system_message(db, conversation_id, event, text, occurred_at):
    """Called by the lifecycle transaction after a successful join or name edit."""
    group = db.execute(
        "SELECT 1 FROM chat_groups WHERE conversation_id=? AND status='active'",
        (conversation_id,),
    ).fetchone()
    if group is None:
        missing()
    fields = {
        "kind": "system",
        "conversation": group_ref(conversation_id),
        "system": event,
        "text": text,
    }
    item = append_entry(db, conversation_id, fields, occurred_at)
    # Validation failure unwinds both the append and its lifecycle transaction.
    return SystemMessage.model_validate(item).model_dump()
