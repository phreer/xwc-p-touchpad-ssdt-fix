#!/usr/bin/bash
#
# Install the HONOR XWC-P touchpad ACPI fix + a kernel-install hook so it
# survives kernel upgrades. Fedora grub2 + BLS only.
#
# Usage: sudo ./install.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMG_SRC="$HERE/acpi-touchpad-override.img"
IMG_DST="/boot/acpi-touchpad-override.img"
HOOK_SRC="$HERE/91-honor-touchpad-acpi.install"
HOOK_DST="/etc/kernel/install.d/91-honor-touchpad-acpi.install"

[ "$(id -u)" -eq 0 ] || { echo "Please run with sudo" >&2; exit 1; }
[ -f "$IMG_SRC" ] || { echo "Not found: $IMG_SRC" >&2; exit 1; }

# This installer supports grub2 + BLS only (not UKI / systemd-boot / rpm-ostree).
if [ ! -d /boot/loader/entries ] || ! ls /boot/loader/entries/*.conf >/dev/null 2>&1; then
    cat >&2 <<'MSG'
Error: no grub2 + BLS layout detected (/boot/loader/entries/*.conf).
Use the manual "GRUB multiple initrds" method in README.md for your system.
MSG
    exit 1
fi
if [ -d /run/ostree-booted ]; then
    echo "Error: rpm-ostree/atomic system detected; this script does not apply." >&2
    exit 1
fi

echo "==> [1/3] Installing override image to $IMG_DST"
install -m 0644 "$IMG_SRC" "$IMG_DST"

echo "==> [2/3] Installing kernel-install hook to $HOOK_DST"
install -D -m 0755 "$HOOK_SRC" "$HOOK_DST"

echo "==> [3/3] Applying to all currently installed kernels"
shopt -s nullglob
applied=0
for kdir in /usr/lib/modules/*/; do
    kv="$(basename "$kdir")"
    if ls /boot/loader/entries/*"$kv"*.conf >/dev/null 2>&1; then
        COMMAND=add \
        KERNEL_INSTALL_LAYOUT=bls \
        KERNEL_INSTALL_MACHINE_ID="$(cat /etc/machine-id)" \
        "$HOOK_DST" add "$kv" >/dev/null 2>&1 || true
        applied=$((applied+1))
    fi
done
echo "    Applied to $applied kernel(s)."

echo
echo "Done. Injected initrd lines:"
grep -H '^[[:space:]]*initrd' /boot/loader/entries/*.conf \
    | grep --color=never acpi-touchpad-override.img \
    || echo "  (none found; check /boot/loader/entries/)"
echo
echo "Reboot, then verify:"
echo "  sudo dmesg | grep -iE 'Table Upgrade|I2CDEVC'"
echo "  grep -i Touchpad /proc/bus/input/devices"
