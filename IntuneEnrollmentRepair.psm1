#Requires -RunAsAdministrator
<#
.SYNOPSIS  IntuneEnrollmentRepair - Diagnose and repair Intune enrollment failures.
.NOTES
    Version : 1.0.8
    Requires: PowerShell 5.1+, Run as Administrator
    Supports: Entra-joined, HAADJ, MAM-to-MDM migration, ppkg (WCD) enrollment
    License : MIT

    IMPORTANT - before Invoke-IntuneReEnrollment: delete the device from the
    Intune/Entra portal first to avoid duplicate device records.
    IMPORTANT - before ppkg cleanup: you must re-apply a new package manually.
    This module does NOT apply provisioning packages.
#>

# StrictMode -Version Latest throws PropertyNotFoundException on registry reads
# even with -ErrorAction SilentlyContinue. Version 1 (uninitialized vars only) is safe.
Set-StrictMode -Version 1
$ErrorActionPreference = 'Continue'

#region -- Helpers -------------------------------------------------------------

function Write-Status {
    param([string]$Message, [ValidateSet('Info','OK','Warn','Fail','Section')]$Type = 'Info')
    $c = @{ Info='Cyan'; OK='Green'; Warn='Yellow'; Fail='Red'; Section='Magenta' }
    $p = @{ Info='[*]';  OK='[+]';  Warn='[!]';   Fail='[-]'; Section='[=]'     }
    Write-Host "$($p[$Type]) $Message" -ForegroundColor $c[$Type]
}

function Confirm-Action { param([string]$Prompt)
    return (Read-Host "$Prompt [Y/N]") -match '^[Yy]'
}

# Safe registry reader - avoids PropertyNotFoundException under any StrictMode
function Get-RegValue { param([string]$Path, [string]$Name)
    try {
        if (-not (Test-Path $Path)) { return $null }
        return (Get-ItemProperty -Path $Path -Name $Name -EA SilentlyContinue |
                Select-Object -ExpandProperty $Name -EA SilentlyContinue)
    } catch { return $null }
}

