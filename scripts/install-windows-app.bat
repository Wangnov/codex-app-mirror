@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
set "CONFIG=%SCRIPT_DIR%install-windows-app.config.json"

if not "%~1"=="" (
  set "FIRST_ARG=%~1"
  if not "!FIRST_ARG:~0,1!"=="-" (
    set "CONFIG=%~1"
    shift
  )
)

if not exist "%CONFIG%" (
  set "CONFIG=%SCRIPT_DIR%install-windows-app.config.example.json"
)

where py >nul 2>nul
if %ERRORLEVEL%==0 (
  py -3 "%SCRIPT_DIR%install-windows-app.py" --config "%CONFIG%" %*
) else (
  python "%SCRIPT_DIR%install-windows-app.py" --config "%CONFIG%" %*
)

exit /b %ERRORLEVEL%
