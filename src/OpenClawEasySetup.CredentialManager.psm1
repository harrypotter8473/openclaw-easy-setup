Set-StrictMode -Version Latest

$script:CredentialIdPattern = [regex]::new(
    '^v1/(gateway/auth/token|models/(openai|anthropic|google)/api-key|channels/(slack/(bot-token|app-token)|telegram/bot-token|discord/bot-token))/[A-Fa-f0-9]{32}$',
    [Text.RegularExpressions.RegexOptions]::CultureInvariant
)
$script:CredentialPurposes = @(
    'gateway/auth/token',
    'models/openai/api-key',
    'models/anthropic/api-key',
    'models/google/api-key',
    'channels/slack/bot-token',
    'channels/slack/app-token',
    'channels/telegram/bot-token',
    'channels/discord/bot-token'
)
$script:ResolverSourceMaximumBytes = 524288
$script:ResolverBinaryMaximumBytes = 2097152

$moduleDirectoryPath = [IO.Path]::GetFullPath($PSScriptRoot)
if (-not (Test-Path -LiteralPath $moduleDirectoryPath -PathType Container)) {
    throw 'The OpenClaw Easy Setup module directory was not found.'
}
$moduleDirectoryItem = Get-Item -LiteralPath $moduleDirectoryPath -Force
if (($moduleDirectoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'The OpenClaw Easy Setup module directory cannot be a reparse point.'
}

$moduleFilePath = [IO.Path]::GetFullPath($PSCommandPath)
$modulePathPrefix = $moduleDirectoryPath.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
if (-not $moduleFilePath.StartsWith($modulePathPrefix, [StringComparison]::OrdinalIgnoreCase) -or
    -not (Test-Path -LiteralPath $moduleFilePath -PathType Leaf)) {
    throw 'The OpenClaw Easy Setup credential module path was invalid.'
}
$moduleFileItem = Get-Item -LiteralPath $moduleFilePath -Force
if (($moduleFileItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'The OpenClaw Easy Setup credential module cannot be a reparse point.'
}

$recoveryModulePath = [IO.Path]::GetFullPath((Join-Path $moduleDirectoryPath 'OpenClawEasySetup.Recovery.ps1'))
if (-not $recoveryModulePath.StartsWith($modulePathPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The OpenClaw Easy Setup state-directory implementation path was invalid.'
}
if (-not (Test-Path -LiteralPath $recoveryModulePath -PathType Leaf)) {
    throw 'The OpenClaw Easy Setup state-directory implementation was not found.'
}
$recoveryModuleItem = Get-Item -LiteralPath $recoveryModulePath -Force
if (($recoveryModuleItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'The OpenClaw Easy Setup state-directory implementation cannot be a reparse point.'
}
. $recoveryModulePath

function Test-OpenClawCredentialId {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Id
    )

    if ([string]::IsNullOrWhiteSpace($Id)) {
        return $false
    }
    return $script:CredentialIdPattern.IsMatch($Id)
}

function Assert-OpenClawCredentialId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    if (-not (Test-OpenClawCredentialId -Id $Id)) {
        throw 'The credential id is not an allowed OpenClaw Easy Setup credential id.'
    }
}

function New-OpenClawCredentialId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet(
            'gateway/auth/token',
            'models/openai/api-key',
            'models/anthropic/api-key',
            'models/google/api-key',
            'channels/slack/bot-token',
            'channels/slack/app-token',
            'channels/telegram/bot-token',
            'channels/discord/bot-token'
        )]
        [string]$Purpose
    )

    $bytes = New-Object byte[] 16
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($bytes)
        $suffix = ([BitConverter]::ToString($bytes)).Replace('-', '')
        $id = 'v1/{0}/{1}' -f $Purpose, $suffix
        Assert-OpenClawCredentialId -Id $id
        return $id
    }
    finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
        $generator.Dispose()
    }
}

