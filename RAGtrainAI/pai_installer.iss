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
UninstallDisplayIcon={app}\pai_app\pai_app.exe

[Files]
; App + backend (entire folders)
Source: "dist\pai_app\*"; DestDir: "{app}\pai_app"; Flags: recursesubdirs
Source: "dist\pai_backend\*"; DestDir: "{app}\pai_backend"; Flags: recursesubdirs
Source: "pai.ico"; DestDir: "{app}"

[Dirs]
; Pre-create folders for logs and Qdrant cache
Name: "{localappdata}\paiassistant\logs"
Name: "{localappdata}\paiassistant\qdrant"

[Icons]
; Desktop + Start Menu shortcuts
Name: "{userdesktop}\PAI Personal Assistant"; Filename: "{app}\pai_app\pai_app.exe"; IconFilename: "{app}\pai.ico"
Name: "{group}\PAI Personal Assistant"; Filename: "{app}\pai_app\pai_app.exe"; IconFilename: "{app}\pai.ico"

[UninstallDelete]
; Clean up cache/logs on uninstall
Type: filesandordirs; Name: "{localappdata}\paiassistant"
Type: filesandordirs; Name: "{userappdata}\PAI"
