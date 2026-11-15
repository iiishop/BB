import base64
import io
import sqlite3
from concurrent.futures import ThreadPoolExecutor

import pytest
from bb_auth_contract import space
from fastapi.testclient import TestClient
from PIL import Image
from space_support import call, publish, register

from bb_server import space_media
from bb_server.app import create_app


class SpaceFixture(tuple):
    def __repr__(self):
        return "<isolated space fixture; credentials omitted>"


@pytest.fixture
def setup(tmp_path):
    path = tmp_path / "space.db"
    clock = [1800000000.0]
    with TestClient(create_app(path, clock=lambda: clock[0])) as api:
        accounts = [register(api, name) for name in ("Alice", "Bob", "Carol")]
        yield SpaceFixture((api, path, accounts, clock))


def png(color="red"):
    buf = io.BytesIO()
    Image.new("RGB", (12, 8), color).save(buf, format="PNG")
    return buf.getvalue()


def add(api, who, did, version, data=None):
    return call(
        api,
        who,
        "add_image",
        draft_id=did,
        expected_version=version,
        filename="../../picture.png",
        base64=base64.b64encode(data or png()).decode(),
    )


def test_t01_private_ten_images_order_and_immutable_publish(setup):
    api, _, (a, b, _), _ = setup
    did = call(api, a, "create_draft")["resource_id"]
    call(api, b, "get_draft", draft_id=did, status=404)
    assert call(api, b, "list_drafts")["items"] == []
    assert call(api, b, "list_posts")["items"] == []
    mids = [add(api, a, did, v, png((v, v, v)))["resource_id"] for v in range(1, 11)]
    assert api.get("/space/images/" + mids[0], headers=b[1]).status_code == 404
    assert api.get("/space/images/" + mids[0], headers=a[1]).content == png((1, 1, 1))
    removed = mids.pop(3)
    call(
        api,
        a,
        "update_draft",
        draft_id=did,
        expected_version=11,
        text="long " * 1000,
        image_ids=mids,
    )
    assert api.get("/space/images/" + removed, headers=a[1]).status_code == 404
    mids.append(add(api, a, did, 12)["resource_id"])
    mids.reverse()
    call(
        api,
        a,
        "update_draft",
        draft_id=did,
        expected_version=13,
        text="long " * 1000,
        image_ids=mids,
    )
    pid = call(api, a, "publish_draft", draft_id=did, expected_version=14)[
        "resource_id"
    ]
    post = call(api, b, "get_post", post_id=pid)
    assert [x["image_id"] for x in post["images"]] == mids
    assert len(post["images"]) == 10
    assert all(x["filename"] == "picture.png" for x in post["images"])
    assert (
        api.get(post["images"][0]["thumbnail_url"], headers=b[1]).headers[
            "content-type"
        ]
        == "image/jpeg"
    )
    call(
        api,
        a,
        "update_draft",
        draft_id=did,
        expected_version=15,
        text="changed",
        image_ids=[],
        status=409,
    )
    call(
        api,
        a,
        "add_image",
        draft_id=did,
        expected_version=15,
        filename="x.png",
        base64=base64.b64encode(png()).decode(),
        status=409,
    )
    assert call(api, a, "get_draft", draft_id=did)["text"] == ""


