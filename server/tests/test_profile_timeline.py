"""DEA-485 shared-authority HTTP regressions over isolated synthetic facts."""

import sqlite3
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta

import pytest
from bb_auth_contract import ErrorResponse
from space_support import call, publish
from test_space import setup as setup  # noqa: PLC0414 - pytest fixture registration


def at(api, path, who, instant, text="post", reference_id=None):
    pid = publish(api, who, text, reference_id)
    with sqlite3.connect(path) as db:
        db.execute("UPDATE space_posts SET created_at=? WHERE id=?", (instant, pid))
    return pid


def ids(page):
    return [p["post_id"] for p in page["items"]]


def timeline(api, who, target, **kwargs):
    return call(
        api,
        who,
        "list_profile_posts",
        target_account=target[0],
        timezone_offset_minutes=0,
        **kwargs,
    )


def test_profile_month_jump_continues_and_repost_uses_own_time(setup):
    api, path, (a, b, viewer), _ = setup
    july = at(api, path, a, "2026-07-03T12:00:00.000000Z")
    september = at(api, path, a, "2026-09-03T12:00:00.000000Z")
    october = at(api, path, a, "2026-10-30T12:00:00.000000Z")
    source = at(api, path, b, "2026-08-01T12:00:00.000000Z", "source")
    repost = at(api, path, a, "2026-11-03T12:00:00.000000Z", "my note", source)
    # Neither private drafts nor standalone likes/comments create entries/months.
    call(api, a, "create_draft", text="private")
    call(api, a, "set_like", post_id=source, liked=True)
    call(api, a, "create_comment", post_id=source, text="comment")
    assert ids(timeline(api, viewer, a)) == [repost, october, september, july]
    assert call(
        api,
        viewer,
        "list_profile_months",
        target_account=a[0],
        timezone_offset_minutes=0,
    )["items"] == [{"year": 2026, "month": m} for m in (11, 10, 9, 7)]
    page = timeline(api, viewer, a, month="2026-10", limit=1)
    assert ids(page) == [october]
    page = timeline(
        api, viewer, a, month="2026-10", cursor=page["next_cursor"], limit=2
    )
    assert ids(page) == [september, july] and not page["has_more"]
    assert ids(timeline(api, viewer, a, month="2026-08")) == [july]
    call(api, b, "delete_post", post_id=source)
    projected = timeline(api, viewer, a)["items"][0]
    assert projected["text"] == "my note" and projected["reference"]["deleted"]
    assert projected["reference"]["text"] is None
    assert projected["reference"]["author"] is None
    call(api, a, "delete_post", post_id=october)
    assert call(
        api,
        viewer,
        "list_profile_months",
        target_account=a[0],
        timezone_offset_minutes=0,
    )["items"] == [{"year": 2026, "month": m} for m in (11, 9, 7)]


@pytest.mark.parametrize("offset", [-840, -330, 0, 345, 840])
def test_directory_jump_matches_explicit_display_offset_at_month_and_year_edges(
    setup, offset
):
    api, path, (a, b, _), _ = setup
    instants = [
        "2025-12-31T23:59:59.999999Z",
        "2026-01-01T00:00:00.000000Z",
        "2026-09-30T23:59:59.999999Z",
        "2026-10-01T00:00:00.000000Z",
        "2026-10-31T23:59:59.999999Z",
        "2026-11-01T00:00:00.000000Z",
    ]
    records = [(at(api, path, a, stamp), stamp) for stamp in instants]
    display = {
        pid: (datetime.fromisoformat(stamp) + timedelta(minutes=offset)).strftime(
            "%Y-%m"
        )
        for pid, stamp in records
    }
    months = sorted(set(display.values()), reverse=True)
    directory = call(
        api,
        b,
        "list_profile_months",
        target_account=a[0],
        timezone_offset_minutes=offset,
    )
    assert directory["items"] == [
        {"year": int(m[:4]), "month": int(m[5:])} for m in months
    ]
    for month in months:
        page = call(
            api,
            b,
            "list_profile_posts",
            target_account=a[0],
            timezone_offset_minutes=offset,
            month=month,
        )
        assert ids(page) == [
            pid for pid, _ in reversed(records) if display[pid] <= month
        ]


