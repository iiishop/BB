"""Regression contracts for the expensive Windows package workflow (stdlib only)."""
import fnmatch
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / '.github/workflows/windows-test-package.yml'


class WindowsPathsTests(unittest.TestCase):
    def test_cache_never_skips_final_checks(self):
        text = WORKFLOW.read_text()
        self.assertIn('actions/cache/restore@v4', text)
        self.assertIn('actions/cache/save@v4', text)
        self.assertNotIn('restore-keys:', text)
        self.assertIn('actions: read', text)
        for block in text.split('\n      - '):
            if ('fetch_ffmpeg_sources.py --dest' in block or
                    'uses: msys2/setup-msys2@' in block or
                    'run: bash scripts/ci/build_ffmpeg_windows.sh' in block):
                self.assertIn("if: steps.ffmpeg-cache.outputs.cache-hit != 'true'", block)
            if ('run: flutter test' in block or 'python scripts/ci/package_windows.py' in block
                    or 'flutter build windows --release' in block or 'ffmpeg_cache.py verify' in block):
                self.assertNotIn('if:', block)

    def test_only_windows_inputs_trigger_packaging(self):
        text = WORKFLOW.read_text()
        paths = re.findall(r"^      - '([^']+)'$", text, re.M)
        def triggers(path):
            return any(fnmatch.fnmatchcase(path, pattern) for pattern in paths)
        excluded = ['scripts/ci/qa_evidence.py', 'scripts/ci/test_qa_evidence.py',
                    'client/docs/dea477-windows-package.md', 'client/android/app/build.gradle.kts',
                    'client/linux/CMakeLists.txt', 'client/macos/Runner/AppDelegate.swift',
                    'scripts/ci/package-linux.sh', 'scripts/ci/plan.py']
        included = ['client/lib/main.dart', 'client/windows/CMakeLists.txt',
                    'client/pubspec.yaml', 'client/pubspec.lock', 'client/assets/icon.png',
                    'client/test/ffmpeg_tool_test.dart', 'client/test/chat_clipboard_paste_test.dart',
                    'client/test/support/fake_chat_service.dart',
                    'scripts/ci/build_ffmpeg_windows.sh', 'scripts/ci/ffmpeg_pins.py',
                    'scripts/ci/fetch_ffmpeg_sources.py', 'scripts/ci/package_windows.py',
                    'scripts/ci/fixtures/cover-smoke-h264.mp4',
                    '.github/workflows/windows-test-package.yml']
        for path in excluded:
            with self.subTest(path=path): self.assertFalse(triggers(path))
        for path in included:
            with self.subTest(path=path): self.assertTrue(triggers(path))
        self.assertIn('  workflow_dispatch:', text)


if __name__ == '__main__':
    unittest.main()
