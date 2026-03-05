@{
    RootModule        = 'IntuneEnrollmentRepair.psm1'
    ModuleVersion     = '1.0.8'
    GUID              = 'a3f72c91-4d58-47be-b831-ef620d3a1c44'
    Author            = 'IntuneEnrollmentRepair'
    CompanyName       = ''
    Copyright         = 'MIT License'
    Description       = 'Diagnoses and repairs Intune enrollment and sync failures on Windows devices. Supports HAADJ, Entra-joined, MAM-to-MDM migration, TPM-backed certs, and full re-enrollment without PSExec.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Invoke-IntuneEnrollmentDiagnostics',
        'Invoke-IntuneReEnrollment',
        'Get-IntuneEnrollmentSummary',
        'Repair-MDMUrls',
        'Repair-ExternallyManagedFlag',
        'Remove-MAMLeftoverKeys',
        'Repair-DMWAPService',
        'Remove-EnrollmentArtifacts',
        'Remove-StaleRetryTasks',
        'Remove-OrphanedEnrollmentTasks',
        'Remove-OrphanedEnrollmentGUID',
        'Remove-ProvisioningPackageAndArtifacts',
        'Get-EnrollmentProvisioningPackages',
        'Start-MDMReEnrollment'
    )

    CmdletsToExport   = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags        = @('Intune', 'MDM', 'Enrollment', 'Windows', 'Repair', 'HAADJ', 'Entra')
            ProjectUri  = 'https://github.com/UMD-PRE/IntuneEnrollmentRepair'
            LicenseUri  = 'https://github.com/UMD-PRE/IntuneEnrollmentRepair/blob/main/LICENSE'
            ReleaseNotes = @'
v1.0.8
- Added: WManSvc cache cleanup (C:\Windows\ServiceState\wmansvc) to
  Remove-EnrollmentArtifacts and Invoke-IntuneReEnrollment. Stale MDM policy
  state in this folder can cause re-enrollment to fail or pick up old session
  data. Files are deleted; folder is rebuilt on next MDM sync.
- Added: CurrentEnrollmentId registry value removal from OMADM\Logger so the
  OMADM logger no longer points to a stale GUID after cleanup.

v1.0.7
- Fixed: SslClientCertReference absent on HAADJ demoted from Fail to Warn,
  removed from failure accumulator. Normal on modern HAADJ Entra-registration path.
- Fixed: ProviderID absent on HAADJ demoted from Fail to Warn, removed from
  failure accumulator. Same reason - not present on modern HAADJ enrollment.
- Fixed: DMPCertThumbPrint mismatch removed from failure accumulator (remains Warn).
  Stale thumbprint record resolves on its own after reboot + sync and does not
  indicate a broken enrollment on an otherwise healthy device.

v1.0.6
- Fixed: dsregcmd output parsed line-by-line instead of as a joined string,
  fixing AzureAdJoined/DomainJoined detection that was failing due to whitespace
  collapse when using Out-String + [string] cast on dsregcmd output.

v1.0.5
- Fixed: Get-EnrollmentType now uses 4 independent domain-join signals (dsregcmd,
  Netlogon registry, Group Policy History key, Win32_ComputerSystem.PartOfDomain)
  requiring Entra-joined + at least 2 domain signals to classify as HAADJ.
  Resolves false EntraJoined classification on AD Connect / HAADJ devices.

v1.0.4
- Full module streamline: ~700 lines vs ~1400 (50%% reduction, same functionality)
- Fixed: ppkg detection $enrollmentPkgs variable not initialised before try block
- Fixed: Get-EnrollmentType false-positive HAADJ detection - now cross-checks
  DomainName in Netlogon registry to confirm domain join is real
- All functions compacted, internal names shortened, redundant comments removed
- get-MdmCert/Get-RegValue/Test-* all tightened

v1.0.3
- Provisioning package (.ppkg/WCD) detection via Get-EnrollmentProvisioningPackages
- ppkg health check: broken vs healthy vs absent, based on existing failure conditions
- Invoke-IntuneEnrollmentDiagnostics now branches: ppkg path vs standard path
- -Fix on broken ppkg device: removes package + all artifacts, prompts admin to re-apply
- Remove-ProvisioningPackageAndArtifacts: ppkg removal + registry/task/cert cleanup
- Invoke-IntuneReEnrollment warns and prompts if ppkg is detected before proceeding
- Get-IntuneEnrollmentSummary extended with PpkgEnrolled, PpkgCount, PpkgNames
- Step 0 added to diagnostics: provisioning package detection always runs first

v1.0.2
- Duplicate enrollment GUID detection and optional cleanup
- dmwappushservice startup type check and enforcement (Automatic)
- Stale retry task detection and removal (Remove-StaleRetryTasks)
- Orphaned enrollment task detection and removal (Remove-OrphanedEnrollmentTasks)
- Enrollment type detection via dsregcmd (HAADJ vs Entra-joined)
- Context-aware messaging: SslClientCertReference/ProviderID warnings suppressed on Entra-joined
- Remove-OrphanedEnrollmentGUID for surgical duplicate GUID cleanup
- Get-IntuneEnrollmentSummary extended with EnrollmentType, DuplicateGUIDs, task breakdown
- Re-enrollment now includes stale retry task cleanup as Phase 4

v1.0.1
- Fixed all PropertyNotFoundException errors under Set-StrictMode -Version Latest
- Introduced Get-RegistryValue helper for safe property reads
- Downgraded to Set-StrictMode -Version 1
- Wrapped all array operations in @() for reliable .Count behaviour
- SslClientCertReference missing now Warn not Fail

v1.0.0
- Initial release
- No PSExec dependency (SYSTEM context via scheduled task)
- No base64 encoded payloads
- TPM/MMP-C cert awareness
- Surgical per-GUID registry cleanup
- Supports HAADJ, Entra-joined, MAM-to-MDM scenarios
- ExternallyManaged flag fix (0x80180026)
- MAM leftover key detection and removal
- Full diagnostics with optional -Fix switch
- Separate Invoke-IntuneReEnrollment for destructive re-enrollment
'@
        }
    }
}
