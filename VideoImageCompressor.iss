; Inno Setup script - Video and Image Compressor
; Put this file in the SAME folder as: VideoImageCompressor.ps1, ffmpeg.exe, ffprobe.exe, VideoImageCompressor.ico, Agreement.txt,
;   LICENSE (this project's MIT license), LICENSE-FFmpeg.txt (FFmpeg's GPLv3 text), THIRD-PARTY-NOTICES.txt
; ...plus an "imagemagick" subfolder holding: magick.exe, all the .xml files, sRGB.icc, LICENSE.txt, NOTICE.txt
; ...and a "caesium" subfolder holding: caesiumclt.exe (v1.5.0 or newer), LICENSE.md, README.md
; Open it in Inno Setup and press F9 (Build > Compile). Output: VideoImageCompressorSetup.exe

[Setup]
AppId={{8F3A6B1E-2C4D-4E7A-9B15-6D0C7A3F2E91}
AppName=Video and Image Compressor
AppVersion=2.2.0
AppPublisher=Whitepumpkin24
DefaultDirName={autopf}\Video and Image Compressor
DefaultGroupName=Video and Image Compressor
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=.
OutputBaseFilename=VideoImageCompressorSetup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
LicenseFile=Agreement.txt
UninstallDisplayName=Video and Image Compressor
SetupIconFile=VideoImageCompressor.ico
UninstallDisplayIcon={app}\VideoImageCompressor.ico

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Shortcuts:"

[Files]
Source: "VideoImageCompressor.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "ffmpeg.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "ffprobe.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "LICENSE-FFmpeg.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "THIRD-PARTY-NOTICES.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "VideoImageCompressor.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "imagemagick\magick.exe"; DestDir: "{app}\imagemagick"; Flags: ignoreversion
Source: "imagemagick\*.xml"; DestDir: "{app}\imagemagick"; Flags: ignoreversion
Source: "imagemagick\*.icc"; DestDir: "{app}\imagemagick"; Flags: ignoreversion
Source: "imagemagick\LICENSE.txt"; DestDir: "{app}\imagemagick"; Flags: ignoreversion
Source: "imagemagick\NOTICE.txt"; DestDir: "{app}\imagemagick"; Flags: ignoreversion
Source: "caesium\caesiumclt.exe"; DestDir: "{app}\caesium"; Flags: ignoreversion
Source: "caesium\LICENSE.md"; DestDir: "{app}\caesium"; Flags: ignoreversion
Source: "caesium\README.md"; DestDir: "{app}\caesium"; Flags: ignoreversion

[InstallDelete]
; the app was renamed, so remove the shortcuts left by the old "Video Compressor" install
Type: files; Name: "{autoprograms}\Video Compressor.lnk"
Type: files; Name: "{autodesktop}\Video Compressor.lnk"

[Icons]
; Use the same headless console host as the development BAT launcher.
Name: "{autoprograms}\Video and Image Compressor"; Filename: "{sys}\conhost.exe"; Parameters: "--headless ""{sys}\WindowsPowerShell\v1.0\powershell.exe"" -NoProfile -ExecutionPolicy Bypass -File ""{app}\VideoImageCompressor.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\VideoImageCompressor.ico"
Name: "{autodesktop}\Video and Image Compressor"; Filename: "{sys}\conhost.exe"; Parameters: "--headless ""{sys}\WindowsPowerShell\v1.0\powershell.exe"" -NoProfile -ExecutionPolicy Bypass -File ""{app}\VideoImageCompressor.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\VideoImageCompressor.ico"; Tasks: desktopicon

[UninstallDelete]
Type: filesandordirs; Name: "{localappdata}\VideoImageCompressor"
; the folder the previous (video-only) version used for its error log
Type: filesandordirs; Name: "{localappdata}\VideoCompressor"
