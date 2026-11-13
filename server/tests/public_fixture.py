"""External-system fakes only; actual store/executor/crypto/files are exercised."""

import base64
import json
from uuid import uuid4

from bb_server.public_cloud import Cloudflare, PublicFailure, unknown
from bb_server.public_platform import SecretFiles, check


class FakeCloud:
    ingress = staticmethod(Cloudflare.ingress)
    owns_token = staticmethod(Cloudflare.owns_token)

    def __init__(self):
        self.zone_id = "a" * 32
        self.account_id = "b" * 32
        self.items = []
        self.dns = []
        self.configs = {}
        self.tokens = {}
        self.calls = {"tunnel": 0, "ingress": 0, "dns": 0}
        self.lose = None

    def inspect(self, domain):
        return {
            "zone_id": self.zone_id,
            "account_id": self.account_id,
            "records": self.dns.copy(),
            "tunnels": self.items.copy(),
        }

    def tunnels(self, account, name=None):
        return [x for x in self.items if name is None or x["name"] == name]

    def records(self, zone, domain):
        return self.dns.copy()

    def token(self, account, tunnel):
        return self.tokens[tunnel]

    def lost(self, step):
        if self.lose == step:
            self.lose = None
            raise unknown(step + "_response_lost")

    def create_tunnel(self, account, name, secret):
        self.calls["tunnel"] += 1
        tunnel = str(uuid4())
        self.items.append(
            {
                "id": tunnel,
                "name": name,
                "remote_config": True,
                "status": "healthy",
                "connections": [{"id": "synthetic"}],
            }
        )
        self.tokens[tunnel] = base64.b64encode(
            json.dumps({"t": tunnel, "s": secret, "a": account}).encode()
        ).decode()
        self.configs[tunnel] = {}
        self.lost("tunnel")
        return tunnel

    def config(self, account, tunnel):
        return self.configs[tunnel]

    def configure(self, account, tunnel, domain, target):
        self.calls["ingress"] += 1
        self.configs[tunnel] = self.ingress(domain, target)
        self.lost("ingress")

    def create_record(self, zone, domain, tunnel, marker):
        self.calls["dns"] += 1
        self.dns.append(
            {
                "id": "c" * 32,
                "type": "CNAME",
                "content": tunnel + ".cfargotunnel.com",
                "name": domain,
                "proxied": True,
                "comment": marker,
            }
        )
        self.lost("dns")
        return "c" * 32


class FakePlatform:
    def __init__(self, directory):
        self.files = SecretFiles(directory)
        self.installed = True
        self.running = False
        self.calls = []
        self.lose = False
        self.denied = False

    def inspect(self, instance):
        return [
            check(
                "installation",
                "passed" if self.installed else "failed",
                None if self.installed else "cloudflared_missing",
                () if self.installed else ("install",),
            ),
            check(
                "service",
                "passed" if self.running else "failed",
                "service_stopped" if not self.running else None,
            ),
        ]

    def apply(self, action, task_id, instance, token=None):
        self.calls.append(action)
        if self.denied:
            raise PublicFailure(
                "local_desktop_required",
                "Synthetic headless fixture",
                waiting="local_admin",
            )
        if action == "install":
            self.installed = True
        else:
            assert token and token not in str((action, task_id, instance))
            self.running = True
        if self.lose:
            self.lose = False
            raise PublicFailure(
                "local_operation_unknown",
                "Synthetic lost helper reply",
                waiting="local_admin",
            )


class FakeVerifier:
    def __init__(self):
        self.calls = []
        self.fail = False

    def verify(self, domain):
        self.calls.append(domain)
        if self.fail:
            raise PublicFailure(
                "instance_verification_failed", "Synthetic mismatched instance"
            )
