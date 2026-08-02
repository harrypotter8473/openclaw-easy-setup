Set-StrictMode -Version Latest

$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:DefaultSourceConfigPath = Join-Path $script:ProjectRoot 'config\openclaw-source.json'

function ConvertTo-OpenClawVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $match = [regex]::Match($Text, '(?<!\d)(\d+)\.(\d+)\.(\d+)(?:[-+][0-9A-Za-z.-]+)?')
    if (-not $match.Success) {
        return $null
    }

    try {
        return [version]("{0}.{1}.{2}" -f $match.Groups[1].Value, $match.Groups[2].Value, $match.Groups[3].Value)
    }
    catch {
        return $null
    }
}

function Get-OpenClawSourceConfig {
    [CmdletBinding()]
    param(
        [string]$Path = $script:DefaultSourceConfigPath
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Source configuration was not found: $Path"
    }

    $config = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($config.schemaVersion -ne 1) {
        throw "Unsupported source configuration schema: $($config.schemaVersion)"
    }

    if ([string]::IsNullOrWhiteSpace([string]$config.installer.uri)) {
        throw 'The source configuration does not define installer.uri.'
    }

    if ([string]$config.openClaw.commitSha -notmatch '^[A-Fa-f0-9]{40}$') {
        throw 'The source configuration does not contain a pinned 40-character OpenClaw commit SHA.'
    }

    if ([string]$config.openClaw.version -notmatch '^\d{4}\.\d+\.\d+$') {
        throw 'The source configuration does not contain an exact OpenClaw version.'
    }

    if ([string]$config.openClaw.releaseTag -ne ("v{0}" -f $config.openClaw.version)) {
        throw 'The pinned OpenClaw release tag does not match the pinned package version.'
    }

    $expectedInstallerUri = "https://raw.githubusercontent.com/openclaw/openclaw/{0}/scripts/install.ps1" -f $config.openClaw.commitSha
    if ([string]$config.installer.uri -ne $expectedInstallerUri) {
        throw 'The installer URI is not pinned to the configured OpenClaw commit and script path.'
    }

    if ([string]$config.installer.sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'The source configuration does not contain a pinned installer SHA-256.'
    }

    if ([string]$config.installer.installMethod -ne 'npm') {
        throw 'Only the pinned npm installation method is supported by this MVP.'
    }

    if ([int64]$config.installer.maxBytes -le 0) {
        throw 'The source configuration does not contain a valid installer size limit.'
    }

    if ([string]$config.node.winget.id -ne 'OpenJS.NodeJS' -or
        [string]$config.node.winget.source -ne 'winget' -or
        [string]$config.node.winget.version -notmatch '^26\.\d+\.\d+$' -or
        [string]$config.node.winget.installerSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'The source configuration does not contain a valid pinned Node.js WinGet package.'
    }

    if (@($config.allowedDownloadHosts).Count -eq 0) {
        throw 'The source configuration does not define any allowed download hosts.'
    }

    return $config
}

function Test-OpenClawUriAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [uri]$Uri,

        [Parameter(Mandatory = $true)]
        [string[]]$AllowedHosts
    )

    if ($Uri.Scheme -ne 'https' -or -not $Uri.IsDefaultPort) {
        return $false
    }

    if (-not [string]::IsNullOrWhiteSpace($Uri.UserInfo) -or
        -not [string]::IsNullOrWhiteSpace($Uri.Query) -or
        -not [string]::IsNullOrWhiteSpace($Uri.Fragment)) {
        return $false
    }

    $parsedIpAddress = $null
    if ([Net.IPAddress]::TryParse($Uri.DnsSafeHost, [ref]$parsedIpAddress)) {
        return $false
    }

    $normalizedHost = $Uri.DnsSafeHost.ToLowerInvariant()
    foreach ($hostName in $AllowedHosts) {
        if ($normalizedHost -eq ([string]$hostName).ToLowerInvariant()) {
            return $true
        }
    }

    return $false
}