function Initialize-OpenClawCredentialNative {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'Windows Credential Manager is only available on Windows.'
    }

    $nativeType = 'OpenClawEasySetup.CredentialNative' -as [type]
    if ($null -eq $nativeType) {
        $nativeSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security;
using System.Text.RegularExpressions;

namespace OpenClawEasySetup
{
    public static class CredentialNative
    {
        private const uint CredentialTypeGeneric = 1;
        private const uint CredentialPersistLocalMachine = 2;
        private const int ErrorNotFound = 1168;
        private const int MaxCredentialBytes = 2560;
        private const uint CodePageUtf8 = 65001;
        private const uint WideCharErrorInvalidChars = 0x00000080;
        private const string TargetPrefix = "OpenClawEasySetup:";

        private static readonly Regex IdPattern = new Regex(
            "^v1/(gateway/auth/token|models/(openai|anthropic|google)/api-key|channels/(slack/(bot-token|app-token)|telegram/bot-token|discord/bot-token))/[A-Fa-f0-9]{32}$",
            RegexOptions.CultureInvariant | RegexOptions.Compiled);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct Credential
        {
            internal uint Flags;
            internal uint Type;
            [MarshalAs(UnmanagedType.LPWStr)] internal string TargetName;
            [MarshalAs(UnmanagedType.LPWStr)] internal string Comment;
            internal System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            internal uint CredentialBlobSize;
            internal IntPtr CredentialBlob;
            internal uint Persist;
            internal uint AttributeCount;
            internal IntPtr Attributes;
            [MarshalAs(UnmanagedType.LPWStr)] internal string TargetAlias;
            [MarshalAs(UnmanagedType.LPWStr)] internal string UserName;
        }

        [DllImport("Advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CredWrite(ref Credential credential, uint flags);

        [DllImport("Advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CredDelete(string target, uint type, uint flags);

        [DllImport("Advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CredRead(string target, uint type, int flags, out IntPtr credential);

        [DllImport("Advapi32.dll", EntryPoint = "CredFree", SetLastError = false)]
        private static extern void CredFree(IntPtr buffer);

        [DllImport("Kernel32.dll", EntryPoint = "LoadLibraryW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr LoadLibrary(string fileName);

        [DllImport("Kernel32.dll", EntryPoint = "FreeLibrary", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool FreeLibrary(IntPtr module);

        [DllImport("Kernel32.dll", EntryPoint = "GetProcAddress", CharSet = CharSet.Ansi, SetLastError = true)]
        private static extern IntPtr GetProcAddress(IntPtr module, string procedureName);

        [DllImport("Kernel32.dll", EntryPoint = "WideCharToMultiByte", SetLastError = true)]
        private static extern int WideCharToMultiByte(
            uint codePage,
            uint flags,
            IntPtr wideCharacters,
            int wideCharacterCount,
            IntPtr bytes,
            int byteCount,
            IntPtr defaultCharacter,
            IntPtr usedDefaultCharacter);

        public static void EnsureAvailable()
        {
            IntPtr module = LoadLibrary("Advapi32.dll");
            if (module == IntPtr.Zero)
            {
                throw new InvalidOperationException("Windows Credential Manager is unavailable.");
            }

            try
            {
                if (GetProcAddress(module, "CredWriteW") == IntPtr.Zero ||
                    GetProcAddress(module, "CredDeleteW") == IntPtr.Zero ||
                    GetProcAddress(module, "CredReadW") == IntPtr.Zero ||
                    GetProcAddress(module, "CredFree") == IntPtr.Zero)
                {
                    throw new InvalidOperationException("Required Windows Credential Manager functions are unavailable.");
                }
            }
            finally
            {
                FreeLibrary(module);
            }
        }

        public static bool Write(string id, SecureString secret)
        {
            EnsureAvailable();
            string target = BuildTarget(id);
            if (secret == null || secret.Length == 0)
            {
                throw new ArgumentException("The credential secret cannot be empty.", "secret");
            }

            IntPtr unicode = IntPtr.Zero;
            IntPtr utf8 = IntPtr.Zero;
            int utf8Length = 0;
            try
            {
                unicode = Marshal.SecureStringToGlobalAllocUnicode(secret);
                for (int index = 0; index < secret.Length; index++)
                {
                    if (Marshal.ReadInt16(unicode, index * 2) == 0)
                    {
                        throw new ArgumentException("The credential secret cannot contain a null character.", "secret");
                    }
                }
                utf8Length = WideCharToMultiByte(
                    CodePageUtf8,
                    WideCharErrorInvalidChars,
                    unicode,
                    secret.Length,
                    IntPtr.Zero,
                    0,
                    IntPtr.Zero,
                    IntPtr.Zero);
                if (utf8Length <= 0)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Credential encoding failed.");
                }
                if (utf8Length > MaxCredentialBytes)
                {
                    throw new ArgumentException("The UTF-8 credential exceeds 2560 bytes.", "secret");
                }

                utf8 = Marshal.AllocHGlobal(utf8Length);
                int encoded = WideCharToMultiByte(
                    CodePageUtf8,
                    WideCharErrorInvalidChars,
                    unicode,
                    secret.Length,
                    utf8,
                    utf8Length,
                    IntPtr.Zero,
                    IntPtr.Zero);
                if (encoded != utf8Length)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Credential encoding failed.");
                }

                Credential credential = new Credential();
                credential.Type = CredentialTypeGeneric;
                credential.TargetName = target;
                credential.CredentialBlobSize = (uint)utf8Length;
                credential.CredentialBlob = utf8;
                credential.Persist = CredentialPersistLocalMachine;
                credential.UserName = Environment.UserName;

                if (!CredWrite(ref credential, 0))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Credential Manager write failed.");
                }
                return true;
            }
            finally
            {
                if (utf8 != IntPtr.Zero)
                {
                    ZeroMemory(utf8, utf8Length);
                    Marshal.FreeHGlobal(utf8);
                }
                if (unicode != IntPtr.Zero)
                {
                    Marshal.ZeroFreeGlobalAllocUnicode(unicode);
                }
            }
        }

        public static int GetUtf8ByteCount(SecureString secret)
        {
            EnsureAvailable();
            if (secret == null || secret.Length == 0)
            {
                throw new ArgumentException("The credential secret cannot be empty.", "secret");
            }

            IntPtr unicode = IntPtr.Zero;
            try
            {
                unicode = Marshal.SecureStringToGlobalAllocUnicode(secret);
                for (int index = 0; index < secret.Length; index++)
                {
                    if (Marshal.ReadInt16(unicode, index * 2) == 0)
                    {
                        throw new ArgumentException("The credential secret cannot contain a null character.", "secret");
                    }
                }
                int utf8Length = WideCharToMultiByte(
                    CodePageUtf8,
                    WideCharErrorInvalidChars,
                    unicode,
                    secret.Length,
                    IntPtr.Zero,
                    0,
                    IntPtr.Zero,
                    IntPtr.Zero);
                if (utf8Length <= 0)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Credential encoding failed.");
                }
                return utf8Length;
            }
            finally
            {
                if (unicode != IntPtr.Zero)
                {
                    Marshal.ZeroFreeGlobalAllocUnicode(unicode);
                }
            }
        }

        public static bool Exists(string id)
        {
            EnsureAvailable();
            string target = BuildTarget(id);
            IntPtr credential = IntPtr.Zero;
            try
            {
                if (CredRead(target, CredentialTypeGeneric, 0, out credential))
                {
                    return credential != IntPtr.Zero;
                }

                int error = Marshal.GetLastWin32Error();
                if (error == ErrorNotFound)
                {
                    return false;
                }
                throw new Win32Exception(error, "Credential Manager read failed.");
            }
            finally
            {
                if (credential != IntPtr.Zero)
                {
                    CredFree(credential);
                }
            }
        }

        public static bool Delete(string id)
        {
            EnsureAvailable();
            string target = BuildTarget(id);
            if (CredDelete(target, CredentialTypeGeneric, 0))
            {
                return true;
            }

            int error = Marshal.GetLastWin32Error();
            if (error == ErrorNotFound)
            {
                return false;
            }
            throw new Win32Exception(error, "Credential Manager delete failed.");
        }

        private static string BuildTarget(string id)
        {
            if (String.IsNullOrEmpty(id) || !IdPattern.IsMatch(id))
            {
                throw new ArgumentException("The credential id is invalid.", "id");
            }
            return TargetPrefix + id;
        }

        private static void ZeroMemory(IntPtr pointer, int length)
        {
            for (int index = 0; index < length; index++)
            {
                Marshal.WriteByte(pointer, index, 0);
            }
        }
    }
}
'@

        try {
            Add-Type -TypeDefinition $nativeSource -Language CSharp -ErrorAction Stop
        }
        catch {
            throw 'Windows Credential Manager integration could not be initialized.'
        }
        $nativeType = 'OpenClawEasySetup.CredentialNative' -as [type]
    }

    if ($null -eq $nativeType) {
        throw 'Windows Credential Manager integration could not be loaded.'
    }
    try {
        $nativeType::EnsureAvailable()
    }
    catch {
        throw 'The required Windows Credential Manager functions are unavailable.'
    }
    return $nativeType
}

function Set-OpenClawCredential {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,

        [Parameter(Mandatory = $true)]
        [Security.SecureString]$Secret
    )

    Assert-OpenClawCredentialId -Id $Id
    if ($null -eq $Secret -or $Secret.Length -eq 0) {
        throw 'The credential secret cannot be empty.'
    }
    if (-not $PSCmdlet.ShouldProcess($Id, 'Store the secret in Windows Credential Manager')) {
        return $false
    }

    $nativeType = Initialize-OpenClawCredentialNative
    return [bool]$nativeType::Write($Id, $Secret)
}

function Get-OpenClawCredentialUtf8ByteCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Security.SecureString]$Secret
    )

    if ($null -eq $Secret -or $Secret.Length -eq 0) {
        throw 'The credential secret cannot be empty.'
    }
    $nativeType = Initialize-OpenClawCredentialNative
    return [int]$nativeType::GetUtf8ByteCount($Secret)
}

function Test-OpenClawCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    Assert-OpenClawCredentialId -Id $Id
    $nativeType = Initialize-OpenClawCredentialNative
    return [bool]$nativeType::Exists($Id)
}

