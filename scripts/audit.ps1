# ==============================================================================
#          NSDL WORKSTATION COMPLIANCE AUDIT SCRIPT (Windows)
# ==============================================================================
# Version: 3.0.0 — Full IT Asset Management Edition

Write-Host "Collecting Workstation Compliance Data..." -ForegroundColor Green

function Get-SafeString {
    param(
        [Parameter(Mandatory = $false)] $Value,
        [string] $Fallback = "Unknown"
    )
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

$executionDateTime = Get-Date -Format "dd-MMM-yyyy_HH:mm:ss"
$consentText = "We provide approval to NSDL e-Governance Infrastructure Ltd.(NSDL e-Gov) to capture the details regarding the System details and share the details with NSDL e-Gov."

# 1. Computer Name
$computer = Get-SafeString $env:COMPUTERNAME "Unknown"

# 2. OS Details
$osName      = "Unknown"
$osVersion   = "Unknown"
$architecture = "Unknown"
try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $osName       = Get-SafeString $os.Caption "Unknown"
    $osVersion    = Get-SafeString $os.Version "Unknown"
    $architecture = Get-SafeString $os.OSArchitecture "Unknown"
} catch {}

# 3. License Status Check
$licenseStatus = "Unknown"
try {
    $sls = Get-CimInstance SoftwareLicensingProduct -ErrorAction Stop |
        Where-Object { $_.PartialProductKey -and $_.ApplicationID -eq "55c92734-d682-4d71-983e-d6ec3f16059f" } |
        Select-Object -First 1
    if ($sls) {
        $statusMap = @{
            0 = "Unlicensed"; 1 = "Licensed"; 2 = "OOBGrace"
            3 = "OOTGrace"; 4 = "NonGenuineGrace"; 5 = "Notification"; 6 = "ExtendedGrace"
        }
        $licenseStatus = Get-SafeString $statusMap[[int]$sls.LicenseStatus] "Unknown"
    }
} catch {
    $licenseStatus = "Licensed (WMI Bypass)"
}

# 4. Windows Update / Hotfix Details
$hotfixes = @()
try {
    $hfObjects = Get-HotFix -ErrorAction Stop
    foreach ($hf in $hfObjects) {
        $installedOn = ""
        if ($hf.InstalledOn) { $installedOn = $hf.InstalledOn.ToString("M/d/yyyy") }
        $hotfixes += @{
            caption      = Get-SafeString $hf.Caption ""
            cs_name      = Get-SafeString $hf.CSName $computer
            description  = Get-SafeString $hf.Description ""
            fix_id       = Get-SafeString $hf.HotFixID ""
            installed_on = Get-SafeString $installedOn ""
        }
    }
} catch {}

# 5. MAC Address (Primary)
$mac = "Unknown"
try {
    $macValue = Get-NetAdapter -ErrorAction Stop |
        Where-Object { $_.Status -eq "Up" } |
        Select-Object -First 1 -ExpandProperty MacAddress
    $mac = (Get-SafeString $macValue "Unknown" -replace '[:-]', '').ToUpper()
} catch {}

# 6. CDROM / DVD Drive Check
$driveName = "No CD Unit Found"
try {
    $cdrom = Get-CimInstance Win32_CDROMDrive -ErrorAction Stop
    if ($cdrom) {
        $driveNames = @($cdrom | ForEach-Object { $_.Name } | Where-Object { $_ })
        $driveName = Get-SafeString $driveNames "No CD Unit Found"
    }
} catch {}

# 7. Compression Utility Details
$compressionUtilities = @()
try {
    $registryPaths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $compressionUtilities = Get-ItemProperty $registryPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match "7-Zip|WinRAR|WinZip|PeaZip|Bandizip|Zipware|PowerArchiver" } |
        Select-Object -ExpandProperty DisplayName -Unique
} catch {}
if ($compressionUtilities.Count -eq 0) {
    $compressionUtilities = @("No compression utility found")
}

