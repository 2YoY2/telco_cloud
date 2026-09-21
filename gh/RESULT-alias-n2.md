# Aliasing works: 8 GiB returned from a registered fronthaul buffer

GH200 480GB, DU-Low with `gpu_init_comms_via_cpu: 0`, DU-High attached over FAPI,
vLLM co-resident on the same GPU. 21 Sep 2026.

## Result

```
[FH.DOCA] TX buffer aliased x2: 17179869184B virtual backed by 8589934592B physical,
          8589934592B returned
[FH.DOCA] Mapping transmit queue buffer (0x340000000 size 17179869184B dmabuf fd 237)
          with dmabuf mode
```

| | baseline (N=1) | aliased (N=2) |
|---|---|---|
| process GPU memory | 26,146 MiB | **17,952 MiB** |
| virtual size the NIC sees | 17,179,869,184 B | 17,179,869,184 B |
| physical backing | 16 GiB | **8 GiB** |
| registration | dmabuf, fd 237 | dmabuf, fd 237 |
| DL | 0.04 Mbps | 0.04 Mbps |
| CRC | 0 | 0 |

8,194 MiB returned against 8,192 predicted.

## What was actually uncertain

That DOCA and the NIC would accept a virtual range with duplicate physical mappings.
Three plausible failure modes: write-combining, cache coherence between the NIC's
view and the GPU's, and mkey translation caching. None of them bit.
`doca_gpu_dmabuf_fd` succeeded on the aliased range and
`doca_mmap_set_dmabuf_memrange` registered the full 16 GiB, exactly as for a plain
allocation. The queue never knew.

The control run matters as much as the result: at N=1 with the same rebuilt library
mounted, the footprint was 26,146 MiB, no alias line appeared, and the registration
was byte-identical. So the 8 GiB is the aliasing, not the rebuild or the mount.

## What this does not yet show

**The cell was idle** — 0.04 Mbps, SSB only, no UE. The buffer is barely touched, so
this establishes that the *mechanism* is sound, not that the alias period is safe
under load. Correctness needs the alias period to exceed the time a packet spends in
the buffer, and at 0.04 Mbps that is not being tested.

**It is still allocation-time.** N is fixed when the queue is created, so each value
needs an L1 restart. Changing the backing while the queue runs is the next patch, and
it is reachable precisely because of what this shows: the virtual address never moves
and DOCA never observes a change, so remapping later is the same operation at a
different moment.

## Next

1. Raise N (4, 8, 16) to find where it breaks mechanically, idle.
2. Put real traffic on it and repeat. The N that survives load is the answer; the
   idle N is an upper bound and nothing more.
3. Then runtime remap: `cuMemUnmap` and `cuMemMap` a subset of the aliases on a live
   queue, no restart.

For co-tenancy: vLLM was holding 47,054 MiB alongside the DU-Low on the same GPU when
this was measured, so the 8 GiB goes somewhere useful.
