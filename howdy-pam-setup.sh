#!/bin/bash
# ===========================================================================
# howdy-pam-setup.sh — Automated Howdy PAM setup for Arch Linux & Omarchy
#
# Works on:
#   - Arch Linux / CachyOS (sudo + system-auth + sddm)
#   - Omarchy (sudo + system-auth + SDDM greeter + Quickshell lockscreen)
#
# Features:
#   - Auto-detects pam_howdy.so location
#   - Configures sudo and system-auth
#   - Configures SDDM greeter (both /etc/pam.d/sddm and auto-face-scan on load)
#   - Configures Omarchy Quickshell lock screen ("press Enter to scan")
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
SDDM_PAM_FILE="$PAM_DIR/sddm"

# Omarchy specific paths
OMARCHY_PAM_FILE="$PAM_DIR/omarchy-lock-password"
OMARCHY_APPLY_LOCK="/usr/bin/omarchy-apply-lock"
LOCKVIEW_QML="/usr/share/omarchy/shell/plugins/lock/LockView.qml"
SERVICE_QML="/usr/share/omarchy/shell/plugins/lock/Service.qml"
SDDM_THEME_QML="/usr/share/sddm/themes/omarchy/Main.qml"
SDDM_DEFAULT_QML="/usr/share/omarchy/default/sddm/omarchy/Main.qml"

