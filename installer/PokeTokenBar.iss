; Per-user installer for the Windows app. No elevation: installs under %LOCALAPPDATA%\Programs\PokeTokenBar.
; ISCC /DSrcDir=<bundle folder> /DAppVer=<x.y.z> /DOutDir=<folder> installer\PokeTokenBar.iss
; Silent: PokeTokenBar-Setup-<x.y.z>-win-x64.exe /VERYSILENT /SUPPRESSMSGBOXES /CURRENTUSER /NORESTART [/NOLAUNCH=1] [/LOG=file]
#ifndef SrcDir
  #error Pass /DSrcDir=<the folder package.ps1 wrote>
#endif
#ifndef AppVer
  #error Pass /DAppVer=<x.y.z>
#endif
#ifndef OutDir
  #define OutDir "out"
#endif

[Setup]
AppId={{6CE57293-9940-4B5E-A604-4C4FEECBF049}
AppName=PokeTokenBar
AppVersion={#AppVer}
AppPublisher=likelion-campus
AppPublisherURL=https://github.com/likelion-campus/PokeTokenBar
DefaultDirName={localappdata}\Programs\PokeTokenBar
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
SetupIconFile=..\assets\AppIcon.ico
UninstallDisplayIcon={app}\PokeTokenBar.exe
UninstallDisplayName=PokeTokenBar
OutputDir={#OutDir}
OutputBaseFilename=PokeTokenBar-Setup-{#AppVer}-win-x64
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; Same name WinSingleInstance holds for the default state folder. Our own code below closes the app first (WM_CLOSE).
AppMutex=Local\PokeTokenBar-Team
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; Flags: unchecked

[Files]
Source: "{#SrcDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\PokeTokenBar"; Filename: "{app}\PokeTokenBar.exe"; AppUserModelID: "LikelionCampus.PokeTokenBar"
Name: "{userdesktop}\PokeTokenBar"; Filename: "{app}\PokeTokenBar.exe"; AppUserModelID: "LikelionCampus.PokeTokenBar"; Tasks: desktopicon

[Run]
; Also in silent mode, so a later auto-update relaunches the app. /NOLAUNCH=1 is for CI steps that start it themselves.
Filename: "{app}\PokeTokenBar.exe"; Description: "Launch PokeTokenBar"; Flags: nowait postinstall runasoriginaluser; Check: LaunchAfterInstall

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
const
  MutexName = 'Local\PokeTokenBar-Team';
  SinkClass = 'PokeTokenBarSink';
  RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';
  ApprovedKey = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';
  RunValue = 'PokeTokenBar';

function LaunchAfterInstall: Boolean;
begin
  Result := ExpandConstant('{param:NOLAUNCH|0}') <> '1';
end;

{ Asks a running instance to end through its sink window (WM_CLOSE -> WindowsApp.exit, settings synced) and waits up to
  15 s for it to release the single-instance mutex. }
function CloseRunningApp: Boolean;
var
  Wnd: HWND;
  I: Integer;
begin
  Result := True;
  if not CheckForMutexes(MutexName) then Exit;
  Wnd := FindWindowByClassName(SinkClass);
  if Wnd <> 0 then PostMessage(Wnd, $0010, 0, 0);
  for I := 1 to 150 do begin
    if not CheckForMutexes(MutexName) then Exit;
    Sleep(100);
  end;
  Result := False;
end;

function InitializeSetup: Boolean;
begin
  Log('InitializeSetup: app mutex held = ' + IntToStr(Ord(CheckForMutexes(MutexName))));
  Result := CloseRunningApp;
  if not Result then
    MsgBox('PokeTokenBar is running and did not close. Quit it from its tray icon, then run Setup again.', mbError, MB_OK);
end;

function InitializeUninstall: Boolean;
begin
  Log('InitializeUninstall: app mutex held = ' + IntToStr(Ord(CheckForMutexes(MutexName))));
  Result := CloseRunningApp;
  if not Result then
    MsgBox('PokeTokenBar is running and did not close. Quit it from its tray icon, then run Uninstall again.', mbError, MB_OK);
end;

{ Launch at login is the app's own setting (HKCU Run value PokeTokenBar, written by the tray toggle). Uninstall removes it
  only when it starts THIS install's exe. State, settings and logs under %LOCALAPPDATA%\PokeTokenBar are kept. }
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Command: String;
begin
  Log('CurUninstallStepChanged ' + IntToStr(Ord(CurUninstallStep)));
  if CurUninstallStep <> usUninstall then Exit;
  if RegQueryStringValue(HKCU, RunKey, RunValue, Command) then begin
    Log('Run value: ' + Command + ' ; this install: ' + ExpandConstant('{app}\PokeTokenBar.exe'));
    if Pos(Lowercase(ExpandConstant('{app}\PokeTokenBar.exe')), Lowercase(Command)) > 0 then begin
      Log('Run value starts this install: deleting it, result ' + IntToStr(Ord(RegDeleteValue(HKCU, RunKey, RunValue))));
      RegDeleteValue(HKCU, ApprovedKey, RunValue);
    end;
  end else
    Log('No Run value PokeTokenBar to remove');
end;
