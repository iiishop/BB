#!/usr/bin/env python3
"""Generate the synthetic avatar used by the DEA-492 phone Profile screenshots.

The image is deliberately asymmetric (an upward marker at the top, a face with
eyes and a mouth) so a rotated or mirrored render is obvious when the scalloped
rim is swept around the photo. It is test-only art, not a product asset and not
a copy of any reference image.

Run: python3 tool/generate_profile_fixture.py
Out: test/fixtures/avatars/sample-photo.png
"""

from __future__ import annotations

import math
import struct
import zlib
from pathlib import Path

SIZE = 250


def blend(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))  # type: ignore[return-value]


def inside_circle(x: int, y: int, cx: float, cy: float, radius: float) -> bool:
    return (x - cx) ** 2 + (y - cy) ** 2 <= radius * radius


def build() -> bytearray:
    pixels = bytearray()
    sky_top = (26, 34, 56)
    sky_bottom = (32, 92, 88)
    face = (241, 235, 221)
    hair = (24, 30, 44)
    skin = (232, 196, 168)
    eye = (24, 30, 44)
    marker = (226, 122, 74)
    bar = (14, 111, 104)

    for y in range(SIZE):
        pixels.append(0)  # PNG filter: none
        for x in range(SIZE):
            color = blend(sky_top, sky_bottom, y / (SIZE - 1))
            # shoulders
            if y > 196 and inside_circle(x, y, 125, 300, 128):
                color = hair
            # face
            if inside_circle(x, y, 125, 136, 84):
                color = skin
            # hair fringe: only the upper part of the head
            if inside_circle(x, y, 125, 122, 88) and (y < 112 or abs(x - 125) > 62):
                color = hair
            # eyes
            if inside_circle(x, y, 98, 138, 8) or inside_circle(x, y, 152, 138, 8):
                color = eye
            # mouth: a short horizontal line, clearly below the eyes
            if 110 <= x <= 140 and 168 <= y <= 172:
                color = eye
            # nose, pointing up towards the marker
            if abs(x - 125) <= 3 and 148 <= y <= 162:
                color = (196, 154, 124)
            # upward marker at the top edge
            if 106 <= x <= 144 and 8 <= y <= 34:
                if abs(x - 125) <= (y - 8) * 1.2:
                    color = marker
            # bottom bar
            if y >= 244:
                color = bar
            # soft vignette so the photo looks like a photo, not flat vector
            distance = math.hypot(x - 125, y - 125) / 176
            if distance > 0.72:
                shade = min(1.0, (distance - 0.72) / 0.28) * 0.35
                color = blend(color, (8, 12, 20), shade)
            pixels.extend((*color, 255))
    return pixels


def png_bytes(pixels: bytearray) -> bytes:
    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(bytes(pixels), 9))
        + chunk(b"IEND", b"")
    )


def main() -> None:
    target = Path(__file__).resolve().parent.parent / "test/fixtures/avatars/sample-photo.png"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(png_bytes(build()))
    print(target)


if __name__ == "__main__":
    main()
