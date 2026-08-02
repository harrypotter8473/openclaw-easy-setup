Set-StrictMode -Version Latest

$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:EngineModulePath = Join-Path $PSScriptRoot 'OpenClawEasySetup.psm1'
$script:CredentialModulePath = Join-Path $PSScriptRoot 'OpenClawEasySetup.CredentialManager.psm1'
$script:ResolverSourcePath = Join-Path $PSScriptRoot 'CredentialResolver\OpenClawEasySetup.SecretResolver.cs'
$script:CredentialProviderAlias = 'oces_wincred'
$script:SettingsInvocationCache = $null

foreach ($requiredPath in @($script:EngineModulePath, $script:CredentialModulePath, $script:ResolverSourcePath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "A required safe-setup component was not found: $requiredPath"
    }
}

Import-Module -Name $script:EngineModulePath -Force -ErrorAction Stop
Import-Module -Name $script:CredentialModulePath -Force -ErrorAction Stop

function Get-OpenClawSafeSetupCatalog {
    [CmdletBinding()]
    param()

    return [pscustomobject]@{
        Version = '0.4.0'
        Providers = @(
            [pscustomobject]@{
                Id = 'openai'
                Label = 'OpenAI API'
                Models = @(
                    [pscustomobject]@{ Id = 'openai/gpt-5.6'; Label = 'GPT-5.6 (권장)' }
                    [pscustomobject]@{ Id = 'openai/gpt-5.5'; Label = 'GPT-5.5 (호환 선택)' }
                )
            }
            [pscustomobject]@{
                Id = 'anthropic'
                Label = 'Anthropic API'
                Models = @(
                    [pscustomobject]@{ Id = 'anthropic/claude-opus-4-8'; Label = 'Claude Opus 4.8 (권장)' }
                    [pscustomobject]@{ Id = 'anthropic/claude-sonnet-5'; Label = 'Claude Sonnet 5' }
                )
            }
            [pscustomobject]@{
                Id = 'google'
                Label = 'Google Gemini API'
                Models = @(
                    [pscustomobject]@{ Id = 'google/gemini-3.1-pro-preview'; Label = 'Gemini 3.1 Pro Preview (권장)' }
                    [pscustomobject]@{ Id = 'google/gemini-3-flash-preview'; Label = 'Gemini 3 Flash Preview' }
                )
            }
        )
        SecurityDefaults = [pscustomobject]@{
            GatewayMode = 'local'
            GatewayBind = 'loopback'
            GatewayAuth = 'token'
            ToolProfile = 'messaging'
            ElevatedTools = $false
            DirectMessagePolicy = 'pairing'
            GroupPolicy = 'disabled'
            ChannelConfigWrites = $false
        }
    }
}

function ConvertTo-OpenClawSettingsJson {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Value,
        [switch]$Compress
    )

    if ($Compress) {
        return ($Value | ConvertTo-Json -Depth 32 -Compress)
    }
    return ($Value | ConvertTo-Json -Depth 32)
}

function Get-OpenClawTextSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Text)
        try {
            return ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '').ToUpperInvariant()
        }
        finally {
            [Array]::Clear($bytes, 0, $bytes.Length)
        }
    }
    finally {
        $algorithm.Dispose()
    }
}

