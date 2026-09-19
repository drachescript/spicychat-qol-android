@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0release_android.ps1"
if errorlevel 1 (
  echo.
  echo Release preparation failed.
)
pause
