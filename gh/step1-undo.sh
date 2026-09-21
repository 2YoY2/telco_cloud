#!/usr/bin/env bash
# Put both configs back exactly as they were.
set -u
n=0
for f in $(find ~/gh-config ~/kit ~/cuBB ~/aerial-k3s -name '*.pre-p2p' 2>/dev/null); do
  orig=${f%.pre-p2p}; cp "$f" "$orig" && rm -f "$f" && echo "  restored $orig" && n=$((n+1))
done
[ $n -eq 0 ] && echo "  nothing to restore (no .pre-p2p backups found)"
