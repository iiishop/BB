#!/usr/bin/env python3
"""Fetch and verify the pinned FFmpeg Windows runtime for BB.

Only ``ffmpeg.exe`` is bundled: the client invokes it as a separate process for
video-cover extraction and never calls ``ffprobe``/``ffplay``. The pinned build
is BtbN's win64 **LGPL** static build (no GPL-only components); its exact
version, release tag, archive hash, source commit and license are recorded in
``FFMPEG-NOTICE.txt`` next to the binary.

Usage:
  python scripts/ci/fetch_ffmpeg_windows.py --dest client/windows/ffmpeg
  python scripts/ci/fetch_ffmpeg_windows.py --archive /path/to/pinned.zip \
      --dest client/windows/ffmpeg

The archive hash is always verified, including for ``--archive`` input.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

FFMPEG_VERSION = "n8.1.3-35-gf1acb0a266"
FFMPEG_RELEASE_BRANCH = "release/8.1"
FFMPEG_COMMIT = "f1acb0a2666c78d92688f4c3d2803a132f5590f6"
FFMPEG_BUILD_TAG = "autobuild-2026-11-15-12-40"
FFMPEG_ASSET = "ffmpeg-n8.1.3-35-gf1acb0a266-win64-lgpl-8.1.zip"
FFMPEG_ASSET_SHA256 = (
    "272140baa96cbb9553eb57c03590e0b8d2c93ce352aa7f876c34fbc657536836"
)
FFMPEG_ASSET_URL = (
    "https://github.com/FFmpeg-Builds/FFmpeg-Builds/releases/download/"
    f"{FFMPEG_BUILD_TAG}/{FFMPEG_ASSET}"
)
FFMPEG_SOURCE_URL = f"https://github.com/FFmpeg/FFmpeg/tree/{FFMPEG_COMMIT}"
FFMPEG_BUILD_SCRIPTS_URL = (
    "https://github.com/FFmpeg-Builds/FFmpeg-Builds/tree/" + FFMPEG_BUILD_TAG
)
MIN_FFMPEG_BYTES = 90 * 1024 * 1024


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(url: str, destination: Path, expected_sha256: str) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(
        url, headers={"User-Agent": "bb-ci-ffmpeg-fetch/1"}
    )
    with urllib.request.urlopen(request) as response, destination.open(
        "wb"
    ) as handle:
        shutil.copyfileobj(response, handle, 1024 * 1024)
    actual = sha256_file(destination)
    if actual != expected_sha256:
        destination.unlink(missing_ok=True)
        raise RuntimeError(
            "FFmpeg archive SHA256 mismatch: "
            f"expected {expected_sha256}, got {actual}"
        )


def notice_text() -> str:
    return f"""FFmpeg — bundled Windows runtime
=================================

Version: {FFMPEG_VERSION} (FFmpeg {FFMPEG_RELEASE_BRANCH}, commit
{FFMPEG_COMMIT})
Build: BtbN/FFmpeg-Builds LGPL win64 static build, release tag
{FFMPEG_BUILD_TAG}
Asset: {FFMPEG_ASSET}
Asset SHA-256: {FFMPEG_ASSET_SHA256}

License
-------
GNU Lesser General Public License, version 3. The full license text that
accompanies this build is in FFMPEG-LICENSE.txt next to this notice. The build
is the `win64-lgpl` variant: FFmpeg is compiled without GPL-only components and
is distributed under the LGPL. FFmpeg itself is also available upstream under
LGPL-2.1-or-later.

Modifications
-------------
None. ffmpeg.exe is redistributed unmodified from the pinned archive above.

Source code and build configuration
-----------------------------------
FFmpeg source for the exact revision:
{FFMPEG_SOURCE_URL}
FFmpeg release branch:
https://github.com/FFmpeg/FFmpeg/tree/{FFMPEG_RELEASE_BRANCH}
Build scripts, configuration and archive for this exact build:
{FFMPEG_BUILD_SCRIPTS_URL}
Archive download:
{FFMPEG_ASSET_URL}

