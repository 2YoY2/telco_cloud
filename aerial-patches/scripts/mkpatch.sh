#!/usr/bin/env bash
# Generate a patch from a modified tree and append it to the series.
#   AERIAL_PRISTINE=/path/to/unmodified  AERIAL_SRC=/path/to/modified \
#     ./mkpatch.sh 0001-short-name path/relative/to/tree.cpp [more paths...]
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC=${AERIAL_SRC:?set AERIAL_SRC};  PRI=${AERIAL_PRISTINE:?set AERIAL_PRISTINE to an unmodified tree}
NAME=${1:?usage: mkpatch.sh NNNN-short-name <paths...>}; shift
[ $# -gt 0 ] || { echo "give at least one path, relative to the tree root" >&2; exit 1; }
OUT="$HERE/patches/$NAME.patch"
: > "$OUT"
for rel in "$@"; do
  [ -f "$SRC/$rel" ] || { echo "missing $SRC/$rel" >&2; exit 1; }
  diff -u "$PRI/$rel" "$SRC/$rel" \
    | sed -e "1s|^--- .*|--- a/$rel|" -e "2s|^+++ .*|+++ b/$rel|" >> "$OUT" || true
done
[ -s "$OUT" ] || { echo "no differences found — nothing written"; rm -f "$OUT"; exit 1; }
grep -qx "$NAME.patch" "$HERE/series" || echo "$NAME.patch" >> "$HERE/series"
echo "wrote patches/$NAME.patch ($(grep -c '^+' "$OUT") added, $(grep -c '^-' "$OUT") removed) and appended to series"
echo "now add a header to it saying what changed and why — Apache 2.0 section 4(b)"
