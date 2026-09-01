#!/bin/bash
# Stand up the build container for the Opengear IM42xx CDK, and unpack a devkit into it.
#
#   ./setup-container.sh [devkit.tar.gz ...]
#
# The CDK's cross-compilers are 32-bit x86 binaries that install system-wide into
# /usr/local/uclinux-dist, so they get a container rather than your host.
#
# ---------------------------------------------------------------------------------------------
# Four things here are not obvious and each one costs a failed build if missed:
#
#  1. Ubuntu 16.04 is what the vendor specifies, and "32 or 64-bit" -- a 64-bit host needs only
#     lib32z1 and lib32ncurses5. The widespread advice that you need a 32-bit VM is wrong.
#  2. archive.ubuntu.com STILL SERVES xenial (it had ESM). Repointing sources.list at
#     old-releases.ubuntu.com -- the reflexive fix for an EOL release -- 404s and breaks apt.
#  3. kmod is required (romfs.modules calls modinfo) and is absent from the vendor's package list.
#  4. faketime is needed by reproduce.sh to pin build timestamps.
set -euo pipefail

C=${CONTAINER:-opengear-cdk}
IMG=${IMAGE:-ubuntu:16.04}
ROOT=$(cd "$(dirname "$0")" && pwd)

if docker ps -a --format '{{.Names}}' | grep -qx "$C"; then
  echo "container $C already exists"
else
  docker pull "$IMG"
  docker run -d --name "$C" -v "$ROOT:/work" "$IMG" sleep infinity >/dev/null
  echo "created container $C with $ROOT mounted at /work"
fi

docker exec "$C" bash -c '
set -e
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  build-essential liblzma-dev libncurses5-dev bc wget file perl \
  lib32z1 lib32ncurses5 kmod faketime
dpkg --configure -a
'
echo "deps installed"

# The toolchain the vendor README names explicitly. Self-extracting; installs to
# /usr/local/uclinux-dist and symlinks into /usr/local/bin. `yes ""` accepts the defaults.
TC=dl/tools-arm-linux-gnueabi-tools-20140823.sh
if docker exec "$C" test -d /usr/local/uclinux-dist; then
  echo "toolchain already installed"
elif [ -f "$ROOT/$TC" ]; then
  docker exec "$C" bash -c "chmod +x /work/$TC && yes '' | sh /work/$TC >/dev/null 2>&1 || true"
  echo "toolchain installed"
else
  echo "WARNING: $TC not present -- fetch it from" >&2
  echo "  https://ftp.opengear.com/download/3rd_party_support_and_scripts/cdk/tools/" >&2
fi

docker exec "$C" bash -c '
echo "--- versions ---"
gcc --version | head -1
arm-linux-gnueabi-20140823-gcc --version | head -1 || true
file $(find /usr/local/uclinux-dist -name arm-linux-gnueabi-gcc -type f 2>/dev/null | head -1) 2>/dev/null | cut -d, -f1-2
'

mkdir -p "$ROOT/build/cdk"
for t in "$@"; do
  n=$(basename "$t" .tar.gz)
  if [ -d "$ROOT/build/cdk/$n" ]; then
    echo "already unpacked: $n"
  else
    echo "unpacking $n ..."
    tar xzf "$t" -C "$ROOT/build/cdk"    # preserves mtimes, which make depends on
  fi
done

cat <<EOF

Ready. Next:
  ./reproduce.sh 3.16.6u1          # build an image (fragments on -- pack tightly)
  ./certify-image.sh <image.bin>   # loop-mount it and run its userland
  ./verify-unpacked.sh <image.bin> <reference.img>
EOF
