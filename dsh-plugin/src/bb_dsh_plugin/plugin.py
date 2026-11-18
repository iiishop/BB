import json
import math
from urllib.parse import urlsplit

import httpx
from bb_auth_contract import (
    AccountResponse,
    ContractError,
    ErrorResponse,
    LoginRequest,
    RegisterRequest,
    parse_request,
)
from mcp.server.lowlevel import Server
from mcp.types import CallToolResult, TextContent, Tool, ToolAnnotations
from pydantic import ValidationError

from .space_tools import SPACE_TOOLS, TOOL_SCHEMAS, description, invoke_space


class LocalClient:
    def __init__(self, base_url: str, timeout: float = 10, *, transport=None):
        url = urlsplit(base_url)
        if (
            url.scheme != "http"
            or url.hostname != "127.0.0.1"
            or url.username is not None
            or url.password is not None
            or url.path not in ("", "/")
            or url.query
            or url.fragment
        ):
            raise ValueError(
                "BB_CLIENT_BASE_URL must be an http://127.0.0.1[:port] origin"
            )
        if url.port is not None and not 1 <= url.port <= 65535:
            raise ValueError("Invalid local client port")
        if not math.isfinite(timeout) or timeout <= 0:
            raise ValueError("Timeout must be a positive finite number")
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.transport = transport

    async def call(self, operation: str, payload: dict):
        if operation not in {"register", "login"}:
            raise ContractError(404, "unknown_tool", "Authentication bootstrap only")
        # Each call owns a short-lived client: no cookies, token, session, or retry state.
        async with httpx.AsyncClient(
            timeout=self.timeout,
            transport=self.transport,
            follow_redirects=False,
            trust_env=False,
        ) as client:
            try:
                response = await client.post(
                    self.base_url + f"/auth/{operation}",
                    json=payload,
                )
            except httpx.TimeoutException:
                raise ContractError(504, "upstream_timeout", "客户端请求超时") from None
            except httpx.RequestError:
                raise ContractError(
                    502, "upstream_unavailable", "无法连接客户端"
                ) from None
        return decode_response(response, operation)


def decode_response(response: httpx.Response, operation: str) -> dict:
    try:
        body = response.json()
        if response.status_code == (201 if operation == "register" else 200):
            return AccountResponse.model_validate(body).model_dump()
        if response.status_code in (401, 404, 409, 413, 415, 422, 502, 503, 504):
            error = ErrorResponse.model_validate(body).error
            raise ContractError(
                response.status_code,
                error.code,
                error.message,
                [field.model_dump() for field in error.fields],
            )
    except (ValueError, ValidationError):
        pass
    raise ContractError(502, "upstream_unavailable", "客户端响应格式错误")


def result(body: dict, *, error: bool = False) -> CallToolResult:
    return CallToolResult(
        isError=error,
        structuredContent=body,
        content=[TextContent(type="text", text=json.dumps(body, ensure_ascii=False))],
    )


async def invoke(client: LocalClient, name: str, arguments: dict) -> CallToolResult:
    try:
        operation = {"register_account": "register", "login_account": "login"}.get(name)
        if operation is None:
            raise ContractError(404, "unknown_tool", "未知工具")
        payload = parse_request(operation, arguments)
        return result(await client.call(operation, payload.model_dump()))
    except ContractError as error:
        return result({"status": error.status, **error.body}, error=True)


def create_server(client: LocalClient, guarded=None) -> Server:
    from .guarded import AwaitingBinding

    guarded = guarded or AwaitingBinding()
    server = Server("bb-client-tools")

    @server.list_tools()
    async def list_tools():
        from .guarded import TOOL_MODELS

        return [
            Tool(
                name="register_account",
                description="通过本地客户端注册，返回分配的账号和展示名。密码至少 6 位，包含 ASCII 大写、小写和数字。",
                inputSchema=RegisterRequest.model_json_schema(),
            ),
            Tool(
                name="login_account",
                description="通过本地客户端使用八位账号及密码登录；会话由客户端管理。",
                inputSchema=LoginRequest.model_json_schema(),
            ),
        ] + [
            Tool(
                name=name,
                description={
                    "get_notifications": "Query this account’s persistent notification setting. Does not mark messages read.",
                    "set_notifications": "Enable/disable account notifications. Off leaves queries, waits and sends available. Manually enabling skips notifications from the disabled interval.",
                    "list_conversations": "List authorized chats; incoming_unread counts received unread messages. Use unread_only/order=recent with the returned snapshot cursor, or list all for proactive chat.",
                    "read_messages": "Read a history page (optional unread_only). Empty filtered pages may have more; follow has_more/next_position. Full successful model presentation is confirmed by the host, previews are not.",
                    "send_message": "Send one chat message. ONE call = ONE bubble: every content part is laid out inside that same bubble, and a newline inside a part is only a line break. To send consecutive short lines as separate bubbles the way a human does, call this tool once per line with a single text part.",
                }.get(name, "BB guarded client: only explicit send tools send. Full successful model presentation, not query invocation, permits read confirmation."),
                inputSchema=model.model_json_schema(),
            )
            for name, model in TOOL_MODELS.items()
        ] + [Tool(name=name, description=description(name),
                  inputSchema=TOOL_SCHEMAS[name],
                  annotations=ToolAnnotations(
                      readOnlyHint='operation_id' not in SPACE_TOOLS[name].model_fields and name != 'space_get_post',
                      destructiveHint='delete' in name,
                      idempotentHint=True,
                      openWorldHint=True,
                  )) for name in SPACE_TOOLS]

    # The shared parser emits the agreed structured 422 envelope, including missing/type.
    @server.call_tool(validate_input=False)
    async def call_tool(name: str, arguments: dict):
        from .guarded import TOOL_MODELS, invoke_guarded

        if name in SPACE_TOOLS:
            return await invoke_space(guarded, name, arguments)
        if name in TOOL_MODELS:
            return await invoke_guarded(guarded, name, arguments)
        return await invoke(client, name, arguments)

    return server
