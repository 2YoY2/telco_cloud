# Right-sizing the DU-Low

Measured on a GB10 bench: one 4T4R 100 MHz cell, testMAC driving an F08 pattern
(7 downlink, 2 uplink, 1 special slot per 10-slot period) against a simulated RU over
O-RAN 7.2 fronthaul. Numbers are steady-state at full load.

## Result

| | stock | right-sized |
|---|---|---|
| GPU footprint | 24,747 MiB | **4,955 MiB** |
| downlink | 1,369.97 Mbps | 1,369.97 Mbps |
| uplink | 498.22 Mbps | 498.22 Mbps |
| CRC errors | 0 | 0 |

Five times less GPU memory, with throughput and correctness unchanged.

## Where the memory goes

Stock, one cell:

| block | size | share |
|---|---|---|
| fronthaul packet buffer | 16 GiB | 66 % |
| HARQ pools | 4.5 GiB | 18 % |
| everything else | ~4 GiB | 16 % |

Scaling is 23.6 GiB fixed plus roughly 584 MiB per additional cell, so on a small
deployment the fixed part dominates completely.

## Three levers

**1. `mtu` (controller YAML, no rebuild).** The fronthaul allocates
`ceil(mtu/128)*128` rounded up to a power of two per packet slot. Dropping the
fronthaul MTU from 9000 to 2048 cuts the per-packet reservation fourfold. The cost is
four times as many packets, which shows up as about 11 µs more per slot in the
compression packet memcopy stage — see [02-per-slot-timing.md](02-per-slot-timing.md).

**2. `max_harq_pools` (controller YAML, no rebuild).** `MAX_HARQ_POOLS` defaults to 3
size classes of 262144 / 4000000 / 8000000 bytes. Raising the pool count knob trims the
reserved HARQ arena substantially for a single-cell deployment.

**3. `kGpuCommSendPeers` (source, needs a rebuild).** See
[`0001-fh-right-size-gpu-comm-send-peers.patch`](../patches/0001-fh-right-size-gpu-comm-send-peers.patch).
This is the big one, and the only one requiring a rebuild.

Levers 1 and 2 are ordinary configuration. Only lever 3 needs the patch.

## A second finding: timer-thread core placement

Not a memory issue, but found during the same bring-up and worth recording.

`timer_thread_config.cpu_affinity` places a SCHED_FIFO 99 thread with a 15 µs wake
deadline (`timer_thread_wakeup_threshold_`, default 15000 ns in
`cuPHY-CP/cuphyl2adapter/lib/nvPHY/nv_phy_module.hpp`). When that core is shared with the
DPDK poll thread, the low-priority threads and the MPS daemons, the thread oversleeps and
the L1 drops the slot, logging `send_slot_error_indication: Late slot error encountered`
(`nv_phy_module.cpp:1333`).

Measured, 180 s per arm at full load:

| timer thread's core | late slots per minute | downlink |
|---|---|---|
| shared, not isolated | 6,196.7 | 1,280.89 Mbps |
| shared with DPDK + MPS + testMAC | 74.3 | 1,369.97 Mbps |
| same, testMAC moved off | 64.7 | 1,369.11 Mbps |
| **a core of its own** | **~0** | 1,369.97 Mbps |

Giving the thread an uncontended core removes the problem, and core *speed* is
irrelevant — GB10 is heterogeneous (cores 5-9 and 15-19 are Cortex-X925 at 3.9 GHz,
the rest Cortex-A725 at 2.8 GHz) and a slow dedicated core scored the same as a fast one.
What matters is only that nothing else is on it. Cost: one core.

Uplink delivery timing did not move across any of these arms, confirming the late-slot
errors are a host scheduling artefact and independent of the uplink pipeline.
