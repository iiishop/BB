"""Real isolated server/client probes using existing Live lifecycle cleanup."""
import os
from pathlib import Path
import shutil
import subprocess
import sys

REPO = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
sys.path.insert(0, str(REPO / "dsh-plugin/probes"))
from space_live import Live  # noqa: E402

target = REPO / "client/.qa-artifacts/forge-round3"
target.mkdir(parents=True, exist_ok=True)
for source in [
    REPO / "docs/evidence/dea481-client/qa-fixes/space_defect_probe_test.dart",
    REPO / "docs/evidence/dea481-qa-integration/adjacent_draft_probe_test.dart",
    REPO / "docs/evidence/dea481-qa-round2/upload_conflict_probe_test.dart",
]:
    shutil.copy2(source, target / source.name)
mode = sys.argv[1]
assert mode in ["original-five", "upload-conflict"]
tests = ["space_defect_probe_test.dart", "adjacent_draft_probe_test.dart"] if mode == "original-five" else ["upload_conflict_probe_test.dart"]
with Live() as live:
    with (OUT / f"{mode}.jsonl").open("w") as log:
        result = subprocess.run(
            ["flutter", "test", "--no-pub", *[str(target / t) for t in tests], "--reporter", "json"],
            cwd=REPO / "client",
            env={**os.environ, "BB_SPACE_API_BASE": live.api},
            stdout=log, stderr=subprocess.STDOUT,
        )
    (OUT / f"{mode}.exit").write_text(str(result.returncode) + "\n")
sys.exit(result.returncode)
