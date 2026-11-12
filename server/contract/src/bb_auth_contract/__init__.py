"""Shared wire contract; no storage or network access."""

import re
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, ValidationError


class FieldError(BaseModel):
    field: str
    code: str
    message: str


class ErrorDetail(BaseModel):
    code: str = Field(
        description="HTTP 503: storage_busy (bounded lock contention), storage_io_error (IO/read-only/full), or storage_unavailable (other storage failures). Unknown codes retain the same error envelope and HTTP status."
    )
    message: str
    fields: list[FieldError] = Field(default_factory=list)


class ErrorResponse(BaseModel):
    error: ErrorDetail


class ContractError(Exception):
    def __init__(
        self, status: int, code: str, message: str, fields: list[dict] | None = None
    ):
        super().__init__(code)  # Never retain input values in exceptions.
        self.status = status
        self.body = ErrorResponse(
            error=ErrorDetail(code=code, message=message, fields=fields or [])
        ).model_dump()


class RequestModel(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", hide_input_in_errors=True)
    password: str = Field(repr=False, json_schema_extra={"writeOnly": True})


class RegisterRequest(RequestModel):
    password: str = Field(
        repr=False,
        description="At least 6 characters, with ASCII A–Z, a–z and 0–9; never trimmed",
        json_schema_extra={"writeOnly": True},
    )
    username: str = Field(
        description="Trimmed display name, 3–24 characters; duplicates allowed"
    )


class LoginRequest(RequestModel):
    account: str = Field(
        description="Eight ASCII digits; server allocates 10000000–99999999"
    )


class AccountResponse(BaseModel):
    model_config = ConfigDict(strict=True)
    account: str = Field(pattern=r"^[1-9][0-9]{7}$")
    username: str


class LoginResponse(AccountResponse):
    token: str = Field(repr=False)


def field_error(field: str, code: str, message: str) -> dict:
    return {"field": field, "code": code, "message": message}


def structural_error(errors: list[dict]) -> ContractError:
    fields = []
    for error in errors:
        # Unknown keys can contain secrets: only echo known field names.
        field = next(
            (
                str(part)
                for part in error["loc"]
                if part
                in (
                    "username",
                    "password",
                    "account",
                    "signature",
                    "value",
                    "path",
                    "url",
                    "base64",
                    "file",
                )
            ),
            "body",
        )
        kind = error["type"]
        code, message = {
            "missing": ("required", "此字段必填"),
            "extra_forbidden": ("extra", "不允许的字段"),
            "json_invalid": ("type", "请求必须为有效 JSON 对象"),
        }.get(kind, ("type", "字段类型错误"))
        fields.append(field_error(field, code, message))
    return ContractError(422, "validation_error", "输入有误", fields)


def validate_rules(model: RegisterRequest | LoginRequest):
    fields = []
    if isinstance(model, RegisterRequest):
        model.username = model.username.strip()
        if not 3 <= len(model.username) <= 24:
            fields.append(
                field_error("username", "length", "用户名去除首尾空白后须为 3–24 字符")
            )
        checks = [
            (len(model.password) >= 6, "min_length", "密码至少 6 位"),
            (
                re.search("[A-Z]", model.password),
                "missing_uppercase",
                "密码必须包含大写字母",
            ),
            (
                re.search("[a-z]", model.password),
                "missing_lowercase",
                "密码必须包含小写字母",
            ),
            (re.search("[0-9]", model.password), "missing_digit", "密码必须包含数字"),
        ]
        fields.extend(
            field_error("password", code, message)
            for valid, code, message in checks
            if not valid
        )
    elif not re.fullmatch("[0-9]{8}", model.account):
        fields.append(field_error("account", "format", "账号必须为 8 位数字"))
    if fields:
        raise ContractError(422, "validation_error", "输入有误", fields)
    return model


def parse_request(operation: Literal["register", "login"], payload: object):
    model_type = RegisterRequest if operation == "register" else LoginRequest
    try:
        model = model_type.model_validate(payload)
    except ValidationError as error:
        raise structural_error(error.errors(include_input=False)) from None
    return validate_rules(model)