function Remove-OpenClawCredential {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    Assert-OpenClawCredentialId -Id $Id
    if (-not $PSCmdlet.ShouldProcess($Id, 'Remove the secret from Windows Credential Manager')) {
        return $false
    }

    $nativeType = Initialize-OpenClawCredentialNative
    return [bool]$nativeType::Delete($Id)
}

function Get-OpenClawVerifiedNormalPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Leaf', 'Container')]
        [string]$Kind
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $pathType = if ($Kind -eq 'Leaf') { 'Leaf' } else { 'Container' }
    if (-not (Test-Path -LiteralPath $fullPath -PathType $pathType)) {
        throw 'A required resolver path was missing or had the wrong type.'
    }
    $item = Get-Item -LiteralPath $fullPath -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Resolver source and destination paths cannot be reparse points.'
    }
    return $fullPath
}

function Test-OpenClawChildPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Parent,

        [Parameter(Mandatory = $true)]
        [string]$Child
    )

    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\', '/')
    $childFull = [IO.Path]::GetFullPath($Child)
    $prefix = $parentFull + [IO.Path]::DirectorySeparatorChar
    return $childFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-OpenClawInheritedPrivateAcl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [switch]$NormalizeOwner
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'Private Windows ACL verification is unavailable on this platform.'
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $systemSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
        $acl = Get-Acl -LiteralPath $Path
        $ownerSid = $acl.GetOwner([Security.Principal.SecurityIdentifier])
        if ($acl.AreAccessRulesProtected) {
            throw 'The resolver path does not inherit the private State directory ACL.'
        }

        $allowedSids = @($identity.User.Value, $systemSid.Value)
        $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        if ($rules.Count -eq 0) {
            throw 'The resolver path has no verifiable inherited access rules.'
        }

        $unexpectedRule = @($rules | Where-Object {
            -not $_.IsInherited -or $_.IdentityReference.Value -notin $allowedSids
        }).Count -gt 0
        $hasUserControl = @($rules | Where-Object {
            $_.IsInherited -and
            $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            $_.IdentityReference.Value -eq $identity.User.Value -and
            ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl
        }).Count -gt 0
        $hasSystemControl = @($rules | Where-Object {
            $_.IsInherited -and
            $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            $_.IdentityReference.Value -eq $systemSid.Value -and
            ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl
        }).Count -gt 0

        if ($unexpectedRule -or -not $hasUserControl -or -not $hasSystemControl) {
            throw 'The resolver path ACL is not restricted to the current user and SYSTEM.'
        }

        if ($ownerSid.Value -ne $identity.User.Value) {
            if (-not $NormalizeOwner) {
                throw 'The resolver path does not inherit the private State directory ACL.'
            }

            # Hosted administrator tokens can assign BUILTIN\Administrators as
            # the owner of a new child even though its DACL safely inherits from
            # State. Change only that owner after validating the inherited DACL,
            # then re-read and verify the complete descriptor.
            $acl.SetOwner($identity.User)
            Set-Acl -LiteralPath $Path -AclObject $acl
            Assert-OpenClawInheritedPrivateAcl -Path $Path
            return
        }
    }
    finally {
        $identity.Dispose()
    }
}

