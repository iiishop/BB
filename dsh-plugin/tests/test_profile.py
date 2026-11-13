import base64
import json

import httpx
import pytest
from guarded_fixture import IDENTITY, guarded_client

from bb_dsh_plugin.guarded import invoke_guarded as invoke

PNG = base64.b64encode(b"\x89PNG\r\n\x1a\nimage-test-double").decode()


async def test_view_avatar_returns_mcp_image_and_revalidates_each_time():
    calls = []

    def handler(request):
        calls.append(request)
        return httpx.Response(
            200,
            json={
                "account": "12345678",
                "mime_type": "image/png",
                "data": PNG,
                "avatar_version": f"version-{len(calls)}",
                "token": "never-forward",
            },
        )

    local = guarded_client(
        "http://127.0.0.1:9187", transport=httpx.MockTransport(handler)
    )
    for version in (1, 2):
        response = await invoke(local, "view_avatar", {"account": "12345678"})
        assert not response.isError
        assert response.content[0].type == "image"
        assert response.content[0].data == PNG
        assert response.structuredContent["avatar_version"] == f"version-{version}"
        assert "never-forward" not in response.model_dump_json()
    assert len(calls) == 2
    assert all(r.url.path == "/v2/profile/view_avatar" for r in calls)
    assert all(
        "authorization" not in r.headers and "cookie" not in r.headers for r in calls
    )


@pytest.mark.parametrize(
    "payload",
    [
        {"path": "/not-read/avatar.png"},
        {"url": "https://example.invalid/not-downloaded.png"},
        {"base64": "data:image/png;base64," + PNG},
        {"base64": PNG},
    ],
)
async def test_avatar_sources_are_forwarded_to_client_only(payload):
    calls = []

    def handler(request):
        calls.append(request)
        return httpx.Response(
            200, json={"avatar_url": "/avatars/12345678.png", "avatar_version": "new"}
        )

    local = guarded_client(
        "http://127.0.0.1:9187", transport=httpx.MockTransport(handler)
    )
    response = await invoke(local, "update_avatar", payload)
    assert not response.isError
    assert len(calls) == 1 and calls[0].url.path == "/v2/profile/update_avatar"
    assert json.loads(calls[0].content) == {**payload, "expected_identity": IDENTITY}


@pytest.mark.parametrize(
    "payload",
    [
        {},
        {"path": "/x", "url": "https://example.invalid/x"},
        {"base64": "abc", "account": "12345678"},
        {"path": "relative.png"},
        {"url": "file:///tmp/x"},
    ],
)
async def test_ambiguous_or_unsafe_avatar_arguments_never_call_client(payload):
    def handler(_):
        pytest.fail("invalid tool arguments reached HTTP")

    local = guarded_client(
        "http://127.0.0.1:9187", transport=httpx.MockTransport(handler)
    )
    response = await invoke(local, "update_avatar", payload)
    assert response.isError and response.structuredContent["status"] == 422


@pytest.mark.parametrize("data", ["invalid-base64!", "YWJj", ""])
async def test_malformed_avatar_response_does_not_emit_an_image(data):
    local = guarded_client(
        "http://127.0.0.1:9187",
        transport=httpx.MockTransport(
            lambda _: httpx.Response(
                200,
                json={
                    "account": "12345678",
                    "mime_type": "image/png",
                    "data": data,
                    "avatar_version": "v1",
                },
            )
        ),
    )
    response = await invoke(local, "view_avatar", {})
    assert response.isError and response.structuredContent["status"] == 502
    assert all(item.type != "image" for item in response.content)


@pytest.mark.parametrize(
    "status,code",
    [
        (401, "unauthenticated"),
        (404, "not_found"),
        (413, "payload_too_large"),
        (415, "unsupported_media_type"),
        (503, "storage_unavailable"),
    ],
)
async def test_profile_error_envelope_is_preserved_without_retry(status, code):
    calls = []
    error = {"code": code, "message": "客户端错误", "fields": []}

    def handler(request):
        calls.append(request)
        return httpx.Response(status, json={"error": error})

    local = guarded_client(
        "http://127.0.0.1:9187", transport=httpx.MockTransport(handler)
    )
    response = await invoke(local, "view_avatar", {})
    assert response.isError and response.structuredContent == {
        "status": status,
        "error": {**error, "message": code},
    }
    assert len(calls) == 1
