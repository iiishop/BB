"""Guarded MCP transport. Host owns the persisted local capability and binding.

No account credential, retry, implicit enrollment, rebind or ACK in query calls.
"""

import base64
import hashlib
import json

import httpx
from bb_auth_contract import ContractError, space, structural_error
from bb_auth_contract import chat_v2 as v2
from bb_auth_contract.cover import MAX_DISPLAY_BYTES, READ_PATH
from bb_auth_contract.profile import PROFILE_TOOLS, parse_profile_tool
from mcp.types import CallToolResult, ImageContent, TextContent
from pydantic import TypeAdapter, ValidationError, create_model

from .space_tools import SPACE_ERRORS, SPACE_TOOLS

INTERNAL = {
    "notification_changes",
    "ack_messages",
    "confirm_presentation",
    "get_consumption",
    "events_subscribe",
    "events_read",
    "events_wait",
}
TOOL_MODELS = {
    name: create_model(
        "Tool_" + name,
        __base__=v2.v1.Wire,
        **{
            key: (field.annotation, field)
            for key, field in request.model_fields.items()
            if key != "expected_identity"
        },
    )
    for name, (_, request, _, _, _) in v2.BUSINESS.items()
    if name not in INTERNAL
}
TOOL_MODELS.update(PROFILE_TOOLS)


class AwaitingBinding:
    async def call(self, operation, payload):
        raise ContractError(409, "stale_binding", "Login and bind the BB bridge first")


class GuardedTransport:
    def __init__(self, base_url, owner_key, identity, *, timeout=10, transport=None):
        # Reuse the origin allowlist, not its legacy routing.
        from .plugin import LocalClient

        self.local = LocalClient(base_url, timeout, transport=transport)
        try:
            self.owner = TypeAdapter(v2.OwnerKey).validate_python(owner_key)
            self.identity = v2.ExpectedIdentity.model_validate(identity).model_dump()
        except ValidationError:
            raise ValueError("Invalid local consumer binding configuration") from None

    async def call(self, operation, payload):
        if operation in SPACE_TOOLS:
            action = operation.removeprefix('space_')
            path, request, response_model, status = ('/v2/space/' + action,
                space.LOCAL_REQUESTS[action], space.LOCAL_RESPONSES[action], 200)
        elif operation.startswith("space_"):
            raise ContractError(404, "unknown_tool", "Unknown Space tool")
        else:
            path, request, response_model, status, _ = v2.BUSINESS[operation]
        try:
            body = request.model_validate(
                {**payload, "expected_identity": self.identity}
            ).model_dump(
                exclude_none=operation not in PROFILE_TOOLS and operation not in SPACE_TOOLS,
                exclude_unset=operation in PROFILE_TOOLS,
            )
        except ValidationError as error:
            raise structural_error(error.errors(include_input=False)) from None
        if operation == "send_attachment":
            # Canonical nullable field: the local attachment parser requires an
            # explicit null when no cover was provided.
            body.setdefault("cover", None)
        try:
            async with httpx.AsyncClient(
                transport=self.local.transport,
                trust_env=False,
                follow_redirects=False,
                timeout=max(self.local.timeout, payload.get("timeout", 0) + 5),
            ) as client:
                response = await client.post(
                    self.local.base_url + path,
                    json=body,
                    headers={v2.OWNER_HEADER: self.owner},
                )
        except httpx.TimeoutException:
            raise ContractError(504, "upstream_timeout", "客户端请求超时") from None
        except httpx.RequestError:
            raise ContractError(502, "upstream_unavailable", "无法连接客户端") from None
        try:
            if response.status_code == status:
                parsed = response_model.model_validate(response.json()).model_dump()
                if parsed["identity"] != self.identity:
                    raise ContractError(409, "stale_identity", "响应身份已失效")
                result = parsed["result"]
                if operation in {"view_cover", "update_cover"}:
                    account = payload.get("account") or self.identity["account"]
                    if (
                        result["cover_url"] != READ_PATH.format(account=account)
                        or result.get("account", account) != account
                    ):
                        raise ValueError("Unexpected cover account")
                return result
            error = v2.ErrorEnvelope.model_validate(response.json()).error
            expected_status = (SPACE_ERRORS.get(error.code) if operation in SPACE_TOOLS
                               else v2.ERRORS.get(error.code, (None,))[0])
            if expected_status != response.status_code:
                raise ValueError("unexpected error status")
            # No upstream text/field echo: it may contain local capabilities or credentials.
            raise ContractError(response.status_code, error.code, error.code)
        except (ValueError, ValidationError):
            raise ContractError(
                502, "upstream_unavailable", "客户端响应格式错误"
            ) from None


async def invoke_guarded(client, name, arguments):
    from .plugin import result

    try:
        try:
            payload = (
                parse_profile_tool(name, arguments)
                if name in PROFILE_TOOLS
                else (
                    TOOL_MODELS[name]
                    .model_validate(arguments)
                    .model_dump(exclude_none=True)
                )
            )
        except ValidationError as error:
            raise structural_error(error.errors(include_input=False)) from None
        body = await client.call(name, payload)
        if name in {"view_avatar", "view_cover"}:
            try:
                data = base64.b64decode(body["data"], validate=True)
                mime = body["mime_type"]
                if not _image_matches_mime(data, mime):
                    raise ValueError("Image MIME mismatch")
                if name == "view_cover" and (
                    len(data) > MAX_DISPLAY_BYTES
                    or body["cover_version"] != "sha256-" + hashlib.sha256(data).hexdigest()
                ):
                    raise ValueError("Cover size or version mismatch")
            except ValueError:
                raise ContractError(
                    502, "upstream_unavailable", "Invalid image bytes"
                ) from None
            metadata = {key: value for key, value in body.items() if key != "data"}
            return CallToolResult(
                isError=False,
                structuredContent=metadata,
                content=[
                    ImageContent(type="image", data=body["data"], mimeType=mime),
                    TextContent(
                        type="text", text=json.dumps(metadata, ensure_ascii=False)
                    ),
                ],
            )
        items = [body["item"]] if name == "get_message" else body.get("items", [])
        if name not in {"get_message", "get_context", "read_messages", "wait_messages"}:
            return result(body)
        blocks = []
        for item in items:
            blocks.append(
                TextContent(
                    type="text", text=json.dumps(item["message"], ensure_ascii=False)
                )
            )
            for block in item["blocks"]:
                if block["type"] == "text":
                    blocks.append(TextContent(type="text", text=block["text"]))
                else:
                    try:
                        raw = base64.b64decode(block["data"], validate=True)
                        if not _image_matches_mime(raw, block["mime_type"]):
                            raise ValueError("invalid image")
                    except ValueError:
                        raise ContractError(
                            502, "upstream_unavailable", "Invalid image bytes"
                        ) from None
                    blocks.append(
                        ImageContent(
                            type="image",
                            data=block["data"],
                            mimeType=block["mime_type"],
                        )
                    )
        # Bridge can collect display receipts, but only its durable turn settlement
        # may confirm/consume them; querying itself must never ACK.
        return CallToolResult(
            isError=False,
            structuredContent=body,
            content=blocks or [TextContent(type="text", text=json.dumps(body))],
        )
    except ContractError as error:
        return result({"status": error.status, **error.body}, error=True)


def _image_matches_mime(data: bytes, mime: str) -> bool:
    if mime == "image/png":
        return data.startswith(b"\x89PNG\r\n\x1a\n")
    if mime == "image/jpeg":
        return data.startswith(b"\xff\xd8")
    return mime == "image/webp" and data.startswith(b"RIFF") and data[8:12] == b"WEBP"
