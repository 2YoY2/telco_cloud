#!/usr/bin/env bash
# Apply the patch series to an Aerial source tree.
#   AERIAL_SRC=/path/to/aerial-cuda-accelerated-ran ./apply.sh [--check]
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC=${AERIAL_SRC:?set AERIAL_SRC to the Aerial source tree}
[ -f "$SRC/aerial-sdk-version" ] || { echo "no aerial-sdk-version in $SRC — is that the SDK root?" >&2; exit 1; }
VER=$(cat "$SRC/aerial-sdk-version")
echo "tree $SRC (version $VER)"
[ "$VER" = "26-1-cubb" ] || echo "  WARNING: patches were made against 26-1-cubb, this tree is $VER"

DRY=""; [ "${1:-}" = "--check" ] && DRY="--dry-run"
n=0
while read -r p; do
  case "$p" in ''|\#*) continue ;; esac
  f="$HERE/patches/$p"
  [ -f "$f" ] || { echo "  MISSING $p" >&2; exit 1; }
  printf '  %-44s ' "$p"
  if patch -p1 -d "$SRC" --forward $DRY < "$f" >/dev/null 2>&1; then echo ok; n=$((n+1))
  else echo FAILED; echo "    re-run without redirection to see why:" >&2
       echo "    patch -p1 -d $SRC --forward < $f" >&2; exit 1; fi
done < "$HERE/series"
echo "${DRY:+would apply }${n} patch(es)${DRY:+, nothing changed}"
