# Installation & Usage Guide

This guide covers everything needed to get `IntuneEnrollmentRepair` running on a device, from a one-off manual run to deploying it via RMM or making it permanently available across all admin sessions.

---

## Prerequisites

| Requirement | Detail |
|---|---|
| OS | Windows 10 1803+ or Windows 11 |
| PowerShell | 5.1 (built into Windows) or PowerShell 7+ |
| Privileges | Must be run as **Administrator** |
| Execution Policy | Must allow script execution (see below) |

---

## Step 1 — Check Execution Policy

PowerShell blocks unsigned scripts by default on many managed endpoints. Check first:

```powershell
Get-ExecutionPolicy -List
```

If `LocalMachine` or `CurrentUser` shows `Restricted` or `AllSigned`, you will need to adjust for the session or permanently:

```powershell
# Temporarily allow for this session only (safest for one-off use)
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

# Or permanently allow local scripts for all users on this machine
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
```

> `RemoteSigned` allows locally-written scripts to run unsigned while still requiring signatures on scripts downloaded from the internet. This is the recommended permanent setting for managed endpoints where admins run local tools.

---

## Step 2 — Install the Module

### Option A — PowerShell Gallery (recommended)

The simplest method. Run in an **elevated** PowerShell window:

```powershell
Install-Module -Name IntuneEnrollmentRepair
```