function Get-OpenClawResolverSourcePath {
    $moduleDirectory = Get-OpenClawVerifiedNormalPath -Path $PSScriptRoot -Kind Container
    $sourceDirectory = Join-Path $moduleDirectory 'CredentialResolver'
    $sourceDirectory = Get-OpenClawVerifiedNormalPath -Path $sourceDirectory -Kind Container
    $sourcePath = Join-Path $sourceDirectory 'OpenClawEasySetup.SecretResolver.cs'
    $sourcePath = Get-OpenClawVerifiedNormalPath -Path $sourcePath -Kind Leaf
    if (-not (Test-OpenClawChildPath -Parent $sourceDirectory -Child $sourcePath)) {
        throw 'The credential resolver source path escaped its expected directory.'
    }

    $sourceItem = Get-Item -LiteralPath $sourcePath -Force
    if ($sourceItem.Length -le 0 -or $sourceItem.Length -gt $script:ResolverSourceMaximumBytes) {
        throw 'The credential resolver source size was invalid.'
    }
    return $sourcePath
}

function Test-OpenClawResolverAssembly {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $verifiedPath = Get-OpenClawVerifiedNormalPath -Path $Path -Kind Leaf
    $item = Get-Item -LiteralPath $verifiedPath -Force
    if ($item.Length -le 0 -or $item.Length -gt $script:ResolverBinaryMaximumBytes) {
        return $false
    }
    try {
        $assemblyName = [Reflection.AssemblyName]::GetAssemblyName($verifiedPath)
        return $assemblyName.Name -eq 'OpenClawEasySetup.SecretResolver'
    }
    catch {
        return $false
    }
}

