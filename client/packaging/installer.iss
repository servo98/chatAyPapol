; Inno Setup — instalador de ChatPapol para Windows
; Compilar: iscc packaging\installer.iss (tras flutter build windows --release)
; la CI lo sobreescribe con /DAppVersion=x.y.z
#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif

[Setup]
AppId={{8C1F4A2E-9B7D-4E5A-A1C3-CHATPAPOL01}
AppName=ChatPapol
AppVersion={#AppVersion}
AppPublisher=Papol
DefaultDirName={autopf}\ChatPapol
DefaultGroupName=ChatPapol
OutputDir=out
OutputBaseFilename=chatpapol-setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
PrivilegesRequired=lowest
CloseApplications=yes
; ícono de marca ❯ para el Setup.exe y para Agregar/Quitar programas
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\chatpapol.exe
; silencioso desde el auto-updater: /SILENT /CLOSEAPPLICATIONS

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs

[Icons]
Name: "{group}\ChatPapol"; Filename: "{app}\chatpapol.exe"
Name: "{autodesktop}\ChatPapol"; Filename: "{app}\chatpapol.exe"

[Run]
Filename: "{app}\chatpapol.exe"; Description: "Abrir ChatPapol"; Flags: nowait postinstall skipifsilent
