import hashlib
import secrets
import sqlite3
from contextlib import asynccontextmanager
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
from fastapi import Depends, FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from bb_server.storage import (
    find_session,
    find_user,
    insert_session,
    insert_user,
    migrate,
)


def create_app(database_path: str | Path) -> FastAPI:
    path = Path(database_path)
    hasher = PasswordHasher()
    # Run the same expensive verification for a nonexistent account.
    dummy_hash = hasher.hash(secrets.token_hex(32))

    @asynccontextmanager
    async def lifespan(app):
        migrate(path)
        yield

    app = FastAPI(title="BB STEP-1 Auth", version="1.0.0", lifespan=lifespan)

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
            path, payload.account, hashlib.sha256(token.encode("ascii")).hexdigest()
        )
        return LoginResponse(
            account=user["account"], username=user["username"], token=token
        )

    @app.get(
        "/auth/session",
        response_model=AccountResponse,
        responses={401: {"model": ErrorResponse}, 503: {"model": ErrorResponse}},
    )
    def session(
        credentials: Annotated[
            HTTPAuthorizationCredentials | None, Depends(HTTPBearer(auto_error=False))
        ],
    ):
        if credentials is not None:
            digest = hashlib.sha256(credentials.credentials.encode("utf-8")).hexdigest()
            user = find_session(path, digest)
            if user is not None:
                return AccountResponse(
                    account=user["account"], username=user["username"]
                )
        raise ContractError(401, "unauthenticated", "请重新登录")

    return app
