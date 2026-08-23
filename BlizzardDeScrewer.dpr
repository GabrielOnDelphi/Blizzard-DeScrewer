program BlizzardDeScrewer;

uses
  {$IFDEF DEBUG}FastMM4,{$ENDIF}
  { Test-only automation bridge. AUTOPILOT is NEVER defined in the .dproj - this tool ships its
    Debug build, and a shipped EXE that runs as administrator must not also listen on a pipe.
    Compile with --define=AUTOPILOT only while driving the GUI from a test session. }
  {$IFDEF AUTOPILOT}Autopilot.Bridge.Vcl,{$ENDIF}
  Vcl.Themes,
  Vcl.Styles,
  Vcl.Forms,
  FormMain in 'FormMain.pas' {MainForm},
  uInitialization in 'uInitialization.pas',
  LightVcl.Visual.AppData in 'c:\Projects\LightSaber\FrameVCL\LightVcl.Visual.AppData.pas',
  LightCore.AppData in 'c:\Projects\LightSaber\LightCore.AppData.pas',
  FormTranslSelector in 'c:\Projects\LightSaber\FrameVCL\AutoTranslator\FormTranslSelector.pas',
  FormTranslEditor in 'c:\Projects\LightSaber\FrameVCL\AutoTranslator\FormTranslEditor.pas',
  LightVcl.TranslatorAPI in 'c:\Projects\LightSaber\FrameVCL\AutoTranslator\LightVcl.TranslatorAPI.pas';

{$R *.res}

begin
  Application.Initialize;                  // Required by IDE, otherwise the Appearance and Orientation pages do not appear in Project Options.

  CONST
     MultiThreaded= FALSE;                 // True => Only if we need to use multithreading in the Log.
  CONST
     AppName= 'Blizzard DeScrewer';        // Absolutelly critical if you use the SaveForm/LoadForm functionality. This string will be used as the name of the INI file.

  AppData:= TAppData.Create(AppName, '', MultiThreaded);
  Application.MainFormOnTaskbar:= FALSE;   { Explicit: this app must NOT own a taskbar button }
  AppData.CreateMainForm(TMainForm, MainForm, asFull);
  {$IFDEF AUTOPILOT}StartBridge;{$ENDIF}

  // Warning: Don't call TrySetStyle until the main form is visible.
  TStyleManager.TrySetStyle('Amakrits');
  AppData.Run;
end.
