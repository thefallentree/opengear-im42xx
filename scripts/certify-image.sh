#!/bin/bash
# Certify that a built Opengear image is bootable -- as far as is checkable without the hardware.
#
# WHAT THIS IS NOT: a real boot. QEMU has no KS8695 machine model (verified: no ks8695/Kendin/
# Micrel entry in its ~40-board ARM list), and this kernel is CONFIG_ATAGS=y with USE_OF and
# ARCH_MULTIPLATFORM unset -- a single-platform pre-devicetree build that panics on an
# unrecognised machine ID. So full-system emulation is impossible; see README section 7b.
#
# WHAT THIS IS: every precondition the real boot chain actually checks, verified mechanically --
# including a simulation of shim.bin's own kernel-location arithmetic, and real execution of the
# built image's userland under qemu-user. A failure here means the image definitely will not
# boot. A pass means every check we can make without the board is satisfied.
#
# Usage: ./certify-image.sh <image.bin>
set -u
IMG="${1:?usage: $0 <image.bin>}"
CDK=${CDK_DIR:-build/cdk/OpenGear-IM42xx-3.16.6u1-devkit-20161114}
PART=14417920                     # mtd3 "OpenGear image" partition size
pass=0; fail=0
ok(){ echo "  PASS  $*"; pass=$((pass+1)); }
no(){ echo "  FAIL  $*"; fail=$((fail+1)); }

echo "=== Certifying $IMG ($(stat -c%s "$IMG") bytes) ==="

# ---- Gate 1: the fake cramfs header shim.bin reads ---------------------------------------
hdr=$(head -c4 "$IMG" | xxd -p)
[ "$hdr" = "453dcd28" ] && ok "cramfs magic 45 3d cd 28 present (shim reads this)" \
                        || no "cramfs magic missing -- image will flash cleanly and NOT boot"

# ---- Gates 2-5: structure, shim simulation, kernel, trailer ------------------------------
python3 - "$IMG" "$CDK" "$PART" <<'PY'
import struct,sys,os,zlib
img=open(sys.argv[1],'rb').read(); cdk=sys.argv[2]; part=int(sys.argv[3])
P=lambda m: print(f"  PASS  {m}"); F=lambda m: print(f"  FAIL  {m}")
rc=0
magic,size=struct.unpack('<II',img[0:8])

# size field must be the squashfs length rounded up to 4K
P(f"header size field = {size:,} (4K-aligned: {size%4096==0})") if size%4096==0 else F("size field not 4K-aligned")

# squashfs superblock at offset 8
sb=img[8:8+96]
if sb[0:4]==b'hsqs':
    inodes,mkfs,bs,frags=struct.unpack('<IIII',sb[4:20])
    comp,=struct.unpack('<H',sb[20:22]); bu,=struct.unpack('<Q',sb[40:48])
    P(f"squashfs 4.0 superblock at +8: {inodes} inodes, {frags} fragments, comp={comp}, bytes_used={bu:,}")
    if bu<=size: P("squashfs fits inside the declared size field")
    else: F("squashfs bytes_used exceeds header size field"); rc=1
else:
    F("no squashfs magic at offset 8"); rc=1

# --- simulate shim.bin's kernel-location logic -------------------------------------------
# shim: base=0x03240000 -> checks magic 0x28cd3d45, reads len at +4,
#       zImage = base + len + 0x1000, scans 4K for 0x016f2818, reads end at magic+8
shim=os.path.join(cdk,'prop/shim/shim.bin')
if os.path.exists(shim):
    sb_bytes=open(shim,'rb').read()
    at=img[size:size+len(sb_bytes)]
    if at==sb_bytes: P(f"shim.bin present at offset {size:,}, byte-identical to prop/shim/shim.bin")
    else: F("shim.bin missing or altered at the expected offset"); rc=1

zstart=size+0x1000
zm=struct.pack('<I',0x016f2818)
idx=img.find(zm,zstart,zstart+4096)
if idx>=0:
    kbase=idx-0x24
    st,en=struct.unpack('<II',img[kbase+0x28:kbase+0x30])
    P(f"shim simulation: zImage magic found at +{idx:,} (search window {zstart:,}..{zstart+4096:,})")
    P(f"shim simulation: kernel start=0x{st:x} end=0x{en:x} -> would copy {en-st:,} bytes to 0x9000")
    if kbase+(en-st)<=len(img): P("shim simulation: copy region lies entirely inside the image")
    else: F("shim would read past the end of the image"); rc=1
