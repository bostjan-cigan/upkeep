#!/bin/zsh
# Run at the end of every manual or scripted test. Leaves no trace of test copies on this Mac or
# on the network:
#   1. quits leftover test copies (Tools/test-copy.sh) gracefully, so they withdraw their names;
#   2. checks that no development build's upkeep-dev-….local name still answers;
#   3. deletes the test copies, their home folders and every test settings domain.
# Never touches com.bostjancigan.Upkeep or com.bostjancigan.Upkeep.local, or their data.
# Usage: Tools/dev-cleanup.sh
set -uo pipefail
cd "$(dirname "$0")/.."

ROOT=${UPKEEP_TEST_ROOT:-${TMPDIR:-/tmp}/upkeep-tests}
PROBLEMS=0

# 1. Test copies still running: SIGTERM lets them deregister their names; SIGKILL only if stuck.
pids=($(pgrep -f "$ROOT/.*/Upkeep.app/Contents/MacOS/Upkeep" 2>/dev/null))
if (( ${#pids} )); then
  echo "Quitting ${#pids} test cop$( (( ${#pids} == 1 )) && echo y || echo ies)…"
  kill -TERM $pids 2>/dev/null
  for _ in {1..25}; do
    pgrep -f "$ROOT/.*/Upkeep.app/Contents/MacOS/Upkeep" >/dev/null || break
    sleep 0.2
  done
  left=($(pgrep -f "$ROOT/.*/Upkeep.app/Contents/MacOS/Upkeep" 2>/dev/null))
  if (( ${#left} )); then
    echo "  still running after 5 s, killing: $left"
    kill -KILL $left 2>/dev/null
  fi
fi

# 2. Development names that still answer. A dev build's name is in its settings; one that's
#    running right now (your own debug session) is expected to answer.
answers() {
  local out
  out=$( (script -q /dev/null dns-sd -G v4 "$1" & p=$!; sleep 3; kill $p 2>/dev/null) 2>&1 | tr -d '\r')
  print -r -- "$out" | grep -q " Add "
}
for domain in com.bostjancigan.Upkeep com.bostjancigan.Upkeep.local $(defaults domains | tr ',' '\n' | tr -d ' ' | grep '^com\.bostjancigan\.Upkeep\.test\.'); do
  suffix=$(defaults read "$domain" phoneDevHostSuffix 2>/dev/null) || continue
  name="upkeep-dev-$suffix.local"
  if [[ $domain == com.bostjancigan.Upkeep || $domain == com.bostjancigan.Upkeep.local ]] && pgrep -x Upkeep >/dev/null; then
    continue
  fi
  if answers "$name"; then
    echo "✗ $name ($domain) still answers on the network"
    PROBLEMS=$((PROBLEMS + 1))
  fi
done

# 3. Test copies, their homes, and test settings domains.
[[ -d $ROOT ]] && rm -rf -- "$ROOT" && echo "Removed $ROOT"
for domain in $(defaults domains | tr ',' '\n' | tr -d ' ' | grep -E '^(com\.bostjancigan\.Upkeep\.(test\..+|resettest)|upkeep-selftest-.+|upkeep-tests-.+)$'); do
  defaults delete "$domain" >/dev/null 2>&1
  rm -f -- "$HOME/Library/Preferences/$domain.plist"
  removed=$((${removed:-0} + 1))
done
(( ${removed:-0} )) && echo "Removed ${removed} test settings domain$( (( removed == 1 )) || echo s)"

if (( PROBLEMS )); then
  echo "Done, with $PROBLEMS name(s) still answering — they drop out within their TTL (10 s for dev builds)."
  exit 1
fi
echo "Clean: no test copies running, no development names answering, no test settings left."
