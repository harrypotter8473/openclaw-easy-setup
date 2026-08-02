Set-StrictMode -Version Latest

$script:RecoverySchemaVersion = 1
$script:RecoveryToolVersion = '0.2.0'
$script:InstallStageIds = @('diagnose', 'node', 'download', 'integrity', 'dryRun', 'install', 'onboard', 'verify')
$script:ExitCodeDefinitions = @{
    Success = [pscustomobject]@{ Kind = 'Success'; Id = 'OCES-SUCCESS'; ExitCode = 0; Message = '작업을 완료했습니다.'; Guidance = '' }
    Warning = [pscustomobject]@{ Kind = 'Warning'; Id = 'OCES-DIAG-WARN'; ExitCode = 10; Message = '확인이 필요한 진단 항목이 있습니다.'; Guidance = '화면의 안내를 확인하세요.' }
    Diagnose = [pscustomobject]@{ Kind = 'Diagnose'; Id = 'OCES-DIAG-001'; ExitCode = 20; Message = 'PC 준비 상태에서 차단 항목을 찾았습니다.'; Guidance = '차단 항목의 해결 안내를 확인하세요.' }
    Download = [pscustomobject]@{ Kind = 'Download'; Id = 'OCES-DOWNLOAD-001'; ExitCode = 30; Message = '공식 설치 파일을 안전하게 내려받지 못했습니다.'; Guidance = '인터넷 연결을 확인한 뒤 이전 설치 이어하기를 선택하세요.' }
    Integrity = [pscustomobject]@{ Kind = 'Integrity'; Id = 'OCES-INTEGRITY-001'; ExitCode = 31; Message = '설치 파일의 무결성 검증을 통과하지 못했습니다.'; Guidance = '파일을 실행하지 않았습니다. 잠시 뒤 다시 시도하세요.' }
    Prerequisite = [pscustomobject]@{ Kind = 'Prerequisite'; Id = 'OCES-PREREQ-001'; ExitCode = 40; Message = '필수 준비 프로그램을 사용할 수 없습니다.'; Guidance = 'WinGet 또는 Node.js 안내를 확인한 뒤 다시 시도하세요.' }
    Install = [pscustomobject]@{ Kind = 'Install'; Id = 'OCES-INSTALL-001'; ExitCode = 41; Message = 'OpenClaw 설치를 완료하지 못했습니다.'; Guidance = '문제를 해결한 뒤 이전 설치 이어하기를 선택하세요.' }
    Configure = [pscustomobject]@{ Kind = 'Configure'; Id = 'OCES-CONFIG-001'; ExitCode = 42; Message = 'OpenClaw 설정을 완료하지 못했습니다.'; Guidance = '공식 설정 화면을 다시 시작하세요.' }
    Verify = [pscustomobject]@{ Kind = 'Verify'; Id = 'OCES-VERIFY-001'; ExitCode = 50; Message = '설치 후 상태 확인을 통과하지 못했습니다.'; Guidance = '문제 해결 파일을 만든 뒤 오류 코드를 함께 확인하세요.' }
    Resume = [pscustomobject]@{ Kind = 'Resume'; Id = 'OCES-RESUME-001'; ExitCode = 60; Message = '이전 설치 기록을 안전하게 이어갈 수 없습니다.'; Guidance = '새 설치를 시작하거나 문제 해결 파일을 만드세요.' }
    Bundle = [pscustomobject]@{ Kind = 'Bundle'; Id = 'OCES-BUNDLE-001'; ExitCode = 70; Message = '문제 해결 파일을 만들지 못했습니다.'; Guidance = '저장 위치와 디스크 여유 공간을 확인하세요.' }
    Unexpected = [pscustomobject]@{ Kind = 'Unexpected'; Id = 'OCES-UNEXPECTED-001'; ExitCode = 99; Message = '예상하지 못한 내부 오류가 발생했습니다.'; Guidance = '문제 해결 파일과 오류 코드를 개발자에게 알려주세요.' }
}

function Get-OpenClawExitCodeDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Success', 'Warning', 'Diagnose', 'Download', 'Integrity', 'Prerequisite', 'Install', 'Configure', 'Verify', 'Resume', 'Bundle', 'Unexpected')]
        [string]$Kind
    )

    $definition = $script:ExitCodeDefinitions[$Kind]
    return [pscustomobject]@{
        Kind = $definition.Kind
        Id = $definition.Id
        ExitCode = $definition.ExitCode
        Message = $definition.Message
        Guidance = $definition.Guidance
    }
}

function Resolve-OpenClawFailure {
    [CmdletBinding()]
    param(
        [ValidateSet('Menu', 'Diagnose', 'Plan', 'Install', 'Configure', 'Verify', 'Bundle')]
        [string]$Action = 'Menu',

        [Exception]$Exception
    )

    $kind = $null
    if ($null -ne $Exception -and $Exception.Data.Contains('OpenClawFailureKind')) {
        $candidate = [string]$Exception.Data['OpenClawFailureKind']
        if ($script:ExitCodeDefinitions.ContainsKey($candidate)) {
            $kind = $candidate
        }
    }

    if ([string]::IsNullOrWhiteSpace($kind)) {
        $kind = switch ($Action) {
            'Diagnose' { 'Diagnose' }
            'Install' { 'Install' }
            'Configure' { 'Configure' }
            'Verify' { 'Verify' }
            'Bundle' { 'Bundle' }
            default { 'Unexpected' }
        }
    }

    return Get-OpenClawExitCodeDefinition -Kind $kind
}