function Test-OpenClawNodeVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [version]$Version
    )

    $supported = $false
    $recommended = $false
    $reason = 'This Node.js release line is not listed in the current OpenClaw requirements.'

    switch ($Version.Major) {
        22 {
            $supported = $Version -ge [version]'22.22.3'
            $reason = if ($supported) { 'Supported Node.js 22 release.' } else { 'Node.js 22.22.3 or newer is required.' }
        }
        24 {
            $supported = $Version -ge [version]'24.15.0'
            $recommended = $supported
            $reason = if ($supported) { 'Recommended Node.js 24 release.' } else { 'Node.js 24.15.0 or newer is required.' }
        }
        25 {
            $supported = $Version -ge [version]'25.9.0'
            $reason = if ($supported) { 'Supported Node.js 25 release.' } else { 'Node.js 25.9.0 or newer is required.' }
        }
        26 {
            $supported = $true
            $recommended = $true
            $reason = 'Recommended Node.js 26 release.'
        }
    }

    [pscustomobject]@{
        Version = $Version
        Supported = $supported
        Recommended = $recommended
        Reason = $reason
    }
}

function Test-OpenClawIsWindows {
    [CmdletBinding()]
    param()

    return [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

function Test-OpenClawIsAdministrator {
    [CmdletBinding()]
    param()

    if (-not (Test-OpenClawIsWindows)) {
        return $false
    }

    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Get-OpenClawCommandSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string[]]$Arguments = @('--version')
    )

    $command = Get-Command -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        return [pscustomobject]@{
            Found = $false
            Path = $null
            RawVersion = $null
            Version = $null
            ExitCode = $null
        }
    }

    try {
        $raw = (& $command.Source @Arguments 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE
        return [pscustomobject]@{
            Found = $true
            Path = $command.Source
            RawVersion = $raw
            Version = ConvertTo-OpenClawVersion -Text $raw
            ExitCode = $exitCode
        }
    }
    catch {
        return [pscustomobject]@{
            Found = $true
            Path = $command.Source
            RawVersion = $_.Exception.Message
            Version = $null
            ExitCode = 1
        }
    }
}

function New-OpenClawReadinessCheck {
    param(
        [string]$Id,
        [ValidateSet('Pass', 'Warn', 'Fail', 'Info')]
        [string]$Status,
        [string]$Current,
        [string]$Required,
        [string]$Guidance
    )

    [pscustomobject]@{
        Id = $Id
        Status = $Status
        Current = $Current
        Required = $Required
        Guidance = $Guidance
    }
}

function Get-OpenClawArchitecture {
    try {
        return [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    }
    catch {
        if (-not [string]::IsNullOrWhiteSpace($env:PROCESSOR_ARCHITECTURE)) {
            return $env:PROCESSOR_ARCHITECTURE
        }
        return 'Unknown'
    }
}

function Get-OpenClawFreeSpaceGb {
    try {
        $drive = New-Object System.IO.DriveInfo($env:SystemDrive)
        return [math]::Round($drive.AvailableFreeSpace / 1GB, 1)
    }
    catch {
        return $null
    }
}

function Get-OpenClawReadiness {
    [CmdletBinding()]
    param()

    $checks = New-Object System.Collections.Generic.List[object]
    $isWindows = Test-OpenClawIsWindows
    $checks.Add((New-OpenClawReadinessCheck -Id 'platform' -Status $(if ($isWindows) { 'Pass' } else { 'Fail' }) -Current ([Environment]::OSVersion.VersionString) -Required 'Windows 10/11' -Guidance 'This MVP currently supports Windows only.'))

    $powerShellVersion = $PSVersionTable.PSVersion
    $powerShellSupported = $powerShellVersion -ge [version]'5.1.0'
    $checks.Add((New-OpenClawReadinessCheck -Id 'powershell' -Status $(if ($powerShellSupported) { 'Pass' } else { 'Fail' }) -Current $powerShellVersion.ToString() -Required '5.1 or newer' -Guidance 'Install Windows PowerShell 5.1 or PowerShell 7.'))

    $architecture = Get-OpenClawArchitecture
    $architectureSupported = @('X64', 'Arm64', 'AMD64') -contains $architecture
    $checks.Add((New-OpenClawReadinessCheck -Id 'architecture' -Status $(if ($architectureSupported) { 'Pass' } else { 'Warn' }) -Current $architecture -Required 'x64 or Arm64' -Guidance 'Confirm that the official OpenClaw installer supports this architecture.'))

    $isAdministrator = Test-OpenClawIsAdministrator
    $checks.Add((New-OpenClawReadinessCheck -Id 'administrator' -Status 'Info' -Current $(if ($isAdministrator) { 'Elevated' } else { 'Standard user' }) -Required 'Standard user preferred' -Guidance 'The helper does not request elevation unless a future step explicitly requires it.'))

    $freeSpace = Get-OpenClawFreeSpaceGb
    if ($null -eq $freeSpace) {
        $checks.Add((New-OpenClawReadinessCheck -Id 'disk' -Status 'Warn' -Current 'Unknown' -Required '2 GB free recommended' -Guidance 'Check available space on the Windows system drive.'))
    }
    else {
        $checks.Add((New-OpenClawReadinessCheck -Id 'disk' -Status $(if ($freeSpace -ge 2) { 'Pass' } else { 'Warn' }) -Current ("$freeSpace GB free") -Required '2 GB free recommended' -Guidance 'Free some disk space before installation.'))
    }

    try {
        $sourceConfig = Get-OpenClawSourceConfig
        $installerUri = [uri]$sourceConfig.installer.uri
        $sourceAllowed = Test-OpenClawUriAllowed -Uri $installerUri -AllowedHosts @($sourceConfig.allowedDownloadHosts)
        $checks.Add((New-OpenClawReadinessCheck -Id 'installerSource' -Status $(if ($sourceAllowed) { 'Pass' } else { 'Fail' }) -Current ("{0} @ {1}" -f $sourceConfig.openClaw.releaseTag, $sourceConfig.openClaw.commitSha) -Required 'Pinned release, commit, URI, and SHA-256' -Guidance 'Review config/openclaw-source.json before downloading anything.'))
    }
    catch {
        $checks.Add((New-OpenClawReadinessCheck -Id 'installerSource' -Status 'Fail' -Current $_.Exception.Message -Required 'Valid source configuration' -Guidance 'Repair config/openclaw-source.json.'))
    }

    $winget = Get-OpenClawCommandSnapshot -Name 'winget'
    if ($winget.Found -and $null -ne $winget.Version) {
        $checks.Add((New-OpenClawReadinessCheck -Id 'winget' -Status 'Pass' -Current $winget.Version.ToString() -Required 'WinGet available for pinned Node.js provisioning' -Guidance 'WinGet will verify the exact package manifest and installer hash.'))
    }
    else {
        $checks.Add((New-OpenClawReadinessCheck -Id 'winget' -Status 'Fail' -Current $(if ($winget.Found) { $winget.RawVersion } else { 'Not found' }) -Required 'WinGet available for pinned Node.js provisioning' -Guidance 'Install or repair Microsoft App Installer before automatic prerequisite setup.'))
    }

    $node = Get-OpenClawCommandSnapshot -Name 'node'
    if (-not $node.Found) {
        $checks.Add((New-OpenClawReadinessCheck -Id 'node' -Status $(if ($winget.Found) { 'Warn' } else { 'Fail' }) -Current 'Not found' -Required 'Node 26 recommended; 22.22.3+, 24.15+, or 25.9+ supported' -Guidance 'The Apply flow can install pinned Node.js 26.5.1 through WinGet.'))
    }
    elseif ($null -eq $node.Version) {
        $checks.Add((New-OpenClawReadinessCheck -Id 'node' -Status $(if ($winget.Found) { 'Warn' } else { 'Fail' }) -Current $node.RawVersion -Required 'A parseable supported Node.js version' -Guidance 'The Apply flow can replace this with pinned Node.js 26.5.1 through WinGet.'))
    }
    else {
        $nodeSupport = Test-OpenClawNodeVersion -Version $node.Version
        $checks.Add((New-OpenClawReadinessCheck -Id 'node' -Status $(if ($nodeSupport.Supported) { 'Pass' } elseif ($winget.Found) { 'Warn' } else { 'Fail' }) -Current $node.Version.ToString() -Required 'Node 26 recommended; 22.22.3+, 24.15+, or 25.9+ supported' -Guidance $(if ($nodeSupport.Supported) { $nodeSupport.Reason } else { 'The Apply flow can replace this with pinned Node.js 26.5.1 through WinGet.' })))
    }

    $npm = Get-OpenClawCommandSnapshot -Name 'npm'
    if ($npm.Found -and $null -ne $npm.Version) {
        $checks.Add((New-OpenClawReadinessCheck -Id 'npm' -Status 'Pass' -Current $npm.Version.ToString() -Required 'npm available with Node.js' -Guidance 'npm is required by the pinned installation method.'))
    }
    else {
        $checks.Add((New-OpenClawReadinessCheck -Id 'npm' -Status 'Fail' -Current $(if ($npm.Found) { $npm.RawVersion } else { 'Not found' }) -Required 'npm available with Node.js' -Guidance 'Repair the Node.js installation so npm is available on PATH.'))
    }

    $openClaw = Get-OpenClawCommandSnapshot -Name 'openclaw'
    if ($openClaw.Found) {
        $checks.Add((New-OpenClawReadinessCheck -Id 'openclaw' -Status 'Pass' -Current $(if ($null -ne $openClaw.Version) { $openClaw.Version.ToString() } else { $openClaw.RawVersion }) -Required 'Optional before installation' -Guidance 'An existing installation will be preserved and handed to the official updater.'))
    }
    else {
        $checks.Add((New-OpenClawReadinessCheck -Id 'openclaw' -Status 'Info' -Current 'Not installed' -Required 'Optional before installation' -Guidance 'Use the plan and install actions when ready.'))
    }

    return $checks.ToArray()
}

function Get-OpenClawMessages {
    [CmdletBinding()]
    param(
        [ValidateSet('ko-KR')]
        [string]$Language = 'ko-KR'
    )

    $path = Join-Path $script:ProjectRoot ("locales\{0}.json" -f $Language)
    return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-OpenClawMessageValue {
    param(
        [object]$Messages,
        [string]$Path,
        [string]$Fallback
    )

    $current = $Messages
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) {
            return $Fallback
        }
        $property = $current.PSObject.Properties[$segment]
        if ($null -eq $property) {
            return $Fallback
        }
        $current = $property.Value
    }

    return [string]$current
}

