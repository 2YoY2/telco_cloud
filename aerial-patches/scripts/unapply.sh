#!/usr/bin/env bash
# Reverse the patch series, last patch first.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC=${AERIAL_SRC:?set AERIAL_SRC to the Aerial source tree}
grep -vE '^\s*(#|$)' "$HERE/series" | tac | while read -r p; do
  printf '  reverting %-36s ' "$p"
  patch -p1 -R -d "$SRC" --forward < "$HERE/patches/$p" >/dev/null 2>&1 && echo ok || { echo FAILED; exit 1; }
done
