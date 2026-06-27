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

function Assert-NoCjk {
    param(
        [string]$Text,
        [string]$Name
    )

    Assert-True (-not ([string]$Text -match '[\u3400-\u9FFF\uF900-\uFAFF]')) $Name
}

. (Join-Path $PSScriptRoot 'LonghuaWeatherWidget.ps1') -TestMode
$scriptText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'LonghuaWeatherWidget.ps1') -Raw
Assert-True ($scriptText -match 'if \(\$script:UiSmokeMode -and \[string\]\$script:UiFixture -ne ''Live''\)') 'UiSmoke Live keeps production region catalog'

# Final UI Gate state-label and long-name regressions
$script:Language = 'zh'
Assert-Equal '加载中' (Tx 'Loading') 'loading top label zh'
Assert-Equal '正在获取天气' (Tx 'FetchingWeather') 'loading main weather copy zh'
Assert-Equal '正在获取临近预报' (Tx 'FetchingNearTerm') 'loading near-term copy zh'
Assert-Equal '天气服务暂不可用' (Tx 'WeatherUnavailable') 'error main weather copy zh'
Assert-Equal '临近预报暂不可用' (Tx 'NearTermUnavailable') 'error near-term copy zh'
Assert-Equal '当前' (Tx 'Live') 'model current source label zh replaces realtime'
$script:Language = 'en'
Assert-Equal 'Loading' (Tx 'Loading') 'loading top label en'
Assert-Equal 'Fetching weather' (Tx 'FetchingWeather') 'loading main weather copy en'
Assert-Equal 'Fetching near-term forecast' (Tx 'FetchingNearTerm') 'loading near-term copy en'
Assert-Equal 'Weather service unavailable' (Tx 'WeatherUnavailable') 'error main weather copy en'
Assert-Equal 'Near-term forecast unavailable' (Tx 'NearTermUnavailable') 'error near-term copy en'
Assert-Equal 'Current' (Tx 'Live') 'model current source label en replaces live'
Assert-True ($scriptText -match 'TextTrimming="CharacterEllipsis"') 'district combo selected text uses character ellipsis'
Assert-True ($scriptText -match 'ToolTip="\{Binding Display\}"') 'district combo selected text exposes full tooltip'
Assert-True ($scriptText -match 'AutomationProperties.Name="\{Binding Display\}"') 'combo item automation name exposes full display text'
Assert-True ($scriptText -match 'x:Name="SelectionText"[\s\S]*TextTrimming="CharacterEllipsis"') 'combo selected item uses character ellipsis separately'
$comboItemTemplateBlock = [regex]::Match($scriptText, 'function New-ComboBoxItemTemplate \{[\s\S]*?\n\}').Value
Assert-True (-not ($comboItemTemplateBlock -match 'TextTrimming')) 'combo dropdown list items keep full names instead of ellipsis'
Assert-True ($scriptText -match 'AutomationProperties\]::NameProperty, \$display') 'combo selected automation name stores full display text'
Assert-True ($scriptText -match "New-District 'SIP' 'Industrial Park'") 'long name fixture Industrial Park exists'
Assert-True ($scriptText -match "New-District 'Pudong' 'Pudong New Area'") 'long name fixture Pudong New Area exists'
Assert-True ($scriptText -match "New-District 'Gaoxin' 'High-tech Zone'") 'long name fixture High-tech Zone exists'
$longNameFixture = 'Experimental Ultra Long Administrative Development Zone'
Assert-True ($longNameFixture.Length -gt 'Industrial Park'.Length) 'extra long test fixture name is longer than production long names'

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
    WeatherText = 'Thunderstorm'
    CloudCoverPercent = 98
    IsDay = 1
}
Assert-Equal 'ThunderstormAlert' (Get-WeatherAlertInfo -Snapshot $thunderSnapshot).Key 'weather alert thunderstorm'
Assert-True ((Get-WeatherVisualInfo -Snapshot $thunderSnapshot).Icon.Length -gt 0) 'weather visual thunderstorm icon'
Assert-Equal 'Thunderstorm' (Get-WeatherVisualInfo -Snapshot $thunderSnapshot).IconKey 'weather visual thunderstorm icon key'
Assert-Equal 'Thunderstorm' (Get-WeatherConditionDisplayText -Snapshot $thunderSnapshot) 'active alert keeps weather condition in hero'
Assert-Equal 'Current' (Get-WeatherStatusDisplayText -Snapshot $thunderSnapshot) 'status panel shows source state not weather description'

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
Assert-Equal 448 (Get-WidgetTargetHeight -SettingsOpen $false) 'window compact height target'
Assert-Equal 656 (Get-WidgetTargetHeight -SettingsOpen $true) 'window settings height target'
Assert-True ($scriptText -match '\$settingsIconText = New-TextBlock -Text \(New-WeatherGlyph 0x2699\)') 'settings icon uses gear glyph'
Assert-True ($scriptText -match '\$settingsIconRotate\.Angle = 28') 'settings icon rotates on expanded state'
Assert-True ($scriptText -match '\$settingsIconGrid\.Height = 18') 'settings icon height scaled 1.5x'
Assert-True ($scriptText -match '\$closeIconCanvas\.Height = 18') 'close icon height matches settings icon'
Assert-True ($scriptText -match '\$closeLineA\.StrokeThickness = 3') 'close icon scaled stroke thickness'
Assert-Equal 28 (Get-DrawerVisibleStrip) 'drawer visible strip width'
Assert-True ($scriptText -match '\$script:DrawerAnimationDurationMs = 260') 'drawer animation duration is in target range'
Assert-True ($scriptText -match 'System\.Windows\.Media\.Animation\.DoubleAnimation') 'drawer uses WPF window Left animation'
Assert-True ($scriptText -match 'System\.Windows\.Media\.Animation\.CubicEase') 'drawer uses cubic easing'
Assert-True ($scriptText -match 'EasingMode\]::EaseOut') 'drawer animation uses ease-out'
Assert-True ($scriptText -match '\$drawerHandle\.Width = Get-DrawerVisibleStrip') 'drawer handle width comes from visible strip'
Assert-True ($scriptText -match '\$drawerHandle\.VerticalAlignment = ''Center''') 'drawer handle is vertically centered'
Assert-True ($scriptText -match 'DrawerScreenDeviceName') 'drawer persists monitor identity'
Assert-True ($scriptText -match 'DrawerTop = \$script:DrawerTop') 'drawer persists vertical position'
Assert-True (-not ($scriptText -match 'DrawerHoverArmed')) 'drawer no longer uses hover auto-collapse state'
$drawerPositionBlock = [regex]::Match($scriptText, 'function Set-DrawerEdgePosition \{(?<body>.*?)function Set-WindowDrawerState \{', [System.Text.RegularExpressions.RegexOptions]::Singleline).Groups['body'].Value
Assert-True (-not ($drawerPositionBlock -match "'Top'")) 'drawer position logic does not dock to top edge'
Assert-True (-not ($drawerPositionBlock -match "'Bottom'")) 'drawer position logic does not dock to bottom edge'
$collapseButtonBlock = [regex]::Match($scriptText, '\$closeButton\.Add_MouseLeftButtonUp\(\{(?<body>.*?)\}\)', [System.Text.RegularExpressions.RegexOptions]::Singleline).Groups['body'].Value
Assert-True ($collapseButtonBlock -match '\$window\.Close\(\)') 'top-right button closes the app'
Assert-True (-not ($collapseButtonBlock -match 'Collapse-WindowDrawer -Window \$window')) 'top-right close button no longer collapses the drawer'
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