def test_t02_conflict_publish_race_and_missing_attachment(setup):
    api, path, (a, b, _), _ = setup
    did = call(api, a, "create_draft", text="first")["resource_id"]

    def update(i):
        return api.post(
            "/space/update_draft",
            headers=a[1],
            json={
                "operation_id": f"u{i}",
                "draft_id": did,
                "expected_version": 1,
                "text": f"writer{i}",
                "image_ids": [],
            },
        )

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(update, range(2)))
    assert sorted(r.status_code for r in results) == [200, 409]
    winner = call(api, a, "get_draft", draft_id=did)["text"]
    call(
        api,
        a,
        "update_draft",
        draft_id=did,
        expected_version=2,
        text="bad",
        image_ids=["incomplete"],
        status=422,
    )

    def retry(_):
        return call(
            api,
            a,
            "publish_draft",
            draft_id=did,
            expected_version=2,
            operation_id="publish_once",
        )

    with ThreadPoolExecutor(max_workers=8) as pool:
        responses = list(pool.map(retry, range(8)))
    assert all(r == responses[0] for r in responses)
    pid = responses[0]["resource_id"]
    assert call(api, b, "get_post", post_id=pid)["text"] == winner
    assert call(api, a, "get_operation", operation_id="publish_once") == responses[0]
    call(api, b, "get_operation", operation_id="publish_once", status=404)
    call(
        api,
        a,
        "publish_draft",
        draft_id=did,
        expected_version=1,
        operation_id="publish_once",
        status=409,
    )
    with sqlite3.connect(path) as db:
        assert db.execute("SELECT count(*) FROM space_posts").fetchone()[0] == 1
        assert (
            db.execute(
                "SELECT count(*) FROM space_events WHERE type='post.changed'"
            ).fetchone()[0]
            == 1
        )


def test_t02_edit_and_publish_serialize_same_version(setup):
    api, _, (a, _, _), _ = setup
    did = call(api, a, "create_draft", text="v1")["resource_id"]

    def write(action):
        body = {"operation_id": action, "draft_id": did, "expected_version": 1}
        if action == "update_draft":
            body.update(text="v2", image_ids=[])
        space.REQUESTS[action].model_validate(body)
        return action, api.post("/space/" + action, headers=a[1], json=body)

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = dict(pool.map(write, ["publish_draft", "update_draft"]))
    assert sorted(r.status_code for r in results.values()) == [200, 409]
    if results["publish_draft"].status_code == 200:
        assert (
            call(
                api,
                a,
                "get_post",
                post_id=results["publish_draft"].json()["resource_id"],
            )["text"]
            == "v1"
        )
    else:
        assert call(api, a, "get_draft", draft_id=did)["text"] == "v2"


def test_t03_keyset_ties_new_inserts_and_no_interaction_reorder(setup):
    api, _, (a, b, _), clock = setup
    ids = [publish(api, a, str(i)) for i in range(7)]
    page = call(api, b, "list_posts", limit=2)
    seen = [p["post_id"] for p in page["items"]]
    clock[0] += 1
    newest = publish(api, b, "new")
    call(api, b, "set_like", post_id=ids[0], liked=True)
    while page["has_more"]:
        page = call(api, b, "list_posts", limit=2, cursor=page["next_cursor"])
        seen += [p["post_id"] for p in page["items"]]
    assert seen == sorted(ids, reverse=True)
    assert call(api, b, "list_posts")["items"][0]["post_id"] == newest
    assert len(call(api, a, "list_posts", author=b[0])["items"]) == 1
    cursor = call(api, a, "list_posts", limit=1)["next_cursor"]
    call(api, b, "list_posts", cursor=cursor, status=422)
    call(api, a, "list_posts", cursor=cursor, unread_only=True, status=422)


def test_t03_equal_timestamp_new_post_is_excluded_until_refresh(setup, monkeypatch):
    api, _, (a, b, _), _ = setup
    from types import SimpleNamespace

    from bb_server import space_store

    # Exact IDs make the new same-time row sort below the saved anchor.
    ids = iter([f"{n:032x}" for n in (100, 900, 101, 800, 102, 700, 103, 600, 104, 1)])
    monkeypatch.setattr(
        space_store,
        "uuid",
        SimpleNamespace(uuid4=lambda: SimpleNamespace(hex=next(ids))),
    )
    baseline = [publish(api, a, str(i)) for i in range(4)]
    first = call(api, b, "list_posts", limit=2)
    fresh = publish(api, a, "same timestamp new row")
    rest = call(api, b, "list_posts", cursor=first["next_cursor"], limit=100)
    assert [p["post_id"] for p in first["items"] + rest["items"]] == sorted(
        baseline, reverse=True
    )
    assert fresh in {p["post_id"] for p in call(api, b, "list_posts")["items"]}


