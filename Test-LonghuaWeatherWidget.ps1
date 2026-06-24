$ErrorActionPreference = 'Stop'

$script:Passed = 0
$script:Failed = 0

function Assert-Equal {
    param(
        [object]$Expected,
        [object]$Actual,
        [string]$Name
    )

    if ($Expected -ne $Actual) {
        $script:Failed++
        throw "FAILED: $Name. Expected '$Expected', got '$Actual'."
    }
    $script:Passed++
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Name
    )

    if (-not $Condition) {
        $script:Failed++
        throw "FAILED: $Name."
    }
    $script:Passed++
}

. (Join-Path $PSScriptRoot 'LonghuaWeatherWidget.ps1') -TestMode
$scriptText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'LonghuaWeatherWidget.ps1') -Raw

$localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
$expectedSettingsPath = Join-Path (Join-Path $localAppData 'LonghuaWeatherWidget') 'settings.json'
Assert-Equal $expectedSettingsPath $script:SettingsPath 'settings path uses LocalAppData'
$legacySettingsExpression = "Join-Path `$PSScriptRoot 'LonghuaWeatherWidget.settings.json'"
Assert-True (-not $scriptText.Contains($legacySettingsExpression)) 'settings path avoids script directory'
Assert-True ($scriptText -match 'GetApartmentState\(\)') 'runtime checks apartment state'
Assert-True ($scriptText -match '\[Threading\.ApartmentState\]::STA') 'runtime requires STA outside test mode'
Assert-True ($scriptText -match 'Weather data by Open-Meteo\.') 'UI includes Open-Meteo attribution'

$originalSettingsPath = $script:SettingsPath
$tempSettingsRoot = Join-Path ([IO.Path]::GetTempPath()) ('LonghuaWeatherWidgetTest-' + [Guid]::NewGuid().ToString('N'))
try {
    $script:SettingsPath = Join-Path $tempSettingsRoot 'settings.json'
    Save-Settings
    Assert-True (Test-Path -LiteralPath $script:SettingsPath) 'settings save creates missing directory and file'
    $savedSettings = Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json
    Assert-Equal 'Guangdong' $savedSettings.ProvinceKey 'settings save default province'
    Assert-Equal 'Shenzhen' $savedSettings.CityKey 'settings save default city'
    Assert-Equal 'Longhua' $savedSettings.DistrictKey 'settings save default district'
} finally {
    $script:SettingsPath = $originalSettingsPath
    if (Test-Path -LiteralPath $tempSettingsRoot) {
        Remove-Item -LiteralPath $tempSettingsRoot -Recurse -Force
    }
}
$fixture = @'
{
  "timezone": "Asia/Shanghai",
  "current": {
    "time": "2026-06-17T10:00",
    "temperature_2m": 30.2,
    "relative_humidity_2m": 76,
    "apparent_temperature": 35.1,
    "is_day": 1,
    "precipitation": 0.2,
    "rain": 0.2,
    "showers": 0,
    "weather_code": 61,
    "cloud_cover": 88,
    "pressure_msl": 1004.5,
    "surface_pressure": 1002.1,
    "wind_speed_10m": 12.4,
    "wind_direction_10m": 145,
    "wind_gusts_10m": 21.8
  },
  "hourly": {
    "time": ["2026-06-17T10:00", "2026-06-17T11:00", "2026-06-17T13:00", "2026-06-17T16:00", "2026-06-17T20:00", "2026-06-18T09:00"],
    "temperature_2m": [30.2, 30.7, 31.5, 30.9, 28.1, 29.4],
    "relative_humidity_2m": [76, 75, 70, 74, 82, 78],
    "dew_point_2m": [25.5, 25.6, 25.2, 25.8, 24.9, 25.1],
    "apparent_temperature": [35.1, 35.8, 36.4, 35.9, 31.6, 33.8],
    "precipitation_probability": [30, 35, 45, 55, 40, 25],
    "precipitation": [0.2, 0.0, 1.1, 2.0, 0.4, 0.0],
    "rain": [0.2, 0.0, 1.1, 2.0, 0.4, 0.0],
    "showers": [0, 0, 0, 0, 0, 0],
    "weather_code": [61, 3, 63, 95, 80, 2],
    "cloud_cover": [88, 82, 90, 96, 86, 55],
    "pressure_msl": [1004.5, 1004.1, 1003.2, 1002.8, 1003.4, 1005.1],
    "surface_pressure": [1002.1, 1001.7, 1000.9, 1000.3, 1001.0, 1002.6],
    "visibility": [9000, 11000, 8000, 6500, 10000, 14000],
    "wind_speed_10m": [12.4, 13.1, 15.2, 18.6, 11.4, 10.2],
    "wind_direction_10m": [145, 150, 162, 170, 140, 120],
    "wind_gusts_10m": [21.8, 23.0, 28.4, 34.6, 20.1, 18.9],
    "uv_index": [6.1, 7.0, 8.2, 3.0, 0, 5.6],
    "is_day": [1, 1, 1, 1, 0, 1]
  },
  "daily": {
    "time": ["2026-06-17", "2026-06-18"],
    "weather_code": [95, 2],
    "temperature_2m_max": [32.0, 31.4],
    "temperature_2m_min": [27.1, 26.8],
    "apparent_temperature_max": [37.2, 36.0],
    "apparent_temperature_min": [30.1, 29.8],
    "sunrise": ["2026-06-17T05:39", "2026-06-18T05:39"],
    "sunset": ["2026-06-17T19:10", "2026-06-18T19:10"],
    "daylight_duration": [48660, 48660],
    "sunshine_duration": [17400, 21600],
    "uv_index_max": [8.5, 7.4],
    "precipitation_sum": [7.7, 1.2],
    "rain_sum": [7.7, 1.2],
    "precipitation_hours": [6, 2],
    "precipitation_probability_max": [70, 35],
    "wind_speed_10m_max": [22.4, 18.0],
    "wind_gusts_10m_max": [36.8, 29.0],
    "wind_direction_10m_dominant": [158, 128]
  }
}
'@

