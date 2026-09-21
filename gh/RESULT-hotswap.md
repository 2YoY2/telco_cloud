# Hot swap: 15.4 GiB moved in and out of a live fronthaul buffer

GH200 480GB, DU-Low with `gpu_init_comms_via_cpu: 0`, DU-High attached over FAPI,
vLLM co-resident holding 47,054 MiB on the same GPU. 21 Sep 2026.

Nothing was restarted between any of these rows. The DOCA queue stayed up, the mkey
and base address never changed, and the cell carried traffic throughout.

| command | physical backing | DU-Low process | DL | CRC |
|---|---|---|---|---|
| start `ALIAS_N=16` | 16,384 MiB | 26,146 MiB | 0.04 Mbps | 0 |
| `alias 8` | 8,192 | 17,952 | 0.04 | 0 |
| `alias 4` | 4,096 | 13,856 | 0.04 | 0 |
| `alias 2` | 2,048 | 11,808 | 0.04 | 0 |
| `alias 1` | **1,024** | **10,784** | 0.04 | 0 |
| `alias 16` | 16,384 | 26,144 | 0.04 | 0 |

Every step matches prediction: 8,194 / 4,096 / 2,048 / 1,024 MiB released against
8,192 / 4,096 / 2,048 / 1,024 expected. **15,362 MiB — 15.0 GiB — handed back while
the cell ran**, and growing back returns to within 2 MiB of the original.

At N=1 that is a 16x alias: 1 GiB of physical memory behind a 16 GiB buffer the NIC
believes it owns in full.

## Why this works

`doca_eth_rxq` setters are all documented "can only be called before calling
doca_ctx_start()", so the buffer cannot be resized the obvious way without stopping
the queue — a fronthaul outage, not a glitch. Aliasing sidesteps that entirely by
never touching anything DOCA can observe. The virtual range, its length and its mkey
are constant; only the physical pages behind the addresses change.

The range is cut into 16 slots, each mapped to a physical handle. With N handles,
slot k uses handle k % N. Reshaping repoints slots one at a time and releases the
handles that fall out of use, so no more than 1/16 of the range is unmapped at once.

## What is proven, and what is not

**Proven.** Physical memory behind a live, NIC-registered, DMA-active buffer can be
reduced 16x and restored, on command, with no restart and no observable effect on the
cell. The memory genuinely leaves the process and is available to anything else on
the GPU — vLLM was holding 47,054 MiB alongside it.

**Not proven.** The cell was idle: 0.04 Mbps, SSB only, no UE. Correctness of aliasing
requires the alias period to exceed the time a packet spends in the buffer, and at
that rate nothing is testing it. **N=1 passing here is not evidence that N=1 is safe
under load.** It is evidence that the mechanism is sound.

Two distinct failure modes to keep separate when load testing:

- a NIC write landing in a slot during its unmapped window faults, showing as an abort
- an alias period shorter than a packet's lifetime corrupts, showing as CRC errors

The first is fixed by reshaping behind the ring's write pointer. The second sets the
real floor on N.

## Next

1. Put real traffic on it and repeat the sweep. The N that survives load is the answer.
2. Read the ring's write pointer and reshape behind it, closing the unmapped window.
3. Move the control path from the file poller onto the OAM gRPC service.
