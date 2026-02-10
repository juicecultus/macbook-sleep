# MacBook Suspend/Resume Fix for Linux

Fixes broken suspend/resume on Intel-only MacBooks running Linux with the COSMIC desktop (or any setup where `nvidia-utils` is installed without an NVIDIA GPU).

## The Problem

The `nvidia-utils` package (often pulled in as a dependency by `cosmic-session`) installs:

1. **NVIDIA suspend/resume services** (`nvidia-suspend`, `nvidia-resume`, `nvidia-hibernate`, `nvidia-suspend-then-hibernate`) that run during every sleep cycle — but fail or hang because there is no NVIDIA GPU
2. **Drop-in configs** that disable `SYSTEMD_SLEEP_FREEZE_USER_SESSIONS` for all sleep services, which systemd explicitly warns causes "unexpected behavior"

### Symptoms

- System crashes or hangs on suspend/resume
- WiFi appears disabled on the lock screen after waking
- Greeter icons missing or broken after resume
- Hard reboot required to recover

## The Fix

This script:

1. **Disables** the 4 NVIDIA sleep services (they do nothing without an NVIDIA GPU)
2. **Restores session freezing** during suspend by overriding the `nvidia-utils` drop-in configs

No packages are removed — `nvidia-utils` stays installed for any packages that depend on it.

## Installation

```bash
git clone https://github.com/juicecultus/macbook-sleep.git
cd macbook-sleep
sudo ./install.sh
```

## Uninstallation

```bash
sudo ./uninstall.sh
```

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

## Supported Models

- MacBook 10,1 (12-inch, 2017)
- Likely any Intel-only MacBook where `nvidia-utils` is installed as a dependency

## Tested On

- Arch Linux with COSMIC desktop
- Kernel 6.18.x

## License

MIT
