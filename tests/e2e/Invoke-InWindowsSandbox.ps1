[CmdletBinding()]
param(
    [ValidateSet('Gui', 'InstallSmoke')]
    [string]$Mode = 'Gui',

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Fa-f0-9]{32}$')]
    [string]$RunId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourceRoot = 'C:\OCES-Source'
$resultsRoot = 'C:\OCES-Results'
$startedAtUtc = [DateTime]::UtcNow
$resultWritten = $false
$result = [ordered]@{
    schemaVersion = 1
    runId = $RunId.ToLowerInvariant()
    mode = $Mode
    startedAtUtc = $startedAtUtc.ToString('o')
    completedAtUtc = ''
    success = $false
    harnessCompleted = $false
    guiExitedCleanly = $false
    installationSucceeded = $false
    exitCode = -1
    errorCode = ''
    targetVersion = ''
    installedVersion = ''
    provenanceReceiptValidated = $false
    slackPluginVerified = $false
    sandboxIdentityVerified = $false
    sourceMappedReadOnly = $false
    stages = @()
}

function Write-OpenClawSandboxResult {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Data
    )

    if (-not (Test-Path -LiteralPath $resultsRoot -PathType Container)) {
        throw 'The dedicated Sandbox results mapping was not available.'
    }
    $targetPath = Join-Path $resultsRoot 'result.json'
    if (Test-Path -LiteralPath $targetPath) {
        throw 'The Sandbox result file already existed.'
    }
    $json = $Data | ConvertTo-Json -Depth 6
    $encoding = New-Object Text.UTF8Encoding($false)
    $bytes = $encoding.GetBytes($json)
    $stream = New-Object IO.FileStream($targetPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
}

function Get-OpenClawSandboxCheckpointSummary {
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
        return @()
    }
    $checkpointFile = Get-ChildItem -LiteralPath $statePath -File -Filter '*.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -match '^[A-Fa-f0-9]{32}$' } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -eq $checkpointFile) {
        return @()
    }
    $checkpoint = Read-OpenClawCheckpoint `
        -Path $checkpointFile.FullName `
        -ExpectedTargetVersion $ExpectedTargetVersion `
        -ExpectedSourceFingerprint $ExpectedSourceFingerprint
    $expectedStageIds = @('diagnose', 'node', 'download', 'integrity', 'dryRun', 'install', 'onboard', 'verify')
    $steps = @($checkpoint.Steps)
    if ($steps.Count -ne $expectedStageIds.Count) {
        throw 'E2E-CHECKPOINT-INVALID'
    }
    for ($index = 0; $index -lt $expectedStageIds.Count; $index++) {
        if ([string]$steps[$index].Id -ne $expectedStageIds[$index] -or
            [string]$steps[$index].Status -notin @('Pending', 'Running', 'Succeeded', 'Failed', 'Skipped')) {
            throw 'E2E-CHECKPOINT-INVALID'
        }
    }
    return @($steps | ForEach-Object {
        [pscustomobject]@{
            id = [string]$_.Id
            status = [string]$_.Status
        }
    })
}

function Update-OpenClawSandboxPostInstallResult {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Data,

        [Parameter(Mandatory = $true)]
        [string]$StateRoot,

        [Parameter(Mandatory = $true)]
        [object]$SourceConfig,

        [Parameter(Mandatory = $true)]
        [string]$SourceFingerprint
    )

    $Data.stages = @(Get-OpenClawSandboxCheckpointSummary `
        -StateRoot $StateRoot `
        -ExpectedTargetVersion ([string]$SourceConfig.openClaw.version) `
        -ExpectedSourceFingerprint $SourceFingerprint)
    $installStage = @($Data.stages | Where-Object { $_.id -eq 'install' } | Select-Object -First 1)
    $Data.installationSucceeded = $installStage.Count -eq 1 -and $installStage[0].status -eq 'Succeeded'

    try {
        Update-OpenClawProcessPath
        $invocation = Resolve-OpenClawInvocation -StateDirectory $StateRoot
        if ($null -eq $invocation) {
            return
        }
        $receiptPath = Join-Path $StateRoot 'State\provenance.json'
        $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$receipt.targetVersion -ne [string]$SourceConfig.openClaw.version) {
            return
        }
        $Data.installedVersion = [string]$receipt.targetVersion
        $Data.provenanceReceiptValidated = $true
    }
    catch {
        $Data.provenanceReceiptValidated = $false
        $Data.installedVersion = ''
        return
    }

    try {
        $inspectionArguments = @($invocation.PrefixArguments) + @('plugins', 'inspect', 'slack', '--json')
        $inspectionText = (& $invocation.Executable @inspectionArguments 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($inspectionText)) {
            $inspection = $inspectionText | ConvertFrom-Json
            $validatedPlugin = Assert-OpenClawSlackPluginProvenance -Inspection $inspection -SourceConfig $SourceConfig
            $Data.slackPluginVerified = $null -ne $validatedPlugin -and [bool]$validatedPlugin.Ready
        }
    }
    catch {
        $Data.slackPluginVerified = $false
    }
}

