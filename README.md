# Prevoyance Inspection — NSDL IT Asset Management Portal

A workstation compliance audit tool for NSDL branch offices. Collects IT asset and system information from Windows, macOS, and Linux workstations and generates PDF + XML audit reports.

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

The server will start at: **http://localhost:8000**

The `--reload` flag enables auto-restart on file changes (recommended for development).

---

## Accessing the Application

Open your browser and navigate to:

```
http://localhost:8000
```

The frontend is served directly by the FastAPI backend.

---

## Running an Audit

1. Open the app in your browser
2. Go to the **Compliance Audit** tab
3. Fill in branch and officer details
4. Click **Start Compliance Audit** — a launcher script will be downloaded
5. Run the downloaded script on the target workstation:
   - **Windows** — run the `.vbs` file (launches PowerShell silently)
   - **macOS** — run the `.command` file in Terminal
   - **Linux** — run the `.sh` file in Terminal
6. The frontend polls for completion every 2 seconds
7. Download the generated **PDF** or **XML** report once complete

---

## Tabs Overview

| Tab | Description |
|-----|-------------|
| Compliance Audit | Run audits, download launcher scripts, get PDF/XML reports |
| Asset Registry | Register, edit, and delete IT assets with lifecycle tracking |
| Network Discovery | TCP port scan any CIDR range with ARP fallback for mobile/firewalled devices |
| Device Audits | Browse hardware specs, software inventory, and login history per device |
| WiFi Dashboard | Scan nearby WiFi networks, connect, and discover devices on the subnet |

---

## Stopping the Server

Press `Ctrl+C` in the terminal where the server is running.

---

## Restarting After Setup

Once the virtual environment is set up, you only need two commands to run the project:

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
| `GET` | `/api/software/{computer_name}` | Get software inventory with change diff |
| `POST` | `/discover/network-scan` | Scan a CIDR range for live hosts |
| `GET` | `/wifi/networks` | List nearby WiFi networks |
| `GET` | `/wifi/current` | Get current WiFi connection info |
| `POST` | `/wifi/connect` | Connect to a WiFi network |
| `POST` | `/asset-metadata` | Save an asset record |
| `GET` | `/assets` | List all asset records |

---

## Tech Stack

- **Backend** — Python, FastAPI, Uvicorn
- **Frontend** — HTML, CSS, Vanilla JavaScript (single page)
- **Reports** — ReportLab (PDF), xml.etree.ElementTree (XML)
- **Audit Scripts** — PowerShell (Windows), Bash (macOS / Linux)
