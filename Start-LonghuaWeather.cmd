@echo off
set "SCRIPT_DIR=%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Sta -File "%SCRIPT_DIR%LonghuaWeatherWidget.ps1"
