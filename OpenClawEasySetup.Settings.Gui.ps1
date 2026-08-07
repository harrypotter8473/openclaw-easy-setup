[CmdletBinding()]
param(
    [string]$StateDirectory,
    [switch]$Describe,
    [switch]$SmokeTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$definition = [ordered]@{
    Name = 'OpenClaw Easy Setup Settings Wizard'
    Version = '0.4.0'
    Xaml = 'ui\SettingsWindow.xaml'
    Providers = @('openai', 'anthropic', 'google')
    ExitCodes = [ordered]@{
        Success = 0
        Failure = 42
        Cancelled = 61
    }
    InteractiveControls = @(
        'ProviderComboBox', 'ModelComboBox', 'ApiKeyPasswordBox',
        'SlackCheckBox', 'SlackBotTokenPasswordBox', 'SlackAppTokenPasswordBox',
        'TelegramCheckBox', 'TelegramTokenPasswordBox',
        'DiscordCheckBox', 'DiscordTokenPasswordBox',
        'PreviewButton', 'PreviewTextBox', 'ApprovalCheckBox',
        'AdvancedButton', 'CancelButton', 'ApplyButton'
    )
    Safety = [ordered]@{
        ApprovalDefault = $false
        SecretsInPreview = $false
        SecretsInLogs = $false
        SecretsInArguments = $false
        SmokeTestCallsOpenClaw = $false
        SmokeTestCallsCredentialManager = $false
    }
}

function ConvertTo-SettingsWindowsArgument {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Argument
    )

    if ($null -eq $Argument) {
        $Argument = ''
    }
    if ($Argument.Length -gt 32760) {
        throw 'An argument exceeded the supported Windows command-line length.'
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

function Get-TrustedSettingsWindowsPowerShellPath {
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
        throw 'The Windows PowerShell executable signature was not valid.'
    }
    if ($null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch '(?i)(?:^|,\s*)O=Microsoft Corporation(?:,|$)') {
        throw 'The Windows PowerShell executable was not signed by Microsoft Corporation.'
    }
    return $path
}

$settingsModulePath = Join-Path $PSScriptRoot 'src\OpenClawEasySetup.Settings.psm1'
$moduleImportError = $null
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
    Import-Module -Name $settingsModulePath -Force -ErrorAction Stop
}
catch {
    $moduleImportError = $_
}
finally {
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        [Environment]::SetEnvironmentVariable('PSModulePath', $originalPSModulePath, 'Process')
    }
}

if ($Describe) {
    $description = [ordered]@{}
    foreach ($entry in $definition.GetEnumerator()) {
        $description[$entry.Key] = $entry.Value
    }
    $description['ModuleImported'] = $null -eq $moduleImportError
    $description | ConvertTo-Json -Depth 8
    return
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Write-Error 'OpenClaw Easy Setup Settings Wizard supports Windows only.'
    exit 42
}

if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
    try {
        if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
            throw 'The settings wizard script path was unavailable.'
        }
        $powerShellPath = Get-TrustedSettingsWindowsPowerShellPath
        $arguments = New-Object System.Collections.Generic.List[string]
        foreach ($argument in @('-NoLogo', '-NoProfile', '-STA', '-File', [IO.Path]::GetFullPath($PSCommandPath))) {
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
        $startInfo.Arguments = (@($arguments.ToArray() | ForEach-Object { ConvertTo-SettingsWindowsArgument -Argument $_ }) -join ' ')
        $startInfo.WorkingDirectory = $PSScriptRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        if ($SmokeTest) {
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
            $startInfo.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
        }
        $process = [Diagnostics.Process]::Start($startInfo)
        if ($null -eq $process) {
            throw 'The STA settings wizard process did not start.'
        }
        try {
            $outputTask = if ($SmokeTest) { $process.StandardOutput.ReadToEndAsync() } else { $null }
            $errorTask = if ($SmokeTest) { $process.StandardError.ReadToEndAsync() } else { $null }
            $process.WaitForExit()
            if ($SmokeTest) {
                $outputText = $outputTask.GetAwaiter().GetResult()
                [Console]::Out.Write($outputText)
                [void]$errorTask.GetAwaiter().GetResult()
            }
            exit $process.ExitCode
        }
        finally {
            $process.Dispose()
        }
    }
    catch {
        Write-Error 'The settings wizard could not start in a trusted STA process.'
        exit 42
    }
}

try {
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Xaml

    $xamlPath = Join-Path $PSScriptRoot 'ui\SettingsWindow.xaml'
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
}
catch {
    Write-Error 'The settings wizard window could not be loaded.'
    exit 42
}

$controlNames = @(
    'MainScrollViewer', 'SettingsContentPanel',
    'ProviderComboBox', 'ModelComboBox', 'ApiKeyPasswordBox',
    'SlackCheckBox', 'SlackBotTokenPasswordBox', 'SlackAppTokenPasswordBox',
    'TelegramCheckBox', 'TelegramTokenPasswordBox',
    'DiscordCheckBox', 'DiscordTokenPasswordBox',
    'PreviewButton', 'PreviewTextBox', 'ApprovalCheckBox',
    'BusyProgressBar', 'AdvancedButton', 'CancelButton', 'ApplyButton', 'StatusText'
)
$controls = @{}
try {
    foreach ($name in $controlNames) {
        $control = $window.FindName($name)
        if ($null -eq $control) {
            throw "Required settings control was not found: $name"
        }
        $controls[$name] = $control
    }
}
catch {
    $window.Close()
    Write-Error 'The settings wizard controls could not be initialized.'
    exit 42
}

$effectiveStateDirectory = ''
$stateDirectoryError = $false
if (-not [string]::IsNullOrWhiteSpace($StateDirectory)) {
    try {
        $effectiveStateDirectory = [IO.Path]::GetFullPath($StateDirectory)
    }
    catch {
        $stateDirectoryError = $true
    }
}

$state = @{
    Busy = $false
    AcceptConfigChangeRequired = $false
    ClosingAllowed = $false
    CredentialReplacementRequired = $false
    ExitCode = 61
    ExternalApiCalls = 0
    HasFailure = $false
    ModuleReady = $null -eq $moduleImportError
    PartialApplied = $false
    PendingRecovery = $null
    Plan = $null
    RecoveryGuardError = $false
    SuppressInputEvents = $false
}

function Get-SettingsMemberValue {
    param(
        [AllowNull()]
        [object]$InputObject,
        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    if ($null -eq $InputObject) {
        return $null
    }
    foreach ($name in $Names) {
        if ($InputObject -is [Collections.IDictionary]) {
            foreach ($key in $InputObject.Keys) {
                if ([string]::Equals([string]$key, $name, [StringComparison]::OrdinalIgnoreCase)) {
                    return $InputObject[$key]
                }
            }
        }
        $property = $InputObject.PSObject.Properties[$name]
        if ($null -ne $property) {
            return $property.Value
        }
    }
    return $null
}

function ConvertTo-SettingsProviderItems {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Catalog
    )

    $catalogProviders = @(Get-SettingsMemberValue -InputObject $Catalog -Names @('Providers'))
    $providerDefinitions = @(
        [pscustomobject]@{ Id = 'openai'; Label = 'OpenAI' },
        [pscustomobject]@{ Id = 'anthropic'; Label = 'Anthropic' },
        [pscustomobject]@{ Id = 'google'; Label = 'Google' }
    )
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($providerDefinition in $providerDefinitions) {
        $catalogProvider = $null
        foreach ($candidate in $catalogProviders) {
            $candidateId = [string](Get-SettingsMemberValue -InputObject $candidate -Names @('Id'))
            if ([string]::Equals($candidateId, [string]$providerDefinition.Id, [StringComparison]::OrdinalIgnoreCase)) {
                $catalogProvider = $candidate
                break
            }
        }

        $models = New-Object System.Collections.Generic.List[object]
        if ($null -ne $catalogProvider) {
            foreach ($catalogModel in @(Get-SettingsMemberValue -InputObject $catalogProvider -Names @('Models'))) {
                if ($null -eq $catalogModel) {
                    continue
                }
                $modelId = [string](Get-SettingsMemberValue -InputObject $catalogModel -Names @('Id'))
                if ([string]::IsNullOrWhiteSpace($modelId)) {
                    continue
                }
                $modelLabel = [string](Get-SettingsMemberValue -InputObject $catalogModel -Names @('Label'))
                if ([string]::IsNullOrWhiteSpace($modelLabel)) {
                    $modelLabel = $modelId
                }
                $models.Add([pscustomobject]@{ Id = $modelId; Label = $modelLabel })
            }
        }

        $label = [string]$providerDefinition.Label
        if ($null -ne $catalogProvider) {
            $catalogLabel = [string](Get-SettingsMemberValue -InputObject $catalogProvider -Names @('Label'))
            if (-not [string]::IsNullOrWhiteSpace($catalogLabel)) {
                $label = $catalogLabel
            }
        }
        elseif (-not $SmokeTest) {
            $label = "$label (현재 설치에서 사용 불가)"
        }

        $result.Add([pscustomobject]@{
            Id = [string]$providerDefinition.Id
            Label = $label
            Models = $models.ToArray()
        })
    }
    return $result.ToArray()
}

function Set-SettingsStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $controls['StatusText'].Text = $Text
    try {
        $peer = [Windows.Automation.Peers.UIElementAutomationPeer]::FromElement($controls['StatusText'])
        if ($null -eq $peer) {
            $peer = New-Object -TypeName Windows.Automation.Peers.TextBlockAutomationPeer -ArgumentList (,$controls['StatusText'])
        }
        $peer.RaiseAutomationEvent([Windows.Automation.Peers.AutomationEvents]::LiveRegionChanged)
    }
    catch {
        # Accessibility notification failure must not replace the settings operation.
    }
}

