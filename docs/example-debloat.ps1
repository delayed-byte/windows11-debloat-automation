<#
.SYNOPSIS
    Applies a conservative, repeatable Windows 11 debloat configuration.

.DESCRIPTION
    Must be run from an elevated Windows PowerShell session. By default, the
    script stops before making changes if it cannot create a restore point.
    HKCU changes apply only to the account running this script.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\example-debloat.ps1

.EXAMPLE
    # Explicitly accept the risk of continuing if System Restore is unavailable.
    powershell.exe -ExecutionPolicy Bypass -File .\example-debloat.ps1 -ContinueWithoutRestorePoint
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [switch]$ContinueWithoutRestorePoint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows-only AppX and restore-point cmdlets require 64-bit Windows PowerShell.
# Transparently hand off PowerShell 7 and 32-bit Windows PowerShell invocations.
if (-not [Environment]::Is64BitOperatingSystem) {
    Write-Error 'This script supports 64-bit Windows 11 only.'
    exit 1
}

if ($PSVersionTable.PSVersion.Major -ge 7 -or -not [Environment]::Is64BitProcess) {
    $windowsPowerShellDirectory = if ([Environment]::Is64BitProcess) { 'System32' } else { 'Sysnative' }
    $windowsPowerShell = Join-Path $env:SystemRoot "$windowsPowerShellDirectory\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path -LiteralPath $windowsPowerShell)) {
        Write-Error 'Windows PowerShell 5.1 is required for AppX and System Restore operations but could not be found.'
        exit 1
    }

    $windowsPowerShellArguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $PSCommandPath
    )
    if ($ContinueWithoutRestorePoint) { $windowsPowerShellArguments += '-ContinueWithoutRestorePoint' }
    if ($WhatIfPreference) { $windowsPowerShellArguments += '-WhatIf' }
    # Windows PowerShell 5.1 cannot bind an explicit Boolean value supplied to a
    # switch parameter through -File. Omission represents $false.
    if ($PSBoundParameters.ContainsKey('Confirm') -and [bool]$PSBoundParameters['Confirm']) {
        $windowsPowerShellArguments += '-Confirm'
    }

    & $windowsPowerShell @windowsPowerShellArguments
    exit $LASTEXITCODE
}

# Edit these explicit identifiers to customize the removal set. Do not add AppX
# frameworks or core applications such as Calculator, Notepad, or Windows Terminal.
$BloatwarePackages = @(
    'Microsoft.3DBuilder',
    'Microsoft.BingNews',
    'Microsoft.BingWeather',
    'Microsoft.GetHelp',
    'Microsoft.Getstarted',
    'Microsoft.MicrosoftOfficeHub',
    'Microsoft.MicrosoftSolitaireCollection',
    'Microsoft.People',
    'Microsoft.PowerAutomateDesktop',
    'Microsoft.Todos',
    'Microsoft.YourPhone',
    'Microsoft.ZuneMusic',
    'Microsoft.ZuneVideo',
    'Microsoft.GamingApp',
    'Microsoft.Xbox.TCUI',
    'Microsoft.XboxApp',
    'Microsoft.XboxGameOverlay',
    'Microsoft.XboxGamingOverlay',
    'Microsoft.XboxIdentityProvider',
    'Microsoft.XboxSpeechToTextOverlay',
    'Clipchamp.Clipchamp',
    'SpotifyAB.SpotifyMusic',
    'Disney.37853FC22B2CE'
)

$TelemetryServices = @('DiagTrack', 'dmwappushservice')
$StartupValueNames = @('MicrosoftEdgeAutoLaunch')
$StartupRegistryPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
)

$Results = [System.Collections.Generic.List[object]]::new()

function Write-Phase {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "`n== $Message ==" -ForegroundColor Cyan
}

function Write-PhaseComplete {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "Completed: $Message" -ForegroundColor Cyan
}

