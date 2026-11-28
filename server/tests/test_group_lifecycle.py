import base64
import io
import os
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier, Event

import test_chat
from bb_auth_contract.group import PROFILE_REVISION_HEADER, REMOTE
from PIL import Image
from space_support import call as space_call
from space_support import register
from starlette.concurrency import run_in_threadpool
from test_admin_http import free_port, running
from test_shared_chat import group_send, shared_list

from bb_server.avatars import default_version, identicon
from bb_server.chat import AuthorizedGroupFile
from bb_server.storage import connection

chat = test_chat.chat


def post(api, who, operation, **body):
    path, model, _ = REMOTE[operation]
    model.model_validate(body)
    return api.post(path, headers=who[1] if who else {}, json=body)


def call(api, who, operation, *, status=200, **body):
    reply = post(api, who, operation, **body)
    assert reply.status_code == status, (operation, reply.status_code, reply.text)
    if status == 200:
        response = REMOTE[operation][2]
        return response.model_validate(reply.json()).model_dump()
    return reply.json()


def notice(api, who, kind, **params):
    return next(
        item
        for item in call(api, who, "list_notices", **params)["items"]
        if item["type"] == kind
    )


def act(api, who, item, action, *, status=200):
    return call(
        api,
        who,
        "execute_notice_action",
        status=status,
        notification_id=item["id"],
        action_id=action,
    )


def replay(api, who, after=0, limit=100, *, include_groups=True):
    response = api.get(
        "/events",
        params={
            "include_groups": str(include_groups).lower(),
            "after_event_id": after,
            "limit": limit,
        },
        headers=who[1],
    )
    assert response.status_code == 200
    return response.json()


def png():
    buffer = io.BytesIO()
    Image.new("RGB", (12, 10), "red").save(buffer, format="PNG")
    return buffer.getvalue()


def avatar():
    return {"base64": base64.b64encode(png()).decode(), "mime_type": "image/png"}


def upload(api, who, target, data, *, cover=None):
    content, filename, mime = data
    body = dict(target)
    if cover is not None:
        body["cover_media_id"] = cover
    reply = api.post(
        "/media", headers=who[1], data=body, files={"file": (filename, content, mime)}
    )
    assert reply.status_code == 200, reply.text
    return reply.json()["media_id"]


def test_empty_group_profile_directory_avatar_and_permissions(chat, monkeypatch):
    api, _, (owner, peer, stranger) = chat
    monkeypatch.setattr("bb_server.groups.allocate_number", lambda _: peer[0])
    empty = api.post(
        REMOTE["create_group"][0],
        headers=owner[1],
        json={"name": " \t", "operation_id": "bad"},
    )
    assert empty.status_code == 422
    call(api, None, "create_group", status=401, operation_id="solo", name="Solo")
    group = call(api, owner, "create_group", operation_id="solo", name=" Solo ")
    assert group["group_number"] == peer[0]
    assert group["name"] == "Solo"
    assert group["role"] == "owner" and group["allow_member_invites"] is False
    assert group["avatar_version"] == default_version(peer[0])
    assert shared_list(api, owner)["items"][0]["last_message"] is None
    assert shared_list(api, peer)["items"] == []
    target = {"conversation": group["conversation"]}
    member = call(api, owner, "list_group_members", **target)["items"]
    assert [(item["account"], item["role"]) for item in member] == [(owner[0], "owner")]
    assert call(api, owner, "create_group", operation_id="solo", name="Solo") == group
    call(api, owner, "create_group", status=409, operation_id="solo", name="Changed")

    public = call(api, stranger, "find_group", group_number=peer[0])
    assert public["role"] is public["allow_member_invites"] is None
    assert not public["can_invite"] and "owner" not in public
    call(api, stranger, "list_group_members", status=404, **target)
    call(api, stranger, "update_group", status=403, name="Other", **target)
    call(api, stranger, "dissolve_group", status=403, **target)
    call(api, owner, "leave_group", status=403, **target)
    call(api, owner, "remove_group_member", status=403, account=owner[0], **target)

    test_chat.send(api, owner, peer, "direct")
    directory = call(api, owner, "list_directory", limit=1)
    first = directory["items"][0]
    next_page = call(
        api, owner, "list_directory", after_account=directory["next_cursor"]
    )
    assert [first["account"], next_page["items"][0]["account"]] == sorted(
        [peer[0], stranger[0]]
    )
    assert all(
        set(row) == {"account", "username", "avatar_url", "avatar_version", "presence"}
        for row in [first, *next_page["items"]]
    )
    avatar_url = group["avatar_url"]
    assert api.get(avatar_url, headers=stranger[1]).content == identicon(peer[0])
    call(
        api,
        owner,
        "update_group",
        status=415,
        avatar={**avatar(), "mime_type": "image/jpeg"},
        **target,
    )
    updated = call(
        api, owner, "update_group", avatar=avatar(), description="Intro", **target
    )
    assert updated["avatar_version"] != group["avatar_version"]
    with Image.open(
        io.BytesIO(api.get(avatar_url, headers=stranger[1]).content)
    ) as image:
        assert image.getpixel((0, 0)) == (255, 0, 0, 255)
    thumb = api.get(avatar_url, params={"variant": "thumb"}, headers=stranger[1])
    assert thumb.headers["content-type"] == "image/jpeg"
    user_avatar = api.get(f"/avatars/{peer[0]}.png", headers=stranger[1])
    assert user_avatar.content == identicon(peer[0])
    reset = call(api, owner, "update_group", reset_avatar=True, **target)
    assert reset["avatar_version"] == group["avatar_version"]
    for _ in range(2):
        assert (
            call(api, owner, "update_group", name="Renamed", **target)["name"]
            == "Renamed"
        )
    history = api.get(
        f"/chat/conversations/{group['conversation']['id']}/messages", headers=owner[1]
    ).json()
    assert [entry["system"] for entry in history["items"]] == [
        {"type": "group.renamed", "old_name": "Solo", "new_name": "Renamed"}
    ]


