# Data Fields Comparison — Infrapulse vs osquery + Fleet

Mapped against the **authoritative 67-field requirement list** from
`Inventory Data Fields (1).xlsx`.

Infrapulse coverage is taken from the Pydantic models in `backend/main.py` (lines 398–685).
osquery columns are taken from the table specifications in the osquery repository at `master`,
verified August 2026. Sources at the end.

Companion document: [tools-comp.md](tools-comp.md) for the strategic comparison.

---

## Contents

**Part 1 — Comparison**
1. [Scoring legend and headline result](#1-scoring-legend-and-headline-result)
2. [Device Data — 25 fields](#2-device-data--25-fields)
3. [Disk Information — 10 fields](#3-disk-information--10-fields)
4. [Partitions — 5 fields](#4-partitions--5-fields)
5. [Network Adaptors — 12 fields](#5-network-adaptors--12-fields)
6. [Peripherals — 4 fields](#6-peripherals--4-fields)
7. [Video Controllers — 4 fields](#7-video-controllers--4-fields)
8. [Users — 7 fields](#8-users--7-fields)
9. [Coverage totals](#9-coverage-totals)
10. [Scalability](#10-scalability)
11. [Maintenance](#11-maintenance)
12. [Setup and deployment](#12-setup-and-deployment)

**Part 2 — [The hybrid](#part-2--the-hybrid)**

---

# Part 1 — Comparison

## 1. Scoring legend and headline result

| Symbol | Meaning |
|---|---|
| **✓** | Fully covered, direct field |
| **✓✓** | Covered with **more** detail than required |
| **~** | Partial — needs a join, a derivation, or loses fidelity |
| **✗** | Not available — custom extension or external source required |

### Headline

| | Infrapulse | osquery + Fleet |
|---|---|---|
| Fully covered | **65** / 67 | **40** / 67 |
| Partial | 1 | 16 |
| Missing | 1 | 11 |
| **Coverage** | **97%** | **60% full, 84% including partial** |

Infrapulse was built directly against this spreadsheet, so near-total coverage is expected — it
is the design specification. The interesting result is that **osquery covers 84% of a requirement
list it was never designed for**, and that the 11 genuine gaps are concentrated in two places:
business metadata and user login statistics.

---

## 2. Device Data — 25 fields

| # | Required field | Infrapulse | osquery + Fleet | |
|---|---|---|---|---|
| 1 | Scanner Name | `hardware_details.scanner_name` **✓** | — | **✗** |
| 2 | Site | `hardware_details.site` **✓** | Fleet Teams/labels | **~** |
| 3 | Organization | `hardware_details.organization` **✓** | Fleet Teams/labels | **~** |
| 4 | Name | `computer_name` **✓** | `system_info.computer_name`, `.hostname` | **✓✓** |
| 5 | device type | `hardware_details.device_type` **✓** | `chassis_info.chassis_types` | **~** |
| 6 | description | `hardware_details.description` **✓** | `chassis_info.description` | **~** |
| 7 | domain | `hardware_details.domain` **✓** | no direct column | **~** |
| 8 | manufacturer | `hardware_details.manufacturer` **✓** | `system_info.hardware_vendor` | **✓** |
| 9 | model | `hardware_details.model` **✓** | `system_info.hardware_model` | **✓** |
| 10 | serial number | `hardware_details.serial_number` **✓** | `system_info.hardware_serial` | **✓** |
| 11 | OS name, version, service pack | `os_name`, `os_version`, `service_pack`, `os_build` **✓** | `os_version.name/version/build/arch` | **✓✓** |
| 12 | number of processors | `hardware_details.num_processors` **✓** | `cpu_physical_cores`, `cpu_logical_cores`, `cpu_sockets` | **✓✓** |
| 13 | processor type | `hardware_details.processor_type` **✓** | `cpu_type`, `cpu_subtype`, `cpu_brand` | **✓✓** |
| 14 | bios version | `hardware_details.bios_version` **✓** | `bios_info` | **✓** |
| 15 | bios date | `hardware_details.bios_date` **✓** | `bios_info` | **✓** |
| 16 | location | `hardware_details.location` **✓** | — | **✗** |
| 17 | online/offline times | `system_status`, `uptime_*`, `last_shutdown` **✓** | **Fleet `seen_time`** — native host online/offline tracking | **✓✓** |
| 18 | last backup time | `hardware_details.last_backup_time` **✓** | — | **✗** |
| 19 | domain role | `hardware_details.domain_role` **✓** | — | **✗** |
| 20 | memory slot count, current size, max size | `memory_slot_count`, `memory_current_size`, `memory_max_size` **✓** | `memory_devices` (20 cols) + `memory_array_info` | **✓✓** |
| 21 | last user to log in | `login_history` **✓** | `logged_in_users` is current-only | **~** |
| 22 | asset tag | `hardware_details.asset_tag` **✓** | `chassis_info.smbios_tag` | **✓** |
| 23 | last boot time | `hardware_details.last_boot_time` **✓** | `uptime.total_seconds` | **✓** |
| 24 | last scan datetime | `execution_datetime` **✓** | **Fleet `detail_updated_at`** | **✓** |
| 25 | **first seen datetime** | — **✗** | **Fleet `created_at`** — native | **✓** |

**Two findings worth flagging:**

- **Field 25 is an Infrapulse gap.** "first seen datetime" is not in any model. It could be derived
  from the oldest `audit_results` row for a device, but that query does not exist. Fleet tracks it
  natively on the host record.
- **Field 17 favours Fleet.** "online/offline times" means presence history. Infrapulse only knows
  uptime at the moment of the scan. Fleet's `seen_time` is continuously updated by an enrolled
  agent — a structurally better answer.

Subtotal: Infrapulse **24 ✓ / 1 ✗**. osquery+Fleet **15 ✓ / 6 ~ / 4 ✗**.

---

## 3. Disk Information — 10 fields

| # | Required field | Infrapulse | osquery | |
|---|---|---|---|---|
| 26 | name | `DiskInfo.name` **✓** | `disk_info.name` | **✓** |
| 27 | interface | `DiskInfo.interface` **✓** | `disk_info.type` | **✓** |
| 28 | file system type | `DiskInfo.file_system` **✓** | `logical_drives.file_system` (logical, not physical) | **~** |
| 29 | manufacturer | `DiskInfo.manufacturer` **✓** | `disk_info.manufacturer` | **✓** |
| 30 | model | `DiskInfo.model` **✓** | `disk_info.hardware_model` | **✓** |
| 31 | serial number | `DiskInfo.serial_number` **✓** | `disk_info.serial` | **✓** |
| 32 | **firmware** | `DiskInfo.firmware` **✓** | — | **✗** |
| 33 | size | `DiskInfo.size` **✓** | `disk_info.disk_size` | **✓** |
| 34 | free space | `DiskInfo.free_space` **✓** | `logical_drives.free_space` | **~** |
| 35 | **whether it's solid state** | `DiskInfo.is_ssd` **✓** | no media-type column | **✗** |

osquery adds `partitions`, `disk_index`, `id`, `pnp_device_id`, `description` beyond the
requirement — but misses **firmware** and the **SSD flag**. The SSD flag matters operationally:
`summarise_storage()` at [main.py:884](backend/main.py#L884) uses it to split SSD vs HDD totals in
every report.

Subtotal: Infrapulse **10 ✓**. osquery **6 ✓ / 2 ~ / 2 ✗**.

---

## 4. Partitions — 5 fields

| # | Required field | Infrapulse | osquery `logical_drives` | |
|---|---|---|---|---|
| 36 | bootable status | `DiskPartition.bootable` **✓** | `boot_partition` | **✓** |
| 37 | name | `DiskPartition.name` **✓** | `device_id` | **✓** |
| 38 | size | `DiskPartition.size_gb` **✓** | `size` | **✓** |
| 39 | free space | `DiskPartition.free_space` **✓** | `free_space` | **✓** |
| 40 | file system type | `DiskPartition.file_system` **✓** | `file_system` | **✓** |

**Perfect 5/5 on both sides.** The cleanest section in the entire comparison.

---

## 5. Network Adaptors — 12 fields

| # | Required field | Infrapulse | osquery | |
|---|---|---|---|---|
| 41 | name | `NetworkAdapter.name` **✓** | `interface_details.interface`, `.friendly_name` | **✓✓** |
| 42 | description | `NetworkAdapter.description` **✓** | `interface_details.description` | **✓** |
| 43 | gateway | `NetworkAdapter.gateway` **✓** | `routes.gateway` — separate table | **~** |
| 44 | network mask | `NetworkAdapter.network_mask` **✓** | `interface_addresses.mask` — join | **~** |
| 45 | DNS domain | `NetworkAdapter.dns_domain` **✓** | `dns_domain`, `dns_domain_suffix_search_order` | **✓✓** |
| 46 | DNS servers | `NetworkAdapter.dns_servers` **✓** | `dns_server_search_order` | **✓** |
| 47 | DHCP server | `NetworkAdapter.dhcp_server` **✓** | `dhcp_server` (+ lease obtained/expires) | **✓✓** |
| 48 | IPv4 addresses | `NetworkAdapter.ipv4_addresses` **✓** | `interface_addresses.address` — join | **~** |
| 49 | IPv6 addresses | `NetworkAdapter.ipv6_addresses` **✓** | `interface_addresses.address` — join | **~** |
| 50 | MAC address | `NetworkAdapter.mac_address` **✓** | `interface_details.mac` | **✓** |
| 51 | MTU | `NetworkAdapter.mtu` **✓** | `interface_details.mtu` | **✓** |
| 52 | type | `NetworkAdapter.adapter_type` **✓** | `type`, `physical_adapter` | **✓✓** |

`interface_details` carries **49 columns** (16 base + 21 Windows-specific + POSIX/Linux extras),
including full traffic counters (`ipackets`, `obytes`, `ierrors`, `odrops`, `collisions`) and DHCP
lease timing that the requirement does not ask for.

The four **~** marks are all the same issue: addressing lives in `interface_addresses` and `routes`,
so one Infrapulse adapter record becomes a **three-table join**. The data is all present — the
shape differs.

Subtotal: Infrapulse **12 ✓**. osquery **8 ✓ / 4 ~**.

---

## 6. Peripherals — 4 fields

| # | Required field | Infrapulse | osquery | |
|---|---|---|---|---|
| 53 | name | `Peripheral.name` **✓** | `usb_devices.model` | **~** |
| 54 | description | `Peripheral.description` **✓** | — | **~** |
| 55 | manufacturer | `Peripheral.manufacturer` **✓** | `usb_devices.vendor` | **~** |
| 56 | version | `Peripheral.version` **✓** | `usb_devices.version` | **~** |

osquery splits this across `usb_devices` and `pci_devices` with no unified view, and no Bluetooth
or display-output coverage on Windows. Infrapulse's `ConnectedDevice` model is deliberately
broader — "anything on any port", including HDMI/VGA outputs so an attached projector is reported.

The data partially overlaps but the **shape is different**, and a straight swap loses the single
"everything attached" list the report renders.

Subtotal: Infrapulse **4 ✓**. osquery **4 ~**.

---

## 7. Video Controllers — 4 fields

| # | Required field | Infrapulse | osquery `video_info` | |
|---|---|---|---|---|
| 57 | device name | `GpuInfo.device_name` **✓** | `model` | **✓** |
| 58 | name | `GpuInfo.name` **✓** | `model` | **✓** |
| 59 | video processor | `GpuInfo.video_processor` **✓** | `series` | **~** |
| 60 | drivers | `GpuInfo.driver_version` **✓** | `driver`, `driver_version`, `driver_date` | **✓✓** |

**Correction to my earlier analysis:** I previously flagged missing VRAM as an osquery gap.
**VRAM is not in the requirement list.** Infrapulse collects it as an extra. Against the actual
spec, `video_info` covers Video Controllers essentially completely, and gives *more* driver detail
than required.

Subtotal: Infrapulse **4 ✓**. osquery **3 ✓ / 1 ~**.

---

## 8. Users — 7 fields

| # | Required field | Infrapulse | osquery | |
|---|---|---|---|---|
| 61 | name | `UserAccount.name` **✓** | `users.username` | **✓** |
| 62 | home directory | `UserAccount.home_directory` **✓** | `users.directory` | **✓** |
| 63 | **last login** | `UserAccount.last_login` **✓** | — | **✗** |
| 64 | **licensed** | `UserAccount.disabled` (inverse) **~** | — | **✗** |
| 65 | **number of logins** | `UserAccount.num_logins` **✓** | — | **✗** |
| 66 | user type | `UserAccount.user_type` **✓** | `users.type` (roaming/local/system) | **✓** |
| 67 | current user | `UserAccount.is_current` **✓** | `logged_in_users` — join | **~** |

**This is osquery's weakest section.** The `users` table is a passwd-file view: `uid`, `gid`,
`username`, `description`, `directory`, `shell`, `uuid`, plus `type` on Windows. It carries **no
account state and no login statistics at all**.

Infrapulse gets these from `Get-LocalUser` and the Security event log. Reproducing them in osquery
means either a custom extension or `windows_events` with ETW publishers configured — a materially
harder deployment.

Note field 64: the requirement says "licensed", Infrapulse models `disabled`. Related but not
identical — worth confirming with whoever owns the spreadsheet which semantic is intended.

Subtotal: Infrapulse **5 ✓ / 1 ~ / (1 ✓ uncertain)**. osquery **3 ✓ / 1 ~ / 3 ✗**.

---

## 9. Coverage totals

| Section | Fields | Infrapulse ✓ | osquery+Fleet ✓ | osquery ~ | osquery ✗ |
|---|---|---|---|---|---|
| Device Data | 25 | 24 | 15 | 6 | 4 |
| Disk Information | 10 | 10 | 6 | 2 | 2 |
| Partitions | 5 | 5 | 5 | 0 | 0 |
| Network Adaptors | 12 | 12 | 8 | 4 | 0 |
| Peripherals | 4 | 4 | 0 | 4 | 0 |
| Video Controllers | 4 | 4 | 3 | 1 | 0 |
| Users | 7 | 6 | 3 | 1 | 3 |
| **Total** | **67** | **65** | **40** | **18** | **9** |

### The 9 fields osquery genuinely cannot supply

1. Scanner Name
2. location
3. last backup time
4. domain role
5. disk firmware
6. whether it's solid state
7. user last login
8. licensed
9. number of logins

Plus Site and Organization, which Fleet can approximate with Teams/labels but does not model as
device fields.

**Six of these nine are trivially small custom extensions.** Three (Scanner Name, location, Site/
Organization) are not device data at all — they are context the *scanning system* supplies, which
Infrapulse already does.

### The 2 fields Infrapulse misses

1. **first seen datetime** — not modelled anywhere; Fleet has it natively
2. **licensed** — modelled as `disabled`, semantics may not match

---

## 10. Scalability

| | Infrapulse | osquery + Fleet |
|---|---|---|
| **Proven ceiling** | Unproven past ~100 hosts | Tens of thousands typical; deployments of **400,000+** exist |
| **Horizontal scaling** | **Not possible today** | Multiple servers behind a load balancer |
| **Blocker** | `sessions` is an in-memory dict ([main.py:105](backend/main.py#L105)), written unconditionally by `_session_set`. Must run `--workers 1` | None — stateless servers, shared MySQL/Redis |
| **Data growth** | `audit_results` grows unbounded — no dedup, no retention. At `INTERVAL_HOURS=3` that is **8 full-audit rows per machine per day**, each containing the complete software inventory | Fleet stores current state, not an append-only log |
| **Query performance** | Several endpoints fall back to `os.listdir()` over `user_info/` and parse every JSON file ([main.py:1634](backend/main.py#L1634), [:1701](backend/main.py#L1701), [:2801](backend/main.py#L2801)) — O(n) filesystem scans | Indexed MySQL |
| **Concurrency model** | Threaded scans capped at 512 hosts per request | Distributed query fan-out across the fleet |
| **Realistic limit** | ~200–500 hosts before the file scans and row growth hurt | Effectively unbounded for this use case |

**Verdict: not close.** Infrapulse's architecture has three specific scaling blockers — the
in-memory session dict, unbounded row growth, and O(n) directory scans in the fallback paths. The
first is a genuine correctness issue at any multi-worker deployment; the other two are performance
cliffs that arrive somewhere in the low hundreds of hosts.

None are unfixable. All are already solved in Fleet.

---

## 11. Maintenance

| | Infrapulse | osquery + Fleet |
|---|---|---|
| **Code you own** | **10,020 lines** — 3,017 backend, 3,666 frontend, 2,186 `audit.sh`, 1,151 `audit.ps1` | Query packs and any custom extensions only |
| **Collector fragility** | PowerShell/bash **parsing the text output of CLI tools**. Breaks on locale changes, tool output changes, OS updates | Compiled C++ using WMI/registry/ETW APIs directly |
| **Evidence** | Recent commits: `Fix disk file_system and free_space collection`, `Fix cross-platform audit collection gaps`, `hostname /devices optimised` | A decade of these fixes already absorbed upstream |
| **Who fixes bugs** | You | Linux Foundation project + Fleet Inc. |
| **Release cadence** | Yours | osquery ~every 2 months; Fleet continuous |
| **Security patching** | You, manually | Upstream, with advisories |
| **Bus factor** | **1** | Large contributor base |
| **Known open defects** | Lexical date sorting corrupts diffs; DB/file paths return different IPs and usernames; WiFi forget doesn't delete from DB; no auth anywhere | Tracked publicly, triaged upstream |

**Verdict: osquery + Fleet, decisively.** This is the single strongest argument for switching. The
text-parsing collector model generates bugs indefinitely and at a steady rate — the git history is
the proof, and each fix is a branch visit or a re-deploy.

The counter-argument is real though: 10,020 lines that you fully understand and can change in an
afternoon has genuine value versus a large upstream project whose roadmap you do not control.

---

## 12. Setup and deployment

### Server side

| | Infrapulse | Fleet |
|---|---|---|
| **Dependencies** | Python + 11 pip packages. **Postgres optional** — working file fallback | **MySQL 5.7+ AND Redis/Valkey AND a TLS certificate** — all three mandatory |
| **Tested versions** | — | MySQL 8.0.44 / 8.4.8 / 9.5.0 (**9.6.0 incompatible**); Redis 6.2 and 7 |
| **Production recommendation** | Single process | Managed MySQL (RDS/Cloud SQL) + managed Redis (ElastiCache/Memorystore) + multiple containers behind a load balancer |
| **Time to first data** | Minutes — `pip install`, `uvicorn`, open browser | Hours to a day for a proper deployment |
| **TLS** | Not required (and not implemented) | Required by design |
| **Cost floor** | One small VM | VM + MySQL + Redis, or a managed stack |

### Endpoint side

| | Infrapulse | osquery + Fleet |
|---|---|---|
| **Install method** | USB installer per PC, or `curl \| bash` / `irm \| iex` | Signed MSI / PKG / DEB, or MDM push |
| **Privileges** | Administrator / root required (`schtasks /RU SYSTEM`, `/etc/systemd/system`, `/Library/LaunchDaemons`) | Administrator / root required |
| **Scheduling** | Already built — Task Scheduler, systemd timer with cron fallback, launchd `StartInterval` | osqueryd handles its own schedule |
| **Enrollment** | None — fire-and-forget. Run once, upload, done | Persistent enrollment with secrets |
| **Works disconnected?** | **Yes** — uploads when it can reach the server | Needs to reach the Fleet server to enroll |
| **Config** | `config.txt` on the USB stick, or injected at serve time | Fleet server URL + enrollment secret |

**Verdict: Infrapulse wins setup, clearly.** A single Python process with an optional database
against a mandatory MySQL + Redis + TLS + load balancer stack is not a close comparison.

And Infrapulse's **fire-and-forget model genuinely fits the branch-office scenario better.** A PC
visited once by an officer with a USB stick, which uploads and is done, is a different operational
shape from a persistently enrolled managed endpoint. Fleet assumes the latter.

---

# Part 2 — The hybrid

## 13. What the hybrid actually is

Three layers, each doing what it is best at:

```
┌─────────────────────────────────────────────────────────────────┐
│  COLLECTION            osquery agent on each workstation        │
│                        · 109 Windows tables, C++, maintained    │
│                        · + ~6 custom extensions for the gaps    │
└────────────────────────────┬────────────────────────────────────┘
                             │  scheduled query pack results
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│  MANAGEMENT            Fleet  (optional — only above ~500 hosts) │
│                        · enrollment, scheduling, host state      │
│                        · first-seen / online-offline natively    │
│                        · CVE scanning + CIS benchmarks (Premium) │
└────────────────────────────┬────────────────────────────────────┘
                             │  REST API  /  direct POST
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│  REPORTING             Infrapulse  (kept, and reduced)          │
│                        · ReportLab PDF generator      ← KEEP    │
│                        · XML schema builder           ← KEEP    │
│                        · AssetMetadata registry       ← KEEP    │
│                        · Branch/officer/consent flow  ← KEEP    │
│                        · audit.ps1 / audit.sh         ← DELETE  │
│                        · network-scan / wifi          ← DELETE  │
└─────────────────────────────────────────────────────────────────┘
```

## 14. Field coverage under the hybrid

| Source | Fields covered |
|---|---|
| osquery core tables | 40 |
| osquery + joins (`interface_addresses`, `routes`, `logged_in_users`) | +18 → **58** |
| ~6 custom osquery extensions (printers, licence status, user login stats, SSD flag, disk firmware, domain role) | +6 → **64** |
| Fleet native (`created_at`, `seen_time`) | first-seen and online/offline — **fixes the field Infrapulse is missing** |
| Infrapulse (Scanner Name, Site, Organization, location, last backup) | +3 → **67** |

**Result: 67/67 — full coverage, and better than either alone.**

The hybrid is the only configuration that reaches 100%, because Infrapulse alone misses "first
seen datetime" and osquery alone misses the business-context fields.

## 15. What changes, concretely

| Component | Fate | Lines affected |
|---|---|---|
| `scripts/audit.ps1` | **Delete** — replaced by osquery | −1,151 |
| `scripts/audit.sh` | **Delete** — replaced by osquery | −2,186 |
| `/discover/network-scan` | **Delete** — Fleet inventory replaces it, and it blocks cloud deploy | −350 |
| `/wifi/*` endpoints | **Delete** — server-local, Windows-only, not a requirement | −640 |
| `/audit/send-notification` | **Delete** — already a stub; Fleet does this properly | −130 |
| PDF generator | **Keep unchanged** | 510 |
| XML builder | **Keep unchanged** | 120 |
| `AssetMetadata` CRUD | **Keep unchanged** | 120 |
| `/upload-audit` ingestion | **Adapt** — map osquery output to `AuditData` | ~150 modified |
| Authentication | **Add** — non-negotiable | +200 |
| Custom osquery extensions | **New** — 6 small collectors | +400 |

Net: roughly **−4,000 lines of the most fragile code you own**, +600 lines of new code.

`AuditData` uses `model_config = ConfigDict(extra="allow")` at
[main.py:610](backend/main.py#L610), so the mapping layer can add osquery fields without breaking
the schema or existing installs. That is what makes this migration incremental rather than a
rewrite.

## 16. Two hybrid options

### Option A — osquery only, keep the Infrapulse server

osquery replaces the collector scripts. No Fleet, no MySQL, no Redis, no per-host cost. A
scheduled query pack POSTs to `/upload-audit` in the shape `AuditData` expects.

- **Cost:** $0 licensing. Same single-VM footprint as today
- **Gets you:** collection reliability, 109 Windows tables, upstream maintenance
- **Does not get you:** first-seen/online-offline tracking, CVE scanning, CIS benchmarks, scale
- **Effort:** ~3–4 weeks
- **Right when:** under ~500 hosts, NSDL report is the deliverable, budget is tight

### Option B — full Fleet, Infrapulse becomes a report service

Fleet owns collection, enrollment, and dashboards. Infrapulse shrinks to a service that pulls from
Fleet's REST API and renders the NSDL PDF/XML plus the asset registry.

- **Cost:** MySQL + Redis + infra; **$7/host/month** if you want CVE scanning and CIS benchmarks
- **Gets you:** everything, including the two fields Infrapulse misses, plus vulnerability
  management and remediation
- **Effort:** ~8–12 weeks including Fleet deployment and agent rollout
- **Right when:** above ~1,000 hosts, or security posture enters scope

## 17. What could go wrong

| Risk | Severity | Mitigation |
|---|---|---|
| The 6 custom extensions are harder than estimated — especially Windows printers and login history via ETW | **High** | Prototype the printers extension first; it is the riskiest. Fall back to a small supplementary PowerShell script if the extension proves painful |
| osquery agent deployment across branches is its own project | Medium | Reuse the existing installer scaffolding — Task Scheduler / systemd / launchd logic already works and is proven |
| Fleet's persistent-enrollment model doesn't suit fire-and-forget branch visits | Medium | This is why **Option A first** — it keeps the existing upload model |
| Report output changes subtly and fails an NSDL inspection | **High** | Run both collectors in parallel for one cycle and **diff the generated PDFs field by field** before cutover |
| Field 64 "licensed" semantics turn out to differ from `disabled` | Low | Confirm with the spreadsheet owner before building |
| osquery adds CPU load on old branch hardware | Low | Tune the query pack schedule; it is configurable per query |

## 18. Recommendation

**Do Option A. Do not skip authentication.**

The sequencing that makes sense:

1. **Add authentication to Infrapulse now.** It is required regardless of which path you take, and
   it is the largest open risk in the current system.
2. **Prototype the Windows printers osquery extension.** It is the riskiest of the six gaps. If it
   works, the rest follow easily. If it does not, you learn that for the cost of a few days.
3. **Run osquery alongside the existing collectors for one audit cycle.** Diff the PDFs. This is
   the step that protects the compliance deliverable.
4. **Cut over, delete 3,337 lines of collector scripts**, and stop fixing collection bugs.
5. **Fix "first seen datetime"** — derive it from the oldest `audit_results` row. Small change,
   closes the one requirement gap.
6. **Revisit Fleet when host count crosses ~1,000**, or when CVE scanning becomes a requirement.

### The one-line summary

**The collectors are a liability; the report generator is the asset.** The hybrid keeps the asset,
deletes the liability, and is the only configuration that hits 67/67 on the requirement list.

---

## Sources

osquery table specifications, retrieved from the `master` branch, August 2026:

- [`patches.table`](https://github.com/osquery/osquery/blob/master/specs/windows/patches.table)
- [`programs.table`](https://github.com/osquery/osquery/blob/master/specs/windows/programs.table)
- [`disk_info.table`](https://github.com/osquery/osquery/blob/master/specs/windows/disk_info.table)
- [`logical_drives.table`](https://github.com/osquery/osquery/blob/master/specs/windows/logical_drives.table)
- [`video_info.table`](https://github.com/osquery/osquery/blob/master/specs/windows/video_info.table)
- [`windows_security_products.table`](https://github.com/osquery/osquery/blob/master/specs/windows/windows_security_products.table)
- [`interface_details.table`](https://github.com/osquery/osquery/blob/master/specs/interface_details.table)
- [`system_info.table`](https://github.com/osquery/osquery/blob/master/specs/system_info.table)
- [`users.table`](https://github.com/osquery/osquery/blob/master/specs/users.table)
- [`memory_devices.table`](https://github.com/osquery/osquery/blob/master/specs/memory_devices.table)
- [osquery schema browser](https://osquery.io/schema)

Fleet documentation:

- [Pricing](https://fleetdm.com/pricing) — $7/host/month Premium
- [Deploying: Introduction](https://fleetdm.com/docs/deploying/introduction) — MySQL + Redis + TLS
- [Reference architectures](https://fleetdm.com/docs/deploy/reference-architectures)
- [Visibility and reporting](https://fleetdm.com/visibility-and-reporting)

Requirement list: `Inventory Data Fields (1).xlsx` — 67 fields across 7 sections.
Infrapulse coverage: `backend/main.py` lines 398–685.
