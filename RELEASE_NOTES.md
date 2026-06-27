# Paper Weather Widget Release Notes

Project rename: Paper Weather Widget / 纸感天气小组件.

Earlier builds used the Longhua Weather Widget name. v1.1.0 downloadable files may still use the previous `LonghuaWeatherWidget` filename for historical compatibility. Future releases should use `PaperWeatherWidget` asset names.

This project uses an Anthropic-inspired visual style only. It is not an Anthropic or Claude product, does not use Anthropic or Claude logos, and does not claim official affiliation.

## v1.1.0 Historical Release

Release title:

Longhua Weather Widget v1.1.0 - Anthropic-inspired Edition

Historical assets:

- `LonghuaWeatherWidget-v1.1.0-anthropic-win-x64.exe`
- `LonghuaWeatherWidget-v1.1.0-anthropic-win-x64.zip`
- `SHA256SUMS.txt`

Do not rebuild v1.1.0. Do not rewrite the v1.1.0 tag. Do not change the v1.1.0 assets.

## Next Release: v1.2.0

Planned release title:

Paper Weather Widget v1.2.0 — Anthropic-inspired Edition

Planned assets:

- `PaperWeatherWidget-v1.2.0-win-x64.exe`
- `PaperWeatherWidget-v1.2.0-win-x64.zip`
- `SHA256SUMS.txt`

Planned ZIP contents:

- `LICENSE`
- `PaperWeatherWidget.exe`
- `README.txt`

## Data Source Notes

- Current weather data comes from Open-Meteo model current weather.
- Open-Meteo data is not official on-site observation.
- The base edition does not integrate an official weather warning API.
- Model-derived content is a risk tip, not an official warning.
- Only official `WarningText` should be treated as an official warning.
- The built-in region catalog currently contains 47 real supported regions.

## Validation Notes

- `RealUiInteractionSmoke` remains FAIL because of WPF UI Automation popup and AutomationId limitations.
- Do not record `RealUiInteractionSmoke` as PASS.
- Docs-only and GitHub metadata changes should not rerun weather smoke tests.
