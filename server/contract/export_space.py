"""Export standalone server and owner-bound local wire schemas (no DB/host)."""

import json
from pathlib import Path

from bb_auth_contract import space


def schema():
    return {
        "contract": space.VERSION,
        "actions": {
            name: {
                "method": "POST",
                "server_path": "/space/" + name,
                "local_path": "/v2/space/" + name,
                "request": model.model_json_schema(),
                "response": space.RESPONSES[name].model_json_schema(),
                "local_request": space.LOCAL_REQUESTS[name].model_json_schema(),
                "local_response": space.LOCAL_RESPONSES[name].model_json_schema(),
            }
            for name, model in space.REQUESTS.items()
        },
    }


if __name__ == "__main__":
    Path(__file__).with_name("space-v1.json").write_text(
        json.dumps(schema(), ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
