# aerial-patches

A patch series against the **NVIDIA Aerial CUDA-Accelerated RAN SDK**, adding dynamic GPU
resource management to cuBB's DU-Low.

This is deliberately *not* a fork of the SDK. The vendor tree stays pristine; every change we
make lives here as a numbered patch that is applied on top. That keeps each change reviewable
on its own, makes re-basing onto a new Aerial release a contained job, and keeps it obvious
which lines are ours.

## Baseline

| | |
|---|---|
| SDK | NVIDIA Aerial CUDA-Accelerated RAN SDK |
| version | `26-1-cubb` (the string in `aerial-sdk-version` at the tree root) |
| upstream licence | Apache 2.0 |

Patches are generated against an unmodified tree at that version. Applying them to a different
release will very likely need a rebase.

## Goal

cuBB allocates all GPU memory at startup and never releases it, and fixes each channel's SM
budget at init. For a DU that owns the GPU outright this is the right design. For AI-RAN
co-tenancy, where another workload should be able to use the GPU that the RAN is not using, it
means the RAN holds everything whether it needs it or not.

The aim is to make both dimensions negotiable at a safe boundary:

- **memory** — physical GPU pages owned by an external broker process, mapped into virtual
  addresses cuBB reserves once, so cuBB's pointers never move
- **SM budget** — repartitioned at a quiesce point rather than only at `l1_init`

The decision logic stays outside cuBB. cuBB only has to be permissive, and has to guarantee
nothing is reading a page before it is unmapped.

See [`notes/00-why.md`](notes/00-why.md) for the code audit these patches are built on.

## Layout

```
aerial-patches/
  series              ordered list of patches to apply
  patches/            the patches themselves, NNNN-short-name.patch
  scripts/apply.sh    apply the series to a target tree
  scripts/unapply.sh  reverse it
  scripts/mkpatch.sh  generate a patch from a modified tree
  notes/              the reasoning behind each patch
```

## Use

```sh
export AERIAL_SRC=/path/to/aerial-cuda-accelerated-ran

scripts/apply.sh          # apply every patch in series order
scripts/apply.sh --check  # dry run, touches nothing
scripts/unapply.sh        # reverse, last patch first
```

To add a change: edit the tree, then

```sh
scripts/mkpatch.sh 0001-short-name cuPHY-CP/cuphydriver/src/common/mps.cpp
```

which writes `patches/0001-short-name.patch` and appends it to `series`.

## Licence

Upstream is Apache 2.0, so derivative works are permitted. Apache 2.0 §4(b) requires modified
files to carry prominent notices stating that they were changed — each patch adds such a notice
to the files it touches, and the patch header records what changed and why.

The SDK *source* is Apache 2.0. The Aerial container and its NVIDIA and third-party
dependencies (CUDA, DOCA/GPUNetIO and others) are governed by their own terms; nothing in this
repository redistributes them.