function Invoke-AsSystem { param([string]$Command, [int]$Wait = 60)
    $n = "IntuneRepair_$(Get-Random)"
    $a = New-ScheduledTaskAction -Execute 'powershell.exe' `
             -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"$Command`""
    Register-ScheduledTask -TaskName $n -Force `
        -Action $a `
        -Principal (New-ScheduledTaskPrincipal -UserId SYSTEM -RunLevel Highest -LogonType ServiceAccount) `
        -Settings  (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5)) | Out-Null
    Start-ScheduledTask -TaskName $n
    Write-Status "Waiting up to $Wait seconds for SYSTEM task..." 'Info'
    $e = 0
    do { Start-Sleep 3; $e += 3
         $s = (Get-ScheduledTask -TaskName $n -EA SilentlyContinue).State
    } while ($s -eq 'Running' -and $e -lt $Wait)
    Unregister-ScheduledTask -TaskName $n -Confirm:$false -EA SilentlyContinue
}

#endregion

#region -- Discovery -----------------------------------------------------------

function Get-EnrollmentGUID {
    # Method 1: OMADM account with ServerVer 4.0
    try {
        foreach ($a in @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts' -EA SilentlyContinue)) {
            if ((Get-RegValue $a.PSPath 'ServerVer') -eq '4.0') { return $a.PSChildName }
        }
    } catch {}
    # Method 2: Enrollments hive with ProviderID = MS DM Server
    try {
        foreach ($e in @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -EA SilentlyContinue)) {
            if ((Get-RegValue $e.PSPath 'ProviderID') -eq 'MS DM Server') { return $e.PSChildName }
        }
    } catch {}
    # Method 3: PushLaunch task path (HAADJ fallback)
    try {
        return @(Get-ScheduledTask -TaskName PushLaunch -EA SilentlyContinue) |
            Where-Object { $_.TaskPath -like '*EnterpriseMgmt*' } |
            Select-Object -ExpandProperty TaskPath |
            ForEach-Object { ($_ -split '\\') | Where-Object { $_ -match '[0-9a-f]{8}-' } } |
            Select-Object -First 1
    } catch {}
    return $null
}

function Get-MdmCert {
    return Get-ChildItem Cert:\LocalMachine\My -EA SilentlyContinue |
        Where-Object { $_.Issuer -like '*Microsoft Intune MDM Device CA*' }
}

function Get-EnrollmentType {
    # Returns: HAADJ | EntraJoined | Unknown
    #
    # dsregcmd alone is unreliable - it can report DomainJoined:NO on a genuine
    # domain-joined device when run offline or in certain cached-credential states.
    # We use four independent signals and require Entra-joined + at least 2 domain
    # signals to classify as HAADJ. This handles AD Connect / HAADJ correctly.
    #
    # Signal 1: dsregcmd DomainJoined:YES
    # Signal 2: Netlogon\Parameters\DomainName registry key (persists offline)
    # Signal 3: Group Policy History key (only written on domain-joined machines)
    # Signal 4: Win32_ComputerSystem.PartOfDomain = True

    $entraJoined = $false
    $domainScore = 0

    try {
        # Join each line individually - avoids whitespace collapse issues with Out-String
        $dsregLines  = @(& dsregcmd /status 2>&1)
        $entraJoined = ($dsregLines | Where-Object { $_ -match 'AzureAdJoined\s*:\s*YES' }).Count -gt 0
        if (($dsregLines | Where-Object { $_ -match 'DomainJoined\s*:\s*YES' }).Count -gt 0) { $domainScore++ }
    } catch {}

    if (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters' 'DomainName') { $domainScore++ }
    if (Test-Path   'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\History')      { $domainScore++ }

    try {
        $cs = Get-WmiObject Win32_ComputerSystem -EA SilentlyContinue
        if ($cs -and $cs.PartOfDomain) { $domainScore++ }
    } catch {}

    if ($entraJoined -and $domainScore -ge 2) { return 'HAADJ' }
    if ($entraJoined)                         { return 'EntraJoined' }
    return 'Unknown'
}

function Get-SslCertRef { param([string]$Guid)
    if (-not $Guid) { return $null }
    return Get-RegValue "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts\$Guid" 'SslClientCertReference'
}

function Get-EnrollmentProvisioningPackages {
    $pkgs = @()
    try {
        foreach ($pkg in @(Get-ProvisioningPackage -AllInstalledPackages -EA SilentlyContinue)) {
            $isEnroll = $false; $basis = @()

            if ($pkg.Name -match 'enroll|intune|mdm|aad|azure|workplace|bulk' -or
                $pkg.Description -match 'enroll|intune|mdm|aad|workplace') {
                $isEnroll = $true; $basis += 'Name/description keywords'
            }

            $pkgClass = Get-RegValue "HKLM:\SOFTWARE\Microsoft\Provisioning\PackageMetadata\$($pkg.PackageId)" 'PackageClass'
            if ($pkgClass -match 'Provisioning|Enterprise') { $isEnroll = $true; $basis += "PackageClass=$pkgClass" }

            if (-not $isEnroll) {
                foreach ($k in @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -EA SilentlyContinue)) {
                    $et = Get-RegValue $k.PSPath 'EnrollmentType'
                    $providerId = Get-RegValue $k.PSPath 'ProviderID'
                    if ($et -eq 12 -or ($et -and -not $providerId)) {
                        $isEnroll = $true; $basis += "EnrollmentType=$et (ppkg)"; break
                    }
                }
            }

            if ($isEnroll) {
                $pkgs += [PSCustomObject]@{
                    PackageId   = $pkg.PackageId; Name = $pkg.Name
                    Version     = $pkg.Version;   InstalledOn = $pkg.Date
                    Basis       = ($basis -join '; '); RawPackage = $pkg
                }
            }
        }
    } catch {}   # Get-ProvisioningPackage not available on all editions
    return $pkgs
}

#endregion

#region -- Checks --------------------------------------------------------------

function Test-RegState { param([string]$Guid)
    $r = @{ ProviderOK=$false; EntDMIDOK=$false; ThumbOK=$false; ExtMgdOK=$true; MAMFound=$false; UrlsOK=$false }
    if (-not $Guid) { return $r }

    $r.ProviderOK = ((Get-RegValue "HKLM:\SOFTWARE\Microsoft\Enrollments\$Guid" 'ProviderID') -eq 'MS DM Server')

    $cert = Get-MdmCert
    if ($cert) {
        $subj = $cert.Subject -replace 'CN=',''
        $r.EntDMIDOK = ((Get-RegValue "HKLM:\SOFTWARE\Microsoft\Enrollments\$Guid\DMClient\MS DM Server" 'EntDMID') -eq $subj)
        $r.ThumbOK   = ((Get-RegValue "HKLM:\SOFTWARE\Microsoft\Enrollments\$Guid" 'DMPCertThumbPrint') -eq $cert.Thumbprint)
    }

    $r.ExtMgdOK = ((Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Enrollments' 'ExternallyManaged') -ne 1)

    foreach ($k in @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -EA SilentlyContinue)) {
        if ((Get-RegValue $k.PSPath 'DiscoveryServiceFullURL') -like '*wip.mam.manage.microsoft.com*') {
            $r.MAMFound = $true; break
        }
    }

    $tk = Get-Item 'HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\TenantInfo\*' -EA SilentlyContinue
    if ($tk) {
        $r.UrlsOK = ((Get-RegValue $tk.PSPath 'MdmEnrollmentUrl') -eq 'https://enrollment.manage.microsoft.com/enrollmentserver/discovery.svc')
    }
    return $r
}

function Test-CertHealth {
    $r = @{ Found=$false; Expired=$false; HasKey=$false; SystemStore=$false; UserStore=$false; TPM=$false; Thumb=$null; Expiry=$null }
    $cert = Get-MdmCert
    if (-not $cert) {
        $uc = Get-ChildItem Cert:\CurrentUser\My -EA SilentlyContinue | Where-Object { $_.Issuer -like '*Microsoft Intune MDM Device CA*' }
        if ($uc) { $r.Found=$true; $r.UserStore=$true; $r.Expiry=$uc.NotAfter; $r.Thumb=$uc.Thumbprint; $r.HasKey=$uc.HasPrivateKey }
        return $r
    }
    $r.Found=$true; $r.SystemStore=$true; $r.Thumb=$cert.Thumbprint; $r.Expiry=$cert.NotAfter
    $r.Expired=($cert.NotAfter -lt (Get-Date)); $r.HasKey=$cert.HasPrivateKey
    if ($cert.HasPrivateKey) {
        try { $r.TPM = ([string](& certutil -store my $cert.Thumbprint 2>&1) -match 'Microsoft Platform Crypto Provider') } catch {}
    }
    return $r
}

function Test-DMWAPService {
    $svc = Get-Service dmwappushservice -EA SilentlyContinue
    if (-not $svc) { return @{ Exists=$false; Running=$false; Auto=$false; StartMode='N/A' } }
    $wmi = Get-WmiObject Win32_Service -Filter "Name='dmwappushservice'" -EA SilentlyContinue
    $mode = if ($wmi) { $wmi.StartMode } else { 'Unknown' }
    return @{ Exists=$true; Running=($svc.Status -eq 'Running'); Auto=($mode -eq 'Auto'); StartMode=$mode }
}

function Test-IMEService {
    $svc = Get-Service IntuneManagementExtension -EA SilentlyContinue
    return @{
        Installed = ($null -ne $svc)
        Running   = ($svc -and $svc.Status -eq 'Running')
        ExeFound  = (Test-Path 'C:\Program Files (x86)\Microsoft Intune Management Extension\Microsoft.Management.Services.IntuneWindowsAgent.exe')
    }
}

function Test-Tasks { param([string]$ActiveGuid)
    $gp   = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    $all  = @(Get-ScheduledTask -EA SilentlyContinue | Where-Object { $_.TaskPath -like '*EnterpriseMgmt*' })
    $regs = @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -EA SilentlyContinue |
              Where-Object { $_.PSChildName -match $gp } | Select-Object -ExpandProperty PSChildName)

    $retry = @($all | Where-Object { $_.TaskName -like 'Retry Schedule created for incomplete session*' })
    $active = @(); $orphan = @()
    foreach ($t in $all) {
        if ($t.TaskName -like 'Retry Schedule*') { continue }
        $tg = if ($t.TaskPath -match $gp) { $Matches[0] } else { $null }
        if ($tg -and $regs -notcontains $tg) { $orphan += $t } else { $active += $t }
    }
    return @{ All=$all; Active=$active; Orphan=$orphan; Retry=$retry }
}

function Test-SyncLog {
    $p = "$env:TEMP\IntuneRepairDiag"
    Remove-Item $p -Recurse -Force -EA SilentlyContinue
    New-Item $p -ItemType Directory -Force | Out-Null
    try { (New-Object -ComObject Shell.Application).Open('intunemanagementextension://syncapp'); Start-Sleep 5 } catch {}
    Start-Process MdmDiagnosticsTool.exe -ArgumentList "-out `"$p`"" -Wait -NoNewWindow -EA SilentlyContinue
    $r = Join-Path $p 'MDMDiagReport.html'
    if (Test-Path $r) { return @{ Found=$true; Errors=[bool](Select-String $r -Pattern 'The last sync failed' -Quiet) } }
    return @{ Found=$false; Errors=$false }
}

