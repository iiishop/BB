"""Explicit local listener; no environment-controlled host or proxy trust."""

import os
from pathlib import Path

import uvicorn

from bb_server.admin import create_admin_app


def is_elevated():
    if os.name == "nt":
        import ctypes

        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    return os.geteuid() == 0


def main():
    database = Path(os.environ["BB_ADMIN_DATABASE_PATH"]).resolve()
    business_database = Path(os.environ["BB_DATABASE_PATH"]).resolve()
    port = int(os.environ["BB_ADMIN_PORT"])
    business_port = int(os.environ["BB_PORT"])
    if database == business_database or (
        database.exists()
        and business_database.exists()
        and database.samefile(business_database)
    ):
        raise ValueError("Management and business databases must be separate")
    if port == business_port:
        raise ValueError("Management and business ports must be separate")
    if is_elevated():
        raise RuntimeError("Run BB management as an unprivileged user")
    uvicorn.run(
        create_admin_app(database, port=port),
        host="127.0.0.1",
        port=port,
        proxy_headers=False,
        access_log=False,
    )


if __name__ == "__main__":
    main()