function Show-SettingsFailure {
    param(
        [ValidateSet('Initialization', 'Catalog', 'Preview', 'Apply', 'Advanced')]
        [string]$Phase
    )

    $state.ExitCode = 42
    $state.HasFailure = $true
    $message = switch ($Phase) {
        'Initialization' { '[오류] 설정 마법사를 초기화하지 못했습니다. 파일 무결성과 설치 상태를 확인하세요. (OCES-SETTINGS-INIT-042)' }
        'Catalog' { '[오류] 설치된 OpenClaw의 지원 모델 목록을 안전하게 확인하지 못했습니다. 공식 고급 설정을 사용할 수 있습니다. (OCES-SETTINGS-CATALOG-042)' }
        'Preview' { '[오류] 미리보기 또는 dry-run 검사를 통과하지 못했습니다. 입력과 현재 설정을 확인한 뒤 다시 시도하세요. (OCES-SETTINGS-PREVIEW-042)' }
        'Apply' { '[오류] 설정 적용을 완료하지 못했습니다. 비밀 입력은 지웠습니다. PC 변경 여부를 확인한 뒤 다시 미리보기를 만드세요. (OCES-SETTINGS-APPLY-042)' }
        default { '[오류] 공식 고급 설정 창을 안전하게 시작하지 못했습니다. (OCES-SETTINGS-ADVANCED-042)' }
    }
    Set-SettingsStatus -Text $message
}

function Get-SettingsPasswordLength {
    param(
        [Parameter(Mandatory = $true)]
        [Windows.Controls.PasswordBox]$PasswordBox
    )

    $secureValue = $PasswordBox.SecurePassword
    try {
        return $secureValue.Length
    }
    finally {
        $secureValue.Dispose()
    }
}

function Copy-SettingsPasswordSecret {
    param(
        [Parameter(Mandatory = $true)]
        [Windows.Controls.PasswordBox]$PasswordBox
    )

    $secureValue = $PasswordBox.SecurePassword
    try {
        if ($secureValue.Length -eq 0) {
            throw 'A required secret was empty.'
        }
        $copy = $secureValue.Copy()
        try {
            $copy.MakeReadOnly()
            return $copy
        }
        catch {
            $copy.Dispose()
            throw
        }
    }
    finally {
        $secureValue.Dispose()
    }
}

function Clear-SettingsSecretInputs {
    $previousSuppression = [bool]$state.SuppressInputEvents
    $state.SuppressInputEvents = $true
    try {
        foreach ($passwordBoxName in @('ApiKeyPasswordBox', 'SlackBotTokenPasswordBox', 'SlackAppTokenPasswordBox', 'TelegramTokenPasswordBox', 'DiscordTokenPasswordBox')) {
            $controls[$passwordBoxName].Clear()
        }
    }
    finally {
        $state.SuppressInputEvents = $previousSuppression
    }
}

function Test-SettingsInputsValid {
    $provider = $controls['ProviderComboBox'].SelectedItem
    $model = $controls['ModelComboBox'].SelectedItem
    if ($null -eq $provider -or $null -eq $model) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace([string]$provider.Id) -or [string]::IsNullOrWhiteSpace([string]$model.Id)) {
        return $false
    }
    if ((Get-SettingsPasswordLength -PasswordBox $controls['ApiKeyPasswordBox']) -eq 0) {
        return $false
    }
    if ($controls['SlackCheckBox'].IsChecked -eq $true -and
        ((Get-SettingsPasswordLength -PasswordBox $controls['SlackBotTokenPasswordBox']) -eq 0 -or
        (Get-SettingsPasswordLength -PasswordBox $controls['SlackAppTokenPasswordBox']) -eq 0)) {
        return $false
    }
    if ($controls['TelegramCheckBox'].IsChecked -eq $true -and (Get-SettingsPasswordLength -PasswordBox $controls['TelegramTokenPasswordBox']) -eq 0) {
        return $false
    }
    if ($controls['DiscordCheckBox'].IsChecked -eq $true -and (Get-SettingsPasswordLength -PasswordBox $controls['DiscordTokenPasswordBox']) -eq 0) {
        return $false
    }
    return $true
}

function Test-SettingsRecoveryCanReplace {
    if ($null -eq $state.PendingRecovery) {
        return $false
    }
    $status = [string](Get-SettingsMemberValue -InputObject $state.PendingRecovery -Names @('Status'))
    $pendingCount = Get-SettingsMemberValue -InputObject $state.PendingRecovery -Names @('PendingCount')
    return $status -in @('AppliedPendingChecks', 'Partial') -and [int]$pendingCount -eq 1
}

function Test-SettingsRecoveryInputsValid {
    if (-not (Test-SettingsRecoveryCanReplace)) {
        return $false
    }
    $plan = Get-SettingsMemberValue -InputObject $state.PendingRecovery -Names @('Plan')
    if ($null -eq $plan -or (Get-SettingsPasswordLength -PasswordBox $controls['ApiKeyPasswordBox']) -eq 0) {
        return $false
    }
    if ((Get-SettingsMemberValue -InputObject $plan -Names @('EnableSlack')) -eq $true -and
        ((Get-SettingsPasswordLength -PasswordBox $controls['SlackBotTokenPasswordBox']) -eq 0 -or
        (Get-SettingsPasswordLength -PasswordBox $controls['SlackAppTokenPasswordBox']) -eq 0)) {
        return $false
    }
    if ((Get-SettingsMemberValue -InputObject $plan -Names @('EnableTelegram')) -eq $true -and
        (Get-SettingsPasswordLength -PasswordBox $controls['TelegramTokenPasswordBox']) -eq 0) {
        return $false
    }
    if ((Get-SettingsMemberValue -InputObject $plan -Names @('EnableDiscord')) -eq $true -and
        (Get-SettingsPasswordLength -PasswordBox $controls['DiscordTokenPasswordBox']) -eq 0) {
        return $false
    }
    return $true
}

function Test-SettingsAnyRecoverySecretEntered {
    foreach ($passwordBoxName in @('ApiKeyPasswordBox', 'SlackBotTokenPasswordBox', 'SlackAppTokenPasswordBox', 'TelegramTokenPasswordBox', 'DiscordTokenPasswordBox')) {
        if ((Get-SettingsPasswordLength -PasswordBox $controls[$passwordBoxName]) -gt 0) {
            return $true
        }
    }
    return $false
}

function Update-SettingsActionState {
    if ($state.Busy) {
        $controls['PreviewButton'].IsEnabled = $false
        $controls['ApprovalCheckBox'].IsEnabled = $false
        $controls['ApplyButton'].IsEnabled = $false
        return
    }
    if ($null -ne $state.PendingRecovery) {
        $pendingStatus = [string](Get-SettingsMemberValue -InputObject $state.PendingRecovery -Names @('Status'))
        if ($pendingStatus -eq 'Preparing') {
            $controls['PreviewButton'].Content = '중단 작업 자격 증명 정리'
            [Windows.Automation.AutomationProperties]::SetName($controls['PreviewButton'], '중단된 적용 전 작업의 정확한 자격 증명 정리')
        }
        elseif ($state.CredentialReplacementRequired) {
            $controls['PreviewButton'].Content = '자격 증명 복구 상태 확인'
            [Windows.Automation.AutomationProperties]::SetName($controls['PreviewButton'], '중단된 전체 자격 증명 교체 상태 다시 확인')
        }
        else {
            $controls['PreviewButton'].Content = '읽기 전용 사후 검사'
            [Windows.Automation.AutomationProperties]::SetName($controls['PreviewButton'], 'Gateway 변경 없이 일부 적용 설정의 사후 검사 실행')
        }
        $controls['PreviewButton'].IsEnabled = [bool]$state.ModuleReady
        $credentialReplacementRequired = [bool]$state.CredentialReplacementRequired
        if ($state.AcceptConfigChangeRequired -and $credentialReplacementRequired) {
            $controls['ApprovalCheckBox'].Content = '승인된 Easy Setup 패치를 복원하고, 기록에 묶인 모델 API 키와 선택 채널 토큰을 모두 다시 입력해 같은 ID에 교체한 뒤 전체 검사를 실행하는 데 동의합니다.'
            [Windows.Automation.AutomationProperties]::SetName($controls['ApprovalCheckBox'], '승인 패치 복원과 필수 자격 증명 전체 교체 동의')
            $controls['ApplyButton'].Content = '패치 복원·자격 증명 교체 및 재검사'
            [Windows.Automation.AutomationProperties]::SetName($controls['ApplyButton'], 'Easy Setup 소유 경로를 복원하고 기록에 묶인 자격 증명 전체를 교체한 뒤 사후 검사 다시 실행')
            $recoveryApprovalValid = $state.ModuleReady -and (Test-SettingsRecoveryInputsValid)
        }
        elseif ($state.AcceptConfigChangeRequired) {
            $controls['ApprovalCheckBox'].Content = '다른 설정은 유지하고 Easy Setup 소유 경로만 이전에 승인한 안전 패치로 복원한 뒤 전체 검사를 실행하는 데 동의합니다.'
            [Windows.Automation.AutomationProperties]::SetName($controls['ApprovalCheckBox'], '승인된 Easy Setup 패치 복원 동의')
            $controls['ApplyButton'].Content = '승인 패치 복원 및 재검사'
            [Windows.Automation.AutomationProperties]::SetName($controls['ApplyButton'], 'Easy Setup 소유 경로를 승인 패치로 복원하고 사후 검사 다시 실행')
            $anyRecoverySecret = Test-SettingsAnyRecoverySecretEntered
            $recoveryApprovalValid = $state.ModuleReady -and ((-not $anyRecoverySecret) -or (Test-SettingsRecoveryInputsValid))
        }
        elseif ($credentialReplacementRequired) {
            $controls['ApprovalCheckBox'].Content = '중단된 자격 증명 교체를 안전하게 완료하려면 기록에 묶인 모델 API 키와 선택 채널 토큰을 모두 다시 입력해 같은 ID에 교체하고 Gateway를 재시작한 뒤 전체 검사를 실행하는 데 동의합니다.'
            [Windows.Automation.AutomationProperties]::SetName($controls['ApprovalCheckBox'], '필수 자격 증명 전체 교체와 Gateway 재시작 동의')
            $controls['ApplyButton'].Content = '자격 증명 교체 및 재검사'
            [Windows.Automation.AutomationProperties]::SetName($controls['ApplyButton'], '기록에 묶인 자격 증명 전체를 교체하고 Gateway를 재시작한 뒤 사후 검사 실행')
            $recoveryApprovalValid = $state.ModuleReady -and (Test-SettingsRecoveryInputsValid)
        }
        else {
            $controls['ApprovalCheckBox'].Content = 'Gateway를 재시작하고 전체 사후 검사를 실행하는 데 동의합니다. 비밀을 입력했다면 같은 ID에 함께 교체합니다.'
            [Windows.Automation.AutomationProperties]::SetName($controls['ApprovalCheckBox'], 'Gateway 재시작과 선택적 복구 자격 증명 교체 승인')
            $controls['ApplyButton'].Content = 'Gateway 재시작 및 재검사'
            [Windows.Automation.AutomationProperties]::SetName($controls['ApplyButton'], 'Gateway를 재시작하고 전체 사후 검사 실행')
            $anyRecoverySecret = Test-SettingsAnyRecoverySecretEntered
            $recoveryApprovalValid = $state.ModuleReady -and ((-not $anyRecoverySecret) -or (Test-SettingsRecoveryInputsValid))
        }
        $controls['ApprovalCheckBox'].IsEnabled = $recoveryApprovalValid
        $controls['ApplyButton'].IsEnabled = $recoveryApprovalValid -and $controls['ApprovalCheckBox'].IsChecked -eq $true
        return
    }
    $controls['PreviewButton'].Content = '미리보기 만들기'
    [Windows.Automation.AutomationProperties]::SetName($controls['PreviewButton'], '설정 변경 미리보기 만들기')
    $controls['ApprovalCheckBox'].Content = '위 미리보기의 변경 사항을 이 PC에 적용하는 데 동의합니다.'
    [Windows.Automation.AutomationProperties]::SetName($controls['ApprovalCheckBox'], '설정 변경 적용 승인')
    $controls['ApplyButton'].Content = '안전하게 적용'
    [Windows.Automation.AutomationProperties]::SetName($controls['ApplyButton'], '승인한 설정 안전하게 적용')
    if ($state.PartialApplied) {
        $controls['PreviewButton'].IsEnabled = $false
        $controls['ApprovalCheckBox'].IsEnabled = $false
        $controls['ApplyButton'].IsEnabled = $false
        return
    }

    $inputsValid = $state.ModuleReady -and (Test-SettingsInputsValid)
    $hasPlan = $null -ne $state.Plan
    $controls['PreviewButton'].IsEnabled = $inputsValid
    $controls['ApprovalCheckBox'].IsEnabled = $hasPlan
    $controls['ApplyButton'].IsEnabled = $inputsValid -and $hasPlan -and $controls['ApprovalCheckBox'].IsChecked -eq $true
}

