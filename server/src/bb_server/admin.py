"""Local management ASGI app. Never mount this on the business app."""

import ipaddress
import secrets
import sqlite3
import time
from contextlib import asynccontextmanager
from pathlib import Path
from uuid import UUID

from bb_auth_contract import ContractError, ErrorResponse, structural_error
from bb_auth_contract.admin import (
    COOKIE,
    PREFIX,
    SESSION_SECONDS,
    ActionPlan,
    AdminLogin,
    AdminSession,
    AdminTask,
    CurrentTask,
    DraftSave,
    PasswordChange,
    PlanCreate,
    PlanExecute,
    ProbeStart,
    PublicConfig,
)
from fastapi import FastAPI, Query, Request, Response
from fastapi.exceptions import RequestValidationError
from starlette.concurrency import run_in_threadpool
from starlette.datastructures import Headers
from starlette.requests import Request as StarletteRequest
from starlette.responses import JSONResponse

from bb_server.admin_storage import AdminStore, unauthenticated
from bb_server.storage_errors import storage_failure


def error_response(error):
    headers = {"Retry-After": "60"} if error.status == 429 else {}
    if error.status == 503:
        headers["Retry-After"] = "1"
    return JSONResponse(error.body, status_code=error.status, headers=headers)


class LocalManagementBoundary:
    def __init__(self, app, store, port):
        self.app, self.store = app, store
        self.host = f"127.0.0.1:{port}"
        self.origin = f"http://{self.host}"

    async def __call__(self, scope, receive, send):
        if scope["type"] not in ("http", "websocket"):
            return await self.app(scope, receive, send)
        if scope["type"] == "websocket":
            return await send({"type": "websocket.close", "code": 1008})

        async def secure_send(message):
            if message["type"] == "http.response.start":
                message["headers"] = list(message.get("headers", [])) + [
                    (b"cache-control", b"no-store"),
                    (b"pragma", b"no-cache"),
                    (b"x-content-type-options", b"nosniff"),
                    (b"x-frame-options", b"DENY"),
                    (b"referrer-policy", b"no-referrer"),
                    (
                        b"content-security-policy",
                        b"default-src 'self'; frame-ancestors 'none'; base-uri 'none'",
                    ),
                ]
            await send(message)

        try:
            headers = Headers(scope=scope)
            peer = scope.get("client")
            try:
                local = peer and ipaddress.ip_address(peer[0]).is_loopback
            except ValueError:
                local = False
            forwarded = any(
                name.lower() == b"forwarded"
                or name.lower().startswith((b"x-forwarded-", b"cf-"))
                for name, _ in scope.get("headers", [])
            )
            if not local or forwarded or headers.getlist("host") != [self.host]:
                raise ContractError(
                    403, "local_management_only", "管理入口仅允许本机直连"
                )
            if headers.get("origin") not in (None, self.origin) or headers.get(
                "sec-fetch-site"
            ) not in (None, "same-origin", "none"):
                raise ContractError(403, "origin_rejected", "不允许跨源管理请求")
            unsafe = scope["method"] not in ("GET", "HEAD", "OPTIONS")
            is_api = scope["path"].startswith(PREFIX)
            is_login = scope["path"] == PREFIX + "/login"
            if is_api and not is_login:
                request = StarletteRequest(scope)
                token = request.cookies.get(COOKIE, "")
                if not token:
                    raise unauthenticated()
                session = await run_in_threadpool(self.store.session, token)
                scope.setdefault("state", {}).update(
                    admin_token=token, admin_session=session
                )
                if unsafe and not secrets.compare_digest(
                    session.csrf_token.encode(),
                    headers.get("x-csrf-token", "").encode(),
                ):
                    raise ContractError(403, "csrf_rejected", "管理请求校验失败")
                if session.must_change_password and scope["path"] not in (
                    PREFIX + "/session",
                    PREFIX + "/password",
                    PREFIX + "/logout",
                ):
                    raise ContractError(
                        403, "password_change_required", "请先修改管理员初始密码"
                    )
            if unsafe and (
                headers.get("origin") != self.origin or headers.get("x-bb-admin") != "1"
            ):
                raise ContractError(403, "csrf_rejected", "管理请求校验失败")
            if (
                unsafe
                and headers.get("content-type", "").split(";")[0] != "application/json"
            ):
                raise ContractError(415, "json_required", "管理请求必须为 JSON")
            # Bound actual streamed bytes as well as Content-Length, before JSON parsing.
            if unsafe:
                body = bytearray()
                while True:
                    message = await receive()
                    if message["type"] == "http.disconnect":
                        return
                    body.extend(message.get("body", b""))
                    if len(body) > 16 * 1024:
                        raise ContractError(413, "payload_too_large", "管理请求体过大")
                    if not message.get("more_body", False):
                        break
                original_receive = receive
                delivered = False

                async def bounded_receive():
                    nonlocal delivered
                    if not delivered:
                        delivered = True
                        return {
                            "type": "http.request",
                            "body": bytes(body),
                            "more_body": False,
                        }
                    return await original_receive()

                receive = bounded_receive
        except ContractError as error:
            return await error_response(error)(scope, receive, secure_send)
        except (sqlite3.Error, OSError) as error:
            code = storage_failure(
                error, method=scope["method"], route="admin_boundary"
            )
            return await error_response(ContractError(503, code, "管理存储暂不可用"))(
                scope, receive, secure_send
            )
        await self.app(scope, receive, secure_send)


