#!/bin/bash
# =====================================================================
#  NSDL Workstation Compliance Audit - Linux uninstaller
#  Run:  sudo bash uninstall-audit.sh
# =====================================================================
set -u

INSTALL_DIR="/var/lib/nsdl-audit"
SVC="/etc/systemd/system/nsdl-audit.service"
TMR="/etc/systemd/system/nsdl-audit.timer"
CRON="/etc/cron.d/nsdl-audit"

if [ "$(id -u)" -ne 0 ]; then
    echo "  [FAIL] Must run as root:  sudo bash uninstall-audit.sh"
    exit 1
fi

echo ""
echo "  Removing NSDL Compliance Audit..."

if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now nsdl-audit.timer >/dev/null 2>&1
    systemctl stop nsdl-audit.service        >/dev/null 2>&1
fi
for f in "$TMR" "$SVC" "$CRON"; do
    [ -f "$f" ] && rm -f "$f" && echo "  [OK]   Removed $f"
done
command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1

if [ -d "$INSTALL_DIR" ]; then
    [ -f "$INSTALL_DIR/device.id" ] && echo "  Device id was: $(cat "$INSTALL_DIR/device.id")"
    rm -rf "$INSTALL_DIR"
    echo "  [OK]   Removed $INSTALL_DIR"
fi

echo ""
echo "  Uninstall complete. This PC will no longer audit itself."
echo "  Audits already sent to the server are not affected."
echo ""