function New-SemanticWeatherRecord {
    param(
        [datetime]$Time,
        [int]$WeatherCode,
        [double]$RainMm = 0,
        [double]$PrecipitationMm = $RainMm,
        [double]$CloudCoverPercent = 80,
        [int]$PrecipitationProbability = 20,
        [double]$TemperatureC = 29.5,
        [Nullable[int]]$IntervalSeconds = $null
    )

    [pscustomobject]@{
        Time = $Time
        TemperatureC = $TemperatureC
        HumidityPercent = 72
        DewPointC = $null
        FeelsLikeC = ($TemperatureC + 2.0)
        PrecipitationProbability = $PrecipitationProbability
        PrecipitationMm = $PrecipitationMm
        RainMm = $RainMm
        ShowersMm = 0.0
        WeatherCode = $WeatherCode
        CloudCoverPercent = $CloudCoverPercent
        PressureMslHpa = 1004.0
        SurfacePressureHpa = 1002.0
        VisibilityM = 10000
        WindKmh = 9.0
        WindDirectionDeg = 135
        WindGustKmh = 16.0
        UvIndex = 3.0
        IsDay = 1
        IntervalSeconds = $IntervalSeconds
        WeatherText = $null
    }
}
function New-SemanticWeatherModel {
    param(
        [object]$Current,
        [object[]]$Hourly = @(),
        [string]$WarningText = '',
        [string]$WarningLevel = '',
        [string]$LocationKey = (Get-SelectedLocationKey),
        [string]$Source = 'SemanticFixture'
    )

    $daily = [pscustomobject]@{
        Date = $Current.Time.Date
        WeatherCode = $Current.WeatherCode
        PrecipitationSumMm = 0
        RainSumMm = 0
        PrecipitationHours = 0
        PrecipitationProbabilityMax = 20
        UvIndexMax = 3
    }

    [pscustomobject]@{
        Source = $Source
        SourceTime = $Current.Time.ToString('HH:mm')
        Timezone = 'Asia/Shanghai'
        Current = $Current
        Hourly = @($Hourly)
        Daily = @($daily)
        SupportsForecastSlots = $true
        AirQuality = $null
        WarningText = $WarningText
        WarningLevel = $WarningLevel
        LocationKey = $LocationKey
        FetchedAt = $Current.Time
        IsCacheData = $false
    }
}

function Assert-TextDoesNotContainHeavyRainNow {
    param(
        [string]$Text,
        [string]$Name
    )

    Assert-True ($Text -notmatch '当前暴雨|现在暴雨|正在暴雨') $Name
}

function Reset-TestWeatherRequestState {
    $script:WeatherModelCache = @{}
    Clear-ActiveWeatherModelForLocationChange
    $script:WeatherRequestSequence = 0
    $script:ActiveWeatherRequestId = 0
    $script:ActiveWeatherRequestLocationKey = $null
    $script:SelectedForecastSlotKey = 'Now'
}

function Use-TestLocation {
    param(
        [string]$ProvinceKey,
        [string]$CityKey,
        [string]$DistrictKey
    )

    $script:SelectedProvinceKey = $ProvinceKey
    $script:SelectedCityKey = $CityKey
    $script:SelectedDistrictKey = $DistrictKey
    Get-SelectedDistrict | Out-Null
}

$script:Language = 'en'
Assert-Equal 'Heavy rain' (Get-WeatherText -Code 65) 'WMO 65 maps to heavy rain, not rainstorm'
$script:Language = 'zh'
$semanticNow = [datetime]'2026-06-26T14:20:00'
$currentDryOvercast = New-SemanticWeatherRecord -Time $semanticNow -WeatherCode 3 -RainMm 0 -PrecipitationMm 0 -CloudCoverPercent 96
$futureHeavyRain = New-SemanticWeatherRecord -Time ([datetime]'2026-06-26T15:00:00') -WeatherCode 65 -RainMm 12 -PrecipitationMm 12 -CloudCoverPercent 100 -PrecipitationProbability 95 -IntervalSeconds 3600
$currentNoRainFutureHeavyModel = New-SemanticWeatherModel -Current $currentDryOvercast -Hourly @($currentDryOvercast, $futureHeavyRain)
$currentNoRainFutureHeavySnapshot = Get-WeatherSnapshotFromModel -Model $currentNoRainFutureHeavyModel -SlotKey 'Now' -Now $semanticNow
Assert-Equal 0.0 ([double]$currentNoRainFutureHeavySnapshot.CurrentRainAmount) 'scenario semantic 1 current dry main condition'
Assert-TextDoesNotContainHeavyRainNow -Text (Get-WeatherConditionDisplayText -Snapshot $currentNoRainFutureHeavySnapshot) -Name 'scenario semantic 1 future heavy rain not current'
Assert-True ($null -ne $currentNoRainFutureHeavySnapshot.NearTermForecastTime) 'scenario semantic 1 near-term forecast announces future rain'

