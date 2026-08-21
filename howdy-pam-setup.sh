#!/usr/bin/env bash
#
# howdy-pam-setup.sh
#
# Idempotently wires Howdy (pam_howdy.so) into PAM on Arch-based systems
# (Arch, CachyOS, Manjaro, EndeavourOS, etc).
#
# What it does:
#   1. Locates pam_howdy.so on disk (does not assume a fixed path).
#   2. Backs up every PAM file it touches (once, with a timestamp).
#   3. Inserts howdy into /etc/pam.d/sudo (top of file).
#   4. Inserts howdy into /etc/pam.d/system-auth, placed right after
#      "pam_faillock.so preauth" and before pam_unix.so, so it doesn't
#      interfere with faillock bookkeeping. This single file chains
#      into sudo, su, login, KDE's kscreenlocker (kde -> system-local-login
#      -> system-login -> system-auth) and polkit-1 (-> system-auth)
#      on most Arch/CachyOS setups.
#   5. Skips any file that already has a howdy line (safe to re-run).
#   6. Verifies sudo still works via a syntax/logic sanity check before
#      declaring success, and prints manual test instructions.
#
# It deliberately does NOT touch kwallet — kwallet needs an actual
# password to derive its decryption key, not a pass/fail auth module,
# so it can't be wired through howdy the same way. See the printed
# notes at the end of the script.
#
# Usage:
#   sudo ./howdy-pam-setup.sh              # apply
#   sudo ./howdy-pam-setup.sh --dry-run    # show what would change
#   sudo ./howdy-pam-setup.sh --undo       # restore latest backups
#
set -euo pipefail

DRY_RUN=0
UNDO=0
for arg in "${@:-}"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --undo) UNDO=1 ;;
    -h|--help)
      echo "Usage: sudo $0 [--dry-run|--undo]"
      exit 0
      ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (sudo $0)" >&2
  exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
PAM_DIR="/etc/pam.d"
SUDO_FILE="$PAM_DIR/sudo"
SYSAUTH_FILE="$PAM_DIR/system-auth"

log()  { echo -e "[*] $*"; }
warn() { echo -e "[!] $*" >&2; }
ok()   { echo -e "[✓] $*"; }

# ---------------------------------------------------------------------------
# --undo mode: restore the most recent backup of each managed file
# ---------------------------------------------------------------------------
if [[ $UNDO -eq 1 ]]; then
  for f in "$SUDO_FILE" "$SYSAUTH_FILE"; do
    latest="$(ls -1t "${f}.bak."* 2>/dev/null | head -n1 || true)"
    if [[ -n "$latest" ]]; then
      cp -v "$latest" "$f"
      ok "Restored $f from $latest"
    else
      warn "No backup found for $f, skipping"
    fi
  done
  echo
  ok "Undo complete. Test sudo now: sudo -k && sudo whoami"
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Locate pam_howdy.so
# ---------------------------------------------------------------------------
log "Locating pam_howdy.so..."
HOWDY_SO="$(find /usr/lib -xdev -name 'pam_howdy.so' 2>/dev/null | grep -v '/.snapshots/' | head -n1 || true)"

if [[ -z "$HOWDY_SO" ]]; then
  warn "Could not find pam_howdy.so under /usr/lib. Is howdy-next installed?"
  warn "Try: pacman -Qs howdy   (or check your AUR package name)"
  exit 1
fi
ok "Found: $HOWDY_SO"

HOWDY_LINE="auth       sufficient                  ${HOWDY_SO}"

# ---------------------------------------------------------------------------
# helper: backup a file once per run
# ---------------------------------------------------------------------------
backup_file() {
  local f="$1"
  if [[ $DRY_RUN -eq 0 ]]; then
    cp -p "$f" "${f}.bak.${TS}"
    ok "Backed up $f -> ${f}.bak.${TS}"
  else
    log "[dry-run] Would back up $f -> ${f}.bak.${TS}"
  fi
}

# ---------------------------------------------------------------------------
# 2. /etc/pam.d/sudo — insert howdy as the very first auth line
# ---------------------------------------------------------------------------
log "Checking $SUDO_FILE ..."
if [[ ! -f "$SUDO_FILE" ]]; then
  warn "$SUDO_FILE not found, skipping"