def test_t04_t05_deep_comments_bounded_context_exact_recipients(setup):
    api, _, (a, b, c), clock = setup
    pid = publish(api, a)
    roots = []
    for i in range(6):
        clock[0] += 1
        roots.append(
            call(api, b, "create_comment", post_id=pid, text=str(i))["resource_id"]
        )
    parent = roots[0]
    descendants = []
    for i, who in enumerate((c, a, a, b)):
        clock[0] += 1
        parent = call(
            api,
            who,
            "create_comment",
            post_id=pid,
            text=f"depth{i}",
            reply_to_id=parent,
        )["resource_id"]
        descendants.append(parent)
    post = call(api, a, "get_post", post_id=pid)
    assert len(post["preview_comments"]) == 5 and post["remaining_roots"] == 1
    assert len(post["preview_comments"][0]["replies"]) == 3
    assert post["preview_comments"][0]["remaining_replies"] == 1
    page = call(api, c, "list_comments", post_id=pid, root_id=roots[0], limit=2)
    page2 = call(
        api,
        c,
        "list_comments",
        post_id=pid,
        root_id=roots[0],
        limit=2,
        cursor=page["next_cursor"],
    )
    assert [x["comment_id"] for x in page["items"] + page2["items"]] == descendants
    context = call(api, c, "get_comment_context", comment_id=descendants[-1], radius=1)
    assert context["root"]["comment_id"] == roots[0]
    assert context["parent"]["comment_id"] == descendants[-2]
    assert context["target"]["reply_to_author"]["account"] == a[0]
    notices = [call(api, who, "list_notifications")["items"] for who in (a, b, c)]
    assert len(notices[0]) == 7  # six roots plus b's direct reply to a
    assert [x["comment_id"] for x in notices[1]] == [descendants[0]]
    assert [x["comment_id"] for x in notices[2]] == [descendants[1]]
    assert all(x["comment_id"] != descendants[2] for xs in notices for x in xs)


def test_t06_t07_reposts_delete_scrub_media_and_shared_blob(setup):
    api, path, (a, b, c), _ = setup
    did = call(api, a, "create_draft", text="erase_original_secret")["resource_id"]
    mid = add(api, a, did, 1)["resource_id"]
    original = call(api, a, "publish_draft", draft_id=did, expected_version=2)[
        "resource_id"
    ]
    other = call(api, a, "create_draft", text="independent")["resource_id"]
    other_mid = add(api, a, other, 1)["resource_id"]
    second = publish(api, b, "B own text", original)
    third = publish(api, c, "C own text", second)
    cid = call(api, b, "create_comment", post_id=original, text="erase_comment_secret")[
        "resource_id"
    ]
    call(api, c, "set_like", post_id=original, liked=True)
    call(api, b, "get_post", post_id=original, visit_id="visit")
    call(api, b, "mark_read", post_ids=[original])
    assert call(api, c, "get_post", post_id=third)["reference"]["post_id"] == second
    assert [
        n["target_post_id"] for n in call(api, b, "list_notifications")["items"]
    ] == [third]
    thumb = api.get(f"/space/images/{mid}?variant=thumb", headers=b[1])
    assert thumb.status_code == 200
    call(api, a, "delete_post", post_id=original)
    for action, args in (
        ("get_post", {"post_id": original}),
        ("list_comments", {"post_id": original}),
        ("list_likes", {"post_id": original}),
        ("list_visitors", {"post_id": original}),
        ("get_comment_context", {"comment_id": cid}),
    ):
        call(api, a, action, status=404, **args)
    assert api.get(f"/space/images/{mid}", headers=a[1]).status_code == 404
    assert (
        api.get(
            f"/space/images/{mid}?variant=thumb",
            headers={**b[1], "If-None-Match": '"anything"'},
        ).status_code
        == 404
    )
    assert api.get(f"/space/images/{other_mid}", headers=a[1]).content == png()
    ref = call(api, c, "get_post", post_id=second)["reference"]
    assert ref["deleted"] and ref["text"] is ref["image"] is ref["author"] is None
    notices = call(api, a, "list_notifications")["items"]
    assert any(
        n["kind"] == "repost" and n["accessible"] and n["snippet"] == "B own text"
        for n in notices
    )
    assert any(
        n["kind"] == "comment" and n["deleted"] and n["snippet"] is None
        for n in notices
    )
    assert any(
        n["kind"] == "like" and n["deleted"] and n["actor_count"] == 0 for n in notices
    )
    with sqlite3.connect(path) as db:
        for table in (
            "space_comments",
            "space_likes",
            "space_reads",
            "space_visits",
            "space_visitors",
        ):
            assert (
                db.execute(
                    f"SELECT count(*) FROM {table} WHERE post_id=?", (original,)
                ).fetchone()[0]
                == 0
            )
        # Logical projection/database rows, not a promise to erase disk backups.
        logical_dump = "\n".join(db.iterdump())
        assert "erase_original_secret" not in logical_dump
        assert "erase_comment_secret" not in logical_dump
    call(api, b, "delete_post", post_id=second)
    assert call(api, c, "get_post", post_id=third)["reference"]["deleted"]


