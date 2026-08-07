#!/bin/bash
# =====================================================================
#  NSDL Workstation Compliance Audit - Linux installer
# =====================================================================
#  Run once per PC:   sudo bash install-audit.sh
#
#  Uses a systemd timer where available, falling back to cron.
#  Safe to re-run: replaces the schedule and keeps the same device id.
# =====================================================================

set -u

INSTALL_DIR="/var/lib/nsdl-audit"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SVC="/etc/systemd/system/nsdl-audit.service"
TMR="/etc/systemd/system/nsdl-audit.timer"
CRON="/etc/cron.d/nsdl-audit"

ok()   { printf "  [OK]   %s\n" "$1"; }
warn() { printf "  [WARN] %s\n" "$1"; }
fail() { printf "  [FAIL] %s\n" "$1"; }
step() { printf "  %s\n" "$1"; }

echo ""
echo "====================================================="
echo "  NSDL Workstation Compliance Audit - Setup (Linux)"
echo "====================================================="
echo ""

# ---------------------------------------------------------------- 1. root
if [ "$(id -u)" -ne 0 ]; then
    fail "This installer must run as root."
    echo ""
    echo "  Run it like this:"
    echo "      sudo bash install-audit.sh"
    echo ""
    exit 1
fi
ok "Running as root"

# ---------------------------------------------------------------- 2. prerequisites
MISSING=""
command -v curl    >/dev/null 2>&1 || MISSING="$MISSING curl"
command -v python3 >/dev/null 2>&1 || MISSING="$MISSING python3"
if [ -n "$MISSING" ]; then
    fail "Missing required tools:$MISSING"
    echo "  Install them first, for example:"
    echo "      sudo apt install$MISSING        (Debian / Ubuntu)"
    echo "      sudo dnf install$MISSING        (Fedora / RHEL)"
    exit 1
fi
ok "Required tools present (curl, python3)"

for t in lspci lsusb lpstat; do
    command -v "$t" >/dev/null 2>&1 || warn "$t not installed - some fields will be blank (optional)"
done

# ---------------------------------------------------------------- 3. config
CONFIG="$SCRIPT_DIR/config.txt"
[ -f "$CONFIG" ] || CONFIG="$(dirname "$SCRIPT_DIR")/config.txt"
if [ ! -f "$CONFIG" ]; then
    fail "config.txt not found next to the installer."; exit 1
fi

get_cfg() { grep -E "^$1=" "$CONFIG" | head -1 | cut -d'=' -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

SERVER_URL="$(get_cfg SERVER_URL | sed 's:/*$::')"
INTERVAL_HOURS="$(get_cfg INTERVAL_HOURS)"
JITTER_SECONDS="$(get_cfg JITTER_SECONDS)"

case "$INTERVAL_HOURS" in ''|*[!0-9]*) INTERVAL_HOURS=3 ;; esac
[ "$INTERVAL_HOURS" -lt 1 ] && INTERVAL_HOURS=3
case "$JITTER_SECONDS" in ''|*[!0-9]*) JITTER_SECONDS=300 ;; esac

if [ -z "$SERVER_URL" ]; then fail "SERVER_URL missing from config.txt"; exit 1; fi

# Testing override: run every N minutes instead of every N hours.
INTERVAL_MINUTES="$(get_cfg INTERVAL_MINUTES)"
case "$INTERVAL_MINUTES" in ''|*[!0-9]*) INTERVAL_MINUTES=0 ;; esac

if [ "$INTERVAL_MINUTES" -gt 0 ]; then
    TIMER_SPEC="${INTERVAL_MINUTES}min"
    CRON_SPEC="*/${INTERVAL_MINUTES} * * * *"
    SCHEDULE_DESC="every ${INTERVAL_MINUTES} minute(s)"
    warn "INTERVAL_MINUTES=$INTERVAL_MINUTES - testing mode, not for fleet use"
else
    TIMER_SPEC="${INTERVAL_HOURS}h"
    CRON_SPEC="0 */${INTERVAL_HOURS} * * *"
    SCHEDULE_DESC="every ${INTERVAL_HOURS} hour(s)"
fi
ok "Config loaded  (server $SERVER_URL, $SCHEDULE_DESC)"

# ---------------------------------------------------------------- 4. reachability
step "Testing connection to the audit server..."
if curl -s -f -m 10 -o /dev/null "$SERVER_URL/api/devices"; then
    ok "Server reachable"
else
    fail "Cannot reach $SERVER_URL"
    echo ""
    echo "  Check that the server is running, SERVER_URL uses the network ip"
    echo "  (not localhost), and this PC is on the same network."
    echo ""
    exit 1
fi

# ---------------------------------------------------------------- 5. install dir
mkdir -p "$INSTALL_DIR"
cp "$CONFIG" "$INSTALL_DIR/config.txt"
chmod 755 "$INSTALL_DIR"
ok "Install folder ready: $INSTALL_DIR"

# ---------------------------------------------------------------- 6. device id
DEVICE_ID_FILE="$INSTALL_DIR/device.id"
if [ -f "$DEVICE_ID_FILE" ]; then
    DEVICE_ID="$(tr -d '\n\r' < "$DEVICE_ID_FILE")"
    ok "Existing device id reused: $DEVICE_ID"
