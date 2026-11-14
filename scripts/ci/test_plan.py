"""Run: uv run --no-project python -m unittest discover -s scripts/ci -p 'test_*.py' -v."""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from plan import changed_paths, plan

ROOT = Path(__file__).resolve().parents[2]
ALL = {"flutter", "android", "server", "plugin", "admin_ui"}


class PlanTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for directory in ("client", "server", "dsh-plugin", "admin-ui"):
            (self.root / directory).mkdir()

    def enabled(self, paths):
        return {name for name, value in plan(self.root, paths).items() if value}

    def test_dependency_matrix(self):
        cases = {
            "client/lib/main.dart": {"flutter"},
            "dsh-plugin/uv.lock": {"plugin"},
            "server/src/bb_server/admin.py": {"server", "admin_ui"},
            "server/tests/public_fixture.py": {"server", "admin_ui"},
            "server/probes/public_browser.mjs": {"server", "admin_ui"},
            "server/probes/public_browser_fixture.py": {"server", "admin_ui"},
            "server/uv.lock": {"server", "admin_ui"},
            "server/contract/profile-cases.json": ALL - {"android"},
            "server/contract/chat-v2-openapi.json": ALL - {"android"},
            "server/contract/src/bb_auth_contract/admin.py": ALL - {"android"},
            "server/contract/pyproject.toml": ALL - {"android"},
            "scripts/run_flutter_tests.sh": {"flutter"},
            # Android 门禁只在 Android 侧或依赖变化时构建 APK。
            "client/lib/ui/chat/chat_page.dart": {"flutter"},
            "client/android/app/build.gradle.kts": {"flutter", "android"},
            "client/pubspec.lock": {"flutter", "android"},
            "scripts/ci/apk_budget.py": {"android"},
            ".github/workflows/ci.yml": ALL,
            "scripts/ci/plan.py": ALL,
            "scripts/ci/test_plan.py": ALL,
            "admin-ui/package-lock.json": {"admin_ui"},
            "admin-ui/tests/contract/validate_execute_body.py": {"admin_ui"},
            "README.md": set(),
            "docs/contracts/profile-step2.md": set(),
            "scripts/ci/package-linux.sh": set(),
            ".github/workflows/release.yml": set(),
            "server-old/file.py": set(),
            ".github/workflows/ci.yml.bak": set(),
            "scripts/run_flutter_tests.sh.bak": set(),
        }
        for path, expected in cases.items():
            with self.subTest(path=path):
                self.assertEqual(self.enabled([path]), expected)

    def test_empty_and_union(self):
        self.assertEqual(self.enabled([]), set())
        self.assertEqual(
            self.enabled(["client/a", "dsh-plugin/b"]), {"flutter", "plugin"}
        )

    def test_full_runs_and_missing_subsystems(self):
        self.assertEqual(self.enabled(None), ALL)
        (self.root / "client").rmdir()
        for paths in (
            None,
            [".github/workflows/ci.yml"],
            ["server/contract/cases.json"],
        ):
            self.assertEqual(self.enabled(paths), ALL - {"flutter", "android"})

    def test_large_changes_and_unusual_names(self):
        paths = ["docs/" + "x" * 100 + str(i) for i in range(10000)]
        paths += ["client/new\nfile.dart", "server/contract/空 格.json"]
        self.assertEqual(self.enabled(paths), ALL - {"android"})

    def git(self, *args):
        return subprocess.check_output(
            ["git", *args], cwd=self.root, stderr=subprocess.PIPE
        )

    def init_repo(self):
        self.git("init", "-q")
        self.git("config", "user.email", "ci-test@example.invalid")
        self.git("config", "user.name", "CI scope test")
        (self.root / "client/old.dart").write_text("fixture\n")
        self.git("add", ".")
        self.git("commit", "-qm", "base")
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")

    def test_real_git_rename_deletion_and_base_only_changes(self):
        self.init_repo()
        base = self.git("rev-parse", "HEAD").decode().strip()
        # Simulate base branch advancing: its change must not enter the PR diff.
        (self.root / "server/base-only.py").write_text("base\n")
        self.git("add", ".")
        self.git("commit", "-qm", "base advanced")
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        self.git("reset", "--hard", base)
        (self.root / "client/old.dart").rename(self.root / "moved\nfile.dart")
        self.git("add", "-A")
        self.git("commit", "-qm", "move out of client")
        paths = changed_paths(self.root, "pull_request", "main")
        assert paths is not None
        self.assertEqual(set(paths), {"client/old.dart", "moved\nfile.dart"})
        self.assertEqual(self.enabled(paths), {"flutter"})

    def test_cli_outputs_and_diff_failure(self):
        self.init_repo()
        cases = (
            ("pull_request", "missing", None),
            ("pull_request", "", None),
            ("pull_request", "main", "false"),
            ("push", "", "true"),
            ("workflow_dispatch", "", "true"),
        )
        for event, base, expected in cases:
            with self.subTest(event=event, base=base):
                result = subprocess.run(
                    [sys.executable, str(ROOT / "scripts/ci/plan.py")],
                    cwd=self.root,
                    env={**os.environ, "EVENT_NAME": event, "BASE_REF": base},
                    capture_output=True,
                    text=True,
                    check=False,
                )
                if expected is None:
                    self.assertNotEqual(result.returncode, 0)
                    # Never advertise successful skips on diff failure.
                    self.assertEqual(result.stdout, "")
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(
                        set(result.stdout.splitlines()),
                        {f"{key}={expected}" for key in ALL},
                    )
        with self.assertRaises(ValueError):
            changed_paths(self.root, "pull_request", "")


if __name__ == "__main__":
    unittest.main()
