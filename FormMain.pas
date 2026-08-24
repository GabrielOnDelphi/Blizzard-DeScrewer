UNIT FormMain;

{=============================================================================================================
   Blizzard DeScrewer
   2026.08.23
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
    chkDiagRevoke  : TCheckBox;
    chkFixRevoke   : TCheckBox;
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
    FRevocationFailed: Boolean;   { Set by StepDiagnoseRevocation. The installer WILL fail while this is TRUE. }
    FSetupLogBefore  : string;    { Newest bootstrapper log that existed BEFORE we launched the installer, so we never read a stale one }
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
    procedure StepClearRevocationCache;
    function  NativeCmdPath: string;
    function  FolderProgramData: string;
    function  FolderProgramFilesX86: string;
    function  FolderProgramFilesNative: string;
    function  CurlPath: string;
    function  ProbeVersionService(NoRevoke: Boolean): string;
    function  RevocationProbeFails: Boolean;
    function  ProxyIsConfigured(const NetshOutput: string): Boolean;
    procedure StepDiagnoseRevocation;
    procedure StepFixRevocation;
    function  FindLatestSetupLog: string;
    procedure CheckInstallerOutcome;
    function  InternetIsReachable: Boolean;
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
   Winapi.WinSvc,
   Winapi.ShlObj,                    { CSIDL_COMMON_APPDATA / CSIDL_PROGRAM_FILESX86 - see the Folder* helpers }
   System.DateUtils, System.IOUtils,
   LightVcl.Common.Registry,
   LightVcl.Common.Process,
   LightVcl.Common.ExecuteShell,
   LightVcl.Common.ExecuteProc,
   LightVcl.Common.IO,
   LightVcl.Common.System,
   LightCore.IO,
   LightCore.TextFile,
   LightVcl.Internet.Common,
   uInitialization;


CONST
  { Evergreen Blizzard URL: 302-redirects to the CURRENT installer version (verified 2026-07-07).
    The old version-pinned URL (…/installer/win/1.0.63/…) rots as Blizzard ships new versions.
    DownloadToStream follows redirects (HandleRedirects=TRUE, LightCore.Download.pas). }
  InstallerURL = 'https://us.battle.net/download/getInstaller?os=win&installer=Battle.net-Setup.exe';

  { The bootstrapper's very first network call. Probing it reproduces the BLZBNTBTS00000028
    network phase without running the installer at all. }
  VersionServiceURL = 'https://us.version.battle.net/bts/versions';

  { CRL distribution point of the Let's Encrypt certificate that us.version.battle.net serves
    (leaf <- CN=YR2 <- ISRG Root YR <- ISRG Root X1). Used ONLY to prove the machine can reach
    the CRL host over plain HTTP - any answer counts, including 404, because Let's Encrypt
    rotates the shard number and this URL will eventually stop being 34.crl. }
  LetsEncryptCRL = 'http://yr2.c.lencr.org/34.crl';

  { Whitelist-mode (deny-by-default) firewalls. Service names, as they appear under
    HKLM\SYSTEM\CurrentControlSet\Services. Their presence is the prime suspect when the
    revocation fetch is refused locally: they block lsass.exe, Windows' own TLS engine, which is
    not a Blizzard program, so the user never sees a Blizzard entry being denied. }
  WhitelistFirewalls: array[0..4] of string = ('TinyWall', 'simplewall', 'cmdagent', 'nlsvc', 'GlassWire');

  { The bootstrapper writes one timestamped log per run, named battle.net-setup-YYYYMMDDThhmmss.log.
    Which folder it lands in depends on the installer build, so all three known candidates are
    searched and the newest file wins. The name sorts chronologically, which is what
    FindLatestSetupLog relies on - no file timestamps, no parsing. }
  SetupLogMask = 'battle.net-setup-*.log';


{ The local DeleteRegKeyRecursive helper that used to live here is gone. It existed because LightSaber's
  RegDeleteKey could not delete a key that had sub-keys - it opened the key with KEY_WRITE, which lacks
  KEY_QUERY_VALUE, so TRegistry.DeleteKey's own recursion was skipped silently. Fixed at the source on
  2026-08-22 (LightVcl.Common.Registry.pas), so RegDeleteKey now deletes the whole tree by itself. }


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
    if DirectoryExists(FolderProgramFilesX86 + '\StarCraft II')
    then EXIT(FolderProgramFilesX86 + '\StarCraft II\');
    if DirectoryExists(FolderProgramFilesNative + '\StarCraft II')
    then EXIT(FolderProgramFilesNative + '\StarCraft II\');
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

  { The design-time captions spell out the default English locations. The paths themselves are now
    asked from Windows, so on a PC that keeps those folders elsewhere the user would be SHOWN one
    path and have a different one deleted. Re-label from the very same expression the delete uses,
    so the label cannot lie about what is about to be removed. }
  chkBattleNet.Caption:= 'Delete ' + FolderProgramData + '\Battle.net';
  chkBNetComp.Caption := 'Delete ' + FolderProgramData + '\Battle.net_components';
  chkBlizzard.Caption := 'Delete ' + FolderProgramData + '\Blizzard Entertainment';
  chkProgFiles.Caption:= 'Delete ' + FolderProgramFilesX86 + '\Battle.net';

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

  { The cleanup steps run synchronously with NO message pump, so nothing repaints until
    the whole run ends - the form would show half-drawn garbage (reported by Gabriel).
    Force an immediate SYNCHRONOUS repaint of the form AND every windowed child control:
    RDW_UPDATENOW sends WM_ERASEBKGND/WM_PAINT before returning, RDW_ALLCHILDREN reaches
    the child HWNDs (buttons, memo, group box). Unlike Application.ProcessMessages this
    pumps NO input messages, so there is no re-entrancy risk. Verified against the Win32
    RedrawWindow docs, 2026-07-18.
    Caveat: this refreshes only BETWEEN steps - a single long blocking call (SFC/DISM, or
    a winmgmt reset) still cannot repaint until it returns. }
  RedrawWindow(Handle, nil, 0, RDW_INVALIDATE or RDW_ERASE or RDW_ALLCHILDREN or RDW_UPDATENOW);
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

  { Ask the installer's own log how it is going, instead of making the user wait out the full
    countdown to find out it died in the first second. }
  if FCountdownSecs mod 15 = 0 then
   begin
    try CheckInstallerOutcome except on E: Exception do LogMsg('  ERROR reading the installer log: ' + E.Message) end;
    if NOT tmrCountdown.Enabled then EXIT;    { CheckInstallerOutcome stopped us - the installer failed }
   end;

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
    if RegDeleteKey(HKEY_CURRENT_USER, Key)
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
    if RegDeleteKey(HKEY_LOCAL_MACHINE, Key)
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

  { Refuse anything that is not a full path to a FOLDER on a drive. The folder roots are now asked
    from Windows instead of hardcoded, and a failed query returns an empty string: '' + '\Battle.net'
    is '\Battle.net', which Windows resolves against whatever the CURRENT drive happens to be. The
    Folder* helpers already fall back to a literal so this should never fire - but the next line
    recursively deletes a tree, and that is not a place to rely on "should never".

    Written with Copy, not FolderPath[2] and FolderPath[3], on purpose. Indexing would fault on a
    short or empty string unless short-circuit boolean evaluation is in force, and this project
    builds with range checking ON - so the guard against a bad path could itself raise on the very
    input it exists to catch. Copy simply returns '' and cannot fault.
    The Length test is the second half: Copy('C:\', 2, 2) is also ':\', and 'C:\' is a whole DRIVE.
    Nothing here ever deletes a drive root, and it must stay impossible by construction. }
  if (Copy(FolderPath, 2, 2) <> ':\') OR (Length(FolderPath) <= 3) then
   begin
    LogMsg('  REFUSED: that is not a full path to a folder (like C:\Folder). Nothing was deleted.');
    EXIT;
   end;

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
VAR Output, NativeCmd: string;
begin
  LogMsg('Resetting WMI repository...');

  { This tool is a 32-bit (Win32) build. On 64-bit Windows a 32-bit process that runs a bare
    "winmgmt" is WOW64-redirected to the SysWOW64 copy, so it resets the 32-bit WMI SHADOW
    instead of the machine's real 64-bit repository - and on Gabriel's box this returned
    0x8007007E (ERROR_MOD_NOT_FOUND). Route the repository ops through the NATIVE cmd via the
    "Sysnative" alias so they hit the true 64-bit WMI (and regsvr32/mofcomp resolve to the
    64-bit copies). Sysnative exists ONLY for a WOW64 process; on a native build or a 32-bit
    OS it is absent, so we fall back to the normal System32 cmd with no change in behaviour.
    Verified 2026-07-18 against learn.microsoft.com "File System Redirector". }
  NativeCmd:= NativeCmdPath;
  if Pos('\Sysnative\', NativeCmd) > 0
  then LogMsg('  (32-bit tool on 64-bit Windows - targeting the native 64-bit WMI via Sysnative.)');

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
  Output:= ExecuteAndGetOut(NativeCmd + ' /c winmgmt /salvagerepository');
  LogMsg('  ' + Trim(Output));

  { If salvage didn't help, try full reset }
  LogMsg('  Running: winmgmt /resetrepository');
  Output:= ExecuteAndGetOut(NativeCmd + ' /c winmgmt /resetrepository');
  LogMsg('  ' + Trim(Output));

  { If reset failed (0x8007007E = ERROR_MOD_NOT_FOUND, a wbem DLL not registered), re-register
    the DLLs and recompile the MOF files in the NATIVE wbem folder. Going through NativeCmd
    makes %SystemRoot%\System32 resolve to the true (un-redirected) folder and regsvr32/mofcomp
    resolve to the 64-bit copies that match the 64-bit repository. }
  if Pos('0x8007007E', Output) > 0 then
   begin
    LogMsg('  Reset failed with 0x8007007E (a WMI module is not registered). Re-registering wbem DLLs...');
    Output:= ExecuteAndGetOut(NativeCmd + ' /c cd /d %SystemRoot%\System32\wbem && for /f %s in (''dir /b *.dll'') do regsvr32 /s %s');
    LogMsg('  Re-registered wbem DLLs');
    Output:= ExecuteAndGetOut(NativeCmd + ' /c cd /d %SystemRoot%\System32\wbem && for /f %s in (''dir /b *.mof *.mfl'') do mofcomp %s');
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

  LogMsg('  TIP: If WMI reset still fails, the repository may be badly corrupt - reboot into');
  LogMsg('       Safe Mode and run this step there, or run SFC /scannow + DISM /RestoreHealth first.');
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

  { Native netsh: reproduces the documented repair (an elevated 64-bit cmd) instead of the
    SysWOW64 copy that WOW64 redirection would hand this 32-bit process. }
  LogMsg('  Resetting Winsock catalog...');
  Output:= ExecuteAndGetOut(NativeCmdPath + ' /c netsh winsock reset');
  LogMsg('  ' + Trim(Output));

  LogMsg('  Resetting TCP/IP stack...');
  Output:= ExecuteAndGetOut(NativeCmdPath + ' /c netsh int ip reset');
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

  { Both tools go through NativeCmdPath, but for different reasons - MEASURED 2026-08-24 on
    Windows 11 build 26200, from a real 32-bit process:
      sfc  - MANDATORY. The redirected SysWOW64 copy answers "Windows Resource Protection could
             not start the repair service", while the same command through Sysnative answers
             "did not find any integrity violations". Half of this step was dead before the fix.
      DISM - PRECAUTION only. Here the bare 32-bit DISM worked exactly like the native one (same
             Image Version, same verdict, no error). Older builds are widely reported to refuse
             with "Error: 11 - You cannot service a running 64-bit operating system with a 32-bit
             version of DISM"; that was NOT reproduced on this build, so do not claim it as fact.
             Routing it natively costs nothing and removes the question. }
  LogMsg('  Running: DISM /Online /Cleanup-Image /RestoreHealth');
  Output:= ExecuteAndGetOut(NativeCmdPath + ' /c DISM /Online /Cleanup-Image /RestoreHealth');
  LogMsg(Trim(Output));

  LogMsg('  Running: sfc /scannow  (output may look garbled - it is Unicode; check %windir%\Logs\CBS\CBS.log for the real result)');
  Output:= ExecuteAndGetOut(NativeCmdPath + ' /c sfc /scannow');
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


{ Clears the Windows CryptAPI URL cache (cached CRL/OCSP revocation results).

  ROOT CAUSE this fixes (diagnosed 2026-07-14 on Gabriel's own machine):
  the Battle.net-Setup bootstrapper's very first call is an HTTPS GET to
  https://us.version.battle.net/bts/versions. Schannel validates that server
  certificate, which means fetching its revocation status (OCSP/CRL) over HTTP.
  If that revocation fetch is blocked - a whitelist firewall like TinyWall drops
  the non-whitelisted Battle.net-Setup.exe, while the browser is allowed - Schannel
  returns 0x80092013 CRYPT_E_REVOCATION_OFFLINE, the TLS handshake fails, and the
  bootstrapper reports "can't connect to the patch service" = BLZBNTBTS00000028.
  Confirmed via Windows System log, Schannel event 36876, SSPI client Battle.net-Setup.

  Windows then CACHES that "revocation offline" negative result, so the next attempt
  keeps failing even after the firewall is opened. Clearing the cache removes the poison.
  The cache is per-user; the setup runs elevated but as the SAME user, so this reaches it.
  Syntax verified: certutil -urlcache * delete  (GlobalSign / gradenegger.eu, 2026-07).

  LIMIT, measured 2026-08-23 on two machines: this clears the POISONED-CACHE variant only.
  It does NOT fix the variant seen on both of Gabriel's PCs, where the CRL shard was never
  cached in the first place - CryptoAPI reports  Failed "CDP" Time: 0  0x80072efd
  (WinHttp 12029 ERROR_WINHTTP_CANNOT_CONNECT) on http://yr2.c.lencr.org/34.crl, i.e. the
  request is refused locally and never reaches the wire. Pre-seeding the CRL with
  certutil -addstore CA installs cleanly but changes nothing either. Keep this step (it is
  free and it does fix the cached-negative case), but the real diagnosis is the A/B probe. }
procedure TMainForm.StepClearRevocationCache;
VAR
  Output: string;
  Lines: TStringList;
  i: Integer;
  Reported: Boolean;
begin
  LogMsg('Clearing TLS certificate-revocation cache (CRL/OCSP)...');
  Output:= ExecuteAndGetOut('certutil -urlcache * delete');

  { Do NOT log this output raw. MEASURED 2026-08-24: certutil printed every cached URL, then
      WinHttp Cache entries deleted: 7
      CertUtil: -URLCache command FAILED: 0x80070103 (WIN32/HTTP: 259 ERROR_NO_MORE_ITEMS)
    It had deleted all 7 entries and succeeded. 0x80070103 is ERROR_NO_MORE_ITEMS - certutil
    simply ran out of entries to walk - but a user reading "FAILED" concludes the step broke,
    in the one program whose whole job is telling them what is actually wrong.
    So: report the counts, swallow that one harmless code, and still show any OTHER failure. }
  Reported:= FALSE;
  Lines:= TStringList.Create;
  TRY
    Lines.Text:= Output;
    for i:= 0 to Lines.Count-1 do
      if Pos('deleted:', Lines[i]) > 0
      then
       begin
        LogMsg('  ' + Trim(Lines[i]));
        Reported:= TRUE;
       end
      else
      if (Pos('FAILED', Lines[i]) > 0) AND (Pos('0x80070103', Lines[i]) = 0)
      then
       begin
        LogMsg('  ' + Trim(Lines[i]));
        Reported:= TRUE;
       end;
  FINALLY
    FreeAndNil(Lines);
  END;

  if NOT Reported
  then LogMsg('  Nothing was cached.');

  LogMsg('  (Prevents a cached "revocation server offline" result from blocking the installer.)');
end;


{ Full path of the NATIVE cmd.exe. This is a 32-bit build, so on 64-bit Windows a bare tool name
  resolves to the SysWOW64 copy (WOW64 file-system redirection) - a DIFFERENT binary that can give
  a confidently wrong result. Two of these are MEASURED on Windows 11 build 26200 (2026-08-24):
  the SysWOW64 sfc cannot start the repair service at all, and SysWOW64 netsh reads/writes the
  32-BIT WinHTTP proxy view while lsass.exe (64-bit) uses the 64-bit view. DISM, on that build,
  worked either way - the "32-bit DISM refuses a 64-bit OS" story is reported for older builds
  but did not reproduce here.
  The Sysnative alias reaches the true System32 and exists ONLY for a WOW64 process; on 32-bit
  Windows we fall back to the normal System32 cmd with no change in behaviour.
  Do NOT quote the result - ExecuteAndGetOut runs "cmd.exe /C <CmdLine>" and cmd mangles a command
  line whose FIRST character is a quote (see CurlPath); the Windows directory has no spaces. }
function TMainForm.NativeCmdPath: string;
VAR WinDir: string;
begin
  WinDir:= GetEnvironmentVariable('windir');
  if DirectoryExists(WinDir + '\Sysnative')
  then Result:= WinDir + '\Sysnative\cmd.exe'
  else Result:= WinDir + '\System32\cmd.exe';
end;


{ The three system folders this program deletes from, asked from Windows instead of hardcoded.

  WHY, and why NOT for the reason you would expect: on a German (or any localized) Windows the
  folder on disk is still literally "ProgramData" and "Program Files". Only the name Explorer
  DISPLAYS is translated - through a desktop.ini entry, plus compatibility junctions such as
  C:\Programme pointing at the real English folder. Localization is therefore NOT what breaks a
  hardcoded path. What does break it: Windows installed on a drive other than C:, and a
  ProgramData or Program Files that has been relocated. On Windows XP the names really were
  translated on disk, but that is long gone.
  (Verified: https://en.wikipedia.org/wiki/Program_Files - localized names are junction points to
  the non-localized locations.)

  ForceFolder stays FALSE on every call. That matters twice: it means no trailing backslash is
  added (so '\Battle.net' can be appended directly), and it means the call never CREATES the
  folder - which would be an absurd thing to do right before deleting it. }
function TMainForm.FolderProgramData: string;
begin
  Result:= GetSpecialFolder(CSIDL_COMMON_APPDATA);
  if Result = '' then
   begin
    LogMsg('  WARNING: Windows did not report where ProgramData is. Falling back to C:\ProgramData.');
    Result:= 'C:\ProgramData';
   end;
end;


function TMainForm.FolderProgramFilesX86: string;
begin
  Result:= GetSpecialFolder(CSIDL_PROGRAM_FILESX86);
  if Result = '' then
   begin
    LogMsg('  WARNING: Windows did not report where Program Files (x86) is. Falling back to C:\Program Files (x86).');
    Result:= 'C:\Program Files (x86)';
   end;
end;


{ The NATIVE 64-bit Program Files. No CSIDL returns it to a 32-bit program - MEASURED 2026-08-24 on
  this machine, from a real 32-bit process: CSIDL_PROGRAM_FILES answers "C:\Program Files (x86)",
  the same as CSIDL_PROGRAM_FILESX86. LightSaber's GetProgramFilesDir does not help either: it reads
  HKLM\...\CurrentVersion\ProgramFilesDir, which WOW64 redirects to WOW6432Node, so it agrees with
  them. ProgramW6432 is the variable Windows provides for exactly this case, and it measured correct
  (32-bit process: "C:\Program Files"). A genuine 32-bit Windows has no ProgramW6432 - there ProgramFiles
  is already the only Program Files, so it is the right fallback. }
function TMainForm.FolderProgramFilesNative: string;
begin
  Result:= GetEnvironmentVariable('ProgramW6432');
  if Result = '' then Result:= GetEnvironmentVariable('ProgramFiles');
  if Result = '' then
   begin
    LogMsg('  WARNING: Windows did not report where Program Files is. Falling back to C:\Program Files.');
    Result:= 'C:\Program Files';
   end;
end;


{ Full path of the Windows-supplied curl.exe, or '' when this Windows is too old to have one
  (System32\curl.exe ships with Windows 10 1803 and later).

  Why curl and not our own HTTP code: this curl is built against Schannel, so it validates the
  server certificate through the SAME Windows stack the Battle.net bootstrapper uses. Its
  --ssl-no-revoke switch turns off exactly one thing - the revocation check - which makes an
  A/B pair a direct measurement of the failure instead of a guess.

  Do NOT quote the path when handing it to ExecuteAndGetOut: that helper runs
  "cmd.exe /C <CmdLine>", and cmd mangles the arguments when the command line's FIRST character
  is a quote (measured 2026-08-23: the whole line up to the next quote was taken as the program
  name). The Windows directory cannot contain a space, so an unquoted path is safe. }
function TMainForm.CurlPath: string;
VAR WinDir: string;
begin
  WinDir:= GetEnvironmentVariable('windir');

  { MEASURED 2026-08-23, and it silently falsified the whole diagnosis before it was found:
    this is a 32-bit tool, so "System32" is WOW64-redirected to SysWOW64 - a DIFFERENT curl.exe
    (691,760 bytes instead of 791,600). A whitelist firewall permits programs BY PATH, so the
    64-bit curl was allowed and the 32-bit one was refused; both probes then returned 000 and
    the step wrongly reported "a real connectivity problem". The Sysnative alias reaches the
    true System32 and exists ONLY for a WOW64 process - same trick StepResetWMI uses. }
  if DirectoryExists(WinDir + '\Sysnative') then
   begin
    Result:= WinDir + '\Sysnative\curl.exe';
    if FileExists(Result) then EXIT;
   end;

  Result:= WinDir + '\System32\curl.exe';
  if NOT FileExists(Result) then Result:= '';
end;


// Returns the HTTP status code as text. '000' means the TLS handshake never completed.
//
// The http_code write-out is used rather than exitcode on purpose: %{exitcode} only exists in
// curl 7.75 and later, while Windows 10 1803 shipped 7.55. %{http_code} yields '000' on a TLS
// failure in every version.
//
// Line comments, not a { } block: curl's write-out placeholders contain a closing brace, which
// would end a brace comment early (see the Compiler Quirks note in the global CLAUDE.md).
function TMainForm.ProbeVersionService(NoRevoke: Boolean): string;
VAR Cmd: string;
begin
  Cmd:= CurlPath + ' -s -o NUL -w "%{http_code}" --max-time 20 ';
  if NoRevoke
  then Cmd:= Cmd + '--ssl-no-revoke ';
  Result:= Trim(ExecuteAndGetOut(Cmd + '"' + VersionServiceURL + '"'));
end;


{ TRUE only for the revocation signature: the handshake fails WITH the revocation check and
  succeeds WITHOUT it. Both probes failing is a genuine connectivity problem, not this bug,
  and must not be reported as one. }
function TMainForm.RevocationProbeFails: Boolean;
begin
  Result:= (ProbeVersionService(FALSE) <> '200')
       AND (ProbeVersionService(TRUE)  =  '200');
end;


{ "netsh winhttp show proxy" prints localized labels, so searching for "Direct access" only
  works on an English Windows. What IS language-independent: when a proxy exists netsh prints
  its host:port, and a colon followed immediately by a digit appears nowhere else in that output
  - the localized labels are always followed by a space. }
function TMainForm.ProxyIsConfigured(const NetshOutput: string): Boolean;
VAR i: Integer;
begin
  for i:= 1 to Length(NetshOutput)-1 do
    if (NetshOutput[i] = ':') AND CharInSet(NetshOutput[i+1], ['0'..'9'])
    then EXIT(TRUE);
  Result:= FALSE;
end;


{ Read-only probe for the failure DeScrewer's other 18 steps cannot see. Changes nothing.

  WHAT IT DETECTS (measured on two of Gabriel's machines, 2026-08-20 and 2026-08-23):
  us.version.battle.net now serves a Let's Encrypt certificate that carries NO OCSP responder
  URL - Let's Encrypt and Google Trust Services have finished retiring OCSP. The only way left
  for Windows to establish revocation status is to download a 161 KB CRL over plain HTTP on
  port 80. When that download is refused, Schannel aborts the handshake with 0x80092013
  CRYPT_E_REVOCATION_OFFLINE and the bootstrapper reports BLZBNTBTS00000028.

  This is a NEW failure class - the same machine worked a year ago, when the check was a small,
  usually-cached OCSP query - and it will keep spreading as more issuers drop OCSP. }
procedure TMainForm.StepDiagnoseRevocation;
VAR
  OnCode, OffCode, CrlCode, Output, Firewalls: string;
  i: Integer;
begin
  LogMsg('Checking TLS certificate revocation (the invisible cause of BLZBNTBTS00000028)...');
  FRevocationFailed:= FALSE;    { re-runs must start from a clean verdict }

  if CurlPath = '' then
   begin
    LogMsg('  curl.exe not found - needs Windows 10 1803 or later. Skipping this check.');
    EXIT;
   end;

  { # The A/B probe }
  OnCode := ProbeVersionService(FALSE);
  OffCode:= ProbeVersionService(TRUE);
  LogMsg('  revocation ON : HTTP ' + OnCode);
  LogMsg('  revocation OFF: HTTP ' + OffCode);

  if OnCode = '200' then
   begin
    LogMsg('  OK - Windows can validate Blizzard''s certificate. This is not your problem.');
    EXIT;
   end;

  if OffCode <> '200' then
   begin
    LogMsg('  Both probes failed - this is a real connectivity problem, not a revocation one.');
    LogMsg('  Try the "Clean hosts file" and "Reset network stack" steps.');
    EXIT;
   end;

  FRevocationFailed:= TRUE;
  LogMsg('');
  LogMsg('  >>> CONFIRMED: the certificate revocation check is failing. <<<');
  LogMsg('  The installer CAN reach Blizzard. Windows aborts the connection because it');
  LogMsg('  cannot download the certificate revocation list (CRL).');
  LogMsg('');

  { # Network, or this machine? }
  CrlCode:= Trim(ExecuteAndGetOut(CurlPath + ' -s -o NUL -w "%{http_code}" --max-time 15 "' + LetsEncryptCRL + '"'));
  LogMsg('  CRL download test: HTTP ' + CrlCode);
  if CrlCode <> '000'
  then LogMsg('  The CRL host answers from this PC -> your Internet is NOT the problem.')
  else LogMsg('  The CRL host is unreachable -> a proxy, DNS or upstream filter is blocking HTTP port 80.');

  { # Corroborating facts }
  { NATIVE netsh, not a bare "netsh": WinHTTP proxy settings exist per bitness (the 32-bit view
    lives under WOW6432Node), and the CRL fetch is made by lsass.exe, a 64-BIT process - so only
    the 64-bit view matters. A bare netsh from this 32-bit tool would show the 32-bit view and
    could report "no proxy" while lsass is choking on one (learn.microsoft.com/en-us/archive/
    blogs/jpsanders/winhttp-proxy-settings-in-64-bit-x64-environments). }
  Output:= Trim(ExecuteAndGetOut(NativeCmdPath + ' /c netsh winhttp show proxy'));
  LogMsg('  WinHTTP proxy: ' + StringReplace(Output, sLineBreak, ' ', [rfReplaceAll]));
  if ProxyIsConfigured(Output)
  then LogMsg('    ^ A WinHTTP proxy is set. If it is unreachable, every CRL fetch fails. See the "Fix" step.');

  LogMsg('  Clock: ' + DateTimeToStr(Now) + ' local / ' + DateTimeToStr(TTimeZone.Local.ToUniversalTime(Now)) + ' UTC');
  LogMsg('        (a wrong clock makes every CRL look expired, which raises the same error)');

  { WinAPI query, not "sc query" - sc.exe prints LOCALIZED state names, so searching its output
    for 'RUNNING' fails on every non-English Windows. The SCM query is language- and bitness-neutral. }
  if ServiceGetStatus('', 'CryptSvc') <> SERVICE_RUNNING
  then LogMsg('  Could not confirm that Cryptographic Services (CryptSvc) is running - check services.msc.');

  Firewalls:= '';
  for i:= Low(WhitelistFirewalls) to High(WhitelistFirewalls) do
    if RegKeyExist(HKEY_LOCAL_MACHINE, 'SYSTEM\CurrentControlSet\Services\' + WhitelistFirewalls[i])
    then Firewalls:= Firewalls + WhitelistFirewalls[i] + ' ';

  LogMsg('');
  if Firewalls <> '' then
   begin
    LogMsg('  Whitelist-mode firewall installed: ' + Trim(Firewalls));
    LogMsg('  IMPORTANT: the blocked program is NOT a Blizzard one - it is Windows'' own certificate');
    LogMsg('  service. That is why no Blizzard entry ever appears in your firewall log, and why');
    LogMsg('  whitelisting Battle.net-Setup.exe / Battle.net.exe / Agent.exe does not help.');
    LogMsg('  -> Set the firewall to "Allow outgoing" (or allow lsass.exe on outgoing TCP port 80),');
    LogMsg('     then run this check again.');
   end
  else
    LogMsg('  No whitelist-mode firewall found by name. Run the "Fix certificate revocation" step.');
end;


{ Repairs what can be repaired, cheapest first, re-probing after each sub-fix so the log names
  the one that actually worked. Does nothing at all when the probe is clean.

  DELIBERATELY NOT DONE - both were tested and ruled out on 2026-08-20:
    - Pre-seeding the CRL with "certutil -addstore CA <file>". It installs cleanly and changes
      nothing; Schannel still insists on its own retrieval.
    - Disabling revocation checking machine-wide. It is a real security downgrade, it would
      outlive the problem, and Windows offers no supported switch for it anyway: the
      NoCertRevocationCheck value is read by SstpSvc only, and CRLF_REVCHECK_IGNORE_OFFLINE is
      a setting on the certificate authority, not on the client (Microsoft Learn, 2026-08).
  And DeScrewer never turns the user's firewall off by itself - it says what to do instead. }
procedure TMainForm.StepFixRevocation;
VAR Output, OldProxy: string;
begin
  LogMsg('Repairing certificate revocation...');

  if CurlPath = '' then
   begin
    LogMsg('  curl.exe not found - a fix could not be verified. Skipping.');
    EXIT;
   end;

  if NOT RevocationProbeFails then
   begin
    { The probe just measured that the revocation signature is NOT present, so a verdict left
      over from an earlier StepDiagnoseRevocation is stale - without this reset the
      StepRunInstaller warning prompt would contradict the line logged right below. }
    FRevocationFailed:= FALSE;
    LogMsg('  Nothing to fix: the revocation check is not what is failing here.');
    EXIT;
   end;

  { # 1 - stale cache }
  LogMsg('  [1/3] Clearing the revocation cache...');
  ExecuteAndGetOut('certutil -urlcache * delete');
  if NOT RevocationProbeFails then
   begin
    FRevocationFailed:= FALSE;
    LogMsg('  FIXED by clearing the revocation cache.');
    EXIT;
   end;

  { # 2 - WinHTTP proxy }
  { NATIVE netsh (see StepDiagnoseRevocation): lsass.exe is 64-bit, so only the 64-bit WinHTTP
    proxy view can poison its CRL fetch. A bare netsh from this 32-bit tool would probe and reset
    the WOW6432Node view - it would skip the fix exactly when it is needed, and "fix" nothing. }
  OldProxy:= Trim(ExecuteAndGetOut(NativeCmdPath + ' /c netsh winhttp show proxy'));
  if ProxyIsConfigured(OldProxy) then
   begin
    LogMsg('  [2/3] Resetting the WinHTTP proxy. Previous setting was:');
    LogMsg('        ' + StringReplace(OldProxy, sLineBreak, ' ', [rfReplaceAll]));
    ExecuteAndGetOut(NativeCmdPath + ' /c netsh winhttp reset proxy');
    if NOT RevocationProbeFails then
     begin
      FRevocationFailed:= FALSE;
      LogMsg('  FIXED by resetting the WinHTTP proxy.');
      EXIT;
     end;
   end
  else
    LogMsg('  [2/3] No WinHTTP proxy set - skipping.');

  { # 3 - clock }
  LogMsg('  [3/3] Re-syncing the system clock...');
  ExecuteAndGetOut('sc config W32Time start= auto');                             // the space after "start=" is required by sc.exe
  ExecuteAndGetOut('net start W32Time');
  Output:= ExecuteAndGetOut('w32tm /resync /force');
  { w32tm answers on two lines and mixes CRLF with a bare LF, which a TMemo renders as a broken
    line. Flatten it to one. }
  Output:= StringReplace(Output, #13, ' ', [rfReplaceAll]);
  Output:= StringReplace(Output, #10, ' ', [rfReplaceAll]);
  LogMsg('        ' + Trim(Output));
  if NOT RevocationProbeFails then
   begin
    FRevocationFailed:= FALSE;
    LogMsg('  FIXED by correcting the clock.');
    EXIT;
   end;

  LogMsg('');
  LogMsg('  Still failing. Your firewall is blocking Windows'' own TLS engine - lsass.exe - from');
  LogMsg('  downloading the certificate revocation list on outgoing TCP port 80.');
  LogMsg('  DeScrewer will not change your firewall for you. Do this by hand:');
  LogMsg('    1. Add a PERMANENT exception for  C:\Windows\System32\lsass.exe');
  LogMsg('       Outgoing TCP port 80 ONLY. Leave every other port, and all inbound, closed.');
  LogMsg('    2. Press "Clean" again. This step should then say the revocation check is working.');
  LogMsg('');
  LogMsg('  MEASURED 2026-08-23 on a TinyWall machine: lsass.exe is the process that makes the');
  LogMsg('  fetch. Whitelisting svchost.exe does NOT fix it, and neither does whitelisting any');
  LogMsg('  Blizzard file - no Blizzard program is involved in this request at all.');
  LogMsg('  Quick alternative if you would rather not touch lsass.exe: set the firewall to');
  LogMsg('  "Allow outgoing" for the few minutes the install takes, then put it back.');
end;


{ Newest bootstrapper log on this machine, or '' if there is none.

  The installer writes one timestamped log per run and reports its own verdict there, so the log
  is the only trustworthy way to learn whether the install actually worked. Watching for the
  error WINDOW would be worse: its caption is localized and changes between installer builds.

  The file name (battle.net-setup-YYYYMMDDThhmmss.log) sorts chronologically, so plain string
  comparison finds the newest one across all candidate folders - no file timestamps to trust. }
function TMainForm.FindLatestSetupLog: string;

  procedure ScanFolder(const Folder: string);
  VAR
    Files: TStringList;
    i: Integer;
  begin
    if (Folder = '') OR NOT DirectoryExists(Folder) then EXIT;
    Files:= ListFilesOf(Folder, SetupLogMask, TRUE, FALSE);
    TRY
      for i:= 0 to Files.Count-1 do
        if (Result = '') OR (CompareText(ExtractFileName(Files[i]), ExtractFileName(Result)) > 0)
        then Result:= Files[i];
    FINALLY
      FreeAndNil(Files);
    END;
  end;

begin
  Result:= '';
  ScanFolder(FolderProgramData + '\Battle.net\Setup');
  ScanFolder(GetEnvironmentVariable('LOCALAPPDATA') + '\Battle.net\Setup');
  ScanFolder(GetEnvironmentVariable('TEMP'));
end;


{ Reads the log the installer wrote for THIS run and tells the user what actually happened.

  Called every 15 seconds while the countdown runs, so a failure is reported in seconds instead
  of after the full 15-minute wait. Only a log newer than FSetupLogBefore counts - otherwise a
  leftover log from an earlier, failed attempt would be reported as today's result. }
procedure TMainForm.CheckInstallerOutcome;
VAR
  LogFile, Content: string;
begin
  LogFile:= FindLatestSetupLog;
  if LogFile = '' then EXIT;
  if CompareText(ExtractFileName(LogFile), ExtractFileName(FSetupLogBefore)) <= 0 then EXIT;   { still the pre-launch log }

  Content:= '';
  TRY
    Content:= StringFromFile(LogFile);       { the installer keeps the file open - a read can legitimately fail }
  EXCEPT
    { EInOutError, NOT EFOpenError: StringFromFile = TFile.ReadAllText, and TFile.OpenRead catches
      every EFileStreamError (EFOpenError included) and re-raises it as EInOutError
      (System.IOUtils.pas, TFile.OpenRead). An EFOpenError can never arrive here. }
    on E: EInOutError do EXIT;               { locked right now; the next tick will try again }
  END;

  if Pos('BLZBNTBTS00000028', Content) = 0 then EXIT;

  StopCountdown;
  LogMsg('');
  LogMsg('>>> The installer FAILED with BLZBNTBTS00000028. <<<');
  LogMsg('    Read from its own log: ' + LogFile);
  LogMsg('');
  LogMsg('    This is NOT a broken Internet connection and NOT a leftover Blizzard file.');
  LogMsg('    Windows could not download the certificate revocation list (CRL) that it needs');
  LogMsg('    before it will trust Blizzard''s server, so it aborted the connection itself.');
  LogMsg('    Tick "Diagnose certificate / revocation problem" and press Clean to see the proof.');
  SetStatus('Installer failed: BLZBNTBTS00000028 (certificate revocation).');

  Application.MessageBox(
    'The Battle.net installer failed with error BLZBNTBTS00000028.'#13#10#13#10 +
    'Your Internet connection is fine. The real cause is that Windows cannot download the '
    + 'certificate revocation list it needs before trusting Blizzard''s server - almost always '
    + 'because a firewall is blocking WINDOWS ITSELF on port 80. The program being blocked is '
    + 'lsass.exe, Windows'' own TLS engine - not any Blizzard program, which is why you never see '
    + 'a Blizzard entry in your firewall.'#13#10#13#10 +
    'Set your firewall to "Allow outgoing" for a few minutes and run the installer again.'#13#10 +
    'The log window has the details.',
    'Battle.net installer failed', MB_OK or MB_ICONWARNING);
end;


{ TRUE when this program can actually reach the Internet. Used ONLY before the automatic
  installer download - a manual run must never be blocked by a connectivity opinion.

  The three failing answers are genuinely different problems and each gets its own advice.
  Note the second one: DeScrewer is itself a freshly built EXE, so a whitelist firewall blocks
  IT by default, which looks exactly like "no Internet" unless it is named. }
function TMainForm.InternetIsReachable: Boolean;
VAR State: Integer;
begin
  LogMsg('Checking Internet connection...');
  State:= ProgramConnect2Internet(ConnectivityProbeURL, ConnectivityProbeTimeout, ConnectivityProbeBody);
  Result:= State = 1;   { Only state 1 counts. State 2 = an HTTP 200 came back but the body was NOT
                          the expected marker, i.e. a captive portal or a content-rewriting proxy is
                          in the path (LightVcl.Internet.Common.ProgramConnect2Internet). The
                          installer download that would follow is HTTPS, so on a real portal it dies
                          in the TLS handshake anyway, and behind a rewriting proxy its content is
                          whatever that proxy decides to return - neither is worth attempting.
                          A FALSE here never aborts the cleanup: the caller falls back to an
                          installer already on disk, or tells the user to fetch one by hand. }

  case State of
   -1: begin
         LogMsg('  This PC is NOT connected to the Internet.');
         LogMsg('  Connect first, then press Clean again - or download the installer by hand from');
         LogMsg('  https://www.blizzard.com/download and untick "Download Battle.net installer".');
       end;
    0: begin
         LogMsg('  The PC is online, but THIS program got no answer back.');
         LogMsg('  Your firewall is blocking BlizzardDeScrewer.exe. Whitelist it (TinyWall: tray icon >');
         LogMsg('  Whitelist by executable), or download the installer by hand.');
       end;
    1: LogMsg('  Connected.');
    2: begin
         LogMsg('  Something answered, but it was not the real page - a captive portal or a proxy is');
         LogMsg('  rewriting traffic. Log in to that portal first; the download would fetch its page.');
       end;
  end;
end;


procedure TMainForm.StepRunInstaller;
begin
  if (FInstallerPath = '') OR NOT FileExists(FInstallerPath)
  then
   begin
    LogMsg('Cannot run installer: file not found at ' + FInstallerPath);
    EXIT;
   end;

  { Pre-flight: drop any cached "revocation offline" failure before the setup's first HTTPS call. }
  try StepClearRevocationCache except on E: Exception do LogMsg('  ERROR: ' + E.Message) end;
  LogMsg('');

  { Remember which log already existed, so CheckInstallerOutcome cannot mistake an old failed
    run for this one. }
  FSetupLogBefore:= FindLatestSetupLog;

  { Do not let the user watch a 15-minute countdown for an installer we already know will die on
    its first HTTPS call. }
  if FRevocationFailed then
   begin
    LogMsg('*** WARNING: the revocation check is still failing on this PC. ***');
    LogMsg('    The installer will almost certainly stop with BLZBNTBTS00000028.');
    LogMsg('    Fix the firewall first - see the diagnosis above.');
    LogMsg('');
    if Application.MessageBox(
         'The certificate revocation check is still failing on this PC.'#13#10#13#10 +
         'The Battle.net installer will almost certainly fail with BLZBNTBTS00000028. '
         + 'Set your firewall to "Allow outgoing" first, then try again.'#13#10#13#10 +
         'Run the installer anyway?',
         'Run the installer?', MB_YESNO or MB_ICONWARNING) <> IDYES
    then
     begin
      LogMsg('  Installer NOT started (your choice). It is saved at: ' + FInstallerPath);
      EXIT;
     end;
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
  LogMsg('TIP: "BLZBNTBTS00000028 / can''t connect to the patch service" is almost always your');
  LogMsg('     FIREWALL blocking the installer''s TLS certificate-revocation check (Schannel 0x80092013).');
  LogMsg('     Battle.net now uses a Let''s Encrypt certificate with NO OCSP responder, so Windows must');
  LogMsg('     download a 161 KB CRL over plain HTTP (port 80) before the handshake can finish.');
  LogMsg('     That download is made by WINDOWS itself (lsass.exe, its TLS engine), NOT by any Blizzard');
  LogMsg('     program - which is why no Blizzard process ever shows up in your firewall log, and why');
  LogMsg('     whitelisting Battle.net-Setup.exe / Battle.net.exe / Agent.exe does NOT help.');
  LogMsg('     FIX: set the firewall to "Allow Outgoing" for a few minutes and retry - OR add a');
  LogMsg('     permanent exception for C:\Windows\System32\lsass.exe on outgoing TCP port 80 only');
  LogMsg('     (that is the process that fetches the list). A mobile hotspot / VPN also bypasses it.');
  LogMsg('     If it instead freezes at 45%, click "Kill now" to kill Agent.exe and force a retry.');
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
  Offline: Boolean;
begin
  SetUIEnabled(FALSE);
  StopCountdown;     { A countdown left over from a previous run monitors an installer this run is about to kill/replace - and its timer could fire from inside any message box shown below }
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
    try StepDeleteFolder(FolderProgramData + '\Battle.net', 'ProgramData\Battle.net') except on E: Exception do LogMsg('  ERROR: ' + E.Message) end;
    LogMsg('');
   end;

  if chkBNetComp.Checked then
   begin
    try StepDeleteFolder(FolderProgramData + '\Battle.net_components', 'ProgramData\Battle.net_components') except on E: Exception do LogMsg('  ERROR: ' + E.Message) end;
    LogMsg('');
   end;

  if chkBlizzard.Checked then
   begin
    try StepDeleteFolder(FolderProgramData + '\Blizzard Entertainment', 'ProgramData\Blizzard Entertainment') except on E: Exception do LogMsg('  ERROR: ' + E.Message) end;
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
    try StepDeleteFolder(FolderProgramFilesX86 + '\Battle.net', 'Program Files (x86)\Battle.net') except on E: Exception do LogMsg('  ERROR: ' + E.Message) end;
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

  { Diagnose the TLS revocation failure. Must run BEFORE the download - there is no point
    fetching an installer that is about to die on the very same handshake. }
  if chkDiagRevoke.Checked then
   begin
    try StepDiagnoseRevocation except on E: Exception do LogMsg('  ERROR: ' + E.Message) end;
    LogMsg('');
   end;

  if chkFixRevoke.Checked then
   begin
    try StepFixRevocation except on E: Exception do LogMsg('  ERROR: ' + E.Message) end;
    LogMsg('');
   end;

  { Download and run installer }
  if chkDownload.Checked then
   begin
    FInstallerPath:= GetEnvironmentVariable('TEMP') + '\Battle.net-Setup.exe';

    { Only the AUTOMATIC download needs a live connection. Checked here, not at startup, so the
      cleanup steps still run on an offline PC. }
    Offline:= NOT InternetIsReachable;
    if Offline then
     begin
      LogMsg('');
      if NOT FileExists(FInstallerPath) then
       begin
        LogMsg('  Skipping the download, and there is no installer on disk to fall back on.');
        SetStatus('No Internet connection - installer not downloaded.');
        LogMsg('=== Cleanup complete ===');
        SetUIEnabled(TRUE);
        EXIT;
       end;
      LogMsg('  Cannot download, but an installer is already on disk - using that one.');
     end;
    LogMsg('');

    { Skip the download when the installer on disk is still fresh - or when we cannot download at all }
    if FileExists(FInstallerPath) AND (Offline OR (DaysBetween(Now, TFile.GetLastWriteTime(FInstallerPath)) < 7))
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

  { FINALLY: the field is already detached, so this handler is now the ONLY owner of the object.
    An exception escaping the body would leak the thread (Synchronize re-raises it on the worker,
    nothing else ever frees it), so the hand-over to the message queue must be unconditional. }
  TRY
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

    LogMsg('');

    if FileExists(FInstallerPath) AND chkRunInstaller.Checked then
     begin
      try StepRunInstaller except on E: Exception do LogMsg('  ERROR: ' + E.Message) end;
      LogMsg('');
     end;

    LogMsg('=== Cleanup complete ===');
    SetStatus('Done.');
    SetUIEnabled(TRUE);
  FINALLY
    { Queued LAST, after every line that can pump messages. StepRunInstaller's warning prompt
      (Application.MessageBox) runs a modal message loop, and a modal loop dispatches the WM_NULL
      that TThread.ForceQueue posts to Application.Handle (Vcl.Forms.pas TApplication.WakeMainThread
      -> WndProc WM_NULL -> CheckSynchronize) -> this FreeAndNil would run WHILE the worker is
      still parked inside its Synchronize(DownloadDone) call. Destroy's WaitFor (main thread) then
      waits on the thread handle, the worker waits for DownloadDone to return: deadlock, frozen UI.
      Queued here, the free cannot run before DownloadDone returns; the worker leaves Synchronize
      first, so Destroy's WaitFor returns immediately. }
    TThread.ForceQueue(NIL, procedure
      begin
        FreeAndNil(Downloader);
      end);
  END;
end;




end.
