# The fronthaul packet buffer cannot be made dynamic on GB10

A negative result, recorded so nobody spends time on it twice.

## The idea

The fronthaul packet buffer is the largest single block in a default configuration: at MTU
9120 it is `kGpuCommSendPeers x kMaxFlows x kMaxPktsFlow` slots of 16,384 bytes, which with
the peer count already cut to 4 is still **4 GiB**. Measured occupancy is about 224 packets
per slot against 262,144 slots.

It is a `DOCA_ETH_RXQ_TYPE_CYCLIC` ring, so the NIC sweeps the whole range and wraps roughly
twice a second. There is no spatially unused region to reclaim; the excess is *depth*, not
area. Two ways to exploit that:

1. **Shrink the ring.** Blocked while running: every setter in `doca_eth_rxq.h` is documented
   "can only be called before calling doca_ctx_start()", including `doca_eth_rxq_set_pkt_buf`.
   Resizing means stopping the receive queue, which is a fronthaul outage rather than a glitch.
2. **Alias the ring.** Keep the virtual range and the DOCA configuration exactly as they are,
   but map one physical allocation at several virtual offsets, so the NIC sweeps 4 GiB of
   address while the physical footprint wraps N times faster. DOCA sees no change at all: same
   mmap, same mkey, queue never stops. Correctness needs only that the alias period exceed the
   drain latency, and at 512 MiB backing that is ~146 slots against a ~2.7 slot drain, about
   50x margin.

Aliasing is the better idea and needs no queue restart. It also needs the packet buffer to be
GPU memory that VMM can map.

## Why neither works on this platform

Every configuration on the bench sets `gpu_init_comms_via_cpu: 1`, including NVIDIA's own
shipped `cuphycontroller_F08_GL4.yaml` and `cuphycontroller_P5G_WNC_DGX.yaml`. That is not a
default, it is a requirement. Setting it to 0 and starting the L1:

    DOCA exception [DOCA_ERROR_DRIVER] priv_doca_umem constructor failed
    Mmap: Failed to initialize memory range. Failed to register MR for device with id: 1.
    terminate called without an active exception

The NIC cannot register a memory region backed by GPU memory on this platform. Hardware is a
GB10 with ConnectX-7 (MT2910), and the GPU reports `GPUDirect RDMA supported: 1`, but the
registration fails in the driver regardless.

So on GB10 the fronthaul packet buffer is necessarily `DOCA_GPU_MEM_TYPE_CPU_GPU` registered
by its **CPU** address. It is not a device range, `cuMemMap` has nothing to grip, and neither
shrinking nor aliasing can be attempted.

This also explains the earlier finding that `cuMemGetHandleForAddressRange` with
`CU_MEM_RANGE_HANDLE_TYPE_DMA_BUF_FD` fails on GB10, and that `nvidia_peermem` sits at
refcount 0 while the fronthaul runs: nothing is registering GPU memory with the NIC because
nothing can.

## What that leaves

The idea is not wrong, it is untestable here. It needs a platform where the fronthaul buffer
lives in real GPU memory, which means GPUDirect RDMA working end to end with the NIC. A
Grace-Hopper machine is the obvious candidate.

On this bench the remaining target is the cuPHY channel objects, 2,198 MiB of PDSCH and PUSCH
allocated through `make_unique_device` in `cuphy_internal.h`. They have nothing to do with the
NIC, they are plain `cudaMalloc`, and they are larger than the fronthaul buffer is once MTU
2048 is in force. See [00-why.md](00-why.md) for the seam.
