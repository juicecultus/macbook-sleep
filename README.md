# MacBook Suspend/Resume Fix for Linux

Fixes broken suspend/resume on Intel-only MacBooks running Linux with the COSMIC desktop (or any setup where `nvidia-utils` is installed without an NVIDIA GPU).

## The Problems

There are two separate issues that break suspend on these machines:

### 1. NVIDIA services running without an NVIDIA GPU

The `nvidia-utils` package (often pulled in as a dependency by `cosmic-session`) installs:

- **4 NVIDIA suspend/resume services** (`nvidia-suspend`, `nvidia-resume`, `nvidia-hibernate`, `nvidia-suspend-then-hibernate`) that run during every sleep cycle — but fail or hang because there is no NVIDIA GPU
- **Drop-in configs** that disable `SYSTEMD_SLEEP_FREEZE_USER_SESSIONS` for all sleep services, which systemd explicitly warns causes "unexpected behavior, particularly in suspend-then-hibernate operations or setups with encrypted home directories"

### 2. S3 (deep sleep) firmware crash

The Linux kernel defaults to S3 deep sleep when the ACPI tables advertise support for it. Apple's firmware reports `S0 S3 S4 S5` as supported states, so the kernel picks `deep` as the default `mem_sleep` mode.

**The problem:** Apple's EFI firmware was designed exclusively for macOS's IOKit power management. The S3 resume path in the firmware does not work correctly under Linux. When the CPU exits S3, the firmware is responsible for re-initialising hardware before handing control back to the kernel — but it crashes or mis-initialises, killing the system before Linux can even begin its resume sequence.

**How we confirmed this:** Using `pm_test=devices` (which calls all Linux driver suspend/resume callbacks without actually entering S3), the system suspends and resumes perfectly. All Linux drivers handle sleep correctly. The crash only occurs when the system actually enters the ACPI S3 state — i.e., when Apple's firmware takes over.

Evidence from the ACPI tables at boot:
```
ACPI Error: AE_ALREADY_EXISTS, SSDT Table is already loaded
ACPI BIOS Error (bug): Could not resolve symbol [\_SB.OSCP], AE_NOT_FOUND
ACPI: [Firmware Bug]: BIOS _OSI(Linux) query ignored
```

These errors indicate Apple's DSDT/SSDT tables were not designed for Linux's ACPI interpreter. The `_WAK` (wake) method or hardware re-initialisation relies on macOS-specific state that Linux does not provide.

**Why S3 can't be fixed from Linux:**
- Apple's EFI firmware is closed-source and read-only
- The resume crash happens in firmware, before Linux regains control
- DSDT patching is fragile and the crash may be in the EFI itself, not the ACPI tables
- There is no known upstream kernel fix for MacBook 10,1 S3 resume

### 3. Apple-specific drivers fail to resume

Even with s2idle, several out-of-tree or Apple-specific kernel modules do not properly reinitialise hardware after waking. The SPI controller that manages the keyboard and touchpad (`applespi` via `intel-lpss` / `pxa2xx-spi`) loses state during suspend. On resume, the driver fails to reinitialise, leaving the keyboard and touchpad completely unresponsive.

Similarly, the Broadcom WiFi driver (`brcmfmac`) and FaceTime HD webcam driver (`facetimehd`) often fail to resume cleanly.

**How we confirmed this:** After switching to s2idle, the display came back on resume and the greeter appeared, but the keyboard was completely dead — even on a plain TTY (no Wayland compositor). This proved the issue is in the SPI/input driver resume path, not the desktop environment.

### Symptoms

- System crashes or hangs on suspend/resume
- Display goes dark briefly then returns to the greeter with no WiFi
- Keyboard and touchpad unresponsive after wake (even on TTY)
- Greeter icons missing or broken after resume
- Desktop crashes after login (only wallpaper visible, no panels/dock)
- Hard reboot required to recover

## The Fix

This script applies four fixes:

1. **Disables** the 4 NVIDIA sleep services (they do nothing without an NVIDIA GPU)
2. **Restores session freezing** during suspend by overriding the `nvidia-utils` drop-in configs
3. **Switches sleep mode from S3 (`deep`) to `s2idle`** via kernel parameter, bypassing the broken Apple firmware resume path entirely
4. **Installs a suspend/resume hook** that unloads `applespi`, `brcmfmac`, and `facetimehd` before suspend and reloads them after resume, ensuring keyboard, WiFi, and webcam work on wake

No packages are removed — `nvidia-utils` stays installed for any packages that depend on it.

### S3 (deep) vs s2idle comparison

| | S3 (deep) | s2idle |
|---|---|---|
| **Who manages sleep** | Apple firmware (broken) | Linux kernel |
| **CPU state** | Powered off | Deep C-states (very low power) |
| **RAM** | Self-refresh only | Self-refresh + CPU idle |
| **Wake speed** | ~2-3 seconds | Near-instant |
| **Power draw** | ~1-2W (if it worked) | ~2-5W |
| **Firmware involvement** | Full (crashes) | None |
| **Reliability** | Broken on MacBook 10,1 | Works on all hardware |

## Installation

```bash
git clone https://github.com/juicecultus/macbook-sleep.git
cd macbook-sleep
sudo ./install.sh
```

After installation, **reboot** for the kernel parameter to take effect.

## Uninstallation

```bash
sudo ./uninstall.sh
```

Reboot after uninstalling to revert the kernel parameter.

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

Contents:

```ini
[Service]
Environment="SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=1"
```

This overrides the `nvidia-utils` drop-in at `/usr/lib/systemd/system/<service>.service.d/10-nvidia-no-freeze-session.conf` which sets it to `false`.

### Suspend/resume module hook

```
/usr/lib/systemd/system-sleep/macbook-suspend-modules
```

Before suspend, unloads:
- `applespi` — Apple SPI keyboard/touchpad (fails to reinitialise SPI controller on wake)
- `brcmfmac` / `brcmfmac_wcc` — Broadcom WiFi (firmware reload needed)
- `facetimehd` — FaceTime HD webcam

After resume, reloads all three in the correct order.

### Kernel parameter added

```
mem_sleep_default=s2idle
```

Added to the boot loader configuration to force `s2idle` instead of `deep` as the default sleep mode. This is detected and applied for both systemd-boot and GRUB.

## Supported Models

- MacBook 10,1 (12-inch, 2017)
- Likely any Intel-only MacBook where `nvidia-utils` is installed as a dependency and S3 resume is broken

## Tested On

- Arch Linux with COSMIC desktop
- Kernel 6.18.x

## Debugging

To verify the current sleep mode:

```bash
cat /sys/power/mem_sleep
# Should show: [s2idle] deep
# The bracketed value is the active mode
```

To test device driver suspend/resume without actually sleeping:

```bash
echo devices | sudo tee /sys/power/pm_test
echo mem | sudo tee /sys/power/state
# System will suspend devices, wait 5 seconds, then resume
echo none | sudo tee /sys/power/pm_test  # Reset after testing
```

## License

MIT
