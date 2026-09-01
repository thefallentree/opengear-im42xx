# References

Public sources. Nothing here is redistributed — fetch from the originals.

## Opengear (obtain the CDK, toolchains, firmware, recovery images yourself)

- Devkits + toolchains: `https://ftp.opengear.com/download/3rd_party_support_and_scripts/cdk/`
  (checksums in `cdk/SHASUMS`)
- Recovery guide + recovery images:
  `https://ftp.opengear.com/download/opengear_appliances/end_of_sale_products/recovery/`
- End-of-sale firmware archive:
  `https://ftp.opengear.com/download/opengear_appliances/`
- GPL source: Opengear's current user manual carries the written offer
  ("Opengear will provide source code … upon request"); contact
  `support@opengear.com`.

## Hardware / software lineage

- Micrel/Kendin **KS8695P** datasheet (now Microchip).
- **uClinux-dist** / SnapGear — origin of the `gofsk` U-Boot command
  (Greg Ungerer's KS8695 board support on the U-Boot mailing list).
- Go on ARM — the `GOArm` wiki and the golang-dev "ARMv4 support" threads
  (rejected for mainline; ARMv4T needs a locally patched toolchain).

## Tools used for analysis

- `radare2`, Ghidra — static analysis / decompilation.
- `qemu-user` (`qemu-arm -cpu ti925t`) — ARMv4T userland execution check.
- `binutils` (`readelf -A`) — ARM architecture attribute checks.