This installs the module permanently and makes it available in all future sessions without needing to `Import-Module` manually. The module is hosted on the [PowerShell Gallery](https://www.powershellgallery.com/packages/IntuneEnrollmentRepair/1.0.8).

To update to the latest version later:

```powershell
Update-Module -Name IntuneEnrollmentRepair
```

---

### Option B — Manual download

1. Download or copy the two module files to the device:
   - `IntuneEnrollmentRepair.psm1`
   - `IntuneEnrollmentRepair.psd1`

2. Place them together in a folder, for example:
   ```
   C:\Tools\IntuneEnrollmentRepair\
   ```

3. Copy to a PowerShell module directory so it is permanently discoverable:

```powershell
$dest = "$env:ProgramFiles\WindowsPowerShell\Modules\IntuneEnrollmentRepair"
New-Item -Path $dest -ItemType Directory -Force
Copy-Item -Path "C:\Tools\IntuneEnrollmentRepair\*" -Destination $dest -Force
```

Or import directly for a one-off session:

```powershell
Import-Module C:\Tools\IntuneEnrollmentRepair\IntuneEnrollmentRepair.psm1 -Force
```

Both files must be in the same directory. The `.psd1` manifest is required — do not deploy just the `.psm1`.

---

## Step 3 — First Run

Open an **elevated** PowerShell window (Run as Administrator).

```powershell
Import-Module IntuneEnrollmentRepair
```

Run a read-only health check first to understand the device's current state before making any changes:

```powershell
Invoke-IntuneEnrollmentDiagnostics
```

Review the output, then proceed based on what was found.

---

## Usage Guide

### Understanding the output

Every line is prefixed with a status indicator:

| Prefix | Colour | Meaning |
|---|---|---|
| `[+]` | Green | Check passed or action succeeded |
| `[-]` | Red | Failure — action required |
| `[!]` | Yellow | Warning — review but may not require action |
| `[*]` | Cyan | Informational |
| `[=]` | Magenta | Section header |

A `[!]` warning does not always mean something is broken. For example, on modern HAADJ devices, `SslClientCertReference` and `ProviderID` being absent are expected and shown as `[!]` rather than `[-]`.

---

### Scenario 1 — Standard health check (read-only)

Use this as your starting point on any device. Makes no changes.

```powershell
Invoke-IntuneEnrollmentDiagnostics
```

---

### Scenario 2 — Auto-fix safe issues

Fixes common issues without triggering re-enrollment. Safe to run on a production device.

```powershell
Invoke-IntuneEnrollmentDiagnostics -Fix
```

**What this fixes automatically:**
- Starts `dmwappushservice` if stopped, sets startup type to Automatic
- Starts IME service if stopped
- Resets `ExternallyManaged` flag (fixes error `0x80180026`)
- Removes MAM leftover enrollment keys
- Sets correct MDM enrollment URLs
- Removes stale `Retry Schedule` tasks
- Removes orphaned enrollment tasks (GUID no longer in registry)
- Prompts to remove duplicate/orphaned enrollment GUIDs
- On broken ppkg devices: prompts to remove the provisioning package and all artifacts

**What it does NOT do:**
- Trigger re-enrollment (`DeviceEnroller.exe`)
- Remove the active enrollment GUID or MDM certificate
- Clear `C:\Windows\ServiceState\wmansvc` (this happens only during full `Remove-EnrollmentArtifacts` or `Invoke-IntuneReEnrollment`, not during `-Fix` alone)
- Apply a new provisioning package

---

### Scenario 3 — Full re-enrollment

Use this when the MDM certificate is missing, expired, or the enrollment is fundamentally broken and `-Fix` alone cannot repair it.

> **Before running:** Delete the device record from the **Intune portal** and from **Entra ID** (if it appears there with a stale record). Failing to do so will result in a duplicate device object.

```powershell
Invoke-IntuneReEnrollment
```

You will be prompted to confirm. The process takes 2–5 minutes. A post-enrollment diagnostic runs automatically at the end.

To skip the confirmation prompt (for RMM deployment):

```powershell
Invoke-IntuneReEnrollment -Force
```

> **Note:** Do not use `Invoke-IntuneReEnrollment` on provisioning package (WCD/ppkg) enrolled devices. Use `Invoke-IntuneEnrollmentDiagnostics -Fix` instead — the module will warn you if it detects a ppkg.

---

### Scenario 4 — RMM / monitoring pre-check

`Get-IntuneEnrollmentSummary` returns a structured object rather than coloured console output, making it suitable for use in RMM scripts, monitoring agents, or logging pipelines.

```powershell
$summary = Get-IntuneEnrollmentSummary
$summary | Format-List

# Use individual properties in RMM logic
if (-not $summary.CertPresent) {
    # Trigger alert or remediation
}
if ($summary.RetryTasks -gt 0) {
    Remove-StaleRetryTasks
}
```

**Output fields:**

| Field | Type | Description |
|---|---|---|
| `EnrolledGUID` | String | Active enrollment GUID |
| `JoinType` | String | `HAADJ`, `EntraJoined`, or `Unknown` |
| `PpkgEnrolled` | Bool | Whether a ppkg enrollment was detected |
| `PpkgNames` | String | Name(s) of detected ppkg(s) |
| `DuplicateGUIDs` | Bool | Whether duplicate MS DM Server GUIDs exist |
| `CertPresent` | Bool | MDM certificate present in LocalMachine\My |
| `CertExpired` | Bool/String | Whether the cert is past its NotAfter date |
| `CertExpiry` | String | Cert expiry date (yyyy-MM-dd) |
| `CertThumbprint` | String | Cert thumbprint |
| `IMERunning` | Bool | IME service running |
| `DMWAPRunning` | Bool | dmwappushservice running |
| `DMWAPAutomatic` | Bool | dmwappushservice startup type is Automatic |
| `ActiveTasks` | Int | Count of active EnterpriseMgmt scheduled tasks |
| `OrphanedTasks` | Int | Count of tasks with no matching registry GUID |
| `RetryTasks` | Int | Count of stale retry session tasks |

---

### Scenario 5 — Targeted individual fixes

Each repair function can be called independently without running the full diagnostic flow:

```powershell
# Fix MDM enrollment URLs only
Repair-MDMUrls

# Fix ExternallyManaged flag only (error 0x80180026)
Repair-ExternallyManagedFlag

# Remove MAM leftover keys only
Remove-MAMLeftoverKeys

# Start dmwappushservice and set to Automatic
Repair-DMWAPService

# Remove stale retry tasks only
Remove-StaleRetryTasks

# Remove enrollment artifacts for a specific GUID
Remove-EnrollmentArtifacts -Guid 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'

# Remove an orphaned duplicate GUID
Remove-OrphanedEnrollmentGUID -OrphanGuid 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'

# Trigger re-enrollment as SYSTEM only (without full cleanup phases)
Start-MDMReEnrollment
```

---

## Uninstalling the Module

### If installed via PSGallery or module directory

```powershell
Uninstall-Module -Name IntuneEnrollmentRepair
```

### Remove from current session only

```powershell
Remove-Module IntuneEnrollmentRepair -Force
```

---

## Troubleshooting

### "Running scripts is disabled on this system"

```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
Import-Module .\IntuneEnrollmentRepair.psm1 -Force
```

### "The module was not loaded because no valid module file was found"

- Ensure both `.psm1` and `.psd1` files are in the same directory
- Ensure the file was saved as UTF-8 with BOM (the provided files are already correct)
- Try importing with the full path: `Import-Module C:\full\path\IntuneEnrollmentRepair.psm1 -Force`

### "Access is denied" during repair operations

The session must be elevated. Right-click PowerShell and select **Run as Administrator**, then re-import and re-run.

### Re-enrollment appears to complete but device does not appear in Intune

- Wait 5–10 minutes — Intune sync can take time after initial enrollment
- Ensure the old device record was deleted from the portal before re-enrolling
- Run `Invoke-IntuneEnrollmentDiagnostics` again to confirm the new GUID and cert are in place
- Trigger a manual sync: `Start-IMESync` or open the Company Portal app and hit Sync

### Module loads but Invoke-IntuneEnrollmentDiagnostics shows no output

Ensure you are running in an interactive elevated session, not a background or non-interactive context. The diagnostic writes coloured host output which requires an interactive console host.