function Add-Result {
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$Item,
        [Parameter(Mandatory)][ValidateSet('Success', 'Planned', 'Skipped', 'Warning', 'Failure')][string]$Status,
        [string]$Detail = ''
    )

    $script:Results.Add([pscustomobject]@{
        Area = $Area; Item = $Item; Status = $Status; Detail = $Detail
    })

    $color = @{ Success = 'Green'; Planned = 'Blue'; Skipped = 'DarkYellow'; Warning = 'Yellow'; Failure = 'Red' }[$Status]
    Write-Host "[$Status] $Area - $Item$(if ($Detail) { ": $Detail" })" -ForegroundColor $color
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-RegistryKey {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
}

function Set-DwordValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Value,
        [Parameter(Mandatory)][string]$Area
    )

    try {
        if ($PSCmdlet.ShouldProcess("$Path\\$Name", "Set DWORD to $Value")) {
            Ensure-RegistryKey -Path $Path
            New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
            Add-Result -Area $Area -Item $Name -Status Success -Detail "Set to $Value"
        }
        else {
            $status = if ($WhatIfPreference) { 'Planned' } else { 'Skipped' }
            Add-Result -Area $Area -Item $Name -Status $status -Detail "DWORD would be set to $Value"
        }
    }
    catch {
        Add-Result -Area $Area -Item $Name -Status Failure -Detail $_.Exception.Message
    }
}

function New-SafetyRestorePoint {
    Write-Phase 'System safety and rollback'

    # Checkpoint-Computer permits only one restore point per 24 hours. Reusing a
    # recent restore point created by this script makes sequential runs safe and
    # idempotent without weakening the rollback guarantee.
    $restorePointCutoff = (Get-Date).AddHours(-24)
    $recentRestorePoint = Get-ComputerRestorePoint -ErrorAction SilentlyContinue |
        Where-Object { $_.Description -eq 'Pre-Debloat Restore Point' } |
        ForEach-Object {
            try {
                $creationTime = if ($_.CreationTime -is [datetime]) {
                    $_.CreationTime
                }
                else {
                    [Management.ManagementDateTimeConverter]::ToDateTime([string]$_.CreationTime)
                }
                if ($creationTime -ge $restorePointCutoff) { $_ }
            }
            catch {
                # Ignore malformed historical entries and attempt a new checkpoint.
            }
        } |
        Select-Object -First 1

    if ($null -ne $recentRestorePoint) {
        Add-Result -Area 'Safety' -Item 'Pre-Debloat Restore Point' -Status Success -Detail 'Reusing a restore point created within the last 24 hours'
        Write-PhaseComplete 'System safety and rollback'
        return $true
    }

    try {
        if (-not $PSCmdlet.ShouldProcess('C:', 'Enable System Restore and create Pre-Debloat Restore Point')) {
            $status = if ($WhatIfPreference) { 'Planned' } else { 'Skipped' }
            Add-Result -Area 'Safety' -Item 'Pre-Debloat Restore Point' -Status $status -Detail 'System Restore would be enabled and a restore point created'
            Write-PhaseComplete 'System safety and rollback'
            return $WhatIfPreference
        }

        Enable-ComputerRestore -Drive 'C:\' -ErrorAction Stop
        Checkpoint-Computer -Description 'Pre-Debloat Restore Point' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Add-Result -Area 'Safety' -Item 'Pre-Debloat Restore Point' -Status Success
        Write-PhaseComplete 'System safety and rollback'
        return $true
    }
    catch {
        Add-Result -Area 'Safety' -Item 'Pre-Debloat Restore Point' -Status Failure -Detail $_.Exception.Message
        Write-Host 'Failed: System safety and rollback' -ForegroundColor Red
        return $false
    }
}

