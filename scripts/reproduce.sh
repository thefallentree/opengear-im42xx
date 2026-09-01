#!/bin/bash
# Reproduce an Opengear IM42xx firmware image from the vendor's Custom Development Kit,
# with every known source of build non-determinism pinned.
#
#   ./reproduce.sh 3.16.6u1 [--deterministic] [--replay-modules-dep]
#
# Requires a build container (see setup-container.sh) with the CDK unpacked under build/cdk/.
#
# ---------------------------------------------------------------------------------------------
# WHY THIS SCRIPT EXISTS
#
# A plain `make` in the CDK does not reproduce a vendor image. Four things differ, each with a
# distinct cause, and all four are handled below:
#
#   1. /etc/version   Makefile:94 (romfs.post) overwrites common.mk:40's correct line with a
#                     literal " CDK " marker plus a fresh `date`. Fixed by patching that marker
#                     out and pinning VERSIONSUFFIX + the clock.
#   2. module path    EXTRA_MODULE_DIRS makes the out-of-tree module dir an *absolute*
#                     vmlinux-dir while TOPDIR is empty, which perturbs Opengear's patched
#                     scripts/Makefile.modinst:28 path substitution. ax88172a.ko lands in
#                     asix/ instead of kernel/asix/.
#   3. modprobe.conf  Generated from `find`, i.e. readdir order.
#   4. modules.dep    tools/depmod.pl sorts with `sub bydep`, which returns 1 or -1 and NEVER 0
#                     -- neither antisymmetric nor transitive, so not a valid ordering relation
#                     -- fed by randomized Perl hash order. Non-reproducible by construction.
#
# Plus three metadata traps:
#   * faketime also fakes stat(), so mksquashfs records the frozen clock as every file's mtime.
#     NO_FAKE_STAT=1 keeps real mtimes while still pinning the superblock's mkfs_time.
#   * directory mtimes must be restored AFTER all file operations (a directory's mtime changes
#     whenever an entry is added or removed).
#   * the vendor built with umask 002 -- modules_install honours it, so the default 022 gives
#     mode 644 kernel modules where the firmware has 664. Set the umask; do NOT chmod after.
#   * unsquashfs/tar run as NON-ROOT silently drop setuid bits. Never copy modes from such a
#     tree: an earlier version of this script did, dropping setuid on 8 binaries, then had to
#     repair the damage it caused. romfs.extract runs `tar xpzf` as root and gets modes right.
#
# ---------------------------------------------------------------------------------------------
# PACKING: fragments are ON by default, and should stay on.
#
# The acceptance test for an image is certify-image.sh -- which mounts it with the kernel's own
# squashfs driver via loop device and runs its userland. The packed byte layout is not compared
# against anything, so there is nothing to gain from making it reproducible, and a real cost:
# -no-fragments inflates the image by roughly 6%. For 4.1.1u2 that is fatal -- it pushes the
# image 228,444 bytes OVER the mtd3 partition. Flash headroom is the scarce resource here
# (see README section 7g), so pack as tightly as the vendor does.
#
# --deterministic exists only to demonstrate a property, not for images you intend to flash:
# mksquashfs is deterministic EXCEPT for fragment packing (frag_deflator claims output offsets
# from the same global `bytes` counter the main deflator advances, so placement depends on which
# thread reaches fragment_mutex first). Passing -no-fragments removes that race and makes output
# bit-identical across runs. Unpacked CONTENT is byte-identical either way, which is what
# actually matters.
set -euo pipefail

VER="${1:?usage: $0 <3.16.6u1|3.16.6u4|4.1.1u2> [--deterministic] [--replay-modules-dep]}"
shift || true
DET=0; REPLAY=0
for a in "$@"; do
  case "$a" in
    --deterministic) DET=1;;   # demonstration only -- costs ~6% size, see header
    --replay-modules-dep) REPLAY=1;;
    *) echo "unknown option: $a" >&2; exit 2;;
  esac
done

# version -> devkit dir | reference tree | VERSIONSUFFIX | version-date TZ | version date | mkfs_time(UTC)
case "$VER" in
  3.16.6u1) DK=OpenGear-IM42xx-3.16.6u1-devkit-20161114; REF=/work/build/rootfs
            SUF=e02e2d59; VTZ=EST5EDT; VDATE="2016-11-14 17:25:35"; MKFS="2016-11-14 07:26:37";;
  3.16.6u4) DK=OpenGear-IM42xx-3.16.6u4-devkit-20170310; REF=/work/build/ref-u4/romfs
            SUF=9077fc8f; VTZ=EST5EDT; VDATE="2017-03-10 09:13:23"; MKFS="2017-03-10 14:13:23";;
  4.1.1u2)  DK=OpenGear-IM42xx-4.1.1u2-devkit-20180508;  REF=/work/build/ref-411/romfs
            SUF=594cb83d; VTZ=UTC;     VDATE="2018-05-08 01:23:09"; MKFS="2018-05-08 01:23:09";;
  *) echo "unknown version: $VER" >&2; exit 2;;
esac

C=${CONTAINER:-opengear-cdk}
OUT=${OUT:-build/repro-$VER.bin}

docker exec \
  -e VER="$VER" -e DK="$DK" -e REF="$REF" -e SUF="$SUF" -e VTZ="$VTZ" \
  -e VDATE="$VDATE" -e MKFS="$MKFS" -e DET="$DET" -e REPLAY="$REPLAY" \
  -i "$C" bash -s <<'INNER'
set -euo pipefail
D=/work/build/cdk/$DK
R=$D/romfs
cd "$D"
export PATH="$D/tools:$PATH"

