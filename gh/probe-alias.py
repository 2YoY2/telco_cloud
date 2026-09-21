# Can one physical allocation be mapped at several virtual offsets?
# That is the whole basis of the "alias the ring" idea: the NIC sweeps a large VA
# range while the physical footprint wraps N times faster.
import ctypes
from ctypes import byref, c_int, c_void_p, c_size_t, c_ulonglong, c_ubyte, c_ushort, POINTER
cu = ctypes.CDLL("libcuda.so.1")
DPTR = c_ulonglong; HANDLE = c_ulonglong
class Loc(ctypes.Structure): _fields_=[("type",c_int),("id",c_int)]
class Flags(ctypes.Structure):
    _fields_=[("compressionType",c_ubyte),("gpuDirectRDMACapable",c_ubyte),("usage",c_ushort),("reserved",c_ubyte*4)]
class Prop(ctypes.Structure):
    _fields_=[("type",c_int),("requestedHandleTypes",c_int),("location",Loc),("win32HandleMetaData",c_void_p),("allocFlags",Flags)]
class Access(ctypes.Structure): _fields_=[("location",Loc),("flags",c_int)]
for f,a in [("cuMemCreate",[POINTER(HANDLE),c_size_t,POINTER(Prop),c_ulonglong]),
            ("cuMemGetAllocationGranularity",[POINTER(c_size_t),POINTER(Prop),c_int]),
            ("cuMemAddressReserve",[POINTER(DPTR),c_size_t,c_size_t,DPTR,c_ulonglong]),
            ("cuMemMap",[DPTR,c_size_t,c_size_t,HANDLE,c_ulonglong]),
            ("cuMemUnmap",[DPTR,c_size_t]),
            ("cuMemSetAccess",[DPTR,c_size_t,POINTER(Access),c_size_t]),
            ("cuMemsetD8_v2",[DPTR,c_ubyte,c_size_t]),
            ("cuMemcpyDtoH_v2",[c_void_p,DPTR,c_size_t]),
            ("cuMemcpyHtoD_v2",[DPTR,c_void_p,c_size_t])]:
    getattr(cu,f).argtypes=a
def err(rc):
    s=ctypes.c_char_p(); cu.cuGetErrorString(rc,byref(s)); return "rc=%d %s"%(rc,s.value.decode() if s.value else "?")
def ck(rc,w):
    if rc!=0: print("  FAIL %s: %s"%(w,err(rc))); raise SystemExit(1)
ck(cu.cuInit(0),"init"); dev=c_int(); cu.cuDeviceGet(byref(dev),0)
ctx=c_void_p(); cu.cuDevicePrimaryCtxRetain(byref(ctx),dev); cu.cuCtxSetCurrent(ctx)
prop=Prop(); prop.type=1; prop.location.type=1; prop.location.id=dev.value
acc=Access(); acc.location.type=1; acc.location.id=dev.value; acc.flags=3
g=c_size_t(); ck(cu.cuMemGetAllocationGranularity(byref(g),byref(prop),0),"gran")
G=g.value; N=4
print("  granularity %d KiB, aliasing one %d KiB allocation across %d slots" % (G//1024, G//1024, N))
h=HANDLE(); ck(cu.cuMemCreate(byref(h),G,byref(prop),0),"create")
va=DPTR(); ck(cu.cuMemAddressReserve(byref(va),G*N,G,DPTR(0),0),"reserve")
for k in range(N):
    ck(cu.cuMemMap(DPTR(va.value+k*G),G,0,h,0),"map alias %d"%k)
ck(cu.cuMemSetAccess(va,G*N,byref(acc),1),"setAccess")
print("  mapped the SAME physical pages at 0x%x .. 0x%x" % (va.value, va.value+(N-1)*G))
# write through alias 0, read through alias 2
src=(c_ubyte*8)(*[0xA0+i for i in range(8)])
ck(cu.cuMemcpyHtoD_v2(va,src,8),"write via alias 0")
out=(c_ubyte*8)()
ck(cu.cuMemcpyDtoH_v2(out,DPTR(va.value+2*G),8),"read via alias 2")
same = list(out)==list(src)
print("  wrote via alias 0, read via alias 2: %s  %s" % ([hex(x) for x in out[:4]], "ALIASING WORKS" if same else "NOT ALIASED"))
# write through alias 3, read through alias 1
src2=(c_ubyte*8)(*[0x50+i for i in range(8)])
ck(cu.cuMemcpyHtoD_v2(DPTR(va.value+3*G),src2,8),"write via alias 3")
out2=(c_ubyte*8)()
ck(cu.cuMemcpyDtoH_v2(out2,DPTR(va.value+1*G),8),"read via alias 1")
print("  wrote via alias 3, read via alias 1: %s  %s" % ([hex(x) for x in out2[:4]], "ALIASING WORKS" if list(out2)==list(src2) else "NOT ALIASED"))
for k in range(N): cu.cuMemUnmap(DPTR(va.value+k*G),G)
