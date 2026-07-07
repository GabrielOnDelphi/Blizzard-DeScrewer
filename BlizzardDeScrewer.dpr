program BlizzardDeScrewer;

uses
  {$IFDEF DEBUG}FastMM4,{$ENDIF}
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
     AppName= 'Blizzerd De-Screwer';       // Absolutelly critical if you use the SaveForm/LoadForm functionality. This string will be used as the name of the INI file.

  AppData:= TAppData.Create(AppName, '', MultiThreaded);
  AppData.CreateMainForm(TMainForm, MainForm, FALSE, TRUE, asFull);

  // Warning: Don't call TrySetStyle until the main form is visible.
  TStyleManager.TrySetStyle('Amakrits');
  AppData.Run;
end.
