[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$settingsModulePath = Join-Path $projectRoot 'src\OpenClawEasySetup.Settings.psm1'
Import-Module -Name $settingsModulePath -Force
$settingsModule = Get-Module | Where-Object { $_.Path -eq [IO.Path]::GetFullPath($settingsModulePath) } | Select-Object -First 1
if ($null -eq $settingsModule) {
    throw 'The safe settings module did not load for private contract tests.'
}

$script:Passed = 0
$script:Failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Name)
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
    param([object]$Actual, [object]$Expected, [string]$Name)
    Assert-True -Condition ($Actual -eq $Expected) -Name ("{0} (expected: {1}; actual: {2})" -f $Name, $Expected, $Actual)
}

function Get-ThrownException {
    param([scriptblock]$ScriptBlock)
    try {
        & $ScriptBlock
        return $null
    }
    catch {
        return $_.Exception
    }
}

$catalog = Get-OpenClawSafeSetupCatalog
Assert-Equal -Actual $catalog.Version -Expected '0.4.0' -Name 'Safe setup catalog exposes the 0.4 contract'
Assert-Equal -Actual @($catalog.Providers).Count -Expected 3 -Name 'Reviewed catalog exposes three API-key providers'
Assert-True -Condition (@($catalog.Providers | Where-Object Id -eq 'openai').Count -eq 1) -Name 'OpenAI is a reviewed provider choice'
Assert-True -Condition ($catalog.SecurityDefaults.GatewayMode -eq 'local' -and $catalog.SecurityDefaults.GatewayBind -eq 'loopback') -Name 'Catalog defaults to a local loopback Gateway'
Assert-True -Condition ($catalog.SecurityDefaults.ToolProfile -eq 'messaging' -and -not $catalog.SecurityDefaults.ElevatedTools) -Name 'Catalog defaults to messaging-only non-elevated tools'

$fixtureRoot = Join-Path $projectRoot 'tests\settings-fixture'
$fixtureConfig = Join-Path $fixtureRoot 'openclaw.json'
$fixtureResolver = Join-Path $fixtureRoot 'State\Resolver\OpenClawEasySetup.SecretResolver.exe'
$schemaHash = 'A' * 64
$configHash = 'B' * 64
$runId = '0123456789abcdef0123456789abcdef'
$plan = New-OpenClawSafeSetupPlan -ProviderId openai -ModelId 'openai/gpt-5.6' -EnableTelegram $true -EnableDiscord $true -RunId $runId -SchemaHash $schemaHash -BaseConfigHash $configHash -ConfigPath $fixtureConfig -ResolverPath $fixtureResolver

Assert-Equal -Actual $plan.OpenClawVersion -Expected '2026.7.1' -Name 'Plan binds the reviewed OpenClaw release'
Assert-True -Condition ($plan.Fingerprint -match '^[A-F0-9]{64}$') -Name 'Plan has a canonical SHA-256 fingerprint'
Assert-Equal -Actual (Get-OpenClawSafeSetupPlanFingerprint -Plan $plan) -Expected $plan.Fingerprint -Name 'Plan fingerprint is reproducible'
Assert-True -Condition ($plan.Patch.gateway.mode -eq 'local' -and $plan.Patch.gateway.bind -eq 'loopback') -Name 'Patch cannot expose the Gateway beyond loopback'
Assert-True -Condition ($plan.Patch.gateway.auth.mode -eq 'token' -and $plan.Patch.gateway.auth.token.source -eq 'exec') -Name 'Patch requires token auth through a SecretRef'
Assert-True -Condition ($plan.Patch.gateway.tailscale.mode -eq 'off' -and -not $plan.Patch.gateway.terminal.enabled) -Name 'Patch disables remote Tailscale exposure and the operator terminal'
Assert-True -Condition ($plan.Patch.tools.profile -eq 'messaging' -and -not $plan.Patch.tools.elevated.enabled) -Name 'Patch applies the minimum messaging tool profile'
Assert-True -Condition ($plan.Patch.tools.deny -contains 'group:runtime' -and $plan.Patch.tools.deny -contains 'group:fs' -and $plan.Patch.tools.deny -contains 'bundle-mcp') -Name 'Patch explicitly denies command, filesystem, and bundled MCP escape surfaces'
Assert-Equal -Actual $plan.Patch.session.dmScope -Expected 'per-channel-peer' -Name 'Direct-message sessions are separated per channel peer'

foreach ($channelName in @('telegram', 'discord')) {
    $channel = $plan.Patch.channels.$channelName
    Assert-True -Condition ($channel.enabled -and $channel.dmPolicy -eq 'pairing' -and $channel.groupPolicy -eq 'disabled' -and -not $channel.configWrites) -Name "$channelName uses pairing, blocks groups, and cannot rewrite config"
}
Assert-True -Condition ($plan.Patch.channels.telegram.botToken.source -eq 'exec' -and $plan.Patch.channels.discord.token.source -eq 'exec') -Name 'Channel bot tokens are Credential Manager SecretRefs'
Assert-True -Condition ($plan.Patch.models.providers.openai.apiKey.source -eq 'exec') -Name 'Model API key is a Credential Manager SecretRef'
Assert-True -Condition ($plan.Patch.models.mode -eq 'merge' -and $plan.Patch.models.providers.openai.Count -eq 1 -and $plan.Patch.models.providers.openai.Contains('apiKey')) -Name 'Built-in provider uses the pinned key-only overlay contract and forces bundled catalog merge mode'

