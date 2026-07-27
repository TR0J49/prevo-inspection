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

# User Accounts (all Excel fields)
USER_ACCOUNTS="[]"
if command -v python3 >/dev/null 2>&1; then
    CURRENT_USER="$USER"
    USER_ACCOUNTS=$(python3 - "$CURRENT_USER" <<'PYEOF'
import subprocess, json, sys, os, pwd, grp
current_user = sys.argv[1] if len(sys.argv) > 1 else os.environ.get('USER', '')
users = []
try:
    # Get all non-system users (uid >= 500 or 1000)
    min_uid = 500
    all_users = [u for u in pwd.getpwall() if u.pw_uid >= min_uid and u.pw_shell not in ('/bin/false','/usr/sbin/nologin','/sbin/nologin')]
    # Get admin group members
    admin_groups = {'sudo', 'wheel', 'admin'}
    admin_members = set()
    for g in grp.getgrall():
        if g.gr_name in admin_groups:
            admin_members.update(g.gr_mem)
    for u in all_users:
        user_type = "Administrator" if u.pw_name in admin_members else "Standard"
        last_login = "Unknown"
        try:
            lr = subprocess.run(['last', '-n', '1', u.pw_name], capture_output=True, text=True, timeout=5)
            for line in lr.stdout.splitlines():
                if line.startswith(u.pw_name):
                    parts = line.split()
                    if len(parts) >= 4:
                        last_login = ' '.join(parts[3:7])
                    break
        except: pass
        home = u.pw_dir or "Unknown"
        if not os.path.exists(home): home = "Unknown"
        users.append({
            "name": u.pw_name,
            "disabled": "False",
            "home_directory": home,
            "last_login": last_login,
            "num_logins": "0",
            "user_type": user_type,
            "is_current": "True" if u.pw_name == current_user else "False"
        })
except Exception as e:
    users = [{"name": current_user, "disabled": "False", "home_directory": "Unknown",
              "last_login": "Unknown", "num_logins": "0", "user_type": "Unknown", "is_current": "True"}]
print(json.dumps(users))
PYEOF
)
fi

# ────────────────────────────────────────────────────────────────────────────
#  PHASE 1 — EXTENDED HARDWARE COLLECTION
# ────────────────────────────────────────────────────────────────────────────
echo "Collecting extended hardware info..."

