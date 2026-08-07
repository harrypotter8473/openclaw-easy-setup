[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$workflowPath = Join-Path $projectRoot '.github\workflows\windows-install-e2e.yml'
$controllerPath = Join-Path $projectRoot 'tests\e2e\Invoke-OnGitHubHostedRunner.ps1'
$workerPath = Join-Path $projectRoot 'tests\e2e\Invoke-InstallSmokeWorker.ps1'
$modulePath = Join-Path $projectRoot 'src\OpenClawEasySetup.psm1'
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

function Assert-Parses {
    param([string]$Path, [string]$Name)
    $tokens = $null
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    Assert-True -Condition (@($parseErrors).Count -eq 0) -Name $Name
}

function Get-OpenClawE2EFunctionSource {
    param(
        [Parameter(Mandatory = $true)]
        [Management.Automation.Language.Ast]$Ast,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $matches = @($Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst]
    }, $true) | Where-Object {
        [string]::Equals($_.Name, $Name, [StringComparison]::Ordinal)
    })
    if ($matches.Count -ne 1) {
        throw "Expected exactly one controller function named $Name."
    }
    return $matches[0].Extent.Text
}
function Get-OpenClawE2ESummaryScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkflowText
    )

    $stepMarker = '      - name: Publish sanitized job summary'
    $runMarker = '        run: |'
    $stepIndex = $WorkflowText.IndexOf($stepMarker, [StringComparison]::Ordinal)
    $runIndex = if ($stepIndex -ge 0) {
        $WorkflowText.IndexOf($runMarker, $stepIndex, [StringComparison]::Ordinal)
    }
    else {
        -1
    }
    if ($runIndex -lt 0) {
        throw 'Summary script block was not found.'
    }

    $block = $WorkflowText.Substring($runIndex + $runMarker.Length)
    $sourceLines = New-Object Collections.Generic.List[string]
    foreach ($line in @($block -split '\r?\n')) {
        if ($line.StartsWith('          ', [StringComparison]::Ordinal)) {
            $sourceLines.Add($line.Substring(10))
        }
        elseif ($line.Length -eq 0) {
            $sourceLines.Add('')
        }
        else {
            break
        }
    }
    return $sourceLines -join [Environment]::NewLine
}

function Invoke-OpenClawE2ESummaryCase {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$SummaryScript,

        [AllowNull()]
        [object]$Receipt,

        [Parameter(Mandatory = $true)]
        [string]$ControllerOutcome,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedCommit
    )

    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $caseRoot = [IO.Path]::GetFullPath((Join-Path $tempBase ('OpenClawE2ESummaryTest-' + [Guid]::NewGuid().ToString('N'))))
    $tempPrefix = $tempBase.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $caseRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Unexpected test temp path.'
    }

    [void][IO.Directory]::CreateDirectory($caseRoot)
    $receiptPath = Join-Path $caseRoot 'result.json'
    $summaryPath = Join-Path $caseRoot 'summary.md'
    $environmentNames = @('OCES_E2E_RESULT', 'OCES_E2E_EXPECTED_SHA', 'OCES_E2E_OUTCOME', 'GITHUB_STEP_SUMMARY')
    $previousEnvironment = @{}
    foreach ($name in $environmentNames) {
        $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
    }

    try {
        if ($null -ne $Receipt) {
            $json = $Receipt | ConvertTo-Json -Depth 8
            [IO.File]::WriteAllText($receiptPath, $json, (New-Object Text.UTF8Encoding($false)))
        }
        $env:OCES_E2E_RESULT = $receiptPath
        $env:OCES_E2E_EXPECTED_SHA = $ExpectedCommit
        $env:OCES_E2E_OUTCOME = $ControllerOutcome
        $env:GITHUB_STEP_SUMMARY = $summaryPath

        $threw = $false
        try {
            & $SummaryScript
        }
        catch {
            $threw = $true
        }
        $summary = if (Test-Path -LiteralPath $summaryPath -PathType Leaf) {
            Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8
        }
        else {
            ''
        }
        return [pscustomobject]@{
            Threw = $threw
            Summary = $summary
        }
    }
    finally {
        foreach ($name in $environmentNames) {
            [Environment]::SetEnvironmentVariable(
                $name,
                $previousEnvironment[$name],
                [EnvironmentVariableTarget]::Process
            )
        }
        if ([IO.Directory]::Exists($caseRoot) -and
            $caseRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            [IO.Directory]::Delete($caseRoot, $true)
        }
    }
}

Assert-Parses -Path $controllerPath -Name 'GitHub-hosted runner controller parses as PowerShell'
Assert-Parses -Path $workerPath -Name 'Install-smoke worker parses as PowerShell'

