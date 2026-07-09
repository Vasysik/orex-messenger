#define MyAppName "Orex Messenger"
#define MyAppPublisher "Orex"
#define MyAppExeName "orex_messenger.exe"
#ifndef MyAppVersion
  #error Pass /DMyAppVersion from pubspec.yaml as shown in docs\release-builds.md.
#endif
#ifndef MyAppVersionInfo
  #error Pass /DMyAppVersionInfo derived from pubspec.yaml as shown in docs\release-builds.md.
#endif
#define ReleaseDir "..\..\build\windows\x64\runner\Release"

[Setup]
AppId={{D6A47346-4A49-4D8E-97E9-D31BC0606C84}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\Orex Messenger
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\..\build\windows\x64\installer
OutputBaseFilename=Orex-Setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
VersionInfoVersion={#MyAppVersionInfo}
VersionInfoProductName={#MyAppName}
VersionInfoProductVersion={#MyAppVersionInfo}

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{userdesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent
