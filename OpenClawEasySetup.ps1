[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('Menu', 'Diagnose', 'Plan', 'Install', 'Configure', 'Verify')]
    [string]$Action = 'Menu',

    [switch]$Apply,

    [switch]$SkipOnboarding,
    [switch]$Strict
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'src\OpenClawEasySetup.psm1'
Import-Module -Name $modulePath -Force

function Show-MainMenu {
    $messagesPath = Join-Path $PSScriptRoot 'locales\ko-KR.json'
    $messages = Get-Content -LiteralPath $messagesPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host ''
    Write-Host $messages.title -ForegroundColor Cyan
    foreach ($line in $messages.menu) {
        Write-Host $line
    }
    $choice = Read-Host $messages.menuPrompt
    switch ($choice) {
        '1' { return 'Diagnose' }
        '2' { return 'Plan' }
        '3' { return 'Install' }
        '4' { return 'Configure' }
        '5' { return 'Verify' }
        '0' { return 'Exit' }
        default { throw 'Choose a number from 0 through 5.' }
    }
}

if ($Action -eq 'Menu') {
    $Action = Show-MainMenu
}

switch ($Action) {
    'Exit' {
        return
    }
    'Diagnose' {
        $checks = Get-OpenClawReadiness
        $checks | Show-OpenClawReadiness
        if (@($checks | Where-Object Status -eq 'Fail').Count -gt 0) {
            exit 20
        }
        if ($Strict -and @($checks | Where-Object Status -eq 'Warn').Count -gt 0) {
            exit 10
        }
    }
    'Plan' {
        Show-OpenClawInstallPlan
    }
    'Install' {
        Show-OpenClawInstallPlan
        if (-not $Apply) {
            $messagesPath = Join-Path $PSScriptRoot 'locales\ko-KR.json'
            $messages = Get-Content -LiteralPath $messagesPath -Raw -Encoding UTF8 | ConvertFrom-Json
            Write-Host ''
            Write-Host $messages.previewOnly -ForegroundColor Yellow
            return
        }

        Install-OpenClawOfficial -SkipOnboarding:$SkipOnboarding -WhatIf:$WhatIfPreference
    }
    'Configure' {
        if (-not $Apply) {
            Write-Host 'Preview: openclaw onboard --install-daemon' -ForegroundColor Yellow
            Write-Host 'Run again with -Apply to start the official interactive onboarding.'
            return
        }
        Start-OpenClawOnboarding -WhatIf:$WhatIfPreference
    }
    'Verify' {
        $results = Invoke-OpenClawVerification
        $results | Format-Table -AutoSize
        if (@($results | Where-Object Passed -eq $false).Count -gt 0) {
            exit 50
        }
    }
}
