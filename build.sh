#!/bin/zsh
# Builds a shareable copy of Upkeep: Universal release build (runs natively on Apple Silicon and
# Intel Macs), signed with your own "Upkeep Local Signing" certificate if you've made one
# (Tools/make-signing-identity.sh), otherwise ad hoc — no Apple account needed either way —
# as build/Upkeep.zip and build/Upkeep.dmg (drag to Applications; LICENSE and NOTICE sit beside it).
# Uses Tools/build-local.sh under the hood; UPKEEP_VERSION and UPKEEP_BUILD set the version.
# Usage: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

Tools/build-local.sh release

rm -f build/Upkeep.zip
ditto -c -k --keepParent build/local/Upkeep.app build/Upkeep.zip
echo "Built build/Upkeep.zip"

STAGE=build/dmg
rm -rf "$STAGE" build/Upkeep.dmg
mkdir -p "$STAGE"
ditto build/local/Upkeep.app "$STAGE/Upkeep.app"
ln -s /Applications "$STAGE/Applications"
cp LICENSE NOTICE "$STAGE/"
hdiutil create -volname Upkeep -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov build/Upkeep.dmg >/dev/null
rm -rf "$STAGE"
echo "Built build/Upkeep.dmg"
