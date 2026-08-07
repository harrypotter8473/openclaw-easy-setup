[CmdletBinding()]
param(
    [string]$StateDirectory,
    [switch]$Describe,
    [switch]$SmokeTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$guiModulePath = Join-Path $PSScriptRoot 'src\OpenClawEasySetup.Gui.psm1'
$originalPSModulePath = $env:PSModulePath
try {
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        $builtInModulePath = [IO.Path]::GetFullPath([IO.Path]::Combine($PSHOME, 'Modules'))
        if (-not (Test-Path -LiteralPath $builtInModulePath -PathType Container)) {
            throw 'The trusted Windows PowerShell module directory was not found.'
        }
        $builtInModuleDirectory = Get-Item -LiteralPath $builtInModulePath -Force
        if (($builtInModuleDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The trusted Windows PowerShell module directory was a reparse point.'
        }
        [Environment]::SetEnvironmentVariable('PSModulePath', $builtInModulePath, 'Process')
        foreach ($builtInModuleName in @('Microsoft.PowerShell.Utility', 'Microsoft.PowerShell.Security')) {
            $builtInModuleManifest = [IO.Path]::Combine($builtInModulePath, $builtInModuleName, ($builtInModuleName + '.psd1'))
            if (-not (Test-Path -LiteralPath $builtInModuleManifest -PathType Leaf)) {
                throw "The trusted Windows PowerShell module manifest was not found: $builtInModuleName"
            }
            Import-Module -Name $builtInModuleManifest -Force -ErrorAction Stop
        }
    }
    Import-Module -Name $guiModulePath -Force -ErrorAction Stop
}
finally {
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        [Environment]::SetEnvironmentVariable('PSModulePath', $originalPSModulePath, 'Process')
    }
}

if ($Describe) {
    Get-OpenClawGuiDefinition | ConvertTo-Json -Depth 8
    return
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'OpenClaw Easy Setup GUI supports Windows only.'
}

if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
    $powerShellPath = Get-OpenClawWindowsPowerShellPath
    $arguments = New-Object System.Collections.Generic.List[string]
    foreach ($argument in @('-NoLogo', '-NoProfile', '-STA', '-File', $PSCommandPath)) {
        $arguments.Add([string]$argument)
    }
    if (-not [string]::IsNullOrWhiteSpace($StateDirectory)) {
        foreach ($argument in @('-StateDirectory', [IO.Path]::GetFullPath($StateDirectory))) {
            $arguments.Add([string]$argument)
        }
    }
    if ($SmokeTest) {
        $arguments.Add('-SmokeTest')
    }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powerShellPath
    $startInfo.Arguments = (@($arguments.ToArray() | ForEach-Object { ConvertTo-OpenClawWindowsArgument -Argument $_ }) -join ' ')
    $startInfo.WorkingDirectory = $PSScriptRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    [void][Diagnostics.Process]::Start($startInfo)
    return
}

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

$xamlPath = Join-Path $PSScriptRoot 'ui\MainWindow.xaml'
$xamlText = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
$xmlDocument = New-Object Xml.XmlDocument
$xmlDocument.PreserveWhitespace = $true
$xmlDocument.LoadXml($xamlText)
$xmlReader = New-Object Xml.XmlNodeReader($xmlDocument)
try {
    $window = [Windows.Markup.XamlReader]::Load($xmlReader)
}
finally {
    $xmlReader.Dispose()
}

$controlNames = @(
    'HeaderTitleText', 'HeaderSubtitleText', 'HeaderStatusText', 'MainScrollViewer',
    'HomePanel', 'HomeHeadingText', 'HomeDescriptionText',
    'DiagnoseButton', 'InstallButton', 'ResumeButton', 'ConfigureButton',
    'VerifyButton', 'BundleButton',
    'PlanPanel', 'PlanHeadingText', 'PlanDescriptionText', 'PlanItemsControl',
    'PlanApprovalGuidanceText', 'PlanApprovalCheckBox', 'PlanCancelButton', 'PlanStartButton',
    'WorkPanel', 'WorkHeadingText', 'WorkSummaryText', 'OverallProgressBar', 'WorkStageList',
    'WorkCancelGuidanceText', 'WorkCancelButton',
    'ResultPanel', 'ResultHeadingText', 'ResultSummaryText', 'ResultErrorPanel',
    'ResultErrorLabelText', 'ResultErrorCodeText', 'ResultGuidanceText',
    'ResultLogPanel', 'ResultLogGuidanceText', 'ResultLogPathTextBox', 'ResultOpenLogButton',
    'ResultBundlePanel', 'ResultBundleGuidanceText', 'ResultBundlePathTextBox',
    'ResultCreateBundleButton', 'ResultOpenBundleButton', 'ResultHomeButton', 'ResultPrimaryButton',
    'FooterStatusText'
)
$controls = @{}
foreach ($name in $controlNames) {
    $control = $window.FindName($name)
    if ($null -eq $control) {
        throw "Required GUI control was not found: $name"
    }
    $controls[$name] = $control
}

