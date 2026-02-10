#!/bin/bash
# Revert all sleep fixes:
# 1. Re-enables NVIDIA sleep services
# 2. Removes session freeze overrides
# 3. Removes swap file and @swap subvolume
# 4. Removes resume kernel parameters and initramfs hook
# 5. Removes hibernate logind/sleep.conf overrides

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Please run as root: sudo ./uninstall.sh"
    exit 1
fi

echo "[1/5] Re-enabling NVIDIA suspend/resume services..."
systemctl enable nvidia-suspend.service nvidia-resume.service \
    nvidia-hibernate.service nvidia-suspend-then-hibernate.service 2>/dev/null || true

echo "[2/5] Removing session freeze overrides..."
for svc in systemd-suspend systemd-hibernate systemd-hybrid-sleep systemd-suspend-then-hibernate; do
    rm -f "/etc/systemd/system/${svc}.service.d/override-nvidia-freeze.conf"
    rmdir "/etc/systemd/system/${svc}.service.d" 2>/dev/null || true
done

echo "[3/5] Removing swap file..."
swapoff /swap/swapfile 2>/dev/null || true
swapoff /swapfile 2>/dev/null || true
rm -f /swap/swapfile /swapfile
umount /swap 2>/dev/null || true

# Remove @swap subvolume
ROOT_DEV=$(findmnt -n -o SOURCE / | sed 's/\[.*\]//')
if findmnt -n -o FSTYPE / | grep -q btrfs; then
    TMPDIR=$(mktemp -d)
    if mount -o subvolid=5 "$ROOT_DEV" "$TMPDIR" 2>/dev/null; then
        btrfs subvolume delete "$TMPDIR/@swap" 2>/dev/null && echo "  Deleted @swap subvolume"
        umount "$TMPDIR"
    fi
    rmdir "$TMPDIR" 2>/dev/null || true
fi

# Remove from fstab
sed -i '\|/swap|d' /etc/fstab
sed -i '\|swapfile|d' /etc/fstab
rmdir /swap 2>/dev/null || true

echo "[4/5] Removing kernel parameters and initramfs hook..."

# systemd-boot
if [[ -d /boot/loader/entries ]]; then
    for entry in /boot/loader/entries/*.conf; do
        [[ -f "$entry" ]] || continue
        sed -i "s|mem_sleep_default=s2idle ||; s|resume=[^ ]* ||g; s|resume_offset=[^ ]* ||g" "$entry"
        echo "  Cleaned: $(basename "$entry")"
    done
fi

# GRUB
if [[ -f /etc/default/grub ]]; then
    sed -i "s|resume=[^ ]* ||g; s|resume_offset=[^ ]* ||g" /etc/default/grub
    echo "  Cleaned GRUB config. Run 'grub-mkconfig -o /boot/grub/grub.cfg' to apply."
fi

# Remove resume hook from mkinitcpio
if [[ -f /etc/mkinitcpio.conf ]]; then
    if grep -q " resume" /etc/mkinitcpio.conf; then
        sed -i 's/ resume//' /etc/mkinitcpio.conf
        echo "  Removed 'resume' hook from mkinitcpio.conf"
        echo "  Rebuilding initramfs..."
        mkinitcpio -P
    fi
fi

echo "[5/5] Removing hibernate overrides..."
rm -f /etc/systemd/logind.conf.d/hibernate.conf
rmdir /etc/systemd/logind.conf.d 2>/dev/null || true

# Remove suspend→hibernate override and module unload overrides
rm -f /etc/systemd/system/systemd-suspend.service.d/override.conf
rmdir /etc/systemd/system/systemd-suspend.service.d 2>/dev/null || true
rm -f /etc/systemd/system/systemd-hibernate.service.d/unload-modules.conf
rmdir /etc/systemd/system/systemd-hibernate.service.d 2>/dev/null || true

# Clean up old files from previous versions
rm -f /etc/systemd/sleep.conf.d/hibernate.conf
rmdir /etc/systemd/sleep.conf.d 2>/dev/null || true
rm -f /usr/lib/systemd/system-sleep/macbook-suspend-modules

systemctl daemon-reload

echo ""
echo "Done! All fixes reverted."
echo "Reboot to apply changes."
