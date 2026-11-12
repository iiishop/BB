#!/usr/bin/env bash
# 把 Flutter Linux release bundle 打成 Arch 包（.pkg.tar.zst）。
#
# 用法：
#   bash scripts/ci/package-arch.sh \
#     --bundle client/build/linux/x64/release/bundle \
#     --out dist --version 0.2.0 [--bin bb_mobile] [--pkg bb] [--pkgrel 1]
#
# 说明：
#   · 这是「本地/CI 直接产出的二进制包」，不是 AUR 提交物。AUR 只收 PKGBUILD 文本，
#     要上 AUR 得把它单独推到 aur.archlinux.org，见 docs/CI-CD.md。
#   · Flutter 的 .so 不能被 strip 坏，所以 options 里关掉 strip/debug。
#   · 需要在 Arch 环境跑（makepkg + fakeroot）。CI 里用 archlinux 容器。
set -euo pipefail

BUNDLE=""
OUT="dist"
VERSION=""
BIN_NAME="bb_mobile"
PKG="bb"
PKGREL="1"
DESC="BB private social platform client"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) BUNDLE="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --bin) BIN_NAME="${2:-}"; shift 2 ;;
    --pkg) PKG="${2:-}"; shift 2 ;;
    --pkgrel) PKGREL="${2:-}"; shift 2 ;;
    *) echo "ERROR: 未知参数 $1" >&2; exit 1 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -n "$BUNDLE" ]] || die "缺少 --bundle"
[[ -n "$VERSION" ]] || die "缺少 --version"
[[ -d "$BUNDLE" ]] || die "bundle 目录不存在: $BUNDLE"
[[ -x "$BUNDLE/$BIN_NAME" ]] || die "bundle 里没有可执行文件: $BUNDLE/$BIN_NAME"
command -v makepkg >/dev/null 2>&1 || die "缺少 makepkg（需要在 Arch 环境）"

BUNDLE="$(cd -- "$BUNDLE" && pwd -P)"
mkdir -p -- "$OUT"
OUT="$(cd -- "$OUT" && pwd -P)"

case "$(uname -m)" in
  x86_64) PKGARCH="x86_64" ;;
  aarch64) PKGARCH="aarch64" ;;
  *) die "不支持的架构: $(uname -m)" ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
BUILD="$WORK/build"
install -d "$BUILD"

cat > "$BUILD/PKGBUILD" <<EOF
pkgname=${PKG}-bin
pkgver=${VERSION//-/_}
pkgrel=${PKGREL}
pkgdesc="${DESC}"
arch=('${PKGARCH}')
url="https://github.com/iiishop/BB"
license=('MIT')
depends=('gtk3' 'blkid' 'xz' 'gcc-libs')
options=('!strip' '!debug' '!emptydirs')
_bundle='${BUNDLE}'
_bin='${BIN_NAME}'

package() {
  install -d "\$pkgdir/opt/${PKG}" "\$pkgdir/usr/bin" "\$pkgdir/usr/share/applications"
  cp -a "\$_bundle/." "\$pkgdir/opt/${PKG}/"
  ln -sfn "/opt/${PKG}/\$_bin" "\$pkgdir/usr/bin/${PKG}"
  cat > "\$pkgdir/usr/share/applications/${PKG}.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=BB
Comment=${DESC}
Exec=/opt/${PKG}/\$_bin
Terminal=false
Categories=Network;Chat;
DESKTOP
  chmod 0644 "\$pkgdir/usr/share/applications/${PKG}.desktop"
}
EOF

# --nodeps：CI 里已经装好依赖，别让 makepkg 再去解析仓库
( cd "$BUILD" && makepkg --nodeps --noconfirm -f -C --log >"$WORK/makepkg.log" 2>&1 ) || {
  echo "---- makepkg 输出 ----" >&2; tail -40 "$WORK/makepkg.log" >&2; die "makepkg 失败"; }

BUILT="$(find "$BUILD" -maxdepth 1 -name '*.pkg.tar.zst' -type f | head -1)"
[[ -n "$BUILT" ]] || die "makepkg 没有产出 .pkg.tar.zst"
cp -a "$BUILT" "$OUT/"
echo "OK arch pkg: $OUT/$(basename "$BUILT")"
