[Setup]
AppName=PAI Assistant
AppVersion=0.1
PrivilegesRequired=lowest
DefaultDirName={userappdata}\PAI
DefaultGroupName=PAI Personal Assistant
OutputDir=output
OutputBaseFilename=PAI_Installer
Compression=lzma
SolidCompression=yes
UninstallDisplayIcon={app}\app.exe

[Files]
; Compiled app + backend
Source: "dist\*"; DestDir: "{app}"; Flags: recursesubdirs
Source: "pai.ico"; DestDir: "{app}"

[Dirs]
; Pre-create folders for logs and Qdrant cache
Name: "{localappdata}\paiassistant\logs"
Name: "{localappdata}\paiassistant\qdrant"

[Icons]
; Desktop + Start Menu shortcuts
Name: "{userdesktop}\PAI Personal Assistant"; Filename: "{app}\app.exe"; IconFilename: "{app}\pai.ico"
Name: "{group}\PAI Personal Assistant"; Filename: "{app}\app.exe"; IconFilename: "{app}\pai.ico"

[UninstallDelete]
; Clean up cache/logs on uninstall
Type: filesandordirs; Name: "{localappdata}\paiassistant"
Type: filesandordirs; Name: "{userappdata}\PAI"