function ConvertTo-OpenClawSettingsWindowsArgument {
    param(
        [AllowEmptyString()]
        [string]$Argument
    )

    if ($null -eq $Argument) {
        $Argument = ''
    }
    if ($Argument.Length -gt 32760) {
        throw 'An OpenClaw settings command argument exceeded the Windows limit.'
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

function New-OpenClawSettingsInvocationCacheEntry {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Invocation,
        [Parameter(Mandatory = $true)]
        [string]$CacheKey
    )

    $stamps = New-Object System.Collections.Generic.List[object]
    $paths = @([string]$Invocation.Executable) + @($Invocation.PrefixArguments | Where-Object { Test-Path -LiteralPath ([string]$_) -PathType Leaf } | ForEach-Object { [string]$_ })
    foreach ($path in @($paths | Select-Object -Unique)) {
        $fullPath = [IO.Path]::GetFullPath($path)
        $item = Get-Item -LiteralPath $fullPath -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'A verified OpenClaw invocation path became unsafe.'
        }
        $isEntryPoint = @($Invocation.PrefixArguments | Where-Object { [string]::Equals([string]$_, $fullPath, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        $stamps.Add([pscustomobject]@{
            Path = $fullPath
            Length = [long]$item.Length
            LastWriteTimeUtcTicks = [long]$item.LastWriteTimeUtc.Ticks
            Sha256 = if ($isEntryPoint -and $item.Length -le 16MB) { (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash } else { '' }
        })
    }
    return [pscustomobject]@{
        CacheKey = $CacheKey
        Invocation = $Invocation
        Stamps = $stamps.ToArray()
    }
}

function Test-OpenClawSettingsInvocationCacheEntry {
    param(
        [AllowNull()]
        [object]$Entry,
        [Parameter(Mandatory = $true)]
        [string]$CacheKey
    )

    try {
        if ($null -eq $Entry -or -not [string]::Equals([string]$Entry.CacheKey, $CacheKey, [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
        foreach ($stamp in @($Entry.Stamps)) {
            if (-not (Test-Path -LiteralPath ([string]$stamp.Path) -PathType Leaf)) {
                return $false
            }
            $item = Get-Item -LiteralPath ([string]$stamp.Path) -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                [long]$item.Length -ne [long]$stamp.Length -or
                [long]$item.LastWriteTimeUtc.Ticks -ne [long]$stamp.LastWriteTimeUtcTicks) {
                return $false
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$stamp.Sha256)) {
                $currentHash = (Get-FileHash -LiteralPath ([string]$stamp.Path) -Algorithm SHA256).Hash
                if (-not [string]::Equals($currentHash, [string]$stamp.Sha256, [StringComparison]::OrdinalIgnoreCase)) {
                    return $false
                }
            }
        }
        return @($Entry.Stamps).Count -gt 0
    }
    catch {
        return $false
    }
}

function Get-OpenClawSettingsInvocation {
    param(
        [string]$StateDirectory,
        [switch]$ForceRefresh
    )

    $cacheKey = Get-OpenClawSafeSetupStateRoot -StateDirectory $StateDirectory
    if (-not $ForceRefresh -and (Test-OpenClawSettingsInvocationCacheEntry -Entry $script:SettingsInvocationCache -CacheKey $cacheKey)) {
        return $script:SettingsInvocationCache.Invocation
    }

    Update-OpenClawProcessPath
    $invocation = Resolve-OpenClawInvocation -StateDirectory $StateDirectory
    if ($null -eq $invocation) {
        throw 'OpenClaw was not found. Complete the verified installation before configuration.'
    }
    $script:SettingsInvocationCache = New-OpenClawSettingsInvocationCacheEntry -Invocation $invocation -CacheKey $cacheKey
    return $script:SettingsInvocationCache.Invocation
}

function Invoke-OpenClawSettingsCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [AllowEmptyString()]
        [string]$InputText,
        [string]$StateDirectory,
        [int]$TimeoutMilliseconds = 120000,
        [switch]$AllowFailure,
        [switch]$ForceInvocationRefresh
    )

    $invocation = Get-OpenClawSettingsInvocation -StateDirectory $StateDirectory -ForceRefresh:$ForceInvocationRefresh

    $allArguments = @($invocation.PrefixArguments) + @($Arguments)
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = [IO.Path]::GetFullPath([string]$invocation.Executable)
    $startInfo.Arguments = (@($allArguments | ForEach-Object { ConvertTo-OpenClawSettingsWindowsArgument -Argument ([string]$_) }) -join ' ')
    $startInfo.WorkingDirectory = $script:ProjectRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $PSBoundParameters.ContainsKey('InputText')
    $utf8 = New-Object Text.UTF8Encoding($false)
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    $inputBytes = $null
    try {
        if (-not $process.Start()) {
            throw 'The OpenClaw settings command did not start.'
        }
        $standardOutput = $process.StandardOutput.ReadToEndAsync()
        $standardError = $process.StandardError.ReadToEndAsync()
        if ($startInfo.RedirectStandardInput) {
            $inputBytes = $utf8.GetBytes($InputText)
            $process.StandardInput.BaseStream.Write($inputBytes, 0, $inputBytes.Length)
            $process.StandardInput.BaseStream.Flush()
            $process.StandardInput.Close()
        }
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            try { $process.Kill() } catch { }
            throw 'The OpenClaw settings command timed out.'
        }
        $stdout = [string]$standardOutput.Result
        $stderr = [string]$standardError.Result
        if ($stdout.Length -gt 16MB -or $stderr.Length -gt 1MB) {
            throw 'The OpenClaw settings command returned more output than allowed.'
        }
        $result = [pscustomobject]@{
            Arguments = @($Arguments)
            ExitCode = [int]$process.ExitCode
            Succeeded = $process.ExitCode -eq 0
            Stdout = $stdout
            SafeError = Protect-OpenClawLogText -Text $stderr -MaximumLength 2048
        }
        if (-not $result.Succeeded -and -not $AllowFailure) {
            throw ("OpenClaw command failed safely (exit {0}): {1}" -f $result.ExitCode, ($Arguments -join ' '))
        }
        return $result
    }
    finally {
        if ($null -ne $inputBytes) {
            [Array]::Clear($inputBytes, 0, $inputBytes.Length)
        }
        $process.Dispose()
    }
}

function Resolve-OpenClawSettingsConfigPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $lines = @($Text -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -ne 1) {
        throw 'OpenClaw returned an ambiguous active configuration path.'
    }
    $path = $lines[0].Trim()
    if ($path -eq '~' -or $path.StartsWith('~\') -or $path.StartsWith('~/')) {
        if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
            throw 'The user profile path was unavailable while resolving the OpenClaw configuration.'
        }
        $relative = $path.Substring(1).TrimStart('\', '/')
        $path = Join-Path $env:USERPROFILE $relative
    }
    $path = [Environment]::ExpandEnvironmentVariables($path)
    return [IO.Path]::GetFullPath($path)
}

function Get-OpenClawSettingsFileHash {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return Get-OpenClawTextSha256 -Text 'OPENCLAW-CONFIG-MISSING-v1'
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The active OpenClaw configuration path was not a regular file.'
    }
    if ($item.Length -gt 10MB) {
        throw 'The active OpenClaw configuration exceeded the safe inspection size.'
    }
    return (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-OpenClawSafeSetupLiveState {
    [CmdletBinding()]
    param(
        [string]$StateDirectory,
        [switch]$ForceInvocationRefresh
    )

    $source = Get-OpenClawSourceConfig
    $schemaResult = Invoke-OpenClawSettingsCommand -Arguments @('config', 'schema') -StateDirectory $StateDirectory -ForceInvocationRefresh:$ForceInvocationRefresh
    try {
        [void]($schemaResult.Stdout | ConvertFrom-Json)
    }
    catch {
        throw 'OpenClaw returned an invalid configuration schema document.'
    }
    $validateResult = Invoke-OpenClawSettingsCommand -Arguments @('config', 'validate', '--json') -StateDirectory $StateDirectory -AllowFailure
    if (-not $validateResult.Succeeded) {
        throw 'The existing OpenClaw configuration is invalid. Run the official repair flow before Easy Setup.'
    }
    $pathResult = Invoke-OpenClawSettingsCommand -Arguments @('config', 'file') -StateDirectory $StateDirectory
    $configPath = Resolve-OpenClawSettingsConfigPath -Text $pathResult.Stdout
    return [pscustomobject]@{
        OpenClawVersion = [string]$source.openClaw.version
        SchemaHash = Get-OpenClawTextSha256 -Text $schemaResult.Stdout
        BaseConfigHash = Get-OpenClawSettingsFileHash -Path $configPath
        ConfigPath = $configPath
    }
}

function Get-OpenClawSafeSetupRecoveryCompatibilityState {
    param(
        [string]$StateDirectory
    )

    # Recovery may need to repair a drifted (and potentially invalid) config, so
    # collect only the immutable compatibility inputs here. Do not validate or
    # bind the current config bytes as a new baseline.
    $source = Get-OpenClawSourceConfig
    $schemaResult = Invoke-OpenClawSettingsCommand `
        -Arguments @('config', 'schema') `
        -StateDirectory $StateDirectory `
        -ForceInvocationRefresh
    try {
        [void]($schemaResult.Stdout | ConvertFrom-Json)
    }
    catch {
        throw 'OpenClaw returned an invalid recovery configuration schema document.'
    }
    $pathResult = Invoke-OpenClawSettingsCommand -Arguments @('config', 'file') -StateDirectory $StateDirectory
    return [pscustomobject]@{
        OpenClawVersion = [string]$source.openClaw.version
        SchemaHash = Get-OpenClawTextSha256 -Text $schemaResult.Stdout
        ConfigPath = Resolve-OpenClawSettingsConfigPath -Text $pathResult.Stdout
    }
}

function Test-OpenClawSafeSetupRecoveryCompatibility {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Plan,
        [Parameter(Mandatory = $true)]
        [object]$LiveState
    )

    try {
        if ($null -eq $Plan -or $null -eq $LiveState -or
            [string]$Plan.SchemaHash -notmatch '^[A-Fa-f0-9]{64}$' -or
            [string]$LiveState.SchemaHash -notmatch '^[A-Fa-f0-9]{64}$') {
            return $false
        }
        $planConfigPath = [IO.Path]::GetFullPath([string]$Plan.ConfigPath)
        $liveConfigPath = [IO.Path]::GetFullPath([string]$LiveState.ConfigPath)
        return [string]::Equals([string]$Plan.OpenClawVersion, [string]$LiveState.OpenClawVersion, [StringComparison]::Ordinal) -and
            [string]::Equals([string]$Plan.SchemaHash, [string]$LiveState.SchemaHash, [StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals($planConfigPath, $liveConfigPath, [StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return $false
    }
}

function Get-OpenClawSafeSetupStateRoot {
    param([string]$StateDirectory)

    if ([string]::IsNullOrWhiteSpace($StateDirectory)) {
        $localApplicationData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        if ([string]::IsNullOrWhiteSpace($localApplicationData)) {
            throw 'The current user LocalApplicationData directory could not be determined.'
        }
        $StateDirectory = Join-Path $localApplicationData 'OpenClawEasySetup'
    }
    return [IO.Path]::GetFullPath($StateDirectory)
}

function New-OpenClawSecretReference {
    param([string]$Id)

    return [ordered]@{
        source = 'exec'
        provider = $script:CredentialProviderAlias
        id = $Id
    }
}

function Get-OpenClawSafeSetupReplacePaths {
    param(
        [string]$ProviderId,
        [bool]$EnableTelegram,
        [bool]$EnableDiscord
    )

    $paths = New-Object System.Collections.Generic.List[string]
    # The exec provider is a replace-owned object. In particular, an empty env
    # object in a recursive merge would otherwise retain pre-existing entries.
    $paths.Add("secrets.providers.$($script:CredentialProviderAlias)")
    $paths.Add('gateway.auth')
    $paths.Add('agents.defaults.model')
    $paths.Add('models.mode')
    # Replace the selected provider object so an old baseUrl/header override
    # cannot receive the newly entered API key. Bundled provider defaults remain.
    $paths.Add(("models.providers.{0}" -f $ProviderId))
    if ($EnableTelegram) { $paths.Add('channels.telegram') }
    if ($EnableDiscord) { $paths.Add('channels.discord') }
    return $paths.ToArray()
}

function Get-OpenClawSafeSetupPatchArguments {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Plan,
        [switch]$DryRun,
        [switch]$AllowExec
    )

    $arguments = New-Object System.Collections.Generic.List[string]
    foreach ($argument in @('config', 'patch', '--stdin')) { $arguments.Add($argument) }
    foreach ($path in @($Plan.ReplacePaths)) {
        $arguments.Add('--replace-path')
        $arguments.Add([string]$path)
    }
    if ($DryRun) {
        $arguments.Add('--dry-run')
        $arguments.Add('--json')
    }
    if ($AllowExec) { $arguments.Add('--allow-exec') }
    return $arguments.ToArray()
}

function Assert-OpenClawSafeSetupSelection {
    param(
        [string]$ProviderId,
        [string]$ModelId
    )

    $catalog = Get-OpenClawSafeSetupCatalog
    $provider = @($catalog.Providers | Where-Object Id -eq $ProviderId)
    if ($provider.Count -ne 1) {
        throw 'Choose one of the model providers supported by this reviewed setup version.'
    }
    if (@($provider[0].Models | Where-Object Id -eq $ModelId).Count -ne 1) {
        throw 'Choose a reviewed model for the selected provider.'
    }
}

function Get-OpenClawSafeSetupPlanFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Plan
    )

    $fingerprintSource = [ordered]@{
        planVersion = 1
        openClawVersion = [string]$Plan.OpenClawVersion
        schemaHash = [string]$Plan.SchemaHash
        baseConfigHash = [string]$Plan.BaseConfigHash
        configPath = [string]$Plan.ConfigPath
        resolverPath = [string]$Plan.ResolverPath
        providerId = [string]$Plan.ProviderId
        modelId = [string]$Plan.ModelId
        enableTelegram = [bool]$Plan.EnableTelegram
        enableDiscord = [bool]$Plan.EnableDiscord
        credentialIds = $Plan.CredentialIds
        replacePaths = @($Plan.ReplacePaths)
        patch = $Plan.Patch
    }
    return Get-OpenClawTextSha256 -Text (ConvertTo-OpenClawSettingsJson -Value $fingerprintSource -Compress)
}

function New-OpenClawSafeSetupPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('openai', 'anthropic', 'google')]
        [string]$ProviderId,
        [Parameter(Mandatory = $true)]
        [string]$ModelId,
        [bool]$EnableTelegram = $false,
        [bool]$EnableDiscord = $false,
        [string]$StateDirectory,
        [ValidatePattern('^[A-Fa-f0-9]{32}$')]
        [string]$RunId,
        [ValidatePattern('^[A-Fa-f0-9]{64}$')]
        [string]$SchemaHash,
        [ValidatePattern('^[A-Fa-f0-9]{64}$')]
        [string]$BaseConfigHash,
        [string]$ConfigPath,
        [string]$ResolverPath
    )

    Assert-OpenClawSafeSetupSelection -ProviderId $ProviderId -ModelId $ModelId
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = [guid]::NewGuid().ToString('N')
    }

    $hasInjectedLiveState = -not [string]::IsNullOrWhiteSpace($SchemaHash) -or -not [string]::IsNullOrWhiteSpace($BaseConfigHash) -or -not [string]::IsNullOrWhiteSpace($ConfigPath)
    if ($hasInjectedLiveState) {
        if ($SchemaHash -notmatch '^[A-Fa-f0-9]{64}$' -or $BaseConfigHash -notmatch '^[A-Fa-f0-9]{64}$' -or [string]::IsNullOrWhiteSpace($ConfigPath)) {
            throw 'Injected setup state requires schema hash, config hash, and config path together.'
        }
        $source = Get-OpenClawSourceConfig
        $liveState = [pscustomobject]@{
            OpenClawVersion = [string]$source.openClaw.version
            SchemaHash = $SchemaHash.ToUpperInvariant()
            BaseConfigHash = $BaseConfigHash.ToUpperInvariant()
            ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
        }
    }
    else {
        $liveState = Get-OpenClawSafeSetupLiveState -StateDirectory $StateDirectory -ForceInvocationRefresh
    }

    if ([string]::IsNullOrWhiteSpace($ResolverPath)) {
        $ResolverPath = Join-Path (Get-OpenClawSafeSetupStateRoot -StateDirectory $StateDirectory) 'State\Resolver\OpenClawEasySetup.SecretResolver.exe'
    }
    $ResolverPath = [IO.Path]::GetFullPath($ResolverPath)

    $credentialIds = [ordered]@{
        GatewayToken = "v1/gateway/auth/token/$RunId"
        ModelApiKey = "v1/models/$ProviderId/api-key/$RunId"
    }
    if ($EnableTelegram) {
        $credentialIds['TelegramBotToken'] = "v1/channels/telegram/bot-token/$RunId"
    }
    if ($EnableDiscord) {
        $credentialIds['DiscordBotToken'] = "v1/channels/discord/bot-token/$RunId"
    }
    foreach ($credentialId in $credentialIds.Values) {
        if (-not (Test-OpenClawCredentialId -Id ([string]$credentialId))) {
            throw 'An internal Credential Manager identifier failed validation.'
        }
    }

    $modelProviders = [ordered]@{}
    $modelProviders[$ProviderId] = [ordered]@{
        apiKey = New-OpenClawSecretReference -Id $credentialIds.ModelApiKey
    }
    $channels = [ordered]@{}
    if ($EnableTelegram) {
        $channels['telegram'] = [ordered]@{
            enabled = $true
            botToken = New-OpenClawSecretReference -Id $credentialIds.TelegramBotToken
            dmPolicy = 'pairing'
            groupPolicy = 'disabled'
            configWrites = $false
        }
    }
    if ($EnableDiscord) {
        $channels['discord'] = [ordered]@{
            enabled = $true
            token = New-OpenClawSecretReference -Id $credentialIds.DiscordBotToken
            dmPolicy = 'pairing'
            groupPolicy = 'disabled'
            configWrites = $false
        }
    }

    $patch = [ordered]@{
        gateway = [ordered]@{
            mode = 'local'
            bind = 'loopback'
            auth = [ordered]@{
                mode = 'token'
                token = New-OpenClawSecretReference -Id $credentialIds.GatewayToken
                rateLimit = [ordered]@{
                    maxAttempts = 10
                    windowMs = 60000
                    lockoutMs = 300000
                    exemptLoopback = $true
                }
            }
            tailscale = [ordered]@{ mode = 'off' }
            terminal = [ordered]@{ enabled = $false }
        }
        secrets = [ordered]@{
            providers = [ordered]@{
                $script:CredentialProviderAlias = [ordered]@{
                    source = 'exec'
                    command = $ResolverPath
                    args = @()
                    env = [ordered]@{}
                    passEnv = @()
                    jsonOnly = $true
                    timeoutMs = 5000
                    noOutputTimeoutMs = 5000
                    maxOutputBytes = 65536
                    trustedDirs = @((Split-Path -Parent $ResolverPath))
                    allowSymlinkCommand = $false
                    allowInsecurePath = $false
                }
            }
        }
        agents = [ordered]@{
            defaults = [ordered]@{
                model = [ordered]@{ primary = $ModelId }
            }
        }
        models = [ordered]@{
            mode = 'merge'
            providers = $modelProviders
        }
        session = [ordered]@{ dmScope = 'per-channel-peer' }
        tools = [ordered]@{
            profile = 'messaging'
            deny = @('group:runtime', 'group:fs', 'group:automation', 'group:ui', 'group:nodes', 'group:plugins', 'bundle-mcp')
            elevated = [ordered]@{ enabled = $false }
        }
    }
    if ($channels.Count -gt 0) {
        $patch['channels'] = $channels
    }

    $plan = [pscustomobject]@{
        PlanVersion = 1
        OpenClawVersion = [string]$liveState.OpenClawVersion
        SchemaHash = [string]$liveState.SchemaHash
        BaseConfigHash = [string]$liveState.BaseConfigHash
        ConfigPath = [string]$liveState.ConfigPath
        ResolverPath = $ResolverPath
        ProviderId = $ProviderId
        ModelId = $ModelId
        EnableTelegram = $EnableTelegram
        EnableDiscord = $EnableDiscord
        CredentialIds = [pscustomobject]$credentialIds
        ReplacePaths = @(Get-OpenClawSafeSetupReplacePaths -ProviderId $ProviderId -EnableTelegram $EnableTelegram -EnableDiscord $EnableDiscord)
        Patch = [pscustomobject]$patch
        Fingerprint = ''
    }
    $plan.Fingerprint = Get-OpenClawSafeSetupPlanFingerprint -Plan $plan
    return $plan
}

function Get-OpenClawSafeSetupPreview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Plan
    )

    Assert-OpenClawSafeSetupPlan -Plan $Plan
    $patchJson = ConvertTo-OpenClawSettingsJson -Value $Plan.Patch
    $channelSummary = New-Object System.Collections.Generic.List[string]
    if ($Plan.EnableTelegram) { $channelSummary.Add('Telegram: DM pairing, 그룹 차단') }
    if ($Plan.EnableDiscord) { $channelSummary.Add('Discord: DM pairing, 서버 그룹 차단') }
    if ($channelSummary.Count -eq 0) { $channelSummary.Add('선택한 채널 없음 (기존 채널은 변경하지 않음)') }
    $lines = @(
        'OpenClaw 쉬운 설정 변경 미리보기'
        "- 대상 OpenClaw: $($Plan.OpenClawVersion)"
        "- 기본 모델: $($Plan.ModelId)"
        '- Gateway: 이 PC의 loopback만, 256-bit token 인증, Tailscale 노출 끔'
        '- 도구 권한: messaging 프로필, 파일/명령 실행/자동화/elevated 차단'
        '- 개인 대화: 채널별 상대방 세션 분리'
        "- 채널: $($channelSummary -join '; ')"
        '- 비밀값: Windows Credential Manager에 저장; 아래 패치에는 참조 ID만 포함'
        '- 적용 방식: 공식 config patch dry-run → Easy Setup 소유 비밀 경로 정확히 교체 → validate/audit'
        "- 정확히 교체하는 Easy Setup 경로: $(@($Plan.ReplacePaths) -join ', ')"
        '- 선택하지 않은 기존 채널과 기타 사용자 설정은 merge patch에서 유지'
        ''
        '비밀값이 제거된 공식 OpenClaw merge patch:'
        $patchJson
        ''
        "계획 지문: $($Plan.Fingerprint)"
    )
    return ($lines -join [Environment]::NewLine)
}

function Assert-OpenClawSafeSetupPlan {
    param([object]$Plan)

    if ($null -eq $Plan -or [int]$Plan.PlanVersion -ne 1) {
        throw 'The approved setup plan was missing or unsupported.'
    }
    if ([string]$Plan.SchemaHash -notmatch '^[A-Fa-f0-9]{64}$' -or [string]$Plan.BaseConfigHash -notmatch '^[A-Fa-f0-9]{64}$' -or [string]$Plan.Fingerprint -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'The approved setup plan hashes were invalid.'
    }
    $expectedReplacePaths = @(Get-OpenClawSafeSetupReplacePaths `
        -ProviderId ([string]$Plan.ProviderId) `
        -EnableTelegram ([bool]$Plan.EnableTelegram) `
        -EnableDiscord ([bool]$Plan.EnableDiscord))
    $actualReplacePaths = @($Plan.ReplacePaths)
    if ($actualReplacePaths.Count -ne $expectedReplacePaths.Count) {
        throw 'The approved setup plan replace-path contract was invalid.'
    }
    for ($replacePathIndex = 0; $replacePathIndex -lt $expectedReplacePaths.Count; $replacePathIndex++) {
        if (-not [string]::Equals([string]$actualReplacePaths[$replacePathIndex], [string]$expectedReplacePaths[$replacePathIndex], [StringComparison]::Ordinal)) {
            throw 'The approved setup plan replace-path contract was invalid.'
        }
    }
    $calculated = Get-OpenClawSafeSetupPlanFingerprint -Plan $Plan
    if (-not [string]::Equals($calculated, [string]$Plan.Fingerprint, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The approved setup plan changed after preview.'
    }
}

function Assert-OpenClawSafeSetupPlanFresh {
    param(
        [object]$Plan,
        [string]$StateDirectory,
        [switch]$ForceInvocationRefresh
    )

    $liveState = Get-OpenClawSafeSetupLiveState -StateDirectory $StateDirectory -ForceInvocationRefresh:$ForceInvocationRefresh
    if (-not [string]::Equals([string]$liveState.OpenClawVersion, [string]$Plan.OpenClawVersion, [StringComparison]::Ordinal) -or
        -not [string]::Equals([string]$liveState.SchemaHash, [string]$Plan.SchemaHash, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$liveState.BaseConfigHash, [string]$Plan.BaseConfigHash, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$liveState.ConfigPath, [string]$Plan.ConfigPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'OpenClaw schema or configuration changed after preview. Create and approve a new preview.'
    }
}

function Test-OpenClawSafeSetupDryRunJson {
    param(
        [AllowNull()]
        [object]$Value,
        [switch]$RequireExecResolution
    )

    try {
        if ($null -eq $Value -or $Value.ok -ne $true) {
            return $false
        }
        if ($RequireExecResolution) {
            $skippedProperty = $Value.PSObject.Properties['skippedExecRefs']
            $checksProperty = $Value.PSObject.Properties['checks']
            $completeProperty = if ($null -ne $checksProperty -and $null -ne $checksProperty.Value) { $checksProperty.Value.PSObject.Properties['resolvabilityComplete'] } else { $null }
            if ($null -eq $skippedProperty -or [int]$skippedProperty.Value -ne 0 -or
                $null -eq $completeProperty -or $completeProperty.Value -ne $true) {
                return $false
            }
        }
        return $true
    }
    catch {
        return $false
    }
}

function Invoke-OpenClawSafeSetupDryRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Plan,
        [string]$StateDirectory,
        [switch]$AllowExec,
        [switch]$ForceInvocationRefresh
    )

    Assert-OpenClawSafeSetupPlan -Plan $Plan
    $arguments = Get-OpenClawSafeSetupPatchArguments -Plan $Plan -DryRun -AllowExec:$AllowExec
    $patchJson = ConvertTo-OpenClawSettingsJson -Value $Plan.Patch
    $command = Invoke-OpenClawSettingsCommand -Arguments $arguments -InputText $patchJson -StateDirectory $StateDirectory -AllowFailure -ForceInvocationRefresh:$ForceInvocationRefresh
    $parsed = $null
    try { $parsed = $command.Stdout | ConvertFrom-Json } catch { }
    if (-not $command.Succeeded -or -not (Test-OpenClawSafeSetupDryRunJson -Value $parsed -RequireExecResolution:$AllowExec)) {
        throw 'OpenClaw rejected the safe setup patch during its official dry run.'
    }
    return [pscustomobject]@{
        Passed = $true
        ExecResolutionChecked = [bool]$AllowExec
        Operations = [int]$parsed.operations
        SkippedExecRefs = [int]$parsed.skippedExecRefs
    }
}

function New-OpenClawGatewayToken {
    [CmdletBinding()]
    param()

    $bytes = New-Object byte[] 32
    $generator = New-Object Security.Cryptography.RNGCryptoServiceProvider
    $secure = New-Object Security.SecureString
    try {
        $generator.GetBytes($bytes)
        $hex = '0123456789abcdef'
        foreach ($value in $bytes) {
            $secure.AppendChar($hex[[int]($value -shr 4)])
            $secure.AppendChar($hex[[int]($value -band 15)])
        }
        $secure.MakeReadOnly()
        return $secure
    }
    catch {
        $secure.Dispose()
        throw
    }
    finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
        $generator.Dispose()
    }
}

function Test-OpenClawCredentialMap {
    param(
        [object]$Plan,
        [hashtable]$CredentialMap
    )

    $expectedNames = @($Plan.CredentialIds.PSObject.Properties.Name)
    if ($CredentialMap.Count -ne $expectedNames.Count) {
        throw 'The setup credential set did not match the approved plan.'
    }
    foreach ($name in $expectedNames) {
        if (-not $CredentialMap.ContainsKey($name) -or $CredentialMap[$name] -isnot [Security.SecureString]) {
            throw "A required secure credential was missing: $name"
        }
        $length = $CredentialMap[$name].Length
        if ($length -le 0 -or $length -gt 2560) {
            throw "A secure credential had an unsupported length: $name"
        }
        $utf8ByteCount = Get-OpenClawCredentialUtf8ByteCount -Secret $CredentialMap[$name]
        if ($utf8ByteCount -le 0 -or $utf8ByteCount -gt 2560) {
            throw "A secure credential exceeded the Windows Credential Manager byte limit: $name"
        }
    }
}

function Test-OpenClawRecoveryCredentialMap {
    param(
        [object]$Plan,
        [hashtable]$CredentialMap
    )

    # Keep the generated Gateway token stable during recovery. Replacing it while
    # the running Gateway still has the old value loaded can lock the CLI out.
    $expectedNames = @('ModelApiKey')
    if ($Plan.EnableTelegram) { $expectedNames += 'TelegramBotToken' }
    if ($Plan.EnableDiscord) { $expectedNames += 'DiscordBotToken' }
    if ($CredentialMap.Count -ne $expectedNames.Count) {
        throw 'The recovery credential set did not match the pending plan.'
    }
    foreach ($name in $expectedNames) {
        if (-not $CredentialMap.ContainsKey($name) -or $CredentialMap[$name] -isnot [Security.SecureString]) {
            throw "A required secure recovery credential was missing: $name"
        }
        $length = $CredentialMap[$name].Length
        if ($length -le 0 -or $length -gt 2560) {
            throw "A secure recovery credential had an unsupported length: $name"
        }
        $utf8ByteCount = Get-OpenClawCredentialUtf8ByteCount -Secret $CredentialMap[$name]
        if ($utf8ByteCount -le 0 -or $utf8ByteCount -gt 2560) {
            throw "A secure recovery credential exceeded the Windows Credential Manager byte limit: $name"
        }
    }
}

function Test-OpenClawSafeSetupCredentialReplacementPending {
    param([object[]]$Checks)

    foreach ($check in @($Checks)) {
        if ($null -eq $check) { continue }
        $nameProperty = $check.PSObject.Properties['Name']
        if ($null -eq $nameProperty) { $nameProperty = $check.PSObject.Properties['name'] }
        $passedProperty = $check.PSObject.Properties['Passed']
        if ($null -eq $passedProperty) { $passedProperty = $check.PSObject.Properties['passed'] }
        if ($null -ne $nameProperty -and
            [string]::Equals([string]$nameProperty.Value, 'Credential replacement pending', [StringComparison]::Ordinal) -and
            ($null -eq $passedProperty -or $passedProperty.Value -ne $true)) {
            return $true
        }
    }
    return $false
}

function Get-OpenClawSafeSetupRecoveryChecks {
    param(
        [AllowEmptyCollection()]
        [object[]]$Checks = @(),
        [switch]$PreserveCredentialReplacementPending
    )

    $composed = New-Object System.Collections.Generic.List[object]
    foreach ($check in @($Checks)) {
        if ($null -eq $check) { continue }
        $nameProperty = $check.PSObject.Properties['Name']
        if ($null -eq $nameProperty) { $nameProperty = $check.PSObject.Properties['name'] }
        if ($null -ne $nameProperty -and
            [string]::Equals([string]$nameProperty.Value, 'Credential replacement pending', [StringComparison]::Ordinal)) {
            # Canonicalize the marker below so repeated recovery attempts cannot
            # duplicate it or accidentally preserve a stale passed variant.
            continue
        }
        $composed.Add($check)
    }
    if ($PreserveCredentialReplacementPending) {
        $composed.Add([pscustomobject]@{
            Name = 'Credential replacement pending'
            Passed = $false
            ExitCode = -1
            Detail = 'The complete receipt-bound model and selected-channel credential set must be written again after an interruption.'
        })
    }
    return $composed.ToArray()
}

function Invoke-OpenClawSafeSetupConfigurationContinuityCheck {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Plan,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$ExpectedConfigHash
    )

    $actualHash = ''
    try { $actualHash = Get-OpenClawSettingsFileHash -Path ([string]$Plan.ConfigPath) } catch { }
    $passed = $ExpectedConfigHash -match '^[A-Fa-f0-9]{64}$' -and
        -not [string]::IsNullOrWhiteSpace($actualHash) -and
        [string]::Equals($actualHash, $ExpectedConfigHash, [StringComparison]::OrdinalIgnoreCase)
    return [pscustomobject]@{
        Name = 'Approved patch continuity'
        Passed = $passed
        ExitCode = if ($passed) { 0 } else { -1 }
        Detail = if ($passed) { '' } else { 'The active configuration no longer matched the byte fingerprint established by the approved exact patch.' }
    }
}

