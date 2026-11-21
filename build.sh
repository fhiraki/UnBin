#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/build}"
app="$out/UnBin.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$out/obj"
for arch in arm64 x86_64; do
  swiftc -O ${MODULE_CACHE:+-module-cache-path "$MODULE_CACHE"} -swift-version 5 -parse-as-library -target "$arch-apple-macos13.0" \
    "$here"/Sources/*.swift -o "$out/obj/UnBin-$arch"
done
lipo -create "$out/obj/UnBin-arm64" "$out/obj/UnBin-x86_64" -output "$app/Contents/MacOS/UnBin"
cp "$here/Info.plist" "$app/Contents/Info.plist"
cp "$here/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
codesign --force -s - "$app"
echo "$app"
