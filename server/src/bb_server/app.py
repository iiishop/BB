import asyncio
import hashlib
import logging
import math
import secrets
import sqlite3
import time
from contextlib import asynccontextmanager
from datetime import UTC, datetime
from pathlib import Path
from typing import Annotated

from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError
from bb_auth_contract import (
    AccountResponse,
    ContractError,
    ErrorResponse,
    LoginRequest,
    LoginResponse,
    RegisterRequest,
    structural_error,
    validate_rules,
)
from bb_auth_contract.profile import (
    MAX_AVATAR_BYTES,
    AvatarResponse,
    HeartbeatResponse,
    ProfilePatch,
    ProfileResponse,
    invalid,
    profile_changes,
)
from fastapi import Depends, FastAPI, File, Request, Response, UploadFile
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from starlette.concurrency import run_in_threadpool

from bb_server.avatars import (
    default_version,
    etag_matches,
    normalize_image,
    read_avatar,
    replace_avatar,
)
from bb_server.storage import (
    cleanup_sessions,
    delete_session,
    find_session,
    find_user,
    get_profile,
    heartbeat,
    insert_session,
    insert_user,
    migrate,
    update_profile,
)
from bb_server.upload_limit import UploadLimit


def create_app(
    database_path: str | Path,
    avatar_directory: str | Path | None = None,
    *,
    clock=time.time,
    maintenance_interval: float = 5.0,
) -> FastAPI:
    path = Path(database_path)
    avatars = (
        Path(avatar_directory)
        if avatar_directory is not None
        else path.parent / (path.name + ".avatars")
    )
    if not math.isfinite(maintenance_interval) or maintenance_interval <= 0:
        raise ValueError("Maintenance interval must be positive and finite")
    hasher = PasswordHasher()
    # Run the same expensive verification for a nonexistent account.
    dummy_hash = hasher.hash(secrets.token_hex(32))

    @asynccontextmanager
    async def lifespan(app):
        migrate(path)
        cleanup_sessions(path, clock())
        stop = asyncio.Event()

        async def maintain():
            while not stop.is_set():
                try:
                    await asyncio.wait_for(stop.wait(), timeout=maintenance_interval)
                except TimeoutError:
                    try:
                        await run_in_threadpool(cleanup_sessions, path, clock())
                    except sqlite3.Error:
                        logging.getLogger(__name__).warning(
                            "session_maintenance_storage_unavailable"
                        )

        worker = asyncio.create_task(maintain())
        try:
            yield
        finally:
            stop.set()
            await worker

    app = FastAPI(title="BB Auth & Profile", version="2.0.0", lifespan=lifespan)
    app.add_middleware(UploadLimit)

    @app.exception_handler(ContractError)
    async def contract_error(request: Request, error: ContractError):
        return JSONResponse(status_code=error.status, content=error.body)

    @app.exception_handler(RequestValidationError)
    async def validation_error(request: Request, error: RequestValidationError):
        safe = structural_error(error.errors())
        return JSONResponse(status_code=safe.status, content=safe.body)

    @app.exception_handler(sqlite3.Error)
    async def storage_error(request: Request, error: sqlite3.Error):
        safe = ContractError(503, "storage_unavailable", "存储暂不可用，请稍后再试")
        return JSONResponse(status_code=safe.status, content=safe.body)

    @app.exception_handler(OSError)
    async def media_storage_error(request: Request, error: OSError):
        safe = ContractError(503, "storage_unavailable", "存储暂不可用，请稍后再试")
        return JSONResponse(status_code=safe.status, content=safe.body)

    responses = {422: {"model": ErrorResponse}, 503: {"model": ErrorResponse}}

    @app.post(
        "/auth/register",
        status_code=201,
        response_model=AccountResponse,
        responses=responses,
    )
    def register(payload: RegisterRequest):
        validate_rules(payload)
        account = insert_user(path, payload.username, hasher.hash(payload.password))
        return AccountResponse(account=account, username=payload.username)

    @app.post(
        "/auth/login",
        response_model=LoginResponse,
        responses={**responses, 401: {"model": ErrorResponse}},
    )
    def login(payload: LoginRequest):
        validate_rules(payload)
        user = find_user(path, payload.account)
        try:
            hasher.verify(user["password"] if user else dummy_hash, payload.password)
        except VerifyMismatchError:
            raise ContractError(401, "invalid_credentials", "账号或密码错误") from None
        if user is None:
            raise ContractError(401, "invalid_credentials", "账号或密码错误")
        token = secrets.token_hex(32)
        insert_session(
            path,
            payload.account,
            hashlib.sha256(token.encode("ascii")).hexdigest(),
            clock(),
        )
        return LoginResponse(
            account=user["account"], username=user["username"], token=token
        )

    def current_session(
        credentials: Annotated[
            HTTPAuthorizationCredentials | None, Depends(HTTPBearer(auto_error=False))
        ],
    ):
        if credentials is not None:
            digest = hashlib.sha256(credentials.credentials.encode("utf-8")).hexdigest()
            user = find_session(path, digest, clock())
            if user is not None:
                return {
                    "account": user["account"],
                    "username": user["username"],
                    "digest": digest,
                }
        raise ContractError(401, "unauthenticated", "请重新登录")

    Identity = Annotated[dict, Depends(current_session)]
    protected_errors = {code: {"model": ErrorResponse} for code in (401, 404, 422, 503)}

    def no_query(request: Request):
        if request.query_params:
            invalid("body", "extra", "不允许的字段")

    mutations = [Depends(no_query)]

    @app.get(
        "/auth/session", response_model=AccountResponse, responses=protected_errors
    )
    def session(identity: Identity):
        return {"account": identity["account"], "username": identity["username"]}

    @app.post(
        "/auth/logout",
        status_code=204,
        responses=protected_errors,
        dependencies=mutations,
    )
    def logout(identity: Identity):
        delete_session(path, identity["digest"])
        return Response(status_code=204)

    @app.post(
        "/auth/heartbeat",
        response_model=HeartbeatResponse,
        responses=protected_errors,
        dependencies=mutations,
    )
    def beat(identity: Identity):
        now = clock()
        if not heartbeat(path, identity["digest"], now):
            raise ContractError(401, "unauthenticated", "请重新登录")
        return HeartbeatResponse(
            last_seen_at=datetime.fromtimestamp(now, UTC)
            .isoformat(timespec="milliseconds")
            .replace("+00:00", "Z")
        )

    def profile_body(account: str):
        row = get_profile(path, account)
        if row is None:
            raise ContractError(404, "not_found", "用户不存在")
        return ProfileResponse(
            account=row["account"],
            username=row["username"],
            signature=row["signature"],
            avatar_url=f"/avatars/{account}.png",
            avatar_version=row["avatar_version"] or default_version(account),
        )

    @app.get(
        "/users/{account}/profile",
        response_model=ProfileResponse,
        responses=protected_errors,
    )
    def profile(account: str, identity: Identity):
        return profile_body(account)

    @app.patch(
        "/me/profile",
        response_model=ProfileResponse,
        responses=protected_errors,
        dependencies=mutations,
    )
    def patch_profile(payload: ProfilePatch, identity: Identity):
        update_profile(path, identity["account"], profile_changes(payload))
        return profile_body(identity["account"])

    @app.post(
        "/me/avatar",
        response_model=AvatarResponse,
        responses={
            **protected_errors,
            413: {"model": ErrorResponse},
            415: {"model": ErrorResponse},
        },
        dependencies=mutations,
    )
    async def upload_avatar(
        request: Request, identity: Identity, file: Annotated[UploadFile, File()]
    ):
        form = await request.form()
        if len(form.multi_items()) != 1 or list(form) != ["file"]:
            invalid("body", "extra", "只允许一个 file 字段")
        data = await file.read(MAX_AVATAR_BYTES + 1)
        png = await run_in_threadpool(normalize_image, data)
        return await run_in_threadpool(
            replace_avatar, path, avatars, identity["account"], png
        )

    @app.delete(
        "/me/avatar",
        response_model=AvatarResponse,
        responses=protected_errors,
        dependencies=mutations,
    )
    def delete_avatar(identity: Identity):
        return replace_avatar(path, avatars, identity["account"], None)

    @app.get(
        "/avatars/{account}.png",
        response_class=Response,
        responses={
            **protected_errors,
            200: {
                "content": {
                    "image/png": {"schema": {"type": "string", "format": "binary"}}
                }
            },
            304: {"description": "ETag matched"},
        },
    )
    def avatar(account: str, request: Request, identity: Identity):
        png, version = read_avatar(path, avatars, account)
        etag = '"' + version + '"'
        headers = {
            "ETag": etag,
            "Cache-Control": "private, no-cache",
            "Vary": "Authorization",
            "X-Content-Type-Options": "nosniff",
        }
        if etag_matches(request.headers.get("if-none-match"), etag):
            return Response(status_code=304, headers=headers)
        return Response(png, media_type="image/png", headers=headers)

    return app
