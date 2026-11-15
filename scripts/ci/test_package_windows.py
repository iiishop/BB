"""Unit tests for the Windows bundle packaging helper (no Windows needed)."""

from __future__ import annotations

import hashlib
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import package_windows as pkg
from ffmpeg_pins import (
    FFMPEG_COMMIT,
    FFMPEG_REQUIRED_CONFIGURE,
    FFMPEG_SOURCE_SHA256,
    FFMPEG_VERSION,
    ZLIB_SOURCE_SHA256,
    ZLIB_VERSION,
)


def make_bundle(
    root: Path,
    *,
    ffmpeg_payload: bytes = b"MZ" + b"\0" * 256,
    configure: str = " ".join(FFMPEG_REQUIRED_CONFIGURE),
    tamper_after_manifest: bool = False,
    omit_license: str | None = None,
    forbidden: bool = False,
) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    assets = root / "data" / "flutter_assets"
    assets.mkdir(parents=True, exist_ok=True)
    (assets / "AssetManifest.bin").write_bytes(b"manifest")
    (root / "bb_client.exe").write_bytes(b"MZ" + b"\0" * 512)
    ffmpeg_dir = root / "ffmpeg"
    ffmpeg_dir.mkdir()
    exe = ffmpeg_dir / "ffmpeg.exe"
    exe.write_bytes(ffmpeg_payload)
    licenses = {
        "FFMPEG-LICENSE.txt": "GNU LESSER GENERAL PUBLIC LICENSE\nVersion 2.1\n",
        "FFMPEG-LGPLv3.txt": "GNU LESSER GENERAL PUBLIC LICENSE Version 3\n",
        "FFMPEG-GPLv3.txt": "GNU GENERAL PUBLIC LICENSE Version 3\n",
        "ZLIB-LICENSE.txt": "This software is provided 'as-is'\n",
    }
    if omit_license:
        licenses.pop(omit_license)
    for name, text in licenses.items():
        (ffmpeg_dir / name).write_text(text, encoding="utf-8")
    (ffmpeg_dir / "BUILD-FFMPEG.sh").write_text(
        "#!/usr/bin/env bash\n", encoding="utf-8"
    )
    (ffmpeg_dir / "FFMPEG-NOTICE.txt").write_text(
        "\n".join(
            (
                f"Version: {FFMPEG_VERSION}",
                f"Commit: {FFMPEG_COMMIT}",
                f"FFmpeg source SHA-256 {FFMPEG_SOURCE_SHA256}",
                f"zlib {ZLIB_VERSION} SHA-256 {ZLIB_SOURCE_SHA256}",
                "License: LGPL",
                "Corresponding source: public archives",
            )
        ),
        encoding="utf-8",
    )
    digest = hashlib.sha256(ffmpeg_payload).hexdigest()
    (ffmpeg_dir / "BUILD-MANIFEST.txt").write_text(
        "\n".join(
            (
                "format=1",
                f"ffmpeg_version={FFMPEG_VERSION}",
                f"ffmpeg_commit={FFMPEG_COMMIT}",
                f"ffmpeg_source_sha256={FFMPEG_SOURCE_SHA256}",
                f"zlib_version={ZLIB_VERSION}",
                f"zlib_source_sha256={ZLIB_SOURCE_SHA256}",
                f"ffmpeg_exe_sha256={digest}",
                f"ffmpeg_exe_bytes={len(ffmpeg_payload)}",
                f"configure={configure}",
                "imports=KERNEL32.dll,USER32.dll",
                "toolchain=gcc",
                "build_script_git_commit=0123456789abcdef0123456789abcdef01234567",
            )
        )
        + "\n",
        encoding="utf-8",
    )
    if tamper_after_manifest:
        exe.write_bytes(ffmpeg_payload + b"tampered")
    if forbidden:
        (root / "ffprobe.exe").write_bytes(b"MZ")
    return root