function Show-OpenClawReadiness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [object[]]$Check,

        [ValidateSet('ko-KR')]
        [string]$Language = 'ko-KR'
    )

    begin {
        $messages = Get-OpenClawMessages -Language $Language
        Write-Host ''
        Write-Host $messages.title -ForegroundColor Cyan
        Write-Host $messages.diagnoseHeader
        Write-Host $messages.diagnoseReadOnly -ForegroundColor DarkGray
        Write-Host ''
    }
    process {
        foreach ($item in $Check) {
            $name = Get-OpenClawMessageValue -Messages $messages -Path ("checks.{0}.name" -f $item.Id) -Fallback $item.Id
            $statusLabel = Get-OpenClawMessageValue -Messages $messages -Path ("status.{0}" -f $item.Status) -Fallback $item.Status
            $color = switch ($item.Status) {
                'Pass' { 'Green' }
                'Warn' { 'Yellow' }
                'Fail' { 'Red' }
                default { 'Gray' }
            }
            Write-Host ("[{0}] {1}: {2}" -f $statusLabel, $name, $item.Current) -ForegroundColor $color
            if ($item.Status -in @('Warn', 'Fail')) {
                Write-Host ("  -> {0}" -f $item.Guidance) -ForegroundColor DarkGray
            }
        }
    }
}

function Get-OpenClawInstallPlan {
    [CmdletBinding()]
    param()

    $config = Get-OpenClawSourceConfig
    @(
        [pscustomobject]@{ Order = 1; Id = 'diagnose'; ChangesPC = $false; RequiresAdmin = $false; Title = 'Read-only environment diagnosis'; Detail = 'Check Windows, PowerShell, architecture, disk, WinGet, Node.js, npm, and existing OpenClaw.' }
        [pscustomobject]@{ Order = 2; Id = 'node'; ChangesPC = $true; RequiresAdmin = 'MayPrompt'; Title = 'Provision the pinned Node.js prerequisite when needed'; Detail = ("WinGet {0} {1}; installer SHA-256 recorded as {2}." -f $config.node.winget.id, $config.node.winget.version, $config.node.winget.installerSha256) }
        [pscustomobject]@{ Order = 3; Id = 'download'; ChangesPC = $true; RequiresAdmin = $false; Title = 'Download the pinned official installer to a unique temporary file'; Detail = ("Release {0}; commit {1}; allow only HTTPS redirects on: {2}" -f $config.openClaw.releaseTag, $config.openClaw.commitSha, (@($config.allowedDownloadHosts) -join ', ')) }
        [pscustomobject]@{ Order = 4; Id = 'integrity'; ChangesPC = $false; RequiresAdmin = $false; Title = 'Verify size, PowerShell syntax, and pinned SHA-256'; Detail = ("Expected SHA-256: {0}" -f $config.installer.sha256) }
        [pscustomobject]@{ Order = 5; Id = 'dryRun'; ChangesPC = $false; RequiresAdmin = $false; Title = 'Run the pinned installer dry-run'; Detail = ("Use fixed method {0} and package version {1}." -f $config.installer.installMethod, $config.openClaw.version) }
        [pscustomobject]@{ Order = 6; Id = 'install'; ChangesPC = $true; RequiresAdmin = $false; Title = 'Run the pinned official PowerShell installer'; Detail = 'Run without onboarding first, in a sanitized child environment, only after confirmation.' }
        [pscustomobject]@{ Order = 7; Id = 'onboard'; ChangesPC = $true; RequiresAdmin = $false; Title = 'Start official OpenClaw onboarding'; Detail = 'Run with daemon installation and SecretRef input mode.' }
        [pscustomobject]@{ Order = 8; Id = 'verify'; ChangesPC = $false; RequiresAdmin = $false; Title = 'Verify health, secrets, and security'; Detail = 'Run version, doctor, secrets audit, security audit --deep, health, and authenticated Gateway status.' }
    )
}

