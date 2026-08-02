[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Menu', 'Diagnose', 'Plan', 'Install', 'Configure', 'Verify', 'Bundle')]
    [string]$Action = 'Menu',

    [switch]$Apply,

    [switch]$Resume,

    [string]$StateDirectory,

    [string]$DiagnosticOutputPath,

    [string]$CancellationPath,

    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$ExpectedPlanFingerprint,

    [switch]$GuiApproved,

    [switch]$GuiOutput,

    [switch]$SkipOnboarding,
    [switch]$Strict
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'src\OpenClawEasySetup.psm1'
$originalPSModulePath = $env:PSModulePath
$builtInModulePath = $null
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
    Import-Module -Name $modulePath -Force -ErrorAction Stop
}
catch {
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        [Environment]::SetEnvironmentVariable('PSModulePath', $originalPSModulePath, 'Process')
    }
    Write-Host 'OpenClaw 쉬운 설치 도우미를 시작하지 못했습니다.' -ForegroundColor Red
    Write-Host '오류 코드: OCES-UNEXPECTED-001'
    exit 99
}

function Show-MainMenu {
    $messagesPath = Join-Path $PSScriptRoot 'locales\ko-KR.json'
    $messages = Get-Content -LiteralPath $messagesPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host ''
    Write-Host $messages.title -ForegroundColor Cyan
    foreach ($line in $messages.menu) {
        Write-Host $line
    }
    $choice = Read-Host $messages.menuPrompt
    switch ($choice) {
        '1' { return [pscustomobject]@{ Action = 'Diagnose'; Resume = $false; ConfirmChange = $false } }
        '2' { return [pscustomobject]@{ Action = 'Install'; Resume = $false; ConfirmChange = $true } }
        '3' { return [pscustomobject]@{ Action = 'Install'; Resume = $true; ConfirmChange = $true } }
        '4' { return [pscustomobject]@{ Action = 'Configure'; Resume = $false; ConfirmChange = $true } }
        '5' { return [pscustomobject]@{ Action = 'Verify'; Resume = $false; ConfirmChange = $false } }
        '6' { return [pscustomobject]@{ Action = 'Bundle'; Resume = $false; ConfirmChange = $false } }
        '0' { return [pscustomobject]@{ Action = 'Exit'; Resume = $false; ConfirmChange = $false } }
        default { throw 'Choose a number from 0 through 6.' }
    }
}

