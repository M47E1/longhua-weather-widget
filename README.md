# Longhua Weather Widget

Longhua Weather Widget v1.1.0 - Anthropic-inspired Edition is a compact Windows PowerShell WPF weather widget for supported Chinese city and district locations. The default location is Shenzhen Longhua.

This is the 基础版本: a WPF-only desktop widget without WebView2, Node.js, Cloudflare, API keys, telemetry, or tracking.

## Download

Download the latest Windows build from GitHub Releases:

https://github.com/M47E1/longhua-weather-widget/releases

v1.1.0 assets:

- `LonghuaWeatherWidget-v1.1.0-anthropic-win-x64.exe`
- `LonghuaWeatherWidget-v1.1.0-anthropic-win-x64.zip`
- `SHA256SUMS.txt`

The ZIP contains only `LICENSE`, `LonghuaWeatherWidget.exe`, and `README.txt`.

No administrator rights are required. The executable is unsigned, so Windows SmartScreen may show an unknown publisher warning on first launch.

## Edition

The v1.1.0 UI uses an Anthropic-inspired style: paper-toned surfaces, restrained borders, compact typography, and warm accent colors. It does not use Anthropic or Claude logos, brand assets, or official product claims.

## Features

- Current weather and forecast views are visually and textually distinct: `Now` for current data, `Forecast · HH:mm` for forecast data.
- Open-Meteo is the primary weather provider; wttr.in remains the fallback.
- Cached weather stays usable when refresh fails.
- Chinese and English UI labels.
- 47 supported real regions in the current catalog.
- Compact drawer UI with settings, language, refresh interval, and forecast slot controls.

## Run From Source

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Sta -File .\LonghuaWeatherWidget.ps1
```

Or use:

```cmd
Start-LonghuaWeather.cmd
```

## Settings

Runtime settings are stored in `LonghuaWeatherWidget.settings.json` next to the launched script or EXE. UI smoke runs isolate settings under their output directory.

Do not commit real local settings, private paths, tokens, or exact home addresses.

## Build Release Assets

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build-release.ps1
```

The build writes:

- `dist/LonghuaWeatherWidget-v1.1.0-anthropic-win-x64.exe`
- `dist/LonghuaWeatherWidget-v1.1.0-anthropic-win-x64.zip`
- `dist/SHA256SUMS.txt`

PS2EXE flags include `NoConsole`, `STA`, `DPIAware`, `SupportOS`, and `x64`. The build does not use `RequireAdmin`.

## Testing

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Run-ProjectTests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\LonghuaWeatherWidget.ps1 -TestMode
```

Additional release gates include English no-CJK, UI region render smoke, real UI interaction smoke, and release asset verification.

## Weather Providers

Primary provider: Open-Meteo Forecast API.

Fallback provider: wttr.in JSON endpoint.

No API key is required. Third-party services remain subject to their own availability and terms.

## License

MIT License. See `LICENSE`.