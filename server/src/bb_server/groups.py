"""Group lifecycle over shared conversation storage and general BB notices."""

import base64
import hashlib
import json
import secrets
import sqlite3
import uuid

from bb_auth_contract import ErrorResponse
from bb_auth_contract.group import (
    PROFILE_REVISION_HEADER,
    PROFILE_REVISION_PATTERN,
    REMOTE,
    GroupProfile,
    RemoteGroupMemberPage,
)
from fastapi import Depends, Response

from . import avatars, chat_media_gc, chat_store, notices
from .chat import fail
from .chat_queries import directory_rows, group_member_counts, user_card
from .storage import connection
from .storage_errors import storage_failure


def by_id(db, conversation_id):
    row = db.execute(
        "SELECT * FROM chat_groups WHERE conversation_id=?", (conversation_id,)
    ).fetchone()
    if row is None:
        chat_store.missing()
    return row


def active(group):
    if group["status"] != "active":
        fail(409, "group_unavailable")


def require_owner(group, account):
    if group["owner"] != account:
        fail(403, "forbidden")


def profile(db, group, account):
    membership = db.execute(
        """SELECT active,membership_revision FROM chat_group_members
        WHERE conversation_id=? AND account=?""",
        (group["conversation_id"], account),
    ).fetchone()
    role = None
    if group["status"] == "active" and membership and membership["active"]:
        role = "owner" if group["owner"] == account else "member"
    number = group["group_number"]
    allow = bool(group["allow_member_invites"])
    # Membership is viewer-relative. Neither another user's membership changes
    # nor private invite settings advance a non-member's visible revision.
    membership_revision = membership["membership_revision"] if membership else 0
    invite_revision = group["invite_settings_revision"] if role is not None else 0
    return {
        "profile_revision": f"{membership_revision}.{group['profile_revision']}.{invite_revision}",
        "conversation": chat_store.group_ref(group["conversation_id"]),
        "group_number": number,
        "name": group["name"],
        "description": group["description"],
        "avatar_url": f"/chat/groups/{number}/avatar",
        "avatar_version": group["avatar_version"] or avatars.default_version(number),
        "status": group["status"],
        "role": role,
        "can_invite": role == "owner" or (role == "member" and allow),
        "allow_member_invites": allow if role == "owner" else None,
    }


def allocate_number(db):
    for _ in range(100):
        number = str(10_000_000 + secrets.randbelow(90_000_000))
        if (
            db.execute(
                "SELECT 1 FROM chat_groups WHERE group_number=?", (number,)
            ).fetchone()
            is None
        ):
            return number
    raise sqlite3.OperationalError("Group number allocation exhausted")


def username(db, account):
    row = db.execute(
        "SELECT username FROM users WHERE account=?", (account,)
    ).fetchone()
    if row is None:
        chat_store.missing()
    return row[0]


def decode_avatar(payload):
    try:
        data = base64.b64decode(payload.base64, validate=True)
    except ValueError:
        fail(422, "validation_error")
    return avatars.normalize_image(data, mime_type=payload.mime_type)


def link(group):
    return ("group", group["group_number"])


def start_request(db, group, account, initiator, kind, now):
    conversation_id = group["conversation_id"]
    if db.execute(
        "SELECT 1 FROM chat_group_members WHERE conversation_id=? AND account=? AND active=1",
        (conversation_id, account),
    ).fetchone():
        return None
    prior = db.execute(
        """SELECT id FROM chat_group_join_requests
        WHERE conversation_id=? AND account=? AND state='pending'""",
        (conversation_id, account),
    ).fetchone()
    request_id = prior[0] if prior else uuid.uuid4().hex
    if prior is None:
        db.execute(
            "INSERT INTO chat_group_join_requests VALUES (?,?,?,'pending')",
            (request_id, conversation_id, account),
        )
    elif db.execute(
        "SELECT 1 FROM bb_notices WHERE request_id=? AND kind=?", (request_id, kind)
    ).fetchone():
        return request_id
    if kind == notices.INVITATION:
        recipient = account
        title = "入群邀请"
        text = f"{username(db, initiator)} 邀请你加入「{group['name']}」"
    else:
        recipient = group["owner"]
        title = "入群申请"
        text = f"{username(db, account)} 申请加入「{group['name']}」"
    notices.insert(
        db,
        recipient,
        kind,
        title,
        text,
        now,
        link=link(group),
        request_id=request_id,
        initiator=initiator,
    )
    return request_id