$resolverProvider = $plan.Patch.secrets.providers.oces_wincred
Assert-True -Condition ($resolverProvider.source -eq 'exec' -and $resolverProvider.jsonOnly -and -not $resolverProvider.allowInsecurePath -and -not $resolverProvider.allowSymlinkCommand) -Name 'Resolver provider is JSON-only and fails closed on unsafe paths'
Assert-Equal -Actual $resolverProvider.command -Expected ([IO.Path]::GetFullPath($fixtureResolver)) -Name 'Resolver command is the approved absolute path'
Assert-True -Condition (@($resolverProvider.passEnv).Count -eq 0 -and $resolverProvider.env.Count -eq 0) -Name 'Resolver receives no inherited secret environment'
$expectedReplacePaths = @(
    'secrets.providers.oces_wincred'
    'gateway.auth'
    'agents.defaults.model'
    'models.mode'
    'models.providers.openai'
    'channels.telegram'
    'channels.discord'
)
Assert-Equal -Actual (@($plan.ReplacePaths) -join '|') -Expected ($expectedReplacePaths -join '|') -Name 'Plan binds exact replacement ownership for the resolver and every SecretRef'
$writePatchArguments = & $settingsModule { param($PlanValue) Get-OpenClawSafeSetupPatchArguments -Plan $PlanValue } $plan
$dryRunPatchArguments = & $settingsModule { param($PlanValue) Get-OpenClawSafeSetupPatchArguments -Plan $PlanValue -DryRun -AllowExec } $plan
$writeReplacePaths = for ($argumentIndex = 0; $argumentIndex -lt $writePatchArguments.Count; $argumentIndex++) {
    if ($writePatchArguments[$argumentIndex] -eq '--replace-path') { $writePatchArguments[$argumentIndex + 1] }
}
$dryRunReplacePaths = for ($argumentIndex = 0; $argumentIndex -lt $dryRunPatchArguments.Count; $argumentIndex++) {
    if ($dryRunPatchArguments[$argumentIndex] -eq '--replace-path') { $dryRunPatchArguments[$argumentIndex + 1] }
}
Assert-True -Condition ((@($writeReplacePaths) -join '|') -eq ($expectedReplacePaths -join '|') -and (@($dryRunReplacePaths) -join '|') -eq ($expectedReplacePaths -join '|')) -Name 'Dry-run and write use the identical fingerprint-bound replace-path set'

$expectedCredentialNames = @('GatewayToken', 'ModelApiKey', 'TelegramBotToken', 'DiscordBotToken')
Assert-Equal -Actual @($plan.CredentialIds.PSObject.Properties).Count -Expected $expectedCredentialNames.Count -Name 'Plan creates one credential per secret'
foreach ($name in $expectedCredentialNames) {
    $id = [string]$plan.CredentialIds.$name
    Assert-True -Condition ($id.EndsWith($runId) -and $id -notmatch '\.\.|\\') -Name "$name uses a run-scoped non-traversing id"
}

$canary = 'OCES_CANARY_SECRET_VALUE_1234567890'
$preview = Get-OpenClawSafeSetupPreview -Plan $plan
$patchJson = $plan.Patch | ConvertTo-Json -Depth 32
Assert-True -Condition (-not $preview.Contains($canary) -and -not $patchJson.Contains($canary)) -Name 'Preview and patch contain no plaintext canary secret'
Assert-True -Condition ($preview.Contains('Windows Credential Manager') -and $preview.Contains($plan.Fingerprint)) -Name 'Preview explains secret storage and binds the plan fingerprint'
try {
    [void]($patchJson | ConvertFrom-Json)
    $patchParses = $true
}
catch {
    $patchParses = $false
}
Assert-True -Condition $patchParses -Name 'Generated merge patch is valid JSON'
$plan | Add-Member -NotePropertyName PatchJson -NotePropertyValue ('{"gateway":{"bind":"lan"},"canary":"' + $canary + '"}')
$previewWithUntrustedProperty = Get-OpenClawSafeSetupPreview -Plan $plan
Assert-True -Condition (-not $previewWithUntrustedProperty.Contains($canary) -and -not $previewWithUntrustedProperty.Contains('"bind":"lan"')) -Name 'Untrusted sidecar JSON cannot alter an approved preview or applied patch'

$noChannelPlan = New-OpenClawSafeSetupPlan -ProviderId anthropic -ModelId 'anthropic/claude-opus-4-8' -RunId ('1' * 32) -SchemaHash $schemaHash -BaseConfigHash $configHash -ConfigPath $fixtureConfig -ResolverPath $fixtureResolver
Assert-True -Condition ($null -eq $noChannelPlan.Patch.PSObject.Properties['channels']) -Name 'Unselected channels are left unchanged instead of being deleted'
Assert-Equal -Actual @($noChannelPlan.CredentialIds.PSObject.Properties).Count -Expected 2 -Name 'No-channel plan stores only Gateway and model credentials'

$badModel = Get-ThrownException { New-OpenClawSafeSetupPlan -ProviderId openai -ModelId 'openai/not-reviewed' -RunId ('2' * 32) -SchemaHash $schemaHash -BaseConfigHash $configHash -ConfigPath $fixtureConfig -ResolverPath $fixtureResolver }
Assert-True -Condition ($null -ne $badModel) -Name 'Unreviewed model ids are rejected before a plan is created'
$partialState = Get-ThrownException { New-OpenClawSafeSetupPlan -ProviderId openai -ModelId 'openai/gpt-5.6' -RunId ('3' * 32) -SchemaHash $schemaHash }
Assert-True -Condition ($null -ne $partialState) -Name 'Partial injected live state is rejected'

$mutatedPlan = New-OpenClawSafeSetupPlan -ProviderId google -ModelId 'google/gemini-3.1-pro-preview' -RunId ('4' * 32) -SchemaHash $schemaHash -BaseConfigHash $configHash -ConfigPath $fixtureConfig -ResolverPath $fixtureResolver
$originalFingerprint = $mutatedPlan.Fingerprint
$mutatedPlan.Patch.gateway.bind = 'lan'
Assert-True -Condition ((Get-OpenClawSafeSetupPlanFingerprint -Plan $mutatedPlan) -ne $originalFingerprint) -Name 'A post-preview security change invalidates the plan fingerprint'

$gatewayToken = New-OpenClawGatewayToken
try {
    Assert-True -Condition ($gatewayToken.IsReadOnly() -and $gatewayToken.Length -eq 64) -Name 'Gateway token is a read-only 256-bit SecureString'
}
finally {
    $gatewayToken.Dispose()
}

