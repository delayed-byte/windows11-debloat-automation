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
        $message = Get-CompletionMessage -FailureCount 0 -WarningCount 0 -PlannedCount 3 -SuccessCount 0 -IsWhatIf $true
        Assert-True -Condition ($message -match 'No changes were made') -Message 'Preview output must state that no changes were made.'
        Assert-True -Condition ($message -match 'do not restart') -Message 'Preview output must not recommend a restart.'
    }

    It 'does not recommend a restart when the configuration already matches' {
        $message = Get-CompletionMessage -FailureCount 0 -WarningCount 0 -PlannedCount 0 -SuccessCount 0 -IsWhatIf $false
        Assert-True -Condition ($message -match 'no restart is required') -Message 'An unchanged run must not recommend a restart.'
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
