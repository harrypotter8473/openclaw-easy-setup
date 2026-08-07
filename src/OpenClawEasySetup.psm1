Set-StrictMode -Version Latest

$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:DefaultSourceConfigPath = Join-Path $script:ProjectRoot 'config\openclaw-source.json'
$script:PackageTreeHasherSourcePath = Join-Path $PSScriptRoot 'PackageIntegrity\OpenClawEasySetup.PackageTreeHasher.cs'
$recoveryModulePath = Join-Path $PSScriptRoot 'OpenClawEasySetup.Recovery.ps1'
if (-not (Test-Path -LiteralPath $recoveryModulePath -PathType Leaf)) {
    throw "Recovery module was not found: $recoveryModulePath"
}
. $recoveryModulePath

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

    if ([string]$config.slackPlugin.id -ne 'slack' -or
        [string]$config.slackPlugin.package -ne '@openclaw/slack' -or
        [string]$config.slackPlugin.version -notmatch '^\d{4}\.\d+\.\d+$' -or
        [string]$config.slackPlugin.version -ne [string]$config.openClaw.version -or
        [string]$config.slackPlugin.installSpec -ne ("{0}@{1}" -f $config.slackPlugin.package, $config.slackPlugin.version) -or
        [string]$config.slackPlugin.npmIntegrity -notmatch '^sha512-[A-Za-z0-9+/]+={0,2}$' -or
        [string]$config.slackPlugin.npmShasum -notmatch '^[A-Fa-f0-9]{40}$') {
        throw 'The source configuration does not contain a valid exact official Slack plugin pin.'
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

    if ([string]$config.git.winget.id -ne 'Git.Git' -or
        [string]$config.git.winget.source -ne 'winget' -or
        [string]$config.git.winget.version -notmatch '^\d+\.\d+\.\d+\.\d+$' -or
        [string]$config.git.winget.installerSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'The source configuration does not contain a valid pinned Git for Windows WinGet package.'
    }

    if (@($config.allowedDownloadHosts).Count -eq 0) {
        throw 'The source configuration does not define any allowed download hosts.'
    }

    return $config
}

function Enter-OpenClawSourceConfigReadLock {
    [CmdletBinding()]
    param()

    $path = [IO.Path]::GetFullPath($script:DefaultSourceConfigPath)
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -le 0 -or $item.Length -gt 256KB) {
        throw 'The source configuration must be a normal file within the allowed size.'
    }
    try {
        return New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    }
    catch {
        $_.Exception.Data['OpenClawFailureKind'] = 'Integrity'
        throw
    }
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

function Get-OpenClawPackageSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandPath
    )

    $blocked = {
        param([string]$Reason)
        [pscustomobject]@{
            Found = $true
            Path = $CommandPath
            RawVersion = $Reason
            Version = $null
            ExitCode = 1
            Trusted = $false
            Ambiguous = $false
            EntryPath = $null
            PackageRoot = $null
        }
    }

    try {
        if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
            return & $blocked 'The per-user npm directory could not be determined.'
        }
        $packageRoot = [IO.Path]::GetFullPath((Join-Path $env:APPDATA 'npm\node_modules\openclaw'))
        $packagePrefix = $packageRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        $packageJsonPath = Join-Path $packageRoot 'package.json'
        if (-not (Test-Path -LiteralPath $packageJsonPath -PathType Leaf)) {
            return & $blocked 'The OpenClaw npm package metadata was not found.'
        }
        foreach ($path in @($packageRoot, $packageJsonPath, $CommandPath)) {
            $item = Get-Item -LiteralPath $path -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                return & $blocked 'The OpenClaw npm package used a reparse point.'
            }
        }
        $packageJsonItem = Get-Item -LiteralPath $packageJsonPath -Force
        if ($packageJsonItem.Length -le 0 -or $packageJsonItem.Length -gt 1MB) {
            return & $blocked 'The OpenClaw npm package metadata size was invalid.'
        }
        $package = Get-Content -LiteralPath $packageJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$package.name -ne 'openclaw' -or [string]$package.version -notmatch '^\d{4}\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$') {
            return & $blocked 'The OpenClaw npm package name or version was invalid.'
        }
        $binEntry = if ($package.bin -is [string]) {
            [string]$package.bin
        }
        elseif ($null -ne $package.bin -and $null -ne $package.bin.PSObject.Properties['openclaw']) {
            [string]$package.bin.openclaw
        }
        else {
            $null
        }
        if ([string]::IsNullOrWhiteSpace($binEntry)) {
            return & $blocked 'The OpenClaw npm package did not define its command entrypoint.'
        }
        $entryPath = [IO.Path]::GetFullPath((Join-Path $packageRoot $binEntry))
        if (-not $entryPath.StartsWith($packagePrefix, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $entryPath -PathType Leaf)) {
            return & $blocked 'The OpenClaw npm command entrypoint left the package directory.'
        }
        if (((Get-Item -LiteralPath $entryPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return & $blocked 'The OpenClaw npm command entrypoint was a reparse point.'
        }
        $commandItem = Get-Item -LiteralPath $CommandPath -Force
        if ($commandItem.Length -le 0 -or $commandItem.Length -gt 64KB) {
            return & $blocked 'The OpenClaw npm command shim size was invalid.'
        }
        $commandText = Get-Content -LiteralPath $CommandPath -Raw -Encoding UTF8
        if ($commandText -notmatch '(?i)node_modules[\\/]openclaw[\\/]') {
            return & $blocked 'The OpenClaw npm command shim did not reference the expected package.'
        }

        return [pscustomobject]@{
            Found = $true
            Path = $CommandPath
            RawVersion = ("openclaw {0}" -f [string]$package.version)
            Version = ConvertTo-OpenClawVersion -Text ([string]$package.version)
            ExitCode = 0
            Trusted = $true
            Ambiguous = $false
            EntryPath = $entryPath
            PackageRoot = $packageRoot
        }
    }
    catch {
        return & $blocked 'The OpenClaw npm package provenance could not be verified.'
    }
}

function Initialize-OpenClawPackageTreeHasher {
    [CmdletBinding()]
    param()

    if ($null -eq ('OpenClawEasySetup.Integrity.PackageTreeHasher' -as [type])) {
        $sourcePath = [IO.Path]::GetFullPath($script:PackageTreeHasherSourcePath)
        $sourcePrefix = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if (-not $sourcePath.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw 'The package integrity helper source was not found in the trusted module directory.'
        }
        $sourceItem = Get-Item -LiteralPath $sourcePath -Force
        if (($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $sourceItem.Length -le 0 -or $sourceItem.Length -gt 64KB) {
            throw 'The package integrity helper source was unsafe.'
        }
        Add-Type -Path $sourcePath -ErrorAction Stop
    }
}

function Get-OpenClawPackageTreeDigest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageRoot
    )

    Initialize-OpenClawPackageTreeHasher
    return [OpenClawEasySetup.Integrity.PackageTreeHasher]::Compute([IO.Path]::GetFullPath($PackageRoot))
}

function Get-OpenClawPackageTreeMetadataDigest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageRoot
    )

    Initialize-OpenClawPackageTreeHasher
    return [OpenClawEasySetup.Integrity.PackageTreeHasher]::ComputeMetadata([IO.Path]::GetFullPath($PackageRoot))
}

function Get-OpenClawCriticalPackageDigests {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Snapshot
    )

    if ([string]::IsNullOrWhiteSpace([string]$Snapshot.PackageRoot) -or
        [string]::IsNullOrWhiteSpace([string]$Snapshot.EntryPath) -or
        [string]::IsNullOrWhiteSpace([string]$Snapshot.Path)) {
        throw 'The OpenClaw critical package paths were incomplete.'
    }

    $packageRoot = [IO.Path]::GetFullPath([string]$Snapshot.PackageRoot)
    $packageRootItem = Get-Item -LiteralPath $packageRoot -Force -ErrorAction Stop
    if (-not $packageRootItem.PSIsContainer -or
        ($packageRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The OpenClaw package root was not a normal directory.'
    }

    $packagePrefix = $packageRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $entryPath = [IO.Path]::GetFullPath([string]$Snapshot.EntryPath)
    $packageJsonPath = [IO.Path]::GetFullPath((Join-Path $packageRoot 'package.json'))
    if (-not $entryPath.StartsWith($packagePrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not $packageJsonPath.StartsWith($packagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'An OpenClaw critical package file left the package root.'
    }

    $commandPath = [IO.Path]::GetFullPath([string]$Snapshot.Path)
    Initialize-OpenClawPackageTreeHasher
    $commandShimSha256 = [OpenClawEasySetup.Integrity.PackageTreeHasher]::ComputeFile($commandPath, [int64](64KB))
    $packageEntryPointSha256 = [OpenClawEasySetup.Integrity.PackageTreeHasher]::ComputeFile($entryPath, [int64](256MB))
    $packageJsonSha256 = [OpenClawEasySetup.Integrity.PackageTreeHasher]::ComputeFile($packageJsonPath, [int64](1MB))

    return [pscustomobject]@{
        CommandShimSha256 = $commandShimSha256
        PackageEntryPointSha256 = $packageEntryPointSha256
        PackageJsonSha256 = $packageJsonSha256
        PackageEntryPointRelativePath = $entryPath.Substring($packagePrefix.Length).Replace('\', '/')
    }
}

function Get-OpenClawExistingStatePaths {
    [CmdletBinding()]
    param(
        [string]$StateDirectory
    )

    $root = if ([string]::IsNullOrWhiteSpace($StateDirectory)) {
        $localApplicationData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        if ([string]::IsNullOrWhiteSpace($localApplicationData)) {
            return $null
        }
        Join-Path $localApplicationData 'OpenClawEasySetup'
    }
    else {
        $StateDirectory
    }
    $root = [IO.Path]::GetFullPath($root)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        return $null
    }
    $rootItem = Get-Item -LiteralPath $root -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        return $null
    }
    $markerPath = Join-Path $root '.openclaw-easy-setup-state'
    $statePath = Join-Path $root 'State'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf) -or -not (Test-Path -LiteralPath $statePath -PathType Container)) {
        return $null
    }
    $markerItem = Get-Item -LiteralPath $markerPath -Force
    $stateItem = Get-Item -LiteralPath $statePath -Force
    if (($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($stateItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $markerItem.Length -gt 128 -or
        (Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8).Trim() -ne 'OpenClawEasySetup-State-v1') {
        return $null
    }
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        foreach ($privatePath in @($root, $markerPath, $statePath)) {
            $privateAcl = Get-Acl -LiteralPath $privatePath
            $currentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $allowedSids = @($currentUserSid, 'S-1-5-18')
            $ownerSid = $privateAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value
            $unexpectedAllowRule = @($privateAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object {
                $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and $_.IdentityReference.Value -notin $allowedSids
            }).Count -gt 0
            if ($ownerSid -ne $currentUserSid -or $unexpectedAllowRule -or -not $privateAcl.AreAccessRulesProtected) {
                return $null
            }
        }
    }
    return [pscustomobject]@{ Root = $root; State = $statePath }
}

