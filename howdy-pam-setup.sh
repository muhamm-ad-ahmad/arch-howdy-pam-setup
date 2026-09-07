#!/bin/bash
# ===========================================================================
# howdy-pam-setup.sh — Automated Howdy PAM setup for Arch Linux & Omarchy
#
# Works on:
#   - Arch Linux / CachyOS (standard sudo + system-auth)
#   - Omarchy (sudo + system-auth + Quickshell lockscreen with "press Enter to scan")
#
# Features:
#   - Auto-detects pam_howdy.so location
#   - Detects Omarchy desktop and configures its custom Quickshell lock screen
#   - Patches Omarchy lock screen to trigger face scan when pressing Enter
#   - Fully idempotent (safe to re-run anytime)
#   - Creates timestamped backups of all modified files
#   - Full --undo and --dry-run support
#
# Usage:
#   sudo ./howdy-pam-setup.sh              # Apply setup
#   sudo ./howdy-pam-setup.sh --dry-run    # Preview changes without modifying
#   sudo ./howdy-pam-setup.sh --undo       # Restore latest backups
# ===========================================================================

set -euo pipefail

DRY_RUN=0
UNDO=0

for arg in "${@:-}"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --undo)    UNDO=1 ;;
    -h|--help)
      cat <<'USAGE'
howdy-pam-setup.sh - Automated Howdy PAM setup for Arch Linux & Omarchy

Usage:
  sudo ./howdy-pam-setup.sh              Apply configuration
  sudo ./howdy-pam-setup.sh --dry-run    Preview changes without applying
  sudo ./howdy-pam-setup.sh --undo       Revert to the latest backups
  sudo ./howdy-pam-setup.sh --help       Show this help message
USAGE
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      echo "Run 'sudo $0 --help' for usage." >&2
      exit 1
      ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Error: This script must be run as root (e.g. sudo $0)" >&2
  exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
PAM_DIR="/etc/pam.d"
SUDO_FILE="$PAM_DIR/sudo"
SYSAUTH_FILE="$PAM_DIR/system-auth"

# Omarchy specific paths
OMARCHY_PAM_FILE="$PAM_DIR/omarchy-lock-password"
OMARCHY_APPLY_LOCK="/usr/bin/omarchy-apply-lock"
LOCKVIEW_QML="/usr/share/omarchy/shell/plugins/lock/LockView.qml"
SERVICE_QML="/usr/share/omarchy/shell/plugins/lock/Service.qml"

ALL_MANAGED_FILES=(
  "$SUDO_FILE"
  "$SYSAUTH_FILE"
  "$OMARCHY_PAM_FILE"
  "$OMARCHY_APPLY_LOCK"
  "$LOCKVIEW_QML"
  "$SERVICE_QML"
)

# Terminal formatting
log()  { echo -e "\e[34m[*]\e[0m $*"; }
warn() { echo -e "\e[33m[!]\e[0m $*" >&2; }
ok()   { echo -e "\e[32m[✓]\e[0m $*"; }
err()  { echo -e "\e[31m[✗]\e[0m $*" >&2; }

# Helper: backup file once per run
backup_file() {
  local f="$1"
  if [[ $DRY_RUN -eq 0 ]]; then
    cp -p "$f" "${f}.bak.${TS}"
    ok "Backed up $(basename "$f") -> ${f}.bak.${TS}"
  else
    log "[dry-run] Would back up $f -> ${f}.bak.${TS}"
  fi
}

# ---------------------------------------------------------------------------
# --undo mode: restore latest backup for all managed files
# ---------------------------------------------------------------------------
if [[ $UNDO -eq 1 ]]; then
  log "Reverting changes from latest backups..."
  restored_any=0
  for f in "${ALL_MANAGED_FILES[@]}"; do
    latest="$(ls -1t "${f}.bak."* 2>/dev/null | head -n1 || true)"
    if [[ -n "$latest" ]]; then
      cp -v "$latest" "$f"
      ok "Restored $f from $latest"
      restored_any=1
    fi
  done

  if [[ $restored_any -eq 0 ]]; then
    warn "No backup files found to restore."
  else
    echo
    ok "Undo complete."
    # If Omarchy shell is running, reload it
    if command -v omarchy-restart-shell >/dev/null 2>&1; then
      log "Restarting Omarchy shell to reload restored files..."
      # Run as the actual user if running through sudo
      target_user="${SUDO_USER:-$USER}"
      if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        su - "$target_user" -c "omarchy-restart-shell" || true
      else
        omarchy-restart-shell || true
      fi
    fi
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Locate pam_howdy.so
# ---------------------------------------------------------------------------
log "Locating pam_howdy.so..."
HOWDY_SO="$(find /usr/lib -xdev -name 'pam_howdy.so' 2>/dev/null | grep -v '/.snapshots/' | head -n1 || true)"