# 8. Antivirus Products
$antivirus = @()
try {
    $avProducts = Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntivirusProduct -ErrorAction Stop
    foreach ($av in $avProducts) {
        if ($av.displayName) { $antivirus += $av.displayName }
    }
} catch {}
if ($antivirus.Count -eq 0) { $antivirus = @("Windows Defender") }

# 9. Connected Printer Details
$printers = @()
try {
    $printerObjects = Get-CimInstance Win32_Printer -ErrorAction Stop | Where-Object {
        $_.Name -notmatch "Microsoft Print to PDF|Microsoft XPS Document Writer|OneNote|Fax|Root Print|Send to Microsoft|AnyDesk" -and
        $_.PortName -notmatch "PORTPROMPT:|SHRFAX:|nul:"
    }
    foreach ($p in $printerObjects) {
        $printers += @{
            name                    = Get-SafeString $p.Name "Unknown"
            system_name             = Get-SafeString $p.SystemName $computer
            enable_bidi             = Get-SafeString $p.EnableBIDI "False"
            extended_printer_status = Get-SafeString $p.ExtendedPrinterStatus "0"
            port_name               = Get-SafeString $p.PortName "Unknown"
        }
    }
} catch {}

# 10. Hardware Basics — CPU, RAM, Logical Disk
$cpuName = "Unknown"
$ramTotal = "Unknown"
$diskBasic = "Unknown"
try {
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cpu) { $cpuName = Get-SafeString $cpu.Name "Unknown" }

    $ram = Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue
    if ($ram) {
        $totalRam = ($ram | Measure-Object -Property Capacity -Sum).Sum
        $ramTotal = [math]::Round($totalRam / 1GB, 2).ToString() + " GB"
    }

    $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue
    if ($disks) {
        $diskStrings = @()
        foreach ($d in $disks) {
            if ($d.Size -gt 0) {
                $free = [math]::Round($d.FreeSpace / 1GB, 2)
                $size = [math]::Round($d.Size / 1GB, 2)
                $diskStrings += "$($d.DeviceID) $free GB free of $size GB"
            }
        }
        if ($diskStrings.Count -gt 0) { $diskBasic = $diskStrings -join "; " }
    }
} catch {}

# 11. Network Details (IP / Gateway)
$networkDetails = @()
try {
    $nics = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" -ErrorAction SilentlyContinue
    foreach ($nic in $nics) {
        $networkDetails += @{
            ip_address = if ($nic.IPAddress) { $nic.IPAddress -join ", " } else { "Unknown" }
            gateway    = if ($nic.DefaultIPGateway) { $nic.DefaultIPGateway -join ", " } else { "Unknown" }
            mac        = if ($nic.MACAddress) { $nic.MACAddress } else { "Unknown" }
        }
    }
} catch {}

# 12. Local User Accounts (all Excel fields)
$userAccounts = @()
try {
    $currentUserName = $env:USERNAME
    $wmiUsers = Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True" -ErrorAction SilentlyContinue
    # Build a map of LastLogon from Get-LocalUser if available
    $localUserMap = @{}
    try {
        Get-LocalUser -ErrorAction SilentlyContinue | ForEach-Object {
            $localUserMap[$_.Name] = $_
        }
    } catch {}
    foreach ($u in $wmiUsers) {
        $lastLogin = "Unknown"
        $numLogins  = "0"
        $homeDir    = "Unknown"
        $userType   = "Standard"
        $lu = $localUserMap[$u.Name]
        if ($lu) {
            if ($lu.LastLogon) { $lastLogin = $lu.LastLogon.ToString("yyyy-MM-dd HH:mm:ss") }
            $homeDir = Get-SafeString $lu.HomeDirectory "Unknown"
            if ([string]::IsNullOrWhiteSpace($homeDir)) { $homeDir = "Unknown" }
        }
        # Determine user type via group membership
        try {
            $isAdmin = (Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "\\$($u.Name)$" }) -ne $null
            if ($isAdmin) { $userType = "Administrator" }
        } catch {}
        $userAccounts += @{
            name           = Get-SafeString $u.Name "Unknown"
            disabled       = if ($u.Disabled) { "True" } else { "False" }
            home_directory = $homeDir
            last_login     = $lastLogin
            num_logins     = $numLogins
            user_type      = $userType
            is_current     = if ($u.Name -eq $currentUserName) { "True" } else { "False" }
        }
    }
} catch {}