$warningDryModel = New-SemanticWeatherModel -Current $currentDryOvercast -Hourly @($currentDryOvercast, $futureHeavyRain) -WarningText 'OfficialRainstormYellowWarning' -WarningLevel 'Yellow'
$warningDrySnapshot = Get-WeatherSnapshotFromModel -Model $warningDryModel -SlotKey 'Now' -Now $semanticNow
Assert-TextDoesNotContainHeavyRainNow -Text (Get-WeatherConditionDisplayText -Snapshot $warningDrySnapshot) -Name 'scenario semantic 2 warning does not become current heavy rain'
Assert-True ((Get-WeatherWarningDisplayText -Snapshot $warningDrySnapshot) -match 'OfficialRainstormYellowWarning') 'scenario semantic 2 official warning appears in warning field'
Assert-True ((Get-WeatherConditionDisplayText -Snapshot $warningDrySnapshot) -notmatch 'OfficialRainstormYellowWarning') 'scenario semantic 2 warning absent from main condition'

$currentActualHeavy = New-SemanticWeatherRecord -Time $semanticNow -WeatherCode 65 -RainMm 16 -PrecipitationMm 16 -CloudCoverPercent 100 -PrecipitationProbability 95 -IntervalSeconds 3600
$actualHeavyModel = New-SemanticWeatherModel -Current $currentActualHeavy -Hourly @($currentActualHeavy) -WarningText 'OfficialRainstormYellowWarning' -WarningLevel 'Yellow'
$actualHeavySnapshot = Get-WeatherSnapshotFromModel -Model $actualHeavyModel -SlotKey 'Now' -Now $semanticNow
Assert-Equal $true $actualHeavySnapshot.CurrentIsRainstorm 'scenario semantic 3 actual current rainstorm'
Assert-Equal 3600 $actualHeavySnapshot.CurrentIntervalSeconds 'scenario semantic 3 current interval preserved'
Assert-True ((Get-WeatherWarningDisplayText -Snapshot $actualHeavySnapshot) -match 'OfficialRainstormYellowWarning') 'scenario semantic 3 official warning remains separate'

$currentEight900 = New-SemanticWeatherRecord -Time $semanticNow -WeatherCode 65 -RainMm 8 -PrecipitationMm 8 -CloudCoverPercent 100 -PrecipitationProbability 90 -IntervalSeconds 900
$currentEight900Model = New-SemanticWeatherModel -Current $currentEight900 -Hourly @($currentEight900)
$currentEight900Snapshot = Get-WeatherSnapshotFromModel -Model $currentEight900Model -SlotKey 'Now' -Now $semanticNow
Assert-TextDoesNotContainHeavyRainNow -Text (Get-WeatherConditionDisplayText -Snapshot $currentEight900Snapshot) -Name 'scenario semantic 3b interval 900 8mm not rainstorm'
Assert-Equal $true $currentEight900Snapshot.CurrentIsStrongRain 'scenario semantic 3b interval 900 8mm is strong rain'
Assert-Equal 900 $currentEight900Snapshot.CurrentIntervalSeconds 'scenario semantic 3b interval 900 preserved'
Assert-True ((Get-WeatherWarningDisplayText -Snapshot $currentEight900Snapshot) -notmatch 'Warning|Rainstorm') 'scenario semantic 3b model rain tip is not official warning or rainstorm'
Assert-Equal $false $currentEight900Snapshot.CurrentIsRainstorm 'scenario semantic 3b model rain is not rainstorm'

$currentEight3600 = New-SemanticWeatherRecord -Time $semanticNow -WeatherCode 65 -RainMm 8 -PrecipitationMm 8 -CloudCoverPercent 100 -PrecipitationProbability 90 -IntervalSeconds 3600
$currentEight3600Model = New-SemanticWeatherModel -Current $currentEight3600 -Hourly @($currentEight3600)
$currentEight3600Snapshot = Get-WeatherSnapshotFromModel -Model $currentEight3600Model -SlotKey 'Now' -Now $semanticNow
Assert-TextDoesNotContainHeavyRainNow -Text (Get-WeatherConditionDisplayText -Snapshot $currentEight3600Snapshot) -Name 'scenario semantic 3c interval 3600 8mm not rainstorm'
Assert-Equal $true $currentEight3600Snapshot.CurrentIsStrongRain 'scenario semantic 3c interval 3600 8mm is strong rain'
Assert-Equal 3600 $currentEight3600Snapshot.CurrentIntervalSeconds 'scenario semantic 3c interval 3600 preserved'
$currentAt1420 = New-SemanticWeatherRecord -Time $semanticNow -WeatherCode 3 -RainMm 0 -PrecipitationMm 0 -CloudCoverPercent 96
$hourly1400 = New-SemanticWeatherRecord -Time ([datetime]'2026-06-26T14:00:00') -WeatherCode 3 -RainMm 0 -PrecipitationMm 0 -CloudCoverPercent 96
$hourly1500 = New-SemanticWeatherRecord -Time ([datetime]'2026-06-26T15:00:00') -WeatherCode 65 -RainMm 12 -PrecipitationMm 12 -CloudCoverPercent 100 -PrecipitationProbability 95
$futureSlotModel = New-SemanticWeatherModel -Current $currentAt1420 -Hourly @($hourly1400, $hourly1500)
$futureSlotSnapshot = Get-WeatherSnapshotFromModel -Model $futureSlotModel -SlotKey 'Now' -Now $semanticNow
Assert-TextDoesNotContainHeavyRainNow -Text (Get-WeatherConditionDisplayText -Snapshot $futureSlotSnapshot) -Name 'scenario semantic 4 15:00 heavy rain not current'
Assert-True ($null -ne $futureSlotSnapshot.NearTermForecastTime) 'scenario semantic 4 future strong rain remains forecast'

