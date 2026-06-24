# Release Checklist v1.0.0

Use this checklist before uploading GitHub Release assets. This round does not create the release, push, or sign binaries.

## Build Inputs

- [ ] Confirm `LonghuaWeatherWidget.ps1` runs on Windows PowerShell 5.1.
- [ ] Confirm WPF launches in STA mode.
- [ ] Confirm no API keys, tokens, exact home addresses, or private paths exist in source or examples.
- [ ] Confirm Open-Meteo remains the primary provider and wttr.in remains fallback.
- [ ] Confirm recent successful weather data is reused after refresh failure.

## Commands

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-LonghuaWeatherWidget.ps1
Invoke-Pester -Script .\LonghuaWeatherWidget.Tests.ps1 -EnableExit
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build-release.ps1
```

## Assets

- [ ] `dist/LonghuaWeatherWidget-v1.0.0-win-x64.exe`
- [ ] `dist/LonghuaWeatherWidget-v1.0.0-win-x64.zip`
- [ ] `dist/SHA256SUMS.txt`

ZIP contents must be exactly:

- [ ] `LonghuaWeatherWidget.exe`
- [ ] `README.txt`
- [ ] `LICENSE`

## Local Smoke Test

- [ ] Launch the EXE directly.
- [ ] Confirm no PowerShell console window appears.
- [ ] Confirm no external settings file is needed.
- [ ] Confirm settings write to `%LOCALAPPDATA%\LonghuaWeatherWidget\settings.json`.
- [ ] Confirm the app exits without a leftover process.
- [ ] Confirm EXE product name is `Longhua Weather Widget`.
- [ ] Confirm EXE version is `1.0.0.0`.
- [ ] Confirm the EXE does not depend on files in the project directory.

## GitHub Release Notes

- [ ] Mention the build is unsigned.
- [ ] Mention Windows SmartScreen may warn about an unknown publisher.
- [ ] Mention no administrator rights are required.
- [ ] Mention Startup installation is optional.
- [ ] Include `Weather data by Open-Meteo.`