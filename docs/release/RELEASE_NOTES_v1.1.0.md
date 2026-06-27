# Longhua Weather Widget v1.1.0 - Anthropic-inspired Edition

Release title: Longhua Weather Widget v1.1.0 – Anthropic-inspired Edition

## What Changed

- Adds an Anthropic-inspired UI theme with paper-toned surfaces, restrained borders, dark neutral text, and warm accent controls.
- Keeps the 基础版本 WPF-only architecture. No WebView2 renderer code was added.
- Preserves the current weather and forecast distinction: current data is labeled `Now`; forecast data is labeled `Forecast · HH:mm`.
- Preserves Open-Meteo request logic, supported region catalog, cache behavior, rainstorm risk semantics, close behavior, and drawer positioning logic.
- Builds v1.1.0 assets with `anthropic-win-x64` names and a portable ZIP containing only `LICENSE`, `LonghuaWeatherWidget.exe`, and `README.txt`.

## Validation

- Source RC hash preflight passed for `LonghuaWeatherWidget.ps1`, `Test-LonghuaWeatherWidget.ps1`, `Run-ProjectTests.ps1`, and `AGENTS.md`.
- Project tests and `-TestMode` must pass before release publication.
- Full AllSupportedRegions evidence remains the final RC evidence index at `C:\Users\25800\Documents\今天深圳下雨了么\reports\final-evidence\english-ui-gate-20260627-125712\final-evidence-index.json`.
- The UI-only v1.1.0 branch does not rerun the full 47-region live data gate because the data layer was not changed.

## Notes

This edition is not affiliated with, endorsed by, or using brand assets from Anthropic or Claude. The wording “Anthropic-inspired” describes a general visual direction only.

The executable is unsigned. Windows SmartScreen may show an unknown publisher warning on first launch.