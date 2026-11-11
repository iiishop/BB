"""Export the implemented contract without creating or opening a database."""

import argparse
import json
from pathlib import Path

from bb_auth_contract.profile import PROFILE_RESPONSES, PROFILE_TOOLS

from bb_server.app import create_app


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("--local-profile-output", type=Path)
    args = parser.parse_args()
    schema = create_app(Path("unused-for-schema")).openapi()
    args.output.write_text(
        json.dumps(schema, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    if args.local_profile_output:
        local_schema = {
            name: {
                "method": "POST",
                "path": f"/profile/{name}",
                "input": model.model_json_schema(),
                "output": PROFILE_RESPONSES[name].model_json_schema(),
            }
            for name, model in PROFILE_TOOLS.items()
        }
        args.local_profile_output.write_text(
            json.dumps(local_schema, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )


if __name__ == "__main__":
    main()