function Write-OpenClawProvenanceReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Snapshot,

        [Parameter(Mandatory = $true)]
        [version]$TargetVersion,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Fa-f0-9]{64}$')]
        [string]$SourceFingerprint,

        [string]$StateDirectory
    )

    if (-not $Snapshot.Found -or -not $Snapshot.Trusted -or $Snapshot.Ambiguous -or
        $Snapshot.ExitCode -ne 0 -or $null -eq $Snapshot.Version -or $Snapshot.Version -ne $TargetVersion -or
        [string]::IsNullOrWhiteSpace([string]$Snapshot.Path) -or
        [string]::IsNullOrWhiteSpace([string]$Snapshot.EntryPath) -or
        [string]::IsNullOrWhiteSpace([string]$Snapshot.PackageRoot)) {
        throw 'A provenance receipt can only be written for the exact trusted OpenClaw target.'
    }

    $treeDigest = Get-OpenClawPackageTreeDigest -PackageRoot $Snapshot.PackageRoot
    $criticalDigests = Get-OpenClawCriticalPackageDigests -Snapshot $Snapshot
    $finalMetadataDigest = Get-OpenClawPackageTreeMetadataDigest -PackageRoot $Snapshot.PackageRoot
    if ($treeDigest.MetadataSha256 -ne $finalMetadataDigest.Sha256 -or
        $treeDigest.FileCount -ne $finalMetadataDigest.FileCount -or
        $treeDigest.TotalBytes -ne $finalMetadataDigest.TotalBytes) {
        throw 'The OpenClaw package tree changed while its provenance receipt was being created.'
    }
    $userSid = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }
    else {
        'non-windows'
    }
    $directories = Initialize-OpenClawStateDirectory -Path $StateDirectory
    $receiptPath = Join-Path $directories.State 'provenance.json'
    $temporaryPath = Join-Path $directories.State ("provenance.{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
    $backupPath = Join-Path $directories.State ("provenance.{0}.bak" -f ([guid]::NewGuid().ToString('N')))
    $receipt = [ordered]@{
        schemaVersion = 2
        toolVersion = '0.4.0'
        targetVersion = $TargetVersion.ToString()
        sourceFingerprint = $SourceFingerprint.ToUpperInvariant()
        userSid = $userSid
        packageTreeSha256 = $treeDigest.Sha256
        packageMetadataTreeSha256 = $finalMetadataDigest.Sha256
        packageFileCount = $treeDigest.FileCount
        packageTotalBytes = $treeDigest.TotalBytes
        commandShimSha256 = $criticalDigests.CommandShimSha256
        packageEntryPointSha256 = $criticalDigests.PackageEntryPointSha256
        packageEntryPointRelativePath = $criticalDigests.PackageEntryPointRelativePath
        packageJsonSha256 = $criticalDigests.PackageJsonSha256
        createdAtUtc = [DateTime]::UtcNow.ToString('o')
    }

    try {
        $json = $receipt | ConvertTo-Json -Depth 4
        $encoding = New-Object Text.UTF8Encoding($false)
        $bytes = $encoding.GetBytes($json)
        $stream = New-Object IO.FileStream($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            [void](Set-OpenClawPrivatePathAcl -Path $temporaryPath)
        }
        if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
            $existingReceipt = Get-Item -LiteralPath $receiptPath -Force
            if (($existingReceipt.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'The existing provenance receipt was a reparse point.'
            }
            [IO.File]::Replace($temporaryPath, $receiptPath, $backupPath, $true)
        }
        else {
            [IO.File]::Move($temporaryPath, $receiptPath)
        }
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            [void](Set-OpenClawPrivatePathAcl -Path $receiptPath)
        }
        return $receiptPath
    }
    finally {
        foreach ($cleanupPath in @($temporaryPath, $backupPath)) {
            if (Test-Path -LiteralPath $cleanupPath -PathType Leaf) {
                Remove-Item -LiteralPath $cleanupPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Test-OpenClawProvenanceReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Snapshot,

        [string]$StateDirectory
    )

    $invalid = {
        param([string]$Reason, [string]$Path, [string]$VerificationMode = 'None')
        [pscustomobject]@{ Valid = $false; Reason = $Reason; Path = $Path; VerificationMode = $VerificationMode }
    }
    try {
        $paths = Get-OpenClawExistingStatePaths -StateDirectory $StateDirectory
        if ($null -eq $paths) {
            return & $invalid 'The OpenClaw Easy Setup state directory was not found or was invalid.' $null
        }
        $receiptPath = Join-Path $paths.State 'provenance.json'
        if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
            return & $invalid 'The OpenClaw installation provenance receipt was not found.' $receiptPath
        }
        $receiptItem = Get-Item -LiteralPath $receiptPath -Force
        if (($receiptItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $receiptItem.Length -le 0 -or $receiptItem.Length -gt 64KB) {
            return & $invalid 'The OpenClaw installation provenance receipt was invalid.' $receiptPath
        }
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            $receiptAcl = Get-Acl -LiteralPath $receiptPath
            $currentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $allowedSids = @($currentUserSid, 'S-1-5-18')
            $ownerSid = $receiptAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value
            $unexpectedAllowRule = @($receiptAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object {
                $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and $_.IdentityReference.Value -notin $allowedSids
            }).Count -gt 0
            if ($ownerSid -ne $currentUserSid -or $unexpectedAllowRule -or -not $receiptAcl.AreAccessRulesProtected) {
                return & $invalid 'The OpenClaw installation provenance receipt permissions were not private.' $receiptPath
            }
        }
        $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $sourceFingerprint = (Get-FileHash -LiteralPath $script:DefaultSourceConfigPath -Algorithm SHA256).Hash.ToUpperInvariant()
        $currentSid = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        }
        else {
            'non-windows'
        }
        if ([int]$receipt.schemaVersion -ne 2 -or
            [string]$receipt.targetVersion -notmatch '^\d{4}\.\d+\.\d+$' -or
            [string]$receipt.sourceFingerprint -ne $sourceFingerprint -or
            [string]$receipt.userSid -ne $currentSid -or
            [string]$receipt.packageTreeSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
            [string]$receipt.packageMetadataTreeSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
            [string]$receipt.commandShimSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
            [string]$receipt.packageEntryPointSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
            [string]$receipt.packageJsonSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
            [string]::IsNullOrWhiteSpace([string]$receipt.packageEntryPointRelativePath) -or
            [string]$receipt.packageEntryPointRelativePath -match '(^/|\\|(^|/)\.\.(/|$))' -or
            [int]$receipt.packageFileCount -le 0 -or [int]$receipt.packageFileCount -gt 50000 -or
            [int64]$receipt.packageTotalBytes -le 0 -or [int64]$receipt.packageTotalBytes -gt 2GB) {
            return & $invalid 'The OpenClaw installation provenance receipt did not match this tool or user.' $receiptPath
        }
        if (-not $Snapshot.Found -or -not $Snapshot.Trusted -or $Snapshot.Ambiguous -or
            $Snapshot.ExitCode -ne 0 -or $null -eq $Snapshot.Version -or
            $Snapshot.Version.ToString() -ne [string]$receipt.targetVersion) {
            return & $invalid 'The installed OpenClaw version did not match its provenance receipt.' $receiptPath
        }

        $criticalDigests = Get-OpenClawCriticalPackageDigests -Snapshot $Snapshot
        if ($criticalDigests.CommandShimSha256 -ne ([string]$receipt.commandShimSha256).ToUpperInvariant() -or
            $criticalDigests.PackageEntryPointSha256 -ne ([string]$receipt.packageEntryPointSha256).ToUpperInvariant() -or
            $criticalDigests.PackageJsonSha256 -ne ([string]$receipt.packageJsonSha256).ToUpperInvariant() -or
            $criticalDigests.PackageEntryPointRelativePath -cne [string]$receipt.packageEntryPointRelativePath) {
            return & $invalid 'The installed OpenClaw files changed after their verified installation.' $receiptPath 'CriticalFiles'
        }

        $metadataDigest = Get-OpenClawPackageTreeMetadataDigest -PackageRoot $Snapshot.PackageRoot
        if ($metadataDigest.Sha256 -eq ([string]$receipt.packageMetadataTreeSha256).ToUpperInvariant() -and
            $metadataDigest.FileCount -eq [int]$receipt.packageFileCount -and
            $metadataDigest.TotalBytes -eq [int64]$receipt.packageTotalBytes) {
            return [pscustomobject]@{ Valid = $true; Reason = ''; Path = $receiptPath; VerificationMode = 'MetadataCache' }
        }

        $treeDigest = Get-OpenClawPackageTreeDigest -PackageRoot $Snapshot.PackageRoot
        $finalCriticalDigests = Get-OpenClawCriticalPackageDigests -Snapshot $Snapshot
        if ($treeDigest.Sha256 -ne ([string]$receipt.packageTreeSha256).ToUpperInvariant() -or
            $treeDigest.FileCount -ne [int]$receipt.packageFileCount -or
            $treeDigest.TotalBytes -ne [int64]$receipt.packageTotalBytes -or
            $finalCriticalDigests.CommandShimSha256 -ne ([string]$receipt.commandShimSha256).ToUpperInvariant() -or
            $finalCriticalDigests.PackageEntryPointSha256 -ne ([string]$receipt.packageEntryPointSha256).ToUpperInvariant() -or
            $finalCriticalDigests.PackageJsonSha256 -ne ([string]$receipt.packageJsonSha256).ToUpperInvariant() -or
            $finalCriticalDigests.PackageEntryPointRelativePath -cne [string]$receipt.packageEntryPointRelativePath) {
            return & $invalid 'The installed OpenClaw files changed after their verified installation.' $receiptPath 'FullFallback'
        }
        return [pscustomobject]@{ Valid = $true; Reason = ''; Path = $receiptPath; VerificationMode = 'FullFallback' }
    }
    catch {
        return & $invalid 'The OpenClaw installation provenance could not be verified.' $null
    }
}

