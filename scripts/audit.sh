#!/bin/bash
# ==============================================================================
#        NSDL WORKSTATION COMPLIANCE AUDIT SCRIPT (macOS / Linux)
# ==============================================================================
# Version: 3.1.0 — Full cross-platform support

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

# ── MAC Address ───────────────────────────────────────────────────────────────
MAC_ADDRESS="Unknown"
if command -v ifconfig >/dev/null 2>&1; then
    MAC_ADDRESS=$(ifconfig | grep -v '00:00:00:00:00:00' | grep -oE '([[:xdigit:]]{1,2}:){5}[[:xdigit:]]{1,2}' | head -n 1 | tr -d ':' | tr '[:lower:]' '[:upper:]')
elif command -v ip >/dev/null 2>&1; then
    MAC_ADDRESS=$(ip link | grep -v '00:00:00:00:00:00' | grep -oE '([[:xdigit:]]{1,2}:){5}[[:xdigit:]]{1,2}' | head -n 1 | tr -d ':' | tr '[:lower:]' '[:upper:]')
fi
[ -z "$MAC_ADDRESS" ] && MAC_ADDRESS="Unknown"

DRIVE_NAME="No CD Unit Found"

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
if [ "$OS_NAME" = "Darwin" ]; then
    # macOS: hostname -I is not available; use ipconfig per-interface
    IP_ADDRESS=$(ipconfig getifaddr en0 2>/dev/null)
    [ -z "$IP_ADDRESS" ] && IP_ADDRESS=$(ipconfig getifaddr en1 2>/dev/null)