def test_t08_parent_tombstones_keep_children_and_forbid_foreign_delete(setup):
    api, _, (a, b, c), _ = setup
    pid = publish(api, a)
    root = call(api, b, "create_comment", post_id=pid, text="parent secret")[
        "resource_id"
    ]
    middle = call(
        api, c, "create_comment", post_id=pid, reply_to_id=root, text="middle secret"
    )["resource_id"]
    leaf = call(
        api, a, "create_comment", post_id=pid, reply_to_id=middle, text="survives"
    )["resource_id"]
    call(api, a, "delete_comment", comment_id=root, status=403)
    call(api, b, "delete_post", post_id=pid, status=403)
    call(api, b, "delete_comment", comment_id=root)
    call(api, c, "delete_comment", comment_id=middle)
    context = call(api, b, "get_comment_context", comment_id=leaf)
    assert context["root"]["deleted"] and context["root"]["text"] is None
    assert context["parent"]["deleted"] and context["parent"]["text"] is None
    assert context["target"]["reply_to_author"]["account"] == c[0]
    assert context["target"]["text"] == "survives"
    call(
        api, a, "create_comment", post_id=pid, reply_to_id=root, text="bad", status=404
    )
    call(api, b, "create_comment", post_id=pid, reply_to_id=leaf, text="valid")
    assert call(api, c, "list_notifications")["items"][0]["accessible"]


def test_t09_t10_read_visit_and_notification_state_are_independent(setup):
    api, _, (a, b, c), _ = setup
    ids = [publish(api, a, str(i)) for i in range(3)]
    pid = ids[1]
    call(api, b, "overview")
    call(api, b, "list_posts")
    call(api, b, "get_post", post_id=pid)  # explicit preview default
    assert call(api, a, "get_view_summary", post_id=pid)["view_count"] == 0
    for visit in ("one", "one", "two"):
        call(api, b, "get_post", post_id=pid, visit_id=visit)
    call(api, c, "get_post", post_id=pid, visit_id="one")
    assert call(api, b, "get_view_summary", post_id=pid)["view_count"] == 3
    assert call(api, b, "overview")["unread_posts"] == 3
    call(api, b, "mark_read", post_ids=[pid], operation_id="read")
    call(api, b, "mark_read", post_ids=[pid], operation_id="read")
    assert {
        p["post_id"] for p in call(api, b, "list_posts", unread_only=True)["items"]
    } == set(ids) - {pid}
    visitors = call(api, a, "list_visitors", post_id=pid)["items"]
    assert {v["author"]["account"]: v["count"] for v in visitors} == {b[0]: 2, c[0]: 1}
    call(api, b, "list_visitors", post_id=pid, status=403)
    call(api, c, "list_visitors", post_id=pid, status=403)
    assert call(api, a, "list_notifications")["items"] == []
    call(api, c, "create_comment", post_id=pid, text="new comment")
    assert call(api, b, "get_post", post_id=pid)["read"]
    call(api, b, "get_post", post_id=ids[0], visit_id="one", status=409)


