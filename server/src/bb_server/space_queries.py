"""Bounded live projections: no persisted content snapshots in notifications/events."""

import base64
import json

from bb_auth_contract import ContractError


def fail(status, code):
    raise ContractError(status, code, code)


def live_post(db, post_id):
    row = db.execute(
        "SELECT * FROM space_posts WHERE id=? AND deleted=0", (post_id,)
    ).fetchone()
    if row is None:
        fail(404, "not_found")
    return row


def own_draft(db, account, draft_id):
    row = db.execute(
        "SELECT * FROM space_drafts WHERE id=? AND author=?", (draft_id, account)
    ).fetchone()
    if row is None:
        fail(404, "not_found")
    return row


def author(db, account):
    row = db.execute(
        "SELECT username FROM users WHERE account=?", (account,)
    ).fetchone()
    return {
        "account": account,
        "username": row[0],
        "avatar_url": f"/avatars/{account}.png",
    }


def image(row):
    url = f"/space/images/{row['id']}"
    return {
        "image_id": row["id"],
        "filename": row["filename"],
        "mime_type": row["mime"],
        "byte_size": row["size"],
        "original_url": url,
        "thumbnail_url": url + "?variant=thumb",
    }


def images(db, field, value):
    assert field in ("draft_id", "post_id")
    return [
        image(row)
        for row in db.execute(
            f"SELECT * FROM space_images WHERE {field}=? ORDER BY position,id", (value,)
        )
    ]


def draft(db, row):
    return {
        "draft_id": row["id"],
        "version": row["version"],
        "state": row["state"],
        "text": row["text"],
        "reference_id": row["reference_id"],
        "images": images(db, "draft_id", row["id"]),
        "post_id": row["post_id"],
        "created_at": row["created_at"],
    }


def comment(db, row, account):
    parent = db.execute(
        "SELECT author FROM space_comments WHERE id=?", (row["reply_to_id"],)
    ).fetchone()
    return {
        "comment_id": row["id"],
        "post_id": row["post_id"],
        "root_id": row["root_id"],
        "reply_to_id": row["reply_to_id"],
        "reply_to_author": author(db, parent[0]) if parent else None,
        "author": author(db, row["author"]),
        "created_at": row["created_at"],
        "text": None if row["deleted"] else row["text"],
        "deleted": bool(row["deleted"]),
        "can_delete": row["author"] == account and not row["deleted"],
    }


def reference(db, post_id):
    if post_id is None:
        return None
    row = db.execute("SELECT * FROM space_posts WHERE id=?", (post_id,)).fetchone()
    result = {
        "post_id": post_id,
        "deleted": row is None or bool(row["deleted"]),
        "author": None,
        "text": None,
        "image": None,
    }
    if row and not row["deleted"]:
        first = db.execute(
            "SELECT * FROM space_images WHERE post_id=? ORDER BY position,id LIMIT 1",
            (post_id,),
        ).fetchone()
        result.update(
            author=author(db, row["author"]),
            text=row["text"][:240],
            image=image(first) if first else None,
        )
    return result


def count(db, table, post_id, extra=""):
    return db.execute(
        f"SELECT count(*) FROM {table} WHERE post_id=? {extra}", (post_id,)
    ).fetchone()[0]


def views(db, post_id):
    return db.execute(
        "SELECT coalesce(sum(count),0) FROM space_visitors WHERE post_id=?", (post_id,)
    ).fetchone()[0]


