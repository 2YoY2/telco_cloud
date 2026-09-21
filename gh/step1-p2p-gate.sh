#!/usr/bin/env bash
# Step 1: flip the fronthaul to GPU-direct memory and prepare the logs to tell us what happened.
#   bash gh/step1-p2p-gate.sh [path/to/cuphycontroller_x.yaml] [path/to/nvlog_config.yaml]
# Backs up both files as *.pre-p2p.  Undo with gh/step1-undo.sh
set -u
CFG=${1:-}; NVLOG=${2:-}

find_one() {  # $1 = grep pattern, rest = roots
  local pat=$1; shift
  grep -rl "$pat" "$@" 2>/dev/null | grep -E '\.yaml$' | grep -v '\.pre-p2p' | sort -u
}
if [ -z "$CFG" ]; then
  mapfile -t hits < <(find_one "gpu_init_comms_via_cpu" ~/gh-config ~/kit ~/cuBB ~/aerial-k3s 2>/dev/null)
  if [ ${#hits[@]} -eq 0 ]; then echo "No yaml with gpu_init_comms_via_cpu found. Pass the path explicitly."; exit 1; fi
  if [ ${#hits[@]} -gt 1 ]; then printf 'Several candidates, pass the right one explicitly:\n'; printf '  %s\n' "${hits[@]}"; exit 1; fi
  CFG=${hits[0]}
fi
if [ -z "$NVLOG" ]; then
  mapfile -t nh < <(find_one '"FH.DOCA"' ~/gh-config ~/kit ~/cuBB ~/aerial-k3s 2>/dev/null)
  [ ${#nh[@]} -eq 1 ] && NVLOG=${nh[0]}
fi

echo "controller config : $CFG"
echo "nvlog config      : ${NVLOG:-<not found, fronthaul lines will stay hidden>}"
echo

cp -n "$CFG" "$CFG.pre-p2p" && echo "  backed up $(basename "$CFG").pre-p2p"
sed -i -E 's/^([[:space:]]*gpu_init_comms_via_cpu:[[:space:]]*)1/\10/' "$CFG"
grep -nE '^\s*(gpu_init_comms_via_cpu|cpu_init_comms):' "$CFG" | sed 's/^/  /'

if [ -n "$NVLOG" ]; then
  cp -n "$NVLOG" "$NVLOG.pre-p2p" && echo "  backed up $(basename "$NVLOG").pre-p2p"
  python3 - "$NVLOG" <<'PY'
import re, sys
p = sys.argv[1]; src = open(p).read().splitlines(keepends=True)
want, out, i, n = {"600", "605", "618"}, [], 0, 0
while i < len(src):
    l = src[i]; out.append(l)
    m = re.match(r'^(\s*)- (\d+): "([^"]+)"', l)
    if m and m.group(2) in want:
        if i + 1 < len(src) and re.match(r"^\s*#?\s*shm_level:", src[i+1]): i += 1
        out.append(m.group(1) + "  shm_level: 5\n"); n += 1
    i += 1
open(p, "w").write("".join(out))
print("  raised %d fronthaul tags (FH, FH.MEMREG, FH.DOCA) to INFO" % n)
PY
fi
cat <<'TXT'

Now start the L1 exactly as you normally do, then:

    bash gh/step1-check.sh <path-to-phy.log>

If it aborts within a few seconds, that is the expected GB10-style failure and the
answer is no. If it reaches "L1 is ready", the answer is yes.
TXT
