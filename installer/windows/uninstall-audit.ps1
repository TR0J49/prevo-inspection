# =====================================================================
#  NSDL Workstation Compliance Audit - Windows uninstaller
#  Run as Administrator. Removes the scheduled tasks and all local files.
# =====================================================================

$ErrorActionPreference = 'SilentlyContinue'

$TaskName   = 'NSDL Compliance Audit'
$InstallDir = Join-Path $env:ProgramData 'NSDLAudit'

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "  [FAIL] Must run as Administrator." -ForegroundColor Red
    Read-Host "  Press Enter to exit"; exit 1
}

Write-Host ""
Write-Host "  Removing NSDL Compliance Audit..." -ForegroundColor Cyan

foreach ($t in @($TaskName, "$TaskName (Startup)")) {
    schtasks /Query /TN "$t" >$null 2>&1
    if ($LASTEXITCODE -eq 0) {
        schtasks /Delete /TN "$t" /F >$null 2>&1
        Write-Host "  [OK]   Removed task: $t" -ForegroundColor Green
    }
}

if (Test-Path $InstallDir) {
    # Show the device id first, in case it is needed to tidy server records
    $idFile = Join-Path $InstallDir 'device.id'
    if (Test-Path $idFile) { Write-Host "  Device id was: $((Get-Content $idFile -Raw).Trim())" }
    Remove-Item $InstallDir -Recurse -Force
    Write-Host "  [OK]   Removed $InstallDir" -ForegroundColor Green
}

Write-Host ""
Write-Host "  Uninstall complete. This PC will no longer audit itself." -ForegroundColor Green
Write-Host "  Audits already sent to the server are not affected."
Write-Host ""
Read-Host "  Press Enter to close"
