# Step 2: resize the transmit buffer while the queue keeps running

Step 1 established that GH200 registers GPU memory with the NIC in dmabuf mode.
This is the resize itself.

## What the patch does

[`0004-fh-alias-the-transmit-buffer.patch`](../aerial-patches/patches/0004-fh-alias-the-transmit-buffer.patch)
adds one environment variable:

    AERIAL_FH_ALIAS_N=N

The transmit buffer keeps its full virtual range. Behind it goes **one physical
allocation of size/N, mapped N times across the range**. DOCA and the NIC see the
same base address, the same length and the same mkey, and the queue is never
stopped — which matters, because every setter in `doca_eth_rxq.h` is pre-start
only, so the obvious way to resize costs a fronthaul outage.

`N=1` is the default and does not enter the new code at all. The patch is inert
until you set the variable, and sweeping N needs no rebuild.

## Apply and build

```sh
cd <your cuBB source tree>
patch -p1 < ~/telco_cloud/aerial-patches/patches/0004-fh-alias-the-transmit-buffer.patch
ninja -C build.aarch64 aerial-fh
```

That builds `build.aarch64/cuPHY-CP/aerial-fh-driver/libaerial-fh.so`. Keep the
stock one first:

```sh
cp build.aarch64/cuPHY-CP/aerial-fh-driver/libaerial-fh.so ~/libaerial-fh.so.alias
```

## Run

Add two things to `run-du-low-gh.sh`: mount the library over the container's copy,
and pass the variable.

```sh
  -v $HOME/libaerial-fh.so.alias:/opt/nvidia/cuBB/build.aarch64/cuPHY-CP/aerial-fh-driver/libaerial-fh.so:ro \
  -e AERIAL_FH_ALIAS_N=${ALIAS_N:-1} \
```

Then, with `gpu_init_comms_via_cpu: 0` still set from step 1:

```sh
ALIAS_N=1 bash ~/gh-config/run-du-low-gh.sh     # baseline, should match today exactly
ALIAS_N=2 bash ~/gh-config/run-du-low-gh.sh     # half the physical memory
ALIAS_N=4 bash ~/gh-config/run-du-low-gh.sh
ALIAS_N=8 bash ~/gh-config/run-du-low-gh.sh
```

## What to look at, each run

```sh
sudo docker logs du-low 2>&1 | grep -a "TX buffer aliased"
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader
sudo docker exec du-low grep -a 'SCF.PHY] Cell' /var/log/aerial/phy.log | tail -2
sudo docker exec du-low grep -aoE "RX Packet Dropped Count\] \{ [0-9]+ \}" /var/log/aerial/phy.log | sort -u | tail -3
```

| | expected at N=1 | what a good N looks like | what a bad N looks like |
|---|---|---|---|
| `TX buffer aliased` line | absent | present, showing bytes returned | present |
| process GPU memory | ~26,146 MiB | falls by ~16 GiB × (1 − 1/N) | falls the same |
| DL Mbps | unchanged | unchanged | drops |
| CRC | 0 | 0 | **non-zero** |
| dropped RX packets | 0 | 0 | non-zero |

**A too-short alias period corrupts packets rather than crashing.** CRC and the
dropped counter are the detectors; do not read "it did not crash" as success.

## The load caveat

An idle cell (0.04 Mbps, no UE) barely touches the buffer, so it will tolerate a
large N that real traffic would not. The alias period has to exceed the time a
packet spends in the buffer, and that time only becomes meaningful under load.

So: sweep N idle to find where it breaks mechanically, then repeat under real
traffic before believing any number. The N that survives load is the answer; the
idle N is an upper bound and nothing more.

## If it works

The memory handed back is available to whatever else is on the GPU — vLLM was
holding 47,054 MiB alongside the DU-Low's 26,146 MiB when this was measured. That
is the co-tenancy result the whole series is aimed at.