$resolverSourcePath = Join-Path $projectRoot 'src\CredentialResolver\OpenClawEasySetup.SecretResolver.cs'
$resolverSource = Get-Content -LiteralPath $resolverSourcePath -Raw -Encoding UTF8
Assert-True -Condition ($resolverSource -match 'CredReadW' -and $resolverSource -match 'CredFree') -Name 'Native resolver reads and frees Windows credentials directly'
Assert-True -Condition ($resolverSource -notmatch 'CredEnumerate' -and $resolverSource -notmatch 'Process\.Start') -Name 'Resolver cannot enumerate credentials or launch child processes'
Assert-True -Condition ($resolverSource -match 'protocolVersion' -and $resolverSource -match 'OpenClawEasySetup:') -Name 'Resolver implements the OpenClaw protocol and fixed credential namespace'
$settingsSource = Get-Content -LiteralPath $settingsModulePath -Raw -Encoding UTF8
Assert-True -Condition ($settingsSource -notmatch 'StandardInputEncoding' -and $settingsSource.Contains('StandardInput.BaseStream.Write')) -Name 'OpenClaw JSON stdin uses the Windows PowerShell 5.1-compatible UTF-8 byte stream'
Assert-True -Condition (([regex]::Matches($settingsSource, 'Resolve-OpenClawInvocation')).Count -eq 1 -and $settingsSource.Contains('SettingsInvocationCache')) -Name 'Settings workflow resolves full package provenance only through its stamped invocation cache'
$secretRefreshCount = ([regex]::Matches($settingsSource, 'Invoke-OpenClawSafeSetupDryRun[^\r\n]*-AllowExec[^\r\n]*-ForceInvocationRefresh')).Count
$patchRefreshCount = ([regex]::Matches($settingsSource, "config', 'patch', '--stdin'[^\r\n]*ForceInvocationRefresh")).Count
Assert-True -Condition ($secretRefreshCount -eq 2 -and $patchRefreshCount -eq 0) -Name 'Apply and approved drift recovery refresh provenance at their secret-bearing exec boundary and reuse the stamped invocation for patching'
$completeExecDryRun = [pscustomobject]@{ ok = $true; skippedExecRefs = 0; checks = [pscustomobject]@{ resolvabilityComplete = $true } }
$incompleteExecDryRun = [pscustomobject]@{ ok = $true; skippedExecRefs = 1; checks = [pscustomobject]@{ resolvabilityComplete = $false } }
$completeExecAccepted = & $settingsModule { param($Value) Test-OpenClawSafeSetupDryRunJson -Value $Value -RequireExecResolution } $completeExecDryRun
$incompleteExecAccepted = & $settingsModule { param($Value) Test-OpenClawSafeSetupDryRunJson -Value $Value -RequireExecResolution } $incompleteExecDryRun
Assert-True -Condition ($completeExecAccepted -and -not $incompleteExecAccepted) -Name 'Credential resolver dry-run requires complete resolution with zero skipped exec refs'

$recoverySecrets = New-Object 'System.Collections.Generic.List[System.Security.SecureString]'
try {
    $recoveryCredentialMap = @{}
    foreach ($credentialName in @('ModelApiKey', 'TelegramBotToken', 'DiscordBotToken')) {
        $secureFixture = New-Object Security.SecureString
        foreach ($character in ('fixture-' + $credentialName).ToCharArray()) { $secureFixture.AppendChar($character) }
        $secureFixture.MakeReadOnly()
        $recoverySecrets.Add($secureFixture)
        $recoveryCredentialMap[$credentialName] = $secureFixture
    }
    $validRecoveryMapError = Get-ThrownException {
        & $settingsModule { param($PlanValue, $MapValue) Test-OpenClawRecoveryCredentialMap -Plan $PlanValue -CredentialMap $MapValue } $plan $recoveryCredentialMap
    }
    Assert-True -Condition ($null -eq $validRecoveryMapError) -Name 'Recovery replaces only the receipt-bound model and selected channel credentials'

    $recoveryCredentialMap['GatewayToken'] = $gatewayToken = New-OpenClawGatewayToken
    $recoverySecrets.Add($gatewayToken)
    $gatewayReplacementError = Get-ThrownException {
        & $settingsModule { param($PlanValue, $MapValue) Test-OpenClawRecoveryCredentialMap -Plan $PlanValue -CredentialMap $MapValue } $plan $recoveryCredentialMap
    }
Assert-True -Condition ($null -ne $gatewayReplacementError) -Name 'Recovery refuses to replace the generated Gateway token'
}
finally {
    foreach ($secret in $recoverySecrets) { if ($null -ne $secret) { $secret.Dispose() } }
}

$pendingReplacementFixture = @([pscustomobject]@{ name = 'Credential replacement pending'; passed = $false })
$completedReplacementFixture = @([pscustomobject]@{ name = 'Credential replacement pending'; passed = $true })
$pendingReplacementDetected = & $settingsModule { param($ChecksValue) Test-OpenClawSafeSetupCredentialReplacementPending -Checks $ChecksValue } $pendingReplacementFixture
$completedReplacementDetected = & $settingsModule { param($ChecksValue) Test-OpenClawSafeSetupCredentialReplacementPending -Checks $ChecksValue } $completedReplacementFixture
Assert-True -Condition ($pendingReplacementDetected -and -not $completedReplacementDetected) -Name 'Interrupted all-secret replacement remains an explicit recovery guard'
$replacementBranchFixture = @([pscustomobject]@{ Name = 'Active configuration path'; Passed = $false; ExitCode = -1; Detail = 'fixture' })
$preservedReplacementChecks = @(& $settingsModule {
    param($ChecksValue)
    Get-OpenClawSafeSetupRecoveryChecks -Checks $ChecksValue -PreserveCredentialReplacementPending
} (@($pendingReplacementFixture) + @($replacementBranchFixture)))
$preservedReplacementChecksAgain = @(& $settingsModule {
    param($ChecksValue)
    Get-OpenClawSafeSetupRecoveryChecks -Checks $ChecksValue -PreserveCredentialReplacementPending
} $preservedReplacementChecks)
$clearedReplacementChecks = @(& $settingsModule {
    param($ChecksValue)
    Get-OpenClawSafeSetupRecoveryChecks -Checks $ChecksValue
} $preservedReplacementChecksAgain)
$preservedMarkerCount = @($preservedReplacementChecksAgain | Where-Object { [string]$_.Name -eq 'Credential replacement pending' -and $_.Passed -ne $true }).Count
$preservedBranchCount = @($preservedReplacementChecksAgain | Where-Object { [string]$_.Name -eq 'Active configuration path' }).Count
$clearedMarkerDetected = & $settingsModule { param($ChecksValue) Test-OpenClawSafeSetupCredentialReplacementPending -Checks $ChecksValue } $clearedReplacementChecks
Assert-True -Condition ($preservedMarkerCount -eq 1 -and $preservedBranchCount -eq 1 -and -not $clearedMarkerDetected) -Name 'Recovery check composition deduplicates and preserves a failed replacement marker until explicit completion clearing'