$workflow = Get-Content -LiteralPath $workflowPath -Raw -Encoding UTF8
$controller = Get-Content -LiteralPath $controllerPath -Raw -Encoding UTF8
$worker = Get-Content -LiteralPath $workerPath -Raw -Encoding UTF8
$module = Get-Content -LiteralPath $modulePath -Raw -Encoding UTF8
$controllerTokens = $null
$controllerParseErrors = $null
$controllerAst = [Management.Automation.Language.Parser]::ParseFile(
    $controllerPath,
    [ref]$controllerTokens,
    [ref]$controllerParseErrors
)
Assert-True -Condition (@($controllerParseErrors).Count -eq 0) -Name 'Controller AST is available for isolated resolver tests'
Assert-True -Condition ($workflow -match '(?m)^\s{2}workflow_dispatch:\s*$') -Name 'Install E2E is manually dispatched'
Assert-True -Condition ($workflow -notmatch '(?m)^\s{2}(push|pull_request|schedule):') -Name 'Install E2E never runs automatically on repository events'
Assert-True -Condition ($workflow -match '(?ms)^permissions:\s*\r?\n\s{2}contents:\s*read\s*$') -Name 'Workflow has read-only repository permissions'
Assert-True -Condition ($workflow.Contains("runs-on: windows-latest") -and $workflow.Contains('timeout-minutes: 30')) -Name 'Workflow uses a bounded hosted Windows job'
Assert-True -Condition ($workflow.Contains('persist-credentials: false') -and $workflow.Contains('fetch-depth: 1')) -Name 'Checkout leaves no repository credential behind'
Assert-True -Condition ($workflow -notmatch '(?i)(secrets\.|vars\.|environment:|upload-artifact)') -Name 'Workflow references no secrets, environment, variables, or uploaded artifacts'
Assert-True -Condition ($workflow.Contains('if: github.ref_name != github.event.repository.default_branch') -and $workflow.Contains("throw 'E2E-DEFAULT-BRANCH-REQUIRED'") -and $workflow.Contains('ref: ${{ github.sha }}')) -Name 'A non-default branch fails before checkout instead of reporting a skipped success'
Assert-True -Condition ($workflow.Contains('OCES_E2E_EXPECTED_SHA: ${{ github.sha }}') -and $workflow.Contains('"- Tested commit: $testedCommit"')) -Name 'Summary validates and prints the exact tested commit'
Assert-True -Condition ($workflow.Contains('${{ runner.temp }}\OpenClawEasySetup-GitHubE2E\result.json')) -Name 'Sanitized receipt stays under runner temp'
Assert-True -Condition (([regex]::Matches($workflow, 'OCES_E2E_RESULT: \$\{\{ runner\.temp \}\}\\OpenClawEasySetup-GitHubE2E\\result\.json')).Count -eq 2 -and $workflow -notmatch '(?m)^      OCES_E2E_RESULT:') -Name 'Runner context is referenced only from step-level environments'
Assert-True -Condition ($workflow.Contains('${{ steps.install_e2e.outcome }}') -and $workflow.Contains('E2E-RESULT-INVALID')) -Name 'Summary cannot report PASS when the controller failed or the receipt is invalid'
Assert-True -Condition ($workflow.Contains('[IO.FileAttributes]::ReparsePoint') -and $workflow.Contains('^(OCES|E2E)-[A-Z0-9-]{1,64}$')) -Name 'Summary validates receipt type and fixed output formats before rendering'
Assert-True -Condition ($workflow.Contains("throw 'E2E-SUMMARY-FAIL-CLOSED'") -and $workflow.Contains('$stages.Count -eq $expectedStageIds.Count')) -Name 'Missing or incomplete evidence makes the summary step fail closed'
Assert-True -Condition ($workflow.Contains('$installedVersion -eq $targetVersion') -and $workflow.Contains('$result.installationSucceeded -eq $true') -and $workflow.Contains('$candidateErrorCode -eq ''''')) -Name 'PASS requires exact versions and every independent postcondition'

Assert-True -Condition ($controller.Contains('$env:RUNNER_ENVIRONMENT -ne ''github-hosted''') -and $controller.Contains('$env:GITHUB_EVENT_NAME -ne ''workflow_dispatch''')) -Name 'Controller refuses local and non-manual execution'
Assert-True -Condition ($controller.Contains('E2E-COMMIT-INVALID') -and $controller.Contains('$result.testedCommit = $testedCommit')) -Name 'Controller attests the selected default-branch commit'
Assert-True -Condition ($controller.Contains('E2E-RUNNER-PATH-INVALID') -and $controller.Contains('Test-OpenClawE2EPathContainedBy')) -Name 'Controller confines mutable state to runner temp outside the checkout'
Assert-True -Condition ($controller.Contains('Set-OpenClawE2EMinimalEnvironment') -and -not $controller.Contains('ACTIONS_RUNTIME_TOKEN')) -Name 'Controller rebuilds rather than selectively deleting the worker environment'
Assert-True -Condition ($controller.Contains('(TOKEN|SECRET|PASSWORD|CREDENTIAL|API[_-]?KEY|AUTH)') -and $controller.Contains('$result.credentialsScrubbed = $true')) -Name 'Controller fails closed if a credential-like environment name survives'
Assert-True -Condition ($controller.Contains('$stagedFiles = @(') -and $controller.Contains('''tests\e2e\Invoke-InstallSmokeWorker.ps1''')) -Name 'Controller stages an explicit minimal source allowlist'
Assert-True -Condition (([regex]::Matches($controller, 'Assert-OpenClawE2EStagedSource -SourceRoot')).Count -eq 2 -and $controller.Contains('E2E-SOURCE-MUTATED')) -Name 'Staged source hashes are checked before and after installation'
Assert-True -Condition ($controller.Contains('$safePathCandidates') -and $controller.Contains('(Join-Path $env:ProgramFiles ''nodejs'')') -and $controller.Contains('Assert-OpenClawE2EExpandedPath') -and $controller.Contains('E2E-PATH-EXPANSION-INVALID')) -Name 'Worker and post-install verification reject GitHub toolcache paths'
Assert-True -Condition ($controller.Contains('NPM_CONFIG_USERCONFIG') -and $controller.Contains('GIT_CONFIG_NOSYSTEM')) -Name 'Worker uses empty npm and Git user configuration'
Assert-True -Condition ($controller.Contains('-RedirectStandardOutput $standardOutputPath') -and $controller.Contains('Get-OpenClawE2ESafeErrorCode')) -Name 'Raw installer output remains private and only stable codes are extracted'
Assert-True -Condition ($controller.Contains('Read-OpenClawCheckpoint') -and $controller.Contains('Resolve-OpenClawInvocation')) -Name 'Controller independently validates checkpoint and package receipt'
Assert-True -Condition ($controller.Contains('Get-OpenClawSlackPluginInspection') -and $module.Contains('@(''plugins'', ''inspect'', $pluginId, ''--json'')') -and $module.Contains('@(''plugins'', ''inspect'', $pluginId, ''--runtime'', ''--json'')')) -Name 'Slack provenance is checked before runtime loading'
Assert-True -Condition ($module.Contains('''Get-OpenClawSlackPluginInspection''')) -Name 'The ordered Slack inspection contract is exported for E2E verification'
Assert-True -Condition ($controller.Contains('E2E-RESULT-PERSISTENCE-FAILED') -and $controller.Contains('-not $resultWritten')) -Name 'Missing result persistence fails the E2E run closed'
Assert-True -Condition ($controller.Contains('if ($result.installerExitCode -eq 0)') -and $controller.Contains('$checkpointEvidence = $null')) -Name 'Installer failures preserve their safe code when checkpoint evidence is unavailable'
Assert-True -Condition ($controller.Contains("throw 'E2E-CHECKPOINT-INVALID'") -and $controller.Contains('Stages = $safeStages.ToArray()') -and -not $controller.Contains('Stages = @($safeStages)')) -Name 'Checkpoint reads fail safely and PowerShell 5.1 materializes stage evidence explicitly'
Assert-True -Condition ($controller.Contains('Get-OpenClawE2ECheckpointMismatchCode -Checkpoint $checkpoint') -and
    $controller.Contains('-CandidateCode ([string]$checkpointEvidence.FailureCode)') -and
    $controller.Contains('E2E-CHECKPOINT-TOP-LEVEL-STATUS-MISMATCH')) -Name 'Checkpoint mismatches are reduced to fixed safe diagnostic codes'
Assert-True -Condition ($controller.Contains('Get-OpenClawE2EInstallFailureCode') -and
    $controller.Contains('Select-OpenClawE2ECheckpointErrorCode') -and
    $controller.Contains('$safeInstallFailureCodes') -and
    $controller.Contains('E2E-INSTALL-SLACK-PLUGIN-FAILED')) -Name 'Validated install details can refine only allowlisted checkpoint diagnostics'
$installProducerPatterns = @(
    '-StepId ''install'' -Status ''Failed'' -Detail ''Installer invocation failure.''',
    '-StepId ''install'' -Status ''Failed'' -Detail ''Postcondition failure.''',
    '-StepId ''install'' -Status ''Failed'' -Detail ''Provenance receipt failure.''',
    '$installFailureDetail = ''''',
    '-FailureDetail ([ref]$installFailureDetail)',
    '$diagnosticStage = ''''',
    '-DiagnosticStage ([ref]$diagnosticStage)',
    '$FailureDetail.Value = Resolve-OpenClawPinnedInstallerFailureDetail',
    'Get-OpenClawPinnedInstallerCheckpointDetail -ExitCode $installExitCode -FailureDetail $installFailureDetail',
    '-StepId ''install'' -Status ''Failed'' -Detail $installCheckpointDetail'
)
$installProducerMatchCounts = @($installProducerPatterns | ForEach-Object {
    ([regex]::Matches($module, [regex]::Escape($_))).Count
})
$slackProducerPattern = '-StepId ''install'' -Status ''Failed'' -Detail ''Slack plugin provenance or installation failure.'''
Assert-True -Condition (($installProducerMatchCounts -join ',') -eq '1,1,1,1,1,1,1,1,1,1' -and
    ([regex]::Matches($module, [regex]::Escape($slackProducerPattern))).Count -eq 2) -Name 'Install checkpoint producers retain the exact classifier detail contract'
Assert-True -Condition ($controller.Contains('Get-OpenClawE2EPostconditionErrorCode -Result $result') -and
    $controller.Contains('E2E-POSTCONDITION-INSTALLATION-FAILED') -and
    $controller.Contains('E2E-POSTCONDITION-PROVENANCE-FAILED') -and
    $controller.Contains('E2E-SLACK-VERIFICATION-FAILED')) -Name 'Final postcondition failures use fixed diagnostic codes'
Assert-True -Condition ($controller.Contains('Write-Host ("Installer exit code: {0}" -f $result.installerExitCode)')) -Name 'Controller prints only the safe numeric installer exit code'
Assert-True -Condition (([regex]::Matches($controller, '\$result\.stages\s*=')).Count -eq 1 -and
    $controller.Contains('Write-Host ("Checkpoint stage {0}: {1}" -f ([string]$stage.id), ([string]$stage.status))')) -Name 'Controller prints only checkpoint stages copied from validated evidence'
