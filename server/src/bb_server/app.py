import asyncio
import hashlib
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
from bb_auth_contract.cover import (
    DEFAULT_HEADER,
    MAX_COVER_BYTES,
    MIME_TYPES,
    READ_PATH,
    UPLOAD_PATH,
    CoverResponse,
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
from fastapi import Depends, FastAPI, File, Header, Request, Response, UploadFile
from fastapi import Path as ApiPath
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from starlette.concurrency import run_in_threadpool

from bb_server import space, space_media
from bb_server.avatars import (
    default_version,
    etag_matches,
    normalize_image,
    read_avatar,
    replace_avatar,
)
from bb_server.covers import read_cover, replace_cover
from bb_server.public_challenge import directory_for, install_challenge_route
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
from bb_server.storage_errors import storage_failure
from bb_server.upload_limit import UploadLimit


def create_app(
    database_path: str | Path,
    avatar_directory: str | Path | None = None,
    *,
    media_directory: str | Path | None = None,
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
    media_root = (
        Path(media_directory)
        if media_directory
        else path.parent / (path.name + ".media")
    )
    # Run the same expensive verification for a nonexistent account.
    dummy_hash = hasher.hash(secrets.token_hex(32))

    @asynccontextmanager
    async def lifespan(app):
        migrate(path)
        # Retry physical cleanup without undoing committed logical deletion.
        try:
            space_media.collect(path, media_root / "space", scan=True)
        except (sqlite3.Error, OSError) as error:
            storage_failure(error)
        cleanup_sessions(path, clock())
        stop = asyncio.Event()

        async def maintain():
            while not stop.is_set():
                try:
                    await asyncio.wait_for(stop.wait(), timeout=maintenance_interval)
                except TimeoutError:
                    try:
                        await run_in_threadpool(cleanup_sessions, path, clock())
                        await run_in_threadpool(
                            space_media.collect, path, media_root / "space"
                        )
                    except (sqlite3.Error, OSError) as error:
                        storage_failure(error)

        worker = asyncio.create_task(maintain())
        try:
            yield
        finally:
            stop.set()
            await worker

    app = FastAPI(title="BB Auth, Profile & Chat", version="3.0.0", lifespan=lifespan)
    install_challenge_route(app, directory_for(path), clock)
    app.add_middleware(UploadLimit)

    @app.exception_handler(ContractError)
    async def contract_error(request: Request, error: ContractError):
        return JSONResponse(status_code=error.status, content=error.body)

    @app.exception_handler(RequestValidationError)
    async def validation_error(request: Request, error: RequestValidationError):
        safe = structural_error(error.errors())
        return JSONResponse(status_code=safe.status, content=safe.body)

    @app.exception_handler(sqlite3.Error)
    @app.exception_handler(OSError)
    async def storage_error(request: Request, error: Exception):
        code = storage_failure(
            error,
            method=request.method,
            route=getattr(request.scope.get("route"), "path", "unmatched"),
        )
        safe = ContractError(503, code, "存储暂不可用，请稍后再试")
        return JSONResponse(
            status_code=safe.status,
            content=safe.body,
            headers={"Retry-After": "1"} if code == "storage_busy" else None,
        )

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
    def avatar(
        account: str,
        request: Request,
        identity: Identity,
        variant: str = "original",
    ):
        # `variant=thumb` serves the derivative lists and bubbles use; anything
        # else keeps the original so the profile detail stays full resolution.
        data, version, media_type = read_avatar(
            path, avatars, account, "thumb" if variant == "thumb" else "original"
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
        return Response(data, media_type=media_type, headers=headers)

    @app.post(
        UPLOAD_PATH,
        response_model=CoverResponse,
        responses={
            **protected_errors,
            413: {"model": ErrorResponse},
            415: {"model": ErrorResponse},
        },
        dependencies=mutations,
    )
    async def upload_cover(
        request: Request, identity: Identity, file: Annotated[UploadFile, File()]
    ):
        form = await request.form()
        if len(form.multi_items()) != 1 or list(form) != ["file"]:
            invalid("body", "extra", "只允许一个 file 字段")
        raw = await file.read(MAX_COVER_BYTES + 1)
        return await run_in_threadpool(replace_cover, path, identity["digest"], raw, clock)

    cover_headers = {
        "ETag": {"schema": {"type": "string"}},
        DEFAULT_HEADER: {"schema": {"type": "string", "enum": ["true", "false"]}},
    }

    @app.get(
        READ_PATH,
        response_class=Response,
        responses={
            **protected_errors,
            200: {
                "headers": cover_headers,
                "content": {
                    mime: {"schema": {"type": "string", "format": "binary"}}
                    for mime in MIME_TYPES
                },
            },
            304: {"description": "ETag matched", "headers": cover_headers},
        },
    )
    def cover(
        account: Annotated[str, ApiPath(pattern=r"^[1-9][0-9]{7}$")],
        identity: Identity,
        if_none_match: Annotated[str | None, Header()] = None,
    ):
        display = read_cover(path, account)
        etag = '"' + display.version + '"'
        headers = {
            "ETag": etag,
            DEFAULT_HEADER: "true" if display.is_default else "false",
            "Cache-Control": "private, no-cache",
            "Vary": "Authorization",
            "X-Content-Type-Options": "nosniff",
        }
        if etag_matches(if_none_match, etag):
            return Response(status_code=304, headers=headers)
        return Response(display.data, media_type=display.mime_type, headers=headers)

    from .chat import install

    install(
        app,
        path,
        Path(media_directory)
        if media_directory
        else path.parent / (path.name + ".media"),
        current_session,
        clock,
    )
    space.install(app, path, media_root / "space", current_session, clock)
    return app
