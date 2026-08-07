[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$launcherPath = Join-Path $projectRoot 'Start-OpenClawEasySetup.Sandbox.ps1'
$sandboxEntryPoint = Join-Path $projectRoot 'tests\e2e\Invoke-InWindowsSandbox.ps1'
$workerPath = Join-Path $projectRoot 'tests\e2e\Invoke-InstallSmokeWorker.ps1'
$script:Passed = 0
$script:Failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) {
        $script:Passed++
        Write-Host "PASS: $Name" -ForegroundColor Green
    }
    else {
        $script:Failed++
        Write-Host "FAIL: $Name" -ForegroundColor Red
    }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Name)
    Assert-True -Condition ($Actual -eq $Expected) -Name $Name
}

$parseErrors = $null
$null = [Management.Automation.Language.Parser]::ParseFile($launcherPath, [ref]$null, [ref]$parseErrors)
Assert-Equal -Actual @($parseErrors).Count -Expected 0 -Name 'Sandbox host launcher parses as PowerShell'
$parseErrors = $null
$null = [Management.Automation.Language.Parser]::ParseFile($sandboxEntryPoint, [ref]$null, [ref]$parseErrors)
Assert-Equal -Actual @($parseErrors).Count -Expected 0 -Name 'In-sandbox E2E entry point parses as PowerShell'
$parseErrors = $null
$null = [Management.Automation.Language.Parser]::ParseFile($workerPath, [ref]$null, [ref]$parseErrors)
Assert-Equal -Actual @($parseErrors).Count -Expected 0 -Name 'Shared install-smoke worker parses as PowerShell'