$weather = $fixture | ConvertFrom-Json
$model = ConvertTo-OpenMeteoForecastModel -Weather $weather

Assert-Equal 'Open-Meteo' $model.Source 'weather API parsing source'
Assert-Equal 6 @($model.Hourly).Count 'weather API parsing hourly count'
Assert-Equal 2 @($model.Daily).Count 'weather API parsing daily count'
Assert-Equal 30.2 $model.Current.TemperatureC 'weather API parsing current temperature'
Assert-Equal 21.8 $model.Current.WindGustKmh 'weather API parsing wind gust'

$urls = Get-WeatherUrls
Assert-True ($urls.OpenMeteo -match 'timezone=auto') 'Open-Meteo request timezone'
Assert-True ($urls.OpenMeteo -match 'forecast_days=14') 'Open-Meteo request forecast days'
Assert-True ($urls.OpenMeteo -match 'forecast_hours=336') 'Open-Meteo request forecast hours'
Assert-True ($urls.OpenMeteo -match 'hourly=.*uv_index') 'Open-Meteo request hourly fields'

$script:Language = 'en'
Assert-Equal 'Thunderstorm' (Get-WeatherText -Code 95) 'weather code mapping thunderstorm'
Assert-Equal 'Rain' (Get-WeatherText -Code 63) 'weather code mapping rain'

$slot = Get-WeatherSnapshotFromModel -Model $model -SlotKey '+3h'
Assert-Equal $false $slot.IsCurrent 'forecast slot is future'
Assert-Equal '13:00' $slot.SourceTime 'forecast slot +3h source time'
Assert-Equal 45 $slot.RainProbability 'forecast slot hourly probability'
Assert-Equal ('Forecast {0} 06-17 13:00' -f ([char]0x00B7)) (Format-ForecastModeLabel -Snapshot $slot) 'forecast mode label'

$tomorrow = Get-WeatherSnapshotFromModel -Model $model -SlotKey 'Tomorrow'
Assert-Equal '09:00' $tomorrow.SourceTime 'forecast slot tomorrow source time'

$dayHour = Get-WeatherSnapshotFromModel -Model $model -SlotKey 'D1T09'
Assert-Equal $false $dayHour.IsCurrent 'forecast slot day hour is future'
Assert-Equal '09:00' $dayHour.SourceTime 'forecast slot day hour source time'
Assert-Equal 'D1T09' $dayHour.SlotKey 'forecast slot day hour key'

$now = Get-WeatherSnapshotFromModel -Model $model -SlotKey 'Now'
Assert-Equal $true $now.IsCurrent 'forecast slot now current'
Assert-Equal 'Now' (Format-ForecastModeLabel -Snapshot $now) 'current mode label'

