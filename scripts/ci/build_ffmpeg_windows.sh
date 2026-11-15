#!/usr/bin/env bash
# Build the minimal, self-contained Windows FFmpeg shipped inside the BB
# package. Sources are pinned and hash-verified by fetch_ffmpeg_sources.py; this
# script always rebuilds into a fresh destination directory (no stale staging
# reuse) and records a BUILD-MANIFEST.txt that the package validator checks.
#
# Only internal FFmpeg decoders/demuxers are enabled (no external libraries,
# no GPL/nonfree components) plus the PNG encoder/image2 muxer needed for the
# cover frame. zlib is the only external dependency and is built statically from
# a pinned source tarball; its license text is shipped.
#
# Usage (MSYS2 MINGW64 shell):
#   bash scripts/ci/build_ffmpeg_windows.sh \
#     --sources .ffmpeg-src --dest client/windows/ffmpeg
#
# Local cross-check (not used by CI):
#   CROSS_PREFIX=x86_64-w64-mingw32- bash scripts/ci/build_ffmpeg_windows.sh ...
set -euo pipefail

SOURCES=".ffmpeg-src"
DEST="client/windows/ffmpeg"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
CROSS_PREFIX="${CROSS_PREFIX:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sources) SOURCES="${2:-}"; shift 2 ;;
    --dest) DEST="${2:-}"; shift 2 ;;
    --jobs) JOBS="${2:-}"; shift 2 ;;
    *) echo "ERROR: 未知参数 $1" >&2; exit 1 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -d "$SOURCES" ]] || die "source directory not found: $SOURCES (run fetch_ffmpeg_sources.py)"
SOURCES="$(cd "$SOURCES" && pwd -P)"
[[ -f "$SOURCES/sources.sha256" ]] || die "missing $SOURCES/sources.sha256"
[[ -f "$SOURCES/pins.env" ]] || die "missing $SOURCES/pins.env"

# shellcheck disable=SC1091
source "$SOURCES/pins.env"

echo "Verifying pinned source archives"
(cd "$SOURCES" && sha256sum -c sources.sha256)

CC="${CROSS_PREFIX}gcc"
AR="${CROSS_PREFIX}ar"
OBJDUMP="${CROSS_PREFIX}objdump"
command -v "$CC" >/dev/null 2>&1 || die "compiler not found: $CC"
command -v "$AR" >/dev/null 2>&1 || die "ar not found: $AR"
command -v "$OBJDUMP" >/dev/null 2>&1 || die "objdump not found: $OBJDUMP"

WORK="${WORK_DIR:-build/ffmpeg-build}"
rm -rf -- "$WORK"
mkdir -p -- "$WORK/zlib-build" "$WORK/zlib-prefix/include" "$WORK/zlib-prefix/lib" "$WORK/ffmpeg-prefix"
WORK="$(cd "$WORK" && pwd -P)"

tar -C "$WORK" -xzf "$SOURCES/ffmpeg-src.tar.gz"
tar -C "$WORK" -xzf "$SOURCES/zlib-src.tar.gz"
FFMPEG_SRC="$(find "$WORK" -maxdepth 1 -type d -name 'FFmpeg-*' | head -1)"
ZLIB_SRC="$(find "$WORK" -maxdepth 1 -type d -name 'zlib-*' | head -1)"
[[ -n "$FFMPEG_SRC" && -d "$FFMPEG_SRC" ]] || die "FFmpeg source not extracted"
[[ -n "$ZLIB_SRC" && -d "$ZLIB_SRC" ]] || die "zlib source not extracted"

