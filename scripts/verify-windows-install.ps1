# The controller needs elevation only to provision and clean its disposable user.
# Installation, filesystem probes, application startup and uninstall run as that
# standard user. Never retry those checks with the controller's administrator token.
[CmdletBinding()]
param(
    [string]$InstallerPath,
    [string]$OutputDirectory,
    [string]$SharedRootDirectory,
    [ValidateRange(60, 900)][int]$TimeoutSeconds = 240,
    [switch]$Worker,
    [string]$SharedDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'This verification must run on Windows.' }

if ($Worker) {
    $report = [ordered]@{ success = $false; identity = $null; checks = [ordered]@{}; error = $null }
    $application = $null
    $installDirectory = $null
    $workerLog = Join-Path $SharedDirectory 'worker.log'
    try {
        $config = Get-Content -LiteralPath (Join-Path $SharedDirectory 'config.json') -Raw | ConvertFrom-Json
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        $isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $administratorSidPresent = @($identity.Groups | Where-Object { $_.Value -eq 'S-1-5-32-544' }).Count -ne 0
        if ($identity.User.Value -ne $config.expectedUserSid -or $isAdministrator -or $administratorSidPresent) {
            throw 'Worker identity is not the expected disposable non-administrator user.'
        }

        # Use this user's loaded profile and reset inherited test/settings/temp paths.
        $profileKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($identity.User.Value)"
        $profileRoot = [Environment]::ExpandEnvironmentVariables((Get-ItemPropertyValue -LiteralPath $profileKey -Name ProfileImagePath))
        $localData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData, [Environment+SpecialFolderOption]::DoNotVerify)
        $roamingData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData, [Environment+SpecialFolderOption]::DoNotVerify)
        foreach ($folder in @($localData, $roamingData)) {
            if (-not $folder.StartsWith($profileRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Worker known folders are outside its own loaded profile.'
            }
        }
        $env:USERPROFILE = $profileRoot
        $env:LOCALAPPDATA = $localData
        $env:APPDATA = $roamingData
        $env:TEMP = Join-Path $localData 'Temp'
        $env:TMP = $env:TEMP
        Remove-Item Env:FLUTTER_DEV_SETTINGS_PATH -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $env:TEMP -Force | Out-Null

        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class InstallCheckToken {
    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetTokenInformation(IntPtr token, int kind,
        out int value, int length, out int returned);
    public static int Read(IntPtr token, int kind) {
        int value, returned;
        if (!GetTokenInformation(token, kind, out value, sizeof(int), out returned))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return value;
    }
}
'@
        $tokenHandle = $identity.AccessToken.DangerousGetHandle()
        $isElevated = [InstallCheckToken]::Read($tokenHandle, 20) -ne 0
        $elevationType = [InstallCheckToken]::Read($tokenHandle, 18)
        $report.identity = [ordered]@{
            name = $identity.Name
            sid = $identity.User.Value
            administratorRole = $isAdministrator
            administratorSidPresent = $administratorSidPresent
            tokenIsElevated = $isElevated
            tokenElevationType = $elevationType
            profile = $profileRoot
            localAppData = $localData
            appData = $roamingData
        }
        $report.identity | ConvertTo-Json | Set-Content -LiteralPath $workerLog -Encoding utf8
        if ($isElevated -or $elevationType -eq 2) { throw 'Worker unexpectedly has an elevated token.' }

        # A fresh user's HKCU contains no previous installation directory.
        # Deliberately omit /DIR to exercise the actual per-user installer default.
        $installDirectory = Join-Path $localData 'Programs/Flutter Dev'
        $report.installDirectory = $installDirectory
        $installLog = Join-Path $SharedDirectory 'install.log'
        $installer = Start-Process -FilePath (Join-Path $SharedDirectory 'package.exe') -ArgumentList @(
            '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', "/LOG=`"$installLog`""
        ) -WorkingDirectory $SharedDirectory -Wait -PassThru
        $report.checks.installExitCode = $installer.ExitCode
        if ($installer.ExitCode -ne 0) { throw "Standard-user installation failed: $($installer.ExitCode)" }
        foreach ($file in @('flutter_dev.exe', 'flutter_windows.dll', 'flutter_dev_core.dll', 'data/flutter_assets/AssetManifest.bin')) {
            if (-not (Test-Path -LiteralPath (Join-Path $installDirectory $file) -PathType Leaf)) {
                throw "Default per-user installation is missing $file"
            }
        }
        $report.checks.defaultPerUserInstallation = $true

        $probeFolder = Join-Path $installDirectory 'permission-check'
        New-Item -ItemType Directory -Path $probeFolder | Out-Null
        Set-Content -LiteralPath (Join-Path $probeFolder 'probe.txt') -Value 'standard-user write probe' -Encoding utf8
        Remove-Item -LiteralPath $probeFolder -Recurse -Force
        $report.checks.installDirectoryWritable = $true

        $settingsDirectory = Join-Path $roamingData 'flutter_dev'
        New-Item -ItemType Directory -Path $settingsDirectory -Force | Out-Null
        $settingsProbe = Join-Path $settingsDirectory 'verify-write.json'
        Set-Content -LiteralPath $settingsProbe -Value '{"standardUserWriteProbe":true}' -Encoding utf8
        if ((Get-Content -LiteralPath $settingsProbe -Raw | ConvertFrom-Json).standardUserWriteProbe -ne $true) {
            throw 'Could not read back the standard-user settings directory write.'
        }
        Remove-Item -LiteralPath $settingsProbe
        $report.checks.settingsDirectoryWritable = $true
        $report.settingsDirectory = $settingsDirectory

        $application = Start-Process -FilePath (Join-Path $installDirectory 'flutter_dev.exe') -WorkingDirectory $installDirectory -PassThru
        if ($application.WaitForExit(10000)) {
            throw "Standard-user application exited during the 10-second startup check: $($application.ExitCode)"
        }
        $report.checks.applicationAliveAfterTenSeconds = $true
        Add-Content -LiteralPath $workerLog -Value 'Default installation, directory writes and 10-second process survival passed.'
    } catch {
        $report.error = $_.Exception.Message
        Add-Content -LiteralPath $workerLog -Value $report.error
    } finally {
        if ($null -ne $application -and -not $application.HasExited) {
            Stop-Process -Id $application.Id -Force -ErrorAction SilentlyContinue
            $application.WaitForExit(5000) | Out-Null
        }
        try {
            if ($installDirectory -and (Test-Path -LiteralPath (Join-Path $installDirectory 'unins000.exe'))) {
                $uninstallLog = Join-Path $SharedDirectory 'uninstall.log'
                $uninstall = Start-Process -FilePath (Join-Path $installDirectory 'unins000.exe') -ArgumentList @(
                    '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$uninstallLog`""
                ) -WorkingDirectory $SharedDirectory -Wait -PassThru
                $report.checks.uninstallExitCode = $uninstall.ExitCode
                if ($uninstall.ExitCode -ne 0 -or (Test-Path -LiteralPath (Join-Path $installDirectory 'flutter_dev.exe'))) {
                    throw "Standard-user uninstall failed: $($uninstall.ExitCode)"
                }
                $report.checks.standardUserUninstall = $true
            }
        } catch {
            $report.error = "$($report.error) Uninstall: $($_.Exception.Message)".Trim()
        }
        $report.success = -not $report.error -and $report.checks.Contains('standardUserUninstall') -and $report.checks.standardUserUninstall
        $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $SharedDirectory 'worker-result.pending') -Encoding utf8
        Move-Item -LiteralPath (Join-Path $SharedDirectory 'worker-result.pending') -Destination (Join-Path $SharedDirectory 'worker-result.json') -Force
    }
    if (-not $report.success) { exit 1 }
    exit 0
}

$controllerIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$controllerPrincipal = [Security.Principal.WindowsPrincipal]::new($controllerIdentity)
if (-not $controllerPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Controller requires elevation to create and remove its temporary standard user.'
}
$controllerProcess = Get-Process -Id $PID
if ($controllerProcess.SessionId -eq 0) {
    throw 'Session 0 cannot run this desktop standard-user check. Run from an elevated administrator desktop in a nonzero session; no test account was created.'
}
if (-not $InstallerPath) { throw '-InstallerPath is required.' }
$InstallerPath = (Resolve-Path -LiteralPath $InstallerPath).Path
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) 'build/windows/standard-user-validation'
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
foreach ($oldLog in @('result.json', 'worker-result.json', 'worker.log', 'worker-stdout.log', 'worker-stderr.log', 'install.log', 'uninstall.log')) {
    $oldPath = Join-Path $OutputDirectory $oldLog
    if (Test-Path -LiteralPath $oldPath -PathType Leaf) { Remove-Item -LiteralPath $oldPath }
}
$runId = [guid]::NewGuid().ToString('N')
$userName = 'fdcheck' + $runId.Substring(0, 10)
$qualifiedUser = "$env:COMPUTERNAME\$userName"
if (-not $SharedRootDirectory) { $SharedRootDirectory = $env:ProgramData }
$SharedRootDirectory = (Resolve-Path -LiteralPath $SharedRootDirectory).Path
$SharedDirectory = Join-Path $SharedRootDirectory ('FlutterDev-install-check-' + $runId)
$user = $null
$workerProcess = $null
$workerProcessHandle = [IntPtr]::Zero
$ownedProcessesExited = $false
$batchLogonRightAdded = $false
$sharedCreated = $false
$profilePrivileges = $null
$profileLease = $null
$securePassword = $null
$passwordBytes = $null
$result = [ordered]@{ success = $false; runId = $runId; startedAtUtc = [DateTime]::UtcNow.ToString('o'); controllerSessionId = $controllerProcess.SessionId; transport = $null; userName = $qualifiedUser; worker = $null; error = $null; cleanupErrors = @() }
try {
    # Passwords are generated in memory and never written to arguments, logs or JSON.
    $passwordBytes = New-Object byte[] 32
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $random.GetBytes($passwordBytes) } finally { $random.Dispose() }
    $plainPassword = 'Fd!Aa7' + [Convert]::ToBase64String($passwordBytes)
    $securePassword = ConvertTo-SecureString $plainPassword -AsPlainText -Force
    $user = New-LocalUser -Name $userName -Password $securePassword -AccountNeverExpires -PasswordNeverExpires -UserMayNotChangePassword -Description 'Disposable Flutter Dev installer validation'
    $result.userSid = $user.SID.Value
    $usersGroup = Get-LocalGroup -SID 'S-1-5-32-545'
    Add-LocalGroupMember -Group $usersGroup -Member $user

    New-Item -ItemType Directory -Path $SharedDirectory | Out-Null
    $sharedCreated = $true
    $acl = Get-Acl -LiteralPath $SharedDirectory
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sidText in @($controllerIdentity.User.Value, 'S-1-5-18', 'S-1-5-32-544', $user.SID.Value)) {
        $rights = if ($sidText -eq $user.SID.Value) { 'Modify' } else { 'FullControl' }
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sidText), $rights, 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $SharedDirectory -AclObject $acl
    Copy-Item -LiteralPath $InstallerPath -Destination (Join-Path $SharedDirectory 'package.exe')
    Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $SharedDirectory 'verify.ps1')
    @{ expectedUserSid = $user.SID.Value } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $SharedDirectory 'config.json') -Encoding utf8

    $powershellExe = (Get-Process -Id $PID).Path
    if (-not [Environment]::Is64BitProcess -or -not (Test-Path -LiteralPath $powershellExe)) {
        throw 'Run the controller with 64-bit Windows PowerShell 5.1 or PowerShell 7.'
    }
    $workerArguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$(Join-Path $SharedDirectory 'verify.ps1')`" -Worker -SharedDirectory `"$SharedDirectory`""
    $workerResult = Join-Path $SharedDirectory 'worker-result.json'
    # Only this disposable account gets the batch logon right for the explicit
    # profile lease. The desktop worker uses Credential without LoadUserProfile.
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
public static class InstallCheckBatchLogon {
    [StructLayout(LayoutKind.Sequential)]
    private struct Attributes {
        public int Length; public IntPtr Root, Name; public uint Flags;
        public IntPtr Descriptor, Quality;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct Text { public ushort Length, Maximum; public IntPtr Buffer; }
    [DllImport("advapi32.dll")]
    private static extern uint LsaOpenPolicy(IntPtr system, ref Attributes attributes, uint access, out IntPtr policy);
    [DllImport("advapi32.dll")]
    private static extern uint LsaAddAccountRights(IntPtr policy, byte[] sid, Text[] rights, uint count);
    [DllImport("advapi32.dll")]
    private static extern uint LsaRemoveAccountRights(IntPtr policy, byte[] sid, [MarshalAs(UnmanagedType.U1)] bool all, Text[] rights, uint count);
    [DllImport("advapi32.dll")]
    private static extern uint LsaNtStatusToWinError(uint status);
    [DllImport("advapi32.dll")]
    private static extern uint LsaClose(IntPtr policy);
    private static void Check(uint status) {
        if (status != 0) throw new Win32Exception((int)LsaNtStatusToWinError(status));
    }
    public static void Set(string sidText, bool enabled) {
        var sid = new SecurityIdentifier(sidText);
        var bytes = new byte[sid.BinaryLength]; sid.GetBinaryForm(bytes, 0);
        var attributes = new Attributes { Length = Marshal.SizeOf(typeof(Attributes)) };
        IntPtr policy; Check(LsaOpenPolicy(IntPtr.Zero, ref attributes, 0x810, out policy));
        var name = "SeBatchLogonRight";
        var right = new Text { Length = (ushort)(name.Length * 2), Maximum = (ushort)((name.Length + 1) * 2), Buffer = Marshal.StringToHGlobalUni(name) };
        try {
            Check(enabled ? LsaAddAccountRights(policy, bytes, new[] { right }, 1) :
                LsaRemoveAccountRights(policy, bytes, false, new[] { right }, 1));
        } finally { Marshal.FreeHGlobal(right.Buffer); LsaClose(policy); }
    }
}

// Keep the controller's privilege changes scoped, including constructor failures.
public sealed class InstallCheckProfilePrivileges : IDisposable {
    [StructLayout(LayoutKind.Sequential)]
    private struct Luid { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)]
    private struct Privileges { public uint Count; public Luid Id; public uint Flags; }
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool LookupPrivilegeValue(string system, string name, out Luid id);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool AdjustTokenPrivileges(IntPtr token, bool disable, ref Privileges value,
        int length, out Privileges previous, out int returned);
    private IntPtr token;
    private readonly Privileges[] previous = new Privileges[2];
    private int changed;
    public InstallCheckProfilePrivileges() {
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            foreach (var name in new[] { "SeBackupPrivilege", "SeRestorePrivilege" }) {
                var value = new Privileges { Count = 1, Flags = 2 };
                if (!LookupPrivilegeValue(null, name, out value.Id))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                int length;
                if (!AdjustTokenPrivileges(token, false, ref value, Marshal.SizeOf(typeof(Privileges)), out previous[changed], out length))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                var error = Marshal.GetLastWin32Error();
                if (error != 0) throw new Win32Exception(error);
                changed++;
            }
        } catch { Dispose(); throw; }
    }
    public void Dispose() {
        if (token == IntPtr.Zero) return;
        Exception failure = null;
        try {
            for (var index = changed - 1; index >= 0; index--) {
                Privileges ignored; int length;
                if (!AdjustTokenPrivileges(token, false, ref previous[index], Marshal.SizeOf(typeof(Privileges)), out ignored, out length))
                    failure = new Win32Exception(Marshal.GetLastWin32Error());
                else if (Marshal.GetLastWin32Error() != 0)
                    failure = new Win32Exception(Marshal.GetLastWin32Error());
            }
        } finally { CloseHandle(token); token = IntPtr.Zero; }
        if (failure != null) throw failure;
    }
}

