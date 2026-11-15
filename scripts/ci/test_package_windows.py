"""Unit tests for the Windows bundle packaging helper (no Windows needed)."""

from __future__ import annotations

import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import package_windows as pkg


def make_bundle(
    root: Path,
    *,
    with_ffmpeg: bool = True,
    with_license: bool = True,
    forbidden: bool = False,
    ffmpeg_payload: bytes = b"MZ" + b"\0" * 256,
) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    assets = root / "data" / "flutter_assets"
    assets.mkdir(parents=True, exist_ok=True)
    (assets / "AssetManifest.bin").write_bytes(b"manifest")
    (root / "bb_client.exe").write_bytes(b"MZ" + b"\0" * 512)
    (root / "data" / "app.so").write_bytes(b"\0" * 128)
    if with_ffmpeg:
        ffmpeg_dir = root / "ffmpeg"
        ffmpeg_dir.mkdir()
        (ffmpeg_dir / "ffmpeg.exe").write_bytes(ffmpeg_payload)
        if with_license:
            (ffmpeg_dir / "FFMPEG-LICENSE.txt").write_text(
                "LGPL", encoding="utf-8"
            )
            (ffmpeg_dir / "FFMPEG-NOTICE.txt").write_text(
                "notice", encoding="utf-8"
            )
    if forbidden:
        (root / "ffprobe.exe").write_bytes(b"MZ")
    return root


class ValidateBundleTests(unittest.TestCase):
    def test_accepts_complete_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bundle = make_bundle(Path(temporary) / "bundle")
            report = pkg.validate_bundle(
                bundle, min_ffmpeg_bytes=8, min_app_bytes=8
            )
            self.assertEqual(report["ffmpeg_bytes"], 258)

    def test_rejects_missing_ffmpeg(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bundle = make_bundle(Path(temporary) / "bundle", with_ffmpeg=False)
            with self.assertRaises(RuntimeError) as context:
                pkg.validate_bundle(
                    bundle, min_ffmpeg_bytes=8, min_app_bytes=8
                )
            self.assertIn("ffmpeg/ffmpeg.exe", str(context.exception))

    def test_rejects_missing_license_and_notice(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bundle = make_bundle(
                Path(temporary) / "bundle", with_license=False
            )
            with self.assertRaises(RuntimeError) as context:
                pkg.validate_bundle(
                    bundle, min_ffmpeg_bytes=8, min_app_bytes=8
                )
            self.assertIn("FFMPEG-LICENSE.txt", str(context.exception))

    def test_rejects_unused_ffprobe(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bundle = make_bundle(Path(temporary) / "bundle", forbidden=True)
            with self.assertRaises(RuntimeError) as context:
                pkg.validate_bundle(
                    bundle, min_ffmpeg_bytes=8, min_app_bytes=8
                )
            self.assertIn("ffprobe.exe", str(context.exception))

    def test_rejects_non_pe_ffmpeg(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bundle = make_bundle(
                Path(temporary) / "bundle",
                ffmpeg_payload=b"not-an-exe" * 4,
            )
            with self.assertRaises(RuntimeError) as context:
                pkg.validate_bundle(
                    bundle, min_ffmpeg_bytes=8, min_app_bytes=8
                )
            self.assertIn("not a Windows PE", str(context.exception))


class ZipTests(unittest.TestCase):
    def test_zip_layout_and_inspection(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bundle = make_bundle(Path(temporary) / "bundle")
            archive_path = Path(temporary) / "package.zip"
            pkg.build_zip(bundle, archive_path)
            report = pkg.inspect_zip(archive_path, min_zip_bytes=1)
            self.assertGreater(report["zip_bytes"], 0)
            self.assertEqual(len(report["zip_sha256"]), 64)
            with zipfile.ZipFile(archive_path) as archive:
                names = set(archive.namelist())
            self.assertIn("bb_client.exe", names)
            self.assertIn("ffmpeg/ffmpeg.exe", names)
            self.assertIn("data/flutter_assets/AssetManifest.bin", names)

    def test_inspection_rejects_archive_without_bundled_tools(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive_path = Path(temporary) / "broken.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("bb_client.exe", b"MZ")
                archive.writestr(
                    "data/flutter_assets/AssetManifest.bin", b"manifest"
                )
            with self.assertRaises(RuntimeError) as context:
                pkg.inspect_zip(archive_path, min_zip_bytes=1)
            self.assertIn("ffmpeg/ffmpeg.exe", str(context.exception))

    def test_extracts_to_space_and_chinese_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bundle = make_bundle(Path(temporary) / "bundle")
            archive_path = Path(temporary) / "package.zip"
            pkg.build_zip(bundle, archive_path)
            workspace = Path(temporary) / "work"
            result = pkg.extract_and_recheck(
                archive_path,
                workspace,
                min_ffmpeg_bytes=8,
                min_app_bytes=8,
            )
            self.assertIn("BB 测试 包", result["extracted_to"])
            self.assertTrue(Path(result["extracted_to"]).is_dir())
            # Non-Windows hosts cannot execute the .exe; the smoke must be
            # explicitly NOT_RUN, never a fake PASS.
            self.assertEqual(result["smoke"]["status"], "NOT_RUN")


class CleanPathTests(unittest.TestCase):
    def test_clean_env_replaces_path(self) -> None:
        env = pkg.build_clean_env({"PATH": "/does/not/matter", "KEEP": "yes"})
        self.assertNotEqual(env["PATH"], "/does/not/matter")
        self.assertEqual(env["KEEP"], "yes")

    def test_assert_rejects_visible_system_tool(self) -> None:
        with mock.patch.object(
            pkg.shutil, "which", return_value="/usr/bin/ffmpeg"
        ):
            with self.assertRaises(RuntimeError):
                pkg.assert_no_system_ffmpeg({"PATH": "/usr/bin"})
        with mock.patch.object(pkg.shutil, "which", return_value=None):
            pkg.assert_no_system_ffmpeg({"PATH": "/clean"})


if __name__ == "__main__":
    unittest.main()
