#!/usr/bin/env bash
# Local tests for match-game-versions.sh and collect-interfaces.sh.
# Needs bash and jq only - no CurseForge credentials.
#
#   bash .github/actions/upload-curseforge/tests/test-match-game-versions.sh
#
# Set JQ=/path/to/jq if jq is not on PATH.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_DIR="$(dirname "$HERE")"
MATCH="$ACTION_DIR/match-game-versions.sh"
COLLECT="$ACTION_DIR/collect-interfaces.sh"
FIXTURE="$HERE/fixtures/game-versions.json"

PASS=0
FAIL=0

# run_match <interfaces> -> sets OUT, ERR, CODE
run_match() {
  local errfile
  errfile="$(mktemp)"
  OUT="$(bash "$MATCH" "$1" "$FIXTURE" 2>"$errfile")"
  CODE=$?
  ERR="$(cat "$errfile")"
  rm -f "$errfile"
}

check() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok   - $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL - $label"
    echo "       expected: [$expected]"
    echo "       actual:   [$actual]"
    FAIL=$((FAIL + 1))
  fi
}

check_contains() {
  local label="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "ok   - $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL - $label"
    echo "       expected to find: [$needle]"
    echo "       in: [$haystack]"
    FAIL=$((FAIL + 1))
  fi
}

# Exact retail match. 120001 must become 12.0.1, never a substring hit.
run_match "120001"
check "retail 120001 -> 12.0.1 exact" "9102" "$OUT"
check "retail exact exits 0" "0" "$CODE"

# Exact classic matches for Era, Anniversary and Mists.
run_match "11509, 20506, 50504"
check "classic 11509/20506/50504 -> exact ids" "1003,2002,5002" "$OUT"

# Missing patch falls back to the highest listed patch in the same major.minor.
run_match "120007"
check "retail 120007 falls back to 12.0.5" "9103" "$OUT"
check_contains "fallback is logged as a warning" "::warning::Interface 120007 wants 12.0.7" "$ERR"

# An interface with no listed major.minor is skipped with a warning while the
# others still resolve.
run_match "120001, 120100"
check "unmatchable 120100 skipped, 120001 kept" "9102" "$OUT"
check "partial match exits 0" "0" "$CODE"
check_contains "unmatchable value is warned" "::warning::Interface 120100 (12.1.0)" "$ERR"

# Nothing matched at all: fail loudly, print no IDs.
run_match "120100, 30405"
check "nothing matched exits 1" "1" "$CODE"
check "nothing matched prints no ids" "" "$OUT"
check_contains "nothing matched raises an error" "::error::None of the interface values" "$ERR"

# De-duplication: repeated values and two values resolving to the same id.
run_match "120005,120005, 120007"
check "duplicates collapse to one id" "9103" "$OUT"

# The full collection line from the brief.
run_match "11509, 20506, 50504, 120001, 120005, 120007, 120100"
check "full multi-flavour line" "1003,2002,5002,9102,9103" "$OUT"
check "full multi-flavour line exits 0" "0" "$CODE"

# Non-numeric tokens are ignored rather than matched.
run_match "abc, 120001"
check "non-numeric token ignored" "9102" "$OUT"

# collect-interfaces.sh across several TOCs, CRLF and flavour-specific lines.
TMP="$(mktemp -d)"
printf '## Interface: 120001, 120005\r\n## Title: Test\r\n## Version: 1.0.0\r\n' > "$TMP/Addon.toc"
printf '## Interface: 11509\n## Interface-Mists: 50504, 120001\n' > "$TMP/Addon_Vanilla.toc"
printf '## Title: No interface here\n' > "$TMP/Addon_Empty.toc"
check "collect across TOCs de-duplicates in order" "120001,120005,11509,50504" \
  "$(bash "$COLLECT" "$TMP/Addon.toc" "$TMP/Addon_Vanilla.toc" "$TMP/Addon_Empty.toc")"
check "collect from a single TOC" "120001,120005" "$(bash "$COLLECT" "$TMP/Addon.toc")"
rm -rf "$TMP"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
