[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $projectRoot 'src\OpenClawEasySetup.psm1'
Import-Module -Name $modulePath -Force

$script:Passed = 0
$script:Failed = 0

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Name
    )

    if ($Condition) {
        Write-Host "[PASS] $Name" -ForegroundColor Green
        $script:Passed++
    }
    else {
        Write-Host "[FAIL] $Name" -ForegroundColor Red
        $script:Failed++
    }
}

function Assert-Equal {
    param(
        [object]$Actual,
        [object]$Expected,
        [string]$Name
    )

    Assert-True -Condition ($Actual -eq $Expected) -Name ("{0} (expected: {1}; actual: {2})" -f $Name, $Expected, $Actual)
}

$parsed = ConvertTo-OpenClawVersion -Text 'v24.15.3'
Assert-Equal -Actual $parsed.ToString() -Expected '24.15.3' -Name 'Version parser accepts a v prefix'
Assert-True -Condition ($null -eq (ConvertTo-OpenClawVersion -Text 'not-a-version')) -Name 'Version parser rejects invalid text'

$recommendedNode = Test-OpenClawNodeVersion -Version ([version]'24.15.0')
Assert-True -Condition $recommendedNode.Supported -Name 'Node 24.15.0 is supported'
Assert-True -Condition $recommendedNode.Recommended -Name 'Node 24.15.0 is recommended'
Assert-True -Condition (-not (Test-OpenClawNodeVersion -Version ([version]'24.14.9')).Supported) -Name 'Node 24.14.9 is rejected'
Assert-True -Condition (Test-OpenClawNodeVersion -Version ([version]'22.22.3')).Supported -Name 'Node 22.22.3 is supported'
Assert-True -Condition (Test-OpenClawNodeVersion -Version ([version]'25.9.0')).Supported -Name 'Node 25.9.0 is supported'
Assert-True -Condition (-not (Test-OpenClawNodeVersion -Version ([version]'23.9.0')).Supported) -Name 'Unlisted Node release lines are not assumed safe'
$recommendedNode26 = Test-OpenClawNodeVersion -Version ([version]'26.0.0')
Assert-True -Condition ($recommendedNode26.Supported -and $recommendedNode26.Recommended) -Name 'Node 26 is supported and recommended'

$config = Get-OpenClawSourceConfig
Assert-Equal -Actual $config.schemaVersion -Expected 1 -Name 'Source configuration schema is supported'
$officialUri = [uri]$config.installer.uri
Assert-True -Condition (Test-OpenClawUriAllowed -Uri $officialUri -AllowedHosts @($config.allowedDownloadHosts)) -Name 'Official HTTPS installer URI is allowed'
Assert-True -Condition (-not (Test-OpenClawUriAllowed -Uri ([uri]'http://openclaw.ai/install.ps1') -AllowedHosts @($config.allowedDownloadHosts))) -Name 'HTTP installer URI is rejected'
Assert-True -Condition (-not (Test-OpenClawUriAllowed -Uri ([uri]'https://example.com/install.ps1') -AllowedHosts @($config.allowedDownloadHosts))) -Name 'Non-allowlisted installer host is rejected'
Assert-True -Condition (-not (Test-OpenClawUriAllowed -Uri ([uri]'https://user:pass@raw.githubusercontent.com/openclaw/install.ps1') -AllowedHosts @($config.allowedDownloadHosts))) -Name 'URI user information is rejected'
Assert-True -Condition (-not (Test-OpenClawUriAllowed -Uri ([uri]'https://raw.githubusercontent.com:8443/openclaw/install.ps1') -AllowedHosts @($config.allowedDownloadHosts))) -Name 'Non-default HTTPS ports are rejected'
Assert-True -Condition (-not (Test-OpenClawUriAllowed -Uri ([uri]'https://raw.githubusercontent.com/openclaw/install.ps1?token=test') -AllowedHosts @($config.allowedDownloadHosts))) -Name 'Installer query strings are rejected'
Assert-True -Condition ([string]$config.openClaw.commitSha -match '^[A-Fa-f0-9]{40}$') -Name 'OpenClaw source is pinned to a commit SHA'
Assert-True -Condition ([string]$config.installer.sha256 -match '^[A-Fa-f0-9]{64}$') -Name 'Installer is pinned to a SHA-256'
Assert-Equal -Actual $config.node.winget.id -Expected 'OpenJS.NodeJS' -Name 'Node.js WinGet package uses the exact official package ID'
Assert-Equal -Actual $config.node.winget.version -Expected '26.5.1' -Name 'Node.js WinGet package is version-pinned'
Assert-True -Condition ([string]$config.node.winget.installerSha256 -match '^[A-Fa-f0-9]{64}$') -Name 'Node.js installer hash is recorded'