$utcFixture = @"
{
  "timezone": "Asia/Shanghai",
  "current": {
    "time": "2026-06-26T14:20:00",
    "temperature_2m": 29.5,
    "relative_humidity_2m": 72,
    "apparent_temperature": 31.5,
    "is_day": 1,
    "precipitation": 0,
    "rain": 0,
    "showers": 0,
    "weather_code": 3,
    "interval": 900,
    "cloud_cover": 96,
    "pressure_msl": 1004,
    "surface_pressure": 1002,
    "wind_speed_10m": 9,
    "wind_direction_10m": 135,
    "wind_gusts_10m": 16
  },
  "hourly": {
    "time": ["2026-06-26T06:00:00Z", "2026-06-26T07:00:00Z"],
    "temperature_2m": [29.2, 28.8],
    "relative_humidity_2m": [72, 88],
    "dew_point_2m": [24, 25],
    "apparent_temperature": [31, 32],
    "precipitation_probability": [10, 95],
    "precipitation": [0, 12],
    "rain": [0, 12],
    "showers": [0, 0],
    "weather_code": [3, 65],
    "cloud_cover": [96, 100],
    "pressure_msl": [1004, 1003],
    "surface_pressure": [1002, 1001],
    "visibility": [10000, 6000],
    "wind_speed_10m": [9, 18],
    "wind_direction_10m": [135, 150],
    "wind_gusts_10m": [16, 28],
    "uv_index": [3, 1],
    "is_day": [1, 1]
  },
  "daily": {
    "time": ["2026-06-26"],
    "weather_code": [65],
    "temperature_2m_max": [30],
    "temperature_2m_min": [26],
    "apparent_temperature_max": [33],
    "apparent_temperature_min": [29],
    "sunrise": ["2026-06-26T05:40"],
    "sunset": ["2026-06-26T19:11"],
    "daylight_duration": [48660],
    "sunshine_duration": [10000],
    "uv_index_max": [5],
    "precipitation_sum": [12],
    "rain_sum": [12],
    "precipitation_hours": [1],
    "precipitation_probability_max": [95],
    "wind_speed_10m_max": [18],
    "wind_gusts_10m_max": [28],
    "wind_direction_10m_dominant": [150]
  }
}
"@
$utcModel = ConvertTo-OpenMeteoForecastModel -Weather ($utcFixture | ConvertFrom-Json)
$utcSnapshot = Get-WeatherSnapshotFromModel -Model $utcModel -SlotKey 'Now' -Now $semanticNow
Assert-Equal 900 $utcModel.Current.IntervalSeconds 'scenario semantic 5 Open-Meteo current interval preserved'
Assert-Equal 14 $utcModel.Hourly[0].Time.Hour 'scenario semantic 5 UTC slot converts to Asia Shanghai local hour'
Assert-TextDoesNotContainHeavyRainNow -Text (Get-WeatherConditionDisplayText -Snapshot $utcSnapshot) -Name 'scenario semantic 5 UTC future heavy rain not early current'
Assert-True ($null -ne $utcSnapshot.NearTermForecastTime) 'scenario semantic 5 UTC future slot remains future strong rain'

$contradictoryCurrent = New-SemanticWeatherRecord -Time $semanticNow -WeatherCode 65 -RainMm 0 -PrecipitationMm 0 -CloudCoverPercent 100 -PrecipitationProbability 95
$contradictoryModel = New-SemanticWeatherModel -Current $contradictoryCurrent -Hourly @($contradictoryCurrent)
$contradictorySnapshot = Get-WeatherSnapshotFromModel -Model $contradictoryModel -SlotKey 'Now' -Now $semanticNow
Assert-TextDoesNotContainHeavyRainNow -Text (Get-WeatherConditionDisplayText -Snapshot $contradictorySnapshot) -Name 'scenario semantic 6 contradictory heavy code not active heavy rain'
Assert-Equal $false $contradictorySnapshot.CurrentIsRainstorm 'scenario semantic 6 conservative current state'
Assert-True (($contradictorySnapshot.Diagnostics -join '|') -match 'InconsistentCurrentRainSignal') 'scenario semantic 6 records inconsistency diagnostic'

Reset-TestWeatherRequestState
Use-TestLocation 'Guangdong' 'Shenzhen' 'Longhua'
$warningARequest = Start-WeatherRequestContext
Resolve-WeatherRequestSuccess -Request $warningARequest -Model (New-SemanticWeatherModel -Current $currentActualHeavy -WarningText 'OfficialRainstormYellowWarning' -WarningLevel 'Yellow') | Out-Null
Use-TestLocation 'Guangdong' 'Shenzhen' 'Futian'
Clear-ActiveWeatherModelForLocationChange
$clearBRequest = Start-WeatherRequestContext
$clearBResult = Resolve-WeatherRequestSuccess -Request $clearBRequest -Model (New-SemanticWeatherModel -Current $currentDryOvercast -LocationKey (Get-SelectedLocationKey)) -FetchedAt $semanticNow
$clearBSnapshot = Get-WeatherSnapshotFromModel -Model $clearBResult.Model -SlotKey 'Now' -Now $semanticNow
Assert-True ((Get-WeatherWarningDisplayText -Snapshot $clearBSnapshot) -notmatch 'OfficialRainstormYellowWarning') 'scenario semantic 7 B does not show A warning'
Assert-TextDoesNotContainHeavyRainNow -Text (Get-WeatherConditionDisplayText -Snapshot $clearBSnapshot) -Name 'scenario semantic 7 B does not show current heavy rain'