function Test-OpenClawExternalCommandTrust {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('node', 'npm', 'winget', 'git')]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        $fullPath = [IO.Path]::GetFullPath($Path)
        if ($Name -eq 'winget') {
            $expectedWinget = if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $null } else { [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe')) }
            $trusted = -not [string]::IsNullOrWhiteSpace($expectedWinget) -and [string]::Equals($fullPath, $expectedWinget, [StringComparison]::OrdinalIgnoreCase)
            return [pscustomobject]@{ Trusted = $trusted; Reason = $(if ($trusted) { '' } else { 'WinGet was outside the Windows App Execution Alias directory.' }) }
        }

        if ($Name -eq 'git') {
            $gitItem = Get-Item -LiteralPath $fullPath -Force
            if (($gitItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or [IO.Path]::GetFileName($fullPath).ToLowerInvariant() -ne 'git.exe') {
                return [pscustomobject]@{ Trusted = $false; Reason = 'Git was not a normal git.exe file.' }
            }
            $expectedGitPaths = @(
                $(if ([string]::IsNullOrWhiteSpace($env:ProgramFiles)) { $null } else { Join-Path $env:ProgramFiles 'Git\cmd\git.exe' }),
                $(if ([string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) { $null } else { Join-Path ${env:ProgramFiles(x86)} 'Git\cmd\git.exe' }),
                $(if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $null } else { Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe' })
            ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [IO.Path]::GetFullPath($_) }
            if (@($expectedGitPaths | Where-Object { [string]::Equals($_, $fullPath, [StringComparison]::OrdinalIgnoreCase) }).Count -ne 1) {
                return [pscustomobject]@{ Trusted = $false; Reason = 'Git was outside an approved Git for Windows installation directory.' }
            }
            $gitSignature = Get-AuthenticodeSignature -LiteralPath $fullPath
            if ($gitSignature.Status -ne 'Valid') {
                return [pscustomobject]@{ Trusted = $false; Reason = 'Git for Windows did not have a valid Authenticode signature.' }
            }
            return [pscustomobject]@{ Trusted = $true; Reason = '' }
        }

        $item = Get-Item -LiteralPath $fullPath -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return [pscustomobject]@{ Trusted = $false; Reason = 'The command path was a reparse point.' }
        }

        $trustedRoots = New-Object System.Collections.Generic.List[string]
        foreach ($rootCandidate in @(
            $(if ([string]::IsNullOrWhiteSpace($env:ProgramFiles)) { $null } else { Join-Path $env:ProgramFiles 'nodejs' }),
            $(if ([string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) { $null } else { Join-Path ${env:ProgramFiles(x86)} 'nodejs' }),
            $(if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $null } else { Join-Path $env:LOCALAPPDATA 'Programs\nodejs' })
        )) {
            if (-not [string]::IsNullOrWhiteSpace($rootCandidate)) {
                $trustedRoots.Add(([IO.Path]::GetFullPath($rootCandidate)).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar)
            }
        }
        $trustedRoot = @($trustedRoots | Where-Object { $fullPath.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)
        if ($trustedRoot.Count -ne 1) {
            return [pscustomobject]@{ Trusted = $false; Reason = 'Node.js command was outside an approved installation directory.' }
        }

        $nodeExecutable = if ($Name -eq 'node') { $fullPath } else { Join-Path (Split-Path -Parent $fullPath) 'node.exe' }
        if (-not (Test-Path -LiteralPath $nodeExecutable -PathType Leaf)) {
            return [pscustomobject]@{ Trusted = $false; Reason = 'The matching Node.js executable was not found.' }
        }
        $signature = Get-AuthenticodeSignature -LiteralPath $nodeExecutable
        if ($signature.Status -ne 'Valid') {
            return [pscustomobject]@{ Trusted = $false; Reason = 'The Node.js executable did not have a valid Authenticode signature.' }
        }
        if ($Name -eq 'node' -and [IO.Path]::GetExtension($fullPath).ToLowerInvariant() -ne '.exe') {
            return [pscustomobject]@{ Trusted = $false; Reason = 'The Node.js command was not an executable.' }
        }
        if ($Name -eq 'npm' -and [IO.Path]::GetFileName($fullPath).ToLowerInvariant() -ne 'npm.cmd') {
            return [pscustomobject]@{ Trusted = $false; Reason = 'The npm command was not the expected npm.cmd shim.' }
        }
        return [pscustomobject]@{ Trusted = $true; Reason = '' }
    }
    catch {
        return [pscustomobject]@{ Trusted = $false; Reason = 'The command provenance could not be verified.' }
    }
}

function Get-OpenClawCommandSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string[]]$Arguments = @('--version')
    )

    $commandPath = $null
    $trusted = $true
    $ambiguous = $false

    if ($Name -eq 'openclaw') {
        try {
            $commandPath = Resolve-OpenClawCommand
        }
        catch {
            return [pscustomobject]@{
                Found = $true
                Path = $null
                RawVersion = 'OpenClaw command resolution was blocked because the installation path was untrusted or ambiguous.'
                Version = $null
                ExitCode = 1
                Trusted = $false
                Ambiguous = $true
            }
        }
    }
    elseif ($Name -eq 'npm') {
        $nodeCommand = Get-Command -Name 'node' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $nodeCommand -and -not [string]::IsNullOrWhiteSpace([string]$nodeCommand.Source)) {
            $npmCommandPath = Join-Path (Split-Path -Parent $nodeCommand.Source) 'npm.cmd'
            if (Test-Path -LiteralPath $npmCommandPath -PathType Leaf) {
                $commandPath = $npmCommandPath
            }
        }
        if ([string]::IsNullOrWhiteSpace($commandPath)) {
            $command = Get-Command -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $command) {
                $commandPath = $command.Source
            }
        }
    }
    else {
        $command = Get-Command -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) {
            $commandPath = $command.Source
        }
    }

    if ([string]::IsNullOrWhiteSpace($commandPath)) {
        return [pscustomobject]@{
            Found = $false
            Path = $null
            RawVersion = $null
            Version = $null
            ExitCode = $null
            Trusted = $trusted
            Ambiguous = $ambiguous
        }
    }

    if ($Name -eq 'openclaw') {
        return Get-OpenClawPackageSnapshot -CommandPath $commandPath
    }

    if ($Name -in @('node', 'npm', 'winget', 'git')) {
        $trust = Test-OpenClawExternalCommandTrust -Name $Name -Path $commandPath
        if (-not $trust.Trusted) {
            return [pscustomobject]@{
                Found = $true
                Path = $commandPath
                RawVersion = Protect-OpenClawLogText -Text $trust.Reason
                Version = $null
                ExitCode = 1
                Trusted = $false
                Ambiguous = $false
            }
        }
    }

    try {
        $raw = (& $commandPath @Arguments 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE
        $parsedVersion = ConvertTo-OpenClawVersion -Text $raw
        $safeRaw = Protect-OpenClawLogText -Text $raw
        return [pscustomobject]@{
            Found = $true
            Path = $commandPath
            RawVersion = $safeRaw
            Version = $parsedVersion
            ExitCode = $exitCode
            Trusted = $trusted
            Ambiguous = $ambiguous
        }
    }
    catch {
        return [pscustomobject]@{
            Found = $true
            Path = $commandPath
            RawVersion = Protect-OpenClawLogText -Text $_.Exception.Message
            Version = $null
            ExitCode = 1
            Trusted = $trusted
            Ambiguous = $ambiguous
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
    $wingetUsable = $winget.Found -and $winget.Trusted -and $winget.ExitCode -eq 0 -and $null -ne $winget.Version
    if ($wingetUsable) {
        $checks.Add((New-OpenClawReadinessCheck -Id 'winget' -Status 'Pass' -Current $winget.Version.ToString() -Required 'WinGet available for pinned Node.js provisioning' -Guidance 'WinGet will verify the exact package manifest and installer hash.'))
    }
    else {
        $checks.Add((New-OpenClawReadinessCheck -Id 'winget' -Status 'Fail' -Current $(if ($winget.Found) { $winget.RawVersion } else { 'Not found' }) -Required 'WinGet available for pinned Node.js provisioning' -Guidance 'Install or repair Microsoft App Installer before automatic prerequisite setup.'))
    }

    $git = Get-OpenClawCommandSnapshot -Name 'git'
    $gitUsable = $git.Found -and $git.Trusted -and $git.ExitCode -eq 0 -and $null -ne $git.Version
    if ($gitUsable) {
        $checks.Add((New-OpenClawReadinessCheck -Id 'git' -Status 'Pass' -Current $git.RawVersion -Required 'Trusted Git for Windows or pinned WinGet provisioning' -Guidance 'Only this signed Git executable will be exposed to the official OpenClaw installer.'))
    }
    else {
        $checks.Add((New-OpenClawReadinessCheck -Id 'git' -Status $(if ($wingetUsable) { 'Warn' } else { 'Fail' }) -Current $(if ($git.Found) { $git.RawVersion } else { 'Not found' }) -Required 'Trusted Git for Windows or pinned WinGet provisioning' -Guidance 'The Apply flow can install pinned Git for Windows through WinGet.'))
    }

    $node = Get-OpenClawCommandSnapshot -Name 'node'
    if (-not $node.Found) {
        $checks.Add((New-OpenClawReadinessCheck -Id 'node' -Status $(if ($wingetUsable) { 'Warn' } else { 'Fail' }) -Current 'Not found' -Required 'Node 26 recommended; 22.22.3+, 24.15+, or 25.9+ supported' -Guidance 'The Apply flow can install pinned Node.js 26.5.1 through WinGet.'))
    }
    elseif ($node.ExitCode -ne 0 -or $null -eq $node.Version) {
        $checks.Add((New-OpenClawReadinessCheck -Id 'node' -Status $(if ($wingetUsable) { 'Warn' } else { 'Fail' }) -Current $node.RawVersion -Required 'A parseable supported Node.js version' -Guidance 'The Apply flow can replace this with pinned Node.js 26.5.1 through WinGet.'))
    }
    else {
        $nodeSupport = Test-OpenClawNodeVersion -Version $node.Version
        $checks.Add((New-OpenClawReadinessCheck -Id 'node' -Status $(if ($nodeSupport.Supported) { 'Pass' } elseif ($wingetUsable) { 'Warn' } else { 'Fail' }) -Current $node.Version.ToString() -Required 'Node 26 recommended; 22.22.3+, 24.15+, or 25.9+ supported' -Guidance $(if ($nodeSupport.Supported) { $nodeSupport.Reason } else { 'The Apply flow can replace this with pinned Node.js 26.5.1 through WinGet.' })))
    }

    $npm = Get-OpenClawCommandSnapshot -Name 'npm'
    if ($npm.Found -and $npm.ExitCode -eq 0 -and $null -ne $npm.Version) {
        $checks.Add((New-OpenClawReadinessCheck -Id 'npm' -Status 'Pass' -Current $npm.Version.ToString() -Required 'npm available with Node.js' -Guidance 'npm is required by the pinned installation method.'))
    }
    else {
        $checks.Add((New-OpenClawReadinessCheck -Id 'npm' -Status 'Fail' -Current $(if ($npm.Found) { $npm.RawVersion } else { 'Not found' }) -Required 'npm available with Node.js' -Guidance 'Repair the Node.js installation so npm is available on PATH.'))
    }

    $openClaw = Get-OpenClawCommandSnapshot -Name 'openclaw'
    if ($openClaw.Found) {
        $openClawUsable = $openClaw.Trusted -and -not $openClaw.Ambiguous -and $openClaw.ExitCode -eq 0 -and $null -ne $openClaw.Version
        $checks.Add((New-OpenClawReadinessCheck -Id 'openclaw' -Status $(if ($openClawUsable) { 'Pass' } else { 'Fail' }) -Current $(if ($openClawUsable) { $openClaw.Version.ToString() } else { $openClaw.RawVersion }) -Required 'A single trusted per-user npm installation' -Guidance $(if ($openClawUsable) { 'The existing installation will be evaluated before any update.' } else { 'Remove duplicate or untrusted OpenClaw command shims before automatic installation.' })))
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
                $guidance = Get-OpenClawMessageValue -Messages $messages -Path ("checks.{0}.guidance" -f $item.Id) -Fallback $item.Guidance
                Write-Host ("  -> {0}" -f $guidance) -ForegroundColor DarkGray
            }
        }
    }
}

function Get-OpenClawInstallPlan {
    [CmdletBinding()]
    param()

    $config = Get-OpenClawSourceConfig
    $messages = Get-OpenClawMessages
    @(
        [pscustomobject]@{ Order = 1; Id = 'diagnose'; ChangesPC = $false; RequiresAdmin = $false; Title = $messages.planSteps.diagnoseTitle; Detail = $messages.planSteps.diagnoseDetail }
        [pscustomobject]@{ Order = 2; Id = 'node'; ChangesPC = $true; RequiresAdmin = 'MayPrompt'; Title = $messages.planSteps.nodeTitle; Detail = ([string]$messages.planSteps.nodeDetail -f $config.git.winget.id, $config.git.winget.version, $config.git.winget.installerSha256, $config.node.winget.id, $config.node.winget.version, $config.node.winget.installerSha256) }
        [pscustomobject]@{ Order = 3; Id = 'download'; ChangesPC = $true; RequiresAdmin = $false; Title = $messages.planSteps.downloadTitle; Detail = ([string]$messages.planSteps.downloadDetail -f $config.openClaw.releaseTag, $config.openClaw.commitSha, (@($config.allowedDownloadHosts) -join ', ')) }
        [pscustomobject]@{ Order = 4; Id = 'integrity'; ChangesPC = $false; RequiresAdmin = $false; Title = $messages.planSteps.integrityTitle; Detail = ([string]$messages.planSteps.integrityDetail -f $config.installer.sha256) }
        [pscustomobject]@{ Order = 5; Id = 'dryRun'; ChangesPC = $false; RequiresAdmin = $false; Title = $messages.planSteps.dryRunTitle; Detail = ([string]$messages.planSteps.dryRunDetail -f $config.installer.installMethod, $config.openClaw.version) }
        [pscustomobject]@{ Order = 6; Id = 'install'; ChangesPC = $true; RequiresAdmin = $false; Title = $messages.planSteps.installTitle; Detail = ([string]$messages.planSteps.installDetail -f $config.slackPlugin.installSpec) }
        [pscustomobject]@{ Order = 7; Id = 'onboard'; ChangesPC = $true; RequiresAdmin = $false; Title = $messages.planSteps.onboardTitle; Detail = $messages.planSteps.onboardDetail }
        [pscustomobject]@{ Order = 8; Id = 'verify'; ChangesPC = $false; RequiresAdmin = $false; Title = $messages.planSteps.verifyTitle; Detail = $messages.planSteps.verifyDetail }
    )
}

function Get-OpenClawPlanFingerprint {
    [CmdletBinding()]
    param(
        [ValidateSet('Install', 'Resume')]
        [string]$Mode = 'Install'
    )

    $sourceFingerprint = (Get-FileHash -LiteralPath $script:DefaultSourceConfigPath -Algorithm SHA256).Hash.ToUpperInvariant()
    $localeFingerprint = (Get-FileHash -LiteralPath (Join-Path $script:ProjectRoot 'locales\ko-KR.json') -Algorithm SHA256).Hash.ToUpperInvariant()
    $semanticPlan = @(Get-OpenClawInstallPlan | ForEach-Object {
        [ordered]@{
            order = [int]$_.Order
            id = [string]$_.Id
            changesPC = [bool]$_.ChangesPC
            requiresAdmin = [string]$_.RequiresAdmin
            title = [string]$_.Title
            detail = [string]$_.Detail
        }
    })
    $payload = [ordered]@{
        schemaVersion = 1
        mode = $Mode
        sourceFingerprint = $sourceFingerprint
        localeFingerprint = $localeFingerprint
        stages = $semanticPlan
    } | ConvertTo-Json -Compress -Depth 5
    $encoding = New-Object Text.UTF8Encoding($false)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $encoding.GetBytes($payload)
        return ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
    }
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
        $mutation = if ($step.ChangesPC) { $messages.mutationChange } else { $messages.mutationReadOnly }
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
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('OpenClaw-Easy-Setup/0.4')
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
                throw (New-OpenClawTaggedException -Kind 'Integrity' -Message "Installer response size was outside the allowed range: $declaredLength bytes")
            }

            $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $outputStream = [IO.File]::Open($DestinationPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $buffer = New-Object byte[] 8192
                $totalBytes = [int64]0
                while (($bytesRead = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $totalBytes += $bytesRead
                    if ($totalBytes -gt $maximumBytes) {
                        throw (New-OpenClawTaggedException -Kind 'Integrity' -Message "Installer download exceeded the $maximumBytes byte limit.")
                    }
                    $outputStream.Write($buffer, 0, $bytesRead)
                }
            }
            finally {
                $outputStream.Dispose()
                $inputStream.Dispose()
            }

            if ($totalBytes -le 0) {
                throw (New-OpenClawTaggedException -Kind 'Integrity' -Message 'Installer download was empty.')
            }

            $hash = (Get-FileHash -LiteralPath $DestinationPath -Algorithm SHA256).Hash.ToUpperInvariant()
            if ($hash -ne ([string]$SourceConfig.installer.sha256).ToUpperInvariant()) {
                throw (New-OpenClawTaggedException -Kind 'Integrity' -Message "Installer SHA-256 mismatch. Expected $($SourceConfig.installer.sha256) but received $hash.")
            }

            $tokens = $null
            $parseErrors = $null
            [void][Management.Automation.Language.Parser]::ParseFile($DestinationPath, [ref]$tokens, [ref]$parseErrors)
            if (@($parseErrors).Count -gt 0) {
                throw (New-OpenClawTaggedException -Kind 'Integrity' -Message "Downloaded installer did not parse as PowerShell: $($parseErrors[0].Message)")
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

    if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
        $commandsWithoutProfile = @(Get-Command -Name 'openclaw' -All -ErrorAction SilentlyContinue)
        if ($commandsWithoutProfile.Count -gt 0) {
            throw 'OpenClaw was found, but its expected per-user npm installation directory could not be determined.'
        }
        return $null
    }

    $trustedRoot = [IO.Path]::GetFullPath((Join-Path $env:APPDATA 'npm'))
    $trustedPrefix = $trustedRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $candidatePaths = New-Object System.Collections.Generic.List[string]
    foreach ($command in @(Get-Command -Name 'openclaw' -All -ErrorAction SilentlyContinue)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
            try {
                $candidatePaths.Add([IO.Path]::GetFullPath([string]$command.Source))
            }
            catch {
                throw 'An OpenClaw command candidate used an invalid path.'
            }
        }
    }

    foreach ($fileName in @('openclaw.cmd', 'openclaw.exe', 'openclaw.ps1')) {
        $expectedPath = Join-Path $trustedRoot $fileName
        if (Test-Path -LiteralPath $expectedPath -PathType Leaf) {
            $candidatePaths.Add([IO.Path]::GetFullPath($expectedPath))
        }
    }

    $uniqueCandidates = @($candidatePaths | Select-Object -Unique)
    if ($uniqueCandidates.Count -eq 0) {
        return $null
    }

    $untrustedCandidates = @($uniqueCandidates | Where-Object {
        -not $_.StartsWith($trustedPrefix, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($untrustedCandidates.Count -gt 0) {
        throw 'OpenClaw commands were found outside the expected per-user npm installation directory.'
    }

    foreach ($candidate in $uniqueCandidates) {
        $item = Get-Item -LiteralPath $candidate -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'An OpenClaw command candidate was a reparse point.'
        }
        $candidateExtension = [IO.Path]::GetExtension($candidate).ToLowerInvariant()
        $candidateLeaf = [IO.Path]::GetFileName($candidate)
        if ($candidateExtension -notin @('.cmd', '.exe', '.ps1') -and $candidateLeaf -ne 'openclaw') {
            throw 'An OpenClaw command candidate used an unexpected file type.'
        }
    }

    $preferredCommand = Join-Path $trustedRoot 'openclaw.cmd'
    if ($uniqueCandidates -contains [IO.Path]::GetFullPath($preferredCommand)) {
        return [IO.Path]::GetFullPath($preferredCommand)
    }

    $preferredExecutable = @($uniqueCandidates | Where-Object { [IO.Path]::GetExtension($_) -eq '.exe' } | Select-Object -First 1)
    if ($preferredExecutable.Count -eq 1) {
        return $preferredExecutable[0]
    }

    if ($uniqueCandidates.Count -gt 1) {
        throw 'Multiple OpenClaw command shims were found and no trusted command shim could be selected safely.'
    }

    return $uniqueCandidates[0]
}

function Update-OpenClawProcessPath {
    [CmdletBinding()]
    param()

    $segments = New-Object System.Collections.Generic.List[string]
    foreach ($segment in @(([string]$env:Path).Split(';'))) {
        if (-not [string]::IsNullOrWhiteSpace($segment)) {
            $segments.Add($segment)
        }
    }

    $approvedRefreshCandidates = @(
        $(if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) { Join-Path $env:ProgramFiles 'Git\cmd' }),
        $(if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) { Join-Path ${env:ProgramFiles(x86)} 'Git\cmd' }),
        $(if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd' }),
        $(if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) { Join-Path $env:ProgramFiles 'nodejs' }),
        $(if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) { Join-Path ${env:ProgramFiles(x86)} 'nodejs' }),
        $(if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { Join-Path $env:LOCALAPPDATA 'Programs\nodejs' }),
        $(if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) { Join-Path $env:APPDATA 'npm' })
    )
    foreach ($candidate in $approvedRefreshCandidates) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate) -or
            -not (Test-Path -LiteralPath $candidate -PathType Container)) {
            continue
        }
        try {
            $fullPath = [IO.Path]::GetFullPath([string]$candidate)
            $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                $segments.Add($fullPath)
            }
        }
        catch {
            continue
        }
    }

    $env:Path = @($segments | Select-Object -Unique) -join ';'
}

