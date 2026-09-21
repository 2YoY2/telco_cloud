# Elastic GPU memory in the Aerial DU-Low — handover

## What the problem was

cuBB allocates all its GPU memory at startup and never releases it. On a GH200 running
one cell, the DU-Low holds **26 GiB**, of which **16 GiB is a single allocation**: the
fronthaul transmit buffer. Almost none of it is in use at any moment — it is a cyclic
ring sized for worst case. Anything else sharing the GPU, an AI workload for instance,
simply cannot have that memory.

The obvious fix does not work. The buffer is registered with the NIC, and every setter
in DOCA's `doca_eth_rxq.h` is documented *"can only be called before calling
doca_ctx_start()"*. Resizing means stopping the receive queue, which is a fronthaul
outage rather than a glitch.

## What we did

Left the buffer alone and changed what is behind it.

The virtual range keeps its address, its length and its mkey. Behind it we place fewer
physical pages, mapped repeatedly across the range, using the CUDA virtual memory API.
The NIC sweeps the full 16 GiB of address exactly as before; the physical footprint is
whatever fraction we choose. **DOCA observes nothing and the queue is never stopped.**

The range is cut into 16 slots, each mapped to a physical handle. With N distinct
handles, slot k uses handle k % N. Changing N repoints slots one at a time, so no more
than 1/16 of the range is unmapped at any instant.

## Result, measured

GH200 480GB, DU-High attached over FAPI, vLLM co-resident holding 47 GiB on the same
GPU. Nothing restarted between rows.

| command | physical backing | DU-Low process | CRC |
|---|---|---|---|
| start at 16 | 16,384 MiB | 26,146 MiB | 0 |
| `alias 8` | 8,192 | 17,952 | 0 |
| `alias 4` | 4,096 | 13,856 | 0 |
| `alias 2` | 2,048 | 11,808 | 0 |
| `alias 1` | 1,024 | **10,784** | 0 |
| `alias 16` | 16,384 | 26,144 | 0 |

**15.4 GiB released and reclaimed while the cell ran.** Every step matched prediction;
the round trip returns to within 2 MiB. At N=1 that is a 16x alias — 1 GiB of physical
memory behind a 16 GiB buffer the NIC believes it owns in full.

## The knob

**At startup**, environment variable on the DU-Low container:

    AERIAL_FH_ALIAS_N=16      # 16 = full backing (default is 1, which is the stock path)

**At runtime**, a file the DU-Low polls:

    echo "alias 4" > /var/log/aerial/fh_ctl     # results appear in fh_ctl.out

N ranges 1..16. Lower N means less physical memory. The file poller is a test harness,
not an API — the real control path belongs on the OAM gRPC service, off the real-time
cores.

## What is proven, and what is not

**Proven.** Physical memory behind a live, NIC-registered, DMA-active buffer can be
reduced 16x and restored on command, with no restart and no observable effect on the
cell. The memory genuinely leaves the process and is available to anything else on the
GPU.

**Not proven.** The cell was **idle** — 0.04 Mbps, SSB only, no UE attached. Aliasing
is correct only while the alias period exceeds the time a packet spends in the buffer,
and at that rate nothing exercises it. **N=1 passing here is not evidence that N=1 is
safe under load.** It shows the mechanism is sound. The safe value of N is unmeasured.

Two failure modes to keep apart when load testing:

- a NIC write landing in a slot during its unmapped window **faults** — shows as an abort
- an alias period shorter than a packet's lifetime **corrupts** — shows as CRC errors

The first is fixed by reshaping behind the ring's write pointer. The second sets the
real floor on N.

## Next steps

1. **Load test.** Attach a UE, repeat the sweep, find the N that survives.
2. **Close the unmapped window** by reading the ring write pointer and reshaping behind it.
3. **Move the control path** onto the OAM gRPC service so an external policy can drive it.

## Where the code is

<https://github.com/2YoY2/telco_cloud> — a patch series against Aerial `26-1-cubb`,
applied over a pristine tree rather than a fork. Upstream is Apache 2.0.

- `aerial-patches/patches/0005-...` — the aliasing patch (supersedes 0004)
- `gh/RESULT-hotswap.md` — this measurement in full
- `gh/step2-alias.md` — build and run procedure
- `aerial-patches/notes/` — the code audit behind the series

One platform constraint worth knowing: this needs GPUDirect RDMA to the NIC. It works
on GH200. On GB10 the NIC cannot register GPU memory at all
(`DOCA_ERROR_DRIVER` on `doca_mmap_start`), so none of this is reachable there — see
`aerial-patches/notes/05-fronthaul-blocked-on-gb10.md`.