# The vendor built with umask 002. It matters: modules_install honours the umask, so the
# default 022 yields mode 644 kernel modules where the shipped firmware has 664. Everything
# else comes from `tar xpzf` (root, -p) and is already correct.
umask 002

# The CDK stamps its own builds; patch that out so it reproduces a vendor image instead.
cp -n Makefile Makefile.cdk-orig 2>/dev/null || true
sed -i 's|echo "$(VERSIONSTR) CDK -- " `date`|echo "$(VERSIONSTR) -- " `date`|' Makefile

echo "== 1. /etc/version via make, with VERSIONSUFFIX and the clock pinned =="
TZ="$VTZ" NO_FAKE_STAT=1 faketime -f "@$VDATE x0.0" \
  make VERSIONSUFFIX="$SUF" romfs.post >/dev/null 2>&1
echo "   $(cat "$R/etc/version")"

echo "== 2. out-of-tree module: restore the kernel/ prefix =="
if [ -f "$R/lib/modules/3.10.0-uc0/asix/ax88172a/ax88172a.ko" ]; then
  mkdir -p "$R/lib/modules/3.10.0-uc0/kernel/asix/ax88172a"
  chmod 775 "$R/lib/modules/3.10.0-uc0/kernel" \
            "$R/lib/modules/3.10.0-uc0/kernel/asix" \
            "$R/lib/modules/3.10.0-uc0/kernel/asix/ax88172a"
  mv "$R/lib/modules/3.10.0-uc0/asix/ax88172a/ax88172a.ko" \
     "$R/lib/modules/3.10.0-uc0/kernel/asix/ax88172a/ax88172a.ko"
  rm -rf "$R/lib/modules/3.10.0-uc0/asix"
fi

echo "== 3. modprobe.conf: replay the reference's module enumeration order =="
# Content is still genuinely generated -- modules-alias.sh runs modinfo against the modules we
# built. Only the input ORDER is replayed, because it is readdir order on the original host.
if [ -f "$REF/etc/modprobe.conf" ]; then
  : > /tmp/kolist
  for m in $(awk '{print $NF}' "$REF/etc/modprobe.conf" | awk '!seen[$0]++'); do
    find "$R/lib/modules" -type f -name "$m.ko" >> /tmp/kolist || true
  done
  find "$R/lib/modules" -type f -name '*.ko' | grep -vxFf /tmp/kolist >> /tmp/kolist || true
  /bin/sh tools/modules-alias.sh "$R/etc/modprobe.conf" < /tmp/kolist
fi

if [ "$REPLAY" = "1" ] && [ -f "$REF/lib/modules/3.10.0-uc0/modules.dep" ]; then
  echo "== 3b. modules.dep: replayed (its order is non-reproducible -- see header) =="
  cp "$REF/lib/modules/3.10.0-uc0/modules.dep" "$R/lib/modules/3.10.0-uc0/modules.dep"
fi

echo "== 4. restore mtimes from the reference (modes are already correct) =="
# Only TIMESTAMPS are replayed. Modes are NOT touched: romfs.extract runs `tar xpzf` as root,
# which preserves the vendor's permissions including setuid, and the build gets them right.
# An earlier version of this script also ran `chmod --reference` against a tree that had been
# extracted as a non-root user -- which silently DROPPED setuid on 8 binaries, a bug this script
# then had to repair. Don't reintroduce it: verify modes, never copy them.
( cd "$REF" && find . \( -type f -o -type l \) -print | while read -r f; do
    if [ -e "$R/$f" ] || [ -L "$R/$f" ]; then touch -h -r "$REF/$f" "$R/$f" 2>/dev/null || true; fi
  done ) || true
# Directories last -- their mtime changes whenever an entry is added or removed.
( cd "$REF" && find . -type d -print | while read -r f; do
    [ -d "$R/$f" ] && touch -r "$REF/$f" "$R/$f" 2>/dev/null || true
  done ) || true

echo "== 4b. verify setuid survived (do not restore -- a clean build already has it) =="
n=$(find "$R" \( -perm -4000 -o -perm -2000 \) | wc -l)
echo "   setuid/setgid binaries present: $n (expected 8)"
[ "$n" = "8" ] || echo "   WARNING: expected 8 -- check that romfs was extracted as root"

echo "== 5. mksquashfs, clock frozen (this build has no -fstime option) =="
EXTRA=""; [ "$DET" = "1" ] && EXTRA="-no-fragments"
MK=$D/vendors/OpenGear/IM42xx/mksquashfs
rm -f /work/build/_ramdisk
( cd "$R" && TZ=UTC NO_FAKE_STAT=1 faketime -f "@$MKFS x0.0" \
    "$MK" . /work/build/_ramdisk -all-root -noappend -processors 1 $EXTRA >/dev/null )

echo "== 6. assemble exactly as vendors/OpenGear/IM42xx/Makefile's image: rule does =="
O=/work/build/_image.bin
cp /work/build/_ramdisk "$O"
[ -f prop/shim/shim.bin ] && cat prop/shim/shim.bin >> "$O"
cat images/zImage >> "$O"
printf '\0%s\0%s\0%s' "$VER" "OpenGear" "CM41XX" >> "$O"
tools/cksum -b -o 2 "$O" >> "$O"
echo "   $(stat -c%s "$O") bytes"
INNER

cp build/_image.bin "$OUT"
n=$(stat -c%s "$OUT"); part=14417920
printf 'wrote %s (%d bytes)  mtd3 %d  ' "$OUT" "$n" "$part"
[ "$n" -le "$part" ] && echo "FITS, $((part-n)) free" || echo "TOO BIG by $((n-part))"
sha256sum "$OUT"
