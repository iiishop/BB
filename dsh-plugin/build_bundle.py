"""Assemble a self-contained directory bundle; fixed uv locks, no build scripts/dependency upgrades."""

import argparse
import shutil
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("output", type=Path)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
if args.output.exists():
    raise SystemExit(
        "Output must be a fresh directory; existing bundles are never overwritten"
    )
shutil.copytree(repo / "dsh-plugin/bundle", args.output)
for project in ["dsh-plugin", "server/contract"]:
    target = args.output / "python" / project
    target.mkdir(parents=True)
    for name in ["pyproject.toml", "uv.lock"]:
        source = repo / project / name
        if source.exists():
            shutil.copy2(source, target / name)
    shutil.copytree(
        repo / project / "src",
        target / "src",
        ignore=shutil.ignore_patterns("__pycache__", "*.pyc"),
    )
print(args.output.resolve())
