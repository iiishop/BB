#!/usr/bin/env python3
"""Crop the shared DEA-492 default profile cover from the approved mockup.

Source: the issue attachment `profile-layout.png`
  attachment id 01a20479-8b3e-75cf-b907-3d8307a4a1eb, 1024x1536 PNG,
  sha256 3f02992748a6cc995f8fdc498891aca9c6328326527b406188492c9f0ea5965d
Rect: x=420, y=150, w=604, h=326 (aspect 604/326 = 1.853, the phone cover band
ratio). The rect deliberately excludes the mockup's back arrow, title and
scalloped avatar, so no UI is baked into the background.

The result is committed as `client/assets/profile/default-cover.png`
(sha256 85e4f78178c812b90f453be0c9033ea49b4fd1223a84c91f70719d673edc6ba9,
422141 bytes, no re-encode). The server packages the same file; it must not be
edited on one side only.

Usage: python3 tool/crop_default_cover.py <profile-layout.png>
"""

from __future__ import annotations

import hashlib
import subprocess
import sys
from pathlib import Path

SOURCE_SHA256 = "3f02992748a6cc995f8fdc498891aca9c6328326527b406188492c9f0ea5965d"
EXPECTED_SHA256 = "85e4f78178c812b90f453be0c9033ea49b4fd1223a84c91f70719d673edc6ba9"
RECT = (420, 150, 604, 326)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: python3 tool/crop_default_cover.py <profile-layout.png>")
    source = Path(sys.argv[1])
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    if digest != SOURCE_SHA256:
        raise SystemExit(f"source hash mismatch: {digest}")
    target = Path(__file__).resolve().parent.parent / "assets/profile/default-cover.png"
    target.parent.mkdir(parents=True, exist_ok=True)
    x, y, w, h = RECT
    subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-loglevel",
            "error",
            "-i",
            str(source),
            "-vf",
            f"crop={w}:{h}:{x}:{y}",
            str(target),
        ],
        check=True,
    )
    out = hashlib.sha256(target.read_bytes()).hexdigest()
    print(target, target.stat().st_size, out)
    if out != EXPECTED_SHA256:
        raise SystemExit("crop hash mismatch; the committed default cover changed")


if __name__ == "__main__":
    main()