def test_equal_timestamp_keyset_snapshot_and_deletion(setup):
    api, path, (a, b, _), _ = setup
    stamp = "2026-10-30T12:00:00.000000Z"
    posts = sorted([at(api, path, a, stamp) for _ in range(7)], reverse=True)
    first = timeline(api, b, a, limit=2)
    assert ids(first) == posts[:2]
    inserted = at(api, path, a, stamp)
    backdated = at(api, path, a, "2026-01-01T00:00:00.000000Z")
    call(api, a, "delete_post", post_id=posts[3])
    found, cursor = ids(first), first["next_cursor"]
    while cursor:
        page = timeline(api, b, a, cursor=cursor, limit=1)
        found += ids(page)
        cursor = page["next_cursor"]
    assert found == [p for p in posts if p != posts[3]]
    assert len(found) == len(set(found))
    assert {inserted, backdated} <= set(ids(timeline(api, b, a)))


def test_follow_filter_publisher_history_empty_and_shared_post_state(setup):
    api, _, (a, b, viewer), _ = setup
    source = publish(api, b, "B original")
    own = publish(api, a, "A original")
    repost = publish(api, a, "A note", source)
    assert call(api, viewer, "list_posts", scope="following")["items"] == []
    assert call(api, viewer, "get_follow", target_account=a[0])["following"] is False
    assert call(api, viewer, "set_follow", target_account=a[0], following=True) == {
        "target_account": a[0],
        "following": True,
    }
    assert set(ids(call(api, viewer, "list_posts", scope="following"))) == {own, repost}
    assert ids(call(api, viewer, "list_posts", scope="following", author=b[0])) == []
    assert all(p["author_following"] for p in timeline(api, viewer, a)["items"])
    assert call(api, viewer, "get_post", post_id=own)["author_following"] is True
    assert call(api, b, "get_post", post_id=own)["author_following"] is False
    call(api, viewer, "mark_read", post_ids=[own])
    assert ids(
        call(api, viewer, "list_posts", scope="following", unread_only=True)
    ) == [repost]
    call(api, viewer, "set_follow", target_account=a[0], following=False)
    assert call(api, viewer, "list_posts", scope="following")["items"] == []
    assert set(ids(call(api, viewer, "list_posts"))) == {source, own, repost}
    assert not any(p["author_following"] for p in timeline(api, viewer, a)["items"])


def test_cursor_binding_to_viewer_target_month_offset_action_and_feed_query(setup):
    api, path, (a, b, c), _ = setup
    for _ in range(3):
        at(api, path, a, "2026-10-30T12:00:00.000000Z")
    query = {
        "target_account": a[0],
        "month": "2026-10",
        "timezone_offset_minutes": 0,
        "limit": 1,
    }
    cursor = call(api, b, "list_profile_posts", **query)["next_cursor"]
    for changes in (
        {"target_account": c[0]},
        {"month": None},
        {"month": "2026-09"},
        {"timezone_offset_minutes": 60},
    ):
        result = call(
            api,
            b,
            "list_profile_posts",
            **{**query, **changes},
            cursor=cursor,
            status=422,
        )
        assert result["error"]["code"] == "validation_error"
    call(api, c, "list_profile_posts", **query, cursor=cursor, status=422)
    call(api, b, "list_posts", cursor=cursor, status=422)
    feed_cursor = call(api, b, "list_posts", limit=1)["next_cursor"]
    for changes in ({"scope": "following"}, {"author": a[0]}, {"unread_only": True}):
        call(api, b, "list_posts", cursor=feed_cursor, status=422, **changes)
    call(api, b, "set_follow", target_account=a[0], following=True)
    cursor = call(api, b, "list_posts", scope="following", limit=1)["next_cursor"]
    # Duplicate desired state does not invalidate a continuation.
    call(api, b, "set_follow", target_account=a[0], following=True)
    call(api, b, "list_posts", scope="following", cursor=cursor)
    call(api, b, "set_follow", target_account=a[0], following=False)
    call(api, b, "list_posts", scope="following", cursor=cursor, status=422)
    call(api, b, "set_follow", target_account=a[0], following=True)
    call(api, b, "list_posts", scope="following", cursor=cursor, status=422)