// The lease owns exactly the token and hProfile returned for this test user.
// UnloadUserProfile closes hProfile; never close/force-unload registry hives.
public sealed class InstallCheckProfileLease : IDisposable {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ProfileInfo {
        public int Size, Flags;
        public string UserName, ProfilePath, DefaultPath, ServerName, PolicyPath;
        public IntPtr Profile;
    }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool LogonUser(string user, string domain, string password, int type, int provider, out IntPtr token);
    [DllImport("userenv.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool LoadUserProfile(IntPtr token, ref ProfileInfo profile);
    [DllImport("userenv.dll", SetLastError = true)]
    private static extern bool UnloadUserProfile(IntPtr token, IntPtr profile);
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr process, out uint code);
    private IntPtr token, profile;
    public static InstallCheckProfileLease Load(string user, string domain, string password) {
        var lease = new InstallCheckProfileLease();
        if (!LogonUser(user, domain, password, 4, 0, out lease.token))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        var info = new ProfileInfo { Size = Marshal.SizeOf(typeof(ProfileInfo)), Flags = 1, UserName = user };
        if (!LoadUserProfile(lease.token, ref info)) {
            var error = Marshal.GetLastWin32Error();
            CloseHandle(lease.token); lease.token = IntPtr.Zero;
            throw new Win32Exception(error);
        }
        lease.profile = info.Profile;
        return lease;
    }
    public static int ProcessExitCode(IntPtr process) {
        uint code;
        if (!GetExitCodeProcess(process, out code)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return unchecked((int)code);
    }
    public void Dispose() {
        try {
            if (profile != IntPtr.Zero) {
                if (!UnloadUserProfile(token, profile))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                profile = IntPtr.Zero;
            }
        } finally {
            if (token != IntPtr.Zero) { CloseHandle(token); token = IntPtr.Zero; }
        }
    }
}
'@
    [InstallCheckBatchLogon]::Set($user.SID.Value, $true)
    $batchLogonRightAdded = $true
    $result.batchLogonRightGrantedToTemporaryUser = $true
    $profilePrivileges = [InstallCheckProfilePrivileges]::new()
    $profileLease = [InstallCheckProfileLease]::Load($userName, $env:COMPUTERNAME, $plainPassword)
    $result.explicitProfileLeaseLoaded = $true
    $loadedProfile = Get-CimInstance Win32_UserProfile -Filter "SID='$($user.SID.Value)'"
    if (-not $loadedProfile) { throw 'Explicit profile lease did not create the expected user profile.' }
    $workerEnvironment = @{
        USERPROFILE = $loadedProfile.LocalPath
        LOCALAPPDATA = Join-Path $loadedProfile.LocalPath 'AppData/Local'
        APPDATA = Join-Path $loadedProfile.LocalPath 'AppData/Roaming'
        TEMP = Join-Path $loadedProfile.LocalPath 'AppData/Local/Temp'
        TMP = Join-Path $loadedProfile.LocalPath 'AppData/Local/Temp'
    }
    New-Item -ItemType Directory -Path $workerEnvironment.TEMP -Force | Out-Null
    $previousEnvironment = @{}
    foreach ($name in $workerEnvironment.Keys) { $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    try {
        foreach ($name in $workerEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $workerEnvironment[$name], 'Process') }
        $credential = [PSCredential]::new($qualifiedUser, $securePassword)
        # Do not pass -LoadUserProfile: the controller owns the only profile lease.
        $workerProcess = Start-Process -FilePath $powershellExe -ArgumentList $workerArguments -Credential $credential -WorkingDirectory $SharedDirectory -RedirectStandardOutput (Join-Path $SharedDirectory 'worker-stdout.log') -RedirectStandardError (Join-Path $SharedDirectory 'worker-stderr.log') -PassThru
        $workerProcessHandle = $workerProcess.Handle
    } finally {
        foreach ($name in $previousEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process') }
        $result.controllerEnvironmentRestored = $true
        $credential = $null
    }
    $result.transport = 'Start-Process-Credential-ExplicitProfile'
    $plainPassword = $null
    [Array]::Clear($passwordBytes, 0, $passwordBytes.Length)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while (-not (Test-Path -LiteralPath $workerResult)) {
        $exitCode = [InstallCheckProfileLease]::ProcessExitCode($workerProcessHandle)
        if ($exitCode -ne 259) {
            if (Test-Path -LiteralPath $workerResult) { break }
            throw "Standard-user worker exited before producing a result: $exitCode"
        }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Standard-user verification timed out; no administrator fallback is permitted.' }
        Start-Sleep -Milliseconds 500
    }
    $result.worker = Get-Content -LiteralPath $workerResult -Raw | ConvertFrom-Json
    if (-not $result.worker.success) { throw "Standard-user verification failed: $($result.worker.error)" }
    if ($result.worker.identity.sid -ne $user.SID.Value -or $result.worker.identity.administratorRole -or $result.worker.identity.administratorSidPresent -or $result.worker.identity.tokenIsElevated) {
        throw 'Worker result did not prove the expected standard-user token.'
    }
    if (-not $workerProcess.WaitForExit(15000)) { throw 'Standard-user worker did not exit after reporting.' }
    $result.workerExitCode = [InstallCheckProfileLease]::ProcessExitCode($workerProcessHandle)
    if ($result.workerExitCode -ne 0) { throw "Standard-user worker exit code: $($result.workerExitCode)" }
    $result.success = $true
} catch {
    $result.error = $_.Exception.Message
} finally {
    # This random user is owned exclusively by this run. No other users' processes,
    # directories, settings, projects or applications are inspected or terminated.
    if ($user) {
        if ($batchLogonRightAdded) {
            try { [InstallCheckBatchLogon]::Set($user.SID.Value, $false) }
            catch { $result.cleanupErrors += "Temporary batch logon right: $($_.Exception.Message)" }
        }
        try {
            if ($null -ne $workerProcess -and (Test-Path -LiteralPath (Join-Path $SharedDirectory 'worker-result.json'))) {
                $workerProcess.WaitForExit(10000) | Out-Null
            }
            $ownedProcesses = @(Get-Process -IncludeUserName -ErrorAction SilentlyContinue | Where-Object { $_.UserName -eq $qualifiedUser })
            foreach ($owned in $ownedProcesses) {
                try {
                    if (-not $owned.HasExited) { $owned.Kill() }
                    if (-not $owned.WaitForExit(5000)) { throw "Owned process did not exit: $($owned.Id)" }
                } catch {
                    if (Get-Process -Id $owned.Id -ErrorAction SilentlyContinue) { throw }
                } finally { $owned.Dispose() }
            }
            if ($null -ne $workerProcess) {
                if (-not $workerProcess.WaitForExit(5000)) { throw 'Worker process is still running before profile unload.' }
                if ($workerProcessHandle -ne [IntPtr]::Zero) { $result.workerExitCode = [InstallCheckProfileLease]::ProcessExitCode($workerProcessHandle) }
            }
            if (@(Get-Process -IncludeUserName -ErrorAction SilentlyContinue | Where-Object { $_.UserName -eq $qualifiedUser }).Count -ne 0) {
                throw 'Owned user still has a running process before profile unload.'
            }
            $ownedProcessesExited = $true
            $result.ownedProcessesExitedBeforeProfileUnload = $true
        } catch { $result.cleanupErrors += "Owned processes: $($_.Exception.Message)" }
    }
    if ($null -ne $workerProcess) { $workerProcess.Dispose() }
    if ($sharedCreated) {
        try {
            foreach ($logFile in @('worker-result.json', 'worker.log', 'worker-stdout.log', 'worker-stderr.log', 'install.log', 'uninstall.log')) {
                $source = Join-Path $SharedDirectory $logFile
                if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $OutputDirectory $logFile) -Force }
            }
            Remove-Item -LiteralPath $SharedDirectory -Recurse -Force
        } catch { $result.cleanupErrors += "Shared directory: $($_.Exception.Message)" }
    }
    if ($null -ne $profileLease) {
        if ($ownedProcessesExited) {
            try {
                $profileLease.Dispose()
                $result.explicitProfileLeaseUnloaded = $true
            } catch { $result.cleanupErrors += "Owned profile lease: $($_.Exception.Message)" }
        } else {
            $result.cleanupErrors += 'Owned profile lease was not unloaded because process exit could not be confirmed.'
        }
    }
    if ($user) {
        try {
            $profile = Get-CimInstance Win32_UserProfile -Filter "SID='$($user.SID.Value)'"
            for ($attempt = 0; $profile -and $profile.Loaded -and $attempt -lt 30; $attempt++) {
                Start-Sleep -Seconds 1
                $profile = Get-CimInstance Win32_UserProfile -Filter "SID='$($user.SID.Value)'"
            }
            if ($profile) {
                $result.profileCleanup = [ordered]@{ sid = $profile.SID; path = $profile.LocalPath; loadedBeforeRemoval = $profile.Loaded; removed = $false }
                $profile | Remove-CimInstance
                $result.profileCleanup.removed = $true
            }
        } catch { $result.cleanupErrors += "Owned profile: $($_.Exception.Message)" }
        try { Remove-LocalUser -SID $user.SID } catch { $result.cleanupErrors += "Owned local user: $($_.Exception.Message)" }
    }
    if ($null -ne $profilePrivileges) {
        try {
            $profilePrivileges.Dispose()
            $result.controllerPrivilegesRestored = $true
        } catch { $result.cleanupErrors += "Controller privileges: $($_.Exception.Message)" }
    }
    $plainPassword = $null
    if ($null -ne $securePassword) { $securePassword.Dispose() }
    if ($null -ne $passwordBytes) { [Array]::Clear($passwordBytes, 0, $passwordBytes.Length) }
    if ($result.cleanupErrors.Count -gt 0) { $result.success = $false }
    $result.finishedAtUtc = [DateTime]::UtcNow.ToString('o')
    $result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'result.json') -Encoding utf8
}
if (-not $result.success) { throw "Standard-user installation verification failed. See $(Join-Path $OutputDirectory 'result.json')" }
Write-Host "Standard-user installation, writable user directories, startup, uninstall and cleanup passed. Results: $OutputDirectory"