$thunderSnapshot = [pscustomobject]@{
    WindKmh = 12
    WindGustKmh = 24
    RainNowMm = 0.4
    TodayRainMm = 12
    RainProbability = 80
    IsThunderstorm = $true
    IsRainingNow = $true
    WeatherCode = 95
    CloudCoverPercent = 98
    IsDay = 1
}
Assert-Equal 'ThunderstormAlert' (Get-WeatherAlertInfo -Snapshot $thunderSnapshot).Key 'weather alert thunderstorm'
Assert-True ((Get-WeatherVisualInfo -Snapshot $thunderSnapshot).Icon.Length -gt 0) 'weather visual thunderstorm icon'
Assert-Equal 'Thunderstorm' (Get-WeatherVisualInfo -Snapshot $thunderSnapshot).IconKey 'weather visual thunderstorm icon key'

$forecastThunderSnapshot = [pscustomobject]@{
    WindKmh = 12
    WindGustKmh = 24
    RainNowMm = 0.2
    TodayRainMm = 2.1
    RainProbability = 30
    IsThunderstorm = $true
    IsRainingNow = $true
    WeatherCode = 95
    CloudCoverPercent = 92
    IsDay = 1
    IsCurrent = $false
}
$forecastThunderAlert = Get-WeatherAlertInfo -Snapshot $forecastThunderSnapshot
Assert-Equal 'ForecastThunderstorm' $forecastThunderAlert.Key 'forecast thunderstorm risk label'
Assert-Equal $false $forecastThunderAlert.Active 'forecast thunderstorm is not current active alert'
Assert-Equal 'Thunderstorm' (Get-WeatherVisualInfo -Snapshot $forecastThunderSnapshot).IconKey 'forecast thunderstorm visual icon key'

$typhoonSnapshot = [pscustomobject]@{
    WindKmh = 64
    WindGustKmh = 92
    RainNowMm = 2
    TodayRainMm = 35
    RainProbability = 95
    IsThunderstorm = $false
    IsRainingNow = $true
    WeatherCode = 82
    CloudCoverPercent = 100
    IsDay = 1
}
Assert-Equal 'TyphoonAlert' (Get-WeatherAlertInfo -Snapshot $typhoonSnapshot).Key 'weather alert typhoon threshold'

$clearSnapshot = [pscustomobject]@{
    WindKmh = 8
    WindGustKmh = 16
    RainNowMm = 0
    TodayRainMm = 0
    RainProbability = 10
    IsThunderstorm = $false
    IsRainingNow = $false
    WeatherCode = 0
    CloudCoverPercent = 5
    IsDay = 1
}
Assert-Equal 'NoWeatherAlert' (Get-WeatherAlertInfo -Snapshot $clearSnapshot).Key 'weather alert clear'
Assert-Equal 420 (Get-WidgetTargetHeight -SettingsOpen $false) 'window compact height target'
Assert-Equal 548 (Get-WidgetTargetHeight -SettingsOpen $true) 'window settings height target'
Assert-True ($scriptText -match '\$settingsIconHorizontal\.Height = 3') 'settings icon horizontal bar scaled thickness'
Assert-True ($scriptText -match '\$settingsIconVertical\.Width = 3') 'settings icon vertical bar scaled thickness'
Assert-True ($scriptText -match 'Set-SettingsIconExpanded') 'settings icon minus uses hidden vertical bar'
Assert-True ($scriptText -match '\$settingsIconGrid\.Height = 18') 'settings icon height scaled 1.5x'
Assert-True ($scriptText -match '\$closeIconCanvas\.Height = 18') 'close icon height matches settings icon'
Assert-True ($scriptText -match '\$closeLineA\.StrokeThickness = 3') 'close icon scaled stroke thickness'
Assert-True (-not ($scriptText -match '\$closeText = New-TextBlock')) 'close icon avoids glyph TextBlock'
Assert-True (-not ($scriptText -match '\$settingsText = New-TextBlock -Text ''\+''')) 'settings icon avoids plus glyph'
Assert-True ($scriptText -match 'New-WeatherIconElement -IconKey \$visual.IconKey') 'weather icon uses drawn icon key'
Assert-True (-not ($scriptText -match '\$weatherIconBlock')) 'weather icon avoids emoji TextBlock'
Assert-Equal $false (Test-RainWeatherCode -Code 95) 'thunder code is not rain by itself'
Assert-Equal 2 (Get-CloudDerivedWeatherCode -CloudCoverPercent 29) 'cloud-derived partly cloudy code'

