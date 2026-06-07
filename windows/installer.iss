; Inno Setup script для Brandmen Control (Windows).
; Версия передаётся из CI: ISCC.exe /DAppVersion=0.70.0 installer.iss
; Ставим в %LOCALAPPDATA% с правами обычного пользователя — тогда и установка
; в один клик без админа, и встроенное автообновление (xcopy в папку приложения)
; продолжает работать без повышения прав.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#define MyAppName "Brandmen Control"
#define MyAppExeName "brandmen_windows.exe"

[Setup]
AppName={#MyAppName}
AppVersion={#AppVersion}
AppPublisher=Brandmen
DefaultDirName={localappdata}\BrandmenControl
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=.
OutputBaseFilename=BrandmenControl-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "Создать ярлык на рабочем столе"; GroupDescription: "Дополнительно:"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{userdesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Запустить {#MyAppName}"; Flags: nowait postinstall skipifsilent
