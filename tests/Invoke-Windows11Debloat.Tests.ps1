$scriptPath = Join-Path $PSScriptRoot '..\scripts\Invoke-Windows11Debloat.ps1'
$scriptContent = Get-Content -LiteralPath $scriptPath -Raw
$tokens = $null
$parseErrors = $null
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )
    if (-not $Condition) { throw $Message }
}

Describe 'Invoke-Windows11Debloat.ps1 static safety checks' {
    It 'has valid PowerShell syntax' {
        Assert-True -Condition ($parseErrors.Count -eq 0) -Message 'The script contains PowerShell parse errors.'
        Assert-True -Condition ($null -ne $scriptAst) -Message 'The script AST was not created.'
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

    It 'reuses its recent restore point to support sequential runs' {
        Assert-True -Condition ($scriptContent -match 'Get-ComputerRestorePoint') -Message 'Existing restore points are not queried.'
        Assert-True -Condition ($scriptContent -match "Description -eq 'Pre-Debloat Restore Point'") -Message 'The named restore point is not selected.'
        Assert-True -Condition ($scriptContent -match 'AddHours\(-24\)') -Message 'The 24-hour restore-point window is not checked.'
    }

    It 'reports declined WhatIf operations as planned' {
        Assert-True -Condition ($scriptContent -match "ValidateSet\('Success', 'Planned', 'Skipped', 'Warning', 'Failure'\)") -Message 'Planned is not a supported result status.'
        Assert-True -Condition ($scriptContent -match 'if \(\$WhatIfPreference\) \{ ''Planned'' \} else \{ ''Skipped'' \}') -Message 'WhatIf declines are not reported as planned.'
    }

    It 'includes required Xbox packages while preserving named core apps' {
        Assert-True -Condition ($scriptContent -match "'Microsoft.XboxGamingOverlay'") -Message 'Xbox Gaming Overlay is missing from the target list.'
        Assert-True -Condition ($scriptContent -match "'Microsoft.GamingApp'") -Message 'Microsoft Gaming App is missing from the target list.'
        Assert-True -Condition ($scriptContent -notmatch "(?m)^\s*'Microsoft.WindowsCalculator',?\s*$") -Message 'Calculator must be preserved.'
        Assert-True -Condition ($scriptContent -notmatch "(?m)^\s*'Microsoft.WindowsNotepad',?\s*$") -Message 'Notepad must be preserved.'
        Assert-True -Condition ($scriptContent -notmatch "(?m)^\s*'Microsoft.WindowsTerminal',?\s*$") -Message 'Windows Terminal must be preserved.'
    }
}
