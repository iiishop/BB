"""One-use proof with address pinning: public responses must match this business process."""

import http.client
import ipaddress
import json
import os
import secrets
import socket
import ssl
import time
from pathlib import Path
from uuid import UUID, uuid4

from fastapi import HTTPException
from fastapi.responses import JSONResponse

from bb_server.public_cloud import PublicFailure

CHALLENGE_PATH = "/.well-known/bb-instance/"


def directory_for(database):
    path = Path(database)
    return path.parent / (path.name + ".public-challenges")


def install_challenge_route(app, directory, clock=time.time):
    @app.get(CHALLENGE_PATH + "{challenge_id}", include_in_schema=False)
    def challenge(challenge_id: UUID):
        try:
            path = Path(directory) / (str(challenge_id) + ".json")
            if path.is_symlink() or path.stat().st_size > 1024:
                raise ValueError()
            value = json.loads(path.read_text(encoding="utf-8"))
            if not clock() < value["expires_at"] <= clock() + 61:
                raise ValueError()
            proof = value["proof"]
            if not isinstance(proof, str) or len(proof) != 64:
                raise ValueError()
        except (OSError, ValueError, KeyError, TypeError):
            raise HTTPException(404) from None
        return JSONResponse(
            {"proof": proof},
            headers={"Cache-Control": "no-store, max-age=0", "Pragma": "no-cache"},
        )


def public_addresses(domain, resolver=socket.getaddrinfo):
    try:
        values = resolver(domain, 443, type=socket.SOCK_STREAM)
    except OSError:
        raise PublicFailure("public_dns_unavailable", "公网域名暂不能解析") from None
    addresses = list(dict.fromkeys(item[4][0] for item in values))
    if not addresses or any(not ipaddress.ip_address(ip).is_global for ip in addresses):
        raise PublicFailure("public_address_rejected", "域名包含非公网目标，拒绝连接")
    return addresses


class PinnedHTTPS(http.client.HTTPSConnection):
    def __init__(self, domain, address):
        super().__init__(domain, timeout=5, context=ssl.create_default_context())
        self.address = address

    def connect(self):
        # No second DNS lookup. SNI and certificate validation still use the domain.
        family = socket.AF_INET6 if ":" in self.address else socket.AF_INET
        raw = socket.socket(family, socket.SOCK_STREAM)
        raw.settimeout(self.timeout)
        try:
            raw.connect((self.address, 443))
            self.sock = self._context.wrap_socket(raw, server_hostname=self.host)
        except BaseException:
            raw.close()
            raise


def fetch(connection, path):
    try:
        connection.request(
            "GET",
            path,
            headers={
                "Cache-Control": "no-cache, no-store",
                "Accept": "application/json",
            },
        )
        response = connection.getresponse()
        if (
            response.status != 200
            or "no-store" not in response.getheader("Cache-Control", "").lower()
        ):
            raise ValueError()
        body = response.read(1025)
        if len(body) > 1024:
            raise ValueError()
        return json.loads(body)
    finally:
        connection.close()


class InstanceVerifier:
    def __init__(
        self,
        directory,
        business_port,
        *,
        resolver=socket.getaddrinfo,
        public_connection=PinnedHTTPS,
        local_connection=http.client.HTTPConnection,
    ):
        self.directory = Path(directory)
        self.port = business_port
        self.resolver, self.public_connection, self.local_connection = (
            resolver,
            public_connection,
            local_connection,
        )

    def verify(self, domain):
        addresses = public_addresses(domain, self.resolver)
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        challenge_id = str(uuid4())
        path = self.directory / (challenge_id + ".json")
        proof = secrets.token_hex(32)
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as file:
            json.dump({"proof": proof, "expires_at": time.time() + 60}, file)
        try:
            local = fetch(
                self.local_connection("127.0.0.1", self.port, timeout=5),
                CHALLENGE_PATH + challenge_id,
            )
            remote = fetch(
                self.public_connection(domain, addresses[0]),
                CHALLENGE_PATH + challenge_id,
            )
            if local != {"proof": proof} or remote != {"proof": proof}:
                raise ValueError()
        except (OSError, ValueError, http.client.HTTPException):
            raise PublicFailure(
                "instance_verification_failed",
                "公网挑战未匹配当前业务实例；普通 HTTP 200 不代表就绪",
            ) from None
        finally:
            path.unlink(missing_ok=True)
