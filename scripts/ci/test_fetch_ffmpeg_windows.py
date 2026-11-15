"""Unit tests for the pinned FFmpeg fetch helper (no network needed)."""

from __future__ import annotations

import hashlib
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import fetch_ffmpeg_windows as ffmpeg


def make_archive(
    path: Path,
    *,
    exe: bytes = b"MZ" + b"\0" * 64,
    license_text: bytes = b"GNU LESSER GENERAL PUBLIC LICENSE",
    with_exe: bool = True,
    with_license: bool = True,
) -> Path:
    with zipfile.ZipFile(path, "w") as archive:
        if with_exe:
            archive.writestr("ffmpeg-build/bin/ffmpeg.exe", exe)
        if with_license:
            archive.writestr("ffmpeg-build/LICENSE.txt", license_text)
        archive.writestr("ffmpeg-build/bin/ffprobe.exe", b"MZ" + b"\0" * 8)
        archive.writestr("ffmpeg-build/bin/ffplay.exe", b"MZ" + b"\0" * 8)
    return path


class FetchFfmpegTests(unittest.TestCase):
    def test_sha256_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "payload.bin"
            path.write_bytes(b"bb-ffmpeg")
            self.assertEqual(
                ffmpeg.sha256_file(path),
                hashlib.sha256(b"bb-ffmpeg").hexdigest(),
            )

    def test_download_accepts_matching_hash(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "source.bin"
            source.write_bytes(b"pinned-archive")
            destination = Path(temporary) / "copy.bin"
            digest = hashlib.sha256(b"pinned-archive").hexdigest()
            ffmpeg.download(source.as_uri(), destination, digest)
            self.assertEqual(destination.read_bytes(), b"pinned-archive")

    def test_download_rejects_bad_hash_and_removes_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "source.bin"
            source.write_bytes(b"tampered")
            destination = Path(temporary) / "copy.bin"
            with self.assertRaises(RuntimeError):
                ffmpeg.download(source.as_uri(), destination, "0" * 64)
            self.assertFalse(destination.exists())

    def test_install_copies_only_ffmpeg_license_and_notice(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = make_archive(Path(temporary) / "ffmpeg.zip")
            destination = Path(temporary) / "bundle" / "ffmpeg"
            summary = ffmpeg.install_from_archive(
                archive, destination, min_exe_bytes=4
            )
            names = {path.name for path in destination.iterdir()}
            self.assertEqual(
                names,
                {
                    "ffmpeg.exe",
                    "FFMPEG-LICENSE.txt",
                    "FFMPEG-NOTICE.txt",
                },
            )
            self.assertNotIn("ffprobe.exe", names)
            self.assertEqual(
                (destination / "ffmpeg.exe").read_bytes(),
                b"MZ" + b"\0" * 64,
            )
            self.assertEqual(summary["version"], ffmpeg.FFMPEG_VERSION)
            notice = (destination / "FFMPEG-NOTICE.txt").read_text(
                encoding="utf-8"
            )
            self.assertIn(ffmpeg.FFMPEG_VERSION, notice)
            self.assertIn(ffmpeg.FFMPEG_COMMIT, notice)
            self.assertIn(ffmpeg.FFMPEG_ASSET_SHA256, notice)
            self.assertIn(ffmpeg.FFMPEG_SOURCE_URL, notice)
            self.assertIn("LGPL", notice)
            self.assertIn("None. ffmpeg.exe is redistributed unmodified", notice)

    def test_install_rejects_missing_executable_or_license(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            missing_exe = make_archive(
                Path(temporary) / "no-exe.zip", with_exe=False
            )
            with self.assertRaises(RuntimeError):
                ffmpeg.install_from_archive(
                    missing_exe, Path(temporary) / "out", min_exe_bytes=4
                )
            missing_license = make_archive(
                Path(temporary) / "no-license.zip", with_license=False
            )
            with self.assertRaises(RuntimeError):
                ffmpeg.install_from_archive(
                    missing_license, Path(temporary) / "out2", min_exe_bytes=4
                )

    def test_install_rejects_non_pe_payload(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = make_archive(
                Path(temporary) / "bad.zip", exe=b"not a windows exe"
            )
            with self.assertRaises(RuntimeError):
                ffmpeg.install_from_archive(
                    archive, Path(temporary) / "out", min_exe_bytes=4
                )
            self.assertFalse((Path(temporary) / "out" / "ffmpeg.exe").exists())


if __name__ == "__main__":
    unittest.main()
