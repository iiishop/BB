"""Cloudflare API adapter. No ambient credentials, proxy env, redirects or logging."""

import base64
import http.client
import json
import re
import secrets
import ssl
from urllib.parse import urlencode
from uuid import UUID


class PublicFailure(Exception):
    def __init__(self, code, message, *, waiting=None):
        super().__init__(code)
        self.code, self.message, self.waiting = code, message, waiting


def unknown(code="cloud_unavailable"):
    return PublicFailure(
        code,
        "外部结果未知；需提供授权后查询核对，未重发创建操作",
        waiting="authorization",
    )


def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{32}", value):
        raise unknown("cloud_response_invalid")
    return value


class Cloudflare:
    def __init__(self, token, transport=None):
        self._token, self._transport = token, transport

    def request(self, method, path, payload=None):
        if self._transport:
            return self._transport(method, path, payload)
        if not path.startswith("/") or "\r" in path or "\n" in path:
            raise ValueError("Invalid fixed API path")
        connection = http.client.HTTPSConnection(
            "api.cloudflare.com", timeout=10, context=ssl.create_default_context()
        )
        try:
            headers = {
                "Authorization": "Bearer " + self._token,
                "Content-Type": "application/json",
            }
            connection.request(
                method,
                "/client/v4" + path,
                body=json.dumps(payload).encode() if payload is not None else None,
                headers=headers,
            )
            response = connection.getresponse()
            if response.status in (401, 403):
                raise PublicFailure(
                    "cloud_authorization_required",
                    "需要专用 API Token：指定区域 Zone Read、DNS Edit，以及所属账户 Cloudflare Tunnel Edit",
                    waiting="authorization",
                )
            if response.status == 429 or response.status >= 500:
                raise unknown()
            if not 200 <= response.status < 300:
                raise PublicFailure(
                    "cloud_request_rejected",
                    "Cloudflare 拒绝请求；保留已创建资源，核对权限或冲突",
                )
            body = response.read(2 * 1024 * 1024 + 1)
            if len(body) > 2 * 1024 * 1024:
                raise unknown("cloud_response_too_large")
            result = json.loads(body)
            if result.get("success") is not True or "result" not in result:
                raise unknown("cloud_response_invalid")
            return result
        except (OSError, ValueError, http.client.HTTPException):
            raise unknown() from None
        finally:
            connection.close()

    def listing(self, path, **query):
        values = []
        for page in range(1, 101):
            result = self.request(
                "GET", path + "?" + urlencode({**query, "page": page, "per_page": 50})
            )
            if not isinstance(result["result"], list):
                raise unknown("cloud_response_invalid")
            values.extend(result["result"])
            info = result.get("result_info", {})
            total = info.get("total_pages")
            if (isinstance(total, int) and page >= total) or (
                total is None and len(result["result"]) < 50
            ):
                return values
        raise unknown("cloud_inventory_incomplete")

    def zone(self, domain):
        labels = domain.split(".")
        for offset in range(len(labels) - 1):
            name = ".".join(labels[offset:])
            zones = self.listing("/zones", name=name, status="active")
            exact = [z for z in zones if z.get("name") == name]
            if len(exact) > 1:
                raise PublicFailure("zone_ambiguous", "区域归属不唯一，停止自动配置")
            if exact:
                return {
                    "zone_id": identifier(exact[0]["id"]),
                    "account_id": identifier(exact[0]["account"]["id"]),
                }
        raise PublicFailure(
            "zone_not_authorized",
            "无法读取专用子域所属区域；DNS 可解析不代表拥有管理权",
            waiting="authorization",
        )

    def tunnels(self, account, name=None):
        return self.listing(
            f"/accounts/{identifier(account)}/cfd_tunnel",
            **({"name": name} if name else {}),
            is_deleted="false",
        )

    def records(self, zone, domain):
        return self.listing(f"/zones/{identifier(zone)}/dns_records", name=domain)

    def token(self, account, tunnel):
        value = self.request(
            "GET",
            f"/accounts/{identifier(account)}/cfd_tunnel/{UUID(str(tunnel))}/token",
        )["result"]
        if not isinstance(value, str) or len(value) > 4096:
            raise unknown("cloud_token_invalid")
        return value

    @staticmethod
    def owns_token(token, secret, tunnel):
        try:
            value = json.loads(
                base64.b64decode(token + "=" * (-len(token) % 4), validate=True)
            )
            return str(UUID(value["t"])) == str(
                UUID(str(tunnel))
            ) and secrets.compare_digest(value["s"], secret)
        except (ValueError, KeyError, TypeError):
            return False

    def create_tunnel(self, account, name, secret):
        result = self.request(
            "POST",
            f"/accounts/{identifier(account)}/cfd_tunnel",
            {"name": name, "config_src": "cloudflare", "tunnel_secret": secret},
        )["result"]
        return str(UUID(result["id"]))

    def config(self, account, tunnel):
        return self.request(
            "GET",
            f"/accounts/{identifier(account)}/cfd_tunnel/{UUID(str(tunnel))}/configurations",
        )["result"].get("config", {})

    @staticmethod
    def ingress(domain, target):
        return {
            "ingress": [
                {"hostname": domain, "service": target},
                {"service": "http_status:404"},
            ]
        }

    def configure(self, account, tunnel, domain, target):
        self.request(
            "PUT",
            f"/accounts/{identifier(account)}/cfd_tunnel/{UUID(str(tunnel))}/configurations",
            {"config": self.ingress(domain, target)},
        )

    def create_record(self, zone, domain, tunnel, marker):
        value = self.request(
            "POST",
            f"/zones/{identifier(zone)}/dns_records",
            {
                "type": "CNAME",
                "name": domain,
                "content": f"{UUID(str(tunnel))}.cfargotunnel.com",
                "proxied": True,
                "comment": marker,
            },
        )["result"]
        return identifier(value["id"])

    def inspect(self, domain):
        scope = self.zone(domain)
        records = self.records(scope["zone_id"], domain)
        # Inventory does not read cert.pem or infer service failure from its absence.
        tunnels = self.tunnels(scope["account_id"])
        return {**scope, "records": records, "tunnels": tunnels}