def test_group_profile_revision_orders_visible_state_and_preserves_the_body(chat):
    api, _, (owner, peer, stranger) = chat

    def snapshot(who, operation="find_group", **body):
        reply = post(api, who, operation, **body)
        assert reply.status_code == 200, reply.text
        revision = tuple(map(int, reply.headers[PROFILE_REVISION_HEADER].split(".")))
        payload = reply.json()
        REMOTE[operation][2].model_validate(payload)
        assert "profile_revision" not in payload
        return revision, payload

    creation = {
        "operation_id": "profile-order",
        "name": "Initial",
        "invitees": [peer[0]],
    }
    before, group = snapshot(owner, "create_group", **creation)
    target = {"conversation": group["conversation"]}
    lookup = {"group_number": group["group_number"]}
    peer_initial, _ = snapshot(peer, **lookup)
    public_initial, _ = snapshot(stranger, **lookup)

    settings, _ = snapshot(owner, "update_group", allow_member_invites=True, **target)
    assert settings > before
    assert snapshot(stranger, **lookup)[0] == public_initial
    assert snapshot(peer, **lookup)[0] == peer_initial
    act(api, peer, notice(api, peer, "group_invitation"), "accept")
    joined, peer_profile = snapshot(peer, **lookup)
    assert joined > peer_initial and peer_profile["can_invite"]
    assert snapshot(stranger, **lookup)[0] == public_initial

    renamed, _ = snapshot(
        owner, "update_group", name="Final", description="new", **target
    )
    assert renamed > settings
    assert snapshot(owner, "update_group", name="Final", **target)[0] == renamed
    replay, replayed = snapshot(owner, "create_group", **creation)
    assert replay == renamed and replayed["name"] == "Final"
    with_avatar, _ = snapshot(owner, "update_group", avatar=avatar(), **target)
    reset, _ = snapshot(owner, "update_group", reset_avatar=True, **target)
    assert reset > with_avatar > renamed

    peer_renamed, _ = snapshot(peer, **lookup)
    left, left_profile = snapshot(peer, "leave_group", **target)
    assert left > peer_renamed and left_profile["role"] is None
    call(api, owner, "invite_to_group", accounts=[peer[0]], **target)
    invitation = next(
        item
        for item in call(api, peer, "list_notices", filter="pending")["items"]
        if item["type"] == "group_invitation"
    )
    act(api, peer, invitation, "accept")
    rejoined, _ = snapshot(peer, **lookup)
    assert rejoined > left
    assert snapshot(owner, "remove_group_member", account=peer[0], **target)[0] == reset
    assert snapshot(peer, **lookup)[0] > rejoined

    dissolved, _ = snapshot(owner, "dissolve_group", **target)
    assert dissolved > reset
    assert snapshot(owner, "dissolve_group", **target)[0] == dissolved