Assert-True -Condition ($controller -notmatch 'ScriptStackTrace|PositionMessage|InvocationInfo|Write-Host\s+\$_') -Name 'Controller never emits raw exception diagnostics'
$moduleTokens = $null
$moduleParseErrors = $null
$moduleAst = [Management.Automation.Language.Parser]::ParseFile(
    $modulePath,
    [ref]$moduleTokens,
    [ref]$moduleParseErrors
)
Assert-True -Condition (@($moduleParseErrors).Count -eq 0) -Name 'Module AST is available for isolated PATH refresh tests'
Assert-True -Condition ($module.Contains('$approvedRefreshCandidates') -and
    -not $module.Contains("GetEnvironmentVariable('Path', 'Machine')") -and
    -not $module.Contains("GetEnvironmentVariable('Path', 'User')")) -Name 'PATH refresh never reimports unrestricted persistent PATH values'

$pathUpdateSource = Get-OpenClawE2EFunctionSource -Ast $moduleAst -Name 'Update-OpenClawProcessPath'
$pathContainedSource = Get-OpenClawE2EFunctionSource -Ast $controllerAst -Name 'Test-OpenClawE2EPathContainedBy'
$pathAssertSource = Get-OpenClawE2EFunctionSource -Ast $controllerAst -Name 'Assert-OpenClawE2EExpandedPath'
$pathCaseSource = @(
    'param([string]$CaseRoot)',
    $pathUpdateSource,
    $pathContainedSource,
    $pathAssertSource,
    '$environmentNames = @(''Path'', ''ProgramFiles'', ''ProgramFiles(x86)'', ''LOCALAPPDATA'', ''APPDATA'')',
    '$savedEnvironment = @{}',
    'foreach ($name in $environmentNames) {',
    '    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)',
    '}',
    '$safePaths = @()',
    '$expectedPaths = @()',
    '$safeCode = ''''',
    '$toolcacheCode = ''''',
    '$blockedCode = ''''',
    'try {',
    '    $safeCurrentPath = Join-Path $CaseRoot ''safe-current''',
    '    $programFiles = Join-Path $CaseRoot ''ProgramFiles''',
    '    $programFilesX86 = Join-Path $CaseRoot ''ProgramFilesX86''',
    '    $localAppData = Join-Path $CaseRoot ''LocalAppData''',
    '    $appData = Join-Path $CaseRoot ''AppData''',
    '    $workspaceRoot = Join-Path $CaseRoot ''workspace''',
    '    $runnerTemp = Join-Path $CaseRoot ''runner-temp''',
    '    $runnerToolCache = Join-Path $CaseRoot ''runner-toolcache''',
    '    $expectedPaths = @(',
    '        $safeCurrentPath,',
    '        (Join-Path $programFiles ''Git\cmd''),',
    '        (Join-Path $programFilesX86 ''Git\cmd''),',
    '        (Join-Path $localAppData ''Programs\Git\cmd''),',
    '        (Join-Path $programFiles ''nodejs''),',
    '        (Join-Path $programFilesX86 ''nodejs''),',
    '        (Join-Path $localAppData ''Programs\nodejs''),',
    '        (Join-Path $appData ''npm'')',
    '    )',
    '    foreach ($directoryPath in @($expectedPaths + @($workspaceRoot, $runnerTemp, $runnerToolCache))) {',
    '        [void][IO.Directory]::CreateDirectory($directoryPath)',
    '    }',
    '    [Environment]::SetEnvironmentVariable(''Path'', $safeCurrentPath, [EnvironmentVariableTarget]::Process)',
    '    [Environment]::SetEnvironmentVariable(''ProgramFiles'', $programFiles, [EnvironmentVariableTarget]::Process)',
    '    [Environment]::SetEnvironmentVariable(''ProgramFiles(x86)'', $programFilesX86, [EnvironmentVariableTarget]::Process)',
    '    [Environment]::SetEnvironmentVariable(''LOCALAPPDATA'', $localAppData, [EnvironmentVariableTarget]::Process)',
    '    [Environment]::SetEnvironmentVariable(''APPDATA'', $appData, [EnvironmentVariableTarget]::Process)',
    '    Update-OpenClawProcessPath',
    '    $safePaths = @(([string]$env:Path).Split('';'') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })',
    '    try {',
    '        Assert-OpenClawE2EExpandedPath -BlockedRoots @($workspaceRoot, $runnerTemp, $runnerToolCache)',
    '    }',
    '    catch {',
    '        $safeCode = [string]$_.Exception.Message',
    '    }',
    '    $env:Path = ''C:\hostedtoolcache\windows\Python\3.12.0\x64''',
    '    try {',
    '        Assert-OpenClawE2EExpandedPath -BlockedRoots @($workspaceRoot, $runnerTemp, $runnerToolCache)',
    '    }',
    '    catch {',
    '        $toolcacheCode = [string]$_.Exception.Message',
    '    }',
    '    $env:Path = Join-Path $workspaceRoot ''child''',
    '    try {',
    '        Assert-OpenClawE2EExpandedPath -BlockedRoots @($workspaceRoot, $runnerTemp, $runnerToolCache)',
    '    }',
    '    catch {',
    '        $blockedCode = [string]$_.Exception.Message',
    '    }',
    '}',
    'finally {',
    '    foreach ($name in $environmentNames) {',
    '        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], [EnvironmentVariableTarget]::Process)',
    '    }',
    '}',
    '[pscustomobject]@{',
    '    ExpectedPaths = @($expectedPaths)',
    '    SafePaths = @($safePaths)',
    '    SafeCode = $safeCode',
    '    ToolcacheCode = $toolcacheCode',
    '    BlockedCode = $blockedCode',
    '}'
) -join [Environment]::NewLine
$pathCaseRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('OpenClawE2EPathTest-' + [guid]::NewGuid().ToString('N'))))
$pathTempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$pathEvidence = $null
$pathEvidenceException = $null
try {
    [void][IO.Directory]::CreateDirectory($pathCaseRoot)
    try {
        $pathEvidence = & ([scriptblock]::Create($pathCaseSource)) $pathCaseRoot
    }
    catch {
        $pathEvidenceException = $_.Exception
    }
}
finally {
    if ([IO.Directory]::Exists($pathCaseRoot) -and $pathCaseRoot.StartsWith($pathTempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        [IO.Directory]::Delete($pathCaseRoot, $true)
    }
}
$pathEvidenceValid = $null -eq $pathEvidenceException -and $null -ne $pathEvidence
Assert-True -Condition ($pathEvidenceValid -and
    [string]::IsNullOrWhiteSpace([string]$pathEvidence.SafeCode) -and
    [string]::Equals((@($pathEvidence.ExpectedPaths) -join ';'), (@($pathEvidence.SafePaths) -join ';'), [StringComparison]::OrdinalIgnoreCase)) -Name 'Production PATH refresh remains inside the E2E allowlist on PowerShell 5.1'
Assert-True -Condition ($pathEvidenceValid -and $pathEvidence.ToolcacheCode -eq 'E2E-PATH-EXPANSION-INVALID') -Name 'Expanded PATH guard still rejects hosted toolcache paths'
Assert-True -Condition ($pathEvidenceValid -and $pathEvidence.BlockedCode -eq 'E2E-PATH-EXPANSION-INVALID') -Name 'Expanded PATH guard still rejects paths inside mutable runner roots'


$safeErrorSource = Get-OpenClawE2EFunctionSource -Ast $controllerAst -Name 'Get-OpenClawE2ESafeErrorCode'
$safeErrorCaseSource = @(
    'param([string]$CaseRoot)',
    $safeErrorSource,
    '$encoding = New-Object Text.UTF8Encoding($false)',
    '$legacyEncoding = [Text.Encoding]::GetEncoding(949)',
    '$errorCodeLabel = ([string][char]0xC624) + ([char]0xB958) + '' '' + ([char]0xCF54) + ([char]0xB4DC)',
    '$exactPath = Join-Path $CaseRoot ''exact.txt''',
    '$otherPath = Join-Path $CaseRoot ''other.txt''',
    '$duplicatePath = Join-Path $CaseRoot ''duplicate.txt''',
    '$embeddedPath = Join-Path $CaseRoot ''embedded.txt''',
    '$unknownPath = Join-Path $CaseRoot ''unknown.txt''',
    '$legacyPath = Join-Path $CaseRoot ''legacy.txt''',
    '[IO.File]::WriteAllText($exactPath, (''noise'' + [Environment]::NewLine + $errorCodeLabel + '': OCES-INSTALL-001'' + [Environment]::NewLine), $encoding)',
    '[IO.File]::WriteAllText($otherPath, ($errorCodeLabel + '': OCES-INTEGRITY-001'' + [Environment]::NewLine), $encoding)',
    '[IO.File]::WriteAllText($duplicatePath, ($errorCodeLabel + '': OCES-INSTALL-001'' + [Environment]::NewLine), $encoding)',
    '[IO.File]::WriteAllText($embeddedPath, (''npm says '' + $errorCodeLabel + '': OCES-DOWNLOAD-001 trailing'' + [Environment]::NewLine + ''OCES-PREREQ-001''), $encoding)',
    '[IO.File]::WriteAllText($unknownPath, ($errorCodeLabel + '': OCES-FAKE-999'' + [Environment]::NewLine), $encoding)',
    '[IO.File]::WriteAllText($legacyPath, ($errorCodeLabel + '': OCES-INSTALL-001'' + [Environment]::NewLine), $legacyEncoding)',
    '[pscustomobject]@{',
    '    Exact = Get-OpenClawE2ESafeErrorCode -Paths @($exactPath)',
    '    Duplicate = Get-OpenClawE2ESafeErrorCode -Paths @($exactPath, $duplicatePath)',
    '    Ambiguous = Get-OpenClawE2ESafeErrorCode -Paths @($exactPath, $otherPath)',
    '    Embedded = Get-OpenClawE2ESafeErrorCode -Paths @($embeddedPath)',
    '    Unknown = Get-OpenClawE2ESafeErrorCode -Paths @($unknownPath)',
    '    Legacy = Get-OpenClawE2ESafeErrorCode -Paths @($legacyPath)',
    '}'
) -join [Environment]::NewLine
$safeErrorCaseRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('OpenClawE2ESafeErrorTest-' + [guid]::NewGuid().ToString('N'))))
$safeErrorTempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$safeErrorEvidence = $null
try {
    [void][IO.Directory]::CreateDirectory($safeErrorCaseRoot)
    $safeErrorEvidence = & ([scriptblock]::Create($safeErrorCaseSource)) $safeErrorCaseRoot
}
finally {
    if ([IO.Directory]::Exists($safeErrorCaseRoot) -and $safeErrorCaseRoot.StartsWith($safeErrorTempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        [IO.Directory]::Delete($safeErrorCaseRoot, $true)
    }
}
Assert-True -Condition ($safeErrorEvidence.Exact -eq 'OCES-INSTALL-001' -and $safeErrorEvidence.Duplicate -eq 'OCES-INSTALL-001') -Name 'UTF-8 installer output yields a code only from duplicate-safe exact allowlisted lines'
Assert-True -Condition ([string]::IsNullOrWhiteSpace([string]$safeErrorEvidence.Ambiguous) -and
    [string]::IsNullOrWhiteSpace([string]$safeErrorEvidence.Embedded) -and
    [string]::IsNullOrWhiteSpace([string]$safeErrorEvidence.Unknown) -and
    [string]::IsNullOrWhiteSpace([string]$safeErrorEvidence.Legacy)) -Name 'Ambiguous, embedded, unknown, or legacy-encoded OCES output fails closed'
$unknownHarnessSource = Get-OpenClawE2EFunctionSource -Ast $controllerAst -Name 'Get-OpenClawE2EUnknownHarnessCode'
$resolveHarnessSource = Get-OpenClawE2EFunctionSource -Ast $controllerAst -Name 'Resolve-OpenClawE2EHarnessErrorCode'
$selectCheckpointSource = Get-OpenClawE2EFunctionSource -Ast $controllerAst -Name 'Select-OpenClawE2ECheckpointErrorCode'
$resolverCaseSource = @(
    '$safeCodes = @(''E2E-CHECKPOINT-INVALID'', ''E2E-CHECKPOINT-STAGE-INSTALL-STATUS-MISMATCH'', ''E2E-INSTALL-SLACK-PLUGIN-FAILED'')',
    '$specificInstallCodes = @(''E2E-INSTALL-SLACK-PLUGIN-FAILED'')',
    '$phases = @(''preflight'', ''paths'', ''source'', ''environment'', ''installer'', ''checkpoint'', ''provenance'', ''slack'', ''postconditions'')',
    '[pscustomobject]@{',
    '    PhaseCodes = @($phases | ForEach-Object { Get-OpenClawE2EUnknownHarnessCode -Phase $_ })',
    '    UnknownPhase = Get-OpenClawE2EUnknownHarnessCode -Phase ''CHECKPOINT''',
    '    MaliciousPhase = Get-OpenClawE2EUnknownHarnessCode -Phase (''checkpoint'' + [Environment]::NewLine + ''C:\Users\runneradmin\secret'')',
    '    ExactSafe = Resolve-OpenClawE2EHarnessErrorCode -CandidateCode ''E2E-CHECKPOINT-INVALID'' -Phase ''checkpoint'' -SafeCodes $safeCodes',
    '    WrongCase = Resolve-OpenClawE2EHarnessErrorCode -CandidateCode ''e2e-checkpoint-invalid'' -Phase ''checkpoint'' -SafeCodes $safeCodes',
    '    MaliciousCandidate = Resolve-OpenClawE2EHarnessErrorCode -CandidateCode (''E2E-CHECKPOINT-INVALID'' + [Environment]::NewLine + ''- injected'') -Phase ''checkpoint'' -SafeCodes $safeCodes',
    '    EmptyCurrentSpecific = Select-OpenClawE2ECheckpointErrorCode -CurrentCode '''' -CandidateCode ''E2E-INSTALL-SLACK-PLUGIN-FAILED'' -SafeCodes $safeCodes -SpecificInstallCodes $specificInstallCodes',
    '    BroadCurrentSpecific = Select-OpenClawE2ECheckpointErrorCode -CurrentCode ''OCES-INSTALL-001'' -CandidateCode ''E2E-INSTALL-SLACK-PLUGIN-FAILED'' -SafeCodes $safeCodes -SpecificInstallCodes $specificInstallCodes',
    '    BroadCurrentGeneric = Select-OpenClawE2ECheckpointErrorCode -CurrentCode ''OCES-INSTALL-001'' -CandidateCode ''E2E-CHECKPOINT-STAGE-INSTALL-STATUS-MISMATCH'' -SafeCodes $safeCodes -SpecificInstallCodes $specificInstallCodes',
    '    GenericCurrentSpecific = Select-OpenClawE2ECheckpointErrorCode -CurrentCode ''E2E-INSTALLER-FAILED'' -CandidateCode ''E2E-INSTALL-SLACK-PLUGIN-FAILED'' -SafeCodes $safeCodes -SpecificInstallCodes $specificInstallCodes',
    '    GenericCurrentGeneric = Select-OpenClawE2ECheckpointErrorCode -CurrentCode ''E2E-INSTALLER-FAILED'' -CandidateCode ''E2E-CHECKPOINT-STAGE-INSTALL-STATUS-MISMATCH'' -SafeCodes $safeCodes -SpecificInstallCodes $specificInstallCodes',
    '    GenericCurrentWrongCase = Select-OpenClawE2ECheckpointErrorCode -CurrentCode ''E2E-INSTALLER-FAILED'' -CandidateCode ''e2e-install-slack-plugin-failed'' -SafeCodes $safeCodes -SpecificInstallCodes $specificInstallCodes',
    '    GenericCurrentMalicious = Select-OpenClawE2ECheckpointErrorCode -CurrentCode ''E2E-INSTALLER-FAILED'' -CandidateCode (''E2E-INSTALL-SLACK-PLUGIN-FAILED'' + [Environment]::NewLine + ''token'') -SafeCodes $safeCodes -SpecificInstallCodes $specificInstallCodes',    '    OtherCurrentSpecific = Select-OpenClawE2ECheckpointErrorCode -CurrentCode ''OCES-INTEGRITY-001'' -CandidateCode ''E2E-INSTALL-SLACK-PLUGIN-FAILED'' -SafeCodes $safeCodes -SpecificInstallCodes $specificInstallCodes',
    '    WrongCaseSelection = Select-OpenClawE2ECheckpointErrorCode -CurrentCode ''OCES-INSTALL-001'' -CandidateCode ''e2e-install-slack-plugin-failed'' -SafeCodes $safeCodes -SpecificInstallCodes $specificInstallCodes',
    '    MaliciousSelection = Select-OpenClawE2ECheckpointErrorCode -CurrentCode ''OCES-INSTALL-001'' -CandidateCode (''E2E-INSTALL-SLACK-PLUGIN-FAILED'' + [Environment]::NewLine + ''token'') -SafeCodes $safeCodes -SpecificInstallCodes $specificInstallCodes',
    '}'
) -join [Environment]::NewLine
$resolverTestSource = $unknownHarnessSource + [Environment]::NewLine + $resolveHarnessSource + [Environment]::NewLine + $selectCheckpointSource + [Environment]::NewLine + $resolverCaseSource
$resolverEvidence = & ([scriptblock]::Create($resolverTestSource))
$expectedPhaseCodes = @(
    'E2E-HARNESS-PREFLIGHT-001',
    'E2E-HARNESS-PATHS-001',
    'E2E-HARNESS-SOURCE-001',
    'E2E-HARNESS-ENVIRONMENT-001',
    'E2E-HARNESS-INSTALLER-001',
    'E2E-HARNESS-CHECKPOINT-001',
    'E2E-HARNESS-PROVENANCE-001',
    'E2E-HARNESS-SLACK-001',
    'E2E-HARNESS-POSTCONDITIONS-001'
)
Assert-True -Condition (($resolverEvidence.PhaseCodes -join ',') -eq ($expectedPhaseCodes -join ',')) -Name 'Every internal harness phase maps to a fixed safe code'
Assert-True -Condition ($resolverEvidence.UnknownPhase -eq 'E2E-HARNESS-001' -and $resolverEvidence.MaliciousPhase -eq 'E2E-HARNESS-001') -Name 'Unknown or malformed harness phases become the generic code'
Assert-True -Condition ($resolverEvidence.ExactSafe -eq 'E2E-CHECKPOINT-INVALID' -and $resolverEvidence.WrongCase -eq 'E2E-HARNESS-CHECKPOINT-001' -and $resolverEvidence.MaliciousCandidate -eq 'E2E-HARNESS-CHECKPOINT-001') -Name 'Harness resolver preserves only exact allowlisted codes and never reflects exception text'
Assert-True -Condition ($resolverEvidence.EmptyCurrentSpecific -eq 'E2E-INSTALL-SLACK-PLUGIN-FAILED' -and
    $resolverEvidence.BroadCurrentSpecific -eq 'E2E-INSTALL-SLACK-PLUGIN-FAILED' -and
    $resolverEvidence.BroadCurrentGeneric -eq 'OCES-INSTALL-001' -and
    $resolverEvidence.GenericCurrentSpecific -eq 'E2E-INSTALL-SLACK-PLUGIN-FAILED' -and
    $resolverEvidence.GenericCurrentGeneric -eq 'E2E-INSTALLER-FAILED' -and
    $resolverEvidence.GenericCurrentWrongCase -eq 'E2E-INSTALLER-FAILED' -and
    $resolverEvidence.GenericCurrentMalicious -eq 'E2E-INSTALLER-FAILED' -and
    $resolverEvidence.OtherCurrentSpecific -eq 'OCES-INTEGRITY-001' -and
    $resolverEvidence.WrongCaseSelection -eq 'OCES-INSTALL-001' -and
    $resolverEvidence.MaliciousSelection -eq 'OCES-INSTALL-001') -Name 'Checkpoint selection refines only broad or generic installer failures with an exact allowlisted cause'
$postconditionSource = Get-OpenClawE2EFunctionSource -Ast $controllerAst -Name 'Get-OpenClawE2EPostconditionErrorCode'
$postconditionCaseSource = @(
    $postconditionSource,
    '$result = [ordered]@{',
    '    installationSucceeded = $true',
    '    provenanceReceiptValidated = $true',
    '    slackPluginVerified = $true',
    '    installedVersion = ''2026.7.1''',
    '    targetVersion = ''2026.7.1''',
    '}',
    '$result[''installationSucceeded''] = $false',
    '$installationCode = Get-OpenClawE2EPostconditionErrorCode -Result $result',
    '$result[''installationSucceeded''] = $true',
    '$result[''provenanceReceiptValidated''] = $false',
    '$result[''slackPluginVerified''] = $false',
    '$provenanceCode = Get-OpenClawE2EPostconditionErrorCode -Result $result',
    '$result[''provenanceReceiptValidated''] = $true',
    '$result[''slackPluginVerified''] = $true',
    '$result[''installedVersion''] = ''C:\Users\runneradmin\secret'' + [Environment]::NewLine + ''token''',
    '$versionCode = Get-OpenClawE2EPostconditionErrorCode -Result $result',
    '$result[''installedVersion''] = $result[''targetVersion'']',
    '$result[''slackPluginVerified''] = $false',
    '$slackCode = Get-OpenClawE2EPostconditionErrorCode -Result $result',
    '$result[''slackPluginVerified''] = $true',
    '$fallbackCode = Get-OpenClawE2EPostconditionErrorCode -Result $result',
    '[pscustomobject]@{',
    '    Codes = @($installationCode, $provenanceCode, $versionCode, $slackCode, $fallbackCode)',
    '}'
) -join [Environment]::NewLine
$postconditionEvidence = & ([scriptblock]::Create($postconditionCaseSource))
$expectedPostconditionCodes = @(
    'E2E-POSTCONDITION-INSTALLATION-FAILED',
    'E2E-POSTCONDITION-PROVENANCE-FAILED',
    'E2E-POSTCONDITION-PROVENANCE-FAILED',
    'E2E-SLACK-VERIFICATION-FAILED',
    'E2E-POSTCONDITION-FAILED'
)
Assert-True -Condition (($postconditionEvidence.Codes -join ',') -eq ($expectedPostconditionCodes -join ',')) -Name 'PowerShell 5.1 deterministically classifies causal hosted E2E postconditions'
$unsafePostconditionCodes = @($postconditionEvidence.Codes | Where-Object {
    [string]$_ -notmatch '^E2E-[A-Z0-9-]{1,64}$'
})
Assert-True -Condition ($unsafePostconditionCodes.Count -eq 0) -Name 'Postcondition classification never reflects paths, secrets, or raw values'

Assert-True -Condition ($worker.Contains('-SkipOnboarding') -and $worker.Contains('-Confirm:$false')) -Name 'Worker skips token entry and binds noninteractive confirmation as a Boolean'
Assert-True -Condition ($worker.Contains('& $entryPoint') -and -not $controller.Contains('-Confirm:$false')) -Name 'Worker evaluates confirmation inside PowerShell instead of a native argument string'
Assert-True -Condition ($worker.Contains('$global:LASTEXITCODE = 0') -and
    $worker.Contains('$entryPointSucceeded = $?') -and
    $worker.Contains('if (-not $entryPointSucceeded)') -and
    $worker.Contains('$entryPointExitCode = [int]$LASTEXITCODE') -and
    $worker.Contains('if ($entryPointExitCode -lt 1 -or $entryPointExitCode -gt 255)') -and
    $worker.Contains('exit $entryPointExitCode')) -Name 'Worker preserves only failed entry point exit codes and ignores stale native status after success'

$workerCaseRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('OpenClawE2EWorkerExitTest-' + [guid]::NewGuid().ToString('N'))))
$workerTempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$workerFailureExitCode = -1
$workerSuccessExitCode = -1
$workerInvalidExitCode = -1
try {
    $workerProjectRoot = Join-Path $workerCaseRoot 'project'
    $workerStateRoot = Join-Path $workerCaseRoot 'state'
    [void][IO.Directory]::CreateDirectory($workerProjectRoot)
    [void][IO.Directory]::CreateDirectory($workerStateRoot)
    $fakeEntryPoint = Join-Path $workerProjectRoot 'OpenClawEasySetup.ps1'
    $trustedPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    [IO.File]::WriteAllText($fakeEntryPoint, "exit 41`r`n", (New-Object Text.UTF8Encoding($false)))
    $failureProcess = Start-Process -FilePath $trustedPowerShell -ArgumentList @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $workerPath),
        '-ProjectRoot', ('"{0}"' -f $workerProjectRoot),
        '-StateDirectory', ('"{0}"' -f $workerStateRoot)
    ) -WorkingDirectory $workerProjectRoot -WindowStyle Hidden -Wait -PassThru
    $workerFailureExitCode = [int]$failureProcess.ExitCode

    [IO.File]::WriteAllText($fakeEntryPoint, "& `$env:ComSpec /d /c 'exit 17'`r`n`$null = Get-Date`r`nreturn`r`n", (New-Object Text.UTF8Encoding($false)))
    $successProcess = Start-Process -FilePath $trustedPowerShell -ArgumentList @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $workerPath),
        '-ProjectRoot', ('"{0}"' -f $workerProjectRoot),
        '-StateDirectory', ('"{0}"' -f $workerStateRoot)
    ) -WorkingDirectory $workerProjectRoot -WindowStyle Hidden -Wait -PassThru
    $workerSuccessExitCode = [int]$successProcess.ExitCode

    [IO.File]::WriteAllText($fakeEntryPoint, "exit 256`r`n", (New-Object Text.UTF8Encoding($false)))
    $invalidProcess = Start-Process -FilePath $trustedPowerShell -ArgumentList @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $workerPath),
        '-ProjectRoot', ('"{0}"' -f $workerProjectRoot),
        '-StateDirectory', ('"{0}"' -f $workerStateRoot)
    ) -WorkingDirectory $workerProjectRoot -WindowStyle Hidden -Wait -PassThru
    $workerInvalidExitCode = [int]$invalidProcess.ExitCode
}
finally {
    if ([IO.Directory]::Exists($workerCaseRoot) -and
        $workerCaseRoot.StartsWith($workerTempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        [IO.Directory]::Delete($workerCaseRoot, $true)
    }
}
Assert-True -Condition ($workerFailureExitCode -eq 41 -and $workerSuccessExitCode -eq 0 -and $workerInvalidExitCode -eq 1) -Name 'PowerShell 5.1 worker propagates valid failures, ignores stale success status, and bounds invalid exit codes'

$summarySource = Get-OpenClawE2ESummaryScript -WorkflowText $workflow
$summaryTokens = $null
$summaryParseErrors = $null
$null = [Management.Automation.Language.Parser]::ParseInput(
    $summarySource,
    [ref]$summaryTokens,
    [ref]$summaryParseErrors
)
Assert-True -Condition (@($summaryParseErrors).Count -eq 0) -Name 'Workflow summary block parses as PowerShell'
$summaryScript = [scriptblock]::Create($summarySource)

$testedCommit = ('a' * 40) -join ''
$expectedStageIds = @('diagnose', 'node', 'download', 'integrity', 'dryRun', 'install', 'onboard', 'verify')
$expectedStageStatuses = @('Succeeded', 'Succeeded', 'Succeeded', 'Succeeded', 'Succeeded', 'Succeeded', 'Skipped', 'Skipped')
$successfulStages = @(
    for ($index = 0; $index -lt $expectedStageIds.Count; $index++) {
        [pscustomobject]@{
            id = $expectedStageIds[$index]
            status = $expectedStageStatuses[$index]
        }
    }
)
$installFailureSource = Get-OpenClawE2EFunctionSource -Ast $controllerAst -Name 'Get-OpenClawE2EInstallFailureCode'
$installFailureCaseSource = @(
    $installFailureSource,
    '$knownDetails = @(',
    '    ''Installer invocation failure.'',',
    '    ''Exit code 1'',',
    '    ''Exit code 2'',',
    '    ''Postcondition failure.'',',
    '    ''Provenance receipt failure.'',',
    '    ''Slack plugin provenance or installation failure.'',',
    '    ''Npm permission failure.'',',
    '    ''Npm disk capacity failure.'',',
    '    ''Npm network failure.'',',
    '    ''Npm package target failure.'',',
    '    ''Npm engine incompatibility.'',',
    '    ''Npm integrity failure.'',',
    '    ''Npm lifecycle failure.'',',
    '    ''Npm filesystem failure.'',',
    '    ''Npm dependency resolution failure.'',',
    '    ''Npm registry authentication failure.'',',
    '    ''Npm TLS failure.'',',
    '    ''Npm protocol failure.'',',
    '    ''Npm diagnostics unavailable.'',',
    '    ''Npm diagnostic file rejected.'',',
    '    ''Npm install log missing or ambiguous.'',',
    '    ''Npm failure evidence unclassified.''',
    ')',
    '$unknownDetails = @('''', ''Exit code 3'', ''installer invocation failure.'', (''Exit code 1'' + [Environment]::NewLine + ''C:\Users\runneradmin\secret''), (''Slack plugin provenance or installation failure.'' + [Environment]::NewLine + ''token''), (''Npm network failure.'' + [Environment]::NewLine + ''npm_token=synthetic''), (''Npm diagnostics unavailable.'' + [Environment]::NewLine + ''token''))',
    '[pscustomobject]@{',
    '    KnownCodes = @($knownDetails | ForEach-Object { Get-OpenClawE2EInstallFailureCode -Detail $_ })',
    '    UnknownCodes = @($unknownDetails | ForEach-Object { Get-OpenClawE2EInstallFailureCode -Detail $_ })',
    '}'
) -join [Environment]::NewLine
$installFailureEvidence = & ([scriptblock]::Create($installFailureCaseSource))
$expectedInstallFailureCodes = @(
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
Assert-True -Condition (($installFailureEvidence.KnownCodes -join ',') -eq ($expectedInstallFailureCodes -join ',')) -Name 'Exact validated install details map to fixed causal or diagnostic codes'
Assert-True -Condition (@($installFailureEvidence.UnknownCodes | Where-Object { $_ -ne 'E2E-CHECKPOINT-STAGE-INSTALL-STATUS-MISMATCH' }).Count -eq 0) -Name 'Unknown or malformed install details collapse to the generic install mismatch code'
$safeInstallAssignments = @($controllerAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        [string]::Equals($node.Left.VariablePath.UserPath, 'safeInstallFailureCodes', [StringComparison]::Ordinal)
}, $true))
$productionInstallCodeEvidence = $null
if ($safeInstallAssignments.Count -eq 1) {
    $productionInstallCodeCaseSource = @(
        $unknownHarnessSource,
        $resolveHarnessSource,
        $selectCheckpointSource,
        $safeInstallAssignments[0].Extent.Text,
        '$safeHarnessCodes = @(''E2E-CHECKPOINT-STAGE-INSTALL-STATUS-MISMATCH'') + $safeInstallFailureCodes',
        '[pscustomobject]@{',
        '    SafeCodes = @($safeInstallFailureCodes)',
        '    SelectedCodes = @($safeInstallFailureCodes | ForEach-Object { Select-OpenClawE2ECheckpointErrorCode -CurrentCode ''OCES-INSTALL-001'' -CandidateCode $_ -SafeCodes $safeHarnessCodes -SpecificInstallCodes $safeInstallFailureCodes })',
        '}'
    ) -join [Environment]::NewLine
    $productionInstallCodeEvidence = & ([scriptblock]::Create($productionInstallCodeCaseSource))
}
Assert-True -Condition ($safeInstallAssignments.Count -eq 1 -and
    $null -ne $productionInstallCodeEvidence -and
    ($productionInstallCodeEvidence.SafeCodes -join ',') -eq ($expectedInstallFailureCodes -join ',') -and
    ($productionInstallCodeEvidence.SelectedCodes -join ',') -eq ($expectedInstallFailureCodes -join ',')) -Name 'Production install allowlist contains and selects every fixed classifier code'

$checkpointMismatchSource = Get-OpenClawE2EFunctionSource -Ast $controllerAst -Name 'Get-OpenClawE2ECheckpointMismatchCode'
$checkpointMismatchCaseSource = @(
    'param([object[]]$ExpectedSteps)',
    $installFailureSource,
    $checkpointMismatchSource,
    'function Copy-CheckpointSteps {',
    '    param([object[]]$SourceSteps)',
    '    return @($SourceSteps | ForEach-Object {',
    '        $detail = ''''',
    '        if ($null -ne $_.PSObject.Properties[''detail'']) { $detail = [string]$_.detail }',
    '        [pscustomobject]@{ Id = [string]$_.id; Status = [string]$_.status; Detail = $detail }',
    '    })',
    '}',
    '$stageCodes = @()',
    'for ($index = 0; $index -lt $ExpectedSteps.Count; $index++) {',
    '    $steps = Copy-CheckpointSteps -SourceSteps $ExpectedSteps',
    '    $steps[$index].Status = ''Pending''',
    '    $stageCodes += Get-OpenClawE2ECheckpointMismatchCode -Checkpoint ([pscustomobject]@{ Status = ''InProgress''; Steps = $steps })',
    '}',
    '$precedenceSteps = Copy-CheckpointSteps -SourceSteps $ExpectedSteps',
    '$precedenceSteps[1].Status = ''Pending''',
    '$precedenceSteps[5].Status = ''Failed''',
    '$precedenceSteps[5].Detail = ''Slack plugin provenance or installation failure.''',
    '$precedenceCode = Get-OpenClawE2ECheckpointMismatchCode -Checkpoint ([pscustomobject]@{ Status = ''InProgress''; Steps = $precedenceSteps })',
    '$installFailedSteps = Copy-CheckpointSteps -SourceSteps $ExpectedSteps',
    '$installFailedSteps[5].Status = ''Failed''',
    '$installFailedSteps[5].Detail = ''Slack plugin provenance or installation failure.''',
    '$installFailedCode = Get-OpenClawE2ECheckpointMismatchCode -Checkpoint ([pscustomobject]@{ Status = ''Failed''; Steps = $installFailedSteps })',
    '$unknownInstallSteps = Copy-CheckpointSteps -SourceSteps $ExpectedSteps',
    '$unknownInstallSteps[5].Status = ''Failed''',
    '$unknownInstallSteps[5].Detail = ''Exit code 1'' + [Environment]::NewLine + ''token''',
    '$unknownInstallCode = Get-OpenClawE2ECheckpointMismatchCode -Checkpoint ([pscustomobject]@{ Status = ''Failed''; Steps = $unknownInstallSteps })',
    '$topLevelCode = Get-OpenClawE2ECheckpointMismatchCode -Checkpoint ([pscustomobject]@{ Status = ''InProgress''; Steps = (Copy-CheckpointSteps -SourceSteps $ExpectedSteps) })',
    '$invalidCodes = @()',
    'try {',
    '    $shortSteps = @((Copy-CheckpointSteps -SourceSteps $ExpectedSteps) | Select-Object -First 7)',
    '    [void](Get-OpenClawE2ECheckpointMismatchCode -Checkpoint ([pscustomobject]@{ Status = ''InProgress''; Steps = $shortSteps }))',
    '}',
    'catch { $invalidCodes += [string]$_.Exception.Message }',
    'try {',
    '    $maliciousIdSteps = Copy-CheckpointSteps -SourceSteps $ExpectedSteps',
    '    $maliciousIdSteps[0].Status = ''Pending''',
    '    $maliciousIdSteps[7].Id = ''verify'' + [Environment]::NewLine + ''C:\Users\runneradmin\secret''',
    '    [void](Get-OpenClawE2ECheckpointMismatchCode -Checkpoint ([pscustomobject]@{ Status = ''InProgress''; Steps = $maliciousIdSteps }))',
    '}',
    'catch { $invalidCodes += [string]$_.Exception.Message }',
    'try {',
    '    $maliciousStatusSteps = Copy-CheckpointSteps -SourceSteps $ExpectedSteps',
    '    $maliciousStatusSteps[0].Status = ''Pending''',
    '    $maliciousStatusSteps[7].Status = ''Skipped'' + [Environment]::NewLine + ''token''',
    '    [void](Get-OpenClawE2ECheckpointMismatchCode -Checkpoint ([pscustomobject]@{ Status = ''InProgress''; Steps = $maliciousStatusSteps }))',
    '}',
    'catch { $invalidCodes += [string]$_.Exception.Message }',
    '[pscustomobject]@{ StageCodes = $stageCodes; PrecedenceCode = $precedenceCode; InstallFailedCode = $installFailedCode; UnknownInstallCode = $unknownInstallCode; TopLevelCode = $topLevelCode; InvalidCodes = $invalidCodes }'
) -join [Environment]::NewLine
$checkpointMismatchEvidence = & ([scriptblock]::Create($checkpointMismatchCaseSource)) $successfulStages
$expectedCheckpointStageCodes = @(
    'E2E-CHECKPOINT-STAGE-DIAGNOSE-STATUS-MISMATCH',
    'E2E-CHECKPOINT-STAGE-NODE-STATUS-MISMATCH',
    'E2E-CHECKPOINT-STAGE-DOWNLOAD-STATUS-MISMATCH',
    'E2E-CHECKPOINT-STAGE-INTEGRITY-STATUS-MISMATCH',
    'E2E-CHECKPOINT-STAGE-DRY-RUN-STATUS-MISMATCH',
    'E2E-CHECKPOINT-STAGE-INSTALL-STATUS-MISMATCH',
    'E2E-CHECKPOINT-STAGE-ONBOARD-STATUS-MISMATCH',
    'E2E-CHECKPOINT-STAGE-VERIFY-STATUS-MISMATCH'
)
Assert-True -Condition (($checkpointMismatchEvidence.StageCodes -join ',') -eq ($expectedCheckpointStageCodes -join ',')) -Name 'Every checkpoint stage mismatch maps to its fixed code'
Assert-True -Condition ($checkpointMismatchEvidence.PrecedenceCode -eq 'E2E-CHECKPOINT-STAGE-NODE-STATUS-MISMATCH' -and
    $checkpointMismatchEvidence.TopLevelCode -eq 'E2E-CHECKPOINT-TOP-LEVEL-STATUS-MISMATCH') -Name 'Checkpoint mismatch precedence selects the first causal stage before the top-level fallback'
Assert-True -Condition ($checkpointMismatchEvidence.InstallFailedCode -eq 'E2E-INSTALL-SLACK-PLUGIN-FAILED' -and
    $checkpointMismatchEvidence.UnknownInstallCode -eq 'E2E-CHECKPOINT-STAGE-INSTALL-STATUS-MISMATCH') -Name 'Install failure classification uses only exact validated checkpoint details'
Assert-True -Condition (@($checkpointMismatchEvidence.InvalidCodes).Count -eq 3 -and
    @($checkpointMismatchEvidence.InvalidCodes | Where-Object { $_ -ne 'E2E-CHECKPOINT-INVALID' }).Count -eq 0) -Name 'Malformed checkpoint shape, IDs, and statuses fail closed before classification'
$allCheckpointCodes = @($checkpointMismatchEvidence.StageCodes) + @($checkpointMismatchEvidence.PrecedenceCode, $checkpointMismatchEvidence.InstallFailedCode, $checkpointMismatchEvidence.UnknownInstallCode, $checkpointMismatchEvidence.TopLevelCode) + @($checkpointMismatchEvidence.InvalidCodes)
Assert-True -Condition (@($allCheckpointCodes | Where-Object { [string]$_ -notmatch '^E2E-[A-Z0-9-]{1,64}$' }).Count -eq 0) -Name 'Checkpoint diagnostics never reflect raw IDs, statuses, paths, or secrets'
$checkpointEvidenceSource = Get-OpenClawE2EFunctionSource -Ast $controllerAst -Name 'Get-OpenClawE2ECheckpointEvidence'
$checkpointCaseSource = @(
    'param([string]$StateRootValue, [object[]]$StepsValue, [string]$StatusValue)',
    $installFailureSource,
    $checkpointMismatchSource,
    $checkpointEvidenceSource,
    'function Read-OpenClawCheckpoint {',
    '    param([string]$Path, [string]$ExpectedTargetVersion, [string]$ExpectedSourceFingerprint)',
    '    return [pscustomobject]@{ Status = $StatusValue; Steps = @($StepsValue) }',
    '}',
    'Get-OpenClawE2ECheckpointEvidence -StateRoot $StateRootValue -ExpectedTargetVersion ''2026.7.1'' -ExpectedSourceFingerprint (''A'' * 64)'
) -join [Environment]::NewLine
$checkpointCaseRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('OpenClawE2ECheckpointTest-' + [guid]::NewGuid().ToString('N'))))
$checkpointTempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$checkpointEvidence = $null
$checkpointMismatchIntegrationEvidence = $null
$checkpointEvidenceException = $null
try {
    $checkpointStatePath = Join-Path $checkpointCaseRoot 'State'
    [void][IO.Directory]::CreateDirectory($checkpointStatePath)
    [IO.File]::WriteAllText((Join-Path $checkpointStatePath (('a' * 32) + '.json')), '{}', (New-Object Text.UTF8Encoding($false)))
    try {
        $checkpointEvidence = & ([scriptblock]::Create($checkpointCaseSource)) $checkpointCaseRoot $successfulStages 'Completed'
        $integrationSteps = @($successfulStages | ForEach-Object { [pscustomobject]@{ id = [string]$_.id; status = [string]$_.status; detail = '' } })
        $integrationSteps[5].status = 'Failed'
        $integrationSteps[5].detail = 'Npm filesystem failure.'
        $checkpointMismatchIntegrationEvidence = & ([scriptblock]::Create($checkpointCaseSource)) $checkpointCaseRoot $integrationSteps 'Failed'
    }
    catch {
        $checkpointEvidenceException = $_.Exception
    }
}
finally {
    if ([IO.Directory]::Exists($checkpointCaseRoot) -and $checkpointCaseRoot.StartsWith($checkpointTempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        [IO.Directory]::Delete($checkpointCaseRoot, $true)
    }
}
Assert-True -Condition ($null -eq $checkpointEvidenceException -and $null -ne $checkpointEvidence -and @($checkpointEvidence.Stages).Count -eq 8 -and $checkpointEvidence.MatchesExpected -and [string]::IsNullOrWhiteSpace([string]$checkpointEvidence.FailureCode)) -Name 'PowerShell 5.1 returns all eight checkpoint stages without Generic List conversion failure'
Assert-True -Condition ($null -eq $checkpointEvidenceException -and $null -ne $checkpointMismatchIntegrationEvidence -and -not $checkpointMismatchIntegrationEvidence.MatchesExpected -and $checkpointMismatchIntegrationEvidence.FailureCode -eq 'E2E-INSTALL-NPM-FILESYSTEM-FAILED') -Name 'Checkpoint evidence carries only the fixed causal npm install code'
Assert-True -Condition (@($checkpointMismatchIntegrationEvidence.Stages | Where-Object { $null -ne $_.PSObject.Properties['detail'] }).Count -eq 0) -Name 'Published checkpoint stages omit raw detail even when it supplied a fixed classifier code'
$successReceipt = [ordered]@{
    schemaVersion = 1
    success = $true
    harnessCompleted = $true
    environmentVerified = $true
    credentialsScrubbed = $true
    installerExitCode = 0
    errorCode = ''
    targetVersion = '2026.7.1'
    testedCommit = $testedCommit
    installedVersion = '2026.7.1'
    installationSucceeded = $true
    provenanceReceiptValidated = $true
    slackPluginVerified = $true
    stages = $successfulStages
}

$successCase = Invoke-OpenClawE2ESummaryCase -SummaryScript $summaryScript -Receipt $successReceipt -ControllerOutcome success -ExpectedCommit $testedCommit
Assert-True -Condition (-not $successCase.Threw -and $successCase.Summary.Contains('- Result: PASS') -and $successCase.Summary.Contains($testedCommit)) -Name 'Complete consistent evidence produces PASS'

$missingCase = Invoke-OpenClawE2ESummaryCase -SummaryScript $summaryScript -Receipt $null -ControllerOutcome success -ExpectedCommit $testedCommit
Assert-True -Condition ($missingCase.Threw -and $missingCase.Summary.Contains('- Result: FAIL')) -Name 'Missing receipt fails the summary step'

$shortReceipt = [ordered]@{}
foreach ($key in $successReceipt.Keys) {
    $shortReceipt[$key] = $successReceipt[$key]
}
$shortReceipt['stages'] = @($successfulStages | Select-Object -First 7)
$shortCase = Invoke-OpenClawE2ESummaryCase -SummaryScript $summaryScript -Receipt $shortReceipt -ControllerOutcome success -ExpectedCommit $testedCommit
Assert-True -Condition ($shortCase.Threw -and $shortCase.Summary.Contains('- Result: FAIL')) -Name 'Truncated stage evidence cannot produce PASS'

$contradictoryReceipt = [ordered]@{}
foreach ($key in $successReceipt.Keys) {
    $contradictoryReceipt[$key] = $successReceipt[$key]
}
$contradictoryReceipt['provenanceReceiptValidated'] = $false
$contradictoryCase = Invoke-OpenClawE2ESummaryCase -SummaryScript $summaryScript -Receipt $contradictoryReceipt -ControllerOutcome success -ExpectedCommit $testedCommit
Assert-True -Condition ($contradictoryCase.Threw -and $contradictoryCase.Summary.Contains('- Result: FAIL')) -Name 'Contradictory success evidence cannot produce PASS'

$failureReceipt = [ordered]@{
    schemaVersion = 1
    success = $false
    harnessCompleted = $true
    environmentVerified = $true
    credentialsScrubbed = $true
    installerExitCode = 1
    errorCode = 'E2E-INSTALLER-FAILED'
    targetVersion = '2026.7.1'
    testedCommit = $testedCommit
    installedVersion = ''
    installationSucceeded = $false
    provenanceReceiptValidated = $false
    slackPluginVerified = $false
    stages = @()
}
$failureCase = Invoke-OpenClawE2ESummaryCase -SummaryScript $summaryScript -Receipt $failureReceipt -ControllerOutcome failure -ExpectedCommit $testedCommit
Assert-True -Condition ($failureCase.Threw -and $failureCase.Summary.Contains('- Result: FAIL') -and $failureCase.Summary.Contains('E2E-INSTALLER-FAILED')) -Name 'Valid installer failure keeps its sanitized error code while failing closed'

$otherCommit = ('b' * 40) -join ''
$commitMismatchCase = Invoke-OpenClawE2ESummaryCase -SummaryScript $summaryScript -Receipt $successReceipt -ControllerOutcome success -ExpectedCommit $otherCommit
Assert-True -Condition ($commitMismatchCase.Threw -and $commitMismatchCase.Summary.Contains('- Result: FAIL')) -Name 'Commit mismatch cannot produce PASS'

$maliciousCommitReceipt = [ordered]@{}
foreach ($key in $successReceipt.Keys) {
    $maliciousCommitReceipt[$key] = $successReceipt[$key]
}
$maliciousCommitReceipt['testedCommit'] = $testedCommit + "`n- injected"
$maliciousCommitCase = Invoke-OpenClawE2ESummaryCase -SummaryScript $summaryScript -Receipt $maliciousCommitReceipt -ControllerOutcome success -ExpectedCommit $testedCommit
Assert-True -Condition ($maliciousCommitCase.Threw -and $maliciousCommitCase.Summary.Contains('(invalid receipt)') -and -not $maliciousCommitCase.Summary.Contains('injected')) -Name 'Invalid commit text cannot inject Markdown into the summary'

$maliciousErrorReceipt = [ordered]@{}
foreach ($key in $failureReceipt.Keys) {
    $maliciousErrorReceipt[$key] = $failureReceipt[$key]
}
$maliciousErrorReceipt['errorCode'] = 'E2E-HARNESS-CHECKPOINT-001' + [Environment]::NewLine + '- injected'
$maliciousErrorCase = Invoke-OpenClawE2ESummaryCase -SummaryScript $summaryScript -Receipt $maliciousErrorReceipt -ControllerOutcome failure -ExpectedCommit $testedCommit
Assert-True -Condition ($maliciousErrorCase.Threw -and $maliciousErrorCase.Summary.Contains('(invalid receipt)') -and -not $maliciousErrorCase.Summary.Contains('injected')) -Name 'Invalid harness error text cannot inject Markdown into the summary'

Write-Host ''
Write-Host ("GitHub runner E2E contract tests: {0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) {
    exit 1
}
