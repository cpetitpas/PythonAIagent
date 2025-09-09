[Setup]
AppName=PAI Assistant
AppVersion=0.1
DefaultDirName={autopf}\PAI
DefaultGroupName=PAI Personal Assistant
OutputDir=output
OutputBaseFilename=PAIInstaller
Compression=lzma
SolidCompression=yes

[Files]
Source: "dist\*"; DestDir: "{app}"; Flags: recursesubdirs

[Icons]
Name: "{commondesktop}\PAI Personal Assistant"; Filename: "{app}\app.exe"
Name: "{group}\PAI Personal Assistant"; Filename: "{app}\app.exe"