def invite(db, group, account, accounts, now):
    request_ids = []
    for target in dict.fromkeys(accounts):
        # Fail atomically for unknown accounts, even in a multi-recipient request.
        username(db, target)
        request_id = start_request(db, group, target, account, notices.INVITATION, now)
        if request_id is not None:
            request_ids.append(request_id)
    return {"request_ids": request_ids}


def change_avatar(db, directory, conversation_id, png):
    name, version = (
        avatars.write_avatar_files(directory, png) if png is not None else (None, None)
    )
    try:
        db.execute(
            """UPDATE chat_groups SET avatar_path=?,avatar_version=?,
            profile_revision=profile_revision+(avatar_version IS NOT ?)
            WHERE conversation_id=?""",
            (name, version, version, conversation_id),
        )
    except BaseException:
        avatars.remove_file(directory, name)
        raise
    return name


def settle(db, account, body, now):
    row = notices.get(db, account, body.notification_id)
    if not notices.check_action(row, body.action_id):
        return notices.view(row)
    request = db.execute(
        "SELECT * FROM chat_group_join_requests WHERE id=?", (row["request_id"],)
    ).fetchone()
    if request is None or request["state"] != "pending":
        fail(409, "action_unavailable")
    conversation_id = request["conversation_id"]
    group = by_id(db, conversation_id)
    active(group)
    invitation = row["kind"] == notices.INVITATION
    if account != (request["account"] if invitation else group["owner"]):
        fail(403, "forbidden")

    accepted = body.action_id != "reject"
    target = request["account"]
    if accepted and chat_store.set_group_membership(
        db, conversation_id, target, True, now
    ):
        display = username(db, target)
        chat_store.append_system_message(
            db,
            conversation_id,
            {"type": "member.joined", "account": target, "username": display},
            f"{display} 加入了群聊",
            now,
        )
    db.execute(
        "UPDATE chat_group_join_requests SET state=? WHERE id=?",
        ("accepted" if accepted else "rejected", request["id"]),
    )
    db.execute(
        "UPDATE bb_notices SET state='processed',chosen_action=? WHERE id=?",
        (body.action_id, row["id"]),
    )
    db.execute(
        "UPDATE bb_notices SET state='invalidated' WHERE request_id=? AND state='pending'",
        (request["id"],),
    )

    name = group["name"]
    if invitation:
        result = "接受" if accepted else "拒绝"
        text = f"{username(db, target)}{result}了你发出的「{name}」入群邀请"
    else:
        result = "同意" if accepted else "拒绝"
        text = f"群主{result}了你的「{name}」入群申请"
    notices.insert(
        db,
        row["initiator"],
        "group_join_result",
        "入群结果",
        text,
        now,
        link=link(group),
    )
    return notices.view(notices.get(db, account, row["id"]))