function Show-OpenClawInstallPlan {
    [CmdletBinding()]
    param(
        [object[]]$Plan = $(Get-OpenClawInstallPlan),
        [ValidateSet('ko-KR')]
        [string]$Language = 'ko-KR'
    )

    $messages = Get-OpenClawMessages -Language $Language
    Write-Host ''
    Write-Host $messages.planHeader -ForegroundColor Cyan
    foreach ($step in $Plan) {
        $mutation = if ($step.ChangesPC) { 'CHANGE' } else { 'READ ONLY' }
        Write-Host ("{0}. [{1}] {2}" -f $step.Order, $mutation, $step.Title)
        Write-Host ("   {0}" -f $step.Detail) -ForegroundColor DarkGray
    }
}

function Save-OpenClawInstaller {
    [CmdletBinding()]
    param(
        [string]$DestinationPath,
        [object]$SourceConfig = $(Get-OpenClawSourceConfig)
    )

    $initialUri = [uri]$SourceConfig.installer.uri
    $allowedHosts = [string[]]@($SourceConfig.allowedDownloadHosts)
    $maximumBytes = [int64]$SourceConfig.installer.maxBytes
    if (-not (Test-OpenClawUriAllowed -Uri $initialUri -AllowedHosts $allowedHosts)) {
        throw "Installer URI is not allowed: $initialUri"
    }

    if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
        $DestinationPath = Join-Path ([IO.Path]::GetTempPath()) (([IO.Path]::GetRandomFileName()) + '.ps1')
    }
    elseif (Test-Path -LiteralPath $DestinationPath) {
        throw "Destination already exists: $DestinationPath"
    }

    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(60)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('OpenClaw-Easy-Setup/0.1')
    $currentUri = $initialUri
    $response = $null

    try {
        for ($redirectCount = 0; $redirectCount -le 5; $redirectCount++) {
            if (-not (Test-OpenClawUriAllowed -Uri $currentUri -AllowedHosts $allowedHosts)) {
                throw "Download redirect left the allowlist: $currentUri"
            }

            $response = $client.GetAsync($currentUri).GetAwaiter().GetResult()
            $statusCode = [int]$response.StatusCode
            if ($statusCode -in @(301, 302, 303, 307, 308)) {
                $location = $response.Headers.Location
                if ($null -eq $location) {
                    throw "Redirect response did not include a Location header: $currentUri"
                }
                $nextUri = if ($location.IsAbsoluteUri) { $location } else { New-Object Uri($currentUri, $location) }
                $response.Dispose()
                $response = $null
                $currentUri = $nextUri
                continue
            }

            if (-not $response.IsSuccessStatusCode) {
                throw "Installer download failed with HTTP $statusCode from $currentUri"
            }

            $contentType = $response.Content.Headers.ContentType
            if ($null -ne $contentType -and $contentType.MediaType -notin @('text/plain', 'application/octet-stream')) {
                throw "Installer response used an unexpected content type: $($contentType.MediaType)"
            }

            $declaredLength = $response.Content.Headers.ContentLength
            if ($null -ne $declaredLength -and ($declaredLength -le 0 -or $declaredLength -gt $maximumBytes)) {
                throw "Installer response size was outside the allowed range: $declaredLength bytes"
            }

            $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $outputStream = [IO.File]::Open($DestinationPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $buffer = New-Object byte[] 8192
                $totalBytes = [int64]0
                while (($bytesRead = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $totalBytes += $bytesRead
                    if ($totalBytes -gt $maximumBytes) {
                        throw "Installer download exceeded the $maximumBytes byte limit."
                    }
                    $outputStream.Write($buffer, 0, $bytesRead)
                }
            }
            finally {
                $outputStream.Dispose()
                $inputStream.Dispose()
            }

            if ($totalBytes -le 0) {
                throw 'Installer download was empty.'
            }

            $hash = (Get-FileHash -LiteralPath $DestinationPath -Algorithm SHA256).Hash.ToUpperInvariant()
            if ($hash -ne ([string]$SourceConfig.installer.sha256).ToUpperInvariant()) {
                throw "Installer SHA-256 mismatch. Expected $($SourceConfig.installer.sha256) but received $hash."
            }

            $tokens = $null
            $parseErrors = $null
            [void][Management.Automation.Language.Parser]::ParseFile($DestinationPath, [ref]$tokens, [ref]$parseErrors)
            if (@($parseErrors).Count -gt 0) {
                throw "Downloaded installer did not parse as PowerShell: $($parseErrors[0].Message)"
            }

            $signature = Get-AuthenticodeSignature -LiteralPath $DestinationPath
            return [pscustomobject]@{
                Path = $DestinationPath
                SourceUri = $currentUri.AbsoluteUri
                Sha256 = $hash
                SignatureStatus = $signature.Status.ToString()
            }
        }

        throw 'Installer download exceeded the maximum redirect count.'
    }
    catch {
        if (Test-Path -LiteralPath $DestinationPath) {
            Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
        }
        throw
    }
    finally {
        if ($null -ne $response) {
            $response.Dispose()
        }
        $client.Dispose()
        $handler.Dispose()
    }
}

