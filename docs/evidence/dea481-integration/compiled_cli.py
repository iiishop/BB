"""Smoke the packaged AOT standalone client with the shared contract validator."""
import json
from pathlib import Path
import sys

from bb_auth_contract import space

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "dsh-plugin/probes"))
from space_live import Live  # noqa: E402

with Live() as live:
    live.stop(live.dart)
    binary = Path(sys.argv[1]).resolve()
    live.dart = live.launch([str(binary), *live.dart_command[3:]], live.local)
    account = live.register("CompiledClient")
    live.login(account)
    assert live.call("overview")["contract"] == space.VERSION
    result = live.call("create_draft", {
        "operation_id": "compiled-draft", "text": "compiled executable",
    })
    assert live.call("get_draft", {"draft_id": result["resource_id"]})["text"] == "compiled executable"
    print(json.dumps({"compiled_cli_real_tcp": "PASS", "registration_login_consumer_draft": "PASS"}))