def create_admin_app(database_path: str | Path, *, port: int, clock=time.time):
    if not 1 <= port <= 65535:
        raise ValueError("BB_ADMIN_PORT must be between 1 and 65535")
    store = AdminStore(Path(database_path), clock)

    @asynccontextmanager
    async def lifespan(app):
        await run_in_threadpool(store.migrate)
        yield

    app = FastAPI(
        title="BB Local Management",
        version="1.0.0",
        lifespan=lifespan,
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
        responses={
            code: {"model": ErrorResponse}
            for code in (401, 403, 409, 413, 415, 422, 429, 501, 503)
        },
    )
    app.add_middleware(LocalManagementBoundary, store=store, port=port)

    @app.exception_handler(ContractError)
    async def contract_error(request, error):
        return error_response(error)

    @app.exception_handler(RequestValidationError)
    async def validation_error(request, error):
        return error_response(structural_error(error.errors()))

    @app.exception_handler(sqlite3.Error)
    @app.exception_handler(OSError)
    async def storage_error(request, error):
        code = storage_failure(
            error,
            method=request.method,
            route=getattr(request.scope.get("route"), "path", "unmatched"),
        )
        return error_response(ContractError(503, code, "管理存储暂不可用"))

    @app.post(PREFIX + "/login", response_model=AdminSession)
    def login(body: AdminLogin, response: Response):
        token, session = store.login(body.username, body.password.get_secret_value())
        response.set_cookie(
            COOKIE,
            token,
            max_age=SESSION_SECONDS,
            httponly=True,
            samesite="strict",
            path="/admin",
        )
        return session

    @app.get(PREFIX + "/session", response_model=AdminSession)
    def session(request: Request):
        return request.state.admin_session

    @app.post(PREFIX + "/password", status_code=204)
    def password(body: PasswordChange, request: Request, response: Response):
        store.change_password(
            request.state.admin_token,
            request.headers.get("x-csrf-token", ""),
            body.old_password.get_secret_value(),
            body.new_password.get_secret_value(),
        )
        response.delete_cookie(COOKIE, path="/admin", httponly=True, samesite="strict")

    @app.post(PREFIX + "/logout", status_code=204)
    def logout(request: Request, response: Response):
        store.logout(request.state.admin_token, request.headers.get("x-csrf-token", ""))
        response.delete_cookie(COOKIE, path="/admin", httponly=True, samesite="strict")

    # Fixed wire contract for B/C. These handlers have NO configuration/cloud side effects.
    pending = {"x-implementation-stage": "B", "security": [{"AdminCookie": []}]}

    def not_implemented():
        raise ContractError(501, "stage_b_not_implemented", "公网编排将在阶段 B 实现")

    @app.get(
        PREFIX + "/public-config", response_model=PublicConfig, openapi_extra=pending
    )
    def config_get():
        not_implemented()

    @app.put(
        PREFIX + "/public-config", response_model=PublicConfig, openapi_extra=pending
    )
    def config_save(body: DraftSave):
        not_implemented()

    @app.post(
        PREFIX + "/probes",
        status_code=202,
        response_model=AdminTask,
        openapi_extra=pending,
    )
    def probe_start(body: ProbeStart):
        not_implemented()

    @app.post(
        PREFIX + "/plans",
        status_code=201,
        response_model=ActionPlan,
        openapi_extra=pending,
    )
    def plan_create(body: PlanCreate):
        not_implemented()

    @app.post(
        PREFIX + "/executions",
        status_code=202,
        response_model=AdminTask,
        openapi_extra=pending,
    )
    def execute(body: PlanExecute):
        not_implemented()

    @app.get(
        PREFIX + "/tasks/current", response_model=CurrentTask, openapi_extra=pending
    )
    def task_current():
        not_implemented()

    @app.get(
        PREFIX + "/tasks/{task_id}", response_model=AdminTask, openapi_extra=pending
    )
    def task_get(task_id: UUID):
        not_implemented()

    @app.get(
        PREFIX + "/tasks/{task_id}/events",
        response_class=Response,
        responses={
            200: {"content": {"text/event-stream": {"schema": {"type": "string"}}}}
        },
        openapi_extra=pending,
    )
    def task_events(task_id: UUID, after_seq: int = Query(default=0, ge=0)):
        not_implemented()

    original_openapi = app.openapi

    def management_schema():
        schema = original_openapi()
        if schema.get("x-bb-admin-contract"):
            return schema
        schema["x-bb-admin-contract"] = "1.0.0"
        schema["components"]["securitySchemes"] = {
            "AdminCookie": {"type": "apiKey", "in": "cookie", "name": COOKIE}
        }
        for path, methods in schema["paths"].items():
            for operation in methods.values():
                operation["security"] = (
                    [] if path == PREFIX + "/login" else [{"AdminCookie": []}]
                )
                operation.setdefault("x-implementation-stage", "A")
                if any(key in operation for key in ("requestBody",)) or path.endswith(
                    "/logout"
                ):
                    operation["parameters"] = operation.get("parameters", []) + [
                        {
                            "name": "Origin",
                            "in": "header",
                            "required": True,
                            "schema": {"type": "string"},
                        },
                        {
                            "name": "X-BB-Admin",
                            "in": "header",
                            "required": True,
                            "schema": {"type": "string", "const": "1"},
                        },
                    ]
                    if path != PREFIX + "/login":
                        operation["parameters"].append(
                            {
                                "name": "X-CSRF-Token",
                                "in": "header",
                                "required": True,
                                "schema": {"type": "string"},
                            }
                        )
        return schema

    app.openapi = management_schema
    return app
