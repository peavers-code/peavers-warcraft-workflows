#!/usr/bin/env bash
# Print the de-duplicated, comma-separated interface numbers declared by one
# or more TOC files.
#
# Usage: collect-interfaces.sh <file.toc> [<file.toc> ...]
#
# Reads "## Interface:" and client-specific "## Interface-<Flavour>:" lines,
# tolerates CRLF line endings, and preserves first-seen order.
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "::error::usage: collect-interfaces.sh <file.toc> [<file.toc> ...]" >&2
  exit 2
fi

for toc in "$@"; do
  if [ ! -f "$toc" ]; then
    echo "::warning::TOC file not found: $toc" >&2
    continue
  fi
  tr -d '\r' < "$toc" \
    | grep -E '^##[[:space:]]*Interface(-[A-Za-z]+)?[[:space:]]*:' \
    | sed -E 's/^[^:]*://' \
    || true
done | tr ', ' '\n\n' | grep -E '^[0-9]+$' | awk '!seen[$0]++' | paste -sd, -