class Groups:
    def __init__(self, path, media_directory, avatar_directory, clock):
        self.path = path
        self.media_directory = media_directory
        self.avatar_directory = avatar_directory
        self.clock = clock

    def create_group(self, account, body):
        request = body.model_dump(exclude={"operation_id"}, mode="json")
        request["invitees"] = sorted(set(body.invitees))
        digest = hashlib.sha256(
            json.dumps(request, sort_keys=True, ensure_ascii=False).encode()
        ).hexdigest()
        new_avatar = None
        try:
            with connection(self.path, write=True) as db:
                prior = db.execute(
                    """SELECT request_hash,conversation_id FROM chat_group_create_operations
                    WHERE account=? AND operation_id=?""",
                    (account, body.operation_id),
                ).fetchone()
                if prior is not None:
                    if prior["request_hash"] != digest:
                        fail(409, "conflict")
                    return profile(db, by_id(db, prior["conversation_id"]), account)
                now = chat_store.timestamp(self.clock)
                conversation_id = chat_store.create_group_conversation(
                    db, account, allocate_number(db), body.name, body.description, now
                )
                if body.avatar is not None:
                    new_avatar = change_avatar(
                        db,
                        self.avatar_directory,
                        conversation_id,
                        decode_avatar(body.avatar),
                    )
                group = by_id(db, conversation_id)
                invite(db, group, account, body.invitees, now)
                db.execute(
                    "INSERT INTO chat_group_create_operations VALUES (?,?,?,?)",
                    (account, body.operation_id, digest, conversation_id),
                )
                return profile(db, group, account)
        except BaseException:
            avatars.remove_file(self.avatar_directory, new_avatar)
            raise

    def find_group(self, account, body):
        with connection(self.path) as db:
            group = db.execute(
                "SELECT * FROM chat_groups WHERE group_number=?", (body.group_number,)
            ).fetchone()
            if group is None:
                chat_store.missing()
            return profile(db, group, account)

    def update_group(self, account, body):
        conversation_id = body.conversation.id
        new_avatar = removed_avatar = None
        try:
            with connection(self.path, write=True) as db:
                group = by_id(db, conversation_id)
                active(group)
                require_owner(group, account)
                profile_changed = any(
                    value is not None and value != group[field]
                    for field, value in (
                        ("name", body.name),
                        ("description", body.description),
                    )
                )
                settings_changed = (
                    body.allow_member_invites is not None
                    and body.allow_member_invites != group["allow_member_invites"]
                )
                db.execute(
                    """UPDATE chat_groups SET name=COALESCE(?,name),
                    description=COALESCE(?,description),
                    allow_member_invites=COALESCE(?,allow_member_invites),
                    profile_revision=profile_revision+?,
                    invite_settings_revision=invite_settings_revision+?
                    WHERE conversation_id=?""",
                    (
                        body.name,
                        body.description,
                        body.allow_member_invites,
                        profile_changed,
                        settings_changed,
                        conversation_id,
                    ),
                )
                if body.avatar is not None or body.reset_avatar:
                    png = (
                        decode_avatar(body.avatar) if body.avatar is not None else None
                    )
                    new_avatar = change_avatar(
                        db, self.avatar_directory, conversation_id, png
                    )
                    removed_avatar = group["avatar_path"]
                if body.name is not None and body.name != group["name"]:
                    old_name = group["name"]
                    chat_store.append_system_message(
                        db,
                        conversation_id,
                        {
                            "type": "group.renamed",
                            "old_name": old_name,
                            "new_name": body.name,
                        },
                        f"群名称从「{old_name}」改为「{body.name}」",
                        chat_store.timestamp(self.clock),
                    )
                result = profile(db, by_id(db, conversation_id), account)
        except BaseException:
            avatars.remove_file(self.avatar_directory, new_avatar)
            raise
        avatars.remove_file(self.avatar_directory, removed_avatar)
        return result

    def list_directory(self, account, body):
        with connection(self.path) as db:
            rows = directory_rows(
                db, account, body.after_account, body.limit, self.clock()
            )
            return {
                "items": [user_card(row) for row in rows[: body.limit]],
                "next_cursor": rows[body.limit - 1]["account"]
                if len(rows) > body.limit
                else None,
            }

    def list_group_members(self, account, body):
        conversation_id = body.conversation.id
        with connection(self.path) as db:
            chat_store.active_membership(db, account, conversation_id)
            owner = by_id(db, conversation_id)["owner"]
            now = self.clock()
            rows = directory_rows(
                db,
                account,
                body.after_account,
                body.limit,
                now,
                conversation_id=conversation_id,
            )
            page = {
                "items": [
                    {
                        **user_card(row),
                        "role": "owner" if row["account"] == owner else "member",
                    }
                    for row in rows[: body.limit]
                ],
                "next_cursor": rows[body.limit - 1]["account"]
                if len(rows) > body.limit
                else None,
            }
            if body.include_counts:
                page["counts"] = group_member_counts(db, conversation_id, now)
            return page

    def invite_to_group(self, account, body):
        conversation_id = body.conversation.id
        with connection(self.path, write=True) as db:
            group = by_id(db, conversation_id)
            active(group)
            chat_store.active_membership(db, account, conversation_id)
            if account != group["owner"] and not group["allow_member_invites"]:
                fail(403, "forbidden")
            return invite(
                db, group, account, body.accounts, chat_store.timestamp(self.clock)
            )

    def apply_to_group(self, account, body):
        with connection(self.path, write=True) as db:
            group = by_id(db, body.conversation.id)
            active(group)
            request_id = start_request(
                db,
                group,
                account,
                account,
                notices.APPLICATION,
                chat_store.timestamp(self.clock),
            )
            return {"request_ids": [request_id] if request_id else []}

    def leave_group(self, account, body):
        conversation_id = body.conversation.id
        with connection(self.path, write=True) as db:
            group = by_id(db, conversation_id)
            active(group)
            prior = db.execute(
                "SELECT 1 FROM chat_group_members WHERE conversation_id=? AND account=?",
                (conversation_id, account),
            ).fetchone()
            if prior is None:
                chat_store.missing()
            now = chat_store.timestamp(self.clock)
            if chat_store.set_group_membership(
                db, conversation_id, account, False, now
            ):
                notices.insert(
                    db,
                    group["owner"],
                    "group_member_left",
                    "成员退出",
                    f"{username(db, account)} 退出了「{group['name']}」",
                    now,
                    link=link(group),
                )
            return profile(db, group, account)

    def remove_group_member(self, account, body):
        conversation_id = body.conversation.id
        with connection(self.path, write=True) as db:
            group = by_id(db, conversation_id)
            active(group)
            require_owner(group, account)
            now = chat_store.timestamp(self.clock)
            if chat_store.set_group_membership(
                db, conversation_id, body.account, False, now
            ):
                notices.insert(
                    db,
                    body.account,
                    "group_member_removed",
                    "移出群聊",
                    f"{username(db, account)} 将你移出了「{group['name']}」",
                    now,
                    link=link(group),
                )
            return profile(db, group, account)

    def dissolve_group(self, account, body):
        conversation_id = body.conversation.id
        with connection(self.path, write=True) as db:
            group = by_id(db, conversation_id)
            require_owner(group, account)
            if group["status"] == "active":
                now = chat_store.timestamp(self.clock)
                db.execute(
                    """UPDATE chat_groups SET status='dissolved',
                    profile_revision=profile_revision+1 WHERE conversation_id=?""",
                    (conversation_id,),
                )
                db.execute(
                    """UPDATE bb_notices SET state='invalidated' WHERE state='pending'
                    AND request_id IN (SELECT id FROM chat_group_join_requests
                        WHERE conversation_id=? AND state='pending')""",
                    (conversation_id,),
                )
                db.execute(
                    """UPDATE chat_group_join_requests SET state='invalidated'
                    WHERE conversation_id=? AND state='pending'""",
                    (conversation_id,),
                )
                actor = username(db, account)
                for (member,) in db.execute(
                    "SELECT account FROM chat_group_members WHERE conversation_id=? AND active=1",
                    (conversation_id,),
                ).fetchall():
                    chat_store.set_group_membership(
                        db, conversation_id, member, False, now
                    )
                    notices.insert(
                        db,
                        member,
                        "group_dissolved",
                        "群已解散",
                        f"{actor} 解散了「{group['name']}」",
                        now,
                        link=link(group),
                    )
                db.execute(
                    "DELETE FROM messages WHERE conversation_id=?", (conversation_id,)
                )
                chat_media_gc.release(db)
            result = profile(db, by_id(db, conversation_id), account)
        # Logical deletion is already committed. Startup/maintenance retries GC.
        try:
            chat_media_gc.collect(self.path, self.media_directory)
        except (sqlite3.Error, OSError) as error:
            storage_failure(error, route="chat_media_gc")
        return result

    def list_notices(self, account, body):
        with connection(self.path) as db:
            return notices.page(db, account, body)

    def mark_notice_read(self, account, body):
        with connection(self.path, write=True) as db:
            return notices.mark_read(db, account, body.notification_id)

    def execute_notice_action(self, account, body):
        with connection(self.path, write=True) as db:
            return settle(db, account, body, chat_store.timestamp(self.clock))


