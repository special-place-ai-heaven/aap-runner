@echo off
rem Installed as the zccache member of the synthetic test archive; the model lives in fake-zccache.ps1.
rem A PowerShell 7 caller leaves its module path behind; Windows PowerShell must rebuild its own.
set "PSModulePath="
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0fake-zccache.ps1" %*
exit /b %ERRORLEVEL%