$messagesPath = Join-Path $PSScriptRoot 'locales\ko-KR.json'
try {
    $messages = Get-Content -LiteralPath $messagesPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
catch {
    Write-Host '한국어 메시지 파일을 읽지 못했습니다.' -ForegroundColor Red
    Write-Host '오류 코드: OCES-UNEXPECTED-001'
    exit 99
}
$interactiveApproval = $false
$planAlreadyShown = $false
$logPath = $null
$installLock = $null
$sourceConfigLock = $null
$confirmWasBound = $PSBoundParameters.ContainsKey('Confirm')
$explicitConfirm = if ($confirmWasBound) { [bool]$PSBoundParameters['Confirm'] } else { $false }

try {
    if ($Action -eq 'Menu') {
        $selection = Show-MainMenu
        $Action = $selection.Action
        $Resume = [switch][bool]$selection.Resume
        if ($selection.ConfirmChange) {
            if ($Action -eq 'Install') {
                Show-OpenClawInstallPlan
                $planAlreadyShown = $true
                $confirmation = Read-Host $messages.installConfirmPrompt
            }
            else {
                $confirmation = Read-Host $messages.configureConfirmPrompt
            }
            if ($confirmation -notmatch '^(?i:y|yes|예)$') {
                $cancelMessage = if ($Action -eq 'Configure') { $messages.configureCancelled } else { $messages.installCancelled }
                Write-Host $cancelMessage -ForegroundColor Yellow
                return
            }
            $Apply = [switch]$true
            $interactiveApproval = $true
        }
    }

    if ($Resume -and $Action -ne 'Install') {
        $resumeException = New-Object InvalidOperationException('Resume can only be used with the Install action.')
        $resumeException.Data['OpenClawFailureKind'] = 'Resume'
        throw $resumeException
    }
    if (-not [string]::IsNullOrWhiteSpace($CancellationPath) -and $Action -ne 'Install') {
        $cancellationException = New-Object InvalidOperationException('CancellationPath can only be used with the Install action.')
        $cancellationException.Data['OpenClawFailureKind'] = 'Resume'
        throw $cancellationException
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedPlanFingerprint) -and $Action -ne 'Install') {
        $planException = New-Object InvalidOperationException('ExpectedPlanFingerprint can only be used with the Install action.')
        $planException.Data['OpenClawFailureKind'] = 'Integrity'
        throw $planException
    }
    if ($GuiApproved -and $Action -notin @('Install', 'Configure')) {
        $guiApprovalException = New-Object InvalidOperationException('GuiApproved can only be used with Install or Configure.')
        $guiApprovalException.Data['OpenClawFailureKind'] = 'Unexpected'
        throw $guiApprovalException
    }
    if ($GuiApproved -and $Action -eq 'Install' -and [string]::IsNullOrWhiteSpace($ExpectedPlanFingerprint)) {
        $guiPlanException = New-Object InvalidOperationException('GUI installation approval requires an expected plan fingerprint.')
        $guiPlanException.Data['OpenClawFailureKind'] = 'Integrity'
        throw $guiPlanException
    }
    if ($GuiOutput -and $Action -ne 'Diagnose') {
        $guiOutputException = New-Object InvalidOperationException('GuiOutput can only be used with Diagnose.')
        $guiOutputException.Data['OpenClawFailureKind'] = 'Unexpected'
        throw $guiOutputException
    }
    if ($GuiOutput) {
        [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
    }

    switch ($Action) {
        'Exit' {
            return
        }
        'Diagnose' {
            $checks = Get-OpenClawReadiness
            $checks | Show-OpenClawReadiness
            if (@($checks | Where-Object Status -eq 'Fail').Count -gt 0) {
                $diagnoseException = New-Object InvalidOperationException('PC 준비 상태에서 설치를 막는 문제를 찾았습니다.')
                $diagnoseException.Data['OpenClawFailureKind'] = 'Diagnose'
                throw $diagnoseException
            }
            if ($Strict -and @($checks | Where-Object Status -eq 'Warn').Count -gt 0) {
                $warningException = New-Object InvalidOperationException('엄격 진단에서 확인이 필요한 항목을 찾았습니다.')
                $warningException.Data['OpenClawFailureKind'] = 'Warning'
                throw $warningException
            }
        }
        'Plan' {
            Show-OpenClawInstallPlan
        }
        'Install' {
            if (-not $planAlreadyShown) {
                Show-OpenClawInstallPlan
            }
            if (-not $Apply) {
                Write-Host ''
                Write-Host $messages.previewOnly -ForegroundColor Yellow
                if ($Resume) {
                    Write-Host $messages.resumeApplyRequired -ForegroundColor DarkGray
                }
                return
            }

            if (-not [string]::IsNullOrWhiteSpace($ExpectedPlanFingerprint)) {
                $sourceConfigLock = Enter-OpenClawSourceConfigReadLock
                $planMode = if ($Resume) { 'Resume' } else { 'Install' }
                $currentPlanFingerprint = Get-OpenClawPlanFingerprint -Mode $planMode
                if (-not [string]::Equals($currentPlanFingerprint, $ExpectedPlanFingerprint, [StringComparison]::OrdinalIgnoreCase)) {
                    $planChangedException = New-Object InvalidOperationException('The approved installation plan changed before execution.')
                    $planChangedException.Data['OpenClawFailureKind'] = 'Integrity'
                    throw $planChangedException
                }
            }

            if (-not $WhatIfPreference) {
                $runtimeDirectories = Initialize-OpenClawStateDirectory -Path $StateDirectory
                $installLockPath = Join-Path $runtimeDirectories.State 'install.lock'
                if (Test-Path -LiteralPath $installLockPath) {
                    $installLockItem = Get-Item -LiteralPath $installLockPath -Force
                    if (($installLockItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                        $lockException = New-Object InvalidOperationException('The installation lock was a reparse point.')
                        $lockException.Data['OpenClawFailureKind'] = 'Resume'
                        throw $lockException
                    }
                }
                try {
                    $installLock = New-Object IO.FileStream($installLockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                }
                catch {
                    $_.Exception.Data['OpenClawFailureKind'] = 'Resume'
                    throw
                }
                $logPath = New-OpenClawLog -StateDirectory $runtimeDirectories.Root
                Write-Host ("{0}: {1}" -f $messages.logPath, $logPath) -ForegroundColor DarkGray
            }
            $installParameters = @{
                SkipOnboarding = $SkipOnboarding
                Resume = $Resume
                InteractiveApproval = $interactiveApproval
                StateDirectory = $StateDirectory
                LogPath = $logPath
                CancellationPath = $CancellationPath
                WhatIf = $WhatIfPreference
            }
            if ($interactiveApproval -or $GuiApproved) {
                $installParameters['Confirm'] = $false
            }
            elseif ($confirmWasBound) {
                $installParameters['Confirm'] = $explicitConfirm
            }
            $installResult = Install-OpenClawOfficial @installParameters
            if ($null -ne $installResult -and -not [string]::IsNullOrWhiteSpace([string]$installResult.CheckpointPath)) {
                Write-Host ("{0}: {1}" -f $messages.checkpointPath, $installResult.CheckpointPath) -ForegroundColor DarkGray
            }
        }
        'Configure' {
            if (-not $Apply) {
                Write-Host $messages.configurePreview -ForegroundColor Yellow
                Write-Host $messages.configureApplyHint
                return
            }
            if (-not $WhatIfPreference) {
                $runtimeDirectories = Initialize-OpenClawStateDirectory -Path $StateDirectory
                $logPath = New-OpenClawLog -StateDirectory $runtimeDirectories.Root
                Write-OpenClawLog -Path $logPath -Level 'Info' -Event 'configure.start' -Message 'Official OpenClaw onboarding started.'
                Write-Host ("{0}: {1}" -f $messages.logPath, $logPath) -ForegroundColor DarkGray
            }
            $configurationParameters = @{
                StateDirectory = $StateDirectory
                WhatIf = $WhatIfPreference
            }
            if ($interactiveApproval -or $GuiApproved) {
                $configurationParameters['Confirm'] = $false
            }
            elseif ($confirmWasBound) {
                $configurationParameters['Confirm'] = $explicitConfirm
            }
            $configurationCompleted = Start-OpenClawOnboarding @configurationParameters
            if (-not $configurationCompleted) {
                Write-Host $messages.configureCancelled -ForegroundColor Yellow
                if (-not [string]::IsNullOrWhiteSpace($logPath)) {
                    Write-OpenClawLog -Path $logPath -Level 'Warning' -Event 'configure.cancelled' -Message 'Official OpenClaw onboarding confirmation was declined.'
                }
                return
            }
            if (-not [string]::IsNullOrWhiteSpace($logPath)) {
                Write-OpenClawLog -Path $logPath -Level 'Info' -Event 'configure.success' -Message 'Official OpenClaw onboarding completed.'
            }
        }
        'Verify' {
            $results = Invoke-OpenClawVerification -StateDirectory $StateDirectory
            $results | Format-Table -AutoSize
            if (@($results | Where-Object Passed -eq $false).Count -gt 0) {
                $verifyException = New-Object InvalidOperationException('하나 이상의 OpenClaw 확인 단계가 실패했습니다.')
                $verifyException.Data['OpenClawFailureKind'] = 'Verify'
                throw $verifyException
            }
        }
        'Bundle' {
            $bundleTarget = if ([string]::IsNullOrWhiteSpace($DiagnosticOutputPath)) { 'default diagnostics directory' } else { $DiagnosticOutputPath }
            if (-not $PSCmdlet.ShouldProcess($bundleTarget, 'Create an offline diagnostic ZIP')) {
                return
            }
            $bundle = Export-OpenClawDiagnosticBundle -StateDirectory $StateDirectory -DestinationPath $DiagnosticOutputPath
            Write-Host $messages.bundleCreated -ForegroundColor Green
            Write-Host ("{0}: {1}" -f $messages.diagnosticsLocation, $bundle.Path)
            Write-Host ("{0}: {1}" -f $messages.diagnosticsHash, $bundle.Sha256)
            Write-Host $messages.bundleNotUploaded -ForegroundColor DarkGray
        }
    }
}
catch {
    $failure = Resolve-OpenClawFailure -Action $Action -Exception $_.Exception
    if (-not [string]::IsNullOrWhiteSpace($logPath)) {
        try {
            Write-OpenClawLog -Path $logPath -Level 'Error' -Event 'workflow.failure' -Message $failure.Message -Data @{ errorCode = $failure.Id; exitCode = $failure.ExitCode }
        }
        catch {
            # The original stable failure code takes precedence over a logging failure.
        }
    }
    Write-Host ''
    Write-Host $messages.failureHeader -ForegroundColor Red
    Write-Host $failure.Message
    if (-not [string]::IsNullOrWhiteSpace($failure.Guidance)) {
        Write-Host $failure.Guidance -ForegroundColor Yellow
    }
    Write-Host ("{0}: {1}" -f $messages.errorCode, $failure.Id)
    if (-not [string]::IsNullOrWhiteSpace($logPath)) {
        Write-Host ("{0}: {1}" -f $messages.logPath, $logPath)
    }
    exit $failure.ExitCode
}
finally {
    if ($null -ne $installLock) {
        $installLock.Dispose()
    }
    if ($null -ne $sourceConfigLock) {
        $sourceConfigLock.Dispose()
    }
    if (-not [string]::IsNullOrWhiteSpace($CancellationPath)) {
        try {
            if (Test-Path -LiteralPath $CancellationPath -PathType Leaf) {
                [void](Remove-OpenClawCancellationSignal -Path $CancellationPath -StateDirectory $StateDirectory)
            }
        }
        catch {
            # A cancellation-signal cleanup failure must not replace the workflow result.
        }
    }
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        [Environment]::SetEnvironmentVariable('PSModulePath', $originalPSModulePath, 'Process')
    }
}
