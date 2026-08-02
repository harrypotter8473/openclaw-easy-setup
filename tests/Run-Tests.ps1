[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $projectRoot 'src\OpenClawEasySetup.psm1'
Import-Module -Name $modulePath -Force
$openClawModule = Get-Module -Name OpenClawEasySetup | Select-Object -First 1

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

function Get-ThrownException {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    try {
        & $ScriptBlock
        return $null
    }
    catch {
        return $_.Exception
    }
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
$recoveryToolVersion = & $openClawModule { $script:RecoveryToolVersion }
Assert-Equal -Actual $recoveryToolVersion -Expected '0.4.0' -Name 'Recovery and checkpoint metadata uses the current tool version'
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
Assert-Equal -Actual $config.git.winget.id -Expected 'Git.Git' -Name 'Git for Windows uses the exact WinGet package ID'
Assert-Equal -Actual $config.git.winget.version -Expected '2.55.0.3' -Name 'Git for Windows package is version-pinned'
Assert-True -Condition ([string]$config.git.winget.installerSha256 -match '^[A-Fa-f0-9]{64}$') -Name 'Git for Windows installer hash is recorded'

$plan = @(Get-OpenClawInstallPlan)
Assert-Equal -Actual $plan.Count -Expected 8 -Name 'Install plan has eight explicit stages'
Assert-True -Condition (@($plan | Where-Object ChangesPC -eq $true).Count -ge 3) -Name 'Mutating install stages are labeled'
Assert-True -Condition (@($plan | Where-Object { $null -eq $_.RequiresAdmin }).Count -eq 0) -Name 'Every install stage declares its admin requirement'

$readiness = @(Get-OpenClawReadiness)
Assert-True -Condition ($readiness.Count -ge 10) -Name 'Readiness returns the expected checks'
Assert-True -Condition (@($readiness | Where-Object Id -eq 'git').Count -eq 1) -Name 'Readiness includes the trusted Git prerequisite check'
Assert-True -Condition (@($readiness | Where-Object Status -notin @('Pass', 'Warn', 'Fail', 'Info')).Count -eq 0) -Name 'Readiness statuses use the documented set'

$powerShellFiles = Get-ChildItem -LiteralPath $projectRoot -Recurse -File | Where-Object {
    $_.Extension -in @('.ps1', '.psm1') -and
    $_.FullName -notmatch '[\\/]tests[\\/]\.tmp-'
}
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
$moduleSourceText = Get-Content -LiteralPath $modulePath -Raw -Encoding UTF8
Assert-True -Condition (-not $moduleSourceText.Contains('NPM_CONFIG_FORCE')) -Name 'Installer does not enable npm force mode through NPM_CONFIG_FORCE'
Assert-True -Condition ($moduleSourceText.Contains("OpenClaw-Easy-Setup/0.4")) -Name 'Installer network requests identify the current tool version'
Assert-True -Condition ($moduleSourceText.Contains('GIT_CONFIG_NOSYSTEM') -and $moduleSourceText.Contains('GIT_CONFIG_GLOBAL')) -Name 'Installer isolates system and user Git configuration'
Assert-True -Condition ($moduleSourceText.Contains('uninstall --global openclaw --ignore-scripts')) -Name 'Exact-version repair disables package lifecycle scripts during removal'
Assert-True -Condition ($moduleSourceText.Contains('$forceNestedConfirmation') -and $moduleSourceText.Contains('Start-OpenClawOnboarding -StateDirectory $StateDirectory -Confirm:$true')) -Name 'Explicit confirmation is preserved for nested onboarding changes'

$entryPoint = Join-Path $projectRoot 'OpenClawEasySetup.ps1'
$entrySourceText = Get-Content -LiteralPath $entryPoint -Raw -Encoding UTF8
$entryCommand = Get-Command -Name $entryPoint
Assert-True -Condition $entryCommand.Parameters.ContainsKey('Apply') -Name 'Entry point requires an explicit Apply switch for mutations'
Assert-True -Condition $entryCommand.Parameters.ContainsKey('WhatIf') -Name 'Entry point exposes standard WhatIf support'
Assert-True -Condition $entryCommand.Parameters.ContainsKey('CancellationPath') -Name 'Entry point exposes cooperative cancellation for the GUI worker'
Assert-True -Condition $entryCommand.Parameters.ContainsKey('ExpectedPlanFingerprint') -Name 'Entry point can bind an approved GUI plan fingerprint'
Assert-True -Condition $entryCommand.Parameters.ContainsKey('GuiApproved') -Name 'Entry point exposes an argv-safe GUI approval switch'
Assert-True -Condition $entryCommand.Parameters.ContainsKey('GuiOutput') -Name 'Entry point exposes a UTF-8 GUI diagnosis output switch'
Assert-True -Condition (([regex]::Matches($entrySourceText, '\[''Confirm''\]\s*=\s*\$explicitConfirm')).Count -eq 2) -Name 'Explicit Confirm values cross the entry-point module boundary'
$modulePathBeforePreview = $env:PSModulePath
& $entryPoint -Action Install
Assert-True -Condition $? -Name 'Install preview completes without starting installation'
Assert-Equal -Actual $env:PSModulePath -Expected $modulePathBeforePreview -Name 'CLI preview restores the caller PowerShell module path'
& $entryPoint -Action Install -Apply -WhatIf
Assert-True -Condition $? -Name 'WhatIf plans prerequisite and OpenClaw changes without downloading or installing'

$trackedCandidates = Get-ChildItem -LiteralPath $projectRoot -Recurse -File | Where-Object {
    $_.FullName -notmatch '[\\/]\.git[\\/]' -and
    $_.FullName -notmatch '[\\/]tests[\\/]\.tmp-' -and
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

$stableExitCodes = @{
    Success = 0
    Warning = 10
    Diagnose = 20
    Download = 30
    Integrity = 31
    Prerequisite = 40
    Install = 41
    Configure = 42
    Verify = 50
    Resume = 60
    Cancelled = 61
    Bundle = 70
    Unexpected = 99
}
$resolvedExitDefinitions = foreach ($kind in @($stableExitCodes.Keys)) {
    $definition = Get-OpenClawExitCodeDefinition -Kind $kind
    Assert-Equal -Actual $definition.ExitCode -Expected $stableExitCodes[$kind] -Name ("Stable exit code for {0}" -f $kind)
    Assert-True -Condition ([string]$definition.Id -match '^OCES-(?:SUCCESS|DIAG-WARN|[A-Z]+(?:-[A-Z]+)?-\d{3})$') -Name ("Stable error ID for {0}" -f $kind)
    $definition
}
Assert-Equal -Actual @($resolvedExitDefinitions | Select-Object -ExpandProperty ExitCode -Unique).Count -Expected $stableExitCodes.Count -Name 'Stable exit codes are unique'
Assert-Equal -Actual @($resolvedExitDefinitions | Select-Object -ExpandProperty Id -Unique).Count -Expected $stableExitCodes.Count -Name 'Stable error IDs are unique'

$taggedIntegrityException = New-Object InvalidOperationException('synthetic integrity failure')
$taggedIntegrityException.Data['OpenClawFailureKind'] = 'Integrity'
$taggedIntegrityFailure = Resolve-OpenClawFailure -Action Install -Exception $taggedIntegrityException
Assert-Equal -Actual $taggedIntegrityFailure.ExitCode -Expected 31 -Name 'Tagged failures retain their stable category across actions'
$fallbackInstallFailure = Resolve-OpenClawFailure -Action Install -Exception (New-Object InvalidOperationException('synthetic install failure'))
Assert-Equal -Actual $fallbackInstallFailure.ExitCode -Expected 41 -Name 'Untagged install failures use the stable install exit code'

$syntheticToken = ('gh' + 'p_' + ('A' * 32))
$syntheticAwsKey = ('AK' + 'IA' + ('B' * 16))
$syntheticSlackAppToken = ('xapp' + '-' + ('C' * 24))
$syntheticSha256 = [string]$config.installer.sha256
$ansiEscape = [char]27
$sensitiveText = @(
    "token=$syntheticToken",
    "aws=$syntheticAwsKey",
    "slack=$syntheticSlackAppToken",
    "https://example.invalid/support?token=$syntheticToken&mode=full",
    $(if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) { 'profile unavailable' } else { Join-Path $env:USERPROFILE 'private\openclaw.log' }),
    ("line-one{0}line-two" -f [Environment]::NewLine),
    ("{0}[31mred{0}[0m" -f $ansiEscape),
    "sha256=$syntheticSha256"
) -join ' | '
$protectedText = Protect-OpenClawLogText -Text $sensitiveText
Assert-True -Condition (-not $protectedText.Contains($syntheticToken)) -Name 'Log redaction removes synthetic tokens'
Assert-True -Condition (-not $protectedText.Contains($syntheticAwsKey) -and -not $protectedText.Contains($syntheticSlackAppToken)) -Name 'Log redaction removes cloud and app token formats'
Assert-True -Condition (-not $protectedText.Contains('?token=')) -Name 'Log redaction removes URI query strings'
if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    Assert-True -Condition ($protectedText.IndexOf($env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase) -lt 0) -Name 'Log redaction removes the current user profile path'
    Assert-True -Condition $protectedText.Contains('%USERPROFILE%') -Name 'Log redaction leaves a useful user-profile placeholder'
}
Assert-True -Condition (-not $protectedText.Contains([Environment]::NewLine)) -Name 'Log redaction flattens CRLF and newline characters'
Assert-True -Condition (-not $protectedText.Contains([string]$ansiEscape)) -Name 'Log redaction removes ANSI escape sequences'
Assert-True -Condition $protectedText.Contains($syntheticSha256) -Name 'Log redaction preserves public SHA-256 values'
Assert-Equal -Actual (Protect-OpenClawLogText -Text $protectedText) -Expected $protectedText -Name 'Log redaction is idempotent'

$targetOpenClawVersion = [version]$config.openClaw.version
$missingDecision = Get-OpenClawInstallDecision -Snapshot ([pscustomobject]@{ Found = $false }) -TargetVersion $targetOpenClawVersion
Assert-Equal -Actual $missingDecision.Decision -Expected 'FreshInstall' -Name 'Missing OpenClaw produces a fresh-install decision'
Assert-True -Condition $missingDecision.ChangesRequired -Name 'Missing OpenClaw requires a change'

$olderDecision = Get-OpenClawInstallDecision -Snapshot ([pscustomobject]@{
    Found = $true; Trusted = $true; Ambiguous = $false; ExitCode = 0
    Version = [version]'2026.7.0'; RawVersion = 'openclaw 2026.7.0'
}) -TargetVersion $targetOpenClawVersion
Assert-Equal -Actual $olderDecision.Decision -Expected 'Upgrade' -Name 'Older OpenClaw produces an upgrade decision'

$equalDecision = Get-OpenClawInstallDecision -Snapshot ([pscustomobject]@{
    Found = $true; Trusted = $true; Ambiguous = $false; ExitCode = 0
    Version = $targetOpenClawVersion; RawVersion = ("openclaw {0}" -f $targetOpenClawVersion)
}) -TargetVersion $targetOpenClawVersion
Assert-Equal -Actual $equalDecision.Decision -Expected 'AlreadyCurrent' -Name 'Equal OpenClaw produces an already-current decision'

$newerDecision = Get-OpenClawInstallDecision -Snapshot ([pscustomobject]@{
    Found = $true; Trusted = $true; Ambiguous = $false; ExitCode = 0
    Version = [version]'2027.1.0'; RawVersion = 'openclaw 2027.1.0'
}) -TargetVersion $targetOpenClawVersion
Assert-Equal -Actual $newerDecision.Decision -Expected 'KeepNewer' -Name 'Newer OpenClaw is kept instead of downgraded'

$prereleaseDecision = Get-OpenClawInstallDecision -Snapshot ([pscustomobject]@{
    Found = $true; Trusted = $true; Ambiguous = $false; ExitCode = 0
    Version = $targetOpenClawVersion; RawVersion = ("openclaw {0}-beta.1" -f $targetOpenClawVersion)
}) -TargetVersion $targetOpenClawVersion
Assert-Equal -Actual $prereleaseDecision.Decision -Expected 'PrereleaseBlocked' -Name 'Prerelease OpenClaw requires manual review'

$nonzeroDecision = Get-OpenClawInstallDecision -Snapshot ([pscustomobject]@{
    Found = $true; Trusted = $true; Ambiguous = $false; ExitCode = 7
    Version = $targetOpenClawVersion; RawVersion = ("openclaw {0}" -f $targetOpenClawVersion)
}) -TargetVersion $targetOpenClawVersion
Assert-Equal -Actual $nonzeroDecision.Decision -Expected 'UnknownBlocked' -Name 'Nonzero version command exit blocks automatic installation'

$ambiguousDecision = Get-OpenClawInstallDecision -Snapshot ([pscustomobject]@{
    Found = $true; Trusted = $true; Ambiguous = $true; ExitCode = 0
    Version = $targetOpenClawVersion; RawVersion = ("openclaw {0}" -f $targetOpenClawVersion)
}) -TargetVersion $targetOpenClawVersion
Assert-Equal -Actual $ambiguousDecision.Decision -Expected 'AmbiguousBlocked' -Name 'Ambiguous OpenClaw command paths block automatic installation'

$ambiguousOutputDecision = Get-OpenClawInstallDecision -Snapshot ([pscustomobject]@{
    Found = $true; Trusted = $true; Ambiguous = $false; ExitCode = 0
    Version = $targetOpenClawVersion; RawVersion = ("openclaw {0}; node 26.5.1" -f $targetOpenClawVersion)
}) -TargetVersion $targetOpenClawVersion
Assert-Equal -Actual $ambiguousOutputDecision.Decision -Expected 'UnknownBlocked' -Name 'Multiple version values in command output block automatic installation'

$untrustedDecision = Get-OpenClawInstallDecision -Snapshot ([pscustomobject]@{
    Found = $true; Trusted = $false; Ambiguous = $false; ExitCode = 0
    Version = $targetOpenClawVersion; RawVersion = ("openclaw {0}" -f $targetOpenClawVersion)
}) -TargetVersion $targetOpenClawVersion
Assert-Equal -Actual $untrustedDecision.Decision -Expected 'UntrustedBlocked' -Name 'Untrusted OpenClaw command paths block automatic installation'

$temporaryTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("OpenClawEasySetup-Tests-{0}" -f ([guid]::NewGuid().ToString('N')))
$exactTemporaryTestRoot = [IO.Path]::GetFullPath($temporaryTestRoot)
try {
    $sourceFingerprint = 'A' * 64
    $checkpoint = New-OpenClawCheckpoint -StateDirectory $exactTemporaryTestRoot -TargetVersion ([string]$config.openClaw.version) -SourceFingerprint $sourceFingerprint
    Assert-True -Condition (Test-Path -LiteralPath $checkpoint.Path -PathType Leaf) -Name 'Checkpoint creation writes a state file'
    Assert-Equal -Actual $checkpoint.Steps.Count -Expected 8 -Name 'Checkpoint contains every install stage'
    Assert-Equal -Actual ($checkpoint.Steps.Id -join ',') -Expected 'diagnose,node,download,integrity,dryRun,install,onboard,verify' -Name 'Checkpoint stages use the stable ordered IDs'

    $roundTrip = Read-OpenClawCheckpoint -Path $checkpoint.Path -ExpectedTargetVersion ([string]$config.openClaw.version) -ExpectedSourceFingerprint $sourceFingerprint
    Assert-Equal -Actual $roundTrip.RunId -Expected $checkpoint.RunId -Name 'Checkpoint roundtrip preserves the run ID'
    Assert-Equal -Actual $roundTrip.SourceFingerprint -Expected $sourceFingerprint -Name 'Checkpoint roundtrip preserves the source fingerprint'

    $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId diagnose -Status Running -Detail ("token={0}" -f $syntheticToken)
    $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId diagnose -Status Succeeded -Detail 'Readiness completed'
    $updatedCheckpoint = Read-OpenClawCheckpoint -Path $checkpoint.Path -ExpectedTargetVersion ([string]$config.openClaw.version) -ExpectedSourceFingerprint $sourceFingerprint
    Assert-Equal -Actual @($updatedCheckpoint.Steps | Where-Object Id -eq diagnose)[0].Status -Expected 'Succeeded' -Name 'Checkpoint stage updates survive a disk roundtrip'
    Assert-True -Condition (-not ((Get-Content -LiteralPath $checkpoint.Path -Raw -Encoding UTF8).Contains($syntheticToken))) -Name 'Checkpoint stage detail never persists a synthetic token'

    $corruptCheckpointPath = Join-Path (Split-Path -Parent $checkpoint.Path) 'corrupt.json'
    [IO.File]::WriteAllText($corruptCheckpointPath, '{broken-json', (New-Object Text.UTF8Encoding($false)))
    $corruptException = Get-ThrownException { Read-OpenClawCheckpoint -Path $corruptCheckpointPath }
    Assert-True -Condition ($null -ne $corruptException -and [string]$corruptException.Data['OpenClawFailureKind'] -eq 'Resume') -Name 'Damaged checkpoint fails with the stable resume category'

    $schemaCheckpointPath = Join-Path (Split-Path -Parent $checkpoint.Path) 'schema-mismatch.json'
    $schemaCheckpoint = Get-Content -LiteralPath $checkpoint.Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $schemaCheckpoint.schemaVersion = 999
    [IO.File]::WriteAllText($schemaCheckpointPath, ($schemaCheckpoint | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    $schemaException = Get-ThrownException { Read-OpenClawCheckpoint -Path $schemaCheckpointPath }
    Assert-True -Condition ($null -ne $schemaException -and [string]$schemaException.Data['OpenClawFailureKind'] -eq 'Resume') -Name 'Unsupported checkpoint schema fails with the stable resume category'

    $targetMismatchException = Get-ThrownException {
        Read-OpenClawCheckpoint -Path $checkpoint.Path -ExpectedTargetVersion '2099.1.1' -ExpectedSourceFingerprint $sourceFingerprint
    }
    Assert-True -Condition ($null -ne $targetMismatchException -and [string]$targetMismatchException.Data['OpenClawFailureKind'] -eq 'Resume') -Name 'Checkpoint target-version mismatch blocks resume'

    $fingerprintMismatchException = Get-ThrownException {
        Read-OpenClawCheckpoint -Path $checkpoint.Path -ExpectedTargetVersion ([string]$config.openClaw.version) -ExpectedSourceFingerprint ('B' * 64)
    }
    Assert-True -Condition ($null -ne $fingerprintMismatchException -and [string]$fingerprintMismatchException.Data['OpenClawFailureKind'] -eq 'Resume') -Name 'Checkpoint source-fingerprint mismatch blocks resume'

    $latestCheckpointRoot = Join-Path $exactTemporaryTestRoot 'latest-checkpoint-barrier'
    $olderIncompleteCheckpoint = New-OpenClawCheckpoint -StateDirectory $latestCheckpointRoot -TargetVersion ([string]$config.openClaw.version) -SourceFingerprint $sourceFingerprint
    $newestCompletedCheckpoint = New-OpenClawCheckpoint -StateDirectory $latestCheckpointRoot -TargetVersion ([string]$config.openClaw.version) -SourceFingerprint $sourceFingerprint
    foreach ($stageId in @($newestCompletedCheckpoint.Steps.Id)) {
        $newestCompletedCheckpoint = Set-OpenClawCheckpointStep -Checkpoint $newestCompletedCheckpoint -StepId $stageId -Status Succeeded -Detail 'Synthetic completed run'
    }
    $checkpointClock = [DateTime]::UtcNow
    [IO.File]::SetLastWriteTimeUtc($olderIncompleteCheckpoint.Path, $checkpointClock.AddMinutes(-1))
    [IO.File]::SetLastWriteTimeUtc($newestCompletedCheckpoint.Path, $checkpointClock)
    $latestIncompleteCheckpoint = Get-OpenClawLatestCheckpoint -StateDirectory $latestCheckpointRoot -ExpectedTargetVersion ([string]$config.openClaw.version) -ExpectedSourceFingerprint $sourceFingerprint
    Assert-True -Condition ($null -eq $latestIncompleteCheckpoint) -Name 'Latest completed checkpoint prevents an older incomplete run from being resumed'
    $latestCheckpointIncludingCompleted = Get-OpenClawLatestCheckpoint -StateDirectory $latestCheckpointRoot -ExpectedTargetVersion ([string]$config.openClaw.version) -ExpectedSourceFingerprint $sourceFingerprint -IncludeCompleted
    Assert-Equal -Actual $latestCheckpointIncludingCompleted.RunId -Expected $newestCompletedCheckpoint.RunId -Name 'Latest checkpoint lookup returns the newest completed run when explicitly requested'

    $resumeInstallCheckpoint = [pscustomobject]@{
        Steps = @(
            [pscustomobject]@{ Id = 'install'; Status = 'Pending' }
            [pscustomobject]@{ Id = 'onboard'; Status = 'Pending' }
        )
    }
    $resumeOnboardCheckpoint = [pscustomobject]@{
        Steps = @(
            [pscustomobject]@{ Id = 'install'; Status = 'Succeeded' }
            [pscustomobject]@{ Id = 'onboard'; Status = 'Pending' }
        )
    }
    $resumeVerifyCheckpoint = [pscustomobject]@{
        Steps = @(
            [pscustomobject]@{ Id = 'install'; Status = 'Succeeded' }
            [pscustomobject]@{ Id = 'onboard'; Status = 'Succeeded' }
        )
    }
    $alreadyCurrentDecision = [pscustomobject]@{ Decision = 'AlreadyCurrent' }
    $installResumePoint = & $openClawModule { param($checkpointValue, $decisionValue) Get-OpenClawResumePoint -Checkpoint $checkpointValue -Decision $decisionValue } $resumeInstallCheckpoint $alreadyCurrentDecision
    $onboardResumePoint = & $openClawModule { param($checkpointValue, $decisionValue) Get-OpenClawResumePoint -Checkpoint $checkpointValue -Decision $decisionValue } $resumeOnboardCheckpoint $alreadyCurrentDecision
    $verifyResumePoint = & $openClawModule { param($checkpointValue, $decisionValue) Get-OpenClawResumePoint -Checkpoint $checkpointValue -Decision $decisionValue } $resumeVerifyCheckpoint $alreadyCurrentDecision
    Assert-Equal -Actual $installResumePoint -Expected 'Install' -Name 'Resume point restarts installation when install did not succeed'
    Assert-Equal -Actual $onboardResumePoint -Expected 'Onboard' -Name 'Resume point continues with onboarding after installation succeeds'
    Assert-Equal -Actual $verifyResumePoint -Expected 'Verify' -Name 'Resume point continues with verification after onboarding succeeds'

    $bestEffortCheckpoint = New-OpenClawCheckpoint -StateDirectory (Join-Path $exactTemporaryTestRoot 'best-effort-checkpoint') -TargetVersion ([string]$config.openClaw.version) -SourceFingerprint $sourceFingerprint
    $bestEffortCheckpoint.Path = Join-Path $exactTemporaryTestRoot 'missing-checkpoint-parent\checkpoint.json'
    $bestEffortCheckpointException = Get-ThrownException {
        [void](& $openClawModule {
            param($checkpointValue)
            Set-OpenClawCheckpointStepBestEffort -Checkpoint $checkpointValue -StepId diagnose -Status Failed -Detail 'Synthetic persistence failure'
        } $bestEffortCheckpoint)
    }
    Assert-True -Condition ($null -eq $bestEffortCheckpointException) -Name 'Best-effort checkpoint updates do not throw when persistence fails'

    $lockedInstallerPath = Join-Path $exactTemporaryTestRoot 'locked-installer.ps1'
    [IO.File]::WriteAllText($lockedInstallerPath, '# synthetic installer', (New-Object Text.UTF8Encoding($false)))
    $lockedInstallerStream = New-Object IO.FileStream($lockedInstallerPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
    try {
        $cleanupException = Get-ThrownException {
            [void](& $openClawModule { param($installerPath) Remove-OpenClawInstallerBestEffort -Path $installerPath } $lockedInstallerPath)
        }
        Assert-True -Condition ($null -eq $cleanupException) -Name 'Best-effort installer cleanup does not throw when the file is locked'
    }
    finally {
        $lockedInstallerStream.Dispose()
        if (Test-Path -LiteralPath $lockedInstallerPath -PathType Leaf) {
            Remove-Item -LiteralPath $lockedInstallerPath -Force
        }
    }

    $syntheticPackageRoot = Join-Path $exactTemporaryTestRoot 'synthetic-openclaw-package'
    [void](New-Item -ItemType Directory -Path $syntheticPackageRoot -Force)
    $syntheticPackageFile = Join-Path $syntheticPackageRoot 'index.js'
    $syntheticPackageJsonFile = Join-Path $syntheticPackageRoot 'package.json'
    $syntheticHelperDirectory = Join-Path $syntheticPackageRoot 'lib'
    [void](New-Item -ItemType Directory -Path $syntheticHelperDirectory -Force)
    $syntheticHelperFile = Join-Path $syntheticHelperDirectory 'helper.js'
    $syntheticCommandShim = Join-Path $exactTemporaryTestRoot 'openclaw.cmd'
    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($syntheticPackageFile, 'module.exports = {};', $utf8NoBom)
    [IO.File]::WriteAllText($syntheticPackageJsonFile, ('{{"name":"openclaw","version":"{0}","bin":{{"openclaw":"index.js"}}}}' -f $targetOpenClawVersion.ToString()), $utf8NoBom)
    [IO.File]::WriteAllText($syntheticHelperFile, 'exports.answer = 42;', $utf8NoBom)
    [IO.File]::WriteAllText($syntheticCommandShim, '@echo off & node node_modules\openclaw\index.js', $utf8NoBom)
    $actualSourceFingerprint = (Get-FileHash -LiteralPath (Join-Path $projectRoot 'config\openclaw-source.json') -Algorithm SHA256).Hash.ToUpperInvariant()
    $syntheticSnapshot = [pscustomobject]@{
        Found = $true
        Trusted = $true
        Ambiguous = $false
        ExitCode = 0
        Version = $targetOpenClawVersion
        Path = $syntheticCommandShim
        EntryPath = $syntheticPackageFile
        PackageRoot = $syntheticPackageRoot
    }
    $firstMetadataDigest = & $openClawModule {
        param($packageRootValue)
        Get-OpenClawPackageTreeMetadataDigest -PackageRoot $packageRootValue
    } $syntheticPackageRoot
    $secondMetadataDigest = & $openClawModule {
        param($packageRootValue)
        Get-OpenClawPackageTreeMetadataDigest -PackageRoot $packageRootValue
    } $syntheticPackageRoot
    Assert-Equal -Actual $secondMetadataDigest.Sha256 -Expected $firstMetadataDigest.Sha256 -Name 'Package metadata tree digest is deterministic'
    Assert-Equal -Actual $secondMetadataDigest.FileCount -Expected 3 -Name 'Package metadata tree digest counts package files'

    $provenanceStateRoot = Join-Path $exactTemporaryTestRoot 'provenance-state'
    $provenanceReceiptPath = & $openClawModule {
        param($snapshotValue, $targetVersionValue, $fingerprintValue, $stateDirectoryValue)
        Write-OpenClawProvenanceReceipt -Snapshot $snapshotValue -TargetVersion $targetVersionValue -SourceFingerprint $fingerprintValue -StateDirectory $stateDirectoryValue
    } $syntheticSnapshot $targetOpenClawVersion $actualSourceFingerprint $provenanceStateRoot
    Assert-True -Condition (Test-Path -LiteralPath $provenanceReceiptPath -PathType Leaf) -Name 'Provenance receipt is written for a trusted exact-version package'
    $provenanceReceipt = Get-Content -LiteralPath $provenanceReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal -Actual ([int]$provenanceReceipt.schemaVersion) -Expected 2 -Name 'Provenance receipt uses the metadata-cache schema'
    Assert-Equal -Actual ([string]$provenanceReceipt.packageMetadataTreeSha256) -Expected $firstMetadataDigest.Sha256 -Name 'Provenance receipt stamps the deterministic package metadata tree'
    Assert-Equal -Actual ([string]$provenanceReceipt.packageEntryPointRelativePath) -Expected 'index.js' -Name 'Provenance receipt stamps the package entrypoint path'
    Assert-Equal -Actual ([string]$provenanceReceipt.packageEntryPointSha256) -Expected (Get-FileHash -LiteralPath $syntheticPackageFile -Algorithm SHA256).Hash.ToUpperInvariant() -Name 'Provenance receipt stamps the package entrypoint content'
    Assert-Equal -Actual ([string]$provenanceReceipt.packageJsonSha256) -Expected (Get-FileHash -LiteralPath $syntheticPackageJsonFile -Algorithm SHA256).Hash.ToUpperInvariant() -Name 'Provenance receipt stamps package metadata content'
    Assert-Equal -Actual ([string]$provenanceReceipt.commandShimSha256) -Expected (Get-FileHash -LiteralPath $syntheticCommandShim -Algorithm SHA256).Hash.ToUpperInvariant() -Name 'Provenance receipt stamps the command shim content'

    $validProvenanceReceipt = & $openClawModule {
        param($snapshotValue, $stateDirectoryValue)
        Test-OpenClawProvenanceReceipt -Snapshot $snapshotValue -StateDirectory $stateDirectoryValue
    } $syntheticSnapshot $provenanceStateRoot
    Assert-True -Condition $validProvenanceReceipt.Valid -Name 'Provenance receipt validates after a write-read roundtrip'
    Assert-Equal -Actual $validProvenanceReceipt.VerificationMode -Expected 'MetadataCache' -Name 'Unchanged package validation uses the metadata cache'

    $escapedEntrySnapshot = [pscustomobject]@{
        Found = $true
        Trusted = $true
        Ambiguous = $false
        ExitCode = 0
        Version = $targetOpenClawVersion
        Path = $syntheticCommandShim
        EntryPath = $syntheticCommandShim
        PackageRoot = $syntheticPackageRoot
    }
    $escapedEntryException = Get-ThrownException {
        [void](& $openClawModule {
            param($snapshotValue)
            Get-OpenClawCriticalPackageDigests -Snapshot $snapshotValue
        } $escapedEntrySnapshot)
    }
    Assert-True -Condition ($null -ne $escapedEntryException) -Name 'Critical entrypoint hashing rejects paths outside the package root'

    $helperOriginalBytes = [IO.File]::ReadAllBytes($syntheticHelperFile)
    $helperCreationTimeUtc = [IO.File]::GetCreationTimeUtc($syntheticHelperFile)
    $helperLastWriteTimeUtc = [IO.File]::GetLastWriteTimeUtc($syntheticHelperFile)
    $helperAttributes = [IO.File]::GetAttributes($syntheticHelperFile)
    [IO.File]::SetLastWriteTimeUtc($syntheticHelperFile, $helperLastWriteTimeUtc.AddSeconds(2))
    $metadataOnlyProvenanceReceipt = & $openClawModule {
        param($snapshotValue, $stateDirectoryValue)
        Test-OpenClawProvenanceReceipt -Snapshot $snapshotValue -StateDirectory $stateDirectoryValue
    } $syntheticSnapshot $provenanceStateRoot
    Assert-True -Condition $metadataOnlyProvenanceReceipt.Valid -Name 'Metadata-only package change falls back to the retained full digest'
    Assert-Equal -Actual $metadataOnlyProvenanceReceipt.VerificationMode -Expected 'FullFallback' -Name 'Metadata-only package change reports full-digest fallback'
    [IO.File]::SetCreationTimeUtc($syntheticHelperFile, $helperCreationTimeUtc)
    [IO.File]::SetLastWriteTimeUtc($syntheticHelperFile, $helperLastWriteTimeUtc)
    [IO.File]::SetAttributes($syntheticHelperFile, $helperAttributes)

    [IO.File]::AppendAllText($syntheticHelperFile, "`n// tampered", $utf8NoBom)
    $tamperedProvenanceReceipt = & $openClawModule {
        param($snapshotValue, $stateDirectoryValue)
        Test-OpenClawProvenanceReceipt -Snapshot $snapshotValue -StateDirectory $stateDirectoryValue
    } $syntheticSnapshot $provenanceStateRoot
    Assert-True -Condition (-not $tamperedProvenanceReceipt.Valid) -Name 'Provenance receipt detects package file tampering'
    Assert-Equal -Actual $tamperedProvenanceReceipt.VerificationMode -Expected 'FullFallback' -Name 'Ordinary package tampering is rejected by full-digest fallback'
    [IO.File]::WriteAllBytes($syntheticHelperFile, $helperOriginalBytes)
    [IO.File]::SetCreationTimeUtc($syntheticHelperFile, $helperCreationTimeUtc)
    [IO.File]::SetLastWriteTimeUtc($syntheticHelperFile, $helperLastWriteTimeUtc)
    [IO.File]::SetAttributes($syntheticHelperFile, $helperAttributes)

    $entryOriginalBytes = [IO.File]::ReadAllBytes($syntheticPackageFile)
    $entryCreationTimeUtc = [IO.File]::GetCreationTimeUtc($syntheticPackageFile)
    $entryLastWriteTimeUtc = [IO.File]::GetLastWriteTimeUtc($syntheticPackageFile)
    $entryAttributes = [IO.File]::GetAttributes($syntheticPackageFile)
    $entryTamperedBytes = [byte[]]$entryOriginalBytes.Clone()
    $entryTamperedBytes[0] = [byte]($entryTamperedBytes[0] -bxor 1)
    [IO.File]::WriteAllBytes($syntheticPackageFile, $entryTamperedBytes)
    [IO.File]::SetCreationTimeUtc($syntheticPackageFile, $entryCreationTimeUtc)
    [IO.File]::SetLastWriteTimeUtc($syntheticPackageFile, $entryLastWriteTimeUtc)
    [IO.File]::SetAttributes($syntheticPackageFile, $entryAttributes)
    $entryTamperMetadataDigest = & $openClawModule {
        param($packageRootValue)
        Get-OpenClawPackageTreeMetadataDigest -PackageRoot $packageRootValue
    } $syntheticPackageRoot
    Assert-Equal -Actual $entryTamperMetadataDigest.Sha256 -Expected ([string]$provenanceReceipt.packageMetadataTreeSha256) -Name 'Same-size and same-metadata entrypoint tamper bypasses only the metadata signal'
    $entryTamperProvenanceReceipt = & $openClawModule {
        param($snapshotValue, $stateDirectoryValue)
        Test-OpenClawProvenanceReceipt -Snapshot $snapshotValue -StateDirectory $stateDirectoryValue
    } $syntheticSnapshot $provenanceStateRoot
    Assert-True -Condition (-not $entryTamperProvenanceReceipt.Valid) -Name 'Entrypoint content hash rejects same-metadata tampering'
    Assert-Equal -Actual $entryTamperProvenanceReceipt.VerificationMode -Expected 'CriticalFiles' -Name 'Entrypoint tampering is rejected before metadata-cache acceptance'
    [IO.File]::WriteAllBytes($syntheticPackageFile, $entryOriginalBytes)
    [IO.File]::SetCreationTimeUtc($syntheticPackageFile, $entryCreationTimeUtc)
    [IO.File]::SetLastWriteTimeUtc($syntheticPackageFile, $entryLastWriteTimeUtc)
    [IO.File]::SetAttributes($syntheticPackageFile, $entryAttributes)

    $packageJsonOriginalBytes = [IO.File]::ReadAllBytes($syntheticPackageJsonFile)
    $packageJsonCreationTimeUtc = [IO.File]::GetCreationTimeUtc($syntheticPackageJsonFile)
    $packageJsonLastWriteTimeUtc = [IO.File]::GetLastWriteTimeUtc($syntheticPackageJsonFile)
    $packageJsonAttributes = [IO.File]::GetAttributes($syntheticPackageJsonFile)
    $packageJsonTamperedBytes = [byte[]]$packageJsonOriginalBytes.Clone()
    $packageJsonTamperedBytes[0] = [byte]($packageJsonTamperedBytes[0] -bxor 1)
    [IO.File]::WriteAllBytes($syntheticPackageJsonFile, $packageJsonTamperedBytes)
    [IO.File]::SetCreationTimeUtc($syntheticPackageJsonFile, $packageJsonCreationTimeUtc)
    [IO.File]::SetLastWriteTimeUtc($syntheticPackageJsonFile, $packageJsonLastWriteTimeUtc)
    [IO.File]::SetAttributes($syntheticPackageJsonFile, $packageJsonAttributes)
    $packageJsonTamperProvenanceReceipt = & $openClawModule {
        param($snapshotValue, $stateDirectoryValue)
        Test-OpenClawProvenanceReceipt -Snapshot $snapshotValue -StateDirectory $stateDirectoryValue
    } $syntheticSnapshot $provenanceStateRoot
    Assert-True -Condition (-not $packageJsonTamperProvenanceReceipt.Valid) -Name 'Package metadata content hash rejects same-metadata tampering'
    Assert-Equal -Actual $packageJsonTamperProvenanceReceipt.VerificationMode -Expected 'CriticalFiles' -Name 'Package metadata tampering is rejected before metadata-cache acceptance'
    [IO.File]::WriteAllBytes($syntheticPackageJsonFile, $packageJsonOriginalBytes)
    [IO.File]::SetCreationTimeUtc($syntheticPackageJsonFile, $packageJsonCreationTimeUtc)
    [IO.File]::SetLastWriteTimeUtc($syntheticPackageJsonFile, $packageJsonLastWriteTimeUtc)
    [IO.File]::SetAttributes($syntheticPackageJsonFile, $packageJsonAttributes)

    $shimOriginalBytes = [IO.File]::ReadAllBytes($syntheticCommandShim)
    $shimTamperedBytes = [byte[]]$shimOriginalBytes.Clone()
    $shimTamperedBytes[0] = [byte]($shimTamperedBytes[0] -bxor 1)
    [IO.File]::WriteAllBytes($syntheticCommandShim, $shimTamperedBytes)
    $shimTamperProvenanceReceipt = & $openClawModule {
        param($snapshotValue, $stateDirectoryValue)
        Test-OpenClawProvenanceReceipt -Snapshot $snapshotValue -StateDirectory $stateDirectoryValue
    } $syntheticSnapshot $provenanceStateRoot
    Assert-True -Condition (-not $shimTamperProvenanceReceipt.Valid) -Name 'Command shim content hash rejects tampering'
    Assert-Equal -Actual $shimTamperProvenanceReceipt.VerificationMode -Expected 'CriticalFiles' -Name 'Command shim tampering is rejected before metadata-cache acceptance'
    [IO.File]::WriteAllBytes($syntheticCommandShim, $shimOriginalBytes)

    $currentReceiptJson = Get-Content -LiteralPath $provenanceReceiptPath -Raw -Encoding UTF8
    $legacyReceipt = $currentReceiptJson | ConvertFrom-Json
    $legacyReceipt.schemaVersion = 1
    [IO.File]::WriteAllText($provenanceReceiptPath, ($legacyReceipt | ConvertTo-Json -Depth 4), $utf8NoBom)
    $legacyProvenanceReceipt = & $openClawModule {
        param($snapshotValue, $stateDirectoryValue)
        Test-OpenClawProvenanceReceipt -Snapshot $snapshotValue -StateDirectory $stateDirectoryValue
    } $syntheticSnapshot $provenanceStateRoot
    Assert-True -Condition (-not $legacyProvenanceReceipt.Valid) -Name 'Legacy provenance receipts fail closed instead of bypassing metadata-cache fields'
    Assert-Equal -Actual $legacyProvenanceReceipt.VerificationMode -Expected 'None' -Name 'Legacy provenance receipts are rejected before package execution checks'
    [IO.File]::WriteAllText($provenanceReceiptPath, $currentReceiptJson, $utf8NoBom)

    Remove-Item -LiteralPath $corruptCheckpointPath -Force
    Remove-Item -LiteralPath $schemaCheckpointPath -Force

    $logPath = New-OpenClawLog -StateDirectory $exactTemporaryTestRoot
    Write-OpenClawLog -Path $logPath -Level Error -Event 'synthetic-failure' -Message ("See https://example.invalid/support?token={0}" -f $syntheticToken) -Data @{
        token = $syntheticToken
        sha256 = $syntheticSha256
    }
    $bundleDestination = Join-Path $exactTemporaryTestRoot 'diagnostic-bundle.zip'
    $bundle = Export-OpenClawDiagnosticBundle -StateDirectory $exactTemporaryTestRoot -DestinationPath $bundleDestination
    Assert-True -Condition (Test-Path -LiteralPath $bundle.Path -PathType Leaf) -Name 'Offline diagnostic bundle creates a ZIP file'
    Assert-Equal -Actual $bundle.Sha256 -Expected (Get-FileHash -LiteralPath $bundle.Path -Algorithm SHA256).Hash.ToUpperInvariant() -Name 'Diagnostic bundle reports its actual SHA-256'

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $bundleArchive = [IO.Compression.ZipFile]::OpenRead($bundle.Path)
    $bundleContents = @{}
    try {
        $bundleEntryNames = @($bundleArchive.Entries | ForEach-Object FullName)
        $allowedBundleEntries = @('checkpoint-summary.json', 'manifest.json', 'readiness.json', 'recent-log.jsonl', 'redaction-report.json', 'versions.json')
        Assert-Equal -Actual $bundleEntryNames.Count -Expected $allowedBundleEntries.Count -Name 'Diagnostic bundle contains only the allowlisted file count'
        Assert-True -Condition (@($bundleEntryNames | Where-Object { $_ -notin $allowedBundleEntries }).Count -eq 0) -Name 'Diagnostic bundle contains only allowlisted file names'
        foreach ($entry in $bundleArchive.Entries) {
            $stream = $entry.Open()
            $reader = New-Object IO.StreamReader($stream, (New-Object Text.UTF8Encoding($false)))
            try {
                $bundleContents[$entry.FullName] = $reader.ReadToEnd()
            }
            finally {
                $reader.Dispose()
                $stream.Dispose()
            }
        }
    }
    finally {
        $bundleArchive.Dispose()
    }

    $bundleJsonValid = $true
    foreach ($jsonEntryName in @('checkpoint-summary.json', 'manifest.json', 'readiness.json', 'redaction-report.json', 'versions.json')) {
        try {
            $null = $bundleContents[$jsonEntryName] | ConvertFrom-Json
        }
        catch {
            $bundleJsonValid = $false
        }
    }
    foreach ($jsonLine in @($bundleContents['recent-log.jsonl'] -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        try {
            $null = $jsonLine | ConvertFrom-Json
        }
        catch {
            $bundleJsonValid = $false
        }
    }
    Assert-True -Condition $bundleJsonValid -Name 'Every diagnostic bundle JSON payload is parseable'
    $allBundleText = @($bundleContents.Values) -join [Environment]::NewLine
    Assert-True -Condition (-not $allBundleText.Contains($syntheticToken)) -Name 'Diagnostic bundle excludes synthetic token values'
    Assert-True -Condition (-not $allBundleText.Contains('?token=')) -Name 'Diagnostic bundle excludes URI query secrets'
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        Assert-True -Condition ($allBundleText.IndexOf($env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase) -lt 0) -Name 'Diagnostic bundle excludes the user profile path'
    }

    $entryCommand = Get-Command -Name $entryPoint
    Assert-True -Condition $entryCommand.Parameters.ContainsKey('Resume') -Name 'Entry point exposes the Resume switch'
    Assert-True -Condition $entryCommand.Parameters.ContainsKey('StateDirectory') -Name 'Entry point exposes the StateDirectory parameter'
    Assert-True -Condition $entryCommand.Parameters.ContainsKey('DiagnosticOutputPath') -Name 'Entry point exposes the DiagnosticOutputPath parameter'

    $resumePreviewRoot = Join-Path $exactTemporaryTestRoot 'resume-preview-must-not-exist'
    $hostExecutable = (Get-Process -Id $PID).Path
    $resumePreviewOutput = (& $hostExecutable -NoLogo -NoProfile -ExecutionPolicy Bypass -File $entryPoint -Action Install -Resume -StateDirectory $resumePreviewRoot 2>&1 | Out-String)
    $resumePreviewExitCode = $LASTEXITCODE
    Assert-Equal -Actual $resumePreviewExitCode -Expected 0 -Name 'Resume without Apply exits successfully as a preview'
    Assert-True -Condition (-not (Test-Path -LiteralPath $resumePreviewRoot)) -Name 'Resume without Apply does not mutate its requested state directory'

    $bundleWhatIfStateRoot = Join-Path $exactTemporaryTestRoot 'bundle-whatif-state-must-not-exist'
    $bundleWhatIfDestination = Join-Path $exactTemporaryTestRoot 'bundle-whatif-must-not-exist.zip'
    $bundleWhatIfOutput = (& $hostExecutable -NoLogo -NoProfile -ExecutionPolicy Bypass -File $entryPoint -Action Bundle -StateDirectory $bundleWhatIfStateRoot -DiagnosticOutputPath $bundleWhatIfDestination -WhatIf 2>&1 | Out-String)
    $bundleWhatIfExitCode = $LASTEXITCODE
    Assert-Equal -Actual $bundleWhatIfExitCode -Expected 0 -Name 'Bundle WhatIf exits successfully'
    Assert-True -Condition (-not (Test-Path -LiteralPath $bundleWhatIfStateRoot)) -Name 'Bundle WhatIf does not create its requested state directory'
    Assert-True -Condition (-not (Test-Path -LiteralPath $bundleWhatIfDestination)) -Name 'Bundle WhatIf does not create a diagnostic archive'
}
finally {
    if (Test-Path -LiteralPath $exactTemporaryTestRoot) {
        $resolvedTemporaryTestRoot = (Resolve-Path -LiteralPath $exactTemporaryTestRoot).Path
        if ([string]::Equals($resolvedTemporaryTestRoot, $exactTemporaryTestRoot, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedTemporaryTestRoot -Recurse -Force
        }
        else {
            Write-Host "[FAIL] Refused to clean an unexpected temporary test path: $resolvedTemporaryTestRoot" -ForegroundColor Red
            $script:Failed++
        }
    }
}

Write-Host ''
Write-Host ("Tests passed: {0}; failed: {1}" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) {
    exit 1
}
