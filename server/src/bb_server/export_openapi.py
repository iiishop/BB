"""Export the implemented contract without creating or opening a database."""

import argparse
import json
from pathlib import Path

from bb_server.app import create_app


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    schema = create_app(Path("unused-for-schema")).openapi()
    args.output.write_text(
        json.dumps(schema, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    main()