def test_follow_idempotence_concurrent_requests_and_private_events(setup):
    api, path, (a, b, _), _ = setup
    for desired in (True, False):
        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(
                pool.map(
                    lambda _, desired=desired: call(
                        api, a, "set_follow", target_account=b[0], following=desired
                    ),
                    range(8),
                )
            )
        assert all(r["following"] == desired for r in results)
        assert call(api, a, "get_follow", target_account=b[0])["following"] == desired
    events = [
        e for e in call(api, a, "read_events")["items"] if e["type"] == "follow.changed"
    ]
    assert len(events) == 2
    assert all(
        e["post_id"] is None
        and e["comment_id"] is None
        and e["notification_id"] is None
        for e in events
    )
    assert not any(
        e["type"] == "follow.changed" for e in call(api, b, "read_events")["items"]
    )
    with sqlite3.connect(path) as db:
        assert db.execute("SELECT count(*) FROM space_follows").fetchone()[0] == 0
        assert (
            db.execute(
                "SELECT revision FROM space_follow_versions WHERE account=?", (a[0],)
            ).fetchone()[0]
            == 2
        )


@pytest.mark.parametrize("desired", [True, False])
@pytest.mark.parametrize("boundary", ["revision", "event"])
def test_follow_failure_rolls_back_state_revision_event_then_retry(
    setup, desired, boundary
):
    api, path, (a, b, _), _ = setup
    call(api, a, "set_follow", target_account=b[0], following=not desired)
    with sqlite3.connect(path) as db:
        before = {
            t: db.execute(f"SELECT * FROM {t}").fetchall()
            for t in ("space_follows", "space_follow_versions", "space_events")
        }
        table = "space_follow_versions" if boundary == "revision" else "space_events"
        db.execute(
            f"CREATE TRIGGER fail_follow BEFORE INSERT ON {table} BEGIN SELECT RAISE(ABORT,'injected'); END"
        )
    result = call(
        api, a, "set_follow", target_account=b[0], following=desired, status=503
    )
    ErrorResponse.model_validate(result)
    with sqlite3.connect(path) as db:
        assert {
            t: db.execute(f"SELECT * FROM {t}").fetchall() for t in before
        } == before
        db.execute("DROP TRIGGER fail_follow")
    assert call(api, a, "get_follow", target_account=b[0])["following"] == (not desired)
    assert (
        call(api, a, "set_follow", target_account=b[0], following=desired)["following"]
        == desired
    )


def test_profile_and_follow_errors_keep_existing_envelope(setup):
    api, _, (a, b, c), _ = setup
    for desired in (True, False):
        result = call(
            api, a, "set_follow", target_account=a[0], following=desired, status=422
        )
        assert result["error"] == {
            "code": "validation_error",
            "message": "validation_error",
            "fields": [],
        }
    assert call(api, a, "get_follow", target_account=a[0])["following"] is False
    missing = next(
        str(n) for n in range(10000000, 10000100) if str(n) not in {a[0], b[0], c[0]}
    )
    for action, kwargs in (
        ("get_follow", {}),
        ("set_follow", {"following": False}),
        ("list_profile_posts", {"timezone_offset_minutes": 0}),
        ("list_profile_months", {"timezone_offset_minutes": 0}),
    ):
        result = call(api, a, action, target_account=missing, status=404, **kwargs)
        ErrorResponse.model_validate(result)
        assert result["error"]["code"] == "not_found"
    for malformed in (
        {"timezone_offset_minutes": 841},
        {"timezone_offset_minutes": True},
        {"month": "2026-13"},
        {"month": "9999-12"},
        {"month": "2026-1"},
        {"cursor": "not-a-cursor"},
        {"unexpected": "do-not-echo"},
    ):
        body = {"target_account": a[0], "timezone_offset_minutes": 0, **malformed}
        response = api.post("/space/list_profile_posts", headers=b[1], json=body)
        assert response.status_code == 422
        ErrorResponse.model_validate(response.json())
        assert "do-not-echo" not in response.text
    assert timeline(api, b, b)["items"] == []
    assert (
        call(
            api,
            a,
            "list_profile_months",
            target_account=b[0],
            timezone_offset_minutes=0,
        )["items"]
        == []
    )
