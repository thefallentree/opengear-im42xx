# opengear-im42xx

Reproduce, verify, and customize the firmware of the **Opengear IM4200-series
console server** (Micrel KS8695P, ARM922T / ARMv4T) from Opengear's Custom
Development Kit — with a container-based build, a byte-for-byte reproducibility
check against a running unit, and a boot-certification harness.

This repo is **tooling and documentation only**. It does not contain the CDK or
any firmware — see [`NOTICE.md`](NOTICE.md). You supply the CDK, a cross toolchain,
and (optionally) a dump of your own device.

> _Provided as-is, for convenience. No license, no warranty, no support — use at
> your own risk._

## Prebuilt images

Don't want to build it yourself? The **[Releases page](../../releases/latest)**
carries the images below, prebuilt from the CDK and certified, plus `SHA256SUMS`:

> 🛑 **These fit the IM4200 family ONLY** — IM4216 / IM4248 / IMG4216 / IM4004
> (Opengear product ID `CM41XX`). **Do not flash them on any other model.**
> In particular the **`cm41xx` boxes (CM4116/CM4148) share the `CM41XX` product
> ID**, so netflash's product check would *pass* while installing the wrong
> rootfs — a brick. Confirm your unit is an IM42xx (its web UI / label) before
> flashing. Unsure? Don't.

| Image | Version | Notes |
|---|---|---|
| `im42xx-3.16.6u1.flash` | 3.16.6u1 | Control — unpacks **byte-for-byte identical** to the firmware shipped on the unit |
| `im42xx-3.16.6u4.flash` | 3.16.6u4 | Same series + 3 security fixes (strncat, X-Frame/CSP, mf2b) |
| `im42xx-4.1.1u2.flash` | 4.1.1u2 | Newest buildable for this hardware; fixes the netflash non-tty bug |

```sh
sha256sum -c SHA256SUMS      # verify what you downloaded before flashing
```