function Resolve-OpenClawInvocation {
    [CmdletBinding()]
    param(
        [string]$StateDirectory
    )

    $commandPath = Resolve-OpenClawCommand
    if ([string]::IsNullOrWhiteSpace($commandPath)) {
        return $null
    }
    $packageSnapshot = Get-OpenClawPackageSnapshot -CommandPath $commandPath
    if (-not $packageSnapshot.Trusted -or $packageSnapshot.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$packageSnapshot.EntryPath)) {
        throw 'The installed OpenClaw npm package provenance could not be verified.'
    }
    $provenance = Test-OpenClawProvenanceReceipt -Snapshot $packageSnapshot -StateDirectory $StateDirectory
    if (-not $provenance.Valid) {
        throw 'The installed OpenClaw files did not match a verified OpenClaw Easy Setup installation receipt. Run Install -Apply first.'
    }
    $nodeSnapshot = Get-OpenClawCommandSnapshot -Name 'node'
    if (-not $nodeSnapshot.Found -or -not $nodeSnapshot.Trusted -or $nodeSnapshot.ExitCode -ne 0) {
        throw 'A trusted Node.js executable was not available for OpenClaw.'
    }
    return [pscustomobject]@{
        Executable = $nodeSnapshot.Path
        PrefixArguments = @($packageSnapshot.EntryPath)
    }
}

function Get-OpenClawObjectPropertyValue {
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }
    if ($InputObject -is [Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) {
            return $InputObject[$Name]
        }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Test-OpenClawPathContainedBy {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CandidatePath,

        [Parameter(Mandatory = $true)]
        [string]$RootPath
    )

    try {
        $candidate = [IO.Path]::GetFullPath($CandidatePath)
        $root = [IO.Path]::GetFullPath($RootPath)
        $rootPrefix = $root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        return [string]::Equals($candidate, $root, [StringComparison]::OrdinalIgnoreCase) -or
            $candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return $false
    }
}

function Assert-OpenClawSlackPluginProvenance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Inspection,

        [object]$SourceConfig = $(Get-OpenClawSourceConfig)
    )

    $expected = Get-OpenClawObjectPropertyValue -InputObject $SourceConfig -Name 'slackPlugin'
    $expectedId = [string](Get-OpenClawObjectPropertyValue -InputObject $expected -Name 'id')
    $expectedPackage = [string](Get-OpenClawObjectPropertyValue -InputObject $expected -Name 'package')
    $expectedVersion = [string](Get-OpenClawObjectPropertyValue -InputObject $expected -Name 'version')
    $expectedSpec = [string](Get-OpenClawObjectPropertyValue -InputObject $expected -Name 'installSpec')
    $expectedIntegrity = [string](Get-OpenClawObjectPropertyValue -InputObject $expected -Name 'npmIntegrity')
    $expectedShasum = [string](Get-OpenClawObjectPropertyValue -InputObject $expected -Name 'npmShasum')
    if ($expectedId -ne 'slack' -or $expectedPackage -ne '@openclaw/slack' -or
        $expectedVersion -notmatch '^\d{4}\.\d+\.\d+$' -or
        $expectedSpec -ne ("{0}@{1}" -f $expectedPackage, $expectedVersion) -or
        $expectedIntegrity -notmatch '^sha512-[A-Za-z0-9+/]+={0,2}$' -or
        $expectedShasum -notmatch '^[A-Fa-f0-9]{40}$') {
        throw 'The expected Slack plugin source metadata was invalid.'
    }

    $plugin = Get-OpenClawObjectPropertyValue -InputObject $Inspection -Name 'plugin'
    if ($null -eq $plugin) {
        throw 'OpenClaw did not return a Slack plugin inspection record.'
    }
    if ([string](Get-OpenClawObjectPropertyValue -InputObject $plugin -Name 'id') -ne $expectedId -or
        [string](Get-OpenClawObjectPropertyValue -InputObject $plugin -Name 'version') -ne $expectedVersion) {
        throw 'The installed Slack plugin identity or version did not match the reviewed pin.'
    }
    $reportedPackageName = [string](Get-OpenClawObjectPropertyValue -InputObject $plugin -Name 'packageName')
    if (-not [string]::IsNullOrWhiteSpace($reportedPackageName) -and $reportedPackageName -ne $expectedPackage) {
        throw 'The installed Slack plugin reported a different npm package identity.'
    }
    if ([string](Get-OpenClawObjectPropertyValue -InputObject $plugin -Name 'origin') -ne 'global') {
        throw 'The active Slack plugin did not come from the managed global plugin installation.'
    }
    if ((Get-OpenClawObjectPropertyValue -InputObject $plugin -Name 'enabled') -ne $true) {
        throw 'The exact Slack plugin was not enabled.'
    }
    $pluginStatus = [string](Get-OpenClawObjectPropertyValue -InputObject $plugin -Name 'status')
    if ([string]::IsNullOrWhiteSpace($pluginStatus) -or $pluginStatus -in @('disabled', 'error') -or
        -not [string]::IsNullOrWhiteSpace([string](Get-OpenClawObjectPropertyValue -InputObject $plugin -Name 'error')) -or
        -not [string]::IsNullOrWhiteSpace([string](Get-OpenClawObjectPropertyValue -InputObject $plugin -Name 'failurePhase'))) {
        throw 'The Slack plugin snapshot reported a disabled, invalid, or failed source.'
    }

    $channelIdsValue = Get-OpenClawObjectPropertyValue -InputObject $plugin -Name 'channelIds'
    $channelIds = @()
    if ($null -ne $channelIdsValue) {
        $channelIds = @($channelIdsValue)
    }
    if ($channelIds.Count -ne 1 -or [string]$channelIds[0] -ne $expectedId) {
        throw 'The Slack plugin did not expose only the reviewed Slack channel capability.'
    }
    $diagnosticsValue = Get-OpenClawObjectPropertyValue -InputObject $Inspection -Name 'diagnostics'
    $diagnostics = @()
    if ($null -ne $diagnosticsValue) {
        $diagnostics = @($diagnosticsValue)
    }
    if (@($diagnostics | Where-Object {
        [string](Get-OpenClawObjectPropertyValue -InputObject $_ -Name 'level') -eq 'error'
    }).Count -gt 0) {
        throw 'The Slack plugin runtime inspection reported an error diagnostic.'
    }
    $compatibilityValue = Get-OpenClawObjectPropertyValue -InputObject $Inspection -Name 'compatibility'
    $compatibility = @()
    if ($null -ne $compatibilityValue) {
        $compatibility = @($compatibilityValue)
    }
    if (@($compatibility | Where-Object {
        [string](Get-OpenClawObjectPropertyValue -InputObject $_ -Name 'severity') -eq 'warn'
    }).Count -gt 0) {
        throw 'The Slack plugin reported a compatibility warning for this OpenClaw host.'
    }

    $install = Get-OpenClawObjectPropertyValue -InputObject $Inspection -Name 'install'
    # The reviewed `plugins install <npm-spec> --pin` record uses the base
    # `integrity`/`shasum` fields. `npmIntegrity`/`npmShasum` describe an
    # npm-pack archive artifact and are not interchangeable provenance.
    if ($null -eq $install -or [string](Get-OpenClawObjectPropertyValue -InputObject $install -Name 'source') -ne 'npm' -or
        [string](Get-OpenClawObjectPropertyValue -InputObject $install -Name 'spec') -ne $expectedSpec -or
        [string](Get-OpenClawObjectPropertyValue -InputObject $install -Name 'version') -ne $expectedVersion -or
        -not [string]::Equals([string](Get-OpenClawObjectPropertyValue -InputObject $install -Name 'integrity'), $expectedIntegrity, [StringComparison]::Ordinal) -or
        -not [string]::Equals([string](Get-OpenClawObjectPropertyValue -InputObject $install -Name 'shasum'), $expectedShasum, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The Slack plugin npm install record did not match the reviewed package provenance.'
    }
    $resolvedName = [string](Get-OpenClawObjectPropertyValue -InputObject $install -Name 'resolvedName')
    if (-not [string]::IsNullOrWhiteSpace($resolvedName) -and $resolvedName -ne $expectedPackage) {
        throw 'The Slack plugin resolved npm package name did not match the reviewed package.'
    }
    $resolvedVersion = [string](Get-OpenClawObjectPropertyValue -InputObject $install -Name 'resolvedVersion')
    if (-not [string]::IsNullOrWhiteSpace($resolvedVersion) -and $resolvedVersion -ne $expectedVersion) {
        throw 'The Slack plugin resolved npm version did not match the reviewed version.'
    }
    $resolvedSpec = [string](Get-OpenClawObjectPropertyValue -InputObject $install -Name 'resolvedSpec')
    if (-not [string]::IsNullOrWhiteSpace($resolvedSpec) -and $resolvedSpec -ne $expectedSpec) {
        throw 'The Slack plugin resolved npm spec did not match the reviewed exact package.'
    }
    $installPath = [string](Get-OpenClawObjectPropertyValue -InputObject $install -Name 'installPath')
    $pluginRoot = [string](Get-OpenClawObjectPropertyValue -InputObject $plugin -Name 'rootDir')
    $activePluginPath = if ([string]::IsNullOrWhiteSpace($pluginRoot)) {
        [string](Get-OpenClawObjectPropertyValue -InputObject $plugin -Name 'source')
    }
    else {
        $pluginRoot
    }
    if ([string]::IsNullOrWhiteSpace($installPath) -or [string]::IsNullOrWhiteSpace($activePluginPath) -or
        -not (Test-OpenClawPathContainedBy -CandidatePath $activePluginPath -RootPath $installPath)) {
        throw 'The active Slack plugin source was not inside its recorded managed npm installation.'
    }

    return [pscustomobject]@{
        Ready = $true
        Id = $expectedId
        Package = $expectedPackage
        Version = $expectedVersion
        InstallSpec = $expectedSpec
        NpmIntegrity = $expectedIntegrity
        NpmShasum = $expectedShasum.ToLowerInvariant()
        InstallPath = [IO.Path]::GetFullPath($installPath)
    }
}

function Assert-OpenClawSlackPluginInspection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Inspection,

        [object]$SourceConfig = $(Get-OpenClawSourceConfig)
    )

    $verifiedProvenance = Assert-OpenClawSlackPluginProvenance -Inspection $Inspection -SourceConfig $SourceConfig
    $plugin = Get-OpenClawObjectPropertyValue -InputObject $Inspection -Name 'plugin'
    if ([string](Get-OpenClawObjectPropertyValue -InputObject $plugin -Name 'status') -ne 'loaded') {
        throw 'The exact Slack plugin was not loaded by runtime inspection.'
    }

    $capabilitiesValue = Get-OpenClawObjectPropertyValue -InputObject $Inspection -Name 'capabilities'
    $capabilities = @()
    if ($null -ne $capabilitiesValue) {
        $capabilities = @($capabilitiesValue)
    }
    $channelCapabilities = @($capabilities | Where-Object {
        [string](Get-OpenClawObjectPropertyValue -InputObject $_ -Name 'kind') -eq 'channel'
    })
    if ($channelCapabilities.Count -ne 1) {
        throw 'The Slack plugin runtime inspection did not contain one channel capability.'
    }
    $capabilityIdsValue = Get-OpenClawObjectPropertyValue -InputObject $channelCapabilities[0] -Name 'ids'
    $capabilityIds = @()
    if ($null -ne $capabilityIdsValue) {
        $capabilityIds = @($capabilityIdsValue)
    }
    if ($capabilityIds.Count -ne 1 -or [string]$capabilityIds[0] -ne [string]$SourceConfig.slackPlugin.id) {
        throw 'The Slack plugin runtime channel capability did not match the reviewed Slack id.'
    }
    return $verifiedProvenance
}

