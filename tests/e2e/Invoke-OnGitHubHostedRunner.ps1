[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$startedAtUtc = [DateTime]::UtcNow
$resultPath = $null
$resultWritten = $false
$invocation = $null
$harnessPhase = 'preflight'
$result = [ordered]@{
    schemaVersion = 1
    startedAtUtc = $startedAtUtc.ToString('o')
    completedAtUtc = ''
    success = $false
    harnessCompleted = $false
    environmentVerified = $false
    credentialsScrubbed = $false
    installerExitCode = -1
    errorCode = ''
    targetVersion = ''
    testedCommit = ''
    installedVersion = ''
    installationSucceeded = $false
    provenanceReceiptValidated = $false
    slackPluginVerified = $false
    stages = @()
}

function Test-OpenClawE2EPathContainedBy {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CandidatePath,

        [Parameter(Mandatory = $true)]
        [string]$RootPath
    )

    try {
        $candidate = [IO.Path]::GetFullPath($CandidatePath)
        $root = [IO.Path]::GetFullPath($RootPath)
        $rootPrefix = $root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        return [string]::Equals($candidate, $root, [StringComparison]::OrdinalIgnoreCase) -or
            $candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return $false
    }
}

function Write-OpenClawE2EResult {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Data,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        throw 'E2E-RESULT-PERSISTENCE-FAILED'
    }
    $parent = Split-Path -Parent $Path
    $parentItem = Get-Item -LiteralPath $parent -Force -ErrorAction Stop
    if (-not $parentItem.PSIsContainer -or
        ($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'E2E-RESULT-PERSISTENCE-FAILED'
    }

    $json = $Data | ConvertTo-Json -Depth 6
    $encoding = New-Object Text.UTF8Encoding($false)
    $bytes = $encoding.GetBytes($json)
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
}

function Get-OpenClawE2ESafeErrorCode {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Paths
    )

    $safeCodes = @(
        'OCES-BUNDLE-001',
        'OCES-BUNDLE-LOG-001',
        'OCES-CANCELLED-001',
        'OCES-CONFIG-001',
        'OCES-DIAG-001',
        'OCES-DOWNLOAD-001',
        'OCES-INSTALL-001',
        'OCES-INTEGRITY-001',
        'OCES-PREREQ-001',
        'OCES-RESUME-001',
        'OCES-SETTINGS-PARTIAL-042',
        'OCES-UNEXPECTED-001',
        'OCES-VERIFY-001'
    )
    $foundCodes = @{}
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }
        try {
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                $item.Length -le 0 -or $item.Length -gt 2MB) {
                continue
            }
            foreach ($line in @(Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction Stop)) {
                if ([string]$line -cmatch '^\uC624\uB958 \uCF54\uB4DC: (?<code>OCES-[A-Z-]+-[0-9]{3})$') {
                    $candidateCode = [string]$Matches['code']
                    if ($safeCodes -cnotcontains $candidateCode) {
                        return ''
                    }
                    $foundCodes[$candidateCode] = $true
                }
            }
        }
        catch {
            continue
        }
    }
    if ($foundCodes.Count -eq 1) {
        return [string]@($foundCodes.Keys)[0]
    }
    return ''
}

function Get-OpenClawE2EUnknownHarnessCode {
    param(
        [AllowEmptyString()]
        [string]$Phase
    )

    switch -CaseSensitive ($Phase) {
        'preflight' { return 'E2E-HARNESS-PREFLIGHT-001' }
        'paths' { return 'E2E-HARNESS-PATHS-001' }
        'source' { return 'E2E-HARNESS-SOURCE-001' }
        'environment' { return 'E2E-HARNESS-ENVIRONMENT-001' }
        'installer' { return 'E2E-HARNESS-INSTALLER-001' }
        'checkpoint' { return 'E2E-HARNESS-CHECKPOINT-001' }
        'provenance' { return 'E2E-HARNESS-PROVENANCE-001' }
        'slack' { return 'E2E-HARNESS-SLACK-001' }
        'postconditions' { return 'E2E-HARNESS-POSTCONDITIONS-001' }
        default { return 'E2E-HARNESS-001' }
    }
}

function Resolve-OpenClawE2EHarnessErrorCode {
    param(
        [AllowEmptyString()]
        [string]$CandidateCode,

        [AllowEmptyString()]
        [string]$Phase,

        [Parameter(Mandatory = $true)]
        [string[]]$SafeCodes
    )

    foreach ($safeCode in $SafeCodes) {
        if ([string]::Equals($CandidateCode, $safeCode, [StringComparison]::Ordinal)) {
            return $CandidateCode
        }
    }
    return Get-OpenClawE2EUnknownHarnessCode -Phase $Phase
}

