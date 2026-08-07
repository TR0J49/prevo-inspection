# Tools Comparison — Infrapulse vs osquery + Fleet

Researched August 2026. All third-party figures are current as of the dates cited; sources are
listed at the end.

---

## 0. The verdict up front

**osquery + Fleet wins the collection and management layer decisively. Infrapulse wins the
regulatory-reporting and asset-lifecycle layer, which osquery and Fleet simply do not have.**

Neither one wins outright, because **they are not the same kind of product.** The honest answer is
a hybrid: use osquery as the collector, keep Infrapulse's report generator and asset registry as
the layer on top. Details in [section 9](#9-who-wins).

If you are forced to pick one and only one: for an InfraPulse branch-office compliance mandate under
~300 machines, **Infrapulse as it stands is the more direct fit** — because the deliverable is a
prescribed PDF/XML document, and Fleet cannot produce one. For anything larger, or anywhere
security posture matters, **osquery + Fleet**, with the reports rebuilt on top.

---

## 1. These are three different categories

This is the most common mistake in this comparison. Lining them up as competitors is misleading.

| | What it actually is | Analogy |
|---|---|---|
| **osquery** | A **collection agent**. A C++ binary that exposes the OS as SQL tables. It has no server, no UI, no reports. | The sensor |
| **Fleet** | A **fleet manager for osquery**, now also a full MDM. Server + web UI + API. Does not collect anything itself — it orchestrates osquery. | The control plane |
| **Infrapulse** | A **vertical compliance application**. Collector + server + UI + PDF/XML report generator + asset registry, purpose-built for one regulatory format. | The finished product for one use case |

So the real comparison is two separate ones:

- **Infrapulse's collectors** (`audit.ps1`, `audit.sh`) **vs osquery** — a fair fight, and osquery wins
- **Infrapulse's backend** (`backend/main.py`) **vs Fleet** — a fair fight, and Fleet wins on
  everything except reporting
- **Infrapulse's report generator + asset registry vs … nothing.** Fleet has no equivalent.

---

## 2. Current data

| | osquery | Fleet | Infrapulse |
|---|---|---|---|
| **Latest version** | 5.22.1 (27 Feb 2026) | 4.x, continuous releases | 3.0.0 |
| **License** | Apache 2.0 / GPL 2.0 dual | MIT core, some features paid | Proprietary (internal) |
| **Governance** | Linux Foundation | Fleet Device Management Inc. | One developer |
| **GitHub stars** | ~23,400 | ~6,400 | — |
| **Cost** | Free | $0 free tier / **$7 per host per month** Premium / Custom for 700+ hosts | Dev time only |
| **Codebase size** | Large C++ project | Large Go + React project | ~10,020 lines total |
| **Platforms** | Windows, macOS, Linux, FreeBSD | + iOS, iPadOS, Android, ChromeOS | Windows, macOS, Linux |
| **Data tables / fields** | ~277 tables (109 Windows, 183 macOS, 154 Linux; 54 cross-platform) | 350+ categories of system data | ~15 collection areas |
| **Proven scale** | Meta-scale, millions of hosts | Tens of thousands typical; some deployments 400,000+ | Single branch, unproven past ~100 |
| **Infra dependencies** | None (single binary) | MySQL 5.7+ **and** Redis/Valkey **and** TLS cert | Postgres optional — falls back to files |

Fleet's tested database matrix is worth noting for anyone deploying it: MySQL 8.0.44, 8.4.8, and
9.5.0 are supported, **9.6.0 is currently incompatible**; Redis 6.2 and 7 are actively tested.

---

## 3. Data collection — head to head

This is where the gap is widest, and it is not close.

### osquery's advantage

osquery is a compiled C++ agent using proper OS APIs — WMI providers, registry APIs, ETW event
tracing. Infrapulse's collectors are PowerShell and bash scripts that **parse the text output of
command-line tools**. The difference in robustness is structural, not a matter of effort.

The project's own git history shows the cost of this: recent commits include
`Fix disk file_system and free_space collection` and
`Fix cross-platform audit collection gaps and script serving`. Those are exactly the class of bug
that text-parsing collectors generate indefinitely — a tool's output format changes, or a locale
differs, and a field silently goes empty. osquery has absorbed a decade of those fixes already.

### Where Infrapulse actually collects things osquery does not

This cuts the other way more than expected. Checked against the current osquery schema:

| Field Infrapulse collects | osquery coverage | Notes |
|---|---|---|
| **Windows printers** | **Gap.** osquery's `printers` table is CUPS-based — macOS/Linux only | Infrapulse reads Windows printers via WMI. A real hole in osquery for a Windows fleet |
| **CD/DVD drive presence** | Covered — `logical_drives.description` returns `'CD-ROM Disk'` | Not a gap |
| **Compression utilities** | Derivable from `programs` | The *detection logic* is the value, not the raw data |
| **Antivirus product name** | Covered and then some — `windows_security_products` gives name, state, and `signatures_up_to_date` | **osquery is better here** than Infrapulse's list of names |
| **GPU VRAM** | **Gap.** `video_info` has no VRAM column | Infrapulse reads `Win32_VideoController.AdapterRAM` |
| **Disk SSD/HDD flag** | **Gap.** `disk_info` has no media-type column | Drives the SSD/HDD split in every report |
| **Windows licence status** | **Gap.** No activation/licensing table | Required InfraPulse field |
| **User `disabled` / `last_login` / `num_logins`** | **Gap.** `users` is a passwd-style view with no account state | Infrapulse uses `Get-LocalUser` |
| **Login history** | `logged_in_users` is **current sessions only**. Historical logins need `windows_events` with ETW configured | Infrapulse reads the Security event log directly |
| **Warranty / PO / supplier / purchase price** | **None.** Not endpoint telemetry — osquery cannot know it | Entirely Infrapulse's `AssetMetadata` model |
| **Consent text, branch code, officer name** | **None.** Business metadata | Infrapulse-specific |

### Where osquery collects vastly more

Everything else. Processes, open sockets, kernel modules, browser extensions, Python packages,
file hashes, scheduled tasks, services, certificates, firewall state, disk encryption, TPM
status, launch daemons, crontab, sudoers, SSH keys, Chrome extensions, and ~250 more tables.
Infrapulse collects roughly 15 areas; osquery covers 109 tables on Windows alone.

**Net:** osquery wins on breadth by more than an order of magnitude and on reliability
structurally — but it has around seven genuine gaps against Infrapulse's specific requirement
list, of which Windows printers and login history are the notable ones.

A full field-by-field mapping of all ~145 Infrapulse fields against the osquery schema is in
[data-fields-comparison.md](data-fields-comparison.md).

---

## 4. The reporting gap — Infrapulse's real moat

I checked Fleet's visibility and reporting documentation specifically for this. Fleet offers:

- Live compliance checks against CIS benchmarks, SOC 2, ISO
- Automated evidence collection, audit-ready on demand
- Continuous policy evaluation with pass/fail per device
- Export to Splunk, Snowflake, AWS Kinesis, Kafka
- Dashboard widgets and AI-generated descriptions (Premium)

**What Fleet does not offer: PDF export, or fixed-format document generation of any kind.**
The documentation does not mention it because it is not a design goal. Fleet's model is a live
dashboard plus an API — the auditor is expected to look at the screen or query the API.

That is a fundamentally different deliverable from what InfraPulse requires. The InfraPulse mandate is a
**document** — a specific PDF with a specific table layout, a consent clause, branch code, officer
name, and a matching XML in a prescribed schema. Infrapulse's `upload-audit` endpoint produces
exactly that in ~510 lines of ReportLab and ElementTree code.

You cannot get that out of Fleet without writing it yourself. And if you write it yourself, you
have written the most valuable half of Infrapulse again.

**Second moat: asset lifecycle.** Warranty start/end, warranty provider, purchase price, purchase
date, supplier, PO number, vendor, owner, department, status. None of this exists in osquery or
Fleet, because none of it lives on the endpoint. It is procurement data. Fleet is not an ITAM
tool and does not claim to be.

---

## 5. Pros and cons

### osquery

**Pros**
- Free, permissively licensed, Linux Foundation governed — no vendor risk
- ~277 tables; by far the broadest collection available
- Battle-tested at enormous scale; a decade of edge cases already fixed
- Single binary, no server dependencies — deploys anywhere
- SQL interface means new questions need no new code
- Extensible via a documented plugin/extension API
- Releases roughly every two months; active security maintenance

**Cons**
- **Collection only.** No server, no UI, no storage, no reports — you must supply all of that
- Steep learning curve; you must know what to query
- Windows table coverage (109) trails macOS (183)
- Missing Windows printers, CD drive, and historical login data without custom work
- Deploying and configuring the agent across a fleet is itself a project
- Query performance can be a problem on weak hardware if scheduled queries are careless

### Fleet

**Pros**
- The mature control plane for osquery; largest open-source MDM by adoption
- Genuinely capable free tier — inventory, search, policies, multi-platform MDM
- Scales to 400,000+ hosts; horizontal scaling behind a load balancer
- Full MDM: config enforcement, script execution, remediation, app deployment
- Continuous vulnerability scanning and CIS benchmark policies (Premium)
- GitOps workflow, comprehensive REST API and CLI
- Streams to Splunk/Snowflake/Kafka — fits an existing SIEM
- Self-hostable, so data residency is fully controllable

**Cons**
- **$7 per host per month** for Premium — at 500 hosts that is **$42,000/year**; at 2,000 hosts,
  **$168,000/year**
- The features you most want (vuln scanning, CIS benchmarks, conditional access, advanced
  reporting) are **all Premium** — the free tier is inventory and basic policies
- Heavy infrastructure: MySQL **and** Redis **and** TLS, with managed services recommended in
  production. Compare Infrapulse, which runs on a single Python process with Postgres optional
- **No PDF or fixed-format report export**
- No asset lifecycle / procurement data
- Assumes persistently enrolled, network-reachable agents — awkward for a branch PC visited once
- Free tier has no support at all

### Infrapulse

**Pros**
- **Produces the exact InfraPulse PDF and XML deliverable.** Nothing else here does
- Full asset lifecycle registry — warranty, PO, supplier, purchase price
- Trivial deployment: one Python process; Postgres optional with a working file fallback
- Zero licensing cost at any host count
- Purpose-built workflow — USB installer, branch/officer metadata, consent capture, scheduled
  re-audit via Task Scheduler / systemd / launchd
- Collects three things osquery misses on Windows (printers, CD drive, login history)
- Total control; ~10k lines you can change in an afternoon
- Works in a fire-and-forget model — run once, upload, done. No persistent enrollment needed

**Cons**
- **No authentication on any endpoint.** Not a small thing — this is the single largest gap
- Collectors are text-parsing scripts; brittle by construction, and the git history shows it
- Collection breadth is ~15 areas versus osquery's 277 tables
- No vulnerability management, no CVE matching, no CIS benchmarks
- No remediation or configuration enforcement — read-only
- Unproven past ~100 hosts; `sessions` is an in-memory dict, so it needs `--workers 1`
- `audit_results` grows without bound — no dedup, no retention
- Two features (Network Discovery, WiFi Dashboard) require the server on the branch LAN, blocking
  central cloud deployment
- Bus factor of one. A Linux Foundation project this is not
- Known data bugs: DB and file paths return different IPs and usernames; audit sorting is lexical
  on a day-first date string, so "the latest two audits" can be the wrong two

---

## 6. Cost at scale

Fleet Premium is the only line item that scales with host count. Rough five-year totals,
excluding staff time:

| Hosts | Infrapulse | Fleet Free + self-host | Fleet Premium |
|---|---|---|---|
| 100 | ~$3,000 (one VM) | ~$6,000 (VM + MySQL + Redis) | **$42,000** + infra |
| 500 | ~$3,000 | ~$12,000 | **$210,000** + infra |
| 2,000 | ~$6,000 | ~$30,000 | **$840,000** + infra |

The honest counter-argument: **Infrapulse's real cost is engineering time, and it is not in that
table.** One developer maintaining 10,000 lines of collector and server code — chasing the kind of
collection bugs already visible in the git log — plausibly costs more per year than Fleet Premium
at 500 hosts. The build-versus-buy maths only favours building when the thing you are building is
something you cannot buy.

Which, for the InfraPulse report format, it is.

---

## 7. Security posture

Not close, and worth stating plainly.

| | Infrapulse | Fleet |
|---|---|---|
| Authentication | **None on any endpoint** | SSO/SAML, RBAC, teams |
| Transport | HTTP by default | TLS required by design |
| Agent auth | `client_id` in a query string | Enrolment secrets, certificate-based |
| Credential storage | **WiFi passwords in plaintext** (DB and JSON) | Managed secrets |
| Install channel | `curl \| bash` / `irm \| iex` | Signed MSI/PKG installers |
| Audit log | Application log file only | Full activity audit trail |
| Vulnerability data | None | Continuous CVE scanning (Premium) |

Infrapulse's posture is defensible on an isolated branch LAN and indefensible anywhere else. Fleet
was built assuming public exposure from day one.

---

## 8. Scoring

Weighted for an InfraPulse branch-compliance use case. 1–5, higher is better.

| Dimension | Weight | Infrapulse | osquery + Fleet |
|---|---|---|---|
| Produces the required PDF/XML deliverable | High | **5** | 1 |
| Asset lifecycle / procurement data | High | **5** | 1 |
| Collection breadth | High | 2 | **5** |
| Collection reliability | High | 2 | **5** |
| Security posture | High | 1 | **5** |
| Deployment simplicity | Medium | **5** | 2 |
| Cost at 500 hosts | Medium | **5** | 2 (Premium) / 4 (Free) |
| Scale headroom | Medium | 1 | **5** |
| Vulnerability management | Medium | 1 | **5** |
| Remediation / MDM | Medium | 1 | **5** |
| Maintenance burden | Medium | 1 | **4** |
| Offline / one-shot branch workflow | Medium | **5** | 2 |
| Ecosystem and integrations | Low | 1 | **5** |
| **Weighted total** | | **~2.9** | **~3.6** |

osquery + Fleet wins on aggregate. But look at *where* Infrapulse scores 5s: they are the two
rows that define whether the project satisfies its actual mandate. A tool that scores 3.6 overall
and 1 on "produces the required deliverable" does not pass an InfraPulse inspection.

---

## 9. Who wins

### The straight answer

**osquery + Fleet is the better platform. Infrapulse is the better fit for this specific
mandate.** Those are both true and they do not contradict each other.

### The answer I would actually act on: hybrid

Keep the half of Infrapulse that is genuinely differentiated. Replace the half that is a worse
version of something free.

```
KEEP  ── ReportLab PDF generator          (510 lines, no substitute exists)
KEEP  ── XML schema builder               (InfraPulse prescribed format)
KEEP  ── AssetMetadata registry           (warranty, PO, supplier — not endpoint data)
KEEP  ── Branch/officer/consent workflow  (business logic)

SWAP  ── audit.ps1 / audit.sh  ->  osquery agent
         2,186 + 1,151 lines of brittle text parsing, replaced by a maintained C++ binary
         with 277 tables and a decade of edge cases already handled

DROP  ── /discover/network-scan   (Fleet's inventory replaces it, and it blocks cloud deploy)
DROP  ── /wifi/*                  (server-local, Windows-only, not a compliance requirement)
DROP  ── /audit/send-notification (already a stub; Fleet does remote execution properly)

ADD   ── Authentication  (non-negotiable either way)
```

Two ways to wire the collector swap:

**Option A — osquery only, keep the Infrapulse server.** Ship osquery alongside the existing
installer, run a scheduled query pack, POST the JSON to `/upload-audit` in the shape `AuditData`
expects. Cheapest path; no Fleet, no MySQL, no Redis, no per-host cost. You get osquery's
reliability without Fleet's infrastructure. Write custom extensions for the three Windows gaps
(printers, CD drive, login history).

**Option B — full Fleet, Infrapulse becomes a report service.** Fleet owns collection, enrollment,
and dashboards. Infrapulse shrinks to a small service that pulls from Fleet's REST API and renders
the InfraPulse PDF/XML. Right answer above ~1,000 hosts or if vulnerability management becomes a
requirement. Budget for MySQL + Redis + $7/host/month if you want CIS and CVE scanning.

**Start with Option A.** It captures most of the reliability win at a fraction of the cost and
complexity, and it does not foreclose Option B later.

### When each choice is right

| Situation | Choice |
|---|---|
| < 300 PCs, InfraPulse report is the whole deliverable, isolated LANs | **Infrapulse**, plus auth. Ship it |
| Same, but collection bugs are hurting you | **Option A** — osquery collector, Infrapulse server |
| > 1,000 devices, or security posture is now in scope | **Option B** — Fleet + Infrapulse reporting |
| You need CVE scanning, patch compliance, or remediation | **Fleet Premium.** Infrapulse will never do this |
| You need warranty/PO/asset lifecycle tracking | **Infrapulse.** Fleet has no answer at all |
| Budget is zero and hosts number in the thousands | **Fleet Free + Infrapulse reports** |

### The one thing that decides it

If the InfraPulse PDF and XML are contractually required in a prescribed format, no amount of Fleet
capability substitutes for them, and adopting Fleet means rebuilding Infrapulse's report generator
on top of it regardless. **That report generator is the asset. The collectors are the liability.**

Optimise accordingly: keep the reports, replace the collectors, add authentication.

---

## Sources

- [osquery — GitHub](https://github.com/osquery/osquery)
- [osquery — Grokipedia (version history)](https://grokipedia.com/page/Osquery)
- [The Linux Foundation Announces Intent to Form New Foundation to Support osquery Community](https://www.linuxfoundation.org/press/press-release/the-linux-foundation-announces-intent-to-form-new-foundation-to-support-osquery-community)
- [osquery `windows_security_center` table spec](https://github.com/osquery/osquery/blob/master/specs/windows/windows_security_center.table)
- [osquery `windows_security_products` table spec](https://github.com/osquery/osquery/blob/master/specs/windows/windows_security_products.table)
- [Fleet — `printers` table documentation](https://fleetdm.com/tables/printers)
- [Fleet — Pricing](https://fleetdm.com/pricing)
- [Fleet — Visibility and reporting](https://fleetdm.com/visibility-and-reporting)
- [Fleet — Deploying: Introduction](https://fleetdm.com/docs/deploying/introduction)
- [Fleet — Reference architectures](https://fleetdm.com/docs/deploy/reference-architectures)
- [Fleet — CIS Benchmarks guide](https://fleetdm.com/guides/cis-benchmarks)
- [Fleet — Open source MDM](https://fleetdm.com/lp/open-source)
- [Fleet — GitHub](https://github.com/fleetdm/fleet)
- [Top Open Source MDM Solutions in 2026](https://h-mdm.com/top-open-source-mdm-solutions-in-2026/)

Infrapulse figures are from this repository: `backend/main.py` (3,017 lines),
`frontend/index.html` (3,666), `scripts/audit.sh` (2,186), `scripts/audit.ps1` (1,151).
