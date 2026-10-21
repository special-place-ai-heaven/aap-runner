@echo off
rem Fake compiler for the P13 tests (no real toolchain): -o OUT gets "OBJ" plus the input file; with -MD or -MMD the
rem depfile (-MF, or OUT with its extension replaced by .d) gets "DEP" plus the input's name; "#error" in the input
rem fails with exit 1 and no output; --version prints a banner. Pure batch, so no PowerShell starts per compile.
rem FAKE_CC_STDERR=TEXT prints TEXT to stderr. Run by zccache (ZCCACHE_CACHE_DIR set), FAKE_CC_OMIT=obj or dep leaves
rem out that output while still exiting 0: a cache that reports success without delivering it.
setlocal EnableExtensions DisableDelayedExpansion
set "out="
set "in="
set "mf="
set "md="
:next
if "%~1"=="" goto run
if "%~1"=="--version" (echo fake-cc version 18.1.3& exit /b 0)
if "%~1"=="-o" (set "out=%~2"& shift& shift& goto next)
if "%~1"=="-MF" (set "mf=%~2"& shift& shift& goto next)
if "%~1"=="-MD" set "md=1"
if "%~1"=="-MMD" set "md=1"
if exist "%~1" set "in=%~1"
shift
goto next
:run
if not defined in (echo fake-cc: no input 1>&2& exit /b 2)
findstr /c:"#error" "%in%" >nul 2>&1 && (echo fake-cc: error: deliberate 1>&2& exit /b 1)
if defined FAKE_CC_STDERR (echo %FAKE_CC_STDERR%) 1>&2
set "omit="
if defined ZCCACHE_CACHE_DIR set "omit=%FAKE_CC_OMIT%"
if not defined out exit /b 0
if not "%omit%"=="obj" (
  >"%out%" echo OBJ
  type "%in%" >>"%out%"
)
if not defined md exit /b 0
if "%omit%"=="dep" exit /b 0
if not defined mf for %%F in ("%out%") do set "mf=%%~dpnF.d"
for %%F in ("%in%") do >"%mf%" echo DEP %%~nxF
exit /b 0
