#!/usr/bin/bash
# Uninstall the HONOR touchpad ACPI fix + hook, and strip the injection from
# existing BLS entries.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Please run with sudo" >&2; exit 1; }

echo "==> Removing the kernel-install hook"
rm -f /etc/kernel/install.d/91-honor-touchpad-acpi.install

echo "==> Stripping /acpi-touchpad-override.img from all BLS entries' initrd lines"
shopt -s nullglob
for f in /boot/loader/entries/*.conf; do
    sed -i -E 's#[[:space:]]*/acpi-touchpad-override\.img##g' "$f"
done

echo "==> Deleting image /boot/acpi-touchpad-override.img"
rm -f /boot/acpi-touchpad-override.img

echo "Done. After reboot the touchpad reverts to its unfixed state."