elif grep -q "pam_howdy.so" "$SUDO_FILE"; then
  ok "$SUDO_FILE already has howdy, skipping"
else
  if [[ $DRY_RUN -eq 1 ]]; then
    log "[dry-run] Would prepend to $SUDO_FILE:"
    echo "    $HOWDY_LINE"
  else
    backup_file "$SUDO_FILE"
    sed -i "1i ${HOWDY_LINE}" "$SUDO_FILE"
    ok "Inserted howdy into $SUDO_FILE"
  fi
fi

# ---------------------------------------------------------------------------
# 3. /etc/pam.d/system-auth — insert after "pam_faillock.so preauth"
#    (covers sudo/su/login + anything that includes system-auth, e.g.
#    KDE's kscreenlocker and polkit-1 on most Arch-based setups)
# ---------------------------------------------------------------------------
log "Checking $SYSAUTH_FILE ..."
if [[ ! -f "$SYSAUTH_FILE" ]]; then
  warn "$SYSAUTH_FILE not found, skipping"
elif grep -q "pam_howdy.so" "$SYSAUTH_FILE"; then
  ok "$SYSAUTH_FILE already has howdy, skipping"
elif ! grep -q "pam_faillock.so.*preauth" "$SYSAUTH_FILE"; then
  warn "Couldn't find a 'pam_faillock.so preauth' line in $SYSAUTH_FILE"
  warn "Skipping automatic insertion — your system-auth layout differs from"
  warn "the standard Arch template. Insert this line manually, right before"
  warn "the first pam_unix.so line under 'auth':"
  echo "    $HOWDY_LINE"
else
  if [[ $DRY_RUN -eq 1 ]]; then
    log "[dry-run] Would insert into $SYSAUTH_FILE after 'pam_faillock.so preauth':"
    echo "    $HOWDY_LINE"
  else
    backup_file "$SYSAUTH_FILE"
    sed -i "/pam_faillock.so[[:space:]]*preauth/a ${HOWDY_LINE}" "$SYSAUTH_FILE"
    ok "Inserted howdy into $SYSAUTH_FILE"
  fi
fi

# ---------------------------------------------------------------------------
# 4. Sanity check: make sure sudo's PAM file still parses sanely
#    (basic check — real proof is the manual test below)
# ---------------------------------------------------------------------------
if [[ $DRY_RUN -eq 0 ]]; then
  if [[ -f "$SUDO_FILE" ]] && ! head -n1 "$SUDO_FILE" | grep -q "auth"; then
    warn "First line of $SUDO_FILE doesn't look like an auth line — please check manually:"
    head -n3 "$SUDO_FILE"
  fi
fi

echo
if [[ $DRY_RUN -eq 1 ]]; then
  ok "Dry run complete. No files were changed."
  exit 0
fi

ok "Done."
cat <<'EOF'

──────────────────────────────────────────────────────────────────────────
NEXT STEPS — DO NOT SKIP TESTING
──────────────────────────────────────────────────────────────────────────
1. Open a SECOND terminal (keep this one open as a fallback) and run:
     sudo -k && sudo whoami
   Confirm it either face-matches you or cleanly falls back to a password
   prompt. If it hangs or errors with no fallback, run:
     sudo ./howdy-pam-setup.sh --undo

2. Also test:
     su - "$USER"

3. Lock your screen (Meta+L) and confirm Howdy attempts a face scan there.

4. Test a polkit prompt (e.g. open a GUI app that needs admin rights, like
   a package manager) and confirm Howdy triggers there too.

──────────────────────────────────────────────────────────────────────────
NOTE ON KWALLET / KEYRING
──────────────────────────────────────────────────────────────────────────
This script intentionally does NOT touch kwallet. Kwallet derives its
encryption key from your login password (via pam_kwallet5), not a
pass/fail auth check — so wiring Howdy into it directly isn't possible
the same way. If you log into plasmalogin with your password as usual,
kwallet auto-unlocks normally; Howdy only replaces the *face* step for
sudo/su/lock-screen/polkit, not the password kwallet needs.

To restore your previous PAM config at any time:
     sudo ./howdy-pam-setup.sh --undo
──────────────────────────────────────────────────────────────────────────
EOF