function Protect-OpenClawLogText {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Text,

        [ValidateRange(16, 8192)]
        [int]$MaximumLength = 2048
    )

    if ($null -eq $Text) {
        return ''
    }

    $safe = [string]$Text
    $safe = [regex]::Replace($safe, '\x1B\[[0-?]*[ -/]*[@-~]', '')
    $safe = [regex]::Replace($safe, '(?is)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----', '<PRIVATE_KEY_REDACTED>')
    $safe = [regex]::Replace($safe, '(?i)(Authorization\s*[:=]\s*Bearer\s+)[^\s,;]+', '$1<REDACTED>')
    $safe = [regex]::Replace($safe, '(?i)(Authorization\s*[:=]\s*Basic\s+)[A-Za-z0-9+/=]+', '$1<REDACTED>')
    $safe = [regex]::Replace($safe, '(?i)(--(?:token|api[-_]?key|password|secret)\s+)[^\s]+', '$1<REDACTED>')
    $safe = [regex]::Replace($safe, '(?i)(["''](?:token|secret|password|passphrase|authorization|api[-_]?key|access[-_]?token|private[-_]?key|cookie)["'']\s*:\s*["''])[^"'']*(["''])', '$1<REDACTED>$2')
    $safe = [regex]::Replace($safe, '(?i)(\b(?:token|secret|password|passphrase|authorization|api[-_]?key|access[-_]?token|private[-_]?key|cookie)\b\s*["'']?\s*[:=]\s*["'']?)[^,\s;"''}]+', '$1<REDACTED>')
    $safe = [regex]::Replace($safe, '(?i)(\b[A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASSPHRASE|AUTHORIZATION|API_KEY|PRIVATE_KEY|ACCESS_KEY)[A-Z0-9_]*\b\s*[:=]\s*["'']?)[^,\s;"''}]+', '$1<REDACTED>')
    $safe = [regex]::Replace($safe, '(?i)\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{16,}|sk_live_[A-Za-z0-9]{16,}|npm_[A-Za-z0-9]{20,}|mfa\.[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{16,}|xapp-[A-Za-z0-9-]{16,}|AIza[A-Za-z0-9_-]{30,}|(?:AKIA|ASIA)[A-Z0-9]{16})\b', '<TOKEN_REDACTED>')
    $safe = [regex]::Replace($safe, '\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b', '<JWT_REDACTED>')
    $safe = [regex]::Replace($safe, '\b\d{6,}:[A-Za-z0-9_-]{20,}\b', '<BOT_TOKEN_REDACTED>')
    $safe = [regex]::Replace($safe, '(?i)(https://)[^/\s:@]+:[^/\s@]+@', '$1<REDACTED>@')
    $safe = [regex]::Replace($safe, '(?i)(https://[^\s?#]+)\?[^\s#]+', '$1?<QUERY_REDACTED>')
    $safe = [regex]::Replace($safe, '(?i)(https://[^\s#]+)#[^\s]+', '$1#<FRAGMENT_REDACTED>')
    $safe = [regex]::Replace($safe, '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b', '<EMAIL_REDACTED>')

    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $safe = [regex]::Replace($safe, [regex]::Escape($env:USERPROFILE), '%USERPROFILE%', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    $safe = [regex]::Replace($safe, '(?i)\b[A-Z]:\\Users\\[^\\\s]+', '%USERPROFILE%')
    $safe = [regex]::Replace($safe, '(?i)(?<![A-Za-z0-9_])/home/[^/\s]+', '%USERPROFILE%')
    if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME) -and $env:COMPUTERNAME.Length -ge 3) {
        $safe = [regex]::Replace($safe, ('\b{0}\b' -f [regex]::Escape($env:COMPUTERNAME)), '[HOST]', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }

    $safe = [regex]::Replace($safe, '[\r\n\t]+', ' ')
    $safe = [regex]::Replace($safe, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '')
    $safe = $safe.Trim()
    if ($safe.Length -gt $MaximumLength) {
        $safe = $safe.Substring(0, $MaximumLength) + ' [TRUNCATED]'
    }
    return $safe
}

