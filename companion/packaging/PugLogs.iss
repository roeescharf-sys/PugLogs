; Windows installer for the PugLogs app (Inno Setup 6). Built by .github/workflows/release.yml:
;   iscc /DAppVersion=0.7.0 /DSourceDir=..\dist\PugLogs /DOutputDir=..\dist packaging\PugLogs.iss
; Installs for the current user only (no administrator rights needed).

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\dist\PugLogs"
#endif
#ifndef OutputDir
  #define OutputDir "..\dist"
#endif

[Setup]
AppId={{6F0C7E2A-3B1D-4C5E-9A8F-2D4B6C8E1F30}
AppName=PugLogs
AppVersion={#AppVersion}
AppVerName=PugLogs {#AppVersion}
AppPublisher=Roee
AppPublisherURL=https://github.com/roeescharf-sys/PugLogs
AppSupportURL=https://github.com/roeescharf-sys/PugLogs/issues
AppUpdatesURL=https://github.com/roeescharf-sys/PugLogs/releases/latest
DefaultDirName={localappdata}\Programs\PugLogs
DefaultGroupName=PugLogs
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=lowest
OutputDir={#OutputDir}
OutputBaseFilename=PugLogs-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=PugLogs
UninstallDisplayIcon={app}\PugLogs.exe
; Close a running PugLogs before updating it.
CloseApplications=force
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"
Name: "startup"; Description: "Start PugLogs when Windows starts"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\PugLogs"; Filename: "{app}\PugLogs.exe"
Name: "{userdesktop}\PugLogs"; Filename: "{app}\PugLogs.exe"; Tasks: desktopicon
Name: "{userstartup}\PugLogs"; Filename: "{app}\PugLogs.exe"; Tasks: startup

[Run]
Filename: "{app}\PugLogs.exe"; Description: "Start PugLogs now"; Flags: nowait postinstall skipifsilent