Reset-TestWeatherRequestState
Use-TestLocation 'Guangdong' 'Shenzhen' 'Futian'
$slowFutureBRequest = Start-WeatherRequestContext
Use-TestLocation 'Beijing' 'Beijing' 'Chaoyang'
Clear-ActiveWeatherModelForLocationChange
$fastDryCRequest = Start-WeatherRequestContext
$fastDryCResult = Resolve-WeatherRequestSuccess -Request $fastDryCRequest -Model (New-SemanticWeatherModel -Current $currentDryOvercast -LocationKey (Get-SelectedLocationKey)) -FetchedAt $semanticNow
$lateFutureBResult = Resolve-WeatherRequestSuccess -Request $slowFutureBRequest -Model (New-SemanticWeatherModel -Current $currentDryOvercast -Hourly @($currentDryOvercast, $futureHeavyRain) -LocationKey 'Guangdong|Shenzhen|Futian') -FetchedAt $semanticNow
$finalCSnapshot = Get-WeatherSnapshotFromModel -Model $fastDryCResult.Model -SlotKey 'Now' -Now $semanticNow
Assert-Equal $false $lateFutureBResult.ShouldApply 'scenario semantic 8 late B future heavy rain rejected'
Assert-TextDoesNotContainHeavyRainNow -Text (Get-WeatherConditionDisplayText -Snapshot $finalCSnapshot) -Name 'scenario semantic 8 C remains current no heavy rain'

$script:Language = 'en'

$script:Language = 'en'
$clearNoRain = New-SemanticWeatherRecord -Time $semanticNow -WeatherCode 0 -RainMm 0 -PrecipitationMm 0 -CloudCoverPercent 0
$clearNoRainModel = New-SemanticWeatherModel -Current $clearNoRain -Hourly @($clearNoRain)
$clearNoRainSnapshot = Get-WeatherSnapshotFromModel -Model $clearNoRainModel -SlotKey 'Now' -Now $semanticNow
Assert-Equal 'Clear · Current no rain' (Get-WeatherConditionDisplayText -Snapshot $clearNoRainSnapshot) 'English clear current no rain text'
Assert-NoCjk (Get-WeatherConditionDisplayText -Snapshot $clearNoRainSnapshot) 'English clear current no rain has no CJK'
Assert-NoCjk $clearNoRainSnapshot.NearTermForecast 'English clear near-term has no CJK'
Assert-NoCjk (Get-WeatherWarningDisplayText -Snapshot $clearNoRainSnapshot) 'English clear alert text has no CJK'

$overcastFutureModel = New-SemanticWeatherModel -Current $currentDryOvercast -Hourly @($currentDryOvercast, $futureHeavyRain)
$overcastFutureSnapshot = Get-WeatherSnapshotFromModel -Model $overcastFutureModel -SlotKey 'Now' -Now $semanticNow
Assert-Equal 'Overcast · Current no rain' (Get-WeatherConditionDisplayText -Snapshot $overcastFutureSnapshot) 'English overcast current no rain text'
Assert-True ($overcastFutureSnapshot.NearTermForecast -match '^Heavy rain risk') 'English future heavy rain near-term text'
Assert-NoCjk (Get-WeatherConditionDisplayText -Snapshot $overcastFutureSnapshot) 'English overcast future main text has no CJK'
Assert-NoCjk $overcastFutureSnapshot.NearTermForecast 'English overcast future near-term has no CJK'

Assert-NoCjk (Tx 'WeatherUnavailable') 'English weather failure no-cache main copy has no CJK'
Assert-NoCjk (Tx 'NearTermUnavailable') 'English weather failure no-cache near-term copy has no CJK'
Assert-NoCjk (Tx 'Updating') 'English same-location updating top copy has no CJK'
Assert-NoCjk (Tx 'UpdatingFooter') 'English same-location updating footer has no CJK'

$thunderRecord = New-SemanticWeatherRecord -Time $semanticNow -WeatherCode 95 -RainMm 6 -PrecipitationMm 6 -CloudCoverPercent 100 -PrecipitationProbability 95
$thunderSnapshot = Get-WeatherSnapshotFromModel -Model (New-SemanticWeatherModel -Current $thunderRecord -Hourly @($thunderRecord)) -SlotKey 'Now' -Now $semanticNow
Assert-NoCjk (Get-WeatherWarningDisplayText -Snapshot $thunderSnapshot) 'English thunderstorm risk text has no CJK'
Assert-True ((Get-WeatherWarningDisplayText -Snapshot $thunderSnapshot) -match 'Thunderstorm risk') 'English thunderstorm risk fallback text'

$officialZhWarning = T '5rex5Zyz5biC5pq06Zuo6buE6Imy6aKE6K2m'
$officialWarningModel = New-SemanticWeatherModel -Current $currentDryOvercast -Hourly @($currentDryOvercast) -WarningText $officialZhWarning -WarningLevel 'Yellow'
$officialWarningSnapshot = Get-WeatherSnapshotFromModel -Model $officialWarningModel -SlotKey 'Now' -Now $semanticNow
Assert-NoCjk (Get-WeatherWarningDisplayText -Snapshot $officialWarningSnapshot) 'English official warning fallback has no CJK'
Assert-True ((Get-WeatherWarningDisplayText -Snapshot $officialWarningSnapshot) -match 'Heavy rain alert') 'English official warning fallback text'

Use-TestLocation 'Jiangsu' 'Suzhou' 'SIP'
$industrialParkName = Get-DisplayName (Get-SelectedDistrict)
Assert-Equal 'Industrial Park' $industrialParkName 'English Industrial Park display name'
Assert-NoCjk (Get-LocationCardText) 'English Industrial Park location path has no CJK'

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


