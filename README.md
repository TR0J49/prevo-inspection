# Infrapulse — NSDL IT Asset Management Portal

A workstation compliance audit tool for NSDL branch offices. Collects IT asset and system information from Windows, macOS, and Linux workstations and generates PDF + XML audit reports.

---

## Tech Stack

| Layer | Technology | Role |
|-------|-----------|------|
| ⭐ **Backend Framework** | [FastAPI](https://fastapi.tiangolo.com/) | Core API server — routes, data validation, report generation |
| ⭐ **ASGI Server** | [Uvicorn](https://www.uvicorn.org/) | Serves FastAPI, auto-reload, LAN binding on `0.0.0.0` |
| ⭐ **Data Validation** | [Pydantic v2](https://docs.pydantic.dev/) | Validates all incoming audit JSON payloads |
| ⭐ **PDF Generation** | [ReportLab](https://www.reportlab.com/) | Builds the compliance PDF report with tables and branding |
| **XML Generation** | Python `xml.etree.ElementTree` | Builds structured XML audit export |
| ⭐ **Frontend** | Vanilla JS + HTML/CSS | Single-page UI, no framework — zero build step |
| **Windows Audit** | PowerShell (`audit.ps1`) | Collects full system data via WMI/registry on Windows |
| ⭐ **Mac/Linux Audit** | Bash + Python3 (`audit.sh`) | Cross-platform data collection via system commands |
| **Network Scanning** | Python `socket` + `ipaddress` | TCP port scan with ARP fallback for device discovery |
| **WiFi** | `netsh` / `airport` / `nmcli` | Platform-specific WiFi scan and connect |
| **Concurrency** | `concurrent.futures.ThreadPoolExecutor` | Parallel port scanning across /24 subnets |
| **Tunneling** | [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) | Expose local server publicly for remote audits |

> ⭐ = plays a major role in core functionality

---

## System Flow

```mermaid
flowchart TD
    A([Auditor opens browser]) --> B[Frontend - index.html\nServed by FastAPI]
    B --> C[Fill branch & officer details\nCompliance Audit tab]
    C --> D[Click Start Compliance Audit]
    D --> E[Backend creates client_id\nstores session in memory]

    E --> F{Target OS?}
    F -->|Windows| G[Download .vbs launcher]
    F -->|macOS| H[Download .command launcher]
    F -->|Linux| I[Download .sh launcher]

    G --> J[VBScript runs PowerShell\naudit.ps1 silently]
    H --> K[curl fetches audit.sh\npipes to bash]
    I --> K

    J --> L[audit.ps1 collects\nOS, CPU, RAM, Disk\nSoftware, Hotfixes\nAV, Printers, USB\nLogin History]
    K --> M[audit.sh collects\nOS, CPU, RAM, Disk\nSoftware, Printers\nAV, USB, Hotfixes\nLogin History]

    L --> N[POST JSON to\n/upload-audit?client_id=]
    M --> N

    N --> O[FastAPI validates payload\nvia Pydantic]
    O --> P[Save raw audit.json]
    P --> Q[Generate PDF\nvia ReportLab]
    P --> R[Generate XML\nvia ElementTree]

    Q --> S[Store in user_info/]
    R --> S

    S --> T[Session status = completed]
    T --> U[Frontend polls /check-status\nevery 2 seconds]
    U --> V{Status?}
    V -->|pending| U
    V -->|completed| W[Show Download Links\nPDF and XML]

    style A fill:#4f46e5,color:#fff
    style W fill:#047857,color:#fff
    style N fill:#b45309,color:#fff
    style O fill:#b45309,color:#fff
```

---

## Network Flow (LAN / Broadband)

```mermaid
flowchart LR
    subgraph Server["Server Machine (Windows)"]
        SRV[Uvicorn :8000\nFirewall port open]
        FE[Frontend UI]
        BE[FastAPI Backend]
        SRV --> FE
        SRV --> BE
    end

    subgraph Network["Local Network / Router"]
        LAN[LAN IP\n192.168.x.x:8000]
        CF[Cloudflare Tunnel\nhttps://xxx.trycloudflare.com]
    end

    subgraph Clients["Client Workstations"]
        WIN[Windows\naudit.ps1]
        MAC[macOS\naudit.sh]
        LNX[Linux\naudit.sh]
    end

    Server --> LAN
    Server --> CF

    LAN -->|Same router| WIN
    LAN -->|Same router| MAC
    LAN -->|Same router| LNX

    CF -->|Any network| WIN
    CF -->|Any network| MAC
    CF -->|Any network| LNX

    WIN -->|POST audit JSON| BE
    MAC -->|POST audit JSON| BE
    LNX -->|POST audit JSON| BE

    style Server fill:#1e3a5f,color:#fff
    style Network fill:#374151,color:#fff
    style Clients fill:#1a3d2b,color:#fff
    style CF fill:#f97316,color:#fff
```

---

## Audit Data Flow (Incremental Diff)

```mermaid
flowchart TD
    A[Device runs audit] --> B[audit JSON saved\nwith timestamp]
    B --> C{Previous audit\nexists?}

    C -->|Yes| D[Load latest 2 audits\nfor this device]
    C -->|No| E[Show all apps as unchanged\nSort by install date]

    D --> F[Compare software lists\nby app name]

    F --> G[Tag each app]
    G --> G1[NEW - not in previous]
    G --> G2[UPDATED - version changed]
    G --> G3[REMOVED - gone from latest]
    G --> G4[UNCHANGED - no change]

    G1 --> H[Sort order:\nNEW first]
    G2 --> H
    G4 --> H
    G3 --> I[REMOVED at bottom\nstrike-through style]

    H --> J[Render table with badges\nGreen = NEW\nBlue = UPDATED]
    I --> J

    J --> K[Diff summary bar\nshows change counts]

    style G1 fill:#047857,color:#fff
    style G2 fill:#1d4ed8,color:#fff
    style G3 fill:#991b1b,color:#fff
    style G4 fill:#374151,color:#fff
    style K fill:#4f46e5,color:#fff
```

---

## Project Structure

```
prevo-inspection/
├── backend/
│   ├── main.py              # FastAPI application (all API routes)
│   └── requirements.txt     # Python dependencies
├── frontend/
│   └── index.html           # Single-page UI (vanilla JS, no framework)
├── scripts/
│   ├── audit.ps1            # Windows PowerShell audit script
│   └── audit.sh             # macOS / Linux bash audit script
├── user_info/               # Generated audit JSON, PDF, XML reports
├── logs/                    # Backend log file
└── venv/                    # Python virtual environment (created locally)
```

---

## Requirements

- Python 3.10 or higher
- pip

---

## Setup & Running

### 1. Clone the repository

```bash
git clone https://github.com/TR0J49/prevo-inspection.git
cd prevo-inspection
```

### 2. Create a virtual environment

**Windows**
```bash
python -m venv venv
```

**macOS / Linux**
```bash
python3 -m venv venv
```

### 3. Activate the virtual environment

**Windows**
```bash
venv\Scripts\activate
```

**macOS / Linux**
```bash
source venv/bin/activate
```

### 4. Install dependencies

```bash
pip install -r backend/requirements.txt
```

### 5. Start the server

```bash
uvicorn backend.main:app --host 0.0.0.0 --port 8000 --reload
```

On startup you will see your network URL printed automatically:

```
======================================================
  Infrapulse - NSDL IT Asset Management Portal
======================================================
  Local   : http://localhost:8000
  Network : http://192.168.x.x:8000   <-- share this with client machines
------------------------------------------------------
  macOS : right-click .command -> Open, or run:
    bash verify_system_<id>.command
  Linux : run with:
    bash verify_system_<id>.sh
======================================================
```

> Open the frontend using the **Network URL** (not localhost) so audit scripts on client machines get the correct server address injected automatically.

---

## Running an Audit

1. Open the app in your browser using the **Network IP** shown on startup
2. Go to the **Compliance Audit** tab
3. Fill in branch and officer details
4. Click **Start Compliance Audit** — a launcher script will be downloaded
5. Run the downloaded script on the target workstation:
   - **Windows** — run the `.vbs` file (launches PowerShell silently)
   - **macOS** — run: `bash verify_system_<id>.command`
   - **Linux** — run: `bash verify_system_<id>.sh`
6. The frontend polls for completion every 2 seconds
7. Download the generated **PDF** or **XML** report once complete

---

## LAN / Firewall Notes

| Issue | Solution |
|-------|---------|
| Windows Firewall blocks port 8000 | Auto-added on startup as `Infrapulse Port 8000` rule. Run server as Administrator if it fails |
| macOS Gatekeeper blocks `.command` | Run with `bash verify_system_<id>.command` instead of double-clicking |
| Client on different network | Use Cloudflare Tunnel: `cloudflared tunnel --url http://localhost:8000` |
| curl not installed (Linux) | Script falls back to `wget` automatically |
| Server unreachable | Script checks TCP connection first and prints a clear error with cause |

---

## Exposing via Cloudflare Tunnel

For cross-network audits (different router / broadband / remote site):

**Terminal 1 — Server**
```bash
venv\Scripts\activate
uvicorn backend.main:app --host 0.0.0.0 --port 8000 --reload
```

**Terminal 2 — Tunnel**
```bash
cloudflared tunnel --url http://localhost:8000
```

Open the frontend via the `https://xxxx.trycloudflare.com` URL so that URL is injected into audit scripts.

---

## Tabs Overview

| Tab | Description |
|-----|-------------|
| Compliance Audit | Run audits, download launcher scripts, get PDF/XML reports |
| Asset Registry | Register, edit, and delete IT assets with lifecycle tracking |
| Network Discovery | TCP port scan any CIDR range with ARP fallback for mobile/firewalled devices |
| Device Audits | Browse hardware specs, software inventory, and incremental change diff per device |
| WiFi Dashboard | Scan nearby WiFi networks, connect, and discover devices on the subnet |

---

## API Endpoints (Quick Reference)

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/check-status?client_id=` | Poll audit completion status |
| `GET` | `/download-vbs?client_id=` | Download Windows VBS launcher |
| `GET` | `/download-mac?client_id=` | Download macOS .command launcher |
| `GET` | `/download-linux?client_id=` | Download Linux .sh launcher |
| `POST` | `/upload-audit?client_id=` | Submit audit data, generate PDF + XML |
| `GET` | `/download-report?client_id=&format=pdf\|xml` | Download generated report |
| `GET` | `/api/devices` | List all audited devices |
| `GET` | `/api/software/{computer_name}` | Get software inventory with incremental diff |
| `POST` | `/discover/network-scan` | Scan a CIDR range for live hosts |
| `GET` | `/wifi/networks` | List nearby WiFi networks |
| `GET` | `/wifi/current` | Get current WiFi connection info |
| `POST` | `/wifi/connect` | Connect to a WiFi network |
| `POST` | `/asset-metadata` | Save an asset record |
| `GET` | `/assets` | List all asset records |

---

## Restarting After Setup

**Windows**
```bash
venv\Scripts\activate
uvicorn backend.main:app --host 0.0.0.0 --port 8000 --reload
```

**macOS / Linux**
```bash
source venv/bin/activate
uvicorn backend.main:app --host 0.0.0.0 --port 8000 --reload
```
