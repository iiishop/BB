"""STEP-2 wire models shared by the server and the stateless MCP adapter."""

import re
from pathlib import PurePosixPath, PureWindowsPath
from typing import Literal
from urllib.parse import urlsplit

from pydantic import BaseModel, ConfigDict, Field, ValidationError

from bb_auth_contract import (
    AccountResponse,
    ContractError,
    field_error,
    structural_error,
)

MAX_AVATAR_BYTES = 5 * 1024 * 1024


class StrictRequest(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", hide_input_in_errors=True)


class ProfilePatch(StrictRequest):
    username: str | None = Field(
        default=None,
        description="Omit to preserve; null rejected; trim to 3–24 code points",
    )
    signature: str | None = Field(
        default=None,
        description="Omit to preserve; null/trimmed empty clears; at most 49 code points",
    )


class AvatarResponse(BaseModel):
    model_config = ConfigDict(strict=True)
    avatar_url: str = Field(pattern=r"^/avatars/[1-9][0-9]{7}\.png$")
    avatar_version: str = Field(min_length=1)


class ProfileResponse(AccountResponse, AvatarResponse):
    signature: str | None


class HeartbeatResponse(BaseModel):
    status: Literal["online"] = "online"
    last_seen_at: str


class ViewRequest(StrictRequest):
    account: str | None = Field(
        default=None, description="Omitted or null means current client session"
    )


class NicknameUpdate(StrictRequest):
    value: str


class SignatureUpdate(StrictRequest):
    value: str | None = None


class AvatarUpdate(StrictRequest):
    model_config = ConfigDict(
        strict=True,
        extra="forbid",
        hide_input_in_errors=True,
        json_schema_extra={
            "minProperties": 1,
            "maxProperties": 1,
            "oneOf": [{"required": [name]} for name in ("path", "url", "base64")],
        },
    )
    path: str | None = Field(
        default=None, description="Absolute path read only by the client"
    )
    url: str | None = Field(
        default=None, description="http/https URL downloaded only by the client"
    )
    base64: str | None = Field(
        default=None,
        description="Raw base64 or data:image/...;base64,...; decoded by client",
        repr=False,
    )


class SignatureResponse(BaseModel):
    model_config = ConfigDict(strict=True)
    account: str = Field(pattern=r"^[1-9][0-9]{7}$")
    signature: str | None


class AvatarImageResponse(BaseModel):
    model_config = ConfigDict(strict=True)
    account: str = Field(pattern=r"^[1-9][0-9]{7}$")
    mime_type: Literal["image/png"]
    data: str = Field(min_length=1, repr=False)
    avatar_version: str = Field(min_length=1)


def invalid(field: str, code: str, message: str):
    raise ContractError(
        422, "validation_error", "输入有误", [field_error(field, code, message)]
    )


def nickname(value: str | None) -> str:
    if value is None:
        invalid("username", "type", "字段类型错误")
    value = value.strip()
    if not 3 <= len(value) <= 24:
        invalid("username", "length", "用户名去除首尾空白后须为 3–24 字符")
    return value


def signature(value: str | None) -> str | None:
    value = value.strip() if value is not None else None
    if value and len(value) > 49:
        invalid("signature", "length", "签名去除首尾空白后最多 49 字符")
    return value or None


def profile_changes(payload: ProfilePatch) -> dict:
    changes = {}
    if "username" in payload.model_fields_set:
        changes["username"] = nickname(payload.username)
    if "signature" in payload.model_fields_set:
        changes["signature"] = signature(payload.signature)
    return changes


PROFILE_TOOLS = {
    "view_avatar": ViewRequest,
    "update_avatar": AvatarUpdate,
    "view_nickname": ViewRequest,
    "update_nickname": NicknameUpdate,
    "view_signature": ViewRequest,
    "update_signature": SignatureUpdate,
}
PROFILE_RESPONSES = {
    "view_avatar": AvatarImageResponse,
    "update_avatar": AvatarResponse,
    "view_nickname": AccountResponse,
    "update_nickname": AccountResponse,
    "view_signature": SignatureResponse,
    "update_signature": SignatureResponse,
}


def parse_profile_tool(name: str, arguments: object) -> dict:
    try:
        model = PROFILE_TOOLS[name].model_validate(arguments)
    except ValidationError as error:
        raise structural_error(error.errors(include_input=False)) from None
    if isinstance(model, ViewRequest):
        if model.account is not None and not re.fullmatch(r"[0-9]{8}", model.account):
            invalid("account", "format", "账号必须为 8 位数字")
    elif isinstance(model, NicknameUpdate):
        model.value = nickname(model.value)
    elif isinstance(model, SignatureUpdate):
        model.value = signature(model.value)
        return {"value": model.value}
    elif isinstance(model, AvatarUpdate):
        # Count supplied keys, including null, so ambiguous requests never get guessed.
        if len(model.model_fields_set) != 1:
            invalid("body", "one_source", "path、url、base64 必须且只能提供一个")
        source = next(iter(model.model_fields_set))
        value = getattr(model, source)
        if not value:
            invalid(source, "required", "此字段必填")
        if source == "path" and not (
            PurePosixPath(value).is_absolute() or PureWindowsPath(value).is_absolute()
        ):
            invalid("path", "format", "必须为本机绝对路径")
        if source == "url":
            try:
                url = urlsplit(value)
                valid = (
                    url.scheme in ("http", "https")
                    and bool(url.hostname)
                    and not url.username
                    and not url.password
                )
                _ = url.port
            except ValueError:
                valid = False
            if not valid:
                invalid("url", "format", "必须为有效 http/https URL")
    return model.model_dump(exclude_unset=True)
