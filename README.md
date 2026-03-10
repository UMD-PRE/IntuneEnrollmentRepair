# IntuneEnrollmentRepair

[![PSGallery](https://img.shields.io/powershellgallery/v/IntuneEnrollmentRepair)](https://www.powershellgallery.com/packages/IntuneEnrollmentRepair/1.0.8)

A PowerShell module for diagnosing and repairing Microsoft Intune enrollment failures on Windows devices. Built as a transparent, production-grade replacement for the `intunesyncdebugtool` by Rudy Ooms.

---

## Why This Exists

The `intunesyncdebugtool` has limitations that make it unsuitable for production:

- Downloads and executes PSExec from Sysinternals for SYSTEM context
- Fix logic hidden in base64-encoded payloads — cannot be audited
- Wipes the entire enrollment registry hive rather than the affected GUID only
- No awareness of TPM-backed MDM certificates (default since late 2022 MDM hardening)
- Does not handle MAM leftover keys, `ExternallyManaged` flag, provisioning packages, or duplicate GUIDs

---

## Features

| Feature | Detail |
|---|---|
| No PSExec | SYSTEM context via native one-shot scheduled task |
| Fully auditable | No encoded payloads — readable PowerShell throughout |
| TPM-aware | Detects TPM-backed certs, advises re-enrollment instead of attempting `certutil -repairstore` |
| Surgical cleanup | Removes only GUID-scoped keys, not the entire Enrollments hive |
| ppkg support | Detects WCD provisioning package enrollment, removes broken packages and all artifacts |
| Duplicate GUID detection | Identifies and removes orphaned enrollment GUIDs left by partial cleanups |
| Startup type enforcement | Ensures `dmwappushservice` is set to Automatic, not just currently running |
| WManSvc cache cleanup | Clears `C:\Windows\ServiceState\wmansvc` during artifact removal and re-enrollment, preventing stale MDM session data from interfering with the new enrollment |
| Stale task cleanup | Removes orphaned tasks and stale retry session tasks |
| Join type awareness | Four-signal HAADJ detection (dsregcmd, Netlogon registry, GP History, WMI PartOfDomain). Modern HAADJ devices correctly classified even when dsregcmd returns stale state offline. SslClientCertReference and ProviderID absence correctly treated as warnings on modern HAADJ, not failures. |
| RMM-friendly | `Get-IntuneEnrollmentSummary` returns a structured object for monitoring pipelines |

---

## Requirements

| | |
|---|---|
| OS | Windows 10 1803+ / Windows 11 |
| PowerShell | 5.1 or 7+ |
| Privileges | Must run as Administrator |
| Enrollment types | Entra-joined, HAADJ (including AD Connect sync), MAM-to-MDM migration, WCD provisioning package |

> **Not suitable for** mid-flight Autopilot pre-provisioning or co-managed devices where ConfigMgr enrollment also needs re-establishing independently.

---

## Installation

```powershell
Install-Module -Name IntuneEnrollmentRepair
```

Available on the [PowerShell Gallery](https://www.powershellgallery.com/packages/IntuneEnrollmentRepair/1.0.8).

---

## Quick Start

```powershell
# Read-only health check
Invoke-IntuneEnrollmentDiagnostics

# Diagnose and auto-fix safe issues
Invoke-IntuneEnrollmentDiagnostics -Fix

# Structured summary for RMM/monitoring
Get-IntuneEnrollmentSummary

# Full re-enrollment (standard enrollment only - destructive, read warnings)
Invoke-IntuneReEnrollment
```

> See [INSTALLATION.md](INSTALLATION.md) for full setup instructions.

---

## Command Reference

### `Invoke-IntuneEnrollmentDiagnostics [-Fix]`

Full diagnostic across all enrollment health areas. Read-only by default.

**Diagnostic steps:**

| Step | What it checks |
|---|---|
| 0 | Provisioning package (ppkg/WCD) detection |
| 1 | Enrollment GUID resolution, join type (HAADJ/Entra-joined), duplicate GUIDs |
| 2 | MDM certificate: presence, store, expiry, private key, TPM backing, SslClientCertReference |
| 3 | ProviderID, EntDMID, DMPCertThumbPrint, ExternallyManaged flag, MAM keys, MDM URLs |
| 4 | dmwappushservice (run state + startup type), IME service |
| 5 | Scheduled tasks: active, orphaned (GUID not in registry), stale retry |
| 6 | MDM sync log via MdmDiagnosticsTool |

**HAADJ vs Entra-joined thresholds:**

Some checks behave differently depending on join type. The module uses four independent signals to determine join type reliably, including when `dsregcmd` returns stale output offline.

| Check | Entra-joined | HAADJ |
|---|---|---|
| SslClientCertReference absent | Info | Warn (not a failure - normal on modern HAADJ) |
| ProviderID absent | Info | Warn (not a failure - normal on modern HAADJ) |
| DMPCertThumbPrint mismatch | Warn | Warn (resolves after reboot + sync) |

**Branching behaviour:**

| Scenario | Read-only | With `-Fix` |
|---|---|---|
| ppkg + failures | Reports issues | Removes package + artifacts. Admin re-applies manually. |
| ppkg + healthy | Informational only | No action |
| Standard + failures | Reports issues | Fixes safe issues. Use `Invoke-IntuneReEnrollment` for full wipe. |
| Standard + healthy | All green | No action |

**What `-Fix` remediates without re-enrollment:**
- MDM enrollment URLs
- `ExternallyManaged` flag reset to `0` (fixes `0x80180026`)
- MAM leftover enrollment keys
- `dmwappushservice` stopped or wrong startup type
- IME service stopped
- Software-backed certificate private key via `certutil -repairstore`
- Stale retry scheduled tasks
- Orphaned enrollment scheduled tasks
- Duplicate/orphaned enrollment GUIDs (with confirmation prompt)
- Broken ppkg: removes package and all registry/task/cert artifacts

---

### `Invoke-IntuneReEnrollment [-Force]`

Full destructive re-enrollment for **standard (non-ppkg) devices only**.

> For ppkg-enrolled devices, use `Invoke-IntuneEnrollmentDiagnostics -Fix` instead. This function will warn and prompt if a ppkg is detected.

> **Before running:** Delete the device from the Intune portal and/or Entra ID to avoid duplicate device records.

**Phases:**
1. Configure MDM enrollment URLs
2. Reset `ExternallyManaged` flag
3. Remove MAM leftover keys
4. Remove stale retry tasks
5. Remove GUID-scoped registry keys, MDM cert, scheduled tasks
6. Start `dmwappushservice` (Automatic)
7. Run `DeviceEnroller.exe /C /AutoenrollMDM` as SYSTEM
8. Trigger IME sync
9. Run `Invoke-IntuneEnrollmentDiagnostics` as post-check

Use `-Force` to skip confirmation prompts (for RMM scripts).

---

### `Get-IntuneEnrollmentSummary`

Returns a structured object for RMM pre-checks or monitoring.

```
EnrolledGUID    : xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
JoinType        : HAADJ
PpkgEnrolled    : False
PpkgNames       :
DuplicateGUIDs  : False
CertPresent     : True
CertExpired     : False
CertExpiry      : 2026-12-01
CertThumbprint  : 472B5CEE...
IMERunning      : True
DMWAPRunning    : True
DMWAPAutomatic  : True
ActiveTasks     : 35
OrphanedTasks   : 0
RetryTasks      : 7
```

---

### `Get-EnrollmentProvisioningPackages`

Lists installed provisioning packages that are enrollment-related. Filters by name/description keywords, PackageClass registry value, and EnrollmentType.

```powershell
Get-EnrollmentProvisioningPackages | Format-List
```

---

### Individual Repair Functions

| Function | What it does |
|---|---|
| `Repair-MDMUrls` | Sets the three MDM enrollment URLs in TenantInfo |
| `Repair-ExternallyManagedFlag` | Resets `ExternallyManaged` to `0` (fixes `0x80180026`) |
| `Remove-MAMLeftoverKeys` | Removes stale MAM enrollment keys |
| `Repair-DMWAPService` | Starts `dmwappushservice` and sets startup to Automatic |
| `Remove-EnrollmentArtifacts -Guid <guid>` | Removes all GUID-scoped keys, MDM cert, and tasks |
| `Remove-ProvisioningPackageAndArtifacts -Package <pkg>` | Removes ppkg and all its enrollment artifacts |
| `Remove-StaleRetryTasks` | Removes `Retry Schedule created for incomplete session` tasks |
| `Remove-OrphanedEnrollmentGUID -OrphanGuid <guid>` | Removes a duplicate/orphaned enrollment GUID |
| `Start-MDMReEnrollment` | Runs `DeviceEnroller.exe /C /AutoenrollMDM` as SYSTEM |

---

## Common Scenarios

### Device shows in Entra but not syncing in Intune
```powershell
Invoke-IntuneEnrollmentDiagnostics -Fix
```
If cert is present but thumbprint or EntDMID is mismatched, reboot and rerun — these typically self-resolve after a successful sync.

### Error `0x80180026`
Caused by `ExternallyManaged = 1`, often left by SCCM or a failed previous enrollment.
```powershell
Repair-ExternallyManagedFlag
Start-MDMReEnrollment
```

### "Device already managed by an organization" / MAM-to-MDM
```powershell
Remove-MAMLeftoverKeys
Start-MDMReEnrollment
```

### MDM cert expired or missing
```powershell
# Delete device from Intune/Entra portal first, then:
Invoke-IntuneReEnrollment
```

### Broken provisioning package (WCD) enrollment
```powershell
Invoke-IntuneEnrollmentDiagnostics -Fix
# Confirm removal at the prompt, then re-apply a new package manually
```

### dmwappushservice not surviving reboots
```powershell
Repair-DMWAPService
# Sets startup type to Automatic AND starts the service
```

### Clean up stale retry tasks only
```powershell
Remove-StaleRetryTasks
```

### HAADJ device showing warnings for SslClientCertReference / ProviderID
These are `[!] Warn` on modern HAADJ devices enrolled via the Entra registration path — they are not failures. The OMADM account structure that populates these values is not written during modern enrollment. No action required if the cert is valid and sync is working.

---

## Comparison with intunesyncdebugtool

| | intunesyncdebugtool | IntuneEnrollmentRepair |
|---|---|---|
| SYSTEM context | Downloads + runs PSExec | Native scheduled task |
| Code transparency | Base64-encoded payloads | Fully readable |
| Registry cleanup | Entire hive | GUID-scoped only |
| TPM cert handling | None | Detects, advises re-enrollment |
| MAM key cleanup | Not handled | Detected and removed |
| ExternallyManaged fix | Not handled | Detected and fixed |
| ppkg support | Not handled | Full detect/remove/cleanup |
| Duplicate GUID cleanup | Not handled | Detected and removed |
| HAADJ detection | Basic | 4-signal scoring, offline-safe |
| WManSvc cache cleanup | Not handled | Cleared during artifact removal |
| GUID resolution methods | 1 (PushLaunch task) | 3 (OMADM, ProviderID, task) |
| RMM-friendly output | No | `Get-IntuneEnrollmentSummary` |
| EDR/security friendly | No (PSExec download) | Yes |

---

## Output Key

| Prefix | Meaning |
|---|---|
| `[+]` Green | Check passed / action succeeded |
| `[-]` Red | Failure / action required |
| `[!]` Yellow | Warning / advisory — review but may not require action |
| `[*]` Cyan | Informational |
| `[=]` Magenta | Section header |

---

## License

MIT — free to use, modify, and distribute. No warranty. Test in non-production before deploying at scale.