try {
    $identityName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $accountName = ($identityName -split '\\')[-1]
    if ($accountName -ne 'WDAGUtilityAccount') {
        throw 'E2E-ENVIRONMENT-NOT-SANDBOX'
    }
    $result.sandboxIdentityVerified = $true
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container) -or
        -not (Test-Path -LiteralPath $resultsRoot -PathType Container)) {
        throw 'E2E-MAPPING-MISSING'
    }

    $writeProbePath = Join-Path $sourceRoot ('.oces-write-probe-{0}' -f ([guid]::NewGuid().ToString('N')))
    try {
        $writeProbe = New-Object IO.FileStream($writeProbePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $writeProbe.Dispose()
    }
    catch {
        # The configured read-only mapping must reject creation.
    }
    if (Test-Path -LiteralPath $writeProbePath) {
        Remove-Item -LiteralPath $writeProbePath -Force -ErrorAction SilentlyContinue
        throw 'E2E-SOURCE-MAPPING-WRITABLE'
    }
    $result.sourceMappedReadOnly = $true

    if ($null -ne (Get-Command openclaw -All -ErrorAction SilentlyContinue) -or
        (Test-Path -LiteralPath (Join-Path $env:APPDATA 'npm\node_modules\openclaw'))) {
        throw 'E2E-ENVIRONMENT-NOT-CLEAN'
    }

    $runRoot = Join-Path $env:LOCALAPPDATA ("OpenClawEasySetup-E2E\{0}" -f ([guid]::NewGuid().ToString('N')))
    $appRoot = Join-Path $runRoot 'App'
    $stateRoot = Join-Path $runRoot 'StateRoot'
    [void](New-Item -ItemType Directory -Path $appRoot -Force)
    [void](New-Item -ItemType Directory -Path $stateRoot -Force)

    foreach ($item in @(Get-ChildItem -LiteralPath $sourceRoot -Force)) {
        Copy-Item -LiteralPath $item.FullName -Destination $appRoot -Recurse -Force
    }

    $sourceConfigPath = Join-Path $appRoot 'config\openclaw-source.json'
    $sourceConfig = Get-Content -LiteralPath $sourceConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $sourceFingerprint = (Get-FileHash -LiteralPath $sourceConfigPath -Algorithm SHA256).Hash.ToUpperInvariant()
    $result.targetVersion = [string]$sourceConfig.openClaw.version
    $modulePath = Join-Path $appRoot 'src\OpenClawEasySetup.psm1'
    Import-Module -Name $modulePath -Force -ErrorAction Stop
    $trustedPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $trustedPowerShell -PathType Leaf)) {
        throw 'E2E-TRUSTED-POWERSHELL-MISSING'
    }

    Write-Host ''
    Write-Host 'OpenClaw Easy Setup 격리 시험' -ForegroundColor Cyan
    Write-Host '이 창은 일회용 Windows Sandbox 안에서 실행 중입니다.'
    Write-Host '운영용 API 키나 메신저 토큰을 사용하지 마세요.' -ForegroundColor Yellow
    Write-Host 'Sandbox를 닫으면 내부 프로그램, 설정, 자격 증명이 모두 삭제됩니다.'
    Write-Host ''

    if ($Mode -eq 'Gui') {
        $guiPath = Join-Path $appRoot 'OpenClawEasySetup.Gui.ps1'
        $process = Start-Process -FilePath $trustedPowerShell -ArgumentList @(
            '-NoLogo', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
            '-File', ('"{0}"' -f $guiPath),
            '-StateDirectory', ('"{0}"' -f $stateRoot)
        ) -Wait -PassThru
        $result.exitCode = [int]$process.ExitCode
        $result.guiExitedCleanly = $process.ExitCode -eq 0
        Update-OpenClawSandboxPostInstallResult -Data $result -StateRoot $stateRoot -SourceConfig $sourceConfig -SourceFingerprint $sourceFingerprint
        $result.harnessCompleted = $true
    }
    else {
        $entryPoint = Join-Path $appRoot 'OpenClawEasySetup.ps1'
        $standardOutputPath = Join-Path $runRoot 'install.stdout.txt'
        $standardErrorPath = Join-Path $runRoot 'install.stderr.txt'
        $process = Start-Process -FilePath $trustedPowerShell -ArgumentList @(
            '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', ('"{0}"' -f $entryPoint),
            '-Action', 'Install', '-Apply', '-SkipOnboarding', '-Confirm:$false',
            '-StateDirectory', ('"{0}"' -f $stateRoot)
        ) -RedirectStandardOutput $standardOutputPath -RedirectStandardError $standardErrorPath -Wait -PassThru
        $result.exitCode = [int]$process.ExitCode

        $safeErrorCode = ''
        foreach ($outputPath in @($standardOutputPath, $standardErrorPath)) {
            if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
                $outputText = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                $errorMatch = [regex]::Match([string]$outputText, 'OCES-[A-Z-]+-[0-9]{3}')
                if ($errorMatch.Success) {
                    $safeErrorCode = $errorMatch.Value
                    break
                }
            }
        }
        $result.errorCode = $safeErrorCode
        Update-OpenClawSandboxPostInstallResult -Data $result -StateRoot $stateRoot -SourceConfig $sourceConfig -SourceFingerprint $sourceFingerprint
        $result.harnessCompleted = $true
    }

    $result.success = $process.ExitCode -eq 0 -and
        $result.installationSucceeded -and
        $result.provenanceReceiptValidated -and
        $result.slackPluginVerified -and
        [string]$result.installedVersion -eq [string]$result.targetVersion
    if ($Mode -eq 'InstallSmoke' -and -not $result.success -and [string]::IsNullOrWhiteSpace([string]$result.errorCode)) {
        $result.errorCode = 'E2E-POSTCONDITION-FAILED'
    }
}
catch {
    $safeHarnessCodes = @(
        'E2E-ENVIRONMENT-NOT-SANDBOX',
        'E2E-MAPPING-MISSING',
        'E2E-SOURCE-MAPPING-WRITABLE',
        'E2E-ENVIRONMENT-NOT-CLEAN',
        'E2E-TRUSTED-POWERSHELL-MISSING',
        'E2E-CHECKPOINT-INVALID'
    )
    $candidateCode = [string]$_.Exception.Message
    $result.errorCode = if ($candidateCode -in $safeHarnessCodes) { $candidateCode } else { 'E2E-HARNESS-001' }
    $result.exitCode = 90
    $result.success = $false
}
finally {
    $result.completedAtUtc = [DateTime]::UtcNow.ToString('o')
    if (-not $resultWritten) {
        try {
            Write-OpenClawSandboxResult -Data $result
            $resultWritten = $true
            Write-Host ("정제된 시험 결과: {0}" -f (Join-Path $resultsRoot 'result.json')) -ForegroundColor Green
        }
        catch {
            $result.success = $false
            $result.harnessCompleted = $false
            $result.exitCode = 90
            $result.errorCode = 'E2E-RESULT-PERSISTENCE-FAILED'
            Write-Host '정제된 시험 결과를 저장하지 못했습니다.' -ForegroundColor Red
        }
    }
}

if (-not $result.success -or -not $resultWritten) {
    exit 90
}
