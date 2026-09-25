; 可由本地命令或 GitHub Actions 覆盖的应用版本。
#ifndef AppVersion
  #define AppVersion "0.1.1"
#endif

; Flutter Windows Release 目录。
#ifndef SourceDir
  #define SourceDir "..\..\apps\client\build\windows\x64\runner\Release"
#endif

; 安装器输出目录。
#ifndef OutputDir
  #define OutputDir "..\..\output"
#endif

; Windows 应用图标路径。
#ifndef IconPath
  #define IconPath "..\..\apps\client\windows\runner\resources\app_icon.ico"
#endif

[Setup]
AppId={{4737C6F0-6D36-4AA6-9775-2E22381E6F22}
AppName=Omni Butler
AppVersion={#AppVersion}
AppPublisher=Omni Butler
DefaultDirName={localappdata}\Programs\Omni Butler
DefaultGroupName=Omni Butler
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=Omni-Butler-{#AppVersion}-windows-x64-setup
SetupIconFile={#IconPath}
UninstallDisplayIcon={app}\omni_butler.exe
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加快捷方式："; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Omni Butler"; Filename: "{app}\omni_butler.exe"
Name: "{autodesktop}\Omni Butler"; Filename: "{app}\omni_butler.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\omni_butler.exe"; Description: "启动 Omni Butler"; Flags: nowait postinstall skipifsilent
