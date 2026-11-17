"""Serialized business writes and durable invalidation receipts in one database."""

import hashlib
import json
import re
import uuid
from datetime import UTC, datetime
from pathlib import PurePosixPath

from . import space_media
from .space_queries import fail, follow_state, live_post, own_draft


def now(clock):
    return (
        datetime.fromtimestamp(clock(), UTC)
        .isoformat(timespec="microseconds")
        .replace("+00:00", "Z")
    )


def set_follow(db, account, body, timestamp):
    prior = follow_state(db, account, body.target_account)
    if account == body.target_account:
        fail(422, "validation_error")
    if prior["following"] != body.following:
        if body.following:
            db.execute(
                "INSERT INTO space_follows VALUES (?,?)", (account, body.target_account)
            )
        else:
            db.execute(
                "DELETE FROM space_follows WHERE account=? AND target_account=?",
                (account, body.target_account),
            )
        db.execute(
            "INSERT INTO space_follow_versions VALUES (?,1) "
            "ON CONFLICT(account) DO UPDATE SET revision=revision+1",
            (account,),
        )
        event(db, timestamp, "follow.changed", recipient=account)
    return {"target_account": body.target_account, "following": body.following}


def event(
    db,
    timestamp,
    kind,
    *,
    recipient=None,
    post_id=None,
    comment_id=None,
    notification_id=None,
):
    db.execute(
        "INSERT INTO space_events(recipient,type,post_id,comment_id,notification_id,occurred_at) VALUES (?,?,?,?,?,?)",
        (recipient, kind, post_id, comment_id, notification_id, timestamp),
    )


def notify(
    db,
    timestamp,
    kind,
    actor,
    recipient,
    post_id,
    *,
    comment_id=None,
    target_post_id=None,
):
    if actor == recipient:
        return
    nid = uuid.uuid4().hex
    if kind == "like":
        row = db.execute(
            "SELECT id FROM space_notifications WHERE kind='like' AND post_id=? AND recipient=?",
            (post_id, recipient),
        ).fetchone()
        if row:
            nid = row[0]
            db.execute(
                "UPDATE space_notifications SET version=version+1 WHERE id=?", (nid,)
            )
        else:
            db.execute(
                "INSERT INTO space_notifications VALUES (?,?,?,?,?,?,?,?,0,?)",
                (nid, recipient, kind, post_id, None, post_id, actor, 1, timestamp),
            )
    else:
        db.execute(
            "INSERT INTO space_notifications VALUES (?,?,?,?,?,?,?,?,0,?)",
            (
                nid,
                recipient,
                kind,
                post_id,
                comment_id,
                target_post_id or post_id,
                actor,
                1,
                timestamp,
            ),
        )
    event(
        db,
        timestamp,
        "notification.changed",
        recipient=recipient,
        post_id=post_id,
        notification_id=nid,
    )


def editable(db, account, body):
    draft = own_draft(db, account, body.draft_id)
    if draft["state"] != "draft":
        fail(409, "invalid_state")
    if draft["version"] != body.expected_version:
        fail(409, "version_conflict")
    return draft


def source(db, reference_id):
    if reference_id is not None:
        row = db.execute(
            "SELECT * FROM space_posts WHERE id=? AND deleted=0", (reference_id,)
        ).fetchone()
        if row is None:
            fail(409, "source_deleted")
        return row
    return None


