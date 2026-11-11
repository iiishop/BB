import os

import uvicorn

from bb_server.app import create_app


def main():
    # Required values keep machine-specific paths and listening addresses out of source.
    database = os.environ["BB_DATABASE_PATH"]
    host = os.environ["BB_HOST"]
    port = int(os.environ["BB_PORT"])
    if not 1 <= port <= 65535:
        raise ValueError("BB_PORT must be between 1 and 65535")
    uvicorn.run(create_app(database), host=host, port=port, access_log=False)


if __name__ == "__main__":
    main()