function Invalidate-SettingsPreview {
    param([bool]$Announce = $false)

    $state.Plan = $null
    if ($null -eq $state.PendingRecovery) {
        $state.CredentialReplacementRequired = $false
    }
    $controls['PreviewTextBox'].Clear()
    $controls['ApprovalCheckBox'].IsChecked = $false
    $controls['ApprovalCheckBox'].IsEnabled = $false
    $controls['ApplyButton'].IsEnabled = $false
    if ($Announce) {
        Set-SettingsStatus -Text '입력이 바뀌어 기존 미리보기와 승인을 해제했습니다. 새 미리보기를 만들어 주세요.'
    }
    Update-SettingsActionState
}

function Update-SettingsChannelState {
    $slackEnabled = $controls['SlackCheckBox'].IsChecked -eq $true
    $telegramEnabled = $controls['TelegramCheckBox'].IsChecked -eq $true
    $discordEnabled = $controls['DiscordCheckBox'].IsChecked -eq $true
    $recoveryReplaceEnabled = (-not $state.Busy) -and (Test-SettingsRecoveryCanReplace)
    $normalInputEnabled = (-not $state.Busy) -and (-not $state.PartialApplied)
    $controls['SlackBotTokenPasswordBox'].IsEnabled = ($normalInputEnabled -or $recoveryReplaceEnabled) -and $slackEnabled
    $controls['SlackAppTokenPasswordBox'].IsEnabled = ($normalInputEnabled -or $recoveryReplaceEnabled) -and $slackEnabled
    $controls['TelegramTokenPasswordBox'].IsEnabled = ($normalInputEnabled -or $recoveryReplaceEnabled) -and $telegramEnabled
    $controls['DiscordTokenPasswordBox'].IsEnabled = ($normalInputEnabled -or $recoveryReplaceEnabled) -and $discordEnabled
    if (-not $slackEnabled) {
        $controls['SlackBotTokenPasswordBox'].Clear()
        $controls['SlackAppTokenPasswordBox'].Clear()
    }
    if (-not $telegramEnabled) {
        $controls['TelegramTokenPasswordBox'].Clear()
    }
    if (-not $discordEnabled) {
        $controls['DiscordTokenPasswordBox'].Clear()
    }
}

function Update-SettingsModelItems {
    $previousSuppression = [bool]$state.SuppressInputEvents
    $state.SuppressInputEvents = $true
    try {
        $selectedProvider = $controls['ProviderComboBox'].SelectedItem
        $models = @()
        if ($null -ne $selectedProvider) {
            $models = @($selectedProvider.Models)
        }
        $controls['ModelComboBox'].ItemsSource = $models
        $controls['ModelComboBox'].SelectedIndex = if ($models.Count -gt 0) { 0 } else { -1 }
    }
    finally {
        $state.SuppressInputEvents = $previousSuppression
    }
    Invalidate-SettingsPreview -Announce:$false
    if ($controls['ModelComboBox'].Items.Count -eq 0 -and -not $SmokeTest -and -not $state.HasFailure) {
        Set-SettingsStatus -Text '선택한 제공자에는 현재 설치에서 확인된 모델이 없습니다. 공식 고급 설정을 사용하거나 OpenClaw를 업데이트하세요.'
    }
}

function Set-SettingsBusy {
    param([bool]$Busy)

    $state.Busy = $Busy
    $controls['BusyProgressBar'].Visibility = if ($Busy) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    foreach ($controlName in @('ProviderComboBox', 'ModelComboBox', 'SlackCheckBox', 'TelegramCheckBox', 'DiscordCheckBox')) {
        $controls[$controlName].IsEnabled = (-not $Busy) -and (-not $state.PartialApplied)
    }
    $controls['ApiKeyPasswordBox'].IsEnabled = (-not $Busy) -and ((-not $state.PartialApplied) -or (Test-SettingsRecoveryCanReplace))
    $controls['AdvancedButton'].IsEnabled = (-not $Busy) -and (-not $state.RecoveryGuardError)
    $controls['CancelButton'].IsEnabled = -not $Busy
    Update-SettingsChannelState
    Update-SettingsActionState
}

function Test-SettingsOperationSucceeded {
    param(
        [AllowNull()]
        [object]$Result
    )

    if ($Result -is [bool]) {
        return [bool]$Result
    }
    foreach ($propertyName in @('Succeeded', 'Passed', 'Valid')) {
        $value = Get-SettingsMemberValue -InputObject $Result -Names @($propertyName)
        if ($null -ne $value) {
            return [bool]$value
        }
    }
    return $true
}

function Protect-SettingsPreviewText {
    param(
        [AllowNull()]
        [object]$Preview
    )

    if ($null -eq $Preview) {
        return '안전한 dry-run이 완료되었으며 표시할 설정 변경이 없습니다.'
    }
    $text = [string]$Preview
    if ([string]::IsNullOrWhiteSpace($text)) {
        return '안전한 dry-run이 완료되었으며 표시할 설정 변경이 없습니다.'
    }

    $safeLines = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($text -split '\r?\n' | Select-Object -First 300)) {
        $safeLine = [string]$line
        $safeLine = [regex]::Replace(
            $safeLine,
            '(?i)(api[-_ ]?key|bot[-_ ]?token|gateway[-_ ]?token|password|secret)(\s*[=:]\s*)(?!\[REDACTED\]|\*\*\*|<redacted>).*$',
            '$1$2[REDACTED]'
        )
        $safeLine = [regex]::Replace($safeLine, '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{8,}', 'Bearer [REDACTED]')
        $safeLine = [regex]::Replace($safeLine, '(?i)\bsk-[A-Za-z0-9_-]{8,}', '[REDACTED]')
        if ($safeLine.Length -gt 1000) {
            $safeLine = $safeLine.Substring(0, 1000) + ' …'
        }
        $safeLines.Add($safeLine)
    }
    $safeText = $safeLines.ToArray() -join [Environment]::NewLine
    if ($safeText.Length -gt 32768) {
        $safeText = $safeText.Substring(0, 32768) + [Environment]::NewLine + '[미리보기 일부 생략]'
    }
    return $safeText
}

function Get-SettingsFailedCheckDetails {
    param(
        [AllowNull()]
        [object[]]$Checks
    )

    $details = New-Object System.Collections.Generic.List[string]
    foreach ($check in @($Checks)) {
        if ($null -eq $check -or (Get-SettingsMemberValue -InputObject $check -Names @('Passed')) -eq $true) {
            continue
        }
        $checkName = [string](Get-SettingsMemberValue -InputObject $check -Names @('Name'))
        if ([string]::IsNullOrWhiteSpace($checkName)) { $checkName = 'Unknown post-apply check' }
        $checkExitCode = Get-SettingsMemberValue -InputObject $check -Names @('ExitCode')
        $checkDetail = [string](Get-SettingsMemberValue -InputObject $check -Names @('Detail'))
        $failureKind = if ($null -eq $checkExitCode -or [int]$checkExitCode -lt 0) {
            '명령 실행 오류'
        }
        elseif ([int]$checkExitCode -eq 0) {
            '상태 검증 실패'
        }
        else {
            '종료 코드 {0}' -f [int]$checkExitCode
        }
        $safeDetail = if ([string]::IsNullOrWhiteSpace($checkDetail)) { '' } else { Protect-SettingsPreviewText -Preview $checkDetail }
        $details.Add(('{0} ({1}){2}' -f $checkName, $failureKind, $(if ([string]::IsNullOrWhiteSpace($safeDetail)) { '' } else { ': ' + $safeDetail })))
    }
    return $details.ToArray()
}