def mutate(db, directory, account, action, body, timestamp, upload=None):
    """No network/filesystem side effect is replayed after a receipt is found."""
    digest = hashlib.sha256(
        json.dumps(
            [action, body.model_dump()],
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
        ).encode()
    ).hexdigest()
    previous = db.execute(
        "SELECT * FROM space_operations WHERE account=? AND operation_id=?",
        (account, body.operation_id),
    ).fetchone()
    if previous:
        if previous["request_hash"] != digest:
            fail(409, "idempotency_conflict")
        return {
            "operation_id": body.operation_id,
            "status": "succeeded",
            "action": action,
            "resource_id": previous["resource_id"],
            "resource_version": previous["resource_version"],
        }
    resource_id, version = None, None
    if action == "create_draft":
        source(db, body.reference_id)
        resource_id, version = uuid.uuid4().hex, 1
        db.execute(
            "INSERT INTO space_drafts VALUES (?,?,?,?,?,?,?,?)",
            (
                resource_id,
                account,
                timestamp,
                1,
                "draft",
                body.text,
                body.reference_id,
                None,
            ),
        )
        event(db, timestamp, "draft.changed", recipient=account)
    elif action in ("update_draft", "add_image", "publish_draft", "delete_draft"):
        draft = editable(db, account, body)
        resource_id, version = draft["id"], draft["version"] + 1
        if action == "update_draft":
            source(db, body.reference_id)
            owned = {
                r[0]
                for r in db.execute(
                    "SELECT id FROM space_images WHERE draft_id=?", (draft["id"],)
                )
            }
            if not set(body.image_ids) <= owned:
                fail(422, "attachments_not_ready")
            space_media.release(db, "draft_id", draft["id"], body.image_ids)
            for position, mid in enumerate(body.image_ids):
                db.execute(
                    "UPDATE space_images SET position=? WHERE id=?", (position, mid)
                )
            db.execute(
                "UPDATE space_drafts SET text=?,reference_id=? WHERE id=?",
                (body.text, body.reference_id, draft["id"]),
            )
        elif action == "add_image":
            data, mime, blob = upload
            space_media.store(directory, data, blob)
            resource_id = uuid.uuid4().hex
            position = db.execute(
                "SELECT coalesce(max(position),-1)+1 FROM space_images WHERE draft_id=?",
                (draft["id"],),
            ).fetchone()[0]
            filename = (
                re.sub(
                    r"[\x00-\x1f\x7f]",
                    "_",
                    PurePosixPath(body.filename.replace("\\", "/")).name,
                )
                or "image"
            )
            db.execute(
                "INSERT INTO space_images VALUES (?,?,?,?,?,?,?,?)",
                (
                    resource_id,
                    blob,
                    filename,
                    mime,
                    len(data),
                    draft["id"],
                    None,
                    position,
                ),
            )
        elif action == "publish_draft":
            ref = source(db, draft["reference_id"])
            rows = db.execute(
                "SELECT blob FROM space_images WHERE draft_id=?", (draft["id"],)
            ).fetchall()
            if any(not (directory / r[0]).is_file() for r in rows):
                fail(422, "attachments_not_ready")
            if not draft["text"].strip() and not rows and ref is None:
                fail(422, "validation_error")
            resource_id = uuid.uuid4().hex
            db.execute(
                "INSERT INTO space_posts VALUES (?,?,?,?,?,0,(SELECT coalesce(max(seq),0)+1 FROM space_posts))",
                (resource_id, account, timestamp, draft["text"], draft["reference_id"]),
            )
            db.execute(
                "UPDATE space_images SET post_id=?,draft_id=NULL WHERE draft_id=?",
                (resource_id, draft["id"]),
            )
            db.execute(
                "UPDATE space_drafts SET state='published',text='',reference_id=NULL,post_id=? WHERE id=?",
                (resource_id, draft["id"]),
            )
            event(db, timestamp, "post.changed", post_id=resource_id)
            if ref:
                notify(
                    db,
                    timestamp,
                    "repost",
                    account,
                    ref["author"],
                    ref["id"],
                    target_post_id=resource_id,
                )
                event(db, timestamp, "post.changed", post_id=ref["id"])
        else:
            space_media.release(db, "draft_id", draft["id"])
            db.execute(
                "UPDATE space_drafts SET state='deleted',text='',reference_id=NULL WHERE id=?",
                (draft["id"],),
            )
        db.execute(
            "UPDATE space_drafts SET version=? WHERE id=?", (version, draft["id"])
        )
        event(db, timestamp, "draft.changed", recipient=account)
    elif action == "delete_post":
        post = live_post(db, body.post_id)
        if post["author"] != account:
            fail(403, "forbidden")
        resource_id = post["id"]
        space_media.release(db, "post_id", post["id"])
        for table in (
            "space_comments",
            "space_likes",
            "space_reads",
            "space_visits",
            "space_visitors",
        ):
            db.execute(f"DELETE FROM {table} WHERE post_id=?", (post["id"],))
        db.execute("UPDATE space_posts SET deleted=1,text='' WHERE id=?", (post["id"],))
        event(db, timestamp, "post.deleted", post_id=post["id"])
        # Source's repost count changed; existing references resolve tombstones.
        if post["reference_id"]:
            event(db, timestamp, "post.changed", post_id=post["reference_id"])
    elif action == "set_like":
        post = live_post(db, body.post_id)
        resource_id = post["id"]
        prior = db.execute(
            "SELECT active FROM space_likes WHERE post_id=? AND account=?",
            (post["id"], account),
        ).fetchone()
        if bool(prior and prior[0]) != body.liked:
            db.execute(
                "INSERT INTO space_likes VALUES (?,?,?) ON CONFLICT(post_id,account) DO UPDATE SET active=excluded.active",
                (post["id"], account, int(body.liked)),
            )
            if body.liked and prior is None:
                notify(db, timestamp, "like", account, post["author"], post["id"])
            elif account != post["author"]:
                nid = db.execute(
                    "SELECT id FROM space_notifications WHERE post_id=? AND kind='like'",
                    (post["id"],),
                ).fetchone()
                if nid:
                    event(
                        db,
                        timestamp,
                        "notification.changed",
                        recipient=post["author"],
                        post_id=post["id"],
                        notification_id=nid[0],
                    )
            event(db, timestamp, "post.changed", post_id=post["id"])
    elif action == "create_comment":
        post = live_post(db, body.post_id)
        parent = None
        if body.reply_to_id:
            parent = db.execute(
                "SELECT * FROM space_comments WHERE id=? AND post_id=? AND deleted=0",
                (body.reply_to_id, post["id"]),
            ).fetchone()
            if parent is None:
                fail(404, "not_found")
        resource_id = uuid.uuid4().hex
        db.execute(
            "INSERT INTO space_comments VALUES (?,?,?,?,?,?,?,0)",
            (
                resource_id,
                post["id"],
                account,
                timestamp,
                body.text,
                parent["root_id"] if parent else resource_id,
                body.reply_to_id,
            ),
        )
        notify(
            db,
            timestamp,
            "reply" if parent else "comment",
            account,
            parent["author"] if parent else post["author"],
            post["id"],
            comment_id=resource_id,
        )
        event(db, timestamp, "post.changed", post_id=post["id"])
    elif action == "delete_comment":
        comment = db.execute(
            "SELECT * FROM space_comments WHERE id=? AND deleted=0", (body.comment_id,)
        ).fetchone()
        if comment is None:
            fail(404, "not_found")
        live_post(db, comment["post_id"])
        if comment["author"] != account:
            fail(403, "forbidden")
        resource_id = comment["id"]
        db.execute(
            "UPDATE space_comments SET deleted=1,text=NULL WHERE id=?", (comment["id"],)
        )
        event(
            db,
            timestamp,
            "comment.deleted",
            post_id=comment["post_id"],
            comment_id=comment["id"],
        )
    elif action == "mark_read":
        for pid in set(body.post_ids):
            live_post(db, pid)
            if db.execute(
                "INSERT OR IGNORE INTO space_reads VALUES (?,?)", (pid, account)
            ).rowcount:
                event(db, timestamp, "read.changed", recipient=account, post_id=pid)
    elif action == "ack_notifications":
        for item in body.items:
            row = db.execute(
                "SELECT * FROM space_notifications WHERE id=? AND recipient=?",
                (item.notification_id, account),
            ).fetchone()
            if row is None:
                fail(404, "not_found")
            if item.version > row["version"]:
                fail(409, "version_conflict")
            if item.version > row["ack_version"]:
                db.execute(
                    "UPDATE space_notifications SET ack_version=? WHERE id=?",
                    (item.version, row["id"]),
                )
                event(
                    db,
                    timestamp,
                    "notification.changed",
                    recipient=account,
                    notification_id=row["id"],
                    post_id=row["post_id"],
                )
    else:
        raise AssertionError("unhandled space mutation")
    db.execute(
        "INSERT INTO space_operations VALUES (?,?,?,?,?,?)",
        (account, body.operation_id, digest, action, resource_id, version),
    )
    return {
        "operation_id": body.operation_id,
        "status": "succeeded",
        "action": action,
        "resource_id": resource_id,
        "resource_version": version,
    }


def visit(db, account, body, timestamp):
    live_post(db, body.post_id)
    prior = db.execute(
        "SELECT post_id FROM space_visits WHERE account=? AND visit_id=?",
        (account, body.visit_id),
    ).fetchone()
    if prior:
        if prior[0] != body.post_id:
            fail(409, "idempotency_conflict")
        return
    db.execute(
        "INSERT INTO space_visits VALUES (?,?,?)",
        (account, body.visit_id, body.post_id),
    )
    db.execute(
        "INSERT INTO space_visitors VALUES (?,?,1,?) ON CONFLICT(post_id,account) DO UPDATE SET count=count+1,last_visited_at=excluded.last_visited_at",
        (body.post_id, account, timestamp),
    )
    event(db, timestamp, "post.changed", post_id=body.post_id)
