import os

import uvicorn

from bb_server.app import create_app


def main():
    # Required values keep machine-specific paths and listening addresses out of source.
    database = os.environ["BB_DATABASE_PATH"]
    avatars = os.environ["BB_AVATAR_DIRECTORY"]
    host = os.environ["BB_HOST"]
    port = int(os.environ["BB_PORT"])
    if not 1 <= port <= 65535:
        raise ValueError("BB_PORT must be between 1 and 65535")
    interval = float(os.environ.get("BB_SESSION_MAINTENANCE_SECONDS", "5"))
    uvicorn.run(
        create_app(
            database,
            avatars,
            media_directory=os.environ["BB_MEDIA_DIRECTORY"],
            maintenance_interval=interval,
        ),
        host=host,
        port=port,
        access_log=False,
    )


if __name__ == "__main__":
    main()
