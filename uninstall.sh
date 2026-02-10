#!/bin/bash
# Revert all suspend/resume fixes:
# 1. Re-enables NVIDIA sleep services
# 2. Removes session freeze overrides
# 3. Removes s2idle kernel parameter (reverts to S3 deep)

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Please run as root: sudo ./uninstall.sh"
    exit 1
fi

echo "[1/3] Re-enabling NVIDIA suspend/resume services..."
systemctl enable nvidia-suspend.service nvidia-resume.service \
    nvidia-hibernate.service nvidia-suspend-then-hibernate.service 2>/dev/null || true

echo "[2/3] Removing session freeze overrides..."
for svc in systemd-suspend systemd-hibernate systemd-hybrid-sleep systemd-suspend-then-hibernate; do
    rm -f "/etc/systemd/system/${svc}.service.d/override-nvidia-freeze.conf"
    rmdir "/etc/systemd/system/${svc}.service.d" 2>/dev/null || true
done

systemctl daemon-reload

echo "[3/3] Removing s2idle kernel parameter..."

PARAM="mem_sleep_default=s2idle"

# systemd-boot
if [[ -d /boot/loader/entries ]]; then
    for entry in /boot/loader/entries/*.conf; do
        [[ -f "$entry" ]] || continue
        if grep -q "$PARAM" "$entry"; then
            sed -i "s|${PARAM} ||; s| ${PARAM}||; s|${PARAM}||" "$entry"
            echo "  Removed from: $(basename "$entry")"
        fi
    done
fi

# GRUB
if [[ -f /etc/default/grub ]]; then
    if grep -q "$PARAM" /etc/default/grub; then
        sed -i "s|${PARAM} ||; s| ${PARAM}||; s|${PARAM}||" /etc/default/grub
        echo "  Removed from GRUB config. Run 'grub-mkconfig -o /boot/grub/grub.cfg' to apply."
    fi
fi

echo ""
echo "Done! All fixes reverted."
echo "Reboot to apply changes."
