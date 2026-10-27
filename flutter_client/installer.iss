#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef AppIconFile
  #define AppIconFile "..\assets\svoi.ico"
#endif
[Setup]
AppId=SVOI.FlutterDesktop
AppName=SVOI
AppVersion={#AppVersion}
AppPublisher=SVOI
DefaultDirName={code:DefaultInstallDir}
UsePreviousAppDir=no
DefaultGroupName=SVOI
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#ReleaseDir}
OutputBaseFilename=SVOI-{#AppVersion}-windows-x64-setup
SetupIconFile={#AppIconFile}
UninstallDisplayIcon={app}\svoi.exe
UninstallDisplayName=SVOI
AppMutex=Local\SVOI.FlutterDesktop
SetupMutex=SVOI.FlutterDesktop.Setup
CloseApplications=no
RestartApplications=no
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
DisableWelcomePage=no
DisableFinishedPage=no
UsePreviousTasks=no

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Создать ярлык на рабочем столе"
Name: "runasadmin"; Description: "Всегда запускать от имени администратора (для TUN и zapret; Windows запросит подтверждение при запуске)"

[INI]
Filename: "{app}\launch.ini"; Section: "Launch"; Key: "RunAsAdmin"; String: "{code:AdminLaunchPreference}"; Flags: uninsdeleteentry uninsdeletesectionifempty
Filename: "{app}\launch.ini"; Section: "Updates"; Key: "PreviousVersion"; String: "{code:PreviousInstallVersion}"; Flags: uninsdeleteentry uninsdeletesectionifempty
Filename: "{app}\launch.ini"; Section: "Updates"; Key: "InstalledVersion"; String: "{#AppVersion}"; Flags: uninsdeleteentry uninsdeletesectionifempty

[Files]
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
Type: files; Name: "{app}\svoi_flutter.exe"
Type: files; Name: "{autodesktop}\SVOI Flutter.lnk"
Type: files; Name: "{userprograms}\SVOI Flutter\SVOI Flutter.lnk"
Type: dirifempty; Name: "{userprograms}\SVOI Flutter"

[Icons]
Name: "{group}\SVOI"; Filename: "{app}\svoi.exe"; WorkingDir: "{app}"; IconFilename: "{app}\svoi.ico"
Name: "{autodesktop}\SVOI"; Filename: "{app}\svoi.exe"; WorkingDir: "{app}"; IconFilename: "{app}\svoi.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\svoi.exe"; Description: "Запустить SVOI"; Flags: nowait postinstall skipifsilent

[Code]
var
  UpdateFromVersion: String;

function InitializeSetup(): Boolean;
begin
  RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Uninstall\SVOI.FlutterDesktop_is1', 'DisplayVersion', UpdateFromVersion);
  Result := True;
end;

function PreviousInstallVersion(Param: String): String;
begin
  Result := UpdateFromVersion;
end;

function DefaultInstallDir(Param: String): String;
var
  Previous: String;
begin
  Result := ExpandConstant('{localappdata}\Programs\SVOI');
  if RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Uninstall\SVOI.FlutterDesktop_is1', 'InstallLocation', Previous) then begin
    Previous := RemoveBackslashUnlessRoot(Previous);
    if CompareText(ExtractFileName(Previous), 'SVOI Flutter') = 0 then
      Result := ExtractFileDir(Previous) + '\SVOI'
    else if Previous <> '' then
      Result := Previous;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Code: Integer;
  Backend, Params: String;
begin
  if CurUninstallStep = usUninstall then begin
    Backend := ExpandConstant('{app}\backend\svoi-backend.exe');
    Params := '-desktop-exe "' + ExpandConstant('{app}\svoi.exe') + '"';
    if Exec(Backend, '-startup-status ' + Params, '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0) then begin
      if not ShellExec('runas', Backend, '-remove-startup ' + Params, '', SW_HIDE, ewWaitUntilTerminated, Code) or (Code <> 0) then
        MsgBox('Не удалось удалить автозапуск SVOI. Отключите задачу SVOI в Планировщике Windows.', mbError, MB_OK);
    end;
  end;
end;

function AdminLaunchPreference(Param: String): String;
begin
  if WizardIsTaskSelected('runasadmin') then
    Result := '1'
  else
    Result := '0';
end;