$dryThunderRecord = [pscustomobject]@{
    Time = [datetime]'2026-06-22T10:15:00'
    WeatherCode = 95
    WeatherText = $null
    PrecipitationMm = 0
    RainMm = 0
    ShowersMm = 0
    PrecipitationProbability = $null
    CloudCoverPercent = 29
    TemperatureC = 31.1
    FeelsLikeC = 36.7
    HumidityPercent = 69
    DewPointC = $null
    PressureMslHpa = 1002.1
    SurfacePressureHpa = 1000.2
    WindKmh = 13.5
    WindDirectionDeg = 160
    WindGustKmh = 33.8
    UvIndex = $null
    VisibilityM = $null
    IsDay = 1
}
$dryThunderDaily = [pscustomobject]@{
    PrecipitationSumMm = 0
    PrecipitationProbabilityMax = 24
    UvIndexMax = $null
}
$dryThunderSnapshot = ConvertTo-DisplayWeatherSnapshot -Model ([pscustomobject]@{ Source = 'Open-Meteo' }) -Record $dryThunderRecord -DailyRecord $dryThunderDaily -SlotKey 'Now' -IsCurrent $true
Assert-Equal 95 $dryThunderSnapshot.RawWeatherCode 'dry thunder preserves raw source code'
Assert-Equal 2 $dryThunderSnapshot.WeatherCode 'dry thunder display code derives from cloud cover'
Assert-Equal 'Partly cloudy' $dryThunderSnapshot.WeatherText 'dry thunder display text'
Assert-Equal $false $dryThunderSnapshot.IsThunderstorm 'dry thunder does not become active thunder alert'
Assert-Equal $false $dryThunderSnapshot.IsRainingNow 'dry thunder does not become active rain'
Assert-Equal 'NoWeatherAlert' (Get-WeatherAlertInfo -Snapshot $dryThunderSnapshot).Key 'dry thunder alert suppression'
Assert-Equal (New-WeatherGlyph 0x26C5) (Get-WeatherVisualInfo -Snapshot $dryThunderSnapshot).Icon 'dry thunder visual fallback'

function New-TestVisualSnapshot {
    param(
        [int]$WeatherCode,
        [double]$RainNowMm = 0,
        [double]$CloudCoverPercent = 0,
        [bool]$IsThunderstorm = $false
    )

    [pscustomobject]@{
        WindKmh = 0
        WindGustKmh = 0
        RainNowMm = $RainNowMm
        TodayRainMm = $RainNowMm
        RainProbability = 0
        IsThunderstorm = $IsThunderstorm
        IsRainingNow = ($RainNowMm -gt 0)
        WeatherCode = $WeatherCode
        CloudCoverPercent = $CloudCoverPercent
        IsDay = 1
    }
}

$visualSamples = @(
    (New-TestVisualSnapshot -WeatherCode 0 -CloudCoverPercent 5),
    (New-TestVisualSnapshot -WeatherCode 2 -CloudCoverPercent 45),
    (New-TestVisualSnapshot -WeatherCode 3 -CloudCoverPercent 90),
    (New-TestVisualSnapshot -WeatherCode 45 -CloudCoverPercent 80),
    (New-TestVisualSnapshot -WeatherCode 61 -RainNowMm 0.2 -CloudCoverPercent 90),
    (New-TestVisualSnapshot -WeatherCode 80 -RainNowMm 0.2 -CloudCoverPercent 90),
    (New-TestVisualSnapshot -WeatherCode 71 -CloudCoverPercent 90),
    (New-TestVisualSnapshot -WeatherCode 95 -CloudCoverPercent 90 -IsThunderstorm $true)
)
$uniqueWeatherIcons = @($visualSamples | ForEach-Object { (Get-WeatherVisualInfo -Snapshot $_).Icon } | Select-Object -Unique)
Assert-Equal 8 $uniqueWeatherIcons.Count 'weather visual icon variety'

Assert-Equal '12.3' (Format-Number 12.34 1) 'unit formatting decimal'
Assert-Equal '--' (Format-Number $null 1) 'unit formatting null'

Assert-Equal 'Cloud' (Tx 'Cloud') 'English label cloud'
$script:Language = 'zh'
$cloudZh = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('5LqR6YeP'))
Assert-Equal $cloudZh (Tx 'Cloud') 'Chinese label cloud'
$lastTryZh = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('5LiK5qyh5bCd6K+V'))
Assert-Equal $lastTryZh (Tx 'LastTry') 'Chinese label last try'
Assert-Equal 'plain text' (T 'plain text') 'translation fallback for invalid base64'

Write-Host "Tests passed: $script:Passed"