function Select-OpenClawE2ECheckpointErrorCode {
    param(
        [AllowEmptyString()]
        [string]$CurrentCode = '',

        [AllowEmptyString()]
        [string]$CandidateCode = '',

        [Parameter(Mandatory = $true)]
        [string[]]$SafeCodes,

        [Parameter(Mandatory = $true)]
        [string[]]$SpecificInstallCodes
    )

    $resolvedCode = Resolve-OpenClawE2EHarnessErrorCode `
        -CandidateCode $CandidateCode `
        -Phase 'checkpoint' `
        -SafeCodes $SafeCodes

    if ([string]::IsNullOrWhiteSpace($CurrentCode)) {
        return $resolvedCode
    }

    if (([string]::Equals($CurrentCode, 'OCES-INSTALL-001', [StringComparison]::Ordinal) -or
        [string]::Equals($CurrentCode, 'E2E-INSTALLER-FAILED', [StringComparison]::Ordinal)) -and
        $SpecificInstallCodes -ccontains $resolvedCode) {
        return $resolvedCode
    }

    return $CurrentCode
}

function Get-OpenClawE2EPostconditionErrorCode {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Result
    )

    if (-not [bool]$Result['installationSucceeded']) {
        return 'E2E-POSTCONDITION-INSTALLATION-FAILED'
    }
    if (-not [bool]$Result['provenanceReceiptValidated'] -or
        -not [string]::Equals(
            [string]$Result['installedVersion'],
            [string]$Result['targetVersion'],
            [StringComparison]::Ordinal
        )) {
        return 'E2E-POSTCONDITION-PROVENANCE-FAILED'
    }
    if (-not [bool]$Result['slackPluginVerified']) {
        return 'E2E-SLACK-VERIFICATION-FAILED'
    }
    return 'E2E-POSTCONDITION-FAILED'
}

function Get-OpenClawE2EInstallFailureCode {
    param(
        [AllowEmptyString()]
        [string]$Detail = ''
    )

    switch -CaseSensitive ($Detail) {
        'Installer invocation failure.' { return 'E2E-INSTALL-INVOKE-FAILED' }
        'Exit code 1' { return 'E2E-INSTALL-PINNED-INSTALLER-EXIT-1' }
        'Exit code 2' { return 'E2E-INSTALL-PINNED-INSTALLER-EXIT-2' }
        'Postcondition failure.' { return 'E2E-INSTALL-POSTCONDITION-FAILED' }
        'Provenance receipt failure.' { return 'E2E-INSTALL-PROVENANCE-RECEIPT-FAILED' }
        'Slack plugin provenance or installation failure.' { return 'E2E-INSTALL-SLACK-PLUGIN-FAILED' }
        'Npm permission failure.' { return 'E2E-INSTALL-NPM-PERMISSION-FAILED' }
        'Npm disk capacity failure.' { return 'E2E-INSTALL-NPM-DISK-CAPACITY-FAILED' }
        'Npm network failure.' { return 'E2E-INSTALL-NPM-NETWORK-FAILED' }
        'Npm package target failure.' { return 'E2E-INSTALL-NPM-PACKAGE-UNAVAILABLE' }
        'Npm engine incompatibility.' { return 'E2E-INSTALL-NPM-ENGINE-INCOMPATIBLE' }
        'Npm integrity failure.' { return 'E2E-INSTALL-NPM-INTEGRITY-FAILED' }
        'Npm lifecycle failure.' { return 'E2E-INSTALL-NPM-LIFECYCLE-FAILED' }
        'Npm filesystem failure.' { return 'E2E-INSTALL-NPM-FILESYSTEM-FAILED' }
        'Npm dependency resolution failure.' { return 'E2E-INSTALL-NPM-DEPENDENCY-RESOLUTION-FAILED' }
        'Npm registry authentication failure.' { return 'E2E-INSTALL-NPM-REGISTRY-AUTH-FAILED' }
        'Npm TLS failure.' { return 'E2E-INSTALL-NPM-TLS-FAILED' }
        'Npm protocol failure.' { return 'E2E-INSTALL-NPM-PROTOCOL-FAILED' }
        'Npm diagnostics unavailable.' { return 'E2E-INSTALL-NPM-DIAGNOSTIC-UNAVAILABLE' }
        'Npm diagnostic file rejected.' { return 'E2E-INSTALL-NPM-DIAGNOSTIC-FILE-REJECTED' }
        'Npm install log missing or ambiguous.' { return 'E2E-INSTALL-NPM-DIAGNOSTIC-LOG-MISSING-OR-AMBIGUOUS' }
        'Npm failure evidence unclassified.' { return 'E2E-INSTALL-NPM-DIAGNOSTIC-EVIDENCE-UNCLASSIFIED' }
        default { return 'E2E-CHECKPOINT-STAGE-INSTALL-STATUS-MISMATCH' }
    }
}

function Get-OpenClawE2ECheckpointMismatchCode {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Checkpoint
    )

    $expectedStages = @(
        [pscustomobject]@{ id = 'diagnose'; status = 'Succeeded'; code = 'E2E-CHECKPOINT-STAGE-DIAGNOSE-STATUS-MISMATCH' }
        [pscustomobject]@{ id = 'node'; status = 'Succeeded'; code = 'E2E-CHECKPOINT-STAGE-NODE-STATUS-MISMATCH' }
        [pscustomobject]@{ id = 'download'; status = 'Succeeded'; code = 'E2E-CHECKPOINT-STAGE-DOWNLOAD-STATUS-MISMATCH' }
        [pscustomobject]@{ id = 'integrity'; status = 'Succeeded'; code = 'E2E-CHECKPOINT-STAGE-INTEGRITY-STATUS-MISMATCH' }
        [pscustomobject]@{ id = 'dryRun'; status = 'Succeeded'; code = 'E2E-CHECKPOINT-STAGE-DRY-RUN-STATUS-MISMATCH' }
        [pscustomobject]@{ id = 'install'; status = 'Succeeded'; code = 'E2E-CHECKPOINT-STAGE-INSTALL-STATUS-MISMATCH' }
        [pscustomobject]@{ id = 'onboard'; status = 'Skipped'; code = 'E2E-CHECKPOINT-STAGE-ONBOARD-STATUS-MISMATCH' }
        [pscustomobject]@{ id = 'verify'; status = 'Skipped'; code = 'E2E-CHECKPOINT-STAGE-VERIFY-STATUS-MISMATCH' }
    )
    $steps = @($Checkpoint.Steps)
    if ($steps.Count -ne $expectedStages.Count) {
        throw 'E2E-CHECKPOINT-INVALID'
    }

    for ($index = 0; $index -lt $expectedStages.Count; $index++) {
        $stepId = [string]$steps[$index].Id
        $stepStatus = [string]$steps[$index].Status
        if ($stepId -ne $expectedStages[$index].id -or
            $stepStatus -notin @('Pending', 'Running', 'Succeeded', 'Failed', 'Skipped')) {
            throw 'E2E-CHECKPOINT-INVALID'
        }
    }
    for ($index = 0; $index -lt $expectedStages.Count; $index++) {
        if ([string]$steps[$index].Status -ne $expectedStages[$index].status) {
            if ([string]::Equals([string]$expectedStages[$index].id, 'install', [StringComparison]::Ordinal) -and
                [string]::Equals([string]$steps[$index].Status, 'Failed', [StringComparison]::Ordinal)) {
                return Get-OpenClawE2EInstallFailureCode -Detail ([string]$steps[$index].Detail)
            }
            return [string]$expectedStages[$index].code
        }
    }
    if ([string]$Checkpoint.Status -ne 'Completed') {
        return 'E2E-CHECKPOINT-TOP-LEVEL-STATUS-MISMATCH'
    }
    return ''
}

function Get-OpenClawE2ECheckpointEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateRoot,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedTargetVersion,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedSourceFingerprint
    )

    $statePath = Join-Path $StateRoot 'State'
    if (-not (Test-Path -LiteralPath $statePath -PathType Container)) {
        throw 'E2E-CHECKPOINT-INVALID'
    }
    $checkpointFiles = @(Get-ChildItem -LiteralPath $statePath -File -Filter '*.json' -ErrorAction Stop |
        Where-Object { $_.BaseName -match '^[A-Fa-f0-9]{32}$' })
    if ($checkpointFiles.Count -ne 1) {
        throw 'E2E-CHECKPOINT-INVALID'
    }

    try {
        $checkpoint = Read-OpenClawCheckpoint `
            -Path $checkpointFiles[0].FullName `
            -ExpectedTargetVersion $ExpectedTargetVersion `
            -ExpectedSourceFingerprint $ExpectedSourceFingerprint
    }
    catch {
        throw 'E2E-CHECKPOINT-INVALID'
    }
    $steps = @($checkpoint.Steps)
    $mismatchCode = Get-OpenClawE2ECheckpointMismatchCode -Checkpoint $checkpoint
    $safeStages = New-Object Collections.Generic.List[object]
    foreach ($step in $steps) {
        $safeStages.Add([pscustomobject]@{
            id = [string]$step.Id
            status = [string]$step.Status
        })
    }

    return [pscustomobject]@{
        MatchesExpected = [string]::IsNullOrWhiteSpace($mismatchCode)
        FailureCode = $mismatchCode
        Stages = $safeStages.ToArray()
    }
}

