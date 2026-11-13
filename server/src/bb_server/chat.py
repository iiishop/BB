"""SQLite-authoritative private chat and durable replay. All identities are server-derived."""

import asyncio
import hashlib
import io
import json
import os
import re
import uuid
from datetime import UTC, datetime
from typing import Annotated

import regex
from bb_auth_contract import ContractError, ErrorResponse
from bb_auth_contract.chat import (
    Account,
    EventPage,
    Media,
    Message,
    MessagePage,
    Operation,
    SendAttachment,
    SendMessage,
    UserPage,
)
from bb_auth_contract.chat_query import ConversationPage, MessageContext, MessageId
from fastapi import (
    Depends,
    File,
    Form,
    Query,
    UploadFile,
    WebSocket,
    WebSocketDisconnect,
)
from fastapi.responses import FileResponse
from PIL import Image as PILImage
from PIL import UnidentifiedImageError
from starlette.concurrency import run_in_threadpool

from . import chat_queries
from .avatars import default_version
from .storage import connection, find_session

MAX_MEDIA = 32 * 1024 * 1024
MIMES = {
    "image/png": "image",
    "image/jpeg": "image",
    "image/webp": "image",
    "video/mp4": "video",
    "video/webm": "video",
    "audio/mpeg": "audio",
    "audio/wav": "audio",
    "application/pdf": "document",
    "text/plain": "document",
    "application/octet-stream": "other",
}


def fail(status, code):
    raise ContractError(status, code, code)


def peer_exists(db, account, peer):
    if (
        account == peer
        or not db.execute("SELECT 1 FROM users WHERE account=?", (peer,)).fetchone()
    ):
        fail(404, "not_found")


def media_view(row):
    return {
        "media_id": row["id"],
        "media_type": row["kind"],
        "filename": row["filename"],
        "mime_type": row["mime"],
        "byte_size": row["size"],
        "cover_media_id": row["cover_id"],
    }


def readable_media(db, mid, account, peer=None):
    row = db.execute(
        "SELECT * FROM media WHERE id=? AND (owner=? OR peer=?)",
        (mid, account, account),
    ).fetchone()
    if not row or (peer and {row["owner"], row["peer"]} != {account, peer}):
        fail(404, "not_found")
    return row


def submit(path, account, body, clock):
    request = body.model_dump()
    digest = hashlib.sha256(
        json.dumps(
            request, sort_keys=True, separators=(",", ":"), ensure_ascii=False
        ).encode()
    ).hexdigest()
    with connection(path, write=True) as db:
        prior = db.execute(
            "SELECT * FROM operations WHERE account=? AND operation_id=?",
            (account, body.client_nonce),
        ).fetchone()
        if prior:
            if prior["request_hash"] != digest:
                fail(409, "conflict")
            return json.loads(
                db.execute(
                    "SELECT payload FROM messages WHERE id=?", (prior["message_id"],)
                ).fetchone()[0]
            )
        peer_exists(db, account, body.target_account)
        content, attachment = None, None
        if isinstance(body, SendMessage):
            content = request["content"]
            for part in content:
                if (
                    part["type"] == "image"
                    and readable_media(
                        db, part["media_id"], account, body.target_account
                    )["kind"]
                    != "image"
                ):
                    fail(422, "validation_error")
        else:
            row = readable_media(db, body.media_id, account, body.target_account)
            if row["kind"] == "image":
                fail(422, "validation_error")
            attachment = media_view(row)
        low, high = sorted([account, body.target_account])
        position = db.execute(
            "SELECT COALESCE(MAX(position),0)+1 FROM messages WHERE pair_low=? AND pair_high=?",
            (low, high),
        ).fetchone()[0]
        message = {
            "id": uuid.uuid4().hex,
            "position": position,
            "sender_account": account,
            "target_account": body.target_account,
            "created_at": datetime.fromtimestamp(clock(), UTC)
            .isoformat(timespec="milliseconds")
            .replace("+00:00", "Z"),
            "kind": "body" if content is not None else "attachment",
            "content": content,
            "attachment": attachment,
        }
        db.execute(
            "INSERT INTO messages VALUES (?,?,?,?,?,?,?,?)",
            (
                message["id"],
                low,
                high,
                position,
                account,
                body.target_account,
                message["created_at"],
                json.dumps(message, ensure_ascii=False),
            ),
        )
        db.execute(
            "INSERT INTO operations VALUES (?,?,?,?)",
            (account, body.client_nonce, digest, message["id"]),
        )
        for receiver, other in (
            (account, body.target_account),
            (body.target_account, account),
        ):
            db.execute(
                "INSERT INTO events(account,message_id,peer,position,occurred_at) VALUES (?,?,?,?,?)",
                (receiver, message["id"], other, position, message["created_at"]),
            )
        return message


