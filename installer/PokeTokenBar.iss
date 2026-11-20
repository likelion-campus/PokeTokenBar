; Per-user installer for the Windows app. No elevation: installs under %LOCALAPPDATA%\Programs\PokeTokenBar.
; ISCC /DSrcDir=<bundle folder> /DAppVer=<x.y.z> /DOutDir=<folder> installer\PokeTokenBar.iss
; Silent: PokeTokenBar-Setup-<x.y.z>-win-x64.exe /VERYSILENT /SUPPRESSMSGBOXES /CURRENTUSER /NORESTART [/NOLAUNCH=1] [/LOG=file]
; In-app update (the app starts Setup with a working folder outside the app folder, then exits):
;   /SILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER /PTBRELAUNCHONFAIL=1 /LOG="<file>"
; Every update first copies the installed app folder to {app}.previous (PrepareToInstall; if the copy cannot be made,
; Setup stops before touching anything). Inno then updates in place, the exe and the version file last. If Setup ends
; without finishing, DeinitializeSetup copies the previous files back over the app folder. ssDone deletes the copy.
; /PTBRELAUNCHONFAIL=1: when Setup ends without finishing, it then starts {app}\PokeTokenBar.exe again as the user who
; started Setup, unless another Setup is running, an instance still runs, or the previous app could not be put back.
; A finished install starts the new app through [Run]. Exit codes: 0 finished; 1 did not start (Windows too old or not
; x64-capable, checked before any [Code], so nothing is closed or restarted; another PokeTokenBar Setup is running; or
; the app did not close in 30 s: nothing is touched or restarted); 5 stopped while installing (previous files put back); 7 stopped before installing
; (no copy of the app could be made, a copy an earlier Setup left could not be put back, or a test build).
; Test builds only, never shipped: their file name and FileDescription say TESTFAIL (stage 8 Task 1's release
; manifest is to refuse any ISCC define but SrcDir, AppVer and OutDir):
;   /DPTBTestFailInstall=1  PrepareToInstall fails after the copy was made: the app closed, no file of it touched.
;   /DPTBTestFailCopy=1     a missing source fails the copy after the exe was written, before the version file.
;   /DPTBTestFailLate=1     a missing source fails the copy after every file, the version file too, was written.
;                           Both: /PTBTESTPAUSE=<folder> waits for <folder>\resume at /PTBTESTPAUSEAT=exe (after the
;                           exe, the default), first (after 5 files of the first entry) or restore (after the first
;                           file put back), so CI can hold a file, start a second Setup or kill this one there.
;   /DPTBTestBuild=1        nothing else (CI probes built from this script).
#ifndef SrcDir
  #error Pass /DSrcDir=<the folder package.ps1 wrote>
#endif
#ifndef AppVer
  #error Pass /DAppVer=<x.y.z>
#endif
#ifndef OutDir
  #define OutDir "out"
#endif
#if Defined(PTBTestFailInstall) || Defined(PTBTestFailCopy) || Defined(PTBTestFailLate) || Defined(PTBTestBuild)
  #define PTBTest
#endif
#if Defined(PTBTestFailCopy) || Defined(PTBTestFailLate)
  #define PTBTestPause
#endif

