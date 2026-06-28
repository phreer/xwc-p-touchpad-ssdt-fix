# HONOR XWC-P touchpad fix for Linux

The internal touchpad on the **HONOR XWC-P** (MagicBook, Panther Lake platform,
BIOS 1.09) does not work on Linux. This is a small ACPI fix that makes it
enumerate and work normally.

- Touchpad: `TOPS0102` / I2C-HID, on i2c bus `\_SB.PC00.I2C1` @ `0x5D`.
- Tested on Fedora (kernel 7.0.x). Works with libinput / Wayland / Xorg.

For those who want to understand the details, please read [the complete root cause analysis](./full-analysis.md). Note that the guide in this README only applies variant C of all three fixes described in the complate analysis, and only prebuilt files for variant C are included in this repo. If you want to try other variants, you will need to build the SSDT and initrd override image yourself.

## Cause

The touchpad device `TPD0` lives in a BIOS SSDT (`I2C_DEVT`). That table contains
a line of **module-level** code in the unrelated NFC device:

```asl
INT1 = GNUM (0x001A088A)
```

Running at *table-load* time, `GNUM` indexes an ACPI package before the namespace
is fully built, which trips a firmware bug (`AE_AML_INTERNAL`). The kernel rolls
back the **entire** table, so `TPD0` is never created and the touchpad never
appears. (Windows' ACPI interpreter tolerates this, so it works on the factory OS.)

## Fix

Move that one line out of module-level scope into the device's `_CRS` method, so
it runs at *runtime* when the namespace is ready. Nothing else changes — the
touchpad keeps the OEM's own resource/interrupt logic. See `ssdt-touchpad.patch`
for the exact one-line diff.

The fixed table is supplied to the kernel as an initrd **ACPI table override**.
Its OEM Table ID is renamed to `I2CDEVC` so the kernel loads it as a *new* table
instead of trying to replace (and re-crash) the BIOS one.

## Install (Fedora, grub2 + BLS)

Prebuilt files are included; no compilation needed.

```bash
sudo ./install.sh
sudo reboot
```

This copies `acpi-touchpad-override.img` to `/boot`, installs a `kernel-install`
hook so the fix is re-applied automatically on every kernel upgrade, and applies
it to all currently installed kernels.

### Verify after reboot

```bash
sudo dmesg | grep -iE "Table Upgrade|I2CDEVC"
#   expect: ACPI: Table Upgrade: install [SSDT- HONOR- I2CDEVC]
grep -i Touchpad /proc/bus/input/devices
sudo libinput debug-events       # move a finger -> coordinate events
```

### Uninstall

```bash
sudo ./uninstall.sh
```

## Install (other distros / boot setups — manual)

`acpi-touchpad-override.img` is a standard initrd cpio
(`kernel/firmware/acpi/SSDT-I2CDEVC.aml`). Have your bootloader load it **before**
the main initramfs. Quick one-off test in GRUB: press `e` on the boot entry and
edit the `initrd` line so the override comes first:

```
initrd /acpi-touchpad-override.img /initramfs-<version>.img
```

Press `Ctrl+X` to boot (affects this boot only). Other options: tuned's
`$tuned_initrd`, or a dracut ACPI-override include.

## Files

| File | Purpose |
|------|---------|
| `acpi-touchpad-override.img` | prebuilt initrd ACPI-override image (install this) |
| `ssdt-touchpad.asl` / `.aml` | the fixed SSDT, source / compiled |
| `ssdt-touchpad.patch` | the one-line fix vs. the original SSDT |
| `install.sh` / `uninstall.sh` | Fedora grub2+BLS installer / uninstaller |
| `91-honor-touchpad-acpi.install` | kernel-install hook (auto re-apply on upgrade) |
| `build.sh` | recompile the SSDT + repackage the image (only if you edit the ASL) |

## Appendix: how to obtain your machine's SSDTs

Only needed if you want to inspect/rebuild against your own firmware (e.g. a
different BIOS version). Requires `acpica-tools`.

```bash
sudo dnf install acpica-tools          # Fedora (Debian/Ubuntu: apt install acpica-tools)

mkdir acpidump && cd acpidump
sudo acpidump -b                       # dumps dsdt.dat, ssdt1.dat, ssdt2.dat, ...

# Disassemble everything together (DSDT defines symbols the SSDTs reference):
iasl -e ssdt*.dat -d dsdt.dat          # -> dsdt.dsl
iasl -d ssdt*.dat                      # -> ssdtN.dsl

# Find which SSDT holds the touchpad (the I2C_DEVT table with TPD0/TOPS0102):
for s in ssdt*.dat; do
  strings "$s" | grep -q I2C_DEVT && echo "$s is I2C_DEVT"
done
```

Note: the SSDT *number* (e.g. `ssdt27`) is just acpidump's enumeration order and
can differ between boots; identify the table by its content / OEM Table ID
(`I2C_DEVT`), not by number. To validate a modified table offline before booting:

```bash
sudo dnf install acpica-tools
acpiexec -b 'quit' dsdt.dat ssdt*.dat ssdt-touchpad.aml   # should load with 0 added failures
```
