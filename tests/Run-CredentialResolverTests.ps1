[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$credentialModulePath = Join-Path $projectRoot 'src\OpenClawEasySetup.CredentialManager.psm1'
$settingsModulePath = Join-Path $projectRoot 'src\OpenClawEasySetup.Settings.psm1'
$resolverSourcePath = Join-Path $projectRoot 'src\CredentialResolver\OpenClawEasySetup.SecretResolver.cs'
Import-Module -Name $credentialModulePath -Force

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

function Invoke-TestResolver {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$InputText,
        [string[]]$Arguments = @()
    )

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Path
    $startInfo.Arguments = ($Arguments -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'The resolver test process did not start.'
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(5000)) {
            try { $process.Kill() } catch { }
            throw 'The resolver test process timed out.'
        }
        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            Stdout = [string]$stdoutTask.Result
            Stderr = [string]$stderrTask.Result
        }
    }
    finally {
        $process.Dispose()
    }
}

$purposes = @(
    'gateway/auth/token',
    'models/openai/api-key',
    'models/anthropic/api-key',
    'models/google/api-key',
    'channels/telegram/bot-token',
    'channels/discord/bot-token'
)
foreach ($purpose in $purposes) {
    $id = New-OpenClawCredentialId -Purpose $purpose
    Assert-True -Condition (Test-OpenClawCredentialId -Id $id) -Name "$purpose receives an allowlisted run-scoped id"
}
Assert-True -Condition (-not (Test-OpenClawCredentialId -Id 'v1/gateway/auth/token/../../arbitrary')) -Name 'Credential ids reject path traversal'
Assert-True -Condition (-not (Test-OpenClawCredentialId -Id 'arbitrary-target')) -Name 'Credential ids reject arbitrary Credential Manager targets'

$nullSecret = New-Object Security.SecureString
$nullSecret.AppendChar([char]0)
$nullSecret.MakeReadOnly()
$nullSecretRejected = $false
try {
    [void](Set-OpenClawCredential -Id (New-OpenClawCredentialId -Purpose 'gateway/auth/token') -Secret $nullSecret -Confirm:$false)
}
catch {
    $nullSecretRejected = $true
}
finally {
    $nullSecret.Dispose()
}
Assert-True -Condition $nullSecretRejected -Name 'Credential storage rejects embedded null characters before writing'

$multibyteSecret = New-Object Security.SecureString
try {
    for ($index = 0; $index -lt 854; $index++) {
        $multibyteSecret.AppendChar([char]0xD55C)
    }
    $multibyteSecret.MakeReadOnly()
    Assert-True -Condition ((Get-OpenClawCredentialUtf8ByteCount -Secret $multibyteSecret) -eq 2562) -Name 'Credential preflight measures the exact UTF-8 byte length for multibyte secrets'
}
finally {
    $multibyteSecret.Dispose()
}

$resolverSource = Get-Content -LiteralPath $resolverSourcePath -Raw -Encoding UTF8
$settingsSource = Get-Content -LiteralPath $settingsModulePath -Raw -Encoding UTF8
Assert-True -Condition ($resolverSource -match 'CredReadW' -and $resolverSource -match 'CredFree' -and $resolverSource -notmatch 'CredEnumerate') -Name 'Resolver reads exact credentials and cannot enumerate the vault'
Assert-True -Condition ($resolverSource -notmatch 'Process\.Start|cmd\.exe|powershell(?:\.exe)?') -Name 'Resolver cannot launch a shell or child process'
Assert-True -Condition ($resolverSource -match "IndexOf\('\\0'\)") -Name 'Resolver rejects stored secrets containing null characters'
Assert-True -Condition ($settingsSource -notmatch 'Install-OpenClawCredentialResolver[^\r\n]*-SourcePath') -Name 'Settings engine calls the fixed-source resolver installation contract'

$testRoot = Join-Path $PSScriptRoot ('.tmp-credential-' + [Guid]::NewGuid().ToString('N'))
try {
    $installation = Install-OpenClawCredentialResolver -StateDirectory $testRoot -Confirm:$false
    Assert-True -Condition ($installation.ProtocolVersion -eq 1 -and (Test-Path -LiteralPath $installation.Path -PathType Leaf)) -Name 'Resolver compiles into the private test State directory'
    Assert-True -Condition ($installation.BinarySha256 -match '^[A-Fa-f0-9]{64}$') -Name 'Installed resolver has a verified SHA-256'

    $missingId = New-OpenClawCredentialId -Purpose 'gateway/auth/token'
    $request = [pscustomobject]@{ protocolVersion = 1; provider = 'oces_wincred'; ids = @($missingId) } | ConvertTo-Json -Compress
    $result = Invoke-TestResolver -Path $installation.Path -InputText $request
    $response = $result.Stdout | ConvertFrom-Json
    $missingError = $response.errors.PSObject.Properties[$missingId]
    Assert-True -Condition ($result.ExitCode -eq 0 -and [string]::IsNullOrEmpty($result.Stderr) -and $response.protocolVersion -eq 1) -Name 'Resolver accepts the exact OpenClaw protocol v1 shape'
    Assert-True -Condition (@($response.values.PSObject.Properties).Count -eq 0 -and $missingError.Value.message -eq 'not found') -Name 'Unknown allowlisted ids return a secret-free not-found result'

    $invalidRequest = '{"protocolVersion":1,"provider":"oces_wincred","ids":["../../arbitrary-target"]}'
    $invalidResult = Invoke-TestResolver -Path $installation.Path -InputText $invalidRequest
    Assert-True -Condition ($invalidResult.ExitCode -ne 0 -and [string]::IsNullOrEmpty($invalidResult.Stdout) -and $invalidResult.Stderr.Trim() -eq 'invalid request') -Name 'Invalid ids fail closed without disclosing a target or secret'

    $argumentResult = Invoke-TestResolver -Path $installation.Path -InputText $request -Arguments @('unexpected')
    Assert-True -Condition ($argumentResult.ExitCode -ne 0 -and [string]::IsNullOrEmpty($argumentResult.Stdout)) -Name 'Resolver rejects command-line arguments so secrets cannot enter argv'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedTestRoot = (Resolve-Path -LiteralPath $testRoot).Path
        $expectedPrefix = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.tmp-credential-'))
        if (-not $resolvedTestRoot.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing to clean a credential test directory outside the expected prefix.'
        }
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}

Write-Host ''
Write-Host ("Credential resolver tests: {0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) {
    exit 1
}
