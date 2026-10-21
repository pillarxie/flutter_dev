; Compiled by scripts/package-windows.ps1 after a Windows x64 release build.
#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef AppFileVersion
  #error AppFileVersion is required
#endif
#ifndef BundleDirectory
  #error BundleDirectory is required
#endif
#ifndef InstallerOutputDirectory
  #error InstallerOutputDirectory is required
#endif
#ifndef InstallerBaseName
  #error InstallerBaseName is required
#endif

[Setup]
AppId={{C5496F02-544F-4B9A-B45E-54B5D4D6C709}
AppName=Flutter Dev
AppVersion={#AppVersion}
VersionInfoVersion={#AppFileVersion}
DefaultDirName={localappdata}\Programs\Flutter Dev
DefaultGroupName=Flutter Dev
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#InstallerOutputDirectory}
OutputBaseFilename={#InstallerBaseName}
SetupIconFile=runner\resources\app_icon.ico
UninstallDisplayIcon={app}\flutter_dev.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "{#BundleDirectory}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Flutter Dev"; Filename: "{app}\flutter_dev.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Flutter Dev"; Filename: "{app}\flutter_dev.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\flutter_dev.exe"; Description: "Launch Flutter Dev"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent
