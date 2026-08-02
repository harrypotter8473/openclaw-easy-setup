Set-StrictMode -Version Latest

$script:GuiVersion = '0.3.0'
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:EngineModulePath = Join-Path $PSScriptRoot 'OpenClawEasySetup.psm1'
$script:EntryPointPath = Join-Path $script:ProjectRoot 'OpenClawEasySetup.ps1'
$script:LocalePath = Join-Path $script:ProjectRoot 'locales\ko-KR.json'
$script:GuiStageIds = @('diagnose', 'node', 'download', 'integrity', 'dryRun', 'install', 'onboard', 'verify')

if (-not (Test-Path -LiteralPath $script:EngineModulePath -PathType Leaf)) {
    throw "OpenClaw engine module was not found: $script:EngineModulePath"
}
Import-Module -Name $script:EngineModulePath -Force -ErrorAction Stop

function Get-OpenClawGuiMessages {
    [CmdletBinding()]
    param()

    $messages = Get-Content -LiteralPath $script:LocalePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $messages.PSObject.Properties['gui']) {
        throw 'The Korean GUI message catalog was missing.'
    }
    return $messages
}

function Get-OpenClawGuiDefinition {
    [CmdletBinding()]
    param()

    $messages = Get-OpenClawGuiMessages
    $gui = $messages.gui
    $actions = @(
        [pscustomobject]@{ Id = 'Diagnose'; Label = [string]$gui.actions.diagnose; Description = [string]$gui.actionDescriptions.diagnose; ChangesPC = $false; RequiresApproval = $false; Shortcut = 'Alt+D' }
        [pscustomobject]@{ Id = 'Install'; Label = [string]$gui.actions.install; Description = [string]$gui.actionDescriptions.install; ChangesPC = $true; RequiresApproval = $true; Shortcut = 'Alt+I' }
        [pscustomobject]@{ Id = 'Resume'; Label = [string]$gui.actions.resume; Description = [string]$gui.actionDescriptions.resume; ChangesPC = $true; RequiresApproval = $true; Shortcut = 'Alt+R' }
        [pscustomobject]@{ Id = 'Configure'; Label = [string]$gui.actions.configure; Description = [string]$gui.actionDescriptions.configure; ChangesPC = $true; RequiresApproval = $true; Shortcut = 'Alt+C' }
        [pscustomobject]@{ Id = 'Verify'; Label = [string]$gui.actions.verify; Description = [string]$gui.actionDescriptions.verify; ChangesPC = $false; RequiresApproval = $false; Shortcut = 'Alt+V' }
        [pscustomobject]@{ Id = 'Bundle'; Label = [string]$gui.actions.bundle; Description = [string]$gui.actionDescriptions.bundle; ChangesPC = $true; RequiresApproval = $false; Shortcut = 'Alt+B' }
    )
    $stages = foreach ($stageId in $script:GuiStageIds) {
        [pscustomobject]@{
            Id = $stageId
            Label = [string]$gui.stages.$stageId
        }
    }
    return [pscustomobject]@{
        SchemaVersion = 1
        Version = $script:GuiVersion
        Language = 'ko-KR'
        Title = [string]$messages.title
        Subtitle = [string]$gui.subtitle
        Actions = $actions
        Stages = @($stages)
        Approval = [pscustomobject]@{
            DefaultApproved = $false
            StartIsDefaultButton = $false
            CancelIsDefaultButton = $true
            Text = [string]$gui.approvalText
        }
        Accessibility = [pscustomobject]@{
            KeyboardNavigation = $true
            ScreenReaderNames = $true
            UsesSystemColors = $true
            StatusUsesText = $true
            DpiAwareLayout = $true
        }
    }
}

function Get-OpenClawGuiInstallPlan {
    [CmdletBinding()]
    param()

    return @(Get-OpenClawInstallPlan)
}

function Get-OpenClawGuiPlanFingerprint {
    [CmdletBinding()]
    param(
        [ValidateSet('Install', 'Resume')]
        [string]$Action = 'Install'
    )

    return Get-OpenClawPlanFingerprint -Mode $Action
}

function Get-OpenClawGuiPlanSnapshot {
    [CmdletBinding()]
    param(
        [ValidateSet('Install', 'Resume')]
        [string]$Action = 'Install'
    )

    $fingerprintBefore = Get-OpenClawPlanFingerprint -Mode $Action
    $plan = @(Get-OpenClawInstallPlan)
    $fingerprintAfter = Get-OpenClawPlanFingerprint -Mode $Action
    if (-not [string]::Equals($fingerprintBefore, $fingerprintAfter, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The installation plan changed while the approval view was being prepared.'
    }
    return [pscustomobject]@{
        Plan = $plan
        Fingerprint = $fingerprintAfter
    }
}

function Get-OpenClawGuiReadiness {
    [CmdletBinding()]
    param()

    return @(Get-OpenClawReadiness)
}

function New-OpenClawGuiCancellationPath {
    [CmdletBinding()]
    param(
        [string]$StateDirectory
    )

    return New-OpenClawCancellationPath -StateDirectory $StateDirectory
}

function Request-OpenClawGuiCancellation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [string]$StateDirectory
    )

    return Request-OpenClawCancellation -Path $Path -StateDirectory $StateDirectory
}

function Remove-OpenClawGuiCancellationSignal {
    [CmdletBinding()]
    param(
        [string]$Path,
        [string]$StateDirectory
    )

    return Remove-OpenClawCancellationSignal -Path $Path -StateDirectory $StateDirectory
}

function Get-OpenClawGuiStateRoot {
    [CmdletBinding()]
    param(
        [string]$StateDirectory
    )

    if ([string]::IsNullOrWhiteSpace($StateDirectory)) {
        $localApplicationData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        if ([string]::IsNullOrWhiteSpace($localApplicationData)) {
            throw 'The current user LocalApplicationData directory could not be determined.'
        }
        $StateDirectory = Join-Path $localApplicationData 'OpenClawEasySetup'
    }
    return [IO.Path]::GetFullPath($StateDirectory)
}

function Get-OpenClawGuiResumeState {
    [CmdletBinding()]
    param(
        [string]$StateDirectory,
        [switch]$IncludeCompleted
    )

    $root = Get-OpenClawGuiStateRoot -StateDirectory $StateDirectory
    $emptyResult = [ordered]@{
        Available = $false
        CompletedBarrier = $false
        Invalid = $false
        ErrorId = ''
        Root = $root
        Checkpoint = $null
        NextStage = ''
    }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        return [pscustomobject]$emptyResult
    }
    try {
        $rootItem = Get-Item -LiteralPath $root -Force
        if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The state root was a reparse point.'
        }
        $markerPath = Join-Path $root '.openclaw-easy-setup-state'
        $statePath = Join-Path $root 'State'
        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf) -or -not (Test-Path -LiteralPath $statePath -PathType Container)) {
            throw 'The state root marker or checkpoint directory was missing.'
        }
        $marker = Get-Item -LiteralPath $markerPath -Force
        $stateItem = Get-Item -LiteralPath $statePath -Force
        if (($marker.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or ($stateItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $marker.Length -gt 128) {
            throw 'The state root layout was unsafe.'
        }
        if ((Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8).Trim() -ne 'OpenClawEasySetup-State-v1') {
            throw 'The state root marker was invalid.'
        }
        $candidates = @(Get-ChildItem -LiteralPath $statePath -Filter '*.json' -File |
            Where-Object BaseName -Match '^[A-Fa-f0-9]{32}$' |
            Sort-Object LastWriteTimeUtc -Descending)
        if ($candidates.Count -eq 0) {
            return [pscustomobject]$emptyResult
        }
        $config = Get-OpenClawSourceConfig
        $sourceConfigPath = Join-Path $script:ProjectRoot 'config\openclaw-source.json'
        $sourceFingerprint = (Get-FileHash -LiteralPath $sourceConfigPath -Algorithm SHA256).Hash.ToUpperInvariant()
        $checkpoint = Read-OpenClawCheckpoint -Path $candidates[0].FullName -ExpectedTargetVersion ([string]$config.openClaw.version) -ExpectedSourceFingerprint $sourceFingerprint
        $completed = $checkpoint.Status -eq 'Completed'
        $nextStage = @($checkpoint.Steps | Where-Object Status -notin @('Succeeded', 'Skipped') | Select-Object -First 1)
        return [pscustomobject]@{
            Available = (-not $completed)
            CompletedBarrier = $completed
            Invalid = $false
            ErrorId = ''
            Root = $root
            Checkpoint = $(if ($IncludeCompleted -or -not $completed) { $checkpoint } else { $null })
            NextStage = $(if ($nextStage.Count -eq 1) { [string]$nextStage[0].Id } else { '' })
        }
    }
    catch {
        return [pscustomobject]@{
            Available = $false
            CompletedBarrier = $false
            Invalid = $true
            ErrorId = 'OCES-RESUME-001'
            Root = $root
            Checkpoint = $null
            NextStage = ''
        }
    }
}

