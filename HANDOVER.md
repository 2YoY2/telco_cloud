# Elastic GPU memory in the DU-Low — handing this over

Short version: the DU-Low can now give GPU memory back while it's running, and take it
again, without restarting anything. Here's what I did and how to drive it.

## The problem I was chasing

cuBB grabs all its GPU memory at startup and never lets go. On our GH200 with one cell
the DU-Low sits on **26 GiB**, and **16 GiB of that is one allocation** — the fronthaul
transmit buffer. It's a cyclic ring sized for worst case, so at any given moment almost
none of it is actually holding anything. If you want to run something else on that GPU,
an AI workload say, that 16 GiB is just gone.

I first tried the obvious thing: make the buffer smaller. That doesn't work. It's
registered with the NIC, and every setter in DOCA's `doca_eth_rxq.h` is documented
*"can only be called before calling doca_ctx_start()"*. So resizing it means stopping
the receive queue — that's a fronthaul outage, not a blip.

## What I ended up doing

Left the buffer completely alone and changed what sits behind it.

The virtual range keeps its address, its length and its mkey. Behind it I put fewer
physical pages, mapped several times across the range, using the CUDA virtual memory
API. The NIC still sweeps the full 16 GiB of address space exactly as before — it has
no idea anything changed. DOCA sees nothing, and the queue never stops.

Under the hood the range is cut into 16 slots, each pointing at a physical handle. With
N handles, slot k uses handle k % N. Changing N repoints the slots one at a time, so at
worst 1/16 of the range is unmapped for a moment.

## What it actually did

GH200, DU-High attached over FAPI, vLLM sitting on the same GPU with 47 GiB. I didn't
restart anything between these:

| what I ran | physical backing | DU-Low process | CRC |
|---|---|---|---|
| started at 16 | 16,384 MiB | 26,146 MiB | 0 |
| `alias 8` | 8,192 | 17,952 | 0 |
| `alias 4` | 4,096 | 13,856 | 0 |
| `alias 2` | 2,048 | 11,808 | 0 |
| `alias 1` | 1,024 | **10,784** | 0 |
| `alias 16` | 16,384 | 26,144 | 0 |

**15.4 GiB out and back, live.** Every step landed exactly where the arithmetic said it
would, and going back up returns to within 2 MiB of where it started. At N=1 that's a
16x alias — 1 GiB of real memory behind a 16 GiB buffer the NIC thinks it owns outright.

## How to drive it

At startup, an environment variable on the DU-Low container:

    AERIAL_FH_ALIAS_N=16      # 16 = full backing. Default is 1, which is the stock path.

While it's running, a file the DU-Low polls:

    echo "alias 4" > /var/log/aerial/fh_ctl      # it writes results to fh_ctl.out

N goes 1 to 16, lower means less memory held. Fair warning: the file poller is something
I threw together to test this. It isn't an API. If you take this further the control
path really belongs on the OAM gRPC service, off the real-time cores.

## Under real load

I first ran all of the above on an idle cell, so the obvious question was whether it
survives real traffic — aliasing is only correct while the alias period is longer than
a packet's lifetime in the buffer, and an idle cell never tests that.

It does survive. With a UE attached pushing **66–84 Mbps uplink**, roughly 590 slots a
tick, the CRC count sits at 7–86 per tick **at N=16, with no aliasing at all**. At N=4,
2 and 1 it was 15, 53 and 34 — the same range. The errors are the radio link, not the
memory. Note also that it isn't monotonic in N: N=1 is the most aggressive case and
came out better than N=2, which is not what a too-short alias period would look like.

So: 16x aliasing is clean under ~75 Mbps of uplink. What I did not get around to is a
proper rate comparison — the cumulative CRC counter over a fixed window at N=16 versus
N=1, rather than eyeballing per-tick numbers that swing between 7 and 86. That would
turn "same range" into a number, and it's an easy hour.

## What to watch if you push it further

Two things fail in different ways and it's worth telling them apart:

- a NIC write landing in a slot while it's briefly unmapped will **fault** — you'll see an abort
- an alias period that's too short **corrupts** — you'll see CRC errors above the link's own rate

I never saw either. The first goes away if you read the ring's write pointer and reshape
behind it, which is the one real piece of hardening still missing. The second is what
would tell you the floor on N, and at 75 Mbps we haven't found it.

## Where I'd go next

1. Do the rate comparison properly — cumulative CRC over 60s at N=16 vs N=1 — so the
   load result is a number rather than an observation.
2. Push the load higher and find where N actually breaks. 75 Mbps didn't do it.
3. Close the unmapped window by reshaping behind the ring write pointer.
4. Move the control onto gRPC so a policy engine can drive it instead of me echoing into
   a file.

## The code

<https://github.com/2YoY2/telco_cloud>

It's a patch series against Aerial `26-1-cubb`, applied on top of a pristine tree rather
than a fork, so rebasing onto a new release stays manageable. Upstream is Apache 2.0.

- `aerial-patches/patches/0005-...` — the aliasing patch (supersedes 0004)
- `gh/RESULT-hotswap.md` — the full measurement
- `gh/step2-alias.md` — how to build and run it
- `aerial-patches/notes/` — the code audit this all came out of

One thing that'll save you time: this needs GPUDirect RDMA to the NIC. It works on GH200.
It's impossible on GB10 — the NIC there can't register GPU memory at all, you just get
`DOCA_ERROR_DRIVER` from `doca_mmap_start`. I lost a while on that before working it out;
it's written up in `aerial-patches/notes/05-fronthaul-blocked-on-gb10.md`.