function Resolve-OpenClawCommand {
    [CmdletBinding()]
    param()

    $command = Get-Command -Name 'openclaw' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) {
        return $command.Source
    }

    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        $npmCommand = Join-Path $env:APPDATA 'npm\openclaw.cmd'
        if (Test-Path -LiteralPath $npmCommand -PathType Leaf) {
            return $npmCommand
        }
    }

    return $null
}

function Update-OpenClawProcessPath {
    [CmdletBinding()]
    param()

    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $segments = @($env:Path, $machinePath, $userPath) -join ';'
    $env:Path = @($segments.Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique) -join ';'
}

function Start-OpenClawOnboarding {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param()

    Update-OpenClawProcessPath
    $openClawCommand = Resolve-OpenClawCommand
    if ([string]::IsNullOrWhiteSpace($openClawCommand)) {
        throw 'OpenClaw was not found on PATH. Open a new PowerShell window and run Configure again.'
    }

    if ($PSCmdlet.ShouldProcess('OpenClaw user configuration and Scheduled Task', 'Run official onboarding')) {
        & $openClawCommand onboard --install-daemon --secret-input-mode ref
        if ($LASTEXITCODE -ne 0) {
            throw "OpenClaw onboarding failed with exit code $LASTEXITCODE."
        }
    }
}

function Invoke-OpenClawPinnedInstallerFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallerPath,

        [Parameter(Mandatory = $true)]
        [object]$SourceConfig,

        [switch]$DryRun
    )

    $processEnvironment = [Environment]::GetEnvironmentVariables('Process')
    $environmentNames = @(
        @($processEnvironment.Keys | Where-Object { ([string]$_).StartsWith('OPENCLAW_', [StringComparison]::OrdinalIgnoreCase) })
        'NODE_OPTIONS'
        'NPM_CONFIG_USERCONFIG'
        'NPM_CONFIG_SCRIPT_SHELL'
        'NPM_CONFIG_REGISTRY'
    ) | Select-Object -Unique
    $savedEnvironment = @{}

    foreach ($name in $environmentNames) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }

    try {
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_REGISTRY', 'https://registry.npmjs.org/', 'Process')
        $hostPath = (Get-Process -Id $PID).Path
        $arguments = @(
            '-NoLogo',
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $InstallerPath,
            '-NoOnboard',
            '-InstallMethod', [string]$SourceConfig.installer.installMethod,
            '-Tag', [string]$SourceConfig.openClaw.version
        )
        if ($DryRun) {
            $arguments += '-DryRun'
        }

        & $hostPath @arguments
        return $LASTEXITCODE
    }
    finally {
        foreach ($name in $environmentNames) {
            [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
        }
    }
}

