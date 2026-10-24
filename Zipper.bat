@echo off
setlocal DisableDelayedExpansion
rem Zipper launcher: asks for admin rights, then starts Zipper.ps1 (GUI).
rem You can drag a folder onto this file to pre-select it.
set "ZIPPER_ARG=%~1"
set "ZIPPER_SELF=%~f0"

fltmc >nul 2>&1
if errorlevel 1 goto elevate
if not exist "%~dp0Zipper.ps1" goto noscript

start "" powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Zipper.ps1"
exit /b

:elevate
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:ZIPPER_SELF -ArgumentList ('\"' + $env:ZIPPER_ARG + '\"') -Verb RunAs"
exit /b

:noscript
echo Zipper.ps1 not found next to Zipper.bat
pause
exit /b 1
