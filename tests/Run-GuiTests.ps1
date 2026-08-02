[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$engineModulePath = Join-Path $projectRoot 'src\OpenClawEasySetup.psm1'
$guiModulePath = Join-Path $projectRoot 'src\OpenClawEasySetup.Gui.psm1'
$guiEntryPoint = Join-Path $projectRoot 'OpenClawEasySetup.Gui.ps1'
$settingsGuiEntryPoint = Join-Path $projectRoot 'OpenClawEasySetup.Settings.Gui.ps1'
$guiLauncher = Join-Path $projectRoot 'Start-OpenClawEasySetup.cmd'
$xamlPath = Join-Path $projectRoot 'ui\MainWindow.xaml'
$settingsXamlPath = Join-Path $projectRoot 'ui\SettingsWindow.xaml'
$localePath = Join-Path $projectRoot 'locales\ko-KR.json'
Import-Module -Name $guiModulePath -Force
Import-Module -Name $engineModulePath -Force

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

function Invoke-GuiWorkerProcess {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Invocation,
        [int]$TimeoutMilliseconds = 60000,
        [string]$InheritedModulePath
    )

    $startInfo = New-OpenClawGuiProcessStartInfo -Invocation $Invocation
    $modulePathWasOverridden = $PSBoundParameters.ContainsKey('InheritedModulePath')
    $previousModulePath = $env:PSModulePath
    try {
        if ($modulePathWasOverridden) {
            $env:PSModulePath = $InheritedModulePath
        }
        $process = [Diagnostics.Process]::Start($startInfo)
    }
    finally {
        if ($modulePathWasOverridden) {
            $env:PSModulePath = $previousModulePath
        }
    }
    if ($null -eq $process) {
        throw 'The GUI worker test process did not start.'
    }
    $outputTask = if ($startInfo.RedirectStandardOutput) { $process.StandardOutput.ReadToEndAsync() } else { $null }
    $errorTask = if ($startInfo.RedirectStandardError) { $process.StandardError.ReadToEndAsync() } else { $null }
    try {
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $process.Kill()
            throw 'The GUI worker test process exceeded its bounded timeout.'
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StandardOutput = $(if ($null -eq $outputTask) { '' } else { [string]$outputTask.Result })
            StandardError = $(if ($null -eq $errorTask) { '' } else { [string]$errorTask.Result })
        }
    }
    finally {
        $process.Dispose()
    }
}