$matchingRecoveryLiveState = [pscustomobject]@{
    OpenClawVersion = [string]$plan.OpenClawVersion
    SchemaHash = ([string]$plan.SchemaHash).ToLowerInvariant()
    ConfigPath = [string]$plan.ConfigPath
}
$schemaDriftRecoveryLiveState = [pscustomobject]@{
    OpenClawVersion = [string]$plan.OpenClawVersion
    SchemaHash = 'C' * 64
    ConfigPath = [string]$plan.ConfigPath
}
$versionDriftRecoveryLiveState = [pscustomobject]@{
    OpenClawVersion = '2026.7.2'
    SchemaHash = [string]$plan.SchemaHash
    ConfigPath = [string]$plan.ConfigPath
}
$pathDriftRecoveryLiveState = [pscustomobject]@{
    OpenClawVersion = [string]$plan.OpenClawVersion
    SchemaHash = [string]$plan.SchemaHash
    ConfigPath = Join-Path $fixtureRoot 'other-openclaw.json'
}
$matchingRecoveryCompatibility = & $settingsModule { param($PlanValue, $LiveValue) Test-OpenClawSafeSetupRecoveryCompatibility -Plan $PlanValue -LiveState $LiveValue } $plan $matchingRecoveryLiveState
$schemaDriftRecoveryCompatibility = & $settingsModule { param($PlanValue, $LiveValue) Test-OpenClawSafeSetupRecoveryCompatibility -Plan $PlanValue -LiveState $LiveValue } $plan $schemaDriftRecoveryLiveState
$versionDriftRecoveryCompatibility = & $settingsModule { param($PlanValue, $LiveValue) Test-OpenClawSafeSetupRecoveryCompatibility -Plan $PlanValue -LiveState $LiveValue } $plan $versionDriftRecoveryLiveState
$pathDriftRecoveryCompatibility = & $settingsModule { param($PlanValue, $LiveValue) Test-OpenClawSafeSetupRecoveryCompatibility -Plan $PlanValue -LiveState $LiveValue } $plan $pathDriftRecoveryLiveState
Assert-True -Condition ($matchingRecoveryCompatibility -and -not $schemaDriftRecoveryCompatibility -and -not $versionDriftRecoveryCompatibility -and -not $pathDriftRecoveryCompatibility) -Name 'Recovery compatibility requires the exact pending version, schema, and active config path without rebasing'

$passingGatewayPreflight = @(
    [pscustomobject]@{ Name = 'Approved patch continuity'; Passed = $true }
    [pscustomobject]@{ Name = 'Config validation'; Passed = $true }
    [pscustomobject]@{ Name = 'Safe configuration invariants'; Passed = $true }
)
$failingGatewayPreflight = @(
    [pscustomobject]@{ Name = 'Approved patch continuity'; Passed = $true }
    [pscustomobject]@{ Name = 'Config validation'; Passed = $false }
    [pscustomobject]@{ Name = 'Safe configuration invariants'; Passed = $true }
)
$passingGatewayGate = & $settingsModule { param($ChecksValue) Test-OpenClawSafeSetupGatewayPreflightChecks -Checks $ChecksValue } $passingGatewayPreflight
$failingGatewayGate = & $settingsModule { param($ChecksValue) Test-OpenClawSafeSetupGatewayPreflightChecks -Checks $ChecksValue } $failingGatewayPreflight
$incompleteGatewayGate = & $settingsModule { param($ChecksValue) Test-OpenClawSafeSetupGatewayPreflightChecks -Checks $ChecksValue } @($passingGatewayPreflight | Select-Object -First 2)
Assert-True -Condition ($passingGatewayGate -and -not $failingGatewayGate -and -not $incompleteGatewayGate) -Name 'Gateway mutation gate requires all three exact configuration preflight checks to pass'