function Get-OpenClawGuiProgress {
    [CmdletBinding()]
    param(
        [object]$Checkpoint
    )

    $messages = Get-OpenClawGuiMessages
    $gui = $messages.gui
    $stages = New-Object System.Collections.Generic.List[object]
    $completedCount = 0
    $currentStage = ''
    foreach ($stageId in $script:GuiStageIds) {
        $checkpointStage = @()
        if ($null -ne $Checkpoint) {
            $checkpointStage = @($Checkpoint.Steps | Where-Object Id -eq $stageId)
        }
        $status = if ($checkpointStage.Count -eq 1) { [string]$checkpointStage[0].Status } else { 'Pending' }
        $detail = if ($checkpointStage.Count -eq 1) { Protect-OpenClawLogText -Text ([string]$checkpointStage[0].Detail) } else { '' }
        if ($status -in @('Succeeded', 'Skipped')) {
            $completedCount++
        }
        if ([string]::IsNullOrWhiteSpace($currentStage) -and $status -in @('Running', 'Failed', 'Pending')) {
            $currentStage = $stageId
        }
        $stages.Add([pscustomobject]@{
            Id = $stageId
            Label = [string]$gui.stages.$stageId
            Status = $status
            StatusLabel = [string]$gui.stageStatus.$status
            Detail = $detail
        })
    }
    return [pscustomobject]@{
        Percent = [int][Math]::Floor(($completedCount / [double]$script:GuiStageIds.Count) * 100)
        IsIndeterminate = @($stages | Where-Object Status -eq 'Running').Count -gt 0
        CurrentStage = $currentStage
        Stages = $stages.ToArray()
    }
}

function Select-OpenClawGuiProgressCheckpoint {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Checkpoint,

        [string]$Action,
        [string]$StartedAtUtc
    )

    if ($null -eq $Checkpoint -or $Action -ne 'Install') {
        return $Checkpoint
    }
    if ([string]::IsNullOrWhiteSpace($StartedAtUtc) -or $null -eq $Checkpoint.PSObject.Properties['CreatedAtUtc']) {
        return $null
    }
    try {
        $started = [DateTimeOffset]::Parse($StartedAtUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        $created = [DateTimeOffset]::Parse([string]$Checkpoint.CreatedAtUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    }
    catch {
        return $null
    }
    if ($created -lt $started.AddSeconds(-2)) {
        return $null
    }
    return $Checkpoint
}

function ConvertTo-OpenClawWindowsArgument {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Argument
    )

    if ($null -eq $Argument) {
        $Argument = ''
    }
    if ($Argument.Length -gt 32760) {
        throw 'A worker argument exceeded the supported length.'
    }
    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') {
        return $Argument
    }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append([char]34)
    $backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashes++
            continue
        }
        if ($character -eq [char]34) {
            if ($backslashes -gt 0) {
                [void]$builder.Append([char]92, ($backslashes * 2))
            }
            [void]$builder.Append([char]92)
            [void]$builder.Append([char]34)
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append([char]92, $backslashes)
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append([char]92, ($backslashes * 2))
    }
    [void]$builder.Append([char]34)
    return $builder.ToString()
}