[Setup]
AppId={{6CE57293-9940-4B5E-A604-4C4FEECBF049}
AppName=PokeTokenBar
AppVersion={#AppVer}
VersionInfoVersion={#AppVer}.0
VersionInfoProductVersion={#AppVer}
; VersionInfoDescription is set below with the output name: TESTFAIL in test builds (release-manifest.ps1 checks it).
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
#ifdef PTBTest
OutputBaseFilename=PokeTokenBar-Setup-{#AppVer}-win-x64-TESTFAIL
VersionInfoDescription=PokeTokenBar Setup TESTFAIL
#else
OutputBaseFilename=PokeTokenBar-Setup-{#AppVer}-win-x64
VersionInfoDescription=PokeTokenBar Setup
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
; The exe and then the version file go last: a Setup killed part way through the copy leaves the previous exe and
; version file, so the app still starts and reports the old version (the next update copies everything again).
#ifdef PTBTestPause
Source: "{#SrcDir}\*"; Excludes: "\PokeTokenBar.exe,\PokeTokenBar.version"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; AfterInstall: TestPauseAfterFile
Source: "{#SrcDir}\PokeTokenBar.exe"; DestDir: "{app}"; Flags: ignoreversion; AfterInstall: TestPauseAfterExe
#else
Source: "{#SrcDir}\*"; Excludes: "\PokeTokenBar.exe,\PokeTokenBar.version"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SrcDir}\PokeTokenBar.exe"; DestDir: "{app}"; Flags: ignoreversion
#endif
#ifdef PTBTestFailCopy
Source: "{tmp}\PTBTestFailCopy-missing-file"; DestDir: "{app}"; Flags: external
#endif
Source: "{#SrcDir}\PokeTokenBar.version"; DestDir: "{app}"; Flags: ignoreversion
#ifdef PTBTestFailLate
Source: "{tmp}\PTBTestFailLate-missing-file"; DestDir: "{app}"; Flags: external
#endif

[Icons]
Name: "{userprograms}\PokeTokenBar"; Filename: "{app}\PokeTokenBar.exe"; AppUserModelID: "LikelionCampus.PokeTokenBar"
Name: "{userdesktop}\PokeTokenBar"; Filename: "{app}\PokeTokenBar.exe"; AppUserModelID: "LikelionCampus.PokeTokenBar"; Tasks: desktopicon

[Run]
; Also in silent mode, so a later auto-update relaunches the app. /NOLAUNCH=1 is for CI steps that start it themselves.
Filename: "{app}\PokeTokenBar.exe"; Description: "Launch PokeTokenBar"; Flags: nowait postinstall runasoriginaluser; Check: LaunchAfterInstall

[Registry]
; --- stage 7 Task 23: the poketokenbar: link (begin) ---
; Agent hooks open poketokenbar://agent?state=...; the shell starts this install's exe with --agent-link and the link (the
; Mac's CFBundleURLTypes). Per user (HKCU\Software\Classes, no elevation), written by every install and update. Uninstall
; removes the key only when its command starts THIS install (CurUninstallStepChanged); the app itself never writes it.
Root: HKCU; Subkey: "Software\Classes\poketokenbar"; ValueType: string; ValueName: ""; ValueData: "URL:PokeTokenBar agent link"
Root: HKCU; Subkey: "Software\Classes\poketokenbar"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\poketokenbar\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\PokeTokenBar.exe"",0"
Root: HKCU; Subkey: "Software\Classes\poketokenbar\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\PokeTokenBar.exe"" --agent-link ""%1"""
; --- stage 7 Task 23 (end) ---

[UninstallDelete]
Type: filesandordirs; Name: "{app}"
; The copy an update keeps of the previous app; normally gone at ssDone.
Type: filesandordirs; Name: "{app}.previous"

[Code]
const
  MutexName = 'Local\PokeTokenBar-Team';
  SinkClass = 'PokeTokenBarSink';
  RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';
  ApprovedKey = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';
  RunValue = 'PokeTokenBar';
  { stage 7 Task 23: the poketokenbar: link ([Registry]). }
  LinkKey = 'Software\Classes\poketokenbar';
  LinkCommandKey = 'Software\Classes\poketokenbar\shell\open\command';
  { One PokeTokenBar Setup at a time: an in-app update and a double-clicked download must not clean up each other's
    copy of the app. Checked and created at the top of InitializeSetup, before the app is closed. Inno's SetupMutex
    directive is checked only after InitializeSetup, when the app is already closed, so it is not used. }
  SetupMutexName = 'Local\PokeTokenBar-Setup';
  { Written last into the copy: a copy without it is not complete. }
  BackupMarker = 'PTB-backup-complete.txt';
  { How long Setup and Uninstall wait for a running PokeTokenBar to close after WM_CLOSE. It closes in well under a
    second (the app's exit syncs its settings and ends the team links); 30 s leaves room for a loaded PC. Then they
    stop instead of killing it: a killed app skips that exit (the last settings write, the team's goodbye), and one
    that does not answer WM_CLOSE for 30 s may be waiting for its user. }
  CloseWaitSeconds = 30;

var
  { InitializeSetup stopped because another PokeTokenBar Setup runs: DeinitializeSetup changes nothing. }
  OtherSetupRunning: Boolean;
  { Set in CurStepChanged(ssDone): the install finished. }
  SetupFinished: Boolean;
  { Set in CurStepChanged(ssInstall): files may have been written since. }
  InstallStarted: Boolean;
  { The complete copy PrepareToInstall made of the previous app; empty when there was no previous app. }
  BackupDir: String;
  { The previous files could not all be put back: the app folder is not started. }
  RestoreFailed: Boolean;

function LaunchAfterInstall: Boolean;
begin
  Result := ExpandConstant('{param:NOLAUNCH|0}') <> '1';
end;

{ Asks a running instance to end through its sink window (WM_CLOSE -> WindowsApp.exit, settings synced) and waits up to
  CloseWaitSeconds for it to release the single-instance mutex. }
function CloseRunningApp: Boolean;
var
  Wnd: HWND;
  I: Integer;
begin
  Result := True;
  if not CheckForMutexes(MutexName) then Exit;
  Wnd := FindWindowByClassName(SinkClass);
  if Wnd <> 0 then PostMessage(Wnd, $0010, 0, 0);
  for I := 1 to CloseWaitSeconds * 10 do begin
    if not CheckForMutexes(MutexName) then Exit;
    Sleep(100);
  end;
  Result := False;
end;

function InitializeSetup: Boolean;
begin
  { Setup runs where it was started from (the app's folder, when the app starts it); Inno's loader process keeps that
    folder whatever this does. Nothing here depends on it: the app folder is copied, never renamed. }
  Log('PTB setup: working folder ' + GetCurrentDir + '; moving to the system folder: ' + IntToStr(Ord(SetCurrentDir(ExpandConstant('{sys}')))));
  if CheckForMutexes(SetupMutexName) then begin
    OtherSetupRunning := True;
    Log('PTB setup: another PokeTokenBar Setup is running; stopping before the app is touched');
    SuppressibleMsgBox('Another PokeTokenBar Setup is running. Let it finish, then run this one again.', mbError, MB_OK, IDOK);
    Result := False;
    Exit;
  end;
  CreateMutex(SetupMutexName);
  Log('InitializeSetup: app mutex held = ' + IntToStr(Ord(CheckForMutexes(MutexName))));
  Result := CloseRunningApp;
  if not Result then begin
    { Never MsgBox: it ignores /SUPPRESSMSGBOXES, so a silent Setup (the in-app update, CI) would wait for a click forever.
      Silent: logged, exit 1; DeinitializeSetup then starts nothing (the app's mutex is still held). }
    Log('PTB setup: PokeTokenBar did not close in ' + IntToStr(CloseWaitSeconds) + ' s; stopping before the app is touched');
    SuppressibleMsgBox('PokeTokenBar is running and did not close. Quit it from its tray icon, then run Setup again.', mbError, MB_OK, IDOK);
  end;
end;

function InitializeUninstall: Boolean;
begin
  Log('InitializeUninstall: app mutex held = ' + IntToStr(Ord(CheckForMutexes(MutexName))));
  Result := CloseRunningApp;
  if not Result then begin
    Log('PTB uninstall: PokeTokenBar did not close in ' + IntToStr(CloseWaitSeconds) + ' s; nothing removed');
    SuppressibleMsgBox('PokeTokenBar is running and did not close. Quit it from its tray icon, then run Uninstall again.', mbError, MB_OK, IDOK);
  end;
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
  { stage 7 Task 23: the poketokenbar: link, only when it starts this install (another install's or program's is kept). }
  if RegQueryStringValue(HKCU, LinkCommandKey, '', Command) then begin
    Log('poketokenbar: link command: ' + Command);
    if Pos(Lowercase(ExpandConstant('{app}\PokeTokenBar.exe')), Lowercase(Command)) > 0 then
      Log('The link starts this install: deleting it, result ' + IntToStr(Ord(RegDeleteKeyIncludingSubkeys(HKCU, LinkKey))));
  end else
    Log('No poketokenbar: link to remove');
end;

// Inno's own rollback only deletes the files an aborted install created: a file it replaced keeps the new contents
// (Inno keeps no copy). So PrepareToInstall copies the whole app folder to <app>.previous first, Inno updates in place,
// and an install that does not finish copies the previous files back. The app folder is never renamed or emptied, so a
// Setup killed part way leaves a folder that still starts (the [Files] order keeps the old exe and version file).

function IsCompleteApp(const Dir: String): Boolean;
begin
  Result := FileExists(Dir + '\PokeTokenBar.exe') and FileExists(Dir + '\PokeTokenBar.version');
end;

// The version a folder's version file names; empty without one.
function VersionIn(const Dir: String): String;
var
  S: AnsiString;
begin
  Result := '';
  if LoadStringFromFile(Dir + '\PokeTokenBar.version', S) then Result := Trim(String(S));
end;

#ifdef PTBTestPause
var
  TestFilesSeen: Integer;
  TestRestorePaused: Boolean;

// Test builds only: with /PTBTESTPAUSE=<folder>, wait at the point /PTBTESTPAUSEAT names until <folder>\resume exists
// (120 s), so CI can hold a file, start a second Setup or kill this one there.
procedure TestPause(const Point: String);
var
  Dir: String;
  I: Integer;
begin
  Dir := ExpandConstant('{param:PTBTESTPAUSE|}');
  if (Dir = '') or (CompareText(ExpandConstant('{param:PTBTESTPAUSEAT|exe}'), Point) <> 0) then Exit;
  SaveStringToFile(Dir + '\paused', Point, False);
  Log('PTBTest: paused at ' + Point + '; waiting for ' + Dir + '\resume');
  for I := 1 to 1200 do begin
    if FileExists(Dir + '\resume') then Break;
    Sleep(100);
  end;
  Log('PTBTest: going on');
end;

procedure TestPauseAfterExe;
begin
  TestPause('exe');
end;

procedure TestPauseAfterFile;
begin
  TestFilesSeen := TestFilesSeen + 1;
  if TestFilesSeen = 5 then TestPause('first');
end;
#endif

// Same contents (SHA-256). Size and time are not enough: Inno rounds installed times to 2 s (TimeStampRounding), and
// a version file keeps its length from one version to the next.
function SameContents(const A, B: String): Boolean;
begin
  Result := False;
  if not (FileExists(A) and FileExists(B)) then Exit;
  try
    Result := GetSHA256OfFile(A) = GetSHA256OfFile(B);
  except
    Log('PTB update: could not compare ' + B + ' with the copy: ' + GetExceptionMessage);
  end;
end;

// Copies every file under Src to Dst (folders created as needed). False at the first file it cannot copy.
function CopyTree(const Src, Dst: String; var Files: Integer; var Bytes: Int64): Boolean;
var
  F: TFindRec;
begin
  Result := ForceDirectories(Dst);
  if not Result then begin
    Log('PTB update: could not create ' + Dst);
    Exit;
  end;
  if FindFirst(Src + '\*', F) then
  try
    repeat
      if (F.Name <> '.') and (F.Name <> '..') then begin
        if (F.Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
          Result := CopyTree(Src + '\' + F.Name, Dst + '\' + F.Name, Files, Bytes)
        else if CopyFile(Src + '\' + F.Name, Dst + '\' + F.Name, False) then begin
          Files := Files + 1;
          Bytes := Bytes + F.SizeLow;
        end else begin
          Log('PTB update: could not copy ' + Src + '\' + F.Name);
          Result := False;
        end;
      end;
    until (not Result) or (not FindNext(F));
  finally
    FindClose(F);
  end;
end;

// One file of the copy back into the app folder: one with the copy's contents is the previous one and stays; any other
// is copied back, retried for about 3 s (antivirus holds fresh files briefly). False if it could not be put back.
function RestoreFile(const Src, Dst: String; var Copied, Kept: Integer): Boolean;
var
  I: Integer;
begin
  Result := SameContents(Src, Dst);
  if Result then
    Kept := Kept + 1
  else begin
    for I := 1 to 10 do begin
      if CopyFile(Src, Dst, False) then begin
        Result := True;
        Break;
      end;
      Sleep(300);
    end;
    if Result then
      Copied := Copied + 1
    else
      Log('PTB update: could not put back ' + Dst);
  end;
#ifdef PTBTestPause
  if not TestRestorePaused then begin
    TestRestorePaused := True;
    TestPause('restore');
  end;
#endif
end;

// Puts every file of the copy Src back into Dst (created if it is gone). At the top the version file goes first: a
// Setup stopped while putting files back then leaves the copy's version in the folder, so the next Setup puts the copy
// back again instead of taking the folder for a finished install (HandleLeftOverBackup). Goes on after a failure and
// returns False if any file could not be put back.
function RestoreTree(const Src, Dst: String; var Copied, Kept: Integer; const Top: Boolean): Boolean;
var
  F: TFindRec;
begin
  Result := ForceDirectories(Dst);
  if not Result then begin
    Log('PTB update: could not create ' + Dst);
    Exit;
  end;
  if Top and FileExists(Src + '\PokeTokenBar.version') then
    if not RestoreFile(Src + '\PokeTokenBar.version', Dst + '\PokeTokenBar.version', Copied, Kept) then Result := False;
  if FindFirst(Src + '\*', F) then
  try
    repeat
      if (F.Name <> '.') and (F.Name <> '..') and (F.Name <> BackupMarker) and not (Top and (CompareText(F.Name, 'PokeTokenBar.version') = 0)) then begin
        if (F.Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then begin
          if not RestoreTree(Src + '\' + F.Name, Dst + '\' + F.Name, Copied, Kept, False) then Result := False;
        end else if not RestoreFile(Src + '\' + F.Name, Dst + '\' + F.Name, Copied, Kept) then
          Result := False;
      end;
    until not FindNext(F);
  finally
    FindClose(F);
  end;
end;

// A copy left by an earlier Setup that did not end cleanly. Without its marker, that Setup stopped while making it,
// before it touched the app folder: the copy goes. With the marker the copy is complete, and it goes only when the app
// folder is complete and names ANOTHER version: the version file is written last (and put back first), so the install
// that made the copy wrote every file (a finished install whose copy could not be deleted, or one stopped after its
// last file). Otherwise (an incomplete folder, or the copy's own version: that Setup stopped while writing files or
// while putting them back, so the folder may be mixed) the copy is put back first. A finished reinstall of the same
// version whose copy could not be deleted also lands here; putting back that version's own files is harmless.
// Empty: go on. Otherwise why Setup stops (RestoreFailed is set: nothing is started).
function HandleLeftOverBackup(const AppDir, Aside: String): String;
var
  Copied, Kept: Integer;
  AppVersion, CopyVersion: String;
begin
  Result := '';
  if not DirExists(Aside) then Exit;
  if not (FileExists(Aside + '\' + BackupMarker) and FileExists(Aside + '\PokeTokenBar.exe')) then begin
    Log('PTB update: removing a partial left-over copy ' + Aside + ', result ' + IntToStr(Ord(DelTree(Aside, True, True, True))));
    Exit;
  end;
  AppVersion := VersionIn(AppDir);
  CopyVersion := VersionIn(Aside);
  if IsCompleteApp(AppDir) and (AppVersion <> CopyVersion) then begin
    Log('PTB update: removing a left-over copy of ' + CopyVersion + ' (the app folder has all of ' + AppVersion + '), result ' +
      IntToStr(Ord(DelTree(Aside, True, True, True))));
    Exit;
  end;
  Copied := 0;
  Kept := 0;
  if RestoreTree(Aside, AppDir, Copied, Kept, True) then
    Log('PTB update: put the left-over copy back (app folder version "' + AppVersion + '", copy "' + CopyVersion + '"; ' +
      IntToStr(Copied) + ' files copied back, ' + IntToStr(Kept) + ' unchanged), removing it: ' + IntToStr(Ord(DelTree(Aside, True, True, True))))
  else begin
    RestoreFailed := True;
    Log('PTB update: could not put the left-over copy back; it stays in ' + Aside);
    Result := 'Setup could not put back the copy of PokeTokenBar an earlier Setup left in ' + Aside +
      ', so it stopped. Close any program using files of PokeTokenBar, then run Setup again.';
  end;
end;

// The copy every update makes before it touches the app folder. Empty: go on (copied, or no previous app). Otherwise
// why Setup stops.
function BackUpPreviousApp: String;
var
  AppDir, Aside: String;
  Files: Integer;
  Bytes: Int64;
begin
  AppDir := ExpandConstant('{app}');
  Aside := AppDir + '.previous';
  Result := HandleLeftOverBackup(AppDir, Aside);
  if Result <> '' then Exit;
  if not FileExists(AppDir + '\PokeTokenBar.exe') then begin
    Log('PTB update: no previous app in ' + AppDir);
    Exit;
  end;
  if DirExists(Aside) then
    Log('PTB update: removing ' + Aside + ' before the copy, result ' + IntToStr(Ord(DelTree(Aside, True, True, True))));
  Log('PTB update: copying the previous app to ' + Aside);
  Files := 0;
  Bytes := 0;
  if CopyTree(AppDir, Aside, Files, Bytes) and SaveStringToFile(Aside + '\' + BackupMarker, IntToStr(Files) + ' files', False) then begin
    BackupDir := Aside;
    Log('PTB update: copied the previous app to ' + Aside + ' (' + IntToStr(Files) + ' files, ' + IntToStr(Bytes) + ' bytes)');
  end else begin
    Log('PTB update: could not copy the previous app to ' + Aside + '; nothing is changed, removing the partial copy: ' +
      IntToStr(Ord(DelTree(Aside, True, True, True))));
    Result := 'Setup could not keep a copy of the installed PokeTokenBar (is the disk full, or a file of it open?), so it changed nothing.';
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := BackUpPreviousApp;
  if Result <> '' then Exit;
#ifdef PTBTestFailInstall
  Log('PTBTestFailInstall: stopping in PrepareToInstall (test build)');
  Result := 'PTBTestFailInstall: this test build stops before installing.';
#endif
end;

procedure RestorePreviousApp;
var
  AppDir: String;
  Copied, Kept: Integer;
begin
  AppDir := ExpandConstant('{app}');
  if not FileExists(BackupDir + '\' + BackupMarker) then begin
    RestoreFailed := True;
    Log('PTB update: the copy ' + BackupDir + ' is not complete; the app folder stays as the unfinished install left it');
    Exit;
  end;
  Copied := 0;
  Kept := 0;
  if RestoreTree(BackupDir, AppDir, Copied, Kept, True) then
    Log('PTB update: put the previous app back from ' + BackupDir + ' (' + IntToStr(Copied) + ' files copied back, ' +
      IntToStr(Kept) + ' unchanged), removing the copy: ' + IntToStr(Ord(DelTree(BackupDir, True, True, True))))
  else begin
    RestoreFailed := True;
    Log('PTB update: could not put the previous app back; the complete copy stays in ' + BackupDir);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
    InstallStarted := True
  else if CurStep = ssDone then begin
    SetupFinished := True;
    Log('PTB update: setup finished');
    if BackupDir <> '' then
      Log('PTB update: removing the copy of the previous app ' + BackupDir + ', result ' + IntToStr(Ord(DelTree(BackupDir, True, True, True))));
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

// Setup ended without finishing: put the previous files back (only after ssInstall; before it nothing was written and
// the copy just goes), then, with /PTBRELAUNCHONFAIL=1 (the in-app update: the app exited for this Setup), start the
// app again as the user who started Setup. Not when another Setup runs, not when the previous app could not be put
// back, not while an instance holds the mutex (it did not close; a second start would only make it show itself).
procedure DeinitializeSetup;
var
  Exe: String;
  Code: Integer;
begin
  if OtherSetupRunning then begin
    Log('PTB relaunch: no (another Setup is running)');
    Exit;
  end;
  if SetupFinished then begin
    Log('PTB relaunch: no (setup finished)');
    Exit;
  end;
  if BackupDir <> '' then begin
    if InstallStarted then
      RestorePreviousApp
    else
      Log('PTB update: nothing was installed; removing the copy ' + BackupDir + ', result ' + IntToStr(Ord(DelTree(BackupDir, True, True, True))));
  end;
  if ExpandConstant('{param:PTBRELAUNCHONFAIL|0}') <> '1' then begin
    Log('PTB relaunch: no (setup did not finish; PTBRELAUNCHONFAIL is not 1)');
    Exit;
  end;
  if RestoreFailed then begin
    Log('PTB relaunch: no (the previous app could not be put back)');
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
