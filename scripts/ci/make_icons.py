"""Regenerate BB's app icons from the master logo.

Source: docs/images/logo.png (the artwork the user supplied, trimmed to its
content and padded). Run from the repo root:

    uv run --with pillow python scripts/ci/make_icons.py
"""

import sys
from pathlib import Path

from PIL import Image, ImageChops

CLIENT = Path("client")
MASTER = Path("docs/images/logo.png")

# Share of the icon edge the artwork occupies. Legacy launcher icons can sit
# close to the edge; an adaptive foreground must stay inside the 72dp safe
# circle of its 108dp canvas, so it gets a much smaller share.
LEGACY_CONTENT = 0.78
ADAPTIVE_CONTENT = 0.68

ANDROID_DENSITIES = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}
ADAPTIVE_DP = 108

WINDOWS_SIZES = [16, 24, 32, 48, 64, 128, 256]


def trim(image: Image.Image) -> Image.Image:
    """Crop the white margin so the mark fills the frame."""
    white = Image.new("RGB", image.size, (255, 255, 255))
    diff = ImageChops.difference(image, white).convert("L")
    mask = diff.point(lambda value: 255 if value > 12 else 0)
    box = mask.getbbox()
    if box is None:
        raise SystemExit("logo is blank")
    return image.crop(box)


def square(image: Image.Image, content_share: float, background) -> Image.Image:
    """Centre the artwork on a square canvas with the requested padding."""
    side = round(max(image.size) / content_share)
    canvas = Image.new("RGBA", (side, side), background)
    canvas.paste(
        image,
        ((side - image.width) // 2, (side - image.height) // 2),
        image if image.mode == "RGBA" else None,
    )
    return canvas


def main() -> int:
    if not MASTER.exists():
        raise SystemExit(f"missing master artwork: {MASTER}")
    source = trim(Image.open(MASTER).convert("RGB"))

    # Legacy Android launcher icons: white plate, mark filling most of it.
    legacy = square(source, LEGACY_CONTENT, (255, 255, 255, 255))
    for density, px in ANDROID_DENSITIES.items():
        target = CLIENT / "android/app/src/main/res" / f"mipmap-{density}"
        target.mkdir(parents=True, exist_ok=True)
        legacy.resize((px, px), Image.Resampling.LANCZOS).save(target / "ic_launcher.png")

    # Adaptive icon: transparent foreground + white background layer, so any
    # system mask (circle, squircle, teardrop) leaves the mark intact.
    adaptive = square(source, ADAPTIVE_CONTENT, (255, 255, 255, 0))
    for density, px in ANDROID_DENSITIES.items():
        side = round(px * ADAPTIVE_DP / 48)
        target = CLIENT / "android/app/src/main/res" / f"mipmap-{density}"
        adaptive.resize((side, side), Image.Resampling.LANCZOS).save(
            target / "ic_launcher_foreground.png"
        )
    anydpi = CLIENT / "android/app/src/main/res/mipmap-anydpi-v26"
    anydpi.mkdir(parents=True, exist_ok=True)
    (anydpi / "ic_launcher.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background" />\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
        "</adaptive-icon>\n",
        encoding="utf-8",
    )
    values = CLIENT / "android/app/src/main/res/values"
    values.mkdir(parents=True, exist_ok=True)
    (values / "ic_launcher_background.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<resources>\n"
        '    <color name="ic_launcher_background">#FFFFFF</color>\n'
        "</resources>\n",
        encoding="utf-8",
    )

    # Windows: one multi-size .ico for the exe and the taskbar.
    windows = square(source, LEGACY_CONTENT, (255, 255, 255, 255))
    windows.save(
        CLIENT / "windows/runner/resources/app_icon.ico",
        sizes=[(px, px) for px in WINDOWS_SIZES],
    )

    # A flat 1024 for tools that want one image, and the 512 the README uses.
    (CLIENT / "assets").mkdir(parents=True, exist_ok=True)
    square(source, LEGACY_CONTENT, (255, 255, 255, 255)).resize(
        (1024, 1024), Image.Resampling.LANCZOS
    ).save(CLIENT / "assets/icon.png")
    flat = square(source, LEGACY_CONTENT, (255, 255, 255, 255))
    flat.resize((512, 512), Image.Resampling.LANCZOS).save(
        Path("docs/images/logo-512.png")
    )
    # Ships next to the packaging scripts: CI copies only `scripts/` into the
    # packaging sandbox, so the icon cannot live under docs/ alone.
    (Path("scripts/ci/assets")).mkdir(parents=True, exist_ok=True)
    flat.resize((512, 512), Image.Resampling.LANCZOS).save(
        Path("scripts/ci/assets/icon-512.png")
    )

    print("icons regenerated")
    return 0


if __name__ == "__main__":
    sys.exit(main())