function Test-DuplicateGUIDs {
    $active = @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -EA SilentlyContinue |
        Where-Object { (Get-RegValue $_.PSPath 'ProviderID') -eq 'MS DM Server' } |
        Select-Object -ExpandProperty PSChildName)
    return @{ Count=$active.Count; GUIDs=$active; HasDuplicate=($active.Count -gt 1) }
}

#endregion

#region -- Repairs -------------------------------------------------------------

function Repair-MDMUrls {
    $tk = Get-Item 'HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\TenantInfo\*' -EA SilentlyContinue
    if (-not $tk) { Write-Status 'TenantInfo key not found. Device may not be Entra-joined.' 'Fail'; return $false }
    @{
        MdmEnrollmentUrl = 'https://enrollment.manage.microsoft.com/enrollmentserver/discovery.svc'
        MdmTermsOfUseUrl = 'https://portal.manage.microsoft.com/TermsofUse.aspx'
        MdmComplianceUrl = 'https://portal.manage.microsoft.com/?portalAction=Compliance'
    }.GetEnumerator() | ForEach-Object {
        New-ItemProperty -LiteralPath $tk.PSPath -Name $_.Key -Value $_.Value -PropertyType String -Force -EA SilentlyContinue | Out-Null
    }
    Write-Status 'MDM URLs configured.' 'OK'; return $true
}

function Repair-ExternallyManagedFlag {
    Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Enrollments' -Name ExternallyManaged -Value 0 -Type DWord -Force -EA SilentlyContinue
    Write-Status 'ExternallyManaged reset to 0.' 'OK'
}

function Remove-MAMLeftoverKeys {
    $keys = @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -EA SilentlyContinue |
        Where-Object { (Get-RegValue $_.PSPath 'DiscoveryServiceFullURL') -like '*wip.mam.manage.microsoft.com*' })
    if ($keys.Count -eq 0) { Write-Status 'No MAM leftover keys found.' 'OK'; return }
    $keys | ForEach-Object {
        Write-Status "  Removing MAM key: $($_.PSChildName)" 'Warn'
        Remove-Item $_.PSPath -Recurse -Force -EA SilentlyContinue
    }
    Write-Status 'MAM leftover keys removed.' 'OK'
}