function Remove-BloatwarePackages {
    Write-Phase 'Removing selected AppX packages'
    try {
        $provisionedPackages = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop)
    }
    catch {
        Add-Result -Area 'App removal' -Item 'Provisioned package inventory' -Status Failure -Detail $_.Exception.Message
        Write-Host 'Failed: Removing selected AppX packages' -ForegroundColor Red
        return
    }

    foreach ($packageName in $BloatwarePackages) {
        $installedPackages = @(Get-AppxPackage -Name $packageName -AllUsers -ErrorAction SilentlyContinue)
        if ($installedPackages.Count -eq 0) {
            Add-Result -Area 'App removal' -Item "$packageName (installed)" -Status Skipped -Detail 'Not installed'
        }
        else {
            foreach ($package in $installedPackages) {
                try {
                    if ($PSCmdlet.ShouldProcess($package.PackageFullName, 'Remove AppX package for all users')) {
                        Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop
                        Add-Result -Area 'App removal' -Item $package.PackageFullName -Status Success
                    }
                    else {
                        $status = if ($WhatIfPreference) { 'Planned' } else { 'Skipped' }
                        Add-Result -Area 'App removal' -Item $package.PackageFullName -Status $status -Detail 'Installed package would be removed for all users'
                    }
                }
                catch {
                    Add-Result -Area 'App removal' -Item $package.PackageFullName -Status Failure -Detail $_.Exception.Message
                }
            }
        }

        $provisionedMatches = @($provisionedPackages | Where-Object { $_.DisplayName -eq $packageName })
        if ($provisionedMatches.Count -eq 0) {
            Add-Result -Area 'App removal' -Item "$packageName (provisioned)" -Status Skipped -Detail 'Not provisioned'
        }
        else {
            foreach ($package in $provisionedMatches) {
                try {
                    if ($PSCmdlet.ShouldProcess($package.PackageName, 'Remove provisioned AppX package')) {
                        Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName -ErrorAction Stop | Out-Null
                        Add-Result -Area 'App removal' -Item $package.PackageName -Status Success -Detail 'Provisioning removed'
                    }
                    else {
                        $status = if ($WhatIfPreference) { 'Planned' } else { 'Skipped' }
                        Add-Result -Area 'App removal' -Item $package.PackageName -Status $status -Detail 'Provisioned package would be removed'
                    }
                }
                catch {
                    Add-Result -Area 'App removal' -Item $package.PackageName -Status Failure -Detail $_.Exception.Message
                }
            }
        }
    }
    Write-PhaseComplete 'Removing selected AppX packages'
}

function Disable-Telemetry {
    Write-Phase 'Configuring telemetry and tracking services'
    Set-DwordValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'AllowTelemetry' -Value 0 -Area 'Telemetry'
    Set-DwordValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' -Name 'AllowTelemetry' -Value 0 -Area 'Telemetry'

    foreach ($serviceName in $TelemetryServices) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($null -eq $service) {
            Add-Result -Area 'Telemetry service' -Item $serviceName -Status Skipped -Detail 'Service not present'
            continue
        }
        try {
            if ($PSCmdlet.ShouldProcess($serviceName, 'Stop service and set startup type to Disabled')) {
                if ($service.Status -ne 'Stopped') {
                    Stop-Service -Name $serviceName -Force -ErrorAction Stop
                }
                Set-Service -Name $serviceName -StartupType Disabled -ErrorAction Stop
                Add-Result -Area 'Telemetry service' -Item $serviceName -Status Success -Detail 'Stopped and disabled'
            }
            else {
                $status = if ($WhatIfPreference) { 'Planned' } else { 'Skipped' }
                Add-Result -Area 'Telemetry service' -Item $serviceName -Status $status -Detail 'Service would be stopped and disabled'
            }
        }
        catch {
            Add-Result -Area 'Telemetry service' -Item $serviceName -Status Failure -Detail $_.Exception.Message
        }
    }
    Write-PhaseComplete 'Configuring telemetry and tracking services'
}

