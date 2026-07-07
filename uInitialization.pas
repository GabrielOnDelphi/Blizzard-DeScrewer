UNIT uInitialization;

{=============================================================================================================
   Blizzard DeScrewer
   2026.03
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   Late initialization for the Blizzard DeScrewer utility.
=============================================================================================================}

INTERFACE

procedure LateInitialization;

IMPLEMENTATION

USES
  WinApi.Windows, System.SysUtils, Vcl.Forms,
  LightCore.AppData, LightVcl.Visual.AppData,
  LightVcl.Common.SystemPermissions,
  LightVcl.Common.ExecuteShell,
  FormMain;


procedure LateInitialization;
begin
  { Brand }
  AppData.CompanyName:= 'BuyTime Ltd';
  AppData.ProductHome:= 'https://GabrielMoraru.com';

  { Re-launch elevated if not admin }
  if NOT AppHasAdminRights then
   begin
    if ExecuteAsAdmin(Application.ExeName)
    then Application.Terminate     { Elevated instance started, close this one }
    else Vcl.Forms.Application.MessageBox(
      'This application needs administrator rights to delete registry keys and system folders.'#13#10 +
      'Some operations may fail without elevation.',
      'Warning', MB_OK or MB_ICONWARNING);
   end;
end;



end.
