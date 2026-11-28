"""SQLite-authoritative chat and durable replay. All identities are server-derived."""

import asyncio
import hashlib
import io
import json
import os
import re
import uuid
from contextlib import asynccontextmanager
from typing import Annotated

import anyio
import regex
from bb_auth_contract import ContractError, ErrorResponse
from bb_auth_contract.chat import (
    Account,
    ChatMessage,
    EventPage,
    Media,
    MessagePage,
    Operation,
    SendAttachment,
    SendMessage,
    UserPage,
)
from bb_auth_contract.chat_association import (
    HEADER,
    VERSION,
    AssociatedChatMessage,
    AssociatedConversationPage,
    AssociatedMessageContext,
    AssociatedMessagePage,
    AssociatedOperation,
    AssociatedSharedConversationPage,
)
from bb_auth_contract.chat_query import (
    ConversationPage,
    MessageContext,
    MessageId,
    SharedConversationPage,
)
from bb_auth_contract.conversation import (
    CONVERSATION_PATTERN,
    ConversationId,
    GroupNumber,
    direct_id,
)
from bb_auth_contract.media import THUMB_MIME, MediaVariant
from fastapi import (
    Depends,
    File,
    Form,
    Header,
    Query,
    Request,
    UploadFile,
    WebSocket,
    WebSocketDisconnect,
)
from fastapi.responses import FileResponse, Response
from PIL import Image as PILImage
from PIL import UnidentifiedImageError
from starlette.concurrency import run_in_threadpool

from . import chat_alerts, chat_mentions, chat_queries, chat_replies, chat_store
from .avatars import avatar_bytes, etag_matches
from .media_thumbnails import thumbnail
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


class AuthorizedGroupFile(FileResponse):
    """Pin the file while the membership snapshot still protects its path."""

    def __init__(self, path, **kwargs):
        self.file = path.open("rb")
        try:
            super().__init__(path, stat_result=os.fstat(self.file.fileno()), **kwargs)
        except BaseException:
            self.file.close()
            raise

    @asynccontextmanager
    async def _open_file(self):
        yield anyio.wrap_file(self.file)

    async def __call__(self, scope, receive, send):
        # The ASGI server must stream the authorized handle rather than reopen
        # the name after a concurrent dissolve has unlinked it.
        extensions = dict(scope.get("extensions", {}))
        extensions.pop("http.response.pathsend", None)
        try:
            await super().__call__({**scope, "extensions": extensions}, receive, send)
        finally:
            self.file.close()


def fail(status, code):
    raise ContractError(status, code, code)


def media_view(row):
    return {
        "media_id": row["id"],
        "media_type": row["kind"],
        "filename": row["filename"],
        "mime_type": row["mime"],
        "byte_size": row["size"],
        "cover_media_id": row["cover_id"],
    }


def readable_media(db, mid, account, *, peer=None, group_id=None):
    row = db.execute("SELECT * FROM media WHERE id=?", (mid,)).fetchone()
    if row is None:
        fail(404, "not_found")
    if row["group_id"] is None:
        participants = {row["owner"], row["peer"]}
        if (
            group_id
            or account not in participants
            or (peer and peer not in participants)
        ):
            fail(404, "not_found")
    else:
        if peer or (group_id and row["group_id"] != group_id):
            fail(404, "not_found")
        chat_store.active_membership(db, account, row["group_id"])
        if (
            row["owner"] != account
            and not db.execute(
                """SELECT 1 FROM chat_message_media r JOIN messages m ON m.id=r.message_id
            WHERE m.conversation_id=? AND r.media_id IN (
                SELECT ? UNION ALL SELECT id FROM media WHERE cover_id=?
            ) LIMIT 1""",
                (row["group_id"], mid, mid),
            ).fetchone()
        ):
            fail(404, "not_found")
    return row


