"""Run profile/follow acceptance through real stdio, Dart and FastAPI.

From the repository root, after preparing client dependencies:
uv run --project dsh-plugin --locked python dsh-plugin/probes/space_profile_mcp.py
Only the synthetic post timestamps are assigned directly in the isolated DB.
"""

import asyncio
import json
import sqlite3
import sys
from contextlib import closing
from datetime import UTC, datetime

from bb_auth_contract import space
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from space_live import Live

PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
LONG_TEXT = "长正文" * 4000


def record(cases, **facts):
    print(json.dumps({"cases": cases, "status": "PASS", **facts}), flush=True)


def publish(live, day, *, image=False, reference=None):
    draft = live.call(
        "create_draft",
        {"operation_id": day + "-draft", "text": LONG_TEXT, "reference_id": reference},
    )
    draft_id = draft["resource_id"]
    image_id = None
    if image:
        image_id = live.call(
            "add_image",
            {
                "operation_id": day + "-image",
                "draft_id": draft_id,
                "expected_version": 1,
                "filename": "fixture.png",
                "base64": PNG,
            },
        )["resource_id"]
    post_id = live.call(
        "publish_draft",
        {
            "operation_id": day + "-publish",
            "draft_id": draft_id,
            "expected_version": 2 if image else 1,
        },
    )["resource_id"]
    with closing(sqlite3.connect(live.root / "db")) as db, db:
        db.execute(
            "UPDATE space_posts SET created_at=? WHERE id=?",
            (day + "T12:00:00.000000Z", post_id),
        )
    return post_id, image_id


def ids(page):
    return [post["post_id"] for post in page["items"]]