function Disable-ConsumerFeatures {
    Write-Phase 'Disabling suggestions and consumer features'
    $contentDeliveryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    foreach ($name in @(
        'SystemPaneSuggestionsEnabled',
        'SubscribedContent-338388Enabled',
        'SubscribedContent-338389Enabled',
        'SubscribedContent-353696Enabled'
    )) {
        Set-DwordValue -Path $contentDeliveryPath -Name $name -Value 0 -Area 'Current-user UI settings'
    }
    Set-DwordValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableWindowsConsumerFeatures' -Value 1 -Area 'Machine UI policy'
    Write-PhaseComplete 'Disabling suggestions and consumer features'
}

function Remove-StartupEntries {
    Write-Phase 'Removing selected startup entries'
    foreach ($path in $StartupRegistryPaths) {
        foreach ($valueName in $StartupValueNames) {
            try {
                $existingValue = Get-ItemProperty -Path $path -Name $valueName -ErrorAction SilentlyContinue
                if ($null -eq $existingValue) {
                    Add-Result -Area 'Startup' -Item "$path\\$valueName" -Status Skipped -Detail 'Value not present'
                    continue
                }
                if ($PSCmdlet.ShouldProcess("$path\\$valueName", 'Remove startup value')) {
                    Remove-ItemProperty -Path $path -Name $valueName -ErrorAction Stop
                    Add-Result -Area 'Startup' -Item "$path\\$valueName" -Status Success
                }
                else {
                    $status = if ($WhatIfPreference) { 'Planned' } else { 'Skipped' }
                    Add-Result -Area 'Startup' -Item "$path\\$valueName" -Status $status -Detail 'Startup value would be removed'
                }
            }
            catch {
                Add-Result -Area 'Startup' -Item "$path\\$valueName" -Status Failure -Detail $_.Exception.Message
            }
        }
    }
    Write-PhaseComplete 'Removing selected startup entries'
}

if (-not (Test-Administrator)) {
    Write-Error 'Administrator privileges are required. Re-run PowerShell using Run as Administrator.'
    exit 1
}

$os = Get-CimInstance -ClassName Win32_OperatingSystem
if ($os.Caption -notmatch 'Windows 11') {
    Write-Error "This script supports Windows 11 only. Detected: $($os.Caption)"
    exit 1
}

foreach ($requiredCommand in @('Get-AppxPackage', 'Get-AppxProvisionedPackage', 'Enable-ComputerRestore', 'Checkpoint-Computer', 'Get-ComputerRestorePoint')) {
    if (Get-Command -Name $requiredCommand -ErrorAction SilentlyContinue) { continue }
    Write-Error "Required command '$requiredCommand' is unavailable in Windows PowerShell 5.1."
    exit 1
}

$restorePointCreated = New-SafetyRestorePoint
if (-not $restorePointCreated -and -not $ContinueWithoutRestorePoint) {
    Write-Error 'No restore point was created. Debloat changes were not started; System Restore might have been enabled. Use -ContinueWithoutRestorePoint only if you explicitly accept this risk.'
    exit 1
}
if (-not $restorePointCreated) {
    Add-Result -Area 'Safety' -Item 'Restore point policy' -Status Warning -Detail 'Continuing by explicit user request'
}

Remove-BloatwarePackages
Disable-Telemetry
Disable-ConsumerFeatures
Remove-StartupEntries

Write-Phase 'Completion summary'
$Results | Format-Table -AutoSize
$failures = @($Results | Where-Object { $_.Status -eq 'Failure' })
$warnings = @($Results | Where-Object { $_.Status -eq 'Warning' })
Write-Host "Completed with $($failures.Count) failure(s) and $($warnings.Count) warning(s). Restart Windows to apply all changes." -ForegroundColor $(if ($failures.Count -gt 0) { 'Red' } elseif ($warnings.Count -gt 0) { 'Yellow' } else { 'Green' })

if ($failures.Count -gt 0) { exit 1 }
