#!/bin/bash
# Fix suspend/resume on Intel-only MacBooks running Linux
#
# 1. Disables NVIDIA sleep services (no NVIDIA GPU present)
# 2. Restores session freezing during suspend
# 3. Switches from S3 (deep) to s2idle to bypass broken Apple firmware resume

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Please run as root: sudo ./install.sh"
    exit 1
fi

# Check there is no NVIDIA GPU — this fix is for Intel-only MacBooks
if lspci | grep -qi "NVIDIA"; then
    echo "WARNING: NVIDIA GPU detected. This fix is intended for Intel-only MacBooks."
    echo "Applying it may break NVIDIA suspend/resume. Continue? (y/N)"
    read -r answer
    [[ "$answer" =~ ^[Yy]$ ]] || exit 1
fi

# --- Fix 1: Disable NVIDIA suspend/resume services ---
echo "[1/3] Disabling NVIDIA suspend/resume services..."
systemctl disable nvidia-suspend.service nvidia-resume.service \
    nvidia-hibernate.service nvidia-suspend-then-hibernate.service 2>/dev/null || true

# --- Fix 2: Restore session freezing ---
echo "[2/3] Restoring session freezing during sleep..."
for svc in systemd-suspend systemd-hibernate systemd-hybrid-sleep systemd-suspend-then-hibernate; do
    mkdir -p "/etc/systemd/system/${svc}.service.d"
    cat > "/etc/systemd/system/${svc}.service.d/override-nvidia-freeze.conf" <<EOF
[Service]
Environment="SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=1"
EOF
done

systemctl daemon-reload

# --- Fix 3: Switch to s2idle ---
echo "[3/3] Configuring s2idle as default sleep mode..."

PARAM="mem_sleep_default=s2idle"
APPLIED=false

# systemd-boot
if [[ -d /boot/loader/entries ]]; then
    for entry in /boot/loader/entries/*.conf; do
        [[ -f "$entry" ]] || continue
        if grep -q "^options " "$entry"; then
            if ! grep -q "$PARAM" "$entry"; then
                sed -i "s|^options |options ${PARAM} |" "$entry"
                echo "  Added to systemd-boot entry: $(basename "$entry")"
                APPLIED=true
            else
                echo "  Already present in: $(basename "$entry")"
                APPLIED=true
            fi
        fi
    done
fi

# GRUB
if [[ -f /etc/default/grub ]]; then
    if ! grep -q "$PARAM" /etc/default/grub; then
        sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"|GRUB_CMDLINE_LINUX_DEFAULT=\"${PARAM} |" /etc/default/grub
        echo "  Added to GRUB config. Run 'grub-mkconfig -o /boot/grub/grub.cfg' to apply."
        APPLIED=true
    else
        echo "  Already present in GRUB config."
        APPLIED=true
    fi
fi

if ! $APPLIED; then
    echo "  WARNING: Could not detect boot loader. Manually add '$PARAM' to your kernel parameters."
fi

# --- Fix 4: Install module unload/reload hook ---
echo "[4/4] Installing suspend/resume module hook..."
install -m 755 "$(dirname "$0")/macbook-suspend-modules" /usr/lib/systemd/system-sleep/macbook-suspend-modules

echo ""
echo "Done! All four fixes applied."
echo ""
echo "  - NVIDIA sleep services: disabled"
echo "  - Session freezing: restored"
echo "  - Sleep mode: s2idle (bypasses broken S3 firmware)"
echo "  - Module hook: unloads applespi/brcmfmac/facetimehd before suspend, reloads after"
echo ""
echo "Reboot for the kernel parameter to take effect, then test suspend."
