#!/usr/bin/env python3
"""
Answer the Pi's ARP probe for 192.168.2.1.

macOS/BSD refuses to reply to an ARP request whose sender is on a different
subnet than the target (the Pi asks "who-has 192.168.2.1 tell 10.12.194.1").
Linux and Windows both answer, which is why rpi-usb-gadget's ICS detection
works there and silently fails here.

This opens a BPF device on the gadget interface and emits the reply itself,
bypassing the kernel's subnet check. Pure stdlib -- no scapy, no install.
"""
import fcntl, os, struct, socket, sys, time

IFACE  = sys.argv[1] if len(sys.argv) > 1 else "en7"
TARGET = sys.argv[2] if len(sys.argv) > 2 else "192.168.2.1"

# macOS net/bpf.h ioctls
BIOCSETIF      = 0x8020426C
BIOCIMMEDIATE  = 0x80044270
BIOCGBLEN      = 0x40044266
BIOCSHDRCMPLT  = 0x80044275
BIOCSSEESENT   = 0x80044277
BPF_ALIGNMENT  = 4

def word_align(x):
    return (x + (BPF_ALIGNMENT - 1)) & ~(BPF_ALIGNMENT - 1)

def iface_mac(name):
    import subprocess
    out = subprocess.run(["ifconfig", name], capture_output=True, text=True).stdout
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("ether "):
            return bytes(int(b, 16) for b in line.split()[1].split(":"))
    raise SystemExit(f"no MAC on {name}")

def open_bpf(name):
    for i in range(256):
        path = f"/dev/bpf{i}"
        try:
            fd = os.open(path, os.O_RDWR)
        except OSError:
            continue
        try:
            fcntl.ioctl(fd, BIOCSETIF, struct.pack("16s16x", name.encode()))
        except OSError as e:
            os.close(fd)
            raise SystemExit(f"BIOCSETIF {name} failed: {e}")
        fcntl.ioctl(fd, BIOCIMMEDIATE, struct.pack("I", 1))
        fcntl.ioctl(fd, BIOCSHDRCMPLT, struct.pack("I", 1))
        fcntl.ioctl(fd, BIOCSSEESENT, struct.pack("I", 0))
        blen = struct.unpack("I", fcntl.ioctl(fd, BIOCGBLEN, struct.pack("I", 0)))[0]
        return fd, blen, path
    raise SystemExit("no free /dev/bpf device")

def main():
    if os.geteuid() != 0:
        raise SystemExit("must run as root")

    mac    = iface_mac(IFACE)
    target = socket.inet_aton(TARGET)
    fd, blen, path = open_bpf(IFACE)
    print(f"[arp-responder] {path} on {IFACE}, mac {mac.hex(':')}, "
          f"answering for {TARGET}", flush=True)

    replies = 0
    while True:
        try:
            buf = os.read(fd, blen)
        except InterruptedError:
            continue
        except OSError as e:
            # The fd is bound to a specific interface instance. A replug or
            # re-enumeration destroys that instance, after which every read
            # fails immediately -- retrying just spins at 100% CPU. Bail and
            # let the caller restart us against the new interface.
            print(f"[arp-responder] read failed: {e}. Interface was likely "
                  f"re-enumerated; exiting so it can be restarted.", flush=True)
            raise SystemExit(1)
        off = 0
        while off + 18 <= len(buf):
            # struct bpf_hdr: timeval32(8) caplen(4) datalen(4) hdrlen(2)
            caplen, _datalen, hdrlen = struct.unpack_from("=IIH", buf, off + 8)
            start = off + hdrlen
            pkt = buf[start:start + caplen]
            off += word_align(hdrlen + caplen)

            if len(pkt) < 42 or pkt[12:14] != b"\x08\x06":
                continue
            arp = pkt[14:42]
            htype, ptype, hlen, plen, oper = struct.unpack_from(">HHBBH", arp, 0)
            if htype != 1 or ptype != 0x0800 or oper != 1:
                continue
            sha, spa, _tha, tpa = arp[8:14], arp[14:18], arp[18:24], arp[24:28]
            if tpa != target:
                continue

            reply = (sha + mac + b"\x08\x06" +
                     struct.pack(">HHBBH", 1, 0x0800, 6, 4, 2) +
                     mac + target + sha + spa)
            try:
                os.write(fd, reply)
                replies += 1
                print(f"[arp-responder] replied to {socket.inet_ntoa(spa)} "
                      f"({sha.hex(':')})  total={replies}", flush=True)
            except OSError as e:
                print(f"[arp-responder] write failed: {e}", flush=True)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n[arp-responder] stopped", flush=True)