def post(db, row, account):
    pid = row["id"]
    roots = db.execute(
        "SELECT * FROM space_comments WHERE post_id=? AND reply_to_id IS NULL ORDER BY created_at,id LIMIT 5",
        (pid,),
    ).fetchall()
    branches = []
    for root in roots:
        replies = db.execute(
            "SELECT * FROM space_comments WHERE post_id=? AND root_id=? AND reply_to_id IS NOT NULL ORDER BY created_at,id LIMIT 3",
            (pid, root["id"]),
        ).fetchall()
        total = db.execute(
            "SELECT count(*) FROM space_comments WHERE post_id=? AND root_id=? AND reply_to_id IS NOT NULL",
            (pid, root["id"]),
        ).fetchone()[0]
        branches.append(
            {
                "root": comment(db, root, account),
                "replies": [comment(db, r, account) for r in replies],
                "remaining_replies": max(0, total - 3),
            }
        )
    root_count = count(db, "space_comments", pid, "AND reply_to_id IS NULL")
    return {
        "post_id": pid,
        "author": author(db, row["author"]),
        "created_at": row["created_at"],
        "text": row["text"],
        "images": images(db, "post_id", pid),
        "reference": reference(db, row["reference_id"]),
        "liked": bool(
            db.execute(
                "SELECT 1 FROM space_likes WHERE post_id=? AND account=? AND active=1",
                (pid, account),
            ).fetchone()
        ),
        "read": bool(
            db.execute(
                "SELECT 1 FROM space_reads WHERE post_id=? AND account=?",
                (pid, account),
            ).fetchone()
        ),
        "like_count": count(db, "space_likes", pid, "AND active=1"),
        "comment_count": count(db, "space_comments", pid, "AND deleted=0"),
        "root_count": root_count,
        "repost_count": db.execute(
            "SELECT count(*) FROM space_posts WHERE reference_id=? AND deleted=0",
            (pid,),
        ).fetchone()[0],
        "view_count": views(db, pid),
        "can_delete": row["author"] == account,
        "can_list_visitors": row["author"] == account,
        "preview_comments": branches,
        "remaining_roots": max(0, root_count - 5),
    }


def encode_cursor(scope, key):
    return (
        base64.urlsafe_b64encode(
            json.dumps([1, scope, key], separators=(",", ":")).encode()
        )
        .decode()
        .rstrip("=")
    )


def decode_cursor(cursor, scope, size):
    if cursor is None:
        return None
    try:
        version, actual_scope, key = json.loads(
            base64.b64decode(
                cursor + "=" * (-len(cursor) % 4), altchars=b"-_", validate=True
            )
        )
        if (
            version != 1
            or actual_scope != scope
            or not isinstance(key, list)
            or len(key) != size
            or any(not isinstance(x, str) for x in key)
        ):
            raise ValueError
        return key
    except (ValueError, TypeError, UnicodeError):
        fail(422, "validation_error")


def page(db, query, params, body, scope, fields, project, *, descending=False):
    """Internal keyset primitive. SQL/fields are constants owned by this module."""
    key = decode_cursor(body.cursor, scope, len(fields))
    if key is not None:
        query += (
            " AND ("
            + ",".join(fields)
            + ") "
            + ("<" if descending else ">")
            + " ("
            + ",".join("?" for _ in fields)
            + ")"
        )
        params = [*params, *key]
    query += (
        " ORDER BY "
        + ",".join(f + (" DESC" if descending else " ASC") for f in fields)
        + " LIMIT ?"
    )
    rows = db.execute(query, [*params, body.limit + 1]).fetchall()
    selected = rows[: body.limit]
    return {
        "items": [project(row) for row in selected],
        "has_more": len(rows) > body.limit,
        "next_cursor": encode_cursor(scope, [selected[-1][field] for field in fields])
        if len(rows) > body.limit
        else None,
    }


def notification(db, row):
    target = db.execute(
        "SELECT * FROM space_posts WHERE id=? AND deleted=0", (row["target_post_id"],)
    ).fetchone()
    accessible = target is not None
    snippet = None
    actors = [author(db, row["actor"])]
    total = 1
    if row["kind"] == "like":
        total = db.execute(
            "SELECT count(*) FROM space_likes WHERE post_id=? AND active=1 AND account!=?",
            (row["post_id"], row["recipient"]),
        ).fetchone()[0]
        actors = [
            author(db, r[0])
            for r in db.execute(
                "SELECT account FROM space_likes WHERE post_id=? AND active=1 AND account!=? ORDER BY account LIMIT 3",
                (row["post_id"], row["recipient"]),
            )
        ]
    elif row["comment_id"]:
        c = db.execute(
            "SELECT text,deleted FROM space_comments WHERE id=?", (row["comment_id"],)
        ).fetchone()
        accessible = accessible and c is not None and not c["deleted"]
        if accessible:
            snippet = c["text"][:240]
    elif accessible:
        snippet = target["text"][:240]
    return {
        "notification_id": row["id"],
        "kind": row["kind"],
        "post_id": row["post_id"],
        "comment_id": row["comment_id"],
        "target_post_id": row["target_post_id"],
        "version": row["version"],
        "ack_version": row["ack_version"],
        "unread": row["ack_version"] < row["version"],
        "accessible": accessible,
        "deleted": not accessible,
        "actors": actors,
        "actor_count": total,
        "snippet": snippet,
        "created_at": row["created_at"],
    }