def test_t11_like_version_watermark_and_relike_does_not_spam(setup):
    api, _, (a, b, c), _ = setup
    pid = publish(api, a)
    call(api, b, "set_like", post_id=pid, liked=True)
    first = call(api, a, "list_notifications")["items"][0]
    call(api, c, "set_like", post_id=pid, liked=True)
    call(
        api,
        a,
        "ack_notifications",
        items=[
            {"notification_id": first["notification_id"], "version": first["version"]}
        ],
    )
    latest = call(api, a, "list_notifications")["items"][0]
    assert latest["unread"] and latest["version"] == 2 and latest["ack_version"] == 1
    before = call(api, a, "read_events")["next_event_id"]
    call(api, b, "set_like", post_id=pid, liked=True)
    assert call(api, a, "read_events", after_event_id=before)["items"] == []
    call(api, b, "set_like", post_id=pid, liked=False)
    assert len(call(api, a, "list_likes", post_id=pid)["items"]) == 1
    call(api, b, "set_like", post_id=pid, liked=True)
    assert call(api, a, "list_notifications")["items"][0]["version"] == 2
    call(
        api,
        a,
        "ack_notifications",
        items=[{"notification_id": first["notification_id"], "version": 3}],
        status=409,
    )
    call(
        api,
        b,
        "ack_notifications",
        items=[{"notification_id": first["notification_id"], "version": 1}],
        status=404,
    )
    call(api, a, "set_like", post_id=pid, liked=True)
    call(api, a, "create_comment", post_id=pid, text="self")
    publish(api, a, "self repost", pid)
    assert len(call(api, a, "list_notifications")["items"]) == 1


@pytest.mark.parametrize("first", ["delete", "write"])
def test_t12_delete_and_write_commit_orders(setup, first):
    api, _, (a, b, _), _ = setup
    pid = publish(api, a)
    did = call(api, b, "create_draft", reference_id=pid)["resource_id"]
    if first == "delete":
        call(api, a, "delete_post", post_id=pid)
        call(api, b, "publish_draft", draft_id=did, expected_version=1, status=409)
        call(api, b, "create_comment", post_id=pid, text="late", status=404)
        call(api, b, "set_like", post_id=pid, liked=True, status=404)
        assert call(api, b, "get_draft", draft_id=did)["state"] == "draft"
    else:
        repost = call(api, b, "publish_draft", draft_id=did, expected_version=1)[
            "resource_id"
        ]
        cid = call(api, b, "create_comment", post_id=pid, text="before")["resource_id"]
        call(api, a, "delete_post", post_id=pid)
        call(api, b, "get_comment_context", comment_id=cid, status=404)
        assert call(api, b, "get_post", post_id=repost)["reference"]["deleted"]
    events = call(api, b, "read_events")
    assert events == call(api, b, "read_events")
    assert any(e["type"] == "post.deleted" for e in events["items"])


def test_t12_transaction_rollback_does_not_publish_without_event(setup):
    api, path, (a, b, _), _ = setup
    source_id = publish(api, b)
    did = call(api, a, "create_draft", text="rollback", reference_id=source_id)[
        "resource_id"
    ]
    before = call(api, b, "read_events")
    with sqlite3.connect(path) as db:
        db.execute(
            "CREATE TRIGGER fail_space_event BEFORE INSERT ON space_events BEGIN SELECT RAISE(ABORT,'fault'); END"
        )
    call(
        api,
        a,
        "publish_draft",
        draft_id=did,
        expected_version=1,
        operation_id="retry",
        status=503,
    )
    call(api, a, "get_operation", operation_id="retry", status=404)
    assert call(api, a, "get_draft", draft_id=did)["version"] == 1
    assert call(api, b, "read_events") == before
    assert call(api, b, "list_notifications")["items"] == []
    with sqlite3.connect(path) as db:
        db.execute("DROP TRIGGER fail_space_event")
    call(
        api, a, "publish_draft", draft_id=did, expected_version=1, operation_id="retry"
    )
    assert len(call(api, b, "list_notifications")["items"]) == 1


