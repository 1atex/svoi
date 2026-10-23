#ifndef AppVersion
  #error AppVersion is required
#endif
[Setup]
AppId=SVOI.FlutterDesktop
AppName=SVOI Flutter
AppVersion={#AppVersion}
AppPublisher=SVOI
DefaultDirName={localappdata}\Programs\SVOI Flutter
DefaultGroupName=SVOI Flutter
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#ReleaseDir}
OutputBaseFilename=SVOI-Flutter-{#AppVersion}-windows-x64-setup
SetupIconFile=..\assets\svoi.ico
UninstallDisplayIcon={app}\svoi_flutter.exe
UninstallDisplayName=SVOI Flutter
AppMutex=Local\SVOI.FlutterDesktop
SetupMutex=SVOI.FlutterDesktop.Setup
CloseApplications=no
RestartApplications=no
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
DisableWelcomePage=no
DisableFinishedPage=no

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Создать ярлык на рабочем столе"; Flags: checkedonce
Name: "runasadmin"; Description: "Всегда запускать от имени администратора (для TUN и zapret; Windows запросит подтверждение при запуске)"; Flags: unchecked

[INI]
Filename: "{app}\launch.ini"; Section: "Launch"; Key: "RunAsAdmin"; String: "{code:AdminLaunchPreference}"; Flags: uninsdeleteentry uninsdeletesectionifempty

[Files]
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\SVOI Flutter"; Filename: "{app}\svoi_flutter.exe"; WorkingDir: "{app}"; IconFilename: "{app}\svoi.ico"
Name: "{autodesktop}\SVOI Flutter"; Filename: "{app}\svoi_flutter.exe"; WorkingDir: "{app}"; IconFilename: "{app}\svoi.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\svoi_flutter.exe"; Description: "Запустить SVOI Flutter"; Flags: nowait postinstall skipifsilent

; User profiles in APPDATA are preserved when uninstalling.

[Code]
function AdminLaunchPreference(Param: String): String;
begin
  if WizardIsTaskSelected('runasadmin') then
    Result := '1'
  else
    Result := '0';
end;
