"""Run: python3 -m unittest discover -s scripts/ci -p 'test_*.py' -v."""

import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

from apk_budget import EXCLUDED_SO, MAX_MIB, check_bundle, check_sources


class ApkBudgetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def make_apk(self, names, padding=0):
        apk = self.root / "app-release.apk"
        with zipfile.ZipFile(apk, "w", zipfile.ZIP_STORED) as bundle:
            for name in names:
                bundle.writestr(name, "x")
            if padding:
                bundle.writestr("blob.bin", b"\0" * padding)
        return apk

    def make_sources(self, body):
        lib = self.root / "client" / "lib"
        lib.mkdir(parents=True)
        (lib / "viewer_video.dart").write_text(body, encoding="utf-8")

    def test_clean_bundle_passes(self):
        apk = self.make_apk(
            [
                "lib/arm64-v8a/libapp.so",
                "lib/arm64-v8a/libc++_shared.so",
                "lib/arm64-v8a/libflutter.so",
            ]
        )
        self.assertEqual(check_bundle(apk), [])

    def test_each_excluded_library_is_reported(self):
        for banned in EXCLUDED_SO:
            with self.subTest(banned=banned):
                apk = self.make_apk(["lib/arm64-v8a/libapp.so", f"lib/arm64-v8a/{banned}"])
                problems = check_bundle(apk)
                self.assertEqual(len(problems), 1)
                self.assertIn(banned, problems[0])

    def test_bare_name_at_archive_root_is_reported(self):
        apk = self.make_apk(["libffmpeg.so"])
        self.assertEqual(len(check_bundle(apk)), 1)

    def test_lookalike_name_is_not_reported(self):
        apk = self.make_apk(
            ["lib/arm64-v8a/libapp.so", "lib/arm64-v8a/libffmpeg_extra.so"]
        )
        self.assertEqual(check_bundle(apk), [])

    def test_oversized_bundle_is_reported(self):
        apk = self.make_apk(["lib/arm64-v8a/libapp.so"], padding=MAX_MIB * 1024 * 1024)
        problems = check_bundle(apk)
        self.assertEqual(len(problems), 1)
        self.assertIn("超过上限", problems[0])

    def test_missing_apk_is_reported(self):
        self.assertEqual(len(check_bundle(self.root / "nope.apk")), 1)

    def test_clean_sources_pass(self):
        self.make_sources("import 'package:video_player/video_player.dart';\n")
        self.assertEqual(check_sources(self.root), [])

    def test_fvp_dart_import_is_reported(self):
        self.make_sources("import 'package:fvp/fvp.dart';\n")
        problems = check_sources(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("package:fvp/", problems[0])


if __name__ == "__main__":
    unittest.main()