def test_media_unready_and_cleanup_failure_retry_after_restart(setup, monkeypatch):
    api, path, (a, b, _), _ = setup
    did = call(api, a, "create_draft")["resource_id"]
    mid = add(api, a, did, 1)["resource_id"]
    directory = path.parent / (path.name + ".media") / "space"
    with sqlite3.connect(path) as db:
        blob = db.execute(
            "SELECT blob FROM space_images WHERE id=?", (mid,)
        ).fetchone()[0]
    data = (directory / blob).read_bytes()
    (directory / blob).unlink()
    call(api, a, "publish_draft", draft_id=did, expected_version=2, status=422)
    (directory / blob).write_bytes(data)
    pid = call(api, a, "publish_draft", draft_id=did, expected_version=2)["resource_id"]

    def unavailable(*args, **kwargs):
        raise OSError("synthetic cleanup failure")

    with monkeypatch.context() as patch:
        patch.setattr(space_media, "collect", unavailable)
        call(api, a, "delete_post", post_id=pid)
        assert api.get(f"/space/images/{mid}", headers=b[1]).status_code == 404
        assert (directory / blob).is_file()
        with sqlite3.connect(path) as db:
            assert db.execute("SELECT count(*) FROM space_gc").fetchone()[0] == 1
    with TestClient(create_app(path, clock=lambda: 1800000000.0)) as restarted:
        call(restarted, b, "get_post", post_id=pid, status=404)
    assert not (directory / blob).exists()


def test_transport_auth_errors_replay_and_request_bounds(setup):
    api, _, (a, b, _), _ = setup
    for action in space.REQUESTS:
        response = api.post("/space/" + action, json={})
        assert response.status_code == 401
    for payload in ({"author": b[0]}, {"secret_unknown": "do-not-echo"}):
        response = api.post("/space/overview", headers=a[1], json=payload)
        assert response.status_code == 422 and "do-not-echo" not in response.text
    assert (
        api.post(
            "/space/overview", headers=a[1], content=b"x" * (1024 * 1024 + 1)
        ).status_code
        == 413
    )
    pid = publish(api, a)
    call(api, b, "set_like", post_id=pid, liked=True)
    all_events = call(api, a, "read_events")
    cursor, gathered = 0, []
    while True:
        page = call(api, a, "read_events", after_event_id=cursor, limit=1)
        gathered += page["items"]
        cursor = page["next_event_id"]
        if not page["has_more"]:
            break
    assert gathered == all_events["items"]
    with api.websocket_connect("/space/events", headers=a[1]) as ws:
        assert ws.receive_json() == gathered[0]
    b_events = call(api, b, "read_events")["items"]
    assert all(
        e["type"] not in ("draft.changed", "notification.changed") for e in b_events
    )


def test_space_routes_use_shared_schema_and_preserve_chat_openapi(setup):
    api, _, _, _ = setup
    schema = api.get("/openapi.json").json()
    for action in space.REQUESTS:
        route = schema["paths"]["/space/" + action]["post"]
        assert route["security"] == [{"HTTPBearer": []}]
    assert "/messages" in schema["paths"] and "/auth/login" in schema["paths"]


