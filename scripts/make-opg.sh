#!/bin/bash
# Build a restorable Opengear .opg config backup from an archived /etc/config tarball.
#
# WHY
# ---
# Phase 0 exported /etc/config by streaming tar over SSH, which is a fine *archive* but not
# something the appliance can ingest. The web UI restores configuration from a `.opg` file.
# This converts our tarball into that format, so the config side has a restore path the same
# way make-flash-from-mtd3.sh gives the firmware side one.
#
# THE FORMAT (reverse-engineered from the unit's own 20260808.opg, 2026-08-19)
# ---------------------------------------------------------------------------
#   offset 0 : "OpenGear\0"    vendor
#   offset 9 : "CM41XX\0"      HW_PRODUCT  <- same value as the firmware image trailer
#   offset 16: "3.16.6u1\0"    version
#   offset 25: a plain (GNU) tar archive whose first entry is "etc/config/"
#
# 25-byte header, no length field, no checksum. Verified: splitting the unit's own backup at
# offset 25 and reconcatenating reproduces the original byte-for-byte, and 'ustar' sits at
# body+257 exactly as a tar header requires.
#
# Note the product string is CM41XX, not IM42XX -- the same u-boot-compatibility quirk seen in
# vendors/OpenGear/IM42xx/config.arch and in the .flash trailer.
#
# STATUS: never restored to the appliance. Format-correct and round-trip verified against a
# genuine vendor-produced .opg, but untested as an actual restore. Treat accordingly.
#
# Usage: ./make-opg.sh <etc-config.tar.gz> <output.opg> [version]

set -euo pipefail

SRC="${1:?usage: $0 <etc-config.tar.gz> <output.opg> [version]}"
OUT="${2:?usage: $0 <etc-config.tar.gz> <output.opg> [version]}"
VERSION="${3:-3.16.6u1}"

HW_VENDOR="OpenGear"
HW_PRODUCT="CM41XX"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Our Phase 0 export was made with `tar czf - -C /etc config`, so its paths are "config/...".
# A .opg expects "etc/config/...". Repack rather than assume.
mkdir -p "$TMP/etc"
tar xzf "$SRC" -C "$TMP/etc"
[ -d "$TMP/etc/config" ] || { echo "error: no config/ dir inside $SRC" >&2; exit 1; }

# -p preserves permissions; several files under etc/config are mode 0600 and must stay that way.
tar cf "$TMP/body.tar" -C "$TMP" --owner=root --group=root -p etc/config

printf '%s\0%s\0%s\0' "$HW_VENDOR" "$HW_PRODUCT" "$VERSION" > "$OUT"
cat "$TMP/body.tar" >> "$OUT"

echo "wrote   : $OUT ($(stat -c%s "$OUT") bytes)"
echo "header  : ${HW_VENDOR}\\0${HW_PRODUCT}\\0${VERSION}\\0 (25 bytes)"
echo "entries : $(tar tf "$TMP/body.tar" | wc -l)"
echo
echo "sanity — re-read it back the way the appliance would:"
tail -c +26 "$OUT" | tar tf - >/dev/null && echo "  tar body parses OK"
head -c 25 "$OUT" | tr '\0' '|' | sed 's/^/  header: /'; echo