function Set-OpenClawPrivatePathAcl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [switch]$Directory
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        return $false
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $systemSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $existingSecurity = Get-Acl -LiteralPath $Path
    $ownerSid = $existingSecurity.GetOwner([Security.Principal.SecurityIdentifier])
    $accessRules = @($existingSecurity.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    $allowedSids = @($identity.User.Value, $systemSid.Value)
    $unexpectedAllowRule = @($accessRules | Where-Object {
        $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
        $_.IdentityReference.Value -notin $allowedSids
    }).Count -gt 0
    $hasUserControl = @($accessRules | Where-Object {
        $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
        $_.IdentityReference.Value -eq $identity.User.Value -and
        ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl
    }).Count -gt 0
    if ($ownerSid.Value -eq $identity.User.Value -and -not $unexpectedAllowRule -and $hasUserControl -and $existingSecurity.AreAccessRulesProtected) {
        return $true
    }

    $privateSecurity = if ($Directory) {
        New-Object Security.AccessControl.DirectorySecurity
    }
    else {
        New-Object Security.AccessControl.FileSecurity
    }
    $privateSecurity.SetOwner($identity.User)
    $privateSecurity.SetAccessRuleProtection($true, $false)
    $inheritance = if ($Directory) { [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit' } else { [Security.AccessControl.InheritanceFlags]::None }
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $userRule = New-Object Security.AccessControl.FileSystemAccessRule($identity.User, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance, $propagation, $allow)
    $systemRule = New-Object Security.AccessControl.FileSystemAccessRule($systemSid, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance, $propagation, $allow)
    [void]$privateSecurity.AddAccessRule($userRule)
    [void]$privateSecurity.AddAccessRule($systemRule)
    Set-Acl -LiteralPath $Path -AclObject $privateSecurity
    return $true
}

function Initialize-OpenClawStateDirectory {
    [CmdletBinding()]
    param(
        [string]$Path
    )

    $usingDefaultPath = [string]::IsNullOrWhiteSpace($Path)
    if ($usingDefaultPath) {
        $localApplicationData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        if ([string]::IsNullOrWhiteSpace($localApplicationData)) {
            throw 'The current user LocalApplicationData directory could not be determined.'
        }
        $Path = Join-Path $localApplicationData 'OpenClawEasySetup'
    }

    $root = [IO.Path]::GetFullPath($Path)
    $pathRoot = [IO.Path]::GetPathRoot($root)
    if ($root.TrimEnd('\', '/') -eq $pathRoot.TrimEnd('\', '/')) {
        throw 'The state directory cannot be a filesystem root.'
    }

    $protectedRoots = New-Object System.Collections.Generic.List[string]
    foreach ($protectedCandidate in @(
        $env:USERPROFILE,
        $env:LOCALAPPDATA,
        $env:APPDATA,
        $env:SystemRoot,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        [IO.Path]::GetTempPath(),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
    )) {
        if (-not [string]::IsNullOrWhiteSpace($protectedCandidate)) {
            $protectedRoots.Add(([IO.Path]::GetFullPath($protectedCandidate)).TrimEnd('\', '/'))
        }
    }
    if (@($protectedRoots | Where-Object { [string]::Equals($root.TrimEnd('\', '/'), $_, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
        throw 'The state directory must be a dedicated subdirectory, not a profile, system, or shared root.'
    }

    $markerPath = Join-Path $root '.openclaw-easy-setup-state'
    if (Test-Path -LiteralPath $root) {
        $existingRoot = Get-Item -LiteralPath $root -Force
        if (-not $existingRoot.PSIsContainer -or ($existingRoot.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The state path must be a normal directory and cannot be a reparse point.'
        }
        if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
            $markerItem = Get-Item -LiteralPath $markerPath -Force
            if (($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $markerItem.Length -gt 128 -or (Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8).Trim() -ne 'OpenClawEasySetup-State-v1') {
                throw 'The state directory ownership marker was invalid.'
            }
        }
        else {
            $existingChildren = @(Get-ChildItem -LiteralPath $root -Force)
            $isRecognizedDefaultLayout = $usingDefaultPath -and @($existingChildren | Where-Object { $_.Name -notin @('Logs', 'State', 'Diagnostics') }).Count -eq 0
            if ($existingChildren.Count -gt 0 -and -not $isRecognizedDefaultLayout) {
                throw 'An existing custom state directory must be empty or already owned by OpenClaw Easy Setup.'
            }
        }
    }
    else {
        [void][IO.Directory]::CreateDirectory($root)
    }

    $logs = Join-Path $root 'Logs'
    $state = Join-Path $root 'State'
    $diagnostics = Join-Path $root 'Diagnostics'

    $permissionsHardened = $false
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        try {
            $permissionsHardened = Set-OpenClawPrivatePathAcl -Path $root -Directory
        }
        catch {
            throw 'The state directory permissions could not be restricted to the current user.'
        }
    }

    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        Write-OpenClawUtf8File -Path $markerPath -Content 'OpenClawEasySetup-State-v1'
    }
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        try {
            [void](Set-OpenClawPrivatePathAcl -Path $markerPath)
        }
        catch {
            throw 'The state directory marker permission could not be restricted to the current user.'
        }
    }

    foreach ($directory in @($logs, $state, $diagnostics)) {
        if (Test-Path -LiteralPath $directory) {
            $item = Get-Item -LiteralPath $directory -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'A state subdirectory was not a normal directory.'
            }
        }
        else {
            [void][IO.Directory]::CreateDirectory($directory)
        }
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            try {
                [void](Set-OpenClawPrivatePathAcl -Path $directory -Directory)
            }
            catch {
                throw 'A state subdirectory permission could not be restricted to the current user.'
            }
        }
    }

    return [pscustomobject]@{
        Root = $root
        Logs = $logs
        State = $state
        Diagnostics = $diagnostics
        PermissionsHardened = $permissionsHardened
    }
}

function New-OpenClawLog {
    [CmdletBinding()]
    param(
        [string]$StateDirectory,
        [string]$RunId = $(New-Guid).ToString('N')
    )

    $parsedRunId = [guid]::Empty
    if (-not [guid]::TryParse($RunId, [ref]$parsedRunId)) {
        throw 'The log run ID was invalid.'
    }
    $directories = Initialize-OpenClawStateDirectory -Path $StateDirectory
    $logPath = Join-Path $directories.Logs ("{0}.jsonl" -f $parsedRunId.ToString('N'))
    $stream = New-Object IO.FileStream($logPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    $stream.Dispose()
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        [void](Set-OpenClawPrivatePathAcl -Path $logPath)
    }
    return $logPath
}

function Write-OpenClawLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [string]$Event,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message,

        [hashtable]$Data = @{}
    )

    $logItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($logItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $logItem.Extension -ne '.jsonl') {
        throw 'The structured log path was not a regular JSONL file.'
    }
    if ($logItem.Length -gt 5MB) {
        throw 'The structured log reached its maximum size.'
    }

    $safeData = [ordered]@{}
    foreach ($key in @($Data.Keys | Sort-Object)) {
        $safeKey = Protect-OpenClawLogText -Text ([string]$key) -MaximumLength 128
        if ($safeKey -match '(?i)(token|secret|password|authorization|cookie|private.?key)') {
            $safeData[$safeKey] = '<REDACTED>'
        }
        else {
            $safeData[$safeKey] = Protect-OpenClawLogText -Text $Data[$key]
        }
    }

    $record = [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        level = $Level
        event = Protect-OpenClawLogText -Text $Event -MaximumLength 128
        message = Protect-OpenClawLogText -Text $Message
        data = $safeData
    }
    $line = ($record | ConvertTo-Json -Compress -Depth 4) + [Environment]::NewLine
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($line)
    $stream = New-Object IO.FileStream($logItem.FullName, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
}

function New-OpenClawTaggedException {
    param(
        [string]$Kind,
        [string]$Message
    )

    $exception = New-Object InvalidOperationException($Message)
    $exception.Data['OpenClawFailureKind'] = $Kind
    return $exception
}

function Save-OpenClawCheckpointInternal {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Checkpoint
    )

    $payload = [ordered]@{
        schemaVersion = [int]$Checkpoint.SchemaVersion
        toolVersion = [string]$Checkpoint.ToolVersion
        runId = [string]$Checkpoint.RunId
        targetVersion = [string]$Checkpoint.TargetVersion
        sourceFingerprint = [string]$Checkpoint.SourceFingerprint
        userSid = [string]$Checkpoint.UserSid
        status = [string]$Checkpoint.Status
        createdAtUtc = [string]$Checkpoint.CreatedAtUtc
        updatedAtUtc = [string]$Checkpoint.UpdatedAtUtc
        steps = @($Checkpoint.Steps | ForEach-Object {
            [ordered]@{
                id = [string]$_.Id
                status = [string]$_.Status
                updatedAtUtc = [string]$_.UpdatedAtUtc
                detail = [string]$_.Detail
            }
        })
    }
    $json = $payload | ConvertTo-Json -Depth 6
    $encoding = New-Object Text.UTF8Encoding($false)
    $targetPath = [IO.Path]::GetFullPath([string]$Checkpoint.Path)
    $parent = Split-Path -Parent $targetPath
    $temporaryPath = Join-Path $parent (".{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
    $backupPath = Join-Path $parent (".{0}.bak" -f ([guid]::NewGuid().ToString('N')))
    $bytes = $encoding.GetBytes($json)
    $stream = New-Object IO.FileStream($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }

    try {
        if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
            [IO.File]::Replace($temporaryPath, $targetPath, $backupPath)
        }
        else {
            [IO.File]::Move($temporaryPath, $targetPath)
        }
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            [void](Set-OpenClawPrivatePathAcl -Path $targetPath)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function New-OpenClawCheckpoint {
    [CmdletBinding()]
    param(
        [string]$StateDirectory,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^\d{4}\.\d+\.\d+$')]
        [string]$TargetVersion,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Fa-f0-9]{64}$')]
        [string]$SourceFingerprint
    )

    $directories = Initialize-OpenClawStateDirectory -Path $StateDirectory
    $runId = [guid]::NewGuid().ToString('N')
    $now = [DateTime]::UtcNow.ToString('o')
    $userSid = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }
    else {
        'non-windows'
    }
    $steps = foreach ($stageId in $script:InstallStageIds) {
        [pscustomobject]@{
            Id = $stageId
            Status = 'Pending'
            UpdatedAtUtc = $now
            Detail = ''
        }
    }
    $checkpoint = [pscustomobject]@{
        Path = Join-Path $directories.State ("{0}.json" -f $runId)
        SchemaVersion = $script:RecoverySchemaVersion
        ToolVersion = $script:RecoveryToolVersion
        RunId = $runId
        TargetVersion = $TargetVersion
        SourceFingerprint = $SourceFingerprint.ToUpperInvariant()
        UserSid = $userSid
        Status = 'InProgress'
        CreatedAtUtc = $now
        UpdatedAtUtc = $now
        Steps = @($steps)
    }
    Save-OpenClawCheckpointInternal -Checkpoint $checkpoint
    return $checkpoint
}

function Read-OpenClawCheckpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$ExpectedTargetVersion,
        [string]$ExpectedSourceFingerprint
    )

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -le 0 -or $item.Length -gt 256KB) {
            throw 'The checkpoint was not a normal file within the allowed size.'
        }
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            [void](Set-OpenClawPrivatePathAcl -Path $item.FullName)
        }
        $checkpointData = Get-Content -LiteralPath $item.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([int]$checkpointData.schemaVersion -ne $script:RecoverySchemaVersion) {
            throw 'The checkpoint schema version was not supported.'
        }
        $parsedRunId = [guid]::Empty
        if (-not [guid]::TryParse([string]$checkpointData.runId, [ref]$parsedRunId)) {
            throw 'The checkpoint run ID was invalid.'
        }
        if ([string]$checkpointData.targetVersion -notmatch '^\d{4}\.\d+\.\d+$' -or [string]$checkpointData.sourceFingerprint -notmatch '^[A-Fa-f0-9]{64}$') {
            throw 'The checkpoint target or source fingerprint was invalid.'
        }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedTargetVersion) -and [string]$checkpointData.targetVersion -ne $ExpectedTargetVersion) {
            throw 'The checkpoint target version no longer matches the pinned target.'
        }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceFingerprint) -and [string]$checkpointData.sourceFingerprint -ne $ExpectedSourceFingerprint.ToUpperInvariant()) {
            throw 'The checkpoint source configuration fingerprint no longer matches.'
        }
        $currentSid = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        }
        else {
            'non-windows'
        }
        if ([string]$checkpointData.userSid -ne $currentSid) {
            throw 'The checkpoint belongs to a different Windows user.'
        }

        $steps = @($checkpointData.steps)
        if ($steps.Count -ne $script:InstallStageIds.Count) {
            throw 'The checkpoint did not contain the expected installation stages.'
        }
        for ($index = 0; $index -lt $script:InstallStageIds.Count; $index++) {
            if ([string]$steps[$index].id -ne $script:InstallStageIds[$index] -or [string]$steps[$index].status -notin @('Pending', 'Running', 'Succeeded', 'Failed', 'Skipped')) {
                throw 'The checkpoint stages were invalid or out of order.'
            }
            $safeDetail = Protect-OpenClawLogText -Text ([string]$steps[$index].detail)
            if ($safeDetail -ne [string]$steps[$index].detail) {
                throw 'The checkpoint contained unsafe detail text.'
            }
        }
        $derivedStatus = if (@($steps | Where-Object status -eq 'Failed').Count -gt 0) {
            'Failed'
        }
        elseif (@($steps | Where-Object status -eq 'Running').Count -gt 0) {
            'Running'
        }
        elseif (@($steps | Where-Object status -notin @('Succeeded', 'Skipped')).Count -eq 0) {
            'Completed'
        }
        else {
            'InProgress'
        }
        if ([string]$checkpointData.status -notin @('InProgress', 'Running', 'Failed', 'Completed') -or [string]$checkpointData.status -ne $derivedStatus) {
            throw 'The checkpoint top-level status did not match its stage states.'
        }

        return [pscustomobject]@{
            Path = $item.FullName
            SchemaVersion = [int]$checkpointData.schemaVersion
            ToolVersion = [string]$checkpointData.toolVersion
            RunId = $parsedRunId.ToString('N')
            TargetVersion = [string]$checkpointData.targetVersion
            SourceFingerprint = ([string]$checkpointData.sourceFingerprint).ToUpperInvariant()
            UserSid = [string]$checkpointData.userSid
            Status = [string]$checkpointData.status
            CreatedAtUtc = [string]$checkpointData.createdAtUtc
            UpdatedAtUtc = [string]$checkpointData.updatedAtUtc
            Steps = @($steps | ForEach-Object {
                [pscustomobject]@{
                    Id = [string]$_.id
                    Status = [string]$_.status
                    UpdatedAtUtc = [string]$_.updatedAtUtc
                    Detail = [string]$_.detail
                }
            })
        }
    }
    catch {
        if ($_.Exception.Data.Contains('OpenClawFailureKind')) {
            throw
        }
        throw (New-OpenClawTaggedException -Kind 'Resume' -Message 'The installation checkpoint was invalid or damaged.')
    }
}

