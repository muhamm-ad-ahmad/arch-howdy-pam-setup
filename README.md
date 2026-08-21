# arch-howdy-pam-setup

Automated, idempotent script to wire [Howdy](https://github.com/boltgolt/howdy) (webcam face recognition) into PAM authentication on Arch-based Linux systems.

Tested on **CachyOS + KDE Plasma**, should work on any Arch-based distro (Manjaro, EndeavourOS, vanilla Arch).

## What it does

- Locates `pam_howdy.so` automatically (no hardcoded paths)
- Backs up every PAM file it touches before editing (timestamped, restorable)
- Adds Howdy face auth to:
  - `sudo`
  - `system-auth` (which also covers `su`, `login`, KDE's lock screen via `kde` → `system-local-login` → `system-login`, and `polkit-1` — on most Arch/CachyOS setups where those files just `include system-auth`)
- Safe to re-run — skips files that already have the Howdy line instead of duplicating it
- Includes a dry-run mode to preview changes before touching anything
- Includes an undo command to restore the previous PAM config

**Not covered:** KWallet/GNOME Keyring. These derive their encryption key from your actual login password, not a pass/fail auth check, so they can't be wired through Howdy the same way. Keep logging in with your password normally and they'll keep unlocking automatically.

## Requirements

- Howdy (howdy-next or similar) already installed and your face already enrolled (`sudo howdy add`)
- Arch-based distro with the standard `system-auth` / `system-login` PAM layout

## Usage

### Download and run

```bash
curl -fsSL https://raw.githubusercontent.com/muhamm-ad-ahmad/arch-howdy-pam-setup/main/howdy-pam-setup.sh -o howdy-pam-setup.sh
chmod +x howdy-pam-setup.sh

# Preview changes first
sudo ./howdy-pam-setup.sh --dry-run

# Apply
sudo ./howdy-pam-setup.sh
```

### Or run directly without saving the file

```bash
curl -fsSL https://raw.githubusercontent.com/muhamm-ad-ahmad/arch-howdy-pam-setup/main/howdy-pam-setup.sh | sudo bash
```

### Undo

```bash
sudo ./howdy-pam-setup.sh --undo
```

Restores the most recent backup of each modified file.

## After running — test before you rely on it

Open a **second terminal** and keep your first one open as a fallback, then:

```bash
sudo -k && sudo whoami
su - "$USER"
```

Then lock your screen (`Meta+L`) and confirm Howdy attempts a face scan. Also test a polkit prompt (e.g. opening a GUI package manager).

If anything breaks, run the `--undo` command above, or restore manually from the `.bak.<timestamp>` files left next to each edited PAM file in `/etc/pam.d/`.

## Safety notes

- Howdy is always added as `auth sufficient`, never `required` — so a failed or unavailable face scan always falls back to your password. It should never lock you out on its own.
- Still, always keep a second terminal session (or a live USB) available the first time you run this, in case something in your specific PAM layout differs from the standard template.