function ConvertTo-OpenClawWindowsCommandArgument {
    param(
        [AllowEmptyString()]
        [string]$Argument
    )

    if ($null -eq $Argument) {
        $Argument = ''
    }
    if ($Argument.Length -gt 32760) {
        throw 'An OpenClaw command argument exceeded the Windows limit.'
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

function Invoke-OpenClawCapturedCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Invocation,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [int]$TimeoutMilliseconds = 120000
    )

    $allArguments = @($Invocation.PrefixArguments) + @($Arguments)
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = [IO.Path]::GetFullPath([string]$Invocation.Executable)
    $startInfo.Arguments = (@($allArguments | ForEach-Object { ConvertTo-OpenClawWindowsCommandArgument -Argument ([string]$_) }) -join ' ')
    $startInfo.WorkingDirectory = $script:ProjectRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $utf8 = New-Object Text.UTF8Encoding($false)
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'The trusted OpenClaw command did not start.'
        }
        $standardOutput = $process.StandardOutput.ReadToEndAsync()
        $standardError = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            try { $process.Kill() } catch { }
            throw 'The trusted OpenClaw command timed out.'
        }
        $stdout = [string]$standardOutput.Result
        $stderr = [string]$standardError.Result
        if ($stdout.Length -gt 16MB -or $stderr.Length -gt 1MB) {
            throw 'The trusted OpenClaw command returned more output than allowed.'
        }
        return [pscustomobject]@{
            Arguments = @($Arguments)
            ExitCode = [int]$process.ExitCode
            Succeeded = $process.ExitCode -eq 0
            Stdout = $stdout
            SafeError = Protect-OpenClawLogText -Text $stderr -MaximumLength 2048
        }
    }
    finally {
        $process.Dispose()
    }
}

function ConvertFrom-OpenClawCommandJson {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Result,

        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    if (-not $Result.Succeeded) {
        throw ("OpenClaw {0} failed safely with exit code {1}." -f $Context, $Result.ExitCode)
    }
    if ([string]::IsNullOrWhiteSpace([string]$Result.Stdout)) {
        throw ("OpenClaw {0} returned no JSON." -f $Context)
    }
    try {
        return ([string]$Result.Stdout | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        throw ("OpenClaw {0} returned invalid JSON." -f $Context)
    }
}

function Get-OpenClawSlackPluginInventoryEntry {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Invocation,

        [Parameter(Mandatory = $true)]
        [object]$SourceConfig
    )

    $result = Invoke-OpenClawCapturedCommand -Invocation $Invocation -Arguments @('plugins', 'list', '--json')
    $inventory = ConvertFrom-OpenClawCommandJson -Result $result -Context 'plugin inventory'
    $pluginsProperty = $inventory.PSObject.Properties['plugins']
    if ($null -eq $pluginsProperty) {
        throw 'OpenClaw plugin inventory JSON did not contain a plugins array.'
    }
    $diagnosticsValue = Get-OpenClawObjectPropertyValue -InputObject $inventory -Name 'diagnostics'
    $diagnostics = @()
    if ($null -ne $diagnosticsValue) {
        $diagnostics = @($diagnosticsValue)
    }
    $registry = Get-OpenClawObjectPropertyValue -InputObject $inventory -Name 'registry'
    $registryDiagnosticsValue = Get-OpenClawObjectPropertyValue -InputObject $registry -Name 'diagnostics'
    $registryDiagnostics = @()
    if ($null -ne $registryDiagnosticsValue) {
        $registryDiagnostics = @($registryDiagnosticsValue)
    }
    if (@($diagnostics + $registryDiagnostics | Where-Object {
        [string](Get-OpenClawObjectPropertyValue -InputObject $_ -Name 'level') -eq 'error'
    }).Count -gt 0) {
        throw 'OpenClaw plugin inventory reported an error and could not establish safe absence.'
    }

    $pluginId = [string]$SourceConfig.slackPlugin.id
    $matches = @(@($pluginsProperty.Value) | Where-Object {
        [string](Get-OpenClawObjectPropertyValue -InputObject $_ -Name 'id') -eq $pluginId
    })
    if ($matches.Count -gt 1) {
        throw 'OpenClaw plugin inventory contained duplicate Slack plugin ids.'
    }
    if ($matches.Count -eq 0) {
        return $null
    }
    return $matches[0]
}

function Get-OpenClawSlackPluginInspection {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Invocation,

        [Parameter(Mandatory = $true)]
        [object]$SourceConfig
    )

    $pluginId = [string]$SourceConfig.slackPlugin.id
    $snapshotResult = Invoke-OpenClawCapturedCommand -Invocation $Invocation -Arguments @('plugins', 'inspect', $pluginId, '--json')
    $snapshotInspection = ConvertFrom-OpenClawCommandJson -Result $snapshotResult -Context 'Slack plugin snapshot inspection'
    [void](Assert-OpenClawSlackPluginProvenance -Inspection $snapshotInspection -SourceConfig $SourceConfig)

    $runtimeResult = Invoke-OpenClawCapturedCommand -Invocation $Invocation -Arguments @('plugins', 'inspect', $pluginId, '--runtime', '--json')
    $runtimeInspection = ConvertFrom-OpenClawCommandJson -Result $runtimeResult -Context 'Slack plugin runtime inspection'
    return Assert-OpenClawSlackPluginInspection -Inspection $runtimeInspection -SourceConfig $SourceConfig
}

function Ensure-OpenClawSlackPlugin {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)]
        [object]$SourceConfig,

        [string]$StateDirectory
    )

    Update-OpenClawProcessPath
    $invocation = Resolve-OpenClawInvocation -StateDirectory $StateDirectory
    if ($null -eq $invocation) {
        throw 'OpenClaw was not found before the official Slack plugin stage.'
    }

    $existing = Get-OpenClawSlackPluginInventoryEntry -Invocation $invocation -SourceConfig $SourceConfig
    if ($null -ne $existing) {
        $verified = Get-OpenClawSlackPluginInspection -Invocation $invocation -SourceConfig $SourceConfig
        return [pscustomobject]@{ Ready = $true; Changed = $false; Verification = $verified }
    }

    $installSpec = [string]$SourceConfig.slackPlugin.installSpec
    if (-not $PSCmdlet.ShouldProcess($installSpec, 'Install and provenance-check the exact official Slack plugin')) {
        return [pscustomobject]@{ Ready = $false; Changed = $false; Declined = $true }
    }
    $installResult = Invoke-OpenClawCapturedCommand -Invocation $invocation -Arguments @('plugins', 'install', $installSpec, '--pin') -TimeoutMilliseconds 300000
    if (-not $installResult.Succeeded) {
        throw ("The exact official Slack plugin installation failed safely with exit code {0}." -f $installResult.ExitCode)
    }
    $verified = Get-OpenClawSlackPluginInspection -Invocation $invocation -SourceConfig $SourceConfig
    return [pscustomobject]@{ Ready = $true; Changed = $true; Verification = $verified }
}

function Invoke-OpenClawSlackPluginWorkflowStage {
    param(
        [Parameter(Mandatory = $true)]
        [object]$SourceConfig,

        [string]$StateDirectory,

        [bool]$SuppressConfirmation,

        [bool]$ForceConfirmation
    )

    if ($SuppressConfirmation) {
        return Ensure-OpenClawSlackPlugin -SourceConfig $SourceConfig -StateDirectory $StateDirectory -Confirm:$false
    }
    if ($ForceConfirmation) {
        return Ensure-OpenClawSlackPlugin -SourceConfig $SourceConfig -StateDirectory $StateDirectory -Confirm:$true
    }
    return Ensure-OpenClawSlackPlugin -SourceConfig $SourceConfig -StateDirectory $StateDirectory
}

function Start-OpenClawOnboarding {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [string]$StateDirectory
    )

    Update-OpenClawProcessPath
    $openClawInvocation = Resolve-OpenClawInvocation -StateDirectory $StateDirectory
    if ($null -eq $openClawInvocation) {
        throw 'OpenClaw was not found on PATH. Open a new PowerShell window and run Configure again.'
    }

    if ($PSCmdlet.ShouldProcess('OpenClaw user configuration and Scheduled Task', 'Run official onboarding')) {
        $arguments = @($openClawInvocation.PrefixArguments) + @('onboard', '--install-daemon', '--secret-input-mode', 'ref')
        & $openClawInvocation.Executable @arguments
        if ($LASTEXITCODE -ne 0) {
            throw "OpenClaw onboarding failed with exit code $LASTEXITCODE."
        }
        return $true
    }
    return $false
}

function Invoke-OpenClawPinnedInstallerFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallerPath,

        [Parameter(Mandatory = $true)]
        [object]$SourceConfig,

        [switch]$DryRun,

        [switch]$RepairExactPackage
    )

    $processEnvironment = [Environment]::GetEnvironmentVariables('Process')
    $savedEnvironment = @{}
    foreach ($environmentName in $processEnvironment.Keys) {
        $savedEnvironment[[string]$environmentName] = [string]$processEnvironment[$environmentName]
    }
    $hostPath = (Get-Process -Id $PID).Path
    $nodeSnapshot = Get-OpenClawCommandSnapshot -Name 'node'
    if (-not $nodeSnapshot.Found -or -not $nodeSnapshot.Trusted -or $nodeSnapshot.ExitCode -ne 0 -or $null -eq $nodeSnapshot.Version -or -not (Test-OpenClawNodeVersion -Version $nodeSnapshot.Version).Supported) {
        throw 'A trusted, supported Node.js executable is required before launching the installer process.'
    }
    $gitSnapshot = Get-OpenClawCommandSnapshot -Name 'git'
    if (-not $gitSnapshot.Found -or -not $gitSnapshot.Trusted -or $gitSnapshot.ExitCode -ne 0 -or $null -eq $gitSnapshot.Version) {
        throw 'A trusted Git for Windows executable is required before launching the installer process.'
    }
    $npmSnapshot = Get-OpenClawCommandSnapshot -Name 'npm'
    if (-not $npmSnapshot.Found -or -not $npmSnapshot.Trusted -or $npmSnapshot.ExitCode -ne 0 -or $null -eq $npmSnapshot.Version) {
        throw 'A trusted npm command is required before launching the installer process.'
    }
    $nodeDirectory = Split-Path -Parent $nodeSnapshot.Path
    $gitDirectory = Split-Path -Parent $gitSnapshot.Path
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $safeWorkingDirectory = Join-Path $temporaryRoot ("OpenClawEasySetup-{0}" -f ([guid]::NewGuid().ToString('N')))
    $safeWorkingDirectory = [IO.Path]::GetFullPath($safeWorkingDirectory)
    $temporaryPrefix = $temporaryRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $safeWorkingDirectory.StartsWith($temporaryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The isolated installer working directory was outside the Windows temporary directory.'
    }
    [void][IO.Directory]::CreateDirectory($safeWorkingDirectory)
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        [void](Set-OpenClawPrivatePathAcl -Path $safeWorkingDirectory -Directory)
    }
    $emptyNpmConfig = Join-Path $safeWorkingDirectory 'empty.npmrc'
    $emptyGitConfig = Join-Path $safeWorkingDirectory 'empty.gitconfig'
    $safeNpmCache = Join-Path $safeWorkingDirectory 'npm-cache'
    [void][IO.Directory]::CreateDirectory($safeNpmCache)
    [IO.File]::WriteAllText($emptyNpmConfig, '', (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($emptyGitConfig, '', (New-Object Text.UTF8Encoding($false)))
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        [void](Set-OpenClawPrivatePathAcl -Path $safeNpmCache -Directory)
        [void](Set-OpenClawPrivatePathAcl -Path $emptyNpmConfig)
        [void](Set-OpenClawPrivatePathAcl -Path $emptyGitConfig)
    }

    foreach ($name in @($processEnvironment.Keys)) {
        [Environment]::SetEnvironmentVariable([string]$name, $null, 'Process')
    }

    try {
        foreach ($allowedName in @(
            'SystemRoot', 'WINDIR', 'TEMP', 'TMP', 'ComSpec', 'PATHEXT',
            'PROCESSOR_ARCHITECTURE', 'NUMBER_OF_PROCESSORS', 'LOCALAPPDATA',
            'APPDATA', 'ProgramFiles', 'ProgramFiles(x86)', 'ProgramData',
            'USERPROFILE', 'HOMEDRIVE', 'HOMEPATH'
        )) {
            if ($savedEnvironment.ContainsKey($allowedName)) {
                [Environment]::SetEnvironmentVariable($allowedName, $savedEnvironment[$allowedName], 'Process')
            }
        }
        $windowsDirectory = $savedEnvironment['SystemRoot']
        $safePath = @(
            $nodeDirectory,
            $gitDirectory,
            (Split-Path -Parent $hostPath),
            $(if ([string]::IsNullOrWhiteSpace($windowsDirectory)) { $null } else { Join-Path $windowsDirectory 'System32' }),
            $windowsDirectory,
            $(if ([string]::IsNullOrWhiteSpace($windowsDirectory)) { $null } else { Join-Path $windowsDirectory 'System32\Wbem' }),
            $(if ([string]::IsNullOrWhiteSpace($windowsDirectory)) { $null } else { Join-Path $windowsDirectory 'System32\WindowsPowerShell\v1.0' })
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
        [Environment]::SetEnvironmentVariable('Path', ($safePath -join ';'), 'Process')
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_REGISTRY', 'https://registry.npmjs.org/', 'Process')
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_USERCONFIG', $emptyNpmConfig, 'Process')
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_GLOBALCONFIG', $emptyNpmConfig, 'Process')
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_CACHE', $safeNpmCache, 'Process')
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_PREFER_OFFLINE', 'false', 'Process')
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_NOSYSTEM', '1', 'Process')
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_GLOBAL', $emptyGitConfig, 'Process')
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_COUNT', '0', 'Process')
        [Environment]::SetEnvironmentVariable('GIT_TERMINAL_PROMPT', '0', 'Process')
        [Environment]::SetEnvironmentVariable('GCM_INTERACTIVE', 'Never', 'Process')
        if ($RepairExactPackage -and -not $DryRun) {
            & $npmSnapshot.Path uninstall --global openclaw --ignore-scripts --no-audit --no-fund
            if ($LASTEXITCODE -ne 0) {
                throw "npm could not remove the unverified exact-version OpenClaw package before repair. Exit code: $LASTEXITCODE"
            }
        }
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

        Push-Location -LiteralPath $safeWorkingDirectory
        try {
            & $hostPath @arguments | Out-Host
            $installerExitCode = [int]$LASTEXITCODE
            return $installerExitCode
        }
        finally {
            Pop-Location
        }
    }
    finally {
        $currentEnvironment = [Environment]::GetEnvironmentVariables('Process')
        foreach ($name in @($currentEnvironment.Keys)) {
            [Environment]::SetEnvironmentVariable([string]$name, $null, 'Process')
        }
        foreach ($name in $savedEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable([string]$name, $savedEnvironment[$name], 'Process')
        }
        if (Test-Path -LiteralPath $safeWorkingDirectory -PathType Container) {
            $resolvedWorkingDirectory = (Resolve-Path -LiteralPath $safeWorkingDirectory).Path
            if ($resolvedWorkingDirectory.StartsWith($temporaryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $resolvedWorkingDirectory -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Install-OpenClawGitPrerequisite {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param()

    $sourceConfig = Get-OpenClawSourceConfig
    $currentGit = Get-OpenClawCommandSnapshot -Name 'git'
    if ($currentGit.Found -and $currentGit.Trusted -and $currentGit.ExitCode -eq 0 -and $null -ne $currentGit.Version) {
        Write-Host "Trusted Git for Windows is already available: $($currentGit.RawVersion)"
        return
    }

    $winget = Get-OpenClawCommandSnapshot -Name 'winget'
    if (-not $winget.Found -or -not $winget.Trusted -or $winget.ExitCode -ne 0) {
        throw 'WinGet was not found or trusted. Install or repair Microsoft App Installer before automatic Git provisioning.'
    }

    $packageTarget = "{0} {1}" -f $sourceConfig.git.winget.id, $sourceConfig.git.winget.version
    if (-not $PSCmdlet.ShouldProcess($packageTarget, 'Install the exact Git for Windows package from the WinGet source')) {
        return
    }

    $arguments = @(
        'install',
        '--id', [string]$sourceConfig.git.winget.id,
        '--exact',
        '--source', [string]$sourceConfig.git.winget.source,
        '--version', [string]$sourceConfig.git.winget.version,
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    )
    & $winget.Path @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "WinGet failed to install pinned Git for Windows with exit code $LASTEXITCODE."
    }

    Update-OpenClawProcessPath
    $installedGit = Get-OpenClawCommandSnapshot -Name 'git'
    $versionParts = ([string]$sourceConfig.git.winget.version).Split('.')
    $expectedRawVersion = 'git version {0}.{1}.{2}.windows.{3}' -f $versionParts[0], $versionParts[1], $versionParts[2], $versionParts[3]
    if (-not $installedGit.Found -or -not $installedGit.Trusted -or $installedGit.ExitCode -ne 0 -or $null -eq $installedGit.Version -or -not [string]::Equals($installedGit.RawVersion.Trim(), $expectedRawVersion, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Git provisioning did not produce pinned Git for Windows $($sourceConfig.git.winget.version)."
    }
}

function Install-OpenClawNodePrerequisite {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param()

    $sourceConfig = Get-OpenClawSourceConfig
    $targetNodeVersion = [version]$sourceConfig.node.winget.version
    $currentNode = Get-OpenClawCommandSnapshot -Name 'node'
    if ($currentNode.Found -and $currentNode.ExitCode -eq 0 -and $null -ne $currentNode.Version) {
        $support = Test-OpenClawNodeVersion -Version $currentNode.Version
        $currentNpm = Get-OpenClawCommandSnapshot -Name 'npm'
        if ($support.Supported -and $currentNpm.Found -and $currentNpm.Trusted -and $currentNpm.ExitCode -eq 0 -and $null -ne $currentNpm.Version) {
            Write-Host "Supported Node.js $($currentNode.Version) is already available."
            return
        }
    }

    $winget = Get-OpenClawCommandSnapshot -Name 'winget'
    if (-not $winget.Found -or -not $winget.Trusted -or $winget.ExitCode -ne 0) {
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
    if (-not $installedNode.Found -or $installedNode.ExitCode -ne 0 -or $null -eq $installedNode.Version -or $installedNode.Version -ne $targetNodeVersion) {
        throw "Node.js provisioning did not produce pinned version $targetNodeVersion."
    }

    $nodeSignature = Get-AuthenticodeSignature -LiteralPath $installedNode.Path
    if ($nodeSignature.Status -ne 'Valid') {
        throw "Pinned Node.js executable did not have a valid Authenticode signature: $($nodeSignature.Status)"
    }

    $npm = Get-OpenClawCommandSnapshot -Name 'npm'
    if (-not $npm.Found -or -not $npm.Trusted -or $npm.ExitCode -ne 0 -or $null -eq $npm.Version) {
        throw 'Pinned Node.js was installed, but npm was not available.'
    }
}

function Get-OpenClawResumePoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Checkpoint,

        [Parameter(Mandatory = $true)]
        [object]$Decision
    )

    if ([string]$Decision.Decision -ne 'AlreadyCurrent') {
        return 'Install'
    }
    $installStep = @($Checkpoint.Steps | Where-Object Id -eq 'install')
    if ($installStep.Count -ne 1 -or $installStep[0].Status -ne 'Succeeded') {
        return 'Install'
    }
    $onboardStep = @($Checkpoint.Steps | Where-Object Id -eq 'onboard')
    if ($onboardStep.Count -eq 1 -and $onboardStep[0].Status -eq 'Succeeded') {
        return 'Verify'
    }
    return 'Onboard'
}

function Remove-OpenClawInstallerBestEffort {
    [CmdletBinding()]
    param(
        [string]$Path,
        [string]$LogPath
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }
    try {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
    catch {
        if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
            try {
                Write-OpenClawLog -Path $LogPath -Level 'Warning' -Event 'installer.cleanup-failed' -Message 'The temporary installer could not be removed. Close programs using the file and remove it manually.'
            }
            catch {
                # Cleanup and cleanup logging are best effort and cannot replace the workflow result.
            }
        }
        Write-Warning '임시 설치 파일을 자동으로 지우지 못했습니다. 다른 프로그램이 파일을 사용 중이라면 닫은 뒤 직접 삭제하세요.'
    }
}

function Set-OpenClawCheckpointStepBestEffort {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Checkpoint,

        [Parameter(Mandatory = $true)]
        [ValidateSet('diagnose', 'node', 'download', 'integrity', 'dryRun', 'install', 'onboard', 'verify')]
        [string]$StepId,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Pending', 'Running', 'Succeeded', 'Failed', 'Skipped')]
        [string]$Status,

        [string]$Detail = ''
    )

    try {
        return Set-OpenClawCheckpointStep -Checkpoint $Checkpoint -StepId $StepId -Status $Status -Detail $Detail
    }
    catch {
        Write-Warning '복구 기록을 갱신하지 못했지만 원래 작업 결과와 오류 코드는 유지합니다.'
        return $Checkpoint
    }
}

function Install-OpenClawOfficial {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [switch]$KeepInstaller,
        [switch]$SkipOnboarding,
        [switch]$Resume,
        [switch]$InteractiveApproval,
        [string]$StateDirectory,
        [string]$LogPath,
        [string]$CancellationPath
    )

    if (-not (Test-OpenClawIsWindows)) {
        throw 'This installer MVP supports Windows only.'
    }

    $sourceConfig = Get-OpenClawSourceConfig
    $targetVersion = [version]$sourceConfig.openClaw.version
    $node = Get-OpenClawCommandSnapshot -Name 'node'
    $suppressNestedConfirmation = $InteractiveApproval -or $ConfirmPreference -eq 'None'
    $forceNestedConfirmation = $ConfirmPreference -eq 'Low'

    if ($WhatIfPreference) {
        $gitForPreview = Get-OpenClawCommandSnapshot -Name 'git'
        if (-not $gitForPreview.Found -or -not $gitForPreview.Trusted -or $gitForPreview.ExitCode -ne 0 -or $null -eq $gitForPreview.Version) {
            [void]$PSCmdlet.ShouldProcess(("{0} {1}" -f $sourceConfig.git.winget.id, $sourceConfig.git.winget.version), 'Install the exact Git for Windows package from the WinGet source')
        }
        $nodeRequiresProvisioning = -not $node.Found -or $node.ExitCode -ne 0 -or $null -eq $node.Version
        if (-not $nodeRequiresProvisioning) {
            $nodeRequiresProvisioning = -not (Test-OpenClawNodeVersion -Version $node.Version).Supported
        }
        if (-not $nodeRequiresProvisioning) {
            $npmForPreview = Get-OpenClawCommandSnapshot -Name 'npm'
            $nodeRequiresProvisioning = -not $npmForPreview.Found -or -not $npmForPreview.Trusted -or $npmForPreview.ExitCode -ne 0 -or $null -eq $npmForPreview.Version
        }
        if ($nodeRequiresProvisioning) {
            [void]$PSCmdlet.ShouldProcess(("{0} {1}" -f $sourceConfig.node.winget.id, $sourceConfig.node.winget.version), 'Install the exact Node.js package from the WinGet source')
        }
        [void]$PSCmdlet.ShouldProcess('This Windows user account', ("Install pinned OpenClaw {0}" -f $targetVersion))
        [void]$PSCmdlet.ShouldProcess([string]$sourceConfig.slackPlugin.installSpec, 'Install and provenance-check the exact official Slack plugin')
        return
    }

    $sourceFingerprint = (Get-FileHash -LiteralPath $script:DefaultSourceConfigPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($Resume) {
        $checkpoint = Get-OpenClawLatestCheckpoint -StateDirectory $StateDirectory -ExpectedTargetVersion $targetVersion.ToString() -ExpectedSourceFingerprint $sourceFingerprint
        if ($null -eq $checkpoint) {
            Write-Host (Get-OpenClawMessages).resumeNotFound -ForegroundColor Yellow
            throw (New-OpenClawTaggedException -Kind 'Resume' -Message 'No resumable installation checkpoint was found.')
        }
        Write-Host '중단된 설치를 찾았습니다. 현재 PC 상태를 다시 확인한 뒤 안전한 단계부터 이어갑니다.' -ForegroundColor Cyan
    }
    else {
        $checkpoint = New-OpenClawCheckpoint -StateDirectory $StateDirectory -TargetVersion $targetVersion.ToString() -SourceFingerprint $sourceFingerprint
    }
    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        Write-OpenClawLog -Path $LogPath -Level 'Info' -Event 'install.start' -Message 'OpenClaw installation workflow started.' -Data @{ targetVersion = $targetVersion.ToString(); resumed = [bool]$Resume }
    }

    Assert-OpenClawCancellationNotRequested -Path $CancellationPath -StateDirectory $StateDirectory
    $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'diagnose' -Status 'Running'
    $readiness = @(Get-OpenClawReadiness)
    $blockingReadiness = @($readiness | Where-Object { $_.Status -eq 'Fail' -and $_.Id -notin @('winget', 'git', 'node', 'npm', 'openclaw') })
    if ($blockingReadiness.Count -gt 0) {
        $checkpoint = Set-OpenClawCheckpointStepBestEffort -Checkpoint $checkpoint -StepId 'diagnose' -Status 'Failed' -Detail 'Blocking prerequisite.'
        throw (New-OpenClawTaggedException -Kind 'Prerequisite' -Message 'The read-only diagnosis found a blocking prerequisite.')
    }
    $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'diagnose' -Status 'Succeeded'
    Assert-OpenClawCancellationNotRequested -Path $CancellationPath -StateDirectory $StateDirectory

    $existing = Get-OpenClawCommandSnapshot -Name 'openclaw'
    $decision = Get-OpenClawInstallDecision -Snapshot $existing -TargetVersion $targetVersion
    Write-Host ("Existing installation decision: {0} - {1}" -f $decision.Decision, $decision.Reason)
    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        Write-OpenClawLog -Path $LogPath -Level 'Info' -Event 'install.decision' -Message $decision.Reason -Data @{ decision = $decision.Decision; targetVersion = $targetVersion.ToString() }
    }
    if ($decision.Decision -in @('UnknownBlocked', 'PrereleaseBlocked', 'AmbiguousBlocked', 'UntrustedBlocked')) {
        $checkpoint = Set-OpenClawCheckpointStepBestEffort -Checkpoint $checkpoint -StepId 'install' -Status 'Failed' -Detail $decision.Decision
        throw (New-OpenClawTaggedException -Kind 'Install' -Message 'The existing OpenClaw installation could not be handled automatically.')
    }
    $repairExactPackage = $false
    if ($decision.Decision -eq 'AlreadyCurrent') {
        $alreadyCurrentProvenance = Test-OpenClawProvenanceReceipt -Snapshot $existing -StateDirectory $StateDirectory
        if (-not $alreadyCurrentProvenance.Valid) {
            $repairExactPackage = $true
            Write-Host '동일 버전 설치의 무결성 영수증이 없어, 패키지 스크립트를 실행하지 않고 제거한 뒤 고정 버전으로 복구합니다.' -ForegroundColor Yellow
            if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
                Write-OpenClawLog -Path $LogPath -Level 'Warning' -Event 'install.repair-exact' -Message 'The existing exact-version package lacked a valid provenance receipt and will be safely reinstalled.'
            }
        }
    }

    $resumePoint = if ($Resume -and -not $repairExactPackage) { Get-OpenClawResumePoint -Checkpoint $checkpoint -Decision $decision } else { 'Install' }
    $resumeAfterInstalledStage = $Resume -and $resumePoint -in @('Onboard', 'Verify')
    $requiresInstall = (($decision.Decision -in @('FreshInstall', 'Upgrade')) -or $repairExactPackage) -and -not $resumeAfterInstalledStage

    if ($decision.Decision -eq 'KeepNewer') {
        $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'node' -Status 'Skipped' -Detail 'Newer existing version kept.'
        foreach ($skippedStage in @('download', 'integrity', 'dryRun')) {
            $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId $skippedStage -Status 'Skipped' -Detail $decision.Decision
        }
        $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'install' -Status 'Succeeded' -Detail $decision.Decision
        $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'onboard' -Status 'Skipped' -Detail 'Newer existing version kept; automatic execution skipped.'
        $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'verify' -Status 'Skipped' -Detail 'Run verification manually for the newer version.'
        if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
            Write-OpenClawLog -Path $LogPath -Level 'Warning' -Event 'install.keep-newer' -Message 'A newer existing OpenClaw version was kept without automatic execution.' -Data @{ decision = $decision.Decision }
        }
        return [pscustomobject]@{ Decision = $decision.Decision; TargetVersion = $targetVersion.ToString(); CheckpointPath = $checkpoint.Path; LogPath = $LogPath }
    }

    $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'node' -Status 'Running'
    $git = $null
    if ($requiresInstall) {
        $git = Get-OpenClawCommandSnapshot -Name 'git'
        if (-not $git.Found -or -not $git.Trusted -or $git.ExitCode -ne 0 -or $null -eq $git.Version) {
            try {
                if ($suppressNestedConfirmation) {
                    Install-OpenClawGitPrerequisite -Confirm:$false
                }
                elseif ($forceNestedConfirmation) {
                    Install-OpenClawGitPrerequisite -Confirm:$true
                }
                else {
                    Install-OpenClawGitPrerequisite
                }
            }
            catch {
                $checkpoint = Set-OpenClawCheckpointStepBestEffort -Checkpoint $checkpoint -StepId 'node' -Status 'Failed' -Detail 'Git for Windows provisioning failure.'
                if (-not $_.Exception.Data.Contains('OpenClawFailureKind')) {
                    $_.Exception.Data['OpenClawFailureKind'] = 'Prerequisite'
                }
                throw
            }
            $git = Get-OpenClawCommandSnapshot -Name 'git'
        }
        if (-not $git.Found -or -not $git.Trusted -or $git.ExitCode -ne 0 -or $null -eq $git.Version) {
            $checkpoint = Set-OpenClawCheckpointStepBestEffort -Checkpoint $checkpoint -StepId 'node' -Status 'Failed' -Detail 'Trusted Git for Windows unavailable.'
            throw (New-OpenClawTaggedException -Kind 'Prerequisite' -Message 'A trusted Git for Windows installation is required before OpenClaw installation.')
        }
    }

    $nodeRequiresProvisioning = -not $node.Found -or $node.ExitCode -ne 0 -or $null -eq $node.Version
    if (-not $nodeRequiresProvisioning) {
        $nodeRequiresProvisioning = -not (Test-OpenClawNodeVersion -Version $node.Version).Supported
    }
    if (-not $nodeRequiresProvisioning -and $requiresInstall) {
        $npmBeforeProvisioning = Get-OpenClawCommandSnapshot -Name 'npm'
        $nodeRequiresProvisioning = -not $npmBeforeProvisioning.Found -or -not $npmBeforeProvisioning.Trusted -or $npmBeforeProvisioning.ExitCode -ne 0 -or $null -eq $npmBeforeProvisioning.Version
    }
    if ($nodeRequiresProvisioning) {
        try {
            if ($suppressNestedConfirmation) {
                Install-OpenClawNodePrerequisite -Confirm:$false
            }
            elseif ($forceNestedConfirmation) {
                Install-OpenClawNodePrerequisite -Confirm:$true
            }
            else {
                Install-OpenClawNodePrerequisite
            }
        }
        catch {
            $checkpoint = Set-OpenClawCheckpointStepBestEffort -Checkpoint $checkpoint -StepId 'node' -Status 'Failed' -Detail 'Node.js provisioning failure.'
            if (-not $_.Exception.Data.Contains('OpenClawFailureKind')) {
                $_.Exception.Data['OpenClawFailureKind'] = 'Prerequisite'
            }
            throw
        }
        $node = Get-OpenClawCommandSnapshot -Name 'node'
    }
    if (-not $node.Found -or $node.ExitCode -ne 0 -or $null -eq $node.Version -or -not (Test-OpenClawNodeVersion -Version $node.Version).Supported) {
        $checkpoint = Set-OpenClawCheckpointStepBestEffort -Checkpoint $checkpoint -StepId 'node' -Status 'Failed' -Detail 'Node.js unavailable.'
        throw (New-OpenClawTaggedException -Kind 'Prerequisite' -Message 'A supported Node.js installation is required before OpenClaw installation.')
    }

    if ($requiresInstall) {
        $npm = Get-OpenClawCommandSnapshot -Name 'npm'
        if (-not $npm.Found -or -not $npm.Trusted -or $npm.ExitCode -ne 0 -or $null -eq $npm.Version) {
            $checkpoint = Set-OpenClawCheckpointStepBestEffort -Checkpoint $checkpoint -StepId 'node' -Status 'Failed' -Detail 'npm unavailable.'
            throw (New-OpenClawTaggedException -Kind 'Prerequisite' -Message 'npm was not found or did not return a valid version.')
        }
    }
    $nodeDetail = if ($requiresInstall) { "Git {0}; Node.js {1}" -f $git.Version, $node.Version } else { "Node.js {0}" -f $node.Version }
    $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'node' -Status 'Succeeded' -Detail $nodeDetail
    Assert-OpenClawCancellationNotRequested -Path $CancellationPath -StateDirectory $StateDirectory

    if (-not $requiresInstall) {
        if (-not $resumeAfterInstalledStage) {
            foreach ($skippedStage in @('download', 'integrity', 'dryRun')) {
                $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId $skippedStage -Status 'Skipped' -Detail $decision.Decision
            }
        }
        else {
            Write-Host '검증된 OpenClaw 설치 단계는 다시 실행하지 않고 다음 단계부터 이어갑니다.' -ForegroundColor Cyan
        }

        $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'install' -Status 'Running' -Detail 'Validating the exact official Slack plugin.'
        try {
            $slackPluginResult = Invoke-OpenClawSlackPluginWorkflowStage -SourceConfig $sourceConfig -StateDirectory $StateDirectory -SuppressConfirmation $suppressNestedConfirmation -ForceConfirmation $forceNestedConfirmation
        }
        catch {
            $checkpoint = Set-OpenClawCheckpointStepBestEffort -Checkpoint $checkpoint -StepId 'install' -Status 'Failed' -Detail 'Slack plugin provenance or installation failure.'
            if (-not $_.Exception.Data.Contains('OpenClawFailureKind')) {
                $_.Exception.Data['OpenClawFailureKind'] = 'Install'
            }
            throw
        }
        if ($null -eq $slackPluginResult -or -not $slackPluginResult.Ready) {
            $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'install' -Status 'Pending' -Detail 'Slack plugin installation confirmation was declined.'
            return [pscustomobject]@{ Decision = 'Cancelled'; TargetVersion = $targetVersion.ToString(); CheckpointPath = $checkpoint.Path; LogPath = $LogPath }
        }
        $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'install' -Status 'Succeeded' -Detail ("{0}; Slack plugin {1}" -f $decision.Decision, $sourceConfig.slackPlugin.version)
        Assert-OpenClawCancellationNotRequested -Path $CancellationPath -StateDirectory $StateDirectory

        $priorOnboarding = @($checkpoint.Steps | Where-Object { $_.Id -eq 'onboard' -and $_.Status -eq 'Succeeded' })
        if ($SkipOnboarding -and $resumePoint -ne 'Verify') {
            $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'onboard' -Status 'Skipped' -Detail 'Explicitly skipped by user.'
            $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'verify' -Status 'Skipped' -Detail 'Run Verify after configuration.'
        }
        elseif (-not ($Resume -and $priorOnboarding.Count -gt 0)) {
            $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'onboard' -Status 'Running'
            try {
                if ($suppressNestedConfirmation) {
                    $onboardingCompleted = Start-OpenClawOnboarding -StateDirectory $StateDirectory -Confirm:$false
                }
                elseif ($forceNestedConfirmation) {
                    $onboardingCompleted = Start-OpenClawOnboarding -StateDirectory $StateDirectory -Confirm:$true
                }
                else {
                    $onboardingCompleted = Start-OpenClawOnboarding -StateDirectory $StateDirectory
                }
            }
            catch {
                $checkpoint = Set-OpenClawCheckpointStepBestEffort -Checkpoint $checkpoint -StepId 'onboard' -Status 'Failed' -Detail 'Onboarding failure.'
                if (-not $_.Exception.Data.Contains('OpenClawFailureKind')) {
                    $_.Exception.Data['OpenClawFailureKind'] = 'Configure'
                }
                throw
            }
            if (-not $onboardingCompleted) {
                $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'onboard' -Status 'Pending' -Detail 'Onboarding confirmation was declined.'
                return [pscustomobject]@{ Decision = 'Cancelled'; TargetVersion = $targetVersion.ToString(); CheckpointPath = $checkpoint.Path; LogPath = $LogPath }
            }
            $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'onboard' -Status 'Succeeded'
            Assert-OpenClawCancellationNotRequested -Path $CancellationPath -StateDirectory $StateDirectory
            $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'verify' -Status 'Running'
            try {
                $verification = @(Invoke-OpenClawVerification -StateDirectory $StateDirectory)
            }
            catch {
                $checkpoint = Set-OpenClawCheckpointStepBestEffort -Checkpoint $checkpoint -StepId 'verify' -Status 'Failed' -Detail 'Verification invocation failure.'
                if (-not $_.Exception.Data.Contains('OpenClawFailureKind')) {
                    $_.Exception.Data['OpenClawFailureKind'] = 'Verify'
                }
                throw
            }
            if (@($verification | Where-Object Passed -eq $false).Count -gt 0) {
                $checkpoint = Set-OpenClawCheckpointStepBestEffort -Checkpoint $checkpoint -StepId 'verify' -Status 'Failed' -Detail 'Verification failure.'
                throw (New-OpenClawTaggedException -Kind 'Verify' -Message 'One or more OpenClaw verification steps failed.')
            }
            $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'verify' -Status 'Succeeded'
        }
        else {
            Assert-OpenClawCancellationNotRequested -Path $CancellationPath -StateDirectory $StateDirectory
            $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'verify' -Status 'Running'
            try {
                $verification = @(Invoke-OpenClawVerification -StateDirectory $StateDirectory)
            }
            catch {
                $checkpoint = Set-OpenClawCheckpointStepBestEffort -Checkpoint $checkpoint -StepId 'verify' -Status 'Failed' -Detail 'Verification invocation failure.'
                if (-not $_.Exception.Data.Contains('OpenClawFailureKind')) {
                    $_.Exception.Data['OpenClawFailureKind'] = 'Verify'
                }
                throw
            }
            if (@($verification | Where-Object Passed -eq $false).Count -gt 0) {
                $checkpoint = Set-OpenClawCheckpointStepBestEffort -Checkpoint $checkpoint -StepId 'verify' -Status 'Failed' -Detail 'Verification failure.'
                throw (New-OpenClawTaggedException -Kind 'Verify' -Message 'One or more OpenClaw verification steps failed.')
            }
            $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'verify' -Status 'Succeeded'
        }
        if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
            Write-OpenClawLog -Path $LogPath -Level 'Info' -Event 'install.success' -Message 'OpenClaw installation workflow completed without replacing the existing version.' -Data @{ decision = $decision.Decision }
        }
        return [pscustomobject]@{ Decision = $decision.Decision; TargetVersion = $targetVersion.ToString(); CheckpointPath = $checkpoint.Path; LogPath = $LogPath }
    }

    if (-not $PSCmdlet.ShouldProcess('This Windows user account', ("Download pinned OpenClaw {0} installer" -f $targetVersion))) {
        return
    }

    Assert-OpenClawCancellationNotRequested -Path $CancellationPath -StateDirectory $StateDirectory
    $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'download' -Status 'Running'
    try {
        $artifact = Save-OpenClawInstaller -SourceConfig $sourceConfig
    }
    catch {
        if ($_.Exception.Data.Contains('OpenClawFailureKind') -and [string]$_.Exception.Data['OpenClawFailureKind'] -eq 'Integrity') {
            $checkpoint = Set-OpenClawCheckpointStepBestEffort -Checkpoint $checkpoint -StepId 'download' -Status 'Succeeded' -Detail 'Response received.'
            $checkpoint = Set-OpenClawCheckpointStepBestEffort -Checkpoint $checkpoint -StepId 'integrity' -Status 'Failed' -Detail 'Integrity validation failure.'
        }
        else {
            $checkpoint = Set-OpenClawCheckpointStepBestEffort -Checkpoint $checkpoint -StepId 'download' -Status 'Failed' -Detail 'Download or source validation failure.'
            $_.Exception.Data['OpenClawFailureKind'] = 'Download'
        }
        throw
    }
    try {
        $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'download' -Status 'Succeeded'
        $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'integrity' -Status 'Succeeded' -Detail ("SHA-256 {0}" -f $artifact.Sha256)
        Write-Host ("Installer source: {0}" -f $artifact.SourceUri)
        Write-Host ("Installer SHA-256: {0}" -f $artifact.Sha256)
        Write-Host ("Authenticode status: {0}" -f $artifact.SignatureStatus)

        Assert-OpenClawCancellationNotRequested -Path $CancellationPath -StateDirectory $StateDirectory
        $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'dryRun' -Status 'Running'
        try {
            $dryRunExitCode = Invoke-OpenClawPinnedInstallerFile -InstallerPath $artifact.Path -SourceConfig $sourceConfig -DryRun
        }
        catch {
            $checkpoint = Set-OpenClawCheckpointStepBestEffort -Checkpoint $checkpoint -StepId 'dryRun' -Status 'Failed' -Detail 'Dry-run invocation failure.'
            if (-not $_.Exception.Data.Contains('OpenClawFailureKind')) {
                $_.Exception.Data['OpenClawFailureKind'] = 'Install'
            }
            throw
        }
        if ($dryRunExitCode -ne 0) {
            $checkpoint = Set-OpenClawCheckpointStepBestEffort -Checkpoint $checkpoint -StepId 'dryRun' -Status 'Failed' -Detail ("Exit code {0}" -f $dryRunExitCode)
            throw (New-OpenClawTaggedException -Kind 'Install' -Message "The pinned OpenClaw installer dry-run failed with exit code $dryRunExitCode.")
        }
        $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'dryRun' -Status 'Succeeded'

        Assert-OpenClawCancellationNotRequested -Path $CancellationPath -StateDirectory $StateDirectory
        $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'install' -Status 'Running'
        if ($PSCmdlet.ShouldProcess($artifact.Path, ("Install pinned OpenClaw {0}" -f $targetVersion))) {
            try {
                $installExitCode = Invoke-OpenClawPinnedInstallerFile -InstallerPath $artifact.Path -SourceConfig $sourceConfig -RepairExactPackage:$repairExactPackage
            }
            catch {
                $checkpoint = Set-OpenClawCheckpointStepBestEffort -Checkpoint $checkpoint -StepId 'install' -Status 'Failed' -Detail 'Installer invocation failure.'
                if (-not $_.Exception.Data.Contains('OpenClawFailureKind')) {
                    $_.Exception.Data['OpenClawFailureKind'] = 'Install'
                }
                throw
            }
            if ($installExitCode -ne 0) {
                $checkpoint = Set-OpenClawCheckpointStepBestEffort -Checkpoint $checkpoint -StepId 'install' -Status 'Failed' -Detail ("Exit code {0}" -f $installExitCode)
                throw (New-OpenClawTaggedException -Kind 'Install' -Message "The pinned OpenClaw installer failed with exit code $installExitCode.")
            }

            Update-OpenClawProcessPath
            $installed = Get-OpenClawCommandSnapshot -Name 'openclaw'
            if (-not $installed.Found -or -not $installed.Trusted -or $installed.Ambiguous -or $installed.ExitCode -ne 0 -or $null -eq $installed.Version -or $installed.Version -ne $targetVersion) {
                $checkpoint = Set-OpenClawCheckpointStepBestEffort -Checkpoint $checkpoint -StepId 'install' -Status 'Failed' -Detail 'Postcondition failure.'
                throw (New-OpenClawTaggedException -Kind 'Install' -Message "Installed OpenClaw version did not match pinned target $targetVersion.")
            }
            try {
                [void](Write-OpenClawProvenanceReceipt -Snapshot $installed -TargetVersion $targetVersion -SourceFingerprint $sourceFingerprint -StateDirectory $StateDirectory)
            }
            catch {
                $checkpoint = Set-OpenClawCheckpointStepBestEffort -Checkpoint $checkpoint -StepId 'install' -Status 'Failed' -Detail 'Provenance receipt failure.'
                throw (New-OpenClawTaggedException -Kind 'Install' -Message 'The installed OpenClaw files could not be recorded for safe later execution.')
            }
            try {
                $slackPluginResult = Invoke-OpenClawSlackPluginWorkflowStage -SourceConfig $sourceConfig -StateDirectory $StateDirectory -SuppressConfirmation $suppressNestedConfirmation -ForceConfirmation $forceNestedConfirmation
            }
            catch {
                $checkpoint = Set-OpenClawCheckpointStepBestEffort -Checkpoint $checkpoint -StepId 'install' -Status 'Failed' -Detail 'Slack plugin provenance or installation failure.'
                if (-not $_.Exception.Data.Contains('OpenClawFailureKind')) {
                    $_.Exception.Data['OpenClawFailureKind'] = 'Install'
                }
                throw
            }
            if ($null -eq $slackPluginResult -or -not $slackPluginResult.Ready) {
                $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'install' -Status 'Pending' -Detail 'Slack plugin installation confirmation was declined.'
                return [pscustomobject]@{ Decision = 'Cancelled'; TargetVersion = $targetVersion.ToString(); CheckpointPath = $checkpoint.Path; LogPath = $LogPath }
            }
            $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'install' -Status 'Succeeded' -Detail ("OpenClaw {0}; Slack plugin {1}" -f $installed.Version, $sourceConfig.slackPlugin.version)
            Assert-OpenClawCancellationNotRequested -Path $CancellationPath -StateDirectory $StateDirectory

            if ($SkipOnboarding) {
                $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'onboard' -Status 'Skipped' -Detail 'Explicitly skipped by user.'
                $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'verify' -Status 'Skipped' -Detail 'Run Verify after configuration.'
            }
            else {
                $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'onboard' -Status 'Running'
                try {
                    if ($suppressNestedConfirmation) {
                        $onboardingCompleted = Start-OpenClawOnboarding -StateDirectory $StateDirectory -Confirm:$false
                    }
                    elseif ($forceNestedConfirmation) {
                        $onboardingCompleted = Start-OpenClawOnboarding -StateDirectory $StateDirectory -Confirm:$true
                    }
                    else {
                        $onboardingCompleted = Start-OpenClawOnboarding -StateDirectory $StateDirectory
                    }
                }
                catch {
                    $checkpoint = Set-OpenClawCheckpointStepBestEffort -Checkpoint $checkpoint -StepId 'onboard' -Status 'Failed' -Detail 'Onboarding failure.'
                    if (-not $_.Exception.Data.Contains('OpenClawFailureKind')) {
                        $_.Exception.Data['OpenClawFailureKind'] = 'Configure'
                    }
                    throw
                }
                if (-not $onboardingCompleted) {
                    $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'onboard' -Status 'Pending' -Detail 'Onboarding confirmation was declined.'
                    return [pscustomobject]@{ Decision = 'Cancelled'; TargetVersion = $targetVersion.ToString(); CheckpointPath = $checkpoint.Path; LogPath = $LogPath }
                }
                $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'onboard' -Status 'Succeeded'
                Assert-OpenClawCancellationNotRequested -Path $CancellationPath -StateDirectory $StateDirectory
                $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'verify' -Status 'Running'
                try {
                    $verification = @(Invoke-OpenClawVerification -StateDirectory $StateDirectory)
                }
                catch {
                    $checkpoint = Set-OpenClawCheckpointStepBestEffort -Checkpoint $checkpoint -StepId 'verify' -Status 'Failed' -Detail 'Verification invocation failure.'
                    if (-not $_.Exception.Data.Contains('OpenClawFailureKind')) {
                        $_.Exception.Data['OpenClawFailureKind'] = 'Verify'
                    }
                    throw
                }
                if (@($verification | Where-Object Passed -eq $false).Count -gt 0) {
                    $checkpoint = Set-OpenClawCheckpointStepBestEffort -Checkpoint $checkpoint -StepId 'verify' -Status 'Failed' -Detail 'Verification failure.'
                    throw (New-OpenClawTaggedException -Kind 'Verify' -Message 'One or more OpenClaw verification steps failed.')
                }
                $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'verify' -Status 'Succeeded'
            }
        }
        else {
            $checkpoint = Set-OpenClawCheckpointStep -Checkpoint $checkpoint -StepId 'install' -Status 'Pending' -Detail 'Installation confirmation was declined.'
            return [pscustomobject]@{ Decision = 'Cancelled'; TargetVersion = $targetVersion.ToString(); CheckpointPath = $checkpoint.Path; LogPath = $LogPath }
        }
        if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
            Write-OpenClawLog -Path $LogPath -Level 'Info' -Event 'install.success' -Message 'OpenClaw installation workflow completed.' -Data @{ decision = $decision.Decision; targetVersion = $targetVersion.ToString() }
        }
        return [pscustomobject]@{ Decision = $decision.Decision; TargetVersion = $targetVersion.ToString(); CheckpointPath = $checkpoint.Path; LogPath = $LogPath }
    }
    finally {
        if (-not $KeepInstaller -and (Test-Path -LiteralPath $artifact.Path)) {
            Remove-OpenClawInstallerBestEffort -Path $artifact.Path -LogPath $LogPath
        }
    }
}