function Get-OpenClawLatestCheckpoint {
    [CmdletBinding()]
    param(
        [string]$StateDirectory,
        [string]$ExpectedTargetVersion,
        [string]$ExpectedSourceFingerprint,
        [switch]$IncludeCompleted
    )

    $directories = Initialize-OpenClawStateDirectory -Path $StateDirectory
    $candidates = @(Get-ChildItem -LiteralPath $directories.State -Filter '*.json' -File |
        Where-Object BaseName -Match '^[A-Fa-f0-9]{32}$' |
        Sort-Object LastWriteTimeUtc -Descending)
    if ($candidates.Count -eq 0) {
        return $null
    }

    $checkpoint = Read-OpenClawCheckpoint -Path $candidates[0].FullName -ExpectedTargetVersion $ExpectedTargetVersion -ExpectedSourceFingerprint $ExpectedSourceFingerprint
    if (-not $IncludeCompleted -and $checkpoint.Status -eq 'Completed') {
        return $null
    }
    return $checkpoint
}

function Set-OpenClawCheckpointStep {
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

    $step = @($Checkpoint.Steps | Where-Object Id -eq $StepId)
    if ($step.Count -ne 1) {
        throw (New-OpenClawTaggedException -Kind 'Resume' -Message 'The checkpoint stage could not be updated safely.')
    }
    $now = [DateTime]::UtcNow.ToString('o')
    $step[0].Status = $Status
    $step[0].UpdatedAtUtc = $now
    $step[0].Detail = Protect-OpenClawLogText -Text $Detail
    $Checkpoint.UpdatedAtUtc = $now
    if (@($Checkpoint.Steps | Where-Object Status -eq 'Failed').Count -gt 0) {
        $Checkpoint.Status = 'Failed'
    }
    elseif (@($Checkpoint.Steps | Where-Object Status -eq 'Running').Count -gt 0) {
        $Checkpoint.Status = 'Running'
    }
    elseif (@($Checkpoint.Steps | Where-Object Status -notin @('Succeeded', 'Skipped')).Count -eq 0) {
        $Checkpoint.Status = 'Completed'
    }
    else {
        $Checkpoint.Status = 'InProgress'
    }
    Save-OpenClawCheckpointInternal -Checkpoint $Checkpoint
    return $Checkpoint
}