def test_crossed_actions_are_atomic_and_authorized(chat):
    api, path, (owner, candidate, other) = chat
    group = call(
        api,
        owner,
        "create_group",
        operation_id="many",
        name="Cross",
        invitees=[candidate[0], other[0], candidate[0]],
    )
    target = {"conversation": group["conversation"]}
    cid = group["conversation"]["id"]
    assert shared_list(api, candidate)["items"] == []
    assert notice(api, other, "group_invitation")["state"] == "pending"
    invitation = notice(api, candidate, "group_invitation")
    assert (
        act(api, candidate, invitation, "approve", status=409)["error"]["code"]
        == "action_unavailable"
    )
    act(api, other, invitation, "accept", status=404)
    marked = call(api, candidate, "mark_notice_read", notification_id=invitation["id"])
    assert marked["read"] and marked["state"] == "pending"
    pending = call(api, candidate, "list_notices", filter="pending")
    assert pending["unread_count"] == 0 and pending["pending_count"] == 1

    assert group_send(api, owner, cid, "before-join").status_code == 200
    with ThreadPoolExecutor(max_workers=5) as executor:
        start = Barrier(5)

        def ask(index):
            start.wait(timeout=5)
            if index % 2:
                return call(
                    api, owner, "invite_to_group", accounts=[candidate[0]], **target
                )
            return call(api, candidate, "apply_to_group", **target)

        requests = list(executor.map(ask, range(5)))
    assert len({tuple(reply["request_ids"]) for reply in requests}) == 1
    application = notice(api, owner, "group_application")
    act(api, candidate, application, "approve", status=404)
    assert [e["notification_id"] for e in replay(api, candidate)["items"]] == [
        invitation["id"]
    ]
    assert replay(api, candidate, include_groups=False)["items"] == []

    with ThreadPoolExecutor(max_workers=4) as executor:
        start = Barrier(4)
        attempts = [
            (candidate, invitation, "accept"),
            (candidate, invitation, "accept"),
            (owner, application, "reject"),
            (owner, application, "reject"),
        ]

        def click(attempt):
            who, item, action = attempt
            start.wait(timeout=5)
            return post(
                api,
                who,
                "execute_notice_action",
                notification_id=item["id"],
                action_id=action,
            )

        replies = list(executor.map(click, attempts))
    assert [r.status_code for r in replies] in (
        [200, 200, 409, 409],
        [409, 409, 200, 200],
    )
    accepted = replies[0].status_code == 200
    with connection(path) as db:
        assert (
            db.execute(
                "SELECT count(*) FROM chat_group_join_requests WHERE conversation_id=?",
                (cid,),
            ).fetchone()[0]
            == 2
        )
        assert (
            db.execute(
                "SELECT count(*) FROM bb_notices WHERE kind='group_join_result'"
            ).fetchone()[0]
            == 1
        )
        assert db.execute(
            "SELECT count(*) FROM messages WHERE conversation_id=? AND sender IS NULL",
            (cid,),
        ).fetchone()[0] == int(accepted)
    if accepted:
        assert notice(api, owner, "group_application")["state"] == "invalidated"
        assert "接受" in notice(api, owner, "group_join_result")["text"]
        active = shared_list(api, candidate)["items"][0]
        assert active["history_through"] == 1
        act(api, candidate, invitation, "reject", status=409)
    else:
        assert notice(api, candidate, "group_invitation")["state"] == "invalidated"
        assert "拒绝" in notice(api, candidate, "group_join_result")["text"]
        assert shared_list(api, candidate)["items"] == []
        assert call(api, candidate, "apply_to_group", **target) != requests[0]
        application = notice(api, owner, "group_application")
        assert act(api, owner, application, "approve")["state"] == "processed"
    assert (
        act(api, other, notice(api, other, "group_invitation"), "reject")["state"]
        == "processed"
    )
    assert shared_list(api, other)["items"] == []
    assert notice(api, owner, "group_join_result")["state"] == "informational"

    first_page = call(api, owner, "list_notices", limit=1)
    later = call(api, owner, "list_notices", cursor=first_page["next_cursor"])
    assert first_page["items"][0]["id"] not in {row["id"] for row in later["items"]}
    call(api, other, "list_notices", status=404, cursor=first_page["next_cursor"])


