"""Dependency-aware CI scope; stdlib only. Run from the checkout root."""

import os
import subprocess
from pathlib import Path

# A trailing slash means a directory prefix; other entries are exact files.
# Shared fixtures are read by client tests and installed by the Python plugin.
TARGETS = {
    "flutter": (
        "client",
        ("client/", "server/contract/", "scripts/run_flutter_tests.sh"),
    ),
    # Android 构建要真跑 gradle（几分钟），所以只在 Android 侧或依赖变化时
    # 触发，日常改 Dart 代码不付这个成本。
    "android": (
        "client",
        (
            "client/android/",
            "client/pubspec.yaml",
            "client/pubspec.lock",
        ),
    ),
    "server": ("server", ("server/",)),
    "plugin": ("dsh-plugin", ("dsh-plugin/", "server/contract/")),
    # The browser probe runs the real server and imports server/tests fixtures.
    "admin_ui": ("admin-ui", ("admin-ui/", "server/")),
}
COMMON = (".github/workflows/ci.yml", "scripts/ci/plan.py", "scripts/ci/test_plan.py")


def matches(path, rule):
    return path.startswith(rule) if rule.endswith("/") else path == rule


def plan(root, changed):
    """None means push/dispatch (all existing targets); [] means no PR changes."""
    return {
        name: (root / directory).is_dir()
        and (
            changed is None
            or any(matches(path, rule) for path in changed for rule in COMMON + rules)
        )
        for name, (directory, rules) in TARGETS.items()
    }


def changed_paths(root, event, base_ref):
    if event != "pull_request":
        return None
    if not base_ref:
        raise ValueError("pull_request requires BASE_REF")
    # checkout fetch-depth: 0 provides origin/<base>. Never turn a failed diff
    # into a green skip. NUL handles unusual filenames; no-renames includes BOTH
    # paths when a file moves out of a target. Read once, without grep/SIGPIPE.
    output = subprocess.check_output(
        [
            "git",
            "diff",
            "--no-renames",
            "--name-only",
            "-z",
            f"origin/{base_ref}...HEAD",
            "--",
        ],
        cwd=root,
    )
    return [os.fsdecode(path) for path in output.split(b"\0") if path]


def main():
    root = Path.cwd()
    changed = changed_paths(
        root, os.environ["EVENT_NAME"], os.environ.get("BASE_REF", "")
    )
    for name, enabled in plan(root, changed).items():
        print(f"{name}={str(enabled).lower()}")


if __name__ == "__main__":
    main()