def submit(path, account, body, clock, association=False):
    with connection(path, write=True) as db:
        conversation_id, peer = chat_store.resolve_send(
            db, account, body.target_account, body.conversation
        )
        request = body.model_dump(exclude={"conversation", "target_account"})
        if body.reply_to_message_id is None:
            request.pop("reply_to_message_id")
        if isinstance(body, SendMessage):
            # Retain pre-mention operation digests and canonicalize the recipient set.
            request.pop("mentioned_accounts")
            if body.mentioned_accounts:
                request["mentioned_accounts"] = sorted(body.mentioned_accounts)
        if peer:
            # Keep the pre-migration digest and make explicit dm sends replay it.
            request["target_account"] = peer
        else:
            request["conversation"] = chat_store.group_ref(conversation_id)
        digest = hashlib.sha256(
            json.dumps(
                request, sort_keys=True, separators=(",", ":"), ensure_ascii=False
            ).encode()
        ).hexdigest()
        prior = db.execute(
            "SELECT * FROM operations WHERE account=? AND operation_id=?",
            (account, body.client_nonce),
        ).fetchone()
        if prior:
            if prior["request_hash"] != digest:
                fail(409, "conflict")
            if prior["message_id"] is None:
                fail(404, "not_found")
            return chat_queries.find_message(
                db, account, prior["message_id"], association
            )[0]
        recipients = chat_mentions.recipients(
            db, conversation_id, account, request.get("mentioned_accounts", [])
        )
        scope = {"peer": peer} if peer else {"group_id": conversation_id}
        created_at = chat_store.timestamp(clock)
        fields = {"sender_account": account, "content": None, "attachment": None}
        if body.reply_to_message_id is not None:
            original, username = chat_replies.original_for_send(
                db, conversation_id, body.reply_to_message_id
            )
            fields["reply_to"] = {
                "message_id": original["id"],
                "sender_account": original.get("sender_account"),
                "sender_username": username,
                "preview": preview(original),
            }
        if peer:
            chat_store.ensure_direct(db, account, peer, created_at)
            fields["target_account"] = peer
        else:
            fields.update(
                conversation=chat_store.group_ref(conversation_id),
                sender_username=db.execute(
                    "SELECT username FROM users WHERE account=?", (account,)
                ).fetchone()[0],
            )
        media_ids = []
        if isinstance(body, SendMessage):
            fields.update(kind="body", content=request["content"])
            for part in request["content"]:
                if part["type"] == "image":
                    media_id = part["media_id"]
                    if (
                        readable_media(db, media_id, account, **scope)["kind"]
                        != "image"
                    ):
                        fail(422, "validation_error")
                    media_ids.append(media_id)
        else:
            row = readable_media(db, body.media_id, account, **scope)
            if row["kind"] == "image":
                fail(422, "validation_error")
            fields.update(kind="attachment", attachment=media_view(row))
            media_ids.append(body.media_id)
        message = chat_store.append_entry(
            db,
            conversation_id,
            fields,
            created_at,
            direct_accounts=(account, peer) if peer else None,
            media_ids=media_ids,
        )
        if recipients:
            chat_alerts.record_mentions(db, conversation_id, message["position"], recipients)
        if body.reply_to_message_id is not None:
            chat_replies.record_reply(
                db, conversation_id, message, original.get("sender_account")
            )
        db.execute(
            "INSERT INTO operations VALUES (?,?,?,?)",
            (account, body.client_nonce, digest, message["id"]),
        )
        return chat_queries.project_messages(db, account, [message], association)[0]


def preview(message):
    if message["kind"] == "system":
        value = message["text"]
    elif message["kind"] == "body":
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