function Invoke-OpenClawVerification {
    [CmdletBinding()]
    param(
        [string]$StateDirectory
    )

    Update-OpenClawProcessPath
    $openClawInvocation = Resolve-OpenClawInvocation -StateDirectory $StateDirectory
    if ($null -eq $openClawInvocation) {
        throw 'OpenClaw was not found on PATH.'
    }

    Write-Host 'Running: Slack plugin provenance' -ForegroundColor Cyan
    $slackPluginVerification = try {
        $sourceConfig = Get-OpenClawSourceConfig
        [void](Get-OpenClawSlackPluginInspection -Invocation $openClawInvocation -SourceConfig $sourceConfig)
        [pscustomobject]@{ Name = 'Slack plugin provenance'; ExitCode = 0; Passed = $true }
    }
    catch {
        Write-Warning (Protect-OpenClawLogText -Text $_.Exception.Message -MaximumLength 2048)
        [pscustomobject]@{ Name = 'Slack plugin provenance'; ExitCode = 1; Passed = $false }
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
        $arguments = @($openClawInvocation.PrefixArguments) + @($step.Arguments)
        & $openClawInvocation.Executable @arguments
        [pscustomobject]@{
            Name = $step.Name
            ExitCode = $LASTEXITCODE
            Passed = $LASTEXITCODE -eq 0
        }
    }

    return @($slackPluginVerification) + @($results)
}

