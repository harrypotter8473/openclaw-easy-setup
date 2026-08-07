[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,

    [Parameter(Mandatory = $true)]
    [string]$StateDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectFullPath = [IO.Path]::GetFullPath($ProjectRoot)
$stateFullPath = [IO.Path]::GetFullPath($StateDirectory)
$projectItem = Get-Item -LiteralPath $projectFullPath -Force -ErrorAction Stop
if (-not $projectItem.PSIsContainer -or
    ($projectItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'E2E-WORKER-PROJECT-INVALID'
}

$entryPoint = Join-Path $projectFullPath 'OpenClawEasySetup.ps1'
$entryItem = Get-Item -LiteralPath $entryPoint -Force -ErrorAction Stop
if ($entryItem.PSIsContainer -or
    ($entryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
    $entryItem.Length -le 0 -or $entryItem.Length -gt 1MB) {
    throw 'E2E-WORKER-ENTRYPOINT-INVALID'
}

# Keep -Confirm:$false inside PowerShell language evaluation. Passing that text
# through powershell.exe -File would bind it as a string in Windows PowerShell 5.1.
& $entryPoint `
    -Action Install `
    -Apply `
    -SkipOnboarding `
    -StateDirectory $stateFullPath `
    -Confirm:$false

exit 0