def test_current_permissions_and_invitation_survives_issuer_leaving(chat):
    api, _, (owner, member, applicant) = chat
    group = call(api, owner, "create_group", operation_id="group", name="Team")
    target = {"conversation": group["conversation"]}
    cid = group["conversation"]["id"]
    old = group_send(api, owner, cid, "old-message").json()
    call(api, member, "apply_to_group", **target)
    act(api, owner, notice(api, owner, "group_application"), "approve")
    assert shared_list(api, member)["items"][0]["history_through"] == old["position"]
    acl = api.get(f"/chat/conversations/{cid}/messages", headers=member[1])
    assert acl.json()["items"][0]["id"] == old["id"]
    call(api, member, "invite_to_group", status=403, accounts=[applicant[0]], **target)
    call(api, member, "remove_group_member", status=403, account=applicant[0], **target)
    call(api, member, "update_group", status=403, allow_member_invites=True, **target)
    call(api, owner, "update_group", allow_member_invites=True, **target)
    assert call(api, member, "find_group", group_number=group["group_number"])[
        "can_invite"
    ]
    members = call(api, member, "list_group_members", limit=1, **target)
    others = call(
        api,
        member,
        "list_group_members",
        after_account=members["next_cursor"],
        **target,
    )
    assert {row["role"] for row in members["items"] + others["items"]} == {
        "owner",
        "member",
    }
    call(api, member, "invite_to_group", accounts=[applicant[0]], **target)
    call(api, owner, "update_group", allow_member_invites=False, **target)
    call(api, member, "invite_to_group", status=403, accounts=[applicant[0]], **target)
    assert group_send(api, owner, cid, "unseen").status_code == 200
    for _ in range(2):
        assert call(api, member, "leave_group", **target)["role"] is None
    assert shared_list(api, member)["items"] == []
    revoked = replay(api, member)["items"]
    assert not any(event["type"] == "message.available" for event in revoked)
    assert [
        event["active"]
        for event in revoked
        if event["type"] == "conversation.access_changed"
    ] == [False]
    assert "Bob" in notice(api, owner, "group_member_left")["text"]
    assert (
        len(
            [
                item
                for item in call(api, owner, "list_notices")["items"]
                if item["type"] == "group_member_left"
            ]
        )
        == 1
    )
    assert api.get("/messages/" + old["id"], headers=member[1]).status_code == 404
    act(api, applicant, notice(api, applicant, "group_invitation"), "accept")
    assert "接受" in notice(api, member, "group_join_result")["text"]
    for _ in range(2):
        call(api, owner, "remove_group_member", account=applicant[0], **target)
    removed = notice(api, applicant, "group_member_removed")
    assert "Alice" in removed["text"] and "Team" in removed["text"]
    assert removed["link"] == {"type": "group", "id": group["group_number"]}
    assert (
        call(api, applicant, "find_group", group_number=removed["link"]["id"])["role"]
        is None
    )
    assert call(api, applicant, "apply_to_group", **target)["request_ids"]
    items = api.get(f"/chat/conversations/{cid}/messages", headers=owner[1]).json()[
        "items"
    ]
    assert [m["system"]["type"] for m in items if m["kind"] == "system"] == [
        "member.joined",
        "member.joined",
    ]


