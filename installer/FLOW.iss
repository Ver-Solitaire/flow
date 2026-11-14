; FLOW - installateur Windows (Inno Setup 6). Installation PAR UTILISATEUR : aucun droit administrateur.
; Compilation : iscc /DVersion=1.5.0 installer\FLOW.iss   ->   installer\sortie\FLOW-Setup-<version>.exe
; Après la copie des fichiers, install.ps1 vérifie / installe les dépendances (winget : PowerShell 7, Git, Claude Code, psmux…),
; crée config\accounts.json et le raccourci. Les réglages de l'utilisateur (config\, profils personnels) ne sont jamais écrasés.
#ifndef Version
  #define Version "0.0.0"
#endif

[Setup]
AppId={{6F1C2B7E-3D5A-4C8E-9B21-F10A5E7D4C90}
AppName=FLOW
AppVersion={#Version}
AppPublisher=FLOW
DefaultDirName={localappdata}\Programs\FLOW
DefaultGroupName=FLOW
PrivilegesRequired=lowest
DisableProgramGroupPage=yes
OutputDir=sortie
OutputBaseFilename=FLOW-Setup-{#Version}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayName=FLOW
SetupIconFile=..\assets\flow.ico
UsePreviousAppDir=yes
CloseApplications=no

[Languages]
Name: "french"; MessagesFile: "compiler:Languages\French.isl"

[Files]
Source: "..\FLOW.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\FLOW.cmd"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\install.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\install.cmd"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\dependances.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\VERSION"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\CHANGELOG.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\tools\*"; DestDir: "{app}\tools"; Flags: ignoreversion recursesubdirs
Source: "..\app\*"; DestDir: "{app}\app"; Flags: ignoreversion recursesubdirs
Source: "..\assets\*"; DestDir: "{app}\assets"; Flags: ignoreversion recursesubdirs
Source: "..\skills\*"; DestDir: "{app}\skills"; Flags: ignoreversion recursesubdirs
Source: "..\docs\*"; DestDir: "{app}\docs"; Flags: ignoreversion recursesubdirs
; modèles : ne remplacent jamais les profils et réglages déjà modifiés par l'utilisateur
Source: "..\profiles\*"; DestDir: "{app}\profiles"; Flags: onlyifdoesntexist recursesubdirs
Source: "..\config\accounts.example.json"; DestDir: "{app}\config"; Flags: ignoreversion
Source: "..\config\psmux.conf"; DestDir: "{app}\config"; Flags: onlyifdoesntexist

[Icons]
Name: "{group}\FLOW"; Filename: "{app}\FLOW.cmd"; IconFilename: "{app}\assets\flow.ico"
Name: "{group}\Désinstaller FLOW"; Filename: "{uninstallexe}"

[Run]
; vérifie et installe ce qui manque (winget), prépare la configuration et le raccourci du bureau
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\install.ps1"" -Yes"; WorkingDir: "{app}"; StatusMsg: "Installation des outils nécessaires (PowerShell 7, Git, Claude Code…)"; Flags: waituntilterminated

[UninstallDelete]
Type: files; Name: "{app}\FLOW.exe"