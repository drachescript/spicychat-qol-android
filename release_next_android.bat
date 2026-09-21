@echo off
setlocal EnableExtensions
title SpicyChat QOL Android - Prepare Next Version

echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0release_next_android.ps1"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%EXIT_CODE%"=="0" (
  echo Version preparation failed. Exit code: %EXIT_CODE%
  echo.
)

pause
endlocal & exit /b %EXIT_CODE%