function Set-SettingsPendingRecoveryView {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Recovery,
        [AllowNull()]
        [object[]]$Checks
    )

    $plan = Get-SettingsMemberValue -InputObject $Recovery -Names @('Plan')
    if ($null -eq $plan) {
        throw 'The pending recovery record did not contain its approved plan.'
    }
    $providerId = [string](Get-SettingsMemberValue -InputObject $plan -Names @('ProviderId'))
    $modelId = [string](Get-SettingsMemberValue -InputObject $plan -Names @('ModelId'))
    $providerItem = @($controls['ProviderComboBox'].Items | Where-Object {
        [string]::Equals([string]$_.Id, $providerId, [StringComparison]::Ordinal)
    } | Select-Object -First 1)
    if ($providerItem.Count -ne 1) {
        throw 'The pending recovery provider was not available in the reviewed catalog.'
    }
    $modelItem = @($providerItem[0].Models | Where-Object {
        [string]::Equals([string]$_.Id, $modelId, [StringComparison]::Ordinal)
    } | Select-Object -First 1)
    if ($modelItem.Count -ne 1) {
        throw 'The pending recovery model was not available in the reviewed catalog.'
    }

    $state.SuppressInputEvents = $true
    try {
        $controls['ProviderComboBox'].SelectedItem = $providerItem[0]
        $controls['ModelComboBox'].ItemsSource = @($providerItem[0].Models)
        $controls['ModelComboBox'].SelectedItem = $modelItem[0]
        $controls['SlackCheckBox'].IsChecked = (Get-SettingsMemberValue -InputObject $plan -Names @('EnableSlack')) -eq $true
        $controls['TelegramCheckBox'].IsChecked = (Get-SettingsMemberValue -InputObject $plan -Names @('EnableTelegram')) -eq $true
        $controls['DiscordCheckBox'].IsChecked = (Get-SettingsMemberValue -InputObject $plan -Names @('EnableDiscord')) -eq $true
        $controls['ApprovalCheckBox'].IsChecked = $false
    }
    finally {
        $state.SuppressInputEvents = $false
    }

    $receiptChecks = @((Get-SettingsMemberValue -InputObject $Recovery -Names @('Checks')))
    $effectiveChecks = if ($PSBoundParameters.ContainsKey('Checks')) { @($Checks) } else { $receiptChecks }
    $requirementChecks = @($receiptChecks)
    if ($PSBoundParameters.ContainsKey('Checks')) {
        $requirementChecks += @($effectiveChecks)
    }
    $state.PendingRecovery = $Recovery
    $state.PartialApplied = $true
    $state.HasFailure = $true
    $state.ExitCode = 42
    $state.Plan = $null
    $state.AcceptConfigChangeRequired = @($requirementChecks | Where-Object {
        [string](Get-SettingsMemberValue -InputObject $_ -Names @('Name')) -in @(
            'Configuration drift recovery authorization',
            'Approved patch continuity',
            'Recovery configuration continuity'
        ) -and (Get-SettingsMemberValue -InputObject $_ -Names @('Passed')) -ne $true
    }).Count -gt 0
    $state.CredentialReplacementRequired = @($requirementChecks | Where-Object {
        [string](Get-SettingsMemberValue -InputObject $_ -Names @('Name')) -in @(
            'Credential replacement pending',
            'Credential replacement recovery'
        ) -and (Get-SettingsMemberValue -InputObject $_ -Names @('Passed')) -ne $true
    }).Count -gt 0
    foreach ($controlName in @('ProviderComboBox', 'ModelComboBox', 'SlackCheckBox', 'TelegramCheckBox', 'DiscordCheckBox')) {
        $controls[$controlName].IsEnabled = $false
    }
    $controls['ApiKeyPasswordBox'].IsEnabled = (-not $state.Busy) -and (Test-SettingsRecoveryCanReplace)
    Update-SettingsChannelState

    $status = [string](Get-SettingsMemberValue -InputObject $Recovery -Names @('Status'))
    $pendingCount = [int](Get-SettingsMemberValue -InputObject $Recovery -Names @('PendingCount'))
    $receiptPath = [string](Get-SettingsMemberValue -InputObject $Recovery -Names @('Path'))
    $failedCheckDetails = @(Get-SettingsFailedCheckDetails -Checks $effectiveChecks)
    $failedSummary = if ($failedCheckDetails.Count -gt 0) {
        $failedCheckDetails -join [Environment]::NewLine
    }
    else {
        '아직 완료되지 않은 작업의 사후 검사가 필요합니다.'
    }
    $statusExplanation = switch ($status) {
        'Preparing' { '이전 작업이 설정 적용 전후의 경계에서 중단되었습니다. 아래 재검사 버튼은 설정이 바뀌지 않았을 때 이 실행에서 만든 자격 증명만 정확히 정리합니다.' }
        'AppliedPendingChecks' { '설정은 적용되었지만 사후 검사가 끝나기 전에 작업이 중단되었습니다.' }
        'Partial' { '설정은 적용되었지만 하나 이상의 사후 검사가 실패했거나 복구 확인이 필요합니다.' }
        default { '완료되지 않은 복구 기록이 있어 새 설정 적용을 차단했습니다.' }
    }
    $replacementExplanation = if (Test-SettingsRecoveryCanReplace) {
        if ($state.AcceptConfigChangeRequired -and $state.CredentialReplacementRequired) {
            '현재 설정 파일이 복구 기록과 다르고, 이전의 전체 자격 증명 교체도 완료 지점을 기록하기 전에 중단되었습니다. 모델 API 키와 기록에 선택된 모든 채널 토큰을 반드시 다시 입력해야 합니다. 별도 승인하면 Easy Setup 소유 경로를 이전 안전 패치로 복원하고 완전한 자격 증명 세트를 같은 ID에 다시 교체한 뒤 Gateway를 재시작하고 전체 검사를 실행합니다.'
        }
        elseif ($state.AcceptConfigChangeRequired) {
            '현재 설정 파일이 복구 기록과 달라 자동 성공 처리를 중단했습니다. 별도 승인하면 다른 사용자 설정은 유지하고, 기록의 계획 지문에 묶인 Gateway 인증·기본 모델·선택 공급자·선택 채널·resolver 경로만 이전 안전 패치로 복원한 뒤 새 해시를 기록합니다. 비밀 입력란을 모두 비워두면 기존 자격 증명을 유지하고, 하나라도 입력하려면 모델·선택 채널 값을 모두 입력해야 합니다.'
        }
        elseif ($state.CredentialReplacementRequired) {
            '이전의 전체 자격 증명 교체가 완료 지점을 기록하기 전에 중단되었습니다. 서로 다른 시점의 키가 섞인 상태를 성공으로 간주하지 않으므로, 모델 API 키와 기록에 선택된 모든 채널 토큰을 반드시 다시 입력하고 승인해 같은 ID에 전체 세트를 다시 교체해야 합니다. 생성된 Gateway 토큰은 바꾸지 않습니다.'
        }
        else {
            '먼저 “읽기 전용 사후 검사”를 눌러 보세요. Gateway 재시작이 필요하면 비밀 입력을 비워둔 채 별도 승인할 수 있습니다. 키나 봇 토큰이 잘못된 경우에는 비밀 입력란을 모두 다시 입력하고 승인하면 같은 자격 증명 ID에 교체합니다. 생성된 Gateway 토큰은 바꾸지 않습니다.'
        }
    }
    else {
        '이 상태에서는 새 비밀을 입력하지 않습니다. 표시된 정리 버튼으로 설정 해시가 그대로일 때 이번 실행의 정확한 자격 증명만 정리할 수 있습니다.'
    }
    $multipleWarning = if ($pendingCount -gt 1) {
        "주의: 미완료 복구 기록이 $pendingCount개라 자동 복구를 차단했습니다. docs/easy-setup.md의 수동 검토 절차를 확인하세요."
    }
    else { '' }

    $recoveryLines = @(
        "복구 필요 상태: $status"
        ''
        $statusExplanation
        ''
        '확인할 검사:'
        $failedSummary
        ''
        "복구 기록: $receiptPath"
        $multipleWarning
        ''
        $replacementExplanation
        '자동 롤백이나 새 설정의 무작정 재적용은 수행하지 않습니다.'
    ) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }
    $controls['PreviewTextBox'].Text = @($recoveryLines) -join [Environment]::NewLine
    Set-SettingsStatus -Text '[복구 필요] 완료되지 않은 Easy Setup 기록을 감지해 새 적용을 차단했습니다. 사후 검사 또는 정확한 자격 증명 교체를 진행하세요. (OCES-SETTINGS-PARTIAL-042)'
    Update-SettingsActionState
}

function Set-SettingsRecoveryGuardFailure {
    $state.PendingRecovery = $null
    $state.AcceptConfigChangeRequired = $false
    $state.CredentialReplacementRequired = $false
    $state.PartialApplied = $true
    $state.RecoveryGuardError = $true
    $state.HasFailure = $true
    $state.ExitCode = 42
    $state.Plan = $null
    Clear-SettingsSecretInputs
    $controls['PreviewTextBox'].Text = @(
        '복구 기록을 안전하게 읽거나 검증할 수 없습니다.'
        ''
        '새 설정 적용과 자격 증명 변경을 중단했습니다. 복구 기록을 삭제하거나 수정하지 말고 docs/easy-setup.md의 수동 검토 절차를 확인하세요.'
    ) -join [Environment]::NewLine
    Set-SettingsStatus -Text '[오류] 복구 기록의 무결성을 확인할 수 없어 모든 새 적용을 차단했습니다. (OCES-SETTINGS-RECOVERY-042)'
    Set-SettingsBusy -Busy $false
}