function Reset-TestWeatherRequestState {
    $script:WeatherModelCache = @{}
    Clear-ActiveWeatherModelForLocationChange
    $script:WeatherRequestSequence = 0
    $script:ActiveWeatherRequestId = 0
    $script:ActiveWeatherRequestLocationKey = $null
    $script:SelectedForecastSlotKey = 'Now'
}

function Use-TestLocation {
    param(
        [string]$ProvinceKey,
        [string]$CityKey,
        [string]$DistrictKey
    )

    $script:SelectedProvinceKey = $ProvinceKey
    $script:SelectedCityKey = $CityKey
    $script:SelectedDistrictKey = $DistrictKey
    Get-SelectedDistrict | Out-Null
}

function New-TestWeatherModel {
    param(
        [double]$TemperatureC,
        [int]$WeatherCode = 0,
        [double]$RainMm = 0,
        [double]$WindKmh = 8,
        [double]$WindGustKmh = 12,
        [int]$HumidityPercent = 55,
        [double]$PressureHpa = 1008.2,
        [string]$Source = 'TestSource'
    )

    $record = [pscustomobject]@{
        Time = [datetime]'2026-06-17T10:00:00'
        TemperatureC = $TemperatureC
        HumidityPercent = $HumidityPercent
        DewPointC = $null
        FeelsLikeC = ($TemperatureC + 1.0)
        PrecipitationProbability = 40
        PrecipitationMm = $RainMm
        RainMm = $RainMm
        ShowersMm = 0.0
        WeatherCode = $WeatherCode
        CloudCoverPercent = if ($WeatherCode -eq 0) { 5 } else { 95 }
        PressureMslHpa = $PressureHpa
        SurfacePressureHpa = $PressureHpa
        VisibilityM = 10000
        WindKmh = $WindKmh
        WindDirectionDeg = 120
        WindGustKmh = $WindGustKmh
        UvIndex = 5
        IsDay = 1
        WeatherText = $null
    }

    $daily = [pscustomobject]@{
        Date = ([datetime]'2026-06-17').Date
        PrecipitationSumMm = $RainMm
        PrecipitationProbabilityMax = 40
        UvIndexMax = 5
    }

    [pscustomobject]@{
        Source = $Source
        SourceTime = '10:00'
        Timezone = 'Asia/Shanghai'
        Current = $record
        Hourly = @()
        Daily = @($daily)
        SupportsForecastSlots = $true
        AirQuality = $null
    }
}

Reset-TestWeatherRequestState
Use-TestLocation 'Guangdong' 'Shenzhen' 'Longhua'
$requestA = Start-WeatherRequestContext
$resultA = Resolve-WeatherRequestSuccess -Request $requestA -Model (New-TestWeatherModel -TemperatureC 11.1 -WeatherCode 95 -RainMm 1.2) -FetchedAt ([datetime]'2026-06-17T10:01:00')
$snapshotA = Get-WeatherSnapshotFromModel -Model $resultA.Model -SlotKey 'Now'
Assert-Equal 11.1 $snapshotA.TemperatureC 'scenario A setup stores A temperature'
Assert-Equal 'ThunderstormAlert' (Get-WeatherAlertInfo -Snapshot $snapshotA).Key 'scenario A setup stores A alert'
Use-TestLocation 'Guangdong' 'Shenzhen' 'Futian'
Clear-ActiveWeatherModelForLocationChange
$requestB = Start-WeatherRequestContext
$resultBFail = Resolve-WeatherRequestFailure -Request $requestB -ErrorMessage 'simulated B failure'
Assert-Equal 'NoCache' $resultBFail.Status 'scenario A B failure has no B cache'
Assert-Equal $false $resultBFail.UseCache 'scenario A B failure does not use A cache'
Assert-Equal $null $script:LatestWeatherModel 'scenario A B failure clears active old model'
Assert-Equal (Get-SelectedLocationKey) $resultBFail.LocationKey 'scenario A error state belongs to B location key'
Assert-True ((Get-WeatherAlertInfo -Snapshot $null).Key -ne 'ThunderstormAlert') 'scenario A B failure does not retain A alert'

Reset-TestWeatherRequestState
Use-TestLocation 'Guangdong' 'Shenzhen' 'Longhua'
$requestA = Start-WeatherRequestContext
Resolve-WeatherRequestSuccess -Request $requestA -Model (New-TestWeatherModel -TemperatureC 11.1 -WeatherCode 0 -RainMm 0) -FetchedAt ([datetime]'2026-06-17T10:02:00') | Out-Null
$requestARefresh = Start-WeatherRequestContext
$resultARefreshFail = Resolve-WeatherRequestFailure -Request $requestARefresh -ErrorMessage 'simulated A refresh failure'
$snapshotARefresh = Get-WeatherSnapshotFromModel -Model $resultARefreshFail.Model -SlotKey 'Now'
Assert-Equal 'Cache' $resultARefreshFail.Status 'scenario B same-location failure uses cache'
Assert-Equal $true $resultARefreshFail.UseCache 'scenario B cache fallback marked'
Assert-Equal 11.1 $snapshotARefresh.TemperatureC 'scenario B cache fallback keeps A value'
Assert-Equal $true $snapshotARefresh.IsCacheData 'scenario B snapshot identifies cached data'

Reset-TestWeatherRequestState
Use-TestLocation 'Guangdong' 'Shenzhen' 'Futian'
$slowBRequest = Start-WeatherRequestContext
Use-TestLocation 'Beijing' 'Beijing' 'Chaoyang'
Clear-ActiveWeatherModelForLocationChange
$fastCRequest = Start-WeatherRequestContext
$fastCResult = Resolve-WeatherRequestSuccess -Request $fastCRequest -Model (New-TestWeatherModel -TemperatureC 33.3 -WeatherCode 0 -RainMm 0) -FetchedAt ([datetime]'2026-06-17T10:03:00')
$lateBResult = Resolve-WeatherRequestSuccess -Request $slowBRequest -Model (New-TestWeatherModel -TemperatureC 22.2 -WeatherCode 61 -RainMm 0.5) -FetchedAt ([datetime]'2026-06-17T10:04:00')
Assert-Equal $true $fastCResult.ShouldApply 'scenario C C request applies'
Assert-Equal $false $lateBResult.ShouldApply 'scenario C late B request is stale'
Assert-Equal 'StaleRequest' $lateBResult.Status 'scenario C late B marked stale'
Assert-Equal 33.3 $script:LatestWeatherModel.Current.TemperatureC 'scenario C late B does not overwrite C'

