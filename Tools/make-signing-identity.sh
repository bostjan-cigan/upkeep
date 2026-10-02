#!/bin/zsh
# One-time setup: a code-signing certificate of your own, "Upkeep Local Signing", in your login
# keychain. Tools/build-local.sh and ./build.sh sign with it whenever it's there.
#
# Why: an ad-hoc signed app is known to macOS only by a fingerprint of that exact build, so every
# rebuild looks like a new app — and permissions such as Local Network (which Upkeep needs to
# answer at upkeep-<you>.local) don't carry over. Signed with one certificate, every build is the
# same app to macOS, and a permission given once stays.
#
# It stays on this Mac: nothing is uploaded, and no Apple account is involved. macOS asks for your
# password once, to trust the certificate for code signing. Safe to run again: it finishes a setup
# that stopped halfway, and does nothing once it's done. Works with zsh, bash or sh.
# Usage: Tools/make-signing-identity.sh
set -eu

NAME="Upkeep Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENSSL=/usr/bin/openssl   # the system's; a Homebrew OpenSSL 3 makes .p12 files macOS can't import

has_identity() {
  # $1 is "-v" for trusted (valid) identities only.
  security find-identity $1 -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"${NAME}\""
}

if has_identity -v; then
  echo "\"${NAME}\" is already set up. Build with ./build.sh."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if has_identity ""; then
  # Made by an earlier run that stopped before trusting it: trust that one.
  security find-certificate -c "${NAME}" -p "$KEYCHAIN" > "$TMP/cert.pem"
  echo "Found \"${NAME}\" in your login keychain, not trusted yet."
else
  printf '%s\n' \
    '[req]' 'distinguished_name = dn' 'prompt = no' 'x509_extensions = ext' \
    '[dn]' "CN = ${NAME}" \
    '[ext]' 'basicConstraints = critical, CA:false' 'keyUsage = critical, digitalSignature' \
    'extendedKeyUsage = critical, codeSigning' > "$TMP/cert.cnf"
  "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
  "$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "${NAME}" \
    -out "$TMP/identity.p12" -passout pass:upkeep
  # -T lets codesign use the key without asking each time.
  security import "$TMP/identity.p12" -k "$KEYCHAIN" -P upkeep -T /usr/bin/codesign >/dev/null
  echo "Added \"${NAME}\" to your login keychain."
fi

echo "macOS now asks for your password, to trust it for code signing..."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

if has_identity -v; then
  echo
  echo "Done. Next:"
  echo "  1. ./build.sh - builds are now signed with \"${NAME}\"."
  echo "  2. Replace /Applications/Upkeep.app with build/local/Upkeep.app and open it."
  echo "  3. Allow Upkeep to find devices on your local network when asked (or turn it on in"
  echo "     System Settings > Privacy & Security > Local Network). From now on it stays allowed."
  echo "The first build may ask to use the key: choose Always Allow."
else
  echo "The certificate still isn't trusted for code signing. Open Keychain Access, find \"${NAME}\","
  echo "and under Trust set Code Signing to Always Trust."
  exit 1
fi