$stageControlNames = @{
    diagnose = @{ Status = 'DiagnoseStageStatusText'; Title = 'DiagnoseStageTitleText'; Detail = 'DiagnoseStageDetailText' }
    node = @{ Status = 'NodeStageStatusText'; Title = 'NodeStageTitleText'; Detail = 'NodeStageDetailText' }
    download = @{ Status = 'DownloadStageStatusText'; Title = 'DownloadStageTitleText'; Detail = 'DownloadStageDetailText' }
    integrity = @{ Status = 'IntegrityStageStatusText'; Title = 'IntegrityStageTitleText'; Detail = 'IntegrityStageDetailText' }
    dryRun = @{ Status = 'DryRunStageStatusText'; Title = 'DryRunStageTitleText'; Detail = 'DryRunStageDetailText' }
    install = @{ Status = 'InstallStageStatusText'; Title = 'InstallStageTitleText'; Detail = 'InstallStageDetailText' }
    onboard = @{ Status = 'OnboardStageStatusText'; Title = 'OnboardStageTitleText'; Detail = 'OnboardStageDetailText' }
    verify = @{ Status = 'VerifyStageStatusText'; Title = 'VerifyStageTitleText'; Detail = 'VerifyStageDetailText' }
}
foreach ($stage in $stageControlNames.Values) {
    foreach ($controlName in $stage.Values) {
        $control = $window.FindName([string]$controlName)
        if ($null -eq $control) {
            throw "Required GUI stage control was not found: $controlName"
        }
        $controls[[string]$controlName] = $control
    }
}

$catalog = Get-OpenClawGuiMessages
$gui = $catalog.gui
$definition = Get-OpenClawGuiDefinition
$state = @{
    Process = $null
    OutputTask = $null
    ErrorTask = $null
    StartedAtUtc = ''
    Action = ''
    CancellationPath = ''
    CancellationRequested = $false
    PlanAction = ''
    PlanFingerprint = ''
    BundleOutputPath = ''
    LastResult = $null
    PrimaryAction = 'Home'
    ClosingAllowed = $false
}

function Set-AccessibleText {
    param(
        [Parameter(Mandatory = $true)]
        [Windows.DependencyObject]$Control,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [string]$HelpText = ''
    )

    [Windows.Automation.AutomationProperties]::SetName($Control, $Name)
    if (-not [string]::IsNullOrWhiteSpace($HelpText)) {
        [Windows.Automation.AutomationProperties]::SetHelpText($Control, $HelpText)
    }
}

function Publish-AccessibleLiveRegionChange {
    param(
        [Parameter(Mandatory = $true)]
        [Windows.Controls.TextBlock]$Control
    )

    $peer = [Windows.Automation.Peers.UIElementAutomationPeer]::FromElement($Control)
    if ($null -eq $peer) {
        $peer = New-Object -TypeName Windows.Automation.Peers.TextBlockAutomationPeer -ArgumentList (,$Control)
    }
    $peer.RaiseAutomationEvent([Windows.Automation.Peers.AutomationEvents]::LiveRegionChanged)
}

function Show-GuiPage {
    param(
        [ValidateSet('Home', 'Plan', 'Work', 'Result')]
        [string]$Name
    )

    foreach ($pageName in @('Home', 'Plan', 'Work', 'Result')) {
        $controls["${pageName}Panel"].Visibility = if ($pageName -eq $Name) {
            [Windows.Visibility]::Visible
        }
        else {
            [Windows.Visibility]::Collapsed
        }
    }
    $controls['MainScrollViewer'].ScrollToTop()
}

function Set-HomeEnabled {
    param([bool]$Enabled)

    foreach ($buttonName in @('DiagnoseButton', 'InstallButton', 'ConfigureButton', 'VerifyButton', 'BundleButton')) {
        $controls[$buttonName].IsEnabled = $Enabled
    }
    if ($Enabled) {
        Update-ResumeState
    }
    else {
        $controls['ResumeButton'].IsEnabled = $false
    }
}

function Update-ResumeState {
    $resumeState = Get-OpenClawGuiResumeState -StateDirectory $StateDirectory
    if ($resumeState.Invalid) {
        $controls['ResumeButton'].IsEnabled = $false
        $controls['HeaderStatusText'].Text = [string]$gui.invalidResume
        $controls['FooterStatusText'].Text = ("{0}: {1}" -f $catalog.errorCode, $resumeState.ErrorId)
        return
    }
    $controls['ResumeButton'].IsEnabled = [bool]$resumeState.Available
    if ($resumeState.Available) {
        $controls['HeaderStatusText'].Text = [string]$gui.statusResumeAvailable
        $controls['FooterStatusText'].Text = [string]$catalog.resumeHint
    }
    else {
        $controls['HeaderStatusText'].Text = [string]$gui.statusReady
        $controls['FooterStatusText'].Text = [string]$gui.statusNoResume
    }
}