# GPU Details
GPU_JSON="[]"
if [ "$OS_NAME" = "macOS" ]; then
    GPU_NAME=$(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/Chipset Model/{print $2}' | head -1 | sed 's/^ *//')
    GPU_VRAM=$(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/VRAM \(Total\)/{print $2}' | head -1 | sed 's/^ *//')
    GPU_DRIVER=$(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/Driver Version/{print $2}' | head -1 | sed 's/^ *//')
    if [ -n "$GPU_NAME" ]; then
        GPU_JSON="[{\"name\":\"${GPU_NAME}\",\"device_name\":\"${GPU_NAME}\",\"video_processor\":\"Unknown\",\"driver_version\":\"${GPU_DRIVER:-Unknown}\",\"vram\":\"${GPU_VRAM:-Unknown}\"}]"
    fi
elif command -v lspci >/dev/null 2>&1; then
    GPU_NAME=$(lspci 2>/dev/null | grep -i 'VGA\|3D\|Display' | head -1 | sed 's/.*: //' | sed 's/"/\\"/g')
    if [ -n "$GPU_NAME" ]; then
        GPU_JSON="[{\"name\":\"${GPU_NAME}\",\"device_name\":\"${GPU_NAME}\",\"video_processor\":\"Unknown\",\"driver_version\":\"Unknown\",\"vram\":\"Unknown\"}]"
    fi
fi

# Serial Number, Manufacturer, Model + BIOS + Domain + Asset Tag + Memory + Boot Time
SERIAL_NUMBER="Unknown"
MANUFACTURER="Unknown"
MODEL_NAME="Unknown"
BIOS_VERSION="Unknown"
BIOS_DATE="Unknown"
ASSET_TAG="Unknown"
DOMAIN_NAME="Unknown"
DOMAIN_ROLE="Unknown"
DEVICE_DESC="Unknown"
NUM_PROCESSORS="Unknown"
PROCESSOR_TYPE="Unknown"
MEMORY_SLOTS="Unknown"
LAST_BOOT_TIME="Unknown"
LAST_BACKUP_TIME="Unknown"

if [ "$OS_NAME" = "macOS" ]; then
    SERIAL_NUMBER=$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Serial Number \(system\)/{print $2}' | head -1 | sed 's/^ *//')
    MANUFACTURER="Apple Inc."
    MODEL_NAME=$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Model Name/{print $2}' | head -1 | sed 's/^ *//')
    NUM_PROCESSORS=$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Number of Processors/{print $2}' | head -1 | sed 's/^ *//')
    PROCESSOR_TYPE=$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Processor Name/{print $2}' | head -1 | sed 's/^ *//')
    MEMORY_SLOTS=$(system_profiler SPMemoryDataType 2>/dev/null | awk -F': ' '/Size/{print $2}' | paste -sd',' - 2>/dev/null | head -c 200)
    LAST_BOOT_TIME=$(sysctl -n kern.boottime 2>/dev/null | sed 's/.*sec = //' | sed 's/,.*//' | xargs -I{} python3 -c "import datetime; print(datetime.datetime.fromtimestamp({}).strftime('%Y-%m-%d %H:%M:%S'))" 2>/dev/null)
    DOMAIN_NAME=$(dsconfigad -show 2>/dev/null | awk -F'=' '/Active Directory Domain/{print $2}' | sed 's/^ *//' || echo "Unknown")
    BIOS_VERSION=$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Boot ROM Version/{print $2}' | head -1 | sed 's/^ *//')
    [ -z "$SERIAL_NUMBER" ]  && SERIAL_NUMBER="Unknown"
    [ -z "$MODEL_NAME" ]     && MODEL_NAME="Unknown"
    [ -z "$BIOS_VERSION" ]   && BIOS_VERSION="Unknown"
    [ -z "$DOMAIN_NAME" ]    && DOMAIN_NAME="Unknown"
    [ -z "$LAST_BOOT_TIME" ] && LAST_BOOT_TIME="Unknown"
else
    if command -v dmidecode >/dev/null 2>&1; then
        SERIAL_NUMBER=$(dmidecode -s system-serial-number 2>/dev/null | grep -v '^#' | head -1 || echo "Unknown")
        MANUFACTURER=$(dmidecode -s system-manufacturer 2>/dev/null | grep -v '^#' | head -1 || echo "Unknown")
        MODEL_NAME=$(dmidecode -s system-product-name 2>/dev/null | grep -v '^#' | head -1 || echo "Unknown")
        BIOS_VERSION=$(dmidecode -s bios-version 2>/dev/null | grep -v '^#' | head -1 || echo "Unknown")
        BIOS_DATE=$(dmidecode -s bios-release-date 2>/dev/null | grep -v '^#' | head -1 || echo "Unknown")
        ASSET_TAG=$(dmidecode -s chassis-asset-tag 2>/dev/null | grep -v '^#\|To Be Filled\|Default\|None' | head -1 || echo "Unknown")
        PROCESSOR_TYPE=$(dmidecode -s processor-version 2>/dev/null | grep -v '^#' | head -1 || echo "Unknown")
    fi
    # Domain
    if command -v realm >/dev/null 2>&1; then
        DOMAIN_NAME=$(realm list 2>/dev/null | awk '/domain-name/{print $2}' | head -1)
    fi
    [ -z "$DOMAIN_NAME" ] && DOMAIN_NAME=$(cat /etc/hostname 2>/dev/null | cut -d'.' -f2- || echo "Unknown")
    # Number of processors
    NUM_PROCESSORS=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo "Unknown")
    # Memory slots
    if command -v dmidecode >/dev/null 2>&1; then
        MEMORY_SLOTS=$(dmidecode -t memory 2>/dev/null | grep -E 'Size:|Type:|Speed:' | paste - - - | head -4 | sed 's/\t/,/g' | tr '\n' ';')
    fi
    # Last boot
    LAST_BOOT_TIME=$(who -b 2>/dev/null | awk '{print $3,$4}' | head -1)
    [ -z "$LAST_BOOT_TIME" ] && LAST_BOOT_TIME=$(uptime -s 2>/dev/null || echo "Unknown")
fi

SERIAL_NUMBER=$(echo "$SERIAL_NUMBER" | sed 's/"/\\"/g' | tr -d '\n')
MANUFACTURER=$(echo "$MANUFACTURER"   | sed 's/"/\\"/g' | tr -d '\n')
MODEL_NAME=$(echo "$MODEL_NAME"       | sed 's/"/\\"/g' | tr -d '\n')
BIOS_VERSION=$(echo "$BIOS_VERSION"   | sed 's/"/\\"/g' | tr -d '\n')
BIOS_DATE=$(echo "$BIOS_DATE"         | sed 's/"/\\"/g' | tr -d '\n')
ASSET_TAG=$(echo "$ASSET_TAG"         | sed 's/"/\\"/g' | tr -d '\n')
DOMAIN_NAME=$(echo "$DOMAIN_NAME"     | sed 's/"/\\"/g' | tr -d '\n')
PROCESSOR_TYPE=$(echo "$PROCESSOR_TYPE" | sed 's/"/\\"/g' | tr -d '\n')
MEMORY_SLOTS=$(echo "$MEMORY_SLOTS"   | sed 's/"/\\"/g' | tr -d '\n')
LAST_BOOT_TIME=$(echo "$LAST_BOOT_TIME" | sed 's/"/\\"/g' | tr -d '\n')

# Physical Network Adapters
NETWORK_ADAPTERS_JSON="[]"
if command -v python3 >/dev/null 2>&1; then
    if [ "$OS_NAME" = "macOS" ]; then
        NETWORK_ADAPTERS_JSON=$(python3 - <<'PYEOF'
import subprocess, json, re
adapters = []
try:
    r = subprocess.run(['networksetup', '-listallhardwareports'], capture_output=True, text=True, timeout=10)
    port = ""
    device = ""
    for line in r.stdout.splitlines():
        if 'Hardware Port:' in line:
            port = line.split(':', 1)[1].strip()
        elif 'Device:' in line:
            device = line.split(':', 1)[1].strip()
        elif 'Ethernet Address:' in line:
            mac = line.split(':', 1)[1].strip()
            if port and device:
                # Get IP/gateway/mask for this interface
                ip4 = "Unknown"; ip6 = "Unknown"; gw = "Unknown"; mask = "Unknown"
                dns = "Unknown"; dns_domain = "Unknown"
                try:
                    ipres = subprocess.run(['ipconfig', 'getifaddr', device], capture_output=True, text=True, timeout=5)
                    ip4 = ipres.stdout.strip() or "Unknown"
                except: pass
                try:
                    gwres = subprocess.run(['route', '-n', 'get', 'default'], capture_output=True, text=True, timeout=5)
                    for gl in gwres.stdout.splitlines():
                        if 'gateway:' in gl: gw = gl.split(':', 1)[1].strip()
                except: pass
                try:
                    scutil = subprocess.run(['scutil', '--dns'], capture_output=True, text=True, timeout=5)
                    for dl in scutil.stdout.splitlines():
                        if 'nameserver[0]' in dl: dns = dl.split(':', 1)[1].strip()
                        if 'domain_name' in dl: dns_domain = dl.split(':', 1)[1].strip()
                except: pass
                adapters.append({
                    "name": port, "description": device,
                    "adapter_type": "Ethernet", "speed": "Unknown",
                    "mac_address": mac, "gateway": gw,
                    "network_mask": mask, "dns_domain": dns_domain,
                    "dns_servers": dns, "dhcp_server": "Unknown",
                    "ipv4_addresses": ip4, "ipv6_addresses": ip6, "mtu": "Unknown"
                })
                port = ""; device = ""
except Exception as e:
    pass
print(json.dumps(adapters))
PYEOF
)
    else
        NETWORK_ADAPTERS_JSON=$(python3 - <<'PYEOF'
import subprocess, json, re
adapters = []
try:
    r = subprocess.run(['ip', 'addr', 'show'], capture_output=True, text=True, timeout=10)
    iface = ""; mac = ""; ipv4 = []; ipv6 = []; mtu = "Unknown"
    def flush(iface, mac, ipv4, ipv6, mtu):
        if iface and iface != 'lo':
            gw = "Unknown"; dns = "Unknown"; dns_domain = "Unknown"; mask = "Unknown"
            try:
                gr = subprocess.run(['ip', 'route', 'show', 'dev', iface], capture_output=True, text=True, timeout=5)
                for gl in gr.stdout.splitlines():
                    if 'via' in gl and 'default' in gl:
                        gw = gl.split('via')[1].split()[0]
            except: pass
            try:
                with open('/etc/resolv.conf') as f:
                    lines = f.readlines()
                dns_list = [l.split()[1] for l in lines if l.startswith('nameserver')]
                dns = ', '.join(dns_list[:3])
                domain_list = [l.split()[1] for l in lines if l.startswith('domain') or l.startswith('search')]
                dns_domain = domain_list[0] if domain_list else "Unknown"
            except: pass
            adapters.append({
                "name": iface, "description": iface,
                "adapter_type": "Ethernet", "speed": "Unknown",
                "mac_address": mac, "gateway": gw,
                "network_mask": mask, "dns_domain": dns_domain,
                "dns_servers": dns, "dhcp_server": "Unknown",
                "ipv4_addresses": ', '.join(ipv4) or "Unknown",
                "ipv6_addresses": ', '.join(ipv6) or "Unknown",
                "mtu": mtu
            })
    for line in r.stdout.splitlines():
        m = re.match(r'^\d+: (\S+):', line)
        if m:
            if iface: flush(iface, mac, ipv4, ipv6, mtu)
            iface = m.group(1).rstrip(':'); mac = "Unknown"; ipv4 = []; ipv6 = []; mtu = "Unknown"
            mt = re.search(r'mtu (\d+)', line)
            if mt: mtu = mt.group(1)
        if 'link/ether' in line: mac = line.split()[1]
        ia = re.match(r'\s+inet (\S+)', line)
        if ia: ipv4.append(ia.group(1).split('/')[0])
        ia6 = re.match(r'\s+inet6 (\S+)', line)
        if ia6 and 'fe80' not in ia6.group(1): ipv6.append(ia6.group(1).split('/')[0])
    if iface: flush(iface, mac, ipv4, ipv6, mtu)
except Exception as e:
    pass
print(json.dumps(adapters))
PYEOF
)
    fi
fi

# Disk Partitions (all Excel fields)
DISK_PARTITIONS_JSON="[]"
if command -v python3 >/dev/null 2>&1; then
    if [ "$OS_NAME" = "macOS" ]; then
        DISK_PARTITIONS_JSON=$(python3 - <<'PYEOF'
import subprocess, json
try:
    r = subprocess.run(['diskutil', 'list', '-plist'], capture_output=True, text=True, timeout=10)
    partitions = []
    # Fallback to text parsing
    rt = subprocess.run(['diskutil', 'list'], capture_output=True, text=True, timeout=10)
    df_out = subprocess.run(['df', '-h'], capture_output=True, text=True, timeout=5).stdout
    df_map = {}
    for dfline in df_out.splitlines()[1:]:
        dparts = dfline.split()
        if len(dparts) >= 4: df_map[dparts[0]] = (dparts[3], dparts[1])  # avail, size
    for line in rt.stdout.splitlines():
        parts = line.split()
        if parts and parts[0].isdigit():
            name  = parts[-1] if len(parts) > 1 else "Unknown"
            ptype = parts[1] if len(parts) > 1 else "Unknown"
            size  = " ".join(parts[3:5]) if len(parts) >= 5 else "Unknown"
            free_space = "Unknown"; fs = "Unknown"
            dev = "/dev/" + name
            if dev in df_map: free_space, _ = df_map[dev]
            try:
                dr = subprocess.run(['diskutil', 'info', name], capture_output=True, text=True, timeout=5)
                for dl in dr.stdout.splitlines():
                    if 'File System Personality' in dl or 'Type (Bundle)' in dl:
                        fs = dl.split(':', 1)[1].strip(); break
            except: pass
            partitions.append({"name": name, "type": ptype, "size_gb": size,
                                "free_space": free_space, "bootable": "Unknown", "file_system": fs})
    print(json.dumps(partitions))
except:
    print("[]")
PYEOF
)
    elif command -v lsblk >/dev/null 2>&1; then
        DISK_PARTITIONS_JSON=$(lsblk -J -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE 2>/dev/null | python3 - <<'PYEOF'
import sys, json, subprocess
try:
    data = json.load(sys.stdin)
    partitions = []
    df_map = {}
    try:
        df_out = subprocess.run(['df', '-h', '--output=target,avail'], capture_output=True, text=True, timeout=5).stdout
        for dl in df_out.splitlines()[1:]:
            dp = dl.split()
            if len(dp) == 2: df_map[dp[0]] = dp[1]
    except: pass
    def flatten(devices):
        for d in devices:
            mnt = d.get("mountpoint") or ""
            free_space = df_map.get(mnt, "Unknown") if mnt else "Unknown"
            partitions.append({
                "name": d.get("name",""), "type": d.get("type",""),
                "size_gb": d.get("size",""), "free_space": free_space,
                "bootable": "Unknown", "file_system": d.get("fstype","Unknown") or "Unknown"
            })
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

# Physical Disk Details (Excel "Disk Information" group)
DISK_DETAILS_JSON="[]"
if command -v python3 >/dev/null 2>&1; then
    if [ "$OS_NAME" = "macOS" ]; then
        DISK_DETAILS_JSON=$(python3 - <<'PYEOF'
import subprocess, json, re
disks = []
try:
    r = subprocess.run(['diskutil', 'list'], capture_output=True, text=True, timeout=10)
    # Get top-level disks (e.g. /dev/disk0)
    top_disks = [l.split()[0] for l in r.stdout.splitlines() if l.startswith('/dev/disk')]
    for dev in top_disks:
        try:
            ir = subprocess.run(['diskutil', 'info', dev], capture_output=True, text=True, timeout=5)
            info = {}
            for line in ir.stdout.splitlines():
                if ':' in line:
                    k, v = line.split(':', 1)
                    info[k.strip()] = v.strip()
            size_bytes = info.get('Disk Size', '').split('(')
            size_str = size_bytes[0].strip() if size_bytes else "Unknown"
            is_ssd = "Yes" if info.get('Solid State', '').lower() == 'yes' else "No"
            disks.append({
                "name": dev, "interface": info.get('Protocol', 'Unknown'),
                "file_system": info.get('File System Personality', info.get('Content', 'Unknown')),
                "manufacturer": "Apple", "model": info.get('Device / Media Name', 'Unknown'),
                "serial_number": info.get('Device Serial Number', 'Unknown'),
                "firmware": info.get('OS Can Be Installed to Disk', 'Unknown'),
                "size": size_str, "free_space": "Unknown", "is_ssd": is_ssd
            })
        except: pass
except: pass
print(json.dumps(disks))
PYEOF
)
    else
        DISK_DETAILS_JSON=$(python3 - <<'PYEOF'
import subprocess, json, os, re
disks = []
try:
    r = subprocess.run(['lsblk', '-d', '-o', 'NAME,SIZE,ROTA,TRAN,MODEL,SERIAL,VENDOR', '--json'],
                       capture_output=True, text=True, timeout=10)
    data = json.loads(r.stdout)
    for d in data.get('blockdevices', []):
        is_ssd = "Yes" if d.get('rota') == "0" else "No"
        name = d.get('name', '')
        # Get filesystem from first partition
        fs = "Unknown"
        try:
            fr = subprocess.run(['lsblk', '-o', 'FSTYPE', '-n', '/dev/' + name],
                                capture_output=True, text=True, timeout=5)
            fstypes = [l.strip() for l in fr.stdout.splitlines() if l.strip()]
            if fstypes: fs = fstypes[0]
        except: pass
        disks.append({
            "name": '/dev/' + name,
            "interface": d.get('tran', 'Unknown') or "Unknown",
            "file_system": fs,
            "manufacturer": (d.get('vendor') or "Unknown").strip(),
            "model": (d.get('model') or "Unknown").strip(),
            "serial_number": d.get('serial', 'Unknown') or "Unknown",
            "firmware": "Unknown",
            "size": d.get('size', 'Unknown'),
            "free_space": "Unknown",
            "is_ssd": is_ssd
        })
except Exception as e:
    # Fallback: dmidecode for disk info
    try:
        dr = subprocess.run(['dmidecode', '-t', '17'], capture_output=True, text=True, timeout=10)
        disks.append({"name": "Unknown", "interface": "Unknown", "file_system": "Unknown",
                      "manufacturer": "Unknown", "model": "Unknown", "serial_number": "Unknown",
                      "firmware": "Unknown", "size": "Unknown", "free_space": "Unknown", "is_ssd": "Unknown"})
    except: pass
print(json.dumps(disks))
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
                peripherals.append({
                    'name': name,
                    'type': 'USB',
                    'description': item.get('_name', 'Unknown'),
                    'manufacturer': item.get('manufacturer', 'Unknown') or 'Unknown',
                    'version': item.get('bcd_device', 'Unknown') or 'Unknown'
                })
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
import subprocess, json, re
peripherals = []
try:
    r = subprocess.run(['lsusb', '-v'], capture_output=True, text=True, timeout=15)
    current = {}
    for line in r.stdout.splitlines():
        line = line.strip()
        if line.startswith('Bus ') and 'Device' in line:
            if current.get('name'):
                peripherals.append(current)
            current = {'type': 'USB', 'description': 'Unknown', 'manufacturer': 'Unknown', 'version': 'Unknown'}
            m = re.search(r'ID \S+ (.+)', line)
            current['name'] = m.group(1).strip() if m else 'Unknown'
        elif 'iManufacturer' in line:
            parts = line.split(None, 2)
            current['manufacturer'] = parts[2] if len(parts) > 2 else 'Unknown'
        elif 'iProduct' in line:
            parts = line.split(None, 2)
            if len(parts) > 2: current['description'] = parts[2]
        elif 'bcdDevice' in line:
            parts = line.split()
            current['version'] = parts[1] if len(parts) > 1 else 'Unknown'
    if current.get('name'):
        peripherals.append(current)
    # Filter root hubs
    peripherals = [p for p in peripherals if 'root hub' not in p.get('name','').lower()]
except Exception:
    # Fallback: simple lsusb
    try:
        r = subprocess.run(['lsusb'], capture_output=True, text=True, timeout=10)
        for line in r.stdout.splitlines():
            parts = line.split(':', 2)
            name = parts[2].strip() if len(parts) > 2 else line.strip()
            if name and 'root hub' not in name.lower():
                peripherals.append({'name': name, 'type': 'USB', 'description': name, 'manufacturer': 'Unknown', 'version': 'Unknown'})
    except: pass
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
                'size_mb': 'Unknown',
                'last_used': a.get('lastModified', 'Unknown')
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
                         'publisher': '', 'install_date': 'Unknown', 'size_mb': size_str, 'last_used': 'Unknown'})
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
                         'publisher': '', 'install_date': 'Unknown', 'size_mb': size_str, 'last_used': 'Unknown'})
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
        "serial_number": "$SERIAL_NUMBER",
        "manufacturer": "$MANUFACTURER",
        "model": "$MODEL_NAME",
        "num_processors": "$NUM_PROCESSORS",
        "processor_type": "$PROCESSOR_TYPE",
        "bios_version": "$BIOS_VERSION",
        "bios_date": "$BIOS_DATE",
        "asset_tag": "$ASSET_TAG",
        "last_boot_time": "$LAST_BOOT_TIME",
        "domain": "$DOMAIN_NAME",
        "domain_role": "$DOMAIN_ROLE",
        "description": "$DEVICE_DESC",
        "memory_slots": "$MEMORY_SLOTS",
        "last_backup_time": "$LAST_BACKUP_TIME",
        "gpu_details": $GPU_JSON,
        "network_adapters": $NETWORK_ADAPTERS_JSON,
        "peripherals": $PERIPHERALS_JSON,
        "disk_partitions": $DISK_PARTITIONS_JSON,
        "disk_details": $DISK_DETAILS_JSON
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