function Protect-OpenClawGuiOutput {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Text
    )

    if ($null -eq $Text) {
        return ''
    }
    $safeLines = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(([string]$Text) -split '\r?\n' | Select-Object -First 120)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $safeLines.Add((Protect-OpenClawLogText -Text $line -MaximumLength 512))
    }
    $safeOutput = $safeLines.ToArray() -join [Environment]::NewLine
    if ($safeOutput.Length -gt 16384) {
        $safeOutput = $safeOutput.Substring(0, 16384) + ' [TRUNCATED]'
    }
    return $safeOutput
}

function Get-OpenClawWindowsPowerShellPath {
    [CmdletBinding()]
    param()

    $systemDirectory = [Environment]::SystemDirectory
    if ([string]::IsNullOrWhiteSpace($systemDirectory)) {
        throw 'The Windows system directory could not be determined.'
    }
    $path = [IO.Path]::GetFullPath((Join-Path $systemDirectory 'WindowsPowerShell\v1.0\powershell.exe'))
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'Windows PowerShell 5.1 was not found at the trusted system path.'
    }
    $item = Get-Item -LiteralPath $path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The Windows PowerShell executable was a reparse point.'
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $path
    if ($signature.Status -ne 'Valid') {
        throw "The Windows PowerShell executable signature was not valid: $($signature.Status)"
    }
    if ($null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch '(?i)(?:^|,\s*)O=Microsoft Corporation(?:,|$)') {
        throw 'The Windows PowerShell executable was not signed by Microsoft Corporation.'
    }
    return $path
}

function New-OpenClawGuiWorkerInvocation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Diagnose', 'Install', 'Resume', 'Configure', 'Verify', 'Bundle')]
        [string]$Action,

        [switch]$Approved,
        [string]$StateDirectory,
        [string]$DiagnosticOutputPath,
        [string]$CancellationPath,
        [string]$PlanFingerprint
    )

    if ($Action -in @('Install', 'Resume', 'Configure') -and -not $Approved) {
        throw 'A mutating GUI action requires explicit approval.'
    }
    if ($Action -in @('Install', 'Resume') -and $PlanFingerprint -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'The approved installation plan fingerprint was missing or invalid.'
    }
    if ($Action -eq 'Bundle' -and [string]::IsNullOrWhiteSpace($DiagnosticOutputPath)) {
        throw 'The diagnostic bundle destination was not selected.'
    }

    $interactive = $Action -eq 'Configure'
    $arguments = New-Object System.Collections.Generic.List[string]
    foreach ($argument in @('-NoLogo', '-NoProfile')) {
        $arguments.Add($argument)
    }
    if (-not $interactive) {
        $arguments.Add('-NonInteractive')
    }
    foreach ($argument in @('-File', $script:EntryPointPath, '-Action', $(if ($Action -eq 'Resume') { 'Install' } else { $Action }))) {
        $arguments.Add([string]$argument)
    }

    if ($Action -eq 'Diagnose') {
        $arguments.Add('-GuiOutput')
    }

    if ($Action -in @('Install', 'Resume')) {
        foreach ($argument in @('-Apply', '-SkipOnboarding', '-GuiApproved', '-ExpectedPlanFingerprint', $PlanFingerprint.ToUpperInvariant())) {
            $arguments.Add([string]$argument)
        }
        if ($Action -eq 'Resume') {
            $arguments.Add('-Resume')
        }
        if (-not [string]::IsNullOrWhiteSpace($CancellationPath)) {
            foreach ($argument in @('-CancellationPath', [IO.Path]::GetFullPath($CancellationPath))) {
                $arguments.Add([string]$argument)
            }
        }
    }
    elseif ($Action -eq 'Configure') {
        foreach ($argument in @('-Apply', '-GuiApproved')) {
            $arguments.Add($argument)
        }
    }
    elseif ($Action -eq 'Bundle') {
        $destination = [IO.Path]::GetFullPath($DiagnosticOutputPath)
        if ([IO.Path]::GetExtension($destination) -ne '.zip') {
            throw 'The diagnostic bundle destination must use the .zip extension.'
        }
        foreach ($argument in @('-DiagnosticOutputPath', $destination)) {
            $arguments.Add([string]$argument)
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($StateDirectory)) {
        foreach ($argument in @('-StateDirectory', [IO.Path]::GetFullPath($StateDirectory))) {
            $arguments.Add([string]$argument)
        }
    }

    $powerShellPath = Get-OpenClawWindowsPowerShellPath
    $quotedArguments = @($arguments.ToArray() | ForEach-Object { ConvertTo-OpenClawWindowsArgument -Argument $_ })
    return [pscustomobject]@{
        Action = $Action
        FileName = $powerShellPath
        ArgumentList = $arguments.ToArray()
        Arguments = $quotedArguments -join ' '
        WorkingDirectory = $script:ProjectRoot
        UseShellExecute = $interactive
        CreateNoWindow = (-not $interactive)
        WindowStyle = $(if ($interactive) { 'Normal' } else { 'Hidden' })
        ChangesPC = $Action -in @('Install', 'Resume', 'Configure', 'Bundle')
        CooperativeCancellation = $Action -in @('Install', 'Resume')
    }
}

function New-OpenClawGuiProcessStartInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Invocation
    )

    $trustedPowerShell = Get-OpenClawWindowsPowerShellPath
    if (-not [string]::Equals([IO.Path]::GetFullPath([string]$Invocation.FileName), $trustedPowerShell, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The GUI worker executable did not match the trusted Windows PowerShell path.'
    }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $trustedPowerShell
    $startInfo.Arguments = [string]$Invocation.Arguments
    $startInfo.WorkingDirectory = [IO.Path]::GetFullPath([string]$Invocation.WorkingDirectory)
    $startInfo.UseShellExecute = [bool]$Invocation.UseShellExecute
    $startInfo.CreateNoWindow = [bool]$Invocation.CreateNoWindow
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]([Enum]::Parse([Diagnostics.ProcessWindowStyle], [string]$Invocation.WindowStyle, $true))
    if ([string]$Invocation.Action -eq 'Diagnose') {
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
        $startInfo.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    }
    return $startInfo
}

function Get-OpenClawGuiLatestLogPath {
    [CmdletBinding()]
    param(
        [string]$StateDirectory,
        [string]$NotBeforeUtc
    )

    $logsPath = Join-Path (Get-OpenClawGuiStateRoot -StateDirectory $StateDirectory) 'Logs'
    if (-not (Test-Path -LiteralPath $logsPath -PathType Container)) {
        return ''
    }
    $item = Get-Item -LiteralPath $logsPath -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        return ''
    }
    $minimumTimestamp = [DateTime]::MinValue
    if (-not [string]::IsNullOrWhiteSpace($NotBeforeUtc)) {
        $parsedTimestamp = [DateTime]::MinValue
        if (-not [DateTime]::TryParse($NotBeforeUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsedTimestamp)) {
            return ''
        }
        $minimumTimestamp = $parsedTimestamp.ToUniversalTime().AddSeconds(-2)
    }
    $latest = Get-ChildItem -LiteralPath $logsPath -Filter '*.jsonl' -File |
        Where-Object { $_.BaseName -match '^[A-Fa-f0-9]{32}$' -and $_.LastWriteTimeUtc -ge $minimumTimestamp } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    return $(if ($null -eq $latest) { '' } else { $latest.FullName })
}

