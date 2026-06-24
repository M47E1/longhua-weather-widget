# Longhua Weather Widget v1.0.0

First portable Windows x64 release of the PowerShell WPF Longhua Weather Widget.

## Download

Use either asset:

- `LonghuaWeatherWidget-v1.0.0-win-x64.exe` for a single-file app.
- `LonghuaWeatherWidget-v1.0.0-win-x64.zip` for the EXE plus README and license.

## What Changed

- Packages the PowerShell WPF widget as a no-console x64 Windows executable with PS2EXE.
- Runs WPF in STA mode.
- Stores settings at `%LOCALAPPDATA%\LonghuaWeatherWidget\settings.json`.
- Creates safe default settings on first run.
- Keeps Open-Meteo as the primary provider and wttr.in as fallback.
- Keeps fallback to the last successful weather model when refresh fails.
- Shows weather attribution in the UI and docs.

Weather data by Open-Meteo.

## Notes

- No administrator rights are required.
- The app does not install Startup entries automatically.
- Startup scripts remain available for users who run from source and choose to install them.
- No API key is required.
- This build is unsigned. Windows SmartScreen may show an unknown publisher warning on first launch.