# ── Connectivity check before uploading ───────────────────────────────────────
SERVER_HOST=$(echo "$API_URL" | sed 's|http://||' | cut -d'/' -f1 | cut -d':' -f1)
SERVER_PORT=$(echo "$API_URL" | sed 's|http://||' | cut -d'/' -f1 | cut -d':' -f2)
SERVER_PORT="${SERVER_PORT:-8000}"

echo "Checking connection to server ($SERVER_HOST:$SERVER_PORT)..."
if command -v nc >/dev/null 2>&1; then
    nc -z -w 5 "$SERVER_HOST" "$SERVER_PORT" 2>/dev/null
    NC_RC=$?
elif command -v bash >/dev/null 2>&1; then
    (echo > /dev/tcp/"$SERVER_HOST"/"$SERVER_PORT") 2>/dev/null
    NC_RC=$?
else
    NC_RC=0   # skip check if neither available
fi

if [ "$NC_RC" -ne 0 ]; then
    echo ""
    echo "ERROR: Cannot reach server at $SERVER_HOST:$SERVER_PORT"
    echo "Possible causes:"
    echo "  1. Server is not running — start it with: uvicorn backend.main:app --host 0.0.0.0 --port 8000"
    echo "  2. Windows Firewall is blocking port $SERVER_PORT"
    echo "     Fix: run server as Administrator (it auto-adds the firewall rule)"
    echo "  3. You are on a different network/subnet than the server"
    echo "  4. Open this script URL directly in a browser to verify: $API_URL"
    echo ""
    echo "Press enter to exit..."
    read -r
    exit 1
