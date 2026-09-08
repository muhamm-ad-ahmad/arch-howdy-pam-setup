# arch-howdy-pam-setup (with Omarchy & SDDM support)

Automated PAM configuration script to set up [Howdy](https://github.com/boltgolt/howdy) / [howdy-next](https://github.com/Howdy-Next/howdy-next) facial recognition authentication on **Arch Linux**, **CachyOS**, and **Omarchy**.

## Features

- **Automated Module Detection**: Automatically discovers `pam_howdy.so` under `/usr/lib/`.
- **Sudo & System Auth**: Configures `/etc/pam.d/sudo` and `/etc/pam.d/system-auth` for terminal commands, polkit prompts, and standard display managers.
- **SDDM Greeter / Login Screen Support**:
  - Automatically configures `/etc/pam.d/sddm` for Howdy face authentication.
  - Automatically triggers Howdy face scan when the SDDM greeter loads (no keys needed!).
  - Adds "Scanning face…" visual status indicator and allows pressing <kbd>Enter</kbd> to re-scan.
- **Omarchy Lockscreen Support**:
  - Automatically detects Omarchy desktop.
  - Configures Omarchy's dedicated PAM service (`/etc/pam.d/omarchy-lock-password`).
  - Patches the generator template (`/usr/bin/omarchy-apply-lock`) to survive updates.
  - Patches the Quickshell lock UI (`LockView.qml` & `Service.qml`) so you can **simply press <kbd>Enter</kbd>** to trigger facial recognition without typing a password!
  - Restarts the Omarchy shell to apply changes immediately.
- **Safe & Idempotent**: Safe to run multiple times without duplicating lines. Creates timestamped `.bak` files before modifying anything.
- **Full Undo Support**: Easily rollback changes with `--undo`.

---

## Prerequisites

Make sure `howdy` or `howdy-next` is installed and you have enrolled your face:

```bash
# Example with howdy-next:
yay -S howdy-next
sudo howdy add
sudo howdy test
```

---

## Usage

### 1. Preview changes (Dry Run)
```bash
sudo ./howdy-pam-setup.sh --dry-run
```

### 2. Apply configuration
```bash
sudo ./howdy-pam-setup.sh
```

### 3. Revert changes (Undo)
```bash
sudo ./howdy-pam-setup.sh --undo
```

---

## How to Test

1. **Test Sudo**:
   ```bash
   sudo -k && sudo whoami
   ```
   Confirm Howdy scans your face and outputs `root`.

2. **Test Lock Screen**:
   Lock your desktop (<kbd>Super</kbd> + <kbd>Ctrl</kbd> + <kbd>L</kbd>).
   **Just press <kbd>Enter</kbd>** without typing anything. The prompt will show `Checking…`, the IR camera will scan your face, and the screen will unlock!

3. **Test Greeter / Login Screen**:
   When you boot up or log out to the SDDM greeter, the camera will automatically turn on to scan your face and log you in. You can also press <kbd>Enter</kbd> to trigger the scan, or type your password as a fallback.