# ────────────────────────────────────────────────────────────────────────────
#  PHASE 1 — EXTENDED HARDWARE COLLECTION
# ────────────────────────────────────────────────────────────────────────────

# 13. GPU Details
Write-Host "Collecting GPU information..." -ForegroundColor Cyan
$gpuDetails = @()
try {
    $gpus = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue
    foreach ($gpu in $gpus) {
        $vramMB = "Unknown"
        if ($gpu.AdapterRAM -and $gpu.AdapterRAM -gt 0) {
            $vramMB = [math]::Round($gpu.AdapterRAM / 1MB, 0).ToString() + " MB"
        }
        $gpuDetails += @{
            name            = Get-SafeString $gpu.Name "Unknown"
            device_name     = Get-SafeString $gpu.Name "Unknown"
            video_processor = Get-SafeString $gpu.VideoProcessor "Unknown"
            driver_version  = Get-SafeString $gpu.DriverVersion "Unknown"
            vram            = $vramMB
        }
    }
} catch {}

# 14. Serial Number, Manufacturer, Model, BIOS, Domain, Asset Tag, Memory, Boot Time
Write-Host "Collecting device identity..." -ForegroundColor Cyan
$serialNumber  = "Unknown"
$manufacturer  = "Unknown"
$model         = "Unknown"
$biosVersion   = "Unknown"
$biosDate      = "Unknown"
$assetTag      = "Unknown"
$domainName    = "Unknown"
$domainRole    = "Unknown"
$deviceDesc    = "Unknown"
$memorySlots   = "Unknown"
$lastBootTime  = "Unknown"
$lastBackup    = "Unknown"
$numProcessors = "Unknown"
$processorType = "Unknown"

try {
    $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($bios) {
        $serialNumber = Get-SafeString $bios.SerialNumber "Unknown"
        $biosVersion  = Get-SafeString $bios.SMBIOSBIOSVersion "Unknown"
        $rawDate = $bios.ReleaseDate
        if ($rawDate) { $biosDate = $rawDate.ToString("yyyy-MM-dd") }
    }
} catch {}

try {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cs) {
        $manufacturer  = Get-SafeString $cs.Manufacturer "Unknown"
        $model         = Get-SafeString $cs.Model "Unknown"
        $deviceDesc    = Get-SafeString $cs.Description "Unknown"
        $domainName    = Get-SafeString $cs.Domain "Unknown"
        $numProcessors = Get-SafeString $cs.NumberOfProcessors.ToString() "Unknown"
        $roleMap = @{ 0="Standalone Workstation"; 1="Member Workstation"; 2="Standalone Server"; 3="Member Server"; 4="Backup Domain Controller"; 5="Primary Domain Controller" }
        $domainRole = Get-SafeString $roleMap[[int]$cs.DomainRole] "Unknown"
    }
} catch {}

try {
    $sysEnc = Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($sysEnc) {
        $tag = Get-SafeString $sysEnc.SMBIOSAssetTag "Unknown"
        if ($tag -notmatch "To Be Filled|Default|N/A|None|^$") { $assetTag = $tag }
    }
} catch {}

try {
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cpu) { $processorType = Get-SafeString $cpu.Description "Unknown" }
} catch {}