fi

echo "Uploading secure payload to backend..."

# ── Upload with timeout — curl preferred, wget as fallback ───────────────────
HTTP_STATUS=""
BODY=""

if command -v curl >/dev/null 2>&1; then
    RESPONSE=$(curl -s \
        --connect-timeout 10 \
        --max-time 60 \
        -w "\n%{http_code}" \
        -X POST "$API_URL" \
        -H "Content-Type: application/json" \
        -d "$JSON" 2>/dev/null)
    HTTP_STATUS=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | head -n -1)
elif command -v wget >/dev/null 2>&1; then
    BODY=$(wget -q -O - \
        --timeout=60 \
        --tries=1 \
        --header="Content-Type: application/json" \
        --post-data="$JSON" \
        "$API_URL" 2>/dev/null)
    HTTP_STATUS=$?
    [ "$HTTP_STATUS" -eq 0 ] && HTTP_STATUS=200 || HTTP_STATUS=500
else
    echo "ERROR: Neither curl nor wget is installed. Cannot upload audit data."
    echo "Install curl:  sudo apt install curl  (Debian/Ubuntu)"
    echo "               brew install curl       (macOS)"
    echo "Press enter to exit..."
    read -r
    exit 1
fi

if [ "$HTTP_STATUS" = "200" ]; then
    echo "Audit upload completed successfully!"
else
    echo "Upload failed. HTTP Status: $HTTP_STATUS"
    echo "Details: $BODY"
    echo ""
    echo "Troubleshooting:"
    echo "  - Ensure you opened the frontend using the server's Network IP, not localhost"
    echo "  - Check server logs for errors"
fi

echo "Press enter to exit..."
read -r