function Repair-DMWAPService {
    $svc = Get-Service dmwappushservice -EA SilentlyContinue
    if (-not $svc) { Write-Status 'dmwappushservice not found.' 'Warn'; return }
    $wmi = Get-WmiObject Win32_Service -Filter "Name='dmwappushservice'" -EA SilentlyContinue
    if ($wmi -and $wmi.StartMode -ne 'Auto') {
        Set-Service dmwappushservice -StartupType Automatic -EA SilentlyContinue
        Write-Status 'dmwappushservice set to Automatic.' 'OK'
    }
    if ($svc.Status -ne 'Running') {
        Start-Service dmwappushservice -EA SilentlyContinue; Start-Sleep 3; $svc.Refresh()
        if ($svc.Status -eq 'Running') { Write-Status 'dmwappushservice started.' 'OK' }
        else { Write-Status 'Failed to start dmwappushservice.' 'Fail' }
    } else { Write-Status 'dmwappushservice is running.' 'OK' }
}

function Repair-PrivateKey { param([string]$Thumbprint, [bool]$TPMBacked)
    if ($TPMBacked) { Write-Status 'TPM-backed cert - certutil repairstore cannot help. Re-enrollment required.' 'Fail'; return $false }
    $out = & certutil -repairstore my $Thumbprint 2>&1
    if ([string]($out -join ' ') -match 'completed successfully') { Write-Status 'Private key repaired.' 'OK'; return $true }
    Write-Status "certutil repairstore failed: $($out -join ' ')" 'Fail'; return $false
}

function Remove-EnrollmentArtifacts { param([string]$Guid)
    if (-not $Guid) { Write-Status 'No GUID provided.' 'Warn'; return }
    Write-Status "Removing artifacts for GUID: $Guid" 'Info'
    @(
        "HKLM:\SOFTWARE\Microsoft\Enrollments\$Guid",
        "HKLM:\SOFTWARE\Microsoft\Enrollments\Status\$Guid",
        "HKLM:\SOFTWARE\Microsoft\EnterpriseResourceManager\Tracked\$Guid",
        "HKLM:\SOFTWARE\Microsoft\PolicyManager\AdmxInstalled\$Guid",
        "HKLM:\SOFTWARE\Microsoft\PolicyManager\Providers\$Guid",
        "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts\$Guid",
        "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Logger\$Guid",
        "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Sessions\$Guid"
    ) | Where-Object { Test-Path $_ } | ForEach-Object { Remove-Item $_ -Recurse -Force -EA SilentlyContinue; Write-Status "  Removed: $_" 'Info' }

    # Clear CurrentEnrollmentId pointer so OMADM Logger no longer references a stale GUID
    Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Logger' `
        -Name CurrentEnrollmentId -Force -EA SilentlyContinue

    Get-MdmCert | Remove-Item -Force -EA SilentlyContinue
    Get-ChildItem Cert:\LocalMachine\My -EA SilentlyContinue |
        Where-Object { $_.Issuer -match 'SC_Online_Issuing' } | Remove-Item -Force -EA SilentlyContinue

    @(Get-ScheduledTask -EA SilentlyContinue |
        Where-Object { $_.TaskPath -like "*$Guid*" -or $_.TaskPath -like '*EnterpriseMgmt*' }) |
        ForEach-Object { Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -EA SilentlyContinue; Write-Status "  Removed task: $($_.TaskName)" 'Info' }

    # Remove WManSvc cached MDM policy state - can cause re-enrollment to pick up
    # stale session data and fail. Safe to delete; rebuilt on next MDM sync.
    $wman = 'C:\Windows\ServiceState\wmansvc'
    if (Test-Path $wman) {
        Get-ChildItem $wman -File -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
        Write-Status "  Cleared WManSvc cache: $wman" 'Info'
    }

    Write-Status 'Enrollment artifacts removed.' 'OK'
}

function Remove-StaleRetryTasks {
    $tasks = @(Get-ScheduledTask -EA SilentlyContinue | Where-Object { $_.TaskName -like 'Retry Schedule created for incomplete session*' })
    if ($tasks.Count -eq 0) { Write-Status 'No stale retry tasks.' 'OK'; return }
    $tasks | ForEach-Object { Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -EA SilentlyContinue }
    Write-Status "$($tasks.Count) stale retry task(s) removed." 'OK'
}

function Remove-OrphanedEnrollmentTasks { param([string[]]$Names)
    if ($Names.Count -eq 0) { Write-Status 'No orphaned tasks to remove.' 'OK'; return }
    $Names | ForEach-Object {
        Unregister-ScheduledTask -TaskName $_ -Confirm:$false -EA SilentlyContinue
        Write-Status "  Removed: $_" 'Info'
    }
    Write-Status "$($Names.Count) orphaned task(s) removed." 'OK'
}

function Remove-OrphanedEnrollmentGUID { param([string]$OrphanGuid)
    if (-not $OrphanGuid) { return }
    Write-Status "Removing orphaned GUID: $OrphanGuid" 'Warn'
    Remove-EnrollmentArtifacts -Guid $OrphanGuid
}

