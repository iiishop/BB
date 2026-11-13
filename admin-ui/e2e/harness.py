"""Test-only same-origin harness for the DEA-469 Vue admin build.

Stage A's bb-admin does not serve a UI yet; stage B (Forge) owns that seam.
This harness is browser-evidence scaffolding only, not product code: it wraps
the *real* `create_admin_app` (same origin, same Host/Origin/CSRF boundary and
same cookie) and serves `admin-ui/dist` under /admin/. It deliberately mirrors
the documented mount (base /admin/, API relative /admin/api) without changing
server/ or weakening any header. Run through Playwright only.
"""

from __future__ import annotations

import argparse
import mimetypes
import sys
from pathlib import Path

import uvicorn

from bb_server.admin import create_admin_app

SECURITY_HEADERS = [
    (b"cache-control", b"no-store"),
    (b"pragma", b"no-cache"),
    (b"x-content-type-options", b"nosniff"),
    (b"x-frame-options", b"DENY"),
    (b"referrer-policy", b"no-referrer"),
    (
        b"content-security-policy",
        b"default-src 'self'; frame-ancestors 'none'; base-uri 'none'",
    ),
]


class StaticAdminHarness:
    def __init__(self, app, dist: Path):
        self.app = app
        self.dist = dist.resolve()

    @staticmethod
    async def _send(send, status: int, headers: list[tuple[bytes, bytes]], body: bytes = b""):
        await send(
            {
                "type": "http.response.start",
                "status": status,
                "headers": headers + SECURITY_HEADERS,
            }
        )
        await send({"type": "http.response.body", "body": body})

    async def _not_found(self, send):
        await self._send(
            send,
            404,
            [(b"content-type", b"text/plain; charset=utf-8")],
            b"Not Found",
        )

    def _resolve(self, path: str) -> Path | None:
        relative = path[len("/admin/") :]
        candidate = (self.dist / relative).resolve()
        try:
            candidate.relative_to(self.dist)
        except ValueError:
            return None
        return candidate

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)

        path = scope["path"]
        method = scope["method"]

        # API must hit the real management app; its 404/401/501 bodies and
        # security headers are never replaced by the SPA fallback.
        if path.startswith("/admin/api"):
            return await self.app(scope, receive, send)

        if path in ("/admin", "/admin/"):
            if path == "/admin":
                return await self._send(send, 308, [(b"location", b"/admin/")])
            target = self.dist / "index.html"
        elif path.startswith("/admin/"):
            target = self._resolve(path)
            if target is None or not target.exists():
                if path.endswith("/") or "." not in Path(path).name:
                    target = self.dist / "index.html"
                else:
                    return await self._not_found(send)
        else:
            return await self._not_found(send)

        if method not in ("GET", "HEAD") or not target.is_file():
            return await self._not_found(send)

        body = target.read_bytes()
        content_type = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
        if content_type.startswith("text/") or content_type in (
            "application/javascript",
            "application/json",
            "image/svg+xml",
        ):
            content_type += "; charset=utf-8"
        await self._send(
            send,
            200,
            [
                (b"content-type", content_type.encode()),
                (b"content-length", str(len(body)).encode()),
            ],
            b"" if method == "HEAD" else body,
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--db", type=Path, required=True)
    parser.add_argument("--dist", type=Path, required=True)
    args = parser.parse_args()

    if not (args.dist / "index.html").is_file():
        print(f"missing build: {args.dist}/index.html (run npm run build)", file=sys.stderr)
        return 2
    args.db.parent.mkdir(parents=True, exist_ok=True)
    admin = create_admin_app(args.db, port=args.port)
    harness = StaticAdminHarness(admin, args.dist)
    uvicorn.run(
        harness,
        host="127.0.0.1",
        port=args.port,
        log_level="warning",
        proxy_headers=False,
        server_header=False,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
