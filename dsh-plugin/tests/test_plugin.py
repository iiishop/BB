import httpx
import pytest
from bb_dsh_plugin.plugin import LocalClient, invoke


async def test_success_calls_local_route_and_strips_token():
    calls = []

    def handler(request):
        calls.append(request)
        return httpx.Response(
            200,
            json={"account": "12345678", "username": "Alice", "token": "never-forward"},
        )

    local = LocalClient("http://127.0.0.1:9187", transport=httpx.MockTransport(handler))
    result = await invoke(
        local, "login_account", {"account": "12345678", "password": "x"}
    )
    assert not result.isError
    assert result.structuredContent == {"account": "12345678", "username": "Alice"}
    assert "never-forward" not in result.model_dump_json()
    assert len(calls) == 1
    assert str(calls[0].url) == "http://127.0.0.1:9187/auth/login"


async def test_validation_before_network():
    def handler(_):
        pytest.fail("invalid parameters must not make a request")

    local = LocalClient("http://127.0.0.1:9187", transport=httpx.MockTransport(handler))
    result = await invoke(
        local, "register_account", {"username": "Alice", "password": "abc"}
    )
    assert result.isError
    assert result.structuredContent["status"] == 422
    assert [f["code"] for f in result.structuredContent["error"]["fields"]] == [
        "min_length",
        "missing_uppercase",
        "missing_digit",
    ]


@pytest.mark.parametrize(
    "url",
    [
        "http://example.com",
        "http://localhost:9000",
        "http://0.0.0.0:9000",
        "http://127.0.0.1.evil.test",
        "http://u:p@127.0.0.1",
        "http://127.0.0.1/path",
        "http://127.0.0.1?token=secret",
    ],
)
def test_reject_non_loopback_or_ambiguous_configuration(url):
    with pytest.raises(ValueError):
        LocalClient(url)


@pytest.mark.parametrize(
    ("exception", "status", "code"),
    [
        (httpx.ConnectError, 502, "upstream_unavailable"),
        (httpx.ReadTimeout, 504, "upstream_timeout"),
    ],
)
async def test_transport_failure_no_retry_or_exception_echo(exception, status, code):
    calls = []

    def handler(request):
        calls.append(request)
        raise exception("sensitive transport details")

    local = LocalClient("http://127.0.0.1:9187", transport=httpx.MockTransport(handler))
    result = await invoke(
        local, "login_account", {"account": "12345678", "password": "x"}
    )
    assert result.structuredContent["status"] == status
    assert result.structuredContent["error"]["code"] == code
    assert len(calls) == 1
    assert "sensitive" not in result.model_dump_json()


async def test_preserves_business_error():
    error = {"code": "invalid_credentials", "message": "账号或密码错误", "fields": []}
    local = LocalClient(
        "http://127.0.0.1:9187",
        transport=httpx.MockTransport(
            lambda _: httpx.Response(401, json={"error": error})
        ),
    )
    result = await invoke(
        local, "login_account", {"account": "12345678", "password": "x"}
    )
    assert result.isError
    assert result.structuredContent == {"status": 401, "error": error}


async def test_redirect_is_not_followed():
    calls = []

    def handler(request):
        calls.append(request)
        return httpx.Response(307, headers={"location": "https://example.com"})

    local = LocalClient("http://127.0.0.1:9187", transport=httpx.MockTransport(handler))
    result = await invoke(
        local, "login_account", {"account": "12345678", "password": "x"}
    )
    assert result.isError
    assert result.structuredContent["status"] == 502
    assert len(calls) == 1


@pytest.mark.parametrize(
    "body",
    [
        {"token": "secret"},
        {"account": 12345678, "username": "Alice"},
        {"error": {"message": "invalid"}},
    ],
)
async def test_malformed_client_response_is_safe(body):
    local = LocalClient(
        "http://127.0.0.1:9187",
        transport=httpx.MockTransport(lambda _: httpx.Response(200, json=body)),
    )
    response = await invoke(
        local, "login_account", {"account": "12345678", "password": "x"}
    )
    assert response.isError
    assert response.structuredContent["status"] == 502
    assert "secret" not in response.model_dump_json()


async def test_group_tools_use_protected_contract_and_omit_internal_tools():
    import json
    from pathlib import Path

    from bb_auth_contract import chat_v2
    from bb_dsh_plugin.guarded import INTERNAL, GuardedTransport, invoke_guarded
    from bb_dsh_plugin.plugin import create_server
    from mcp.types import ListToolsRequest

    fixtures = json.loads(
        (Path(__file__).resolve().parents[2] / "server/contract/chat-v2-cases.json").read_text()
    )
    case = fixtures["inputs"]["list_notices"]
    identity = case["expected_identity"]
    owner = fixtures["owner_header"]["value"]
    paths = {operation[0]: name for name, operation in chat_v2.GROUP_BUSINESS.items()}
    seen = []

    def handler(request):
        name = paths[request.url.path]
        seen.append(name)
        assert request.headers["X-BB-Consumer-Key"] == owner
        request_model = chat_v2.GROUP_BUSINESS[name][1]
        assert request_model.model_validate_json(request.content) == request_model.model_validate(
            fixtures["inputs"][name]
        )
        return httpx.Response(200, json=fixtures["outputs"][name])

    transport = GuardedTransport(
        "http://127.0.0.1:9187", owner, identity, transport=httpx.MockTransport(handler)
    )
    server = create_server(transport.local, guarded=transport)
    result = await server.request_handlers[ListToolsRequest](ListToolsRequest())
    tools = {tool.name: tool.inputSchema for tool in result.root.tools}
    assert set(chat_v2.GROUP_BUSINESS) <= tools.keys()
    assert not INTERNAL & tools.keys()
    for name in chat_v2.GROUP_BUSINESS:
        body = dict(fixtures["inputs"][name])
        body.pop("expected_identity")
        assert "expected_identity" not in tools[name]["properties"]
        response = await invoke_guarded(transport, name, body)
        assert not response.isError, (name, response.structuredContent)
        assert response.structuredContent == fixtures["outputs"][name]["result"]
    assert seen == list(chat_v2.GROUP_BUSINESS)


@pytest.mark.parametrize(("code", "status"), [
    ("forbidden", 403), ("action_unavailable", 409), ("group_unavailable", 409),
])
async def test_group_business_errors_are_forwarded_safely(code, status):
    from bb_dsh_plugin.guarded import GuardedTransport, invoke_guarded

    transport = GuardedTransport(
        "http://127.0.0.1:9187",
        "A" * 43,
        {"account": "10000001", "auth_generation": "g", "consumer_id": "c", "binding_revision": 1},
        transport=httpx.MockTransport(lambda _: httpx.Response(
            status, json={"error": {"code": code, "message": "private details", "fields": []}}
        )),
    )
    result = await invoke_guarded(transport, "execute_notice_action", {
        "notification_id": "notice-1", "action_id": "accept",
    })
    assert result.isError
    assert result.structuredContent == {"status": status, "error": {
        "code": code, "message": code, "fields": [],
    }}