function Install-OpenClawNodePrerequisite {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param()

    $sourceConfig = Get-OpenClawSourceConfig
    $targetNodeVersion = [version]$sourceConfig.node.winget.version
    $currentNode = Get-OpenClawCommandSnapshot -Name 'node'
    if ($currentNode.Found -and $null -ne $currentNode.Version) {
        $support = Test-OpenClawNodeVersion -Version $currentNode.Version
        if ($support.Supported) {
            Write-Host "Supported Node.js $($currentNode.Version) is already available."
            return
        }
    }

    $winget = Get-OpenClawCommandSnapshot -Name 'winget'
    if (-not $winget.Found) {
        throw 'WinGet was not found. Install or repair Microsoft App Installer before automatic Node.js provisioning.'
    }

    $packageTarget = "{0} {1}" -f $sourceConfig.node.winget.id, $sourceConfig.node.winget.version
    if (-not $PSCmdlet.ShouldProcess($packageTarget, 'Install the exact Node.js package from the WinGet source')) {
        return
    }

    $arguments = @(
        'install',
        '--id', [string]$sourceConfig.node.winget.id,
        '--exact',
        '--source', [string]$sourceConfig.node.winget.source,
        '--version', [string]$sourceConfig.node.winget.version,
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    )
    & $winget.Path @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "WinGet failed to install pinned Node.js with exit code $LASTEXITCODE."
    }

    Update-OpenClawProcessPath
    $installedNode = Get-OpenClawCommandSnapshot -Name 'node'
    if (-not $installedNode.Found -or $null -eq $installedNode.Version -or $installedNode.Version -ne $targetNodeVersion) {
        throw "Node.js provisioning did not produce pinned version $targetNodeVersion."
    }

    $nodeSignature = Get-AuthenticodeSignature -LiteralPath $installedNode.Path
    if ($nodeSignature.Status -ne 'Valid') {
        throw "Pinned Node.js executable did not have a valid Authenticode signature: $($nodeSignature.Status)"
    }

    $npm = Get-OpenClawCommandSnapshot -Name 'npm'
    if (-not $npm.Found -or $null -eq $npm.Version) {
        throw 'Pinned Node.js was installed, but npm was not available.'
    }
}