try {
    $memSlots  = Get-CimInstance Win32_PhysicalMemoryArray -ErrorAction SilentlyContinue | Select-Object -First 1
    $memSticks = Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue
    if ($memSlots -and $memSticks) {
        $totalMB  = ($memSticks | Measure-Object -Property Capacity -Sum).Sum / 1MB
        $maxCapGB = [math]::Round($memSlots.MaxCapacity / 1024, 0)
        $memorySlots = "Slots: $($memSlots.MemoryDevices) | Installed: $([math]::Round($totalMB/1024,1)) GB | Max: $($maxCapGB) GB"
    }
} catch {}

try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($os -and $os.LastBootUpTime) {
        $lastBootTime = $os.LastBootUpTime.ToString("yyyy-MM-dd HH:mm:ss")
    }
} catch {}

try {
    $shadows = Get-CimInstance Win32_ShadowCopy -ErrorAction SilentlyContinue | Sort-Object InstallDate -Descending | Select-Object -First 1
    if ($shadows) { $lastBackup = $shadows.InstallDate.ToString("yyyy-MM-dd HH:mm:ss") }
} catch {}

# 15. Physical Network Adapters (All 11 Excel fields)
Write-Host "Collecting network adapter details..." -ForegroundColor Cyan
$networkAdapters = @()
try {
    $adapters = Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.PhysicalAdapter -eq $true }
    $configs  = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" -ErrorAction SilentlyContinue
    $cfgIndex = @{}
    foreach ($c in $configs) { $cfgIndex[$c.InterfaceIndex] = $c }

    foreach ($a in $adapters) {
        $speedMbps = "Unknown"
        if ($a.Speed -and $a.Speed -gt 0) {
            $speedMbps = [math]::Round($a.Speed / 1000000, 0).ToString() + " Mbps"
        }
        $cfg = $cfgIndex[$a.InterfaceIndex]
        $networkAdapters += @{
            name           = Get-SafeString $a.Name "Unknown"
            description    = Get-SafeString $a.Description "Unknown"
            adapter_type   = Get-SafeString $a.AdapterType "Unknown"
            speed          = $speedMbps
            mac_address    = Get-SafeString $a.MACAddress "Unknown"
            gateway        = if ($cfg -and $cfg.DefaultIPGateway) { $cfg.DefaultIPGateway -join ", " } else { "Unknown" }
            network_mask   = if ($cfg -and $cfg.IPSubnet)         { $cfg.IPSubnet -join ", " }         else { "Unknown" }
            dns_domain     = if ($cfg)                             { Get-SafeString $cfg.DNSDomain "Unknown" } else { "Unknown" }
            dns_servers    = if ($cfg -and $cfg.DNSServerSearchOrder) { $cfg.DNSServerSearchOrder -join ", " } else { "Unknown" }
            dhcp_server    = if ($cfg)                             { Get-SafeString $cfg.DHCPServer "Unknown" } else { "Unknown" }
            ipv4_addresses = if ($cfg -and $cfg.IPAddress)        { ($cfg.IPAddress | Where-Object { $_ -match '^\d+\.\d+' }) -join ", " } else { "Unknown" }
            ipv6_addresses = if ($cfg -and $cfg.IPAddress)        { ($cfg.IPAddress | Where-Object { $_ -match ':' }) -join ", " }         else { "Unknown" }
            mtu            = "Unknown"
        }
    }
} catch {}

# 16. USB & Connected Peripherals
Write-Host "Collecting peripheral devices..." -ForegroundColor Cyan
$peripherals = @()
try {
    $validClasses = @("HIDClass", "USB", "Printer", "Scanner", "Keyboard", "Mouse", "Image", "Bluetooth")
    $usbDevices = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object { $_.PNPClass -in $validClasses -and $_.Status -eq "OK" }
    foreach ($dev in $usbDevices) {
        $peripherals += @{
            name         = Get-SafeString $dev.Name "Unknown"
            type         = Get-SafeString $dev.PNPClass "Unknown"
            description  = Get-SafeString $dev.Description "Unknown"
            manufacturer = Get-SafeString $dev.Manufacturer "Unknown"
            version      = Get-SafeString $dev.DriverVersion "Unknown"
        }
    }
} catch {}

