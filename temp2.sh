#!/bin/bash
# ==============================================================================
#        NSDL WORKSTATION COMPLIANCE AUDIT SCRIPT (macOS / Linux)
# ==============================================================================
# Version: 3.0.0 — Full IT Asset Management Edition

echo "Collecting Workstation Compliance Data..."

EXECUTION_DATETIME=$(date +"%d-%b-%Y_%H:%M:%S")
CONSENT_TEXT="We provide approval to NSDL e-Governance Infrastructure Ltd.(NSDL e-Gov) to capture the details regarding the System details and share the details with NSDL e-Gov."
COMPUTER_NAME=$(hostname)

# ── OS Detection ──────────────────────────────────────────────────────────────
OS_NAME=$(uname -s)
ARCHITECTURE=$(uname -m)
OS_VERSION=$(uname -r)

if [ "$OS_NAME" = "Darwin" ]; then
    OS_NAME="macOS"
    if command -v sw_vers >/dev/null 2>&1; then
        OS_VERSION=$(sw_vers -productVersion)
    fi
elif [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME="${NAME:-$OS_NAME}"
    OS_VERSION="${VERSION_ID:-$OS_VERSION}"
fi

LICENSE_STATUS="Not Applicable"

# Check if python3 is usable without triggering xcode-select installer
# On macOS without Xcode CLT, invoking python3 pops up an install dialog
PYTHON3_OK=false
if command -v python3 >/dev/null 2>&1; then
    # Test silently — xcode-select errors go to stderr, suppress them
    if python3 -c "import sys; sys.exit(0)" >/dev/null 2>&1; then
        PYTHON3_OK=true
    fi
fi

# ── MAC Address ───────────────────────────────────────────────────────────────
MAC_ADDRESS="Unknown"
if command -v ifconfig >/dev/null 2>&1; then
    MAC_ADDRESS=$(ifconfig | grep -v '00:00:00:00:00:00' | grep -oE '([[:xdigit:]]{1,2}:){5}[[:xdigit:]]{1,2}' | head -n 1 | tr -d ':' | tr '[:lower:]' '[:upper:]')
elif command -v ip >/dev/null 2>&1; then
    MAC_ADDRESS=$(ip link | grep -v '00:00:00:00:00:00' | grep -oE '([[:xdigit:]]{1,2}:){5}[[:xdigit:]]{1,2}' | head -n 1 | tr -d ':' | tr '[:lower:]' '[:upper:]')
fi
[ -z "$MAC_ADDRESS" ] && MAC_ADDRESS="Unknown"

DRIVE_NAME="No CD Unit Found"
COMPRESSION_UTILITIES='["tar", "gzip", "zip (built-in)"]'
ANTIVIRUS='["Built-in OS Protections"]'
PRINTERS="[]"

# ── Basic Hardware: CPU, RAM, Disk ────────────────────────────────────────────
CPU="Unknown"
RAM="Unknown"
DISK="Unknown"

if [ "$OS_NAME" = "macOS" ]; then
    if command -v sysctl >/dev/null 2>&1; then
        CPU=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
        RAM_BYTES=$(sysctl -n hw.memsize 2>/dev/null)
        if [ -n "$RAM_BYTES" ]; then
            RAM_GB=$(awk "BEGIN {printf \"%.2f\", $RAM_BYTES / 1073741824}")
            RAM="${RAM_GB} GB"
        fi
    fi
    DISK=$(df -h / | tail -1 | awk '{print $1 " " $4 " free of " $2}')
else
    if command -v lscpu >/dev/null 2>&1; then
        CPU=$(lscpu | grep 'Model name' | cut -f 2 -d ":" | awk '{$1=$1}1')
    fi
    if command -v free >/dev/null 2>&1; then
        RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
        if [ -n "$RAM_MB" ]; then
            RAM_GB=$(awk "BEGIN {printf \"%.2f\", $RAM_MB / 1024}")
            RAM="${RAM_GB} GB"
        fi
    fi
    DISK=$(df -h / | tail -1 | awk '{print $1 " " $4 " free of " $2}')
fi

# ── Network Details ───────────────────────────────────────────────────────────
IP_ADDRESS="Unknown"
if command -v hostname >/dev/null 2>&1; then
    IP_ADDRESS=$(hostname -I 2>/dev/null | awk '{print $1}')
fi
if [ -z "$IP_ADDRESS" ] && command -v ifconfig >/dev/null 2>&1; then
    IP_ADDRESS=$(ifconfig 2>/dev/null | awk '/inet / && !/127.0.0.1/{print $2}' | head -n 1)
fi
[ -z "$IP_ADDRESS" ] && IP_ADDRESS="Unknown"

NETWORK_DETAILS="[{\"ip_address\": \"$IP_ADDRESS\", \"gateway\": \"Unknown\", \"mac\": \"$MAC_ADDRESS\"}]"
USER_ACCOUNTS="[{\"name\": \"$USER\", \"disabled\": \"False\"}]"

# ────────────────────────────────────────────────────────────────────────────
#  PHASE 1 — EXTENDED HARDWARE COLLECTION
# ────────────────────────────────────────────────────────────────────────────
echo "Collecting extended hardware info..."

# GPU Details
GPU_JSON="[]"
if [ "$OS_NAME" = "macOS" ]; then
    GPU_NAME=$(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/Chipset Model/{print $2}' | head -1 | sed 's/^ *//')
    GPU_VRAM=$(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/VRAM \(Total\)/{print $2}' | head -1 | sed 's/^ *//')
    if [ -n "$GPU_NAME" ]; then
        GPU_JSON="[{\"name\":\"$GPU_NAME\",\"driver_version\":\"Unknown\",\"vram\":\"${GPU_VRAM:-Unknown}\"}]"
    fi
elif command -v lspci >/dev/null 2>&1; then
    GPU_NAME=$(lspci 2>/dev/null | grep -i 'VGA\|3D\|Display' | head -1 | sed 's/.*: //' | sed 's/"/\\"/g')
    if [ -n "$GPU_NAME" ]; then
        GPU_JSON="[{\"name\":\"$GPU_NAME\",\"driver_version\":\"Unknown\",\"vram\":\"Unknown\"}]"
    fi
fi

# Serial Number, Manufacturer, Model
SERIAL_NUMBER="Unknown"
MANUFACTURER="Unknown"
MODEL_NAME="Unknown"
if [ "$OS_NAME" = "macOS" ]; then
    SERIAL_NUMBER=$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Serial Number \(system\)/{print $2}' | head -1 | sed 's/^ *//')
    MANUFACTURER="Apple Inc."
    MODEL_NAME=$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Model Name/{print $2}' | head -1 | sed 's/^ *//')
    [ -z "$SERIAL_NUMBER" ] && SERIAL_NUMBER="Unknown"
    [ -z "$MODEL_NAME" ]    && MODEL_NAME="Unknown"
else
    if command -v dmidecode >/dev/null 2>&1; then
        SERIAL_NUMBER=$(dmidecode -s system-serial-number 2>/dev/null | head -1 || echo "Unknown")
        MANUFACTURER=$(dmidecode -s system-manufacturer 2>/dev/null | head -1 || echo "Unknown")
        MODEL_NAME=$(dmidecode -s system-product-name 2>/dev/null | head -1 || echo "Unknown")
    fi
fi
SERIAL_NUMBER=$(echo "$SERIAL_NUMBER" | sed 's/"/\\"/g')
MANUFACTURER=$(echo "$MANUFACTURER"  | sed 's/"/\\"/g')
MODEL_NAME=$(echo "$MODEL_NAME"      | sed 's/"/\\"/g')

# Physical Network Adapters
NETWORK_ADAPTERS_JSON="[]"
if [ "$OS_NAME" = "macOS" ] && [ "$PYTHON3_OK" = "true" ]; then
    NETWORK_ADAPTERS_JSON=$(python3 - 2>/dev/null <<'PYEOF'
import subprocess, json, re
try:
    r = subprocess.run(['networksetup', '-listallhardwareports'], capture_output=True, text=True, timeout=10)
    adapters = []
    port = ""
    for line in r.stdout.splitlines():
        if 'Hardware Port:' in line:
            port = line.split(':', 1)[1].strip()
        elif 'Ethernet Address:' in line:
            mac = line.split(':', 1)[1].strip()
            if port:
                adapters.append({"name": port, "adapter_type": "Ethernet", "speed": "Unknown", "mac_address": mac})
                port = ""
    print(json.dumps(adapters))
except:
    print("[]")
PYEOF
)
fi

# Disk Partitions
DISK_PARTITIONS_JSON="[]"
if [ "$PYTHON3_OK" = "true" ]; then
    if [ "$OS_NAME" = "macOS" ]; then
        DISK_PARTITIONS_JSON=$(python3 - <<'PYEOF'
import subprocess, json
try:
    r = subprocess.run(['diskutil', 'list'], capture_output=True, text=True, timeout=10)
    partitions = []
    for line in r.stdout.splitlines():
        parts = line.split()
        if parts and parts[0].isdigit():
            name = parts[-1] if len(parts) > 1 else "Unknown"
            ptype = parts[1] if len(parts) > 1 else "Unknown"
            size  = " ".join(parts[3:5]) if len(parts) >= 5 else "Unknown"
            partitions.append({"name": name, "type": ptype, "size_gb": size, "bootable": "Unknown"})
    print(json.dumps(partitions))
except:
    print("[]")
PYEOF
)
    elif command -v lsblk >/dev/null 2>&1; then
        DISK_PARTITIONS_JSON=$(lsblk -J -o NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null | python3 - <<'PYEOF'
import sys, json
try:
    data = json.load(sys.stdin)
    partitions = []
    def flatten(devices):
        for d in devices:
            partitions.append({"name": d.get("name",""), "type": d.get("type",""), "size_gb": d.get("size",""), "bootable": "Unknown"})
            if d.get("children"):
                flatten(d["children"])
    flatten(data.get("blockdevices", []))
    print(json.dumps(partitions))
except:
    print("[]")
PYEOF
)
    fi
fi

# Peripherals — not practical to collect in bash, leave empty for Unix
PERIPHERALS_JSON="[]"

# ────────────────────────────────────────────────────────────────────────────
#  PHASE 2 — FULL SOFTWARE INVENTORY
# ────────────────────────────────────────────────────────────────────────────
echo "Scanning installed software..."
SOFTWARE_INVENTORY_JSON="[]"

if command -v python3 >/dev/null 2>&1 && [ "$PYTHON3_OK" = "true" ]; then
    if [ "$OS_NAME" = "macOS" ]; then
        SOFTWARE_INVENTORY_JSON=$(python3 - 2>/dev/null <<'PYEOF'
import subprocess, json
try:
    r = subprocess.run(
        ['system_profiler', 'SPApplicationsDataType', '-json'],
        capture_output=True, text=True, timeout=60
    )
    data = json.loads(r.stdout)
    apps_raw = data.get('SPApplicationsDataType', [])[:150]
    apps = []
    for a in apps_raw:
        name = a.get('_name', '')
        if name:
            apps.append({
                'name': name,
                'version': a.get('version', 'Unknown'),
                'publisher': '',
                'install_date': a.get('lastModified', 'Unknown'),
                'size_mb': 'Unknown'
            })
    print(json.dumps(apps))
except Exception as e:
    print("[]")
PYEOF
)
    else
        # Try dpkg (Debian/Ubuntu)
        SOFTWARE_INVENTORY_JSON=$(python3 - <<'PYEOF'
import subprocess, json
apps = []
try:
    r = subprocess.run(
        ['dpkg-query', '-W', '--showformat=${Package}|${Version}|${Installed-Size}\n'],
        capture_output=True, text=True, timeout=15
    )
    for line in r.stdout.strip().split('\n')[:150]:
        parts = line.split('|')
        if len(parts) >= 2 and parts[0].strip():
            size_kb = int(parts[2].strip()) if len(parts) > 2 and parts[2].strip().isdigit() else 0
            size_str = f"{round(size_kb/1024,2)} MB" if size_kb > 0 else "Unknown"
            apps.append({'name': parts[0].strip(), 'version': parts[1].strip(), 'publisher': '', 'install_date': 'Unknown', 'size_mb': size_str})
    if apps:
        print(json.dumps(apps))
        exit()
except:
    pass
# Try rpm (RHEL/CentOS/Fedora)
try:
    r = subprocess.run(
        ['rpm', '-qa', '--queryformat', '%{NAME}|%{VERSION}|%{SIZE}\n'],
        capture_output=True, text=True, timeout=15
    )
    for line in r.stdout.strip().split('\n')[:150]:
        parts = line.split('|')
        if len(parts) >= 2 and parts[0].strip():
            size_b = int(parts[2].strip()) if len(parts) > 2 and parts[2].strip().isdigit() else 0
            size_str = f"{round(size_b/1048576,2)} MB" if size_b > 0 else "Unknown"
            apps.append({'name': parts[0].strip(), 'version': parts[1].strip(), 'publisher': '', 'install_date': 'Unknown', 'size_mb': size_str})
except:
    pass
print(json.dumps(apps))
PYEOF
)
    fi
fi
echo "Software scan complete."

# ────────────────────────────────────────────────────────────────────────────
#  Build Final JSON Payload
# ────────────────────────────────────────────────────────────────────────────
JSON=$(cat <<EOF
{
    "execution_datetime": "$EXECUTION_DATETIME",
    "consent": "$CONSENT_TEXT",
    "computer_name": "$COMPUTER_NAME",
    "os_name": "$OS_NAME",
    "os_version": "$OS_VERSION",
    "architecture": "$ARCHITECTURE",
    "license_status": "$LICENSE_STATUS",
    "hotfixes": [],
    "mac_address": "$MAC_ADDRESS",
    "drive_name": "$DRIVE_NAME",
    "compression_utilities": $COMPRESSION_UTILITIES,
    "antivirus": $ANTIVIRUS,
    "printers": $PRINTERS,
    "hardware_details": {
        "cpu": "$CPU",
        "ram": "$RAM",
        "disk": "$DISK",
        "gpu_details": $GPU_JSON,
        "serial_number": "$SERIAL_NUMBER",
        "manufacturer": "$MANUFACTURER",
        "model": "$MODEL_NAME",
        "network_adapters": $NETWORK_ADAPTERS_JSON,
        "peripherals": $PERIPHERALS_JSON,
        "disk_partitions": $DISK_PARTITIONS_JSON
    },
    "network_details": $NETWORK_DETAILS,
    "user_accounts": $USER_ACCOUNTS,
    "software_inventory": $SOFTWARE_INVENTORY_JSON
}
EOF
)

CLIENT_ID="123"
API_URL="http://127.0.0.1:8000/upload-audit?client_id=$CLIENT_ID"

echo "Uploading secure payload to backend..."

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API_URL" \
     -H "Content-Type: application/json" \
     -d "$JSON")

HTTP_STATUS=$(echo "$RESPONSE" | tail -n1)
# Use sed to strip last line — works on both macOS (BSD) and Linux (GNU)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_STATUS" -eq 200 ]; then
    echo "Audit upload completed successfully!"
else
    echo "Upload failed. HTTP Status: $HTTP_STATUS"
    echo "Details: $BODY"
fi

echo "Press enter to exit..."
read -r
