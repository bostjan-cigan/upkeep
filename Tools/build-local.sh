#!/bin/zsh
# Builds a local copy of Upkeep without xcodebuild (handy for quick runs), including the
# phone web app from Web/ (skipped with SKIP_WEB=1, e.g. when node isn't installed).
# It has its own bundle id, so its settings and device identity are separate from the Xcode build.
# Release builds are Universal (Apple Silicon and Intel in one app); debug builds only this Mac's
# chip, for speed. ARCHS="arm64 x86_64" overrides either.
# UPKEEP_VERSION (e.g. 1.2.0) and UPKEEP_BUILD (e.g. 42) set the version the app reports; the
# release workflow takes them from the git tag.
# Usage: Tools/build-local.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${1:-debug}
XCODE=/Applications/Xcode.app/Contents/Developer
PLUGINS=$XCODE/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins
SDK=$(xcrun --sdk macosx --show-sdk-path)
OUT=build/local/Upkeep.app
VERSION=${UPKEEP_VERSION:-1.0}
BUILD=${UPKEEP_BUILD:-1}

FLAGS=(-O)
[[ $CONFIG == debug ]] && FLAGS=(-Onone -g -D DEBUG)
DEFAULT_ARCHS=$(uname -m)
[[ $CONFIG == release ]] && DEFAULT_ARCHS="arm64 x86_64"
ARCH_LIST=(${=ARCHS:-$DEFAULT_ARCHS})

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources" build/local/arch

# One binary per chip, then one app that carries both; each Mac runs its own natively.
SLICES=()
for arch in $ARCH_LIST; do
  swiftc "${FLAGS[@]}" -sdk "$SDK" -target "$arch-apple-macos15.0" \
    -plugin-path "$PLUGINS" -parse-as-library -module-name Upkeep \
    $(find Upkeep -name '*.swift' | sort) \
    -o "build/local/arch/Upkeep-$arch"
  SLICES+=("build/local/arch/Upkeep-$arch")
done
lipo -create "${SLICES[@]}" -output "$OUT/Contents/MacOS/Upkeep"

cp Upkeep/Icons/*.svg "$OUT/Contents/Resources/"

if [[ ${SKIP_WEB:-0} != 1 ]]; then
  Tools/build-web.sh "$OUT/Contents/Resources/Web"
fi

ICONSET=build/local/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
A=Upkeep/Assets.xcassets/AppIcon.appiconset
for s in 16 32 128 256 512; do
  cp "$A/icon_$s.png" "$ICONSET/icon_${s}x${s}.png"
  cp "$A/icon_$((s * 2)).png" "$ICONSET/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$ICONSET" -o "$OUT/Contents/Resources/AppIcon.icns"

cat > "$OUT/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Upkeep</string>
  <key>CFBundleIdentifier</key><string>com.bostjancigan.Upkeep.local</string>
  <key>CFBundleName</key><string>Upkeep</string>
  <key>CFBundleDisplayName</key><string>Upkeep</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Boštjan Cigan. Licensed under the Apache License 2.0.</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSLocalNetworkUsageDescription</key><string>Upkeep serves its app to the iPhones and iPads in your household and syncs with them on your home network.</string>
</dict>
</plist>
EOF

# Signed with your own certificate when there is one (Tools/make-signing-identity.sh), every build is
# the same app to macOS, so permissions like Local Network stick. Otherwise ad hoc, which macOS
# knows only by this build's fingerprint.
SIGN_IDENTITY=${UPKEEP_SIGN_IDENTITY:-Upkeep Local Signing}
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$SIGN_IDENTITY\""; then
  codesign --force --sign "$SIGN_IDENTITY" "$OUT"
  echo "Signed with “$SIGN_IDENTITY”"
else
  codesign --force --sign - "$OUT"
  echo "Signed ad hoc — run Tools/make-signing-identity.sh once so permissions survive rebuilds"
fi
# Tell Launch Services about this copy, or macOS keeps showing the generic icon for it —
# in the Dock and, more annoyingly, on every reminder it posts.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[[ -x $LSREGISTER ]] && "$LSREGISTER" -f "$OUT" || true
touch "$OUT"
echo "Built $OUT"