function Remove-ProvisioningPackageAndArtifacts { param([object]$Package)
    Write-Status "Removing ppkg: $($Package.Name) [$($Package.PackageId)]" 'Warn'
    try { Remove-ProvisioningPackage -PackageId $Package.PackageId -EA Stop; Write-Status '  Package removed.' 'OK' }
    catch { Write-Status "  Remove-ProvisioningPackage failed: $_  Continuing cleanup." 'Warn' }

    $pkgId = $Package.PackageId
    if ($pkgId -and (Test-Path "HKLM:\SOFTWARE\Microsoft\Provisioning\PackageMetadata\$pkgId")) {
        Remove-Item "HKLM:\SOFTWARE\Microsoft\Provisioning\PackageMetadata\$pkgId" -Recurse -Force -EA SilentlyContinue
        Write-Status "  Removed PackageMetadata key." 'Info'
    }

    $gp = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    foreach ($k in @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -EA SilentlyContinue)) {
        if ($k.PSChildName -notmatch $gp) { continue }
        $et   = Get-RegValue $k.PSPath 'EnrollmentType'
        $pid2 = Get-RegValue $k.PSPath 'ProviderID'
        $disc = Get-RegValue $k.PSPath 'DiscoveryServiceFullURL'
        if ($et -eq 12 -or ($et -and -not $pid2 -and $disc -notlike '*wip.mam*')) {
            Write-Status "  Removing ppkg GUID: $($k.PSChildName)" 'Info'
            Remove-EnrollmentArtifacts -Guid $k.PSChildName
        }
    }

    foreach ($sub in 'Logger','Sessions') {
        foreach ($k in @(Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\$sub" -EA SilentlyContinue)) {
            if ($k.PSChildName -match $gp -and -not (Test-Path "HKLM:\SOFTWARE\Microsoft\Enrollments\$($k.PSChildName)")) {
                Remove-Item $k.PSPath -Recurse -Force -EA SilentlyContinue
                Write-Status "  Removed orphaned OMADM $sub key: $($k.PSChildName)" 'Info'
            }
        }
    }

    Remove-StaleRetryTasks
    Write-Host ''
    Write-Status '+==================================================+' 'Warn'
    Write-Status '|  PROVISIONING PACKAGE REMOVED                   |' 'Warn'
    Write-Status '|  Re-apply a new package manually to re-enroll.  |' 'Warn'
    Write-Status '+==================================================+' 'Warn'
    Write-Host ''
}

function Start-MDMReEnrollment {
    Write-Status 'Triggering DeviceEnroller.exe as SYSTEM...' 'Info'
    Invoke-AsSystem 'C:\Windows\System32\DeviceEnroller.exe /C /AutoenrollMDM' -Wait 90
    Write-Status 'Waiting 30s for enrollment to settle...' 'Info'; Start-Sleep 30
    $cert = Get-MdmCert
    if ($cert) { Write-Status "Re-enrollment succeeded. Thumbprint: $($cert.Thumbprint)" 'OK'; return $true }
    Write-Status 'MDM cert not yet present - may still be in progress. Recheck in 5 min.' 'Warn'; return $false
}

function Start-IMESync {
    try { (New-Object -ComObject Shell.Application).Open('intunemanagementextension://syncapp') } catch {}
    $t = Get-ScheduledTask -EA SilentlyContinue | Where-Object { $_.TaskName -eq 'Schedule #1 created by enrollment client' }
    if ($t) { Start-ScheduledTask -TaskName $t.TaskName -EA SilentlyContinue; Write-Status 'IME sync triggered.' 'OK' }
}

#endregion

#region -- Public Functions ----------------------------------------------------

