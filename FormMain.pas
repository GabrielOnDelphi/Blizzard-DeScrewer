UNIT FormMain;

{=============================================================================================================
   Blizzard DeScrewer
   2026.07.06
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   Automates the cleanup of Battle.net / Blizzard Entertainment remnants from Windows.
   Fixes the "installer stuck at 45%" issue by killing processes, removing registry keys,
   deleting data folders, optionally resetting WMI, and downloading a fresh installer.
   Preserves StarCraft II registry data for restoration after reinstall.
=============================================================================================================}

INTERFACE

USES
  WinApi.Windows, WinApi.Messages, System.SysUtils, System.Classes,
  Vcl.StdCtrls, Vcl.ComCtrls, Vcl.ExtCtrls, Vcl.Forms, Vcl.Controls,
  LightCore.AppData, LightVcl.Visual.AppData, LightVcl.Visual.AppDataForm,
  LightVcl.Internet.Download.Thread, Vcl.Imaging.jpeg;

TYPE
  TMainForm = class(TLightForm)
    grpCleanup     : TGroupBox;
    chkKillProc    : TCheckBox;
    chkRegHKCU     : TCheckBox;
    chkRegHKLM     : TCheckBox;
    chkBattleNet   : TCheckBox;
    chkBNetComp    : TCheckBox;
    chkBlizzard    : TCheckBox;
    chkLocalApp    : TCheckBox;
    chkRoamingApp  : TCheckBox;
    chkDocuments   : TCheckBox;
    chkProgFiles   : TCheckBox;
    chkResetWMI    : TCheckBox;
    chkHostsFile   : TCheckBox;
    chkSecLogon    : TCheckBox;
    chkNetReset    : TCheckBox;
    chkSysRepair   : TCheckBox;
    chkLocaleFix   : TCheckBox;
    chkDownload    : TCheckBox;
    chkRunInstaller: TCheckBox;
    btnCheckAll    : TButton;
    btnUncheckAll  : TButton;
    btnClean       : TButton;
    mmo            : TMemo;
    pbCountdown    : TProgressBar;
    StatBar        : TStatusBar;
    tmrCountdown   : TTimer;
    Image1: TImage;
    Panel1: TPanel;
    lblSC2: TLabel;
    edtSC2Path: TEdit;
    btnHelpLocate: TButton;
    procedure btnCleanClick      (Sender: TObject);
    procedure btnCheckAllClick   (Sender: TObject);
    procedure btnUncheckAllClick (Sender: TObject);
    procedure btnHelpLocateClick (Sender: TObject);
    procedure FormClose          (Sender: TObject; var Action: TCloseAction);
    procedure FormCloseQuery     (Sender: TObject; var CanClose: Boolean);
    procedure btnKillClick       (Sender: TObject);
    procedure tmrCountdownTimer  (Sender: TObject);
  private
    FDownloader      : TWinInetObj;
    FInstallerPath   : string;
    FRunning         : Boolean;
    FCountdownSecs   : Integer;
    procedure LogMsg(const Msg: string);
    procedure SetStatus(const Msg: string);
    procedure StepKillProcesses;
    procedure StepDeleteRegHKCU;
    procedure StepDeleteRegHKLM;
    procedure StepDeleteFolder(const FolderPath, Description: string);
    procedure StepResetWMI;
    procedure StepCleanHostsFile;
    procedure StepEnableSecondaryLogon;
    procedure StepNetworkReset;
    procedure StepSystemRepair;
    procedure StepLocaleFix;
    procedure StepRunInstaller;
    procedure SetUIEnabled(Enabled: Boolean);
    procedure DownloadDone(Sender: TObject);
    procedure StartCountdown;
    procedure StopCountdown;
    function  DetectSC2Path: string;
  public
    procedure FormPostInitialize; override;
    procedure FormPreRelease; override;
 end;

VAR
   MainForm: TMainForm;

IMPLEMENTATION {$R *.dfm}

USES
   System.DateUtils, System.IOUtils,
   LightVcl.Common.Registry,
   LightVcl.Common.Process,
   LightVcl.Common.ExecuteShell,
   LightVcl.Common.ExecuteProc,
   LightVcl.Common.IO,
   LightCore.TextFile,
   uInitialization;


