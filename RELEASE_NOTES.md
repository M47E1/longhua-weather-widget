# Paper Weather Widget v1.3.0 - Anthropic-inspired Edition

Release title: Paper Weather Widget v1.3.0 - Anthropic-inspired Edition

## What Changed

- Keeps the Anthropic-inspired UI theme with paper-toned surfaces, restrained borders, dark neutral text, and warm accent controls.
- Adds async weather refresh so network calls no longer block the UI thread.
- Keeps window position stable when opening settings, changing selectors, refreshing, and toggling the side drawer.
- Removes the visible side-drawer handle border and keeps X as direct app close.
- Lazily initializes heavier visual layers and settings dropdown contents to improve startup.
- Adds Zhongshan and an approximate Envicool Shenzhen HQ node to the built-in region catalog.
- Renames the project and release assets to Paper Weather Widget / PaperWeatherWidget.
- Keeps the base WPF-only architecture. No WebView2 renderer code was added.
- Preserves the current weather and forecast distinction: current data is labeled Now; forecast data is labeled Forecast HH:mm.
- Preserves Open-Meteo primary provider behavior, wttr.in fallback, cache behavior, and model risk semantics.

## Validation

- Run-ProjectTests: 221/221 PASS.
- LonghuaWeatherWidget.ps1 -TestMode: PASS.
- Test-LocationCatalogAudit: PASS, 51 audited regions, 0 invalid coordinates, 0 0,0 coordinates, 0 swapped coordinates, 0 request/catalog mismatches.
- Test-EnglishModeNoCjk: PASS.
- Package verification: SHA256SUMS.txt matched local hashes; ZIP entries are exactly PaperWeatherWidget.exe, LICENSE, and README.txt; packaged EXE launch-close PASS.
- Full region smoke, 47-region smoke, 200-region smoke, UiRegionRenderSmoke, and RealUiInteractionSmoke were not run because FULL_SMOKE_APPROVED was not provided.

## SHA256

3bcdc3fb801ee015d703aa33f6c48cd5c4c9594b6cfb9339a19755c06afecdc1  PaperWeatherWidget-v1.3.0-win-x64.exe
b048c22c9ba37da7967c7e91a0cdc8c319bcfdf0879edbc0e6ac5906501194a2  PaperWeatherWidget-v1.3.0-win-x64.zip

## Notes

This edition is not affiliated with, endorsed by, or using brand assets from Anthropic or Claude. The wording "Anthropic-inspired" describes a general visual direction only.

The executable is unsigned. Windows SmartScreen may show an unknown publisher warning on first launch.