function Invoke-IntuneEnrollmentDiagnostics {
    <#
    .SYNOPSIS
        Full Intune enrollment diagnostic. Detects ppkg vs standard enrollment and
        branches behaviour accordingly. Use -Fix to auto-remediate found issues.

    .DESCRIPTION
        ppkg enrolled + failures  -> with -Fix: removes package + artifacts. Admin re-applies manually.
        ppkg enrolled + healthy   -> informational only, no action.
        Standard + failures       -> -Fix applies safe repairs. Invoke-IntuneReEnrollment for full wipe.
        Standard + healthy        -> all green.

    .EXAMPLE
        Invoke-IntuneEnrollmentDiagnostics
        Invoke-IntuneEnrollmentDiagnostics -Fix
    #>
    [CmdletBinding()] param([switch]$Fix)

    Write-Host ''
    Write-Status '===================================================' 'Section'
    Write-Status "  Intune Enrollment Diagnostics v1.0.8$(if($Fix){' [-Fix]'})" 'Section'
    Write-Status '===================================================' 'Section'
    Write-Host ''

    # Failure flag accumulator - used for ppkg branch decision at the end
    $fail = @{ cert=$false; reg=$false; svc=$false; task=$false; sync=$false }

    #-- Step 0: Provisioning Packages -----------------------------------------
    Write-Status 'STEP 0: Provisioning Package Detection' 'Section'
    $ppkgs   = @(Get-EnrollmentProvisioningPackages)
    $hasPpkg = ($ppkgs.Count -gt 0)
    if ($hasPpkg) {
        Write-Status "$($ppkgs.Count) enrollment ppkg(s) found - device enrolled via WCD/ppkg." 'Warn'
        $ppkgs | ForEach-Object { Write-Status "  $($_.Name) v$($_.Version) installed $($_.InstalledOn)" 'Info' }
    } else { Write-Status 'No enrollment provisioning packages detected. Standard MDM enrollment.' 'OK' }
    Write-Host ''

    #-- Step 1: GUID + Join Type -----------------------------------------------
    Write-Status 'STEP 1: Enrollment GUID and join type' 'Section'
    $guid    = Get-EnrollmentGUID
    $jtype   = Get-EnrollmentType
    Write-Status "Join type: $jtype" 'Info'
    if ($guid) { Write-Status "Active GUID: $guid" 'OK' }
    else       { Write-Status 'No enrollment GUID found. Device does not appear to be enrolled.' 'Fail'; $fail.reg=$true }

    $dupe = Test-DuplicateGUIDs
    if ($dupe.HasDuplicate) {
        Write-Status "DUPLICATE GUIDs: $($dupe.Count) active MS DM Server entries found." 'Fail'; $fail.reg=$true
        $dupe.GUIDs | ForEach-Object {
            $m = if ($_ -eq $guid) { '<-- active' } else { '<-- ORPHAN' }
            Write-Status "  $_ $m" 'Warn'
        }
        if ($Fix -and -not $hasPpkg) {
            $dupe.GUIDs | Where-Object { $_ -ne $guid } | ForEach-Object {
                if (Confirm-Action "Remove orphaned GUID $_?") { Remove-OrphanedEnrollmentGUID $_ }
            }
        }
    } else { Write-Status 'No duplicate GUIDs.' 'OK' }
    Write-Host ''

    #-- Step 2: Certificate ----------------------------------------------------
    Write-Status 'STEP 2: MDM Certificate Health' 'Section'
    $ch = Test-CertHealth
    if ($ch.Found) {
        if ($ch.SystemStore) { Write-Status 'Certificate in LocalMachine\My store.' 'OK' }
        if ($ch.UserStore)   { Write-Status 'Certificate in WRONG store (CurrentUser\My).' 'Fail'; $fail.cert=$true }
        Write-Status "Thumbprint : $($ch.Thumb)" 'Info'
        Write-Status "Expires    : $($ch.Expiry)" 'Info'
        if ($ch.Expired)  { Write-Status 'Certificate EXPIRED. Re-enrollment required.' 'Fail'; $fail.cert=$true }
        else              { Write-Status 'Certificate within validity period.' 'OK' }
        if ($ch.HasKey)   { Write-Status 'Private key present.' 'OK' }
        else              { Write-Status 'Private key MISSING.' 'Fail'; $fail.cert=$true
                            if ($Fix -and -not $hasPpkg) { Repair-PrivateKey $ch.Thumb $ch.TPM } }
        if ($ch.TPM)      { Write-Status 'TPM-backed (Microsoft Platform Crypto Provider).' 'OK' }
        else              { Write-Status 'Software-backed (not TPM).' 'Warn' }
    } else {
        Write-Status 'MDM certificate MISSING from all stores. Re-enrollment required.' 'Fail'; $fail.cert=$true
    }

    $ssl = Get-SslCertRef $guid
    if ($ssl)                        { Write-Status "SslClientCertReference: $ssl" 'OK' }
    elseif ($jtype -eq 'HAADJ')      { Write-Status 'SslClientCertReference absent. Normal on modern HAADJ enrollment via Entra registration path.' 'Warn' }
    else                             { Write-Status 'SslClientCertReference absent - normal for Entra-joined enrollment.' 'Info' }
    Write-Host ''

    #-- Step 3: Registry -------------------------------------------------------
    Write-Status 'STEP 3: Registry Enrollment State' 'Section'
    $rs = Test-RegState $guid
    if ($rs.ProviderOK)   { Write-Status 'ProviderID = MS DM Server.' 'OK' }
    elseif ($jtype -eq 'HAADJ') { Write-Status 'ProviderID absent. Normal on modern HAADJ enrolled via Entra registration path.' 'Warn' }
    else                  { Write-Status 'ProviderID absent - expected on Entra-joined devices.' 'Info' }

    if ($rs.EntDMIDOK)    { Write-Status 'EntDMID matches cert subject.' 'OK' }
    else                  { Write-Status 'EntDMID mismatch - may resolve after reboot.' 'Warn' }

    if ($rs.ThumbOK)      { Write-Status 'DMPCertThumbPrint matches cert.' 'OK' }
    else                  { Write-Status 'DMPCertThumbPrint mismatch/missing. Usually resolves after reboot + sync.' 'Warn' }

    if ($rs.ExtMgdOK)     { Write-Status 'ExternallyManaged not blocking enrollment.' 'OK' }
    else                  { Write-Status 'ExternallyManaged=1 detected! Causes 0x80180026.' 'Fail'; $fail.reg=$true
                            if ($Fix -and -not $hasPpkg) { Repair-ExternallyManagedFlag } }

    if ($rs.MAMFound)     { Write-Status 'MAM leftover keys detected - can block re-enrollment.' 'Fail'; $fail.reg=$true
                            if ($Fix -and -not $hasPpkg) { Remove-MAMLeftoverKeys } }
    else                  { Write-Status 'No MAM leftover keys.' 'OK' }

    if ($rs.UrlsOK)       { Write-Status 'MDM URLs correctly configured.' 'OK' }
    else                  { Write-Status 'MDM URLs missing or incorrect.' 'Fail'; $fail.reg=$true
                            if ($Fix -and -not $hasPpkg) { Repair-MDMUrls } }
    Write-Host ''

    #-- Step 4: Services -------------------------------------------------------
    Write-Status 'STEP 4: Services' 'Section'
    $dw = Test-DMWAPService
    if (-not $dw.Exists) { Write-Status 'dmwappushservice not found.' 'Warn' }
    elseif ($dw.Running -and $dw.Auto) { Write-Status 'dmwappushservice running, startup=Automatic.' 'OK' }
    else {
        $msg = if (-not $dw.Running) { "NOT running (startup=$($dw.StartMode))" } else { "running but startup=$($dw.StartMode) - won't survive reboot" }
        Write-Status "dmwappushservice $msg." 'Fail'; $fail.svc=$true
        if ($Fix) { Repair-DMWAPService }
    }

    $ime = Test-IMEService
    if ($ime.Running)        { Write-Status 'IME service running.' 'OK' }
    elseif ($ime.Installed)  { Write-Status 'IME installed but NOT running.' 'Warn'; $fail.svc=$true
                               if ($Fix) { Start-Service IntuneManagementExtension -EA SilentlyContinue; Write-Status 'IME start attempted.' 'Info' } }
    elseif ($ime.ExeFound)   { Write-Status 'IME exe present but service not installed.' 'Fail'; $fail.svc=$true }
    else                     { Write-Status 'IME not installed.' 'Warn' }
    Write-Host ''

    #-- Step 5: Scheduled Tasks ------------------------------------------------
    Write-Status 'STEP 5: Enrollment Scheduled Tasks' 'Section'
    $ts = Test-Tasks $guid
    Write-Status "Total: $($ts.All.Count)  Active: $($ts.Active.Count)  Orphaned: $($ts.Orphan.Count)  Retry: $($ts.Retry.Count)" 'Info'

    if ($ts.Active.Count -gt 0) {
        Write-Status 'Active tasks:' 'OK'
        $ts.Active | ForEach-Object { Write-Status "  $($_.TaskName) [$($_.State)]" 'Info' }
    } else { Write-Status 'No active enrollment tasks found.' 'Fail'; $fail.task=$true }

    if ($ts.Orphan.Count -gt 0) {
        Write-Status "$($ts.Orphan.Count) orphaned task(s) (GUID not in registry):" 'Warn'
        $ts.Orphan | ForEach-Object { Write-Status "  $($_.TaskName)" 'Warn' }
        if ($Fix -and -not $hasPpkg) { Remove-OrphanedEnrollmentTasks ($ts.Orphan | Select-Object -ExpandProperty TaskName) }
        else { Write-Status '  Run -Fix to remove.' 'Info' }
    } else { Write-Status 'No orphaned tasks.' 'OK' }

    if ($ts.Retry.Count -gt 0) {
        Write-Status "$($ts.Retry.Count) stale retry task(s):" 'Warn'
        $ts.Retry | ForEach-Object { Write-Status "  $($_.TaskName)" 'Warn' }
        if ($Fix) { Remove-StaleRetryTasks } else { Write-Status '  Run -Fix to remove.' 'Info' }
    } else { Write-Status 'No stale retry tasks.' 'OK' }
    Write-Host ''

    #-- Step 6: Sync Log -------------------------------------------------------
    Write-Status 'STEP 6: MDM Sync Log' 'Section'
    $log = Test-SyncLog
    if (-not $log.Found)  { Write-Status 'MDMDiagReport not generated - MdmDiagnosticsTool may have failed.' 'Warn' }
    elseif ($log.Errors)  { Write-Status 'Sync errors in MDM diagnostic report.' 'Fail'; $fail.sync=$true }
    else                  { Write-Status 'No sync errors detected.' 'OK' }
    Write-Host ''

    #-- Branch: ppkg vs standard -----------------------------------------------
    $anyFail = $fail.Values -contains $true
    if ($hasPpkg -and $anyFail) {
        Write-Status '===================================================' 'Section'
        Write-Status '  PROVISIONING PACKAGE ENROLLMENT IS BROKEN        ' 'Fail'
        Write-Status '  Remove package + re-apply a new one manually.    ' 'Warn'
        Write-Status '  Do NOT use Invoke-IntuneReEnrollment here.       ' 'Info'
        Write-Status '===================================================' 'Section'
        if ($Fix) {
            $ppkgs | ForEach-Object {
                if (Confirm-Action "Remove package '$($_.Name)' and all artifacts?") {
                    Remove-ProvisioningPackageAndArtifacts $_
                }
            }
        } else { Write-Status 'Run -Fix to remove the broken package and artifacts.' 'Info' }
    } elseif ($hasPpkg -and -not $anyFail) {
        Write-Status 'Provisioning package enrollment is healthy. No action needed.' 'OK'
    } else {
        Write-Status '===================================================' 'Section'
        Write-Status '  Diagnostics Complete' 'Section'
        if (-not $Fix -and $anyFail) {
            Write-Status '  Run -Fix to auto-remediate safe issues.' 'Info'
            Write-Status '  Run Invoke-IntuneReEnrollment for full re-enrollment.' 'Info'
        } elseif (-not $anyFail) {
            Write-Status '  No enrollment failures detected.' 'OK'
        }
        Write-Status '===================================================' 'Section'
    }
    Write-Host ''
}