def event_page(path, account, after, limit):
    with connection(path) as db:
        rows = db.execute(
            "SELECT * FROM events WHERE account=? AND event_id>? ORDER BY event_id LIMIT ?",
            (account, after, limit + 1),
        ).fetchall()
    items = [
        {
            "version": 1,
            "event_id": r["event_id"],
            "type": "message.available",
            "occurred_at": r["occurred_at"],
            "message_id": r["message_id"],
            "peer_account": r["peer"],
            "position": r["position"],
        }
        for r in rows[:limit]
    ]
    return {
        "items": items,
        "next_event_id": items[-1]["event_id"] if items else after,
        "has_more": len(rows) > limit,
    }


def preview(message):
    if message["kind"] == "body":
        value = "".join(
            p["text"] if p["type"] == "text" else "[图片]" for p in message["content"]
        )
    else:
        media = message["attachment"]
        value = {"video": "[视频]", "audio": "[音频]"}.get(
            media["media_type"], "[文件]"
        ) + media["filename"]
    clusters = regex.findall(r"\X", value)
    return "".join(clusters[:20]) + ("…" if len(clusters) > 20 else "")


def install(app, path, directory, current_session, clock):
    identity_dep = Depends(current_session)
    errors = {s: {"model": ErrorResponse} for s in (401, 404, 409, 413, 415, 422, 503)}

    @app.post("/messages", response_model=Message, responses=errors)
    def send(body: SendMessage, identity=identity_dep):
        return submit(path, identity["account"], body, clock)

    @app.post("/messages/attachments", response_model=Message, responses=errors)
    def attach(body: SendAttachment, identity=identity_dep):
        return submit(path, identity["account"], body, clock)

    @app.get("/operations/{operation_id}", response_model=Operation, responses=errors)
    def operation(operation_id: str, identity=identity_dep):
        with connection(path) as db:
            row = db.execute(
                "SELECT m.payload FROM operations o JOIN messages m ON m.id=o.message_id WHERE o.account=? AND o.operation_id=?",
                (identity["account"], operation_id),
            ).fetchone()
            if not row:
                fail(404, "not_found")
            return {
                "operation_id": operation_id,
                "kind": "message",
                "status": "succeeded",
                "message": json.loads(row[0]),
            }

    @app.get(
        "/conversations/{account}/messages",
        response_model=MessagePage,
        responses=errors,
    )
    def history(
        account: Account,
        after_position: int | None = Query(None, ge=0, le=9007199254740991),
        before_position: int | None = Query(None, ge=1, le=9007199254740991),
        limit: int = Query(50, ge=1, le=100),
        identity=identity_dep,
    ):
        return chat_queries.history(
            path, identity["account"], account, after_position, before_position, limit
        )

    @app.get("/conversations", response_model=ConversationPage, responses=errors)
    def conversations(
        after_account: str = Query("", pattern=r"^([1-9][0-9]{7})?$"),
        limit: int = Query(50, ge=1, le=100),
        identity=identity_dep,
    ):
        return chat_queries.conversations(
            path, identity["account"], after_account, limit
        )

    @app.get("/messages/{message_id}", response_model=Message, responses=errors)
    def get_message(message_id: MessageId, identity=identity_dep):
        return chat_queries.message(path, identity["account"], message_id)

    @app.get(
        "/messages/{message_id}/context",
        response_model=MessageContext,
        responses=errors,
    )
    def get_context(
        message_id: MessageId,
        before_limit: int = Query(10, ge=0, le=49),
        after_limit: int = Query(10, ge=0, le=49),
        identity=identity_dep,
    ):
        return chat_queries.context(
            path, identity["account"], message_id, before_limit, after_limit
        )

    @app.get("/users", response_model=UserPage, responses=errors)
    def users(
        after_account: str = Query("", pattern=r"^([1-9][0-9]{7})?$"),
        limit: int = Query(50, ge=1, le=100),
        identity=identity_dep,
    ):
        with connection(path) as db:
            rows = db.execute(
                "SELECT *, EXISTS(SELECT 1 FROM sessions s WHERE s.account=users.account AND s.status='online' AND s.last_seen_at>?) AS online FROM users WHERE account!=? AND account>? ORDER BY account LIMIT ?",
                (clock() - 90, identity["account"], after_account, limit + 1),
            ).fetchall()
            items = []
            for row in rows[:limit]:
                last = db.execute(
                    "SELECT payload FROM messages WHERE pair_low=? AND pair_high=? ORDER BY position DESC LIMIT 1",
                    tuple(sorted([identity["account"], row["account"]])),
                ).fetchone()
                m = json.loads(last[0]) if last else None
                sender = (
                    db.execute(
                        "SELECT username FROM users WHERE account=?",
                        (m["sender_account"],),
                    ).fetchone()[0]
                    if m
                    else None
                )
                items.append(
                    {
                        "account": row["account"],
                        "username": row["username"],
                        "avatar_url": f"/avatars/{row['account']}.png",
                        "avatar_version": row["avatar_version"]
                        or default_version(row["account"]),
                        "presence": "online" if row["online"] else "offline",
                        "last_contact_at": m["created_at"] if m else None,
                        "last_message": {
                            "id": m["id"],
                            "sender_account": m["sender_account"],
                            "sender_username": sender,
                            "preview_body": preview(m),
                        }
                        if m
                        else None,
                    }
                )
            return {
                "items": items,
                "next_cursor": items[-1]["account"] if len(rows) > limit else None,
            }

    @app.get("/events", response_model=EventPage, responses=errors)
    def replay(
        after_event_id: int = Query(0, ge=0),
        limit: int = Query(100, ge=1, le=500),
        identity=identity_dep,
    ):
        return event_page(path, identity["account"], after_event_id, limit)

    @app.websocket("/events")
    async def events(socket: WebSocket):
        auth = socket.headers.get("authorization", "")
        if socket.query_params or not auth.startswith("Bearer "):
            await socket.close(code=4401)
            return
        digest = hashlib.sha256(auth[7:].encode()).hexdigest()
        session = await run_in_threadpool(find_session, path, digest, clock())
        if session is None:
            await socket.close(code=4401)
            return
        await socket.accept()
        # A hint to replay durable history, never the sole delivery fact.
        after = 0
        try:
            while True:
                if await run_in_threadpool(find_session, path, digest, clock()) is None:
                    await socket.close(code=4401)
                    break
                page = await run_in_threadpool(
                    event_page, path, session["account"], after, 500
                )
                for item in page["items"]:
                    await socket.send_json(item)
                after = page["next_event_id"]
                # Receive permits immediate disconnect cleanup while idle.
                try:
                    await asyncio.wait_for(socket.receive_text(), timeout=1)
                except TimeoutError:
                    pass
        except WebSocketDisconnect:
            pass

    @app.post("/media", response_model=Media, responses=errors)
    def upload(
        target_account: Annotated[Account, Form()],
        file: Annotated[UploadFile, File()],
        cover_media_id: str | None = Form(None),
        identity=identity_dep,
    ):
        mime = file.content_type
        if mime not in MIMES:
            fail(415, "unsupported_media_type")
        data = file.file.read(MAX_MEDIA + 1)
        if not data or len(data) > MAX_MEDIA:
            fail(413, "payload_too_large")
        kind = MIMES[mime]
        if kind == "image":
            try:
                with PILImage.open(io.BytesIO(data)) as image:
                    if (
                        image.width * image.height > 16_000_000
                        or image.format not in ("PNG", "JPEG", "WEBP")
                        or PILImage.MIME[image.format] != mime
                    ):
                        fail(415, "unsupported_media_type")
                    image.verify()
            except (
                UnidentifiedImageError,
                OSError,
                SyntaxError,
                ValueError,
                PILImage.DecompressionBombError,
            ):
                fail(415, "unsupported_media_type")
        if (
            (mime == "application/pdf" and not data.startswith(b"%PDF-"))
            or (mime == "video/mp4" and data[4:8] != b"ftyp")
            or (mime == "video/webm" and not data.startswith(b"\x1aE\xdf\xa3"))
        ):
            fail(415, "unsupported_media_type")
        # Display metadata only; storage paths never contain supplied names.
        filename = (
            re.sub(
                r"[\x00-\x1f\x7f]",
                "_",
                (file.filename or "file").replace("\\", "/").split("/")[-1],
            )[:200]
            or "file"
        )
        mid = uuid.uuid4().hex
        directory.mkdir(parents=True, exist_ok=True)
        with connection(path, write=True) as db:
            peer_exists(db, identity["account"], target_account)
            if kind == "video" and not cover_media_id:
                fail(422, "validation_error")
            if cover_media_id and (
                kind != "video"
                or readable_media(
                    db, cover_media_id, identity["account"], target_account
                )["kind"]
                != "image"
            ):
                fail(422, "validation_error")
            destination = directory / mid
            # File fsync before DB commit. A crash can leave an unreferenced file,
            # never a committed record referring to bytes not written yet.
            with destination.open("xb") as stream:
                os.chmod(destination, 0o600)
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            if os.name == "posix":
                fd = os.open(directory, os.O_RDONLY)
                try:
                    os.fsync(fd)
                finally:
                    os.close(fd)
            db.execute(
                "INSERT INTO media VALUES (?,?,?,?,?,?,?,?)",
                (
                    mid,
                    identity["account"],
                    target_account,
                    mime,
                    kind,
                    filename,
                    len(data),
                    cover_media_id,
                ),
            )
            return media_view(
                db.execute("SELECT * FROM media WHERE id=?", (mid,)).fetchone()
            )

    @app.get("/media/{media_id}", responses=errors)
    def download(media_id: str, identity=identity_dep):
        with connection(path) as db:
            row = readable_media(db, media_id, identity["account"])
            return FileResponse(
                directory / row["id"],
                media_type=row["mime"],
                filename=row["filename"],
                headers={
                    "Cache-Control": "private, no-store",
                    "X-Content-Type-Options": "nosniff",
                },
            )
