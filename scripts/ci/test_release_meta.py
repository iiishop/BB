"""Release policy regression, executed by the existing CI plan job."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReleaseMetaTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        (self.root / 'client').mkdir()
        (self.root / 'client/pubspec.yaml').write_text('version: 0.0.1+2\n')

    def run_meta(self, event, ref_type, ref_name):
        return subprocess.run(
            [sys.executable, str(ROOT / 'scripts/ci/release_meta.py')],
            cwd=self.root, capture_output=True, text=True,
            env={**os.environ, 'EVENT': event, 'REF_TYPE': ref_type,
                 'REF_NAME': ref_name, 'GITHUB_SHA': 'a' * 40},
        )

    def test_main_is_sha_identified_test_build(self):
        result = self.run_meta('push', 'branch', 'main')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('publish=false', result.stdout)
        self.assertIn('package_version=0.0.1.test.aaaaaaaaaaaa', result.stdout)

    def test_only_matching_tag_push_publishes(self):
        result = self.run_meta('push', 'tag', 'v0.0.1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('publish=true', result.stdout)
        self.assertIn('package_version=0.0.1\n', result.stdout)
        result = self.run_meta('push', 'tag', 'v9.9.9')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_dispatch_even_on_tag_never_publishes(self):
        for ref_type, ref_name in [('branch', 'main'), ('tag', 'v0.0.1')]:
            result = self.run_meta('workflow_dispatch', ref_type, ref_name)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('publish=false', result.stdout)
            self.assertIn('.test.aaaaaaaaaaaa', result.stdout)

    def test_workflow_release_requires_same_sha_ci(self):
        release = (ROOT / '.github/workflows/release.yml').read_text()
        ci = (ROOT / '.github/workflows/ci.yml').read_text()
        self.assertIn('  workflow_call:', ci)
        self.assertIn('uses: ./.github/workflows/ci.yml', release)
        self.assertIn('needs: [meta, ci, linux, arch, windows, macos, android]', release)
        self.assertNotIn('DISPATCH_PUBLISH', release)
        self.assertIn('--repo "$GITHUB_REPOSITORY"', release)
        self.assertIn('flutter test test/ffmpeg_tool_test.dart test/chat_clipboard_paste_test.dart', release)
        # The release job takes the pinned dependency asset instead of compiling
        # FFmpeg twice per release. Integrity still comes from verify(): archive
        # hash, tree digest, build-script byte equality and the measured EXE hash.
        self.assertIn('ffmpeg_cache.py fetch', release)
        self.assertIn('ffmpeg_cache.py verify', release)
        self.assertIn('FFMPEG_SOURCE: asset', release)
        self.assertIn('package_windows.py', release)
        self.assertNotIn('build_ffmpeg_windows.sh --sources', release)


if __name__ == '__main__':
    unittest.main()
