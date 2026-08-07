# =====================================================================
#  NSDL Workstation Compliance Audit - Windows installer
# =====================================================================
#  Run once per PC, as Administrator. Creates a scheduled task that
#  audits this machine every N hours and at every startup.
#
#  Safe to re-run: it replaces the existing task and keeps the same
#  device id, so the machine's audit history is preserved.
#
#  ASCII only on purpose - PowerShell 5.1 reads a BOM-less .ps1 using
#  the ANSI codepage, so any non-ASCII character here would corrupt it.
# =====================================================================

$ErrorActionPreference = 'Stop'

$TaskName   = 'NSDL Compliance Audit'
$InstallDir = Join-Path $env:ProgramData 'NSDLAudit'
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Step  { param($m) Write-Host "  $m" }
function Write-Ok    { param($m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-Warn  { param($m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Fail  { param($m) Write-Host "  [FAIL] $m" -ForegroundColor Red }

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "  NSDL Workstation Compliance Audit - Setup" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------- 1. admin
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Fail "This installer must run as Administrator."
    Write-Host ""
    Write-Host "  Close this window, then RIGHT-CLICK 'Install-Audit.bat'"
    Write-Host "  and choose 'Run as administrator'."
    Write-Host ""
    Read-Host "  Press Enter to exit"
    exit 1
}
Write-Ok "Running as Administrator"

# ---------------------------------------------------------------- 2. config
$configPath = Join-Path $ScriptDir 'config.txt'
if (-not (Test-Path $configPath)) { $configPath = Join-Path (Split-Path -Parent $ScriptDir) 'config.txt' }
if (-not (Test-Path $configPath)) {
    Write-Fail "config.txt not found next to the installer."
    Read-Host "  Press Enter to exit"; exit 1
}

$cfg = @{}
foreach ($line in (Get-Content $configPath)) {
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { continue }
    $i = $t.IndexOf('=')
    if ($i -gt 0) { $cfg[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim() }
}

$serverUrl = $cfg['SERVER_URL']
if (-not $serverUrl) { Write-Fail "SERVER_URL missing from config.txt"; Read-Host "  Press Enter"; exit 1 }
$serverUrl = $serverUrl.TrimEnd('/')

$intervalHours = 3
if ($cfg['INTERVAL_HOURS'] -match '^\d+$') { $intervalHours = [int]$cfg['INTERVAL_HOURS'] }
if ($intervalHours -lt 1 -or $intervalHours -gt 23) {
    Write-Warn "INTERVAL_HOURS must be 1-23, using 3"; $intervalHours = 3
}
$jitter = 300
if ($cfg['JITTER_SECONDS'] -match '^\d+$') { $jitter = [int]$cfg['JITTER_SECONDS'] }

# Testing override: run every N minutes instead of every N hours.
$intervalMinutes = 0
if ($cfg['INTERVAL_MINUTES'] -match '^\d+$') { $intervalMinutes = [int]$cfg['INTERVAL_MINUTES'] }
if ($intervalMinutes -gt 1439) { Write-Warn "INTERVAL_MINUTES must be under 1440, ignoring"; $intervalMinutes = 0 }

if ($intervalMinutes -gt 0) {
    $scheduleDesc = "every $intervalMinutes minute(s)"
    Write-Warn "INTERVAL_MINUTES=$intervalMinutes - testing mode, not for fleet use"
} else {
    $scheduleDesc = "every $intervalHours hour(s)"
}
Write-Ok "Config loaded  (server $serverUrl, $scheduleDesc)"

# ---------------------------------------------------------------- 3. reachability
Write-Step "Testing connection to the audit server..."
try {
    $probe = Invoke-WebRequest -Uri "$serverUrl/api/devices" -TimeoutSec 10 -UseBasicParsing
    Write-Ok "Server reachable (HTTP $($probe.StatusCode))"
} catch {
    Write-Fail "Cannot reach $serverUrl"
    Write-Host ""
    Write-Host "  Check that:"
    Write-Host "    - the audit server is running"
    Write-Host "    - SERVER_URL uses the server's NETWORK ip, not localhost"
    Write-Host "    - this PC is on the same network"
    Write-Host "    - the server firewall allows the port"
    Write-Host ""
    Read-Host "  Press Enter to exit"; exit 1
}

# ---------------------------------------------------------------- 4. install dir
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
Copy-Item $configPath (Join-Path $InstallDir 'config.txt') -Force
Write-Ok "Install folder ready: $InstallDir"

# ---------------------------------------------------------------- 5. device id
# Stable per-machine token. A scheduled task has no browser session, so this
# replaces the per-session client_id and keeps the audit history joined up.
$deviceIdFile = Join-Path $InstallDir 'device.id'
if (Test-Path $deviceIdFile) {
    $deviceId = (Get-Content $deviceIdFile -Raw).Trim()
    Write-Ok "Existing device id reused: $deviceId"
} else {
    $serial = ''
    try { $serial = (Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue).SerialNumber } catch {}
    if (-not $serial -or $serial -match 'To Be Filled|Default|^\s*$') { $serial = [guid]::NewGuid().ToString() }
    $sha  = [Security.Cryptography.SHA1]::Create()
    $hash = ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$env:COMPUTERNAME|$serial")) |
             ForEach-Object { $_.ToString('x2') }) -join ''
    $deviceId = "dev_" + $hash.Substring(0, 12)
    Set-Content -Path $deviceIdFile -Value $deviceId -Encoding ASCII
    Write-Ok "Device id created: $deviceId"
}

# ---------------------------------------------------------------- 6. runner
# Kept tiny on purpose: it only fetches and executes the current audit script,
# so fixing the audit server updates every PC on its next run.
$runnerPath = Join-Path $InstallDir 'run-audit.ps1'
$runner = @'
$ErrorActionPreference = 'Stop'
$dir = Join-Path $env:ProgramData 'NSDLAudit'
$log = Join-Path $dir 'audit.log'

function Log($m) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Add-Content -Path $log -Value $line -Encoding UTF8
    # keep the log from growing without limit
    try {
        if ((Get-Item $log -ErrorAction SilentlyContinue).Length -gt 1MB) {
            $keep = Get-Content $log -Tail 500
            Set-Content -Path $log -Value $keep -Encoding UTF8
        }
    } catch {}
}

try {
    $cfg = @{}
    foreach ($l in (Get-Content (Join-Path $dir 'config.txt'))) {
        $t = $l.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -gt 0) { $cfg[$t.Substring(0,$i).Trim()] = $t.Substring($i+1).Trim() }
    }
    $server   = $cfg['SERVER_URL'].TrimEnd('/')
    $deviceId = (Get-Content (Join-Path $dir 'device.id') -Raw).Trim()

    $jitter = 300
    if ($cfg['JITTER_SECONDS'] -match '^\d+$') { $jitter = [int]$cfg['JITTER_SECONDS'] }
    if ($jitter -gt 0 -and $env:NSDL_NO_JITTER -ne '1') {
        $wait = Get-Random -Minimum 0 -Maximum $jitter
        Log "Waiting $wait s (jitter)"
        Start-Sleep -Seconds $wait
    }

    Log "Audit starting (device $deviceId)"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $script = Invoke-RestMethod -Uri "$server/download-script?client_id=$deviceId" -TimeoutSec 60
    Invoke-Expression $script
    Log "Audit finished"
} catch {
    Log "Audit FAILED: $($_.Exception.Message)"
    exit 1
}
'@
Set-Content -Path $runnerPath -Value $runner -Encoding ASCII
Write-Ok "Runner installed"

# ---------------------------------------------------------------- 7. task
Write-Step "Registering the scheduled task..."

# schtasks reports "task not found" on STDERR and exits non-zero. That is the
# normal case on a first install, but with $ErrorActionPreference = 'Stop' any
# stderr from a native command becomes a terminating NativeCommandError and the
# installer aborts. Relax the preference around these calls and judge success by
# $LASTEXITCODE instead. (Redirecting stderr alone does NOT prevent this.)
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    schtasks /Query /TN "$TaskName" >$null 2>&1
    if ($LASTEXITCODE -eq 0) {
        schtasks /Delete /TN "$TaskName" /F >$null 2>&1
        Write-Step "Removed previous task"
    }
    schtasks /Query /TN "$TaskName (Startup)" >$null 2>&1
    if ($LASTEXITCODE -eq 0) { schtasks /Delete /TN "$TaskName (Startup)" /F >$null 2>&1 }

    $action = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$runnerPath`""

    # Repeating schedule - MINUTE or HOURLY depending on the config
    if ($intervalMinutes -gt 0) {
        schtasks /Create /TN "$TaskName" /SC MINUTE /MO $intervalMinutes /RU SYSTEM /RL HIGHEST /F /TR $action >$null 2>&1
    } else {
        schtasks /Create /TN "$TaskName" /SC HOURLY /MO $intervalHours /RU SYSTEM /RL HIGHEST /F /TR $action >$null 2>&1
    }
    $createRc = $LASTEXITCODE

    # Extra trigger so a PC that was switched off still reports after boot
    schtasks /Create /TN "$TaskName (Startup)" /SC ONSTART /DELAY 0005:00 /RU SYSTEM /RL HIGHEST /F /TR $action >$null 2>&1
    $startupRc = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $prevEAP
}

if ($createRc -ne 0) {
    Write-Fail "Could not create the scheduled task (schtasks exit code $createRc)"
    Write-Host "  Run this window as Administrator and try again."
    Read-Host "  Press Enter to exit"; exit 1
}
if ($startupRc -ne 0) { Write-Warn "Startup trigger not created (repeating schedule still active)" }

Write-Ok "Scheduled: $scheduleDesc, and 5 minutes after every startup"

# ---------------------------------------------------------------- 8. first run
Write-Step "Running the first audit now (may take up to a minute)..."
$env:NSDL_NO_JITTER = '1'
# Same native-command trap as above: anything the audit writes to stderr would
# otherwise abort the installer even though the schedule is already in place.
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runnerPath
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "First audit completed"
    } else {
        Write-Warn "First audit did not complete (exit code $LASTEXITCODE) - the schedule is still active"
        Write-Warn "Check $InstallDir\audit.log"
    }
} catch {
    Write-Warn "First audit did not complete - the schedule is still active"
    Write-Warn "Check $InstallDir\audit.log"
} finally {
    $ErrorActionPreference = $prevEAP
}

# ---------------------------------------------------------------- done
Write-Host ""
Write-Host "=====================================================" -ForegroundColor Green
Write-Host "  SETUP COMPLETE" -ForegroundColor Green
Write-Host "=====================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Computer   : $env:COMPUTERNAME"
Write-Host "  Device id  : $deviceId"
Write-Host "  Server     : $serverUrl"
Write-Host "  Frequency  : $scheduleDesc + at startup"
Write-Host "  Log file   : $InstallDir\audit.log"
Write-Host ""
Write-Host "  This PC will now audit itself automatically."
Write-Host "  Nothing further is needed on this machine."
Write-Host ""
Write-Host "  To remove later: run uninstall-audit.ps1 as Administrator"
Write-Host ""
Read-Host "  Press Enter to close"