ALL_MANAGED_FILES=(
  "$SUDO_FILE"
  "$SYSAUTH_FILE"
  "$SDDM_PAM_FILE"
  "$OMARCHY_PAM_FILE"
  "$OMARCHY_APPLY_LOCK"
  "$LOCKVIEW_QML"
  "$SERVICE_QML"
  "$SDDM_THEME_QML"
  "$SDDM_DEFAULT_QML"
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
# 4. Configure /etc/pam.d/sddm (Display Manager Login Screen)
# ---------------------------------------------------------------------------
if [[ -f "$SDDM_PAM_FILE" ]]; then
  log "Checking $SDDM_PAM_FILE..."
  if grep -q "pam_howdy.so" "$SDDM_PAM_FILE"; then
    ok "$SDDM_PAM_FILE already configured with Howdy, skipping"
  else
    if [[ $DRY_RUN -eq 1 ]]; then
      log "[dry-run] Would prepend Howdy to $SDDM_PAM_FILE"
    else
      backup_file "$SDDM_PAM_FILE"
      sed -i "1a ${HOWDY_LINE}" "$SDDM_PAM_FILE"
      ok "Configured $SDDM_PAM_FILE"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 5. Omarchy Desktop Environment Configuration
# ---------------------------------------------------------------------------
is_omarchy=0
if [[ -f "$OMARCHY_PAM_FILE" || -d "/usr/share/omarchy" ]]; then
  is_omarchy=1
fi

if [[ $is_omarchy -eq 1 ]]; then
  log "Omarchy desktop environment detected!"

  # 5a. /etc/pam.d/omarchy-lock-password
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

  # 5b. /usr/bin/omarchy-apply-lock (to survive future lock generator runs)
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

  # 5c. Patch LockView.qml to allow submitting empty password by pressing Enter
  if [[ -f "$LOCKVIEW_QML" ]]; then
    log "Checking $LOCKVIEW_QML..."
    patched_lockview=0
    if grep -q "submitted.length > 0" "$LOCKVIEW_QML"; then
      if [[ $DRY_RUN -eq 1 ]]; then
        log "[dry-run] Would patch $LOCKVIEW_QML to submit on empty Enter"
      else
        backup_file "$LOCKVIEW_QML"
        sed -i 's/if (submitted.length > 0) root.submitPassword(submitted)/root.submitPassword(submitted)/' "$LOCKVIEW_QML"
        patched_lockview=1
      fi
    fi
    if ! grep -q "Qt.Key_Return" "$LOCKVIEW_QML"; then
      if [[ $DRY_RUN -eq 1 ]]; then
        log "[dry-run] Would patch $LOCKVIEW_QML Keys.onPressed to handle Return/Enter directly"
      else
        backup_file "$LOCKVIEW_QML"
        python3 -c '
with open("'"$LOCKVIEW_QML"'", "r") as f:
    c = f.read()
target = "Keys.onPressed: function(event) {\n          root.wakeRequested()"
replacement = "Keys.onPressed: function(event) {\n          root.wakeRequested()\n          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {\n            var submitted = root.passwordText\n            root.passwordTextEdited(\"\")\n            root.submitPassword(submitted)\n            event.accepted = true\n            return\n          }"
if target in c:
    with open("'"$LOCKVIEW_QML"'", "w") as f:
        f.write(c.replace(target, replacement, 1))
'
        patched_lockview=1
      fi
    fi
    if [[ $patched_lockview -eq 1 ]]; then
      ok "Patched $LOCKVIEW_QML (Enter key triggers face scan immediately)"
    else
      ok "$LOCKVIEW_QML already configured for empty Enter submission, skipping"
    fi
  fi

  # 5d. Patch Service.qml to permit empty password for PAM face recognition
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

  # 5e. Patch SDDM Omarchy Theme Main.qml for auto face scan on load
  for qml_path in "$SDDM_THEME_QML" "$SDDM_DEFAULT_QML"; do
    if [[ -f "$qml_path" ]]; then
      log "Checking $(basename "$(dirname "$qml_path")")/Main.qml..."
      if grep -q "autoFaceScanTimer" "$qml_path"; then
        ok "$qml_path already configured for auto face scan, skipping"
      else
        if [[ $DRY_RUN -eq 1 ]]; then
          log "[dry-run] Would patch $qml_path with auto face scan timer and status"
        else
          backup_file "$qml_path"
          # Insert property and timer after sessionIndex block
          sed -i '/property int sessionIndex:/i \  property bool authenticating: false\n\n  Timer {\n    id: autoFaceScanTimer\n    interval: 400\n    running: true\n    repeat: false\n    onTriggered: {\n      if (root.currentUser && root.currentUser.length > 0 && password.text.length === 0) {\n        root.authenticating = true\n        sddm.login(root.currentUser, "", root.sessionIndex)\n      }\n    }\n  }\n' "$qml_path"
          # Reset authenticating state in Connections
          sed -i '/function onLoginFailed() {/a \      root.authenticating = false' "$qml_path"
          sed -i '/function onLoginSucceeded() {/a \      root.authenticating = false' "$qml_path"
          # Set authenticating state on Enter press
          sed -i '/if (event.key === Qt.Key_Return/a \              root.authenticating = true' "$qml_path"
          # Add "Scanning face…" text indicator inside Item
          sed -i '/id: entry/a \\n        Text {\n          anchors.centerIn: parent\n          text: root.authenticating ? "Scanning face…" : ""\n          color: "#7aa2f7"\n          font.family: "JetBrainsMono Nerd Font"\n          font.pixelSize: 14\n          visible: password.text.length === 0 && root.authenticating\n        }' "$qml_path"
          ok "Patched $qml_path (SDDM auto-scan on greeter load)"
        fi
      fi
    fi
  done

  # 5f. Reload Omarchy shell if running
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
   Run: sudo -k && sudo whoami
   Confirm Howdy matches your face and outputs 'root'.

2. Lock Screen Face Auth:
   Lock your screen (Super + Ctrl + L).
   Simply press [Enter] without typing any password.
   Howdy will scan your face and unlock immediately!

3. Greeter / Login Screen Face Auth:
   When you boot up or log out to the SDDM greeter:
   Howdy will automatically turn on the camera and scan your face!
   If needed, you can also press [Enter] to re-trigger the scan, or
   type your password normally.

──────────────────────────────────────────────────────────────────────────
To restore your original configuration at any time, run:
  sudo ./howdy-pam-setup.sh --undo
──────────────────────────────────────────────────────────────────────────
EOF
