# Windows 11 Debloat Automation

A conservative PowerShell script for removing selected Windows 11 packaged apps, disabling telemetry services, suppressing consumer suggestions, and removing explicitly listed startup entries.

## Safety

The script requires administrator privileges and performs a read-only drift check first. If changes are required, it creates a fresh restore point named `Pre-Debloat Restore Point` before starting them. If the system already matches the requested configuration, the script performs no writes and does not require another restore point or restart.

Windows normally limits restore-point creation to one per 24 hours. If configuration drift requires another modifying run during that window, the script stops safely unless you explicitly supply `-ContinueWithoutRestorePoint`.

Review the configurable package, service, and startup arrays before running the script. Calculator, Notepad, Windows Terminal, AppX frameworks, and other core dependencies are not included in the default removal list.

`HKCU` changes affect the account running the elevated script. Run the script first in a disposable Windows 11 virtual machine before using it on a primary computer.

## Run

Open PowerShell as Administrator, change to the repository directory, and preview the changes:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-Windows11Debloat.ps1 -WhatIf
```

Apply the configuration:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-Windows11Debloat.ps1
```

PowerShell 7 is also supported. The script automatically relaunches itself in 64-bit Windows PowerShell 5.1 for the Windows-only AppX and System Restore cmdlets:

```powershell
pwsh.exe -NoProfile -File .\scripts\Invoke-Windows11Debloat.ps1 -WhatIf
```

The default invocation does not prompt for every change. Supply `-Confirm` to request confirmation. If restore-point creation is unavailable and you explicitly accept the risk, `-ContinueWithoutRestorePoint` allows the remaining phases to run and records a warning.

## Results and exit codes

The script prints color-coded phase and item results:

- `Success`: the requested end state was applied.
- `Planned`: the operation would run, but `-WhatIf` prevented it.
- `Skipped`: the item was absent or confirmation was declined.
- `Warning`: execution continued with an explicitly accepted safety warning.
- `Failure`: an operation failed; the script exits with code `1` after the summary.

## Tests

The tests support Pester 3.4 and later:

```powershell
Invoke-Pester -Path .\tests
```

The test suite parses and safely imports the script, then exercises drift detection, dry-run reporting, completion decisions, relaunch guards, and protected package configuration without applying system changes.

## Repository structure

```text
windows11-debloat-automation/
|-- scripts/
|   `-- Invoke-Windows11Debloat.ps1
|-- tests/
|   `-- Invoke-Windows11Debloat.Tests.ps1
|-- docs/
|   |-- requirements.md
|   `-- requirements-analysis.md
|-- .gitignore
`-- README.md
```

- `scripts/` contains executable automation.
- `tests/` contains non-mutating Pester checks.
- `docs/` contains requirements and design analysis.