@pytest.mark.parametrize("first", ["delete_post", "create_comment"])
def test_t12_actual_inflight_writers_serialize_before_visibility(
    setup, monkeypatch, first
):
    from threading import Event

    from bb_server import space as routes
    from bb_server import space_store

    api, _, (a, b, _), _ = setup
    pid = publish(api, a)
    held, admitted, release = Event(), Event(), Event()
    original_event, original_execute = space_store.event, routes.execute
    first_kind = "post.deleted" if first == "delete_post" else "post.changed"
    second = "create_comment" if first == "delete_post" else "delete_post"

    def event(db, timestamp, kind, **kw):
        if kind == first_kind and kw.get("post_id") == pid:
            held.set()
            assert release.wait(5)
        return original_event(db, timestamp, kind, **kw)

    def execute(path, directory, identity, action, body, clock):
        if action == second:
            admitted.set()
        return original_execute(path, directory, identity, action, body, clock)

    monkeypatch.setattr(space_store, "event", event)
    monkeypatch.setattr(routes, "execute", execute)

    def request(action):
        body = {"post_id": pid, "operation_id": action}
        if action == "create_comment":
            body["text"] = "inflight"
        space.REQUESTS[action].model_validate(body)
        return api.post(
            "/space/" + action,
            headers=(a if action == "delete_post" else b)[1],
            json=body,
        )

    with ThreadPoolExecutor(max_workers=2) as pool:
        one = pool.submit(request, first)
        try:
            assert held.wait(5)
            two = pool.submit(request, second)
            assert admitted.wait(5)
            assert not two.done()
        finally:
            release.set()
        first_result, second_result = one.result(timeout=5), two.result(timeout=5)
    assert first_result.status_code == 200
    assert second_result.status_code == (404 if first == "delete_post" else 200)
    call(api, b, "get_post", post_id=pid, status=404)
    if first == "create_comment":
        call(
            api,
            b,
            "get_comment_context",
            comment_id=first_result.json()["resource_id"],
            status=404,
        )


def test_draft_delete_and_uncommitted_upload_recovery(setup):
    api, path, (a, b, _), _ = setup
    did = call(api, a, "create_draft", text="private")["resource_id"]
    call(api, b, "delete_draft", draft_id=did, expected_version=1, status=404)
    with sqlite3.connect(path) as db:
        db.execute(
            "CREATE TRIGGER fail_space_operation BEFORE INSERT ON space_operations BEGIN SELECT RAISE(ABORT,'fault'); END"
        )
    call(
        api,
        a,
        "add_image",
        draft_id=did,
        expected_version=1,
        filename="x.png",
        base64=base64.b64encode(png()).decode(),
        operation_id="image_once",
        status=503,
    )
    assert call(api, a, "get_draft", draft_id=did)["images"] == []
    directory = path.parent / (path.name + ".media") / "space"
    assert len(list(directory.iterdir())) == 1  # durable precommit orphan, not visible
    with sqlite3.connect(path) as db:
        db.execute("DROP TRIGGER fail_space_operation")
    with TestClient(create_app(path, clock=lambda: 1800000000.0)) as restarted:
        assert list(directory.iterdir()) == []
        mid = call(
            restarted,
            a,
            "add_image",
            draft_id=did,
            expected_version=1,
            filename="x.png",
            base64=base64.b64encode(png()).decode(),
            operation_id="image_once",
        )["resource_id"]
        call(restarted, a, "delete_draft", draft_id=did, expected_version=1, status=409)
        receipt = call(
            restarted,
            a,
            "delete_draft",
            draft_id=did,
            expected_version=2,
            operation_id="delete_once",
        )
        assert (
            call(
                restarted,
                a,
                "delete_draft",
                draft_id=did,
                expected_version=2,
                operation_id="delete_once",
            )
            == receipt
        )
        tombstone = call(restarted, a, "get_draft", draft_id=did)
        assert (
            tombstone["state"] == "deleted"
            and tombstone["text"] == ""
            and tombstone["images"] == []
        )
        call(restarted, a, "get_image", image_id=mid, status=404)
        call(
            restarted, a, "publish_draft", draft_id=did, expected_version=3, status=409
        )