Assert-True -Condition ($settingsSource.Contains('Configuration drift recovery authorization') -and $settingsSource.Contains('[switch]$AcceptConfigChange')) -Name 'Recovery fails closed on config fingerprint drift unless patch restoration is explicitly authorized'
Assert-True -Condition ($settingsSource.Contains('-EnsureGatewayService:$restartGateway')) -Name 'Recovery restarts the Gateway only for an explicitly approved mutation path'
Assert-True -Condition (-not $settingsSource.Contains('Invoke-OpenClawSafeSetupCredentialBindingCheck') -and -not $settingsSource.Contains("models.providers.{0}.apiKey' -f [string]`$Plan.ProviderId")) -Name 'Core verification never treats redacted config-get output as exact SecretRef evidence'
Assert-True -Condition ($settingsSource.Contains('Active configuration path') -and $settingsSource.Contains('Approved patch continuity') -and $settingsSource.Contains('Safe configuration invariants')) -Name 'Recovery binds the official active config path, exact-patch byte fingerprint, and safe settings invariants'
Assert-True -Condition ($settingsSource.Contains('Approved patch restoration') -and $settingsSource.Contains('Get-OpenClawSafeSetupPatchArguments -Plan $plan')) -Name 'Explicit drift recovery restores the fingerprint-bound patch with its exact replace paths'
Assert-True -Condition ($settingsSource.Contains('Recovery configuration continuity') -and $settingsSource.Contains('Post-check configuration continuity')) -Name 'Apply and recovery rehash configuration after their multi-command checks'
$replacementMarkerIndex = $settingsSource.IndexOf("Name = 'Credential replacement pending'", [StringComparison]::Ordinal)
$replacementWriteIndex = $settingsSource.IndexOf('Set-OpenClawCredential -Id $credentialId', $replacementMarkerIndex, [StringComparison]::Ordinal)
$replacementClearIndex = $settingsSource.IndexOf('Clearing the pending marker is itself durable', $replacementWriteIndex, [StringComparison]::Ordinal)
Assert-True -Condition ($replacementMarkerIndex -ge 0 -and $replacementWriteIndex -gt $replacementMarkerIndex -and $replacementClearIndex -gt $replacementWriteIndex) -Name 'Recovery checkpoints all-secret replacement before the first write and clears it only after the full set'
$postChecksIndex = $settingsSource.IndexOf('function Invoke-OpenClawSafeSetupPostChecks', [StringComparison]::Ordinal)
$gatewayGateIndex = $settingsSource.IndexOf('if (Test-OpenClawSafeSetupGatewayPreflightChecks', $postChecksIndex, [StringComparison]::Ordinal)
$gatewayInstallIndex = $settingsSource.IndexOf("-Name 'Gateway service install'", $postChecksIndex, [StringComparison]::Ordinal)
Assert-True -Condition ($postChecksIndex -ge 0 -and $gatewayGateIndex -gt $postChecksIndex -and $gatewayInstallIndex -gt $gatewayGateIndex -and $settingsSource.Contains('failed before Gateway mutation')) -Name 'Post-checks skip Gateway install and restart when any configuration preflight fails'
$recoveryFunctionIndex = $settingsSource.IndexOf('function Invoke-OpenClawSafeSetupRecoveryVerification', [StringComparison]::Ordinal)
$recoveryCompatibilityIndex = $settingsSource.IndexOf('$compatibilityLiveState = Get-OpenClawSafeSetupRecoveryCompatibilityState', $recoveryFunctionIndex, [StringComparison]::Ordinal)
$recoveryCleanupIndex = $settingsSource.IndexOf('Remove-OpenClawCredential -Id', $recoveryFunctionIndex, [StringComparison]::Ordinal)
$recoveryResolverIndex = $settingsSource.IndexOf('Install-OpenClawCredentialResolver', $recoveryFunctionIndex, [StringComparison]::Ordinal)
$recoveryCredentialWriteIndex = $settingsSource.IndexOf('Set-OpenClawCredential -Id $credentialId', $recoveryFunctionIndex, [StringComparison]::Ordinal)
$recoveryPatchIndex = $settingsSource.IndexOf('Invoke-OpenClawSettingsCommand -Arguments $patchArguments', $recoveryFunctionIndex, [StringComparison]::Ordinal)
Assert-True -Condition ($recoveryCompatibilityIndex -gt $recoveryFunctionIndex -and $recoveryCompatibilityIndex -lt $recoveryCleanupIndex -and $recoveryCompatibilityIndex -lt $recoveryResolverIndex -and $recoveryCompatibilityIndex -lt $recoveryCredentialWriteIndex -and $recoveryCompatibilityIndex -lt $recoveryPatchIndex) -Name 'Recovery checks fresh version, schema, and config-path compatibility before every credential or service mutation'
$replacementPreservationSeedIndex = $settingsSource.IndexOf('foreach ($initialRecoveryCheck in @(Get-OpenClawSafeSetupRecoveryChecks', $recoveryFunctionIndex, [StringComparison]::Ordinal)
$replacementPreservationBranches = @(
    'if (-not $activeConfigPathMatches)',
    'if (-not $restoreApprovedPatch)',
    'if ($failedPreMutationChecks.Count -gt 0)',
    'if (-not $resolverReady)'
)
$allReplacementFailureBranchesPreserve = $replacementPreservationSeedIndex -gt $recoveryFunctionIndex
foreach ($branchToken in $replacementPreservationBranches) {
    $branchIndex = $settingsSource.IndexOf($branchToken, $replacementPreservationSeedIndex, [StringComparison]::Ordinal)
    $branchReturnIndex = if ($branchIndex -ge 0) { $settingsSource.IndexOf('return [pscustomobject]', $branchIndex, [StringComparison]::Ordinal) } else { -1 }
    if ($branchIndex -lt $replacementPreservationSeedIndex -or $branchReturnIndex -le $branchIndex) {
        $allReplacementFailureBranchesPreserve = $false
        continue
    }
    $branchSource = $settingsSource.Substring($branchIndex, $branchReturnIndex - $branchIndex)
    if (-not $branchSource.Contains('-Checks $recoveryChecks.ToArray()')) {
        $allReplacementFailureBranchesPreserve = $false
    }
}
Assert-True -Condition $allReplacementFailureBranchesPreserve -Name 'Active-path, config-drift, pre-mutation, and resolver failures all persist the seeded replacement marker'
$lockFreshnessIndex = $settingsSource.IndexOf("`$pendingRecovery = Get-OpenClawSafeSetupPendingRecovery", [StringComparison]::Ordinal)
$lockedFreshnessIndex = $settingsSource.IndexOf('Assert-OpenClawSafeSetupPlanFresh -Plan $Plan', $lockFreshnessIndex, [StringComparison]::Ordinal)
$resolverInstallIndex = $settingsSource.IndexOf('Install-OpenClawCredentialResolver', $lockFreshnessIndex, [StringComparison]::Ordinal)
Assert-True -Condition ($lockFreshnessIndex -ge 0 -and $lockedFreshnessIndex -gt $lockFreshnessIndex -and $lockedFreshnessIndex -lt $resolverInstallIndex) -Name 'Apply rechecks freshness under the transaction lock before writing resolver, receipt, or credentials'
Assert-True -Condition ($settingsSource.Contains("-Status Partial -AppliedConfigHash ''")) -Name 'Ambiguous Preparing recovery never silently trusts an observed changed config hash'

