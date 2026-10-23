#ifndef AppVersion
  #error AppVersion is required
#endif
[Setup]
AppId=SVOI.FlutterDesktop
AppName=SVOI
AppVersion={#AppVersion}
AppPublisher=SVOI
DefaultDirName={localappdata}\Programs\SVOI Flutter
DefaultGroupName=SVOI
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#ReleaseDir}
OutputBaseFilename=SVOI-Flutter-{#AppVersion}-windows-x64-setup
SetupIconFile=..\assets\svoi.ico
UninstallDisplayIcon={app}\svoi_flutter.exe
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

[Files]
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
Type: files; Name: "{autodesktop}\SVOI Flutter.lnk"
Type: files; Name: "{userprograms}\SVOI Flutter\SVOI Flutter.lnk"
Type: dirifempty; Name: "{userprograms}\SVOI Flutter"

[Icons]
Name: "{group}\SVOI"; Filename: "{app}\svoi_flutter.exe"; WorkingDir: "{app}"; IconFilename: "{app}\svoi.ico"
Name: "{autodesktop}\SVOI"; Filename: "{app}\svoi_flutter.exe"; WorkingDir: "{app}"; IconFilename: "{app}\svoi.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\svoi_flutter.exe"; Description: "Запустить SVOI"; Flags: nowait postinstall skipifsilent

[Code]
function AdminLaunchPreference(Param: String): String;
begin
  if WizardIsTaskSelected('runasadmin') then
    Result := '1'
  else
    Result := '0';
end;
