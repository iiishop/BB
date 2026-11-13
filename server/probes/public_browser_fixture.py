"""Product app/worker/DB/SSE; external cloud, installer and verifier are test doubles.

No static wrapper, route mocks, alternate authentication, or production test flag.
Only launched by public_browser.mjs with an isolated directory.
"""

import argparse
import json
import sys
from contextlib import asynccontextmanager
from pathlib import Path

import uvicorn

from bb_server.admin import create_admin_app
from bb_server.public_runtime import PublicRuntime

sys.path.insert(0, str(Path(__file__).parents[1] / "tests"))
from public_fixture import FakeCloud, FakePlatform, FakeVerifier


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()
    cloud = FakeCloud()
    adapter = FakePlatform(args.directory / "private")
    runtime = PublicRuntime(
        args.directory / "admin.db",
        business_port=8000,
        challenge_directory=args.directory / "challenge",
        adapter=adapter,
        cloud_factory=lambda token: cloud,
        verifier=FakeVerifier(),
    )
    app = create_admin_app(
        args.directory / "admin.db", port=args.port, public_runtime=runtime
    )
    lifecycle = app.router.lifespan_context

    @asynccontextmanager
    async def evidence_lifespan(app):
        async with lifecycle(app):
            yield
        (args.directory / "external-effects.json").write_text(
            json.dumps({"cloud": cloud.calls, "platform": adapter.calls}),
            encoding="utf-8",
        )

    app.router.lifespan_context = evidence_lifespan
    uvicorn.run(
        app, host="127.0.0.1", port=args.port, proxy_headers=False, access_log=False
    )


if __name__ == "__main__":
    main()