$healthySecurity = [pscustomobject]@{
    summary = [pscustomobject]@{ critical = 0; warn = 0; info = 1 }
    findings = @([pscustomobject]@{ severity = 'info' })
    deep = [pscustomobject]@{ gateway = [pscustomobject]@{ attempted = $true; ok = $true } }
    secretDiagnostics = @()
}
$warningSecurity = [pscustomobject]@{
    summary = [pscustomobject]@{ critical = 0; warn = 1; info = 0 }
    findings = @([pscustomobject]@{ severity = 'warn'; checkId = 'gateway.bind'; title = 'Gateway exposure requires review' })
    deep = [pscustomobject]@{ gateway = [pscustomobject]@{ attempted = $true; ok = $true } }
    secretDiagnostics = @()
}
$healthySecurityAccepted = & $settingsModule { param($Value) Test-OpenClawSecurityAuditJson -Value $Value } $healthySecurity
$warningSecurityAccepted = & $settingsModule { param($Value) Test-OpenClawSecurityAuditJson -Value $Value } $warningSecurity
$warningSecurityDetail = & $settingsModule { param($Value) Get-OpenClawSafeSetupSemanticFailureDetail -Kind Security -Value $Value } $warningSecurity
Assert-True -Condition $healthySecurityAccepted -Name 'Semantic security check accepts a clean deep audit'
Assert-True -Condition (-not $warningSecurityAccepted) -Name 'Semantic security check rejects warning or critical findings'
Assert-True -Condition ($warningSecurityDetail.Contains('gateway.bind') -and $warningSecurityDetail.Contains('critical=0')) -Name 'Semantic security failure retains bounded actionable finding details'

$healthyModel = [pscustomobject]@{
    resolvedDefault = 'openai/gpt-5.6'
    auth = [pscustomobject]@{ missingProvidersInUse = @() }
}
$missingModelAuth = [pscustomobject]@{
    resolvedDefault = 'openai/gpt-5.6'
    auth = [pscustomobject]@{ missingProvidersInUse = @('openai') }
}
$healthyModelAccepted = & $settingsModule { param($Value) Test-OpenClawModelStatusJson -Value $Value -ExpectedModelId 'openai/gpt-5.6' } $healthyModel
$missingModelAccepted = & $settingsModule { param($Value) Test-OpenClawModelStatusJson -Value $Value -ExpectedModelId 'openai/gpt-5.6' } $missingModelAuth
$wrongModelAccepted = & $settingsModule { param($Value) Test-OpenClawModelStatusJson -Value $Value -ExpectedModelId 'anthropic/claude-opus-4-8' } $healthyModel
Assert-True -Condition $healthyModelAccepted -Name 'Semantic model check accepts the approved default with usable auth'
Assert-True -Condition (-not $missingModelAccepted -and -not $wrongModelAccepted) -Name 'Semantic model check rejects missing auth or a different resolved default'

$healthyChannel = [pscustomobject]@{
    channelAccounts = [pscustomobject]@{
        telegram = @([pscustomobject]@{
            accountId = 'default'
            enabled = $true
            configured = $true
            running = $true
            probe = [pscustomobject]@{ ok = $true }
        })
    }
}
$failedChannelProbe = [pscustomobject]@{
    channelAccounts = [pscustomobject]@{
        telegram = @([pscustomobject]@{
            accountId = 'default'
            enabled = $true
            configured = $true
            probe = [pscustomobject]@{ ok = $false }
        })
    }
}
$configOnlyChannel = [pscustomobject]@{ gatewayReachable = $false; configOnly = $true; channelAccounts = [pscustomobject]@{} }
$stoppedTelegramChannel = [pscustomobject]@{
    channelAccounts = [pscustomobject]@{
        telegram = @([pscustomobject]@{
            accountId = 'default'
            enabled = $true
            configured = $true
            running = $false
            probe = [pscustomobject]@{ ok = $true }
        })
    }
}
$disconnectedDiscordChannel = [pscustomobject]@{
    channelAccounts = [pscustomobject]@{
        discord = @([pscustomobject]@{
            accountId = 'default'
            enabled = $true
            configured = $true
            running = $true
            connected = $false
            probe = [pscustomobject]@{ ok = $true }
        })
    }
}
$partialChannel = [pscustomobject]@{
    partial = $true
    channelAccounts = $healthyChannel.channelAccounts
}
$healthyChannelAccepted = & $settingsModule { param($Value) Test-OpenClawChannelStatusJson -Value $Value -ChannelId telegram } $healthyChannel
$failedChannelAccepted = & $settingsModule { param($Value) Test-OpenClawChannelStatusJson -Value $Value -ChannelId telegram } $failedChannelProbe
$configOnlyChannelAccepted = & $settingsModule { param($Value) Test-OpenClawChannelStatusJson -Value $Value -ChannelId telegram } $configOnlyChannel
$stoppedTelegramAccepted = & $settingsModule { param($Value) Test-OpenClawChannelStatusJson -Value $Value -ChannelId telegram } $stoppedTelegramChannel
$disconnectedDiscordAccepted = & $settingsModule { param($Value) Test-OpenClawChannelStatusJson -Value $Value -ChannelId discord } $disconnectedDiscordChannel
$partialChannelAccepted = & $settingsModule { param($Value) Test-OpenClawChannelStatusJson -Value $Value -ChannelId telegram } $partialChannel
Assert-True -Condition $healthyChannelAccepted -Name 'Semantic channel check accepts a running configured account with a successful probe'
Assert-True -Condition (-not $failedChannelAccepted -and -not $configOnlyChannelAccepted) -Name 'Semantic channel check rejects failed probes and config-only fallback output'
Assert-True -Condition (-not $stoppedTelegramAccepted -and -not $disconnectedDiscordAccepted -and -not $partialChannelAccepted) -Name 'Semantic channel check rejects stopped, disconnected, and partial status output'

