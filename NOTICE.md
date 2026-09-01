# NOTICE

This repository contains **only** original build/verify tooling and independent
technical documentation. It does **not** include, and is not, Opengear firmware
or the Opengear Custom Development Kit (CDK).

- **The CDK is Opengear's.** You must obtain it yourself from Opengear's public
  FTP (`ftp.opengear.com/download/3rd_party_support_and_scripts/cdk/`). Devkits
  are checksum-listed in `cdk/SHASUMS`.
- **The firmware contains GPL and other open-source components** (Linux kernel,
  BusyBox, U-Boot, OpenSSH, OpenSSL, Openswan, uClibc, …) plus Opengear
  proprietary components (the web UI, `pmctl`/`xmldb`, `obfusc`, …). Opengear's
  written GPL source offer is in their current user manual ("Opengear will
  provide source code … upon request").
- **The scripts here orchestrate the vendor toolchain; they do not redistribute
  it.** Running them requires you to supply the CDK and a cross-compiler
  toolchain, both fetched from Opengear.
- Trademarks (Opengear, TrippLite, Micrel, ARM, etc.) belong to their owners and
  are used here only for identification.

Everything in `scripts/` and `README.md` is the authors' own work, **provided
as-is, for convenience, with no warranty of any kind**. The reverse-engineering
documented here was produced by static analysis of publicly downloadable
firmware and a lawfully obtained unit, for interoperability, security
assessment, and preservation.
