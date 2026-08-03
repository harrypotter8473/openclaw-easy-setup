[CmdletBinding()]
param(
    [ValidateSet('Gui', 'InstallSmoke')]
    [string]$Mode = 'Gui',

    [ValidateRange(4096, 32768)]
    [int]$MemoryInMB = 4096,

    [switch]$EnableClipboard,
    [switch]$GenerateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-OpenClawSandboxDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [switch]$MustBeEmpty
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Sandbox path was not a normal directory: $Path"
    }
    if ($MustBeEmpty -and @(Get-ChildItem -LiteralPath $item.FullName -Force).Count -ne 0) {
        throw "Sandbox results directory must be empty: $Path"
    }
    return $item
}

function New-OpenClawSandboxDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    if (Test-Path -LiteralPath $fullPath) {
        throw "Sandbox run directory already existed: $fullPath"
    }

    $parent = Split-Path -Parent $fullPath
    if ([string]::IsNullOrWhiteSpace($parent) -or -not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Sandbox directory parent did not exist: $parent"
    }
    [void](Assert-OpenClawSandboxDirectory -Path $parent)
    [void](New-Item -ItemType Directory -Path $fullPath -ErrorAction Stop)
    return Assert-OpenClawSandboxDirectory -Path $fullPath -MustBeEmpty
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Windows Sandbox E2E is available only on Windows.'
}

$projectRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$sandboxEntryPoint = Join-Path $projectRoot 'tests\e2e\Invoke-InWindowsSandbox.ps1'
if (-not (Test-Path -LiteralPath $sandboxEntryPoint -PathType Leaf)) {
    throw 'The in-sandbox E2E entry point was not found.'
}
[void](Assert-OpenClawSandboxDirectory -Path $projectRoot)

$sandboxExecutable = $null
if (-not $GenerateOnly) {
    $sandboxExecutable = Join-Path $env:SystemRoot 'System32\WindowsSandbox.exe'
    if (-not (Test-Path -LiteralPath $sandboxExecutable -PathType Leaf)) {
        throw @'
Windows Sandbox is not enabled. This launcher does not enable Windows features automatically.
Open an elevated PowerShell only after reviewing the change, run:
Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All
Then restart Windows if prompted and run this launcher again.
'@
    }
}

$runId = [guid]::NewGuid().ToString('N')
$defaultRoot = Join-Path ([IO.Path]::GetTempPath()) 'OpenClawEasySetup-E2E'
if (-not (Test-Path -LiteralPath $defaultRoot)) {
    [void](New-Item -ItemType Directory -Path $defaultRoot -ErrorAction Stop)
}
[void](Assert-OpenClawSandboxDirectory -Path $defaultRoot)

$stagingItem = New-OpenClawSandboxDirectory -Path (Join-Path $defaultRoot ("source-{0}" -f $runId))
$stagingPath = [IO.Path]::GetFullPath($stagingItem.FullName)
$resultsItem = New-OpenClawSandboxDirectory -Path (Join-Path $defaultRoot ("results-{0}" -f $runId))
$resultsPath = [IO.Path]::GetFullPath($resultsItem.FullName)
$configurationFullPath = Join-Path $defaultRoot ("OpenClawEasySetup-{0}.wsb" -f $runId)

