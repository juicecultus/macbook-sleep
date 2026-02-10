#!/bin/bash
# Fix suspend/resume on MacBook running Linux with COSMIC desktop
# Disables NVIDIA sleep services (no NVIDIA GPU present) and restores session freezing

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

echo "Disabling NVIDIA suspend/resume services..."
systemctl disable nvidia-suspend.service nvidia-resume.service \
    nvidia-hibernate.service nvidia-suspend-then-hibernate.service 2>/dev/null || true

echo "Restoring session freezing during sleep..."
for svc in systemd-suspend systemd-hibernate systemd-hybrid-sleep systemd-suspend-then-hibernate; do
    mkdir -p "/etc/systemd/system/${svc}.service.d"
    cat > "/etc/systemd/system/${svc}.service.d/override-nvidia-freeze.conf" <<EOF
[Service]
Environment="SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=1"
EOF
done

systemctl daemon-reload

echo ""
echo "Done! NVIDIA sleep services disabled and session freezing restored."
echo "Try suspending your MacBook to verify the fix."