if [[ -z "$HOWDY_SO" ]]; then
  err "Could not find pam_howdy.so under /usr/lib."
  warn "Please ensure howdy or howdy-next is installed (e.g. yay -S howdy-next)."
  exit 1
fi
ok "Found Howdy PAM module: $HOWDY_SO"

HOWDY_LINE="auth       sufficient                  ${HOWDY_SO}"

# ---------------------------------------------------------------------------
# 2. Configure /etc/pam.d/sudo
# ---------------------------------------------------------------------------
log "Checking $SUDO_FILE..."
if [[ ! -f "$SUDO_FILE" ]]; then
  warn "$SUDO_FILE not found, skipping"
elif grep -q "pam_howdy.so" "$SUDO_FILE"; then
  ok "$SUDO_FILE already configured with Howdy, skipping"
else
  if [[ $DRY_RUN -eq 1 ]]; then
    log "[dry-run] Would prepend to $SUDO_FILE: $HOWDY_LINE"
  else
    backup_file "$SUDO_FILE"
    sed -i "1i ${HOWDY_LINE}" "$SUDO_FILE"
    ok "Configured $SUDO_FILE"
  fi
fi

# ---------------------------------------------------------------------------
# 3. Configure /etc/pam.d/system-auth
# ---------------------------------------------------------------------------
log "Checking $SYSAUTH_FILE..."
if [[ ! -f "$SYSAUTH_FILE" ]]; then
  warn "$SYSAUTH_FILE not found, skipping"
elif grep -q "pam_howdy.so" "$SYSAUTH_FILE"; then
  ok "$SYSAUTH_FILE already configured with Howdy, skipping"
elif ! grep -q "pam_faillock.so.*preauth" "$SYSAUTH_FILE"; then
  warn "Could not find 'pam_faillock.so preauth' in $SYSAUTH_FILE. Skipping automatic insertion."
else
  if [[ $DRY_RUN -eq 1 ]]; then
    log "[dry-run] Would insert into $SYSAUTH_FILE after pam_faillock preauth: $HOWDY_LINE"
  else
    backup_file "$SYSAUTH_FILE"
    sed -i "/pam_faillock.so[[:space:]]*preauth/a ${HOWDY_LINE}" "$SYSAUTH_FILE"
    ok "Configured $SYSAUTH_FILE"
  fi
fi

# ---------------------------------------------------------------------------
# 4. Omarchy Lock Screen Configuration
# ---------------------------------------------------------------------------
is_omarchy=0
if [[ -f "$OMARCHY_PAM_FILE" || -d "/usr/share/omarchy" ]]; then
  is_omarchy=1
fi

