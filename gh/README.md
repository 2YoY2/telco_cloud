# Grace Hopper: can the fronthaul packet buffer be made dynamic?

Everything here is blocked on GB10 and needs a platform with working GPUDirect RDMA to the
NIC. See [../aerial-patches/notes/05-fronthaul-blocked-on-gb10.md](../aerial-patches/notes/05-fronthaul-blocked-on-gb10.md)
for why.

## The prize

At MTU 9120 the fronthaul packet buffer is
`kGpuCommSendPeers x kMaxFlows x kMaxPktsFlow` slots of 16,384 bytes. Even with the peer count
cut to 4 that is **4 GiB**, and measured occupancy on a 4T4R 100 MHz cell is about **224
packets per slot against 262,144 slots**.

It is a `DOCA_ETH_RXQ_TYPE_CYCLIC` ring, so the NIC sweeps the whole range and wraps about
twice a second. There is no spatially unused region — the excess is depth, not area.

## The plan: alias the ring

Keep the virtual range at 4 GiB and the DOCA configuration byte for byte unchanged. Back it
with a fraction of that in physical memory, mapped repeatedly across the range. The NIC sweeps
4 GiB of address; the physical footprint wraps N times faster.

DOCA sees nothing different: same mmap, same mkey, the queue never stops. That matters,
because every setter in `doca_eth_rxq.h` is documented "can only be called before calling
doca_ctx_start()" — so resizing the ring the obvious way would mean a fronthaul outage, and
aliasing avoids it entirely.

Correctness needs only that the alias period exceed the drain latency:

| backing | slots | packets before reuse | drain | margin |
|---|---|---|---|---|
| 512 MiB | 32,768 | ~146 slots | ~2.7 slots | ~54x |
| 256 MiB | 16,384 | ~73 slots | ~2.7 slots | ~27x |

## Run this in order

### Step 0 — the CUDA probes (no L1 needed, two minutes)

```sh
python3 gh/probe-alias.py      # can one allocation be mapped at several addresses?
python3 gh/probe-gh.py         # VMM, dmabuf export, cross-process sharing
```

On GB10: aliasing **works**, cross-process sharing **works**, dmabuf export **fails**.
The dmabuf result is the one expected to differ on Grace Hopper.

### Step 1 — the gate: will the NIC take GPU memory?

In the cuphycontroller yaml:

```yaml
gpu_init_comms_via_cpu: 0     # was 1
```

Start the L1 normally and watch the first few seconds.

**Fails like this** (what GB10 does):

    DOCA exception [DOCA_ERROR_DRIVER] priv_doca_umem constructor failed
    Mmap: Failed to register MR for device with id: 1. err=DOCA_ERROR_DRIVER
    terminate called without an active exception

**Succeeds like this** — the L1 reaches "L1 is ready" and the fronthaul logs one of:

    Mapping receive queue buffer (0x... size ...B dmabuf fd N) with dmabuf mode
    Mapping receive queue buffer (0x... size ...B) with nvidia-peermem mode

To see those lines, raise nvlog tags 600 (`FH`), 605 (`FH.MEMREG`) and 618 (`FH.DOCA`) to
`shm_level: 5`. Also worth checking `lsmod | grep nvidia_peermem` — a non-zero refcount while
the fronthaul runs means GPU memory really is registered with the NIC.

**If step 1 fails, stop.** Nothing below is reachable.

### Step 2 — alias a live ring

Only if step 1 passes. In `doca_create_rx_queue` (`cuPHY-CP/aerial-fh-driver/lib/doca_obj.cpp`),
replace the single `doca_gpu_mem_alloc` of `cyclic_buffer_size` with:

1. `cuMemAddressReserve(cyclic_buffer_size)` — the full range, unchanged as far as DOCA cares
2. `cuMemCreate(cyclic_buffer_size / N)` — one physical allocation, N a small power of two
3. `cuMemMap` that handle at every offset `k * (cyclic_buffer_size / N)` for k in 0..N-1
4. `cuMemSetAccess` over the whole range
5. hand the base address to `doca_mmap_set_memrange` exactly as before

Start with **N = 2**. Run full traffic and watch the order kernel's own counters, which fail
loudly: `EARLY / ONTIME / LATE` and `RX Packet Dropped Count` in the `[PHYDRV] ... ORDER` log
lines, plus the cell's CRC count. Corruption from a too-short alias period shows up as CRC
errors, not as a crash.

Then N = 4, 8, 16, and find where it breaks. The break point measures the real burst depth the
link needs, which is a useful number even if you end up choosing a static ring size instead.

## What could still go wrong at step 2

Aliasing is confirmed to work for CUDA accesses. DMA is a different path, and it could fail on
write-combining, on cache coherence between the NIC's view and the GPU's, or on mkey
translation caching. This is a well-founded hypothesis, not a safe bet. The N = 2 test is
cheap and decides it.

## Cheaper alternative, if you would rather not patch

`kMaxPktsFlow = 2048` in `cuPHY-CP/aerial-fh-driver/lib/defaults.hpp` is the ring depth, a
compile-time constant sized for worst case. At MTU 9120, depth 512 gives a 1 GiB buffer with
about 3.4x headroom over measured need, against 4 GiB today. That is a one-line change in the
same shape as
[patch 0001](../aerial-patches/patches/0001-fh-right-size-gpu-comm-send-peers.patch), and it
recovers most of the memory without the MTU 2048 penalty of four times the packet rate and
+11 us per slot in packet memcopy.

Making it a yaml parameter instead of a constant would let it be retuned without a rebuild.
