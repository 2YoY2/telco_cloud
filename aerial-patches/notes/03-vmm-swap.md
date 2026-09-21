# Does cuBB run on VMM-backed memory?

Yes. This note records the first step toward dynamic memory: change *where* GPU memory
comes from, change nothing else, and confirm the cell is unaffected.

## The change

`device_alloc` is the IOBuf allocator policy behind `dev_buf`, and it is a plain
`cudaMalloc`/`cudaFree` pair. Patch
[0002](../patches/0002-vmm-back-large-device-allocations.patch) routes allocations of at
least 2 MiB through `cuMemAddressReserve` / `cuMemCreate` / `cuMemMap` instead.

Why a threshold rather than converting everything: VMM allocation granularity is 2 MiB on
GB10, and the `dev_buf` call sites are distributed like this:

| allocation size | call sites |
|---|---|
| 4 bytes (`1 * sizeof(uint32_t)` or `int`) | 23 |
| 1 to 8 bytes (`uint8_t`, `uint64_t`) | 4 |
| symbol-sized arrays | 7 |
| genuinely large (HARQ, wavgcfo, cv-bank, ulbuffer) | 4 |

27 of 38 sites allocate 1 to 8 bytes. Converting `device_alloc` wholesale would turn about
150 bytes of flags into 54 MiB of pages. The threshold excludes them by construction.

Nothing above the allocator changes. `IOBuf` is untouched, `dev_buf` is untouched, no call
site changes, and `deallocate` consults `vmm_alloc::owns()` so mixed ownership is safe.

## Result

| | |
|---|---|
| regions through the VMM path | **126, totalling 756 MiB** |
| which allocations | HARQ 4 MB and 8 MB classes; the 256 KiB class stays on cudaMalloc |
| downlink / uplink | 1,369.97 / 498.22 Mbps, unchanged |
| CRC errors | 0 |
| late slots | 1, i.e. baseline |
| footprint | 4,957 MiB against 4,955 stock |

The 2 MiB difference is granularity rounding: 3.81 MiB requests become 4.00, 7.63 become 8.00.

The path was confirmed rather than assumed. `vmm_alloc::allocate` prints one line per region:

    [VMM] region 1:   3.81 MiB requested, 4.00 MiB mapped at 0xf6e31ce00000
    [VMM] region 126: 7.63 MiB requested, 8.00 MiB mapped (total 756.0 MiB)

Without that, a silently-skipped VMM path and a working L1 look identical.

## What this does not do

Nothing is unmapped and no memory is returned to the driver while the process runs. This
patch only establishes that cuBB tolerates VMM-backed memory, which was not obvious given
that these buffers are handed to CUDA graphs and device kernels.

Two things are still missing before memory can shrink:

1. **An arena.** You can only unmap at 2 MiB granularity, so buffers must be packed into
   pages that can be retired as a unit. Today each region is its own reservation, so a page
   can only go when its single buffer does.
2. **A drain.** A page must never be unmapped while a kernel is reading it. HARQ already has
   `ref_count` decremented on callback regardless of CRC or timeout, which is the right
   mechanism; it needs extending to cover whole pages rather than single buffers.

## Bench hygiene

The shared Aerial tree was restored to stock afterwards: `gpudevice.hpp` reverted from
`gpudevice.hpp.pre-vmm`, `vmm_alloc.hpp` removed, and the stock `libcuphydriver.so` put back
in the build directory. The built library is kept outside the tree as
`libcuphydriver.so.vmm` and mounted over the container's copy at run time, the same pattern
used for `libaerial-fh.so.rightsized`. Object files in the shared build directory are stale
VMM builds; the next `ninja` restores consistency.
