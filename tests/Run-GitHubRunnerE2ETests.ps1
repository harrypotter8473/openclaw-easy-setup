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
Assert-True -Condition ($controller.Contains('Get-OpenClawE2EPostconditionErrorCode -Result $result') -and
    $controller.Contains('E2E-POSTCONDITION-INSTALLATION-FAILED') -and
    $controller.Contains('E2E-POSTCONDITION-PROVENANCE-FAILED') -and
    $controller.Contains('E2E-SLACK-VERIFICATION-FAILED')) -Name 'Final postcondition failures use fixed diagnostic codes'
Assert-True -Condition ($controller.Contains('Write-Host ("Installer exit code: {0}" -f $result.installerExitCode)')) -Name 'Controller prints only the safe numeric installer exit code'
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


$unknownHarnessSource = Get-OpenClawE2EFunctionSource -Ast $controllerAst -Name 'Get-OpenClawE2EUnknownHarnessCode'
$resolveHarnessSource = Get-OpenClawE2EFunctionSource -Ast $controllerAst -Name 'Resolve-OpenClawE2EHarnessErrorCode'
$resolverCaseSource = @(
    '$safeCodes = @(''E2E-CHECKPOINT-INVALID'')',
    '$phases = @(''preflight'', ''paths'', ''source'', ''environment'', ''installer'', ''checkpoint'', ''provenance'', ''slack'', ''postconditions'')',
    '[pscustomobject]@{',
    '    PhaseCodes = @($phases | ForEach-Object { Get-OpenClawE2EUnknownHarnessCode -Phase $_ })',
    '    UnknownPhase = Get-OpenClawE2EUnknownHarnessCode -Phase ''CHECKPOINT''',
    '    MaliciousPhase = Get-OpenClawE2EUnknownHarnessCode -Phase (''checkpoint'' + [Environment]::NewLine + ''C:\Users\runneradmin\secret'')',
    '    ExactSafe = Resolve-OpenClawE2EHarnessErrorCode -CandidateCode ''E2E-CHECKPOINT-INVALID'' -Phase ''checkpoint'' -SafeCodes $safeCodes',
    '    WrongCase = Resolve-OpenClawE2EHarnessErrorCode -CandidateCode ''e2e-checkpoint-invalid'' -Phase ''checkpoint'' -SafeCodes $safeCodes',
    '    MaliciousCandidate = Resolve-OpenClawE2EHarnessErrorCode -CandidateCode (''E2E-CHECKPOINT-INVALID'' + [Environment]::NewLine + ''- injected'') -Phase ''checkpoint'' -SafeCodes $safeCodes',
    '}'
) -join [Environment]::NewLine
$resolverTestSource = $unknownHarnessSource + [Environment]::NewLine + $resolveHarnessSource + [Environment]::NewLine + $resolverCaseSource
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
$checkpointEvidenceSource = Get-OpenClawE2EFunctionSource -Ast $controllerAst -Name 'Get-OpenClawE2ECheckpointEvidence'
$checkpointCaseSource = @(
    'param([string]$StateRootValue, [object[]]$StepsValue)',
    $checkpointEvidenceSource,
    'function Read-OpenClawCheckpoint {',
    '    param([string]$Path, [string]$ExpectedTargetVersion, [string]$ExpectedSourceFingerprint)',
    '    return [pscustomobject]@{ Status = ''Completed''; Steps = @($StepsValue) }',
    '}',
    'Get-OpenClawE2ECheckpointEvidence -StateRoot $StateRootValue -ExpectedTargetVersion ''2026.7.1'' -ExpectedSourceFingerprint (''A'' * 64)'
) -join [Environment]::NewLine
$checkpointCaseRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('OpenClawE2ECheckpointTest-' + [guid]::NewGuid().ToString('N'))))
$checkpointTempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$checkpointEvidence = $null
$checkpointEvidenceException = $null
try {
    $checkpointStatePath = Join-Path $checkpointCaseRoot 'State'
    [void][IO.Directory]::CreateDirectory($checkpointStatePath)
    [IO.File]::WriteAllText((Join-Path $checkpointStatePath (('a' * 32) + '.json')), '{}', (New-Object Text.UTF8Encoding($false)))
    try {
        $checkpointEvidence = & ([scriptblock]::Create($checkpointCaseSource)) $checkpointCaseRoot $successfulStages
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
Assert-True -Condition ($null -eq $checkpointEvidenceException -and $null -ne $checkpointEvidence -and @($checkpointEvidence.Stages).Count -eq 8 -and $checkpointEvidence.MatchesExpected) -Name 'PowerShell 5.1 returns all eight checkpoint stages without Generic List conversion failure'
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
