#!/usr/bin/env python3
"""
Can we inject a raw ethernet frame on this interface at all?

BPF write is silently dropped on Skywalk-backed interfaces. macOS also offers
AF_NDRV raw link-layer sockets. Send one ARP reply by each method and check
whether the interface's Opkts counter actually moves.
"""
import ctypes, fcntl, os, struct, socket, subprocess, sys, time

def _gadget_iface():
    """Interface from .gadget-if at the repo root, else ask networksetup."""
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    try:
        v = open(os.path.join(root, ".gadget-if")).read().strip()
        if v:
            return v
    except OSError:
        pass
    out = os.popen("networksetup -listallhardwareports 2>/dev/null").read().split("\n")
    for i, line in enumerate(out):
        if "Raspberry Pi USB Gadget" in line and i + 1 < len(out):
            return out[i + 1].split()[-1]
    sys.exit("no gadget interface found; pass one as the first argument")

IFACE = sys.argv[1] if len(sys.argv) > 1 else _gadget_iface()
SRC_IP = "192.168.2.1"
DST_IP = "10.12.194.1"

BIOCSETIF     = 0x8020426C
BIOCSHDRCMPLT = 0x80044275
AF_NDRV       = 27
SOCK_RAW      = 3

def opkts(ifn):
    out = subprocess.run(["netstat", "-I", ifn, "-b"], capture_output=True, text=True).stdout
    for line in out.splitlines()[1:]:
        f = line.split()
        if len(f) > 7 and f[0] == ifn:
            return int(f[7])
    return -1

def iface_mac(ifn):
    out = subprocess.run(["ifconfig", ifn], capture_output=True, text=True).stdout
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("ether "):
            return bytes(int(b, 16) for b in s.split()[1].split(":"))
    raise SystemExit(f"no MAC on {ifn}")

def pi_mac():
    out = subprocess.run(["arp", "-an"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if DST_IP in line and "incomplete" not in line:
            parts = line.split()
            for p in parts:
                if p.count(":") == 5:
                    return bytes(int(b, 16) for b in
                                 (x.zfill(2) for x in p.split(":")))
    return b"\xff" * 6   # fall back to broadcast

def build_reply(smac, dmac):
    return (dmac + smac + b"\x08\x06" +
            struct.pack(">HHBBH", 1, 0x0800, 6, 4, 2) +
            smac + socket.inet_aton(SRC_IP) +
            dmac + socket.inet_aton(DST_IP))

def try_bpf(frame, ifn):
    for i in range(64):
        try:
            fd = os.open(f"/dev/bpf{i}", os.O_RDWR)
        except OSError:
            continue
        try:
            fcntl.ioctl(fd, BIOCSETIF, struct.pack("16s16x", ifn.encode()))
            fcntl.ioctl(fd, BIOCSHDRCMPLT, struct.pack("I", 1))
            n = os.write(fd, frame)
            os.close(fd)
            return f"wrote {n} bytes"
        except OSError as e:
            os.close(fd)
            return f"error: {e}"
    return "no free bpf device"

def _libc():
    c = ctypes.CDLL("libc.dylib", use_errno=True)
    c.socket.argtypes  = [ctypes.c_int, ctypes.c_int, ctypes.c_int]
    c.socket.restype   = ctypes.c_int
    c.bind.argtypes    = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    c.bind.restype     = ctypes.c_int
    c.connect.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    c.connect.restype  = ctypes.c_int
    c.write.argtypes   = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t]
    c.write.restype    = ctypes.c_ssize_t
    c.sendto.argtypes  = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t,
                          ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    c.sendto.restype   = ctypes.c_ssize_t
    c.close.argtypes   = [ctypes.c_int]
    return c

def _ndrv_sock(libc, ifn):
    """socket + bind, returns (fd, sockaddr_buffer) or (-1, reason)"""
    fd = libc.socket(AF_NDRV, SOCK_RAW, 0)
    if fd < 0:
        return -1, f"socket() failed: {os.strerror(ctypes.get_errno())}"
    sa = struct.pack("BB16s", 18, AF_NDRV, ifn.encode())
    buf = ctypes.create_string_buffer(sa, 18)
    if libc.bind(fd, buf, 18) < 0:
        err = os.strerror(ctypes.get_errno())
        libc.close(fd)
        return -1, f"bind() failed: {err}"
    return fd, buf

def try_ndrv_connect(frame, ifn):
    """bind + connect, then write() -- write needs a connected socket"""
    libc = _libc()
    fd, buf = _ndrv_sock(libc, ifn)
    if fd < 0:
        return buf
    if libc.connect(fd, buf, 18) < 0:
        err = os.strerror(ctypes.get_errno())
        libc.close(fd)
        return f"connect() failed: {err}"
    n = libc.write(fd, ctypes.c_char_p(frame), len(frame))
    err = os.strerror(ctypes.get_errno()) if n < 0 else None
    libc.close(fd)
    return f"write() failed: {err}" if n < 0 else f"wrote {n} bytes"

def try_ndrv_sendto(frame, ifn):
    """bind, then sendto() with the destination sockaddr supplied"""
    libc = _libc()
    fd, buf = _ndrv_sock(libc, ifn)
    if fd < 0:
        return buf
    n = libc.sendto(fd, ctypes.c_char_p(frame), len(frame), 0, buf, 18)
    err = os.strerror(ctypes.get_errno()) if n < 0 else None
    libc.close(fd)
    return f"sendto() failed: {err}" if n < 0 else f"sent {n} bytes"

def main():
    if os.geteuid() != 0:
        raise SystemExit("run as root")

    smac, dmac = iface_mac(IFACE), pi_mac()
    frame = build_reply(smac, dmac)
    print(f"interface {IFACE}  src {smac.hex(':')}  dst {dmac.hex(':')}")
    print(f"frame: {len(frame)} bytes\n")

    methods = (("BPF write", try_bpf),
               ("AF_NDRV connect+write", try_ndrv_connect),
               ("AF_NDRV sendto", try_ndrv_sendto))
    for name, fn in methods:
        before = opkts(IFACE)
        result = fn(frame, IFACE)
        time.sleep(1.5)
        after = opkts(IFACE)
        moved = after - before
        verdict = "*** TRANSMITTED ***" if moved > 0 else "dropped (Opkts unchanged)"
        print(f"{name:22s} {result:34s} Opkts {before} -> {after}  {verdict}")

    print("\nIf AF_NDRV transmitted, the responder can be rewritten to use it.")
    print("If neither did, raw injection is unavailable on this interface.")

if __name__ == "__main__":
    main()
