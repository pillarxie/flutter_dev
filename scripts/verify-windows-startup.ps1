# Run in the desktop session whose visible windows should be measured. Session 0
# measurements are recorded as such and must not be called interactive-user QA.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ExecutablePath,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$ProjectPath,
    [string]$SdkPath,
    [ValidateRange(1000, 60000)][int]$MaxWindowMilliseconds = 10000,
    [ValidateRange(5, 120)][int]$ObserveSeconds = 20,
    [switch]$Worker,
    [string]$LaunchGate
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'Windows is required.' }
$ExecutablePath = (Resolve-Path -LiteralPath $ExecutablePath).Path
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
if (-not $Worker) {
    # A GUI started directly from PowerShell would attach its parent's console,
    # concealing the Explorer-launched application's console-allocation defect.
    # Detach only a dedicated worker, never the caller's interactive terminal.
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public sealed class FlutterDevStartupJob : IDisposable {
    [StructLayout(LayoutKind.Sequential)] private struct BasicLimits {
        public long processTime, jobTime; public uint flags;
        public UIntPtr minimumWorkingSet, maximumWorkingSet;
        public uint activeProcessLimit; public UIntPtr affinity;
        public uint priorityClass, schedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)] private struct IoCounters {
        public ulong readCount, writeCount, otherCount, readBytes, writeBytes, otherBytes;
    }
    [StructLayout(LayoutKind.Sequential)] private struct ExtendedLimits {
        public BasicLimits basic; public IoCounters io;
        public UIntPtr processMemory, jobMemory, peakProcessMemory, peakJobMemory;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetInformationJobObject(IntPtr job, int kind, ref ExtendedLimits info, uint length);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetExitCodeProcess(IntPtr process, out uint code);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CloseHandle(IntPtr handle);
    private IntPtr handle;
    public FlutterDevStartupJob() {
        handle = CreateJobObject(IntPtr.Zero, null);
        if (handle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Create startup verification job");
        var limits = new ExtendedLimits(); limits.basic.flags = 0x2000;
        if (!SetInformationJobObject(handle, 9, ref limits, (uint)Marshal.SizeOf(typeof(ExtendedLimits)))) {
            int error = Marshal.GetLastWin32Error(); CloseHandle(handle); handle = IntPtr.Zero;
            throw new Win32Exception(error, "Configure startup verification job");
        }
    }
    public void Assign(IntPtr process) {
        if (!AssignProcessToJobObject(handle, process)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Assign dedicated startup worker");
    }
    public static uint ExitCode(IntPtr process) {
        uint code;
        if (!GetExitCodeProcess(process, out code)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Read startup worker exit code");
        if (code == 259) throw new InvalidOperationException("Startup worker is still active");
        return code;
    }
    public void Dispose() {
        IntPtr owned = handle; handle = IntPtr.Zero;
        if (owned != IntPtr.Zero && !CloseHandle(owned)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Close startup verification job");
    }
}
'@
    $runId = [guid]::NewGuid().ToString('N')
    $gateDirectory = Join-Path $OutputDirectory ("launch-$runId")
    New-Item -ItemType Directory -Path $gateDirectory | Out-Null
    $gatePath = Join-Path $gateDirectory 'assigned'
    $reportPath = Join-Path $OutputDirectory 'startup-result.json'
    $controllerPath = Join-Path $OutputDirectory 'startup-controller-result.json'
    foreach ($oldReport in @($reportPath, $controllerPath)) {
        if (Test-Path -LiteralPath $oldReport) { Remove-Item -LiteralPath $oldReport -Force }
    }
    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Worker', '-LaunchGate', "`"$gatePath`"", '-ExecutablePath', "`"$ExecutablePath`"", '-OutputDirectory', "`"$OutputDirectory`"", '-MaxWindowMilliseconds', $MaxWindowMilliseconds, '-ObserveSeconds', $ObserveSeconds)
    if ($ProjectPath) { $arguments += @('-ProjectPath', "`"$([IO.Path]::GetFullPath($ProjectPath))`"") }
    if ($SdkPath) { $arguments += @('-SdkPath', "`"$([IO.Path]::GetFullPath($SdkPath))`"") }
    $workerProcess = $null
    $job = $null
    $report = $null
    $controller = [ordered]@{ success = $false; runId = $runId; workerAssignedJob = $false; workerExitCode = $null; error = $null; cleanupErrors = @() }
    try {
        $job = [FlutterDevStartupJob]::new()
        $workerProcess = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $arguments -WindowStyle Hidden -RedirectStandardOutput (Join-Path $OutputDirectory 'startup-worker-stdout.log') -RedirectStandardError (Join-Path $OutputDirectory 'startup-worker-stderr.log') -PassThru
        # Force a real handle before waiting: WinPS 5.1 can otherwise leave the
        # Start-Process object's cached ExitCode unset after a successful wait.
        $workerHandle = $workerProcess.Handle
        $job.Assign($workerHandle)
        $controller.workerAssignedJob = $true
        [IO.File]::WriteAllText($gatePath, $runId)
        if (-not $workerProcess.WaitForExit($MaxWindowMilliseconds + ($ObserveSeconds + 45) * 1000)) {
            throw 'Window verification worker timed out.'
        }
        $controller.workerExitCode = [FlutterDevStartupJob]::ExitCode($workerHandle)
        if (-not (Test-Path -LiteralPath $reportPath)) { throw 'Window verification worker produced no result; inspect its stderr log.' }
        $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
        if ($controller.workerExitCode -ne 0 -or -not $report.success) { throw "Window verification failed: $($report.error)" }
        $controller.success = $true
    } catch {
        $controller.error = $_.Exception.Message
    } finally {
        # Closing this controller-owned handle kills only this worker's assigned
        # tree, including Flutter and its descendants if the worker timed out.
        if ($job) {
            try { $job.Dispose() } catch { $controller.cleanupErrors += $_.Exception.Message }
        }
        if ($workerProcess) {
            try {
                if (-not $workerProcess.HasExited) {
                    # An assignment failure leaves the worker behind its gate;
                    # it has not been allowed to start any child processes.
                    if (-not $controller.workerAssignedJob) { $workerProcess.Kill() }
                    if (-not $workerProcess.WaitForExit(10000)) { throw 'Dedicated startup worker did not exit during cleanup.' }
                }
            } catch { $controller.cleanupErrors += $_.Exception.Message }
            try { $workerProcess.Dispose() } catch { $controller.cleanupErrors += $_.Exception.Message }
        }
        try { Remove-Item -LiteralPath $gateDirectory -Recurse -Force } catch { $controller.cleanupErrors += $_.Exception.Message }
        if ($controller.cleanupErrors.Count -ne 0) {
            $controller.success = $false
            if (-not $controller.error) { $controller.error = 'Startup verification cleanup failed.' }
        }
        if ($null -eq $report) { $report = [pscustomobject]@{ success = $false; error = $controller.error } }
        if (-not $controller.success) { $report.success = $false; $report.error = $controller.error }
        $report | Add-Member -NotePropertyName controller -NotePropertyValue $controller -Force
        $controller | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $controllerPath -Encoding utf8
        $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding utf8
    }
    $report | ConvertTo-Json -Depth 8
    if (-not $controller.success) { throw "Window verification failed: $($controller.error)" }
    return
}
if (-not $LaunchGate) { throw 'The dedicated worker requires its controller launch gate.' }
$gateTimer = [Diagnostics.Stopwatch]::StartNew()
while (-not [IO.File]::Exists($LaunchGate)) {
    if ($gateTimer.ElapsedMilliseconds -ge 30000) { throw 'Startup worker launch gate timed out after 30 seconds.' }
    Start-Sleep -Milliseconds 20
}
$settingsPath = Join-Path $OutputDirectory 'settings.json'
$projects = @()
if ($ProjectPath) {
    $ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
    $projects = @(@{ name = 'windows_validation'; path = $ProjectPath; entrypoint = 'lib/main.dart'; platforms = @('windows') })
}
$settings = @{
    default_sdk_path = $(if ($SdkPath) { (Resolve-Path -LiteralPath $SdkPath).Path } else { $null })
    theme_mode = 'light'
    projects = $projects
    selected_project_path = $(if ($ProjectPath) { $ProjectPath } else { $null })
}
# Windows PowerShell 5.1's UTF8 writer adds a BOM, which serde_json rejects.
[IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class FlutterDevWindowCheck {
    [DllImport("kernel32.dll")] private static extern bool FreeConsole();
    [DllImport("kernel32.dll")] private static extern IntPtr GetConsoleWindow();
    [DllImport("kernel32.dll")] private static extern uint GetConsoleProcessList(uint[] processes, uint count);
    private delegate bool EnumCallback(IntPtr window, IntPtr parameter);
    private delegate void EventCallback(IntPtr hook, uint kind, IntPtr window, int objectId, int childId, uint thread, uint time);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumCallback callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [StructLayout(LayoutKind.Sequential)] private struct Rectangle { public int left, top, right, bottom; }
    [DllImport("user32.dll")] private static extern bool GetClientRect(IntPtr window, out Rectangle rectangle);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder name, int length);
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SetWinEventHook(uint first, uint last, IntPtr module, EventCallback callback, uint process, uint thread, uint flags);
    [DllImport("user32.dll")] private static extern bool UnhookWinEvent(IntPtr hook);
    [StructLayout(LayoutKind.Sequential)] private struct Message { public IntPtr hwnd; public uint kind; public UIntPtr w; public IntPtr l; public uint time; public int x; public int y; public uint extra; }
    [DllImport("user32.dll")] private static extern bool PeekMessage(out Message message, IntPtr window, uint first, uint last, uint remove);
    [DllImport("user32.dll")] private static extern bool TranslateMessage(ref Message message);
    [DllImport("user32.dll")] private static extern IntPtr DispatchMessage(ref Message message);
    private static HashSet<IntPtr> baseline = new HashSet<IntPtr>();
    private static HashSet<IntPtr> appeared = new HashSet<IntPtr>();
    private static EventCallback callback;
    private static IntPtr hook;
    private static string ClassName(IntPtr window) {
        var name = new StringBuilder(256);
        GetClassName(window, name, name.Capacity);
        return name.ToString();
    }
    private static bool IsConsole(IntPtr window) {
        string name = ClassName(window);
        return name == "ConsoleWindowClass" || name == "CASCADIA_HOSTING_WINDOW_CLASS";
    }
    private static void Observe(IntPtr window, bool checkVisible) {
        if (window != IntPtr.Zero && (!checkVisible || IsWindowVisible(window)) && IsConsole(window) && !baseline.Contains(window)) appeared.Add(window);
    }
    public static void Begin() {
        // A headless console can have no HWND while still being attachable by
        // Flutter. Always detach, then prove there is no parent console at all.
        FreeConsole();
        if (GetConsoleWindow() != IntPtr.Zero || ConsoleProcessCount() != 0) throw new InvalidOperationException("Dedicated launcher still has a console");
        EnumWindows(delegate(IntPtr window, IntPtr ignored) { if (IsConsole(window)) baseline.Add(window); return true; }, IntPtr.Zero);
        // A SHOW event already proves visibility, even if the window has since
        // been hidden before this thread pumps its queued event notification.
        callback = delegate(IntPtr h, uint kind, IntPtr window, int obj, int child, uint thread, uint time) { if (obj == 0 && child == 0) Observe(window, false); };
        hook = SetWinEventHook(0x8002, 0x8002, IntPtr.Zero, callback, 0, 0, 0);
        if (hook == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Cannot observe window show events");
    }
    public static uint ConsoleProcessCount() { return GetConsoleProcessList(new uint[1], 1); }
    public static bool Poll(uint process) {
        Message message;
        while (PeekMessage(out message, IntPtr.Zero, 0, 0, 1)) { TranslateMessage(ref message); DispatchMessage(ref message); }
        bool visible = false;
        EnumWindows(delegate(IntPtr window, IntPtr ignored) {
            Observe(window, true);
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            Rectangle client;
            if (owner == process && IsWindowVisible(window) && ClassName(window) == "FLUTTER_RUNNER_WIN32_WINDOW" && GetClientRect(window, out client) && client.right > client.left && client.bottom > client.top) visible = true;
            return true;
        }, IntPtr.Zero);
        return visible;
    }
    public static long[] Consoles() { var result = new List<long>(); foreach (var window in appeared) result.Add(window.ToInt64()); return result.ToArray(); }
    public static void End() { if (hook != IntPtr.Zero) UnhookWinEvent(hook); hook = IntPtr.Zero; }
}
'@
$application = $null
$oldSettings = $env:FLUTTER_DEV_SETTINGS_PATH
$oldLocalData = $env:LOCALAPPDATA
$result = [ordered]@{
    success = $false
    sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    firstVisibleWindowMilliseconds = $null
    maxWindowMilliseconds = $MaxWindowMilliseconds
    observeSeconds = $ObserveSeconds
    launcherHasConsole = $false
    launcherConsoleProcessCount = $null
    newVisibleConsoleWindows = @()
    projectPath = $ProjectPath
    sdkPath = $SdkPath
    error = $null
    cleanup = [ordered]@{ applicationExitConfirmed = $true; closeRequested = $false; forcedTermination = $false; errors = @() }
}
try {
    $env:FLUTTER_DEV_SETTINGS_PATH = $settingsPath
    $env:LOCALAPPDATA = Join-Path $OutputDirectory 'local-app-data'
    New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
    [FlutterDevWindowCheck]::Begin()
    $result.launcherConsoleProcessCount = [FlutterDevWindowCheck]::ConsoleProcessCount()
    $timer = [Diagnostics.Stopwatch]::StartNew()
    # Direct creation keeps the GUI within the worker's inherited Job; do not
    # delegate launch through a shell broker that could escape test ownership.
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $ExecutablePath
    $startInfo.WorkingDirectory = Split-Path -Parent $ExecutablePath
    $startInfo.UseShellExecute = $false
    $application = [Diagnostics.Process]::Start($startInfo)
    $null = $application.Handle
    $result.cleanup.applicationExitConfirmed = $false
    while ($true) {
        $application.Refresh()
        if ($application.HasExited) { throw "Application exited during startup: $($application.ExitCode)" }
        $visible = [FlutterDevWindowCheck]::Poll([uint32]$application.Id)
        if ($visible -and $null -eq $result.firstVisibleWindowMilliseconds) {
            $result.firstVisibleWindowMilliseconds = $timer.ElapsedMilliseconds
        }
        if ($null -eq $result.firstVisibleWindowMilliseconds -and $timer.ElapsedMilliseconds -gt $MaxWindowMilliseconds) {
            throw "No visible application window within $MaxWindowMilliseconds ms."
        }
        if ($null -ne $result.firstVisibleWindowMilliseconds -and $timer.ElapsedMilliseconds -ge ($result.firstVisibleWindowMilliseconds + $ObserveSeconds * 1000)) { break }
        Start-Sleep -Milliseconds 20
    }
    $result.newVisibleConsoleWindows = @([FlutterDevWindowCheck]::Consoles())
    if ($result.newVisibleConsoleWindows.Count -ne 0) { throw 'New visible console windows appeared during application startup/project restore.' }
    $result.success = $true
} catch {
    $result.error = $_.Exception.Message
} finally {
    try { [FlutterDevWindowCheck]::End() } catch { $result.cleanup.errors += $_.Exception.Message }
    if ($application) {
        try {
            if (-not $application.HasExited) {
                $result.cleanup.closeRequested = $application.CloseMainWindow()
                if (-not $application.WaitForExit(10000)) {
                    $result.cleanup.forcedTermination = $true
                    $application.Kill()
                    if (-not $application.WaitForExit(5000)) { throw 'Owned application did not exit after forced termination.' }
                }
            }
            $result.cleanup.applicationExitConfirmed = $application.HasExited
        } catch {
            $result.cleanup.errors += $_.Exception.Message
            try {
                if (-not $application.HasExited) { $result.cleanup.forcedTermination = $true; $application.Kill() }
                $result.cleanup.applicationExitConfirmed = $application.WaitForExit(5000)
            } catch { $result.cleanup.errors += $_.Exception.Message }
        }
        try { $application.Dispose() } catch { $result.cleanup.errors += $_.Exception.Message }
    }
    $env:FLUTTER_DEV_SETTINGS_PATH = $oldSettings
    $env:LOCALAPPDATA = $oldLocalData
    if (-not $result.cleanup.applicationExitConfirmed -or $result.cleanup.errors.Count -ne 0) {
        $result.success = $false
        if (-not $result.error) { $result.error = 'Owned application cleanup failed.' }
    }
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'startup-result.json') -Encoding utf8
}
$result | ConvertTo-Json -Depth 8
if (-not $result.success) { throw 'Windows visible-window/console validation failed. See startup-result.json.' }
exit 0