$generatedRuns = New-Object Collections.Generic.List[object]
try {
    $guiGeneration = & $launcherPath -Mode Gui -GenerateOnly
    $generatedRuns.Add($guiGeneration)
    $launcherCommand = Get-Command -Name $launcherPath
    Assert-True -Condition (-not $launcherCommand.Parameters.ContainsKey('WhatIf')) -Name 'Sandbox launcher uses GenerateOnly instead of an ambient mutating WhatIf path'
    Assert-True -Condition (Test-Path -LiteralPath $guiGeneration.ConfigurationPath -PathType Leaf) -Name 'GenerateOnly creates a Windows Sandbox configuration without launching it'
    Assert-True -Condition (Test-Path -LiteralPath $guiGeneration.ResultsDirectory -PathType Container) -Name 'GenerateOnly creates a dedicated empty result directory'
    Assert-True -Condition (Test-Path -LiteralPath $guiGeneration.SourceStagingDirectory -PathType Container) -Name 'GenerateOnly creates a dedicated source staging directory'
    Assert-True -Condition ($guiGeneration.Disposable -and $guiGeneration.SourceMappedReadOnly -and -not $guiGeneration.ClipboardEnabled) -Name 'Generated GUI run reports its disposable safe defaults'

    [xml]$guiXml = Get-Content -LiteralPath $guiGeneration.ConfigurationPath -Raw -Encoding UTF8
    Assert-Equal -Actual $guiXml.Configuration.VGpu -Expected 'Disable' -Name 'Sandbox disables vGPU'
    Assert-Equal -Actual $guiXml.Configuration.Networking -Expected 'Enable' -Name 'Sandbox explicitly enables only the network needed for installation'
    Assert-Equal -Actual $guiXml.Configuration.AudioInput -Expected 'Disable' -Name 'Sandbox disables microphone redirection'
    Assert-Equal -Actual $guiXml.Configuration.VideoInput -Expected 'Disable' -Name 'Sandbox disables camera redirection'
    Assert-Equal -Actual $guiXml.Configuration.PrinterRedirection -Expected 'Disable' -Name 'Sandbox disables printer redirection'
    Assert-Equal -Actual $guiXml.Configuration.ClipboardRedirection -Expected 'Disable' -Name 'Sandbox disables clipboard redirection by default'
    Assert-Equal -Actual $guiXml.Configuration.ProtectedClient -Expected 'Enable' -Name 'Sandbox enables protected client mode'

    $guiMappings = @($guiXml.Configuration.MappedFolders.MappedFolder)
    Assert-Equal -Actual $guiMappings.Count -Expected 2 -Name 'Sandbox exposes only source and dedicated results mappings'
    $sourceMapping = @($guiMappings | Where-Object SandboxFolder -eq 'C:\OCES-Source')
    $resultMapping = @($guiMappings | Where-Object SandboxFolder -eq 'C:\OCES-Results')
    Assert-True -Condition ($sourceMapping.Count -eq 1 -and [string]$sourceMapping[0].ReadOnly -eq 'true') -Name 'Repository source mapping is read-only'
    Assert-True -Condition ($resultMapping.Count -eq 1 -and [string]$resultMapping[0].ReadOnly -eq 'false') -Name 'Only the dedicated results mapping is writable'
    Assert-Equal -Actual ([IO.Path]::GetFullPath([string]$sourceMapping[0].HostFolder)) -Expected ([IO.Path]::GetFullPath($guiGeneration.SourceStagingDirectory)) -Name 'Read-only mapping targets the allowlisted source staging directory only'
    Assert-Equal -Actual ([IO.Path]::GetFullPath([string]$resultMapping[0].HostFolder)) -Expected ([IO.Path]::GetFullPath($guiGeneration.ResultsDirectory)) -Name 'Writable mapping targets the new result directory only'
    Assert-True -Condition ([string]$guiXml.Configuration.LogonCommand.Command -match 'Invoke-InWindowsSandbox\.ps1 -Mode Gui -RunId [A-Fa-f0-9]{32}$') -Name 'GUI configuration starts the fixed in-sandbox entry point with a bound run ID'
    Assert-True -Condition ([string]$guiXml.Configuration.LogonCommand.Command -match ([regex]::Escape([string]$guiGeneration.RunId) + '$')) -Name 'Generated result receipt is bound to the host run ID'
    Assert-True -Condition (-not ([string]$guiXml.Configuration.LogonCommand.Command).Contains($projectRoot)) -Name 'Sandbox command never embeds or executes a host path'

    $stagedRelativePaths = @(Get-ChildItem -LiteralPath $guiGeneration.SourceStagingDirectory -File -Recurse | ForEach-Object {
        $_.FullName.Substring(([string]$guiGeneration.SourceStagingDirectory).TrimEnd('\').Length + 1)
    })
    Assert-Equal -Actual $stagedRelativePaths.Count -Expected 16 -Name 'Source staging contains only the explicit runtime allowlist'
    Assert-True -Condition ($stagedRelativePaths -contains 'tests\e2e\Invoke-InWindowsSandbox.ps1') -Name 'Source staging includes the fixed Sandbox entry point'
    Assert-True -Condition ($stagedRelativePaths -contains 'tests\e2e\Invoke-InstallSmokeWorker.ps1') -Name 'Source staging includes the shared Boolean-bound install worker'
    Assert-True -Condition ($stagedRelativePaths -notcontains '.git' -and $stagedRelativePaths -notcontains '.gitleaks.toml' -and $stagedRelativePaths -notcontains 'README.md') -Name 'Source staging excludes repository metadata and unrelated files'

    $smokeGeneration = & $launcherPath -Mode InstallSmoke -EnableClipboard -MemoryInMB 8192 -GenerateOnly
    $generatedRuns.Add($smokeGeneration)
    [xml]$smokeXml = Get-Content -LiteralPath $smokeGeneration.ConfigurationPath -Raw -Encoding UTF8
    Assert-Equal -Actual $smokeXml.Configuration.ClipboardRedirection -Expected 'Enable' -Name 'Clipboard sharing requires an explicit opt-in switch'
    Assert-Equal -Actual ([int]$smokeXml.Configuration.MemoryInMB) -Expected 8192 -Name 'Requested Sandbox memory is written to the configuration'
    Assert-True -Condition ([string]$smokeXml.Configuration.LogonCommand.Command -match 'Invoke-InWindowsSandbox\.ps1 -Mode InstallSmoke -RunId [A-Fa-f0-9]{32}$') -Name 'Install smoke configuration selects the noninteractive mode'
    Assert-True -Condition ($smokeGeneration.NetworkingEnabled -and $smokeGeneration.ResultsMappingIsDedicated) -Name 'Install smoke reports required network and dedicated output boundaries'

    $launcherSource = [IO.File]::ReadAllText($launcherPath, [Text.Encoding]::UTF8)
    Assert-True -Condition ($launcherSource.Contains('$stagedFiles = @(') -and $launcherSource.Contains('Get-FileHash -LiteralPath $destinationPath')) -Name 'Host launcher stages an explicit integrity-checked file allowlist'
    Assert-True -Condition ($launcherSource.Contains('[IO.FileMode]::CreateNew') -and $launcherSource.Contains('Start-Process -FilePath $sandboxExecutable')) -Name 'Host launcher creates configuration atomically and invokes the trusted Sandbox executable directly'

    $entrySource = [IO.File]::ReadAllText($sandboxEntryPoint, [Text.Encoding]::UTF8)
    $workerSource = [IO.File]::ReadAllText($workerPath, [Text.Encoding]::UTF8)
    Assert-True -Condition ($entrySource.Contains('$accountName -ne ''WDAGUtilityAccount''')) -Name 'In-sandbox entry point refuses execution as the host user'
    Assert-True -Condition ($entrySource.Contains('E2E-SOURCE-MAPPING-WRITABLE') -and $entrySource.Contains('$result.sourceMappedReadOnly = $true')) -Name 'In-sandbox entry point verifies the source mapping is actually read-only'
    Assert-True -Condition ($entrySource.Contains("Get-Command openclaw -All") -and $entrySource.Contains('E2E-ENVIRONMENT-NOT-CLEAN')) -Name 'Actual install smoke requires a clean OpenClaw environment'
    Assert-True -Condition ($workerSource.Contains('-SkipOnboarding') -and $workerSource.Contains('-Confirm:$false')) -Name 'Automated install smoke skips token entry and binds confirmation as Boolean false'
    Assert-True -Condition (-not $entrySource.Contains("'-Confirm:$false'")) -Name 'Sandbox native argument list never passes Boolean confirmation as text'
    $checkpointSelector = 'Where-Object { $_.BaseName -match ''^[A-Fa-f0-9]{32}$'' }'
    Assert-True -Condition ($entrySource.Contains($checkpointSelector)) -Name 'Result collection selects only installation checkpoint files'
    Assert-True -Condition ($entrySource.Contains('Read-OpenClawCheckpoint') -and $entrySource.Contains('E2E-CHECKPOINT-INVALID')) -Name 'Result collection validates checkpoint schema and fixed stages before export'
    Assert-True -Condition ($entrySource.Contains('id = [string]$_.Id') -and $entrySource.Contains('status = [string]$_.Status')) -Name 'Persistent result exports stage IDs and statuses without raw details'
    Assert-True -Condition ($entrySource.Contains('Resolve-OpenClawInvocation') -and $entrySource.Contains('Assert-OpenClawSlackPluginProvenance')) -Name 'Install success independently validates package receipt and Slack plugin provenance'
    Assert-True -Condition ($entrySource.Contains('$result.guiExitedCleanly') -and $entrySource.Contains('$result.provenanceReceiptValidated') -and $entrySource.Contains('$result.slackPluginVerified')) -Name 'GUI exit and full installation success use separate result fields'
    Assert-True -Condition ($entrySource.Contains('E2E-RESULT-PERSISTENCE-FAILED') -and $entrySource.Contains('-not $resultWritten')) -Name 'A missing or spoofed result receipt makes the E2E process fail closed'
    Assert-True -Condition (-not $entrySource.Contains('standardOutputPath = Join-Path $resultsRoot')) -Name 'Raw child output remains inside the disposable Sandbox'
}
finally {
    $expectedRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'OpenClawEasySetup-E2E')).TrimEnd('\') + '\'
    foreach ($generatedRun in $generatedRuns) {
        foreach ($directoryProperty in @('SourceStagingDirectory', 'ResultsDirectory')) {
            $directoryPath = [IO.Path]::GetFullPath([string]$generatedRun.$directoryProperty)
            if ($directoryPath.StartsWith($expectedRoot, [StringComparison]::OrdinalIgnoreCase) -and
                [IO.Path]::GetFileName($directoryPath) -match '^(source|results)-[A-Fa-f0-9]{32}$' -and
                (Test-Path -LiteralPath $directoryPath -PathType Container)) {
                Remove-Item -LiteralPath $directoryPath -Recurse -Force
            }
        }
        $configurationPath = [IO.Path]::GetFullPath([string]$generatedRun.ConfigurationPath)
        if ($configurationPath.StartsWith($expectedRoot, [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($configurationPath) -match '^OpenClawEasySetup-[A-Fa-f0-9]{32}\.wsb$' -and
            (Test-Path -LiteralPath $configurationPath -PathType Leaf)) {
            Remove-Item -LiteralPath $configurationPath -Force
        }
    }
}

Write-Host ''
Write-Host ("Sandbox harness tests: {0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) {
    exit 1
}