async def check(live, author, viewer, private, expected, photo):
    state = live.root / "mcp-binding.json"
    state.touch(mode=0o600)
    state.write_text(json.dumps({"owner_key": live.owner, "identity": live.identity}))
    token = json.loads((live.root / "client/session.json").read_text())["token"]
    params = StdioServerParameters(
        command=sys.executable,
        args=["-m", "bb_dsh_plugin"],
        env={"BB_CLIENT_BASE_URL": live.local, "BB_CONSUMER_STATE_FILE": str(state)},
    )
    latest = {"target_account": author, "timezone_offset_minutes": 0}
    october = {**latest, "month": "2026-10"}

    def direct(action, payload, status=200):
        space.REQUESTS[action].model_validate(payload)
        body = live.post(
            "/space/" + action,
            payload,
            api=True,
            headers={"Authorization": "Bearer " + token},
            status=status,
        )
        if status == 200:
            space.RESPONSES[action].model_validate(body)
        return body

    def follow_rows():
        with closing(sqlite3.connect(live.root / "db")) as db:
            return db.execute(
                "SELECT account,target_account FROM space_follows"
            ).fetchall()

    async with (
        stdio_client(params) as (read, write),
        ClientSession(read, write) as session,
    ):
        await session.initialize()

        async def call(action, payload, *, error=None):
            reply = await session.call_tool("space_" + action, payload)
            assert reply.isError == (error is not None), (
                action,
                reply.structuredContent,
            )
            body = reply.structuredContent
            assert len(reply.content) == 1 and reply.content[0].type == "text"
            assert json.loads(reply.content[0].text) == body
            if error is not None:
                assert (body["status"], body["error"]["code"]) == error
            return (
                body,
                len(reply.content[0].text.encode()),
                len(reply.model_dump_json().encode()),
            )

        tools = (await session.list_tools()).tools
        names = [tool.name for tool in tools if tool.name.startswith("space_")]
        assert len(names) == 28
        assert set(names) >= {
            "space_get_follow",
            "space_set_follow",
            "space_list_profile_posts",
            "space_list_profile_months",
        }
        record([1], tools=names)

        months, *_ = await call("list_profile_months", latest)
        assert months == direct("list_profile_months", latest)
        assert [(m["year"], m["month"]) for m in months["items"]] == [
            (2026, 11),
            (2026, 10),
            (2026, 9),
            (2026, 7),
        ]
        record([2], months=["2026-11", "2026-10", "2026-09", "2026-07"])

        explicit = {**october, "limit": 3}
        large, text_bytes, result_bytes = await call("list_profile_posts", explicit)
        assert ids(large) == expected[:3]
        assert all(post["text"] == LONG_TEXT for post in large["items"])
        assert large["items"][0]["reference"]["image"] == {"image_id": photo}
        default, *_ = await call("list_profile_posts", october)
        assert ids(default) == expected[:1]
        await call(
            "list_profile_posts",
            {**october, "limit": 4},
            error=(422, "validation_error"),
        )

        target = {"target_account": author}
        assert (await call("get_follow", target))[0]["following"] is False
        follow = {**target, "following": True}
        assert (await call("set_follow", follow))[0] == follow
        assert (await call("get_follow", target))[0] == follow
        assert (await call("set_follow", follow))[0] == follow
        assert follow_rows() == [(viewer, author)]
        record([5], relationship_rows=1, following=True)

        cursor = default["next_cursor"]
        wrong_cursor = (422, "validation_error")
        for query in (
            latest,
            {**october, "month": "2026-09"},
            {**october, "target_account": viewer},
            {**october, "timezone_offset_minutes": 60},
        ):
            await call(
                "list_profile_posts", {**query, "cursor": cursor}, error=wrong_cursor
            )
        following, *_ = await call("list_posts", {"scope": "following", "limit": 1})
        assert following["next_cursor"]
        assert following["items"][0]["author"]["account"] == author
        await call(
            "list_profile_posts",
            {**october, "cursor": following["next_cursor"]},
            error=wrong_cursor,
        )
        for mode in ("all", "following"):
            await call(
                "list_posts", {"scope": mode, "cursor": cursor}, error=wrong_cursor
            )
        await call(
            "list_posts",
            {"scope": "all", "cursor": following["next_cursor"]},
            error=wrong_cursor,
        )
        await call("list_profile_months", {**latest, "target_account": viewer})

        second, *_ = await call(
            "list_profile_posts", {**october, "cursor": cursor, "limit": 3}
        )
        assert ids(default) + ids(second) == expected
        assert not second["has_more"] and second["next_cursor"] is None
        assert second["items"][-1]["images"] == [{"image_id": photo}]
        record(
            [3, 4], month="2026-10", posts=4, last_month="2026-07", cursor_mismatches=8
        )

        unfollow = {**target, "following": False}
        assert (await call("set_follow", unfollow))[0] == unfollow
        assert (await call("get_follow", target))[0] == unfollow
        assert (await call("set_follow", unfollow))[0] == unfollow
        assert follow_rows() == []
        record([6], relationship_rows=0, following=False)

        for desired in (True, False):
            payload = {"target_account": viewer, "following": desired}
            error, *_ = await call(
                "set_follow", payload, error=(422, "validation_error")
            )
            assert (
                error["error"]["code"]
                == direct("set_follow", payload, 422)["error"]["code"]
            )
        assert follow_rows() == []
        record([7], status_code=422, relationship_rows=0)

        private_query = {**latest, "target_account": private}
        private_posts, *_ = await call("list_profile_posts", private_query)
        assert (
            private_posts
            == direct("list_profile_posts", private_query)
            == {"items": [], "has_more": False, "next_cursor": None}
        )
        private_months, *_ = await call("list_profile_months", private_query)
        assert (
            private_months
            == direct("list_profile_months", private_query)
            == {"items": []}
        )
        public, *_ = await call("list_profile_posts", {**latest, "limit": 1})
        assert public == direct("list_profile_posts", {**latest, "limit": 1})
        record(
            [8],
            private_only_target_posts=0,
            private_only_target_months=0,
            public_post_matches=True,
        )

        await call("read_events", {}, error=(404, "unknown_tool"))
        record([9], error="unknown_tool", status_code=404)
        record(
            [11],
            posts=len(large["items"]),
            chars_per_post=len(LONG_TEXT),
            text_utf8_bytes=text_bytes,
            mcp_result_utf8_bytes=result_bytes,
            max_limit=3,
            over_limit_status=422,
            image_ids_only=True,
        )


def main():
    with Live() as live:
        author = live.register("McpTimelineAuthor")
        viewer = live.register("McpTimelineViewer")
        private = live.register("McpTimelinePrivate")
        live.login(private, owner="C" * 43, session="private")
        live.call("create_draft", {"operation_id": "private", "text": "Private draft"})
        live.login(author)
        july, photo = publish(live, "2026-07-23", image=True)
        september, _ = publish(live, "2026-09-21")
        october, _ = publish(live, "2026-10-01")
        repost, _ = publish(live, "2026-10-18", reference=july)
        publish(live, "2026-11-04")
        live.login(viewer, owner="B" * 43, session="viewer")
        publish(live, "2026-08-27")
        asyncio.run(
            check(
                live, author, viewer, private, [repost, october, september, july], photo
            )
        )
        print(json.dumps({"finished_at_utc": datetime.now(UTC).isoformat()}))


if __name__ == "__main__":
    main()