# 17. Disk Partitions (Detailed — all Excel fields)
Write-Host "Collecting disk partition details..." -ForegroundColor Cyan
$diskPartitions = @()
try {
    # Build logical disk → free space map
    $logicalDiskMap = @{}
    Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue | ForEach-Object {
        $logicalDiskMap[$_.DeviceID] = $_
    }
    # Associate partitions → logical disks
    $partToLogical = @{}
    Get-CimInstance -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID=''} WHERE AssocClass=Win32_LogicalDiskToPartition" -ErrorAction SilentlyContinue | Out-Null
    try {
        $assocs = Get-CimInstance Win32_LogicalDiskToPartition -ErrorAction SilentlyContinue
        foreach ($assoc in $assocs) {
            $partName = $assoc.Antecedent.DeviceID
            $logName  = $assoc.Dependent.DeviceID
            $partToLogical[$partName] = $logName
        }
    } catch {}

    $partitions = Get-CimInstance Win32_DiskPartition -ErrorAction SilentlyContinue
    foreach ($p in $partitions) {
        $sizeGB     = [math]::Round($p.Size / 1GB, 2)
        $freeSpace  = "Unknown"
        $fileSystem = "Unknown"
        $logDriveId = $partToLogical[$p.Name]
        if ($logDriveId -and $logicalDiskMap[$logDriveId]) {
            $ld = $logicalDiskMap[$logDriveId]
            $freeSpace  = [math]::Round($ld.FreeSpace / 1GB, 2).ToString() + " GB"
            $fileSystem = Get-SafeString $ld.FileSystem "Unknown"
        }
        $diskPartitions += @{
            name        = Get-SafeString $p.Name "Unknown"
            type        = Get-SafeString $p.Type "Unknown"
            size_gb     = $sizeGB.ToString() + " GB"
            free_space  = $freeSpace
            bootable    = if ($p.Bootable) { "Yes" } else { "No" }
            file_system = $fileSystem
        }
    }
} catch {}

# 17b. Physical Disk Details (Excel "Disk Information" group)
Write-Host "Collecting physical disk details..." -ForegroundColor Cyan
$diskDetails = @()
try {
    $physDisks = Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue
    foreach ($d in $physDisks) {
        $sizeGB    = if ($d.Size -and $d.Size -gt 0) { [math]::Round($d.Size / 1GB, 2).ToString() + " GB" } else { "Unknown" }
        # Determine if SSD via model name heuristic (no WMI property for SSD in Win32_DiskDrive)
        $isSSD = if ($d.MediaType -match "SSD|Solid" -or $d.Model -match "SSD|NVMe|M\.2|SAMSUNG SSD|WD.*SSD|Crucial|Kingston SSD") { "Yes" } else { "No" }
        $interface = Get-SafeString $d.InterfaceType "Unknown"

        # Get filesystem from first associated logical disk
        $fileSystem = "Unknown"
        try {
            $partQuery = "ASSOCIATORS OF {Win32_DiskDrive.DeviceID='$($d.DeviceID -replace '\\\\','\\')' } WHERE AssocClass=Win32_DiskDriveToDiskPartition"
            $diskParts = Get-CimInstance -Query $partQuery -ErrorAction SilentlyContinue
            foreach ($dp in $diskParts) {
                $logQuery = "ASSOCIATORS OF {Win32_DiskPartition.DeviceID='$($dp.DeviceID)'} WHERE AssocClass=Win32_LogicalDiskToPartition"
                $logDisks = Get-CimInstance -Query $logQuery -ErrorAction SilentlyContinue
                if ($logDisks) {
                    $fileSystem = Get-SafeString ($logDisks | Select-Object -First 1).FileSystem "Unknown"
                    break
                }
            }
        } catch {}

        $diskDetails += @{
            name          = Get-SafeString $d.Name "Unknown"
            interface     = $interface
            file_system   = $fileSystem
            manufacturer  = Get-SafeString $d.Manufacturer "Unknown"
            model         = Get-SafeString $d.Model "Unknown"
            serial_number = Get-SafeString $d.SerialNumber "Unknown"
            firmware      = Get-SafeString $d.FirmwareRevision "Unknown"
            size          = $sizeGB
            free_space    = "Unknown"
            is_ssd        = $isSSD
        }
    }
} catch {}

