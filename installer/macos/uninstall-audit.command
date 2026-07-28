#!/bin/bash
# =====================================================================
#  NSDL Workstation Compliance Audit - macOS uninstaller
# =====================================================================
set -u

LABEL="com.nsdl.audit"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
INSTALL_DIR="/Library/Application Support/NSDLAudit"

if [ "$(id -u)" -ne 0 ]; then
    echo "  Administrator rights are required. You will be asked for your password."
    exec sudo /bin/bash "$0" "$@"
fi

echo ""
echo "  Removing NSDL Compliance Audit..."

launchctl bootout system "$PLIST" >/dev/null 2>&1
launchctl unload "$PLIST"        >/dev/null 2>&1
[ -f "$PLIST" ] && rm -f "$PLIST" && echo "  [OK]   Removed $PLIST"

if [ -d "$INSTALL_DIR" ]; then
    [ -f "$INSTALL_DIR/device.id" ] && echo "  Device id was: $(cat "$INSTALL_DIR/device.id")"
    rm -rf "$INSTALL_DIR"
    echo "  [OK]   Removed $INSTALL_DIR"
fi

echo ""
echo "  Uninstall complete. This Mac will no longer audit itself."
echo "  Audits already sent to the server are not affected."
echo ""
read -r -p "  Press Enter to close "