$stagedFiles = @(
    'OpenClawEasySetup.Gui.ps1',
    'OpenClawEasySetup.Settings.Gui.ps1',
    'OpenClawEasySetup.ps1',
    'config\openclaw-source.json',
    'locales\ko-KR.json',
    'src\OpenClawEasySetup.CredentialManager.psm1',
    'src\OpenClawEasySetup.Gui.psm1',
    'src\OpenClawEasySetup.Recovery.ps1',
    'src\OpenClawEasySetup.Settings.psm1',
    'src\OpenClawEasySetup.psm1',
    'src\CredentialResolver\OpenClawEasySetup.SecretResolver.cs',
    'src\PackageIntegrity\OpenClawEasySetup.PackageTreeHasher.cs',
    'tests\e2e\Invoke-InWindowsSandbox.ps1',
    'ui\MainWindow.xaml',
    'ui\SettingsWindow.xaml'
)
$projectPrefix = $projectRoot.TrimEnd('\') + '\'
foreach ($relativePath in $stagedFiles) {
    $sourcePath = [IO.Path]::GetFullPath((Join-Path $projectRoot $relativePath))
    if (-not $sourcePath.StartsWith($projectPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'A Sandbox staging source escaped the project root.'
    }
    $sourceItem = Get-Item -LiteralPath $sourcePath -Force -ErrorAction Stop
    if ($sourceItem.PSIsContainer -or ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $sourceItem.Length -le 0 -or $sourceItem.Length -gt 2MB) {
        throw "Sandbox staging source was not a normal file: $relativePath"
    }

    $relativeParent = Split-Path -Parent $relativePath
    if (-not [string]::IsNullOrWhiteSpace($relativeParent)) {
        $sourceParent = $projectRoot
        foreach ($segment in $relativeParent.Split('\')) {
            $sourceParent = Join-Path $sourceParent $segment
            [void](Assert-OpenClawSandboxDirectory -Path $sourceParent)
        }
    }

    $destinationPath = Join-Path $stagingPath $relativePath
    $destinationParent = Split-Path -Parent $destinationPath
    if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $destinationParent -Force)
    }
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -ErrorAction Stop
    $destinationItem = Get-Item -LiteralPath $destinationPath -Force
    if (($destinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash) {
        throw "Sandbox staging copy failed integrity validation: $relativePath"
    }
}

$escapedStagingPath = [Security.SecurityElement]::Escape($stagingPath)
$escapedResultsPath = [Security.SecurityElement]::Escape($resultsPath)
$clipboardValue = if ($EnableClipboard) { 'Enable' } else { 'Disable' }
$configuration = @"
<Configuration>
  <VGpu>Disable</VGpu>
  <Networking>Enable</Networking>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$escapedStagingPath</HostFolder>
      <SandboxFolder>C:\OCES-Source</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$escapedResultsPath</HostFolder>
      <SandboxFolder>C:\OCES-Results</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\OCES-Source\tests\e2e\Invoke-InWindowsSandbox.ps1 -Mode $Mode -RunId $runId</Command>
  </LogonCommand>
  <AudioInput>Disable</AudioInput>
  <VideoInput>Disable</VideoInput>
  <ProtectedClient>Enable</ProtectedClient>
  <PrinterRedirection>Disable</PrinterRedirection>
  <ClipboardRedirection>$clipboardValue</ClipboardRedirection>
  <MemoryInMB>$MemoryInMB</MemoryInMB>
</Configuration>
"@

$xmlDocument = New-Object Xml.XmlDocument
$xmlDocument.PreserveWhitespace = $true
$xmlDocument.LoadXml($configuration)
$utf8NoBom = New-Object Text.UTF8Encoding($false)
$configurationBytes = $utf8NoBom.GetBytes($configuration)
$configurationStream = New-Object IO.FileStream($configurationFullPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
    $configurationStream.Write($configurationBytes, 0, $configurationBytes.Length)
    $configurationStream.Flush($true)
}
finally {
    $configurationStream.Dispose()
}
$configurationItem = Get-Item -LiteralPath $configurationFullPath -Force
if (($configurationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $configurationItem.Length -ne $configurationBytes.Length) {
    throw 'The generated Windows Sandbox configuration failed integrity validation.'
}

$result = [pscustomobject]@{
    Mode = $Mode
    RunId = $runId
    ConfigurationPath = $configurationFullPath
    SourceStagingDirectory = $stagingPath
    ResultsDirectory = $resultsPath
    SourceMappedReadOnly = $true
    ResultsMappingIsDedicated = $true
    NetworkingEnabled = $true
    ClipboardEnabled = [bool]$EnableClipboard
    Disposable = $true
    ProcessId = $null
}

if ($GenerateOnly) {
    return $result
}

Write-Host '새 Windows Sandbox에서 OpenClaw Easy Setup 시험을 시작합니다.' -ForegroundColor Cyan
Write-Host '호스트 저장소는 읽기 전용이며 Sandbox를 닫으면 내부 설치와 자격 증명이 모두 삭제됩니다.'
Write-Host ("정제된 결과 폴더: {0}" -f $resultsPath) -ForegroundColor DarkGray
if (-not $EnableClipboard) {
    Write-Host '호스트 보호를 위해 클립보드 공유는 꺼져 있습니다.' -ForegroundColor DarkGray
}

$sandboxProcess = Start-Process -FilePath $sandboxExecutable -ArgumentList ('"{0}"' -f $configurationFullPath) -PassThru
$result.ProcessId = $sandboxProcess.Id
return $result