CONST
  { Evergreen Blizzard URL: 302-redirects to the CURRENT installer version (verified 2026-07-07).
    The old version-pinned URL (…/installer/win/1.0.63/…) rots as Blizzard ships new versions.
    DownloadToStream follows redirects (HandleRedirects=TRUE, LightCore.Download.pas). }
  InstallerURL = 'https://us.battle.net/download/getInstaller?os=win&installer=Battle.net-Setup.exe';


{--------------------------------------------------------------------------------------------------
   RECURSIVE REGISTRY DELETE
   Windows RegDeleteKey may fail on keys with subkeys on 64-bit OS.
   This helper enumerates and deletes subkeys first.
--------------------------------------------------------------------------------------------------}
function DeleteRegKeyRecursive(Root: HKEY; const Key: string): Boolean;
VAR
  SubKeys: TStringList;
  i: Integer;
begin
  SubKeys:= RegEnumSubKeys(Root, Key);
  try
    for i:= 0 to SubKeys.Count-1 do
      DeleteRegKeyRecursive(Root, Key + '\' + SubKeys[i]);
  finally
    FreeAndNil(SubKeys);
  end;
  Result:= RegDeleteKey(Root, Key);
end;



{--------------------------------------------------------------------------------------------------
   SC2 PATH DETECTION
   Checks common install locations on disk. This is just for the user's
   reference — Battle.net uses its own product.db, not the registry.
--------------------------------------------------------------------------------------------------}
function TMainForm.DetectSC2Path: string;
CONST
  SC2CapKey = 'SOFTWARE\WOW6432Node\Blizzard Entertainment\StarCraft II\Capabilities';
VAR
  AppIcon: string;
  p: Integer;
begin
  Result:= '';

  { Try ApplicationIcon under SC2 Capabilities (legacy registry) }
  AppIcon:= RegReadString(HKEY_LOCAL_MACHINE, SC2CapKey, 'ApplicationIcon');
  if AppIcon <> '' then
   begin
    if (Length(AppIcon) > 0) AND (AppIcon[1] = '"')
    then Delete(AppIcon, 1, 1);
    p:= Pos('"', AppIcon);
    if p > 0
    then AppIcon:= Copy(AppIcon, 1, p - 1);
    Result:= ExtractFilePath(AppIcon);
    if Result.EndsWith('\Support64\', TRUE)                                   // 64-bit icon: ...\StarCraft II\Support64\SC2Switcher_x64.exe
    then Result:= Copy(Result, 1, Length(Result) - Length('Support64\'))
    else
      if Result.EndsWith('\Support\', TRUE)
      then Result:= Copy(Result, 1, Length(Result) - Length('Support\'));
    if NOT DirectoryExists(Result)
    then Result:= '';
   end;

  { Fallback: check common install locations }
  if Result = '' then
   begin
    if DirectoryExists('C:\Program Files (x86)\StarCraft II')
    then EXIT('C:\Program Files (x86)\StarCraft II\');
    if DirectoryExists('C:\Program Files\StarCraft II')
    then EXIT('C:\Program Files\StarCraft II\');
   end;
end;



{--------------------------------------------------------------------------------------------------
   APP START/CLOSE
--------------------------------------------------------------------------------------------------}
procedure TMainForm.FormPostInitialize;
begin
  inherited FormPostInitialize;

  FRunning:= FALSE;

  { Detect SC2 install path from registry. If not found, keep the
    value restored by asFull from the INI file (previous session). }
  VAR SC2Path: string;
  SC2Path:= DetectSC2Path;
  if SC2Path <> ''
  then edtSC2Path.Text:= SC2Path;

  uInitialization.LateInitialization;
  Show;
end;


{ The veto must live here, NOT in FormClose: TLightForm.CloseQuery runs saveBeforeExit
  (-> FormPreRelease -> SaveForm) BEFORE OnClose fires, so a veto in FormClose would come
  too late - the cleanup would already have destroyed the downloader mid-download. }
procedure TMainForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  CanClose:= NOT FRunning;
  if FRunning
  then LogMsg('Please wait for the current operation to finish.');
end;


procedure TMainForm.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  Action:= caFree;
end;


procedure TMainForm.FormPreRelease;
begin
  inherited FormPreRelease;
  StopCountdown;

  if NOT FFormSaved then
    if FDownloader <> NIL then
     begin
      { Download still in progress (forced shutdown, e.g. WM_ENDSESSION - the FormCloseQuery
        veto cannot stop that). Detach the event first: TWinInetObj.DoDownloadDone re-checks
        OnDownloadDone on the main thread, so no event can fire on a dying form. }
      FDownloader.OnDownloadDone:= NIL;
      FreeAndNil(FDownloader);   // TThread.Destroy waits for the worker thread to end
     end;
end;



{--------------------------------------------------------------------------------------------------
   UI HELPERS
--------------------------------------------------------------------------------------------------}
procedure TMainForm.LogMsg(const Msg: string);
begin
  mmo.Lines.Add(Msg);
  SendMessage(mmo.Handle, WM_VSCROLL, SB_BOTTOM, 0);
  mmo.Update;   // Paint now - the cleanup steps run without a message pump, so the memo would otherwise stay blank until the whole run finishes
end;


procedure TMainForm.SetStatus(const Msg: string);
begin
  StatBar.SimpleText:= Msg;
  StatBar.Update;
end;


procedure TMainForm.SetUIEnabled(Enabled: Boolean);
VAR i: Integer;
begin
  FRunning:= NOT Enabled;
  btnClean.Enabled:= Enabled;
  btnCheckAll.Enabled:= Enabled;
  btnUncheckAll.Enabled:= Enabled;
  btnHelpLocate.Enabled:= Enabled;

  for i:= 0 to grpCleanup.ControlCount-1 do
    if grpCleanup.Controls[i] is TCheckBox
    then grpCleanup.Controls[i].Enabled:= Enabled;

  if Enabled
  then SetStatus('Ready.')
  else SetStatus('Working...');
end;


procedure TMainForm.StartCountdown;
CONST CountdownMinutes = 15;
begin
  FCountdownSecs:= CountdownMinutes * 60;
  pbCountdown.Max:= FCountdownSecs;
  pbCountdown.Position:= FCountdownSecs;
  pbCountdown.Visible:= TRUE;
  tmrCountdown.Enabled:= TRUE;
  SetStatus('Installer running... ' + IntToStr(CountdownMinutes) + ':00 remaining');
end;


procedure TMainForm.StopCountdown;
begin
  tmrCountdown.Enabled:= FALSE;
  pbCountdown.Visible:= FALSE;
end;


procedure TMainForm.tmrCountdownTimer(Sender: TObject);
VAR Minutes, Seconds: Integer;
begin
  Dec(FCountdownSecs);
  pbCountdown.Position:= FCountdownSecs;

  if FCountdownSecs <= 0 then
   begin
    StopCountdown;
    SetStatus('Installer should be done by now. If still stuck at 45%, click "Kill now".');
    LogMsg('');
    LogMsg('>>> 15 minutes elapsed. The installer should be finished by now.');
    LogMsg('    If still stuck at 45%, click "Kill now" to kill Agent.exe, then restart the installer.');
    EXIT;
   end;

  Minutes:= FCountdownSecs div 60;
  Seconds:= FCountdownSecs mod 60;
  SetStatus('Installer running... ' + Format('%d:%.2d remaining  —  Click "Kill now" if stuck at 45%%', [Minutes, Seconds]));
end;


procedure TMainForm.btnCheckAllClick(Sender: TObject);
VAR i: Integer;
begin
  for i:= 0 to grpCleanup.ControlCount-1 do
    if grpCleanup.Controls[i] is TCheckBox
    then TCheckBox(grpCleanup.Controls[i]).Checked:= TRUE;
end;


procedure TMainForm.btnUncheckAllClick(Sender: TObject);
VAR i: Integer;
begin
  for i:= 0 to grpCleanup.ControlCount-1 do
    if grpCleanup.Controls[i] is TCheckBox
    then TCheckBox(grpCleanup.Controls[i]).Checked:= FALSE;
end;


procedure TMainForm.btnKillClick(Sender: TObject);
begin
  StepKillProcesses;
end;



procedure TMainForm.btnHelpLocateClick(Sender: TObject);
begin
  LogMsg('');
  LogMsg('=== How to make Battle.net find your existing games ===');
  LogMsg('');
  LogMsg('After a clean reinstall, Battle.net forgets where your games are.');
  LogMsg('It does NOT use the Windows registry — it stores game locations in its');
  LogMsg('own product.db file (which was deleted during cleanup).');
  LogMsg('');
  LogMsg('To re-link your games:');
  LogMsg('  1. Open Battle.net');
  LogMsg('  2. Click the Blizzard logo (top-left corner)');
  LogMsg('  3. Go to Settings > Downloads');
  LogMsg('  4. Click "Scan for Games"');
  LogMsg('  5. Battle.net will find your installed games automatically');
  LogMsg('');
  LogMsg('If Scan for Games does not find a game:');
  LogMsg('  - In Settings > Downloads > Game Settings, manually set the install folder');
  LogMsg('  - Or navigate to the game folder in Explorer and run the .exe directly');
  LogMsg('    (Battle.net will detect it when the game tries to connect)');
  LogMsg('');
end;



{--------------------------------------------------------------------------------------------------
   CLEANUP STEPS
--------------------------------------------------------------------------------------------------}
procedure TMainForm.StepKillProcesses;
CONST
  Processes: array[0..4] of string = (
    'Battle.net.exe',
    'Agent.exe',
    'BlizzardError.exe',
    'Battle.net-Setup.exe',
    'Blizzard Update Agent.exe'
  );
VAR
  ProcName: string;
begin
  LogMsg('Killing Blizzard processes...');
  for ProcName in Processes do
   begin
    if ProcessRunning(ProcName)
    then
     begin
      if KillProcess(ProcName)
      then LogMsg('  Killed: ' + ProcName)
      else LogMsg('  FAILED to kill: ' + ProcName);
     end
    else
      LogMsg('  Not running: ' + ProcName);
   end;
end;


procedure TMainForm.StepDeleteRegHKCU;
CONST Key = 'Software\Blizzard Entertainment';
begin
  LogMsg('Deleting HKCU\' + Key + '...');
  if RegKeyExist(HKEY_CURRENT_USER, Key)
  then
   begin
    if DeleteRegKeyRecursive(HKEY_CURRENT_USER, Key)
    then LogMsg('  Deleted successfully')
    else LogMsg('  FAILED to delete');
   end
  else
    LogMsg('  Key not found (already clean)');
end;


procedure TMainForm.StepDeleteRegHKLM;
CONST Key = 'SOFTWARE\WOW6432Node\Blizzard Entertainment';
begin
  LogMsg('Deleting HKLM\' + Key + '...');
  if RegKeyExist(HKEY_LOCAL_MACHINE, Key)
  then
   begin
    if DeleteRegKeyRecursive(HKEY_LOCAL_MACHINE, Key)
    then LogMsg('  Deleted successfully')
    else LogMsg('  FAILED to delete (need admin rights?)');
   end
  else
    LogMsg('  Key not found (already clean)');
end;


procedure TMainForm.StepDeleteFolder(const FolderPath, Description: string);
begin
  LogMsg('Deleting ' + Description + '...');
  LogMsg('  Path: ' + FolderPath);
  if DirectoryExists(FolderPath)
  then
   begin
    if RecycleItem(FolderPath, TRUE, FALSE, TRUE)
    then LogMsg('  Sent to Recycle Bin')
    else LogMsg('  FAILED to delete');
   end
  else
    LogMsg('  Folder not found (already clean)');
end;


procedure TMainForm.StepResetWMI;
VAR Output: string;
begin
  LogMsg('Resetting WMI repository...');

  { Force-kill TinyWall (it registers as NOT_STOPPABLE, so net stop fails) }
  LogMsg('  Force-stopping TinyWall (if running)...');
  Output:= ExecuteAndGetOut('sc config TinyWall start= disabled');
  LogMsg('  ' + Trim(Output));
  Output:= ExecuteAndGetOut('taskkill /F /FI "SERVICES eq TinyWall"');
  LogMsg('  ' + Trim(Output));

  { Stop WMI service and all dependents }
  LogMsg('  Stopping WMI service...');
  Output:= ExecuteAndGetOut('net stop winmgmt /y');
  LogMsg('  ' + Trim(Output));

  { Try salvage first (less destructive than full reset) }
  LogMsg('  Running: winmgmt /salvagerepository');
  Output:= ExecuteAndGetOut('winmgmt /salvagerepository');
  LogMsg('  ' + Trim(Output));

  { If salvage didn't help, try full reset }
  LogMsg('  Running: winmgmt /resetrepository');
  Output:= ExecuteAndGetOut('winmgmt /resetrepository');
  LogMsg('  ' + Trim(Output));

  { If reset failed (0x8007007E = missing DLL), recompile MOF files }
  if Pos('0x8007007E', Output) > 0 then
   begin
    LogMsg('  Reset failed with missing DLL error. Recompiling MOF files...');
    Output:= ExecuteAndGetOut('cmd /c "cd %windir%\system32\wbem && for /f %s in (''dir /b *.dll'') do regsvr32 /s %s"');
    LogMsg('  Re-registered DLLs');
    Output:= ExecuteAndGetOut('cmd /c "cd %windir%\system32\wbem && for /f %s in (''dir /b *.mof *.mfl'') do mofcomp %s"');
    LogMsg('  Recompiled MOF files');
   end;

  { Restart services }
  LogMsg('  Restarting WMI service...');
  Output:= ExecuteAndGetOut('net start winmgmt');
  LogMsg('  ' + Trim(Output));

  { Re-enable TinyWall }
  LogMsg('  Re-enabling TinyWall...');
  Output:= ExecuteAndGetOut('sc config TinyWall start= auto');
  LogMsg('  ' + Trim(Output));
  Output:= ExecuteAndGetOut('net start TinyWall');
  LogMsg('  ' + Trim(Output));

  LogMsg('  TIP: If WMI reset still fails, boot into Safe Mode and run this step there.');
end;


{ Removes stale Blizzard/Battle.net mappings from the Windows hosts file. A single user
  on the Blizzard forums reported this as THE fix after everything else failed. Only active
  (non-#) lines are touched, and the original is backed up to hosts.bak first. }
procedure TMainForm.StepCleanHostsFile;
CONST HostsRel = '\System32\drivers\etc\hosts';
VAR
  HostsPath, OrigText, Line, Lower, NewText: string;
  Lines: TStringList;
  i, Removed: Integer;
begin
  HostsPath:= GetEnvironmentVariable('SystemRoot') + HostsRel;
  LogMsg('Cleaning hosts file...');
  LogMsg('  Path: ' + HostsPath);

  if NOT FileExists(HostsPath) then
   begin
    LogMsg('  hosts file not found (nothing to clean)');
    EXIT;
   end;

  OrigText:= StringFromFile(HostsPath);
  Lines:= TStringList.Create;
  try
    Lines.Text:= OrigText;
    Removed:= 0;
    NewText:= '';
    for i:= 0 to Lines.Count-1 do
     begin
      Line := Lines[i];
      Lower:= LowerCase(Trim(Line));
      if  (Lower <> '')
      AND (Lower[1] <> '#')                                                       // keep comments
      AND ((Pos('blizzard', Lower) > 0) OR (Pos('battle.net', Lower) > 0))
      then
       begin
        LogMsg('  Removing: ' + Line);
        Inc(Removed);
       end
      else
        NewText:= NewText + Line + sLineBreak;
     end;

    if Removed > 0 then
     begin
      StringToFile(HostsPath + '.bak', OrigText, woOverwrite, wpOff);             // restorable copy
      StringToFile(HostsPath, NewText, woOverwrite, wpOff);                       // wpOff: no BOM - the hosts parser wants plain ASCII
      if Removed = 1
      then LogMsg('  Removed 1 Blizzard entry (backup saved as hosts.bak)')
      else LogMsg('  Removed ' + IntToStr(Removed) + ' Blizzard entries (backup saved as hosts.bak)');
     end
    else
      LogMsg('  No Blizzard entries found (already clean)');
  finally
    FreeAndNil(Lines);
  end;
end;


{ Battle.net explicitly requires the Windows "Secondary Logon" service (short name seclogon). }
procedure TMainForm.StepEnableSecondaryLogon;
VAR Output: string;
begin
  LogMsg('Enabling Secondary Logon service (required by Battle.net)...');

  Output:= ExecuteAndGetOut('sc config seclogon start= auto');                    // the space after "start=" is required by sc.exe
  LogMsg('  ' + Trim(Output));

  Output:= ExecuteAndGetOut('net start seclogon');                               // "already started" if it was running - harmless
  LogMsg('  ' + Trim(Output));
end;


{ Each machine has its own Winsock catalog, DNS cache and TCP/IP stack; a stale one can
  block the Update Agent. Winsock/TCP-IP reset only takes effect after a reboot. }
procedure TMainForm.StepNetworkReset;
VAR Output: string;
begin
  LogMsg('Resetting network stack...');

  LogMsg('  Flushing DNS cache...');
  Output:= ExecuteAndGetOut('ipconfig /flushdns');
  LogMsg('  ' + Trim(Output));

  LogMsg('  Resetting Winsock catalog...');
  Output:= ExecuteAndGetOut('netsh winsock reset');
  LogMsg('  ' + Trim(Output));

  LogMsg('  Resetting TCP/IP stack...');
  Output:= ExecuteAndGetOut('netsh int ip reset');
  LogMsg('  ' + Trim(Output));

  LogMsg('  NOTE: a REBOOT is required for the Winsock/TCP-IP reset to take effect.');
end;


{ Repairs corrupted Windows system files. DISM restores the component store, then SFC
  repairs protected system files from it. Both are slow (10-30 min) and block the UI. }
procedure TMainForm.StepSystemRepair;
VAR Output: string;
begin
  LogMsg('Repairing Windows system files (DISM + SFC)...');
  LogMsg('  WARNING: this can take 10-30 minutes. The window will look frozen - please wait.');
  mmo.Update;

  LogMsg('  Running: DISM /Online /Cleanup-Image /RestoreHealth');
  Output:= ExecuteAndGetOut('DISM /Online /Cleanup-Image /RestoreHealth');
  LogMsg(Trim(Output));

  LogMsg('  Running: sfc /scannow  (output may look garbled - it is Unicode; check %windir%\Logs\CBS\CBS.log for the real result)');
  Output:= ExecuteAndGetOut('sfc /scannow');
  LogMsg(Trim(Output));
end;


{ Forces the launcher UI language to English. Verified against a real registry export:
  HKCU\Software\Blizzard Entertainment\Launcher has a "Locale" string value (here "enUS").
  REGION is deliberately NOT touched - it is account-specific (EU/US/...). }
procedure TMainForm.StepLocaleFix;
CONST LauncherKey = 'Software\Blizzard Entertainment\Launcher';
begin
  LogMsg('Forcing Battle.net language to English (enUS)...');
  if RegWriteString(HKEY_CURRENT_USER, LauncherKey, 'Locale', 'enUS')
  then LogMsg('  Set HKCU\' + LauncherKey + '\Locale = enUS')
  else LogMsg('  FAILED to write registry value');
end;


procedure TMainForm.StepRunInstaller;
begin
  if (FInstallerPath = '') OR NOT FileExists(FInstallerPath)
  then
   begin
    LogMsg('Cannot run installer: file not found at ' + FInstallerPath);
    EXIT;
   end;

  LogMsg('Running Battle.net installer...');
  if NOT ExecuteFile(FInstallerPath) then
   begin
    LogMsg('  FAILED to launch the installer! Run it manually from: ' + FInstallerPath);
    EXIT;
   end;
  LogMsg('  Installer launched');
  LogMsg('');
  LogMsg('Waiting up to 15 minutes for the installer to complete...');
  LogMsg('TIP: If the installer freezes at 45%, click "Kill now" to kill Agent.exe.');
  LogMsg('     This forces the installer to restart the download agent and usually fixes it.');
  LogMsg('     If it still freezes, try switching to a mobile hotspot or VPN (ISP routing issue).');
  LogMsg('     Also check Windows Defender > "Controlled Folder Access" - it can silently block the installer.');
  LogMsg('');
  LogMsg('AFTER INSTALL: Battle.net won''t auto-find your games after a clean reinstall.');
  LogMsg('  Go to StarCraft II > click "Locate the game" > browse to your SC2 folder.');
  StartCountdown;
end;



{--------------------------------------------------------------------------------------------------
   MAIN ACTION
--------------------------------------------------------------------------------------------------}
procedure TMainForm.btnCleanClick(Sender: TObject);
VAR
  LocalAppData, UserProfile: string;
begin
  SetUIEnabled(FALSE);
  mmo.Clear;
  LogMsg('=== Blizzard DeScrewer - Starting cleanup ===');
  LogMsg('');


  { Step 1: Kill processes }
  if chkKillProc.Checked then
   begin
    try StepKillProcesses except on E: Exception do LogMsg('  ERROR: ' + E.Message) end;
    LogMsg('');
   end;

  { Step 2: Delete HKCU registry }
  if chkRegHKCU.Checked then
   begin
    try StepDeleteRegHKCU except on E: Exception do LogMsg('  ERROR: ' + E.Message) end;
    LogMsg('');
   end;

  { Step 3: Delete HKLM registry }
  if chkRegHKLM.Checked then
   begin
    try StepDeleteRegHKLM except on E: Exception do LogMsg('  ERROR: ' + E.Message) end;
    LogMsg('');
   end;

  { Steps 4-8: Delete folders }
  if chkBattleNet.Checked then
   begin
    try StepDeleteFolder('C:\ProgramData\Battle.net', 'ProgramData\Battle.net') except on E: Exception do LogMsg('  ERROR: ' + E.Message) end;
    LogMsg('');
   end;

  if chkBNetComp.Checked then
   begin
    try StepDeleteFolder('C:\ProgramData\Battle.net_components', 'ProgramData\Battle.net_components') except on E: Exception do LogMsg('  ERROR: ' + E.Message) end;
    LogMsg('');
   end;

  if chkBlizzard.Checked then
   begin
    try StepDeleteFolder('C:\ProgramData\Blizzard Entertainment', 'ProgramData\Blizzard Entertainment') except on E: Exception do LogMsg('  ERROR: ' + E.Message) end;
    LogMsg('');
   end;

  LocalAppData:= GetEnvironmentVariable('LOCALAPPDATA');
  if chkLocalApp.Checked then
   begin
    try StepDeleteFolder(LocalAppData + '\Blizzard Entertainment', 'AppData\Local\Blizzard Entertainment') except on E: Exception do LogMsg('  ERROR: ' + E.Message) end;
    LogMsg('');
   end;

  if chkRoamingApp.Checked then
   begin
    try StepDeleteFolder(GetEnvironmentVariable('APPDATA') + '\Battle.net', 'AppData\Roaming\Battle.net') except on E: Exception do LogMsg('  ERROR: ' + E.Message) end;
    LogMsg('');
   end;

  UserProfile:= GetEnvironmentVariable('USERPROFILE');
  if chkDocuments.Checked then
   begin
    try StepDeleteFolder(UserProfile + '\Documents\StarCraft II', 'Documents\StarCraft II') except on E: Exception do LogMsg('  ERROR: ' + E.Message) end;
    LogMsg('');
   end;

  if chkProgFiles.Checked then
   begin
    try StepDeleteFolder('C:\Program Files (x86)\Battle.net', 'Program Files (x86)\Battle.net') except on E: Exception do LogMsg('  ERROR: ' + E.Message) end;
    LogMsg('');
   end;

  { Clean hosts file }
  if chkHostsFile.Checked then
   begin
    try StepCleanHostsFile except on E: Exception do LogMsg('  ERROR: ' + E.Message) end;
    LogMsg('');
   end;

  { Reset WMI }
  if chkResetWMI.Checked then
   begin
    try StepResetWMI except on E: Exception do LogMsg('  ERROR: ' + E.Message) end;
    LogMsg('');
   end;

  { Enable Secondary Logon service }
  if chkSecLogon.Checked then
   begin
    try StepEnableSecondaryLogon except on E: Exception do LogMsg('  ERROR: ' + E.Message) end;
    LogMsg('');
   end;

  { Reset network stack }
  if chkNetReset.Checked then
   begin
    try StepNetworkReset except on E: Exception do LogMsg('  ERROR: ' + E.Message) end;
    LogMsg('');
   end;

  { Repair Windows system files }
  if chkSysRepair.Checked then
   begin
    try StepSystemRepair except on E: Exception do LogMsg('  ERROR: ' + E.Message) end;
    LogMsg('');
   end;

  { Force launcher language to English }
  if chkLocaleFix.Checked then
   begin
    try StepLocaleFix except on E: Exception do LogMsg('  ERROR: ' + E.Message) end;
    LogMsg('');
   end;

  { Download and run installer }
  if chkDownload.Checked then
   begin
    FInstallerPath:= GetEnvironmentVariable('TEMP') + '\Battle.net-Setup.exe';

    { Skip download if installer already exists and is less than 7 days old }
    if FileExists(FInstallerPath) AND (DaysBetween(Now, TFile.GetLastWriteTime(FInstallerPath)) < 7)
    then
     begin
      LogMsg('Battle.net installer already exists and is recent. Skipping download.');
      LogMsg('  Path: ' + FInstallerPath);
      LogMsg('');

      if chkRunInstaller.Checked then
       begin
        try StepRunInstaller except on E: Exception do LogMsg('  ERROR: ' + E.Message) end;
        LogMsg('');
       end;

      LogMsg('=== Cleanup complete ===');
      SetStatus('Done.');
      SetUIEnabled(TRUE);
     end
    else
     begin
      LogMsg('Downloading Battle.net installer...');
      LogMsg('  Save to: ' + FInstallerPath);

      FDownloader:= TWinInetObj.Create;
      FDownloader.OnDownloadDone:= DownloadDone;
      FDownloader.URL:= InstallerURL;
      FDownloader.Start;
      { UI stays disabled; DownloadDone will re-enable it }
     end;
   end
  else
   begin
    { No download requested }
    if chkRunInstaller.Checked then
     begin
      FInstallerPath:= GetEnvironmentVariable('TEMP') + '\Battle.net-Setup.exe';
      try StepRunInstaller except on E: Exception do LogMsg('  ERROR: ' + E.Message) end;
      LogMsg('');
     end;

    LogMsg('=== Cleanup complete ===');
    SetStatus('Done.');
    SetUIEnabled(TRUE);
   end;
end;



{--------------------------------------------------------------------------------------------------
   DOWNLOAD DONE
   Called by TWinInetObj.OnDownloadDone (thread-safe via Synchronize).
--------------------------------------------------------------------------------------------------}
procedure TMainForm.DownloadDone(Sender: TObject);
VAR
  Downloader: TWinInetObj;
begin
  Assert(FDownloader <> NIL, 'DownloadDone: FDownloader is NIL');

  { We are INSIDE the worker's Synchronize call. Freeing the TThread here deadlocks:
    TThread.Destroy calls WaitFor, but the worker cannot end until this handler returns.
    So: detach the field now, destroy the object later via the message queue. }
  Downloader:= FDownloader;
  FDownloader:= NIL;

  if Downloader.DownloadSuccess
  then
   begin
    try
      Downloader.Data.SaveToFile(FInstallerPath);
      LogMsg('  Download complete');
    except
      on E: Exception do
        LogMsg('  ERROR saving installer: ' + E.Message);
    end;
   end
  else
    LogMsg('  Download FAILED: ' + Downloader.HttpRetCode);   // HttpRetCode is a full error message, not a bare numeric code

  TThread.ForceQueue(NIL, procedure
    begin
      FreeAndNil(Downloader);   // Runs on the main thread after the worker has left Synchronize; Destroy's WaitFor returns immediately
    end);
  LogMsg('');

  if FileExists(FInstallerPath) AND chkRunInstaller.Checked then
   begin
    try StepRunInstaller except on E: Exception do LogMsg('  ERROR: ' + E.Message) end;
    LogMsg('');
   end;

  LogMsg('=== Cleanup complete ===');
  SetStatus('Done.');
  SetUIEnabled(TRUE);
end;




end.
