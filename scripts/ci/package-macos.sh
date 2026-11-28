#!/usr/bin/env bash
set -euo pipefail

app=${1:?usage: package-macos.sh app zip extracted-directory evidence-directory}
zip=${2:?missing zip path}
extracted=${3:?missing extraction directory}
evidence=${4:?missing evidence directory}
script_dir="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$(dirname "$zip")" "$evidence"
mkdir "$extracted"

ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
ditto -x -k "$zip" "$extracted"
signed_app="$extracted/$(basename "$app")"
codesign --verify --deep --strict --verbose=2 "$signed_app" 2>&1 \
  | tee "$evidence/codesign-verify.log"

executable="$(plutil -extract CFBundleExecutable raw "$signed_app/Contents/Info.plist")"
binary="$signed_app/Contents/MacOS/$executable"
lipo -verify_arch x86_64 arm64 "$binary"
architectures="$(lipo -archs "$binary")"
for arch in $architectures; do
  codesign --display --arch "$arch" --verbose=4 --entitlements - --xml "$signed_app" \
    > "$evidence/entitlements-$arch.plist" 2> "$evidence/codesign-$arch.log"
  cat "$evidence/codesign-$arch.log" "$evidence/entitlements-$arch.plist"
  python3 "$script_dir/verify_macos_entitlements.py" "$evidence/entitlements-$arch.plist"
done

(cd "$(dirname "$zip")" && shasum -a 256 "$(basename "$zip")") | tee "$evidence/SHA256SUMS"