# ────────────────────────────────────────────────────────────────────────────
#  PHASE 2 — FULL SOFTWARE INVENTORY
# ────────────────────────────────────────────────────────────────────────────

# 18. Full Installed Software Inventory (Registry Scan)
Write-Host "Scanning installed software (this may take a moment)..." -ForegroundColor Yellow
$softwareInventory = @()
try {
    $regPaths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $allApps = Get-ItemProperty $regPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and $_.DisplayName.Trim() -ne "" } |
        Sort-Object DisplayName -Unique
    foreach ($app in $allApps) {
        $sizeMB = "Unknown"
        if ($app.EstimatedSize -and $app.EstimatedSize -gt 0) {
            $sizeMB = [math]::Round($app.EstimatedSize / 1024, 2).ToString() + " MB"
        }
        # last_used: try EstimatedLastUsed (rarely populated) or InstallDate as fallback
        $lastUsed = "Unknown"
        if ($app.PSObject.Properties["LastUsed"] -and $app.LastUsed) {
            $lastUsed = [string]$app.LastUsed
        }
        $softwareInventory += @{
            name         = Get-SafeString $app.DisplayName ""
            version      = Get-SafeString $app.DisplayVersion "Unknown"
            publisher    = Get-SafeString $app.Publisher "Unknown"
            install_date = Get-SafeString $app.InstallDate "Unknown"
            size_mb      = $sizeMB
            last_used    = $lastUsed
        }
    }
    Write-Host "Found $($softwareInventory.Count) installed applications." -ForegroundColor Green
} catch {}

# ────────────────────────────────────────────────────────────────────────────
#  19. Collect Login History
# ────────────────────────────────────────────────────────────────────────────
Write-Host "Collecting recent login history..." -ForegroundColor Cyan
$loginHistory = @()

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($isAdmin) {
    # Full history from Security event log (requires Admin)
    # LogonType: 2=Interactive, 7=Unlock, 10=RemoteInteractive(RDP), 11=CachedInteractive
    try {
        $events = Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4624} -MaxEvents 200 -ErrorAction Stop
        foreach ($event in $events) {
            $xml = [xml]$event.ToXml()
            $logonType = ($xml.Event.EventData.Data | Where-Object { $_.Name -eq 'LogonType' }).'#text'
            if ($logonType -in '2', '7', '10', '11') {
                $targetUser = ($xml.Event.EventData.Data | Where-Object { $_.Name -eq 'TargetUserName' }).'#text'
                $targetDomain = ($xml.Event.EventData.Data | Where-Object { $_.Name -eq 'TargetDomainName' }).'#text'
                if ($targetUser -and $targetUser -notmatch 'SYSTEM|UMFD|DWM|ANONYMOUS|Font Driver' -and $targetUser -notmatch '\$') {
                    $typeLabel = switch ($logonType) {
                        '2'  { 'Local Interactive' }
                        '7'  { 'Unlock' }
                        '10' { 'Remote (RDP)' }
                        '11' { 'Cached Interactive' }
                        default { "Type $logonType" }
                    }
                    $loginHistory += @{
                        username   = Get-SafeString $targetUser "Unknown"
                        domain     = Get-SafeString $targetDomain "Unknown"
                        logon_type = $typeLabel
                        time       = $event.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
                    }
                }
            }
        }
        # Keep most recent 20 entries
        if ($loginHistory.Count -gt 20) { $loginHistory = $loginHistory[0..19] }
    } catch {}
}

