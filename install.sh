#!/bin/bash
# Fix sleep on Intel-only MacBooks running Linux
#
# Both S3 (deep) and s2idle suspend are broken on these machines:
# - S3: Apple's EFI firmware crashes on resume
# - s2idle: Apple-specific driver resume callbacks hang the kernel
#
# The fix: use hibernate instead of suspend. Hibernate saves RAM to disk,
# does a full shutdown, then boots fresh on wake — identical to a restart
# but with the session restored. No driver resume callbacks, no firmware.
#
# This script:
# 1. Disables NVIDIA sleep services (no NVIDIA GPU present)
# 2. Restores session freezing
# 3. Creates a btrfs swap file for hibernate
# 4. Adds resume kernel parameters and rebuilds initramfs
# 5. Remaps all sleep triggers (lid close, suspend) to hibernate

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
echo "[1/5] Disabling NVIDIA suspend/resume services..."
systemctl disable nvidia-suspend.service nvidia-resume.service \
    nvidia-hibernate.service nvidia-suspend-then-hibernate.service 2>/dev/null || true

# --- Fix 2: Restore session freezing ---
echo "[2/5] Restoring session freezing during sleep..."
for svc in systemd-suspend systemd-hibernate systemd-hybrid-sleep systemd-suspend-then-hibernate; do
    mkdir -p "/etc/systemd/system/${svc}.service.d"
    cat > "/etc/systemd/system/${svc}.service.d/override-nvidia-freeze.conf" <<EOF
[Service]
Environment="SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=1"
EOF
done

systemctl daemon-reload

# --- Fix 3: Create swap file for hibernate ---
echo "[3/5] Setting up swap for hibernate..."

RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_MB=$(( RAM_KB / 1024 ))
SWAP_MB=$(( RAM_MB + 512 ))  # RAM + 512MB headroom

# Detect btrfs root
ROOT_DEV=$(findmnt -n -o SOURCE / | sed 's/\[.*\]//')

if findmnt -n -o FSTYPE / | grep -q btrfs; then
    echo "  Btrfs detected. Creating @swap subvolume..."

    # Mount top-level subvolume to create @swap at root level
    TMPDIR=$(mktemp -d)
    mount -o subvolid=5 "$ROOT_DEV" "$TMPDIR"

    if [[ ! -d "$TMPDIR/@swap" ]]; then
        btrfs subvolume create "$TMPDIR/@swap"
    else
        echo "  @swap subvolume already exists"
    fi
    umount "$TMPDIR" && rmdir "$TMPDIR"

    # Mount @swap and create swap file
    mkdir -p /swap
    if ! findmnt -n /swap > /dev/null 2>&1; then
        mount -o subvol=@swap "$ROOT_DEV" /swap
    fi

    # Add to fstab if not present
    if ! grep -q "/swap" /etc/fstab; then
        UUID=$(blkid -s UUID -o value "$ROOT_DEV")
        echo "UUID=$UUID /swap btrfs subvol=@swap,nodatacow,noatime 0 0" >> /etc/fstab
        echo "  Added /swap to fstab"
    fi

    if [[ ! -f /swap/swapfile ]]; then
        echo "  Creating ${SWAP_MB}MB swap file (this may take a moment)..."
        chattr +C /swap 2>/dev/null || true
        dd if=/dev/zero of=/swap/swapfile bs=1M count="$SWAP_MB" status=progress
        chmod 600 /swap/swapfile
        mkswap /swap/swapfile
    else
        echo "  Swap file already exists"
    fi

    swapon /swap/swapfile 2>/dev/null || true

    # Add swap activation to fstab if not present
    if ! grep -q "swapfile" /etc/fstab; then
        echo "/swap/swapfile none swap defaults 0 0" >> /etc/fstab
        echo "  Added swapfile to fstab"
    fi

    # Get btrfs physical offset for resume
    RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r /swap/swapfile)
    RESUME_DEV="$ROOT_DEV"
else
    echo "  Non-btrfs filesystem. Creating swap file at /swapfile..."

    if [[ ! -f /swapfile ]]; then
        dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_MB" status=progress
        chmod 600 /swapfile
        mkswap /swapfile
    fi

    swapon /swapfile 2>/dev/null || true

    if ! grep -q "swapfile" /etc/fstab; then
        echo "/swapfile none swap defaults 0 0" >> /etc/fstab
    fi

    RESUME_OFFSET=$(filefrag -v /swapfile | awk '$1=="0:" {print substr($4, 1, length($4)-2)}')
    RESUME_DEV="$ROOT_DEV"
fi

echo "  Resume device: $RESUME_DEV"
echo "  Resume offset: $RESUME_OFFSET"

# --- Fix 4: Kernel parameters + initramfs ---
echo "[4/5] Configuring kernel parameters and initramfs..."

RESUME_PARAMS="resume=$RESUME_DEV resume_offset=$RESUME_OFFSET"

# systemd-boot
if [[ -d /boot/loader/entries ]]; then
    for entry in /boot/loader/entries/*.conf; do
        [[ -f "$entry" ]] || continue
        if grep -q "^options " "$entry"; then
            # Remove any old mem_sleep_default param
            sed -i "s|mem_sleep_default=s2idle ||" "$entry"
            # Remove old resume params if present
            sed -i "s|resume=[^ ]* ||g; s|resume_offset=[^ ]* ||g" "$entry"
            # Add new resume params
            sed -i "s|^options |options ${RESUME_PARAMS} |" "$entry"
            echo "  Updated systemd-boot entry: $(basename "$entry")"
        fi
    done
fi

# GRUB
if [[ -f /etc/default/grub ]]; then
    if ! grep -q "resume=" /etc/default/grub; then
        sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"|GRUB_CMDLINE_LINUX_DEFAULT=\"${RESUME_PARAMS} |" /etc/default/grub
        echo "  Updated GRUB config. Run 'grub-mkconfig -o /boot/grub/grub.cfg' to apply."
    fi
fi

# Add resume hook to mkinitcpio if not present
if [[ -f /etc/mkinitcpio.conf ]]; then
    if ! grep -q "resume" /etc/mkinitcpio.conf; then
        sed -i 's/filesystems/filesystems resume/' /etc/mkinitcpio.conf
        echo "  Added 'resume' hook to mkinitcpio.conf"
    fi
    echo "  Rebuilding initramfs..."
    mkinitcpio -P
fi

# --- Fix 5: Remap sleep triggers to hibernate ---
echo "[5/5] Remapping sleep triggers to hibernate..."

# logind: lid close and suspend key → hibernate
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/hibernate.conf <<EOF
[Login]
HandleLidSwitch=hibernate
HandleLidSwitchExternalPower=hibernate
HandleSuspendKey=hibernate
EOF

# Override suspend service to actually call hibernate
# (sleep.conf SuspendState=disk breaks CanSuspend detection)
mkdir -p /etc/systemd/system/systemd-suspend.service.d
cat > /etc/systemd/system/systemd-suspend.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-sleep hibernate
EOF

systemctl daemon-reload

echo ""
echo "Done! All five fixes applied."
echo ""
echo "  - NVIDIA sleep services: disabled"
echo "  - Session freezing: restored"
echo "  - Swap file: ${SWAP_MB}MB at $(findmnt -n /swap > /dev/null 2>&1 && echo /swap/swapfile || echo /swapfile)"
echo "  - Kernel: resume=$RESUME_DEV resume_offset=$RESUME_OFFSET"
echo "  - All sleep triggers (lid, suspend) → hibernate"
echo ""
echo "Reboot now, then test by closing the lid."
echo "Wake takes ~10-15 seconds (full boot + session restore)."
