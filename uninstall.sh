#!/bin/bash
# Revert the suspend/resume fix — re-enables NVIDIA sleep services and removes freeze overrides

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Please run as root: sudo ./uninstall.sh"
    exit 1
fi

echo "Re-enabling NVIDIA suspend/resume services..."
systemctl enable nvidia-suspend.service nvidia-resume.service \
    nvidia-hibernate.service nvidia-suspend-then-hibernate.service 2>/dev/null || true

echo "Removing session freeze overrides..."
for svc in systemd-suspend systemd-hibernate systemd-hybrid-sleep systemd-suspend-then-hibernate; do
    rm -f "/etc/systemd/system/${svc}.service.d/override-nvidia-freeze.conf"
    rmdir "/etc/systemd/system/${svc}.service.d" 2>/dev/null || true
done

systemctl daemon-reload

echo "Done! NVIDIA sleep services restored to defaults."
