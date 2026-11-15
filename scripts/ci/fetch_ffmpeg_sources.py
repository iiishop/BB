#!/usr/bin/env python3
"""Fetch the pinned FFmpeg and zlib sources for the Windows build.

No caching bypass: an existing archive is reused only when its SHA-256 matches
the pinned value; otherwise it is removed and fetched again. ``--ffmpeg-archive``
/ ``--zlib-archive`` still go through the same hash check before being copied
into the source directory.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import urllib.request
from pathlib import Path

from ffmpeg_pins import (
    FFMPEG_COMMIT,
    FFMPEG_SOURCE_ARCHIVE,
    FFMPEG_SOURCE_SHA256,
    FFMPEG_SOURCE_URL,
    FFMPEG_VERSION,
    ZLIB_SOURCE_ARCHIVE,
    ZLIB_SOURCE_SHA256,
    ZLIB_SOURCE_URL,
    ZLIB_VERSION,
)

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download_verified(url: str, destination: Path, expected_sha256: str) -> None:
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(
        url, headers={"User-Agent": "bb-ci-ffmpeg-sources/1"}
    )
    with urllib.request.urlopen(request) as response, destination.open(
        "wb"
    ) as handle:
        shutil.copyfileobj(response, handle, 1024 * 1024)
    actual = sha256_file(destination)
    if actual != expected_sha256:
        destination.unlink(missing_ok=True)
        raise RuntimeError(
            f"{destination.name} SHA256 mismatch: expected {expected_sha256}, "
            f"got {actual}"
        )


def ensure_archive(
    name: str,
    url: str,
    expected_sha256: str,
    destination: Path,
    *,
    local_archive: Path | None = None,
) -> dict[str, object]:
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    target = destination / name
    if local_archive is not None:
        local_archive = Path(local_archive)
        if not local_archive.is_file():
            raise RuntimeError(f"archive not found: {local_archive}")
        actual = sha256_file(local_archive)
        if actual != expected_sha256:
            raise RuntimeError(
                f"{local_archive} is not the pinned {name}: expected "
                f"{expected_sha256}, got {actual}"
            )
        shutil.copyfile(local_archive, target)
        return {"name": name, "reused": False, "sha256": actual, "url": url}
    if target.is_file():
        actual = sha256_file(target)
        if actual == expected_sha256:
            return {"name": name, "reused": True, "sha256": actual, "url": url}
        target.unlink()
    download_verified(url, target, expected_sha256)
    return {
        "name": name,
        "reused": False,
        "sha256": expected_sha256,
        "url": url,
    }


def write_sources_manifest(destination: Path) -> dict[str, object]:
    destination = Path(destination)
    entries = (
        ("ffmpeg", FFMPEG_SOURCE_ARCHIVE, FFMPEG_SOURCE_SHA256, FFMPEG_SOURCE_URL),
        ("zlib", ZLIB_SOURCE_ARCHIVE, ZLIB_SOURCE_SHA256, ZLIB_SOURCE_URL),
    )
    lines = []
    for _, archive, digest, _ in entries:
        lines.append(f"{digest}  {archive}")
    (destination / "sources.sha256").write_text(
        "\n".join(lines) + "\n", encoding="utf-8"
    )
    manifest = {
        "ffmpeg_version": FFMPEG_VERSION,
        "ffmpeg_source_archive": FFMPEG_SOURCE_ARCHIVE,
        "ffmpeg_source_sha256": FFMPEG_SOURCE_SHA256,
        "ffmpeg_source_url": FFMPEG_SOURCE_URL,
        "zlib_version": ZLIB_VERSION,
        "zlib_source_archive": ZLIB_SOURCE_ARCHIVE,
        "zlib_source_sha256": ZLIB_SOURCE_SHA256,
        "zlib_source_url": ZLIB_SOURCE_URL,
    }
    (destination / "sources.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    pins = {
        "FFMPEG_VERSION": FFMPEG_VERSION,
        "FFMPEG_COMMIT": FFMPEG_COMMIT,
        "FFMPEG_SOURCE_SHA256": FFMPEG_SOURCE_SHA256,
        "FFMPEG_SOURCE_ARCHIVE": FFMPEG_SOURCE_ARCHIVE,
        "FFMPEG_SOURCE_URL": FFMPEG_SOURCE_URL,
        "ZLIB_VERSION": ZLIB_VERSION,
        "ZLIB_SOURCE_SHA256": ZLIB_SOURCE_SHA256,
        "ZLIB_SOURCE_ARCHIVE": ZLIB_SOURCE_ARCHIVE,
        "ZLIB_SOURCE_URL": ZLIB_SOURCE_URL,
    }
    (destination / "pins.env").write_text(
        "\n".join(f"{key}={value}" for key, value in pins.items()) + "\n",
        encoding="utf-8",
    )
    return manifest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dest", default=".ffmpeg-src")
    parser.add_argument("--ffmpeg-archive", default=None)
    parser.add_argument("--zlib-archive", default=None)
    args = parser.parse_args(argv)

    destination = Path(args.dest)
    ffmpeg = ensure_archive(
        FFMPEG_SOURCE_ARCHIVE,
        FFMPEG_SOURCE_URL,
        FFMPEG_SOURCE_SHA256,
        destination,
        local_archive=Path(args.ffmpeg_archive) if args.ffmpeg_archive else None,
    )
    zlib = ensure_archive(
        ZLIB_SOURCE_ARCHIVE,
        ZLIB_SOURCE_URL,
        ZLIB_SOURCE_SHA256,
        destination,
        local_archive=Path(args.zlib_archive) if args.zlib_archive else None,
    )
    manifest = write_sources_manifest(destination)
    print(
        json.dumps(
            {"ffmpeg": ffmpeg, "zlib": zlib, "manifest": manifest},
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