Export-ModuleMember -Function @(
    'Get-OpenClawExitCodeDefinition',
    'Resolve-OpenClawFailure',
    'Protect-OpenClawLogText',
    'Initialize-OpenClawStateDirectory',
    'New-OpenClawLog',
    'Write-OpenClawLog',
    'New-OpenClawCheckpoint',
    'Read-OpenClawCheckpoint',
    'Get-OpenClawLatestCheckpoint',
    'Set-OpenClawCheckpointStep',
    'New-OpenClawCancellationPath',
    'Request-OpenClawCancellation',
    'Test-OpenClawCancellationRequested',
    'Remove-OpenClawCancellationSignal',
    'Get-OpenClawInstallDecision',
    'Export-OpenClawDiagnosticBundle',
    'ConvertTo-OpenClawVersion',
    'Get-OpenClawSourceConfig',
    'Enter-OpenClawSourceConfigReadLock',
    'Test-OpenClawUriAllowed',
    'Test-OpenClawNodeVersion',
    'Test-OpenClawIsWindows',
    'Get-OpenClawReadiness',
    'Show-OpenClawReadiness',
    'Get-OpenClawInstallPlan',
    'Get-OpenClawPlanFingerprint',
    'Show-OpenClawInstallPlan',
    'Save-OpenClawInstaller',
    'Install-OpenClawGitPrerequisite',
    'Install-OpenClawNodePrerequisite',
    'Update-OpenClawProcessPath',
    'Resolve-OpenClawInvocation',
    'Assert-OpenClawSlackPluginProvenance',
    'Assert-OpenClawSlackPluginInspection',
    'Get-OpenClawSlackPluginInspection',
    'Start-OpenClawOnboarding',
    'Install-OpenClawOfficial',
    'Invoke-OpenClawVerification'
)