VISIBLE_NOTIFICATIONS = """SELECT * FROM space_notifications WHERE recipient=? AND
 (kind!='like' OR EXISTS(SELECT 1 FROM space_posts p WHERE p.id=space_notifications.post_id AND p.deleted=1)
 OR EXISTS(SELECT 1 FROM space_likes l WHERE l.post_id=space_notifications.post_id AND l.active=1 AND l.account!=space_notifications.recipient))"""


def event_page(db, account, after, limit):
    rows = db.execute(
        "SELECT * FROM space_events WHERE event_id>? AND (recipient IS NULL OR recipient=?) ORDER BY event_id LIMIT ?",
        (after, account, limit + 1),
    ).fetchall()
    items = [
        {
            "version": 1,
            **{
                key: row[key]
                for key in (
                    "event_id",
                    "type",
                    "post_id",
                    "comment_id",
                    "notification_id",
                    "occurred_at",
                )
            },
        }
        for row in rows[:limit]
    ]
    return {
        "items": items,
        "next_event_id": items[-1]["event_id"] if items else after,
        "has_more": len(rows) > limit,
    }


def comment_context(db, account, body):
    target = db.execute(
        "SELECT * FROM space_comments WHERE id=?", (body.comment_id,)
    ).fetchone()
    if target is None:
        fail(404, "not_found")
    live_post(db, target["post_id"])
    root = db.execute(
        "SELECT * FROM space_comments WHERE id=?", (target["root_id"],)
    ).fetchone()
    parent = db.execute(
        "SELECT * FROM space_comments WHERE id=?", (target["reply_to_id"],)
    ).fetchone()
    scope = ["comments", account, target["post_id"], target["root_id"]]
    query = "SELECT * FROM space_comments WHERE post_id=? AND root_id=? AND reply_to_id IS NOT NULL"
    values = (target["post_id"], target["root_id"], target["created_at"], target["id"])
    before = db.execute(
        query + " AND (created_at,id)<(?,?) ORDER BY created_at DESC,id DESC LIMIT ?",
        (*values, body.radius + 1),
    ).fetchall()
    after = db.execute(
        query + " AND (created_at,id)>(?,?) ORDER BY created_at,id LIMIT ?",
        (*values, body.radius + 1),
    ).fetchall()
    window = (
        list(reversed(before[: body.radius]))
        + ([target] if target["reply_to_id"] else [])
        + after[: body.radius]
    )
    return {
        "post_id": target["post_id"],
        "root": comment(db, root, account),
        "target": comment(db, target, account),
        "parent": comment(db, parent, account) if parent else None,
        "nearby": [comment(db, r, account) for r in window],
        "before_cursor": encode_cursor(
            scope, [before[-1]["created_at"], before[-1]["id"]]
        )
        if len(before) > body.radius
        else None,
        "after_cursor": encode_cursor(
            scope, [window[-1]["created_at"], window[-1]["id"]]
        )
        if len(after) > body.radius and window
        else None,
    }


