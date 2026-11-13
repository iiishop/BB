"""Management-only routes, durable SSE and production UI files on the same origin."""

import asyncio
import re
import sqlite3
from pathlib import Path
from uuid import UUID

from bb_auth_contract import ContractError
from bb_auth_contract.admin import (
    PREFIX,
    ActionPlan,
    AdminTask,
    CurrentTask,
    DraftSave,
    PlanCreate,
    PlanExecute,
    ProbeStart,
    PublicConfig,
    TaskAuthorization,
)
from fastapi import Header, HTTPException, Query, Request, Response
from fastapi.responses import FileResponse, StreamingResponse
from starlette.concurrency import run_in_threadpool


def register_public_routes(app, identity, store, runtime, ui_directory):
    implemented = {"x-implementation-stage": "B", "security": [{"AdminCookie": []}]}

    def worker():
        if runtime is None:
            raise ContractError(
                503,
                "public_runtime_unconfigured",
                "请用 bb-admin 入口设置独立业务监听目标",
            )
        return runtime

    def guard(request):
        # Recheck revocation in the SAME write transaction as all HTTP mutations.
        def check(db):
            session = identity._session(db, request.state.admin_token, identity.clock())
            identity._csrf(session, request.headers.get("x-csrf-token", ""))
            if session["must_change_password"]:
                raise ContractError(
                    403, "password_change_required", "请先修改管理员初始密码"
                )

        return check

    @app.get(
        PREFIX + "/public-config",
        response_model=PublicConfig,
        openapi_extra=implemented,
    )
    def config_get():
        return store.config()

    @app.put(
        PREFIX + "/public-config",
        response_model=PublicConfig,
        openapi_extra=implemented,
    )
    def config_save(body: DraftSave, request: Request):
        return store.save(body, auth=guard(request))

    @app.post(
        PREFIX + "/probes",
        status_code=202,
        response_model=AdminTask,
        openapi_extra=implemented,
    )
    def probe_start(body: ProbeStart, request: Request):
        return worker().admit(body, "probe", auth=guard(request))

    @app.post(
        PREFIX + "/plans",
        status_code=201,
        response_model=ActionPlan,
        openapi_extra=implemented,
    )
    def plan_create(body: PlanCreate, request: Request):
        return store.plan(body, target=worker().target, auth=guard(request))

    @app.post(
        PREFIX + "/executions",
        status_code=202,
        response_model=AdminTask,
        openapi_extra=implemented,
    )
    def execute(body: PlanExecute, request: Request):
        return worker().admit(body, "execute", auth=guard(request))

    @app.get(
        PREFIX + "/tasks/current", response_model=CurrentTask, openapi_extra=implemented
    )
    def task_current():
        return CurrentTask(task=store.current())

    @app.get(
        PREFIX + "/tasks/{task_id}", response_model=AdminTask, openapi_extra=implemented
    )
    def task_get(task_id: UUID):
        return store.get(task_id)

    @app.post(
        PREFIX + "/tasks/{task_id}/authorization",
        status_code=202,
        response_model=AdminTask,
        openapi_extra=implemented,
    )
    def task_authorization(task_id: UUID, body: TaskAuthorization, request: Request):
        return worker().authorize(task_id, body, auth=guard(request))

    @app.get(
        PREFIX + "/tasks/{task_id}/events",
        response_class=Response,
        responses={
            200: {"content": {"text/event-stream": {"schema": {"type": "string"}}}}
        },
        openapi_extra=implemented,
    )
    async def task_events(
        task_id: UUID,
        request: Request,
        after_seq: int = Query(default=0, ge=0),
        last_event_id: str | None = Header(default=None, alias="Last-Event-ID"),
    ):
        if last_event_id is not None:
            value = last_event_id
            if not re.fullmatch(r"[0-9]{1,18}", value):
                raise ContractError(422, "event_cursor_invalid", "事件序号无效")
            after_seq = int(value)
        await run_in_threadpool(store.events, task_id, after_seq)

        async def events():
            cursor = after_seq
            ticks = 0
            while not await request.is_disconnected():
                try:
                    await run_in_threadpool(identity.session, request.state.admin_token)
                    batch = await run_in_threadpool(store.events, task_id, cursor)
                    for seq, data in batch:
                        await run_in_threadpool(
                            identity.session, request.state.admin_token
                        )
                        yield f"id: {seq}\nevent: task\ndata: {data}\n\n"
                        cursor = seq
                    current = await run_in_threadpool(store.get, task_id)
                    if current.stage == "finished" and cursor >= current.seq:
                        return
                except (ContractError, sqlite3.Error, OSError):
                    return
                ticks += 1
                if ticks % 30 == 0:
                    yield ": heartbeat\n\n"
                await asyncio.sleep(0.5)

        return StreamingResponse(
            events(),
            media_type="text/event-stream",
            headers={"X-Accel-Buffering": "no"},
        )

    @app.get("/admin", include_in_schema=False)
    @app.get("/admin/{path:path}", include_in_schema=False)
    def ui(path: str = ""):
        if path == "api" or path.startswith("api/"):
            raise HTTPException(404)
        root = Path(ui_directory).resolve()
        relative = path if path.startswith("assets/") else "index.html"
        candidate = (root / relative).resolve()
        if not candidate.is_relative_to(root) or not candidate.is_file():
            raise HTTPException(404)
        return FileResponse(candidate)