function Get-OpenClawInstallDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Snapshot,

        [Parameter(Mandatory = $true)]
        [version]$TargetVersion
    )

    $found = [bool]$Snapshot.Found
    if (-not $found) {
        return [pscustomobject]@{ Decision = 'FreshInstall'; Reason = 'OpenClaw is not installed.'; ChangesRequired = $true }
    }
    $trusted = if ($null -ne $Snapshot.PSObject.Properties['Trusted']) { [bool]$Snapshot.Trusted } else { $true }
    $ambiguous = if ($null -ne $Snapshot.PSObject.Properties['Ambiguous']) { [bool]$Snapshot.Ambiguous } else { $false }
    if (-not $trusted) {
        return [pscustomobject]@{ Decision = 'UntrustedBlocked'; Reason = 'The OpenClaw command path was not trusted.'; ChangesRequired = $false }
    }
    if ($ambiguous) {
        return [pscustomobject]@{ Decision = 'AmbiguousBlocked'; Reason = 'Multiple OpenClaw command paths were found.'; ChangesRequired = $false }
    }
    if ($null -eq $Snapshot.ExitCode -or [int]$Snapshot.ExitCode -ne 0 -or $null -eq $Snapshot.Version) {
        return [pscustomobject]@{ Decision = 'UnknownBlocked'; Reason = 'The installed OpenClaw version could not be verified.'; ChangesRequired = $false }
    }
    $rawVersion = [string]$Snapshot.RawVersion
    $versionMatches = @([regex]::Matches($rawVersion, '(?<!\d)\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?') | ForEach-Object Value | Select-Object -Unique)
    if ($versionMatches.Count -ne 1) {
        return [pscustomobject]@{ Decision = 'UnknownBlocked'; Reason = 'The OpenClaw version output was missing or contained multiple versions.'; ChangesRequired = $false }
    }
    if ($versionMatches[0] -match '[-+]') {
        return [pscustomobject]@{ Decision = 'PrereleaseBlocked'; Reason = 'Prerelease or build-suffixed OpenClaw versions require manual review.'; ChangesRequired = $false }
    }

    $installedVersion = [version]$Snapshot.Version
    if ($installedVersion -lt $TargetVersion) {
        return [pscustomobject]@{ Decision = 'Upgrade'; Reason = ("OpenClaw {0} will be updated to pinned version {1}." -f $installedVersion, $TargetVersion); ChangesRequired = $true }
    }
    if ($installedVersion -eq $TargetVersion) {
        return [pscustomobject]@{ Decision = 'AlreadyCurrent'; Reason = ("Pinned OpenClaw {0} is already installed." -f $TargetVersion); ChangesRequired = $false }
    }
    return [pscustomobject]@{ Decision = 'KeepNewer'; Reason = ("Newer OpenClaw {0} will be kept; automatic downgrade to {1} is blocked." -f $installedVersion, $TargetVersion); ChangesRequired = $false }
}

