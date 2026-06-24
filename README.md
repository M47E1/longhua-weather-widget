# Longhua Weather Widget

A lightweight Windows PowerShell WPF weather widget for Shenzhen and Longhua. It runs as a local desktop widget and uses Open-Meteo as the primary weather provider with wttr.in as fallback.

This is not a web app. It does not use Node.js, Cloudflare, WebView2, or a weather API key.

简短说明：这是一个 Windows 桌面天气小组件，默认面向深圳龙华。

## Download

Download the latest Windows build from GitHub Releases:

https://github.com/M47E1/longhua-weather-widget/releases

Available release assets:

- Windows x64 executable
- Portable ZIP package
- SHA-256 checksum file

Download `LonghuaWeatherWidget-v1.0.0-win-x64.zip`, extract it, and run `LonghuaWeatherWidget.exe`. You can also download the standalone `LonghuaWeatherWidget-v1.0.0-win-x64.exe` asset and run it directly.

The ZIP contains only:

- `LonghuaWeatherWidget.exe`
- `README.txt`
- `LICENSE`

No administrator rights are required. The app does not install Startup entries by itself.

The executable is currently unsigned. Windows SmartScreen may show an
"Unknown publisher" warning. Do not disable Windows security protections.

## Features

- Current weather for supported Chinese city and district locations.
- Hourly and daily forecast data from Open-Meteo.
- wttr.in fallback when the primary request fails.
- Reuses the last successful weather model when a refresh fails.
- Chinese and English UI labels.
- Refresh choices for 1 minute, 1 hour, and 1 day.
- Optional current-user Startup shortcut when running from source.
- Compact WPF UI with built-in vector weather icons.

## Requirements

For the release EXE:

- Windows x64.
- Windows PowerShell 5.1 and .NET Framework/WPF components available on the system.
- Network access to the weather providers.

For source development:

- Windows PowerShell 5.1.
- Pester is optional and only needed for `LonghuaWeatherWidget.Tests.ps1`.
- PS2EXE is fetched or reused by `build-release.ps1` as a build dependency. End users do not need PS2EXE.

PowerShell 7 native support is not claimed for this release.

## Run From Source

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Sta -File .\LonghuaWeatherWidget.ps1
```

Or use the optional launcher:

```cmd
Start-LonghuaWeather.cmd
```

## Settings

The widget creates safe defaults on first run. Users do not need to create a settings file.

Runtime settings are stored at:

```text
%LOCALAPPDATA%\LonghuaWeatherWidget\settings.json
```

The app does not force configuration writes next to the EXE or source script.

`LonghuaWeatherWidget.settings.example.json` is only a safe source-control example. Do not store API keys, tokens, exact home addresses, or private paths in settings.

## Startup Installation

Startup is optional and only runs when you choose to install it from a source checkout.

Create a Startup shortcut for the current Windows user:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-LonghuaWeatherStartup.ps1
```

You can set a supported refresh interval:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-LonghuaWeatherStartup.ps1 -RefreshSeconds 3600
```

Supported values are `60`, `3600`, and `86400`.

Remove the Startup shortcut:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-LonghuaWeatherStartup.ps1
```

## Build Release Assets

Run from the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build-release.ps1
```

The build writes:

- `dist/LonghuaWeatherWidget-v1.0.0-win-x64.exe`
- `dist/LonghuaWeatherWidget-v1.0.0-win-x64.zip`
- `dist/SHA256SUMS.txt`

PS2EXE build flags include `NoConsole`, `STA`, `DPIAware`, `SupportOS`, `x64`, and file metadata. The build does not use `RequireAdmin`.

## Testing

Run the lightweight tests:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-LonghuaWeatherWidget.ps1
```

Run Pester tests if Pester is installed:

```powershell
Invoke-Pester -Script .\LonghuaWeatherWidget.Tests.ps1 -EnableExit
```

## Weather Providers

Primary provider: Open-Meteo Forecast API.

Fallback provider: wttr.in JSON endpoint.

The current implementation does not require an API key. Third-party services remain subject to their own availability and terms.

Weather data by Open-Meteo.

## Forecast Range

The current request asks Open-Meteo for:

- `forecast_hours=336`
- `forecast_days=14`

The UI can show current weather, quick forecast slots, and selected day/hour forecast entries from the fetched data.

## Privacy

The widget does not collect accounts, upload local settings to a server, include analytics, or use telemetry. Local settings can store city or district preferences. Do not commit your actual `settings.json`.

PS2EXE-generated files can allow extraction of the original script. Do not put credentials, tokens, private addresses, or private file paths in source, settings examples, or release assets.

## Known Limitations

- Windows-only desktop widget.
- Requires network access for fresh weather data.
- Weather can become stale when third-party providers fail.
- Optional Startup installation uses the current user's Startup folder.
- No background service, cloud sync, hosted backend, code signing certificate, or SmartScreen reputation in this round.

## License

MIT License. See `LICENSE`.