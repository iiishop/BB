"""Validate actual /executions request bodies against the canonical DTO.

The admin UI test writes the body it really sends (JSON on stdin, shaped as
{"cases": [{"name": ..., "body": ...}]}) and this script runs Pydantic's
PlanExecute validation, the same DTO used by the server route. Exit code 0 only
means validation ran; per-case validity is reported in the JSON.
"""

from __future__ import annotations

import json
import sys

from pydantic import ValidationError

from bb_auth_contract.admin import PlanExecute


def main() -> int:
    payload = json.load(sys.stdin)
    cases = payload.get("cases")
    if not isinstance(cases, list):
        print(json.dumps({"error": "cases must be a list"}), file=sys.stderr)
        return 2

    results = []
    for case in cases:
        try:
            PlanExecute.model_validate(case["body"])
        except ValidationError as error:
            results.append(
                {
                    "name": case.get("name"),
                    "valid": False,
                    "errors": [
                        {
                            "loc": [str(part) for part in item["loc"]],
                            "type": item["type"],
                        }
                        for item in error.errors()
                    ],
                }
            )
        else:
            results.append({"name": case.get("name"), "valid": True, "errors": []})

    json.dump({"results": results}, sys.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
