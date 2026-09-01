#!/bin/bash
# Reconstruct a vendor-format .flash image from a raw dd of /dev/mtd3.
#
# WHY THIS EXISTS
# ---------------
# A raw `dd` of mtd3 is NOT a valid .flash file and cannot be uploaded to the
# recovery web UI as-is. Verified 2026-08-19 by comparing our dump against the
# vendor's own IM42xx_Recovery.flash:
#
#   .flash file  = <payload> + '\0<version>\0<vendor>\0<product>' + 4-byte cksum
#   flash (mtd3) = <payload> only, then erased/unwritten space
#
# i.e. netflash validates the trailer, then writes only the payload. So the
# archived dd is missing the trailer that a recovery upload would validate.
#
# The trailer format comes from the CDK's own image rule, in
# vendors/OpenGear/IM42xx/Makefile:
#
#   printf '\0%s\0%s\0%s' $(VERSIONPKG) $(HW_VENDOR) $(HW_PRODUCT) >> $(IMAGE)
#   $(ROOTDIR)/tools/cksum -b -o 2 $(IMAGE) >> $(IMAGE)
#
# METHOD VALIDATION: stripping the last 4 bytes of the vendor's own
# IM42xx_Recovery.flash and recomputing with the CDK's sg-cksum reproduces its
# checksum exactly (00003e02). So the algorithm and field order below are
# confirmed against a known-good vendor artifact, not inferred.
#
# STATUS: the OUTPUT of this script has never been flashed or uploaded. It is
# format-correct by construction and validated by the control above, but
# untested on hardware. Do not treat it as a guaranteed-working recovery image.
#
# Usage: ./make-flash-from-mtd3.sh <mtd3-dump> <output.flash> [version]

set -euo pipefail

SRC="${1:?usage: $0 <mtd3-dump> <output.flash> [version]}"
OUT="${2:?usage: $0 <mtd3-dump> <output.flash> [version]}"
VERSION="${3:-3.16.6u1}"

# From vendors/OpenGear/IM42xx/config.arch -- note HW_PRODUCT really is CM41XX
# for IM42xx builds (u-boot compatibility), confirmed by the trailer in the
# vendor's own IM42xx_Recovery.flash which reads "...OpenGear\0CM41XX".
HW_VENDOR="OpenGear"
HW_PRODUCT="CM41XX"

CKSUM="${CKSUM:-./build/sg-cksum}"
if [ ! -x "$CKSUM" ]; then
    echo "error: $CKSUM not found. Build it from the CDK first:" >&2
    echo "  gcc -O2 -o build/sg-cksum <cdk>/tools/sg-cksum/{cksum,crc32,crc,print,sum1,sum2}.c" >&2
    exit 1
fi

# --- 1. find the true end of payload -----------------------------------------
# The image is: 8-byte header | squashfs | pad | shim.bin | zImage
# Everything after the zImage in mtd3 is unwritten flash (0xFF) or zeros and
# must NOT be included -- it is not part of the distributed image.
PAYLOAD_END=$(python3 - "$SRC" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read()
# ARM zImage carries magic 0x016f2818 at offset 0x24, with start/end at 0x28/0x2c
zm = struct.pack('<I', 0x016f2818)
best = None
s = 0
while True:
    i = d.find(zm, s)
    if i < 0:
        break
    s = i + 1
    zs = i - 0x24
    if zs < 0:
        continue
    start, end = struct.unpack('<II', d[zs + 0x28:zs + 0x30])
    size = end - start
    # sanity: a real zImage is a few hundred KB to a few MB and must fit
    if start == 0 and 0 < size < len(d) and zs + size <= len(d):
        best = zs + size
if best is None:
    sys.exit("could not locate zImage end")
print(best)
PY
)
echo "payload ends at : $PAYLOAD_END bytes (rest of mtd3 is unwritten flash)"

# --- 2. payload + trailer ----------------------------------------------------
head -c "$PAYLOAD_END" "$SRC" > "$OUT"
printf '\0%s\0%s\0%s' "$VERSION" "$HW_VENDOR" "$HW_PRODUCT" >> "$OUT"

# --- 3. append the checksum over everything written so far -------------------
"$CKSUM" -b -o 2 < "$OUT" >> "$OUT"

echo "wrote           : $OUT ($(stat -c%s "$OUT") bytes)"
echo "trailer         : \\0${VERSION}\\0${HW_VENDOR}\\0${HW_PRODUCT} + 4-byte cksum"
echo
echo "verify trailer round-trips (recompute over body, compare to stored):"
N=$(stat -c%s "$OUT")
head -c $((N - 4)) "$OUT" > "$OUT.body.tmp"
stored=$(tail -c 4 "$OUT" | xxd -p)
recomputed=$("$CKSUM" -b -o 2 < "$OUT.body.tmp" | xxd -p)
rm -f "$OUT.body.tmp"
echo "  stored=$stored recomputed=$recomputed"
[ "$stored" = "$recomputed" ] && echo "  OK" || { echo "  MISMATCH"; exit 1; }