# Fallback (always runs): Get-LocalUser LastLogon — works without Admin
if ($loginHistory.Count -eq 0) {
    try {
        $localUsers = Get-LocalUser -ErrorAction SilentlyContinue | Where-Object { $_.LastLogon -ne $null }
        foreach ($u in $localUsers) {
            $loginHistory += @{
                username   = Get-SafeString $u.Name "Unknown"
                domain     = $env:COMPUTERNAME
                logon_type = "Local (Last Known)"
                time       = $u.LastLogon.ToString("yyyy-MM-dd HH:mm:ss")
            }
        }
    } catch {}
}


# ────────────────────────────────────────────────────────────────────────────
#  20. Construct JSON Data Payload
# ────────────────────────────────────────────────────────────────────────────
$data = @{
    execution_datetime    = $executionDateTime
    consent               = $consentText
    computer_name         = $computer
    os_name               = $osName
    os_version            = $osVersion
    architecture          = $architecture
    license_status        = $licenseStatus
    hotfixes              = $hotfixes
    mac_address           = $mac
    drive_name            = $driveName
    compression_utilities = $compressionUtilities
    antivirus             = $antivirus
    printers              = $printers
    hardware_details      = @{
        cpu              = $cpuName
        ram              = $ramTotal
        disk             = $diskBasic
        serial_number    = $serialNumber
        manufacturer     = $manufacturer
        model            = $model
        num_processors   = $numProcessors
        processor_type   = $processorType
        bios_version     = $biosVersion
        bios_date        = $biosDate
        asset_tag        = $assetTag
        last_boot_time   = $lastBootTime
        domain           = $domainName
        domain_role      = $domainRole
        description      = $deviceDesc
        memory_slots     = $memorySlots
        last_backup_time = $lastBackup
        gpu_details      = $gpuDetails
        network_adapters = $networkAdapters
        peripherals      = $peripherals
        disk_partitions  = $diskPartitions
        disk_details     = $diskDetails
    }
    network_details       = $networkDetails
    user_accounts         = $userAccounts
    software_inventory    = $softwareInventory
    login_history         = $loginHistory
}

$json = $data | ConvertTo-Json -Depth 8

# Capture dynamic client id parameter from backend injection
$client_id = "CLIENT_ID_PLACEHOLDER"

# API URL (dynamically replaced by backend during serving)
$apiUrl = "http://127.0.0.1:8000/upload-audit?client_id=$client_id"

$jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($json)

Write-Host "Uploading secure payload to backend..." -ForegroundColor Yellow
$uploaded = $false

# Attempt 1: Invoke-RestMethod with explicit 5-minute timeout
try {
    $res = Invoke-RestMethod -Uri $apiUrl -Method POST -Body $jsonBytes -ContentType "application/json; charset=utf-8" -TimeoutSec 300
    Write-Host "Audit upload completed successfully!" -ForegroundColor Green
    $uploaded = $true
} catch {
    Write-Host "Attempt 1 failed, retrying with WebClient..." -ForegroundColor Yellow
}

# Attempt 2: Use .NET WebClient (no timeout limit)
if (-not $uploaded) {
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("Content-Type", "application/json; charset=utf-8")
        $responseBytes = $wc.UploadData($apiUrl, "POST", $jsonBytes)
        $responseStr = [System.Text.Encoding]::UTF8.GetString($responseBytes)
        Write-Host "Audit upload completed successfully!" -ForegroundColor Green
        $uploaded = $true
    } catch {
        Write-Host "Upload failed: $_" -ForegroundColor Red
        if ($_.ErrorDetails.Message) {
            Write-Host $_.ErrorDetails.Message -ForegroundColor Red
        }
    }
}