How the BB client uses it
-------------------------
The executable is invoked as a separate process, only to extract one video
frame for the attachment cover. It is not linked into the application and
nothing is executed from user-supplied file contents beyond decoding. Deleting
the application folder removes this bundled executable with the application.
"""


def install_from_archive(
    archive: Path,
    destination: Path,
    *,
    min_exe_bytes: int = MIN_FFMPEG_BYTES,
) -> dict[str, object]:
    """Stage ffmpeg.exe + license + notice from a pinned build archive."""
    archive = Path(archive)
    if not archive.is_file():
        raise RuntimeError(f"FFmpeg archive not found: {archive}")
    with zipfile.ZipFile(archive) as bundle:
        names = bundle.namelist()
        executables = [n for n in names if n.endswith("/bin/ffmpeg.exe")]
        licenses = [
            n
            for n in names
            if n.count("/") == 1 and n.endswith("/LICENSE.txt")
        ]
        if len(executables) != 1:
            raise RuntimeError(
                "expected exactly one bin/ffmpeg.exe in the FFmpeg archive, "
                f"found {executables}"
            )
        if not licenses:
            raise RuntimeError("FFmpeg archive has no LICENSE.txt")
        destination = Path(destination)
        destination.mkdir(parents=True, exist_ok=True)
        target = destination / "ffmpeg.exe"
        with bundle.open(executables[0]) as source, target.open("wb") as out:
            shutil.copyfileobj(source, out, 1024 * 1024)
        (destination / "FFMPEG-LICENSE.txt").write_bytes(
            bundle.read(licenses[0])
        )
    payload = target.read_bytes()
    if len(payload) < min_exe_bytes:
        target.unlink(missing_ok=True)
        raise RuntimeError(
            f"ffmpeg.exe is only {len(payload)} bytes; the archive looks wrong"
        )
    if payload[:2] != b"MZ":
        target.unlink(missing_ok=True)
        raise RuntimeError("ffmpeg.exe is not a Windows PE executable")
    (destination / "FFMPEG-NOTICE.txt").write_text(
        notice_text(), encoding="utf-8"
    )
    return {
        "version": FFMPEG_VERSION,
        "build_tag": FFMPEG_BUILD_TAG,
        "asset": FFMPEG_ASSET,
        "asset_sha256": FFMPEG_ASSET_SHA256,
        "ffmpeg_sha256": sha256_file(target),
        "ffmpeg_bytes": len(payload),
        "license": "LGPL-3.0 (win64-lgpl build)",
        "destination": str(destination),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--dest",
        default="client/windows/ffmpeg",
        help="staging directory for ffmpeg.exe + license/notice",
    )
    parser.add_argument(
        "--archive",
        help="use this already downloaded pinned archive instead of network",
    )
    parser.add_argument(
        "--work-dir",
        default=None,
        help="download cache directory (default: temporary)",
    )
    parser.add_argument(
        "--force", action="store_true", help="reinstall even if present"
    )
    args = parser.parse_args(argv)

    destination = Path(args.dest)
    if (destination / "ffmpeg.exe").exists() and not args.force:
        print(f"FFmpeg already staged in {destination} (use --force to refresh)")
        return 0

    with tempfile.TemporaryDirectory() as temporary:
        work = Path(args.work_dir) if args.work_dir else Path(temporary)
        work.mkdir(parents=True, exist_ok=True)
        archive = Path(args.archive) if args.archive else work / FFMPEG_ASSET
        if not args.archive:
            print(f"Downloading {FFMPEG_ASSET_URL}")
            download(FFMPEG_ASSET_URL, archive, FFMPEG_ASSET_SHA256)
        elif sha256_file(archive) != FFMPEG_ASSET_SHA256:
            raise RuntimeError(
                f"{archive} is not the pinned FFmpeg archive "
                f"(expected SHA-256 {FFMPEG_ASSET_SHA256})"
            )
        summary = install_from_archive(archive, destination)

    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
