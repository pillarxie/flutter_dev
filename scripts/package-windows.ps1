# Run after `flutter build windows --release` on Windows with Visual Studio
# and Inno Setup 6 installed. All packaging work stays under build/ by default.
[CmdletBinding()]
param(
    [string]$ReleaseDirectory,
    [string]$OutputDirectory,
    [string]$IsccPath,
    [string]$VcRedistDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($env:OS -ne 'Windows_NT') {
    throw 'Windows packaging must run on Windows.'
}

$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $ReleaseDirectory) {
    $ReleaseDirectory = Join-Path $projectRoot 'build/windows/x64/runner/Release'
}
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $projectRoot 'build/windows/installer'
}
$ReleaseDirectory = (Resolve-Path -LiteralPath $ReleaseDirectory).Path
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)

$pubspec = Get-Content -LiteralPath (Join-Path $projectRoot 'pubspec.yaml') -Raw
$versionMatch = [regex]::Match($pubspec, '(?m)^version:\s*([^\s#]+)\s*(?:#.*)?$')
if (-not $versionMatch.Success) {
    throw 'Could not read version from pubspec.yaml.'
}
$appVersion = $versionMatch.Groups[1].Value
$numericVersion = [regex]::Match($appVersion, '^(\d+)\.(\d+)\.(\d+)(?:-[0-9A-Za-z.-]+)?(?:\+(\d+))?$')
if (-not $numericVersion.Success) {
    throw "Unsupported pubspec version: $appVersion"
}
$versionParts = @(1..3 | ForEach-Object { $numericVersion.Groups[$_].Value })
$versionParts += $(if ($numericVersion.Groups[4].Success) { $numericVersion.Groups[4].Value } else { '0' })
foreach ($part in $versionParts) {
    if ([decimal]$part -gt 65535) {
        throw 'Windows file version components must be between 0 and 65535.'
    }
}
$fileVersion = $versionParts -join '.'

foreach ($requiredFile in @('flutter_dev.exe', 'flutter_windows.dll', 'flutter_dev_core.dll', 'data/app.so', 'data/icudtl.dat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $ReleaseDirectory $requiredFile) -PathType Leaf)) {
        throw "Missing release file: $requiredFile. Run flutter build windows --release first."
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $ReleaseDirectory 'data/flutter_assets') -PathType Container)) {
    throw 'The release bundle is missing data/flutter_assets.'
}

if (-not $IsccPath) {
    $isccCommand = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
    if ($isccCommand) {
        $IsccPath = $isccCommand.Source
    } else {
        $IsccPath = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'
    }
}
if (-not (Test-Path -LiteralPath $IsccPath -PathType Leaf)) {
    throw 'Inno Setup compiler not found. Install Inno Setup 6 or pass -IsccPath.'
}

# Copy only the redistributable x64 CRT, never DLLs from System32 or debug CRTs.
# App-local deployment keeps installation and portable use free of elevation.
if (-not $VcRedistDirectory) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
        throw 'vswhere.exe not found. Pass -VcRedistDirectory with the Visual Studio x64 CRT directory.'
    }
    $vsPath = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or -not $vsPath) {
        throw 'No Visual Studio C++ toolchain found for CRT redistribution.'
    }
    $redistRoot = Join-Path $vsPath.Trim() 'VC/Redist/MSVC'
    $redistVersions = Get-ChildItem -LiteralPath $redistRoot -Directory |
        Where-Object { $_.Name -match '^\d+(\.\d+)+$' } |
        Sort-Object { [version]$_.Name } -Descending
    foreach ($redistVersion in $redistVersions) {
        $crt = Get-ChildItem -Path (Join-Path $redistVersion.FullName 'x64/Microsoft.VC*.CRT') -Directory -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($crt) {
            $VcRedistDirectory = $crt.FullName
            break
        }
    }
}
if (-not $VcRedistDirectory -or -not (Test-Path -LiteralPath $VcRedistDirectory -PathType Container)) {
    throw 'Visual Studio x64 CRT directory not found. Pass -VcRedistDirectory explicitly.'
}
foreach ($runtime in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $VcRedistDirectory $runtime) -PathType Leaf)) {
        throw "Missing redistributable CRT DLL: $runtime"
    }
}

# A fresh private staging directory avoids mutating the Flutter build bundle or
# accidentally collecting an installer from a previous packaging run.
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$stageDirectory = Join-Path $OutputDirectory ('staging-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stageDirectory | Out-Null
$artifactBase = "FlutterDev-$appVersion-windows-x64"
$setupName = "$artifactBase-setup"
$setupPath = Join-Path $OutputDirectory "$setupName.exe"
$zipPath = Join-Path $OutputDirectory "$artifactBase-portable.zip"
try {
    Get-ChildItem -LiteralPath $ReleaseDirectory -Force |
        Copy-Item -Destination $stageDirectory -Recurse -Force
    Get-ChildItem -LiteralPath $VcRedistDirectory -Filter '*.dll' -File |
        Copy-Item -Destination $stageDirectory -Force

    $compilerArguments = @(
        "/DAppVersion=$appVersion",
        "/DAppFileVersion=$fileVersion",
        "/DBundleDirectory=$stageDirectory",
        "/DInstallerOutputDirectory=$OutputDirectory",
        "/DInstallerBaseName=$setupName",
        (Join-Path $projectRoot 'windows/installer.iss')
    )
    & $IsccPath @compilerArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Inno Setup failed with exit code $LASTEXITCODE."
    }
    if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) {
        throw "Installer was not produced: $setupPath"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath
    }
    [IO.Compression.ZipFile]::CreateFromDirectory($stageDirectory, $zipPath)
    $checksums = foreach ($artifact in @($setupPath, $zipPath)) {
        $hash = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $([IO.Path]::GetFileName($artifact))"
    }
    $checksums | Set-Content -LiteralPath (Join-Path $OutputDirectory 'SHA256SUMS.txt') -Encoding ascii
    Write-Host "Installer: $setupPath"
    Write-Host "Portable:  $zipPath"
    Write-Host "SHA256:    $(Join-Path $OutputDirectory 'SHA256SUMS.txt')"
} finally {
    Remove-Item -LiteralPath $stageDirectory -Recurse -Force
}
