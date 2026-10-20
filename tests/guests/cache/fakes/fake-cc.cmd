@echo off
rem Fake compiler for the P13 tests (no real toolchain): -o OUT gets "OBJ" plus the input file; "#error" in the input
rem fails with exit 1 and no output; --version prints a banner. Pure batch, so no PowerShell starts per compile.
setlocal EnableExtensions DisableDelayedExpansion
set "out="
set "in="
:next
if "%~1"=="" goto run
if "%~1"=="--version" (echo fake-cc version 18.1.3& exit /b 0)
if "%~1"=="-o" (set "out=%~2"& shift& shift& goto next)
if exist "%~1" set "in=%~1"
shift
goto next
:run
if not defined in (echo fake-cc: no input 1>&2& exit /b 2)
findstr /c:"#error" "%in%" >nul 2>&1 && (echo fake-cc: error: deliberate 1>&2& exit /b 1)
if not defined out exit /b 0
>"%out%" echo OBJ
type "%in%" >>"%out%"
exit /b 0