function Set-OpenClawE2EMinimalEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TemporaryRoot,

        [Parameter(Mandatory = $true)]
        [string]$NpmConfigPath,

        [Parameter(Mandatory = $true)]
        [string]$NpmCachePath,

        [Parameter(Mandatory = $true)]
        [string]$GitConfigPath
    )

    $allowedNames = @(
        'ALLUSERSPROFILE',
        'APPDATA',
        'CommonProgramFiles',
        'CommonProgramFiles(x86)',
        'CommonProgramW6432',
        'ComSpec',
        'HOMEDRIVE',
        'HOMEPATH',
        'LOCALAPPDATA',
        'NUMBER_OF_PROCESSORS',
        'OS',
        'PATHEXT',
        'PROCESSOR_ARCHITECTURE',
        'PROCESSOR_IDENTIFIER',
        'ProgramData',
        'ProgramFiles',
        'ProgramFiles(x86)',
        'ProgramW6432',
        'PSModulePath',
        'PUBLIC',
        'SystemDrive',
        'SystemRoot',
        'USERNAME',
        'USERPROFILE',
        'WINDIR'
    )
    $preserved = @{}
    foreach ($name in $allowedNames) {
        $value = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        if ($null -ne $value) {
            $preserved[$name] = $value
        }
    }

    $current = [Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Process)
    foreach ($name in @($current.Keys)) {
        [Environment]::SetEnvironmentVariable([string]$name, $null, [EnvironmentVariableTarget]::Process)
    }
    foreach ($name in $preserved.Keys) {
        [Environment]::SetEnvironmentVariable([string]$name, [string]$preserved[$name], [EnvironmentVariableTarget]::Process)
    }
    $safePathCandidates = @(
        (Join-Path $env:SystemRoot 'System32'),
        $env:SystemRoot,
        (Join-Path $env:SystemRoot 'System32\Wbem'),
        (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'),
        (Join-Path $env:ProgramFiles 'Git\cmd'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd'),
        (Join-Path $env:ProgramFiles 'nodejs'),
        (Join-Path $env:LOCALAPPDATA 'Programs\nodejs')
    )
    $safePath = @($safePathCandidates |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) -and (Test-Path -LiteralPath $_ -PathType Container) } |
        Select-Object -Unique) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $safePath, [EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable('TEMP', $TemporaryRoot, [EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable('TMP', $TemporaryRoot, [EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable('NPM_CONFIG_USERCONFIG', $NpmConfigPath, [EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable('NPM_CONFIG_CACHE', $NpmCachePath, [EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable('GIT_CONFIG_GLOBAL', $GitConfigPath, [EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable('GIT_CONFIG_NOSYSTEM', '1', [EnvironmentVariableTarget]::Process)

    $remainingNames = @([Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Process).Keys)
    if (@($remainingNames | Where-Object { [string]$_ -match '(?i)(TOKEN|SECRET|PASSWORD|CREDENTIAL|API[_-]?KEY|AUTH)' }).Count -gt 0) {
        throw 'E2E-ENVIRONMENT-SCRUB-FAILED'
    }
}

function Assert-OpenClawE2EExpandedPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$BlockedRoots
    )

    $normalizedBlockedRoots = @($BlockedRoots |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        ForEach-Object { [IO.Path]::GetFullPath([string]$_) })
    foreach ($segment in @(([string]$env:Path).Split(';'))) {
        if ([string]::IsNullOrWhiteSpace($segment)) {
            continue
        }
        try {
            $fullPath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($segment))
        }
        catch {
            throw 'E2E-PATH-EXPANSION-INVALID'
        }
        if ($fullPath -match '(?i)(^|\\)hostedtoolcache(\\|$)') {
            throw 'E2E-PATH-EXPANSION-INVALID'
        }
        foreach ($blockedRoot in $normalizedBlockedRoots) {
            if (Test-OpenClawE2EPathContainedBy -CandidatePath $fullPath -RootPath $blockedRoot) {
                throw 'E2E-PATH-EXPANSION-INVALID'
            }
        }
    }
}

function Assert-OpenClawE2EStagedSource {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceRoot,

        [Parameter(Mandatory = $true)]
        [string[]]$RelativePaths,

        [Parameter(Mandatory = $true)]
        [hashtable]$ExpectedHashes
    )

    $rootItem = Get-Item -LiteralPath $SourceRoot -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or
        ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'E2E-SOURCE-MUTATED'
    }
    foreach ($directory in @(Get-ChildItem -LiteralPath $SourceRoot -Directory -Recurse -Force)) {
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'E2E-SOURCE-MUTATED'
        }
    }

    $files = @(Get-ChildItem -LiteralPath $SourceRoot -File -Recurse -Force)
    if ($files.Count -ne $RelativePaths.Count) {
        throw 'E2E-SOURCE-MUTATED'
    }
    foreach ($relativePath in $RelativePaths) {
        $path = Join-Path $SourceRoot $relativePath
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $item.Length -le 0 -or $item.Length -gt 2MB -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $ExpectedHashes[$relativePath]) {
            throw 'E2E-SOURCE-MUTATED'
        }
    }
}

$safeInstallFailureCodes = @(
    'E2E-INSTALL-INVOKE-FAILED',
    'E2E-INSTALL-PINNED-INSTALLER-EXIT-1',
    'E2E-INSTALL-PINNED-INSTALLER-EXIT-2',
    'E2E-INSTALL-POSTCONDITION-FAILED',
    'E2E-INSTALL-PROVENANCE-RECEIPT-FAILED',
    'E2E-INSTALL-SLACK-PLUGIN-FAILED',
    'E2E-INSTALL-NPM-PERMISSION-FAILED',
    'E2E-INSTALL-NPM-DISK-CAPACITY-FAILED',
    'E2E-INSTALL-NPM-NETWORK-FAILED',
    'E2E-INSTALL-NPM-PACKAGE-UNAVAILABLE',
    'E2E-INSTALL-NPM-ENGINE-INCOMPATIBLE',
    'E2E-INSTALL-NPM-INTEGRITY-FAILED',
    'E2E-INSTALL-NPM-LIFECYCLE-FAILED',
    'E2E-INSTALL-NPM-FILESYSTEM-FAILED',
    'E2E-INSTALL-NPM-DEPENDENCY-RESOLUTION-FAILED',
    'E2E-INSTALL-NPM-REGISTRY-AUTH-FAILED',
    'E2E-INSTALL-NPM-TLS-FAILED',
    'E2E-INSTALL-NPM-PROTOCOL-FAILED',
    'E2E-INSTALL-NPM-DIAGNOSTIC-UNAVAILABLE',
    'E2E-INSTALL-NPM-DIAGNOSTIC-FILE-REJECTED',
    'E2E-INSTALL-NPM-DIAGNOSTIC-LOG-MISSING-OR-AMBIGUOUS',
    'E2E-INSTALL-NPM-DIAGNOSTIC-EVIDENCE-UNCLASSIFIED'
)

$safeHarnessCodes = @(
    'E2E-ENVIRONMENT-NOT-GITHUB-HOSTED',
    'E2E-COMMIT-INVALID',
    'E2E-RUNNER-PATH-INVALID',
    'E2E-PATH-EXPANSION-INVALID',
    'E2E-RUNNER-IDENTITY-INVALID',
    'E2E-RUN-ROOT-EXISTS',
    'E2E-SOURCE-INVALID',
    'E2E-SOURCE-MUTATED',
    'E2E-ENVIRONMENT-NOT-CLEAN',
    'E2E-ENVIRONMENT-SCRUB-FAILED',
    'E2E-TRUSTED-POWERSHELL-MISSING',
    'E2E-CHECKPOINT-INVALID',
    'E2E-CHECKPOINT-STAGE-DIAGNOSE-STATUS-MISMATCH',
    'E2E-CHECKPOINT-STAGE-NODE-STATUS-MISMATCH',
    'E2E-CHECKPOINT-STAGE-DOWNLOAD-STATUS-MISMATCH',
    'E2E-CHECKPOINT-STAGE-INTEGRITY-STATUS-MISMATCH',
    'E2E-CHECKPOINT-STAGE-DRY-RUN-STATUS-MISMATCH',
    'E2E-CHECKPOINT-STAGE-INSTALL-STATUS-MISMATCH',
    'E2E-CHECKPOINT-STAGE-ONBOARD-STATUS-MISMATCH',
    'E2E-CHECKPOINT-STAGE-VERIFY-STATUS-MISMATCH',
    'E2E-CHECKPOINT-TOP-LEVEL-STATUS-MISMATCH',
    'E2E-SLACK-VERIFICATION-FAILED',
    'E2E-RESULT-PERSISTENCE-FAILED',
    'E2E-HARNESS-PREFLIGHT-001',
    'E2E-HARNESS-PATHS-001',
    'E2E-HARNESS-SOURCE-001',
    'E2E-HARNESS-ENVIRONMENT-001',
    'E2E-HARNESS-INSTALLER-001',
    'E2E-HARNESS-CHECKPOINT-001',
    'E2E-HARNESS-PROVENANCE-001',
    'E2E-HARNESS-SLACK-001',
    'E2E-HARNESS-POSTCONDITIONS-001'
) + $safeInstallFailureCodes

try {
    if ($env:GITHUB_ACTIONS -ne 'true' -or
        $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or
        $env:RUNNER_OS -ne 'Windows' -or
        $env:RUNNER_ARCH -ne 'X64' -or
        $env:GITHUB_EVENT_NAME -ne 'workflow_dispatch') {
        throw 'E2E-ENVIRONMENT-NOT-GITHUB-HOSTED'
    }
    $testedCommit = ([string]$env:GITHUB_SHA).ToLowerInvariant()
    $expectedCommit = ([string]$env:OCES_E2E_EXPECTED_SHA).ToLowerInvariant()
    if ($testedCommit -notmatch '^[0-9a-f]{40}$' -or
        $expectedCommit -ne $testedCommit -or
        [string]$env:GITHUB_REF_NAME -ne [string]$env:OCES_E2E_DEFAULT_BRANCH) {
        throw 'E2E-COMMIT-INVALID'
    }
    $result.testedCommit = $testedCommit

    $harnessPhase = 'paths'

    $projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $workspaceRoot = [IO.Path]::GetFullPath([string]$env:GITHUB_WORKSPACE)
    $runnerTemp = [IO.Path]::GetFullPath([string]$env:RUNNER_TEMP)
    $runnerToolCache = if ([string]::IsNullOrWhiteSpace([string]$env:RUNNER_TOOL_CACHE)) { '' } else { [IO.Path]::GetFullPath([string]$env:RUNNER_TOOL_CACHE) }
    $projectItem = Get-Item -LiteralPath $projectRoot -Force -ErrorAction Stop
    $workspaceItem = Get-Item -LiteralPath $workspaceRoot -Force -ErrorAction Stop
    $runnerTempItem = Get-Item -LiteralPath $runnerTemp -Force -ErrorAction Stop
    if (-not $projectItem.PSIsContainer -or -not $workspaceItem.PSIsContainer -or -not $runnerTempItem.PSIsContainer -or
        ($projectItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($workspaceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($runnerTempItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not [string]::Equals($projectRoot.TrimEnd('\'), $workspaceRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) -or
        (Test-OpenClawE2EPathContainedBy -CandidatePath $runnerTemp -RootPath $workspaceRoot) -or
        (Test-OpenClawE2EPathContainedBy -CandidatePath $workspaceRoot -RootPath $runnerTemp)) {
        throw 'E2E-RUNNER-PATH-INVALID'
    }

    $runRoot = Join-Path $runnerTemp 'OpenClawEasySetup-GitHubE2E'
    $expectedResultPath = Join-Path $runRoot 'result.json'
    if ([string]::IsNullOrWhiteSpace([string]$env:OCES_E2E_RESULT) -or
        -not [string]::Equals([IO.Path]::GetFullPath([string]$env:OCES_E2E_RESULT), $expectedResultPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'E2E-RUNNER-PATH-INVALID'
    }
    if (Test-Path -LiteralPath $runRoot) {
        throw 'E2E-RUN-ROOT-EXISTS'
    }
    [void](New-Item -ItemType Directory -Path $runRoot -ErrorAction Stop)
    $runRootItem = Get-Item -LiteralPath $runRoot -Force
    if (-not $runRootItem.PSIsContainer -or
        ($runRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not (Test-OpenClawE2EPathContainedBy -CandidatePath $runRoot -RootPath $runnerTemp)) {
        throw 'E2E-RUNNER-PATH-INVALID'
    }
    $resultPath = $expectedResultPath
    $stateRoot = Join-Path $runRoot 'StateRoot'
    $sourceRoot = Join-Path $runRoot 'Source'
    $temporaryRoot = Join-Path $runRoot 'Temp'
    $npmCachePath = Join-Path $runRoot 'npm-cache'
    $npmConfigPath = Join-Path $runRoot 'empty.npmrc'
    $gitConfigPath = Join-Path $runRoot 'empty.gitconfig'
    $standardOutputPath = Join-Path $runRoot 'install.stdout.txt'
    $standardErrorPath = Join-Path $runRoot 'install.stderr.txt'

    foreach ($directoryPath in @($sourceRoot, $temporaryRoot, $npmCachePath)) {
        [void](New-Item -ItemType Directory -Path $directoryPath -ErrorAction Stop)
    }
    foreach ($emptyConfigPath in @($npmConfigPath, $gitConfigPath)) {
        $emptyStream = New-Object IO.FileStream($emptyConfigPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $emptyStream.Dispose()
    }

    $harnessPhase = 'source'
    $stagedFiles = @(
        'OpenClawEasySetup.ps1',
        'config\openclaw-source.json',
        'locales\ko-KR.json',
        'src\OpenClawEasySetup.Recovery.ps1',
        'src\OpenClawEasySetup.psm1',
        'src\PackageIntegrity\OpenClawEasySetup.PackageTreeHasher.cs',
        'tests\e2e\Invoke-InstallSmokeWorker.ps1'
    )
    $stagedHashes = @{}
    foreach ($relativePath in $stagedFiles) {
        $sourcePath = [IO.Path]::GetFullPath((Join-Path $projectRoot $relativePath))
        if (-not (Test-OpenClawE2EPathContainedBy -CandidatePath $sourcePath -RootPath $projectRoot)) {
            throw 'E2E-SOURCE-INVALID'
        }
        $relativeParent = Split-Path -Parent $relativePath
        if (-not [string]::IsNullOrWhiteSpace($relativeParent)) {
            $sourceParent = $projectRoot
            foreach ($segment in $relativeParent.Split('\')) {
                $sourceParent = Join-Path $sourceParent $segment
                $sourceParentItem = Get-Item -LiteralPath $sourceParent -Force -ErrorAction Stop
                if (-not $sourceParentItem.PSIsContainer -or
                    ($sourceParentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw 'E2E-SOURCE-INVALID'
                }
            }
        }
        $sourceItem = Get-Item -LiteralPath $sourcePath -Force -ErrorAction Stop
        if ($sourceItem.PSIsContainer -or
            ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $sourceItem.Length -le 0 -or $sourceItem.Length -gt 2MB) {
            throw 'E2E-SOURCE-INVALID'
        }

        $destinationPath = Join-Path $sourceRoot $relativePath
        $destinationParent = Split-Path -Parent $destinationPath
        if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $destinationParent -Force -ErrorAction Stop)
        }
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -ErrorAction Stop
        $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
        if ((Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash -ne $sourceHash) {
            throw 'E2E-SOURCE-INVALID'
        }
        $stagedHashes[$relativePath] = $sourceHash
    }
    Assert-OpenClawE2EStagedSource -SourceRoot $sourceRoot -RelativePaths $stagedFiles -ExpectedHashes $stagedHashes

    $sourceConfigPath = Join-Path $sourceRoot 'config\openclaw-source.json'
    $modulePath = Join-Path $sourceRoot 'src\OpenClawEasySetup.psm1'
    $workerPath = Join-Path $sourceRoot 'tests\e2e\Invoke-InstallSmokeWorker.ps1'
    $sourceConfig = Get-Content -LiteralPath $sourceConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $sourceFingerprint = (Get-FileHash -LiteralPath $sourceConfigPath -Algorithm SHA256).Hash.ToUpperInvariant()
    $result.targetVersion = [string]$sourceConfig.openClaw.version
    if ($result.targetVersion -notmatch '^\d{4}\.\d+\.\d+$') {
        throw 'E2E-SOURCE-INVALID'
    }
    Import-Module -Name $modulePath -Force -ErrorAction Stop
    $harnessPhase = 'environment'

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if ($identity.User.Value -eq 'S-1-5-18' -or
        -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'E2E-RUNNER-IDENTITY-INVALID'
    }

    if ($null -ne (Get-Command openclaw -All -ErrorAction SilentlyContinue) -or
        (Test-Path -LiteralPath (Join-Path $env:APPDATA 'npm\node_modules\openclaw'))) {
        throw 'E2E-ENVIRONMENT-NOT-CLEAN'
    }

    $trustedPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $trustedPowerShell -PathType Leaf)) {
        throw 'E2E-TRUSTED-POWERSHELL-MISSING'
    }
    $result.environmentVerified = $true

    Set-OpenClawE2EMinimalEnvironment `
        -TemporaryRoot $temporaryRoot `
        -NpmConfigPath $npmConfigPath `
        -NpmCachePath $npmCachePath `
        -GitConfigPath $gitConfigPath
    $result.credentialsScrubbed = $true

    $harnessPhase = 'installer'
    $process = Start-Process -FilePath $trustedPowerShell -ArgumentList @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $workerPath),
        '-ProjectRoot', ('"{0}"' -f $sourceRoot),
        '-StateDirectory', ('"{0}"' -f $stateRoot)
    ) -WorkingDirectory $sourceRoot -RedirectStandardOutput $standardOutputPath -RedirectStandardError $standardErrorPath -Wait -PassThru
    $result.installerExitCode = [int]$process.ExitCode
    if ($process.ExitCode -ne 0) {
        $result.errorCode = Get-OpenClawE2ESafeErrorCode -Paths @($standardOutputPath, $standardErrorPath)
        if ([string]::IsNullOrWhiteSpace([string]$result.errorCode)) {
            $result.errorCode = 'E2E-INSTALLER-FAILED'
        }
    }

    $harnessPhase = 'checkpoint'
    Assert-OpenClawE2EStagedSource -SourceRoot $sourceRoot -RelativePaths $stagedFiles -ExpectedHashes $stagedHashes

    $checkpointEvidence = $null
    try {
        $checkpointEvidence = Get-OpenClawE2ECheckpointEvidence `
            -StateRoot $stateRoot `
            -ExpectedTargetVersion ([string]$sourceConfig.openClaw.version) `
            -ExpectedSourceFingerprint $sourceFingerprint
    }
    catch {
        if ($result.installerExitCode -eq 0) {
            throw
        }
    }
    if ($null -ne $checkpointEvidence) {
        $result.stages = @($checkpointEvidence.Stages)
        $result.installationSucceeded = [bool]$checkpointEvidence.MatchesExpected
        if (-not $result.installationSucceeded) {
            $result.errorCode = Select-OpenClawE2ECheckpointErrorCode `
                -CurrentCode ([string]$result.errorCode) `
                -CandidateCode ([string]$checkpointEvidence.FailureCode) `
                -SafeCodes $safeHarnessCodes `
                -SpecificInstallCodes $safeInstallFailureCodes
        }
    }

    $harnessPhase = 'provenance'
    if ($result.installerExitCode -eq 0) {
    try {
        Update-OpenClawProcessPath
        Assert-OpenClawE2EExpandedPath `
            -BlockedRoots @($workspaceRoot, $runnerTemp, $runnerToolCache)
        $invocation = Resolve-OpenClawInvocation -StateDirectory $stateRoot
        if ($null -ne $invocation) {
            $receiptPath = Join-Path $stateRoot 'State\provenance.json'
            $receiptItem = Get-Item -LiteralPath $receiptPath -Force -ErrorAction Stop
            if (($receiptItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and
                $receiptItem.Length -gt 0 -and $receiptItem.Length -le 64KB) {
                $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ([int]$receipt.schemaVersion -eq 2 -and
                    [string]$receipt.targetVersion -eq [string]$sourceConfig.openClaw.version -and
                    [string]$receipt.sourceFingerprint -eq $sourceFingerprint) {
                    $result.installedVersion = [string]$receipt.targetVersion
                    $result.provenanceReceiptValidated = $true
                }
            }
        }
    }
    catch {
        if ([string]$_.Exception.Message -eq 'E2E-PATH-EXPANSION-INVALID') {
            throw
        }
        $result.installedVersion = ''
        $result.provenanceReceiptValidated = $false
        $invocation = $null
        if ([string]::IsNullOrWhiteSpace([string]$result.errorCode)) {
            $result.errorCode = 'E2E-HARNESS-PROVENANCE-001'
        }
    }
    }

    $harnessPhase = 'slack'
    if ($null -ne $invocation -and $result.provenanceReceiptValidated) {
        try {
            $validatedPlugin = Get-OpenClawSlackPluginInspection -Invocation $invocation -SourceConfig $sourceConfig
            $result.slackPluginVerified = $null -ne $validatedPlugin -and [bool]$validatedPlugin.Ready
        }
        catch {
            $result.slackPluginVerified = $false
            if ([string]::IsNullOrWhiteSpace([string]$result.errorCode)) {
                $result.errorCode = 'E2E-SLACK-VERIFICATION-FAILED'
            }
        }
    }

    $harnessPhase = 'postconditions'
    $result.harnessCompleted = $true
    $result.success = $result.installerExitCode -eq 0 -and
        $result.environmentVerified -and
        $result.credentialsScrubbed -and
        $result.installationSucceeded -and
        $result.provenanceReceiptValidated -and
        $result.slackPluginVerified -and
        [string]$result.installedVersion -eq [string]$result.targetVersion
    if (-not $result.success -and [string]::IsNullOrWhiteSpace([string]$result.errorCode)) {
        $result.errorCode = Get-OpenClawE2EPostconditionErrorCode -Result $result
    }
}
catch {
    $candidateCode = [string]$_.Exception.Message
    $result.errorCode = Resolve-OpenClawE2EHarnessErrorCode -CandidateCode $candidateCode -Phase $harnessPhase -SafeCodes $safeHarnessCodes
    $result.success = $false
}
finally {
    $result.completedAtUtc = [DateTime]::UtcNow.ToString('o')
    if (-not [string]::IsNullOrWhiteSpace($resultPath) -and -not $resultWritten) {
        try {
            Write-OpenClawE2EResult -Data $result -Path $resultPath
            $resultWritten = $true
        }
        catch {
            $result.success = $false
            $result.harnessCompleted = $false
            $result.errorCode = 'E2E-RESULT-PERSISTENCE-FAILED'
        }
    }

    $statusText = if ($result.success -and $resultWritten) { 'PASS' } else { 'FAIL' }
    Write-Host ("Windows install E2E: {0}" -f $statusText)
    Write-Host ("Target version: {0}" -f $result.targetVersion)
    Write-Host ("Installer exit code: {0}" -f $result.installerExitCode)
    foreach ($stage in @($result.stages)) {
        Write-Host ("Checkpoint stage {0}: {1}" -f ([string]$stage.id), ([string]$stage.status))
    }
    if (-not $result.success) {
        Write-Host ("Safe error code: {0}" -f $result.errorCode)
    }
}

if (-not $result.success -or -not $resultWritten) {
    exit 90
}