function Test-OpenClawResolverProtocol {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $testId = New-OpenClawCredentialId -Purpose 'gateway/auth/token'
    for ($attempt = 0; $attempt -lt 3 -and (Test-OpenClawCredential -Id $testId); $attempt++) {
        $testId = New-OpenClawCredentialId -Purpose 'gateway/auth/token'
    }
    if (Test-OpenClawCredential -Id $testId) {
        throw 'A safe resolver self-test credential id could not be allocated.'
    }

    $request = [pscustomobject]@{
        protocolVersion = 1
        provider = 'openclaw-easy-setup'
        ids = @($testId)
    } | ConvertTo-Json -Compress

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Path
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            return $false
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($request)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(5000)) {
            try { $process.Kill() } catch { }
            return $false
        }

        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        if ($process.ExitCode -ne 0 -or -not [string]::IsNullOrEmpty($stderr) -or $stdout.Length -gt 4096) {
            return $false
        }

        try {
            $response = $stdout | ConvertFrom-Json
        }
        catch {
            return $false
        }
        if ($response.protocolVersion -ne 1 -or @($response.values.PSObject.Properties).Count -ne 0) {
            return $false
        }
        $errorProperty = $response.errors.PSObject.Properties[$testId]
        return $null -ne $errorProperty -and $errorProperty.Value.message -eq 'not found'
    }
    finally {
        $process.Dispose()
    }
}

