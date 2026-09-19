@echo off
setlocal
title SpicyChat QOL Android - Reset Version
echo.
echo This resets the visible Android APK version sequence.
echo Old generated APKs will be moved into archive\ instead of deleted.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0reset_android_version.ps1"
if errorlevel 1 (
  echo.
  echo Version reset failed.
)
pause