else
    SERIAL=""
    [ -r /sys/class/dmi/id/product_serial ] && SERIAL="$(cat /sys/class/dmi/id/product_serial 2>/dev/null)"
    [ -z "$SERIAL" ] && [ -r /etc/machine-id ] && SERIAL="$(cat /etc/machine-id)"
    [ -z "$SERIAL" ] && SERIAL="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    HASH="$(printf '%s|%s' "$(hostname)" "$SERIAL" | sha1sum | cut -c1-12)"
    DEVICE_ID="dev_${HASH}"
    printf '%s' "$DEVICE_ID" > "$DEVICE_ID_FILE"
    ok "Device id created: $DEVICE_ID"
fi

# ---------------------------------------------------------------- 7. runner
RUNNER="$INSTALL_DIR/run-audit.sh"
cat > "$RUNNER" <<'RUNNER_EOF'
#!/bin/bash
# Fetches and runs the current audit script, so a server-side fix reaches
# every PC on its next scheduled run.
DIR="/var/lib/nsdl-audit"
LOG="$DIR/audit.log"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG"; }

if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 1048576 ]; then
    tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

get_cfg() { grep -E "^$1=" "$DIR/config.txt" | head -1 | cut -d'=' -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

SERVER_URL="$(get_cfg SERVER_URL | sed 's:/*$::')"
DEVICE_ID="$(tr -d '\n\r' < "$DIR/device.id")"
JITTER="$(get_cfg JITTER_SECONDS)"
case "$JITTER" in ''|*[!0-9]*) JITTER=300 ;; esac

if [ "${NSDL_NO_JITTER:-0}" != "1" ] && [ "$JITTER" -gt 0 ]; then
    WAIT=$(( $(od -An -N2 -tu2 < /dev/urandom | tr -d ' ') % JITTER ))
    log "Waiting ${WAIT}s (jitter)"
    sleep "$WAIT"
fi

log "Audit starting (device $DEVICE_ID)"
if curl -s -f -m 120 "$SERVER_URL/download-mac-script?client_id=$DEVICE_ID" -o /tmp/nsdl_audit.sh; then
    if echo "" | /bin/bash /tmp/nsdl_audit.sh >> "$LOG" 2>&1; then
        log "Audit finished"
    else
        log "Audit script returned an error"
    fi
    rm -f /tmp/nsdl_audit.sh
else
    log "Audit FAILED: could not download the script from $SERVER_URL"
    exit 1
fi
RUNNER_EOF
chmod 755 "$RUNNER"
ok "Runner installed"

# ---------------------------------------------------------------- 8. schedule
step "Registering the schedule..."
SCHEDULED=""

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    cat > "$SVC" <<SVC_EOF
[Unit]
Description=NSDL Workstation Compliance Audit
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash ${RUNNER}
SVC_EOF

    cat > "$TMR" <<TMR_EOF
[Unit]
Description=Run the NSDL compliance audit ${SCHEDULE_DESC}

[Timer]
OnBootSec=5min
OnUnitActiveSec=${TIMER_SPEC}
Persistent=true

[Install]
WantedBy=timers.target
TMR_EOF

    systemctl daemon-reload >/dev/null 2>&1
    if systemctl enable --now nsdl-audit.timer >/dev/null 2>&1; then
        SCHEDULED="systemd"
        ok "Scheduled with systemd: $SCHEDULE_DESC, and 5 minutes after boot"
        step "Missed runs are caught up automatically (Persistent=true)"
    else
        warn "systemd timer could not be enabled, trying cron"
        rm -f "$SVC" "$TMR"
    fi
fi

if [ -z "$SCHEDULED" ]; then
    if command -v crontab >/dev/null 2>&1 || [ -d /etc/cron.d ]; then
        cat > "$CRON" <<CRON_EOF
# NSDL Workstation Compliance Audit
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${CRON_SPEC} root /bin/bash ${RUNNER}
@reboot root sleep 300 && /bin/bash ${RUNNER}
CRON_EOF
        chmod 644 "$CRON"
        SCHEDULED="cron"
        ok "Scheduled with cron: $SCHEDULE_DESC, and 5 minutes after boot"
    else
        fail "Neither systemd nor cron is available - cannot schedule"
        exit 1
    fi
fi

# ---------------------------------------------------------------- 9. first run
step "Running the first audit now (may take up to a minute)..."
if NSDL_NO_JITTER=1 /bin/bash "$RUNNER"; then
    ok "First audit completed"
else
    warn "First audit did not complete - the schedule is still active"
    warn "Check $INSTALL_DIR/audit.log"
fi

# ---------------------------------------------------------------- done
echo ""
echo "====================================================="
echo "  SETUP COMPLETE"
echo "====================================================="
echo ""
echo "  Computer   : $(hostname)"
echo "  Device id  : $DEVICE_ID"
echo "  Server     : $SERVER_URL"
echo "  Frequency  : $SCHEDULE_DESC + after boot"
echo "  Scheduler  : $SCHEDULED"
echo "  Log file   : $INSTALL_DIR/audit.log"
echo ""
echo "  This PC will now audit itself automatically."
echo ""
echo "  To remove later:  sudo bash uninstall-audit.sh"
echo ""
