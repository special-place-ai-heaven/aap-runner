@echo off
rem Installed as the zccache member of the synthetic test archive; the model lives in fake-zccache.ps1.
rem A PowerShell 7 caller leaves its module path behind; Windows PowerShell must rebuild its own.
rem Recording arguments needs PowerShell 7: Windows PowerShell 5.1 -File refuses a bare - before the script runs.
rem A symbolic link (FAKE_ZC_LINK) needs it too: only 7 makes one without elevation in developer mode.
set "PSModulePath="
if defined FAKE_ZC_LINK set FAKE_ZC_PWSH=1
if defined FAKE_ZC_ARGV_LOG set FAKE_ZC_PWSH=1
if defined FAKE_ZC_PWSH (
  "%ProgramFiles%\PowerShell\7\pwsh.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0fake-zccache.ps1" %*
  exit /b %ERRORLEVEL%
)
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0fake-zccache.ps1" %*
exit /b %ERRORLEVEL%