$testRoot = Join-Path $PSScriptRoot ('.tmp-gui-{0}' -f [guid]::NewGuid().ToString('N'))
try {
    $catalogText = Get-Content -LiteralPath $localePath -Raw -Encoding UTF8
    $catalog = $catalogText | ConvertFrom-Json
    Assert-True -Condition ($null -ne $catalog.PSObject.Properties['gui']) -Name 'Korean catalog contains the GUI message section'
    Assert-True -Condition (-not $catalogText.Contains([char]0xFFFD)) -Name 'Korean GUI catalog contains no replacement characters'
    foreach ($requiredSection in @('actions', 'actionDescriptions', 'stages', 'stageStatus', 'accessibility')) {
        Assert-True -Condition ($null -ne $catalog.gui.PSObject.Properties[$requiredSection]) -Name ("GUI catalog contains {0}" -f $requiredSection)
    }

    $definition = Get-OpenClawGuiDefinition
    Assert-Equal -Actual $definition.Version -Expected '0.4.0' -Name 'GUI definition exposes version 0.4.0'
    Assert-Equal -Actual @($definition.Actions).Count -Expected 6 -Name 'GUI exposes six beginner actions'
    Assert-Equal -Actual @($definition.Stages).Count -Expected 8 -Name 'GUI uses all eight checkpoint stages'
    Assert-True -Condition (-not $definition.Approval.DefaultApproved) -Name 'Install approval is unchecked by default'
    Assert-True -Condition (-not $definition.Approval.StartIsDefaultButton) -Name 'Install start is not the default button'
    Assert-True -Condition $definition.Approval.CancelIsDefaultButton -Name 'Cancel is the default plan button'
    Assert-True -Condition (@($definition.Actions | Where-Object { $_.RequiresApproval -and -not $_.ChangesPC }).Count -eq 0) -Name 'Every approval-gated action is labeled as a PC change'
    Assert-True -Condition ($definition.Accessibility.KeyboardNavigation -and $definition.Accessibility.ScreenReaderNames -and $definition.Accessibility.UsesSystemColors -and $definition.Accessibility.StatusUsesText) -Name 'GUI definition declares keyboard, screen-reader, system-color, and text-status support'

    $probeRoot = Join-Path $testRoot 'missing-state'
    $probe = Get-OpenClawGuiResumeState -StateDirectory $probeRoot
    Assert-True -Condition (-not $probe.Available -and -not $probe.Invalid) -Name 'Resume probe reports no checkpoint for a missing state root'
    Assert-True -Condition (-not (Test-Path -LiteralPath $probeRoot)) -Name 'Resume probe does not create a missing state root'

    $planFingerprint = Get-OpenClawPlanFingerprint
    Assert-True -Condition ($planFingerprint -match '^[A-F0-9]{64}$') -Name 'Install plan has a stable SHA-256 fingerprint'
    Assert-Equal -Actual (Get-OpenClawPlanFingerprint) -Expected $planFingerprint -Name 'Install plan fingerprint is deterministic'
    $resumePlanFingerprint = Get-OpenClawPlanFingerprint -Mode Resume
    Assert-True -Condition ($resumePlanFingerprint -match '^[A-F0-9]{64}$' -and $resumePlanFingerprint -ne $planFingerprint) -Name 'Resume approval uses a distinct plan-mode fingerprint'
    $planSnapshot = Get-OpenClawGuiPlanSnapshot -Action Install
    Assert-True -Condition (@($planSnapshot.Plan).Count -eq 8 -and $planSnapshot.Fingerprint -eq $planFingerprint) -Name 'Approval view binds one consistent plan snapshot and fingerprint'
    Assert-Equal -Actual (Get-OpenClawGuiPrimaryAction -Status Succeeded -CompletedAction Install).Id -Expected 'Configure' -Name 'Successful install offers the safe settings wizard next'
    Assert-Equal -Actual (Get-OpenClawGuiPrimaryAction -Status Succeeded -CompletedAction Configure).Id -Expected 'Verify' -Name 'Successful configuration offers verification next'
    Assert-Equal -Actual (Get-OpenClawGuiPrimaryAction -Status Cancelled -CompletedAction Install -ResumeAvailable).Id -Expected 'Resume' -Name 'Cancelled install offers resume only when a checkpoint is available'
    Assert-Equal -Actual (Get-OpenClawGuiPrimaryAction -Status Cancelled -CompletedAction Install).Id -Expected 'Home' -Name 'Cancelled install without a checkpoint returns home'
    Assert-Equal -Actual (Get-OpenClawGuiPrimaryAction -Status Failed -CompletedAction Install -ResumeAvailable).Id -Expected 'Home' -Name 'Failed install never proceeds directly to configuration'
    $oldCheckpoint = [pscustomobject]@{ CreatedAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToString('o') }
    $currentCheckpoint = [pscustomobject]@{ CreatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o') }
    $workerStart = [DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o')
    Assert-True -Condition ($null -eq (Select-OpenClawGuiProgressCheckpoint -Checkpoint $oldCheckpoint -Action Install -StartedAtUtc $workerStart)) -Name 'Fresh install progress ignores a checkpoint from an earlier run'
    Assert-True -Condition ($null -ne (Select-OpenClawGuiProgressCheckpoint -Checkpoint $currentCheckpoint -Action Install -StartedAtUtc $workerStart)) -Name 'Fresh install progress accepts its current checkpoint'
    Assert-True -Condition ($null -ne (Select-OpenClawGuiProgressCheckpoint -Checkpoint $oldCheckpoint -Action Resume -StartedAtUtc $workerStart)) -Name 'Resume progress intentionally keeps the selected earlier checkpoint'
    $sourceConfigLock = Enter-OpenClawSourceConfigReadLock
    try {
        Assert-Equal -Actual (Get-OpenClawPlanFingerprint) -Expected $planFingerprint -Name 'Plan remains readable while the immutable source-config lock is held'
        $sourceConfigPath = Join-Path $projectRoot 'config\openclaw-source.json'
        $writeWhileLocked = Get-ThrownException {
            $writeStream = New-Object IO.FileStream($sourceConfigPath, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
            $writeStream.Dispose()
        }
        Assert-True -Condition ($null -ne $writeWhileLocked) -Name 'Approved source configuration cannot be replaced or written during worker execution'
    }
    finally {
        $sourceConfigLock.Dispose()
    }

    $unapprovedInstall = Get-ThrownException { New-OpenClawGuiWorkerInvocation -Action Install -PlanFingerprint $planFingerprint }
    Assert-True -Condition ($null -ne $unapprovedInstall) -Name 'GUI adapter rejects an install without explicit approval'
    $unapprovedResume = Get-ThrownException { New-OpenClawGuiWorkerInvocation -Action Resume -PlanFingerprint $planFingerprint }
    Assert-True -Condition ($null -ne $unapprovedResume) -Name 'GUI adapter rejects resume without explicit approval'
    $unapprovedConfigure = Get-ThrownException { New-OpenClawGuiWorkerInvocation -Action Configure }
    Assert-True -Condition ($null -ne $unapprovedConfigure) -Name 'GUI adapter rejects configuration without explicit approval'

    $workerState = Join-Path $testRoot 'state with spaces'
    $cancellationPath = Join-Path (Join-Path $workerState 'State') 'gui-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.cancel'
    $installInvocation = New-OpenClawGuiWorkerInvocation -Action Install -Approved -StateDirectory $workerState -CancellationPath $cancellationPath -PlanFingerprint $planFingerprint
    Assert-Equal -Actual ([string]$installInvocation.FileName) -Expected (Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe') -Name 'Worker path comes from the OS system directory rather than a mutable process variable'
    Assert-True -Condition (-not $installInvocation.UseShellExecute -and $installInvocation.CreateNoWindow) -Name 'Install worker is isolated in a hidden non-shell process'
    Assert-True -Condition ($installInvocation.ArgumentList -contains '-Apply' -and $installInvocation.ArgumentList -contains '-SkipOnboarding' -and $installInvocation.ArgumentList -contains '-GuiApproved') -Name 'Approved GUI install passes explicit mutation and argv-safe approval arguments'
    Assert-True -Condition ($installInvocation.ArgumentList -notcontains '-Confirm:$false') -Name 'GUI worker never passes an unbindable native Confirm boolean token'
    Assert-True -Condition ($installInvocation.ArgumentList -contains '-ExpectedPlanFingerprint' -and $installInvocation.ArgumentList -contains $planFingerprint) -Name 'Approved GUI install binds the plan fingerprint shown to the user'
    Assert-True -Condition ($installInvocation.ArgumentList -contains '-CancellationPath' -and $installInvocation.CooperativeCancellation) -Name 'Approved GUI install uses cooperative cancellation'
    Assert-True -Condition ($installInvocation.ArgumentList -notcontains '-ExecutionPolicy') -Name 'GUI worker does not weaken the execution policy'
    Assert-True -Condition ($installInvocation.Arguments.Contains('"' + $workerState + '"')) -Name 'Worker command line quotes state paths containing spaces'

    $resumeInvocation = New-OpenClawGuiWorkerInvocation -Action Resume -Approved -StateDirectory $workerState -CancellationPath $cancellationPath -PlanFingerprint $resumePlanFingerprint
    Assert-True -Condition ($resumeInvocation.ArgumentList -contains '-Resume') -Name 'Resume worker passes the exact Resume switch'
    $configureInvocation = New-OpenClawGuiWorkerInvocation -Action Configure -Approved -StateDirectory $workerState
    Assert-True -Condition (-not $configureInvocation.UseShellExecute -and $configureInvocation.CreateNoWindow) -Name 'Safe settings wizard runs without an extra PowerShell console'
    Assert-True -Condition ($configureInvocation.ArgumentList -contains '-STA' -and $configureInvocation.ArgumentList -contains '-NonInteractive') -Name 'Safe settings wizard uses a hidden STA worker process'
    Assert-True -Condition ($configureInvocation.ArgumentList -contains (Join-Path $projectRoot 'OpenClawEasySetup.Settings.Gui.ps1') -and $configureInvocation.ArgumentList -notcontains '-Apply' -and $configureInvocation.ArgumentList -notcontains '-GuiApproved') -Name 'Opening the wizard cannot pre-approve its inner configuration plan'
    $configureStartInfo = New-OpenClawGuiProcessStartInfo -Invocation $configureInvocation
    Assert-True -Condition ([string]::IsNullOrWhiteSpace($configureStartInfo.Verb)) -Name 'GUI never elevates the settings wizard'

    $missingBundleDestination = Get-ThrownException { New-OpenClawGuiWorkerInvocation -Action Bundle }
    Assert-True -Condition ($null -ne $missingBundleDestination) -Name 'Diagnostic bundle requires an explicit save location'
    $bundleDestination = Join-Path $testRoot 'support bundle.zip'
    $bundleInvocation = New-OpenClawGuiWorkerInvocation -Action Bundle -DiagnosticOutputPath $bundleDestination
    Assert-True -Condition ($bundleInvocation.ArgumentList -contains '-DiagnosticOutputPath' -and $bundleInvocation.ArgumentList -contains ([IO.Path]::GetFullPath($bundleDestination))) -Name 'Diagnostic bundle uses only the selected local path'
    Assert-True -Condition (-not (Test-Path -LiteralPath $bundleDestination)) -Name 'Creating a bundle invocation does not write a file'

    $blockedWorkerState = Join-Path $testRoot 'blocked-worker-state'
    $blockedCancellationPath = Join-Path (Join-Path $blockedWorkerState 'State') 'gui-cccccccccccccccccccccccccccccccc.cancel'
    $blockedInvocation = New-OpenClawGuiWorkerInvocation -Action Install -Approved -StateDirectory $blockedWorkerState -CancellationPath $blockedCancellationPath -PlanFingerprint ('A' * 64)
    $blockedWorkerResult = Invoke-GuiWorkerProcess -Invocation $blockedInvocation -InheritedModulePath (Join-Path $testRoot 'foreign-powershell-modules')
    Assert-Equal -Actual $blockedWorkerResult.ExitCode -Expected 31 -Name 'Real Windows PowerShell worker restores trusted modules, binds GUI approval, and rejects a changed plan'
    Assert-True -Condition (-not (Test-Path -LiteralPath $blockedWorkerState)) -Name 'Changed-plan worker creates no state directory and performs no installation work'

    $resumeWorkerState = Join-Path $testRoot 'cancelled-resume-worker-state'
    $resumeWorkerConfig = Get-OpenClawSourceConfig
    $resumeWorkerSourceFingerprint = (Get-FileHash -LiteralPath (Join-Path $projectRoot 'config\openclaw-source.json') -Algorithm SHA256).Hash.ToUpperInvariant()
    [void](New-OpenClawCheckpoint -StateDirectory $resumeWorkerState -TargetVersion ([string]$resumeWorkerConfig.openClaw.version) -SourceFingerprint $resumeWorkerSourceFingerprint)
    $resumeWorkerCancellationPath = New-OpenClawGuiCancellationPath -StateDirectory $resumeWorkerState
    [void](Request-OpenClawGuiCancellation -Path $resumeWorkerCancellationPath -StateDirectory $resumeWorkerState)
    $cancelledResumeInvocation = New-OpenClawGuiWorkerInvocation -Action Resume -Approved -StateDirectory $resumeWorkerState -CancellationPath $resumeWorkerCancellationPath -PlanFingerprint $resumePlanFingerprint
    $cancelledResumeResult = Invoke-GuiWorkerProcess -Invocation $cancelledResumeInvocation
    Assert-Equal -Actual $cancelledResumeResult.ExitCode -Expected 61 -Name 'Real Resume worker binds its plan mode and honors a pre-requested cancellation'
    $cancelledResumeState = Get-OpenClawGuiResumeState -StateDirectory $resumeWorkerState
    Assert-True -Condition ($cancelledResumeState.Available -and @($cancelledResumeState.Checkpoint.Steps | Where-Object Status -eq 'Running').Count -eq 0) -Name 'Cancelled Resume worker leaves a resumable checkpoint with no running stage'
    Assert-True -Condition (-not (Test-Path -LiteralPath $resumeWorkerCancellationPath)) -Name 'Resume worker cleans its cooperative cancellation signal'

    $bundleWorkerState = Join-Path $testRoot 'bundle-worker-state'
    $bundleWorkerDestination = Join-Path $testRoot 'worker-support.zip'
    $bundleWorkerInvocation = New-OpenClawGuiWorkerInvocation -Action Bundle -StateDirectory $bundleWorkerState -DiagnosticOutputPath $bundleWorkerDestination
    $bundleWorkerResult = Invoke-GuiWorkerProcess -Invocation $bundleWorkerInvocation
    Assert-Equal -Actual $bundleWorkerResult.ExitCode -Expected 0 -Name 'Real Windows PowerShell diagnostic worker binds all native arguments successfully'
    Assert-True -Condition (Test-Path -LiteralPath $bundleWorkerDestination -PathType Leaf) -Name 'Real GUI diagnostic worker creates only the selected local ZIP'

    $diagnoseWorkerState = Join-Path $testRoot 'diagnose-missing-state'
    $diagnoseInvocation = New-OpenClawGuiWorkerInvocation -Action Diagnose -StateDirectory $diagnoseWorkerState
    Assert-True -Condition ($diagnoseInvocation.ArgumentList -contains '-GuiOutput') -Name 'GUI diagnosis requests explicit UTF-8 output'
    $diagnoseWorkerResult = Invoke-GuiWorkerProcess -Invocation $diagnoseInvocation
    Assert-True -Condition ($diagnoseWorkerResult.ExitCode -in @(0, 20)) -Name 'Real Windows PowerShell diagnosis worker returns a stable environment-dependent read-only result'
    $safeDiagnoseOutput = Protect-OpenClawGuiOutput -Text $diagnoseWorkerResult.StandardOutput
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($safeDiagnoseOutput) -and -not $safeDiagnoseOutput.Contains([char]0xFFFD)) -Name 'Real diagnosis output reaches the GUI as valid sanitized UTF-8 text'
    Assert-True -Condition (-not (Test-Path -LiteralPath $diagnoseWorkerState)) -Name 'Real GUI diagnosis creates no state directory'

    $syntheticGuiToken = ('gh' + 'p_' + ('Z' * 32))
    Assert-True -Condition (-not (Protect-OpenClawGuiOutput -Text "result=$syntheticGuiToken").Contains($syntheticGuiToken)) -Name 'GUI worker output removes token-like values before display'

    Assert-Equal -Actual (ConvertTo-OpenClawWindowsArgument -Argument 'plain') -Expected 'plain' -Name 'Simple worker arguments remain unchanged'
    Assert-Equal -Actual (ConvertTo-OpenClawWindowsArgument -Argument '') -Expected '""' -Name 'Empty worker arguments are quoted'
    $quotedArgument = ConvertTo-OpenClawWindowsArgument -Argument 'C:\safe path\value'
    Assert-True -Condition ($quotedArgument.StartsWith('"') -and $quotedArgument.EndsWith('"')) -Name 'Arguments containing whitespace are quoted'

    $checkpointRoot = Join-Path $testRoot 'checkpoint-state'
    $config = Get-OpenClawSourceConfig
    $sourceFingerprint = (Get-FileHash -LiteralPath (Join-Path $projectRoot 'config\openclaw-source.json') -Algorithm SHA256).Hash.ToUpperInvariant()
    $checkpoint = New-OpenClawCheckpoint -StateDirectory $checkpointRoot -TargetVersion ([string]$config.openClaw.version) -SourceFingerprint $sourceFingerprint
    $resumeAvailable = Get-OpenClawGuiResumeState -StateDirectory $checkpointRoot
    Assert-True -Condition ($resumeAvailable.Available -and $resumeAvailable.NextStage -eq 'diagnose') -Name 'GUI detects a valid interrupted checkpoint and its next stage'
    foreach ($stageId in @('diagnose', 'node', 'download', 'integrity', 'dryRun', 'install', 'onboard', 'verify')) {
        $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId $stageId -Status Succeeded
    }
    $completedBarrier = Get-OpenClawGuiResumeState -StateDirectory $checkpointRoot -IncludeCompleted
    Assert-True -Condition (-not $completedBarrier.Available -and $completedBarrier.CompletedBarrier -and $completedBarrier.Checkpoint.Status -eq 'Completed') -Name 'Latest completed checkpoint blocks resurrection of older work'

    $invalidRoot = Join-Path $testRoot 'invalid-state'
    [void][IO.Directory]::CreateDirectory($invalidRoot)
    $invalidResume = Get-OpenClawGuiResumeState -StateDirectory $invalidRoot
    Assert-True -Condition ($invalidResume.Invalid -and $invalidResume.ErrorId -eq 'OCES-RESUME-001') -Name 'Unsafe state layouts produce the stable resume error'

    $cancelRoot = Join-Path $testRoot 'cancel-state'
    $signalPath = New-OpenClawCancellationPath -StateDirectory $cancelRoot
    Assert-True -Condition (-not (Test-Path -LiteralPath $signalPath)) -Name 'Allocating a cancellation path does not request cancellation'
    [void](Request-OpenClawCancellation -Path $signalPath -StateDirectory $cancelRoot)
    Assert-True -Condition (Test-OpenClawCancellationRequested -Path $signalPath -StateDirectory $cancelRoot) -Name 'Cancellation request uses a validated private signal file'
    $outsideSignal = Join-Path $cancelRoot 'gui-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.cancel'
    $outsideException = Get-ThrownException { Request-OpenClawCancellation -Path $outsideSignal -StateDirectory $cancelRoot }
    Assert-True -Condition ($null -ne $outsideException -and -not (Test-Path -LiteralPath $outsideSignal)) -Name 'Cancellation signal outside the private State directory is rejected'
    Assert-True -Condition (Remove-OpenClawCancellationSignal -Path $signalPath -StateDirectory $cancelRoot) -Name 'Validated cancellation signal can be cleaned up exactly'

    $engineCancelPath = New-OpenClawCancellationPath -StateDirectory $cancelRoot
    [void](Request-OpenClawCancellation -Path $engineCancelPath -StateDirectory $cancelRoot)
    $cancelException = Get-ThrownException { Install-OpenClawOfficial -StateDirectory $cancelRoot -CancellationPath $engineCancelPath -SkipOnboarding -Confirm:$false }
    Assert-True -Condition ($null -ne $cancelException -and [string]$cancelException.Data['OpenClawFailureKind'] -eq 'Cancelled') -Name 'Engine stops at the first safe boundary after cancellation'
    $cancelCheckpoint = Get-OpenClawLatestCheckpoint -StateDirectory $cancelRoot -ExpectedTargetVersion ([string]$config.openClaw.version) -ExpectedSourceFingerprint $sourceFingerprint
    Assert-True -Condition ($null -ne $cancelCheckpoint -and $cancelCheckpoint.Status -eq 'InProgress' -and @($cancelCheckpoint.Steps | Where-Object Status -eq 'Running').Count -eq 0) -Name 'Cancelled install leaves a resumable checkpoint with no running stage'
    [void](Remove-OpenClawCancellationSignal -Path $engineCancelPath -StateDirectory $cancelRoot)
    $cancelDefinition = Get-OpenClawExitCodeDefinition -Kind Cancelled
    Assert-Equal -Actual $cancelDefinition.ExitCode -Expected 61 -Name 'Cooperative cancellation has stable exit code 61'
    Assert-Equal -Actual $cancelDefinition.Id -Expected 'OCES-CANCELLED-001' -Name 'Cooperative cancellation has a stable error ID'

    $logCorrelationRoot = Join-Path $testRoot 'log-correlation-state'
    $oldLogPath = New-OpenClawLog -StateDirectory $logCorrelationRoot
    (Get-Item -LiteralPath $oldLogPath).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-10)
    $recentStart = [DateTime]::UtcNow.ToString('o')
    Assert-Equal -Actual (Get-OpenClawGuiResult -ExitCode 0 -Action Verify -StateDirectory $logCorrelationRoot -StartedAtUtc $recentStart).LogPath -Expected '' -Name 'Log-free verification never displays a previous action log'
    Assert-Equal -Actual (Get-OpenClawGuiResult -ExitCode 31 -Action Install -StateDirectory $logCorrelationRoot -StartedAtUtc $recentStart).LogPath -Expected '' -Name 'Early install failure never displays a stale log'

    [xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
    $namespaceManager = New-Object Xml.XmlNamespaceManager($xaml.NameTable)
    $namespaceManager.AddNamespace('w', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation')
    $namespaceManager.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
    $interactiveNodes = @($xaml.SelectNodes('//w:Button | //w:CheckBox | //w:TextBox', $namespaceManager))
    Assert-Equal -Actual $interactiveNodes.Count -Expected 17 -Name 'WPF view exposes the reviewed interactive control count'
    Assert-True -Condition (@($interactiveNodes | Where-Object { [string]::IsNullOrWhiteSpace($_.TabIndex) }).Count -eq 0) -Name 'Every interactive WPF control has an explicit tab index'
    $tabIndices = @($interactiveNodes | ForEach-Object { [int]$_.TabIndex })
    $tabOrderIsStrict = $tabIndices.Count -eq @($tabIndices | Sort-Object -Unique).Count
    for ($tabIndex = 1; $tabIndex -lt $tabIndices.Count; $tabIndex++) {
        $tabOrderIsStrict = $tabOrderIsStrict -and $tabIndices[$tabIndex] -gt $tabIndices[$tabIndex - 1]
    }
    Assert-True -Condition $tabOrderIsStrict -Name 'Interactive WPF controls have a unique forward tab order'
    Assert-True -Condition (@($xaml.SelectNodes('//*[@Text[string-length(normalize-space(.)) > 0 and not(starts-with(normalize-space(.), "{"))] or @Content[string-length(normalize-space(.)) > 0 and not(starts-with(normalize-space(.), "{"))] or @Header[string-length(normalize-space(.)) > 0 and not(starts-with(normalize-space(.), "{"))] or @Title[string-length(normalize-space(.)) > 0 and not(starts-with(normalize-space(.), "{"))]]', $namespaceManager)).Count -eq 0) -Name 'WPF layout contains no hard-coded user-facing strings'
    $xamlText = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
    Assert-True -Condition ($xamlText.Contains('DynamicResource') -and $xamlText.Contains('SystemColors')) -Name 'WPF colors follow Windows system and high-contrast colors'
    Assert-True -Condition ($xamlText.Contains('UseLayoutRounding="True"') -and $xamlText.Contains('ScrollViewer')) -Name 'WPF layout supports DPI rounding and constrained screens'
    Assert-True -Condition ($xamlText.Contains('<ItemsControl.ItemTemplate>') -and $xamlText.Contains('Text="{Binding}"') -and $xamlText.Contains('TextWrapping="Wrap"')) -Name 'Installation plan items use an explicit wrapping template'
    Assert-True -Condition ([int]$xaml.Window.MinWidth -le 520 -and [int]$xaml.Window.MinHeight -le 320) -Name 'WPF minimum size fits a 1366x768 desktop at 200 percent scaling'

    $guiSource = Get-Content -LiteralPath $guiEntryPoint -Raw -Encoding UTF8
    $guiModuleSource = Get-Content -LiteralPath $guiModulePath -Raw -Encoding UTF8
    $engineEntryPointSource = Get-Content -LiteralPath (Join-Path $projectRoot 'OpenClawEasySetup.ps1') -Raw -Encoding UTF8
    Assert-True -Condition ($guiSource -notmatch '(?i)-Verb\s+RunAs|\brunas\b') -Name 'GUI source never elevates the complete application'
    Assert-True -Condition ($guiSource -notmatch '(?i)\bwinget(?:\.exe)?\b|\bnpm(?:\.cmd)?\b|Invoke-WebRequest') -Name 'GUI layer does not install or download directly'
    Assert-True -Condition ($guiModuleSource -notmatch '(?i)-Verb\s+RunAs|\brunas\b') -Name 'GUI adapter defines no broad elevation path'
    Assert-True -Condition ($guiModuleSource -notmatch '\$env:SystemRoot' -and $guiSource -notmatch '\$env:SystemRoot') -Name 'GUI and worker trust decisions do not use mutable SystemRoot'
    Assert-True -Condition ($guiSource.Contains("[IO.Path]::Combine(`$PSHOME, 'Modules')") -and $engineEntryPointSource.Contains("[IO.Path]::Combine(`$PSHOME, 'Modules')") -and $guiSource.Contains('Microsoft.PowerShell.Utility') -and $engineEntryPointSource.Contains('Microsoft.PowerShell.Security')) -Name 'Windows PowerShell entry points load trusted built-in module manifests explicitly'
    Assert-True -Condition ($guiSource.Contains("SetEnvironmentVariable('PSModulePath', `$originalPSModulePath, 'Process')") -and $engineEntryPointSource.Contains("SetEnvironmentVariable('PSModulePath', `$originalPSModulePath, 'Process')")) -Name 'Windows PowerShell entry points restore the caller module path'
    $modulePathBeforeDescribe = $env:PSModulePath
    $describeOutput = (& $guiEntryPoint -Describe | Out-String).Trim()
    Assert-True -Condition (($describeOutput | ConvertFrom-Json).Version -eq '0.4.0' -and $env:PSModulePath -eq $modulePathBeforeDescribe) -Name 'GUI describe mode restores the live caller module path'
    Assert-True -Condition ($guiSource.Contains('AutomationEvents]::LiveRegionChanged') -and $guiSource.Contains("ResultHeadingText'].Focus()")) -Name 'Result view publishes its live-region change and moves focus to the heading'
    Assert-True -Condition ($guiSource -notmatch '\p{IsHangulSyllables}') -Name 'PowerShell 5.1 GUI script keeps localized text in the UTF-8 catalog'

    $launcherSource = Get-Content -LiteralPath $guiLauncher -Raw
    Assert-True -Condition ($launcherSource.Contains('%~dp0OpenClawEasySetup.Gui.ps1') -and $launcherSource.Contains('%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe')) -Name 'Double-click launcher binds exact local GUI and system PowerShell paths'
    Assert-True -Condition ($launcherSource.Contains('-STA -ExecutionPolicy Bypass -File "%OCES_GUI%"') -and $launcherSource -notmatch '(?i)Set-ExecutionPolicy|\brunas\b|https?://') -Name 'Launcher bypass is process-scoped and cannot fetch or elevate code'

    $smokeState = Join-Path $testRoot 'smoke-missing-state'
    $hostExecutable = (Get-Process -Id $PID).Path
    $smokeOutput = (& $hostExecutable -NoLogo -NoProfile -Sta -ExecutionPolicy Bypass -File $guiEntryPoint -SmokeTest -StateDirectory $smokeState 2>&1 | Out-String).Trim()
    $smoke = $smokeOutput | ConvertFrom-Json
    Assert-True -Condition ($smoke.Loaded -and $smoke.PresentationSourceReady -and $smoke.InteractiveControls -eq 17 -and $smoke.MissingAccessibleNames -eq 0 -and $smoke.MissingAutomationPeerNames -eq 0) -Name 'Presented WPF view creates named automation peers for every interactive control'
    Assert-True -Condition ($smoke.ResultLiveSetting -eq 'Assertive') -Name 'Result heading is an assertive screen-reader live region'
    Assert-True -Condition ($smoke.ResultPanelShown -and $smoke.ResultHeadingFocusable -and -not [string]::IsNullOrWhiteSpace([string]$smoke.ResultHeadingPeerName)) -Name 'Rendered result view exposes a focusable named result heading'
    Assert-True -Condition (-not $smoke.ApprovalChecked -and -not $smoke.StartEnabled -and $smoke.CancelIsDefault) -Name 'Rendered approval view preserves default-deny keyboard behavior'
    Assert-True -Condition $smoke.PlanItemsWrappedAndConstrained -Name 'Rendered 520x320 approval plan wraps every item within its container'
    Assert-True -Condition ($smoke.PlanShown -and -not $smoke.UnapprovedWorkerStarted -and $smoke.EscapeHandled -and $smoke.HomeRestored) -Name 'Rendered install plan blocks unapproved work and routes Escape safely home'
    Assert-True -Condition (-not (Test-Path -LiteralPath $smokeState)) -Name 'Loading the GUI does not create its state directory'

    [xml]$settingsXaml = Get-Content -LiteralPath $settingsXamlPath -Raw -Encoding UTF8
    $settingsNamespaceManager = New-Object Xml.XmlNamespaceManager($settingsXaml.NameTable)
    $settingsNamespaceManager.AddNamespace('w', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation')
    $settingsNamespaceManager.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
    $settingsInteractiveNodes = @($settingsXaml.SelectNodes('//w:Button | //w:CheckBox | //w:TextBox | //w:ComboBox | //w:PasswordBox', $settingsNamespaceManager))
    Assert-Equal -Actual $settingsInteractiveNodes.Count -Expected 13 -Name 'Settings wizard exposes the reviewed interactive control count'
    Assert-True -Condition (@($settingsInteractiveNodes | Where-Object { [string]::IsNullOrWhiteSpace($_.TabIndex) }).Count -eq 0) -Name 'Every settings wizard control has an explicit tab index'
    Assert-True -Condition (@($settingsInteractiveNodes | Where-Object { [string]::IsNullOrWhiteSpace($_.'AutomationProperties.Name') }).Count -eq 0) -Name 'Every settings wizard control has an accessible name'
    $settingsTabIndices = @($settingsInteractiveNodes | ForEach-Object { [int]$_.TabIndex })
    Assert-Equal -Actual @($settingsTabIndices | Sort-Object -Unique).Count -Expected $settingsTabIndices.Count -Name 'Settings wizard tab indexes are unique'
    Assert-True -Condition ([int]$settingsXaml.Window.MinWidth -le 520 -and [int]$settingsXaml.Window.MinHeight -le 320 -and $null -ne $settingsXaml.SelectSingleNode('//w:ScrollViewer', $settingsNamespaceManager)) -Name 'Settings wizard fits constrained high-DPI desktops through its scrollable layout'

    $settingsGuiSource = Get-Content -LiteralPath $settingsGuiEntryPoint -Raw -Encoding UTF8
    Assert-True -Condition ($settingsGuiSource.Contains('.SecurePassword') -and $settingsGuiSource -notmatch '\.Password\b') -Name 'Settings wizard reads secrets only through SecureString password input'
    Assert-True -Condition ($settingsGuiSource -notmatch '(?i)-Verb\s+RunAs|\brunas\b') -Name 'Settings wizard never elevates the complete application'
    Assert-True -Condition ($settingsGuiSource.Contains('ApprovalDefault = $false') -and $settingsGuiSource.Contains('PlaintextSecretsWrittenToConfig')) -Name 'Settings wizard keeps approval default-deny and checks the no-plaintext result contract'
    Assert-True -Condition ($settingsGuiSource.Contains('PartialApplied = $false') -and $settingsGuiSource.Contains('OCES-SETTINGS-PARTIAL-042') -and $settingsGuiSource.Contains('$state.Plan = $null') -and $settingsGuiSource.Contains('RecoveryReceiptPath')) -Name 'Settings wizard reports partial application, preserves recovery data, and blocks blind re-apply in the same session'
    $recoveryStartupIndex = $settingsGuiSource.IndexOf('$recoveryInitializationError = $false', [StringComparison]::Ordinal)
    $recoveryStartupReadIndex = $settingsGuiSource.IndexOf('Get-OpenClawSafeSetupPendingRecovery', $recoveryStartupIndex, [StringComparison]::Ordinal)
    $catalogReadIndex = $settingsGuiSource.IndexOf('Get-OpenClawSafeSetupCatalog', $recoveryStartupIndex, [StringComparison]::Ordinal)
    Assert-True -Condition ($recoveryStartupIndex -ge 0 -and $recoveryStartupReadIndex -gt $recoveryStartupIndex -and $recoveryStartupReadIndex -lt $catalogReadIndex) -Name 'Settings startup reads and guards pending recovery before offering a new catalog workflow'
    $previewHandlerIndex = $settingsGuiSource.IndexOf("`$controls['PreviewButton'].add_Click", [StringComparison]::Ordinal)
    $previewRecoveryIndex = $settingsGuiSource.IndexOf('Invoke-OpenClawSafeSetupRecoveryVerification', $previewHandlerIndex, [StringComparison]::Ordinal)
    $previewInputValidationIndex = $settingsGuiSource.IndexOf('if (-not (Test-SettingsInputsValid))', $previewHandlerIndex, [StringComparison]::Ordinal)
    Assert-True -Condition ($previewHandlerIndex -ge 0 -and $previewRecoveryIndex -gt $previewHandlerIndex -and $previewRecoveryIndex -lt $previewInputValidationIndex) -Name 'Pending recovery recheck runs before normal secret validation or new-plan preview logic'
    $previewRecoverySource = $settingsGuiSource.Substring($previewHandlerIndex, $previewInputValidationIndex - $previewHandlerIndex)
    Assert-True -Condition (-not $previewRecoverySource.Contains('-EnsureGatewayService') -and -not $previewRecoverySource.Contains('-CredentialMap') -and -not $previewRecoverySource.Contains('-AcceptConfigChange')) -Name 'Unapproved pending recheck cannot restart the Gateway, replace credentials, or accept config drift'
    $applyHandlerIndex = $settingsGuiSource.IndexOf("`$controls['ApplyButton'].add_Click", [StringComparison]::Ordinal)
    $normalApplyGuardIndex = $settingsGuiSource.IndexOf('if ($null -eq $state.Plan', $applyHandlerIndex, [StringComparison]::Ordinal)
    $recoveryApplySource = $settingsGuiSource.Substring($applyHandlerIndex, $normalApplyGuardIndex - $applyHandlerIndex)
    Assert-True -Condition ($recoveryApplySource.Contains('-CredentialMap $recoveryCredentialMap') -and $recoveryApplySource.Contains('-AcceptConfigChange:$acceptConfigChange') -and $recoveryApplySource.Contains('-EnsureGatewayService') -and $recoveryApplySource.Contains('$replaceRecoverySecrets = $credentialReplacementRequired -or $anyRecoverySecret') -and -not $recoveryApplySource.Contains('New-OpenClawGatewayToken')) -Name 'Approved recovery can restart, restore the approved patch after drift, and replace model/channel secrets without rotating the Gateway token'
    Assert-True -Condition ($settingsGuiSource.Contains('Configuration drift recovery authorization') -and $settingsGuiSource.Contains('PendingDriftRestoreAvailable') -and $settingsGuiSource.Contains('$state.AcceptConfigChangeRequired')) -Name 'Drift consent is wired to fingerprint-bound Easy Setup patch restoration'
    Assert-True -Condition ($settingsGuiSource.Contains("'Credential replacement pending'") -and $settingsGuiSource.Contains("'Credential replacement recovery'") -and $settingsGuiSource.Contains('$state.CredentialReplacementRequired')) -Name 'Interrupted credential replacement is a distinct durable GUI recovery requirement'
    Assert-True -Condition ($settingsGuiSource.Contains("@('ProviderComboBox', 'ModelComboBox', 'TelegramCheckBox', 'DiscordCheckBox')") -and $settingsGuiSource.Contains("`$controls[`$controlName].IsEnabled = `$false")) -Name 'Receipt-bound provider, model, and channel selections are explicitly locked in recovery mode'
    Assert-True -Condition ($settingsGuiSource.Contains('$process.WaitForExit()') -and $settingsGuiSource.Contains('$state.ExitCode = if ($state.PartialApplied) { 42 } else { 0 }')) -Name 'Advanced setup waits for its real result and cannot erase partial-apply failure state'

    $settingsDescribeOutput = (& $hostExecutable -NoLogo -NoProfile -Sta -ExecutionPolicy Bypass -File $settingsGuiEntryPoint -Describe 2>&1 | Out-String).Trim()
    $settingsDescribe = $settingsDescribeOutput | ConvertFrom-Json
    Assert-True -Condition ($settingsDescribe.Version -eq '0.4.0' -and $settingsDescribe.ModuleImported) -Name 'Settings wizard describe mode loads the 0.4 module contract'

    $settingsSmokeState = Join-Path $testRoot 'settings-smoke-missing-state'
    $settingsSmokeOutput = (& $hostExecutable -NoLogo -NoProfile -Sta -ExecutionPolicy Bypass -File $settingsGuiEntryPoint -SmokeTest -StateDirectory $settingsSmokeState 2>&1 | Out-String).Trim()
    $settingsSmoke = $settingsSmokeOutput | ConvertFrom-Json
    Assert-True -Condition ($settingsSmoke.Loaded -and $settingsSmoke.ModuleImported -and $settingsSmoke.InteractiveControls -eq 13 -and $settingsSmoke.MissingAccessibleNames -eq 0 -and $settingsSmoke.MissingTabIndexes -eq 0) -Name 'Rendered settings wizard exposes all reviewed accessible controls'
    Assert-True -Condition ($settingsSmoke.ApprovalDefaultOff -and $settingsSmoke.ApplyDefaultDisabled -and $settingsSmoke.CancelIsDefault) -Name 'Rendered settings wizard preserves default-deny keyboard behavior'
    Assert-True -Condition ($settingsSmoke.PendingSelectionLocked -and $settingsSmoke.PendingSecretReplacementAvailable -and $settingsSmoke.PendingReadOnlyRecheckEnabled -and $settingsSmoke.PendingRestartRequiresApproval) -Name 'Rendered pending recovery locks receipt selections and separates read-only recheck from approved restart/replacement'
    Assert-True -Condition $settingsSmoke.PendingDriftRestoreAvailable -Name 'Rendered drift recovery exposes explicit approved-patch restoration consent'
    Assert-True -Condition $settingsSmoke.PendingCredentialReplacementRequired -Name 'Rendered interrupted credential replacement requires the complete receipt-bound secret set, including during drift restoration'
    Assert-True -Condition ($settingsSmoke.ExternalApiCalls -eq 0 -and $settingsSmoke.SecretsCleared) -Name 'Settings smoke test makes no external calls and clears secret inputs'
    Assert-True -Condition (-not (Test-Path -LiteralPath $settingsSmokeState)) -Name 'Loading the settings wizard does not create its state directory'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedTestRoot = (Resolve-Path -LiteralPath $testRoot).Path
        $expectedPrefix = ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.tmp-gui-')))
        if (-not $resolvedTestRoot.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing to clean a GUI test directory outside the expected test prefix.'
        }
        $cleanupError = $null
        for ($cleanupAttempt = 0; $cleanupAttempt -lt 20; $cleanupAttempt++) {
            try {
                Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction Stop
                $cleanupError = $null
                break
            }
            catch {
                $cleanupError = $_
                [Threading.Thread]::Sleep(100)
            }
        }
        if (Test-Path -LiteralPath $resolvedTestRoot) {
            throw "GUI test cleanup failed for the validated temporary root: $($cleanupError.Exception.Message)"
        }
    }
}

Write-Host ''
Write-Host ("GUI tests passed: {0}; failed: {1}" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) {
    exit 1
}