$whatIfRecoveryRoot = Join-Path $PSScriptRoot ('.tmp-settings-whatif-' + [Guid]::NewGuid().ToString('N'))
$whatIfRecovery = Invoke-OpenClawSafeSetupRecoveryVerification -StateDirectory $whatIfRecoveryRoot -WhatIf
Assert-True -Condition ($whatIfRecovery.Status -eq 'None' -and -not (Test-Path -LiteralPath $whatIfRecoveryRoot)) -Name 'Recovery WhatIf creates no state tree or transaction lock when no receipt exists'
$whatIfResolverRoot = Join-Path $PSScriptRoot ('.tmp-resolver-whatif-' + [Guid]::NewGuid().ToString('N'))
[void](& $settingsModule { param($RootValue) Install-OpenClawCredentialResolver -StateDirectory $RootValue -WhatIf } $whatIfResolverRoot)
Assert-True -Condition (-not (Test-Path -LiteralPath $whatIfResolverRoot)) -Name 'Credential resolver WhatIf creates no state or resolver directory'

$continuityRoot = Join-Path $PSScriptRoot ('.tmp-settings-continuity-' + [Guid]::NewGuid().ToString('N'))
try {
    [void][IO.Directory]::CreateDirectory($continuityRoot)
    $continuityConfig = Join-Path $continuityRoot 'openclaw.json'
    [IO.File]::WriteAllText($continuityConfig, '{"gateway":{"mode":"local"}}', (New-Object Text.UTF8Encoding($false)))
    $continuityHash = (Get-FileHash -LiteralPath $continuityConfig -Algorithm SHA256).Hash
    $continuityPlan = [pscustomobject]@{ ConfigPath = $continuityConfig }
    $matchingContinuity = & $settingsModule {
        param($PlanValue, $HashValue)
        Invoke-OpenClawSafeSetupConfigurationContinuityCheck -Plan $PlanValue -ExpectedConfigHash $HashValue
    } $continuityPlan $continuityHash
    [IO.File]::WriteAllText($continuityConfig, '{"gateway":{"mode":"remote"}}', (New-Object Text.UTF8Encoding($false)))
    $driftedContinuity = & $settingsModule {
        param($PlanValue, $HashValue)
        Invoke-OpenClawSafeSetupConfigurationContinuityCheck -Plan $PlanValue -ExpectedConfigHash $HashValue
    } $continuityPlan $continuityHash
    Assert-True -Condition ($matchingContinuity.Passed -and -not $driftedContinuity.Passed) -Name 'Approved-patch continuity accepts byte identity and rejects later config drift'
}
finally {
    if (Test-Path -LiteralPath $continuityRoot) {
        $resolvedContinuityRoot = (Resolve-Path -LiteralPath $continuityRoot).Path
        $expectedContinuityPrefix = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.tmp-settings-continuity-'))
        if (-not $resolvedContinuityRoot.StartsWith($expectedContinuityPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing to clean a continuity test directory outside the expected prefix.'
        }
        Remove-Item -LiteralPath $resolvedContinuityRoot -Recurse -Force
    }
}

$receiptRoot = Join-Path $PSScriptRoot ('.tmp-settings-receipt-' + [Guid]::NewGuid().ToString('N'))
try {
    $receiptCanary = 'apiKey=OCES_RECEIPT_SECRET_CANARY_1234567890'
    $receiptChecks = @([pscustomobject]@{ Name = 'Security audit'; Passed = $false; ExitCode = 0; Detail = $receiptCanary })
    $receiptIds = @($plan.CredentialIds.PSObject.Properties | ForEach-Object { [string]$_.Value })
    $receiptPath = & $settingsModule {
        param($PlanValue, $IdsValue, $RootValue)
        Write-OpenClawSafeSetupRecoveryReceipt -Plan $PlanValue -Checks @() -CredentialIds $IdsValue -Status Preparing -AppliedConfigHash '' -StateDirectory $RootValue
    } $plan $receiptIds $receiptRoot
    $preparingReceipt = Get-OpenClawSafeSetupPendingRecovery -StateDirectory $receiptRoot
    Assert-True -Condition ($preparingReceipt.Status -eq 'Preparing' -and $preparingReceipt.PendingCount -eq 1) -Name 'Preparing recovery receipt blocks a new setup before the first credential write'
    [void](& $settingsModule {
        param($PlanValue, $IdsValue, $RootValue)
        Write-OpenClawSafeSetupRecoveryReceipt -Plan $PlanValue -Checks @() -CredentialIds $IdsValue -Status AppliedPendingChecks -AppliedConfigHash ('C' * 64) -StateDirectory $RootValue
    } $plan $receiptIds $receiptRoot)
    [void](& $settingsModule {
        param($PlanValue, $ChecksValue, $IdsValue, $RootValue)
        Write-OpenClawSafeSetupRecoveryReceipt -Plan $PlanValue -Checks $ChecksValue -CredentialIds $IdsValue -Status Partial -AppliedConfigHash ('C' * 64) -StateDirectory $RootValue
    } $plan $receiptChecks $receiptIds $receiptRoot)
    $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True -Condition ($receipt.status -eq 'Partial' -and $receipt.planFingerprint -eq $plan.Fingerprint -and @($receipt.credentialIds).Count -eq 4) -Name 'Private recovery receipt preserves the plan fingerprint and exact credential ids'
    Assert-True -Condition (-not (Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8).Contains('OCES_RECEIPT_SECRET_CANARY')) -Name 'Recovery receipt sanitizes diagnostic details before persistence'
    $pendingReceipt = Get-OpenClawSafeSetupPendingRecovery -StateDirectory $receiptRoot
    Assert-True -Condition ($pendingReceipt.Status -eq 'Partial' -and $pendingReceipt.Plan.Fingerprint -eq $plan.Fingerprint -and @($pendingReceipt.CredentialIds).Count -eq 4) -Name 'Recovery reader validates and reconstructs a pending approved plan'
    [void](& $settingsModule {
        param($PlanValue, $ChecksValue, $IdsValue, $RootValue)
        Write-OpenClawSafeSetupRecoveryReceipt -Plan $PlanValue -Checks $ChecksValue -CredentialIds $IdsValue -Status Partial -AppliedConfigHash ('C' * 64) -StateDirectory $RootValue
    } $plan $receiptChecks $receiptIds $receiptRoot)
    Assert-True -Condition ((Get-OpenClawSafeSetupPendingRecovery -StateDirectory $receiptRoot).Status -eq 'Partial') -Name 'Partial recovery can refresh sanitized evidence without clearing its guard'
    [void](& $settingsModule {
        param($PlanValue, $ChecksValue, $IdsValue, $RootValue)
        Write-OpenClawSafeSetupRecoveryReceipt -Plan $PlanValue -Checks $ChecksValue -CredentialIds $IdsValue -Status Succeeded -AppliedConfigHash ('C' * 64) -StateDirectory $RootValue
    } $plan @([pscustomobject]@{ Name = 'Recovery verification'; Passed = $true; ExitCode = 0; Detail = '' }) $receiptIds $receiptRoot)
    Assert-True -Condition ($null -eq (Get-OpenClawSafeSetupPendingRecovery -StateDirectory $receiptRoot)) -Name 'Succeeded recovery receipt no longer blocks a future setup'

    $driftPlan = New-OpenClawSafeSetupPlan -ProviderId openai -ModelId 'openai/gpt-5.6' -RunId ('d' * 32) -SchemaHash $schemaHash -BaseConfigHash $configHash -ConfigPath $fixtureConfig -ResolverPath $fixtureResolver
    $driftIds = @($driftPlan.CredentialIds.PSObject.Properties | ForEach-Object { [string]$_.Value })
    [void](& $settingsModule {
        param($PlanValue, $IdsValue, $RootValue)
        Write-OpenClawSafeSetupRecoveryReceipt -Plan $PlanValue -Checks @() -CredentialIds $IdsValue -Status Preparing -AppliedConfigHash '' -StateDirectory $RootValue
    } $driftPlan $driftIds $receiptRoot)
    [void](& $settingsModule {
        param($PlanValue, $IdsValue, $RootValue)
        Write-OpenClawSafeSetupRecoveryReceipt -Plan $PlanValue -Checks @([pscustomobject]@{ Name = 'Interrupted apply state'; Passed = $false; ExitCode = -1; Detail = 'Ambiguous change.' }) -CredentialIds $IdsValue -Status Partial -AppliedConfigHash '' -StateDirectory $RootValue
    } $driftPlan $driftIds $receiptRoot)
    $driftPending = Get-OpenClawSafeSetupPendingRecovery -StateDirectory $receiptRoot
    Assert-True -Condition ($driftPending.Status -eq 'Partial' -and [string]::IsNullOrWhiteSpace([string]$driftPending.AppliedConfigHash)) -Name 'Preparing drift remains unbound and requires explicit acceptance on the next recovery call'
    [void](& $settingsModule {
        param($PlanValue, $IdsValue, $RootValue)
        Write-OpenClawSafeSetupRecoveryReceipt -Plan $PlanValue -Checks @([pscustomobject]@{ Name = 'Test cleanup'; Passed = $true; ExitCode = 0; Detail = '' }) -CredentialIds $IdsValue -Status Succeeded -AppliedConfigHash ('E' * 64) -StateDirectory $RootValue
    } $driftPlan $driftIds $receiptRoot)

    $cacheExecutable = Join-Path $receiptRoot 'cache-node.exe'
    $cacheEntryPoint = Join-Path $receiptRoot 'cache-openclaw.mjs'
    [IO.File]::WriteAllText($cacheExecutable, 'signed-node-fixture', (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($cacheEntryPoint, 'entry-fixture-v1', (New-Object Text.UTF8Encoding($false)))
    $cacheInvocation = [pscustomobject]@{ Executable = $cacheExecutable; PrefixArguments = @($cacheEntryPoint) }
    $cacheEntry = & $settingsModule { param($InvocationValue, $KeyValue) New-OpenClawSettingsInvocationCacheEntry -Invocation $InvocationValue -CacheKey $KeyValue } $cacheInvocation $receiptRoot
    $cacheInitiallyValid = & $settingsModule { param($EntryValue, $KeyValue) Test-OpenClawSettingsInvocationCacheEntry -Entry $EntryValue -CacheKey $KeyValue } $cacheEntry $receiptRoot
    [IO.File]::WriteAllText($cacheEntryPoint, 'entry-fixture-v2-changed', (New-Object Text.UTF8Encoding($false)))
    $cacheAfterChangeValid = & $settingsModule { param($EntryValue, $KeyValue) Test-OpenClawSettingsInvocationCacheEntry -Entry $EntryValue -CacheKey $KeyValue } $cacheEntry $receiptRoot
    Assert-True -Condition ($cacheInitiallyValid -and -not $cacheAfterChangeValid) -Name 'Invocation cache reuses a stable verified entry and rejects an entry-point change'
}
finally {
    if (Test-Path -LiteralPath $receiptRoot) {
        $resolvedReceiptRoot = (Resolve-Path -LiteralPath $receiptRoot).Path
        $expectedReceiptPrefix = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.tmp-settings-receipt-'))
        if (-not $resolvedReceiptRoot.StartsWith($expectedReceiptPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing to clean a settings receipt test directory outside the expected prefix.'
        }
        Remove-Item -LiteralPath $resolvedReceiptRoot -Recurse -Force
    }
}

Write-Host ''
Write-Host ("Settings tests: {0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) {
    exit 1
}
