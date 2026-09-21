# What one slot costs, and how it moves with SM budget

Same bench as [01](01-du-low-rightsizing.md): one 4T4R 100 MHz cell, F08 at full load,
right-sized configuration, GPU clock pinned at 1989 MHz. Figures come from the L1's own
`[PHYDRV] SFN` lines over 45 s — 63,594 downlink and 18,175 uplink slots.

Getting them needs a light log overlay: raising only tags 216 (`DRV.MAP_DL`) and 224
(`DRV.MAP_UL`) to level 5. The full debug set starved the uplink tasks at the fourfold
packet rate of MTU 2048 and aborted the L1 with `waitChannelEndTask returned error`.

## Per slot, microseconds

| downlink stage | mean | p95 | | uplink stage | mean | p95 |
|---|---|---|---|---|---|---|
| GPU setup | 13.7 | 17.8 | | setup phase 1 | 16.6 | 19.2 |
| PDSCH H2D copy | 8.5 | 14.9 | | setup phase 2 | 88.6 | 96.1 |
| PDSCH GPU run | 48.5 | 53.6 | | front-loaded DMRS | 67.7 | 70.7 |
| compression memcopy | 44.5 | 55.2 | | gap | 4.6 | 13.9 |
| C-plane | 0.4 | 1.0 | | post front-loaded DMRS | 234.8 | 240.6 |
| U-plane prepare | 13.1 | 14.0 | | phase 2 | 25.9 | 52.4 |
| U-plane transmit | 7.2 | 8.0 | | | | |
| **total** | **135.9** | | | **total** | **438.2** | |

## It is a pipeline, not a 500 µs race

Comparing 438 µs of uplink work against a 500 µs slot is the wrong framing. Placing each
stage against the true slot boundary — timestamps are epoch nanoseconds, so
`(t mod 10 ms) - (slot+1) * 500 µs` — gives, in microseconds relative to the slot's end:

| marker | mean | p95 | max |
|---|---|---|---|
| PUSCH setup begins | -1097.1 | -1095.4 | -1094.2 |
| PUSCH GPU completes | +535.6 | +549.1 | +744.9 |
| result reaches the MAC | +563.6 | +576.8 | +772.2 |

The pipeline is 1,661 µs deep — 3.3 slots — and delivers 564 µs after the slot ends.

A cross-check confirms the reading. `Ta4_max_ns` in the controller YAML is 331000: an
uplink U-plane packet may legally arrive up to 331 µs after the slot ends. Delivery is at
564. The difference, 233 µs, matches the measured post-front-loaded-DMRS stage of 234.8 µs.
So only about 234 µs of the 438 is deadline-bound; the rest overlaps packet arrival.

The order kernel's 1,337 µs `GPU Order Run` is a receive window, not arithmetic. GPU idle
time before it is 1.2 µs, the named sub-stages inside the 1,517 µs PUSCH span sum to 328,
and live sampling reads 66 % GPU utilisation at 13.4 W. `launch_order_kernel_doca_single_subSlot`
sets `cudaBlocks = num_order_cells`, so at one cell the ordering kernel is one block of 320
threads on a 48-SM part.

## SM budget versus slot time

`mps_sm_*` in the controller YAML gives each channel its own SM-capped context via
`cuCtxCreate_v3` with `CU_EXEC_AFFINITY_TYPE_SM_COUNT` (`cuphydriver/src/common/mps.cpp`).
Scaling all budgets together, clock fixed, L1 restarted per arm:

| pdsch / pusch SMs | PDSCH GPU run | PUSCH post-DMRS | UL delivery |
|---|---|---|---|
| no cap (48) | 46.8 | 234.8 | 551.0 |
| 46 / 40 (shipped) | 48.9 | 235.7 | 563.9 |
| 23 / 20 | 54.5 | 314.9 | 637.7 |
| 12 / 10 | 69.4 | 509.4 | 833.7 |
| 6 / 5 | 85.2 | 599.0 | 927.3 |
| 48 / 48 | aborts at init | | |

Every working arm carried 1,369.97 Mbps down, 498.22 up, zero CRC — **including the 6/5 arm**.

Three things follow. SM budget genuinely moves slot time. The scaling is strongly sublinear:
eight times fewer PUSCH SMs costs 2.55x on decode. And a full cell survives on 6 + 5 SMs out
of 48, at the price of 376 µs of extra uplink delivery latency and nothing else — the 500 µs
slot never binds, because the pipeline absorbs it.

`GPU Order Run` stayed at 1,334.7-1,338.1 in every arm, unmoved by the budget, independently
confirming it is a wait rather than compute.

Asking for all 48 SMs on every channel aborts: `mps.cpp:52` throws when the request exceeds
what is available, and the throw escapes a thread. The same mechanism explains why setting
`CUDA_MPS_ACTIVE_THREAD_PERCENTAGE` below 100 aborts the L1 — capping the client to 90 %
leaves 43 SMs while PDSCH asks for 46.
