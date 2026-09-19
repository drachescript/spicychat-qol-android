@echo off
setlocal
title SpicyChat QOL Android - Full Sync + Build
echo.
echo SpicyChat QOL Android
echo FULL extension sync + Android APK build
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_android.ps1"
set "BUILD_EXIT=%ERRORLEVEL%"
if not "%BUILD_EXIT%"=="0" (
  echo.
  echo Build failed.
)
if not defined DS_NO_PAUSE pause
endlocal & exit /b %BUILD_EXIT%
