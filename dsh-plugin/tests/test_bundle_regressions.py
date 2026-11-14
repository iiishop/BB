"""Run dependency-free product JS regressions in the existing plugin CI job."""

import subprocess
from pathlib import Path


def test_bundle_regressions():
    root = Path(__file__).resolve().parents[2]
    tests = sorted((root / "dsh-plugin/probes/product").glob("*.test.mjs"))
    result = subprocess.run(
        ["node", "--test", *map(str, tests)],
        cwd=root,
        check=False,
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert result.returncode == 0, result.stdout + result.stderr