echo "Building static zlib from pinned source"
(
  cd "$ZLIB_SRC"
  for source in adler32 compress crc32 deflate gzclose gzlib gzread gzwrite \
    infback inffast inflate inftrees trees uncompr zutil; do
    "$CC" -O2 -I. -c "$source.c" -o "$WORK/zlib-build/$source.o"
  done
  "$AR" rcs "$WORK/zlib-prefix/lib/libz.a" "$WORK"/zlib-build/*.o
  cp zlib.h zconf.h "$WORK/zlib-prefix/include/"
)

# Native MinGW tools on Windows need Windows-style paths in -I/-L/--prefix;
# cygpath is only present in MSYS2 (the local Linux cross-check lacks it).
if command -v cygpath >/dev/null 2>&1; then
  ZLIB_PREFIX_NATIVE="$(cygpath -m "$WORK/zlib-prefix")"
  FFMPEG_PREFIX_NATIVE="$(cygpath -m "$WORK/ffmpeg-prefix")"
else
  ZLIB_PREFIX_NATIVE="$WORK/zlib-prefix"
  FFMPEG_PREFIX_NATIVE="$WORK/ffmpeg-prefix"
fi

CONFIGURE_FLAGS=(
  --prefix="$FFMPEG_PREFIX_NATIVE"
  --target-os=mingw32
  --arch=x86_64
  --disable-autodetect
  --disable-network
  --disable-doc
  --disable-debug
  --disable-ffplay
  --disable-ffprobe
  --disable-encoders
  --enable-encoder=png
  --disable-muxers
  --enable-muxer=image2
  --enable-zlib
  --enable-static
  --disable-shared
  --disable-x86asm
  --enable-w32threads
  --disable-pthreads
  "--extra-cflags=-O2 -I$ZLIB_PREFIX_NATIVE/include"
  "--extra-ldflags=-static -L$ZLIB_PREFIX_NATIVE/lib"
  --extra-ldexeflags=-static
)
if [[ -n "$CROSS_PREFIX" ]]; then
  CONFIGURE_FLAGS+=(--enable-cross-compile "--cross-prefix=$CROSS_PREFIX")
fi

echo "Configuring FFmpeg"
(
  cd "$FFMPEG_SRC"
  ./configure "${CONFIGURE_FLAGS[@]}"
)

echo "Building FFmpeg with $JOBS jobs"
(
  cd "$FFMPEG_SRC"
  make -j"$JOBS"
)

FFMPEG_EXE="$FFMPEG_SRC/ffmpeg.exe"
[[ -f "$FFMPEG_EXE" ]] || die "ffmpeg.exe was not produced"

mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd -P)"
# Always replace the staging directory contents so a stale/tampered tree cannot
# survive a rebuild.
rm -f -- "$DEST"/ffmpeg.exe "$DEST"/FFMPEG-LICENSE.txt "$DEST"/FFMPEG-LGPLv3.txt \
  "$DEST"/FFMPEG-GPLv3.txt "$DEST"/ZLIB-LICENSE.txt "$DEST"/FFMPEG-NOTICE.txt \
  "$DEST"/BUILD-MANIFEST.txt
install -m 0755 "$FFMPEG_EXE" "$DEST/ffmpeg.exe"
cp "$FFMPEG_SRC/COPYING.LGPLv2.1" "$DEST/FFMPEG-LICENSE.txt"
cp "$FFMPEG_SRC/COPYING.LGPLv3" "$DEST/FFMPEG-LGPLv3.txt"
cp "$FFMPEG_SRC/COPYING.GPLv3" "$DEST/FFMPEG-GPLv3.txt"
cp "$ZLIB_SRC/LICENSE" "$DEST/ZLIB-LICENSE.txt"

FFMPEG_VERSION="$(cat "$FFMPEG_SRC/RELEASE" 2>/dev/null || echo unknown)"
CONFIGURE_LINE="${CONFIGURE_FLAGS[*]}"
VERSION_LINE=""
if "$DEST/ffmpeg.exe" -version >"$WORK/version.txt" 2>/dev/null; then
  VERSION_LINE="$(head -1 "$WORK/version.txt")"
fi
[[ -n "$VERSION_LINE" ]] || VERSION_LINE="ffmpeg version $FFMPEG_VERSION (not executed on this host)"

"$OBJDUMP" -p "$DEST/ffmpeg.exe" \
  | awk '/DLL Name/ {print $3}' | sort -u > "$WORK/imports.txt"
if grep -Eiq 'libwinpthread|libgcc|libstdc|zlib1|avcodec|avformat|avutil|swscale|swresample|ffmpeg-' "$WORK/imports.txt"; then
  die "ffmpeg.exe imports a non-system/non-static dependency: $(cat "$WORK/imports.txt")"
fi
IMPORTS="$(paste -sd, "$WORK/imports.txt")"
EXE_SHA256="$(sha256sum "$DEST/ffmpeg.exe" | cut -d' ' -f1)"
EXE_BYTES="$(stat -c %s "$DEST/ffmpeg.exe")"
GIT_COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
TOOLCHAIN="$("$CC" --version | head -1)"

cat > "$DEST/BUILD-MANIFEST.txt" <<EOF
format=1
ffmpeg_version=$FFMPEG_VERSION
ffmpeg_commit=$FFMPEG_COMMIT
ffmpeg_source_sha256=$FFMPEG_SOURCE_SHA256
zlib_version=$ZLIB_VERSION
zlib_source_sha256=$ZLIB_SOURCE_SHA256
ffmpeg_exe_sha256=$EXE_SHA256
ffmpeg_exe_bytes=$EXE_BYTES
configure=$CONFIGURE_LINE
imports=$IMPORTS
toolchain=$TOOLCHAIN
version_line=$VERSION_LINE
build_script_git_commit=$GIT_COMMIT
EOF

cat > "$DEST/FFMPEG-NOTICE.txt" <<EOF
FFmpeg — bundled Windows runtime (self-built, minimal)
======================================================

Version: $FFMPEG_VERSION (FFmpeg commit $FFMPEG_COMMIT)
Binary: ffmpeg.exe, SHA-256 $EXE_SHA256, $EXE_BYTES bytes
Build: self-built from the pinned sources below with MinGW-w64; no source
patches or modifications were applied to FFmpeg or zlib.

License
-------
FFmpeg is licensed under the GNU Lesser General Public License, version 2.1 or
later. This build is configured WITHOUT --enable-gpl and WITHOUT
--enable-nonfree, and it does not enable any external library except zlib.
The full LGPL-2.1 text is in FFMPEG-LICENSE.txt. As additional reference the
LGPLv3 and GPLv3 texts shipped by the FFmpeg project are included as
FFMPEG-LGPLv3.txt and FFMPEG-GPLv3.txt.

zlib (version $ZLIB_VERSION) is statically linked only to provide PNG compression.
Its license text is in ZLIB-LICENSE.txt.

Corresponding source / build configuration
------------------------------------------
FFmpeg source archive (SHA-256 $FFMPEG_SOURCE_SHA256):
$FFMPEG_SOURCE_URL
FFmpeg repository/commit:
https://github.com/FFmpeg/FFmpeg/tree/$FFMPEG_COMMIT
zlib source archive (SHA-256 $ZLIB_SOURCE_SHA256):
$ZLIB_SOURCE_URL

Exact configure flags are recorded in BUILD-MANIFEST.txt (configure=...) and are
produced by scripts/ci/build_ffmpeg_windows.sh in the BB repository at commit
$GIT_COMMIT. That script plus the pinned archives provide the complete
corresponding source and build configuration. No written request is required;
the sources remain publicly available at the URLs above.

How the BB client uses it
-------------------------
ffmpeg.exe is invoked as a separate process, only to extract one video frame
for an attachment cover. Nothing is linked into the app, no user-supplied
content is executed beyond video decoding, and deleting the application folder
removes this executable with the application.
EOF

echo "Built $DEST/ffmpeg.exe ($EXE_BYTES bytes, sha256 $EXE_SHA256)"
echo "Imports: $IMPORTS"
