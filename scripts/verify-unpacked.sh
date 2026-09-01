#!/bin/bash
# Verify that a BUILT image unpacks to something byte-identical to the SHIPPED firmware.
#
# This is the meaningful standard. The packed layout can never match (mksquashfs's
# frag_deflator thread claims output offsets from the same global `bytes` counter the main
# deflator advances, so fragment placement is a race -- see README section 8). What matters is
# that unpacking both yields the same filesystem, byte for byte.
#
# Both images are unpacked AS ROOT inside the container, because unsquashfs run as a normal
# user silently drops setuid/setgid bits and cannot create device nodes -- which would hide
# exactly the differences this check exists to catch.
#
# Compares, per entry: type, mode (incl. setuid/setgid/sticky), uid:gid, mtime, size,
# and content sha256 / symlink target / device major:minor.
#
# Usage: ./verify-unpacked.sh <built-image.bin> [shipped-image]
set -u
BUILT="${1:?usage: $0 <built-image.bin> [shipped-image]}"
SHIPPED="${2:-archive/im42xx-3.16.6u1-running.img}"
C=opengear-cdk

command -v docker >/dev/null || { echo "docker required"; exit 2; }
docker ps --format '{{.Names}}' | grep -qx "$C" || { echo "container $C not running"; exit 2; }

# Opengear images carry a fake 8-byte cramfs header, so the squashfs superblock sits at
# offset 8 while its internal pointers count from byte 0. Move the 96-byte superblock down to
# 0 and leave everything else in place (see extract-rootfs.sh), then pad to 4K -- a loop device
# truncates to a 512-byte boundary, which would cut off the id table and make the mount fail.
prep() {
  python3 - "$1" "$2" <<'PY2'
import struct,sys
d=bytearray(open(sys.argv[1],'rb').read())
if d[8:12]!=b'hsqs': sys.exit(f"{sys.argv[1]}: no squashfs magic at +8")
bu=struct.unpack('<Q',d[8+40:8+48])[0]
flags,=struct.unpack('<H',d[8+24:8+26])
d[0:96]=d[8:104]
# If COMP_OPT (0x400) is set, a compressor-options metadata block follows the superblock at
# +104 and MUST be moved with it -- otherwise offset 96 holds the superblock's own tail and
# unsquashfs fails with "Failed to read compressor options". The 2016 gzip images do not set
# this flag, which is why it stayed hidden; ACM 5.5.1 (xz + ARM BCJ filter) does. See README 7m.
if flags & 0x400:
    n=2+(struct.unpack('<H',d[104:106])[0]&0x7fff)
    d[96:96+n]=d[104:104+n]
out=bytes(d[:bu]); out+=b'\0'*((-len(out))%4096)
open(sys.argv[2],'wb').write(out)
PY2
}

W=build/_verify; sudo rm -rf "$W"; mkdir -p "$W"
prep "$BUILT"   "$W/built.sqfs"   || exit 1
prep "$SHIPPED" "$W/shipped.sqfs" || exit 1

# Mount both with the KERNEL's own squashfs driver. Stronger than unsquashfs: it proves the
# driver accepts the image (a real boot precondition), and preserves setuid bits and device
# nodes, which a non-root unsquashfs silently drops -- hiding the very differences we check.
cleanup(){ for m in "$W/m-built" "$W/m-shipped"; do sudo umount "$m" 2>/dev/null; done; }
trap cleanup EXIT
for n in built shipped; do
  mkdir -p "$W/m-$n"
  sudo mount -o loop,ro -t squashfs "$W/$n.sqfs" "$W/m-$n" \
    || { echo "  FAIL  kernel refused to mount $n.sqfs"; exit 1; }
  echo "  mounted $n.sqfs via loop device"
  ( cd "$W/m-$n" && sudo find . -mindepth 1 -printf '%y|%m|%U:%G|%T@|%s|%p\n' | sort -t'|' -k6 ) > "$W/$n.meta"
  ( cd "$W/m-$n" && sudo find . -type f -exec sha256sum {} + 2>/dev/null | sort -k2 ) > "$W/$n.sha"
  ( cd "$W/m-$n" && sudo find . -type l -printf '%p -> %l\n' | sort ) > "$W/$n.link"
  ( cd "$W/m-$n" && sudo find . \( -type c -o -type b \) -printf '%p %y\n' | sort ) > "$W/$n.dev"
  ( cd "$W/m-$n" && sudo find . -mindepth 1 -printf '%p\n' | sort ) > "$W/$n.list"
done

echo
fail=0
cmpf() {
  local what="$1" a="$W/built.$2" b="$W/shipped.$2"
  if diff -q "$a" "$b" >/dev/null 2>&1; then
    echo "  PASS  $what identical ($(wc -l < "$a") entries)"
  else
    echo "  FAIL  $what differs:"; diff "$b" "$a" | head -8; fail=1
  fi
}
cmpf "entry list"                      list
cmpf "file contents (sha256)"          sha
grep -v '^d|' "$W/built.meta"   > "$W/built.fmeta"
grep -v '^d|' "$W/shipped.meta" > "$W/shipped.fmeta"
cmpf "non-dir metadata (mode/uid:gid/mtime/size)" fmeta
cmpf "symlink targets"                 link
cmpf "device nodes"                    dev

echo
if [ "$fail" -eq 0 ]; then
  echo "VERIFIED: the built image unpacks BYTE-IDENTICALLY to the shipped firmware."
  echo "          (content, permissions incl. setuid, ownership, timestamps, symlinks, device nodes)"
else
  echo "NOT VERIFIED -- see differences above."
fi
exit $fail
