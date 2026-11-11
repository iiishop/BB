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
