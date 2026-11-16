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

# Prebuilt dependency published as a GitHub Release asset. PR jobs download it
# instead of rebuilding from pinned sources (a source build is ~528s of a
# ~860s job). Two independent values pin the same thing: the archive hash
# covers the transfer, the tree digest covers what actually lands on disk.
# verify() additionally requires the BUILD-FFMPEG.sh inside the asset to be
# byte-identical to the one in this repository, so editing the build script
# invalidates the asset and forces a source rebuild. Release builds never
# consume this asset — they compile from the pinned sources on their own.
FFMPEG_DEPS_TAG = "ffmpeg-deps-8.1.3"
FFMPEG_DEPS_ASSET = "ffmpeg-8.1.3-windows-x64.zip"
FFMPEG_DEPS_ARCHIVE_SHA256 = (
    "2fe37cc1758f9b4131ec7f01fc56d4dd82fd8109d72d6b9d3508c2254f37f1a4"
)
FFMPEG_DEPS_TREE_DIGEST = (
    "7f3c3b07ff92739f4f890c042137092db2849de4dac159b53e71c0e620d18222"
)

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
