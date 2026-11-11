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
from mcp.types import CallToolResult, TextContent, Tool
from pydantic import ValidationError


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
        # Each call owns a short-lived client: no cookies, token, session, or retry state.
        async with httpx.AsyncClient(
            timeout=self.timeout,
            transport=self.transport,
            follow_redirects=False,
            trust_env=False,
        ) as client:
            try:
                response = await client.post(
                    f"{self.base_url}/auth/{operation}", json=payload
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
            # Whitelist fields even if a misconfigured client returns a server token.
            return AccountResponse.model_validate(body).model_dump()
        if response.status_code in (401, 422, 502, 503, 504):
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


def create_server(client: LocalClient) -> Server:
    server = Server("bb-auth-client-tools")

    @server.list_tools()
    async def list_tools():
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
        ]

    # The shared parser emits the agreed structured 422 envelope, including missing/type.
    @server.call_tool(validate_input=False)
    async def call_tool(name: str, arguments: dict):
        return await invoke(client, name, arguments)

    return server
