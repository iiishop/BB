"""Unit tests for the pinned-source fetch helper (no network needed)."""

from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import fetch_ffmpeg_sources as fetch
from ffmpeg_pins import (
    FFMPEG_SOURCE_ARCHIVE,
    FFMPEG_SOURCE_SHA256,
    ZLIB_SOURCE_ARCHIVE,
    ZLIB_SOURCE_SHA256,
)


class ShaTests(unittest.TestCase):
    def test_sha256_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "payload.bin"
            path.write_bytes(b"bb-ffmpeg")
            self.assertEqual(
                fetch.sha256_file(path),
                hashlib.sha256(b"bb-ffmpeg").hexdigest(),
            )


class DownloadTests(unittest.TestCase):
    def test_download_accepts_matching_hash(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "source.bin"
            source.write_bytes(b"pinned-archive")
            destination = Path(temporary) / "copy.bin"
            digest = hashlib.sha256(b"pinned-archive").hexdigest()
            fetch.download_verified(source.as_uri(), destination, digest)
            self.assertEqual(destination.read_bytes(), b"pinned-archive")

    def test_download_rejects_bad_hash_and_removes_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "source.bin"
            source.write_bytes(b"tampered")
            destination = Path(temporary) / "copy.bin"
            with self.assertRaises(RuntimeError):
                fetch.download_verified(source.as_uri(), destination, "0" * 64)
            self.assertFalse(destination.exists())


class EnsureArchiveTests(unittest.TestCase):
    def test_matching_archive_is_reused_without_network(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary)
            target = destination / "ffmpeg-src.tar.gz"
            target.write_bytes(b"cached-source")
            digest = hashlib.sha256(b"cached-source").hexdigest()
            result = fetch.ensure_archive(
                "ffmpeg-src.tar.gz",
                "http://invalid.example/should-not-be-used",
                digest,
                destination,
            )
            self.assertTrue(result["reused"])
            self.assertEqual(result["sha256"], digest)

    def test_tampered_cache_is_replaced_from_verified_local_archive(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            destination = root / "sources"
            cache = destination / "ffmpeg-src.tar.gz"
            cache.parent.mkdir(parents=True)
            cache.write_bytes(b"tampered-cache")
            good = root / "good.tar.gz"
            good.write_bytes(b"good-source")
            digest = hashlib.sha256(b"good-source").hexdigest()
            result = fetch.ensure_archive(
                "ffmpeg-src.tar.gz",
                "http://invalid.example/unused",
                digest,
                destination,
                local_archive=good,
            )
            self.assertFalse(result["reused"])
            self.assertEqual(cache.read_bytes(), b"good-source")

    def test_local_archive_hash_is_enforced(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bad = root / "bad.tar.gz"
            bad.write_bytes(b"not-the-pin")
            with self.assertRaises(RuntimeError):
                fetch.ensure_archive(
                    "ffmpeg-src.tar.gz",
                    "http://invalid.example/unused",
                    "0" * 64,
                    root / "dest",
                    local_archive=bad,
                )


class ManifestTests(unittest.TestCase):
    def test_writes_pinned_sources_and_pins_env(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary)
            fetch.write_sources_manifest(destination)
            sums = (destination / "sources.sha256").read_text(
                encoding="utf-8"
            ).splitlines()
            self.assertIn(f"{FFMPEG_SOURCE_SHA256}  {FFMPEG_SOURCE_ARCHIVE}", sums)
            self.assertIn(f"{ZLIB_SOURCE_SHA256}  {ZLIB_SOURCE_ARCHIVE}", sums)
            pins = (destination / "pins.env").read_text(encoding="utf-8")
            self.assertIn(f"FFMPEG_SOURCE_SHA256={FFMPEG_SOURCE_SHA256}", pins)
            self.assertIn(f"ZLIB_SOURCE_SHA256={ZLIB_SOURCE_SHA256}", pins)
            manifest = json.loads(
                (destination / "sources.json").read_text(encoding="utf-8")
            )
            self.assertEqual(manifest["ffmpeg_source_sha256"], FFMPEG_SOURCE_SHA256)
            self.assertEqual(manifest["zlib_source_sha256"], ZLIB_SOURCE_SHA256)


if __name__ == "__main__":
    unittest.main()