Reset-TestWeatherRequestState
Use-TestLocation 'Guangdong' 'Shenzhen' 'Longhua'
$requestA = Start-WeatherRequestContext
Resolve-WeatherRequestSuccess -Request $requestA -Model (New-TestWeatherModel -TemperatureC 11.1 -WeatherCode 95 -RainMm 1.0) | Out-Null
Use-TestLocation 'Guangdong' 'Shenzhen' 'Futian'
Clear-ActiveWeatherModelForLocationChange
$requestB = Start-WeatherRequestContext
$resultB = Resolve-WeatherRequestSuccess -Request $requestB -Model (New-TestWeatherModel -TemperatureC 22.2 -WeatherCode 0 -RainMm 0) -FetchedAt ([datetime]'2026-06-17T10:05:00')
$snapshotB = Get-WeatherSnapshotFromModel -Model $resultB.Model -SlotKey 'Now'
Assert-Equal 22.2 $snapshotB.TemperatureC 'scenario D B success shows B temperature'
Assert-Equal 'NoWeatherAlert' (Get-WeatherAlertInfo -Snapshot $snapshotB).Key 'scenario D B success clears A alert'

Reset-TestWeatherRequestState
Use-TestLocation 'Guangdong' 'Shenzhen' 'Longhua'
$requestA = Start-WeatherRequestContext
Resolve-WeatherRequestSuccess -Request $requestA -Model (New-TestWeatherModel -TemperatureC 11.1 -WeatherCode 95 -RainMm 1.0) | Out-Null
Use-TestLocation 'Guangdong' 'Shenzhen' 'Futian'
Clear-ActiveWeatherModelForLocationChange
$requestB = Start-WeatherRequestContext
$resultBNoCache = Resolve-WeatherRequestFailure -Request $requestB -ErrorMessage 'simulated B failure without cache'
Assert-Equal 'NoCache' $resultBNoCache.Status 'scenario E B failure has no cache'
Assert-Equal $null $resultBNoCache.Model 'scenario E B failure has no old model'
Assert-True ((Get-WeatherAlertInfo -Snapshot $null).Key -ne 'ThunderstormAlert') 'scenario E B failure does not retain A warning'

Reset-TestWeatherRequestState
$originalProvinces = $script:Provinces
try {
    $script:Provinces = @(
        New-Province 'SimilarProvince' 'Similar Province' 'Similar Province' @(
            New-City 'SimilarCity' 'Similar City' 'Similar City' 10.0 20.0 @(
                New-District 'CentralA' 'Central District' 'Central District' 10.1 20.1
                New-District 'CentralB' 'Central District' 'Central District' 10.2 20.2
            )
        )
    )
    Use-TestLocation 'SimilarProvince' 'SimilarCity' 'CentralA'
    $similarAKey = Get-SelectedLocationKey
    $similarARequest = Start-WeatherRequestContext
    Resolve-WeatherRequestSuccess -Request $similarARequest -Model (New-TestWeatherModel -TemperatureC 11.1 -WeatherCode 0 -RainMm 0) | Out-Null
    Use-TestLocation 'SimilarProvince' 'SimilarCity' 'CentralB'
    Clear-ActiveWeatherModelForLocationChange
    $similarBKey = Get-SelectedLocationKey
    $similarBRequest = Start-WeatherRequestContext
    $similarBFail = Resolve-WeatherRequestFailure -Request $similarBRequest -ErrorMessage 'similar display failure'
    Assert-True ($similarAKey -ne $similarBKey) 'scenario F similar display names have different location keys'
    Assert-Equal 'NoCache' $similarBFail.Status 'scenario F similar display names do not share cache'
    Assert-Equal $false $similarBFail.UseCache 'scenario F similar display names do not use wrong cache'
} finally {
    $script:Provinces = $originalProvinces
}
# Coordinate validation regressions
$zeroCoord = Test-LocationCoordinateValidity -Latitude 0 -Longitude 0 -ProvinceKey 'Guangdong' -CityKey 'Dongguan' -DistrictKey 'Guancheng' -LocationKey 'Guangdong|Dongguan|Guancheng'
Assert-Equal $false $zeroCoord.IsValid 'coordinate validation rejects 0,0'
Assert-Equal 'ZeroZero' $zeroCoord.ReasonCode 'coordinate validation 0,0 reason'
$nullCoord = Test-LocationCoordinateValidity -Latitude $null -Longitude $null -ProvinceKey 'Guangdong' -CityKey 'Dongguan' -DistrictKey 'Guancheng' -LocationKey 'Guangdong|Dongguan|Guancheng'
Assert-Equal $false $nullCoord.IsValid 'coordinate validation rejects null'
$nanCoord = Test-LocationCoordinateValidity -Latitude ([double]::NaN) -Longitude 113.7 -ProvinceKey 'Guangdong' -CityKey 'Dongguan' -DistrictKey 'Guancheng' -LocationKey 'Guangdong|Dongguan|Guancheng'
Assert-Equal $false $nanCoord.IsValid 'coordinate validation rejects NaN'
$infCoord = Test-LocationCoordinateValidity -Latitude 23.0 -Longitude ([double]::PositiveInfinity) -ProvinceKey 'Guangdong' -CityKey 'Dongguan' -DistrictKey 'Guancheng' -LocationKey 'Guangdong|Dongguan|Guancheng'
Assert-Equal $false $infCoord.IsValid 'coordinate validation rejects Infinity'
$swappedCoord = Test-LocationCoordinateValidity -Latitude 113.751765 -Longitude 23.020536 -ProvinceKey 'Guangdong' -CityKey 'Dongguan' -DistrictKey 'Guancheng' -LocationKey 'Guangdong|Dongguan|Guancheng'
Assert-Equal $false $swappedCoord.IsValid 'coordinate validation rejects swapped China coordinate'
Use-TestLocation 'Guangdong' 'Dongguan' 'Guancheng'
$guanchengLocation = Get-SelectedWeatherLocation
Assert-Equal 23.020536 $guanchengLocation.Lat 'Guancheng coordinate latitude is explicit city fallback'
Assert-Equal 113.751765 $guanchengLocation.Lon 'Guancheng coordinate longitude is explicit city fallback'
Assert-Equal 'City' $guanchengLocation.CoordinatePrecision 'Guancheng coordinate precision is city-level'
Assert-Equal $true $guanchengLocation.IsApproximateCoordinate 'Guancheng coordinate is marked approximate'
$requestCoordMatch = Test-LocationCoordinateValidity -Latitude $guanchengLocation.Lat -Longitude $guanchengLocation.Lon -ProvinceKey 'Guangdong' -CityKey 'Dongguan' -DistrictKey 'Guancheng' -LocationKey (Get-SelectedLocationKey) -RequestLatitude $guanchengLocation.Lat -RequestLongitude $guanchengLocation.Lon
Assert-Equal $true $requestCoordMatch.IsValid 'request coordinates match catalog coordinates'
$badRequestCoord = Test-LocationCoordinateValidity -Latitude 0 -Longitude 0 -ProvinceKey 'Guangdong' -CityKey 'Dongguan' -DistrictKey 'Guancheng' -LocationKey 'Guangdong|Dongguan|Guancheng' -RequestLatitude 23 -RequestLongitude 113
Assert-Equal $false $badRequestCoord.IsValid 'location title and key cannot pass invalid geography'
$originalProvincesForCoordinates = $script:Provinces
try {
    $script:Provinces = @(
        New-Province 'BadProvince' 'Bad Province' 'Bad Province' @(
            New-City 'BadCity' 'Bad City' 'Bad City' 23.0 113.0 @(
                New-District 'BadDistrict' 'Bad District' 'Bad District' 0 0
            )
        )
    )
    Use-TestLocation 'BadProvince' 'BadCity' 'BadDistrict'
    $fakeClient = [pscustomobject]@{ Called = $false }
    $fakeClient | Add-Member -MemberType ScriptMethod -Name DownloadString -Value { param([string]$Url) $this.Called = $true; '{}' }
    $script:Client = $fakeClient
    $thrown = $false
    try { Get-OpenMeteoForecastModel | Out-Null } catch { $thrown = ($_.Exception.Message -like 'LOCATION_DATA_FAIL:*') }
    Assert-Equal $true $thrown 'invalid coordinates throw LOCATION_DATA_FAIL before Open-Meteo parse'
    Assert-Equal $false $script:Client.Called 'invalid coordinates do not call network client'
} finally {
    $script:Provinces = $originalProvincesForCoordinates
}

