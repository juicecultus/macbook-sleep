# MacBook Sleep Fix for Linux

Fixes broken sleep on Intel-only MacBooks running Linux with the COSMIC desktop (or any setup where `nvidia-utils` is installed without an NVIDIA GPU).

## The Problems

There are three separate issues that break suspend on these machines. All three must be addressed together.

### 1. NVIDIA services running without an NVIDIA GPU

The `nvidia-utils` package (often pulled in as a dependency by `cosmic-session`) installs:

- **4 NVIDIA suspend/resume services** (`nvidia-suspend`, `nvidia-resume`, `nvidia-hibernate`, `nvidia-suspend-then-hibernate`) that run during every sleep cycle — but fail or hang because there is no NVIDIA GPU
- **Drop-in configs** that disable `SYSTEMD_SLEEP_FREEZE_USER_SESSIONS` for all sleep services, which systemd explicitly warns causes "unexpected behavior, particularly in suspend-then-hibernate operations or setups with encrypted home directories"

### 2. S3 (deep sleep) firmware crash

The Linux kernel defaults to S3 deep sleep when the ACPI tables advertise support for it. Apple's firmware reports `S0 S3 S4 S5` as supported states, so the kernel picks `deep` as the default `mem_sleep` mode.

Apple's EFI firmware was designed exclusively for macOS's IOKit power management. The S3 resume path does not work under Linux — the firmware crashes or mis-initialises hardware, killing the system before the kernel can begin its resume sequence.

**How we confirmed this:** Using `pm_test=devices` (which calls all Linux driver suspend/resume callbacks without actually entering S3), the system suspends and resumes perfectly. The crash only occurs when the system enters the actual ACPI S3 state — when Apple's firmware takes over.

Evidence from the ACPI tables at boot:
```
ACPI Error: AE_ALREADY_EXISTS, SSDT Table is already loaded
ACPI BIOS Error (bug): Could not resolve symbol [\_SB.OSCP], AE_NOT_FOUND
```

**Why S3 can't be fixed from Linux:**
- Apple's EFI firmware is closed-source and read-only
- The resume crash happens in firmware, before Linux regains control
- DSDT patching is fragile and the crash may be in the EFI itself
- There is no known upstream kernel fix for MacBook 10,1 S3 resume

### 3. s2idle driver resume callbacks hang

Even with s2idle (which avoids the S3 firmware path), Apple-specific kernel modules do not properly reinitialise hardware after waking. The SPI controller managing the keyboard/touchpad (`applespi` via `intel-lpss` / `pxa2xx-spi`) hangs during its resume callback, making the keyboard and touchpad completely unresponsive and eventually freezing the system.

**How we confirmed this:** After switching to s2idle, the display came back and the greeter appeared, but the keyboard was dead — even on a plain TTY (no Wayland compositor). Unloading `brcmfmac`, `facetimehd`, and `acpi_call` before suspend did not help. The system-sleep post hooks never executed, confirming the kernel hangs during the device resume path before systemd regains control.

**Why s2idle can't be fixed by unloading modules:**
- Unloading `applespi` before suspend prevents keyboard wake events
- The kernel hangs during device resume before post-hooks can reload modules
- The root cause is in the SPI controller / intel-lpss resume path, not a single module

### Symptoms

- System crashes or hangs on suspend/resume
- Display goes dark briefly then returns to the greeter with no WiFi
- Keyboard and touchpad unresponsive after wake (even on TTY)
- Desktop crashes after login (only wallpaper visible, no panels/dock)
- Hard reboot required to recover

## The Fix: Hibernate

Since both S3 and s2idle suspend are broken at the firmware/driver level, the solution is **hibernate**. Hibernate works exactly like a restart (full hardware initialisation from scratch) but preserves the session:

1. Saves RAM contents to a swap file on disk
2. Shuts down completely (clean power off)
3. On wake: boots fresh — BIOS, bootloader, kernel, drivers all initialise from scratch
4. The initramfs `resume` hook detects saved state and restores RAM
5. Session is back exactly as before

No driver resume callbacks. No firmware resume path. Just a clean boot every time.

### Trade-offs

| | S3 / s2idle | Hibernate |
|---|---|---|
| **Wake time** | Instant (if it worked) | ~10-15 seconds (full boot) |
| **Power in sleep** | ~1-5W | 0W (fully off) |
| **Session preserved** | Yes | Yes |
| **Reliability** | Broken | Works perfectly |
| **Battery in sleep** | Drains slowly | Zero drain |

Hibernate actually has a battery advantage — the machine draws zero power while sleeping.

## Installation

```bash
git clone https://github.com/juicecultus/macbook-sleep.git
cd macbook-sleep
sudo ./install.sh
```

The script will:
1. Disable NVIDIA sleep services
2. Restore session freezing
3. Create a swap file (RAM size + 512MB) on a btrfs `@swap` subvolume
4. Add `resume=` and `resume_offset=` kernel parameters
5. Add the `resume` hook to mkinitcpio and rebuild the initramfs
6. Remap lid close and suspend triggers to hibernate

**Reboot** after installation, then test by closing the lid.

## Uninstallation

```bash
sudo ./uninstall.sh
```

Reboot after uninstalling.

## What It Changes

### Services disabled

- `nvidia-suspend.service`
- `nvidia-resume.service`
- `nvidia-hibernate.service`
- `nvidia-suspend-then-hibernate.service`

### Drop-in overrides created

For each of `systemd-suspend`, `systemd-hibernate`, `systemd-hybrid-sleep`, and `systemd-suspend-then-hibernate`:

```
/etc/systemd/system/<service>.service.d/override-nvidia-freeze.conf
```

```ini
[Service]
Environment="SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=1"
```

### Swap file

- Btrfs: `@swap` subvolume mounted at `/swap`, swap file at `/swap/swapfile`
- Other filesystems: `/swapfile`
- Size: RAM + 512MB
- Added to `/etc/fstab`

### Kernel parameters

```
resume=/dev/nvme0n1p5 resume_offset=<offset>
```

Added to boot loader entries (systemd-boot and/or GRUB).

### Initramfs

`resume` hook added to `/etc/mkinitcpio.conf` HOOKS array (before `fsck`).

### Hibernate configuration

`/etc/systemd/logind.conf.d/hibernate.conf`:
```ini
[Login]
HandleLidSwitch=hibernate
HandleLidSwitchExternalPower=hibernate
HandleSuspendKey=hibernate
```

`/etc/systemd/sleep.conf.d/hibernate.conf`:
```ini
[Sleep]
SuspendState=disk
HibernateMode=platform shutdown
```

## Supported Models

- MacBook 10,1 (12-inch, 2017)
- Likely any Intel-only MacBook where suspend is broken

## Tested On

- Arch Linux with COSMIC desktop
- Kernel 6.18.x
- Btrfs with subvolume layout (`@`, `@home`, `@swap`)

## License

MIT