def test_dissolve_http_cleanup_retries_after_process_restart(tmp_path):
    port = free_port()
    path = tmp_path / "db"
    media = tmp_path / "media"
    env = {
        **os.environ,
        "BB_DATABASE_PATH": str(path),
        "BB_AVATAR_DIRECTORY": str(tmp_path / "avatars"),
        "BB_MEDIA_DIRECTORY": str(media),
        "BB_HOST": "127.0.0.1",
        "BB_PORT": str(port),
    }
    origin = f"http://127.0.0.1:{port}"
    with running("bb-server", env, origin, tmp_path / "first.log") as api:
        owner, member, outsider = (
            register(api, name) for name in ("Alice", "Bob", "Carol")
        )
        group = call(
            api,
            owner,
            "create_group",
            operation_id="persistent",
            name="Art",
            avatar=avatar(),
            invitees=[member[0], outsider[0]],
        )
        cid = group["conversation"]["id"]
        target = {"conversation": group["conversation"]}
        avatar_content = api.get(group["avatar_url"], headers=outsider[1]).content
        invitation = notice(api, outsider, "group_invitation")
        act(api, member, notice(api, member, "group_invitation"), "accept")
        message = group_send(api, owner, cid, "before").json()
        call(api, outsider, "apply_to_group", **target)
        image = (png(), "image.png", "image/png")
        own_media = upload(api, owner, {"conversation_id": cid}, image)
        shared_cover = upload(api, owner, {"conversation_id": cid}, image)
        direct = upload(api, owner, {"target_account": member[0]}, image)
        video = upload(
            api,
            owner,
            {"conversation_id": cid},
            (b"0000ftyp-fixture", "clip.mp4", "video/mp4"),
            cover=shared_cover,
        )
        post_image = group_send(
            api,
            owner,
            cid,
            "contains-media",
            [{"type": "image", "media_id": own_media}],
        )
        assert post_image.status_code == 200
        attached = api.post(
            "/messages/attachments",
            headers=owner[1],
            json={**target, "client_nonce": "clip", "media_id": video},
        )
        assert attached.status_code == 200
        clip = api.get(f"/media/{video}", headers={**member[1], "Range": "bytes=4-7"})
        assert clip.status_code == 206 and clip.content == b"ftyp"

        # Model a second surviving consumer of the cover, using the actual FK.
        with connection(path, write=True) as db:
            db.execute("UPDATE media SET cover_id=? WHERE id=?", (shared_cover, direct))
        draft_id = space_call(api, owner, "create_draft", text="space")["resource_id"]
        space_call(
            api,
            owner,
            "add_image",
            draft_id=draft_id,
            expected_version=1,
            base64=avatar()["base64"],
            filename="image.png",
        )
        space_files = [
            entry for entry in (media / "space").iterdir() if entry.is_file()
        ]
        assert space_files

        thumb = media / "derivatives" / "thumb-v1" / (own_media + ".jpg")
        assert (
            api.get(f"/media/{own_media}?variant=thumb", headers=member[1]).status_code
            == 200
        )
        thumb.unlink()
        thumb.mkdir()  # Fail after original unlink, without mocking the server.
        try:
            for _ in range(2):
                assert (
                    call(api, owner, "dissolve_group", **target)["status"]
                    == "dissolved"
                )
            assert not (media / own_media).exists()
            assert not (media / video).exists()
            with connection(path) as db:
                assert [
                    row[0] for row in db.execute("SELECT media_id FROM chat_media_gc")
                ] == [own_media]
                assert (
                    db.execute(
                        "SELECT message_id FROM operations WHERE operation_id='clip'"
                    ).fetchone()[0]
                    is None
                )
                assert (
                    db.execute(
                        "SELECT count(*) FROM messages WHERE conversation_id=?", (cid,)
                    ).fetchone()[0]
                    == 0
                )
            assert call(api, owner, "list_notices", filter="pending")["items"] == []
            assert notice(api, outsider, "group_invitation")["state"] == "invalidated"
            assert notice(api, outsider, "group_invitation")["actions"] == []
            act(api, outsider, invitation, "accept", status=409)
            call(api, outsider, "apply_to_group", status=409, **target)
        finally:
            thumb.rmdir()
            thumb.write_bytes(b"simulated leftover derivative")

    with running("bb-server", env, origin, tmp_path / "restart.log") as api:
        assert not thumb.exists()
        with connection(path) as db:
            assert db.execute("SELECT count(*) FROM chat_media_gc").fetchone()[0] == 0
            assert db.execute("PRAGMA foreign_key_check").fetchall() == []
        assert all(
            entry.is_file()
            for entry in [media / shared_cover, media / direct, *space_files]
        )
        assert api.get(f"/media/{direct}", headers=member[1]).content == image[0]
        assert (
            api.get(group["avatar_url"], headers=outsider[1]).content == avatar_content
        )
        for who in (owner, member):
            assert shared_list(api, who)["items"] == []
            all_notices = call(api, who, "list_notices")
            dissolved = [
                item
                for item in all_notices["items"]
                if item["type"] == "group_dissolved"
            ]
            assert len(dissolved) == 1 and dissolved[0]["state"] == "informational"
            page = replay(api, who, limit=1)
            events = list(page["items"])
            while page["has_more"]:
                page = replay(api, who, page["next_event_id"], limit=1)
                events.extend(page["items"])
            assert all(event["type"] != "message.available" for event in events)
            assert any(
                event.get("notification_id") == dissolved[0]["id"] for event in events
            )
            assert [
                event["active"]
                for event in events
                if event["type"] == "conversation.access_changed"
            ] == [False]
            assert (
                api.get("/messages/" + message["id"], headers=who[1]).status_code == 404
            )
            assert api.get(f"/media/{own_media}", headers=who[1]).status_code == 404
        assert api.get("/operations/clip", headers=owner[1]).status_code == 404
        assert group_send(api, owner, cid, "before").status_code == 404
        assert (
            call(
                api,
                owner,
                "create_group",
                operation_id="persistent",
                name="Art",
                avatar=avatar(),
                invitees=[outsider[0], member[0]],
            )["status"]
            == "dissolved"
        )


