#!/usr/bin/env python3
"""CUDA-side probes that decide whether the fronthaul aliasing plan is reachable.

Needs no L1, no NIC, no traffic.  Run it inside the Aerial container, or anywhere
libcuda is present:

    python3 probe-gh.py

Reference results on GB10, where the plan is blocked:
    VMM supported .......... yes
    aliasing ............... WORKS
    cross-process sharing .. WORKS
    dmabuf export .......... FAILS   <-- the one expected to differ on Grace Hopper
"""
import ctypes, os, socket, array, sys
from ctypes import byref, c_int, c_void_p, c_size_t, c_ulonglong, c_ubyte, c_ushort, POINTER

cu = ctypes.CDLL("libcuda.so.1")
DPTR = c_ulonglong; HANDLE = c_ulonglong

class Loc(ctypes.Structure):   _fields_ = [("type", c_int), ("id", c_int)]
class Flags(ctypes.Structure):
    _fields_ = [("compressionType", c_ubyte), ("gpuDirectRDMACapable", c_ubyte),
                ("usage", c_ushort), ("reserved", c_ubyte * 4)]
class Prop(ctypes.Structure):
    _fields_ = [("type", c_int), ("requestedHandleTypes", c_int), ("location", Loc),
                ("win32HandleMetaData", c_void_p), ("allocFlags", Flags)]
class Access(ctypes.Structure): _fields_ = [("location", Loc), ("flags", c_int)]

for f, a in [("cuMemCreate", [POINTER(HANDLE), c_size_t, POINTER(Prop), c_ulonglong]),
             ("cuMemGetAllocationGranularity", [POINTER(c_size_t), POINTER(Prop), c_int]),
             ("cuMemAddressReserve", [POINTER(DPTR), c_size_t, c_size_t, DPTR, c_ulonglong]),
             ("cuMemAddressFree", [DPTR, c_size_t]),
             ("cuMemMap", [DPTR, c_size_t, c_size_t, HANDLE, c_ulonglong]),
             ("cuMemUnmap", [DPTR, c_size_t]),
             ("cuMemRelease", [HANDLE]),
             ("cuMemSetAccess", [DPTR, c_size_t, POINTER(Access), c_size_t]),
             ("cuMemExportToShareableHandle", [c_void_p, HANDLE, c_int, c_ulonglong]),
             ("cuMemGetHandleForAddressRange", [c_void_p, DPTR, c_size_t, c_int, c_ulonglong]),
             ("cuMemcpyHtoD_v2", [DPTR, c_void_p, c_size_t]),
             ("cuMemcpyDtoH_v2", [c_void_p, DPTR, c_size_t])]:
    getattr(cu, f).argtypes = a

def err(rc):
    s = ctypes.c_char_p(); cu.cuGetErrorString(rc, byref(s))
    return "rc=%d %s" % (rc, s.value.decode() if s.value else "?")

cu.cuInit(0)
dev = c_int(); cu.cuDeviceGet(byref(dev), 0)
ctx = c_void_p(); cu.cuDevicePrimaryCtxRetain(byref(ctx), dev); cu.cuCtxSetCurrent(ctx)
name = ctypes.create_string_buffer(64); cu.cuDeviceGetName(name, 64, dev)
print("  device: %s" % name.value.decode())

prop = Prop(); prop.type = 1; prop.location.type = 1; prop.location.id = dev.value
acc = Access(); acc.location.type = 1; acc.location.id = dev.value; acc.flags = 3
g = c_size_t(); rc = cu.cuMemGetAllocationGranularity(byref(g), byref(prop), 0)
if rc != 0:
    print("  VMM supported .......... NO (%s)  -- the plan is dead here" % err(rc)); sys.exit(1)
G = g.value
print("  VMM supported .......... yes, granularity %d KiB" % (G // 1024))

# --- aliasing: the basis of the whole plan -------------------------------------
N = 4
h = HANDLE(); cu.cuMemCreate(byref(h), G, byref(prop), 0)
va = DPTR(); cu.cuMemAddressReserve(byref(va), G * N, G, DPTR(0), 0)
ok = all(cu.cuMemMap(DPTR(va.value + k * G), G, 0, h, 0) == 0 for k in range(N))
cu.cuMemSetAccess(va, G * N, byref(acc), 1)
src = (c_ubyte * 8)(*range(0xA0, 0xA8)); out = (c_ubyte * 8)()
cu.cuMemcpyHtoD_v2(va, src, 8)
cu.cuMemcpyDtoH_v2(out, DPTR(va.value + 2 * G), 8)
alias_ok = ok and list(out) == list(src)
print("  aliasing ............... %s (one allocation at %d addresses)"
      % ("WORKS" if alias_ok else "FAILS", N))

# --- dmabuf export: the bridge to doca_mmap_set_dmabuf_memrange ----------------
fd = c_int(-1)
rc = cu.cuMemGetHandleForAddressRange(byref(fd), va, G * N, 1, 0)   # DMA_BUF_FD
print("  dmabuf export .......... %s" % ("WORKS, fd=%d" % fd.value if rc == 0 else "FAILS (%s)" % err(rc)))
if rc == 0: os.close(fd.value)
dmabuf_ok = rc == 0
for k in range(N): cu.cuMemUnmap(DPTR(va.value + k * G), G)
cu.cuMemAddressFree(va, G * N); cu.cuMemRelease(h)

# --- exportable handle: needed only for a broker-owned arena -------------------
p2 = Prop(); p2.type = 1; p2.location.type = 1; p2.location.id = dev.value; p2.requestedHandleTypes = 1
h2 = HANDLE(); rc = cu.cuMemCreate(byref(h2), G, byref(p2), 0)
share_ok = False
if rc == 0:
    fd2 = c_int(); share_ok = cu.cuMemExportToShareableHandle(byref(fd2), h2, 1, 0) == 0
    if share_ok: os.close(fd2.value)
    cu.cuMemRelease(h2)
print("  cross-process sharing .. %s" % ("WORKS" if share_ok else "FAILS"))

print()
if alias_ok:
    print("  Aliasing is available, so the plan stands or falls on step 1 of the README:")
    print("  set gpu_init_comms_via_cpu to 0 and see whether the NIC registers GPU memory.")
    if dmabuf_ok:
        print("  dmabuf export works here, so doca_mmap_set_dmabuf_memrange is reachable too.")
    else:
        print("  dmabuf export fails, so only the nvidia-peermem path could work.")
else:
    print("  Aliasing does not work on this device. The plan is dead; use a smaller static")
    print("  ring via kMaxPktsFlow instead (see the README).")