function Update-StageProgress {
    $resumeState = Get-OpenClawGuiResumeState -StateDirectory $StateDirectory -IncludeCompleted
    $checkpoint = if ($null -ne $resumeState.Checkpoint) { $resumeState.Checkpoint } else { $null }
    $checkpoint = Select-OpenClawGuiProgressCheckpoint -Checkpoint $checkpoint -Action ([string]$state.Action) -StartedAtUtc ([string]$state.StartedAtUtc)
    $progress = Get-OpenClawGuiProgress -Checkpoint $checkpoint
    $controls['OverallProgressBar'].IsIndeterminate = $false
    $controls['OverallProgressBar'].Value = $progress.Percent
    $symbols = @{ Pending = '[ ]'; Running = '[>]'; Succeeded = '[OK]'; Failed = '[!]'; Skipped = '[-]' }
    foreach ($stage in $progress.Stages) {
        $names = $stageControlNames[[string]$stage.Id]
        $statusText = "{0} {1}" -f $symbols[[string]$stage.Status], $stage.StatusLabel
        $controls[[string]$names.Status].Text = $statusText
        $controls[[string]$names.Title].Text = [string]$stage.Label
        $controls[[string]$names.Detail].Text = [string]$stage.Detail
        Set-AccessibleText -Control $controls[[string]$names.Status] -Name ("{0}, {1}" -f $stage.Label, $stage.StatusLabel)
    }
}

function Set-StaticStageProgress {
    param(
        [ValidateSet('Diagnose', 'Configure', 'Verify', 'Bundle')]
        [string]$Action
    )

    $activeStage = switch ($Action) {
        'Diagnose' { 'diagnose' }
        'Configure' { 'onboard' }
        'Verify' { 'verify' }
        default { '' }
    }
    $controls['OverallProgressBar'].Value = 0
    $controls['OverallProgressBar'].IsIndeterminate = $true
    $controls['WorkStageList'].Visibility = if ($Action -eq 'Bundle') { [Windows.Visibility]::Collapsed } else { [Windows.Visibility]::Visible }
    $pendingProgress = Get-OpenClawGuiProgress -Checkpoint $null
    foreach ($stage in $pendingProgress.Stages) {
        $names = $stageControlNames[[string]$stage.Id]
        $isActive = [string]$stage.Id -eq $activeStage
        $statusLabel = if ($isActive) { [string]$gui.stageStatus.Running } else { [string]$gui.stageStatus.Pending }
        $symbol = if ($isActive) { '[>]' } else { '[ ]' }
        $controls[[string]$names.Status].Text = ("{0} {1}" -f $symbol, $statusLabel)
        $controls[[string]$names.Title].Text = [string]$stage.Label
        $controls[[string]$names.Detail].Text = ''
        Set-AccessibleText -Control $controls[[string]$names.Status] -Name ("{0}, {1}" -f $stage.Label, $statusLabel)
    }
}

function Show-InstallPlan {
    param(
        [ValidateSet('Install', 'Resume')]
        [string]$Action
    )

    if ($Action -eq 'Resume') {
        $resumeState = Get-OpenClawGuiResumeState -StateDirectory $StateDirectory
        if (-not $resumeState.Available) {
            [void][Windows.MessageBox]::Show([string]$gui.noResume, [string]$catalog.title, [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Information)
            Update-ResumeState
            return
        }
    }
    $planSnapshot = Get-OpenClawGuiPlanSnapshot -Action $Action
    $planItems = New-Object System.Collections.Generic.List[string]
    foreach ($step in @($planSnapshot.Plan)) {
        $changeLabel = if ([bool]$step.ChangesPC) { [string]$catalog.mutationChange } else { [string]$catalog.mutationReadOnly }
        $planItems.Add(("{0}. [{1}] {2}`n{3}" -f $step.Order, $changeLabel, $step.Title, $step.Detail))
    }
    $state.PlanAction = $Action
    $state.PlanFingerprint = [string]$planSnapshot.Fingerprint
    $controls['PlanHeadingText'].Text = [string]$gui.planHeading
    $controls['PlanDescriptionText'].Text = if ($Action -eq 'Resume') { [string]$gui.planDescriptionResume } else { [string]$gui.planDescriptionInstall }
    $controls['PlanItemsControl'].ItemsSource = $planItems.ToArray()
    $controls['PlanApprovalCheckBox'].IsChecked = $false
    $controls['PlanStartButton'].IsEnabled = $false
    Show-GuiPage -Name Plan
    [void]$controls['PlanCancelButton'].Focus()
}

function Open-ContainingFolder {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }
    $windowsDirectory = Split-Path -Parent ([Environment]::SystemDirectory)
    $explorerPath = Join-Path $windowsDirectory 'explorer.exe'
    if (-not (Test-Path -LiteralPath $explorerPath -PathType Leaf)) {
        return
    }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $explorerPath
    $startInfo.Arguments = ('/select,{0}' -f (ConvertTo-OpenClawWindowsArgument -Argument ([IO.Path]::GetFullPath($Path))))
    $startInfo.UseShellExecute = $false
    [void][Diagnostics.Process]::Start($startInfo)
}

