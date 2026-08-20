Describe 'Invoke-Windows11Debloat.ps1' {
    BeforeAll {
        $scriptPath = Join-Path $PSScriptRoot '..\scripts\Invoke-Windows11Debloat.ps1'
        $scriptContent = Get-Content -LiteralPath $scriptPath -Raw
        $tokens = $null
        $parseErrors = $null
        $scriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $scriptPath,
            [ref]$tokens,
            [ref]$parseErrors
        )
        . $scriptPath

        function Assert-True {
            param(
                [Parameter(Mandatory)][bool]$Condition,
                [Parameter(Mandatory)][string]$Message
            )
            if (-not $Condition) { throw $Message }
        }
    }

    It 'has valid PowerShell syntax' {
        Assert-True -Condition ($parseErrors.Count -eq 0) -Message 'The script contains PowerShell parse errors.'
        Assert-True -Condition ($null -ne $scriptAst) -Message 'The script AST was not created.'
    }

    It 'classifies declined operations by actual execution mode' {
        Assert-True -Condition ((Get-DeclinedStatus -IsWhatIf $true) -eq 'Planned') -Message 'WhatIf operations must be planned.'
        Assert-True -Condition ((Get-DeclinedStatus -IsWhatIf $false) -eq 'Skipped') -Message 'Declined operations must be skipped.'
    }

    It 'does not recommend a restart for a preview' {
        $message = Get-CompletionMessage -FailureCount 0 -WarningCount 0 -PlannedCount 3 -AppliedCount 0 -IsWhatIf $true
        Assert-True -Condition ($message -match 'No changes were made') -Message 'Preview output must state that no changes were made.'
        Assert-True -Condition ($message -match 'do not restart') -Message 'Preview output must not recommend a restart.'
    }

    It 'does not recommend a restart when the configuration already matches' {
        $message = Get-CompletionMessage -FailureCount 0 -WarningCount 0 -PlannedCount 0 -AppliedCount 0 -IsWhatIf $false
        Assert-True -Condition ($message -match 'no restart is required') -Message 'An unchanged run must not recommend a restart.'
    }

    It 'does not recommend a restart when preflight fails before changes' {
        $message = Get-CompletionMessage -FailureCount 1 -WarningCount 0 -PlannedCount 0 -AppliedCount 0 -IsWhatIf $false
        Assert-True -Condition ($message -match 'No debloat changes were applied') -Message 'A preflight failure must state that no changes were applied.'
        Assert-True -Condition ($message -match 'no restart is required') -Message 'A preflight failure must not recommend a restart.'
    }

    It 'treats a non-DWORD registry value as correctable drift' {
        $fakeRegistryKey = New-Object psobject
        $fakeRegistryKey | Add-Member -MemberType ScriptMethod -Name GetValueNames -Value { @('AllowTelemetry') }
        $fakeRegistryKey | Add-Member -MemberType ScriptMethod -Name GetValue -Value { param($name) 'not-a-dword' }
        Mock Test-Path { $true }
        Mock Get-Item { $fakeRegistryKey }

        Assert-True -Condition (-not (Test-DwordValueMatches -Path 'HKLM:\Test' -Name 'AllowTelemetry' -Value 0)) -Message 'A wrong registry type must be treated as drift.'
    }

    It 'selects the newest matching restore point within the age window' {
        Mock Get-ComputerRestorePoint {
            @(
                [pscustomobject]@{ Description = 'Pre-Debloat Restore Point'; CreationTime = (Get-Date).AddHours(-8); SequenceNumber = 10 },
                [pscustomobject]@{ Description = 'Pre-Debloat Restore Point'; CreationTime = (Get-Date).AddHours(-2); SequenceNumber = 20 },
                [pscustomobject]@{ Description = 'Pre-Debloat Restore Point'; CreationTime = (Get-Date).AddHours(-5); SequenceNumber = 15 }
            )
        }

        $restorePoint = Get-RecentDebloatRestorePoint
        Assert-True -Condition ($null -ne $restorePoint) -Message 'A qualifying restore point was not selected.'
        Assert-True -Condition ($restorePoint.SequenceNumber -eq 20) -Message 'The newest qualifying restore point was not selected.'
    }

    It 'rejects a restore point older than the age window' {
        Mock Get-ComputerRestorePoint {
            [pscustomobject]@{ Description = 'Pre-Debloat Restore Point'; CreationTime = (Get-Date).AddHours(-25) }
        }

        Assert-True -Condition ($null -eq (Get-RecentDebloatRestorePoint)) -Message 'An expired restore point must not qualify.'
    }

    It 'rejects a restore point with a different description' {
        Mock Get-ComputerRestorePoint {
            [pscustomobject]@{ Description = 'Unrelated Restore Point'; CreationTime = (Get-Date).AddHours(-1) }
        }

        Assert-True -Condition ($null -eq (Get-RecentDebloatRestorePoint)) -Message 'A restore point with a different description must not qualify.'
    }

    It 'ignores malformed restore-point timestamps' {
        Mock Get-ComputerRestorePoint {
            @(
                [pscustomobject]@{ Description = 'Pre-Debloat Restore Point'; CreationTime = 'not-a-timestamp' },
                [pscustomobject]@{ Description = 'Pre-Debloat Restore Point'; CreationTime = (Get-Date).AddHours(-3); SequenceNumber = 30 }
            )
        }

        $restorePoint = Get-RecentDebloatRestorePoint
        Assert-True -Condition ($null -ne $restorePoint) -Message 'A valid record after a malformed record was not selected.'
        Assert-True -Condition ($restorePoint.SequenceNumber -eq 30) -Message 'A malformed timestamp disrupted valid restore-point selection.'
    }

    It 'rejects a restore point timestamped in the future' {
        Mock Get-ComputerRestorePoint {
            [pscustomobject]@{ Description = 'Pre-Debloat Restore Point'; CreationTime = (Get-Date).AddHours(1) }
        }

        Assert-True -Condition ($null -eq (Get-RecentDebloatRestorePoint)) -Message 'A future restore point must not qualify.'
    }

    It 'reuses a recent matching restore point' {
        Mock Get-RecentDebloatRestorePoint { [pscustomobject]@{ Description = 'Pre-Debloat Restore Point' } }
        Mock Enable-ComputerRestore { throw 'Enable should not be called.' }
        Mock Checkpoint-Computer { throw 'Checkpoint should not be called.' }
        $script:Results.Clear()

        Assert-True -Condition (New-SafetyRestorePoint -Confirm:$false) -Message 'A recent matching restore point should be accepted.'
        Assert-True -Condition ($script:Results[0].Detail -match 'Reusing') -Message 'Restore-point reuse was not reported.'
    }

    It 'creates a restore point when no recent matching restore point exists' {
        $script:RestoreCreationCalls = [System.Collections.Generic.List[string]]::new()
        Mock Get-RecentDebloatRestorePoint { $null }
        Mock Enable-ComputerRestore { $script:RestoreCreationCalls.Add('Enable') }
        Mock Checkpoint-Computer { $script:RestoreCreationCalls.Add('Checkpoint') }
        $script:Results.Clear()

        Assert-True -Condition (New-SafetyRestorePoint -Confirm:$false) -Message 'Restore-point creation should succeed.'
        Assert-True -Condition ($script:RestoreCreationCalls.Count -eq 2) -Message 'Restore-point creation commands were not both invoked.'
        Assert-True -Condition ($script:RestoreCreationCalls[0] -eq 'Enable') -Message 'System Restore was not enabled first.'
        Assert-True -Condition ($script:RestoreCreationCalls[1] -eq 'Checkpoint') -Message 'The checkpoint was not created after enablement.'
    }

    It 'fails safely when checkpoint creation fails' {
        Mock Get-RecentDebloatRestorePoint { $null }
        Mock Enable-ComputerRestore { }
        Mock Checkpoint-Computer { throw 'Checkpoint unavailable' }
        $script:Results.Clear()

        Assert-True -Condition (-not (New-SafetyRestorePoint -Confirm:$false)) -Message 'A checkpoint failure must return false.'
        Assert-True -Condition ($script:Results[0].Status -eq 'Failure') -Message 'A checkpoint failure was not recorded.'
    }

    It 'warns and attempts a new restore point when inventory fails' {
        $script:RestoreCreationCalls = [System.Collections.Generic.List[string]]::new()
        Mock Get-RecentDebloatRestorePoint { throw 'Restore-point inventory unavailable' }
        Mock Enable-ComputerRestore { $script:RestoreCreationCalls.Add('Enable') }
        Mock Checkpoint-Computer { $script:RestoreCreationCalls.Add('Checkpoint') }
        $script:Results.Clear()

        Assert-True -Condition (New-SafetyRestorePoint -Confirm:$false) -Message 'Inventory failure should fall back to restore-point creation.'
        Assert-True -Condition ($script:RestoreCreationCalls.Count -eq 2) -Message 'A new restore point was not attempted after inventory failure.'
        Assert-True -Condition (@($script:Results | Where-Object { $_.Status -eq 'Warning' -and $_.Item -eq 'Restore point inventory' }).Count -eq 1) -Message 'Inventory failure was not reported as a warning.'
        Assert-True -Condition (@($script:Results | Where-Object { $_.Status -eq 'Success' -and $_.Item -eq 'Pre-Debloat Restore Point' }).Count -eq 1) -Message 'Successful fallback creation was not reported.'
    }

    It 'detects an unchanged configuration without requesting a restore point' {
        Mock Get-AppxProvisionedPackage { @() }
        Mock Get-AppxPackage { @() }
        Mock Test-DwordValueMatches { $true }
        Mock Get-Service { @() }
        Mock Test-StartupValueExists { $false }

        Assert-True -Condition (-not (Test-DebloatChangesRequired)) -Message 'An unchanged configuration was reported as drifted.'
    }

    It 'detects registry drift before a modifying run' {
        Mock Get-AppxProvisionedPackage { @() }
        Mock Get-AppxPackage { @() }
        Mock Test-DwordValueMatches { $false }

        Assert-True -Condition (Test-DebloatChangesRequired) -Message 'Registry drift was not detected.'
    }

    It 'skips checkpoint creation and modification phases when no drift exists' {
        Mock Test-DebloatChangesRequired { $false }
        Mock New-SafetyRestorePoint { throw 'Restore point should not be called.' }
        Mock Remove-BloatwarePackages { throw 'Modification phase should not be called.' }

        $result = Invoke-DebloatWorkflow
        Assert-True -Condition (-not $result.RestorePointAttempted) -Message 'An unchanged run attempted a restore point.'
        Assert-True -Condition (-not $result.ModificationPhasesAttempted) -Message 'An unchanged run attempted modifications.'
        Assert-True -Condition ($result.ExitCode -eq 0) -Message 'An unchanged run should succeed.'
    }

    It 'gates modifying phases on successful checkpoint creation' {
        Mock Test-DebloatChangesRequired { $true }
        Mock New-SafetyRestorePoint { $false }
        Mock Remove-BloatwarePackages { throw 'Modification phase should not be called.' }

        $result = Invoke-DebloatWorkflow
        Assert-True -Condition $result.RestorePointAttempted -Message 'A drifted run did not attempt a restore point.'
        Assert-True -Condition (-not $result.ModificationPhasesAttempted) -Message 'Modifications ran without a restore point.'
        Assert-True -Condition ($result.ExitCode -eq 1) -Message 'A missing restore point should fail safely.'
        Assert-True -Condition ($result.Message -match 'no restart is required') -Message 'A gated run should not recommend a restart.'
    }

    It 'runs modifying phases after checkpoint creation succeeds' {
        $script:PhaseCalls = [System.Collections.Generic.List[string]]::new()
        Mock Test-DebloatChangesRequired { $true }
        Mock New-SafetyRestorePoint { $true }
        Mock Remove-BloatwarePackages { $script:PhaseCalls.Add('Apps') }
        Mock Disable-Telemetry { $script:PhaseCalls.Add('Telemetry') }
        Mock Disable-ConsumerFeatures { $script:PhaseCalls.Add('Consumer') }
        Mock Remove-StartupEntries { $script:PhaseCalls.Add('Startup') }

        $result = Invoke-DebloatWorkflow
        Assert-True -Condition $result.RestorePointAttempted -Message 'A drifted run did not attempt a restore point.'
        Assert-True -Condition $result.ModificationPhasesAttempted -Message 'Modifications did not run after checkpoint creation.'
        Assert-True -Condition ($result.ExitCode -eq 0) -Message 'A safely gated run should succeed.'
        Assert-True -Condition ($script:PhaseCalls.Count -eq 4) -Message 'Not all modifying phases were invoked.'
        Assert-True -Condition (($script:PhaseCalls -join ',') -eq 'Apps,Telemetry,Consumer,Startup') -Message 'Modifying phases ran in the wrong order.'
    }

    It 'reports inventory failures without attempting a checkpoint or restart' {
        Mock Test-DebloatChangesRequired { throw 'Inventory unavailable' }
        Mock New-SafetyRestorePoint { throw 'Restore point should not be called.' }

        $result = Invoke-DebloatWorkflow
        Assert-True -Condition ($result.ExitCode -eq 1) -Message 'An inventory failure should fail.'
        Assert-True -Condition (-not $result.RestorePointAttempted) -Message 'An inventory failure attempted a restore point.'
        Assert-True -Condition ($result.Message -match 'no restart is required') -Message 'An inventory failure should not recommend a restart.'
    }

    It 'forwards Confirm to Windows PowerShell only when it is true' {
        Assert-True -Condition ($scriptContent -match "ContainsKey\('Confirm'\) -and \[bool\]") -Message 'Confirm is not guarded by its Boolean value.'
        Assert-True -Condition ($scriptContent -match "windowsPowerShellArguments \+= '-Confirm'") -Message 'A true Confirm value is not forwarded.'
        Assert-True -Condition ($scriptContent -notmatch '"-Confirm:') -Message 'Confirm is forwarded as an unsupported explicit Boolean switch.'
    }

    It 'uses a 64-bit Windows PowerShell host' {
        Assert-True -Condition ($scriptContent -match '\[Environment\]::Is64BitOperatingSystem') -Message 'The operating-system architecture is not validated.'
        Assert-True -Condition ($scriptContent -match '\[Environment\]::Is64BitProcess') -Message 'The process architecture is not validated.'
        Assert-True -Condition ($scriptContent -match "'Sysnative'") -Message 'The 32-bit handoff does not use Sysnative.'
        Assert-True -Condition ($scriptContent -match "'System32'") -Message 'The 64-bit handoff does not use System32.'
    }

    It 'includes required Xbox packages while preserving named core apps' {
        Assert-True -Condition ($BloatwarePackages -contains 'Microsoft.XboxGamingOverlay') -Message 'Xbox Gaming Overlay is missing from the target list.'
        Assert-True -Condition ($BloatwarePackages -contains 'Microsoft.GamingApp') -Message 'Microsoft Gaming App is missing from the target list.'
        Assert-True -Condition ($BloatwarePackages -notcontains 'Microsoft.WindowsCalculator') -Message 'Calculator must be preserved.'
        Assert-True -Condition ($BloatwarePackages -notcontains 'Microsoft.WindowsNotepad') -Message 'Notepad must be preserved.'
        Assert-True -Condition ($BloatwarePackages -notcontains 'Microsoft.WindowsTerminal') -Message 'Windows Terminal must be preserved.'
    }
}
