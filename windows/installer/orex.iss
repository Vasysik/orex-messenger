#ifndef OrexDebug
  #define OrexDebug 0
#endif

#if OrexDebug
  #define OrexChannel "debug"
  #define MyAppName "Orex Messenger Debug"
  #define MyAppExeName "orex_messenger_debug.exe"
  #define MyAppId "{{AD83592C-0063-438C-A508-E60558F80F1E}"
  #define MyInstallFolder "Orex Messenger Debug"
#else
  #define OrexChannel "stable"
  #define MyAppName "Orex Messenger"
  #define MyAppExeName "orex_messenger.exe"
  #define MyAppId "{{D6A47346-4A49-4D8E-97E9-D31BC0606C84}"
  #define MyInstallFolder "Orex Messenger"
#endif

#define MyAppPublisher "Orex"
#ifndef MyAppVersion
  #error Pass /DMyAppVersion from pubspec.yaml as shown in docs\release-windows.md.
#endif
#ifndef MyAppVersionInfo
  #error Pass /DMyAppVersionInfo derived from pubspec.yaml as shown in docs\release-windows.md.
#endif
#define ReleaseDir "..\..\build\windows\x64\runner\Release"

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\{#MyInstallFolder}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\..\build\windows\x64\installer\{#OrexChannel}
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
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{userdesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent
