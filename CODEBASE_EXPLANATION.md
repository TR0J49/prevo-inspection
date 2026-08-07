# Codebase Explanation — InfraPulse

Complete walkthrough of the InfraPulse compliance audit system:

| Part | File | Lines |
|---|---|---|
| **Part 1 — Backend** | `backend/main.py` | 3,017 |
| **Part 2 — Windows collector** | `scripts/audit.ps1` | 1,151 |
| **Part 3 — macOS/Linux collector** | `scripts/audit.sh` | 2,186 |
| **Part 4** | [How data is collected — internal mechanics](#part-4--how-data-is-collected-from-inside-the-system) | — |
| **Part 5** | [How the data is verified](#part-5--how-the-data-is-verified) | — |

In Part 1, everything refers to `backend/main.py` unless another file is named.

---

## Table of contents

### Part 1 — Backend (`backend/main.py`)

1. [What this backend does](#1-what-this-backend-does)
2. [File layout and entry point](#2-file-layout-and-entry-point)
3. [Module preamble — imports, paths, logging](#3-module-preamble--imports-paths-logging)
4. [Startup: the `lifespan` handler](#4-startup-the-lifespan-handler)
5. [The storage layer — dual-track design](#5-the-storage-layer--dual-track-design)
6. [Section 1 — Helpers](#6-section-1--helpers)
7. [Section 2 — Pydantic models](#7-section-2--pydantic-models)
8. [Section 3 — Core routing and script launchers](#8-section-3--core-routing-and-script-launchers)
9. [Section 4 — PDF helpers](#9-section-4--pdf-helpers)
10. [Section 5 — Audit ingestion and report generation](#10-section-5--audit-ingestion-and-report-generation)
11. [Section 6 — Report serving](#11-section-6--report-serving)
12. [Section 7 — Asset metadata CRUD](#12-section-7--asset-metadata-crud)
13. [Section 8 — Device and software queries](#13-section-8--device-and-software-queries)
14. [Section 8b — Device diff](#14-section-8b--device-diff)
15. [Section 9 — Network discovery](#15-section-9--network-discovery)
16. [Section 11 — WiFi dashboard](#16-section-11--wifi-dashboard)
17. [Remote audit trigger](#17-remote-audit-trigger)
18. [Section 10 — Frontend serving](#18-section-10--frontend-serving)
19. [End-to-end request lifecycle](#19-end-to-end-request-lifecycle)
20. [Cross-cutting patterns](#20-cross-cutting-patterns)
21. [Known bugs and inconsistencies](#21-known-bugs-and-inconsistencies)

### Part 2 — Windows collector (`scripts/audit.ps1`)
22. [Structure and execution model](#22-auditps1--structure-and-execution-model)
23. [The 20 collection steps](#23-auditps1--the-20-collection-steps)
24. [Payload assembly and upload](#24-auditps1--payload-assembly-and-upload)

### Part 3 — macOS/Linux collector (`scripts/audit.sh`)
25. [Structure and the two-language model](#25-auditsh--structure-and-the-two-language-model)
26. [The 8 collection phases](#26-auditsh--the-8-collection-phases)
27. [Payload assembly and upload](#27-auditsh--payload-assembly-and-upload)

### Part 4 — Internal collection mechanics
28. [Windows — WMI, registry, event log, prefetch](#28-windows--wmi-registry-event-log-prefetch)
29. [Linux — sysfs, procfs, package managers](#29-linux--sysfs-procfs-package-managers)
30. [macOS — system_profiler, sysctl, ioreg](#30-macos--system_profiler-sysctl-ioreg)

### Part 5 — Data verification
31. [The five verification layers](#31-the-five-verification-layers)
32. [Hardware verification in detail](#32-hardware-verification-in-detail)
33. [Software verification in detail](#33-software-verification-in-detail)
34. [What is NOT verified](#34-what-is-not-verified)

---

## 1. What this backend does

A workstation compliance audit tool for NSDL branch offices. In one sentence:

> It hands a data-collection script to a workstation, receives the resulting JSON back over
> HTTP, turns it into a PDF and an XML report, and provides dashboards over the accumulated data.

The backend has **five functional areas**, which map to the five tabs in `frontend/index.html`:

| Area | Endpoints | Works off-LAN? |
|---|---|---|
| Compliance audit | `/download-*`, `/upload-audit`, `/check-status`, `/download-report` | Yes — pure HTTP |
| Asset registry | `/asset-metadata/*`, `/assets` | Yes — pure CRUD |
| Device audits | `/api/devices`, `/api/software/*`, `/api/device-diff/*` | Yes — reads stored data |
| Network discovery | `/discover/network-scan` | **No** — scans the server's own LAN |
| WiFi dashboard | `/wifi/*` | **No** — shells out to `netsh`/`nmcli` on the server |

The last two are the reason this app is normally deployed *inside* a branch LAN rather than
centrally. They ask the server to inspect the network it is physically attached to.

---

## 2. File layout and entry point

```
backend/
  main.py            <- everything described here (3,017 lines)
  requirements.txt
  static/main.py     <- old prototype, NOT imported by anything
frontend/
  index.html         <- single-page UI, served as static files
scripts/
  audit.ps1          <- Windows collector, served with placeholders substituted
  audit.sh           <- macOS/Linux collector, same
user_info/           <- audit JSON + generated PDF/XML
user_info/assets/    <- asset metadata JSON (file-fallback mode only)
logs/                <- audit_backend.log
```

**There is no `if __name__ == "__main__"` block and no `uvicorn.run()` call.** The app object is
created at module level and started externally:

```
uvicorn backend.main:app --host 0.0.0.0 --port 8000
```

The file is organised into numbered comment-banner sections. Note that **the numbering does not
match the physical order** — section 11 (WiFi) sits at line 2224, before section 10 (frontend
serving) at line 3007. Read by line number, not by section number.

---

## 3. Module preamble — imports, paths, logging

**Lines 1–58.**

Imports are conventional FastAPI + ReportLab + stdlib. Two are conditional:

```python
try:
    import psycopg2
    from psycopg2.pool import ThreadedConnectionPool
    from psycopg2.extras import Json as PgJson, RealDictCursor
    _PG_AVAILABLE = True
except ImportError:
    _PG_AVAILABLE = False        # line 41
```

```python
try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass                          # line 49
```

Both are optional. Without psycopg2 the app runs entirely on files. Without python-dotenv the
`.env` file is simply ignored and `os.getenv` falls back to defaults.

**Paths (lines 52–58).** `BASE_DIR` is computed as the parent of the parent of `main.py` — i.e.
the repo root, *not* `backend/`. Three directories are created eagerly at import time:

```python
BASE_DIR           = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOGS_DIR           = os.path.join(BASE_DIR, "logs")
USER_INFO_DIR      = os.path.join(BASE_DIR, "user_info")
ASSET_METADATA_DIR = os.path.join(BASE_DIR, "user_info", "assets")

for d in [LOGS_DIR, USER_INFO_DIR, ASSET_METADATA_DIR]:
    os.makedirs(d, exist_ok=True)
```

**Logging (lines 60–68).** Dual handler — a file at `logs/audit_backend.log` and stdout. Level
INFO. The logger name is `AuditBackend`.

---

## 4. Startup: the `lifespan` handler

**Lines 71–94.** Uses the modern `@asynccontextmanager` lifespan pattern rather than the
deprecated `@app.on_event("startup")`.

On startup, in order:

1. `_init_db()` — connect the Postgres pool and create tables
2. `_load_wifi_passwords()` — populate the in-memory `wifi_passwords` dict
3. `_get_lan_ip()` — determine the machine's LAN IP for the banner
4. `_open_firewall_port(8000)` — add a Windows Firewall rule (no-op elsewhere)
5. Print a banner with the local URL, network URL, and storage mode

Shutdown does nothing — the `yield` is followed by a bare comment. The Postgres pool is never
explicitly closed.

The banner's storage line is the quickest way to tell which mode you are in:

```python
db_status = f"PostgreSQL \"{PG_DATABASE}\" @ {PG_HOST}" if _db_ok() else "File storage (no DB)"
```

**App creation (lines 96–106).**

```python
app = FastAPI(title="NSDL IT Asset Management Portal", version="3.0.0", lifespan=lifespan)

app.add_middleware(CORSMiddleware,
    allow_origins=["*"], allow_credentials=True,
    allow_methods=["*"], allow_headers=["*"])

sessions = {}
```

`sessions` is a module-level dict used as an in-memory mirror of the `sessions` DB table. It is
process-local, so it does not survive a restart and is not shared across worker processes.

**Validation error handler (lines 108–113).** Overrides the default 422 response to log the
error before returning it. Useful when a collector script sends a malformed payload — the reason
lands in `audit_backend.log`.

---

## 5. The storage layer — dual-track design

**Lines 114–324.** This is the single most important pattern in the file. Almost every data
operation is written twice: once against PostgreSQL, once against the filesystem.

### Configuration (lines 116–121)

```python
PG_HOST     = os.getenv("PG_HOST",     "localhost")
PG_PORT     = int(os.getenv("PG_PORT", "5432"))
PG_USER     = os.getenv("PG_USER",     "postgres")
PG_PASSWORD = os.getenv("PG_PASSWORD", "shubham9284")   # hardcoded default
PG_DATABASE = os.getenv("PG_DATABASE", "AI audit")      # note the space in the name
```

### `_init_db()` (lines 124–179)

Builds a `ThreadedConnectionPool(minconn=1, maxconn=10)` and creates four tables with
`CREATE TABLE IF NOT EXISTS`:

| Table | Primary key | Purpose |
|---|---|---|
| `sessions` | `client_id` | One row per audit run — status, branch metadata, report paths |
| `audit_results` | `id` (serial) | One row per uploaded audit — full JSON in a `JSONB` column |
| `asset_metadata` | `device_id` | Lifecycle data (owner, warranty, PO) as `JSONB` |
| `wifi_passwords` | `ssid` | Saved WiFi credentials, **plaintext** |

**Failure is non-fatal.** The whole body is wrapped in `try/except`; on any error it logs and
sets `_db_pool = None`, which flips the entire application into file-storage mode:

```python
except Exception as e:
    logger.error(f"PostgreSQL init failed: {e}  (falling back to file storage)")
    _db_pool = None
```

### `_db_ok()` and `_db_ctx()` (lines 181–197)

`_db_ok()` is a one-liner used as the branch condition everywhere: `return _db_pool is not None`.

`_db_ctx()` is a context manager that borrows a connection, commits on clean exit, rolls back on
exception, and always returns the connection to the pool.

### Session helpers (lines 200–259)

`_session_get(client_id)` reads from the DB, falling back to the `sessions` dict, falling back to
`{"status": "pending"}`. It contains an important fix:

```python
# created_at/updated_at are TIMESTAMPTZ and come back as datetime objects,
# which JSONResponse cannot encode — /check-status would 500 and the frontend
# poll never reaches the download links.
for key, value in session.items():
    if isinstance(value, datetime):
        session[key] = value.isoformat()
```

`_session_set(client_id, data)` writes the in-memory mirror **first and unconditionally**, then
upserts to the DB with `ON CONFLICT (client_id) DO UPDATE`. If the DB write fails it logs but does
not raise — the in-memory copy still works for the life of the process.

### `_db_save_audit()` (lines 261–280)

Plain `INSERT` into `audit_results` with the full audit dict wrapped in `PgJson`. **No
deduplication and no upsert** — every upload is a new row. With `INTERVAL_HOURS=3` in the
installer config that is 8 rows per machine per day, forever.

### WiFi password store (lines 283–323)

A module-level `wifi_passwords: dict` loaded at startup and saved on change. `_save_wifi_passwords()`
loops the whole dict and upserts every entry. The file fallback writes to
`user_info/wifi_passwords.json`.

### `_get_lan_ip()` (lines 326–336)

Standard trick: open a UDP socket to `8.8.8.8:80` (which sends no packet) and read back the local
socket address. Returns `127.0.0.1` on failure.

### `_open_firewall_port()` (lines 338–372)

Windows-only, guarded by an early `return` on non-Windows. Shells out to `netsh advfirewall` to
check for and then add an inbound TCP allow rule. If it fails (not running as Administrator) it
logs the manual command rather than raising.

### `CONSENT_TEXT` (lines 376–380)

The fixed legal consent string embedded in every PDF and XML report.

---

## 6. Section 1 — Helpers

**Lines 375–391.** Two small functions that are used pervasively.

`clean_string(value, fallback="")` — the normalisation workhorse. Handles `None`, recursively
flattens lists into comma-joined strings, and substitutes the fallback for anything that is empty
or whitespace-only. This is why fields show `"Unknown"` rather than `null` throughout the reports.

`model_to_dict(model)` — Pydantic v1/v2 compatibility shim, preferring `model_dump()` and falling
back to `dict()`.

---

## 7. Section 2 — Pydantic models

**Lines 394–685.** Every model in the file is deliberately permissive. Two mechanisms do this.

### `_CleanBase` (lines 398–405)

```python
class _CleanBase(BaseModel):
    model_config = ConfigDict(extra="allow")

    @field_validator("*", mode="before")
    @classmethod
    def normalize(cls, v):
        return clean_string(v, "Unknown")
```

The wildcard `"*"` validator runs `clean_string` over **every field** before validation, so a
missing or null value from any collector becomes `"Unknown"` rather than a validation error.
`extra="allow"` means unknown keys are kept, not rejected.

### The model hierarchy

| Model | Lines | Represents |
|---|---|---|
| `GpuInfo` | 408 | One video controller |
| `NetworkAdapter` | 417 | One NIC — 14 fields incl. DHCP, DNS, MTU |
| `Peripheral` | 435 | One peripheral device |
| `ConnectedDevice` | 444 | Anything on any port — USB, PCI, Bluetooth, HDMI, serial |
| `DiskPartition` | 459 | One partition |
| `DiskInfo` | 469 | One physical disk |
| `HardwareDetails` | 483 | The big one — ~30 scalars plus 6 nested lists |
| `NetworkDetails` | 554 | IP / gateway / MAC triple |
| `UserAccount` | 560 | One local or domain user |
| `HotfixData` | 571 | One OS update |
| `PrinterData` | 585 | One printer |
| `SoftwareEntry` | 599 | One installed application |
| `AuditData` | 609 | **The root payload model** |
| `AssetMetadata` | 661 | Lifecycle record — owner, warranty, PO, supplier |
| `NetworkScanRequest` | 682 | `{ip_range, timeout_ms}` |

The field comments map each attribute back to a column in the source
`Inventory Data Fields (1).xlsx` spreadsheet — e.g. `# Excel: Warranty End Date`. That
spreadsheet is the requirements contract for what must be collected.

`HardwareDetails` does not inherit `_CleanBase` because it needs two *different* validators
(lines 519–553): a string normaliser listing 30 fields explicitly, and a `coerce_list` validator
that wraps a bare object into a single-element list so a collector returning one GPU instead of an
array still parses.

`AuditData` uses `Union[Model, dict, str]` types throughout, e.g.:

```python
hotfixes: List[Union[HotfixData, str]] = []
hardware_details: Union[HardwareDetails, dict, str] = {}
```

That is why downstream report code constantly does `isinstance(x, HotfixData)` checks — the same
field can arrive as a typed model, a raw dict, or a bare string depending on which collector ran.

---

## 8. Section 3 — Core routing and script launchers

**Lines 687–789.** Six endpoints that get a collector script onto a target machine.

### `GET /check-status` (line 690)

One line of logic: `_session_get(client_id)` returned as JSON. The frontend polls this every 2
seconds until `status == "completed"`.

### `GET /download-script` (line 696) — Windows collector

Reads `scripts/audit.ps1` and performs two string substitutions:

```python
content = content.replace("http://127.0.0.1:8000", base_url)
content = content.replace("CLIENT_ID_PLACEHOLDER", client_id)
```

`base_url` comes from `str(request.base_url).rstrip("/")` — derived from the incoming request, so
the script always points back at whatever host the client used to reach the server.

The explicit `encoding="utf-8"` on the `open()` call is deliberate; the comment explains that
Python's default locale codec (cp1252 on Windows) mangles or crashes on the box-drawing characters
in the script's banner.

### `GET /download-vbs` (line 713) — Windows launcher

Creates the session record with branch metadata from query parameters, then returns a `.vbs` file
that runs PowerShell hidden:

```vbscript
command = "powershell -ExecutionPolicy Bypass -WindowStyle Hidden -Command " & Chr(34) &
"Invoke-RestMethod -Uri 'BASE/download-script?client_id=ID' | Invoke-Expression" & Chr(34)
objShell.Run command, 0, False
```

The `.vbs` wrapper exists so a double-click runs the audit with no visible console window.

### `GET /download-mac-script` (line 738) — macOS/Linux collector

Same substitution logic as `/download-script`, but serves `scripts/audit.sh`.

### `GET /download-mac` (line 752) and `GET /download-linux` (line 772)

Nearly identical. Both create the session record and return a two-line shell script:

```bash
#!/bin/bash
curl -s "BASE/download-mac-script?client_id=ID" | bash
```

The only difference is the `Content-Disposition` filename — `.command` for macOS (which Finder
treats as double-clickable) versus `.sh` for Linux.

All three launcher endpoints default the branch metadata to hardcoded values
(`"RELIGARE BROKING LIMITED"`, code `"8301231"`, officer `"SANDIP BALIRAM LOKHANDE"`) when the
frontend does not supply them.

---

## 9. Section 4 — PDF helpers

**Lines 792–945.** ReportLab plumbing plus two non-trivial calculators.

### Layout helpers

- `draw_page_decorations(canvas, doc)` (795) — draws the red border rectangle and the
  "INSPECTION REPORT BY NSDL E-GOVERNANCE" footer on every page. Passed to `doc.build()` as both
  `onFirstPage` and `onLaterPages`.
- `pdf_text(value, style)` (806) — wraps a value in a `Paragraph` with XML-escaping. Every cell in
  every table goes through this, which is what prevents an application name containing `&` from
  corrupting the PDF.
- `list_text(values)` (810) — comma-joins a list, returning `"-"` when empty.
- `apply_grid_style(table, header=False)` (816) — applies the standard black grid, optionally
  shading and bolding row 0.
- `add_pair_table(elements, title, rows, styles)` (832) — the two-column label/value table used for
  most sections. Wraps title + table + spacer in `KeepTogether` so a section never splits across a
  page break.
- `make_styles()` (842) — returns the five paragraph styles. Brand colour is `#A80000`.

### Data accessors

`get_hw(data, key, fallback)` (852) and `get_hw_list(data, key)` (938) read from
`data.hardware_details`, handling all three possible runtime types (typed model, dict, or
something else). Every hardware read in the report generator goes through one of these.

### `_parse_size_gb(text)` (line 861)

Parses `"476.94 GB"`, `"931.5G"`, `"201.3M"` into a float number of gigabytes via a regex plus a
unit multiplier table. Returns `0.0` when unparseable — never raises.

### `summarise_storage(data)` (line 884)

The most carefully reasoned function in the file. It totals capacity across physical disks and
splits SSD versus HDD by the `is_ssd` flag. The subtlety is in how it handles disks that did not
report free space:

```python
fg = _parse_size_gb(dd.get("free_space"))
if fg > 0:
    free_gb += fg
    sized_with_free += gb          # only count this disk's capacity

used_gb = max(0.0, sized_with_free - free_gb)
```

Used space is derived only from disks whose free space is actually known, so a disk with
unreadable free space cannot inflate the "used" figure. And the percentage is suppressed entirely
unless every disk reported:

```python
complete = sized_with_free > 0 and abs(sized_with_free - total_gb) < 0.01
pct = int(round(100 * used_gb / sized_with_free)) if complete else None
```

The reasoning, per the inline comment: with partial coverage the percentage would be a share of the
*measured* disks, and reading it against the machine total would be wrong.

`_storage_summary_from_dict(d)` (877) is a shim that wraps a plain dict in a throwaway class so the
same function can serve the `/api/software` path, which works with raw dicts rather than models.

---

## 10. Section 5 — Audit ingestion and report generation

**Lines 947–1462.** `POST /upload-audit` is the largest function in the codebase — roughly 510
lines. It is the heart of the application.

### Step 1 — Parse and validate (lines 952–964)

Two-stage, deliberately forgiving:

```python
raw_json = await request.json()          # hard failure -> 400
try:
    data = AuditData(**raw_json)
except ValidationError as e:
    logger.warning(f"Pydantic validation failed, accepting raw JSON. Errors: {e.errors()}")
    data = AuditData.model_construct(**raw_json)
```

`model_construct` **bypasses validation entirely**. A malformed payload is accepted anyway, with
field types left exactly as they arrived. This is why the report code is so defensive about types
— after this line, `data.hotfixes` may contain anything at all.

Only genuinely unparseable JSON produces an error (400).

### Step 2 — Resolve metadata and paths (lines 965–987)

Pulls branch/officer details from the session record, applies the same hardcoded defaults, and
builds three sibling paths sharing a timestamped stem:

```python
timestamp  = datetime.now().strftime("%Y%m%d_%H%M%S")
clean_name = "".join(x for x in data.computer_name if x.isalnum() or x in "._- ").strip() or "Unknown"

json_path = f"{USER_INFO_DIR}/audit_{cid}_{clean_name}_{timestamp}.json"
pdf_path  = f"{USER_INFO_DIR}/audit_{cid}_{clean_name}_{timestamp}.pdf"
xml_path  = f"{USER_INFO_DIR}/audit_{cid}_{clean_name}_{timestamp}.xml"
```

The `clean_name` filter strips anything that is not alphanumeric or in `._- ` — a path-traversal
guard, since `computer_name` is attacker-controlled.

The raw JSON is written first, before any report generation, so the source data survives even if
PDF or XML building fails.

### Step 3 — PDF generation (lines 991–1318)

Wrapped in one big `try/except` that logs and continues on failure. Builds a `SimpleDocTemplate`
on `letter` pagesize with 54pt margins, then appends flowables in this order:

1. **Title** — "Inspection Report"
2. **User Details** — branch name/code, officer, execution time, consent text
3. **Compliance summary table** — the NSDL-specific grid. Contains the "Not Installed" logic
   (lines 1001–1014) that appends a canned justification when something is missing:
   ```python
   if cd_val == "Not Installed":
       cd_val += " (Reason: Modern laptops/desktops do not include CD drives)"
   ```
   Four such reasons exist — CD drive, printer, antivirus, compression utility. This is business
   logic, not cosmetics: the audit form requires an explanation for each absent item.
4. **Operating System** — name, version, architecture, CS name, licence status
5. **OS Update Details** — hotfix table, six columns, `repeatRows=1` so the header repeats on
   page breaks
6. **MAC Address / Drive Details / Compression Utilities / Antivirus** — four pair tables
7. **Printer Details** — table plus a total count
8. **Hardware — Basic** — CPU, RAM, logical disk
9. **Device Identity** — serial, manufacturer, model
10. **GPU Details**
11. **Physical Network Adapters**
12. **Disk Partitions**
13. **Installed Software Inventory** — the longest table; deliberately **not** wrapped in
    `KeepTogether` (lines 1311–1315) because a several-hundred-row table cannot fit on one page

Every list section follows the same shape: build a header row, loop the data appending rows
(branching on `isinstance` for typed vs dict), or append a single placeholder row when the list is
empty. That repetition is why the function is 500 lines.

### Step 4 — XML generation (lines 1323–1440)

Independent `try/except` — a PDF failure does not prevent XML, and vice versa. Builds an
`ElementTree` rooted at `<NsdlComplianceAudit version="3.0.0">` with this structure:

```
NsdlComplianceAudit
├── UserDetails            (BranchName, BranchCode, OfficerName, ExecutionDateTime, Consent)
├── OperatingSystem        (OSName, OSVersion, OSArchitecture, CSName, LicenseStatus)
├── OSUpdateDetails        (Hotfix*)
├── MacAddress / DriveName / CompressionUtilities / Antivirus
├── PrinterDetails         (Printer*, TotalPrinterConnected)
├── HardwareDetails        (CPU, RAM, Disk, SerialNumber, Manufacturer, Model)
│   ├── GPUList            (GPU*)
│   ├── NetworkAdapters    (Adapter*)
│   ├── DiskPartitions     (Partition*)
│   ├── Peripherals        (Device*)
│   └── ConnectedDevices   (TotalConnected, Device*)
└── SoftwareInventory      (TotalInstalled, Application*)
```

Written with `xml_declaration=True` and UTF-8 encoding.

### Step 5 — Finalise (lines 1442–1462)

```python
if not os.path.exists(pdf_path) or not os.path.exists(xml_path):
    _session_set(cid, {"status": "failed", ..., "error": "Report generation failed."})
    raise HTTPException(status_code=500, detail="Audit report generation failed.")

_session_set(cid, {"status": "completed", ..., "pdf_path": pdf_path, "xml_path": xml_path})
_db_save_audit(cid, data.computer_name, raw_json, json_path, pdf_path, xml_path, audit_time)
return {"status": "success", "pdf_report": pdf_path, "xml_report": xml_path}
```

Success is determined by **checking the files exist on disk**, not by whether the generation blocks
threw. That is the correct check given both blocks swallow their exceptions.

Note the ordering: the session is marked completed *before* `_db_save_audit`. A DB failure at that
point leaves the session usable (reports downloadable) but the audit missing from the device
dashboards.

---

## 11. Section 6 — Report serving

**Lines 1466–1485.** `GET /download-report?client_id=&format=pdf|xml&action=download|view`

Reads the session, requires `status == "completed"`, then serves the stored absolute path via
`FileResponse`. The `action` parameter maps to the `Content-Disposition` type:

```python
disposition = "inline" if action == "view" else "attachment"
```

`inline` lets the browser render the PDF in a tab; `attachment` forces a download.

Because the path stored in the session is absolute, this endpoint breaks if the working directory
or mount point changes between generation and download.

---

## 12. Section 7 — Asset metadata CRUD

**Lines 1488–1605.** Five endpoints, all following the identical dual-track pattern.

| Endpoint | Line | DB operation | File fallback |
|---|---|---|---|
| `POST /asset-metadata` | 1491 | `INSERT … ON CONFLICT DO UPDATE` | write `{device_id}.json` |
| `GET /asset-metadata/{id}` | 1519 | `SELECT data WHERE device_id` | read the file, 404 if absent |
| `PUT /asset-metadata/{id}` | 1539 | same upsert | overwrite the file |
| `DELETE /asset-metadata/{id}` | 1564 | `DELETE … RETURNING device_id` | `os.remove`, 404 if absent |
| `GET /assets` | 1583 | `SELECT data ORDER BY updated_at DESC` | `listdir` + sort by `last_updated` |

Both POST and PUT stamp `last_updated = datetime.now().isoformat()` before writing, and both use
the same upsert — so POST-to-existing and PUT-to-missing both work.

The `DELETE` DB path uses `RETURNING` to distinguish "deleted" from "did not exist", but only
returns success on a hit; a miss silently falls through to the file path, which then 404s.

---

## 13. Section 8 — Device and software queries

**Lines 1608–1765.** The read side of the audit data.

### `GET /api/devices` (line 1611)

Returns the latest audit per device. The DB path uses `DISTINCT ON`, a Postgres-specific feature:

```sql
SELECT DISTINCT ON (computer_name)
    computer_name,
    executed_at                                  AS last_seen,
    audit_json->>'os_name'                       AS os_name,
    audit_json->'hardware_details'->>'public_ip' AS ip,
    audit_json->>'username'                      AS username,
    json_path                                    AS file
FROM audit_results
ORDER BY computer_name, created_at DESC
```

`DISTINCT ON (computer_name)` combined with `ORDER BY computer_name, created_at DESC` keeps exactly
the newest row per machine.

The file fallback (lines 1633–1677) does the same thing by hand: read every `audit_*.json`, keep
the newest per `computer_name`, then extract the IP by walking `network_details[].ip_address`
(splitting on commas, skipping `Unknown` and `0.0.0.0`) and falling back to
`hardware_details.network_adapters[].ipv4_address`. Username is the first non-disabled account.

The two paths do **not** return the same data — see [Known bugs](#21-known-bugs-and-inconsistencies).

### `GET /api/software/{computer_name}` (line 1681)

Fetches the two most recent audits for a device and computes an incremental software diff, tagging
every application with a `change_status`:

```python
if key not in prev_map:
    tagged.append({**app, "change_status": "new", "prev_version": ""})
elif app_version != prev_version:
    tagged.append({**app, "change_status": "updated", "prev_version": prev_map[key].get("version", "")})
else:
    tagged.append({**app, "change_status": "unchanged", "prev_version": ""})
```

Applications present in the previous audit but missing from the latest are appended with
`change_status: "removed"`. The match key is the lowercased, stripped application name.

With only one audit available, everything is tagged `"unchanged"`.

The response is a wide object — beyond `software_inventory` it also returns OS fields, hardware
details, network details, user accounts, login history, hotfixes, antivirus, printers, and a
computed `storage_summary`. It is the single endpoint backing the entire device detail view.

---

## 14. Section 8b — Device diff

**Lines 1768–1870.** `GET /api/device-diff/{computer_name}` — the "change report card".

Same two-audit fetch as above, but returns a summary rather than a tagged list. Three guard
responses come first:

```python
if not audits:      return {"has_diff": False, "scan_count": 0, ...}
if scan_count < 2:  return {"has_diff": False, "scan_count": 1, "message": "Only 1 scan available…"}
```

Then it compares two explicit field lists — five top-level fields (`os_name`, `os_version`,
`architecture`, `license_status`, `antivirus`) and eight inside `hardware_details` (RAM, processor,
manufacturer, model, serial, BIOS version, domain, domain role) — emitting a
`{field, previous, current}` record for each difference. Empty values render as an em dash.

Software changes are computed as pure set difference on lowercased names, producing
`newly_installed` and `newly_removed` lists, plus a `summary` block with the three counts.

---

## 15. Section 9 — Network discovery

**Lines 1873–2221.** `POST /discover/network-scan` — a threaded TCP port scanner with several
layers of name resolution. This is the most performance-tuned code in the file.

### Setup (lines 1878–1893)

```python
network = ipaddress.ip_network(request.ip_range, strict=False)
hosts   = list(network.hosts())
if len(hosts) > 512:
    raise HTTPException(status_code=400, detail="IP range too large. Use /23 or smaller.")

common_ports = [22, 23, 80, 135, 443, 445, 3389, 8080, 8443, 9100]
timeout_secs = max(0.1, min(request.timeout_ms / 1000, 2.0))
```

Ten ports, each labelled in `PORT_LABELS`. Timeout is clamped to 0.1–2.0 seconds.

### `guess_device_type(open_ports)` (line 1895)

A priority-ordered rule chain:

| Condition | Verdict |
|---|---|
| 3389 **and** 445 | Windows Workstation/Server |
| 445 **and** 135 | Windows Host |
| 22 without 80/443 | Linux/Unix Server |
| 23 | Network Device (Router/Switch) |
| 9100 | Network Printer |
| 80 or 443 | Web Service / Network Device |

### Step 1 — Ping sweep (lines 1950–1965)

Fires one ICMP ping at every host across 128 threads. The point is **not** liveness detection — it
is to populate the OS ARP cache so the ARP fallback later can see devices that block all TCP ports.
Platform-branched between `ping -n 1 -w 500` (Windows) and `ping -c 1 -W 1` (Unix).

### Step 2 — Port scan (lines 1974–1980)

Every `(host, port)` pair goes into one flat task list and one wide thread pool:

```python
tasks = [(str(h), p) for h in hosts for p in common_ports]
scan_workers = max(64, min(512, len(tasks)))
```

The inline comment explains why: scanning a host's ports serially meant a dead host cost
`10 ports × timeout` (~10s), and with only 64 workers a /24 needed four sequential waves.

### Step 3 — Reverse DNS, with a real timeout (lines 1982–2007)

Only the hosts that actually answered get resolved. The implementation detail here is subtle and
documented in the source:

```python
# NOTE: no `with` here. ThreadPoolExecutor.__exit__ calls shutdown(wait=True),
# which blocks until every lookup finishes - including a ~9 s one - making
# the timeout below pointless. Shut down without waiting instead.
executor = concurrent.futures.ThreadPoolExecutor(max_workers=min(32, len(live_ips)))
try:
    futures = {executor.submit(_resolve_host, ip): ip for ip in live_ips}
    done, _ = concurrent.futures.wait(futures, timeout=3)
    ...
finally:
    executor.shutdown(wait=False, cancel_futures=True)
```

Using `with` would silently defeat the 3-second cap. This pattern is repeated three times in the
function.

### Step 4 — ARP fallback (lines 2015–2093)

Parses `arp -a` output to find devices that answered the ping but blocked every TCP port —
typically phones and firewalled laptops. Filters out broadcast/network addresses, broadcast MACs,
and anything outside the requested subnet. Device type is then guessed from hostname keywords
(`desktop`/`laptop`/`win` → Windows, `android`/`iphone`/`pixel` → Mobile).

### Step 5 — Name enrichment cascade (lines 2096–2196)

Four sources tried in order of reliability, each tagged in a `name_source` field so the UI can show
provenance:

| Priority | Source | `name_source` | Notes |
|---|---|---|---|
| 0 | ARP table | — | attaches MAC to port-scan results |
| 1 | Previous audits | `audit` | builds an IP→computer_name index from `user_info/*.json`; the real machine name |
| 2 | Reverse DNS | `dns` | already resolved above |
| 3 | NetBIOS | `netbios` | `nbtstat`/`nmblookup`; works with no DNS server present |
| 4 | MAC vendor | `mac-vendor` | renders as e.g. "Apple device" |
| 5 | Randomised MAC | `private-mac` | "Personal device (private MAC)" |
| 6 | Nothing | `unresolved` | falls back to the bare IP |

The rationale, per the comment: most branch LANs have no DNS server holding PTR records, so reverse
DNS alone leaves the hostname column showing bare IPs for most devices.

### Response (lines 2198–2221)

Returns the device list plus subnet arithmetic — `usable_range` (`.1 - .254` for a /24),
`usable_total`, `in_use`, and `free`.

---

## 16. Section 11 — WiFi dashboard

**Lines 2224–2863.** All of this shells out to platform-specific command-line tools and parses
their text output. It only reports on the machine the backend is running on.

### `_run_cmd(cmd)` (line 2237)

`subprocess.run(cmd, capture_output=True, text=True, timeout=20, shell=True)` returning
`(stdout, returncode)`. Never raises — errors come back as the stdout string with rc `-1`.

### `GET /wifi/networks` (line 2246)

Three-way platform branch:

- **Windows** — `netsh wlan show networks mode=bssid`, parsed line-by-line into SSID / auth /
  encryption / signal
- **macOS** — the private `airport` framework binary
- **Linux** — `nmcli -t -f SSID,SECURITY,SIGNAL device wifi list`, with `iwlist` as fallback

The nmcli parsing has a real subtlety — terse mode escapes literal colons as `\:`, so the split
must ignore escaped ones:

```python
parts = re.split(r'(?<!\\):', line)
```

Results are sorted by signal strength descending.

### `GET /wifi/known-networks` (2367) and `DELETE /wifi/known-networks/{ssid}` (2373)

Read and remove entries from the saved-password store.

### `GET /wifi/current` (line 2381)

Returns the active connection plus a derived `/24` subnet:

```python
def _derive_subnet(ip: str):
    parts = ip.split(".")
    return f"{parts[0]}.{parts[1]}.{parts[2]}.0/24" if len(parts) == 4 else None
```

That derived subnet is what `/wifi/scan-devices` scans when no subnet is given. Note the
assumption: it always produces a `/24` regardless of the real netmask.

### `POST /wifi/connect` (line 2475)

On Windows, generating an XML profile in a temp file, importing it with
`netsh wlan add profile`, then `netsh wlan connect`. On Linux, a single
`nmcli device wifi connect "SSID" password "…"`. The temp file is removed in a `finally` block.

Returns `{"status": "connecting"}` rather than waiting for an IP.

### MAC helpers (lines 2617–2665)

`_MAC_VENDORS` is a hand-picked dict of ~40 OUI prefixes covering the vendors that actually appear
on a branch LAN — Apple, Samsung, Dell, HP, Lenovo, printers (Epson, Brother, Canon, Kyocera,
Xerox), network gear (TP-Link, D-Link), and hypervisors (VMware, Hyper-V, VirtualBox, Parallels).
The comment states the tradeoff explicitly: enough coverage without shipping the full 30,000-entry
IEEE registry.

`_mac_is_randomised(mac)` checks bit 1 of the first octet — the locally-administered bit. iOS 14+
and Android 10+ rotate a private random MAC per network, so such a device can never be identified
by vendor. The function exists so the UI can say so explicitly rather than leaving the operator
wondering.

### `_get_netbios_info(ip)` (line 2667)

Runs `nbtstat -a` (Windows, with `CREATE_NO_WINDOW` so no console flashes) or `nmblookup -A`
(Unix), then parses the NetBIOS name table in two passes:

- `<00> UNIQUE` → computer name
- `<03> UNIQUE` → logged-in username, but only when it differs from the computer name

### `GET /wifi/scan-devices` (line 2721)

Composes the two subsystems. It calls `network_scan()` **as a plain Python function**, not over
HTTP:

```python
scan_req    = NetworkScanRequest(ip_range=subnet, timeout_ms=400)
scan_result = network_scan(scan_req)
```

Then builds an IP→audit index (DB first, file supplement) and enriches every discovered device with
`computer_name`, `os_name`, `username`, `last_audit`, and an `audit_status` of `"audited"` or
`"unaudited"`. Unaudited devices get a final concurrent NetBIOS lookup across 20 threads.

This is the endpoint that answers "what is on this network, and which of those have we audited?"

---

## 17. Remote audit trigger

**Lines 2866–3004.** `POST /audit/send-notification` — attempts to start an audit on a remote
machine without anyone touching it.

`NotificationRequest` takes `ip_address`, `username`, `password`, `method` (`auto`/`winrm`/`psexec`),
`target_os`, `server_url`, and `message`.

### Linux/macOS path (lines 2884–2907)

Imports `paramiko` lazily, opens an SSH session with `AutoAddPolicy`, and runs:

```bash
curl -s "SERVER/download-mac-script?client_id=ID" | bash
```

### Windows path (lines 2909–2990)

Builds a PowerShell payload that displays a Windows toast notification, prints a banner, waits on
`Read-Host` for the user to press Enter, then downloads and runs `audit.ps1`. The payload is
UTF-16LE base64-encoded and passed via `-EncodedCommand`:

```python
encoded_cmd = base64.b64encode(ps_payload.encode('utf-16le')).decode('utf-8')
cmd = f'powershell.exe -NoProfile -EncodedCommand {encoded_cmd}'
```

Two transports are tried in order when `method == "auto"`:

1. **WinRM** — `winrm.Session(f'http://{ip}:5985/wsman', transport='ntlm')`
2. **PsExec** — `pypsexec` creates a temporary service, runs the command interactively, then
   removes the service in a `finally` block

All failures are accumulated into a `results` dict and returned together in the final 500.

Both `winrm` and `pypsexec` are imported inside the function with `try/except ImportError`, so the
app starts fine without them and only this endpoint fails.

### `GET /api/get-audit-script` (line 2992)

A near-duplicate of `/download-script`. It differs in one way — it builds the server URL from
`request.url.scheme` + `request.url.netloc` instead of `request.base_url`, and replaces the full
`/upload-audit` URL rather than just the host:

```python
server_url = f"{request.url.scheme}://{request.url.netloc}"
script_content = script_content.replace("http://127.0.0.1:8000/upload-audit", f"{server_url}/upload-audit")
```

It exists because the remote-audit payload needs a URL it can pass to `Invoke-WebRequest -OutFile`.

---

## 18. Section 10 — Frontend serving

**Lines 3007–3017.** The last thing in the file, and the order matters.

```python
SCRIPTS_DIR = os.path.join(BASE_DIR, "scripts")
if os.path.exists(SCRIPTS_DIR):
    app.mount("/scripts", StaticFiles(directory=SCRIPTS_DIR), name="scripts")

FRONTEND_DIR = os.path.join(BASE_DIR, "frontend")
if os.path.exists(FRONTEND_DIR):
    app.mount("/", StaticFiles(directory=FRONTEND_DIR, html=True), name="frontend")
```

The mount at `/` is a catch-all. **It must be registered last** — FastAPI matches routes in
registration order, so mounting it earlier would shadow every API endpoint defined below it. That
is why these ten lines sit at the very bottom of a 3,000-line file.

`html=True` makes `StaticFiles` serve `index.html` for directory requests, so `GET /` returns the
SPA.

---

## 19. End-to-end request lifecycle

The main compliance-audit flow, tracing one run through every layer:

```
1. Operator opens http://server:8000/
   -> StaticFiles serves frontend/index.html                          [line 3016]

2. Operator fills branch details, clicks "Start Compliance Audit"
   -> frontend generates a client_id
   -> GET /download-vbs?client_id=…&branch_name=…                     [line 713]
   -> _session_set(cid, {status: "pending", …})                       [line 222]
      · writes sessions[cid] in memory
      · upserts the sessions table
   -> returns a .vbs file

3. Operator runs the .vbs on the target workstation
   -> powershell -Command "Invoke-RestMethod '…/download-script?client_id=…' | iex"
   -> GET /download-script                                            [line 696]
   -> reads scripts/audit.ps1, substitutes base_url + CLIENT_ID_PLACEHOLDER
   -> PowerShell executes the returned text in memory

4. audit.ps1 collects the system data and POSTs it
   -> POST /upload-audit?client_id=…                                  [line 950]
      a. parse JSON, validate (falling back to model_construct)       [line 958]
      b. read branch metadata from the session                        [line 972]
      c. write user_info/audit_<cid>_<name>_<ts>.json                 [line 984]
      d. build the PDF via ReportLab                                  [line 991]
      e. build the XML via ElementTree                                [line 1323]
      f. verify both files exist                                      [line 1442]
      g. _session_set(cid, {status: "completed", pdf_path, xml_path}) [line 1452]
      h. _db_save_audit(...) -> INSERT INTO audit_results             [line 1457]

5. Meanwhile the frontend polls every 2 seconds
   -> GET /check-status?client_id=…                                   [line 690]
   -> _session_get reads the DB (datetimes -> isoformat)              [line 200]
   -> once status == "completed", the UI reveals the download links

6. Operator downloads
   -> GET /download-report?client_id=…&format=pdf&action=view         [line 1469]
   -> FileResponse over the path stored in the session

7. Later, the device appears in the dashboards
   -> GET /api/devices           -> DISTINCT ON over audit_results    [line 1611]
   -> GET /api/software/{name}   -> latest 2 audits + software diff   [line 1681]
   -> GET /api/device-diff/{name} -> change report card               [line 1771]
```

---

## 20. Cross-cutting patterns

Five conventions recur throughout. Recognising them makes the file much faster to read.

### 1. Dual-track storage

Every persistence operation is written twice — DB first, files as fallback. The shape is always:

```python
if _db_ok():
    try:
        ...postgres...
        return result
    except Exception as e:
        logger.error(f"DB …: {e}")
# file fallback
...filesystem...
```

Falling through is silent by design: a DB outage degrades the app rather than breaking it. The cost
is that the two paths can return subtly different data (see below).

### 2. Never trust the collector

Every field can be missing, null, empty, a wrong type, a bare string where an object was expected,
or a single object where a list was expected. Defences are layered:

- `clean_string()` substitutes `"Unknown"` for anything empty
- `_CleanBase`'s wildcard validator applies it to every field automatically
- `coerce_list` validators wrap bare values into lists
- `Union[Model, dict, str]` types accept all three shapes
- `model_construct` accepts payloads that fail validation outright
- `isinstance` branches everywhere in the report generators

### 3. Report generation never aborts the request

The PDF block and the XML block each have their own `try/except` that logs and continues. Success
is decided afterwards by checking the filesystem. A PDF failure still produces an XML report.

### 4. Threading with real timeouts

Every parallel operation uses `ThreadPoolExecutor` with `concurrent.futures.wait(timeout=…)` and
`shutdown(wait=False, cancel_futures=True)` — never a `with` block, because `__exit__` calls
`shutdown(wait=True)` and silently defeats the timeout. Documented at line 1993.

### 5. Runtime-derived server URL

Scripts are never served with a baked-in address. Every launcher endpoint derives it from the
incoming request (`str(request.base_url)`) and string-substitutes it into the script text, so the
collector always calls back on whatever host the client used.

---

## 21. Known bugs and inconsistencies

Found while reading. None are addressed in the current code.

### `/api/devices` returns different data depending on storage mode

The DB query (line 1618) and the file fallback (line 1633) do not agree:

| Field | DB path | File path |
|---|---|---|
| `ip` | `hardware_details->>'public_ip'` — the **public** IP | walks `network_details[]` — the **LAN** IP |
| `username` | `audit_json->>'username'` — a key `AuditData` never defines, so always `null` | first non-disabled entry in `user_accounts[]` |

So the same device shows a public IP and a blank username with Postgres connected, but a LAN IP and
a real username without it.

### Audit sorting uses lexical comparison on a day-first date string

In both `/api/software` (line 1707) and `/api/device-diff` (line 1801):

```python
audits.sort(key=lambda x: x[0], reverse=True)
```

`executed_at` is a `TEXT` column holding `"%d-%b-%Y_%H:%M:%S"` (e.g. `05-Aug-2026_14:30:00`).
Sorting that lexically is not chronological — `"10-Jan-2025"` sorts after `"05-Aug-2026"`. The
"latest two audits" can therefore be the wrong two, which silently corrupts every diff. The DB
query already orders correctly by `created_at`; this re-sort undoes it.

### Forgetting a WiFi network does not delete it from the database

`DELETE /wifi/known-networks/{ssid}` (line 2373) pops the SSID from the dict and calls
`_save_wifi_passwords()` — but that function only ever `INSERT … ON CONFLICT DO UPDATE`s the
remaining entries (line 2373 → line 303). It never issues a `DELETE`. The row survives, and the
next restart reloads the "forgotten" password. The file fallback rewrites the whole JSON file and
is therefore correct; only the DB path is broken.

### `audit_results` grows without bound

`_db_save_audit` (line 261) is an unconditional `INSERT`. There is no dedup, no upsert, and no
retention policy. At the installer's default `INTERVAL_HOURS=3` that is 8 rows per machine per day,
each holding a full audit JSON — including the complete software inventory.

### `sessions` dict prevents multi-worker deployment

`_session_set` (line 222) writes the module-level dict unconditionally, and `_session_get` (line
200) falls back to it. With more than one uvicorn worker, a status write in worker A is invisible to
worker B's fallback path — so the app must run `--workers 1` unless the DB is guaranteed available.

### Section numbering does not match file order

Section 11 (WiFi, line 2224) precedes section 10 (frontend serving, line 3007). Navigate by line
number.

### Duplicated script-serving logic

`/download-script` (line 696) and `/api/get-audit-script` (line 2992) both serve `audit.ps1` with
substitutions, but derive the server URL differently and substitute different strings. A change to
one will not apply to the other.

### Hardcoded defaults leak into reports

Branch name `"RELIGARE BROKING LIMITED"`, code `"8301231"`, and officer
`"SANDIP BALIRAM LOKHANDE"` are the query-parameter defaults on all three launcher endpoints
(lines 717–719, 756–758, 776–778) and the session-read fallbacks in `/upload-audit` (lines
973–975). An audit that starts without branch details produces a report attributed to that branch.

### Deployment-blocking issues

Not bugs in the logic, but they prevent exposing this beyond a trusted LAN:

- **No authentication on any endpoint.** No `Depends`, no API key, no session check. Every audit —
  serial numbers, MAC addresses, software inventory, login history — is readable by anyone who can
  reach the port.
- **`allow_origins=["*"]` with `allow_credentials=True`** (line 99) is an invalid CORS combination
  that browsers reject.
- **`PG_PASSWORD` has a hardcoded default** in source (line 120).
- **WiFi passwords are stored in plaintext**, in both the DB table and
  `user_info/wifi_passwords.json`.
- **`curl … | bash` and `Invoke-RestMethod | Invoke-Expression`** (lines 731, 767, 787) are the
  primary install path — acceptable on a trusted LAN, a remote-code-execution channel on a public
  URL.
- **`str(request.base_url)`** (line 698) yields `http://` behind a TLS-terminating proxy unless
  uvicorn runs with `--proxy-headers --forwarded-allow-ips="*"`.

---
---

# Part 2 — Windows collector (`scripts/audit.ps1`)

## 22. audit.ps1 — structure and execution model

**1,151 lines. One linear top-to-bottom script.** There is exactly one function in the entire
file — `Get-SafeString` at line 8. Everything else is straight-line statements executed in order.

The script never touches disk. It is fetched over HTTP, piped into `Invoke-Expression`, and runs
entirely in memory:

```
verify_system_<id>.vbs
  └─> powershell -ExecutionPolicy Bypass -WindowStyle Hidden -Command
        "Invoke-RestMethod '<server>/download-script?client_id=<id>' | Invoke-Expression"
             └─> backend substitutes base_url + CLIENT_ID_PLACEHOLDER   [main.py:696]
                  └─> audit.ps1 text executes in the current PowerShell session
```

### The single helper

```powershell
function Get-SafeString {
    param([Parameter(Mandatory=$false)] $Value, [string] $Fallback = "Unknown")
    if ($null -eq $Value) { return $Fallback }
    if ($Value -is [array]) {
        $joined = ($Value | ForEach-Object { [string]$_ }) -join ", "
        if ([string]::IsNullOrWhiteSpace($joined)) { return $Fallback }
        return $joined
    }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $Fallback }
    return $text
}
```

This is the PowerShell twin of the backend's `clean_string()` at [main.py:378](backend/main.py#L378)
— same three rules: null becomes the fallback, arrays are comma-joined, whitespace-only becomes the
fallback. Normalising on **both** sides means the backend never has to trust the collector.

### The universal collector pattern

Every one of the ~20 collection steps has the same three-part shape:

```powershell
$variable = "Unknown"                                   # 1. pre-seed the fallback
try {
    $obj = Get-CimInstance Win32_Something -ErrorAction Stop
    $variable = Get-SafeString $obj.Property "Unknown"   # 2. normalise on assignment
} catch { }                                             # 3. swallow — fallback survives
```

**Consequence: the script cannot crash on a collection failure.** A missing WMI class, a denied
permission, or an absent cmdlet produces `"Unknown"` in that one field and execution continues.
The audit always completes and always uploads.

The trade-off is that a genuine failure is indistinguishable from genuinely absent hardware — both
read `"Unknown"`. See [section 34](#34-what-is-not-verified).

---

## 23. audit.ps1 — the 20 collection steps

| # | Line | What | Source |
|---|---|---|---|
| — | 8 | `Get-SafeString` helper | — |
| — | 24–25 | Execution timestamp, consent text | `Get-Date`, literal |
| 1 | 28 | Computer name | `$env:COMPUTERNAME` |
| 2 | 30 | OS name, version, architecture, service pack, build | `Win32_OperatingSystem` + registry |
| 2b | 68 | Device type | `Win32_SystemEnclosure.ChassisTypes` |
| 3 | 94 | Licence status | `SoftwareLicensingProduct` |
| 4 | 111 | Hotfixes | `Get-HotFix` |
| 5 | 128 | Primary MAC | `Get-NetAdapter` |
| 6 | 137 | CD/DVD drive | `Win32_CDROMDrive` |
| 7 | 147 | Compression utilities | registry scan |
| 8 | 163 | Antivirus | `root\SecurityCenter2` |
| 9 | 173 | Printers | `Win32_Printer` |
| 10 | 207 | CPU / RAM / logical disk | `Win32_Processor`, `Win32_ComputerSystem` |
| 11 | 235 | Network details (IP/gateway/MAC) | `Win32_NetworkAdapterConfiguration` |
| 12 | 248 | User accounts | `Get-LocalUser` |
| 13 | 311 | GPU details | `Win32_VideoController` |
| 14 | 331 | Device identity, memory slots | `Win32_ComputerSystem`, `Win32_PhysicalMemory` |
| 15 | 354 | Location / site / org / public IP | `ip-api.com` HTTP call |
| 16 | 568 | System status, uptime | `Win32_OperatingSystem.LastBootUpTime` |
| 17 | 588 | Network adapters (full, 14 fields) | `Win32_NetworkAdapter` + `...Configuration` |
| — | 657 | Peripherals | `Win32_PnPEntity` |
| — | 694 | All connected devices | `Win32_PnPEntity` across all buses |
| — | 798 | Disk partitions | `Win32_LogicalDisk` |
| — | 841 | Physical disks | `Win32_DiskDrive` + `MSFT_PhysicalDisk` |
| 18 | 916 | **Software inventory** | 3 registry Uninstall keys |
| — | 945 | Software last-used enrichment | Prefetch `.pf` files |
| 19 | 995 | Login history | Security event log 4624 |
| 20 | 1051 | Payload assembly + upload | — |

### Notable steps

**Step 2 — OS build enrichment (lines 43–54).** `Win32_OperatingSystem.Version` returns the kernel
version (`10.0.26200`), which nobody recognises. The script reads the registry for the marketing
name and the update build revision:

```powershell
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$bld = "$($cv.CurrentBuild)"
if ($cv.UBR) { $bld = "$bld.$($cv.UBR)" }
if ($cv.DisplayVersion) { $osBuild = "$($cv.DisplayVersion) (Build $bld)" }
```

Producing `25H2 (Build 26200.8894)` instead of `10.0.26200`.

**Step 2 — service pack (lines 56–64).** Windows 10/11 have no service packs. Rather than leaving
a blank that reads like a collection failure, the script explicitly reports `"None"`.

**Step 2b — device type (lines 68–92).** A three-source cascade:
1. `Win32_SystemEnclosure.ChassisTypes` — a DMI code mapped through a switch (3–7,15,16 = Desktop;
   8–12,14,18,21 = Laptop; 30–32 = Tablet; 17,23,28 = Server; 13 = All-in-One)
2. If still Unknown, `Win32_ComputerSystem.PCSystemType`
3. **Override:** if the model matches `Virtual|VMware|KVM|Hyper-V|VirtualBox|Xen`, report
   `"Virtual Machine"` — more useful than the emulated chassis

**Step 18 — software inventory (lines 916–941).** Scans three registry hives, because 32-bit and
64-bit and per-user installs live in different places:

```powershell
$regPaths = @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
)
$allApps = Get-ItemProperty $regPaths -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -and $_.DisplayName.Trim() -ne "" } |
    Sort-Object DisplayName -Unique
```

Missing `WOW6432Node` is the classic reason a 32-bit app on 64-bit Windows goes unreported. The
`Where-Object` filter drops entries with no `DisplayName` — these are patch and component records,
not user-visible applications.

**Software last-used (lines 945–987).** Windows does not record "last run" per application, so the
script infers it from the **Prefetch directory**. Windows writes `APPNAME-HASH.pf` each time a
binary runs, and the file's `LastWriteTime` is effectively the last-run time:

```powershell
$pfName = $_.BaseName -replace '-[A-F0-9]{8}$', ''   # strip the hash suffix
$prefetchMap[$pfName.ToLower()] = $_.LastWriteTime
```

Matching is fuzzy — both the app name and the prefetch name are stripped to alphanumerics and
compared with `-like` in both directions. If no prefetch entry matches, it falls back to the
`LastWriteTime` of the install directory. The temporary `install_location` field is deleted before
serialisation (line 988) so it never reaches the backend.

**Step 19 — login history (lines 995–1046).** Privilege-aware, with two paths:

```powershell
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent())
             .IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    $events = Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4624} -MaxEvents 200
    ...
}
if ($loginHistory.Count -eq 0) {
    $localUsers = Get-LocalUser | Where-Object { $_.LastLogon -ne $null }   # non-admin fallback
}
```

Event 4624 is "an account was successfully logged on". Each event is converted to XML and filtered
by `LogonType` — only 2 (interactive), 7 (unlock), 10 (RDP), 11 (cached) are kept. Machine and
service accounts are excluded by regex:

```powershell
if ($targetUser -notmatch 'SYSTEM|UMFD|DWM|ANONYMOUS|Font Driver' -and $targetUser -notmatch '\$')
```

The `\$` check drops computer accounts, which always end in `$`. Results are capped at 20 entries.

---

## 24. audit.ps1 — payload assembly and upload

**Lines 1051–1151.**

The `$data` hashtable is built with keys matching the backend's `AuditData` model exactly, then
serialised:

```powershell
$json = $data | ConvertTo-Json -Depth 8
$jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
```

`-Depth 8` matters — the default is 2, which would flatten `hardware_details.disk_details[].name`
into the literal string `System.Collections.Hashtable`.

Upload has **two attempts with different HTTP stacks**:

```powershell
# Attempt 1 — Invoke-RestMethod, explicit 5-minute timeout
try {
    $res = Invoke-RestMethod -Uri $apiUrl -Method POST -Body $jsonBytes `
                             -ContentType "application/json; charset=utf-8" -TimeoutSec 300
    $uploaded = $true
} catch { }

# Attempt 2 — .NET WebClient, no timeout ceiling
if (-not $uploaded) {
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add("Content-Type", "application/json; charset=utf-8")
    $responseBytes = $wc.UploadData($apiUrl, "POST", $jsonBytes)
}
```

The fallback exists because a large software inventory on a slow link can exceed what
`Invoke-RestMethod` tolerates. `WebClient` is lower-level and has no equivalent ceiling.

**Note:** there is no TLS 1.2 enforcement anywhere in this script. Windows PowerShell 5.1 defaults
to TLS 1.0, so both attempts fail against a modern HTTPS endpoint. See
[tools-comp.md](tools-comp.md).

---
---

# Part 3 — macOS/Linux collector (`scripts/audit.sh`)

## 25. audit.sh — structure and the two-language model

**2,186 lines, version 3.1.0.** Structurally similar to `audit.ps1` — linear, top to bottom — but
with one major architectural difference:

> **Bash orchestrates; embedded Python does anything structured.**

Bash handles scalar values, branching, and command availability checks. Every list-shaped
collector (GPUs, adapters, disks, software, users) is a **Python heredoc that prints JSON to
stdout**, captured into a shell variable:

```bash
SOFTWARE_INVENTORY_JSON=$(python3 - <<'PYEOF'
import subprocess, json, os, datetime, shutil
apps = []
...
# Exactly one print — emitting twice produces a malformed payload.
print(json.dumps(apps))
PYEOF
)
```

The reason is straightforward: building a JSON array of 10-field objects in pure bash means manual
quote escaping on every value, and one stray character invalidates the entire payload. Python's
`json.dumps` guarantees correctness.

**The contract every Python collector must honour: print exactly once.** Two `print()` calls stack
two JSON documents into one variable, which is not valid JSON. The comment on line 1849 states
this explicitly, and `json_fragment()` exists to survive it when it happens anyway.

### Three-way platform branching

Nearly every collector branches three ways:

```bash
if [ "$OS_NAME" = "macOS" ]; then
    # sw_vers / sysctl / system_profiler / ioreg
elif [ -f /etc/os-release ]; then
    # /sys, /proc, lspci, lsusb, dpkg/rpm
fi
```

Plus a tool-availability guard before almost every external command:

```bash
if command -v python3 >/dev/null 2>&1; then ...
if command -v curl   >/dev/null 2>&1; then ... elif command -v wget ...
```

---

## 26. audit.sh — the 8 collection phases

| Phase | Line | What |
|---|---|---|
| — | 13 | OS detection — `uname`, `sw_vers`, `/etc/os-release` |
| — | 47 | Device type — `hw.model` (macOS) / DMI `chassis_type` (Linux) |
| — | 82 | MAC address — `ifconfig` or `ip link` |
| — | 93 | Optical drive — `system_profiler` / `/sys/block/sr*` |
| — | 106 | CPU, RAM, disk basics |
| — | 135 | Network details |
| 1–4 | 213+ | Hardware identity, GPU, network adapters, memory |
| — | 1308 | USB peripherals |
| — | 1453 | All connected devices — USB, PCI, display, Bluetooth, serial |
| 5 | 1755 | **Software inventory** |
| 6 | 1853 | Hotfixes / update history |
| 7 | 1925 | Users |
| 8 | 1967 | Payload assembly, validation, upload |

### Notable phases

**Device type (lines 47–80).** Linux reads `/sys/class/dmi/id/chassis_type` — **the same DMI
numbering Windows uses for `ChassisTypes`**, so the switch table is identical across both
collectors. Two overrides follow:

```bash
if [ -f /.dockerenv ] || grep -qaE 'docker|lxc|kubepods' /proc/1/cgroup 2>/dev/null; then
    DEVICE_TYPE="Container"
elif command -v systemd-detect-virt >/dev/null 2>&1; then
    _VIRT=$(systemd-detect-virt 2>/dev/null)
    [ -n "$_VIRT" ] && [ "$_VIRT" != "none" ] && DEVICE_TYPE="Virtual Machine ($_VIRT)"
fi
```

Container detection is more specific than the Windows script, which has no equivalent.

**Optical drive (lines 93–104).** The comment says "actually probed rather than assumed absent" —
Linux enumerates `/sys/block/sr[0-9]*` and reads `device/model`; macOS tries
`system_profiler SPDiscBurningDataType` then `drutil status`.

**Software inventory (lines 1755–1849).** Three package sources, tried in priority order:

- **macOS:** `system_profiler SPApplicationsDataType -json`, last-used from `os.path.getatime()`
  on the `.app` bundle
- **Linux:** `dpkg-query -W --showformat='${Package}|${Version}|${Installed-Size}'`
- **Linux fallback:** `rpm -qa --queryformat '%{NAME}|%{VERSION}|%{SIZE}'`, **only if dpkg
  returned nothing** — the guard is `if not apps:`, so a Debian box never runs rpm

Last-used on Linux uses `shutil.which(pkg_name)` to locate the binary, then `os.path.getatime()`.

**Both platforms slice to `[:150]`.** This is a silent truncation — see
[section 34](#34-what-is-not-verified).

---

## 27. audit.sh — payload assembly and upload

**Lines 1967–2186.** This section contains the most rigorous validation in the entire codebase.

### Step 1 — scalar sanitisation (line 592)

```bash
json_safe() { echo "$1" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | tr -d '\n\r' | tr -d '\t'; }
```

Backslashes first (order matters — escaping quotes first would then double-escape the added
backslashes), then quotes, then all control characters stripped. Applied to every scalar variable.

### Step 2 — per-fragment validation (lines 1974–2000)

Every Python collector's output is individually parsed before it goes near the payload:

```bash
json_fragment() {
    _frag="$1"; _fallback="$2"
    if [ -z "$_frag" ]; then printf '%s' "$_fallback"; return; fi
    _out=$(printf '%s' "$_frag" | python3 -c "
import sys, json
raw = sys.stdin.read()
try:
    sys.stdout.write(json.dumps(json.loads(raw)))
except Exception:
    # A collector that printed more than once leaves several documents stacked up;
    # keep the first parsable one rather than discarding the section entirely.
    for chunk in raw.splitlines():
        ...
")
    if [ -n "$_out" ]; then printf '%s' "$_out"; else printf '%s' "$_fallback"; fi
}
```

Applied to all 12 list fragments, each defaulting to `[]`. The stated purpose:

> If one emits nothing (missing tool, python error) or malformed output, splicing it straight into
> the template yields invalid JSON and the whole audit is lost. Validate each one and substitute a
> safe default so a single failed collector only costs its section.

The multi-document recovery path is the direct fix for a collector that violates the print-once
contract.

### Step 3 — whole-payload validation (lines 2084–2100)

```bash
JSON_ERR=$(printf '%s' "$JSON" | python3 -c "
import sys, json
try:    json.loads(sys.stdin.read())
except Exception as e: sys.stdout.write(str(e))
")
if [ -n "$JSON_ERR" ]; then
    echo "ERROR: Collected data did not form valid JSON — nothing was uploaded."
    printf '%s' "$JSON" > /tmp/audit_payload_invalid.json
    exit 1
fi
```

**This refuses to upload rather than sending something broken**, and preserves the payload for
diagnosis. The comment records a past bug worth noting:

> Never overwrite `$JSON` here — a failed "repair" used to blank it out, which uploaded an empty
> body and surfaced as a confusing HTTP 422 instead of the real problem.

### Step 4 — connectivity pre-flight (lines 2109–2140)

Before uploading, a TCP reachability check with a bash-builtin fallback:

```bash
if command -v nc >/dev/null 2>&1; then
    nc -z -w 5 "$SERVER_HOST" "$SERVER_PORT" 2>/dev/null; NC_RC=$?
elif command -v bash >/dev/null 2>&1; then
    (echo > /dev/tcp/"$SERVER_HOST"/"$SERVER_PORT") 2>/dev/null; NC_RC=$?
fi
```

On failure it prints four numbered diagnostic causes (server not running, firewall, wrong subnet,
verify in browser) rather than a bare connection error.

### Step 5 — upload (lines 2142–2175)

`curl` preferred with `--connect-timeout 10 --max-time 60` and `-w "\n%{http_code}"` to capture the
status; `wget` as fallback with its exit code mapped to 200/500. If neither exists, the script
prints platform-specific install instructions and exits.

`audit.sh` is meaningfully more careful than `audit.ps1` here — it validates before sending,
checks reachability first, and reads the HTTP status. The PowerShell script does none of the three.

---
---

# Part 4 — How data is collected from inside the system

This part answers: *what actually happens on the machine when the audit runs?*

None of this uses privileged kernel access or drivers. Every value comes from a **documented
operating-system interface** that any local user or administrator can query.

## 28. Windows — WMI, registry, event log, prefetch

### WMI / CIM — the primary source

**Windows Management Instrumentation** is the OS's own inventory database. `Get-CimInstance`
queries it over the local WMI service. This supplies the majority of hardware data:

| WMI class | Namespace | Supplies |
|---|---|---|
| `Win32_OperatingSystem` | `root\cimv2` | OS name, version, architecture, service pack, boot time |
| `Win32_ComputerSystem` | `root\cimv2` | Manufacturer, model, domain, domain role, total RAM |
| `Win32_SystemEnclosure` | `root\cimv2` | Chassis type, asset tag, serial |
| `Win32_Processor` | `root\cimv2` | CPU name, cores, type |
| `Win32_PhysicalMemory` | `root\cimv2` | Memory slots, per-module size |
| `Win32_DiskDrive` | `root\cimv2` | Physical disks — model, serial, firmware, size |
| `Win32_DiskPartition` | `root\cimv2` | Partition layout |
| `Win32_LogicalDisk` | `root\cimv2` | Volumes — file system, free space |
| `Win32_VideoController` | `root\cimv2` | GPU name, driver, VRAM |
| `Win32_NetworkAdapter` | `root\cimv2` | NIC hardware |
| `Win32_NetworkAdapterConfiguration` | `root\cimv2` | IP, gateway, DNS, DHCP |
| `Win32_Printer` | `root\cimv2` | Printers |
| `Win32_PnPEntity` | `root\cimv2` | Every plug-and-play device on every bus |
| `Win32_CDROMDrive` | `root\cimv2` | Optical drives |
| `SoftwareLicensingProduct` | `root\cimv2` | Windows activation status |
| `MSFT_PhysicalDisk` | `root\Microsoft\Windows\Storage` | **Authoritative SSD/HDD media type** |
| `AntiVirusProduct` | `root\SecurityCenter2` | Registered AV products |

Note the two non-default namespaces. `root\SecurityCenter2` is where Windows Security Center
registers antivirus products — the only reliable way to enumerate third-party AV. And
`root\Microsoft\Windows\Storage` is the modern storage stack, which is the only source that
reports SSD-versus-HDD authoritatively.

### Relationship traversal

WMI classes are linked by association classes. Getting a physical disk's file system means walking
three hops:

```powershell
$logicalDisks = $d |
    Get-CimAssociatedInstance -ResultClassName Win32_DiskPartition |
    Get-CimAssociatedInstance -ResultClassName Win32_LogicalDisk
```

`Win32_DiskDrive` → `Win32_DiskPartition` → `Win32_LogicalDisk`. The script uses
`Get-CimAssociatedInstance`, which handles the association internally — see
[section 32](#32-hardware-verification-in-detail) for why that matters.

### Registry

Used where WMI has no equivalent:

- `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion` — `DisplayVersion`, `CurrentBuild`, `UBR`
- Three `...\Uninstall\*` hives — the complete software inventory

### Security event log

`Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4624}` reads logon events. **Requires
Administrator.** Each record is converted to XML because the interesting values (`LogonType`,
`TargetUserName`, `TargetDomainName`) live in the structured `EventData` section, not the rendered
message.

### Prefetch directory

`%SystemRoot%\Prefetch\*.pf` — Windows writes one file per executable that has run, and updates its
`LastWriteTime` on each launch. This is the only practical local source for "when was this
application last used".

### External HTTP

One outbound call to `http://ip-api.com/json/` for public IP, city, region, and country — used to
populate `site`, `organization`, and `location`. **This is the only field group that leaves the
machine to be collected.**

---

## 29. Linux — sysfs, procfs, package managers

Linux exposes hardware through the **kernel's virtual filesystems**, which is why most of the
Linux path is `cat` rather than a tool call.

| Path / tool | Supplies |
|---|---|
| `/etc/os-release` | Distribution name, version, pretty name |
| `uname -s -r -m` | Kernel name, release, architecture |
| `/sys/class/dmi/id/*` | **DMI/SMBIOS** — vendor, product name, serial, chassis type, BIOS version and date |
| `/sys/block/*` | Block devices; `sr[0-9]*` are optical drives |
| `/sys/block/*/queue/rotational` | `0` = SSD, `1` = HDD |
| `/proc/cpuinfo` | CPU model, core count |
| `/proc/meminfo` | Total memory |
| `/proc/uptime` | Uptime seconds |
| `/proc/1/cgroup` | Container detection |
| `lspci -k` | PCI devices **and the bound kernel driver** |
| `lsusb` | USB devices |
| `ip` / `ifconfig` | Interfaces, MAC, addresses |
| `nmcli` | NetworkManager connection state |
| `systemd-detect-virt` | Hypervisor identification |
| `dpkg-query` | Debian/Ubuntu packages |
| `rpm -qa` | RHEL/Fedora packages |
| `last` | Login and shutdown history |
| `getent passwd` | User accounts |

`/sys/class/dmi/id/` is the direct Linux equivalent of the WMI hardware classes — both ultimately
read the same SMBIOS tables the firmware publishes. That is why `chassis_type` uses identical
numbering on both platforms.

One detail worth noting from the GPU collector (line 236):

```bash
# Excel field "drivers": lspci -k names the kernel module actually bound to the device
GPU_DRIVER=$(lspci -k 2>/dev/null | awk '/VGA|3D|Display/{f=1} f && /Kernel driver in use/{print $NF; exit}')
```

`lspci -k` reports the driver **actually bound**, not the one that could be — a meaningful
distinction when a proprietary driver is installed but not active.

---

## 30. macOS — system_profiler, sysctl, ioreg

macOS provides a structured JSON inventory natively, which makes it the easiest of the three.

| Tool | Supplies |
|---|---|
| `sw_vers -productVersion / -buildVersion` | OS version and build |
| `sysctl -n hw.model` | Hardware model identifier (`MacBookPro18,3`) |
| `sysctl -n hw.memsize / hw.ncpu` | RAM, CPU count |
| `system_profiler SPHardwareDataType` | Serial, model, chip, memory |
| `system_profiler SPApplicationsDataType -json` | **Full application inventory as JSON** |
| `system_profiler SPDisplaysDataType` | GPU |
| `system_profiler SPUSBDataType` | USB devices |
| `system_profiler SPStorageDataType` | Disks and volumes |
| `system_profiler SPDiscBurningDataType` | Optical drive |
| `ioreg` | IORegistry — device tree |
| `drutil status` | Optical drive fallback |
| `ipconfig getifaddr en0/en1` | Wi-Fi IP |
| `dscl` / `dscacheutil` | Directory Services user accounts |

`system_profiler -json` is the key advantage — the collector can hand the output straight to
`json.loads()` rather than parsing text, which is why the macOS branches are consistently shorter
and less fragile than the Linux ones.

---
---

# Part 5 — How the data is verified

The user-facing question is: *how does the system know the hardware and software it reports is
correct?*

The honest answer has two halves. There **is** a real, layered verification design — five distinct
mechanisms. And there are specific things it deliberately does not check, which matter for a
compliance audit.

## 31. The five verification layers

```
┌─ LAYER 1 ── Pre-seeded fallbacks ─────────────────────────────────┐
│  Every variable = "Unknown" before its try block.                 │
│  Guarantees: a failed collector never crashes, never emits null.  │
├─ LAYER 2 ── Normalisation at the source ──────────────────────────┤
│  Get-SafeString (ps1) / json_safe (sh)                            │
│  Guarantees: no nulls, no empty strings, no stray control chars.  │
├─ LAYER 3 ── Authoritative source + heuristic fallback ────────────┤
│  Query the source that KNOWS; fall back to inference only if it   │
│  is unavailable. (SSD detection, device type, OS build, logins.)  │
├─ LAYER 4 ── Structural validation before transmission ────────────┤
│  json_fragment() per section, then whole-payload json.loads().    │
│  Guarantees: nothing malformed is ever uploaded.                  │
├─ LAYER 5 ── Server-side re-validation ────────────────────────────┤
│  Pydantic AuditData, then model_construct fallback.               │
│  Guarantees: the backend never trusts the collector's types.      │
└───────────────────────────────────────────────────────────────────┘
```

Layers 1, 2, and 3 run on the endpoint. Layer 4 runs just before upload. Layer 5 runs in
[main.py:958](backend/main.py#L958).

**Layer 5 is deliberately permissive.** If Pydantic validation fails, the backend does not reject
the payload — it calls `AuditData.model_construct(**raw_json)`, which bypasses validation entirely
and keeps whatever arrived. The design priority is *never lose an audit*, not *reject bad data*.

---

## 32. Hardware verification in detail

The strongest verification in the codebase is the **authoritative-source-with-fallback** pattern.
Three worked examples.

### SSD versus HDD — the clearest case

The naive approach is to look for "SSD" or "NVMe" in the model name. The script does that only as
a last resort:

```powershell
# MSFT_PhysicalDisk reports MediaType authoritatively (3=HDD, 4=SSD, 5=SCM).
# The old model-name heuristic guessed wrong on drives whose name contains no
# marketing keyword - e.g. "KINGSTON OM8PCP3512F-AA", a real NVMe SSD, was
# reported as "No". Build a serial-keyed lookup and fall back to the heuristic.
$mediaByName = @{}
Get-CimInstance -Namespace root\Microsoft\Windows\Storage -ClassName MSFT_PhysicalDisk |
    ForEach-Object {
        $mt = switch ([int]$_.MediaType) { 3 {"No"} 4 {"Yes"} 5 {"Yes"} default {""} }
        if ($_.FriendlyName) { $mediaByName[$_.FriendlyName.Trim()] = $mt }
    }
```

The OS's own storage stack classification is used first; the regex heuristic runs only when
`MSFT_PhysicalDisk` has no matching entry. The comment records the exact real-world drive that
proved the heuristic wrong.

Linux does the equivalent by reading `/sys/block/*/queue/rotational` — the kernel's own flag,
not an inference.

### Disk file system and free space — a fixed bug worth reading

```powershell
# Walk DiskDrive -> DiskPartition -> LogicalDisk for the file system and free
# space. This previously hand-built "ASSOCIATORS OF" WQL strings and tried to
# escape the device id with -replace '\\\\','\\' — which swaps two backslashes
# for two backslashes, i.e. does nothing. The query matched no partitions on any
# machine, so file_system and free_space were always "Unknown".
# Get-CimAssociatedInstance needs no string escaping at all.
```

This is the most instructive comment in the codebase. The escaping was a **silent no-op**, so the
query matched nothing on every machine, and two required fields were permanently `"Unknown"` —
with no error, no log line, and no failed audit. The audit looked successful the whole time.

It also shows the limit of Layers 1 and 2: a fallback that fires *always* is indistinguishable from
hardware that genuinely has no answer.

The fix removes string handling entirely by using the API that models the relationship directly.
A physical disk carrying multiple volumes is handled explicitly:

```powershell
$fsList = @($logicalDisks | Where-Object { $_.FileSystem } |
            Select-Object -ExpandProperty FileSystem -Unique)
if ($fsList.Count -gt 0) { $fileSystem = ($fsList -join ', ') }
$totalFree = ($logicalDisks | Measure-Object -Property FreeSpace -Sum).Sum
```

### Device type — three sources, ranked

`ChassisTypes` (DMI, firmware-reported) → `PCSystemType` (OS classification) → model-string regex
override for virtual machines. Each is more specific than the last, and the VM override wins
because "Virtual Machine" is more useful to an auditor than the emulated chassis a hypervisor
advertises.

### Server-side cross-checking

`summarise_storage()` at [main.py:884](backend/main.py#L884) is the one place the backend actively
distrusts its input. It refuses to compute a used-percentage unless **every** disk reported free
space:

```python
complete = sized_with_free > 0 and abs(sized_with_free - total_gb) < 0.01
pct = int(round(100 * used_gb / sized_with_free)) if complete else None
```

With partial coverage the percentage would be a share of the measured disks, not of the machine.
Rather than print a misleading number, it prints nothing. **This is verification in the strict
sense: the system detects that its own data is incomplete and declines to draw a conclusion.**

---

## 33. Software verification in detail

### Source selection

Software inventory is not read from a filesystem scan — it comes from **the OS's own package
database**, which is the authoritative record of what is installed:

| Platform | Source | Why authoritative |
|---|---|---|
| Windows | Three registry `Uninstall` hives | What Add/Remove Programs itself displays |
| Debian/Ubuntu | `dpkg-query -W` | The package manager's own database |
| RHEL/Fedora | `rpm -qa` | Same |
| macOS | `system_profiler SPApplicationsDataType` | Apple's own inventory service |

Covering all three Windows hives (`HKLM`, `HKLM\WOW6432Node`, `HKCU`) is itself a correctness
measure — omitting `WOW6432Node` silently hides every 32-bit application on 64-bit Windows.

### Deduplication and filtering

```powershell
Where-Object { $_.DisplayName -and $_.DisplayName.Trim() -ne "" } | Sort-Object DisplayName -Unique
```

Entries with no `DisplayName` are patch and component records rather than user-visible
applications; `-Unique` removes the duplicates that appear when an app registers in more than one
hive.

On Linux, `rpm` runs **only if `dpkg` returned nothing** (`if not apps:`) — so a system with both
tools installed does not double-count.

### Change verification across audits

The strongest software verification is **not** on the endpoint — it is the backend comparing
consecutive audits. `/api/software/{computer_name}` at [main.py:1681](backend/main.py#L1681) tags
every application against the previous scan:

```python
if key not in prev_map:                          tagged: "new"
elif version != prev_map[key].version:           tagged: "updated"
else:                                            tagged: "unchanged"
# present previously, absent now:                tagged: "removed"
```

Matching is on the lowercased, stripped application name. This is what turns a snapshot into
evidence — an unexpected `"new"` entry between two audits is exactly what a compliance review is
looking for.

`/api/device-diff/{computer_name}` at [main.py:1771](backend/main.py#L1771) does the same for
hardware, comparing 13 named fields and reporting `{field, previous, current}` for each change.

### Last-used verification

There is no direct "last run" record on any of the three platforms, so all three infer it —
Windows from Prefetch `.pf` write times, Linux from `os.path.getatime()` on the resolved binary,
macOS from `getatime()` on the `.app` bundle. **All three are inferences, and all three can be
wrong** — `atime` in particular is unreliable on filesystems mounted `noatime` or `relatime`,
which is the default on most modern Linux distributions.

---

## 34. What is NOT verified

Stated plainly, because for a compliance audit these matter.

### 1. There is no proof the data came from the machine it claims

The payload contains `computer_name` as a self-reported string. The only identity is `client_id`
in a query string. Nothing is signed, checksummed, or attested. A hand-crafted POST to
`/upload-audit` produces a genuine-looking PDF report for a machine that does not exist.

### 2. Collection failure is indistinguishable from absent hardware

`"Unknown"` means both "this machine has no such device" and "the query failed". The
`ASSOCIATORS OF` bug is the proof: two required fields read `"Unknown"` on every machine for an
extended period, and nothing in the system flagged it.

### 3. Licence status reports a pass on a collection failure

```powershell
$licenseStatus = "Unknown"
try {
    $sls = Get-CimInstance SoftwareLicensingProduct -ErrorAction Stop | ...
    if ($sls) { $licenseStatus = $statusMap[[int]$sls.LicenseStatus] }
} catch {
    $licenseStatus = "Licensed (WMI Bypass)"        # <-- line 108
}
```

If the WMI query **throws**, the field is set to `"Licensed (WMI Bypass)"`. A failure to determine
licence status is recorded as licensed. On a licence-compliance audit this is the wrong default —
it should report `"Unknown"` and let a human decide.

### 4. Software inventory is silently truncated on macOS and Linux

Both Python collectors slice to `[:150]`:

```python
apps_raw = data.get('SPApplicationsDataType', [])[:150]
for line in r.stdout.strip().split('\n')[:150]:
```

Windows has no such cap. A Linux machine with 900 packages reports 150, and the PDF prints
`Total Applications: 150` with no indication that anything was dropped. **The report reads as
complete when it is not.**

### 5. Login history is capped and privilege-dependent

Capped at 20 entries from the most recent 200 events. Without Administrator, the Security log is
unreadable and the script silently falls back to `Get-LocalUser LastLogon` — a much weaker source.
The report does not record which path produced the data.

### 6. No cross-source reconciliation

RAM from `Win32_ComputerSystem.TotalPhysicalMemory` is never checked against the sum of
`Win32_PhysicalMemory` modules. Disk sizes are not reconciled against partition totals. Each field
has exactly one source and is trusted.

### 7. No transport integrity

Uploads are plain HTTP by default, with no authentication and no TLS enforcement in `audit.ps1`.
Anything on the network path can read or alter an audit payload in flight.

---

### Summary

| Question | Answer |
|---|---|
| Does it use real OS sources? | **Yes** — WMI/CIM, DMI/SMBIOS, package databases, event logs. Not guesswork |
| Does it prefer authoritative sources? | **Yes** — `MSFT_PhysicalDisk` over model-name regex, `rotational` flag over inference |
| Does it validate structure before sending? | **Yes** in `audit.sh` — per-fragment and whole-payload. **No** in `audit.ps1` |
| Does it detect incomplete data? | **Sometimes** — `summarise_storage()` suppresses a percentage it cannot justify |
| Does it verify data is accurate? | **No** — no cross-source reconciliation, no attestation |
| Does it verify data came from the claimed machine? | **No** |
| Does it report collection failures honestly? | **Mostly** — except licence status, which fails to a pass, and truncation, which is silent |

The design goal throughout is clearly **never lose an audit** — every layer degrades rather than
fails. That is the right call for field collection across branch offices with mixed hardware. But
it means the reports carry no signal distinguishing "collected and confirmed" from "attempted and
defaulted", and three specific defects (licence fallback, silent truncation, no attestation) would
be worth fixing before the output is treated as compliance evidence.
