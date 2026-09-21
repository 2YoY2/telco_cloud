# Handing GPU memory back while the cell runs

This is the first result where memory actually moves. 692 MiB returned to the driver and
taken again, with one 4T4R 100 MHz cell carrying full F08 traffic throughout.

## The interlock was already there

A HARQ buffer sitting in the free ring has been returned by its callback. Nothing holds it,
its `ref_count` is zero. So dequeueing it and releasing its pages is safe with **no new
drain protocol at all** — for this case the ring *is* the drain. What was missing was only
the ability to drop pages without destroying the address, which patch 0002 provided.

That is why this step came before the arena and before a general drain: it is the one case
where cuBB already knows a buffer is quiescent.

## Result

| step | GPU | mapped | DL / UL Mbps | CRC | late |
|---|---|---|---|---|---|
| baseline | 4,971 MiB | 756 MiB | 1,369.97 / 498.22 | 0 | 1 |
| retire 40 | 4,811 | 596 | 1,369.97 / 498.22 | 0 | 1 |
| retire 80 more | **4,279** | 64 | 1,369.97 / 498.22 | 0 | 2 |
| restore all | 4,971 | 756 | 1,369.97 / 498.22 | 0 | 2 |
| settled | 4,971 | 756 | 1,369.97 / 498.22 | 0 | 2 |

Throughput never moved. CRC stayed at zero. Late slots went from 1 to 2 across the entire
run, which is baseline noise — section 16 of the bench log measured ~0.5/min at rest.

The allocator's own mapped-bytes counter tracks the nvidia-smi figure exactly: 756 -> 596 ->
64 -> 756 MiB against 4,971 -> 4,811 -> 4,279 -> 4,971. The memory genuinely leaves the
process; it is not an accounting artefact.

## What broke on the first attempt

`restore` threw and terminated the L1:

    terminate called after throwing an instance of 'std::runtime_error'

`restore_physical` called `cuCtxGetDevice` to rebuild the allocation property, and the
watcher thread had no CUDA context. Retire never hits that path, which is exactly why
retire worked and only restore failed.

Two fixes, both worth keeping:

1. `Region` now captures the `CUmemAllocationProp` at allocation time, so a restore never
   re-queries the device.
2. The watcher retains a primary context, and wraps the work in try/catch. **A failed resize
   must never take the L1 down.** The first revision proved it can.

## What this does not do

- Only **free** buffers can be retired. Nothing in flight is touched, and the pool starves
  if asked to return more than traffic leaves idle.
- Each buffer is still its own reservation, so 2 MiB granularity is paid per buffer rather
  than per arena. Packing buffers into pages that retire as a unit is a later patch.
- The control path is a file poller. That is a test harness, not the API — the real one
  belongs on the OAM gRPC service, driven by `oam_cell_update`, off the real-time cores.

## Where the ceiling is

756 MiB of a 4,971 MiB footprint is about 15 %. Even perfect HARQ elasticity reclaims that
much and no more, because right-sizing already removed most of the fat statically
(24,747 -> 4,955 MiB). Extending coverage to the per-cell pipeline buffers is what would
raise the ceiling.