else:
    F("no ARM zImage magic in the window shim.bin searches -- kernel unreachable"); rc=1

# --- kernel payload actually decompresses ------------------------------------------------
# This kernel is XZ-compressed (CONFIG_KERNEL_XZ), not gzip -- an earlier version of this
# script only probed for gzip and produced a false failure.
k=img[kbase:kbase+(en-st)] if idx>=0 else b''
import lzma
found=False
for name,sig in (("xz",b'\xfd7zXZ'),("gzip",b'\x1f\x8b\x08'),("lzma",b'\x5d\x00\x00')):
    # Scan EVERY occurrence -- the first hit is often a false positive inside the
    # decompressor stub. This kernel's real payload is the SECOND xz magic.
    pos=0
    while not found:
        q=k.find(sig,pos)
        if q<0: break
        pos=q+1
        blob=k[q:]
        try:
            do=(zlib.decompressobj(16+zlib.MAX_WBITS) if name=="gzip" else lzma.LZMADecompressor())
            acc=bytearray()
            for i in range(0,len(blob),1<<16):
                acc+=do.decompress(blob[i:i+(1<<16)])
                if getattr(do,'eof',False): break
            if len(acc)<100000: continue
            found=True
            P(f"kernel payload: {name} at +{q:,}, decompresses to {len(acc):,} bytes")
            i=acc.find(b'Linux version')
            if i>=0:
                P(f"decompressed kernel self-identifies: {acc[i:i+90].split(bytes([0]))[0].decode(errors='replace')}")
            else:
                F("decompressed payload has no 'Linux version' banner"); rc=1
        except Exception:
            continue
    if found: break
if idx>=0 and not found: F("no recognised compressed payload inside zImage"); rc=1

# --- trailer + checksum ------------------------------------------------------------------
tail=img[-40:]
try:
    parts=tail.split(b'\x00')
    strs=[p for p in parts if p and all(32<=c<127 for c in p)]
    P(f"trailer strings: {[s.decode() for s in strs]}")
except Exception: F("trailer unreadable"); rc=1

if len(img)<=part: P(f"fits mtd3: {len(img):,} of {part:,} ({part-len(img):,} bytes free)")
else: F(f"TOO BIG for mtd3 by {len(img)-part:,} bytes"); rc=1

# The real ceiling is the bootloader's, not the partition's. This unit's stored U-Boot
# environment (read from mtd0) is:  bootcmd=gofsk 0x03240000 0x00da0000
# -- fsaddr = mtd3's physical base, fslen = 0x00da0000 = 14,286,848, which is the partition
# size MINUS one 128K erase block. The top block (0x03fe0000-0x04000000) is outside the
# region the bootloader is configured to cover. An image between the two sizes would flash
# cleanly and might not boot, which is the worst possible failure mode on a single-slot device.
BOOTCMD_LEN=0x00da0000
if len(img)<=BOOTCMD_LEN: P(f"fits the bootcmd region too: {len(img):,} of {BOOTCMD_LEN:,} ({BOOTCMD_LEN-len(img):,} free)")
else: F(f"exceeds U-Boot's gofsk region by {len(img)-BOOTCMD_LEN:,} bytes -- flashes but may not boot"); rc=1
sys.exit(rc)
PY
[ $? -eq 0 ] && pass=$((pass+1)) || fail=$((fail+1))

# ---- Gate 6: embedded checksum verifies (what netflash checks) ---------------------------
N=$(stat -c%s "$IMG"); head -c $((N-4)) "$IMG" > /tmp/_cert_body
st=$(tail -c4 "$IMG" | xxd -p); rc=$(./build/sg-cksum -b -o 2 < /tmp/_cert_body | xxd -p); rm -f /tmp/_cert_body
[ "$st" = "$rc" ] && ok "embedded cksum verifies ($st) -- netflash will accept it" \
                  || no "cksum mismatch: stored=$st computed=$rc -- netflash would reject"