function Get-OpenClawSafeSetupConfigValue {
    param(
        [string]$Path,
        [string]$StateDirectory
    )

    try {
        $result = Invoke-OpenClawSettingsCommand `
            -Arguments @('config', 'get', $Path, '--json') `
            -StateDirectory $StateDirectory `
            -AllowFailure
        if (-not $result.Succeeded) {
            return [pscustomobject]@{ Succeeded = $false; ExitCode = [int]$result.ExitCode; Value = $null }
        }
        try {
            return [pscustomobject]@{ Succeeded = $true; ExitCode = 0; Value = ($result.Stdout | ConvertFrom-Json) }
        }
        catch {
            return [pscustomobject]@{ Succeeded = $false; ExitCode = -1; Value = $null }
        }
    }
    catch {
        return [pscustomobject]@{ Succeeded = $false; ExitCode = -1; Value = $null }
    }
}

function Invoke-OpenClawSafeSetupInvariantCheck {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Plan,
        [string]$StateDirectory
    )

    $failures = New-Object System.Collections.Generic.List[string]
    $exitCode = 0
    $gateway = Get-OpenClawSafeSetupConfigValue -Path 'gateway' -StateDirectory $StateDirectory
    if (-not $gateway.Succeeded) {
        $exitCode = [int]$gateway.ExitCode
        $failures.Add('The Gateway safety configuration could not be read.')
    }
    else {
        try {
            if ([string]$gateway.Value.mode -ne 'local' -or
                [string]$gateway.Value.bind -ne 'loopback' -or
                [string]$gateway.Value.auth.mode -ne 'token' -or
                [string]$gateway.Value.tailscale.mode -ne 'off' -or
                $gateway.Value.terminal.enabled -ne $false) {
                $failures.Add('The Gateway was not local, loopback-only, token-authenticated, and remote surfaces disabled.')
            }
        }
        catch {
            $failures.Add('The Gateway safety configuration was incomplete.')
        }
    }

    $session = Get-OpenClawSafeSetupConfigValue -Path 'session' -StateDirectory $StateDirectory
    if (-not $session.Succeeded -or [string]$session.Value.dmScope -ne 'per-channel-peer') {
        if (-not $session.Succeeded -and $exitCode -eq 0) { $exitCode = [int]$session.ExitCode }
        $failures.Add('Direct-message session isolation did not match the approved plan.')
    }

    $tools = Get-OpenClawSafeSetupConfigValue -Path 'tools' -StateDirectory $StateDirectory
    if (-not $tools.Succeeded) {
        if ($exitCode -eq 0) { $exitCode = [int]$tools.ExitCode }
        $failures.Add('The tool safety configuration could not be read.')
    }
    else {
        try {
            $requiredDeny = @('group:runtime', 'group:fs', 'group:automation', 'group:ui', 'group:nodes', 'group:plugins', 'bundle-mcp')
            $denyValues = @($tools.Value.deny)
            $missingDeny = @($requiredDeny | Where-Object { $_ -notin $denyValues })
            if ([string]$tools.Value.profile -ne 'messaging' -or
                $tools.Value.elevated.enabled -ne $false -or
                $missingDeny.Count -gt 0) {
                $failures.Add('The tool profile or explicit deny list did not match the approved minimum-permission plan.')
            }
        }
        catch {
            $failures.Add('The tool safety configuration was incomplete.')
        }
    }

    foreach ($channelId in @('telegram', 'discord')) {
        $enabledByPlan = if ($channelId -eq 'telegram') { [bool]$Plan.EnableTelegram } else { [bool]$Plan.EnableDiscord }
        if (-not $enabledByPlan) { continue }
        $channel = Get-OpenClawSafeSetupConfigValue -Path ("channels.$channelId") -StateDirectory $StateDirectory
        if (-not $channel.Succeeded) {
            if ($exitCode -eq 0) { $exitCode = [int]$channel.ExitCode }
            $failures.Add(("The selected {0} safety configuration could not be read." -f $channelId))
            continue
        }
        try {
            if ($channel.Value.enabled -ne $true -or
                [string]$channel.Value.dmPolicy -ne 'pairing' -or
                [string]$channel.Value.groupPolicy -ne 'disabled' -or
                $channel.Value.configWrites -ne $false) {
                $failures.Add(("The selected {0} channel did not retain pairing-only, groups-disabled, no-config-write defaults." -f $channelId))
            }
        }
        catch {
            $failures.Add(("The selected {0} safety configuration was incomplete." -f $channelId))
        }
    }

    return [pscustomobject]@{
        Name = 'Safe configuration invariants'
        Passed = $failures.Count -eq 0
        ExitCode = if ($failures.Count -eq 0) { 0 } elseif ($exitCode -eq 0) { -1 } else { $exitCode }
        Detail = Protect-OpenClawLogText -Text ($failures.ToArray() -join ' ') -MaximumLength 2048
    }
}

function Invoke-OpenClawSafeSetupCheck {
    param(
        [string]$Name,
        [string[]]$Arguments,
        [string]$StateDirectory
    )

    try {
        $result = Invoke-OpenClawSettingsCommand -Arguments $Arguments -StateDirectory $StateDirectory -AllowFailure
    }
    catch {
        return [pscustomobject]@{
            Name = $Name
            Passed = $false
            ExitCode = -1
            Detail = 'The OpenClaw check could not be started.'
        }
    }
    $detail = if ($result.Succeeded) {
        ''
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$result.SafeError)) {
        Protect-OpenClawLogText -Text ([string]$result.SafeError) -MaximumLength 1024
    }
    else {
        'The OpenClaw command returned a nonzero exit code.'
    }
    return [pscustomobject]@{
        Name = $Name
        Passed = [bool]$result.Succeeded
        ExitCode = [int]$result.ExitCode
        Detail = $detail
    }
}

function Test-OpenClawSecurityAuditJson {
    param([object]$Value)

    try {
        if ($null -eq $Value) { return $false }
        $summaryProperty = $Value.PSObject.Properties['summary']
        $findingsProperty = $Value.PSObject.Properties['findings']
        $deepProperty = $Value.PSObject.Properties['deep']
        $diagnosticsProperty = $Value.PSObject.Properties['secretDiagnostics']
        if ($null -eq $summaryProperty -or $null -eq $findingsProperty -or $null -eq $deepProperty -or $null -eq $diagnosticsProperty) {
            return $false
        }

        $summary = $summaryProperty.Value
        if ($null -eq $summary -or $null -eq $summary.PSObject.Properties['critical'] -or $null -eq $summary.PSObject.Properties['warn']) {
            return $false
        }
        if ([int]$summary.critical -ne 0 -or [int]$summary.warn -ne 0) {
            return $false
        }
        if (@($findingsProperty.Value | Where-Object { $_.severity -in @('critical', 'warn') }).Count -ne 0) {
            return $false
        }
        if (@($diagnosticsProperty.Value).Count -ne 0) {
            return $false
        }

        $deep = $deepProperty.Value
        $gatewayProperty = if ($null -ne $deep) { $deep.PSObject.Properties['gateway'] } else { $null }
        if ($null -eq $gatewayProperty -or $null -eq $gatewayProperty.Value) {
            return $false
        }
        $gateway = $gatewayProperty.Value
        return $gateway.PSObject.Properties['attempted'] -and
            $gateway.PSObject.Properties['ok'] -and
            $gateway.attempted -eq $true -and
            $gateway.ok -eq $true
    }
    catch {
        return $false
    }
}

function Test-OpenClawModelStatusJson {
    param(
        [object]$Value,
        [string]$ExpectedModelId
    )

    try {
        if ($null -eq $Value -or [string]::IsNullOrWhiteSpace($ExpectedModelId)) { return $false }
        $resolvedProperty = $Value.PSObject.Properties['resolvedDefault']
        $authProperty = $Value.PSObject.Properties['auth']
        if ($null -eq $resolvedProperty -or $null -eq $authProperty -or $null -eq $authProperty.Value) {
            return $false
        }
        $missingProperty = $authProperty.Value.PSObject.Properties['missingProvidersInUse']
        if ($null -eq $missingProperty) {
            return $false
        }
        return [string]::Equals([string]$resolvedProperty.Value, $ExpectedModelId, [StringComparison]::Ordinal) -and
            @($missingProperty.Value).Count -eq 0
    }
    catch {
        return $false
    }
}

function Test-OpenClawChannelStatusJson {
    param(
        [object]$Value,
        [ValidateSet('telegram', 'discord')]
        [string]$ChannelId
    )

    try {
        if ($null -eq $Value) { return $false }
        $configOnlyProperty = $Value.PSObject.Properties['configOnly']
        $gatewayReachableProperty = $Value.PSObject.Properties['gatewayReachable']
        $partialProperty = $Value.PSObject.Properties['partial']
        $warningsProperty = $Value.PSObject.Properties['warnings']
        if (($null -ne $configOnlyProperty -and $configOnlyProperty.Value -eq $true) -or
            ($null -ne $gatewayReachableProperty -and $gatewayReachableProperty.Value -eq $false) -or
            ($null -ne $partialProperty -and $partialProperty.Value -eq $true) -or
            ($null -ne $warningsProperty -and @($warningsProperty.Value).Count -gt 0)) {
            return $false
        }

        $channelAccountsProperty = $Value.PSObject.Properties['channelAccounts']
        if ($null -eq $channelAccountsProperty -or $null -eq $channelAccountsProperty.Value) {
            return $false
        }
        $accountsProperty = $channelAccountsProperty.Value.PSObject.Properties[$ChannelId]
        if ($null -eq $accountsProperty) {
            return $false
        }
        $accounts = @($accountsProperty.Value)
        if ($accounts.Count -eq 0) {
            return $false
        }
        $defaultAccounts = @($accounts | Where-Object {
            $accountIdProperty = $_.PSObject.Properties['accountId']
            $null -ne $accountIdProperty -and [string]$accountIdProperty.Value -eq 'default'
        })
        $candidates = if ($defaultAccounts.Count -gt 0) { $defaultAccounts } else { $accounts }
        $healthy = @($candidates | Where-Object {
            $enabledProperty = $_.PSObject.Properties['enabled']
            $configuredProperty = $_.PSObject.Properties['configured']
            $probeProperty = $_.PSObject.Properties['probe']
            $runningProperty = $_.PSObject.Properties['running']
            $connectedProperty = $_.PSObject.Properties['connected']
            $lastErrorProperty = $_.PSObject.Properties['lastError']
            $auditProperty = $_.PSObject.Properties['audit']
            $probeOk = $null -ne $probeProperty -and $null -ne $probeProperty.Value -and
                $null -ne $probeProperty.Value.PSObject.Properties['ok'] -and $probeProperty.Value.ok -eq $true
            $auditOk = $null -eq $auditProperty -or $null -eq $auditProperty.Value -or
                ($null -ne $auditProperty.Value.PSObject.Properties['ok'] -and $auditProperty.Value.ok -eq $true)
            $isRunning = $null -ne $runningProperty -and $runningProperty.Value -eq $true
            $isConnected = $ChannelId -ne 'discord' -or
                ($null -ne $connectedProperty -and $connectedProperty.Value -eq $true)
            $noLastError = $null -eq $lastErrorProperty -or [string]::IsNullOrWhiteSpace([string]$lastErrorProperty.Value)
            $null -ne $enabledProperty -and $enabledProperty.Value -eq $true -and
                $null -ne $configuredProperty -and $configuredProperty.Value -eq $true -and
                $probeOk -and $auditOk -and $isRunning -and $isConnected -and $noLastError
        })
        return $healthy.Count -gt 0
    }
    catch {
        return $false
    }
}

function Get-OpenClawSafeSetupSemanticFailureDetail {
    param(
        [ValidateSet('Security', 'Model', 'Channel')]
        [string]$Kind,
        [AllowNull()]
        [object]$Value,
        [string]$ExpectedModelId,
        [ValidateSet('', 'telegram', 'discord')]
        [string]$ChannelId = ''
    )

    $parts = New-Object System.Collections.Generic.List[string]
    try {
        switch ($Kind) {
            'Security' {
                if ($null -eq $Value) {
                    $parts.Add('Security audit JSON was missing or invalid.')
                    break
                }
                $summaryProperty = $Value.PSObject.Properties['summary']
                if ($null -ne $summaryProperty -and $null -ne $summaryProperty.Value) {
                    $criticalProperty = $summaryProperty.Value.PSObject.Properties['critical']
                    $warnProperty = $summaryProperty.Value.PSObject.Properties['warn']
                    if ($null -ne $criticalProperty -or $null -ne $warnProperty) {
                        $criticalValue = if ($null -ne $criticalProperty) { [string]$criticalProperty.Value } else { '<missing>' }
                        $warnValue = if ($null -ne $warnProperty) { [string]$warnProperty.Value } else { '<missing>' }
                        $parts.Add(('Security summary: critical={0}, warn={1}.' -f $criticalValue, $warnValue))
                    }
                }
                $findingsProperty = $Value.PSObject.Properties['findings']
                if ($null -ne $findingsProperty) {
                    foreach ($finding in @($findingsProperty.Value | Where-Object { $_.severity -in @('critical', 'warn') } | Select-Object -First 3)) {
                        $id = ''
                        foreach ($idName in @('checkId', 'id')) {
                            $idProperty = $finding.PSObject.Properties[$idName]
                            if ($null -ne $idProperty -and -not [string]::IsNullOrWhiteSpace([string]$idProperty.Value)) {
                                $id = [string]$idProperty.Value
                                break
                            }
                        }
                        $titleProperty = $finding.PSObject.Properties['title']
                        $title = if ($null -ne $titleProperty) { [string]$titleProperty.Value } else { '' }
                        $parts.Add(('{0}: {1} {2}' -f [string]$finding.severity, $id, $title).Trim())
                    }
                }
                $deepProperty = $Value.PSObject.Properties['deep']
                if ($null -eq $deepProperty -or $null -eq $deepProperty.Value -or
                    $null -eq $deepProperty.Value.PSObject.Properties['gateway'] -or
                    $null -eq $deepProperty.Value.gateway -or
                    $deepProperty.Value.gateway.attempted -ne $true -or
                    $deepProperty.Value.gateway.ok -ne $true) {
                    $parts.Add('Deep Gateway security probe did not succeed.')
                }
            }
            'Model' {
                if ($null -eq $Value) {
                    $parts.Add('Model status JSON was missing or invalid.')
                    break
                }
                $resolvedProperty = $Value.PSObject.Properties['resolvedDefault']
                $resolved = if ($null -ne $resolvedProperty) { [string]$resolvedProperty.Value } else { '<missing>' }
                if (-not [string]::Equals($resolved, $ExpectedModelId, [StringComparison]::Ordinal)) {
                    $parts.Add(("Resolved default model was '{0}', expected '{1}'." -f $resolved, $ExpectedModelId))
                }
                $authProperty = $Value.PSObject.Properties['auth']
                $missingProperty = if ($null -ne $authProperty -and $null -ne $authProperty.Value) { $authProperty.Value.PSObject.Properties['missingProvidersInUse'] } else { $null }
                if ($null -eq $missingProperty) {
                    $parts.Add('Model authentication status was missing.')
                }
                elseif (@($missingProperty.Value).Count -gt 0) {
                    $parts.Add(('Missing model authentication: {0}.' -f (@($missingProperty.Value) -join ', ')))
                }
            }
            'Channel' {
                if ($null -eq $Value) {
                    $parts.Add(("{0} status JSON was missing or invalid." -f $ChannelId))
                    break
                }
                foreach ($flagName in @('configOnly', 'gatewayReachable', 'partial')) {
                    $flagProperty = $Value.PSObject.Properties[$flagName]
                    if ($null -ne $flagProperty) {
                        $parts.Add(("{0}={1}." -f $flagName, [string]$flagProperty.Value))
                    }
                }
                $warningsProperty = $Value.PSObject.Properties['warnings']
                if ($null -ne $warningsProperty -and @($warningsProperty.Value).Count -gt 0) {
                    $parts.Add(('Channel warnings: {0}' -f (@($warningsProperty.Value | Select-Object -First 3) -join '; ')))
                }
                $channelAccountsProperty = $Value.PSObject.Properties['channelAccounts']
                $accountsProperty = if ($null -ne $channelAccountsProperty -and $null -ne $channelAccountsProperty.Value) { $channelAccountsProperty.Value.PSObject.Properties[$ChannelId] } else { $null }
                if ($null -eq $accountsProperty -or @($accountsProperty.Value).Count -eq 0) {
                    $parts.Add(("No {0} account status was returned." -f $ChannelId))
                }
                else {
                    foreach ($account in @($accountsProperty.Value | Select-Object -First 3)) {
                        $accountIdProperty = $account.PSObject.Properties['accountId']
                        $runningProperty = $account.PSObject.Properties['running']
                        $connectedProperty = $account.PSObject.Properties['connected']
                        $lastErrorProperty = $account.PSObject.Properties['lastError']
                        $accountId = if ($null -ne $accountIdProperty) { [string]$accountIdProperty.Value } else { '<unknown>' }
                        $running = if ($null -ne $runningProperty) { [string]$runningProperty.Value } else { '<missing>' }
                        $connected = if ($null -ne $connectedProperty) { [string]$connectedProperty.Value } else { '<missing>' }
                        $parts.Add(("Account {0}: running={1}, connected={2}." -f $accountId, $running, $connected))
                        if ($null -ne $lastErrorProperty -and -not [string]::IsNullOrWhiteSpace([string]$lastErrorProperty.Value)) {
                            $parts.Add(('Channel error: {0}' -f [string]$lastErrorProperty.Value))
                        }
                    }
                }
            }
        }
    }
    catch {
        $parts.Add('The returned status did not satisfy the expected JSON contract.')
    }

    if ($parts.Count -eq 0) {
        $parts.Add('The returned status did not satisfy the expected safety contract.')
    }
    return Protect-OpenClawLogText -Text ($parts.ToArray() -join ' ') -MaximumLength 2048
}

function Invoke-OpenClawSafeSetupJsonCheck {
    param(
        [string]$Name,
        [string[]]$Arguments,
        [string]$StateDirectory,
        [ValidateSet('Security', 'Model', 'Channel')]
        [string]$Kind,
        [string]$ExpectedModelId,
        [ValidateSet('', 'telegram', 'discord')]
        [string]$ChannelId = ''
    )

    try {
        $result = Invoke-OpenClawSettingsCommand -Arguments $Arguments -StateDirectory $StateDirectory -AllowFailure
    }
    catch {
        return [pscustomobject]@{
            Name = $Name
            Passed = $false
            ExitCode = -1
            Detail = 'The OpenClaw JSON check could not be started.'
        }
    }
    $parsed = $null
    try { $parsed = $result.Stdout | ConvertFrom-Json } catch { }
    $semanticPassed = switch ($Kind) {
        'Security' { Test-OpenClawSecurityAuditJson -Value $parsed }
        'Model' { Test-OpenClawModelStatusJson -Value $parsed -ExpectedModelId $ExpectedModelId }
        'Channel' { Test-OpenClawChannelStatusJson -Value $parsed -ChannelId $ChannelId }
    }
    $passed = [bool]($result.Succeeded -and $semanticPassed)
    $detail = ''
    if (-not $passed) {
        $details = New-Object System.Collections.Generic.List[string]
        if (-not [string]::IsNullOrWhiteSpace([string]$result.SafeError)) {
            $details.Add([string]$result.SafeError)
        }
        $details.Add((Get-OpenClawSafeSetupSemanticFailureDetail -Kind $Kind -Value $parsed -ExpectedModelId $ExpectedModelId -ChannelId $ChannelId))
        $detail = Protect-OpenClawLogText -Text ($details.ToArray() -join ' ') -MaximumLength 2048
    }
    return [pscustomobject]@{
        Name = $Name
        Passed = $passed
        ExitCode = [int]$result.ExitCode
        Detail = $detail
    }
}

function Assert-OpenClawSafeSetupReceiptAcl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'Safe-setup recovery receipts require Windows ACL verification.'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $systemSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
        $acl = Get-Acl -LiteralPath $Path
        $ownerSid = $acl.GetOwner([Security.Principal.SecurityIdentifier])
        $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        $allowedSids = @($identity.User.Value, $systemSid.Value)
        $unexpectedAllow = @($rules | Where-Object {
            $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            $_.IdentityReference.Value -notin $allowedSids
        }).Count -gt 0
        $hasUserControl = @($rules | Where-Object {
            $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            $_.IdentityReference.Value -eq $identity.User.Value -and
            ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl
        }).Count -gt 0
        $hasSystemControl = @($rules | Where-Object {
            $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            $_.IdentityReference.Value -eq $systemSid.Value -and
            ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl
        }).Count -gt 0
        if ($ownerSid.Value -ne $identity.User.Value -or $unexpectedAllow -or -not $hasUserControl -or -not $hasSystemControl) {
            throw 'The safe-setup recovery receipt ACL was not private.'
        }
    }
    finally {
        $identity.Dispose()
    }
}

function Write-OpenClawSafeSetupRecoveryReceipt {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Plan,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Checks,
        [Parameter(Mandatory = $true)]
        [string[]]$CredentialIds,
        [ValidateSet('Preparing', 'AppliedPendingChecks', 'Succeeded', 'Partial', 'RolledBack')]
        [string]$Status,
        [AllowEmptyString()]
        [string]$AppliedConfigHash,
        [string]$StateDirectory
    )

    Assert-OpenClawSafeSetupPlan -Plan $Plan
    if ($CredentialIds.Count -eq 0) {
        throw 'A recovery receipt requires the exact created credential ids.'
    }
    foreach ($id in $CredentialIds) {
        if (-not (Test-OpenClawCredentialId -Id $id)) {
            throw 'A recovery receipt credential id was invalid.'
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($AppliedConfigHash) -and $AppliedConfigHash -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'The applied configuration hash was invalid.'
    }

    $directories = Initialize-OpenClawStateDirectory -Path $StateDirectory
    $statePath = [IO.Path]::GetFullPath([string]$directories.State)
    $stateItem = Get-Item -LiteralPath $statePath -Force
    if (-not $stateItem.PSIsContainer -or ($stateItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The recovery receipt State directory was unsafe.'
    }

    $receiptName = 'settings-{0}.json' -f ([string]$Plan.Fingerprint).ToUpperInvariant()
    $receiptPath = [IO.Path]::GetFullPath((Join-Path $statePath $receiptName))
    $statePrefix = $statePath.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $receiptPath.StartsWith($statePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The recovery receipt destination was unsafe.'
    }

    $existingReceipt = $null
    if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
        $existingReceipt = Read-OpenClawSafeSetupRecoveryReceiptFile -Path $receiptPath -StatePath $statePath
        if (@($existingReceipt.CredentialIds).Count -ne $CredentialIds.Count) {
            throw 'The recovery receipt credential set changed during an update.'
        }
        for ($credentialIndex = 0; $credentialIndex -lt $CredentialIds.Count; $credentialIndex++) {
            if (-not [string]::Equals([string]$existingReceipt.CredentialIds[$credentialIndex], [string]$CredentialIds[$credentialIndex], [StringComparison]::Ordinal)) {
                throw 'The recovery receipt credential set changed during an update.'
            }
        }
        $allowedTransitions = @{
            Preparing = @('AppliedPendingChecks', 'Partial', 'RolledBack')
            AppliedPendingChecks = @('Succeeded', 'Partial')
            Succeeded = @()
            Partial = @('Partial', 'Succeeded')
            RolledBack = @()
        }
        if ($Status -notin @($allowedTransitions[[string]$existingReceipt.Status])) {
            throw 'The recovery receipt state transition was not allowed.'
        }
    }
    elseif ($Status -ne 'Preparing') {
        throw 'A recovery receipt must begin in the Preparing state.'
    }

    $safeChecks = @($Checks | ForEach-Object {
        $nameProperty = $_.PSObject.Properties['Name']
        $passedProperty = $_.PSObject.Properties['Passed']
        $exitCodeProperty = $_.PSObject.Properties['ExitCode']
        $detailProperty = $_.PSObject.Properties['Detail']
        [ordered]@{
            name = Protect-OpenClawLogText -Text $(if ($null -ne $nameProperty) { [string]$nameProperty.Value } else { 'Unknown check' }) -MaximumLength 256
            passed = $null -ne $passedProperty -and $passedProperty.Value -eq $true
            exitCode = if ($null -ne $exitCodeProperty) { [int]$exitCodeProperty.Value } else { -1 }
            detail = Protect-OpenClawLogText -Text $(if ($null -ne $detailProperty) { [string]$detailProperty.Value } else { '' }) -MaximumLength 2048
        }
    })
    $receiptIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $receiptUserSid = $receiptIdentity.User.Value
    }
    finally {
        $receiptIdentity.Dispose()
    }
    $now = [DateTime]::UtcNow.ToString('o')
    $receipt = [ordered]@{
        schemaVersion = 1
        toolVersion = '0.4.0'
        userSid = $receiptUserSid
        createdAtUtc = if ($null -ne $existingReceipt) { [string]$existingReceipt.CreatedAtUtc } else { $now }
        updatedAtUtc = $now
        status = $Status
        planFingerprint = ([string]$Plan.Fingerprint).ToUpperInvariant()
        openClawVersion = [string]$Plan.OpenClawVersion
        schemaHash = ([string]$Plan.SchemaHash).ToUpperInvariant()
        configPath = [string]$Plan.ConfigPath
        resolverPath = [string]$Plan.ResolverPath
        providerId = [string]$Plan.ProviderId
        modelId = [string]$Plan.ModelId
        enableTelegram = [bool]$Plan.EnableTelegram
        enableDiscord = [bool]$Plan.EnableDiscord
        baseConfigHash = ([string]$Plan.BaseConfigHash).ToUpperInvariant()
        appliedConfigHash = if ([string]::IsNullOrWhiteSpace($AppliedConfigHash)) { '' } else { $AppliedConfigHash.ToUpperInvariant() }
        credentialIds = @($CredentialIds)
        credentialIdsByName = $Plan.CredentialIds
        replacePaths = @($Plan.ReplacePaths)
        patch = $Plan.Patch
        checks = $safeChecks
    }
    $json = ConvertTo-OpenClawSettingsJson -Value $receipt
    if ($json.Length -gt 1MB) {
        throw 'The recovery receipt exceeded its size limit.'
    }

    $temporaryPath = [IO.Path]::GetFullPath((Join-Path $statePath ('.settings-receipt-' + [Guid]::NewGuid().ToString('N') + '.tmp')))
    $backupPath = [IO.Path]::GetFullPath((Join-Path $statePath ('.settings-receipt-' + [Guid]::NewGuid().ToString('N') + '.bak')))
    $stream = $null
    $writer = $null
    $replaceSucceeded = $false
    try {
        $stream = New-Object IO.FileStream($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $writer = New-Object IO.StreamWriter($stream, (New-Object Text.UTF8Encoding($false)))
        $writer.Write($json)
        $writer.Flush()
        $stream.Flush($true)
        $writer.Dispose()
        $writer = $null
        $stream.Dispose()
        $stream = $null

        Assert-OpenClawSafeSetupReceiptAcl -Path $temporaryPath
        if ($null -eq $existingReceipt) {
            [IO.File]::Move($temporaryPath, $receiptPath)
        }
        else {
            [IO.File]::Replace($temporaryPath, $receiptPath, $backupPath, $true)
        }
        $receiptItem = Get-Item -LiteralPath $receiptPath -Force
        if ($receiptItem.PSIsContainer -or ($receiptItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $receiptItem.Length -le 0 -or $receiptItem.Length -gt 1MB) {
            throw 'The recovery receipt failed its post-write validation.'
        }
        Assert-OpenClawSafeSetupReceiptAcl -Path $receiptPath
        $writtenReceipt = Read-OpenClawSafeSetupRecoveryReceiptFile -Path $receiptPath -StatePath $statePath
        if (-not [string]::Equals([string]$writtenReceipt.Status, $Status, [StringComparison]::Ordinal) -or
            -not [string]::Equals([string]$writtenReceipt.PlanFingerprint, [string]$Plan.Fingerprint, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The recovery receipt did not match the requested state after writing.'
        }
        $replaceSucceeded = $true
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
            [IO.File]::Delete($backupPath)
        }
        return $receiptPath
    }
    finally {
        if ($null -ne $writer) { $writer.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            [IO.File]::Delete($temporaryPath)
        }
        if ($replaceSucceeded -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            [IO.File]::Delete($backupPath)
        }
    }
}

function Read-OpenClawSafeSetupRecoveryReceiptFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$StatePath
    )

    $stateFullPath = [IO.Path]::GetFullPath($StatePath)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $statePrefix = $stateFullPath.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($statePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'A recovery receipt escaped the private State directory.'
    }
    $fileName = [IO.Path]::GetFileName($fullPath)
    $nameMatch = [regex]::Match($fileName, '^settings-([A-Fa-f0-9]{64})\.json$', [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $nameMatch.Success) {
        throw 'A recovery receipt filename was invalid.'
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw 'A recovery receipt was missing.'
    }
    $item = Get-Item -LiteralPath $fullPath -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -le 0 -or $item.Length -gt 1MB) {
        throw 'A recovery receipt file was unsafe.'
    }
    Assert-OpenClawSafeSetupReceiptAcl -Path $fullPath

    try {
        $data = Get-Content -LiteralPath $fullPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw 'A recovery receipt was not valid JSON.'
    }
    foreach ($requiredProperty in @(
        'schemaVersion', 'toolVersion', 'userSid', 'createdAtUtc', 'updatedAtUtc', 'status',
        'planFingerprint', 'openClawVersion', 'schemaHash', 'configPath', 'resolverPath',
        'providerId', 'modelId', 'enableTelegram', 'enableDiscord', 'baseConfigHash',
        'appliedConfigHash', 'credentialIds', 'credentialIdsByName', 'replacePaths', 'patch', 'checks'
    )) {
        if ($null -eq $data.PSObject.Properties[$requiredProperty]) {
            throw 'A recovery receipt was missing a required field.'
        }
    }
    if ([int]$data.schemaVersion -ne 1 -or [string]$data.toolVersion -ne '0.4.0') {
        throw 'A recovery receipt schema or tool version was unsupported.'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        if (-not [string]::Equals([string]$data.userSid, $identity.User.Value, [StringComparison]::Ordinal)) {
            throw 'A recovery receipt belonged to a different Windows user.'
        }
    }
    finally {
        $identity.Dispose()
    }
    $fingerprint = ([string]$data.planFingerprint).ToUpperInvariant()
    if ($fingerprint -notmatch '^[A-F0-9]{64}$' -or
        -not [string]::Equals($fingerprint, $nameMatch.Groups[1].Value, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$data.schemaHash -notmatch '^[A-Fa-f0-9]{64}$' -or
        [string]$data.baseConfigHash -notmatch '^[A-Fa-f0-9]{64}$' -or
        (-not [string]::IsNullOrWhiteSpace([string]$data.appliedConfigHash) -and [string]$data.appliedConfigHash -notmatch '^[A-Fa-f0-9]{64}$')) {
        throw 'A recovery receipt hash binding was invalid.'
    }
    $allowedStatuses = @('Preparing', 'AppliedPendingChecks', 'Succeeded', 'Partial', 'RolledBack')
    if ([string]$data.status -notin $allowedStatuses) {
        throw 'A recovery receipt status was invalid.'
    }
    try {
        $createdAt = [DateTimeOffset]::Parse([string]$data.createdAtUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        $updatedAt = [DateTimeOffset]::Parse([string]$data.updatedAtUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    }
    catch {
        throw 'A recovery receipt timestamp was invalid.'
    }
    if ($updatedAt -lt $createdAt) {
        throw 'A recovery receipt timestamp order was invalid.'
    }
    $credentialIds = @($data.credentialIds)
    if ($credentialIds.Count -lt 2 -or $credentialIds.Count -gt 4 -or @($credentialIds | Select-Object -Unique).Count -ne $credentialIds.Count) {
        throw 'A recovery receipt credential set was invalid.'
    }
    foreach ($id in $credentialIds) {
        if (-not (Test-OpenClawCredentialId -Id ([string]$id))) {
            throw 'A recovery receipt credential id was invalid.'
        }
    }
    $expectedCredentialNames = @('GatewayToken', 'ModelApiKey')
    if ([bool]$data.enableTelegram) { $expectedCredentialNames += 'TelegramBotToken' }
    if ([bool]$data.enableDiscord) { $expectedCredentialNames += 'DiscordBotToken' }
    $credentialProperties = @($data.credentialIdsByName.PSObject.Properties)
    if ($credentialProperties.Count -ne $expectedCredentialNames.Count) {
        throw 'A recovery receipt named credential set was invalid.'
    }
    for ($credentialIndex = 0; $credentialIndex -lt $expectedCredentialNames.Count; $credentialIndex++) {
        $name = $expectedCredentialNames[$credentialIndex]
        $property = $data.credentialIdsByName.PSObject.Properties[$name]
        if ($null -eq $property -or
            -not [string]::Equals([string]$property.Value, [string]$credentialIds[$credentialIndex], [StringComparison]::Ordinal)) {
            throw 'A recovery receipt named credential set did not match its ordered ids.'
        }
    }
    $configPath = [IO.Path]::GetFullPath([string]$data.configPath)
    $resolverPath = [IO.Path]::GetFullPath([string]$data.resolverPath)
    if (-not [string]::Equals($configPath, [string]$data.configPath, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals($resolverPath, [string]$data.resolverPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'A recovery receipt contained a noncanonical path.'
    }
    Assert-OpenClawSafeSetupSelection -ProviderId ([string]$data.providerId) -ModelId ([string]$data.modelId)
    $receiptPlan = [pscustomobject]@{
        PlanVersion = 1
        OpenClawVersion = [string]$data.openClawVersion
        SchemaHash = ([string]$data.schemaHash).ToUpperInvariant()
        BaseConfigHash = ([string]$data.baseConfigHash).ToUpperInvariant()
        ConfigPath = $configPath
        ResolverPath = $resolverPath
        ProviderId = [string]$data.providerId
        ModelId = [string]$data.modelId
        EnableTelegram = [bool]$data.enableTelegram
        EnableDiscord = [bool]$data.enableDiscord
        CredentialIds = [pscustomobject]$data.credentialIdsByName
        ReplacePaths = @($data.replacePaths)
        Patch = [pscustomobject]$data.patch
        Fingerprint = $fingerprint
    }
    Assert-OpenClawSafeSetupPlan -Plan $receiptPlan
    foreach ($check in @($data.checks)) {
        foreach ($checkProperty in @('name', 'passed', 'exitCode', 'detail')) {
            if ($null -eq $check.PSObject.Properties[$checkProperty]) {
                throw 'A recovery receipt check record was invalid.'
            }
        }
        if ([string]$check.name -ne (Protect-OpenClawLogText -Text ([string]$check.name) -MaximumLength 256) -or
            [string]$check.detail -ne (Protect-OpenClawLogText -Text ([string]$check.detail) -MaximumLength 2048)) {
            throw 'A recovery receipt contained an unsanitized check record.'
        }
    }

    return [pscustomobject]@{
        Path = $fullPath
        Status = [string]$data.status
        PlanFingerprint = $fingerprint
        CreatedAtUtc = $createdAt.ToString('o')
        UpdatedAtUtc = $updatedAt.ToString('o')
        UpdatedAtUtcValue = $updatedAt.UtcDateTime
        CredentialIds = $credentialIds
        AppliedConfigHash = [string]$data.appliedConfigHash
        Checks = @($data.checks)
        Plan = $receiptPlan
    }
}

function Get-OpenClawSafeSetupPendingRecovery {
    [CmdletBinding()]
    param(
        [string]$StateDirectory
    )

    $rootPath = Get-OpenClawSafeSetupStateRoot -StateDirectory $StateDirectory
    $statePath = [IO.Path]::GetFullPath((Join-Path $rootPath 'State'))
    if (-not (Test-Path -LiteralPath $statePath)) {
        return $null
    }
    $stateItem = Get-Item -LiteralPath $statePath -Force
    if (-not $stateItem.PSIsContainer -or ($stateItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The safe-setup recovery State directory was unsafe.'
    }
    Assert-OpenClawSafeSetupReceiptAcl -Path $statePath
    $files = @(Get-ChildItem -LiteralPath $statePath -Filter 'settings-*.json' -File -Force)
    if ($files.Count -gt 1000) {
        throw 'Too many safe-setup recovery receipts were present.'
    }
    $pending = New-Object System.Collections.Generic.List[object]
    foreach ($file in $files) {
        $receipt = Read-OpenClawSafeSetupRecoveryReceiptFile -Path $file.FullName -StatePath $statePath
        if ($receipt.Status -in @('Preparing', 'AppliedPendingChecks', 'Partial')) {
            $pending.Add($receipt)
        }
    }
    if ($pending.Count -eq 0) {
        return $null
    }
    $selected = @($pending.ToArray() | Sort-Object UpdatedAtUtcValue -Descending | Select-Object -First 1)[0]
    $selected | Add-Member -NotePropertyName PendingCount -NotePropertyValue $pending.Count -Force
    return $selected
}

function Enter-OpenClawSafeSetupTransactionLock {
    param(
        [string]$StateDirectory
    )

    $directories = Initialize-OpenClawStateDirectory -Path $StateDirectory
    $statePath = [IO.Path]::GetFullPath([string]$directories.State)
    Assert-OpenClawSafeSetupReceiptAcl -Path $statePath
    $lockPath = [IO.Path]::GetFullPath((Join-Path $statePath 'settings.apply.lock'))
    $stream = $null
    try {
        $stream = New-Object IO.FileStream(
            $lockPath,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None,
            1,
            [IO.FileOptions]::DeleteOnClose
        )
        Assert-OpenClawSafeSetupReceiptAcl -Path $lockPath
        return $stream
    }
    catch {
        if ($null -ne $stream) { $stream.Dispose() }
        throw 'Another safe-setup apply or an unsafe transaction lock prevented configuration.'
    }
}

function Test-OpenClawSafeSetupGatewayPreflightChecks {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Checks
    )

    foreach ($requiredName in @('Approved patch continuity', 'Config validation', 'Safe configuration invariants')) {
        $matchingChecks = @($Checks | Where-Object {
            $nameProperty = $_.PSObject.Properties['Name']
            $null -ne $nameProperty -and
                [string]::Equals([string]$nameProperty.Value, $requiredName, [StringComparison]::Ordinal)
        })
        if ($matchingChecks.Count -ne 1) {
            return $false
        }
        $passedProperty = $matchingChecks[0].PSObject.Properties['Passed']
        if ($null -eq $passedProperty -or $passedProperty.Value -ne $true) {
            return $false
        }
    }
    return $true
}

function Invoke-OpenClawSafeSetupPostChecks {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Plan,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$ExpectedConfigHash,
        [string]$StateDirectory,
        [switch]$EnsureGatewayService
    )

    $checks = New-Object System.Collections.Generic.List[object]
    # Successful official patch + byte identity is the value-free proof for
    # SecretRefs. `config get` redacts descendants of paths such as apiKey and
    # therefore cannot prove their provider/id fields on the pinned release.
    $gatewayPreflightChecks = @(
        Invoke-OpenClawSafeSetupConfigurationContinuityCheck -Plan $Plan -ExpectedConfigHash $ExpectedConfigHash
        Invoke-OpenClawSafeSetupCheck -Name 'Config validation' -Arguments @('config', 'validate', '--json') -StateDirectory $StateDirectory
        Invoke-OpenClawSafeSetupInvariantCheck -Plan $Plan -StateDirectory $StateDirectory
    )
    foreach ($preflightCheck in $gatewayPreflightChecks) {
        $checks.Add($preflightCheck)
    }
    if ($EnsureGatewayService) {
        if (Test-OpenClawSafeSetupGatewayPreflightChecks -Checks $gatewayPreflightChecks) {
            $checks.Add((Invoke-OpenClawSafeSetupCheck -Name 'Gateway service install' -Arguments @('gateway', 'install', '--json') -StateDirectory $StateDirectory))
            $checks.Add((Invoke-OpenClawSafeSetupCheck -Name 'Gateway restart' -Arguments @('gateway', 'restart', '--json') -StateDirectory $StateDirectory))
        }
        else {
            foreach ($gatewayCheckName in @('Gateway service install', 'Gateway restart')) {
                $checks.Add([pscustomobject]@{
                    Name = $gatewayCheckName
                    Passed = $false
                    ExitCode = -1
                    Detail = 'Skipped because configuration continuity, validation, or safe invariants failed before Gateway mutation.'
                })
            }
        }
    }
    $checks.Add((Invoke-OpenClawSafeSetupCheck -Name 'Secrets audit' -Arguments @('secrets', 'audit', '--check', '--allow-exec') -StateDirectory $StateDirectory))
    $checks.Add((Invoke-OpenClawSafeSetupJsonCheck -Name 'Security audit' -Arguments @('security', 'audit', '--deep', '--json') -StateDirectory $StateDirectory -Kind Security))
    $checks.Add((Invoke-OpenClawSafeSetupJsonCheck -Name 'Model status' -Arguments @('models', 'status', '--check', '--json') -StateDirectory $StateDirectory -Kind Model -ExpectedModelId ([string]$Plan.ModelId)))
    if ($Plan.EnableTelegram) {
        $checks.Add((Invoke-OpenClawSafeSetupJsonCheck -Name 'Telegram probe' -Arguments @('channels', 'status', '--channel', 'telegram', '--probe', '--json') -StateDirectory $StateDirectory -Kind Channel -ChannelId telegram))
    }
    if ($Plan.EnableDiscord) {
        $checks.Add((Invoke-OpenClawSafeSetupJsonCheck -Name 'Discord probe' -Arguments @('channels', 'status', '--channel', 'discord', '--probe', '--json') -StateDirectory $StateDirectory -Kind Channel -ChannelId discord))
    }
    $checks.Add((Invoke-OpenClawSafeSetupCheck -Name 'Gateway RPC' -Arguments @('gateway', 'status', '--require-rpc', '--json') -StateDirectory $StateDirectory))
    return $checks.ToArray()
}

function Invoke-OpenClawSafeSetupRecoveryVerification {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [string]$StateDirectory,
        [hashtable]$CredentialMap,
        [switch]$AcceptConfigChange,
        [switch]$EnsureGatewayService
    )

    if ($WhatIfPreference) {
        # Transaction-lock creation initializes and hardens the state tree, so a
        # WhatIf preview must inspect only an already-existing receipt tree.
        $previewReceipt = Get-OpenClawSafeSetupPendingRecovery -StateDirectory $StateDirectory
        if ($null -eq $previewReceipt) {
            return [pscustomobject]@{ Resolved = $true; Status = 'None'; Checks = @(); RecoveryReceiptPath = '' }
        }
        [void]$PSCmdlet.ShouldProcess(
            [string]$previewReceipt.Path,
            'Preview pending Easy Setup recovery without acquiring a transaction lock or changing state'
        )
        return [pscustomobject]@{
            Resolved = $false
            Status = [string]$previewReceipt.Status
            Checks = @($previewReceipt.Checks)
            RecoveryReceiptPath = [string]$previewReceipt.Path
        }
    }

    $transactionLock = Enter-OpenClawSafeSetupTransactionLock -StateDirectory $StateDirectory
    try {
        $receipt = Get-OpenClawSafeSetupPendingRecovery -StateDirectory $StateDirectory
        if ($null -eq $receipt) {
            return [pscustomobject]@{ Resolved = $true; Status = 'None'; Checks = @(); RecoveryReceiptPath = '' }
        }
        if ([int]$receipt.PendingCount -ne 1) {
            return [pscustomobject]@{
                Resolved = $false
                Status = 'MultiplePending'
                Checks = @([pscustomobject]@{ Name = 'Recovery guard'; Passed = $false; ExitCode = -1; Detail = 'Multiple unresolved recovery receipts require manual review.' })
                RecoveryReceiptPath = [string]$receipt.Path
            }
        }

        $plan = $receipt.Plan
        $replacementWasPending = Test-OpenClawSafeSetupCredentialReplacementPending -Checks @($receipt.Checks)
        $compatibilityPassed = $false
        try {
            $compatibilityLiveState = Get-OpenClawSafeSetupRecoveryCompatibilityState -StateDirectory $StateDirectory
            $compatibilityPassed = Test-OpenClawSafeSetupRecoveryCompatibility -Plan $plan -LiveState $compatibilityLiveState
        }
        catch { }
        $compatibilityCheck = [pscustomobject]@{
            Name = 'Recovery plan compatibility'
            Passed = $compatibilityPassed
            ExitCode = if ($compatibilityPassed) { 0 } else { -1 }
            Detail = if ($compatibilityPassed) { '' } else { 'The installed OpenClaw version, runtime schema, or active configuration path no longer matched the pending receipt.' }
        }
        if (-not $compatibilityPassed) {
            # Leave the existing receipt untouched (including any interrupted
            # credential-replacement marker) and perform no recovery mutation.
            $compatibilityChecks = @(Get-OpenClawSafeSetupRecoveryChecks `
                -Checks @($compatibilityCheck) `
                -PreserveCredentialReplacementPending:$replacementWasPending)
            return [pscustomobject]@{
                Resolved = $false
                Status = [string]$receipt.Status
                Checks = $compatibilityChecks
                RecoveryReceiptPath = [string]$receipt.Path
            }
        }
        $currentConfigHash = ''
        $configHashReadable = $true
        try {
            $currentConfigHash = Get-OpenClawSettingsFileHash -Path ([string]$plan.ConfigPath)
        }
        catch {
            $configHashReadable = $false
        }
        if ($receipt.Status -eq 'Preparing') {
            if (-not $configHashReadable -or -not [string]::Equals($currentConfigHash, [string]$plan.BaseConfigHash, [StringComparison]::OrdinalIgnoreCase)) {
                $ambiguityCheck = [pscustomobject]@{
                    Name = 'Interrupted apply state'
                    Passed = $false
                    ExitCode = -1
                    Detail = if ($configHashReadable) {
                        'The configuration changed after a Preparing receipt. Automatic credential cleanup was blocked.'
                    }
                    else {
                        'The configuration fingerprint could not be read after a Preparing receipt. Automatic credential cleanup was blocked.'
                    }
                }
                if ($PSCmdlet.ShouldProcess([string]$receipt.Path, 'Record the interrupted apply as Partial without deleting credentials')) {
                    # Do not rebase continuity here. A readable change may be the
                    # approved patch, an unrelated edit, or a partial write; only
                    # an explicit AcceptConfigChange recovery may bind a new hash.
                    [void](Write-OpenClawSafeSetupRecoveryReceipt -Plan $plan -Checks @($ambiguityCheck) -CredentialIds @($receipt.CredentialIds) -Status Partial -AppliedConfigHash '' -StateDirectory $StateDirectory)
                }
                return [pscustomobject]@{ Resolved = $false; Status = 'Partial'; Checks = @($ambiguityCheck); RecoveryReceiptPath = [string]$receipt.Path }
            }

            $cleanupChecks = New-Object System.Collections.Generic.List[object]
            if (-not $PSCmdlet.ShouldProcess('Run-scoped Windows Credential Manager entries', 'Clean up an interrupted pre-patch setup attempt')) {
                return [pscustomobject]@{ Resolved = $false; Status = 'Preparing'; Checks = @(); RecoveryReceiptPath = [string]$receipt.Path }
            }
            $cleanupSucceeded = $true
            foreach ($id in @($receipt.CredentialIds)) {
                try {
                    [void](Remove-OpenClawCredential -Id ([string]$id) -Confirm:$false)
                }
                catch {
                    $cleanupSucceeded = $false
                }
            }
            $cleanupChecks.Add([pscustomobject]@{
                Name = 'Interrupted credential cleanup'
                Passed = $cleanupSucceeded
                ExitCode = if ($cleanupSucceeded) { 0 } else { -1 }
                Detail = if ($cleanupSucceeded) { '' } else { 'One or more exact run-scoped credentials could not be removed.' }
            })
            if ($cleanupSucceeded) {
                [void](Write-OpenClawSafeSetupRecoveryReceipt -Plan $plan -Checks $cleanupChecks.ToArray() -CredentialIds @($receipt.CredentialIds) -Status RolledBack -AppliedConfigHash '' -StateDirectory $StateDirectory)
            }
            return [pscustomobject]@{
                Resolved = $cleanupSucceeded
                Status = if ($cleanupSucceeded) { 'RolledBack' } else { 'Preparing' }
                Checks = $cleanupChecks.ToArray()
                RecoveryReceiptPath = [string]$receipt.Path
            }
        }

        $replacementRequested = $PSBoundParameters.ContainsKey('CredentialMap')
        if ($replacementWasPending -and -not $replacementRequested) {
            $replacementGuard = [pscustomobject]@{
                Name = 'Credential replacement recovery'
                Passed = $false
                ExitCode = -1
                Detail = 'A previous all-secret replacement stopped before its completion checkpoint. Re-enter the complete receipt-bound model and selected-channel credential set.'
            }
            $replacementGuardChecks = @(Get-OpenClawSafeSetupRecoveryChecks `
                -Checks (@($receipt.Checks) + @($replacementGuard)) `
                -PreserveCredentialReplacementPending)
            return [pscustomobject]@{
                Resolved = $false
                Status = 'Partial'
                Checks = $replacementGuardChecks
                RecoveryReceiptPath = [string]$receipt.Path
            }
        }

        $recoveryChecks = New-Object System.Collections.Generic.List[object]
        foreach ($initialRecoveryCheck in @(Get-OpenClawSafeSetupRecoveryChecks `
            -Checks @($compatibilityCheck) `
            -PreserveCredentialReplacementPending:$replacementWasPending)) {
            $recoveryChecks.Add($initialRecoveryCheck)
        }
        $activeConfigPathMatches = $false
        try {
            $activePathResult = Invoke-OpenClawSettingsCommand -Arguments @('config', 'file') -StateDirectory $StateDirectory
            $activeConfigPath = Resolve-OpenClawSettingsConfigPath -Text $activePathResult.Stdout
            $activeConfigPathMatches = [string]::Equals(
                [IO.Path]::GetFullPath($activeConfigPath),
                [IO.Path]::GetFullPath([string]$plan.ConfigPath),
                [StringComparison]::OrdinalIgnoreCase
            )
        }
        catch { }
        if (-not $activeConfigPathMatches) {
            $recoveryChecks.Add([pscustomobject]@{
                Name = 'Active configuration path'
                Passed = $false
                ExitCode = -1
                Detail = 'The official config CLI did not resolve the exact configuration file recorded by the pending receipt.'
            })
            if ($PSCmdlet.ShouldProcess([string]$receipt.Path, 'Keep recovery Partial because the active configuration path changed')) {
                [void](Write-OpenClawSafeSetupRecoveryReceipt `
                    -Plan $plan `
                    -Checks $recoveryChecks.ToArray() `
                    -CredentialIds @($receipt.CredentialIds) `
                    -Status Partial `
                    -AppliedConfigHash ([string]$receipt.AppliedConfigHash) `
                    -StateDirectory $StateDirectory)
            }
            return [pscustomobject]@{
                Resolved = $false
                Status = 'Partial'
                Checks = $recoveryChecks.ToArray()
                RecoveryReceiptPath = [string]$receipt.Path
            }
        }
        $expectedAppliedConfigHash = [string]$receipt.AppliedConfigHash
        $configHashMatches = $configHashReadable -and
            -not [string]::IsNullOrWhiteSpace($expectedAppliedConfigHash) -and
            [string]::Equals($currentConfigHash, $expectedAppliedConfigHash, [StringComparison]::OrdinalIgnoreCase)
        $restoreApprovedPatch = $false
        if (-not $configHashMatches) {
            $restoreApprovedPatch = $configHashReadable -and [bool]$AcceptConfigChange
            $recoveryChecks.Add([pscustomobject]@{
                Name = 'Configuration drift recovery authorization'
                Passed = $restoreApprovedPatch
                ExitCode = if ($restoreApprovedPatch) { 0 } else { -1 }
                Detail = if (-not $configHashReadable) {
                    'The current configuration fingerprint could not be read safely.'
                }
                elseif ([string]::IsNullOrWhiteSpace($expectedAppliedConfigHash)) {
                    if ($restoreApprovedPatch) {
                        'The operator authorized restoration of the fingerprint-bound Easy Setup patch because no verified applied fingerprint was available.'
                    }
                    else {
                        'The pending receipt did not contain a verified applied configuration fingerprint. Explicit patch restoration is required.'
                    }
                }
                elseif ($restoreApprovedPatch) {
                    'The operator authorized restoration of the fingerprint-bound Easy Setup patch over its owned paths.'
                }
                else {
                    'The current configuration fingerprint differed from the pending receipt. Explicit patch restoration is required.'
                }
            })
            if (-not $restoreApprovedPatch) {
                if ($PSCmdlet.ShouldProcess([string]$receipt.Path, 'Keep the recovery receipt Partial because configuration continuity was not established')) {
                    [void](Write-OpenClawSafeSetupRecoveryReceipt `
                        -Plan $plan `
                        -Checks $recoveryChecks.ToArray() `
                        -CredentialIds @($receipt.CredentialIds) `
                        -Status Partial `
                        -AppliedConfigHash $expectedAppliedConfigHash `
                        -StateDirectory $StateDirectory)
                }
                return [pscustomobject]@{
                    Resolved = $false
                    Status = 'Partial'
                    Checks = $recoveryChecks.ToArray()
                    RecoveryReceiptPath = [string]$receipt.Path
                }
            }
        }

        $restartGateway = $EnsureGatewayService -or $replacementRequested -or $restoreApprovedPatch
        if ($replacementRequested) {
            Test-OpenClawRecoveryCredentialMap -Plan $plan -CredentialMap $CredentialMap
        }
        if ($restartGateway -and -not $restoreApprovedPatch) {
            $preMutationChecks = @(
                Invoke-OpenClawSafeSetupConfigurationContinuityCheck -Plan $plan -ExpectedConfigHash $expectedAppliedConfigHash
                Invoke-OpenClawSafeSetupInvariantCheck -Plan $plan -StateDirectory $StateDirectory
            )
            $failedPreMutationChecks = @($preMutationChecks | Where-Object Passed -eq $false)
            if ($failedPreMutationChecks.Count -gt 0) {
                foreach ($check in $preMutationChecks) { $recoveryChecks.Add($check) }
                if ($PSCmdlet.ShouldProcess([string]$receipt.Path, 'Keep recovery Partial because the active config did not retain its approved patch fingerprint and safe invariants')) {
                    [void](Write-OpenClawSafeSetupRecoveryReceipt `
                        -Plan $plan `
                        -Checks $recoveryChecks.ToArray() `
                        -CredentialIds @($receipt.CredentialIds) `
                        -Status Partial `
                        -AppliedConfigHash $currentConfigHash `
                        -StateDirectory $StateDirectory)
                }
                return [pscustomobject]@{
                    Resolved = $false
                    Status = 'Partial'
                    Checks = $recoveryChecks.ToArray()
                    RecoveryReceiptPath = [string]$receipt.Path
                }
            }
        }
        $recoveryAction = if ($restoreApprovedPatch -and $replacementRequested) {
            'Restore the approved Easy Setup patch, replace the exact pending model/channel credentials, restart the Gateway, re-run checks, and record the result'
        }
        elseif ($restoreApprovedPatch) {
            'Restore the approved Easy Setup patch over its owned paths, restart the Gateway, re-run checks, and record the result'
        }
        elseif ($replacementRequested) {
            'Replace the exact pending model/channel credentials, restart the Gateway, re-run checks, and record the result'
        }
        elseif ($restartGateway) {
            'Restart the Gateway, re-run all pending setup checks, and record the result'
        }
        else {
            'Run read-only pending setup checks and record the result'
        }
        if (-not $PSCmdlet.ShouldProcess([string]$receipt.Path, $recoveryAction)) {
            return [pscustomobject]@{
                Resolved = $false
                Status = [string]$receipt.Status
                Checks = $recoveryChecks.ToArray()
                RecoveryReceiptPath = [string]$receipt.Path
            }
        }

        if ($restartGateway) {
            $resolverReady = $false
            try {
                $resolver = Install-OpenClawCredentialResolver -StateDirectory $StateDirectory -Confirm:$false
                $resolverReady = $null -ne $resolver -and [string]::Equals(
                    [IO.Path]::GetFullPath([string]$resolver.Path),
                    [IO.Path]::GetFullPath([string]$plan.ResolverPath),
                    [StringComparison]::OrdinalIgnoreCase
                )
            }
            catch { }
            $recoveryChecks.Add([pscustomobject]@{
                Name = 'Credential resolver refresh'
                Passed = $resolverReady
                ExitCode = if ($resolverReady) { 0 } else { -1 }
                Detail = if ($resolverReady) { '' } else { 'The approved Credential Manager resolver could not be rebuilt and verified before recovery commands.' }
            })
            if (-not $resolverReady) {
                [void](Write-OpenClawSafeSetupRecoveryReceipt -Plan $plan -Checks $recoveryChecks.ToArray() -CredentialIds @($receipt.CredentialIds) -Status Partial -AppliedConfigHash $expectedAppliedConfigHash -StateDirectory $StateDirectory)
                return [pscustomobject]@{ Resolved = $false; Status = 'Partial'; Checks = $recoveryChecks.ToArray(); RecoveryReceiptPath = [string]$receipt.Path }
            }
        }

        if ($replacementRequested) {
            $replacementCheckpointHash = if ($configHashMatches) { $currentConfigHash } else { $expectedAppliedConfigHash }
            $replacementCheckpointChecks = @(Get-OpenClawSafeSetupRecoveryChecks `
                -Checks $recoveryChecks.ToArray() `
                -PreserveCredentialReplacementPending)
            try {
                [void](Write-OpenClawSafeSetupRecoveryReceipt `
                    -Plan $plan `
                    -Checks $replacementCheckpointChecks `
                    -CredentialIds @($receipt.CredentialIds) `
                    -Status Partial `
                    -AppliedConfigHash $replacementCheckpointHash `
                    -StateDirectory $StateDirectory)
            }
            catch {
                $recoveryChecks.Add([pscustomobject]@{
                    Name = 'Credential replacement checkpoint'
                    Passed = $false
                    ExitCode = -1
                    Detail = 'The all-secret replacement checkpoint could not be recorded before the first credential write.'
                })
                $checkpointFailureChecks = @(Get-OpenClawSafeSetupRecoveryChecks `
                    -Checks $recoveryChecks.ToArray() `
                    -PreserveCredentialReplacementPending:$replacementWasPending)
                return [pscustomobject]@{ Resolved = $false; Status = 'Partial'; Checks = $checkpointFailureChecks; RecoveryReceiptPath = [string]$receipt.Path }
            }

            # From this durable checkpoint onward every write and returned check
            # set retains the marker until the full-set completion checkpoint.
            $recoveryChecks.Clear()
            foreach ($checkpointCheck in $replacementCheckpointChecks) { $recoveryChecks.Add($checkpointCheck) }

            $replacementSucceeded = $true
            foreach ($name in @('ModelApiKey', 'TelegramBotToken', 'DiscordBotToken')) {
                if (-not $CredentialMap.ContainsKey($name)) { continue }
                try {
                    $credentialId = [string]$plan.CredentialIds.PSObject.Properties[$name].Value
                    [void](Set-OpenClawCredential -Id $credentialId -Secret $CredentialMap[$name] -Confirm:$false)
                }
                catch {
                    $replacementSucceeded = $false
                    break
                }
            }
            $recoveryChecks.Add([pscustomobject]@{
                Name = 'Credential replacement'
                Passed = $replacementSucceeded
                ExitCode = if ($replacementSucceeded) { 0 } else { -1 }
                Detail = if ($replacementSucceeded) { '' } else { 'One or more exact pending credentials could not be replaced.' }
            })
            if (-not $replacementSucceeded) {
                [void](Write-OpenClawSafeSetupRecoveryReceipt -Plan $plan -Checks $recoveryChecks.ToArray() -CredentialIds @($receipt.CredentialIds) -Status Partial -AppliedConfigHash $expectedAppliedConfigHash -StateDirectory $StateDirectory)
                return [pscustomobject]@{ Resolved = $false; Status = 'Partial'; Checks = $recoveryChecks.ToArray(); RecoveryReceiptPath = [string]$receipt.Path }
            }
            $replacementCompletionChecks = @(Get-OpenClawSafeSetupRecoveryChecks -Checks $recoveryChecks.ToArray())
            try {
                # Clearing the pending marker is itself durable. A crash after
                # the final CredWrite but before this checkpoint requires the
                # operator to re-enter the complete set instead of silently
                # accepting a potentially mixed replacement.
                [void](Write-OpenClawSafeSetupRecoveryReceipt `
                    -Plan $plan `
                    -Checks $replacementCompletionChecks `
                    -CredentialIds @($receipt.CredentialIds) `
                    -Status Partial `
                    -AppliedConfigHash $replacementCheckpointHash `
                    -StateDirectory $StateDirectory)
            }
            catch {
                $recoveryChecks.Add([pscustomobject]@{
                    Name = 'Credential replacement checkpoint'
                    Passed = $false
                    ExitCode = -1
                    Detail = 'All credential writes completed, but their completion checkpoint could not be recorded. Re-enter the complete set.'
                })
                return [pscustomobject]@{ Resolved = $false; Status = 'Partial'; Checks = $recoveryChecks.ToArray(); RecoveryReceiptPath = [string]$receipt.Path }
            }
            $recoveryChecks.Clear()
            foreach ($completionCheck in $replacementCompletionChecks) { $recoveryChecks.Add($completionCheck) }
            $replacementWasPending = $false
        }

        if ($restoreApprovedPatch) {
            $patchRestored = $false
            try {
                # The dry-run evaluates the candidate config after the exact
                # provider/ref replacements, never the drifted provider binding.
                [void](Invoke-OpenClawSafeSetupDryRun -Plan $plan -StateDirectory $StateDirectory -AllowExec -ForceInvocationRefresh)
                $patchJson = ConvertTo-OpenClawSettingsJson -Value $plan.Patch
                $patchArguments = Get-OpenClawSafeSetupPatchArguments -Plan $plan
                $patchResult = Invoke-OpenClawSettingsCommand -Arguments $patchArguments -InputText $patchJson -StateDirectory $StateDirectory -AllowFailure
                if (-not $patchResult.Succeeded) {
                    throw 'OpenClaw rejected the approved recovery patch.'
                }
                $currentConfigHash = Get-OpenClawSettingsFileHash -Path ([string]$plan.ConfigPath)
                $patchRestored = $currentConfigHash -match '^[A-Fa-f0-9]{64}$'
            }
            catch { }
            $recoveryChecks.Add([pscustomobject]@{
                Name = 'Approved patch restoration'
                Passed = $patchRestored
                ExitCode = if ($patchRestored) { 0 } else { -1 }
                Detail = if ($patchRestored) { '' } else { 'The fingerprint-bound Easy Setup patch could not be restored and fingerprinted safely.' }
            })
            if (-not $patchRestored) {
                [void](Write-OpenClawSafeSetupRecoveryReceipt -Plan $plan -Checks $recoveryChecks.ToArray() -CredentialIds @($receipt.CredentialIds) -Status Partial -AppliedConfigHash '' -StateDirectory $StateDirectory)
                return [pscustomobject]@{ Resolved = $false; Status = 'Partial'; Checks = $recoveryChecks.ToArray(); RecoveryReceiptPath = [string]$receipt.Path }
            }
            # Persist the new byte binding before any restart or postcheck so a
            # crash resumes from a known exact-patch baseline.
            [void](Write-OpenClawSafeSetupRecoveryReceipt -Plan $plan -Checks $recoveryChecks.ToArray() -CredentialIds @($receipt.CredentialIds) -Status Partial -AppliedConfigHash $currentConfigHash -StateDirectory $StateDirectory)
        }

        $checks = @($recoveryChecks.ToArray()) + @(
            Invoke-OpenClawSafeSetupPostChecks `
                -Plan $plan `
                -ExpectedConfigHash $currentConfigHash `
                -StateDirectory $StateDirectory `
                -EnsureGatewayService:$restartGateway
        )
        $finalConfigHash = ''
        try { $finalConfigHash = Get-OpenClawSettingsFileHash -Path ([string]$plan.ConfigPath) } catch { }
        $finalHashMatches = -not [string]::IsNullOrWhiteSpace($finalConfigHash) -and
            [string]::Equals($finalConfigHash, $currentConfigHash, [StringComparison]::OrdinalIgnoreCase)
        $checks += [pscustomobject]@{
            Name = 'Recovery configuration continuity'
            Passed = $finalHashMatches
            ExitCode = if ($finalHashMatches) { 0 } else { -1 }
            Detail = if ($finalHashMatches) { '' } else { 'The active configuration changed while recovery checks were running.' }
        }
        $failedChecks = @($checks | Where-Object Passed -eq $false)
        $finalStatus = if ($failedChecks.Count -eq 0) { 'Succeeded' } else { 'Partial' }
        [void](Write-OpenClawSafeSetupRecoveryReceipt -Plan $plan -Checks $checks -CredentialIds @($receipt.CredentialIds) -Status $finalStatus -AppliedConfigHash $currentConfigHash -StateDirectory $StateDirectory)
        return [pscustomobject]@{
            Resolved = $failedChecks.Count -eq 0
            Status = $finalStatus
            Checks = $checks
            RecoveryReceiptPath = [string]$receipt.Path
        }
    }
    finally {
        $transactionLock.Dispose()
    }
}

function Invoke-OpenClawSafeSetupApply {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Plan,
        [Parameter(Mandatory = $true)]
        [hashtable]$CredentialMap,
        [string]$StateDirectory
    )

    Assert-OpenClawSafeSetupPlan -Plan $Plan
    Test-OpenClawCredentialMap -Plan $Plan -CredentialMap $CredentialMap
    Assert-OpenClawSafeSetupPlanFresh -Plan $Plan -StateDirectory $StateDirectory
    [void](Invoke-OpenClawSafeSetupDryRun -Plan $Plan -StateDirectory $StateDirectory)

    if (-not $PSCmdlet.ShouldProcess('OpenClaw local configuration, Windows Credential Manager, and Gateway service', 'Apply the approved safe setup plan')) {
        return [pscustomobject]@{ Applied = $false; Succeeded = $false; Checks = @(); Fingerprint = [string]$Plan.Fingerprint }
    }

    $transactionLock = Enter-OpenClawSafeSetupTransactionLock -StateDirectory $StateDirectory
    try {
        $pendingRecovery = Get-OpenClawSafeSetupPendingRecovery -StateDirectory $StateDirectory
        if ($null -ne $pendingRecovery) {
            throw 'An unresolved safe-setup recovery receipt blocked a new apply. Review or repair the previous attempt first.'
        }
        # User confirmation may remain open while another OpenClaw process edits
        # the config. Rebind freshness under our transaction lock before the
        # resolver, receipt, or any Credential Manager entry is created.
        Assert-OpenClawSafeSetupPlanFresh -Plan $Plan -StateDirectory $StateDirectory

        $resolver = Install-OpenClawCredentialResolver -StateDirectory $StateDirectory
        if (-not [string]::Equals([IO.Path]::GetFullPath([string]$resolver.Path), [IO.Path]::GetFullPath([string]$Plan.ResolverPath), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The installed Credential Manager resolver path did not match the approved plan.'
        }

        $plannedCredentialIds = @($Plan.CredentialIds.PSObject.Properties | ForEach-Object { [string]$_.Value })
        $receiptPath = Write-OpenClawSafeSetupRecoveryReceipt -Plan $Plan -Checks @() -CredentialIds $plannedCredentialIds -Status Preparing -AppliedConfigHash '' -StateDirectory $StateDirectory
        $createdIds = New-Object System.Collections.Generic.List[string]
        $configApplied = $false
        try {
        foreach ($property in $Plan.CredentialIds.PSObject.Properties) {
            $id = [string]$property.Value
            if (Test-OpenClawCredential -Id $id) {
                throw 'A run-scoped Credential Manager target already existed. Create a new preview.'
            }
            Set-OpenClawCredential -Id $id -Secret $CredentialMap[[string]$property.Name]
            $createdIds.Add($id)
        }

        [void](Invoke-OpenClawSafeSetupDryRun -Plan $Plan -StateDirectory $StateDirectory -AllowExec -ForceInvocationRefresh)
        Assert-OpenClawSafeSetupPlanFresh -Plan $Plan -StateDirectory $StateDirectory
        $patchJson = ConvertTo-OpenClawSettingsJson -Value $Plan.Patch
        $patchArguments = Get-OpenClawSafeSetupPatchArguments -Plan $Plan
        $applyResult = Invoke-OpenClawSettingsCommand -Arguments $patchArguments -InputText $patchJson -StateDirectory $StateDirectory -AllowFailure
        if (-not $applyResult.Succeeded) {
            throw 'OpenClaw rejected the approved configuration patch without changing the active configuration.'
        }
        $configApplied = $true
    }
        catch {
            if (-not $configApplied) {
                $baseStillCurrent = $false
                try {
                    $currentConfigHash = Get-OpenClawSettingsFileHash -Path ([string]$Plan.ConfigPath)
                    $baseStillCurrent = [string]::Equals($currentConfigHash, [string]$Plan.BaseConfigHash, [StringComparison]::OrdinalIgnoreCase)
                }
                catch { }
                if ($baseStillCurrent) {
                    $cleanupSucceeded = $true
                    foreach ($id in $createdIds) {
                        try { [void](Remove-OpenClawCredential -Id $id) } catch { $cleanupSucceeded = $false }
                    }
                    if ($cleanupSucceeded) {
                        try {
                            [void](Write-OpenClawSafeSetupRecoveryReceipt -Plan $Plan -Checks @([pscustomobject]@{
                                Name = 'Pre-patch cleanup'; Passed = $true; ExitCode = 0; Detail = ''
                            }) -CredentialIds $plannedCredentialIds -Status RolledBack -AppliedConfigHash '' -StateDirectory $StateDirectory)
                        }
                        catch { }
                    }
                }
            }
            throw
        }

    $checks = New-Object System.Collections.Generic.List[object]
    $appliedConfigHash = ''
    try {
        $appliedConfigHash = Get-OpenClawSettingsFileHash -Path ([string]$Plan.ConfigPath)
    }
    catch {
        $checks.Add([pscustomobject]@{
            Name = 'Applied configuration fingerprint'
            Passed = $false
            ExitCode = -1
            Detail = 'The applied configuration file could not be fingerprinted safely.'
        })
    }
    try {
        [void](Write-OpenClawSafeSetupRecoveryReceipt `
            -Plan $Plan `
            -Checks $checks.ToArray() `
            -CredentialIds $plannedCredentialIds `
            -Status AppliedPendingChecks `
            -AppliedConfigHash $appliedConfigHash `
            -StateDirectory $StateDirectory)
    }
    catch {
        $checks.Add([pscustomobject]@{
            Name = 'Recovery checkpoint'
            Passed = $false
            ExitCode = -1
            Detail = 'The recovery receipt could not record the applied configuration before post-apply checks.'
        })
    }

    foreach ($postCheck in @(Invoke-OpenClawSafeSetupPostChecks -Plan $Plan -ExpectedConfigHash $appliedConfigHash -StateDirectory $StateDirectory -EnsureGatewayService)) {
        $checks.Add($postCheck)
    }

    $finalAppliedConfigHash = ''
    try { $finalAppliedConfigHash = Get-OpenClawSettingsFileHash -Path ([string]$Plan.ConfigPath) } catch { }
    $appliedHashStayedCurrent = -not [string]::IsNullOrWhiteSpace($appliedConfigHash) -and
        [string]::Equals($finalAppliedConfigHash, $appliedConfigHash, [StringComparison]::OrdinalIgnoreCase)
    $checks.Add([pscustomobject]@{
        Name = 'Post-check configuration continuity'
        Passed = $appliedHashStayedCurrent
        ExitCode = if ($appliedHashStayedCurrent) { 0 } else { -1 }
        Detail = if ($appliedHashStayedCurrent) { '' } else { 'The active configuration changed while post-apply checks were running.' }
    })

    $failedChecksBeforeReceipt = @($checks | Where-Object Passed -eq $false)
    try {
        [void](Write-OpenClawSafeSetupRecoveryReceipt `
            -Plan $Plan `
            -Checks $checks.ToArray() `
            -CredentialIds $plannedCredentialIds `
            -Status $(if ($failedChecksBeforeReceipt.Count -eq 0) { 'Succeeded' } else { 'Partial' }) `
            -AppliedConfigHash $appliedConfigHash `
            -StateDirectory $StateDirectory)
    }
    catch {
        $checks.Add([pscustomobject]@{
            Name = 'Recovery receipt'
            Passed = $false
            ExitCode = -1
            Detail = 'The private recovery receipt could not be written. Preserve the returned credential ids.'
        })
    }

    $failedChecks = @($checks | Where-Object Passed -eq $false)
    return [pscustomobject]@{
        Applied = $true
        Succeeded = $failedChecks.Count -eq 0
        Checks = $checks.ToArray()
        Fingerprint = [string]$Plan.Fingerprint
        CredentialCount = $createdIds.Count
        CredentialIds = $createdIds.ToArray()
        RecoveryReceiptPath = $receiptPath
        PlaintextSecretsWrittenToConfig = $false
    }
    }
    finally {
        if ($null -ne $transactionLock) {
            $transactionLock.Dispose()
        }
    }
}

Export-ModuleMember -Function @(
    'Get-OpenClawSafeSetupCatalog',
    'Get-OpenClawSafeSetupLiveState',
    'New-OpenClawSafeSetupPlan',
    'Get-OpenClawSafeSetupPlanFingerprint',
    'Get-OpenClawSafeSetupPreview',
    'Invoke-OpenClawSafeSetupDryRun',
    'New-OpenClawGatewayToken',
    'Get-OpenClawSafeSetupPendingRecovery',
    'Invoke-OpenClawSafeSetupRecoveryVerification',
    'Invoke-OpenClawSafeSetupApply'
)
