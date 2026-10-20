[Setup]
AppName=AAP Parity Fixture
AppVersion=1.0.0
AppPublisher=aap-runner
DefaultDirName={autopf}\AapParity
OutputDir=.
OutputBaseFilename=parity-setup
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=lowest
ArchitecturesInstallIn64BitMode=x64compatible

[Files]
Source: "payload.txt"; DestDir: "{app}"
