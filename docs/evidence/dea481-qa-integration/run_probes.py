"""Use the existing isolated real-process fixture, never another agent's path."""
import os
from pathlib import Path
import shutil
import subprocess
import sys

REPO = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
sys.path.insert(0, str(REPO / "dsh-plugin/probes"))
from space_live import Live  # noqa: E402

probe_dir = REPO / "client/.qa-artifacts/forge-qa-integration"
probe_dir.mkdir(parents=True, exist_ok=True)
shutil.copy2(REPO / "docs/evidence/dea481-client/qa-fixes/space_defect_probe_test.dart",
             probe_dir / "space_defect_probe_test.dart")
shutil.copy2(OUT / "adjacent_draft_probe_test.dart", probe_dir / "adjacent_draft_probe_test.dart")
name = sys.argv[1]
assert name in ["original", "adjacent"]
test = "space_defect_probe_test.dart" if name == "original" else "adjacent_draft_probe_test.dart"
with Live() as live:
    with (OUT / f"{name}.jsonl").open("w") as log:
        result = subprocess.run(
            ["flutter", "test", "--no-pub", str(probe_dir / test), "--reporter", "json"],
            cwd=REPO / "client",
            env={**os.environ, "BB_SPACE_API_BASE": live.api},
            stdout=log, stderr=subprocess.STDOUT,
        )
    (OUT / f"{name}.exit").write_text(str(result.returncode) + "\n")
sys.exit(result.returncode)
