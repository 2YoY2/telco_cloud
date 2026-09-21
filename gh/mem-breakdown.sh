#!/usr/bin/env bash
# Where is the DU-Low's GPU memory?  Reads the L1's own accounting out of its log.
#   bash gh/mem-breakdown.sh [container-name]        (default: du-low)
set -u
C=${1:-du-low}
echo "=== process totals ==="
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader | sed 's/^/  /'
echo
echo "=== fronthaul buffers registered with the NIC ==="
sudo docker logs "$C" 2>&1 | grep -a "FH.DOCA" | sed -E 's/^[0-9:.]+ [A-Z]+ [^ ]+ [0-9]+ //' | sed 's/^/  /'
sudo docker logs "$C" 2>&1 | grep -aoE "size [0-9]+B" | sort -u \
  | awk '{gsub(/[^0-9]/,"",$2); printf "  %s B = %.2f GiB\n", $2, $2/1073741824}'
echo
echo "=== cuPHY channel objects (allocated on CONFIG.request) ==="
sudo docker exec "$C" cat /var/log/aerial/phy.log 2>/dev/null | python3 -c '
import sys, re
from collections import defaultdict
d = defaultdict(lambda: [0, 0.0])
for l in sys.stdin:
    m = re.search(r"GPU allocation:\s*([0-9.]+)\s*MiB for (.+?)\s*\(0x", l)
    if m:
        k = re.sub(r"\d+", "N", m.group(2)).strip()
        d[k][0] += 1; d[k][1] += float(m.group(1))
if not d: print("  (none logged -- needs CUPHY.MEMFOOT at INFO)"); raise SystemExit
print("  %-44s %6s %10s" % ("description", "count", "MiB"))
for k, (n, mib) in sorted(d.items(), key=lambda kv: -kv[1][1]):
    if mib >= 1: print("  %-44s %6d %10.1f" % (k[:44], n, mib))
print("  %-44s %6d %10.1f" % ("TOTAL", sum(v[0] for v in d.values()), sum(v[1] for v in d.values())))
'
echo
echo "=== driver-side components ==="
sudo docker exec "$C" cat /var/log/aerial/phy.log 2>/dev/null | grep -a "DRV.MEMFOOT" | python3 -c '
import sys, re
from collections import defaultdict
rows=[]; cur=None
for l in sys.stdin:
    m = re.search(r"Memory Footprint (\S+) x (\d+)", l)
    if m: cur = {"n": m.group(1), "g": 0, "p": 0}; rows.append(cur); continue
    if cur is None: continue
    m = re.search(r"GPU regular memory (\d+) Bytes", l)
    if m: cur["g"] = int(m.group(1)); continue
    m = re.search(r"GPU pinned memory (\d+) Bytes", l)
    if m: cur["p"] = int(m.group(1))
agg = defaultdict(int)
for r in rows: agg[r["n"]] += r["g"] + r["p"]
for k, v in sorted(agg.items(), key=lambda kv: -kv[1])[:10]:
    if v >= 1048576: print("  %-40s %10.1f MiB" % (k, v/1048576))
'