elif command -v hostname >/dev/null 2>&1; then
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
if command -v python3 >/dev/null 2>&1; then
    if [ "$OS_NAME" = "macOS" ]; then
        NETWORK_ADAPTERS_JSON=$(python3 - <<'PYEOF'
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
    else
        NETWORK_ADAPTERS_JSON=$(python3 - <<'PYEOF'
import subprocess, json, re
adapters = []
try:
    r = subprocess.run(['ip', 'link', 'show'], capture_output=True, text=True, timeout=10)
    iface = ""
    for line in r.stdout.splitlines():
        m = re.match(r'^\d+: (\S+):', line)
        if m:
            iface = m.group(1).rstrip(':')
        if 'link/ether' in line and iface and iface not in ('lo',):
            mac = line.split()[1]
            adapters.append({"name": iface, "adapter_type": "Ethernet", "speed": "Unknown", "mac_address": mac})
            iface = ""
except:
    pass
print(json.dumps(adapters))
PYEOF
)
    fi
fi

# Disk Partitions
DISK_PARTITIONS_JSON="[]"
if command -v python3 >/dev/null 2>&1; then
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

# ── USB Peripherals ───────────────────────────────────────────────────────────
echo "Collecting peripheral devices..."
PERIPHERALS_JSON="[]"
if command -v python3 >/dev/null 2>&1; then
    if [ "$OS_NAME" = "macOS" ]; then
        PERIPHERALS_JSON=$(python3 - <<'PYEOF'
import subprocess, json
peripherals = []
try:
    r = subprocess.run(['system_profiler', 'SPUSBDataType', '-json'],
                       capture_output=True, text=True, timeout=20)
    data = json.loads(r.stdout)
    def extract(items):
        for item in items:
            name = item.get('_name', '')
            if name:
                peripherals.append({'name': name, 'type': 'USB', 'status': 'OK'})
            for sub in item.get('_items', []):
                extract([sub])
    extract(data.get('SPUSBDataType', []))
except Exception:
    pass
print(json.dumps(peripherals[:30]))
PYEOF
)
    else
        PERIPHERALS_JSON=$(python3 - <<'PYEOF'
import subprocess, json
peripherals = []
try:
    r = subprocess.run(['lsusb'], capture_output=True, text=True, timeout=10)
    for line in r.stdout.splitlines():
        parts = line.split(':', 2)
        name = parts[2].strip() if len(parts) > 2 else line.strip()
        if name and 'root hub' not in name.lower():
            peripherals.append({'name': name, 'type': 'USB', 'status': 'OK'})
except Exception:
    pass
print(json.dumps(peripherals))
PYEOF
)
    fi
fi

# ────────────────────────────────────────────────────────────────────────────
#  PHASE 2 — ANTIVIRUS DETECTION
# ────────────────────────────────────────────────────────────────────────────
echo "Detecting antivirus software..."
ANTIVIRUS='["Built-in OS Protections"]'
if command -v python3 >/dev/null 2>&1; then
    if [ "$OS_NAME" = "macOS" ]; then
        ANTIVIRUS=$(python3 - <<'PYEOF'
import subprocess, json, os
av_found = []
known_avs = ['Malwarebytes', 'Sophos', 'CrowdStrike', 'Carbon Black',
             'Symantec', 'McAfee', 'Avast', 'Bitdefender', 'Kaspersky',
             'ESET', 'Norton', 'Trend Micro', 'F-Secure', 'Webroot', 'Cylance']
try:
    apps = os.listdir('/Applications')
    for av in known_avs:
        if any(av.lower() in app.lower() for app in apps):
            av_found.append(av)
except Exception:
    pass
try:
    r = subprocess.run(['ps', 'aux'], capture_output=True, text=True, timeout=5)
    proc_lower = r.stdout.lower()
    proc_map = {'sophos': 'Sophos', 'malwarebytes': 'Malwarebytes',
                'falconctl': 'CrowdStrike Falcon', 'cbagentd': 'Carbon Black',
                'symantec': 'Symantec', 'mcafee': 'McAfee',
                'avast': 'Avast', 'bitdefender': 'Bitdefender',
                'kaspersky': 'Kaspersky', 'eset': 'ESET'}
    for proc, name in proc_map.items():
        if proc in proc_lower and name not in av_found:
            av_found.append(name)
except Exception:
    pass
if not av_found:
    av_found = ['Built-in XProtect & Gatekeeper']
print(json.dumps(av_found))
PYEOF
)
    else
        ANTIVIRUS=$(python3 - <<'PYEOF'
import subprocess, json, os
av_found = []
path_checks = [
    ('ClamAV',             ['/usr/bin/clamscan', '/usr/local/bin/clamscan', '/usr/sbin/clamd']),
    ('Sophos',             ['/opt/sophos-av/bin/savdstatus', '/usr/local/bin/sophosd']),
    ('ESET NOD32',         ['/opt/eset/esets/sbin/esets_daemon']),
    ('Comodo',             ['/opt/COMODO/cmdscan']),
    ('Bitdefender',        ['/opt/BitDefender-scanner/bin/bdscan']),
    ('CrowdStrike Falcon', ['/opt/CrowdStrike/falconctl']),
    ('Kaspersky',          ['/opt/kaspersky/kav4fs/bin/kav4fs-control']),
]
for name, paths in path_checks:
    for path in paths:
        if os.path.exists(path):
            av_found.append(name)
            break
try:
    r = subprocess.run(['ps', 'aux'], capture_output=True, text=True, timeout=5)
    proc_lower = r.stdout.lower()
    proc_map = {'clamd': 'ClamAV', 'sophosd': 'Sophos',
                'falcond': 'CrowdStrike Falcon', 'esets_daemon': 'ESET',
                'comodo': 'Comodo', 'bdscan': 'Bitdefender'}
    for proc, name in proc_map.items():
        if proc in proc_lower and name not in av_found:
            av_found.append(name)
except Exception:
    pass
if not av_found:
    av_found = ['No AV detected']
print(json.dumps(av_found))
PYEOF
)
    fi
fi

# ────────────────────────────────────────────────────────────────────────────
#  PHASE 3 — COMPRESSION UTILITIES
# ────────────────────────────────────────────────────────────────────────────
echo "Detecting compression utilities..."
COMPRESSION_UTILITIES='["No compression utility found"]'
if command -v python3 >/dev/null 2>&1; then
    COMPRESSION_UTILITIES=$(python3 - <<'PYEOF'
import subprocess, json
utils = []
seen = set()
tools = [
    ('7z',    '7-Zip'), ('7za', '7-Zip'), ('zip',   'zip'),
    ('unzip', 'unzip'), ('rar', 'RAR'),   ('unrar', 'RAR'),
    ('tar',   'tar'),   ('gzip','gzip'),  ('bzip2', 'bzip2'),
    ('xz',    'xz'),    ('pigz','pigz'),  ('zstd',  'zstd'),
]
for cmd, name in tools:
    try:
        r = subprocess.run(['which', cmd], capture_output=True, text=True, timeout=3)
        if r.returncode == 0 and name not in seen:
            utils.append(name)
            seen.add(name)
    except Exception:
        pass
if not utils:
    utils = ['No compression utility found']
print(json.dumps(utils))
PYEOF
)
fi

# ────────────────────────────────────────────────────────────────────────────
#  PHASE 4 — PRINTERS (CUPS)
# ────────────────────────────────────────────────────────────────────────────
echo "Detecting printers..."
PRINTERS="[]"
if command -v python3 >/dev/null 2>&1; then
    PRINTERS=$(python3 - <<'PYEOF'
import subprocess, json
printers = []
try:
    r = subprocess.run(['lpstat', '-p'], capture_output=True, text=True, timeout=10)
    for line in r.stdout.splitlines():
        line = line.strip()
        if line.lower().startswith('printer'):
            parts = line.split()
            if len(parts) >= 2:
                printers.append({
                    'name': parts[1],
                    'system_name': '',
                    'enable_bidi': 'False',
                    'extended_printer_status': '0',
                    'port_name': 'CUPS'
                })
except Exception:
    pass
if not printers:
    try:
        r = subprocess.run(['lpstat', '-a'], capture_output=True, text=True, timeout=10)
        for line in r.stdout.splitlines():
            parts = line.split()
            if parts and 'accepting' in line.lower():
                printers.append({
                    'name': parts[0],
                    'system_name': '',
                    'enable_bidi': 'False',
                    'extended_printer_status': '0',
                    'port_name': 'CUPS'
                })
    except Exception:
        pass
print(json.dumps(printers))
PYEOF
)
fi

# ────────────────────────────────────────────────────────────────────────────
#  PHASE 5 — FULL SOFTWARE INVENTORY
# ────────────────────────────────────────────────────────────────────────────
echo "Scanning installed software..."
SOFTWARE_INVENTORY_JSON="[]"

if command -v python3 >/dev/null 2>&1; then
    if [ "$OS_NAME" = "macOS" ]; then
        SOFTWARE_INVENTORY_JSON=$(python3 - <<'PYEOF'
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
except Exception:
    print("[]")
PYEOF
)
    else
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
            apps.append({'name': parts[0].strip(), 'version': parts[1].strip(),
                         'publisher': '', 'install_date': 'Unknown', 'size_mb': size_str})
    if apps:
        print(json.dumps(apps))
        exit()
except:
    pass
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
            apps.append({'name': parts[0].strip(), 'version': parts[1].strip(),
                         'publisher': '', 'install_date': 'Unknown', 'size_mb': size_str})
except:
    pass
print(json.dumps(apps))
PYEOF
)
    fi
