#!/usr/bin/env bash
# 把 Flutter Linux release bundle 打成 deb / rpm。
#
# 用法：
#   bash scripts/ci/package-linux.sh \
#     --bundle client/build/linux/x64/release/bundle \
#     --out dist --version 0.2.0 [--bin bb_mobile] [--pkg bb] [--rpm]
#
# 只做打包，不负责编译。bundle 必须是 `flutter build linux --release` 的产物目录，
# 里面要有可执行文件（默认 bb_mobile）、lib/ 和 data/。
# 退出码：0 = 请求的格式全部产出；1 = 校验失败或打包失败。
set -euo pipefail

BUNDLE=""
OUT="dist"
VERSION=""
BIN_NAME="bb_mobile"
PKG="bb"
PRETTY="BB"
SUMMARY="BB private social platform client"
WITH_RPM=0
WITH_DEB=0
MAINTAINER="iiishop <iiishop@163.com>"
HOMEPAGE="https://github.com/iiishop/BB"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) BUNDLE="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --bin) BIN_NAME="${2:-}"; shift 2 ;;
    --pkg) PKG="${2:-}"; shift 2 ;;
    --deb) WITH_DEB=1; shift ;;
    --rpm) WITH_RPM=1; shift ;;
    *) echo "ERROR: 未知参数 $1" >&2; exit 1 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -n "$BUNDLE" ]] || die "缺少 --bundle"
[[ -n "$VERSION" ]] || die "缺少 --version"
[[ -d "$BUNDLE" ]] || die "bundle 目录不存在: $BUNDLE"
[[ -x "$BUNDLE/$BIN_NAME" ]] || die "bundle 里没有可执行文件: $BUNDLE/$BIN_NAME"

BUNDLE="$(cd -- "$BUNDLE" && pwd -P)"
mkdir -p -- "$OUT"
OUT="$(cd -- "$OUT" && pwd -P)"

# dpkg 用 amd64/arm64；rpm 用 x86_64/aarch64。同一个 bundle 只能对应一种。
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  x86_64)  DEB_ARCH="amd64"; RPM_ARCH="x86_64" ;;
  aarch64) DEB_ARCH="arm64"; RPM_ARCH="aarch64" ;;
  *) die "不支持的架构: $HOST_ARCH" ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

payload() {
  # $1 = 安装树根目录；把 bundle 铺进 /opt/<pkg>，并生成 /usr/bin 入口 + desktop 文件
  local root="$1"
  install -d "$root/opt/$PKG" "$root/usr/bin" "$root/usr/share/applications"
  cp -a "$BUNDLE/." "$root/opt/$PKG/"
  ln -sfn "../../opt/$PKG/$BIN_NAME" "$root/usr/bin/$PKG"
  cat > "$root/usr/share/applications/$PKG.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$PRETTY
Comment=$SUMMARY
Exec=/opt/$PKG/$BIN_NAME
Terminal=false
Categories=Network;Chat;
EOF
}

# ── 选格式 ──────────────────────────────────────────────────────────────
# 不带参数时按本机可用的工具自动决定；显式 --deb/--rpm 则工具缺失直接报错，
# 免得"以为打了 rpm，其实静默跳过"。
if [[ "$WITH_DEB" == 0 && "$WITH_RPM" == 0 ]]; then
  command -v dpkg-deb >/dev/null 2>&1 && WITH_DEB=1
  command -v rpmbuild >/dev/null 2>&1 && WITH_RPM=1
  [[ "$WITH_DEB$WITH_RPM" != "00" ]] || die "本机既没有 dpkg-deb 也没有 rpmbuild"
fi

# ── deb ────────────────────────────────────────────────────────────────
if [[ "$WITH_DEB" == 1 ]]; then
  command -v dpkg-deb >/dev/null 2>&1 || die "缺少 dpkg-deb"
  ROOT="$WORK/deb/$PKG"
  payload "$ROOT"
  install -d "$ROOT/DEBIAN"
  SIZE="$(du -sk --apparent-size "$ROOT" | cut -f1)"
  cat > "$ROOT/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION
Section: net
Priority: optional
Architecture: $DEB_ARCH
Installed-Size: $SIZE
Maintainer: $MAINTAINER
Homepage: $HOMEPAGE
Depends: libgtk-3-0, libblkid1, liblzma5, libstdc++6
Description: $SUMMARY
 Flutter 桌面客户端。装完用 $PKG 启动。
EOF
  DEB_FILE="$OUT/${PKG}_${VERSION}_${DEB_ARCH}.deb"
  dpkg-deb --root-owner-group -Zxz --build "$ROOT" "$DEB_FILE" >/dev/null
  echo "OK deb: $DEB_FILE"
fi

# ── rpm ────────────────────────────────────────────────────────────────
if [[ "$WITH_RPM" == 1 ]]; then
  command -v rpmbuild >/dev/null 2>&1 || die "缺少 rpmbuild（Arch: paru -S rpm-tools；Ubuntu: apt-get install rpm）"
  TOP="$WORK/rpm"
  install -d "$TOP"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
  # 用 tar 传 payload，避免 spec 里写绝对路径
  install -d "$WORK/rpmroot"
  payload "$WORK/rpmroot/${PKG}-${VERSION}"
  tar -C "$WORK/rpmroot" -czf "$TOP/SOURCES/$PKG-$VERSION.tar.gz" "$PKG-$VERSION"
  cat > "$TOP/SPECS/$PKG.spec" <<EOF
%global debug_package %{nil}
Name:           $PKG
Version:        $VERSION
Release:        1
Summary:        $SUMMARY
License:        MIT
URL:            $HOMEPAGE
Source0:        %{name}-%{version}.tar.gz
BuildArch:      $RPM_ARCH
Requires:       gtk3
Requires:       libblkid
Requires:       xz-libs
Requires:       libstdc++
AutoReqProv:    no

%description
Flutter 桌面客户端。装完用 $PKG 启动。

%prep
%setup -q

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
cp -a opt %{buildroot}/opt
mkdir -p %{buildroot}/usr/bin %{buildroot}/usr/share/applications
ln -sfn ../../opt/$PKG/$BIN_NAME %{buildroot}/usr/bin/$PKG
install -m 0644 usr/share/applications/$PKG.desktop \
  %{buildroot}/usr/share/applications/$PKG.desktop

%files
/opt/$PKG
/usr/bin/$PKG
/usr/share/applications/$PKG.desktop

%changelog
EOF
  rpmbuild --define "_topdir $TOP" --define "_binary_payload w9.xzdio" \
    -bb "$TOP/SPECS/$PKG.spec" >"$WORK/rpmbuild.log" 2>&1 || {
      echo "---- rpmbuild 输出 ----" >&2; tail -40 "$WORK/rpmbuild.log" >&2; die "rpmbuild 失败"; }
  RPM_BUILT="$(find "$TOP/RPMS" -name "*.rpm" -type f | head -1)"
  [[ -n "$RPM_BUILT" ]] || die "rpmbuild 没有产出 rpm"
  cp -a "$RPM_BUILT" "$OUT/"
  echo "OK rpm: $OUT/$(basename "$RPM_BUILT")"
fi

# ── 便携 tar.gz（Arch 之外的发行版直接解压用）────────────────────────────
TAR_FILE="$OUT/${PKG}-${VERSION}-linux-${RPM_ARCH}.tar.gz"
tar -C "$(dirname "$BUNDLE")" -czf "$TAR_FILE" "$(basename "$BUNDLE")"
echo "OK tar.gz: $TAR_FILE"