def install(app, service, current_session, no_query):
    auth = Depends(current_session)
    errors = {code: {"model": ErrorResponse} for code in (401, 403, 404, 409, 422, 503)}

    def bind(name, request_model, has_profile):
        handler = getattr(service, name)

        def endpoint(body: request_model, response: Response, identity=auth):
            result = handler(identity["account"], body)
            if has_profile:
                response.headers[PROFILE_REVISION_HEADER] = result.pop(
                    "profile_revision"
                )
            return result

        endpoint.__name__ = name
        return endpoint

    for name, (path, request_model, response_model) in REMOTE.items():
        responses = dict(errors)
        has_profile = response_model is GroupProfile
        if has_profile:
            responses[200] = {
                "headers": {
                    PROFILE_REVISION_HEADER: {
                        "description": "Group snapshot revision for this viewer, ordered by membership, public profile, and visible invite settings.",
                        "schema": {
                            "type": "string",
                            "pattern": PROFILE_REVISION_PATTERN,
                        },
                    }
                }
            }
        if name in ("create_group", "update_group"):
            responses.update({code: {"model": ErrorResponse} for code in (413, 415)})
        app.add_api_route(
            path,
            bind(name, request_model, has_profile),
            methods=["POST"],
            response_model=response_model,
            response_model_exclude_unset=response_model is RemoteGroupMemberPage,
            responses=responses,
            dependencies=[Depends(no_query)],
        )