fi
echo "Software scan complete."

# ────────────────────────────────────────────────────────────────────────────
#  PHASE 6 — HOTFIXES / UPDATE HISTORY
# ────────────────────────────────────────────────────────────────────────────
echo "Collecting update history..."
HOTFIXES_JSON="[]"
if command -v python3 >/dev/null 2>&1; then
    if [ "$OS_NAME" = "macOS" ]; then
        HOTFIXES_JSON=$(python3 - <<'PYEOF'
import subprocess, json
updates = []
try:
    r = subprocess.run(['system_profiler', 'SPInstallHistoryDataType', '-json'],
                       capture_output=True, text=True, timeout=30)
    data = json.loads(r.stdout)
    for item in data.get('SPInstallHistoryDataType', [])[:30]:
        name    = item.get('_name', '')
        version = item.get('spinstallhistory_version', '')
        date    = str(item.get('install_date', ''))
        if name:
            updates.append({
                'caption': '', 'cs_name': '',
                'description': f'{name} {version}'.strip(),
                'fix_id': name,
                'installed_on': date[:10] if date else ''
            })
except Exception:
    pass
print(json.dumps(updates))
PYEOF
)
    else
        HOTFIXES_JSON=$(python3 - <<'PYEOF'
import subprocess, json, os, sys
updates = []
# Debian/Ubuntu: dpkg log
try:
    if os.path.exists('/var/log/dpkg.log'):
        r = subprocess.run(['grep', 'upgrade', '/var/log/dpkg.log'],
                           capture_output=True, text=True, timeout=10)
        lines = [l for l in r.stdout.strip().split('\n') if l.strip()][-30:]
        for line in lines:
            parts = line.split()
            if len(parts) >= 4:
                updates.append({'caption': '', 'cs_name': '',
                                'description': 'Package upgrade',
                                'fix_id': parts[3].split(':')[0],
                                'installed_on': parts[0]})
        if updates:
            print(json.dumps(updates)); sys.exit()
except Exception:
    pass
# RHEL/CentOS: rpm
try:
    r = subprocess.run(['rpm', '-qa', '--last',
                        '--queryformat', '%{NAME}|%{INSTALLTIME:date}\n'],
                       capture_output=True, text=True, timeout=10)
    for line in r.stdout.strip().split('\n')[:30]:
        parts = line.split('|')
        if len(parts) >= 1 and parts[0].strip():
            updates.append({'caption': '', 'cs_name': '',
                            'description': 'RPM package', 'fix_id': parts[0].strip(),
                            'installed_on': parts[1][:10] if len(parts) > 1 else ''})
    if updates:
        print(json.dumps(updates)); sys.exit()
except Exception:
    pass
print(json.dumps(updates))
PYEOF
)
    fi
