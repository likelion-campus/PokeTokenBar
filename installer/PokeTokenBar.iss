; Per-user installer for the Windows app. No elevation: installs under %LOCALAPPDATA%\Programs\PokeTokenBar.
; ISCC /DSrcDir=<bundle folder> /DAppVer=<x.y.z> /DOutDir=<folder> installer\PokeTokenBar.iss
; Silent: PokeTokenBar-Setup-<x.y.z>-win-x64.exe /VERYSILENT /SUPPRESSMSGBOXES /CURRENTUSER /NORESTART [/NOLAUNCH=1] [/LOG=file]
; In-app update (the app starts Setup, then exits):
;   /SILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER /PTBRELAUNCHONFAIL=1 /LOG="<file>"
;   /PTBRELAUNCHONFAIL=1: when Setup ends without finishing, it starts {app}\PokeTokenBar.exe again (the previous app,
;   put back by DeinitializeSetup) as the user who started Setup, unless an instance still runs. A finished install
;   starts the new app through [Run]. Exit codes: 0 finished; 1 did not start (Windows too old or not x64-capable,
;   checked before any [Code], so nothing is closed or restarted; or the app did not close in 15 s); 5 stopped while
;   installing (previous app put back); 7 stopped before installing.
; Test builds only, never shipped (the release manifest allows only SrcDir, AppVer and OutDir; the file name says TESTFAIL):
;   /DPTBTestFailInstall=1  PrepareToInstall fails: after InitializeSetup closed the app, before any file is touched.
;   /DPTBTestFailCopy=1     a missing source fails the copy: after the exe was written, before the version file.
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
; Windows 10 22H2 (build 19045) or later (D12). x64 Windows and ARM64 Windows 11 (x64 emulation, untested) run the x64
; build; Windows 10 on ARM has no x64 emulation, so ArchitecturesAllowed refuses it. Setup makes both checks before any
; [Code] runs and exits with code 1.
MinVersion=10.0.19045
SetupIconFile=..\assets\AppIcon.ico
UninstallDisplayIcon={app}\PokeTokenBar.exe
UninstallDisplayName=PokeTokenBar
OutputDir={#OutDir}
#if Defined(PTBTestFailInstall) || Defined(PTBTestFailCopy)
OutputBaseFilename=PokeTokenBar-Setup-{#AppVer}-win-x64-TESTFAIL
#else
OutputBaseFilename=PokeTokenBar-Setup-{#AppVer}-win-x64
#endif
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
; The exe and then the version file go last: an update that stops part way through an in-place copy (when the previous
; app folder could not be moved aside, see MovePreviousAppAside) keeps the previous exe and version file.
Source: "{#SrcDir}\*"; Excludes: "\PokeTokenBar.exe,\PokeTokenBar.version"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SrcDir}\PokeTokenBar.exe"; DestDir: "{app}"; Flags: ignoreversion
#ifdef PTBTestFailCopy
Source: "{tmp}\PTBTestFailCopy-missing-file"; DestDir: "{app}"; Flags: external
#endif
Source: "{#SrcDir}\PokeTokenBar.version"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\PokeTokenBar"; Filename: "{app}\PokeTokenBar.exe"; AppUserModelID: "LikelionCampus.PokeTokenBar"
Name: "{userdesktop}\PokeTokenBar"; Filename: "{app}\PokeTokenBar.exe"; AppUserModelID: "LikelionCampus.PokeTokenBar"; Tasks: desktopicon

[Run]
; Also in silent mode, so a later auto-update relaunches the app. /NOLAUNCH=1 is for CI steps that start it themselves.
Filename: "{app}\PokeTokenBar.exe"; Description: "Launch PokeTokenBar"; Flags: nowait postinstall runasoriginaluser; Check: LaunchAfterInstall

[UninstallDelete]
Type: filesandordirs; Name: "{app}"
; Only if an update could not remove the previous app folder it had moved aside (normally gone at ssDone).
Type: filesandordirs; Name: "{app}.previous"

[Code]
const
  MutexName = 'Local\PokeTokenBar-Team';
  SinkClass = 'PokeTokenBarSink';
  RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';
  ApprovedKey = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';
  RunValue = 'PokeTokenBar';

var
  { Set in CurStepChanged(ssDone): the install finished. Without it, DeinitializeSetup puts the previous app back and,
    with /PTBRELAUNCHONFAIL=1, starts it. }
  SetupFinished: Boolean;
  { Where CurStepChanged(ssInstall) moved the previous app folder; empty when there was none or it could not move. }
  PreviousAppDir: String;

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

// An update replaces files in the app folder. Inno's own rollback only deletes the files an aborted install created:
// a file it replaced keeps the new contents (Inno keeps no copy of it). So right before the first file is written the
// previous app folder is moved aside whole (one rename on the same volume), the install writes a fresh folder, and an
// install that does not finish gets the previous folder back in DeinitializeSetup. When the move fails (a file in the
// folder is open), Setup updates in place as before, and only the order of the [Files] entries protects the exe and
// the version file.
procedure MovePreviousAppAside;
var
  AppDir, Aside: String;
begin
  AppDir := ExpandConstant('{app}');
  Aside := AppDir + '.previous';
  if not FileExists(AppDir + '\PokeTokenBar.exe') then begin
    Log('PTB update: no previous app in ' + AppDir);
    Exit;
  end;
  if DirExists(Aside) then
    Log('PTB update: removing a left-over ' + Aside + ', result ' + IntToStr(Ord(DelTree(Aside, True, True, True))));
  if RenameFile(AppDir, Aside) then begin
    PreviousAppDir := Aside;
    Log('PTB update: moved the previous app aside to ' + Aside);
  end else
    Log('PTB update: could not move ' + AppDir + ' aside (a file in it is open?); updating in place');
end;

procedure RestorePreviousApp;
var
  AppDir: String;
begin
  if PreviousAppDir = '' then Exit;
  AppDir := ExpandConstant('{app}');
  if DirExists(AppDir) then
    Log('PTB update: removing what the unfinished install left in ' + AppDir + ', result ' + IntToStr(Ord(DelTree(AppDir, True, True, True))));
  if RenameFile(PreviousAppDir, AppDir) then
    Log('PTB update: put the previous app back from ' + PreviousAppDir)
  else
    Log('PTB update: could not put the previous app back; it is in ' + PreviousAppDir);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
    MovePreviousAppAside
  else if CurStep = ssDone then begin
    SetupFinished := True;
    Log('PTB update: setup finished');
    if PreviousAppDir <> '' then
      Log('PTB update: removing the previous app ' + PreviousAppDir + ', result ' + IntToStr(Ord(DelTree(PreviousAppDir, True, True, True))));
  end;
end;

// The app folder; the fixed default (DisableDirPage) when InitializeSetup gave up before the wizard set it.
function InstalledExe: String;
begin
  try
    Result := ExpandConstant('{app}\PokeTokenBar.exe');
  except
    Result := ExpandConstant('{localappdata}\Programs\PokeTokenBar\PokeTokenBar.exe');
  end;
end;

// /PTBRELAUNCHONFAIL=1 (the in-app update): the app exited for this Setup, so when Setup ends without finishing, the
// app in the app folder (the previous one, put back above) is started again as the user who started Setup. Not while
// an instance holds the mutex: the app did not close (InitializeSetup gave up), and a second start would only make it
// show itself.
procedure DeinitializeSetup;
var
  Exe: String;
  Code: Integer;
begin
  if SetupFinished then begin
    Log('PTB relaunch: no (setup finished)');
    Exit;
  end;
  RestorePreviousApp;
  if ExpandConstant('{param:PTBRELAUNCHONFAIL|0}') <> '1' then begin
    Log('PTB relaunch: no (setup did not finish; PTBRELAUNCHONFAIL is not 1)');
    Exit;
  end;
  if CheckForMutexes(MutexName) then begin
    Log('PTB relaunch: no (an instance is still running)');
    Exit;
  end;
  Exe := InstalledExe;
  if not FileExists(Exe) then begin
    Log('PTB relaunch: no (' + Exe + ' is missing)');
    Exit;
  end;
  if ExecAsOriginalUser(Exe, '', ExtractFileDir(Exe), SW_SHOWNORMAL, ewNoWait, Code) then
    Log('PTB relaunch: started ' + Exe)
  else
    Log('PTB relaunch: could not start ' + Exe + ': ' + SysErrorMessage(Code));
end;

#ifdef PTBTestFailInstall
// Test builds only: stop on the Preparing page, after InitializeSetup closed the app and before any file is touched.
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Log('PTBTestFailInstall: stopping in PrepareToInstall (test build)');
  Result := 'PTBTestFailInstall: this test build stops before installing.';
end;
#endif
