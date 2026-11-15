"""Opt-in gateway and existing auth/chat/media regressions on real FastAPI."""
import os
from pathlib import Path
import subprocess
import sys

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "dsh-plugin/probes"))
from space_live import Live  # noqa: E402

with Live() as live:
    result = subprocess.run(
        ["flutter", "test", "--no-pub", "test/space_real_api_test.dart",
         "test/live_auth_test.dart", "test/live_chat_e2e_test.dart",
         "test/live_media_contract_test.dart", "--reporter", "json"],
        cwd=REPO / "client",
        env={**os.environ, "BB_SPACE_API_BASE": live.api, "BB_LIVE_SERVER_URL": live.api},
    )
sys.exit(result.returncode)