> ⚠️ **One firmware slot (`mtd3`), no rollback.** Flash from the **web UI or a
> real serial console** (3.16.6u1's netflash has a non-tty bug), leave the
> *Firmware Options* field **blank** to keep your config, and **stage a recovery
> image first** — see [Flashing & recovery](#flashing--recovery). These are
> rebuilt from the vendor CDK, **not** vendor-signed originals; they include
> Opengear proprietary components and the firmware-family shipped HTTPS key
> (see [`NOTICE.md`](NOTICE.md)).

> **⚠ These devices have one firmware slot (`mtd3`) — no A/B, no rollback.**
> A bad flash that also survives the bootloader means physical-access-only
> recovery. Read [Flashing & recovery](#flashing--recovery) before writing anything.

---

## What this gives you

- **`reproduce.sh`** — rebuild a vendor firmware image from the CDK with every
  known source of build non-determinism pinned. On the pilot version the result
  unpacks **byte-for-byte identical** to the firmware shipped on the device
  (851/852 files pure-build; 852/852 with module-dep replay).
- **`certify-image.sh`** — 14+ mechanical gates that verify an image is
  bootable as far as is checkable without the hardware: the fake-cramfs header,
  a simulation of the boot shim's own kernel-location arithmetic, XZ kernel
  decompression, a real loop-mount with the kernel's squashfs driver, execution
  of the built userland under a **true ARMv4T QEMU core**, and a static check
  that every ELF is ARMv4T-or-lower.
- **`verify-unpacked.sh`** — loop-mount a built image and a reference image as
  root and compare, per entry: type, mode (incl. setuid/setgid), owner, mtime,
  size, content sha256, symlink target, device major/minor.
- **`setup-container.sh`** — stand up the build container and unpack a devkit.
- **`extract-rootfs.sh` / `make-flash-from-mtd3.sh` / `make-opg.sh`** — unpack a
  device image, reconstruct a flashable `.flash` from a raw `mtd3` dump, and pack
  a config bundle.

---

## Hardware background

| | |
|---|---|
| SoC | **Micrel/Kendin KS8695P** — "router-on-a-chip": ARM922T core, 4-port 10/100 switch, WAN port, USARTs, PCI host bridge |
| Architecture | **ARMv4T** (ARM922T), ~166 MHz |
| RAM / flash | ~51 MB / 16 MB Intel StrataFlash (CFI), bank-switched 4 MB window |
| Kernel | Linux **3.10.0-uc0** (uClinux-dist lineage) |
| libc | **uClibc 0.9.33.2** (not glibc) |
| Rebadge | Also sold as **TrippLite B096** (same board, `CONFIG_TL_REBRAND`) |

The KS8695 board code (`arch/arm/mach-ks8695/board-og.c`) is in the CDK kernel
tree and serves CM4002/CM4008/CM41xx/IM42xx/IM4004 from one `MACHINE_START`.
`panic_on_oops=1; panic_timeout=10` — **a kernel oops auto-reboots after 10 s**,
so a bad custom kernel presents as a *reboot loop*, not a halt.

---

## Build environment

The CDK's cross-compilers are 32-bit x86 binaries that install system-wide into
`/usr/local/uclinux-dist`, so they belong in a container, not on your host.

Per Opengear's own devkit README the host is **Ubuntu 16.04** (32- *or* 64-bit —
the widespread "you need a 32-bit VM" advice is wrong; a 64-bit host needs only
`lib32z1 lib32ncurses5`). Non-obvious extras that each cost a failed build:

- **`archive.ubuntu.com` still serves xenial** (it had ESM). Repointing
  `sources.list` at `old-releases.ubuntu.com` — the reflex EOL fix — 404s.
- **`kmod`** is required (`romfs.modules` calls `modinfo`) and is absent from the
  vendor package list.
- **`faketime`** is needed to pin build timestamps.

```sh
# 1. Fetch a devkit + a cross toolchain from Opengear's FTP into ./dl/ first, then:
./scripts/setup-container.sh dl/OpenGear-IM42xx-<ver>-devkit-<date>.tar.gz
```

Build from the **CDK root only** — the root `Makefile` carries the config, and
running `make` from a subdirectory silently uses the wrong cross-compiler.

---

## Quick start

```sh
./scripts/setup-container.sh dl/<devkit>.tar.gz     # container + toolchain + unpack
./scripts/reproduce.sh 3.16.6u1                     # build (fragments on = pack tight)
./scripts/certify-image.sh build/repro-3.16.6u1.bin # 14+ boot-precondition gates
./scripts/verify-unpacked.sh build/repro-3.16.6u1.bin your-device-dump.img
```

`reproduce.sh` knows a small table of `(devkit dir, reference tree, version
suffix, timezone, version date, mkfs time)` per version — extend it for your
own targets. `--deterministic` demonstrates bit-identical packed output
(`-no-fragments`, ~6% larger — *not* for images you intend to flash);
`--replay-modules-dep` copies `modules.dep` from a reference to reach 852/852.

---

## The image format

An Opengear `.flash` is a flat concatenation (from
`vendors/OpenGear/IM42xx/Makefile`'s `image:` rule):

```
+0x00  8-byte header : fake cramfs magic 45 3d cd 28, then the squashfs length
+0x08  squashfs(romfs), patched so its own magic sits at +8
 ...   pad to 4K
       prop/shim/shim.bin (4096 bytes)
       zImage
       '\0<version>\0<vendor>\0<product>'      e.g. \03.16.6u1\0OpenGear\0CM41XX
       4-byte BSD checksum (tools/cksum -b -o 2)
```

The **fake cramfs header is load-bearing in three places at once** and its
purpose is documented in the kernel's `fs/squashfs/Kconfig`
(`CONFIG_SQUASHFS_CRAMFS_MAGIC`): *"so that old boot loaders and initrd tools
will know its size/type."* The kernel's `struct squashfs_super_block` is patched
with `cramfs_magic[4]` + `cramfs_size[4]` ahead of `s_magic`, which is why
`/dev/mtdblock3` mounts directly as squashfs despite the offset.

- **`HW_PRODUCT` is `CM41XX`, not `IM42XX`** (u-boot compatibility) — confirmed in
  both `config.arch` and the vendor images' own trailers.
- A raw `dd` of `mtd3` is **not** a valid `.flash`: `netflash` validates and
  strips the trailer, so a dump ends at the zImage with no version/cksum.
  `make-flash-from-mtd3.sh` reconstructs a proper one.

---

## Reproducibility: the determinism traps

A plain `make` does **not** reproduce a vendor image. Each of these differs, with
a distinct cause, all handled in `reproduce.sh`:

1. **`/etc/version`** — `romfs.post` overwrites the correct line with a `CDK`
   marker + a fresh `date`. Patched out; `VERSIONSUFFIX` and the clock pinned.
2. **Out-of-tree module path** — `EXTRA_MODULE_DIRS` perturbs a patched
   `Makefile.modinst` path substitution; `ax88172a.ko` lands in `asix/` instead
   of `kernel/asix/`. Moved back.
3. **`modprobe.conf`** — generated from `find` (readdir order). Input order is
   replayed from a reference; content is still genuinely generated by `modinfo`.
4. **`modules.dep`** — `depmod.pl` sorts with a comparator that never returns 0
   (not a valid ordering) fed by randomized Perl hash order. **Non-reproducible
   by construction** — optionally replayed.

Plus metadata traps:

- **`faketime` also fakes `stat()`** → `mksquashfs` records the frozen clock as
  every file's mtime. `NO_FAKE_STAT=1` keeps real mtimes while still pinning the
  superblock's `mkfs_time`.
- **Directory mtimes** must be restored *after* all file ops (adding/removing an
  entry changes a directory's mtime).
- **The vendor built with `umask 002`** — `modules_install` honours it, so the
  default 022 yields mode-644 modules where the firmware has 664. Set the umask;
  do **not** chmod after.
- **`unsquashfs`/`tar` as non-root silently drop setuid** — never copy modes from
  a tree extracted as a normal user. `romfs.extract` runs `tar xpzf` as root and
  gets modes right; the script verifies setuid survived rather than restoring it.

`mksquashfs` is otherwise deterministic **except** fragment packing (the
`frag_deflator` thread claims output offsets from the same global counter the
main deflator advances — a race). `-no-fragments` removes the race for a
bit-identical demonstration, but **unpacked content is byte-identical either
way**, which is what matters. Keep fragments on for images you flash (smaller).

---

## Verification methodology

Two independent standards, because "the packed bytes match" is neither
achievable (fragment race) nor the point:

1. **`certify-image.sh` — bootability.** Full-system emulation is impossible
   (QEMU has no KS8695 machine model, and this kernel is single-platform
   pre-devicetree `CONFIG_ATAGS`), so instead it verifies *every precondition the
   real boot chain checks*: header magic; a Python re-implementation of the boot
   shim's search (`base 0x03240000`, read length at +4, scan 4 KB for ARM zImage
   magic `0x016f2818`, read end at +8, copy to `0x9000`); XZ decompression of the
   kernel payload (scan **all** magics — the real payload is the *second* XZ magic,
   not the decompressor stub); the embedded BSD checksum `netflash` checks; a real
   loop-mount with the kernel's own squashfs driver (pad to 4K — the loop device
   truncates to 512 bytes and would cut the id table); execution of the mounted
   `busybox`/`sshd` under **`qemu-arm -cpu ti925t`** (a true ARMv4T core — the
   default QEMU CPU is a modern ARMv7 that would run ARMv5 code the real chip
   can't); and a static scan that every ELF declares `Tag_CPU_arch` ≤ v4T.

2. **`verify-unpacked.sh` — content identity.** Loop-mount built and reference
   images **as root** (a non-root `unsquashfs` silently drops setuid and can't
   make device nodes, hiding the exact differences you're checking) and diff the
   full entry list, per-file sha256, non-dir metadata, symlink targets, and
   device nodes.

---

## Flashing & recovery

### Partition layout (`drivers/mtd/maps/snaparm.c`)

| dev | offset | size | contents |
|---|---|---|---|
| `mtd0` | `0x000000` | 128 KB | U-Boot |
| `mtd1` | `0x020000` | 128 KB | system config — **MAC addresses + boot args** |
| `mtd2` | `0x040000` | 2 MB | non-volatile config — **`/etc/config` (JFFS2)** |
| `mtd3` | `0x240000` | ~14.4 MB | **the firmware image** (absorbs remaining flash) |
| `mtd4` | `0x000000` | 16 MB | whole chip |

The 16 MB chip is **bank-switched** (`CONFIG_MTD_SNAPARM_BANK`): a single 4 MB
`ioremap` window at `0x03800000` with `ERGCON` bank selection — so all of flash
is reachable and there is no hidden size cliff at 16 MB−128 KB.

### What a firmware flash does — and does not — touch

- **`netflash` writes only `mtd3`.** Your config (`mtd2`) is untouched. Config
  erase is opt-in via a `-E` flag in the web UI's *Firmware Options* field —
  **leave it blank** and settings survive an upgrade (schema is migrated in place
  on first boot by `/etc/scripts/migrate`).
- `netflash` validates **checksum + version + vendor + product** before writing,
  so a truncated download or wrong-product image is rejected while the old image
  is still intact. `-i` bypasses the version gate (deliberate downgrades); type it
  into *Firmware Options*.
- **The 3.16.6u1 firmware's `netflash` has a non-tty bug** (fixed in 4.1.0): drive
  a flash from the **web UI or a real serial console — never a scripted SSH
  session**.
- **The real ceiling is the bootloader's, not the partition's.** The stock
  `bootcmd=gofsk 0x03240000 0x00da0000` declares a length one 128 KB erase block
  *short* of `mtd3`. An image between the two sizes flashes cleanly and may not
  boot — `certify-image.sh` gates on the smaller bootloader region.

### Flashing, step by step (web UI)

1. **Verify the download:** `sha256sum -c SHA256SUMS`.
2. **Stage recovery first** (see below) — `recovery.bin` on a FAT USB stick
   renamed `image.bin`, or a TFTP host ready.
3. **Browse to the unit** (`http://<its-ip>`, or `https://` if HTTP is off) and
   log in as `root`.
4. **System → Firmware**, choose the `.flash`, and **leave *Firmware Options*
   blank** — that preserves your config (`-i` there forces a downgrade).
5. **Start it, and do not cut power.** netflash validates checksum + version +
   vendor + product, writes `mtd3`, and reboots. A same-series upgrade is back in
   ~3 min; a **major-version jump** (e.g. 3.16 → 4.1) runs config migration on
   first boot and can take **8–10 min of silence — do not interrupt it** (that is
   the one way to actually corrupt config).
6. If the web UI doesn't answer after a major upgrade, try **`https://`** — the
   migration may harden HTTP off by default. Confirm the new version under
   *System → Firmware* and that your serial ports/network survived.

### The boot chain (U-Boot 1.1.1, decompiled)

`recovery_setup()` runs on every boot and reads the **ERASE button** (KS8695 GPIO
data register `0x03FFE608`, bit 3, active-low):

- **ERASE held** → network recovery: `bootp 0x400000; gofsk 0x400000`, and it
  raises `bootdelay` to 2 (which is what opens U-Boot's "press any key" window;
  normal boot is `bootdelay=0`, so the prompt is unreachable without ERASE).
- **ERASE up** → auto-probes USB for a file named `image.bin` (`gofsk 0x2000000`);
  if none, sets `bootargs` from the stored pointer and boots `mtd3` normally.

`gofsk fsaddr [fslen]` (custom SnapGear command) validates **only** the cramfs/romfs
magic and that the kernel start is within `fslen`, then copies `shim`+`zImage` to
`0x8000` and jumps — **no checksum or kernel-magic check**. The shim then relocates
the real zImage. So a structurally-valid-but-corrupt image boots into garbage and
hangs; `netflash`'s pre-write validation is the real protection.

### Three recovery paths — all reload into RAM, none need a valid `mtd3`

Enter each by **holding ERASE while powering on**:

1. **TFTP** — DHCP+TFTP on `192.168.0.100/24`, pool from `192.168.0.10`, boot-file =
   a recovery `.flash`. Unit BOOTPs + TFTPs to `0x400000`, `gofsk`s it, then serves
   a plain-HTTP recovery UI at its DHCP address to reflash `mtd3`.
2. **Serial / Kermit** — 115200 8N1; interrupt autoboot, then `loadb 0x400000`,
   send the `.flash` via Kermit (~30 min), `gofsk 0x400000`.
3. **USB** — a FAT stick with `image.bin` in the root, auto-loaded even without
   ERASE. Simplest if you have physical access.

Only a corrupt **`mtd0` bootloader** requires JTAG (20-pin ARM header, OCDemon +
`arm-elf-gdb`) — and `netflash` never writes `mtd0`/`mtd1`.

**Recommended before any flash — stage recovery first.** Grab `recovery.bin`
from the [release](../../releases/latest) (Opengear's IM42xx recovery image; also
on Opengear's FTP under `.../end_of_sale_products/recovery/`) and either:

- copy it to the root of a **FAT-formatted USB stick, renamed `image.bin`** — the
  unit auto-boots it on power-on with no ERASE needed, into a recovery web UI that
  reflashes `mtd3`; or
- serve it over TFTP for the ERASE-held network-recovery path above.

Then a bad flash is a 2-minute recovery, not a brick.

---

## Platform limits — what this hardware can and cannot run

- **ARMv4T is a hard wall for Go.** The stock Go toolchain (`GOARM=5`) and gccgo
  both emit `blx`/`clz` — ARMv5T instructions the ARM922T lacks — so their
  binaries die with SIGILL on a true ARMv4T core (verified under
  `qemu-arm -cpu ti925t`). **Consequence: `cloudflared`, Docker, LXC, WireGuard,
  and Tailscale cannot run on this box.** gccgo's *own* codegen at `-march=armv4t`
  is clean (0 ARMv5 instructions), but the prebuilt `libgo` runtime is not —
  so a from-source `libgo` rebuild is the only (large) path to simple Go, and it
  still won't produce modern Go. GCC C/C++ at `-march=armv4t -mcpu=arm922t` works
  fine (link against the CDK's uClibc, not a distro's ARMv5TE glibc).
- **The CDK line.** Opengear published devkits from 3.x through **4.13.1
  (2022-11)** for these legacy platforms. Across that whole span the kernel stayed
  **3.10** and OpenSSL stayed **1.0.1u (2016)** — the buildable firmware is frozen
  in 2016. The **4.9.0u1+** devkits target a *different* SoC family (Marvell
  Armada 370, **ARMv7-A hard-float**, `cm71xx`/`acm700x`/`im72xx`) where Go and
  modern crypto do run natively; current shipping firmware there (5.x) runs Linux
  5.17 / OpenSSL 3.x / OpenSSH 10.x but ships **no devkit** — so on the modern
  boxes you choose between *reproducible source* and *modern crypto*, not both.

---

## Security notes (this firmware family, not any specific unit)

Findings from static analysis of the firmware, relevant to anyone running one:

- **The HTTPS server private key ships inside the firmware image** and is seeded
  to `/etc/config` on first boot; `gen-keys` regenerates SSH host keys but **not**
  this cert. The default web certificate is an expired 1024-bit SHA-1
  `CN=192.168.0.1` — replace it.
- **`/bin/obfusc` is reversible with no key** (`-d` takes only the ciphertext), so
  any obfuscated secret in a `.opg` config backup should be treated as disclosed.
- **The factory root password hash ships in `/etc/default/passwd`** — MD5-crypt of
  the literal `default`. Fine as a documented factory credential, but public by
  construction; make sure your unit has been reconfigured off it.
- No hardware RNG and software-only crypto on a ~166 MHz core — **CVE-2016-6515**
  (pre-auth password DoS) is the credible technical risk, and it is not fixed by a
  newer OpenSSH.
- A full sweep found **no backdoor, no undocumented account, no telemetry** — the
  only external URL is the vendor cellular-firmware download path.

**The highest-value hardening is not a custom build — it is removing public
exposure of ports 22/443** (a VPN/jump host or a source ACL). Treat a custom
firmware as the durable follow-up, not the first line of defence.

---

## Repository layout

```
scripts/     reproduce.sh, certify-image.sh, verify-unpacked.sh,
             setup-container.sh, extract-rootfs.sh,
             make-flash-from-mtd3.sh, make-opg.sh
docs/        supplementary notes
NOTICE.md    what is and isn't included; vendor/GPL attribution
```

`dl/`, `build/`, `cdk/`, `archive/`, `flash-ready/` and all `*.flash`/`*.img`/
`*.bin` are git-ignored — you supply the CDK, toolchain, and any device dumps
locally; none of that belongs in the repo.

---

## Acknowledgements

Built on Opengear's Custom Development Kit and the uClinux-dist / SnapGear
lineage (the `gofsk` U-Boot command traces to Greg Ungerer's KS8695 board
support). Reverse-engineering used radare2 and Ghidra on publicly downloadable
firmware. See [`NOTICE.md`](NOTICE.md).