def install(app, path, directory, group_avatar_directory, current_session, clock):
    identity_dep = Depends(current_session)
    errors = {s: {"model": ErrorResponse} for s in (401, 404, 409, 413, 415, 422, 503)}

    def association_format(
        response: Response,
        version: Annotated[str | None, Header(alias=HEADER)] = None,
    ):
        enabled = version == VERSION
        if enabled:
            response.headers[HEADER] = VERSION
        return enabled

    association_dep = Depends(association_format)
    association_responses = {
        **errors,
        200: {
            "headers": {
                HEADER: {
                    "description": "Present with value 1 only when association format was negotiated; authorization is unchanged.",
                    "schema": {"type": "string", "const": VERSION},
                }
            }
        },
    }

    @app.post(
        "/messages",
        response_model=ChatMessage | AssociatedChatMessage,
        responses=association_responses,
    )
    def send(body: SendMessage, identity=identity_dep, association=association_dep):
        return submit(path, identity["account"], body, clock, association)

    @app.post(
        "/messages/attachments",
        response_model=ChatMessage | AssociatedChatMessage,
        responses=association_responses,
    )
    def attach(
        body: SendAttachment, identity=identity_dep, association=association_dep
    ):
        return submit(path, identity["account"], body, clock, association)

    @app.get(
        "/operations/{operation_id}",
        response_model=Operation | AssociatedOperation,
        responses=association_responses,
    )
    def operation(
        operation_id: str, identity=identity_dep, association=association_dep
    ):
        with connection(path) as db:
            row = db.execute(
                "SELECT message_id FROM operations WHERE account=? AND operation_id=?",
                (identity["account"], operation_id),
            ).fetchone()
            if not row or row[0] is None:
                fail(404, "not_found")
            return {
                "operation_id": operation_id,
                "kind": "message",
                "status": "succeeded",
                "message": chat_queries.find_message(
                    db, identity["account"], row[0], association
                )[0],
            }

    @app.get(
        "/conversations/{account}/messages",
        response_model=MessagePage | AssociatedMessagePage,
        responses=association_responses,
    )
    def history(
        account: Account,
        after_position: int | None = Query(None, ge=0, le=9007199254740991),
        before_position: int | None = Query(None, ge=1, le=9007199254740991),
        limit: int = Query(50, ge=1, le=100),
        identity=identity_dep,
        association=association_dep,
    ):
        return chat_queries.history(
            path,
            identity["account"],
            direct_id(identity["account"], account),
            after_position,
            before_position,
            limit,
            association,
        )

    @app.get(
        "/conversations",
        response_model=ConversationPage | AssociatedConversationPage,
        responses=association_responses,
    )
    def conversations(
        after_account: str = Query("", pattern=r"^([1-9][0-9]{7})?$"),
        limit: int = Query(50, ge=1, le=100),
        identity=identity_dep,
        association=association_dep,
    ):
        return chat_queries.conversations(
            path, identity["account"], after_account, limit, association
        )

    @app.get(
        "/chat/conversations/{conversation_id}/messages",
        response_model=MessagePage | AssociatedMessagePage,
        responses=association_responses,
    )
    def shared_history(
        conversation_id: ConversationId,
        after_position: int | None = Query(None, ge=0, le=9007199254740991),
        before_position: int | None = Query(None, ge=1, le=9007199254740991),
        limit: int = Query(50, ge=1, le=100),
        identity=identity_dep,
        association=association_dep,
    ):
        return chat_queries.history(
            path,
            identity["account"],
            conversation_id,
            after_position,
            before_position,
            limit,
            association,
        )

    @app.get(
        "/chat/conversations",
        response_model=SharedConversationPage | AssociatedSharedConversationPage,
        responses=association_responses,
    )
    def shared_conversations(
        after_id: str = Query("", pattern=CONVERSATION_PATTERN[:-1] + "?$"),
        limit: int = Query(50, ge=1, le=100),
        identity=identity_dep,
        association=association_dep,
    ):
        return chat_queries.conversations(
            path, identity["account"], after_id, limit, association, shared=True
        )

    @app.get(
        "/chat/groups/{group_number}/avatar", responses=errors, response_class=Response
    )
    def group_avatar(
        group_number: GroupNumber,
        request: Request,
        variant: Annotated[MediaVariant, Query()] = "original",
        identity=identity_dep,
    ):
        with connection(path, write=True) as db:
            row = db.execute(
                "SELECT avatar_path,avatar_version FROM chat_groups WHERE group_number=?",
                (group_number,),
            ).fetchone()
            if row is None:
                fail(404, "not_found")
            data, version, mime = avatar_bytes(
                row, group_avatar_directory, group_number, variant
            )
        etag = '"' + version + '"'
        headers = {
            "ETag": etag,
            "Cache-Control": "private, no-cache",
            "Vary": "Authorization",
            "X-Content-Type-Options": "nosniff",
        }
        if etag_matches(request.headers.get("if-none-match"), etag):
            return Response(status_code=304, headers=headers)
        return Response(data, media_type=mime, headers=headers)

    @app.get(
        "/messages/{message_id}",
        response_model=ChatMessage | AssociatedChatMessage,
        responses=association_responses,
    )
    def get_message(
        message_id: MessageId, identity=identity_dep, association=association_dep
    ):
        return chat_queries.message(path, identity["account"], message_id, association)

    @app.get(
        "/messages/{message_id}/context",
        response_model=MessageContext | AssociatedMessageContext,
        responses=association_responses,
    )
    def get_context(
        message_id: MessageId,
        before_limit: int = Query(10, ge=0, le=49),
        after_limit: int = Query(10, ge=0, le=49),
        identity=identity_dep,
        association=association_dep,
    ):
        return chat_queries.context(
            path,
            identity["account"],
            message_id,
            before_limit,
            after_limit,
            association,
        )

    @app.get("/users", response_model=UserPage, responses=errors)
    def users(
        after_account: str = Query("", pattern=r"^([1-9][0-9]{7})?$"),
        limit: int = Query(50, ge=1, le=100),
        identity=identity_dep,
    ):
        with connection(path) as db:
            rows = chat_queries.directory_rows(
                db, identity["account"], after_account, limit, clock()
            )
            items = []
            for row in rows[:limit]:
                m = chat_queries.latest_direct_message(
                    db, identity["account"], row["account"]
                )
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
                        **chat_queries.user_card(row),
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

    @app.get("/events/head", responses=errors)
    def event_head(include_groups: bool = False, identity=identity_dep):
        with connection(path) as db:
            return {
                "event_id": chat_queries.event_head(
                    db, identity["account"], include_groups=include_groups
                )
            }

    @app.get("/events", response_model=EventPage, responses=errors)
    def replay(
        after_event_id: int = Query(0, ge=0),
        limit: int = Query(100, ge=1, le=500),
        include_groups: bool = False,
        identity=identity_dep,
    ):
        return chat_queries.event_page(
            path, identity["account"], after_event_id, limit, include_groups
        )

    @app.websocket("/events")
    async def events(socket: WebSocket):
        auth = socket.headers.get("authorization", "")
        group_opt_in = socket.query_params.multi_items() == [("include_groups", "true")]
        if (socket.query_params and not group_opt_in) or not auth.startswith("Bearer "):
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
                    chat_queries.event_page,
                    path,
                    session["account"],
                    after,
                    500,
                    group_opt_in,
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
        file: Annotated[UploadFile, File()],
        target_account: Annotated[Account | None, Form()] = None,
        conversation_id: Annotated[ConversationId | None, Form()] = None,
        cover_media_id: str | None = Form(None),
        identity=identity_dep,
    ):
        if (target_account is None) == (conversation_id is None):
            fail(422, "validation_error")
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
            account = identity["account"]
            target = conversation_id or direct_id(account, target_account)
            peer = chat_store.authorize(db, account, target)
            group_id = None if peer else target
            if kind == "video" and not cover_media_id:
                fail(422, "validation_error")
            if cover_media_id and (
                kind != "video"
                or readable_media(
                    db, cover_media_id, account, peer=peer, group_id=group_id
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
                "INSERT INTO media VALUES (?,?,?,?,?,?,?,?,?)",
                (
                    mid,
                    account,
                    peer,
                    mime,
                    kind,
                    filename,
                    len(data),
                    cover_media_id,
                    group_id,
                ),
            )
            return media_view(
                db.execute("SELECT * FROM media WHERE id=?", (mid,)).fetchone()
            )

    @app.get("/media/{media_id}/metadata", response_model=Media, responses=errors)
    def metadata(media_id: str, response: Response, identity=identity_dep):
        with connection(path) as db:
            row = readable_media(db, media_id, identity["account"])
            response.headers["Cache-Control"] = "private, no-store"
            return media_view(row)

    binary_content = {
        mime: {"schema": {"type": "string", "format": "binary"}}
        for mime in ("application/octet-stream", THUMB_MIME)
    }

    @app.get(
        "/media/{media_id}",
        response_class=FileResponse,
        responses={
            **errors,
            200: {
                "description": "Original or thumbnail bytes",
                "content": binary_content,
            },
            206: {"description": "Partial file bytes", "content": binary_content},
            304: {"description": "Authenticated thumbnail ETag matched"},
            400: {"description": "Malformed Range (plain text)"},
            416: {"description": "Unsatisfiable Range (plain text)"},
        },
    )
    def download(
        media_id: str,
        request: Request,
        variant: Annotated[MediaVariant, Query()] = "original",
        identity=identity_dep,
    ):
        with connection(path) as db:
            row = readable_media(db, media_id, identity["account"])
        if row["group_id"] is None:
            return download_file(row, request, variant, FileResponse)
        # The writer lock also serializes file lookup with GC on databases
        # opened in WAL mode. Release it as soon as the authorized file is open.
        with connection(path, write=True) as db:
            row = readable_media(db, media_id, identity["account"])
            return download_file(row, request, variant, AuthorizedGroupFile)

    def download_file(row, request, variant, response_type):
        if variant == "thumb":
            if row["kind"] != "image":
                fail(415, "unsupported_media_type")
            derivative, etag = thumbnail(directory, row["id"])
            headers = {
                "Cache-Control": "private, no-store"
                if row["group_id"]
                else "private, no-cache",
                "X-Content-Type-Options": "nosniff",
                "ETag": etag,
            }
            if etag_matches(request.headers.get("if-none-match"), etag):
                return Response(status_code=304, headers=headers)
            return response_type(derivative, media_type=THUMB_MIME, headers=headers)
        return response_type(
            directory / row["id"],
            media_type=row["mime"],
            filename=row["filename"],
            headers={
                "Cache-Control": "private, no-store",
                "X-Content-Type-Options": "nosniff",
            },
        )