def read(db, account, action, body):
    if action == "overview":
        return {
            "contract": "dea481-space-v1",
            "unread_posts": db.execute(
                "SELECT count(*) FROM space_posts p WHERE deleted=0 AND NOT EXISTS(SELECT 1 FROM space_reads r WHERE r.post_id=p.id AND r.account=?)",
                (account,),
            ).fetchone()[0],
            "unread_notifications": db.execute(
                "SELECT count(*) FROM ("
                + VISIBLE_NOTIFICATIONS
                + " AND ack_version<version)",
                (account,),
            ).fetchone()[0],
            "latest_event_id": db.execute(
                "SELECT coalesce(max(event_id),0) FROM space_events WHERE recipient IS NULL OR recipient=?",
                (account,),
            ).fetchone()[0],
        }
    if action == "get_post":
        return post(db, live_post(db, body.post_id), account)
    if action == "list_posts":
        scope = [action, account, body.author, body.unread_only]
        key = decode_cursor(body.cursor, scope, 3)
        if key:
            if not key[2].isdigit() or len(key[2]) > 16:
                fail(422, "validation_error")
            upper = int(key[2])
        else:
            upper = db.execute(
                "SELECT coalesce(max(seq),0) FROM space_posts"
            ).fetchone()[0]
        query, params = "SELECT * FROM space_posts WHERE deleted=0 AND seq<=?", [upper]
        if body.author:
            query += " AND author=?"
            params.append(body.author)
        if body.unread_only:
            query += " AND NOT EXISTS(SELECT 1 FROM space_reads r WHERE r.post_id=space_posts.id AND r.account=?)"
            params.append(account)
        anchored = body.model_copy(
            update={"cursor": encode_cursor(scope, key[:2]) if key else None}
        )
        result = page(
            db,
            query,
            params,
            anchored,
            scope,
            ["created_at", "id"],
            lambda r: post(db, r, account),
            descending=True,
        )
        if result["next_cursor"]:
            next_key = decode_cursor(result["next_cursor"], scope, 2)
            result["next_cursor"] = encode_cursor(scope, [*next_key, str(upper)])
        return result
    if action == "get_draft":
        return draft(db, own_draft(db, account, body.draft_id))
    if action == "list_drafts":
        return page(
            db,
            "SELECT * FROM space_drafts WHERE author=? AND state='draft'",
            [account],
            body,
            [action, account],
            ["created_at", "id"],
            lambda r: draft(db, r),
            descending=True,
        )
    if action == "get_comment_context":
        return comment_context(db, account, body)
    if action == "list_notifications":
        return page(
            db,
            VISIBLE_NOTIFICATIONS
            + (" AND ack_version<version" if body.unread_only else ""),
            [account],
            body,
            [action, account, body.unread_only],
            ["created_at", "id"],
            lambda r: notification(db, r),
            descending=True,
        )
    if action == "get_operation":
        row = db.execute(
            "SELECT operation_id,action,resource_id,resource_version FROM space_operations WHERE account=? AND operation_id=?",
            (account, body.operation_id),
        ).fetchone()
        if row is None:
            fail(404, "not_found")
        return {"status": "succeeded", **dict(row)}
    if action == "read_events":
        return event_page(db, account, body.after_event_id, body.limit)
    row = live_post(db, body.post_id)
    if action == "get_view_summary":
        return {"post_id": body.post_id, "view_count": views(db, body.post_id)}
    if action == "list_visitors":
        if row["author"] != account:
            fail(403, "forbidden")
        return page(
            db,
            "SELECT * FROM space_visitors WHERE post_id=?",
            [body.post_id],
            body,
            [action, account, body.post_id],
            ["account"],
            lambda r: {
                "author": author(db, r["account"]),
                "count": r["count"],
                "last_visited_at": r["last_visited_at"],
            },
        )
    if action == "list_likes":
        return page(
            db,
            "SELECT account FROM space_likes WHERE post_id=? AND active=1",
            [body.post_id],
            body,
            [action, account, body.post_id],
            ["account"],
            lambda r: author(db, r["account"]),
        )
    if action == "list_comments":
        query = "SELECT * FROM space_comments WHERE post_id=?"
        params = [body.post_id]
        if body.root_id is None:
            query += " AND reply_to_id IS NULL"
        else:
            root = db.execute(
                "SELECT 1 FROM space_comments WHERE id=? AND post_id=? AND reply_to_id IS NULL",
                (body.root_id, body.post_id),
            ).fetchone()
            if root is None:
                fail(404, "not_found")
            query += " AND root_id=? AND reply_to_id IS NOT NULL"
            params.append(body.root_id)
        return page(
            db,
            query,
            params,
            body,
            ["comments", account, body.post_id, body.root_id],
            ["created_at", "id"],
            lambda r: comment(db, r, account),
        )
    raise AssertionError("unhandled space read")