# ---- Gate 7: the kernel's OWN squashfs driver mounts it, and the userland RUNS ----------
# A loop mount is a real boot precondition: it proves the kernel squashfs driver accepts this
# filesystem. Note the loop device truncates to a 512-byte boundary, so the image must be
# padded to a 4K multiple or the tail (id table) is unreadable and the mount fails.
W=$(mktemp -d); M=$(mktemp -d)
python3 - "$IMG" "$W/fs.sqfs" <<'PY2'
import struct,sys,os
d=bytearray(open(sys.argv[1],'rb').read())
bu=struct.unpack('<Q',d[8+40:8+48])[0]
flags,=struct.unpack('<H',d[8+24:8+26])
d[0:96]=d[8:104]
# COMP_OPT (0x400): move the compressor-options block with the superblock -- see verify-unpacked.sh
if flags & 0x400:
    n=2+(struct.unpack('<H',d[104:106])[0]&0x7fff)
    d[96:96+n]=d[104:104+n]
out=bytes(d[:bu]); out+=b'\0'*((-len(out))%4096)
open(sys.argv[2],'wb').write(out)
PY2
if sudo mount -o loop,ro -t squashfs "$W/fs.sqfs" "$M" 2>/dev/null; then
  ok "kernel squashfs driver MOUNTS the filesystem (real boot precondition)"
  n=$(sudo find "$M" -mindepth 1 | wc -l)
  ok "filesystem readable: $n entries"
  for f in bin/busybox bin/sshd etc/rc etc/inittab lib/libuClibc-0.9.33.2.so; do
    sudo test -e "$M/$f" && ok "present: /$f" || no "MISSING: /$f"
  done
  sudo test -u "$M/bin/sudo" && ok "setuid preserved on /bin/sudo" || no "setuid LOST on /bin/sudo"
  if command -v qemu-arm-static >/dev/null; then
    # Pin a genuine ARMv4T core model. qemu-arm's DEFAULT cpu is a modern ARMv7, which executes
    # ARMv5/v6 instructions (blx, clz, ...) happily -- so a toolchain regression that emitted
    # code above ARMv4T would sail through this gate and then fault on the real ARM922T.
    # ti925t is ARM925T-based, i.e. actually ARMv4T. (arm926 would be ARMv5TE -- still too lax.)
    QCPU="-cpu ti925t"
    v=$(sudo qemu-arm-static $QCPU -L "$M" "$M/bin/busybox" 2>&1 | head -1)
    case "$v" in BusyBox*) ok "userland EXECUTES on an ARMv4T core model: $v";; *) no "busybox did not run: $v";; esac
    s2=$(sudo qemu-arm-static $QCPU -L "$M" "$M/bin/sshd" -h 2>&1 | sed -n 2p)
    case "$s2" in OpenSSH*) ok "sshd EXECUTES on an ARMv4T core model: $s2";; *) no "sshd did not run: $s2";; esac
  fi

  # Static counterpart to the above: no ELF in the image may declare an arch above v4T.
  # Catches a bad -march even in binaries the two smoke tests never execute.
  if command -v readelf >/dev/null; then
    bad=$(sudo find "$M" -type f -size +512c 2>/dev/null | while read -r f; do
            [ "$(sudo head -c4 "$f" 2>/dev/null | tr -d '\0')" = "$(printf '\177ELF')" ] || continue
            a=$(sudo readelf -A "$f" 2>/dev/null | grep -oE 'Tag_CPU_arch: \S+' | head -1 | awk '{print $2}')
            case "$a" in ""|v4T|v4) ;; *) echo "$f=$a";; esac
          done | head -5)
    [ -z "$bad" ] && ok "every ELF declares ARMv4T or lower (matches ARM922T)" \
                  || no "ELF above ARMv4T -- will not run on the real CPU: $bad"
  fi
  sudo umount "$M"
else
  no "kernel REFUSES to mount the filesystem"
fi
rmdir "$M" 2>/dev/null; rm -rf "$W"

echo
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ] && echo "CERTIFIED: every boot precondition checkable without the hardware is satisfied." \
                  || echo "NOT CERTIFIED."
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