fi

# ────────────────────────────────────────────────────────────────────────────
#  PHASE 7 — LOGIN HISTORY
# ────────────────────────────────────────────────────────────────────────────
echo "Collecting login history..."
LOGIN_HISTORY_JSON="[]"
if command -v python3 >/dev/null 2>&1; then
    LOGIN_HISTORY_JSON=$(python3 - <<'PYEOF'
import subprocess, json, re
logins = []
try:
    r = subprocess.run(['last', '-n', '20'], capture_output=True, text=True, timeout=10)
    for line in r.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        if any(line.startswith(x) for x in ['wtmp', 'reboot', 'shutdown', 'boot']):
            continue
        parts = line.split()
        if len(parts) < 4:
            continue
        username = parts[0]
        terminal = parts[1]
        if username in ('reboot', 'shutdown', 'wtmp', ''):
            continue
        time_str = ' '.join(parts[3:7]) if len(parts) >= 7 else ' '.join(parts[3:])
        time_str = re.sub(r'\s*[-].*$', '', time_str).strip()
        logon_type = 'Remote (SSH)' if terminal.startswith('pts') else 'Local Interactive'
        logins.append({
            'username': username,
            'domain': 'local',
            'logon_type': logon_type,
            'time': time_str
        })
        if len(logins) >= 20:
            break
except Exception:
    pass
print(json.dumps(logins))
PYEOF
)
fi

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
    "hotfixes": $HOTFIXES_JSON,
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
    "software_inventory": $SOFTWARE_INVENTORY_JSON,
    "login_history": $LOGIN_HISTORY_JSON
}
EOF
)

CLIENT_ID="CLIENT_ID_PLACEHOLDER"
API_URL="http://127.0.0.1:8000/upload-audit?client_id=$CLIENT_ID"

echo "Uploading secure payload to backend..."

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API_URL" \
     -H "Content-Type: application/json" \
     -d "$JSON")

HTTP_STATUS=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_STATUS" -eq 200 ]; then
    echo "Audit upload completed successfully!"
else
    echo "Upload failed. HTTP Status: $HTTP_STATUS"
    echo "Details: $BODY"
fi

echo "Press enter to exit..."
read -r
