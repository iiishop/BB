"""Export A implementation and B reserved wire contract without opening a DB."""

import argparse
import json
from pathlib import Path

from bb_server.admin import create_admin_app


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.write_text(
        json.dumps(
            create_admin_app("unused-for-schema", port=9001).openapi(),
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