function Invoke-IntuneReEnrollment {
    <#
    .SYNOPSIS
        Full destructive re-enrollment for standard (non-ppkg) devices.
        For ppkg devices use: Invoke-IntuneEnrollmentDiagnostics -Fix
        Delete the device from the Intune/Entra portal BEFORE running this.
    .EXAMPLE
        Invoke-IntuneReEnrollment
        Invoke-IntuneReEnrollment -Force
    #>
    [CmdletBinding()] param([switch]$Force)

    $ppkgs = @(Get-EnrollmentProvisioningPackages)
    if ($ppkgs.Count -gt 0) {
        Write-Status 'WARNING: ppkg enrollment detected.' 'Fail'
        $ppkgs | ForEach-Object { Write-Status "  $($_.Name)" 'Info' }
        Write-Status 'Use Invoke-IntuneEnrollmentDiagnostics -Fix for ppkg devices.' 'Warn'
        if (-not (Confirm-Action 'Continue anyway? (Not recommended for ppkg devices)')) { return }
    }

    Write-Host ''
    Write-Status '===================================================' 'Section'
    Write-Status '  Intune FULL Re-Enrollment  !! DESTRUCTIVE !!' 'Fail'
    Write-Status '  Delete device from Intune portal first!' 'Warn'
    Write-Status '===================================================' 'Section'
    Write-Host ''
    if (-not $Force -and -not (Confirm-Action 'Proceed with full re-enrollment?')) { Write-Status 'Cancelled.' 'Info'; return }

    $guid = Get-EnrollmentGUID

    Write-Host ''; Write-Status 'Phase 1: MDM URLs'                   'Section'; Repair-MDMUrls
    Write-Host ''; Write-Status 'Phase 2: ExternallyManaged flag'     'Section'; Repair-ExternallyManagedFlag
    Write-Host ''; Write-Status 'Phase 3: MAM leftover keys'          'Section'; Remove-MAMLeftoverKeys
    Write-Host ''; Write-Status 'Phase 4: Stale retry tasks'          'Section'; Remove-StaleRetryTasks
    Write-Host ''; Write-Status 'Phase 5: Enrollment artifacts'       'Section'
    if ($guid) {
        Remove-EnrollmentArtifacts $guid
    } else {
        Write-Status 'No GUID - removing all GUID-shaped subkeys...' 'Warn'
        @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -EA SilentlyContinue) |
            Where-Object { $_.PSChildName -match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' } |
            ForEach-Object { Remove-Item $_.PSPath -Recurse -Force -EA SilentlyContinue }
        Get-MdmCert | Remove-Item -Force -EA SilentlyContinue
    }
    Write-Host ''; Write-Status 'Phase 6: dmwappushservice'           'Section'; Repair-DMWAPService
    Write-Host ''; Write-Status 'Phase 7: Re-enrollment (SYSTEM)'     'Section'; $ok = Start-MDMReEnrollment
    Write-Host ''; Write-Status 'Phase 8: IME sync'                   'Section'; Start-IMESync
    Write-Host ''; Write-Status 'Phase 9: Post-enrollment validation' 'Section'; Start-Sleep 10; Invoke-IntuneEnrollmentDiagnostics

    Write-Host ''
    if ($ok) { Write-Status 'Re-enrollment complete. Monitor in Intune portal.' 'OK' }
    else      { Write-Status 'Re-enrollment may still be in progress. Recheck in 5 min.' 'Warn' }
}

