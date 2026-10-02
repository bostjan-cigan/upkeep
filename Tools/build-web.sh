#!/bin/zsh
# Builds the phone web app (Web/) and copies it to the given folder, e.g. the app's Resources/Web.
# Used by Tools/build-local.sh and the Xcode "Build Web App" phase.
# Usage: Tools/build-web.sh <destination>
set -euo pipefail
cd "$(dirname "$0")/.."
DEST=${1:?destination folder}

# Xcode runs scripts with a minimal PATH; pick up node from the usual places.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if [[ -s "$HOME/.nvm/nvm.sh" ]] && ! command -v npm >/dev/null; then
  source "$HOME/.nvm/nvm.sh" >/dev/null
fi
command -v npm >/dev/null || { echo "error: npm not found; install Node.js to build the phone app" >&2; exit 1; }

cd Web
[[ -d node_modules ]] || npm ci --no-audit --no-fund
npm run build --silent
cd ..
rm -rf "$DEST"
mkdir -p "$DEST"
cp -R Web/dist/. "$DEST/"
echo "Web app copied to $DEST"