function Select-DiagnosticBundlePath {
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.Title = [string]$gui.bundleDialogTitle
    $dialog.FileName = [string]$gui.bundleFileName
    $dialog.Filter = [string]$gui.bundleFilter
    $dialog.AddExtension = $true
    $dialog.DefaultExt = '.zip'
    $dialog.CheckPathExists = $true
    $dialog.OverwritePrompt = $false
    $selected = $dialog.ShowDialog($window)
    if ($selected -ne $true) {
        return ''
    }
    $path = [IO.Path]::GetFullPath($dialog.FileName)
    if (Test-Path -LiteralPath $path) {
        [void][Windows.MessageBox]::Show([string]$gui.bundleExists, [string]$catalog.title, [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Information)
        return ''
    }
    return $path
}

function Start-GuiWorker {
    param(
        [ValidateSet('Diagnose', 'Install', 'Resume', 'Configure', 'Verify', 'Bundle')]
        [string]$Action,
        [bool]$Approved = $false,
        [string]$OutputPath = ''
    )

    if ($null -ne $state.Process -and -not $state.Process.HasExited) {
        return
    }
    $cancellationPath = ''
    if ($Action -in @('Install', 'Resume')) {
        $cancellationPath = New-OpenClawGuiCancellationPath -StateDirectory $StateDirectory
    }
    $parameters = @{
        Action = $Action
        StateDirectory = $StateDirectory
        DiagnosticOutputPath = $OutputPath
        CancellationPath = $cancellationPath
        PlanFingerprint = $state.PlanFingerprint
    }
    if ($Approved) {
        $parameters['Approved'] = $true
    }
    $invocation = New-OpenClawGuiWorkerInvocation @parameters
    $startInfo = New-OpenClawGuiProcessStartInfo -Invocation $invocation
    $state.StartedAtUtc = [DateTime]::UtcNow.ToString('o')
    $process = [Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process) {
        throw 'The OpenClaw GUI worker process did not start.'
    }
    $state.Process = $process
    $state.OutputTask = if ($startInfo.RedirectStandardOutput) { $process.StandardOutput.ReadToEndAsync() } else { $null }
    $state.ErrorTask = if ($startInfo.RedirectStandardError) { $process.StandardError.ReadToEndAsync() } else { $null }
    $state.Action = $Action
    $state.CancellationPath = $cancellationPath
    $state.CancellationRequested = $false
    $state.BundleOutputPath = $OutputPath
    $controls['HeaderStatusText'].Text = [string]$gui.statusBusy
    $controls['WorkHeadingText'].Text = [string]$gui.workHeading
    $controls['WorkSummaryText'].Text = if ($Action -eq 'Resume') {
        [string]$gui.workSummaryResume
    }
    elseif ($Action -in @('Install', 'Configure', 'Bundle')) {
        [string]$gui.workSummaryInstall
    }
    else {
        [string]$gui.workSummaryReadOnly
    }
    $controls['WorkCancelGuidanceText'].Text = [string]$gui.cancelGuidance
    $controls['WorkCancelButton'].Visibility = if ($Action -in @('Install', 'Resume')) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    $controls['WorkCancelButton'].IsEnabled = $Action -in @('Install', 'Resume')
    Set-HomeEnabled -Enabled $false
    if ($Action -in @('Install', 'Resume')) {
        $controls['WorkStageList'].Visibility = [Windows.Visibility]::Visible
        Update-StageProgress
    }
    else {
        Set-StaticStageProgress -Action $Action
    }
    Show-GuiPage -Name Work
    $workerTimer.Start()
}

function Show-WorkerResult {
    param([object]$Result)

    $state.LastResult = $Result
    $controls['ResultHeadingText'].Text = switch ($Result.Status) {
        'Succeeded' { [string]$gui.resultSuccessHeading }
        'Cancelled' { [string]$gui.resultCancelledHeading }
        default { [string]$gui.resultFailedHeading }
    }
    Set-AccessibleText -Control $controls['ResultHeadingText'] -Name ([string]$controls['ResultHeadingText'].Text)
    $summary = [string]$Result.Message
    if ($Result.Action -eq 'Diagnose' -and -not [string]::IsNullOrWhiteSpace([string]$Result.SafeOutput)) {
        $summary = if ($Result.Status -eq 'Succeeded') {
            [string]$Result.SafeOutput
        }
        else {
            "{0}{1}{1}{2}" -f $Result.Message, [Environment]::NewLine, $Result.SafeOutput
        }
    }
    elseif ($Result.Status -eq 'Succeeded' -and $Result.Action -eq 'Bundle') {
        $summary = [string]$gui.bundleNotUploaded
    }
    $controls['ResultSummaryText'].Text = $summary
    $controls['ResultErrorLabelText'].Text = [string]$gui.errorLabel
    $controls['ResultErrorCodeText'].Text = ("{0} (exit {1})" -f $Result.ErrorId, $Result.ExitCode)
    $controls['ResultGuidanceText'].Text = [string]$Result.Guidance
    $controls['ResultLogGuidanceText'].Text = [string]$gui.logGuidance
    $controls['ResultLogPathTextBox'].Text = [string]$Result.LogPath
    $controls['ResultOpenLogButton'].IsEnabled = -not [string]::IsNullOrWhiteSpace([string]$Result.LogPath)
    $controls['ResultBundleGuidanceText'].Text = [string]$gui.bundleGuidance
    $controls['ResultBundlePathTextBox'].Text = [string]$Result.OutputPath
    $controls['ResultOpenBundleButton'].IsEnabled = -not [string]::IsNullOrWhiteSpace([string]$Result.OutputPath) -and (Test-Path -LiteralPath ([string]$Result.OutputPath) -PathType Leaf)
    $resumeState = Get-OpenClawGuiResumeState -StateDirectory $StateDirectory
    $primaryAction = Get-OpenClawGuiPrimaryAction -Status ([string]$Result.Status) -CompletedAction ([string]$Result.Action) -ResumeAvailable:([bool]$resumeState.Available)
    $state.PrimaryAction = [string]$primaryAction.Id
    $controls['ResultPrimaryButton'].Content = [string]$primaryAction.Label
    Set-AccessibleText -Control $controls['ResultPrimaryButton'] -Name ([string]$controls['ResultPrimaryButton'].Content)
    $controls['FooterStatusText'].Text = if ($Result.AutomaticUpload) { '' } else { [string]$catalog.bundleNotUploaded }
    Set-HomeEnabled -Enabled $true
    Show-GuiPage -Name Result
    $controls['ResultHeadingText'].Focusable = $true
    [void]$controls['ResultHeadingText'].Focus()
    Publish-AccessibleLiveRegionChange -Control $controls['ResultHeadingText']
}

function Complete-GuiWorker {
    $process = $state.Process
    if ($null -eq $process -or -not $process.HasExited) {
        return
    }
    $workerTimer.Stop()
    $process.WaitForExit()
    $exitCode = $process.ExitCode
    $safeOutput = ''
    if ($null -ne $state.OutputTask) {
        try {
            $safeOutput = Protect-OpenClawGuiOutput -Text ([string]$state.OutputTask.Result)
        }
        catch {
            $safeOutput = ''
        }
    }
    if ($null -ne $state.ErrorTask) {
        try {
            [void]$state.ErrorTask.Result
        }
        catch {
            # Stable error codes and sanitized logs take precedence over raw stderr.
        }
    }
    $process.Dispose()
    $action = [string]$state.Action
    $outputPath = [string]$state.BundleOutputPath
    $cancellationPath = [string]$state.CancellationPath
    $startedAtUtc = [string]$state.StartedAtUtc
    $state.Process = $null
    $state.OutputTask = $null
    $state.ErrorTask = $null
    $state.StartedAtUtc = ''
    $state.Action = ''
    $state.CancellationPath = ''
    $state.CancellationRequested = $false
    if (-not [string]::IsNullOrWhiteSpace($cancellationPath)) {
        try {
            [void](Remove-OpenClawGuiCancellationSignal -Path $cancellationPath -StateDirectory $StateDirectory)
        }
        catch {
            # The completed worker result takes precedence over signal cleanup.
        }
    }
    $result = Get-OpenClawGuiResult -ExitCode $exitCode -Action $action -StateDirectory $StateDirectory -OutputPath $outputPath -SafeOutput $safeOutput -StartedAtUtc $startedAtUtc
    if ($action -in @('Install', 'Resume')) {
        Update-StageProgress
    }
    Show-WorkerResult -Result $result
}

$window.Title = [string]$catalog.title
$controls['HeaderTitleText'].Text = [string]$catalog.title
$controls['HeaderSubtitleText'].Text = [string]$gui.subtitle
$controls['HomeHeadingText'].Text = [string]$gui.homeHeading
$controls['HomeDescriptionText'].Text = [string]$gui.homeDescription
$controls['DiagnoseButton'].Content = [string]$gui.actions.diagnose
$controls['InstallButton'].Content = [string]$gui.actions.install
$controls['ResumeButton'].Content = [string]$gui.actions.resume
$controls['ConfigureButton'].Content = [string]$gui.actions.configure
$controls['VerifyButton'].Content = [string]$gui.actions.verify
$controls['BundleButton'].Content = [string]$gui.actions.bundle
$controls['PlanApprovalGuidanceText'].Text = [string]$gui.approvalGuidance
$controls['PlanApprovalCheckBox'].Content = [string]$gui.approvalText
$controls['PlanCancelButton'].Content = [string]$gui.planCancel
$controls['PlanStartButton'].Content = [string]$gui.planStart
$controls['WorkCancelButton'].Content = [string]$gui.cancelButton
$controls['ResultLogGuidanceText'].Text = [string]$gui.logGuidance
$controls['ResultOpenLogButton'].Content = [string]$gui.openLocation
$controls['ResultBundleGuidanceText'].Text = [string]$gui.bundleGuidance
$controls['ResultCreateBundleButton'].Content = [string]$gui.createBundle
$controls['ResultOpenBundleButton'].Content = [string]$gui.openLocation
$controls['ResultHomeButton'].Content = [string]$gui.home
$controls['ResultPrimaryButton'].Content = [string]$gui.home

Set-AccessibleText -Control $controls['DiagnoseButton'] -Name ([string]$gui.accessibility.diagnose) -HelpText ([string]$gui.actionDescriptions.diagnose)
Set-AccessibleText -Control $controls['InstallButton'] -Name ([string]$gui.accessibility.install) -HelpText ([string]$gui.actionDescriptions.install)
Set-AccessibleText -Control $controls['ResumeButton'] -Name ([string]$gui.accessibility.resume) -HelpText ([string]$gui.actionDescriptions.resume)
Set-AccessibleText -Control $controls['ConfigureButton'] -Name ([string]$gui.accessibility.configure) -HelpText ([string]$gui.actionDescriptions.configure)
Set-AccessibleText -Control $controls['VerifyButton'] -Name ([string]$gui.accessibility.verify) -HelpText ([string]$gui.actionDescriptions.verify)
Set-AccessibleText -Control $controls['BundleButton'] -Name ([string]$gui.accessibility.bundle) -HelpText ([string]$gui.actionDescriptions.bundle)
Set-AccessibleText -Control $controls['PlanApprovalCheckBox'] -Name ([string]$gui.accessibility.approval) -HelpText ([string]$gui.approvalGuidance)
Set-AccessibleText -Control $controls['PlanCancelButton'] -Name ([string]$gui.planCancel) -HelpText ([string]$gui.approvalGuidance)
Set-AccessibleText -Control $controls['PlanStartButton'] -Name ([string]$gui.planStart) -HelpText ([string]$gui.approvalText)
Set-AccessibleText -Control $controls['OverallProgressBar'] -Name ([string]$gui.accessibility.progress)
Set-AccessibleText -Control $controls['WorkCancelButton'] -Name ([string]$gui.accessibility.cancel) -HelpText ([string]$gui.cancelGuidance)
Set-AccessibleText -Control $controls['ResultLogPathTextBox'] -Name ([string]$catalog.logPath) -HelpText ([string]$gui.logGuidance)
Set-AccessibleText -Control $controls['ResultOpenLogButton'] -Name ([string]$gui.openLocation) -HelpText ([string]$gui.logGuidance)
Set-AccessibleText -Control $controls['ResultBundlePathTextBox'] -Name ([string]$catalog.diagnosticsLocation) -HelpText ([string]$gui.bundleGuidance)
Set-AccessibleText -Control $controls['ResultCreateBundleButton'] -Name ([string]$gui.createBundle) -HelpText ([string]$gui.bundleGuidance)
Set-AccessibleText -Control $controls['ResultOpenBundleButton'] -Name ([string]$gui.openLocation) -HelpText ([string]$gui.bundleGuidance)
Set-AccessibleText -Control $controls['ResultHomeButton'] -Name ([string]$gui.home)
Set-AccessibleText -Control $controls['ResultPrimaryButton'] -Name ([string]$gui.home)
[Windows.Automation.AutomationProperties]::SetLiveSetting($controls['HeaderStatusText'], [Windows.Automation.AutomationLiveSetting]::Polite)
[Windows.Automation.AutomationProperties]::SetLiveSetting($controls['ResultHeadingText'], [Windows.Automation.AutomationLiveSetting]::Assertive)
[Windows.Automation.AutomationProperties]::SetLiveSetting($controls['FooterStatusText'], [Windows.Automation.AutomationLiveSetting]::Polite)

$workerTimer = New-Object Windows.Threading.DispatcherTimer
$workerTimer.Interval = [TimeSpan]::FromMilliseconds(750)
$workerTimer.add_Tick({
    try {
        if ($null -eq $state.Process) {
            $workerTimer.Stop()
            return
        }
        if ($state.Process.HasExited) {
            Complete-GuiWorker
            return
        }
        if ($state.Action -in @('Install', 'Resume')) {
            Update-StageProgress
        }
    }
    catch {
        $controls['FooterStatusText'].Text = [string]$gui.progressReadError
        if ($null -ne $state.Process -and $state.Process.HasExited) {
            Complete-GuiWorker
        }
    }
})

$controls['DiagnoseButton'].add_Click({ Start-GuiWorker -Action Diagnose })
$controls['InstallButton'].add_Click({ Show-InstallPlan -Action Install })
$controls['ResumeButton'].add_Click({ Show-InstallPlan -Action Resume })
$controls['ConfigureButton'].add_Click({
    $answer = [Windows.MessageBox]::Show([string]$gui.interactiveConsoleNotice, [string]$catalog.title, [Windows.MessageBoxButton]::OKCancel, [Windows.MessageBoxImage]::Information, [Windows.MessageBoxResult]::Cancel)
    if ($answer -eq [Windows.MessageBoxResult]::OK) {
        Start-GuiWorker -Action Configure -Approved $true
    }
})
$controls['VerifyButton'].add_Click({ Start-GuiWorker -Action Verify })
$controls['BundleButton'].add_Click({
    $path = Select-DiagnosticBundlePath
    if (-not [string]::IsNullOrWhiteSpace($path)) {
        Start-GuiWorker -Action Bundle -OutputPath $path
    }
})
$controls['PlanApprovalCheckBox'].add_Checked({ $controls['PlanStartButton'].IsEnabled = $true })
$controls['PlanApprovalCheckBox'].add_Unchecked({ $controls['PlanStartButton'].IsEnabled = $false })
$controls['PlanCancelButton'].add_Click({
    $controls['PlanApprovalCheckBox'].IsChecked = $false
    $state.PlanAction = ''
    $state.PlanFingerprint = ''
    Show-GuiPage -Name Home
    Update-ResumeState
})
$controls['PlanStartButton'].add_Click({
    if ($controls['PlanApprovalCheckBox'].IsChecked -ne $true) {
        return
    }
    $approvedAction = [string]$state.PlanAction
    if ($approvedAction -notin @('Install', 'Resume')) {
        return
    }
    Start-GuiWorker -Action $approvedAction -Approved $true
})
$controls['WorkCancelButton'].add_Click({
    if ($state.Action -notin @('Install', 'Resume') -or [string]::IsNullOrWhiteSpace([string]$state.CancellationPath)) {
        return
    }
    if ($null -eq $state.Process -or $state.Process.HasExited) {
        Complete-GuiWorker
        return
    }
    try {
        [void](Request-OpenClawGuiCancellation -Path ([string]$state.CancellationPath) -StateDirectory $StateDirectory)
        if ($state.Process.HasExited) {
            Complete-GuiWorker
            return
        }
        $state.CancellationRequested = $true
        $controls['WorkCancelButton'].IsEnabled = $false
        $controls['WorkCancelGuidanceText'].Text = [string]$gui.cancelRequested
        $controls['FooterStatusText'].Text = [string]$gui.cancelRequested
    }
    catch {
        [void][Windows.MessageBox]::Show([string]$gui.invalidResume, [string]$catalog.title, [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Error)
    }
})
$controls['ResultOpenLogButton'].add_Click({ Open-ContainingFolder -Path ([string]$controls['ResultLogPathTextBox'].Text) })
$controls['ResultCreateBundleButton'].add_Click({
    $path = Select-DiagnosticBundlePath
    if (-not [string]::IsNullOrWhiteSpace($path)) {
        Start-GuiWorker -Action Bundle -OutputPath $path
    }
})
$controls['ResultOpenBundleButton'].add_Click({ Open-ContainingFolder -Path ([string]$controls['ResultBundlePathTextBox'].Text) })
$controls['ResultHomeButton'].add_Click({ Show-GuiPage -Name Home; Update-ResumeState })
$controls['ResultPrimaryButton'].add_Click({
    switch ([string]$state.PrimaryAction) {
        'Configure' { $controls['ConfigureButton'].RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent))) }
        'Verify' { Start-GuiWorker -Action Verify }
        'Resume' { Show-InstallPlan -Action Resume }
        default { Show-GuiPage -Name Home; Update-ResumeState }
    }
})