function Complete-SettingsRecoveryResult {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Result
    )

    $resolved = (Get-SettingsMemberValue -InputObject $Result -Names @('Resolved')) -eq $true
    $status = [string](Get-SettingsMemberValue -InputObject $Result -Names @('Status'))
    if ($resolved -and $status -eq 'Succeeded') {
        $state.PendingRecovery = $null
        $state.AcceptConfigChangeRequired = $false
        $state.CredentialReplacementRequired = $false
        $state.PartialApplied = $false
        $state.HasFailure = $false
        $state.ExitCode = 0
        $state.ClosingAllowed = $true
        Set-SettingsStatus -Text '복구 사후 검사와 안전 검사가 모두 완료되었습니다.'
        $window.Close()
        return $true
    }
    if ($resolved -and $status -in @('RolledBack', 'None')) {
        $state.PendingRecovery = $null
        $state.AcceptConfigChangeRequired = $false
        $state.CredentialReplacementRequired = $false
        $state.PartialApplied = $false
        $state.HasFailure = $false
        $state.ExitCode = 61
        $state.Plan = $null
        Clear-SettingsSecretInputs
        $controls['PreviewTextBox'].Text = '중단된 적용 전 작업에서 만든 자격 증명을 안전하게 정리했습니다. 새 설정을 적용하려면 입력을 확인하고 새 미리보기를 만드세요.'
        Set-SettingsStatus -Text '중단된 이전 작업을 안전하게 정리했습니다. 새 미리보기부터 다시 시작할 수 있습니다.'
        return $false
    }

    try {
        $pending = Get-OpenClawSafeSetupPendingRecovery -StateDirectory $effectiveStateDirectory
        if ($null -eq $pending) {
            throw 'An unresolved recovery result had no pending receipt.'
        }
        Set-SettingsPendingRecoveryView -Recovery $pending -Checks @((Get-SettingsMemberValue -InputObject $Result -Names @('Checks')))
    }
    catch {
        Set-SettingsRecoveryGuardFailure
    }
    return $false
}

function Start-OfficialSettingsAdvancedSetup {
    $powerShellPath = Get-TrustedSettingsWindowsPowerShellPath
    $entryPointPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'OpenClawEasySetup.ps1'))
    if (-not (Test-Path -LiteralPath $entryPointPath -PathType Leaf)) {
        throw 'The official setup entry point was not found.'
    }
    $entryPointItem = Get-Item -LiteralPath $entryPointPath -Force
    if (($entryPointItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The official setup entry point was a reparse point.'
    }

    $arguments = New-Object System.Collections.Generic.List[string]
    foreach ($argument in @(
        '-NoLogo', '-NoProfile', '-File', $entryPointPath,
        '-Action', 'Configure', '-Apply', '-GuiApproved'
    )) {
        $arguments.Add([string]$argument)
    }
    if (-not [string]::IsNullOrWhiteSpace($effectiveStateDirectory)) {
        foreach ($argument in @('-StateDirectory', $effectiveStateDirectory)) {
            $arguments.Add([string]$argument)
        }
    }

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powerShellPath
    $startInfo.Arguments = (@($arguments.ToArray() | ForEach-Object { ConvertTo-SettingsWindowsArgument -Argument $_ }) -join ' ')
    $startInfo.WorkingDirectory = $PSScriptRoot
    $startInfo.UseShellExecute = $true
    $startInfo.CreateNoWindow = $false
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Normal
    $process = [Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process) {
        throw 'The official advanced setup process did not start.'
    }
    try {
        $process.WaitForExit()
        return [int]$process.ExitCode
    }
    finally {
        $process.Dispose()
    }
}

$controls['ProviderComboBox'].add_SelectionChanged({
    if ($state.SuppressInputEvents) {
        return
    }
    Update-SettingsModelItems
})
$controls['ModelComboBox'].add_SelectionChanged({
    if (-not $state.SuppressInputEvents) {
        Invalidate-SettingsPreview -Announce:$true
    }
})
$controls['ApiKeyPasswordBox'].add_PasswordChanged({
    if (-not $state.SuppressInputEvents) {
        if ($null -ne $state.PendingRecovery) {
            $controls['ApprovalCheckBox'].IsChecked = $false
            Update-SettingsActionState
        }
        else {
            Invalidate-SettingsPreview -Announce:$false
        }
    }
})
$controls['SlackCheckBox'].add_Click({
    if ($state.SuppressInputEvents) {
        return
    }
    Update-SettingsChannelState
    Invalidate-SettingsPreview -Announce:$true
})
foreach ($slackPasswordBoxName in @('SlackBotTokenPasswordBox', 'SlackAppTokenPasswordBox')) {
    $controls[$slackPasswordBoxName].add_PasswordChanged({
        if (-not $state.SuppressInputEvents) {
            if ($null -ne $state.PendingRecovery) {
                $controls['ApprovalCheckBox'].IsChecked = $false
                Update-SettingsActionState
            }
            else {
                Invalidate-SettingsPreview -Announce:$false
            }
        }
    })
}
$controls['TelegramCheckBox'].add_Click({
    if ($state.SuppressInputEvents) {
        return
    }
    Update-SettingsChannelState
    Invalidate-SettingsPreview -Announce:$true
})
$controls['TelegramTokenPasswordBox'].add_PasswordChanged({
    if (-not $state.SuppressInputEvents) {
        if ($null -ne $state.PendingRecovery) {
            $controls['ApprovalCheckBox'].IsChecked = $false
            Update-SettingsActionState
        }
        else {
            Invalidate-SettingsPreview -Announce:$false
        }
    }
})
$controls['DiscordCheckBox'].add_Click({
    if ($state.SuppressInputEvents) {
        return
    }
    Update-SettingsChannelState
    Invalidate-SettingsPreview -Announce:$true
})
$controls['DiscordTokenPasswordBox'].add_PasswordChanged({
    if (-not $state.SuppressInputEvents) {
        if ($null -ne $state.PendingRecovery) {
            $controls['ApprovalCheckBox'].IsChecked = $false
            Update-SettingsActionState
        }
        else {
            Invalidate-SettingsPreview -Announce:$false
        }
    }
})
$controls['ApprovalCheckBox'].add_Checked({ Update-SettingsActionState })
$controls['ApprovalCheckBox'].add_Unchecked({ Update-SettingsActionState })

$controls['PreviewButton'].add_Click({
    if ($SmokeTest) {
        Set-SettingsStatus -Text 'Smoke test에서는 외부 설정 API를 호출하지 않습니다.'
        return
    }
    if ($null -ne $state.PendingRecovery) {
        Set-SettingsBusy -Busy $true
        Set-SettingsStatus -Text '중단되거나 일부 적용된 설정의 사후 검사를 다시 실행하는 중입니다…'
        try {
            $state.ExternalApiCalls++
            $recoveryResult = Invoke-OpenClawSafeSetupRecoveryVerification `
                -StateDirectory $effectiveStateDirectory `
                -Confirm:$false
            [void](Complete-SettingsRecoveryResult -Result $recoveryResult)
        }
        catch {
            $state.HasFailure = $true
            $state.ExitCode = 42
            try {
                $pending = Get-OpenClawSafeSetupPendingRecovery -StateDirectory $effectiveStateDirectory
                if ($null -eq $pending) { throw 'The pending recovery record disappeared unexpectedly.' }
                Set-SettingsPendingRecoveryView -Recovery $pending -Checks @([pscustomobject]@{
                    Name = 'Recovery verification'
                    Passed = $false
                    ExitCode = -1
                    Detail = 'The recovery verification could not be completed safely.'
                })
            }
            catch {
                Set-SettingsRecoveryGuardFailure
            }
        }
        finally {
            if (-not $state.ClosingAllowed) {
                Set-SettingsBusy -Busy $false
            }
        }
        return
    }
    if (-not (Test-SettingsInputsValid)) {
        Set-SettingsStatus -Text '제공자, 모델, API 키와 선택한 채널의 토큰을 모두 입력해 주세요.'
        return
    }

    Set-SettingsBusy -Busy $true
    Set-SettingsStatus -Text '안전한 설정 계획과 dry-run 미리보기를 만드는 중입니다…'
    try {
        $providerId = [string]$controls['ProviderComboBox'].SelectedItem.Id
        $modelId = [string]$controls['ModelComboBox'].SelectedItem.Id
        $enableSlack = $controls['SlackCheckBox'].IsChecked -eq $true
        $enableTelegram = $controls['TelegramCheckBox'].IsChecked -eq $true
        $enableDiscord = $controls['DiscordCheckBox'].IsChecked -eq $true

        $state.ExternalApiCalls++
        $plan = New-OpenClawSafeSetupPlan `
            -ProviderId $providerId `
            -ModelId $modelId `
            -EnableSlack:$enableSlack `
            -EnableTelegram:$enableTelegram `
            -EnableDiscord:$enableDiscord `
            -StateDirectory $effectiveStateDirectory

        $state.ExternalApiCalls++
        $dryRunResult = Invoke-OpenClawSafeSetupDryRun -Plan $plan -StateDirectory $effectiveStateDirectory
        if (-not (Test-SettingsOperationSucceeded -Result $dryRunResult)) {
            throw 'The safe setup dry-run did not succeed.'
        }

        $state.ExternalApiCalls++
        $preview = Get-OpenClawSafeSetupPreview -Plan $plan
        $controls['PreviewTextBox'].Text = Protect-SettingsPreviewText -Preview $preview
        $state.Plan = $plan
        $controls['ApprovalCheckBox'].IsChecked = $false
        $controls['ApprovalCheckBox'].IsEnabled = $true
        Set-SettingsStatus -Text '미리보기와 dry-run 검사가 완료되었습니다. 내용을 확인한 뒤 적용 승인을 선택하세요.'
    }
    catch {
        Invalidate-SettingsPreview -Announce:$false
        Show-SettingsFailure -Phase Preview
    }
    finally {
        Set-SettingsBusy -Busy $false
    }
})