function Get-OpenClawGuiResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$ExitCode,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Diagnose', 'Install', 'Resume', 'Configure', 'Verify', 'Bundle')]
        [string]$Action,

        [string]$StateDirectory,
        [string]$OutputPath,
        [string]$SafeOutput,
        [string]$StartedAtUtc
    )

    $kindByExitCode = @{
        0 = 'Success'; 10 = 'Warning'; 20 = 'Diagnose'; 30 = 'Download'; 31 = 'Integrity';
        40 = 'Prerequisite'; 41 = 'Install'; 42 = 'Configure'; 50 = 'Verify'; 60 = 'Resume';
        61 = 'Cancelled'; 70 = 'Bundle'; 99 = 'Unexpected'
    }
    $kind = if ($kindByExitCode.ContainsKey($ExitCode)) { $kindByExitCode[$ExitCode] } else { 'Unexpected' }
    $definition = Get-OpenClawExitCodeDefinition -Kind $kind
    $logPath = if ($Action -in @('Install', 'Resume', 'Configure') -and -not [string]::IsNullOrWhiteSpace($StartedAtUtc)) {
        Get-OpenClawGuiLatestLogPath -StateDirectory $StateDirectory -NotBeforeUtc $StartedAtUtc
    }
    else {
        ''
    }
    return [pscustomobject]@{
        Action = $Action
        Status = $(if ($ExitCode -eq 0) { 'Succeeded' } elseif ($ExitCode -eq 61) { 'Cancelled' } else { 'Failed' })
        ExitCode = $ExitCode
        ErrorId = [string]$definition.Id
        Message = [string]$definition.Message
        Guidance = [string]$definition.Guidance
        LogPath = $logPath
        OutputPath = $OutputPath
        SafeOutput = Protect-OpenClawGuiOutput -Text $SafeOutput
        AutomaticUpload = $false
    }
}

function Get-OpenClawGuiPrimaryAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Succeeded', 'Cancelled', 'Failed')]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Diagnose', 'Install', 'Resume', 'Configure', 'Verify', 'Bundle')]
        [string]$CompletedAction,

        [switch]$ResumeAvailable
    )

    $messages = Get-OpenClawGuiMessages
    $gui = $messages.gui
    if ($Status -eq 'Succeeded' -and $CompletedAction -in @('Install', 'Resume')) {
        return [pscustomobject]@{ Id = 'Configure'; Label = [string]$gui.configureNext }
    }
    if ($Status -eq 'Succeeded' -and $CompletedAction -eq 'Configure') {
        return [pscustomobject]@{ Id = 'Verify'; Label = [string]$gui.verifyNext }
    }
    if ($Status -eq 'Cancelled' -and $CompletedAction -in @('Install', 'Resume') -and $ResumeAvailable) {
        return [pscustomobject]@{ Id = 'Resume'; Label = [string]$gui.actions.resume }
    }
    return [pscustomobject]@{ Id = 'Home'; Label = [string]$gui.home }
}

Export-ModuleMember -Function @(
    'Get-OpenClawGuiMessages',
    'Get-OpenClawGuiDefinition',
    'Get-OpenClawGuiInstallPlan',
    'Get-OpenClawGuiPlanFingerprint',
    'Get-OpenClawGuiPlanSnapshot',
    'Get-OpenClawGuiReadiness',
    'New-OpenClawGuiCancellationPath',
    'Request-OpenClawGuiCancellation',
    'Remove-OpenClawGuiCancellationSignal',
    'Get-OpenClawGuiStateRoot',
    'Get-OpenClawGuiResumeState',
    'Get-OpenClawGuiProgress',
    'Select-OpenClawGuiProgressCheckpoint',
    'ConvertTo-OpenClawWindowsArgument',
    'Protect-OpenClawGuiOutput',
    'Get-OpenClawWindowsPowerShellPath',
    'New-OpenClawGuiWorkerInvocation',
    'New-OpenClawGuiProcessStartInfo',
    'Get-OpenClawGuiLatestLogPath',
    'Get-OpenClawGuiResult',
    'Get-OpenClawGuiPrimaryAction'
)
