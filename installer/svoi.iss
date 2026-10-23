; Build through package.ps1. PayloadDir is a clean, allowlisted staging folder.
#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef PayloadDir
  #error PayloadDir is required
#endif
#ifndef ReleaseDir
  #error ReleaseDir is required
#endif
#ifndef SetupAppId
  #define SetupAppId "SVOI.Desktop"
#endif
#ifndef DesktopMutex
  #define DesktopMutex "Local\SVOI.Desktop"
#endif
#ifndef AppLabel
  #define AppLabel "SVOI"
#endif
#ifndef TestBuild
  #define TestBuild "0"
#endif
#if (TestBuild == "0") && ((AppLabel != "SVOI") || (SetupAppId != "SVOI.Desktop"))
  #error Custom installer identity requires TestBuild=1
#endif

[Setup]
AppId={#SetupAppId}
AppName={#AppLabel}
AppVersion={#AppVersion}
AppPublisher=SVOI
AppVerName={#AppLabel} {#AppVersion}
DefaultDirName={localappdata}\Programs\{#AppLabel}
DefaultGroupName={#AppLabel}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#ReleaseDir}
#if TestBuild == "1"
OutputBaseFilename=TEST-ONLY-NOT-FOR-DISTRIBUTION
#else
OutputBaseFilename=SVOI-{#AppVersion}-windows-x64-setup
#endif
SetupIconFile=..\assets\svoi.ico
UninstallDisplayIcon={app}\svoi.exe
UninstallDisplayName={#AppLabel}
AppMutex={#DesktopMutex}
SetupMutex={#SetupAppId}.Setup
CloseApplications=no
RestartApplications=no
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
DisableWelcomePage=no
DisableFinishedPage=no
InfoBeforeFile=install-info.txt
ChangesEnvironment=no

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
russian.LaunchSVOI=Запустить SVOI
english.LaunchSVOI=Launch SVOI
russian.InstallingRuntime=Установка Microsoft Edge WebView2 Runtime…
english.InstallingRuntime=Installing Microsoft Edge WebView2 Runtime...
russian.RuntimeFailed=Не удалось установить Microsoft Edge WebView2. Проверьте подключение к интернету и повторите попытку. Также можно установить Runtime с https://developer.microsoft.com/microsoft-edge/webview2/
english.RuntimeFailed=Microsoft Edge WebView2 could not be installed. Check your Internet connection and retry, or install the Runtime from https://developer.microsoft.com/microsoft-edge/webview2/

[Files]
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "redist\MicrosoftEdgeWebview2Setup.exe"; Flags: dontcopy

[Icons]
Name: "{group}\{#AppLabel}"; Filename: "{app}\svoi.exe"; WorkingDir: "{app}"; IconFilename: "{app}\svoi.ico"
Name: "{autodesktop}\{#AppLabel}"; Filename: "{app}\svoi.exe"; WorkingDir: "{app}"; IconFilename: "{app}\svoi.ico"

[Run]
Filename: "{app}\svoi.exe"; Description: "{cm:LaunchSVOI}"; Flags: nowait postinstall skipifsilent

[Code]
function InitializeSetup(): Boolean;
begin
#if TestBuild == "1"
  Result := WizardSilent;
  if not Result then
    MsgBox('Internal installer test. Use the SVOI installer from releases.', mbError, MB_OK);
#else
  Result := True;
#endif
end;

const
  WebViewKey = 'Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';

function RuntimeVersionPresent(RootKey: Integer): Boolean;
var
  Version: String;
begin
  Result := RegQueryStringValue(RootKey, WebViewKey, 'pv', Version) and
    (Version <> '') and (Version <> '0.0.0.0');
end;

function HasWebView2: Boolean;
begin
  Result := RuntimeVersionPresent(HKLM32) or RuntimeVersionPresent(HKCU32) or
    RuntimeVersionPresent(HKCU64);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ExitCode: Integer;
begin
  Result := '';
  if HasWebView2 then begin
    Log('WebView2 Runtime is present.');
    exit;
  end;
  WizardForm.PreparingLabel.Caption := CustomMessage('InstallingRuntime');
  ExtractTemporaryFile('MicrosoftEdgeWebview2Setup.exe');
  if not Exec(ExpandConstant('{tmp}\MicrosoftEdgeWebview2Setup.exe'), '/silent /install',
    '', SW_HIDE, ewWaitUntilTerminated, ExitCode) then begin
    Result := CustomMessage('RuntimeFailed');
    exit;
  end;
  Log(Format('WebView2 bootstrapper exit code: %d', [ExitCode]));
  if not HasWebView2 then
    Result := CustomMessage('RuntimeFailed');
end;

// No UninstallDelete: user subscriptions and WebView2 data in APPDATA stay intact.