class ValidateBundleTests(unittest.TestCase):
    def validate(self, bundle: Path, **kwargs: object) -> dict[str, object]:
        return pkg.validate_bundle(
            bundle, min_ffmpeg_bytes=8, min_app_bytes=8, **kwargs
        )

    def test_accepts_complete_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bundle = make_bundle(Path(temporary) / "bundle")
            report = self.validate(bundle)
            self.assertEqual(report["ffmpeg_version"], FFMPEG_VERSION)
            self.assertEqual(report["ffmpeg_commit"], FFMPEG_COMMIT)

    def test_rejects_ffmpeg_changed_after_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bundle = make_bundle(
                Path(temporary) / "bundle", tamper_after_manifest=True
            )
            with self.assertRaises(RuntimeError) as context:
                self.validate(bundle)
            self.assertIn("BUILD-MANIFEST", str(context.exception))

    def test_rejects_mismatch_with_expected_build_hash(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bundle = make_bundle(Path(temporary) / "bundle")
            with self.assertRaises(RuntimeError) as context:
                self.validate(bundle, expected_ffmpeg_sha256="0" * 64)
            self.assertIn("expected build output", str(context.exception))

    def test_accepts_matching_expected_build_hash(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bundle = make_bundle(Path(temporary) / "bundle")
            digest = hashlib.sha256(
                (bundle / "ffmpeg/ffmpeg.exe").read_bytes()
            ).hexdigest()
            self.validate(bundle, expected_ffmpeg_sha256=digest)

    def test_rejects_gpl_or_external_library_configure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bundle = make_bundle(
                Path(temporary) / "bundle",
                configure=" ".join(FFMPEG_REQUIRED_CONFIGURE) + " --enable-gpl",
            )
            with self.assertRaises(RuntimeError) as context:
                self.validate(bundle)
            self.assertIn("--enable-gpl", str(context.exception))

    def test_rejects_missing_license_material(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bundle = make_bundle(
                Path(temporary) / "bundle", omit_license="FFMPEG-GPLv3.txt"
            )
            with self.assertRaises(RuntimeError) as context:
                self.validate(bundle)
            self.assertIn("FFMPEG-GPLv3.txt", str(context.exception))

    def test_rejects_manifest_without_real_build_commit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bundle = make_bundle(Path(temporary) / "bundle")
            manifest = bundle / "ffmpeg/BUILD-MANIFEST.txt"
            manifest.write_text(
                manifest.read_text(encoding="utf-8").replace(
                    "build_script_git_commit=" + "0" * 0,
                    "build_script_git_commit=",
                ).replace(
                    "build_script_git_commit=0123456789abcdef0123456789abcdef01234567",
                    "build_script_git_commit=unknown",
                ),
                encoding="utf-8",
            )
            with self.assertRaises(RuntimeError) as context:
                self.validate(bundle)
            self.assertIn("build_script_git_commit", str(context.exception))

    def test_rejects_unused_ffprobe(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bundle = make_bundle(Path(temporary) / "bundle", forbidden=True)
            with self.assertRaises(RuntimeError) as context:
                self.validate(bundle)
            self.assertIn("ffprobe.exe", str(context.exception))

    def test_rejects_non_pe_ffmpeg(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bundle = make_bundle(
                Path(temporary) / "bundle",
                ffmpeg_payload=b"not-an-exe" * 4,
            )
            with self.assertRaises(RuntimeError) as context:
                self.validate(bundle)
            self.assertIn("not a Windows PE", str(context.exception))


class DependencyTests(unittest.TestCase):
    def test_validate_dependency_without_app(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = make_bundle(Path(temporary) / 'bundle')
            (bundle / 'bb_client.exe').unlink()
            self.assertTrue(hasattr(pkg, 'validate_ffmpeg'))
            report = pkg.validate_ffmpeg(bundle, min_ffmpeg_bytes=8)
            self.assertEqual(report['ffmpeg_sha256'], pkg.sha256_file(bundle / pkg.FFMPEG_RELATIVE))

    def test_rewritten_manifest_cannot_override_external_hash(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = make_bundle(Path(temporary) / 'bundle')
            original = pkg.sha256_file(bundle / pkg.FFMPEG_RELATIVE)
            exe = bundle / pkg.FFMPEG_RELATIVE
            exe.write_bytes(exe.read_bytes().replace(b'\0', b'X'))
            manifest = bundle / pkg.MANIFEST_RELATIVE
            manifest.write_text(manifest.read_text().replace(original, pkg.sha256_file(exe)))
            self.assertTrue(hasattr(pkg, 'validate_ffmpeg'))
            with self.assertRaisesRegex(RuntimeError, 'expected build output'):
                pkg.validate_ffmpeg(bundle, min_ffmpeg_bytes=8, expected_ffmpeg_sha256=original)


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
            self.assertIn("ffmpeg/BUILD-MANIFEST.txt", names)
            self.assertIn("ffmpeg/ZLIB-LICENSE.txt", names)
            self.assertIn("data/flutter_assets/AssetManifest.bin", names)

    def test_inspection_rejects_archive_without_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive_path = Path(temporary) / "broken.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("bb_client.exe", b"MZ")
                archive.writestr(
                    "data/flutter_assets/AssetManifest.bin", b"manifest"
                )
            with self.assertRaises(RuntimeError) as context:
                pkg.inspect_zip(archive_path, min_zip_bytes=1)
            self.assertIn("BUILD-MANIFEST.txt", str(context.exception))

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


class CleanupTests(unittest.TestCase):
    def test_remove_tree_deletes_and_tolerates_missing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "BB 测试 包"
            (target / "ffmpeg").mkdir(parents=True)
            (target / "ffmpeg" / "ffmpeg.exe").write_bytes(b"MZ")
            pkg.remove_tree(target)
            self.assertFalse(target.exists())
            pkg.remove_tree(target)


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
