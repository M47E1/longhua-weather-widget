# Paper Weather Widget - Anthropic-inspired Edition

纸感天气小组件是一款 Anthropic-inspired 风格的轻量 Windows 天气小组件，支持当前天气、临近预报、模型风险提示、中文 / English 双语界面、地区切换、侧边抽屉和本地设置保存。

Paper Weather Widget is a lightweight Anthropic-inspired Windows weather widget with current weather, near-term forecast, model risk tips, bilingual UI, region switching, a side-drawer window, and local settings.

This is the 基础版本: a WPF-only desktop widget without WebView2, Node.js, Cloudflare, API keys, telemetry, or tracking. It uses an Anthropic-inspired visual style only. It is not an Anthropic or Claude product and does not use Anthropic or Claude logos.

## Download

Download v1.3.0 from GitHub Releases:

https://github.com/M47E1/paper-weather-widget/releases/tag/v1.3.0

Recommended assets:

- `PaperWeatherWidget-v1.3.0-win-x64.exe`
- `PaperWeatherWidget-v1.3.0-win-x64.zip`
- `SHA256SUMS.txt`

The ZIP contains only `LICENSE`, `PaperWeatherWidget.exe`, and `README.txt`.

No administrator rights are required.

Earlier v1.1.0 builds used the Longhua Weather Widget name. Those files remain historical artifacts only.

## Edition

The v1.3.0 UI uses an Anthropic-inspired style: paper-toned surfaces, restrained borders, compact typography, side-drawer mode, and warm accent controls. The project does not claim affiliation with Anthropic or Claude.

## Features

- Current weather and forecast views are visually and textually distinct: `Now` for current data, `Forecast · HH:mm` for forecast data.
- Open-Meteo is the primary weather provider; wttr.in remains the fallback.
- Cached weather stays usable when refresh fails.
- Model-derived risk tips are separated from official weather warnings.
- Chinese and English UI labels.
- 51 real supported regions in the current built-in catalog.
- Side-drawer window with settings, language, refresh interval, and forecast slot controls.
- Local settings are saved next to the launched script or EXE.

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
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build-release.ps1 -Version 1.3.0
```

The build writes:

- `dist/PaperWeatherWidget-v1.3.0-win-x64.exe`
- `dist/PaperWeatherWidget-v1.3.0-win-x64.zip`
- `dist/SHA256SUMS.txt`

The portable ZIP contains `PaperWeatherWidget.exe` plus `LICENSE` and `README.txt`.

PS2EXE flags include `NoConsole`, `STA`, `DPIAware`, `SupportOS`, and `x64`. The build does not use `RequireAdmin`.

## Testing

Use the verification scope that matches the change. Docs and GitHub metadata changes should use diff, text, and GitHub metadata checks, not weather smoke tests.

Release evidence for v1.3.0 must come from current targeted verification. Older RC smoke reports are historical evidence only and are not final proof for this release.

## Known Limitations

- The EXE is unsigned. Windows SmartScreen may show an Unknown publisher warning.
- Open-Meteo provides model current weather, not official on-site observation.
- The base edition does not integrate an official weather warning API.
- Model-derived content is a risk tip, not an official warning.
- The built-in region catalog contains 51 real supported regions.
- `RealUiInteractionSmoke` remains FAIL because of WPF UI Automation popup and AutomationId limitations.
- Anthropic-inspired only: this is not an official Anthropic or Claude product.

## Weather Providers

Primary provider: Open-Meteo Forecast API.

Fallback provider: wttr.in JSON endpoint.

No API key is required. Third-party services remain subject to their own availability and terms.

## License

MIT License. See `LICENSE`.