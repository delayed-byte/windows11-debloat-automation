<#
.SYNOPSIS
    Applies a conservative, repeatable Windows 11 debloat configuration.

.DESCRIPTION
    Must be run from an elevated Windows PowerShell session. By default, the
    script stops before making changes if it cannot establish a qualifying restore point.
    HKCU changes apply only to the account running this script.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\scripts\Invoke-Windows11Debloat.ps1

.EXAMPLE
    # Explicitly accept the risk of continuing if System Restore is unavailable.
    powershell.exe -ExecutionPolicy Bypass -File .\scripts\Invoke-Windows11Debloat.ps1 -ContinueWithoutRestorePoint
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [switch]$ContinueWithoutRestorePoint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows-only AppX and restore-point cmdlets require 64-bit Windows PowerShell.
# Transparently hand off PowerShell 7 and 32-bit Windows PowerShell invocations.
$script:IsDotSourced = $MyInvocation.InvocationName -eq '.'
if (-not $script:IsDotSourced) {
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
$RestorePointDescription = 'Pre-Debloat Restore Point'
$RestorePointMaximumAgeHours = 24
$StartupRegistryPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
)
$RegistryDwordSettings = @(
    [pscustomobject]@{ Phase = 'Telemetry'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowTelemetry'; Value = 0; Area = 'Telemetry' },
    [pscustomobject]@{ Phase = 'Telemetry'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection'; Name = 'AllowTelemetry'; Value = 0; Area = 'Telemetry' },
    [pscustomobject]@{ Phase = 'Consumer'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SystemPaneSuggestionsEnabled'; Value = 0; Area = 'Current-user UI settings' },
    [pscustomobject]@{ Phase = 'Consumer'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338388Enabled'; Value = 0; Area = 'Current-user UI settings' },
    [pscustomobject]@{ Phase = 'Consumer'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338389Enabled'; Value = 0; Area = 'Current-user UI settings' },
    [pscustomobject]@{ Phase = 'Consumer'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-353696Enabled'; Value = 0; Area = 'Current-user UI settings' },
    [pscustomobject]@{ Phase = 'Consumer'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsConsumerFeatures'; Value = 1; Area = 'Machine UI policy' }
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

function Get-DeclinedStatus {
    param([Parameter(Mandatory)][bool]$IsWhatIf)
    if ($IsWhatIf) { return 'Planned' }
    return 'Skipped'
}

function Get-CompletionMessage {
    param(
        [Parameter(Mandatory)][int]$FailureCount,
        [Parameter(Mandatory)][int]$WarningCount,
        [Parameter(Mandatory)][int]$PlannedCount,
        [Parameter(Mandatory)][int]$AppliedCount,
        [Parameter(Mandatory)][bool]$IsWhatIf
    )

    if ($IsWhatIf) {
        if ($FailureCount -gt 0) { return "Preview failed with $FailureCount failure(s). No changes were made." }
        if ($PlannedCount -eq 0) { return 'Preview complete. The system already matches the requested configuration; no changes or restart are required.' }
        return "Preview complete with $PlannedCount planned operation(s). No changes were made; do not restart for this preview."
    }
    if ($AppliedCount -eq 0) {
        if ($FailureCount -gt 0) { return "Failed with $FailureCount failure(s). No debloat changes were applied; no restart is required." }
        return 'Completed. No debloat changes were applied; no restart is required.'
    }
    return "Completed with $FailureCount failure(s) and $WarningCount warning(s). Restart Windows to apply all changes."
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

function Test-DwordValueMatches {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Value
    )

    if (-not (Test-Path -LiteralPath $Path -ErrorAction Stop)) { return $false }
    $key = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($key.GetValueNames() -notcontains $Name) { return $false }
    $currentValue = $key.GetValue($Name)
    if ($currentValue -isnot [int]) { return $false }
    return $currentValue -eq $Value
}

function Test-StartupValueExists {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path -ErrorAction Stop)) { return $false }
    $key = Get-Item -LiteralPath $Path -ErrorAction Stop
    return $key.GetValueNames() -contains $Name
}

function Test-DebloatChangesRequired {
    [CmdletBinding()]
    param()

    $provisionedPackages = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop)
    foreach ($packageName in $BloatwarePackages) {
        if (@(Get-AppxPackage -Name $packageName -AllUsers -ErrorAction Stop).Count -gt 0) { return $true }
        if (@($provisionedPackages | Where-Object { $_.DisplayName -eq $packageName }).Count -gt 0) { return $true }
    }

    foreach ($setting in $RegistryDwordSettings) {
        if (-not (Test-DwordValueMatches -Path $setting.Path -Name $setting.Name -Value $setting.Value)) { return $true }
    }

    $services = @(Get-Service -ErrorAction Stop)
    foreach ($serviceName in $TelemetryServices) {
        $service = $services | Where-Object { $_.Name -eq $serviceName } | Select-Object -First 1
        if ($null -ne $service -and ($service.Status -ne 'Stopped' -or $service.StartType -ne 'Disabled')) { return $true }
    }

    foreach ($path in $StartupRegistryPaths) {
        foreach ($valueName in $StartupValueNames) {
            if (Test-StartupValueExists -Path $path -Name $valueName) { return $true }
        }
    }
    return $false
}

function Set-DwordValue {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Value,
        [Parameter(Mandatory)][string]$Area
    )

    try {
        if (Test-DwordValueMatches -Path $Path -Name $Name -Value $Value) {
            Add-Result -Area $Area -Item $Name -Status Skipped -Detail "Already set to $Value"
            return
        }
        if ($PSCmdlet.ShouldProcess("$Path\\$Name", "Set DWORD to $Value")) {
            Ensure-RegistryKey -Path $Path
            New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
            Add-Result -Area $Area -Item $Name -Status Success -Detail "Set to $Value"
        }
        else {
            $status = Get-DeclinedStatus -IsWhatIf $WhatIfPreference
            Add-Result -Area $Area -Item $Name -Status $status -Detail "DWORD would be set to $Value"
        }
    }
    catch {
        Add-Result -Area $Area -Item $Name -Status Failure -Detail $_.Exception.Message
    }
}

function Get-RecentDebloatRestorePoint {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 168)][int]$MaximumAgeHours = $script:RestorePointMaximumAgeHours,
        [ValidateNotNullOrEmpty()][string]$Description = $script:RestorePointDescription
    )

    $now = Get-Date
    $cutoff = $now.AddHours(-$MaximumAgeHours)
    $matchingRestorePoints = @(Get-ComputerRestorePoint -ErrorAction Stop | Where-Object {
        $_.Description -eq $Description
    })

    $candidates = @(
        foreach ($restorePoint in $matchingRestorePoints) {
            try {
                $creationTime = if ($restorePoint.CreationTime -is [datetime]) {
                    $restorePoint.CreationTime
                }
                else {
                    [Management.ManagementDateTimeConverter]::ToDateTime([string]$restorePoint.CreationTime)
                }
                if ($creationTime -ge $cutoff -and $creationTime -le $now) {
                    [pscustomobject]@{
                        RestorePoint = $restorePoint
                        CreationTime = $creationTime
                    }
                }
            }
            catch {
                # Ignore malformed historical records and continue checking others.
            }
        }
    )

    $newestCandidate = $candidates | Sort-Object -Property CreationTime -Descending | Select-Object -First 1
    if ($null -eq $newestCandidate) { return $null }
    return $newestCandidate.RestorePoint
}

function New-SafetyRestorePoint {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    Write-Phase 'System safety and rollback'

    $recentRestorePoint = $null
    try {
        $recentRestorePoint = Get-RecentDebloatRestorePoint
    }
    catch {
        Add-Result -Area 'Safety' -Item 'Restore point inventory' -Status Warning -Detail "Could not inspect existing restore points; attempting a new checkpoint: $($_.Exception.Message)"
    }

    try {
        $safetyAction = if ($null -ne $recentRestorePoint) {
            "Enable System Restore and reuse $RestorePointDescription"
        }
        else {
            "Enable System Restore and create $RestorePointDescription"
        }

        if (-not $PSCmdlet.ShouldProcess('C:', $safetyAction)) {
            $status = Get-DeclinedStatus -IsWhatIf $WhatIfPreference
            $detail = if ($null -ne $recentRestorePoint) {
                'System Restore would be enabled and the recent restore point reused'
            }
            else {
                'System Restore would be enabled and a restore point created'
            }
            Add-Result -Area 'Safety' -Item $RestorePointDescription -Status $status -Detail $detail
            Write-PhaseComplete 'System safety and rollback'
            return $WhatIfPreference
        }

        Enable-ComputerRestore -Drive 'C:\' -ErrorAction Stop
        if ($null -ne $recentRestorePoint) {
            Add-Result -Area 'Safety' -Item $RestorePointDescription -Status Success -Detail 'System Restore enabled; reusing the newest matching restore point from within the previous 24 hours'
            Write-PhaseComplete 'System safety and rollback'
            return $true
        }

        Checkpoint-Computer -Description $RestorePointDescription -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Add-Result -Area 'Safety' -Item $RestorePointDescription -Status Success
        Write-PhaseComplete 'System safety and rollback'
        return $true
    }
    catch {
        Add-Result -Area 'Safety' -Item $RestorePointDescription -Status Failure -Detail $_.Exception.Message
        Write-Host 'Failed: System safety and rollback' -ForegroundColor Red
        return $false
    }
}

function Remove-BloatwarePackages {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
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
        try {
            $installedPackages = @(Get-AppxPackage -Name $packageName -AllUsers -ErrorAction Stop)
        }
        catch {
            Add-Result -Area 'App removal' -Item "$packageName (inventory)" -Status Failure -Detail $_.Exception.Message
            continue
        }
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
                        $status = Get-DeclinedStatus -IsWhatIf $WhatIfPreference
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
                        $status = Get-DeclinedStatus -IsWhatIf $WhatIfPreference
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
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    Write-Phase 'Configuring telemetry and tracking services'
    foreach ($setting in $RegistryDwordSettings | Where-Object { $_.Phase -eq 'Telemetry' }) {
        Set-DwordValue -Path $setting.Path -Name $setting.Name -Value $setting.Value -Area $setting.Area
    }

    try {
        $services = @(Get-Service -ErrorAction Stop)
    }
    catch {
        Add-Result -Area 'Telemetry service' -Item 'Service inventory' -Status Failure -Detail $_.Exception.Message
        Write-Host 'Failed: Configuring telemetry and tracking services' -ForegroundColor Red
        return
    }
    foreach ($serviceName in $TelemetryServices) {
        $service = $services | Where-Object { $_.Name -eq $serviceName } | Select-Object -First 1
        if ($null -eq $service) {
            Add-Result -Area 'Telemetry service' -Item $serviceName -Status Skipped -Detail 'Service not present'
            continue
        }
        try {
            if ($service.Status -eq 'Stopped' -and $service.StartType -eq 'Disabled') {
                Add-Result -Area 'Telemetry service' -Item $serviceName -Status Skipped -Detail 'Already stopped and disabled'
                continue
            }
            if ($PSCmdlet.ShouldProcess($serviceName, 'Stop service and set startup type to Disabled')) {
                if ($service.Status -ne 'Stopped') {
                    Stop-Service -Name $serviceName -Force -ErrorAction Stop
                }
                Set-Service -Name $serviceName -StartupType Disabled -ErrorAction Stop
                Add-Result -Area 'Telemetry service' -Item $serviceName -Status Success -Detail 'Stopped and disabled'
            }
            else {
                $status = Get-DeclinedStatus -IsWhatIf $WhatIfPreference
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
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    Write-Phase 'Disabling suggestions and consumer features'
    foreach ($setting in $RegistryDwordSettings | Where-Object { $_.Phase -eq 'Consumer' }) {
        Set-DwordValue -Path $setting.Path -Name $setting.Name -Value $setting.Value -Area $setting.Area
    }
    Write-PhaseComplete 'Disabling suggestions and consumer features'
}

function Remove-StartupEntries {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    Write-Phase 'Removing selected startup entries'
    foreach ($path in $StartupRegistryPaths) {
        foreach ($valueName in $StartupValueNames) {
            try {
                if (-not (Test-StartupValueExists -Path $path -Name $valueName)) {
                    Add-Result -Area 'Startup' -Item "$path\\$valueName" -Status Skipped -Detail 'Value not present'
                    continue
                }
                if ($PSCmdlet.ShouldProcess("$path\\$valueName", 'Remove startup value')) {
                    Remove-ItemProperty -Path $path -Name $valueName -ErrorAction Stop
                    Add-Result -Area 'Startup' -Item "$path\\$valueName" -Status Success
                }
                else {
                    $status = Get-DeclinedStatus -IsWhatIf $WhatIfPreference
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

function Invoke-DebloatWorkflow {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([switch]$ContinueWithoutRestorePoint)

    $script:Results.Clear()
    $changesRequired = $false
    $restorePointAttempted = $false
    $modificationPhasesAttempted = $false

    Write-Phase 'Checking current configuration'
    try {
        $changesRequired = Test-DebloatChangesRequired
        Write-PhaseComplete 'Checking current configuration'
    }
    catch {
        Add-Result -Area 'Preflight' -Item 'Configuration inventory' -Status Failure -Detail $_.Exception.Message
        Write-Host 'Failed: Checking current configuration' -ForegroundColor Red
        $changesRequired = $false
    }

    if (@($Results | Where-Object { $_.Status -eq 'Failure' }).Count -eq 0) {
        if ($changesRequired) {
            $restorePointAttempted = $true
            $restorePointCreated = New-SafetyRestorePoint
            if (-not $restorePointCreated -and -not $ContinueWithoutRestorePoint) {
                if (@($Results | Where-Object { $_.Status -eq 'Failure' }).Count -eq 0) {
                    Add-Result -Area 'Safety' -Item 'Restore point requirement' -Status Failure -Detail 'No qualifying recent restore point was available and a new restore point could not be created; debloat changes were not started'
                }
            }
            elseif (-not $restorePointCreated) {
                Add-Result -Area 'Safety' -Item 'Restore point policy' -Status Warning -Detail 'Continuing by explicit user request'
            }

            if ($restorePointCreated -or $ContinueWithoutRestorePoint) {
                $modificationPhasesAttempted = $true
                Remove-BloatwarePackages
                Disable-Telemetry
                Disable-ConsumerFeatures
                Remove-StartupEntries
            }
        }
        else {
            Add-Result -Area 'Safety' -Item 'Restore point' -Status Skipped -Detail 'No configuration changes are required'
        }
    }

    Write-Phase 'Completion summary'
    $Results | Format-Table -AutoSize | Out-Host
    $failures = @($Results | Where-Object { $_.Status -eq 'Failure' })
    $warnings = @($Results | Where-Object { $_.Status -eq 'Warning' })
    $planned = @($Results | Where-Object { $_.Status -eq 'Planned' })
    $applied = @($Results | Where-Object { $_.Status -eq 'Success' -and $_.Area -ne 'Safety' })
    $completionMessage = Get-CompletionMessage -FailureCount $failures.Count -WarningCount $warnings.Count -PlannedCount $planned.Count -AppliedCount $applied.Count -IsWhatIf $WhatIfPreference
    Write-Host $completionMessage -ForegroundColor $(if ($failures.Count -gt 0) { 'Red' } elseif ($warnings.Count -gt 0) { 'Yellow' } else { 'Green' })

    return [pscustomobject]@{
        ExitCode = if ($failures.Count -gt 0) { 1 } else { 0 }
        ChangesRequired = $changesRequired
        RestorePointAttempted = $restorePointAttempted
        ModificationPhasesAttempted = $modificationPhasesAttempted
        AppliedCount = $applied.Count
        Message = $completionMessage
        Results = @($Results)
    }
}

if (-not $script:IsDotSourced) {
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

    $workflowResult = Invoke-DebloatWorkflow -ContinueWithoutRestorePoint:$ContinueWithoutRestorePoint
    if ($workflowResult.ExitCode -ne 0) { exit $workflowResult.ExitCode }
}
