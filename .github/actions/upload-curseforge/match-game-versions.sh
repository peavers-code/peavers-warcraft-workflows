#!/usr/bin/env bash
# Resolve WoW interface numbers to CurseForge game version IDs.
#
# Usage: match-game-versions.sh "<interfaces>" <versions.json>
#
#   <interfaces>     comma- or space-separated interface numbers, e.g.
#                    "11509, 20506, 50504, 120001, 120100"
#   <versions.json>  the array returned by
#                    https://wow.curseforge.com/api/game/versions
#                    (objects with id, gameVersionTypeID, name, slug)
#
# Each interface number is converted to CurseForge's dotted name
# (11509 -> 1.15.9, 120100 -> 12.1.0) and matched on exact name equality.
# When that exact patch is not listed yet, the highest listed patch with the
# same major.minor is used instead and the substitution is logged.
#
# stdout: de-duplicated, comma-separated version IDs (nothing else).
# stderr: GitHub Actions log lines (::warning:: / ::error::).
# Exit:   0 when at least one interface matched, 1 when none did,
#         2 on bad input.
set -euo pipefail

JQ="${JQ:-jq}"

if [ "$#" -ne 2 ]; then
  echo "::error::usage: match-game-versions.sh \"<interfaces>\" <versions.json>" >&2
  exit 2
fi

INTERFACES="$1"
VERSIONS_FILE="$2"

if [ ! -f "$VERSIONS_FILE" ]; then
  echo "::error::versions file not found: $VERSIONS_FILE" >&2
  exit 2
fi
if ! "$JQ" -e 'type == "array"' "$VERSIONS_FILE" >/dev/null 2>&1; then
  echo "::error::versions file is not a JSON array: $VERSIONS_FILE" >&2
  exit 2
fi

# Normalise the list: split on commas/whitespace, keep numeric tokens only,
# preserve first-seen order.
IFACE_LIST=()
for token in $(printf '%s' "$INTERFACES" | tr ',\r' '  '); do
  if [[ "$token" =~ ^[0-9]+$ ]]; then
    IFACE_LIST+=("$token")
  else
    echo "::warning::Ignoring non-numeric interface value '$token'" >&2
  fi
done

if [ "${#IFACE_LIST[@]}" -eq 0 ]; then
  echo "::error::No interface numbers supplied" >&2
  exit 1
fi

IFACES_JSON="[$(IFS=,; echo "${IFACE_LIST[*]}")]"

# One line per interface, tab-separated:
#   exact    <iface> <wanted> <name> <id> <typeID>
#   fallback <iface> <wanted> <name> <id> <typeID>
#   missing  <iface> <wanted>
RESULTS=$("$JQ" -r --argjson ifaces "$IFACES_JSON" '
  def dotted: "\((. / 10000) | floor).\(((. / 100) | floor) % 100).\(. % 100)";
  def parts: (.name // "") | split(".");
  def patchnum: (parts | .[2] // "" | tonumber? // -1);

  [ .[] | select(type == "object" and (.name | type) == "string") ] as $all
  | $ifaces[]
  | . as $iface
  | ($iface | dotted) as $want
  | ($want | split(".") | .[0:2] | join(".")) as $mm
  | ([ $all[] | select(.name == $want) ] | sort_by(.id) | last) as $exact
  | if $exact != null then
      "exact\t\($iface)\t\($want)\t\($exact.name)\t\($exact.id)\t\($exact.gameVersionTypeID)"
    else
      ([ $all[]
         | select((parts | length) == 3 and (parts | .[0:2] | join(".")) == $mm and patchnum >= 0) ]
       | sort_by(patchnum, .id) | last) as $near
      | if $near != null then
          "fallback\t\($iface)\t\($want)\t\($near.name)\t\($near.id)\t\($near.gameVersionTypeID)"
        else
          "missing\t\($iface)\t\($want)"
        end
    end
' "$VERSIONS_FILE" | tr -d '\r')

IDS=()
MISSING=0
while IFS=$'\t' read -r kind iface want name id type_id; do
  [ -n "$kind" ] || continue
  case "$kind" in
    exact)
      echo "Interface $iface -> $name (id $id, type $type_id)" >&2
      IDS+=("$id")
      ;;
    fallback)
      echo "::warning::Interface $iface wants $want, which CurseForge does not list yet; using $name (id $id, type $type_id) instead" >&2
      IDS+=("$id")
      ;;
    missing)
      echo "::warning::Interface $iface ($want) has no CurseForge game version with that major.minor; skipping it" >&2
      MISSING=$((MISSING + 1))
      ;;
  esac
done <<< "$RESULTS"

if [ "${#IDS[@]}" -eq 0 ]; then
  echo "::error::None of the interface values (${IFACE_LIST[*]}) matched a CurseForge game version; refusing to upload with guessed versions" >&2
  exit 1
fi

printf '%s\n' "${IDS[@]}" | awk '!seen[$0]++' | paste -sd, -
