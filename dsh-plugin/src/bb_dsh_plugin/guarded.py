"""Guarded MCP transport. Host owns the persisted local capability and binding.

No account credential, retry, implicit enrollment, rebind or ACK in query calls.
"""

import base64
import json

import httpx
from bb_auth_contract import ContractError, structural_error
from bb_auth_contract import chat_v2 as v2
from bb_auth_contract.profile import PROFILE_TOOLS, parse_profile_tool
from mcp.types import CallToolResult, ImageContent, TextContent
from pydantic import TypeAdapter, ValidationError, create_model

INTERNAL = {
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
        path, request, response_model, status, _ = v2.BUSINESS[operation]
        try:
            body = request.model_validate(
                {**payload, "expected_identity": self.identity}
            ).model_dump(
                exclude_none=operation not in PROFILE_TOOLS,
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
                return parsed["result"]
            error = v2.ErrorEnvelope.model_validate(response.json()).error
            if (
                error.code not in v2.ERRORS
                or v2.ERRORS[error.code][0] != response.status_code
            ):
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
        if name == "view_avatar":
            try:
                data = base64.b64decode(body["data"], validate=True)
                if not data.startswith(b"\x89PNG\r\n\x1a\n"):
                    raise ValueError("Not PNG")
            except ValueError:
                raise ContractError(
                    502, "upstream_unavailable", "Invalid image bytes"
                ) from None
            metadata = {key: value for key, value in body.items() if key != "data"}
            return CallToolResult(
                isError=False,
                structuredContent=metadata,
                content=[
                    ImageContent(type="image", data=body["data"], mimeType="image/png"),
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
                        valid = {
                            "image/png": raw.startswith(b"\x89PNG\r\n\x1a\n"),
                            "image/jpeg": raw.startswith(b"\xff\xd8"),
                            "image/webp": raw.startswith(b"RIFF")
                            and raw[8:12] == b"WEBP",
                        }
                        if not valid[block["mime_type"]]:
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