$window.add_PreviewKeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [Windows.Input.Key]::Escape -and $controls['PlanPanel'].Visibility -eq [Windows.Visibility]::Visible) {
        $controls['PlanCancelButton'].RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
        $eventArgs.Handled = $true
    }
})
$window.add_Closing({
    param($sender, $eventArgs)
    if (-not $state.ClosingAllowed -and $null -ne $state.Process -and -not $state.Process.HasExited) {
        if ($state.Action -in @('Install', 'Resume')) {
            $eventArgs.Cancel = $true
            [void][Windows.MessageBox]::Show([string]$gui.closeBusyPrompt, [string]$catalog.title, [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Information)
        }
        else {
            $closeChoice = [Windows.MessageBox]::Show([string]$gui.closeBackgroundPrompt, [string]$catalog.title, [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Information, [Windows.MessageBoxResult]::No)
            if ($closeChoice -eq [Windows.MessageBoxResult]::Yes) {
                $state.ClosingAllowed = $true
            }
            else {
                $eventArgs.Cancel = $true
            }
        }
    }
})
$window.add_Closed({
    $workerTimer.Stop()
    if ($null -ne $state.Process) {
        $state.Process.Dispose()
    }
})

Update-StageProgress
Update-ResumeState
Show-GuiPage -Name Home
if ($SmokeTest) {
    function Find-SmokeTextBlock {
        param([Windows.DependencyObject]$Root)

        if ($null -eq $Root) {
            return $null
        }
        if ($Root -is [Windows.Controls.TextBlock]) {
            return $Root
        }
        for ($childIndex = 0; $childIndex -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($Root); $childIndex++) {
            $found = Find-SmokeTextBlock -Root ([Windows.Media.VisualTreeHelper]::GetChild($Root, $childIndex))
            if ($null -ne $found) {
                return $found
            }
        }
        return $null
    }

    $window.ShowInTaskbar = $false
    $window.ShowActivated = $false
    $window.WindowStartupLocation = [Windows.WindowStartupLocation]::Manual
    $window.Width = 520
    $window.Height = 320
    $window.Left = -32000
    $window.Top = -32000
    $window.Opacity = 0
    $window.Show()
    $window.UpdateLayout()
    $presentationSource = [Windows.PresentationSource]::FromVisual($window)
    $interactiveNames = @(
        'DiagnoseButton', 'InstallButton', 'ResumeButton', 'ConfigureButton', 'VerifyButton', 'BundleButton',
        'PlanApprovalCheckBox', 'PlanCancelButton', 'PlanStartButton', 'WorkCancelButton',
        'ResultLogPathTextBox', 'ResultOpenLogButton', 'ResultBundlePathTextBox',
        'ResultCreateBundleButton', 'ResultOpenBundleButton', 'ResultHomeButton', 'ResultPrimaryButton'
    )
    $missingAccessibleNames = @($interactiveNames | Where-Object {
        [string]::IsNullOrWhiteSpace([Windows.Automation.AutomationProperties]::GetName($controls[$_]))
    })
    $missingAutomationPeerNames = New-Object System.Collections.Generic.List[string]
    foreach ($interactiveName in $interactiveNames) {
        $control = $controls[$interactiveName]
        $peer = if ($control -is [Windows.Controls.CheckBox]) {
            New-Object -TypeName Windows.Automation.Peers.CheckBoxAutomationPeer -ArgumentList (,$control)
        }
        elseif ($control -is [Windows.Controls.TextBox]) {
            New-Object -TypeName Windows.Automation.Peers.TextBoxAutomationPeer -ArgumentList (,$control)
        }
        else {
            New-Object -TypeName Windows.Automation.Peers.ButtonAutomationPeer -ArgumentList (,$control)
        }
        if ([string]::IsNullOrWhiteSpace([string]$peer.GetName())) {
            $missingAutomationPeerNames.Add($interactiveName)
        }
    }
    $controls['InstallButton'].RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
    $window.UpdateLayout()
    $planShown = $controls['PlanPanel'].Visibility -eq [Windows.Visibility]::Visible
    $planItemsWrappedAndConstrained = $true
    for ($itemIndex = 0; $itemIndex -lt $controls['PlanItemsControl'].Items.Count; $itemIndex++) {
        $container = $controls['PlanItemsControl'].ItemContainerGenerator.ContainerFromIndex($itemIndex)
        $textBlock = Find-SmokeTextBlock -Root $container
        if ($null -eq $container -or $null -eq $textBlock -or $textBlock.TextWrapping -ne [Windows.TextWrapping]::Wrap -or $textBlock.ActualWidth -gt ($container.ActualWidth + 0.5)) {
            $planItemsWrappedAndConstrained = $false
            break
        }
    }
    $controls['PlanStartButton'].RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
    $unapprovedWorkerStarted = $null -ne $state.Process
    $escapeEvent = New-Object Windows.Input.KeyEventArgs([Windows.Input.Keyboard]::PrimaryDevice, $presentationSource, [Environment]::TickCount, [Windows.Input.Key]::Escape)
    $escapeEvent.RoutedEvent = [Windows.Input.Keyboard]::PreviewKeyDownEvent
    $window.RaiseEvent($escapeEvent)
    $homeRestored = $controls['HomePanel'].Visibility -eq [Windows.Visibility]::Visible
    Show-WorkerResult -Result ([pscustomobject]@{
        Status = 'Failed'
        Action = 'Verify'
        Message = 'Smoke-test result'
        SafeOutput = ''
        ErrorId = 'OCES-VERIFY-001'
        ExitCode = 50
        Guidance = 'Smoke-test guidance'
        LogPath = ''
        OutputPath = ''
        AutomaticUpload = $false
    })
    $resultHeadingPeer = New-Object -TypeName Windows.Automation.Peers.TextBlockAutomationPeer -ArgumentList (,$controls['ResultHeadingText'])
    [pscustomobject]@{
        Loaded = $true
        PresentationSourceReady = $null -ne $presentationSource
        InteractiveControls = $interactiveNames.Count
        MissingAccessibleNames = $missingAccessibleNames.Count
        MissingAutomationPeerNames = $missingAutomationPeerNames.Count
        ApprovalChecked = [bool]$controls['PlanApprovalCheckBox'].IsChecked
        StartEnabled = [bool]$controls['PlanStartButton'].IsEnabled
        CancelIsDefault = [bool]$controls['PlanCancelButton'].IsDefault
        PlanShown = $planShown
        PlanItemsWrappedAndConstrained = $planItemsWrappedAndConstrained
        UnapprovedWorkerStarted = $unapprovedWorkerStarted
        EscapeHandled = [bool]$escapeEvent.Handled
        HomeRestored = $homeRestored
        ResultPanelShown = $controls['ResultPanel'].Visibility -eq [Windows.Visibility]::Visible
        ResultHeadingFocusable = [bool]$controls['ResultHeadingText'].Focusable
        ResultHeadingPeerName = [string]$resultHeadingPeer.GetName()
        ResultLiveSetting = [string][Windows.Automation.AutomationProperties]::GetLiveSetting($controls['ResultHeadingText'])
        UsesSystemColors = [bool]$definition.Accessibility.UsesSystemColors
    } | ConvertTo-Json -Compress
    $state.ClosingAllowed = $true
    $window.Close()
    return
}
[void]$window.ShowDialog()