# Near-term failure/cache semantics regressions
$script:Language = 'zh'
$nearUnavailable = Resolve-NearTermForecast -Model $null -Now $semanticNow
Assert-Equal (Tx 'NearTermUnavailable') $nearUnavailable.Text 'B failure without cache shows near-term unavailable'
$cacheCurrent = New-SemanticWeatherRecord -Time $semanticNow -WeatherCode 3 -RainMm 0 -PrecipitationMm 0 -CloudCoverPercent 96
$cacheFutureDry = New-SemanticWeatherRecord -Time ([datetime]'2026-06-26T15:00:00') -WeatherCode 3 -RainMm 0 -PrecipitationMm 0 -CloudCoverPercent 96
$cacheModel = New-SemanticWeatherModel -Current $cacheCurrent -Hourly @($cacheCurrent, $cacheFutureDry)
$cacheSnapshot = Get-WeatherSnapshotFromModel -Model $cacheModel -SlotKey 'Now' -Now $semanticNow
Assert-Equal (Tx 'NearTermNoHeavyRain') $cacheSnapshot.NearTermForecast 'successful future parse may show no near-term heavy rain'
$cachedNearText = Format-CachedNearTermForecastText -Text $cacheSnapshot.NearTermForecast -FetchedAt ([datetime]'2026-06-26T14:21:00')
Assert-True ($cachedNearText -match '14:21:00') 'same-region cache near-term text is explicitly cached with time'
Reset-TestWeatherRequestState
Use-TestLocation 'Guangdong' 'Shenzhen' 'Longhua'
$requestDryA = Start-WeatherRequestContext
Resolve-WeatherRequestSuccess -Request $requestDryA -Model $cacheModel -FetchedAt ([datetime]'2026-06-26T14:21:00') | Out-Null
Use-TestLocation 'Guangdong' 'Shenzhen' 'Futian'
Clear-ActiveWeatherModelForLocationChange
$requestFailB = Start-WeatherRequestContext
$resultFailB = Resolve-WeatherRequestFailure -Request $requestFailB -ErrorMessage 'simulated B fail no cache'
Assert-Equal 'NoCache' $resultFailB.Status 'B failure without same-region cache remains no-cache'
Assert-Equal $null $resultFailB.Model 'B failure without same-region cache has no stale near-term model'
Assert-True ((Resolve-NearTermForecast -Model $resultFailB.Model -Now $semanticNow).Text -ne (Tx 'NearTermNoHeavyRain')) 'B failure does not retain A no-heavy-rain near-term text'

$totalTests = $script:Passed + $script:Failed
Write-Host "Tests passed: $script:Passed"
Write-Host "TEST_SUMMARY Total=$totalTests Passed=$script:Passed Failed=$script:Failed Skipped=0"