def test_action_rolls_back_membership_and_can_retry(chat):
    api, path, (owner, member, _) = chat
    group = call(
        api,
        owner,
        "create_group",
        name="Group",
        operation_id="rollback",
        invitees=[member[0]],
    )
    invite = notice(api, member, "group_invitation")
    with connection(path, write=True) as db:
        db.execute(
            """CREATE TRIGGER fail_system_message BEFORE INSERT ON messages
            WHEN NEW.sender IS NULL BEGIN SELECT RAISE(ABORT,'injected'); END"""
        )
    act(api, member, invite, "accept", status=503)
    assert shared_list(api, member)["items"] == []
    assert notice(api, member, "group_invitation")["state"] == "pending"
    assert call(api, owner, "list_notices")["items"] == []
    events = replay(api, member)["items"]
    assert [e["notification_id"] for e in events] == [invite["id"]]
    with connection(path, write=True) as db:
        db.execute("DROP TRIGGER fail_system_message")
    with api.websocket_connect(
        "/events?include_groups=true", headers=member[1]
    ) as socket:
        assert socket.receive_json() == events[0]
        act(api, member, invite, "accept")
        assert socket.receive_json()["active"] is True
    again = act(api, member, invite, "accept")
    assert again["state"] == "processed" and "已接受" in again["text"]
    assert notice(api, member, "group_invitation") == again
    assert shared_list(api, member)["items"][0]["conversation"] == group["conversation"]
    assert len(call(api, owner, "list_notices")["items"]) == 1


def test_dissolve_racing_an_authorized_media_stream(chat, monkeypatch):
    api, path, (owner, member, _) = chat
    group = call(
        api,
        owner,
        "create_group",
        name="Group",
        operation_id="file-race",
        invitees=[member[0]],
    )
    cid = group["conversation"]["id"]
    act(api, member, notice(api, member, "group_invitation"), "accept")
    image = png()
    media_id = upload(
        api, owner, {"conversation_id": cid}, (image, "image.png", "image/png")
    )
    assert (
        group_send(
            api, owner, cid, "image", [{"type": "image", "media_id": media_id}]
        ).status_code
        == 200
    )

    response_ready, resume = Event(), Event()
    send = AuthorizedGroupFile.__call__

    async def pause(response, *args):
        response_ready.set()
        assert await run_in_threadpool(resume.wait, 5)
        await send(response, *args)

    monkeypatch.setattr(AuthorizedGroupFile, "__call__", pause)
    endpoint = "/media/" + media_id
    with ThreadPoolExecutor(max_workers=1) as executor:
        inflight = executor.submit(api.get, endpoint, headers=member[1])
        try:
            assert response_ready.wait(5)
            call(api, owner, "dissolve_group", conversation=group["conversation"])
            assert api.get(endpoint, headers=member[1]).status_code == 404
            if os.name == "posix":
                assert not (path.parent / (path.name + ".media") / media_id).exists()
        finally:
            resume.set()
        assert inflight.result(timeout=5).content == image
