import json
import socket
from uuid import uuid4

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from bb_server.public_challenge import (
    CHALLENGE_PATH,
    InstanceVerifier,
    install_challenge_route,
    public_addresses,
)
from bb_server.public_cloud import PublicFailure


def answer(ip):
    return [
        (
            socket.AF_INET6 if ":" in ip else socket.AF_INET,
            socket.SOCK_STREAM,
            6,
            "",
            (ip, 443),
        )
    ]


@pytest.mark.parametrize(
    "ip",
    [
        "127.0.0.1",
        "10.0.0.1",
        "169.254.169.254",
        "0.0.0.0",
        "192.168.1.2",
        "::1",
        "fc00::1",
        "fe80::1",
        "::ffff:127.0.0.1",
        "203.0.113.1",
    ],
)
def test_non_public_resolved_addresses_rejected(ip):
    with pytest.raises(PublicFailure) as error:
        public_addresses("bb.example.com", lambda *a, **kw: answer(ip))
    assert error.value.code == "public_address_rejected"


def test_mixed_public_private_dns_is_rejected():
    with pytest.raises(PublicFailure):
        public_addresses(
            "bb.example.com", lambda *a, **kw: answer("1.1.1.1") + answer("127.0.0.1")
        )


@pytest.mark.parametrize(
    "failure",
    [
        None,
        "wrong_instance",
        "ordinary_200",
        "redirect",
        "cache",
        "timeout",
        "oversized",
    ],
)
def test_local_and_public_challenge_must_match_and_no_redirects(tmp_path, failure):
    calls = []
    resolutions = []

    class Response:
        status = 302 if failure == "redirect" else 200

        def getheader(self, name, default=None):
            return (
                "public, max-age=3600" if failure == "cache" else "no-store, max-age=0"
            )

        def read(self, limit):
            value = json.loads(next(tmp_path.glob("*.json")).read_text())
            if failure == "wrong_instance":
                return b'{"proof":"other-instance"}'
            if failure == "ordinary_200":
                return b'{"status":"ok"}'
            if failure == "oversized":
                return b"x" * 1025
            return json.dumps({"proof": value["proof"]}).encode()

    class Connection:
        def request(self, method, path, headers):
            calls.append((method, path, headers))

        def getresponse(self):
            if failure == "timeout":
                raise TimeoutError()
            return Response()

        def close(self):
            pass

    def resolver(domain, port, **kwargs):
        resolutions.append(domain)
        return answer("1.1.1.1")

    def public(domain, address):
        assert address == "1.1.1.1" and domain == "bb.example.com"
        return Connection()

    verifier = InstanceVerifier(
        tmp_path,
        8000,
        resolver=resolver,
        public_connection=public,
        local_connection=lambda *a, **kw: Connection(),
    )
    if failure:
        with pytest.raises(PublicFailure):
            verifier.verify("bb.example.com")
    else:
        verifier.verify("bb.example.com")
        assert len(calls) == 2
    assert resolutions == ["bb.example.com"]
    assert not list(tmp_path.glob("*.json"))
    assert all(
        x[0] == "GET"
        and x[1].startswith(CHALLENGE_PATH)
        and "no-store" in x[2]["Cache-Control"]
        for x in calls
    )


def test_endpoint_is_short_lived_minimal_and_uncacheable(tmp_path):
    clock = [1000.0]
    app = FastAPI()
    install_challenge_route(app, tmp_path, lambda: clock[0])
    challenge = str(uuid4())
    (tmp_path / (challenge + ".json")).write_text(
        json.dumps({"proof": "a" * 64, "expires_at": 1060})
    )
    with TestClient(app) as client:
        result = client.get(CHALLENGE_PATH + challenge)
        assert result.json() == {"proof": "a" * 64}
        assert result.headers["cache-control"] == "no-store, max-age=0"
        assert client.get(CHALLENGE_PATH + str(uuid4())).status_code == 404
        assert client.get(CHALLENGE_PATH + "../../secret").status_code == 404
        clock[0] = 1060
        assert client.get(CHALLENGE_PATH + challenge).status_code == 404


def test_symlink_challenge_is_not_read(tmp_path):
    target = tmp_path / "outside.json"
    target.write_text(json.dumps({"proof": "a" * 64, "expires_at": 1060}))
    identifier = str(uuid4())
    (tmp_path / (identifier + ".json")).symlink_to(target)
    app = FastAPI()
    install_challenge_route(app, tmp_path, lambda: 1000)
    with TestClient(app) as client:
        assert client.get(CHALLENGE_PATH + identifier).status_code == 404


def test_tls_pinning_uses_numeric_address_and_original_hostname(monkeypatch):
    from bb_server import public_challenge

    events = []

    class Raw:
        def settimeout(self, value):
            events.append(("timeout", value))

        def connect(self, address):
            events.append(("connect", address))

        def close(self):
            pass

    class TLS:
        def wrap_socket(self, raw, *, server_hostname):
            events.append(("sni", server_hostname))
            return raw

    monkeypatch.setattr(public_challenge.socket, "socket", lambda *args: Raw())
    value = public_challenge.PinnedHTTPS("bb.example.com", "1.1.1.1")
    value._context = TLS()
    value.connect()
    assert ("connect", ("1.1.1.1", 443)) in events
    assert ("sni", "bb.example.com") in events