$plan = @(Get-OpenClawInstallPlan)
Assert-Equal -Actual $plan.Count -Expected 8 -Name 'Install plan has eight explicit stages'
Assert-True -Condition (@($plan | Where-Object ChangesPC -eq $true).Count -ge 3) -Name 'Mutating install stages are labeled'
Assert-True -Condition (@($plan | Where-Object { $null -eq $_.RequiresAdmin }).Count -eq 0) -Name 'Every install stage declares its admin requirement'

$readiness = @(Get-OpenClawReadiness)
Assert-True -Condition ($readiness.Count -ge 10) -Name 'Readiness returns the expected checks'
Assert-True -Condition (@($readiness | Where-Object Status -notin @('Pass', 'Warn', 'Fail', 'Info')).Count -eq 0) -Name 'Readiness statuses use the documented set'

$powerShellFiles = Get-ChildItem -LiteralPath $projectRoot -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') }
$parseFailure = $false
$forbiddenCommand = $false
foreach ($powerShellFile in $powerShellFiles) {
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($powerShellFile.FullName, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        Write-Host "Parse error in $($powerShellFile.FullName): $($parseErrors[0].Message)" -ForegroundColor Red
        $parseFailure = $true
    }
    $commands = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)
    foreach ($commandAst in $commands) {
        if ($commandAst.GetCommandName() -in @('Invoke-Expression', 'iex')) {
            $forbiddenCommand = $true
        }
    }
}
Assert-True -Condition (-not $parseFailure) -Name 'All PowerShell files parse without syntax errors'
Assert-True -Condition (-not $forbiddenCommand) -Name 'PowerShell code does not invoke remote text through Invoke-Expression'

$entryPoint = Join-Path $projectRoot 'OpenClawEasySetup.ps1'
$entryCommand = Get-Command -Name $entryPoint
Assert-True -Condition $entryCommand.Parameters.ContainsKey('Apply') -Name 'Entry point requires an explicit Apply switch for mutations'
Assert-True -Condition $entryCommand.Parameters.ContainsKey('WhatIf') -Name 'Entry point exposes standard WhatIf support'
& $entryPoint -Action Install
Assert-True -Condition $? -Name 'Install preview completes without starting installation'
& $entryPoint -Action Install -Apply -WhatIf
Assert-True -Condition $? -Name 'WhatIf plans prerequisite and OpenClaw changes without downloading or installing'

$trackedCandidates = Get-ChildItem -LiteralPath $projectRoot -Recurse -File | Where-Object {
    $_.FullName -notmatch '[\\/]\.git[\\/]' -and
    $_.Extension -in @('.ps1', '.psm1', '.json', '.md', '.yml', '.yaml')
}
$secretPatterns = @(
    ('gh' + '[pousr]_[A-Za-z0-9]{30,}'),
    ('sk' + '-[A-Za-z0-9]{20,}'),
    ('github_pat_' + '[A-Za-z0-9_]{20,}')
)
$secretHit = $false
foreach ($file in $trackedCandidates) {
    $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    foreach ($pattern in $secretPatterns) {
        if ($content -match $pattern) {
            Write-Host "Potential secret in $($file.FullName)" -ForegroundColor Red
            $secretHit = $true
        }
    }
}
Assert-True -Condition (-not $secretHit) -Name 'Repository contains no high-confidence token patterns'

Write-Host ''
Write-Host ("Tests passed: {0}; failed: {1}" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) {
    exit 1
}
