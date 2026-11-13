import json

import pytest

from bb_server.public_cloud import Cloudflare, PublicFailure


def test_all_inventory_pages_are_required_and_missing_auth_is_not_missing_zone():
    seen = []

    def transport(method, path, payload):
        seen.append((method, path, payload))
        return {
            "success": True,
            "result": [{"id": "x"}],
            "result_info": {"total_pages": 2},
        }

    assert (
        len(Cloudflare("synthetic", transport).listing("/zones", name="example.com"))
        == 2
    )
    assert all(x[0] == "GET" for x in seen)
    assert "page=1" in seen[0][1] and "page=2" in seen[1][1]
    missing = Cloudflare("synthetic", lambda *a: {"success": True, "result": []})
    with pytest.raises(PublicFailure) as error:
        missing.zone("bb.example.com")
    assert error.value.code == "zone_not_authorized"
    assert error.value.waiting == "authorization"


@pytest.mark.parametrize("status", [200, 302, 401, 403, 429, 503])
def test_api_uses_fixed_tls_origin_and_sanitizes_errors(monkeypatch, status):
    from bb_server import public_cloud

    secret = "synthetic-management-key"
    calls = []

    class Response:
        def __init__(self):
            self.status = status

        def read(self, size):
            return json.dumps({"success": True, "result": []}).encode()

    class Connection:
        def __init__(self, host, **kwargs):
            assert host == "api.cloudflare.com"
            assert kwargs["context"].check_hostname

        def request(self, *args, **kwargs):
            calls.append((args, kwargs))

        def getresponse(self):
            return Response()

        def close(self):
            pass

    monkeypatch.setattr(public_cloud.http.client, "HTTPSConnection", Connection)
    cloud = Cloudflare(secret)
    if status == 200:
        assert cloud.request("GET", "/zones")["result"] == []
    else:
        with pytest.raises(PublicFailure) as error:
            cloud.request("GET", "/zones")
        assert secret not in str(error.value)
        if status in (401, 403, 429, 503):
            assert error.value.waiting == "authorization"
    assert len(calls) == 1  # redirects are not followed
    assert calls[0][1]["headers"]["Authorization"] == "Bearer " + secret


def test_transport_failure_does_not_echo_token(monkeypatch):
    from bb_server import public_cloud

    class Broken:
        def __init__(self, *a, **kw):
            pass

        def request(self, *a, **kw):
            raise OSError("PRIVATE_TOKEN_VALUE")

        def close(self):
            pass

    monkeypatch.setattr(public_cloud.http.client, "HTTPSConnection", Broken)
    with pytest.raises(PublicFailure) as error:
        Cloudflare("PRIVATE_TOKEN_VALUE").request(
            "POST", "/zones", {"token": "PRIVATE_TOKEN_VALUE"}
        )
    assert "PRIVATE_TOKEN_VALUE" not in str(error.value)
    assert "PRIVATE_TOKEN_VALUE" not in error.value.message


@pytest.mark.parametrize(
    "body", [None, [], "PRIVATE_TOKEN_VALUE", {}, {"success": True}]
)
def test_real_http_malformed_envelope_is_unknown(monkeypatch, body):
    from bb_server import public_cloud

    class Connection:
        def __init__(self, *args, **kwargs):
            pass

        def request(self, *args, **kwargs):
            pass

        def getresponse(self):
            return self

        status = 200

        def read(self, size):
            return json.dumps(body).encode()

        def close(self):
            pass

    monkeypatch.setattr(public_cloud.http.client, "HTTPSConnection", Connection)
    with pytest.raises(PublicFailure) as error:
        Cloudflare("PRIVATE_TOKEN_VALUE").request("POST", "/fixed-path", {})
    assert error.value.waiting == "authorization"
    assert "PRIVATE_TOKEN_VALUE" not in str(error.value) + error.value.message


@pytest.mark.parametrize(
    "operation,result",
    [
        ("tunnel", {}),
        ("tunnel", {"id": None}),
        ("tunnel", {"id": []}),
        ("dns", {}),
        ("dns", {"id": 123}),
        ("config", None),
        ("config", {"config": []}),
        ("inventory", [None]),
        ("zone", [{"name": "bb.example.com", "id": "a" * 32, "account": None}]),
    ],
)
def test_nested_response_types_are_unknown_not_local_validation_errors(
    operation, result
):
    from uuid import uuid4

    cloud = Cloudflare("synthetic", lambda *args: {"success": True, "result": result})
    calls = {
        "tunnel": lambda: cloud.create_tunnel("b" * 32, "owned", "synthetic"),
        "dns": lambda: cloud.create_record(
            "a" * 32, "bb.example.com", uuid4(), "owned"
        ),
        "config": lambda: cloud.config("b" * 32, uuid4()),
        "inventory": lambda: cloud.listing("/zones"),
        "zone": lambda: cloud.zone("bb.example.com"),
    }
    with pytest.raises(PublicFailure) as error:
        calls[operation]()
    assert error.value.waiting == "authorization"
    assert error.value.code == "cloud_response_invalid"