if [[ $is_omarchy -eq 1 ]]; then
  log "Omarchy desktop environment detected!"

  # 4a. /etc/pam.d/omarchy-lock-password
  log "Checking $OMARCHY_PAM_FILE..."
  if [[ ! -f "$OMARCHY_PAM_FILE" ]]; then
    warn "$OMARCHY_PAM_FILE not found"
  elif grep -q "pam_howdy.so" "$OMARCHY_PAM_FILE"; then
    ok "$OMARCHY_PAM_FILE already configured with Howdy, skipping"
  elif ! grep -q "pam_faillock.so.*preauth" "$OMARCHY_PAM_FILE"; then
    warn "Could not find 'pam_faillock.so preauth' in $OMARCHY_PAM_FILE. Prepending instead."
    if [[ $DRY_RUN -eq 1 ]]; then
      log "[dry-run] Would prepend to $OMARCHY_PAM_FILE: $HOWDY_LINE"
    else
      backup_file "$OMARCHY_PAM_FILE"
      sed -i "2i ${HOWDY_LINE}" "$OMARCHY_PAM_FILE"
      ok "Configured $OMARCHY_PAM_FILE"
    fi
  else
    if [[ $DRY_RUN -eq 1 ]]; then
      log "[dry-run] Would insert into $OMARCHY_PAM_FILE after pam_faillock preauth: $HOWDY_LINE"
    else
      backup_file "$OMARCHY_PAM_FILE"
      sed -i "/pam_faillock.so[[:space:]]*preauth/a ${HOWDY_LINE}" "$OMARCHY_PAM_FILE"
      ok "Configured $OMARCHY_PAM_FILE"
    fi
  fi

  # 4b. /usr/bin/omarchy-apply-lock (to survive future lock generator runs)
  if [[ -f "$OMARCHY_APPLY_LOCK" ]]; then
    log "Checking $OMARCHY_APPLY_LOCK template..."
    if grep -q "pam_howdy.so" "$OMARCHY_APPLY_LOCK"; then
      ok "$OMARCHY_APPLY_LOCK already contains Howdy, skipping"
    elif grep -q "pam_faillock.so.*preauth" "$OMARCHY_APPLY_LOCK"; then
      if [[ $DRY_RUN -eq 1 ]]; then
        log "[dry-run] Would insert Howdy into $OMARCHY_APPLY_LOCK template"
      else
        backup_file "$OMARCHY_APPLY_LOCK"
        sed -i "/pam_faillock.so[[:space:]]*preauth/a ${HOWDY_LINE}" "$OMARCHY_APPLY_LOCK"
        ok "Updated $OMARCHY_APPLY_LOCK template"
      fi
    fi
  fi

  # 4c. Patch LockView.qml to allow submitting empty password by pressing Enter
  if [[ -f "$LOCKVIEW_QML" ]]; then
    log "Checking $LOCKVIEW_QML..."
    if ! grep -q "submitted.length > 0" "$LOCKVIEW_QML"; then
      ok "$LOCKVIEW_QML already allows empty submission, skipping"
    else
      if [[ $DRY_RUN -eq 1 ]]; then
        log "[dry-run] Would patch $LOCKVIEW_QML to submit on empty Enter"
      else
        backup_file "$LOCKVIEW_QML"
        sed -i 's/if (submitted.length > 0) root.submitPassword(submitted)/root.submitPassword(submitted)/' "$LOCKVIEW_QML"
        ok "Patched $LOCKVIEW_QML (Enter submits on empty field)"
      fi
    fi
  fi

  # 4d. Patch Service.qml to permit empty password for PAM face recognition
  if [[ -f "$SERVICE_QML" ]]; then
    log "Checking $SERVICE_QML..."
    if ! grep -q "password.length === 0" "$SERVICE_QML"; then
      ok "$SERVICE_QML already allows zero-length password auth, skipping"
    else
      if [[ $DRY_RUN -eq 1 ]]; then
        log "[dry-run] Would patch $SERVICE_QML to allow zero-length password auth"
      else
        backup_file "$SERVICE_QML"
        sed -i 's/if (!lockRequested || authenticatingPassword || password.length === 0) return/if (!lockRequested || authenticatingPassword) return/' "$SERVICE_QML"
        ok "Patched $SERVICE_QML (permits face authentication with empty password)"
      fi
    fi
  fi

  # 4e. Reload Omarchy shell if running
  if [[ $DRY_RUN -eq 0 ]] && command -v omarchy-restart-shell >/dev/null 2>&1; then
    log "Restarting Omarchy shell to apply lock screen changes immediately..."
    target_user="${SUDO_USER:-$USER}"
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
      su - "$target_user" -c "omarchy-restart-shell" || true
    else
      omarchy-restart-shell || true
    fi
    ok "Omarchy shell refreshed."
  fi
fi

echo
if [[ $DRY_RUN -eq 1 ]]; then
  ok "Dry run complete. No files were modified."
  exit 0
fi

ok "Howdy PAM setup complete!"

cat <<'EOF'

──────────────────────────────────────────────────────────────────────────
HOW TO TEST:
──────────────────────────────────────────────────────────────────────────
1. Sudo Face Auth:
   Open a terminal and run:
     sudo -k && sudo whoami
   Confirm Howdy matches your face and outputs 'root'.

2. Lock Screen Face Auth:
   Lock your screen (e.g. Super + Ctrl + L).
   Simply press [Enter] without typing any password.
   The prompt will display 'Checking…', Howdy's IR camera will light up,
   scan your face, and unlock the desktop!

3. Password Fallback:
   If your face is not recognized or in dark environments, you can still
   type your password and press [Enter] normally.

──────────────────────────────────────────────────────────────────────────
To restore your original configuration at any time, run:
  sudo ./howdy-pam-setup.sh --undo
──────────────────────────────────────────────────────────────────────────
EOF