function Remove-OpenClawResolverBuildDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$ResolverDirectory
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    if (-not (Test-OpenClawChildPath -Parent $ResolverDirectory -Child $Path)) {
        throw 'The resolver build directory escaped the private resolver directory.'
    }
    $buildItem = Get-Item -LiteralPath $Path -Force
    if (-not $buildItem.PSIsContainer -or ($buildItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The resolver build path was not a normal directory.'
    }

    foreach ($child in @(Get-ChildItem -LiteralPath $Path -Force)) {
        if ($child.PSIsContainer -or ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The resolver build directory contained an unexpected child.'
        }
        [IO.File]::Delete($child.FullName)
    }
    [IO.Directory]::Delete($Path, $false)
}

function Install-OpenClawCredentialResolver {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [string]$StateDirectory
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'The credential resolver can only be installed on Windows.'
    }
    [void](Initialize-OpenClawCredentialNative)
    $sourcePath = Get-OpenClawResolverSourcePath
    if ($WhatIfPreference) {
        $previewRoot = $StateDirectory
        if ([string]::IsNullOrWhiteSpace($previewRoot)) {
            $previewLocalApplicationData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
            if ([string]::IsNullOrWhiteSpace($previewLocalApplicationData)) {
                throw 'The current user LocalApplicationData directory could not be determined.'
            }
            $previewRoot = Join-Path $previewLocalApplicationData 'OpenClawEasySetup'
        }
        $previewDestination = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetFullPath($previewRoot)) 'State\Resolver\OpenClawEasySetup.SecretResolver.exe'))
        [void]$PSCmdlet.ShouldProcess($previewDestination, 'Compile and install the OpenClaw credential resolver')
        return
    }
    $directories = Initialize-OpenClawStateDirectory -Path $StateDirectory
    $statePath = Get-OpenClawVerifiedNormalPath -Path $directories.State -Kind Container
    $resolverDirectory = [IO.Path]::GetFullPath((Join-Path $statePath 'Resolver'))
    if (-not (Test-OpenClawChildPath -Parent $statePath -Child $resolverDirectory)) {
        throw 'The resolver destination escaped the private State directory.'
    }

    if (Test-Path -LiteralPath $resolverDirectory) {
        [void](Get-OpenClawVerifiedNormalPath -Path $resolverDirectory -Kind Container)
    }
    else {
        [void][IO.Directory]::CreateDirectory($resolverDirectory)
        [void](Get-OpenClawVerifiedNormalPath -Path $resolverDirectory -Kind Container)
    }
    Assert-OpenClawInheritedPrivateAcl -Path $resolverDirectory -NormalizeOwner

    $destinationPath = [IO.Path]::GetFullPath((Join-Path $resolverDirectory 'OpenClawEasySetup.SecretResolver.exe'))
    if (-not (Test-OpenClawChildPath -Parent $resolverDirectory -Child $destinationPath)) {
        throw 'The resolver executable destination escaped the private resolver directory.'
    }
    if (-not $PSCmdlet.ShouldProcess($destinationPath, 'Compile and install the OpenClaw credential resolver')) {
        return
    }

    $installLockPath = Join-Path $resolverDirectory '.install.lock'
    $lock = $null
    $buildDirectory = $null
    try {
        $lock = New-Object IO.FileStream(
            $installLockPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None,
            1,
            [IO.FileOptions]::DeleteOnClose
        )
        Assert-OpenClawInheritedPrivateAcl -Path $installLockPath -NormalizeOwner

        $buildDirectory = Join-Path $resolverDirectory ('.build-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($buildDirectory)
        [void](Get-OpenClawVerifiedNormalPath -Path $buildDirectory -Kind Container)
        Assert-OpenClawInheritedPrivateAcl -Path $buildDirectory -NormalizeOwner

        $compiledPath = Join-Path $buildDirectory 'OpenClawEasySetup.SecretResolver.exe'
        $provider = $null
        try {
            Add-Type -AssemblyName Microsoft.CSharp -ErrorAction Stop
            $provider = New-Object Microsoft.CSharp.CSharpCodeProvider
            $parameters = New-Object CodeDom.Compiler.CompilerParameters
            $parameters.GenerateExecutable = $true
            $parameters.GenerateInMemory = $false
            $parameters.IncludeDebugInformation = $false
            $parameters.TreatWarningsAsErrors = $true
            $parameters.WarningLevel = 4
            $parameters.OutputAssembly = $compiledPath
            $parameters.CompilerOptions = '/nologo /optimize+ /checked+ /platform:anycpu /target:exe'
            $parameters.TempFiles = New-Object CodeDom.Compiler.TempFileCollection($buildDirectory, $false)
            [void]$parameters.ReferencedAssemblies.Add('System.dll')
            [void]$parameters.ReferencedAssemblies.Add('System.Core.dll')
            [void]$parameters.ReferencedAssemblies.Add('System.Web.Extensions.dll')
            $results = $provider.CompileAssemblyFromFile($parameters, $sourcePath)
        }
        catch {
            throw 'The credential resolver compiler could not be started.'
        }
        finally {
            if ($null -ne $provider) {
                $provider.Dispose()
            }
        }

        if ($results.Errors.HasErrors) {
            $firstError = @($results.Errors | Where-Object { -not $_.IsWarning } | Select-Object -First 1)
            if ($firstError.Count -gt 0) {
                throw ('The credential resolver compilation failed ({0} at line {1}, column {2}).' -f $firstError[0].ErrorNumber, $firstError[0].Line, $firstError[0].Column)
            }
            throw 'The credential resolver compilation failed.'
        }
        if (-not (Test-OpenClawResolverAssembly -Path $compiledPath)) {
            throw 'The compiled credential resolver assembly failed validation.'
        }
        Assert-OpenClawInheritedPrivateAcl -Path $compiledPath -NormalizeOwner
        if (-not (Test-OpenClawResolverProtocol -Path $compiledPath)) {
            throw 'The compiled credential resolver failed its protocol self-test.'
        }

        $compiledHash = (Get-FileHash -LiteralPath $compiledPath -Algorithm SHA256).Hash
        $backupPath = Join-Path $resolverDirectory ('.previous-' + [Guid]::NewGuid().ToString('N') + '.exe')
        if (Test-Path -LiteralPath $destinationPath) {
            [void](Get-OpenClawVerifiedNormalPath -Path $destinationPath -Kind Leaf)
            Assert-OpenClawInheritedPrivateAcl -Path $destinationPath -NormalizeOwner
            [IO.File]::Replace($compiledPath, $destinationPath, $backupPath, $true)
        }
        else {
            [IO.File]::Move($compiledPath, $destinationPath)
        }

        if (-not (Test-OpenClawResolverAssembly -Path $destinationPath)) {
            throw 'The installed credential resolver assembly failed validation.'
        }
        Assert-OpenClawInheritedPrivateAcl -Path $destinationPath -NormalizeOwner
        $installedHash = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash
        if (-not [string]::Equals($compiledHash, $installedHash, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The installed credential resolver hash did not match the verified build.'
        }
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
            $backupItem = Get-Item -LiteralPath $backupPath -Force
            if (($backupItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not (Test-OpenClawChildPath -Parent $resolverDirectory -Child $backupPath)) {
                throw 'The resolver backup path failed validation.'
            }
            [IO.File]::Delete($backupPath)
        }

        return [pscustomobject]@{
            Path = $destinationPath
            ProtocolVersion = 1
            SourceSha256 = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
            BinarySha256 = $installedHash
        }
    }
    finally {
        if ($null -ne $lock) {
            $lock.Dispose()
        }
        if ($null -ne $buildDirectory -and (Test-Path -LiteralPath $buildDirectory)) {
            Remove-OpenClawResolverBuildDirectory -Path $buildDirectory -ResolverDirectory $resolverDirectory
        }
    }
}

Export-ModuleMember -Function @(
    'New-OpenClawCredentialId',
    'Test-OpenClawCredentialId',
    'Get-OpenClawCredentialUtf8ByteCount',
    'Set-OpenClawCredential',
    'Test-OpenClawCredential',
    'Remove-OpenClawCredential',
    'Install-OpenClawCredentialResolver'
)
