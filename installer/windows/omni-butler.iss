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
AppName={code:GetAppDisplayName}
AppVersion={#AppVersion}
AppPublisher=Omni Butler
DefaultDirName={localappdata}\Programs\Omni Butler
DefaultGroupName=Omni Butler
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=Omni-Butler-{#AppVersion}-windows-x64-setup
SetupIconFile={#IconPath}
UninstallDisplayIcon={app}\omni_butler.exe
UninstallDisplayName={code:GetAppDisplayName}
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
Filename: "{app}\omni_butler.exe"; Description: "{cm:LaunchProgram,{code:GetAppDisplayName}}"; Flags: nowait postinstall skipifsilent

[Code]
// Matches the English and Chinese strings in the runner's resource.h.
const
  AppDisplayNameEn = 102;
  AppDisplayNameZh = 103;

// Reads the language used by Windows UI, independently of regional formats.
function GetUserDefaultUILanguage: Word;
  external 'GetUserDefaultUILanguage@kernel32.dll stdcall';

// Sets a shortcut's visible name without renaming the .lnk file.
function SHSetLocalizedName(Path, ResourceModule: String; ResourceId: Integer): Integer;
  external 'SHSetLocalizedName@shell32.dll stdcall';

// Removes the Shell's localized name entry before the link is deleted.
function SHRemoveLocalizedName(Path: String): Integer;
  external 'SHRemoveLocalizedName@shell32.dll stdcall';

// Checks the primary language so every Chinese region uses the same name.
function IsChineseUI: Boolean;
begin
  Result := (GetUserDefaultUILanguage and $03FF) = $0004;
end;

// Resolves the installer and Installed apps display name.
function GetAppDisplayName(Param: String): String;
begin
  if IsChineseUI then
    Result := '知序'
  else
    Result := 'Omni Butler';
end;

// Applies the executable's language resource to an existing shortcut.
procedure LocalizeShortcut(Path: String);
var
  // The resource selected for the current Windows display language.
  ResourceId: Integer;
begin
  if FileExists(Path) then
  begin
    if IsChineseUI then
      ResourceId := AppDisplayNameZh
    else
      ResourceId := AppDisplayNameEn;
    if SHSetLocalizedName(Path, ExpandConstant('{app}\omni_butler.exe'),
      ResourceId) <> 0 then
      Log('Could not localize shortcut: ' + Path);
  end;
end;

// Register display names after Inno Setup has created the shortcuts.
procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    LocalizeShortcut(ExpandConstant('{autoprograms}\Omni Butler.lnk'));
    if WizardIsTaskSelected('desktopicon') then
      LocalizeShortcut(ExpandConstant('{autodesktop}\Omni Butler.lnk'));
  end;
end;

// Clean up the Shell entries for the installed shortcuts.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
  begin
    SHRemoveLocalizedName(ExpandConstant('{autoprograms}\Omni Butler.lnk'));
    SHRemoveLocalizedName(ExpandConstant('{autodesktop}\Omni Butler.lnk'));
  end;
end;
