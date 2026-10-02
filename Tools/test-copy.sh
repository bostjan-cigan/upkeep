#!/bin/zsh
# Makes a disposable copy of the local build that acts as another Mac: its own bundle id (so its
# own settings and device id), its own home folder (so its own store), and — being a development
# build — its own random upkeep-dev-….local name. Nothing it does touches your real Upkeep.
# Tools/dev-cleanup.sh removes all of it again.
#
# Usage: Tools/test-copy.sh NAME            prints the copy's app path and home folder
#        Tools/test-copy.sh NAME run [ARGS] runs it (in the foreground) with that home
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=${1:?usage: Tools/test-copy.sh NAME [run ARGS…]}
ROOT=${UPKEEP_TEST_ROOT:-${TMPDIR:-/tmp}/upkeep-tests}
ID="com.bostjancigan.Upkeep.test.$NAME"
DIR="$ROOT/$NAME"
APP="$DIR/Upkeep.app"
HOME_DIR="$DIR/home"

if [[ ! -d $APP ]]; then
  [[ -d build/local/Upkeep.app ]] || { echo "Build first: Tools/build-local.sh" >&2; exit 1 }
  mkdir -p "$DIR" "$HOME_DIR/household"
  cp -R build/local/Upkeep.app "$APP"
  plutil -replace CFBundleIdentifier -string "$ID" "$APP/Contents/Info.plist"
  codesign --force --deep --sign - "$APP" 2>/dev/null
  # Its household is a scratch folder of its own, never your iCloud one.
  defaults write "$ID" householdFolderPath "$HOME_DIR/household"
fi

if [[ ${2:-} == run ]]; then
  shift 2
  CFFIXED_USER_HOME="$HOME_DIR" exec "$APP/Contents/MacOS/Upkeep" "$@"
fi
echo "app:  $APP"
echo "home: $HOME_DIR"
echo "id:   $ID"
