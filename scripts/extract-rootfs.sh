#!/bin/bash
# Extract the device's root filesystem from an archived mtd3 image, so its binaries
# can be run and tested on Mon under qemu-user emulation -- no device access needed,
# nothing written to flash.
#
#   ./extract-rootfs.sh archive/im42xx-3.16.6u1-running.img build/rootfs
#   qemu-arm-static -L build/rootfs build/rootfs/bin/sshd -h
#
# Requires: qemu-user-static, squashfs-tools
#
# THE NON-OBVIOUS PART -- read before "fixing" this script
# --------------------------------------------------------
# Opengear PATCHED mksquashfs to prepend a fake 8-byte cramfs superblock to the real one.
# Confirmed in the CDK source, user/squashfs-new/squashfs-tools/:
#
#   squashfs_fs.h:  struct squashfs_super_block {
#                   #ifdef CONFIG_SQUASHFS_CRAMFS_MAGIC
#                           unsigned char cramfs_magic[4];   /* 45 3d cd 28 */
#                           unsigned char cramfs_size[4];    /* fs size, rounded up to 4K */
#                   #endif
#                           unsigned int  s_magic;           /* 'hsqs' -- now at offset 8 */
#
#   mksquashfs.c:5346  writes the magic;  :5404  cs = ((bytes-1) | 4095) + 1
#   Makefile:109       gated on CONFIG_SQUASHFS_CRAMFS_MAGIC
#
# Why: the boot shim locates the kernel by reading a length at offset 4, cramfs-style.
# See README section 7d. The kernel side matches (CONFIG_SQUASHFS_CRAMFS_MAGIC=y), and
# CONFIG_CRAMFS itself is not even compiled in -- it is purely a compatibility shim.
#
# The consequence for extraction: those 8 bytes are part of the superblock STRUCT, not a
# separate prepended header, so every internal table pointer counts from byte 0 of the
# file INCLUDING them -- while stock unsquashfs expects s_magic at 0 and a 96-byte
# superblock. Hence both obvious approaches fail with "File system corruption detected":
#
#   dd skip=8 ...            -> superblock at 0, but pointers now all +8
#   unsquashfs -o 8 <image>  -> identical: -o offsets the pointers too
#
# Verified symptom: superblock reports inode_table_start=11,861,160 while the real
# metadata header sits at 11,861,152 in a superblock-relative extraction -- exactly 8 less,
# same skew on the id, lookup and fragment tables.
#
# unsquashfs cannot express "superblock at 8, pointers counted from 0", so the fix is to
# copy the 96-byte stock superblock down to offset 0 and leave everything else where it
# is, so pointer P still lands on file byte P.

set -euo pipefail

SRC="${1:?usage: $0 <mtd3-image> <output-dir>}"
OUT="${2:?usage: $0 <mtd3-image> <output-dir>}"
WORK="$(dirname "$OUT")/root-fixed.squashfs"

command -v unsquashfs >/dev/null || { echo "need squashfs-tools" >&2; exit 1; }

python3 - "$SRC" "$WORK" <<'PY'
import struct, sys
src, work = sys.argv[1], sys.argv[2]
img = bytearray(open(src, 'rb').read())

if img[8:12] != b'hsqs':
    sys.exit("no squashfs magic at offset 8 -- not an Opengear image?")

# bytes_used lives at superblock offset 0x28; superblock itself starts at image offset 8
bytes_used = struct.unpack('<Q', img[8 + 0x28: 8 + 0x30])[0]

# Move the 96-byte superblock to offset 0. Everything at >= 96 stays put, so a pointer
# value P still resolves to image byte P, which is what the fs expects.
img[0:96] = img[8:104]
open(work, 'wb').write(img[:bytes_used])
print(f"squashfs: {bytes_used:,} bytes -> {work}")
PY

rm -rf "$OUT"
unsquashfs -d "$OUT" "$WORK" | tail -3
echo
echo "extracted: $(find "$OUT" -type f | wc -l) files, $(du -sh "$OUT" | cut -f1)"
echo
echo "try it:"
echo "  qemu-arm-static -L $OUT $OUT/bin/sshd -h"
echo "  qemu-arm-static -L $OUT $OUT/bin/busybox"