function Install-OpenClawOfficial {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [switch]$KeepInstaller,
        [switch]$SkipOnboarding
    )

    if (-not (Test-OpenClawIsWindows)) {
        throw 'This installer MVP supports Windows only.'
    }

    $sourceConfig = Get-OpenClawSourceConfig
    $targetVersion = [version]$sourceConfig.openClaw.version
    $node = Get-OpenClawCommandSnapshot -Name 'node'

    if ($WhatIfPreference) {
        $nodeRequiresProvisioning = -not $node.Found -or $null -eq $node.Version
        if (-not $nodeRequiresProvisioning) {
            $nodeRequiresProvisioning = -not (Test-OpenClawNodeVersion -Version $node.Version).Supported
        }
        if ($nodeRequiresProvisioning) {
            [void]$PSCmdlet.ShouldProcess(("{0} {1}" -f $sourceConfig.node.winget.id, $sourceConfig.node.winget.version), 'Install the exact Node.js package from the WinGet source')
        }
        [void]$PSCmdlet.ShouldProcess('This Windows user account', ("Install pinned OpenClaw {0}" -f $targetVersion))
        return
    }

    $nodeRequiresProvisioning = -not $node.Found -or $null -eq $node.Version
    if (-not $nodeRequiresProvisioning) {
        $nodeRequiresProvisioning = -not (Test-OpenClawNodeVersion -Version $node.Version).Supported
    }
    if ($nodeRequiresProvisioning) {
        Install-OpenClawNodePrerequisite
        $node = Get-OpenClawCommandSnapshot -Name 'node'
    }
    if (-not $node.Found -or $null -eq $node.Version -or -not (Test-OpenClawNodeVersion -Version $node.Version).Supported) {
        throw 'A supported Node.js installation is required before OpenClaw installation.'
    }

    $npm = Get-OpenClawCommandSnapshot -Name 'npm'
    if (-not $npm.Found -or $null -eq $npm.Version) {
        throw 'npm was not found or did not return a valid version.'
    }

    $existing = Get-OpenClawCommandSnapshot -Name 'openclaw'
    if ($existing.Found) {
        if ($null -eq $existing.Version) {
            throw 'The existing OpenClaw version could not be determined. Refusing to replace it automatically.'
        }
        if ($existing.Version -gt $targetVersion) {
            throw "OpenClaw $($existing.Version) is newer than pinned target $targetVersion. Automatic downgrade is blocked."
        }
        if ($existing.Version -eq $targetVersion) {
            Write-Host "Pinned OpenClaw $targetVersion is already installed."
            if (-not $SkipOnboarding) {
                Start-OpenClawOnboarding
            }
            return
        }
    }

    if (-not $PSCmdlet.ShouldProcess('This Windows user account', ("Download pinned OpenClaw {0} installer" -f $targetVersion))) {
        return
    }

    $artifact = Save-OpenClawInstaller -SourceConfig $sourceConfig
    try {
        Write-Host ("Installer source: {0}" -f $artifact.SourceUri)
        Write-Host ("Installer SHA-256: {0}" -f $artifact.Sha256)
        Write-Host ("Authenticode status: {0}" -f $artifact.SignatureStatus)

        $dryRunExitCode = Invoke-OpenClawPinnedInstallerFile -InstallerPath $artifact.Path -SourceConfig $sourceConfig -DryRun
        if ($dryRunExitCode -ne 0) {
            throw "The pinned OpenClaw installer dry-run failed with exit code $dryRunExitCode."
        }

        if ($PSCmdlet.ShouldProcess($artifact.Path, ("Install pinned OpenClaw {0}" -f $targetVersion))) {
            $installExitCode = Invoke-OpenClawPinnedInstallerFile -InstallerPath $artifact.Path -SourceConfig $sourceConfig
            if ($installExitCode -ne 0) {
                throw "The pinned OpenClaw installer failed with exit code $installExitCode."
            }

            Update-OpenClawProcessPath
            $installed = Get-OpenClawCommandSnapshot -Name 'openclaw'
            if (-not $installed.Found -or $null -eq $installed.Version -or $installed.Version -ne $targetVersion) {
                throw "Installed OpenClaw version did not match pinned target $targetVersion."
            }

            if (-not $SkipOnboarding) {
                Start-OpenClawOnboarding -Confirm:$false
            }
        }
    }
    finally {
        if (-not $KeepInstaller -and (Test-Path -LiteralPath $artifact.Path)) {
            Remove-Item -LiteralPath $artifact.Path -Force
        }
    }
}

function Invoke-OpenClawVerification {
    [CmdletBinding()]
    param()

    Update-OpenClawProcessPath
    $openClawCommand = Resolve-OpenClawCommand
    if ([string]::IsNullOrWhiteSpace($openClawCommand)) {
        throw 'OpenClaw was not found on PATH.'
    }

    $steps = @(
        [pscustomobject]@{ Name = 'Version'; Arguments = @('--version') }
        [pscustomobject]@{ Name = 'Doctor'; Arguments = @('doctor') }
        [pscustomobject]@{ Name = 'Secrets audit'; Arguments = @('secrets', 'audit', '--check') }
        [pscustomobject]@{ Name = 'Security audit'; Arguments = @('security', 'audit', '--deep') }
        [pscustomobject]@{ Name = 'Health'; Arguments = @('health') }
        [pscustomobject]@{ Name = 'Gateway status'; Arguments = @('gateway', 'status', '--require-rpc') }
    )

    $results = foreach ($step in $steps) {
        Write-Host ("Running: {0}" -f $step.Name) -ForegroundColor Cyan
        & $openClawCommand @($step.Arguments)
        [pscustomobject]@{
            Name = $step.Name
            ExitCode = $LASTEXITCODE
            Passed = $LASTEXITCODE -eq 0
        }
    }

    return $results
}

Export-ModuleMember -Function @(
    'ConvertTo-OpenClawVersion',
    'Get-OpenClawSourceConfig',
    'Test-OpenClawUriAllowed',
    'Test-OpenClawNodeVersion',
    'Test-OpenClawIsWindows',
    'Get-OpenClawReadiness',
    'Show-OpenClawReadiness',
    'Get-OpenClawInstallPlan',
    'Show-OpenClawInstallPlan',
    'Save-OpenClawInstaller',
    'Install-OpenClawNodePrerequisite',
    'Start-OpenClawOnboarding',
    'Install-OpenClawOfficial',
    'Invoke-OpenClawVerification'
)