function Get-IntuneEnrollmentSummary {
    <#
    .SYNOPSIS  Structured enrollment summary. Suitable for RMM pre-checks or monitoring.
    .EXAMPLE   Get-IntuneEnrollmentSummary
    #>
    $guid  = Get-EnrollmentGUID; $cert = Get-MdmCert
    $ime   = Test-IMEService;    $dw   = Test-DMWAPService
    $ts    = Test-Tasks $guid;   $dup  = Test-DuplicateGUIDs
    $ppkgs = @(Get-EnrollmentProvisioningPackages)

    [PSCustomObject]@{
        EnrolledGUID      = $guid
        JoinType          = Get-EnrollmentType
        PpkgEnrolled      = ($ppkgs.Count -gt 0)
        PpkgNames         = ($ppkgs.Name -join ', ')
        DuplicateGUIDs    = $dup.HasDuplicate
        CertPresent       = ([bool]$cert)
        CertExpired       = if ($cert) { $cert.NotAfter -lt (Get-Date) } else { 'N/A' }
        CertExpiry        = if ($cert) { $cert.NotAfter.ToString('yyyy-MM-dd') } else { 'N/A' }
        CertThumbprint    = if ($cert) { $cert.Thumbprint } else { 'N/A' }
        IMERunning        = $ime.Running
        DMWAPRunning      = $dw.Running
        DMWAPAutomatic    = $dw.Auto
        ActiveTasks       = $ts.Active.Count
        OrphanedTasks     = $ts.Orphan.Count
        RetryTasks        = $ts.Retry.Count
    }
}

#endregion

Export-ModuleMember -Function @(
    'Invoke-IntuneEnrollmentDiagnostics',
    'Invoke-IntuneReEnrollment',
    'Get-IntuneEnrollmentSummary',
    'Get-EnrollmentProvisioningPackages',
    'Repair-MDMUrls',
    'Repair-ExternallyManagedFlag',
    'Remove-MAMLeftoverKeys',
    'Repair-DMWAPService',
    'Remove-EnrollmentArtifacts',
    'Remove-ProvisioningPackageAndArtifacts',
    'Remove-StaleRetryTasks',
    'Remove-OrphanedEnrollmentTasks',
    'Remove-OrphanedEnrollmentGUID',
    'Start-MDMReEnrollment'
)
