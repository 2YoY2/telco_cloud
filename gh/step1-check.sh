#!/usr/bin/env bash
# Read the verdict out of the L1 log after step1-p2p-gate.sh.
#   bash gh/step1-check.sh <path-to-phy.log> [path-to-l1-stdout.log]
set -u
LOG=${1:?usage: step1-check.sh <phy.log> [l1.stdout.log]}; OUT=${2:-}
cat_all() { cat "$LOG" ${OUT:+"$OUT"} 2>/dev/null; }

echo "=== did the NIC accept GPU memory? ==="
if cat_all | grep -aqiE "DOCA_ERROR_DRIVER|Failed to register MR|priv_doca_umem"; then
  echo "  NO -- same failure as GB10:"
  cat_all | grep -aiE "DOCA_ERROR_DRIVER|Failed to register MR|priv_doca_umem" | tail -3 | sed 's/^/    /'
  echo "  The aliasing plan is not reachable on this platform either. Run gh/step1-undo.sh."
elif cat_all | grep -aq "L1 is ready"; then
  echo "  YES -- the L1 came up with gpu_init_comms_via_cpu = 0"
  echo
  echo "=== which registration path did it take? ==="
  cat_all | grep -aiE "Mapping (receive|transmit) queue buffer|dmabuf mode|nvidia-peermem mode" \
    | sed -E 's/^[0-9:.]+ [A-Z]+ [^ ]+ [0-9]+ //' | head -6 | sed 's/^/    /'
  echo "    nvidia_peermem refcount: $(lsmod 2>/dev/null | awk '/^nvidia_peermem/{print $3}')"
  echo "    (dmabuf mode is preferred; a non-zero peermem refcount means the peermem path)"
  echo
  echo "=== buffer size it registered ==="
  cat_all | grep -aoE "size [0-9]+B" | sort -u | head -4 | sed 's/^/    /'
  echo
  echo "  Gate passed. Step 2 in gh/README.md is now worth doing."
else
  echo "  INCONCLUSIVE -- neither the failure nor 'L1 is ready' found."
  echo "  Last lines of the log:"; cat_all | tail -6 | sed 's/^/    /'
fi
echo
echo "=== cell health, if traffic ran ==="
grep -a 'SCF.PHY] Cell  0 |' "$LOG" 2>/dev/null | tail -1 | sed -E 's/^.*Cell  0/  Cell 0/' | cut -c1-95
grep -aoE "RX Packet Dropped Count\] \{ [0-9]+ \}" "$LOG" 2>/dev/null | awk -F'{' '{gsub(/[^0-9]/,"",$2); if($2>0) n++} END {printf "  slots with dropped RX packets: %d\n", n+0}'
