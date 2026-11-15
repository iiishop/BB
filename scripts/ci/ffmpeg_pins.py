"""Pinned sources for the self-built Windows FFmpeg.

One place for the exact FFmpeg and zlib revisions, download URLs and archive
hashes. The fetch helper, the build manifest and the package validator all
consume these values, so a source/cache change cannot silently shift versions.
"""

from __future__ import annotations

FFMPEG_VERSION = "8.1.3"
FFMPEG_COMMIT = "f1acb0a2666c78d92688f4c3d2803a132f5590f6"
FFMPEG_SOURCE_URL = (
    f"https://codeload.github.com/FFmpeg/FFmpeg/tar.gz/{FFMPEG_COMMIT}"
)
FFMPEG_SOURCE_SHA256 = (
    "3d9e59cb878618b9a334d2ce752fa6d9c6896bff39947bc3c3d299e63088f68d"
)
FFMPEG_SOURCE_ARCHIVE = "ffmpeg-src.tar.gz"
FFMPEG_SOURCE_TOP = f"FFmpeg-{FFMPEG_COMMIT}"

ZLIB_VERSION = "1.3.1"
ZLIB_SOURCE_URL = f"https://zlib.net/fossils/zlib-{ZLIB_VERSION}.tar.gz"
ZLIB_SOURCE_SHA256 = (
    "9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23"
)
ZLIB_SOURCE_ARCHIVE = "zlib-src.tar.gz"
ZLIB_SOURCE_TOP = f"zlib-{ZLIB_VERSION}"

ZLIBC_LICENSE = "zlib"
FFMPEG_LICENSE = "LGPL-2.1-or-later"

# The shipped binary may only encode PNG (cover image) and mux image2; every
# other enabled component is an internal decoder/demuxer. These rules are
# checked against the manifest before packaging, alongside the absence of
# GPL/nonfree/external-library switches.
FFMPEG_REQUIRED_CONFIGURE = (
    "--disable-autodetect",
    "--disable-network",
    "--disable-encoders",
    "--enable-encoder=png",
    "--disable-muxers",
    "--enable-muxer=image2",
    "--enable-zlib",
    "--disable-x86asm",
)
FFMPEG_FORBIDDEN_CONFIGURE = (
    "--enable-gpl",
    "--enable-nonfree",
    "--enable-lib",
)
