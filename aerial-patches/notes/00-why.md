# Why these patches exist

A code audit of Aerial `26-1-cubb` plus measurements on a single-cell 4T4R 100 MHz bench.
File and line references are to the unmodified SDK tree.

## What cuBB does today

Every GPU allocation happens before traffic starts, and nothing is released while the process
lives. Each channel's SM budget is fixed at `l1_init` from `mps_sm_*` in the controller YAML and
never changes. For a DU that owns its GPU this is correct: a hard 500 µs slot deadline means no
allocation may happen on the slot path, and the safest way to guarantee that is to allocate
nothing at all once running.

The cost is that the RAN holds the whole GPU whether or not it is using it.

## Five findings

**1. There is no quiescence protocol.** `Cell::stop()` is the entire stop path:

```c
void Cell::stop() { active = CELL_INACTIVE; active_srs = CELL_INACTIVE; }
```

Two atomic stores — a flag, not a drain. It does not wait for in-flight work, synchronise with
the GPU, or flush a queue. `cell_status` (`cuPHY-CP/cuphydriver/include/cell.hpp:37`) has exactly
three values: `CELL_ACTIVE`, `CELL_INACTIVE`, `CELL_UNHEALTHY`. There is no draining state.

**2. Teardown is therefore disabled.** `PhyDriverCtx::removeCell`
(`cuPHY-CP/cuphydriver/src/common/context.cpp:2123`) only calls `stop()`; the real teardown sits
in `#if 0` at line 2132 and is an unbounded spin-wait carrying `/* TBD set a max tentative
number */` and a comment noting the object "will never be freed" if no worker runs. An unbounded
poll in a control path is not shippable, so it was switched off. `l1_cell_destroy` is exported
but dead.

**3. The ownership discipline exists one level down.** A search for *quiesce*, *drain*,
*inflight* or *refcount* across every cuphydriver header hits exactly two files,
`harq_pool.hpp` and `wavgcfo_pool.hpp`:

```c
std::atomic<int> ref_count;   // decremented on callback regardless of CRC/timeout
```

Objects that churn every slot have a correct bounded protocol. Cells do not.

**4. Cells are columns in a batch, not entities.** Every channel is aggregated —
`phypusch_aggr`, `phypdsch_aggr`, `phypdcch_aggr`, `phypucch_aggr`, `phyprach_aggr`,
`physrs_aggr`, `phypbch_aggr`, `phycsirs_aggr`, `phydlbfw_aggr`. One object per channel processes
all `cellGrpDynPrm.nCells` cells in a slot together. A HARQ buffer has an unambiguous begin and
end, which is what a reference count needs; a cell has neither. So refcounting a cell would mean
bolting per-entity ownership onto a batch design. Draining by *epoch* fits the architecture
instead of fighting it.

**5. The skeleton is frozen, but the flesh is not.** `cudaGraphExecUpdate` appears nowhere in the
tree, so instantiated graphs are never mutated. `API_MAX_NUM_CELLS` is a compile-time power of
two (`cuPHY-CP/aerial-fh-driver/include/aerial-fh-driver/api.hpp:252`, commented "power of 2 for
DOCA") and per-cell state lives in arrays kernels index. You cannot remove an entry from such an
array — only mark it unused, which is what `Cell::stop()` does.

But pointers already reach kernels through indirection. `pHarqBuffersInOut`
(`cuPHY-CP/cuphydriver/src/uplink/phypusch_aggr.cpp:194`) is a GPU-mapped table allocated once,
whose entries are rewritten every slot (line 823) and may be set to `NULL` (line 890). The
fronthaul's `FlowPtrInfo` table has the same shape. So what a kernel points at is already
changeable at runtime; only the table's own address is fixed.

That is the opening these patches use.

## Measurements that scope the work

| | |
|---|---|
| stock footprint, one cell | 24,747 MiB |
| after right-sizing (MTU 2048, `max_harq_pools: 64`, `kGpuCommSendPeers` 4) | 4,955 MiB |
| dominant blocks, stock | packet buffer 16 GiB (66 %), HARQ 4.5 GiB (18 %) |
| a full cell runs on | 6 PDSCH + 5 PUSCH SMs out of 48, zero CRC |
| cost of that floor | +376 µs uplink delivery, no throughput loss |
| uplink pipeline depth | 3.3 slots; result delivered 564 µs after the slot ends |
| cost of one add/remove | ~0.5 late slots, independent of block size |
| cost of a co-tenant merely creating a context | ~100 late slots |

Two consequences. Resizing is per-operation, not per-byte, so one large renegotiation is far
cheaper than many small ones — the control layer should work in epochs. And the pipeline depth is
known and bounded, so a drain can be bounded by construction rather than by a timeout guess.

## Platform notes

Cross-process GPU memory ownership works: `cuMemCreate` with
`CU_MEM_HANDLE_TYPE_POSIX_FILE_DESCRIPTOR`, `cuMemExportToShareableHandle`, the fd passed over a
unix socket, then `cuMemImportFromShareableHandle` and `cuMemMap` in the consumer. Verified on
GB10, 2 MiB granularity. Note that
`CU_DEVICE_ATTRIBUTE_HANDLE_TYPE_POSIX_FILE_DESCRIPTOR_SUPPORTED` reports 0 on that part while the
calls succeed, so the path works but is not advertised.

`cuMemGetHandleForAddressRange` with `CU_MEM_RANGE_HANDLE_TYPE_DMA_BUF_FD` fails on GB10, so a VMM
range cannot be handed to `doca_mmap_set_dmabuf_memrange`. The nvidia-peermem fallback,
`doca_mmap_set_memrange(mmap, addr, size)`, takes a plain address and length and does not require
a DOCA-allocated pointer — structurally open, untested.

## Planned series

Nothing is written yet. Intended order, easiest and most valuable first:

| # | patch | depends on |
|---|---|---|
| 0001 | back `HarqPool`'s arena with a reserved VA range instead of a direct allocation | — |
| 0002 | add `poolCreate` / `poolDestroy` to `HarqPoolManager` (today `poolAlloc` only *finds*) | 0001 |
| 0003 | add `CELL_DRAINING` and a last-seen-slot stamp set from `cellGrpDynPrm` | — |
| 0004 | bounded teardown using 0003, replacing the `#if 0` block | 0003 |
| 0005 | import / map / unmap surface behind the existing OAM gRPC path, executed off the real-time cores | 0001-0004 |
| 0006 | extend the green-context SM granularity table past compute capability 9 and lift the split out of init | — |

0001 and 0002 target HARQ because it is already pooled, already reference-counted and already has
a lock-free free list — the least new machinery for the most reclaimable memory. The packet buffer
is deliberately last: it is NIC-registered, and right-sizing already removed most of it statically.
