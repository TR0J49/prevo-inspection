#!/bin/bash
# =====================================================================
#  NSDL Workstation Compliance Audit - macOS installer
# =====================================================================
#  Run once per Mac. Creates a LaunchDaemon that audits this machine
#  every N hours and at every startup.
#
#  Safe to re-run: replaces the daemon and keeps the same device id.
#  ASCII only - the file is executed on machines with unknown locales.
# =====================================================================

set -u

LABEL="com.nsdl.audit"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
INSTALL_DIR="/Library/Application Support/NSDLAudit"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

ok()   { printf "  [OK]   %s\n" "$1"; }
warn() { printf "  [WARN] %s\n" "$1"; }
fail() { printf "  [FAIL] %s\n" "$1"; }
step() { printf "  %s\n" "$1"; }

echo ""
echo "====================================================="
echo "  NSDL Workstation Compliance Audit - Setup (macOS)"
echo "====================================================="
echo ""

# ---------------------------------------------------------------- 1. root
if [ "$(id -u)" -ne 0 ]; then
    step "Administrator rights are required."
    step "You will be asked for your Mac password."
    echo ""
    exec sudo /bin/bash "$0" "$@"
fi
ok "Running with administrator rights"

# ---------------------------------------------------------------- 2. config
CONFIG="$SCRIPT_DIR/config.txt"
[ -f "$CONFIG" ] || CONFIG="$(dirname "$SCRIPT_DIR")/config.txt"
if [ ! -f "$CONFIG" ]; then
    fail "config.txt not found next to the installer."
    read -r -p "  Press Enter to exit "; exit 1
fi

get_cfg() { grep -E "^$1=" "$CONFIG" | head -1 | cut -d'=' -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

SERVER_URL="$(get_cfg SERVER_URL | sed 's:/*$::')"
INTERVAL_HOURS="$(get_cfg INTERVAL_HOURS)"
JITTER_SECONDS="$(get_cfg JITTER_SECONDS)"

case "$INTERVAL_HOURS" in ''|*[!0-9]*) INTERVAL_HOURS=3 ;; esac
[ "$INTERVAL_HOURS" -lt 1 ] && INTERVAL_HOURS=3
case "$JITTER_SECONDS" in ''|*[!0-9]*) JITTER_SECONDS=300 ;; esac

if [ -z "$SERVER_URL" ]; then
    fail "SERVER_URL missing from config.txt"; read -r -p "  Press Enter to exit "; exit 1
fi
INTERVAL_SECONDS=$((INTERVAL_HOURS * 3600))
ok "Config loaded  (server $SERVER_URL, every ${INTERVAL_HOURS}h)"

# ---------------------------------------------------------------- 3. reachability
step "Testing connection to the audit server..."
if curl -s -f -m 10 -o /dev/null "$SERVER_URL/api/devices"; then
    ok "Server reachable"
else
    fail "Cannot reach $SERVER_URL"
    echo ""
    echo "  Check that:"
    echo "    - the audit server is running"
    echo "    - SERVER_URL uses the server's NETWORK ip, not localhost"
    echo "    - this Mac is on the same network"
    echo ""
    read -r -p "  Press Enter to exit "; exit 1
fi

# ---------------------------------------------------------------- 4. install dir
mkdir -p "$INSTALL_DIR"
cp "$CONFIG" "$INSTALL_DIR/config.txt"
chmod 755 "$INSTALL_DIR"
ok "Install folder ready: $INSTALL_DIR"

# ---------------------------------------------------------------- 5. device id
DEVICE_ID_FILE="$INSTALL_DIR/device.id"
if [ -f "$DEVICE_ID_FILE" ]; then
    DEVICE_ID="$(tr -d '\n\r' < "$DEVICE_ID_FILE")"
    ok "Existing device id reused: $DEVICE_ID"
else
    SERIAL="$(ioreg -l 2>/dev/null | awk -F'"' '/IOPlatformSerialNumber/{print $4; exit}')"
    [ -z "$SERIAL" ] && SERIAL="$(uuidgen)"
    HASH="$(printf '%s|%s' "$(hostname)" "$SERIAL" | shasum | cut -c1-12)"
    DEVICE_ID="dev_${HASH}"
    printf '%s' "$DEVICE_ID" > "$DEVICE_ID_FILE"
    ok "Device id created: $DEVICE_ID"
fi

# ---------------------------------------------------------------- 6. runner
RUNNER="$INSTALL_DIR/run-audit.sh"
cat > "$RUNNER" <<'RUNNER_EOF'
#!/bin/bash
# Fetches and runs the current audit script. Kept small on purpose, so a
# fix on the server reaches every Mac on its next scheduled run.
DIR="/Library/Application Support/NSDLAudit"
LOG="$DIR/audit.log"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG"; }

# keep the log bounded
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 1048576 ]; then
    tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

get_cfg() { grep -E "^$1=" "$DIR/config.txt" | head -1 | cut -d'=' -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

SERVER_URL="$(get_cfg SERVER_URL | sed 's:/*$::')"
DEVICE_ID="$(tr -d '\n\r' < "$DIR/device.id")"
JITTER="$(get_cfg JITTER_SECONDS)"
case "$JITTER" in ''|*[!0-9]*) JITTER=300 ;; esac

if [ "${NSDL_NO_JITTER:-0}" != "1" ] && [ "$JITTER" -gt 0 ]; then
    WAIT=$((RANDOM % JITTER))
    log "Waiting ${WAIT}s (jitter)"
    sleep "$WAIT"
fi

log "Audit starting (device $DEVICE_ID)"
if curl -s -f -m 120 "$SERVER_URL/download-mac-script?client_id=$DEVICE_ID" -o /tmp/nsdl_audit.sh; then
    # the audit script ends with a "press enter" prompt; feed it EOF
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

# ---------------------------------------------------------------- 7. daemon
step "Registering the scheduled job..."
launchctl bootout system "$PLIST" >/dev/null 2>&1
launchctl unload "$PLIST"        >/dev/null 2>&1

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${RUNNER}</string>
    </array>
    <key>StartInterval</key>
    <integer>${INTERVAL_SECONDS}</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${INSTALL_DIR}/daemon.log</string>
    <key>StandardErrorPath</key>
    <string>${INSTALL_DIR}/daemon.log</string>
</dict>
</plist>
PLIST_EOF

chown root:wheel "$PLIST"
chmod 644 "$PLIST"

if launchctl bootstrap system "$PLIST" 2>/dev/null; then
    ok "Scheduled: every ${INTERVAL_HOURS} hours, and at every startup"
elif launchctl load -w "$PLIST" 2>/dev/null; then
    ok "Scheduled: every ${INTERVAL_HOURS} hours, and at every startup (legacy loader)"
else
    fail "Could not register the LaunchDaemon"
    read -r -p "  Press Enter to exit "; exit 1
fi

# ---------------------------------------------------------------- 8. first run
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
echo "  Frequency  : every ${INTERVAL_HOURS} hours + at startup"
echo "  Log file   : $INSTALL_DIR/audit.log"
echo ""
echo "  This Mac will now audit itself automatically."
echo "  Nothing further is needed on this machine."
echo ""
echo "  To remove later: run uninstall-audit.command"
echo ""
read -r -p "  Press Enter to close "