$controls['ApplyButton'].add_Click({
    if ($SmokeTest) {
        Set-SettingsStatus -Text 'Smoke test에서는 외부 설정 또는 자격 증명 API를 호출하지 않습니다.'
        return
    }
    if ($null -ne $state.PendingRecovery) {
        $acceptConfigChange = [bool]$state.AcceptConfigChangeRequired
        $credentialReplacementRequired = [bool]$state.CredentialReplacementRequired
        $anyRecoverySecret = Test-SettingsAnyRecoverySecretEntered
        $replaceRecoverySecrets = $credentialReplacementRequired -or $anyRecoverySecret
        $recoveryInputContractValid = if ($credentialReplacementRequired) {
            Test-SettingsRecoveryInputsValid
        }
        else {
            (-not $replaceRecoverySecrets) -or (Test-SettingsRecoveryInputsValid)
        }
        if (-not $recoveryInputContractValid -or $controls['ApprovalCheckBox'].IsChecked -ne $true) {
            Set-SettingsStatus -Text $(if ($acceptConfigChange -and $credentialReplacementRequired) {
                '승인된 Easy Setup 패치 복원 동의와 함께, 기록에 묶인 모델 API 키와 선택 채널 토큰을 모두 다시 입력해야 합니다.'
            }
            elseif ($acceptConfigChange) {
                '승인된 Easy Setup 패치 복원 동의를 직접 선택해 주세요. 비밀을 하나라도 입력했다면 기록에 묶인 모델·채널 값을 모두 입력해야 합니다.'
            }
            elseif ($credentialReplacementRequired) {
                '중단된 자격 증명 교체를 복구하려면 기록에 묶인 모델 API 키와 선택 채널 토큰을 모두 다시 입력하고 교체 승인을 선택해 주세요.'
            }
            else {
                'Gateway 재시작 승인을 직접 선택해 주세요. 비밀을 하나라도 입력했다면 기록에 묶인 모델·채널 값을 모두 입력해야 합니다.'
            })
            return
        }

        Set-SettingsBusy -Busy $true
        Set-SettingsStatus -Text $(if ($acceptConfigChange -and $credentialReplacementRequired) {
            'Easy Setup 소유 경로를 이전 승인 패치로 복원하고, 기록에 묶인 자격 증명 전체를 같은 ID에 다시 교체한 뒤 Gateway와 사후 검사를 복구하는 중입니다…'
        }
        elseif ($acceptConfigChange) {
            'Easy Setup 소유 경로를 이전 승인 패치로 복원하고 새 해시를 기록한 뒤 Gateway를 다시 시작하는 중입니다…'
        }
        elseif ($credentialReplacementRequired) {
            '기록에 묶인 모델·선택 채널 자격 증명 전체를 같은 ID에 다시 교체한 뒤 Gateway와 사후 검사를 복구하는 중입니다…'
        }
        else {
            '승인에 따라 Gateway를 다시 시작하고, 입력한 비밀이 있으면 같은 자격 증명 ID에 저장한 뒤 사후 검사를 실행하는 중입니다…'
        })
        $recoveryCredentialMap = @{}
        $recoveryOwnedSecrets = New-Object 'System.Collections.Generic.List[System.Security.SecureString]'
        try {
            $pendingPlan = Get-SettingsMemberValue -InputObject $state.PendingRecovery -Names @('Plan')
            if ($null -eq $pendingPlan) {
                throw 'The pending recovery plan was unavailable.'
            }
            if ($replaceRecoverySecrets) {
                $modelApiKey = Copy-SettingsPasswordSecret -PasswordBox $controls['ApiKeyPasswordBox']
                $recoveryOwnedSecrets.Add($modelApiKey)
                $recoveryCredentialMap['ModelApiKey'] = $modelApiKey
                if ((Get-SettingsMemberValue -InputObject $pendingPlan -Names @('EnableSlack')) -eq $true) {
                    $slackBotToken = Copy-SettingsPasswordSecret -PasswordBox $controls['SlackBotTokenPasswordBox']
                    $recoveryOwnedSecrets.Add($slackBotToken)
                    $recoveryCredentialMap['SlackBotToken'] = $slackBotToken
                    $slackAppToken = Copy-SettingsPasswordSecret -PasswordBox $controls['SlackAppTokenPasswordBox']
                    $recoveryOwnedSecrets.Add($slackAppToken)
                    $recoveryCredentialMap['SlackAppToken'] = $slackAppToken
                }
                if ((Get-SettingsMemberValue -InputObject $pendingPlan -Names @('EnableTelegram')) -eq $true) {
                    $telegramBotToken = Copy-SettingsPasswordSecret -PasswordBox $controls['TelegramTokenPasswordBox']
                    $recoveryOwnedSecrets.Add($telegramBotToken)
                    $recoveryCredentialMap['TelegramBotToken'] = $telegramBotToken
                }
                if ((Get-SettingsMemberValue -InputObject $pendingPlan -Names @('EnableDiscord')) -eq $true) {
                    $discordBotToken = Copy-SettingsPasswordSecret -PasswordBox $controls['DiscordTokenPasswordBox']
                    $recoveryOwnedSecrets.Add($discordBotToken)
                    $recoveryCredentialMap['DiscordBotToken'] = $discordBotToken
                }
            }

            $state.ExternalApiCalls++
            $recoveryResult = if ($replaceRecoverySecrets) {
                Invoke-OpenClawSafeSetupRecoveryVerification `
                    -StateDirectory $effectiveStateDirectory `
                    -CredentialMap $recoveryCredentialMap `
                    -AcceptConfigChange:$acceptConfigChange `
                    -EnsureGatewayService `
                    -Confirm:$false
            }
            else {
                Invoke-OpenClawSafeSetupRecoveryVerification `
                    -StateDirectory $effectiveStateDirectory `
                    -AcceptConfigChange:$acceptConfigChange `
                    -EnsureGatewayService `
                    -Confirm:$false
            }
            [void](Complete-SettingsRecoveryResult -Result $recoveryResult)
        }
        catch {
            $state.HasFailure = $true
            $state.ExitCode = 42
            try {
                $pending = Get-OpenClawSafeSetupPendingRecovery -StateDirectory $effectiveStateDirectory
                if ($null -eq $pending) { throw 'The pending recovery record disappeared unexpectedly.' }
                Set-SettingsPendingRecoveryView -Recovery $pending -Checks @([pscustomobject]@{
                    Name = 'Pending setup recovery'
                    Passed = $false
                    ExitCode = -1
                    Detail = 'The pending setup could not be accepted or verified safely.'
                })
            }
            catch {
                Set-SettingsRecoveryGuardFailure
            }
        }
        finally {
            Clear-SettingsSecretInputs
            foreach ($secret in $recoveryOwnedSecrets) {
                if ($null -ne $secret) { $secret.Dispose() }
            }
            $recoveryCredentialMap.Clear()
            if (-not $state.ClosingAllowed) {
                Set-SettingsBusy -Busy $false
            }
        }
        return
    }
    if ($null -eq $state.Plan -or $controls['ApprovalCheckBox'].IsChecked -ne $true -or -not (Test-SettingsInputsValid)) {
        Set-SettingsStatus -Text '새 미리보기를 확인하고 적용 승인을 직접 선택해 주세요.'
        return
    }

    Set-SettingsBusy -Busy $true
    Set-SettingsStatus -Text '승인한 설정을 적용하고 안전 검사를 실행하는 중입니다…'
    $credentialMap = @{}
    $ownedSecrets = New-Object 'System.Collections.Generic.List[System.Security.SecureString]'
    $applySucceeded = $false
    $partialApplied = $false
    try {
        $modelApiKey = Copy-SettingsPasswordSecret -PasswordBox $controls['ApiKeyPasswordBox']
        $ownedSecrets.Add($modelApiKey)
        $credentialMap['ModelApiKey'] = $modelApiKey

        if ($controls['SlackCheckBox'].IsChecked -eq $true) {
            $slackBotToken = Copy-SettingsPasswordSecret -PasswordBox $controls['SlackBotTokenPasswordBox']
            $ownedSecrets.Add($slackBotToken)
            $credentialMap['SlackBotToken'] = $slackBotToken
            $slackAppToken = Copy-SettingsPasswordSecret -PasswordBox $controls['SlackAppTokenPasswordBox']
            $ownedSecrets.Add($slackAppToken)
            $credentialMap['SlackAppToken'] = $slackAppToken
        }
        if ($controls['TelegramCheckBox'].IsChecked -eq $true) {
            $telegramBotToken = Copy-SettingsPasswordSecret -PasswordBox $controls['TelegramTokenPasswordBox']
            $ownedSecrets.Add($telegramBotToken)
            $credentialMap['TelegramBotToken'] = $telegramBotToken
        }
        if ($controls['DiscordCheckBox'].IsChecked -eq $true) {
            $discordBotToken = Copy-SettingsPasswordSecret -PasswordBox $controls['DiscordTokenPasswordBox']
            $ownedSecrets.Add($discordBotToken)
            $credentialMap['DiscordBotToken'] = $discordBotToken
        }

        $state.ExternalApiCalls++
        $gatewayToken = New-OpenClawGatewayToken
        if ($gatewayToken -isnot [Security.SecureString]) {
            throw 'The gateway token was not returned as a SecureString.'
        }
        $ownedSecrets.Add($gatewayToken)
        $credentialMap['GatewayToken'] = $gatewayToken

        $state.ExternalApiCalls++
        $applyResult = Invoke-OpenClawSafeSetupApply `
            -Plan $state.Plan `
            -CredentialMap $credentialMap `
            -StateDirectory $effectiveStateDirectory `
            -Confirm:$false
        $applied = Get-SettingsMemberValue -InputObject $applyResult -Names @('Applied')
        $succeeded = Get-SettingsMemberValue -InputObject $applyResult -Names @('Succeeded')
        $plaintextWritten = Get-SettingsMemberValue -InputObject $applyResult -Names @('PlaintextSecretsWrittenToConfig')
        if ($applied -ne $true) {
            throw 'The safe setup apply result did not pass its safety contract.'
        }
        $failedCheckDetails = New-Object System.Collections.Generic.List[string]
        foreach ($check in @(Get-SettingsMemberValue -InputObject $applyResult -Names @('Checks'))) {
            if ($null -ne $check -and (Get-SettingsMemberValue -InputObject $check -Names @('Passed')) -ne $true) {
                $checkName = [string](Get-SettingsMemberValue -InputObject $check -Names @('Name'))
                if ([string]::IsNullOrWhiteSpace($checkName)) {
                    $checkName = 'Unknown post-apply check'
                }
                $checkExitCode = Get-SettingsMemberValue -InputObject $check -Names @('ExitCode')
                $checkDetail = [string](Get-SettingsMemberValue -InputObject $check -Names @('Detail'))
                $failureKind = if ($null -eq $checkExitCode -or [int]$checkExitCode -lt 0) {
                    '명령 실행 오류'
                }
                elseif ([int]$checkExitCode -eq 0) {
                    '상태 검증 실패'
                }
                else {
                    '종료 코드 {0}' -f [int]$checkExitCode
                }
                $safeDetail = if ([string]::IsNullOrWhiteSpace($checkDetail)) { '' } else { Protect-SettingsPreviewText -Preview $checkDetail }
                $failedCheckDetails.Add(('{0} ({1}){2}' -f $checkName, $failureKind, $(if ([string]::IsNullOrWhiteSpace($safeDetail)) { '' } else { ': ' + $safeDetail })))
            }
        }
        if ($plaintextWritten -eq $true) {
            $failedCheckDetails.Add('No-plaintext configuration contract (상태 검증 실패)')
        }
        if ($succeeded -eq $true -and $failedCheckDetails.Count -eq 0) {
            $applySucceeded = $true
        }
        else {
            $partialApplied = $true
            $state.PartialApplied = $true
            $state.HasFailure = $true
            $state.ExitCode = 42
            $state.Plan = $null
            $controls['ApprovalCheckBox'].IsChecked = $false
            $failedSummary = if ($failedCheckDetails.Count -gt 0) { $failedCheckDetails.ToArray() -join [Environment]::NewLine } else { 'Unknown post-apply check' }
            $receiptPath = [string](Get-SettingsMemberValue -InputObject $applyResult -Names @('RecoveryReceiptPath'))
            $credentialIds = @((Get-SettingsMemberValue -InputObject $applyResult -Names @('CredentialIds')))
            $recoverySummary = if (-not [string]::IsNullOrWhiteSpace($receiptPath)) {
                "복구 기록: $receiptPath"
            }
            elseif ($credentialIds.Count -gt 0) {
                '복구 기록 쓰기 실패 — 보존할 자격 증명 ID: ' + ($credentialIds -join ', ')
            }
            else {
                '복구 기록과 자격 증명 ID를 확인할 수 없습니다. 같은 마법사를 다시 적용하지 마세요.'
            }
            $controls['PreviewTextBox'].Text = @(
                '일부 적용 상태: OpenClaw 설정과 자격 증명은 이미 적용되었습니다.'
                ''
                '실패한 검사:'
                $failedSummary
                ''
                $recoverySummary
                ''
                '자동 롤백되지 않았습니다. 같은 마법사를 무작정 다시 적용하면 이전 자격 증명 참조가 남을 수 있습니다.'
                '공식 고급 설정이나 정제된 진단 정보를 사용해 위 검사를 먼저 해결하세요.'
            ) -join [Environment]::NewLine
            Set-SettingsStatus -Text '[확인 필요] 설정은 적용됐지만 사후 검사를 모두 통과하지 못했습니다. 자동 롤백되지 않았으며 이 창에서 재적용은 차단했습니다. (OCES-SETTINGS-PARTIAL-042)'
            try {
                $state.PendingRecovery = Get-OpenClawSafeSetupPendingRecovery -StateDirectory $effectiveStateDirectory
                if ($null -eq $state.PendingRecovery) {
                    throw 'The partial apply did not leave a readable pending recovery receipt.'
                }
                Set-SettingsPendingRecoveryView -Recovery $state.PendingRecovery -Checks @((Get-SettingsMemberValue -InputObject $applyResult -Names @('Checks')))
            }
            catch {
                Set-SettingsRecoveryGuardFailure
            }
        }
    }
    catch {
        Invalidate-SettingsPreview -Announce:$false
        Show-SettingsFailure -Phase Apply
        try {
            $pendingAfterFailure = Get-OpenClawSafeSetupPendingRecovery -StateDirectory $effectiveStateDirectory
            if ($null -ne $pendingAfterFailure) {
                Set-SettingsPendingRecoveryView -Recovery $pendingAfterFailure
            }
        }
        catch {
            Set-SettingsRecoveryGuardFailure
        }
    }
    finally {
        Clear-SettingsSecretInputs
        foreach ($secret in $ownedSecrets) {
            if ($null -ne $secret) {
                $secret.Dispose()
            }
        }
        $credentialMap.Clear()
        Set-SettingsBusy -Busy $false
    }

    if ($applySucceeded) {
        Set-SettingsStatus -Text '설정 적용과 안전 검사가 완료되었습니다.'
        $state.ExitCode = 0
        $state.ClosingAllowed = $true
        $window.Close()
    }
    elseif ($partialApplied) {
        $controls['PreviewTextBox'].Focus()
    }
})

$controls['AdvancedButton'].add_Click({
    if ($SmokeTest) {
        Set-SettingsStatus -Text 'Smoke test에서는 공식 고급 설정 프로세스를 시작하지 않습니다.'
        return
    }
    Set-SettingsBusy -Busy $true
    Clear-SettingsSecretInputs
    Set-SettingsStatus -Text '별도의 보이는 창에서 공식 OpenClaw 고급 설정을 실행 중입니다. 해당 창을 완료하거나 닫아 주세요…'
    try {
        $advancedExitCode = Start-OfficialSettingsAdvancedSetup
        if ($advancedExitCode -ne 0 -and -not $state.PartialApplied) {
            throw ('The official advanced setup ended with exit code {0}.' -f $advancedExitCode)
        }
        $state.ExitCode = if ($state.PartialApplied) { 42 } else { 0 }
        if ($state.PartialApplied) {
            $state.HasFailure = $true
        }
        $state.ClosingAllowed = $true
        Set-SettingsStatus -Text $(if ($state.PartialApplied) {
            '공식 OpenClaw 고급 설정 창이 종료됐지만 일부 적용 상태는 사후 검사 재확인 전까지 유지됩니다.'
        }
        else {
            '공식 OpenClaw 고급 설정이 완료되었습니다.'
        })
        $window.Close()
    }
    catch {
        Show-SettingsFailure -Phase Advanced
    }
    finally {
        if (-not $state.ClosingAllowed) {
            Set-SettingsBusy -Busy $false
        }
    }
})

$controls['CancelButton'].add_Click({
    Clear-SettingsSecretInputs
    if (-not $state.HasFailure) {
        $state.ExitCode = 61
    }
    $state.ClosingAllowed = $true
    $window.Close()
})

$window.add_Closing({
    param($sender, $eventArgs)
    if ($state.Busy -and -not $state.ClosingAllowed) {
        $eventArgs.Cancel = $true
        Set-SettingsStatus -Text '현재 안전 작업이 끝날 때까지 창을 닫을 수 없습니다.'
        return
    }
    Clear-SettingsSecretInputs
    if (-not $state.ClosingAllowed) {
        $state.ExitCode = if ($state.HasFailure) { 42 } else { 61 }
        $state.ClosingAllowed = $true
    }
})
$window.add_Closed({ Clear-SettingsSecretInputs })

$recoveryInitializationError = $false
if (-not $SmokeTest -and $state.ModuleReady -and -not $stateDirectoryError) {
    try {
        $state.PendingRecovery = Get-OpenClawSafeSetupPendingRecovery -StateDirectory $effectiveStateDirectory
        if ($null -ne $state.PendingRecovery) {
            $state.PartialApplied = $true
            $state.HasFailure = $true
            $state.ExitCode = 42
        }
    }
    catch {
        $recoveryInitializationError = $true
        $state.ModuleReady = $false
        $state.PartialApplied = $true
        $state.RecoveryGuardError = $true
        $state.HasFailure = $true
        $state.ExitCode = 42
    }
}

$providerItems = @()
if ($SmokeTest) {
    $providerItems = @(
        [pscustomobject]@{ Id = 'openai'; Label = 'OpenAI'; Models = @([pscustomobject]@{ Id = 'smoke-openai-model'; Label = 'Smoke model (호출 안 함)' }) },
        [pscustomobject]@{ Id = 'anthropic'; Label = 'Anthropic'; Models = @([pscustomobject]@{ Id = 'smoke-anthropic-model'; Label = 'Smoke model (호출 안 함)' }) },
        [pscustomobject]@{ Id = 'google'; Label = 'Google'; Models = @([pscustomobject]@{ Id = 'smoke-google-model'; Label = 'Smoke model (호출 안 함)' }) }
    )
    $state.ModuleReady = $true
}
elseif (-not $state.ModuleReady -or $stateDirectoryError) {
    $state.ModuleReady = $false
    Show-SettingsFailure -Phase Initialization
    $providerItems = @(
        [pscustomobject]@{ Id = 'openai'; Label = 'OpenAI (현재 사용 불가)'; Models = @() },
        [pscustomobject]@{ Id = 'anthropic'; Label = 'Anthropic (현재 사용 불가)'; Models = @() },
        [pscustomobject]@{ Id = 'google'; Label = 'Google (현재 사용 불가)'; Models = @() }
    )
}
else {
    try {
        $state.ExternalApiCalls++
        $catalog = Get-OpenClawSafeSetupCatalog
        $providerItems = @(ConvertTo-SettingsProviderItems -Catalog $catalog)
        $catalogVersion = [string](Get-SettingsMemberValue -InputObject $catalog -Names @('Version'))
        if ([string]::IsNullOrWhiteSpace($catalogVersion)) {
            Set-SettingsStatus -Text '지원 모델 목록을 확인했습니다. 제공자와 모델을 선택하세요.'
        }
        else {
            Set-SettingsStatus -Text ("Easy Setup {0}의 검토 모델 목록을 확인했습니다." -f $catalogVersion)
        }
    }
    catch {
        $state.ModuleReady = $false
        Show-SettingsFailure -Phase Catalog
        $providerItems = @(
            [pscustomobject]@{ Id = 'openai'; Label = 'OpenAI (현재 사용 불가)'; Models = @() },
            [pscustomobject]@{ Id = 'anthropic'; Label = 'Anthropic (현재 사용 불가)'; Models = @() },
            [pscustomobject]@{ Id = 'google'; Label = 'Google (현재 사용 불가)'; Models = @() }
        )
    }
}

$state.SuppressInputEvents = $true
try {
    $controls['ProviderComboBox'].ItemsSource = $providerItems
    $controls['ProviderComboBox'].SelectedIndex = if ($providerItems.Count -gt 0) { 0 } else { -1 }
}
finally {
    $state.SuppressInputEvents = $false
}
Update-SettingsModelItems
Update-SettingsChannelState
Update-SettingsActionState
if ($recoveryInitializationError) {
    Set-SettingsRecoveryGuardFailure
}
elseif ($null -ne $state.PendingRecovery) {
    try {
        Set-SettingsPendingRecoveryView -Recovery $state.PendingRecovery
    }
    catch {
        Set-SettingsRecoveryGuardFailure
    }
}

if ($SmokeTest) {
    $window.ShowInTaskbar = $false
    $window.ShowActivated = $false
    $window.WindowStartupLocation = [Windows.WindowStartupLocation]::Manual
    $window.Width = 520
    $window.Height = 420
    $window.Left = -32000
    $window.Top = -32000
    $window.Opacity = 0
    $window.Show()
    $window.UpdateLayout()

    $interactiveNames = @($definition.InteractiveControls)
    $missingAccessibleNames = @($interactiveNames | Where-Object {
        [string]::IsNullOrWhiteSpace([Windows.Automation.AutomationProperties]::GetName($controls[$_]))
    })
    $missingTabIndexes = @($interactiveNames | Where-Object { $controls[$_].TabIndex -lt 0 })
    $controls['SlackCheckBox'].IsChecked = $true
    $controls['SlackCheckBox'].RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    $slackTokensEnabled = [bool]$controls['SlackBotTokenPasswordBox'].IsEnabled -and
        [bool]$controls['SlackAppTokenPasswordBox'].IsEnabled
    $controls['SlackCheckBox'].IsChecked = $false
    Update-SettingsChannelState
    $controls['TelegramCheckBox'].IsChecked = $true
    $controls['TelegramCheckBox'].RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    $telegramTokenEnabled = [bool]$controls['TelegramTokenPasswordBox'].IsEnabled
    $controls['TelegramCheckBox'].IsChecked = $false
    Update-SettingsChannelState
    Clear-SettingsSecretInputs
    $approvalDefaultOff = $controls['ApprovalCheckBox'].IsChecked -ne $true
    $applyDefaultDisabled = -not [bool]$controls['ApplyButton'].IsEnabled

    $smokePendingRecovery = [pscustomobject]@{
        Status = 'Partial'
        PendingCount = 1
        Path = 'smoke-settings-recovery.json'
        Checks = @([pscustomobject]@{ Name = 'Model status'; Passed = $false; ExitCode = 0; Detail = 'Smoke-only pending check.' })
        Plan = [pscustomobject]@{
            ProviderId = 'openai'
            ModelId = 'smoke-openai-model'
            EnableSlack = $true
            EnableTelegram = $true
            EnableDiscord = $false
        }
    }
    Set-SettingsPendingRecoveryView -Recovery $smokePendingRecovery
    $pendingSelectionLocked = -not [bool]$controls['ProviderComboBox'].IsEnabled -and
        -not [bool]$controls['ModelComboBox'].IsEnabled -and
        -not [bool]$controls['SlackCheckBox'].IsEnabled -and
        -not [bool]$controls['TelegramCheckBox'].IsEnabled -and
        -not [bool]$controls['DiscordCheckBox'].IsEnabled
    $pendingSecretReplacementAvailable = [bool]$controls['ApiKeyPasswordBox'].IsEnabled -and
        [bool]$controls['SlackBotTokenPasswordBox'].IsEnabled -and
        [bool]$controls['SlackAppTokenPasswordBox'].IsEnabled -and
        [bool]$controls['TelegramTokenPasswordBox'].IsEnabled -and
        -not [bool]$controls['DiscordTokenPasswordBox'].IsEnabled
    $pendingReadOnlyRecheckEnabled = [bool]$controls['PreviewButton'].IsEnabled -and
        [string]$controls['PreviewButton'].Content -eq '읽기 전용 사후 검사'
    $pendingRestartRequiresApproval = [bool]$controls['ApprovalCheckBox'].IsEnabled -and
        -not [bool]$controls['ApplyButton'].IsEnabled

    $smokeDriftRecovery = [pscustomobject]@{
        Status = 'Partial'
        PendingCount = 1
        Path = 'smoke-settings-recovery.json'
        Checks = @([pscustomobject]@{ Name = 'Configuration drift recovery authorization'; Passed = $false; ExitCode = -1; Detail = 'Smoke-only drift guard.' })
        Plan = $smokePendingRecovery.Plan
    }
    Set-SettingsPendingRecoveryView -Recovery $smokeDriftRecovery
    $pendingDriftRestoreAvailable = [bool]$state.AcceptConfigChangeRequired -and
        [string]$controls['ApprovalCheckBox'].Content -match 'Easy Setup 소유 경로' -and
        [string]$controls['ApplyButton'].Content -eq '승인 패치 복원 및 재검사'

    $smokeCredentialReplacementRecovery = [pscustomobject]@{
        Status = 'Partial'
        PendingCount = 1
        Path = 'smoke-settings-recovery.json'
        Checks = @(
            [pscustomobject]@{ Name = 'Configuration drift recovery authorization'; Passed = $false; ExitCode = -1; Detail = 'Smoke-only drift guard.' }
            [pscustomobject]@{ Name = 'Credential replacement pending'; Passed = $false; ExitCode = -1; Detail = 'Smoke-only replacement guard.' }
        )
        Plan = $smokePendingRecovery.Plan
    }
    Set-SettingsPendingRecoveryView -Recovery $smokeCredentialReplacementRecovery
    $pendingCredentialReplacementRequired = [bool]$state.CredentialReplacementRequired -and
        [bool]$state.AcceptConfigChangeRequired -and
        -not [bool]$controls['ApprovalCheckBox'].IsEnabled -and
        -not [bool]$controls['ApplyButton'].IsEnabled -and
        [string]$controls['ApprovalCheckBox'].Content -match '모두 다시 입력' -and
        [string]$controls['ApplyButton'].Content -eq '패치 복원·자격 증명 교체 및 재검사'

    [pscustomobject]@{
        Loaded = $true
        ModuleImported = $null -eq $moduleImportError
        PresentationSourceReady = $null -ne [Windows.PresentationSource]::FromVisual($window)
        ProviderCount = $controls['ProviderComboBox'].Items.Count
        InteractiveControls = $interactiveNames.Count
        MissingAccessibleNames = $missingAccessibleNames.Count
        MissingTabIndexes = $missingTabIndexes.Count
        ApprovalDefaultOff = $approvalDefaultOff
        ApplyDefaultDisabled = $applyDefaultDisabled
        CancelIsDefault = [bool]$controls['CancelButton'].IsDefault
        SlackTokensFollowSelection = $slackTokensEnabled
        TelegramTokenFollowsSelection = $telegramTokenEnabled
        PreviewWraps = $controls['PreviewTextBox'].TextWrapping -eq [Windows.TextWrapping]::Wrap
        VerticalScrolling = $controls['MainScrollViewer'].VerticalScrollBarVisibility -eq [Windows.Controls.ScrollBarVisibility]::Auto
        HorizontalScrollingDisabled = $controls['MainScrollViewer'].HorizontalScrollBarVisibility -eq [Windows.Controls.ScrollBarVisibility]::Disabled
        UsesSystemColors = $xamlText -match 'SystemColors\.'
        DpiLayoutRounding = [bool]$window.UseLayoutRounding
        PendingSelectionLocked = $pendingSelectionLocked
        PendingSecretReplacementAvailable = $pendingSecretReplacementAvailable
        PendingReadOnlyRecheckEnabled = $pendingReadOnlyRecheckEnabled
        PendingRestartRequiresApproval = $pendingRestartRequiresApproval
        PendingDriftRestoreAvailable = $pendingDriftRestoreAvailable
        PendingCredentialReplacementRequired = $pendingCredentialReplacementRequired
        ExternalApiCalls = [int]$state.ExternalApiCalls
        SecretsCleared = (Get-SettingsPasswordLength -PasswordBox $controls['ApiKeyPasswordBox']) -eq 0 -and
            (Get-SettingsPasswordLength -PasswordBox $controls['SlackBotTokenPasswordBox']) -eq 0 -and
            (Get-SettingsPasswordLength -PasswordBox $controls['SlackAppTokenPasswordBox']) -eq 0 -and
            (Get-SettingsPasswordLength -PasswordBox $controls['TelegramTokenPasswordBox']) -eq 0 -and
            (Get-SettingsPasswordLength -PasswordBox $controls['DiscordTokenPasswordBox']) -eq 0
    } | ConvertTo-Json -Compress

    $state.ExitCode = 0
    $state.ClosingAllowed = $true
    $window.Close()
    exit 0
}

[void]$window.ShowDialog()
$finalExitCode = [int]$state.ExitCode
Clear-SettingsSecretInputs
exit $finalExitCode