function Write-OpenClawUtf8File {
    param(
        [string]$Path,
        [string]$Content
    )

    $encoding = New-Object Text.UTF8Encoding($false)
    $bytes = $encoding.GetBytes($Content)
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
}

function Export-OpenClawDiagnosticBundle {
    [CmdletBinding()]
    param(
        [string]$StateDirectory,
        [string]$DestinationPath
    )

    $directories = Initialize-OpenClawStateDirectory -Path $StateDirectory
    if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
        $fileName = 'OpenClawEasySetup-Diagnostics-{0}-{1}.zip' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $DestinationPath = Join-Path $directories.Diagnostics $fileName
    }
    $destination = [IO.Path]::GetFullPath($DestinationPath)
    if (Test-Path -LiteralPath $destination) {
        throw (New-OpenClawTaggedException -Kind 'Bundle' -Message 'The diagnostic bundle destination already exists.')
    }
    $destinationParent = Split-Path -Parent $destination
    if ([string]::IsNullOrWhiteSpace($destinationParent)) {
        throw (New-OpenClawTaggedException -Kind 'Bundle' -Message 'The diagnostic bundle destination directory was invalid.')
    }
    if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
        [void][IO.Directory]::CreateDirectory($destinationParent)
    }
    $parentItem = Get-Item -LiteralPath $destinationParent -Force
    if (($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw (New-OpenClawTaggedException -Kind 'Bundle' -Message 'The diagnostic bundle destination cannot be a reparse point.')
    }

    $staging = Join-Path $directories.Diagnostics ("staging-{0}" -f ([guid]::NewGuid().ToString('N')))
    $temporaryZip = Join-Path $destinationParent (".{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
    [void][IO.Directory]::CreateDirectory($staging)
    $stagingPrefix = $directories.Diagnostics.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    try {
        $collectionErrors = New-Object System.Collections.Generic.List[object]
        $safeReadiness = @()
        try {
            $offlineSource = Get-OpenClawSourceConfig
            $offlineArchitecture = Get-OpenClawArchitecture
            $safeReadiness = @(
                [ordered]@{ id = 'platform'; status = $(if (Test-OpenClawIsWindows) { 'Pass' } else { 'Fail' }); current = [Environment]::OSVersion.VersionString; required = 'Windows 10/11'; guidance = 'No external command was executed.' }
                [ordered]@{ id = 'powershell'; status = $(if ($PSVersionTable.PSVersion -ge [version]'5.1.0') { 'Pass' } else { 'Fail' }); current = $PSVersionTable.PSVersion.ToString(); required = '5.1 or newer'; guidance = 'No external command was executed.' }
                [ordered]@{ id = 'architecture'; status = $(if ($offlineArchitecture -in @('X64', 'Arm64', 'AMD64')) { 'Pass' } else { 'Warn' }); current = Protect-OpenClawLogText -Text $offlineArchitecture; required = 'x64 or Arm64'; guidance = 'No external command was executed.' }
                [ordered]@{ id = 'pinnedSource'; status = 'Pass'; current = ("{0} @ {1}" -f $offlineSource.openClaw.releaseTag, $offlineSource.openClaw.commitSha); required = 'Pinned source configuration'; guidance = 'Git, Node, npm, WinGet, and OpenClaw were intentionally not executed while creating this offline bundle.' }
            )
        }
        catch {
            $collectionErrors.Add([ordered]@{ collector = 'readiness'; errorCode = 'OCES-DIAG-001' })
        }
        Write-OpenClawUtf8File -Path (Join-Path $staging 'readiness.json') -Content (ConvertTo-Json -InputObject @($safeReadiness) -Depth 5)

        $sourceConfig = Get-OpenClawSourceConfig
        $versions = [ordered]@{
            schemaVersion = 1
            collectedAtUtc = [DateTime]::UtcNow.ToString('o')
            toolVersion = $script:RecoveryToolVersion
            windowsVersion = [Environment]::OSVersion.Version.ToString()
            architecture = Protect-OpenClawLogText -Text (Get-OpenClawArchitecture) -MaximumLength 64
            powerShellVersion = $PSVersionTable.PSVersion.ToString()
            targetOpenClawVersion = [string]$sourceConfig.openClaw.version
            targetOpenClawReleaseTag = [string]$sourceConfig.openClaw.releaseTag
            targetOpenClawCommit = [string]$sourceConfig.openClaw.commitSha
            installerSha256 = ([string]$sourceConfig.installer.sha256).ToUpperInvariant()
            targetNodeVersion = [string]$sourceConfig.node.winget.version
            targetGitVersion = [string]$sourceConfig.git.winget.version
        }
        Write-OpenClawUtf8File -Path (Join-Path $staging 'versions.json') -Content ($versions | ConvertTo-Json -Depth 4)

        $checkpointSummary = $null
        try {
            $latestCheckpoint = Get-OpenClawLatestCheckpoint -StateDirectory $directories.Root -IncludeCompleted
            if ($null -ne $latestCheckpoint) {
                $checkpointSummary = [ordered]@{
                    schemaVersion = [int]$latestCheckpoint.SchemaVersion
                    runId = [string]$latestCheckpoint.RunId
                    targetVersion = [string]$latestCheckpoint.TargetVersion
                    status = [string]$latestCheckpoint.Status
                    updatedAtUtc = [string]$latestCheckpoint.UpdatedAtUtc
                    steps = @($latestCheckpoint.Steps | ForEach-Object {
                        [ordered]@{
                            id = [string]$_.Id
                            status = [string]$_.Status
                            detail = Protect-OpenClawLogText -Text $_.Detail
                        }
                    })
                }
            }
        }
        catch {
            $collectionErrors.Add([ordered]@{ collector = 'checkpoint'; errorCode = 'OCES-RESUME-001' })
        }
        $checkpointContent = if ($null -eq $checkpointSummary) { 'null' } else { $checkpointSummary | ConvertTo-Json -Depth 6 }
        Write-OpenClawUtf8File -Path (Join-Path $staging 'checkpoint-summary.json') -Content $checkpointContent

        $logIncluded = $false
        $latestLog = Get-ChildItem -LiteralPath $directories.Logs -Filter '*.jsonl' -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        if ($null -ne $latestLog) {
            try {
                $safeLogLines = New-Object System.Collections.Generic.List[string]
                $rawLines = Get-Content -LiteralPath $latestLog.FullName -Encoding UTF8 | Select-Object -Last 500
                foreach ($rawLine in $rawLines) {
                    if ([string]::IsNullOrWhiteSpace($rawLine)) {
                        continue
                    }
                    $record = $rawLine | ConvertFrom-Json
                    $safeRecord = [ordered]@{
                        timestampUtc = Protect-OpenClawLogText -Text $record.timestampUtc -MaximumLength 64
                        level = Protect-OpenClawLogText -Text $record.level -MaximumLength 32
                        event = Protect-OpenClawLogText -Text $record.event -MaximumLength 128
                        message = Protect-OpenClawLogText -Text $record.message
                    }
                    $safeLogLines.Add(($safeRecord | ConvertTo-Json -Compress -Depth 3))
                }
                Write-OpenClawUtf8File -Path (Join-Path $staging 'recent-log.jsonl') -Content (($safeLogLines.ToArray() -join [Environment]::NewLine) + [Environment]::NewLine)
                $logIncluded = $true
            }
            catch {
                $collectionErrors.Add([ordered]@{ collector = 'recent-log'; errorCode = 'OCES-BUNDLE-LOG-001' })
            }
        }

        $redactionReport = [ordered]@{
            schemaVersion = 1
            strategy = 'allowlisted-fields-plus-boundary-redaction'
            sourceLogIncluded = $logIncluded
            automaticUpload = $false
            excluded = @('environmentVariables', 'commandHistory', 'npmrc', 'openClawConfiguration', 'rawCommandOutput', 'registry')
            collectionErrors = $collectionErrors.ToArray()
        }
        Write-OpenClawUtf8File -Path (Join-Path $staging 'redaction-report.json') -Content ($redactionReport | ConvertTo-Json -Depth 5)

        $allowedNames = @('readiness.json', 'versions.json', 'checkpoint-summary.json', 'recent-log.jsonl', 'redaction-report.json')
        $manifestFiles = New-Object System.Collections.Generic.List[object]
        foreach ($file in @(Get-ChildItem -LiteralPath $staging -File | Sort-Object Name)) {
            if ($file.Name -notin $allowedNames) {
                throw 'An unexpected file was present in diagnostic staging.'
            }
            $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
            $unsafePatterns = @(
                '(?i)\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{16,}|sk_live_[A-Za-z0-9]{16,}|npm_[A-Za-z0-9]{20,}|mfa\.[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{16,}|xapp-[A-Za-z0-9-]{16,}|AIza[A-Za-z0-9_-]{30,}|(?:AKIA|ASIA)[A-Z0-9]{16})\b',
                '\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b',
                '\b\d{6,}:[A-Za-z0-9_-]{20,}\b',
                '(?is)-----BEGIN [A-Z ]*PRIVATE KEY-----',
                '(?i)Authorization\s*[:=]\s*(?:Bearer|Basic)\s+(?!<REDACTED>)\S+',
                '(?i)\b[A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASSPHRASE|AUTHORIZATION|API_KEY|PRIVATE_KEY|ACCESS_KEY)[A-Z0-9_]*\b\s*[:=]\s*(?!<REDACTED>)\S+'
            )
            foreach ($unsafePattern in $unsafePatterns) {
                if ($text -match $unsafePattern) {
                    throw 'A diagnostic staging file failed the final secret scan.'
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE) -and $text.IndexOf($env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                throw 'A diagnostic staging file contained the user profile path.'
            }
            $manifestFiles.Add([ordered]@{
                name = $file.Name
                bytes = [int64]$file.Length
                sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
            })
        }
        $manifest = [ordered]@{
            schemaVersion = 1
            createdAtUtc = [DateTime]::UtcNow.ToString('o')
            automaticUpload = $false
            files = $manifestFiles.ToArray()
        }
        Write-OpenClawUtf8File -Path (Join-Path $staging 'manifest.json') -Content ($manifest | ConvertTo-Json -Depth 5)

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($staging, $temporaryZip, [IO.Compression.CompressionLevel]::Optimal, $false)
        [IO.File]::Move($temporaryZip, $destination)
        return [pscustomobject]@{
            Path = $destination
            Sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToUpperInvariant()
        }
    }
    catch {
        if ($_.Exception.Data.Contains('OpenClawFailureKind')) {
            throw
        }
        throw (New-OpenClawTaggedException -Kind 'Bundle' -Message 'The offline diagnostic bundle could not be created safely.')
    }
    finally {
        if (Test-Path -LiteralPath $temporaryZip -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryZip -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $staging -PathType Container) {
            $resolvedStaging = (Resolve-Path -LiteralPath $staging).Path
            if ($resolvedStaging.StartsWith($stagingPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $resolvedStaging -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
