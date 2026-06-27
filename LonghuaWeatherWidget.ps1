param(
    [int]$RefreshSeconds = 60,
    [switch]$NoTopMost,
    [switch]$TestMode,
    [switch]$UiSmokeMode,
    [string]$UiFixture = 'A',
    [string]$UiSmokeOutput = $null,
    [int]$UiSmokeDelayMs = 0
)

$ErrorActionPreference = 'Stop'

function T {
    param([string]$Base64)

    try {
        return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Base64))
    } catch {
        return $Base64
    }
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not ('LonghuaWeatherTimeoutWebClient' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Net;

public sealed class LonghuaWeatherTimeoutWebClient : WebClient
{
    public int TimeoutMilliseconds { get; set; }

    public LonghuaWeatherTimeoutWebClient()
    {
        TimeoutMilliseconds = 3500;
    }

    protected override WebRequest GetWebRequest(Uri address)
    {
        WebRequest request = base.GetWebRequest(address);
        if (request != null)
        {
            request.Timeout = TimeoutMilliseconds;
            HttpWebRequest httpRequest = request as HttpWebRequest;
            if (httpRequest != null)
            {
                httpRequest.ReadWriteTimeout = TimeoutMilliseconds;
                httpRequest.KeepAlive = false;
            }
        }
        return request;
    }
}
'@
}

$script:ReduceMotion = $false
try {
    $script:ReduceMotion = -not [System.Windows.SystemParameters]::ClientAreaAnimation
} catch {
    $script:ReduceMotion = $false
}

function Get-ApplicationRoot {
    $candidates = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $candidates.Add($PSScriptRoot)
    }
    if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        $candidates.Add((Split-Path -Parent $PSCommandPath))
    }
    if ($null -ne $MyInvocation.MyCommand -and -not [string]::IsNullOrWhiteSpace($MyInvocation.MyCommand.Path)) {
        $candidates.Add((Split-Path -Parent $MyInvocation.MyCommand.Path))
    }
    try {
        $processPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if (-not [string]::IsNullOrWhiteSpace($processPath)) {
            $candidates.Add((Split-Path -Parent $processPath))
        }
    } catch {}
    $candidates.Add((Get-Location).Path)

    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Container)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }

    return (Get-Location).Path
}

$script:AppRoot = Get-ApplicationRoot
$script:SettingsPath = Join-Path $script:AppRoot 'LonghuaWeatherWidget.settings.json'
$script:UiSmokeMode = [bool]$UiSmokeMode
$script:UiFixture = if ([string]::IsNullOrWhiteSpace($UiFixture)) { 'A' } else { $UiFixture }
$script:UiSmokeOutput = $UiSmokeOutput
$script:UiSmokeDelayMs = if ($script:UiSmokeMode) { [Math]::Max(0, $UiSmokeDelayMs) } else { 0 }
if ($script:UiSmokeMode) {
    if ([string]::IsNullOrWhiteSpace($script:UiSmokeOutput)) {
        $script:UiSmokeOutput = Join-Path $script:AppRoot 'reports\ui-smoke'
    }
    if (-not (Test-Path -LiteralPath $script:UiSmokeOutput)) {
        New-Item -ItemType Directory -Path $script:UiSmokeOutput -Force | Out-Null
    }
    $script:SettingsPath = Join-Path $script:UiSmokeOutput 'LonghuaWeatherWidget.ui-smoke.settings.json'
}
$script:DefaultProvinceKey = 'Guangdong'
$script:DefaultCityKey = 'Shenzhen'
$script:DefaultDistrictKey = 'Longhua'
$script:Language = 'zh'
$script:SelectedProvinceKey = $script:DefaultProvinceKey
$script:SelectedCityKey = $script:DefaultCityKey
$script:SelectedDistrictKey = $script:DefaultDistrictKey
$script:RefreshSeconds = if (@(60, 3600, 86400) -contains $RefreshSeconds) { $RefreshSeconds } else { 60 }
$script:UpdatingControls = $false
$script:SettingsOpen = $false
$script:CurrentStatusKey = 'Loading'
$script:NextRefreshAt = (Get-Date).AddSeconds($script:RefreshSeconds)
$script:WeatherRequestTimeoutMs = 6000
$script:SelectedForecastSlotKey = 'Now'
$script:ForecastDayCount = 14
$script:ForecastHourCount = 336
$script:WindowMinHeight = 380
$script:WindowClosedHeight = 448
$script:WindowExpandedWidth = 386
$script:DrawerHandleHeight = 92
$script:WidgetBorderBackground = $null
$script:WidgetBorderEffect = $null
$script:WindowSettingsHeight = 656
$script:TopChromeButtonSize = 32
$script:TopChromeColumnWidth = 36
$script:UpdatingForecastControls = $false
$script:LatestWeatherModel = $null
$script:LatestWeatherLocationKey = $null
$script:LatestWeatherFetchedAt = $null
$script:LatestWeatherDataSource = $null
$script:LatestWeatherIsCacheData = $false
$script:WeatherModelCache = @{}
$script:WeatherRequestSequence = 0
$script:ActiveWeatherRequestId = 0
$script:ActiveWeatherRequestLocationKey = $null
$script:ThunderActive = $false
$script:DrawerEdge = $null
$script:DrawerExpanded = $true
$script:DrawerVisibleStrip = 28
$script:DrawerAnimationDurationMs = 260
$script:DrawerAnimationInProgress = $false
$script:DrawerAnimationToken = $null
$script:DrawerSnapThreshold = 28
$script:DrawerAdjusting = $false
$script:DrawerTop = $null
$script:DrawerScreenDeviceName = $null
$script:DraggingWindow = $false
$script:UiSmokeSelectionChangedCount = 0
$script:UiSmokeLastCommandId = ''

$script:CurrentFields = @(
    'temperature_2m',
    'relative_humidity_2m',
    'apparent_temperature',
    'is_day',
    'precipitation',
    'rain',
    'showers',
    'weather_code',
    'cloud_cover',
    'pressure_msl',
    'surface_pressure',
    'wind_speed_10m',
    'wind_direction_10m',
    'wind_gusts_10m'
) -join ','

$script:HourlyFields = @(
    'temperature_2m',
    'relative_humidity_2m',
    'dew_point_2m',
    'apparent_temperature',
    'precipitation_probability',
    'precipitation',
    'rain',
    'showers',
    'weather_code',
    'cloud_cover',
    'pressure_msl',
    'surface_pressure',
    'visibility',
    'wind_speed_10m',
    'wind_direction_10m',
    'wind_gusts_10m',
    'uv_index',
    'is_day'
) -join ','

$script:DailyFields = @(
    'weather_code',
    'temperature_2m_max',
    'temperature_2m_min',
    'apparent_temperature_max',
    'apparent_temperature_min',
    'sunrise',
    'sunset',
    'daylight_duration',
    'sunshine_duration',
    'uv_index_max',
    'precipitation_sum',
    'rain_sum',
    'precipitation_hours',
    'precipitation_probability_max',
    'wind_speed_10m_max',
    'wind_gusts_10m_max',
    'wind_direction_10m_dominant'
) -join ','

$script:ForecastSlotDefinitions = @(
    [pscustomobject]@{ Key = 'Now'; LabelKey = 'Now'; OffsetHours = 0; Kind = 'Current' },
    [pscustomobject]@{ Key = '+1h'; LabelKey = 'Plus1h'; OffsetHours = 1; Kind = 'Offset' },
    [pscustomobject]@{ Key = '+3h'; LabelKey = 'Plus3h'; OffsetHours = 3; Kind = 'Offset' },
    [pscustomobject]@{ Key = '+6h'; LabelKey = 'Plus6h'; OffsetHours = 6; Kind = 'Offset' },
    [pscustomobject]@{ Key = '+12h'; LabelKey = 'Plus12h'; OffsetHours = 12; Kind = 'Offset' },
    [pscustomobject]@{ Key = 'Tonight'; LabelKey = 'Tonight'; Kind = 'Tonight' },
    [pscustomobject]@{ Key = 'Tomorrow'; LabelKey = 'Tomorrow'; Kind = 'Tomorrow' }
)

function New-District {
    param(
        [string]$Key,
        [string]$En,
        [string]$Zh,
        [object]$Lat = $null,
        [object]$Lon = $null,
        [string]$CoordinateSource = 'LocalCatalog',
        [string]$CoordinatePrecision = '',
        [string]$CoordinateValidatedAt = '2026-06-26',
        [bool]$IsApproximateCoordinate = $false
    )

    if ([string]::IsNullOrWhiteSpace($CoordinatePrecision) -and $null -ne $Lat -and $null -ne $Lon) {
        $CoordinatePrecision = 'District'
    }

    [pscustomobject]@{
        Key = $Key
        En = $En
        Zh = $Zh
        Lat = $Lat
        Lon = $Lon
        CoordinateSource = $CoordinateSource
        CoordinatePrecision = $CoordinatePrecision
        CoordinateValidatedAt = $CoordinateValidatedAt
        IsApproximateCoordinate = $IsApproximateCoordinate
    }
}

function New-City {
    param(
        [string]$Key,
        [string]$En,
        [string]$Zh,
        [object]$Lat,
        [object]$Lon,
        [object[]]$Districts,
        [string]$CoordinateSource = 'LocalCatalog',
        [string]$CoordinatePrecision = 'City',
        [string]$CoordinateValidatedAt = '2026-06-26',
        [bool]$IsApproximateCoordinate = $false
    )

    [pscustomobject]@{
        Key = $Key
        En = $En
        Zh = $Zh
        Lat = $Lat
        Lon = $Lon
        Districts = $Districts
        CoordinateSource = $CoordinateSource
        CoordinatePrecision = $CoordinatePrecision
        CoordinateValidatedAt = $CoordinateValidatedAt
        IsApproximateCoordinate = $IsApproximateCoordinate
    }
}
function New-Province {
    param(
        [string]$Key,
        [string]$En,
        [string]$Zh,
        [object[]]$Cities
    )

    [pscustomobject]@{
        Key = $Key
        En = $En
        Zh = $Zh
        Cities = $Cities
    }
}

$script:Provinces = @(
    New-Province 'Guangdong' 'Guangdong' '5bm/5Lic55yB' @(
        New-City 'Shenzhen' 'Shenzhen' '5rex5Zyz' 22.543096 114.057865 @(
        New-District 'Longhua' 'Longhua' '6b6Z5Y2O5Yy6' 22.657383 114.016242
        New-District 'Nanshan' 'Nanshan' '5Y2X5bGx5Yy6' 22.531221 113.930475
        New-District 'Futian' 'Futian' '56aP55Sw5Yy6' 22.540922 114.050891
        New-District 'Luohu' 'Luohu' '572X5rmW5Yy6' 22.548389 114.131611
        New-District 'Baoan' 'Baoan' '5a6d5a6J5Yy6' 22.555259 113.884019
        New-District 'Longgang' 'Longgang' '6b6Z5bKX5Yy6' 22.720889 114.246899
        New-District 'Guangming' 'Guangming' '5YWJ5piO5Yy6' 22.748750 113.935900
        New-District 'Pingshan' 'Pingshan' '5Z2q5bGx5Yy6' 22.691750 114.346200
        New-District 'Yantian' 'Yantian' '55uQ55Sw5Yy6' 22.557000 114.236700
    )
        New-City 'Guangzhou' 'Guangzhou' '5bm/5bee' 23.129110 113.264385 @(
        New-District 'Tianhe' 'Tianhe' '5aSp5rKz5Yy6' 23.124630 113.361990
        New-District 'Yuexiu' 'Yuexiu' '6LaK56eA5Yy6' 23.129110 113.266800
        New-District 'Haizhu' 'Haizhu' '5rW354+g5Yy6' 23.083310 113.317200
        New-District 'Panyu' 'Panyu' '55Wq56a65Yy6' 22.937720 113.384100
        New-District 'Baiyun' 'Baiyun' '55m95LqR5Yy6' 23.159900 113.273200
    )
        New-City 'Dongguan' 'Dongguan' '5Lic6I6e' 23.020536 113.751765 @(
            New-District 'Nancheng' 'Nancheng' '5Y2X5Z+O' 23.020536 113.751765 'ProjectCityCoordinateFallback' 'City' '2026-06-26' $true
            New-District 'Songshanhu' 'Songshan Lake' '5p2+5bGx5rmW' 23.020536 113.751765 'ProjectCityCoordinateFallback' 'City' '2026-06-26' $true
            New-District 'Guancheng' 'Guancheng' '6I6e5Z+O' 23.020536 113.751765 'ProjectCityCoordinateFallback' 'City' '2026-06-26' $true
        )
    )
    New-Province 'Beijing' 'Beijing' '5YyX5Lqs5biC' @(
        New-City 'Beijing' 'Beijing' '5YyX5Lqs' 39.904200 116.407400 @(
        New-District 'Chaoyang' 'Chaoyang' '5pyd6Ziz5Yy6' 39.921900 116.443000
        New-District 'Haidian' 'Haidian' '5rW35reA5Yy6' 39.959300 116.298000
        New-District 'Dongcheng' 'Dongcheng' '5Lic5Z+O5Yy6' 39.928800 116.416000
        New-District 'Xicheng' 'Xicheng' '6KW/5Z+O5Yy6' 39.912300 116.365900
    )
    )
    New-Province 'Shanghai' 'Shanghai' '5LiK5rW35biC' @(
        New-City 'Shanghai' 'Shanghai' '5LiK5rW3' 31.230400 121.473700 @(
        New-District 'Pudong' 'Pudong New Area' '5rWm5Lic5paw5Yy6' 31.230400 121.544000
        New-District 'Huangpu' 'Huangpu' '6buE5rWm5Yy6' 31.231700 121.484600
        New-District 'Jingan' 'Jing''an' '6Z2Z5a6J5Yy6' 31.229900 121.448000
        New-District 'Xuhui' 'Xuhui' '5b6Q5rGH5Yy6' 31.188500 121.436500
    )
    )
    New-Province 'Zhejiang' 'Zhejiang' '5rWZ5rGf55yB' @(
        New-City 'Hangzhou' 'Hangzhou' '5p2t5bee' 30.274100 120.155100 @(
        New-District 'Xihu' 'Xihu' '6KW/5rmW5Yy6' 30.259600 120.130300
        New-District 'Yuhang' 'Yuhang' '5L2Z5p2t5Yy6' 30.421200 120.300600
        New-District 'Shangcheng' 'Shangcheng' '5LiK5Z+O5Yy6' 30.242600 120.169200
        New-District 'Binjiang' 'Binjiang' '5ruo5rGf5Yy6' 30.208400 120.212000
    )
    )
    New-Province 'Sichuan' 'Sichuan' '5Zub5bed55yB' @(
        New-City 'Chengdu' 'Chengdu' '5oiQ6YO9' 30.572800 104.066800 @(
        New-District 'Wuhou' 'Wuhou' '5q2m5L6v5Yy6' 30.642400 104.043400
        New-District 'Jinjiang' 'Jinjiang' '6ZSm5rGf5Yy6' 30.650900 104.083000
        New-District 'Qingyang' 'Qingyang' '6Z2S576K5Yy6' 30.674600 104.062000
        New-District 'Gaoxin' 'High-tech Zone' '6auY5paw5Yy6' 30.554000 104.066000
    )
    )
    New-Province 'Hubei' 'Hubei' '5rmW5YyX55yB' @(
        New-City 'Wuhan' 'Wuhan' '5q2m5rGJ' 30.592800 114.305500 @(
        New-District 'Wuchang' 'Wuchang' '5q2m5piM5Yy6' 30.553900 114.315900
        New-District 'Jianghan' 'Jianghan' '5rGf5rGJ5Yy6' 30.600100 114.270900
        New-District 'Hongshan' 'Hongshan' '5rSq5bGx5Yy6' 30.500600 114.343700
        New-District 'Hanyang' 'Hanyang' '5rGJ6Ziz5Yy6' 30.554300 114.218600
    )
    )
    New-Province 'Jiangsu' 'Jiangsu' '5rGf6IuP55yB' @(
        New-City 'Nanjing' 'Nanjing' '5Y2X5Lqs' 32.060300 118.796900 @(
        New-District 'Xuanwu' 'Xuanwu' '546E5q2m5Yy6' 32.050700 118.797900
        New-District 'Qinhuai' 'Qinhuai' '56em5reu5Yy6' 32.039200 118.794800
        New-District 'Jianye' 'Jianye' '5bu66YK65Yy6' 32.003500 118.731600
        New-District 'Gulou' 'Gulou' '6byT5qW85Yy6' 32.066700 118.769700
    )
        New-City 'Suzhou' 'Suzhou' '6IuP5bee' 31.298900 120.585300 @(
        New-District 'Gusu' 'Gusu' '5aeR6IuP5Yy6' 31.304100 120.623000
        New-District 'Wuzhong' 'Wuzhong' '5ZC05Lit5Yy6' 31.262600 120.631900
        New-District 'SIP' 'Industrial Park' '5bel5Lia5Zut5Yy6' 31.317900 120.704400
        New-District 'Kunshan' 'Kunshan' '5piG5bGx5biC' 31.385600 120.981800
    )
    )
    New-Province 'Shaanxi' 'Shaanxi' '6ZmV6KW/55yB' @(
        New-City 'Xian' 'Xi''an' '6KW/5a6J' 34.341600 108.939800 @(
        New-District 'Yanta' 'Yanta' '6ZuB5aGU5Yy6' 34.213400 108.942400
        New-District 'Beilin' 'Beilin' '56KR5p6X5Yy6' 34.251100 108.934300
        New-District 'Weiyang' 'Weiyang' '5pyq5aSu5Yy6' 34.308900 108.946000
        New-District 'Lianhu' 'Lianhu' '6I6y5rmW5Yy6' 34.267000 108.940000
    )
    )
)

if ($script:UiSmokeMode -and [string]$script:UiFixture -ne 'Live') {
    $script:Provinces = @(
        New-Province 'SmokeProvince' 'Test Province' '5rWL6K+V55yB' @(
            New-City 'SmokeCity' 'Test City' '5rWL6K+V5biC' 22.543096 114.057865 @(
                New-District 'SmokeA' 'Area A' 'QSDljLo=' 22.541 114.051
                New-District 'SmokeB' 'Area B' 'QiDljLo=' 22.542 114.052
                New-District 'SmokeC' 'Area C' 'QyDljLo=' 22.543 114.053
            )
        )
    )
    $script:DefaultProvinceKey = 'SmokeProvince'
    $script:DefaultCityKey = 'SmokeCity'
    $script:DefaultDistrictKey = 'SmokeA'
    $script:SelectedProvinceKey = $script:DefaultProvinceKey
    $script:SelectedCityKey = $script:DefaultCityKey
    $script:SelectedDistrictKey = $script:DefaultDistrictKey
}

$script:Text = @{
    Loading = @{ Zh = '5Yqg6L295Lit'; En = 'Loading' }
    Updating = @{ Zh = '5q2j5Zyo5pu05paw'; En = 'Updating' }
    Live = @{ Zh = '5b2T5YmN'; En = 'Current' }
    Offline = @{ Zh = '56a757q/'; En = 'Offline' }
    Weather = @{ Zh = '5aSp5rCU'; En = 'Weather' }
    Settings = @{ Zh = '6K6+572u'; En = 'Settings' }
    DrawerCollapse = @{ Zh = '5pS26LW3'; En = 'Collapse' }
    DrawerExpand = @{ Zh = '5bGV5byA'; En = 'Expand' }
    Location = @{ Zh = '5L2N572u'; En = 'Location' }
    Province = @{ Zh = '55yB'; En = 'Province' }
    City = @{ Zh = '5Z+O5biC'; En = 'City' }
    District = @{ Zh = '5Yy6'; En = 'District' }
    Language = @{ Zh = '6K+t6KiA'; En = 'Language' }
    SettingsControls = @{ Zh = '6K6+572u6YCJ6aG5'; En = 'Settings' }
    RefreshInterval = @{ Zh = '5Yi35paw6Ze06ZqU'; En = 'Refresh interval' }
    ForecastTime = @{ Zh = '6aKE5oql5pe26Ze0'; En = 'Forecast time' }
    StartTime = @{ Zh = '5byA5aeL5pe26Ze0'; En = 'Start time' }
    EndTime = @{ Zh = '57uT5p2f5pe26Ze0'; En = 'End time' }
    Chinese = @{ Zh = '5Lit5paH'; En = 'Chinese' }
    English = @{ Zh = 'RW5nbGlzaA=='; En = 'English' }
    AutoLocation = @{ Zh = '6Ieq5Yqo5a6a5L2N'; En = 'Auto' }
    Refresh = @{ Zh = '5Yi35paw'; En = 'Refresh' }
    Refresh1Minute = @{ Zh = 'MeWIhumSnw=='; En = '1 min' }
    Refresh1Hour = @{ Zh = 'MeWwj+aXtg=='; En = '1 hour' }
    Refresh1Day = @{ Zh = 'MeWkqQ=='; En = '1 day' }
    Temp = @{ Zh = '5rCU5rip'; En = 'Temp' }
    RainNow = @{ Zh = '5b2T5YmN6ZmN6Zuo'; En = 'Rain now' }
    TodayRain = @{ Zh = '5LuK5pel6ZmN6Zuo'; En = 'Today rain' }
    Pressure = @{ Zh = '5rCU5Y6L'; En = 'Pressure' }
    Humidity = @{ Zh = '5rm/5bqm'; En = 'Humidity' }
    Wind = @{ Zh = '6aOO6YCf'; En = 'Wind' }
    Feels = @{ Zh = '5L2T5oSf'; En = 'feels' }
    Probability = @{ Zh = '5qaC546H'; En = 'prob' }
    ForecastTimeline = @{ Zh = '6aKE5oql5pe26Ze0'; En = 'Forecast timeline' }
    Now = @{ Zh = '546w5Zyo'; En = 'Now' }
    Plus1h = @{ Zh = 'KzFo'; En = '+1h' }
    Plus3h = @{ Zh = 'KzNo'; En = '+3h' }
    Plus6h = @{ Zh = 'KzZo'; En = '+6h' }
    Plus12h = @{ Zh = 'KzEyaA=='; En = '+12h' }
    Tonight = @{ Zh = '5LuK5pma'; En = 'Tonight' }
    Tomorrow = @{ Zh = '5piO5aSp'; En = 'Tomorrow' }
    Forecast = @{ Zh = '6aKE5oql'; En = 'Forecast' }
    Rain = @{ Zh = '6ZmN5rC0'; En = 'Rain' }
    DayRain = @{ Zh = '5pel6ZmN5rC0'; En = 'Day rain' }
    Cloud = @{ Zh = '5LqR6YeP'; En = 'Cloud' }
    Gust = @{ Zh = '6Zi16aOO'; En = 'Gust' }
    UV = @{ Zh = '57Sr5aSW57q/'; En = 'UV' }
    DewPoint = @{ Zh = '6Zyy54K5'; En = 'Dew point' }
    Visibility = @{ Zh = '6IO96KeB5bqm'; En = 'Visibility' }
    MSLPressure = @{ Zh = '5rW35bmz6Z2i5rCU5Y6L'; En = 'MSL pressure' }
    SurfacePressure = @{ Zh = '5Zyw6Z2i5rCU5Y6L'; En = 'Surface pressure' }
    Daylight = @{ Zh = '55m95pi8'; En = 'Daylight' }
    Sunshine = @{ Zh = '5pel54Wn'; En = 'Sunshine' }
    Sunrise = @{ Zh = '5pel5Ye6'; En = 'Sunrise' }
    Sunset = @{ Zh = '5pel6JC9'; En = 'Sunset' }
    WindDirection = @{ Zh = '6aOO5ZCR'; En = 'Wind direction' }
    Updated = @{ Zh = '5bey5pu05paw'; En = 'Updated' }
    Source = @{ Zh = '5pWw5o2u5rqQ'; En = 'Source' }
    WeatherFailed = @{ Zh = '5aSp5rCU5pu05paw5aSx6LSl'; En = 'Weather update failed' }
    WeatherUnavailable = @{ Zh = '5aSp5rCU5pyN5Yqh5pqC5LiN5Y+v55So'; En = 'Weather service unavailable' }
    FetchingWeather = @{ Zh = '5q2j5Zyo6I635Y+W5aSp5rCU'; En = 'Fetching weather' }
    FetchingNearTerm = @{ Zh = '5q2j5Zyo6I635Y+W5Li06L+R6aKE5oql'; En = 'Fetching near-term forecast' }
    UpdatingFooter = @{ Zh = '5q2j5Zyo5pu05pawLi4u'; En = 'Updating...' }
    LocationCoordinatesUnavailable = @{ Zh = '5Zyw5Yy65Z2Q5qCH5pWw5o2u5LiN5Y+v55So'; En = 'Location coordinate data unavailable' }
    CoordinateUnavailable = @{ Zh = '5Zyw5Yy65Z2Q5qCH5pWw5o2u5LiN5Y+v55So'; En = 'Location coordinate data unavailable' }
    RefreshNow = @{ Zh = '56uL5Y2z5Yi35paw'; En = 'Refresh now' }
    Exit = @{ Zh = '6YCA5Ye6'; En = 'Exit' }
    RainingNow = @{ Zh = '5b2T5YmN6ZmN6Zuo'; En = 'Raining now' }
    RainedToday = @{ Zh = '5LuK5aSp5LiL6L+H6Zuo'; En = 'Rained today' }
    NoRain = @{ Zh = '5pqC5peg6Zuo'; En = 'No rain' }
    CurrentNoRain = @{ Zh = '5b2T5YmN5peg6ZmN6Zuo'; En = 'Current no rain' }
    CurrentUnavailable = @{ Zh = '5b2T5YmN5aSp5rCU5pqC5LiN5Y+v55So'; En = 'Current weather unavailable' }
    CurrentUncertain = @{ Zh = '5b2T5YmN5aSp5rCU5pqC5LiN56Gu5a6a'; En = 'Current weather uncertain' }
    CurrentHeavyRain = @{ Zh = '5q2j5Zyo5by66ZmN6Zuo'; En = 'Current heavy rain' }
    CurrentRainstorm = @{ Zh = '5q2j5Zyo5pq06Zuo'; En = 'Rainstorm now' }
    NearTermNoHeavyRain = @{ Zh = '5Li06L+R5pqC5peg5by66ZmN6Zuo'; En = 'No near-term heavy rain' }
    NearTermUnavailable = @{ Zh = '5Li06L+R6aKE5oql5pqC5LiN5Y+v55So'; En = 'Near-term forecast unavailable' }
    CachedNearTermNoHeavyRain = @{ Zh = '57yT5a2Y5Li06L+R6aKE5oql77ya5pqC5peg5by66ZmN6Zuo'; En = 'Cached near-term forecast: no heavy rain' }
    CachedNearTerm = @{ Zh = '57yT5a2Y5Li06L+R6aKE5oql77yaezB9'; En = 'Cached near-term forecast: {0}' }
    LastTry = @{ Zh = '5LiK5qyh5bCd6K+V'; En = 'Last try' }
    CachedData = @{ Zh = '57yT5a2Y5pWw5o2u'; En = 'Cached data' }
    AlertStatus = @{ Zh = '5o+Q56S6'; En = 'Tip' }
    ActiveAlert = @{ Zh = '5b2T5YmN5o+Q56S6'; En = 'Active tip' }
    NoWeatherAlert = @{ Zh = '5aSp5rCU5bmz56iz'; En = 'No active alert' }
    ThunderstormAlert = @{ Zh = '6Zu35pq06aOO6Zmp5o+Q56S6'; En = 'Thunderstorm risk' }
    HeavyRainAlert = @{ Zh = '5by66ZmN6Zuo6aOO6Zmp5o+Q56S6'; En = 'Heavy rain risk' }
    GaleAlert = @{ Zh = '5aSn6aOO6aOO6Zmp5o+Q56S6'; En = 'Gale risk' }
    TyphoonAlert = @{ Zh = '5Y+w6aOO6aOO6Zmp5o+Q56S6'; En = 'Typhoon risk' }
    OfflineAlert = @{ Zh = '56a757q/77ya5pi+56S65pyA6L+R5pWw5o2u'; En = 'Offline: showing last data' }
    ForecastThunderstorm = @{ Zh = '6aKE5oql6Zu35pq0'; En = 'Thunderstorm forecast' }
    ForecastHeavyRain = @{ Zh = '5by66ZmN6Zuo6aOO6Zmp5o+Q56S6'; En = 'Heavy rain risk' }
    ForecastGale = @{ Zh = '6aKE5oql5aSn6aOO'; En = 'Gale forecast' }
    ForecastTyphoon = @{ Zh = '6aKE5oql5Y+w6aOO'; En = 'Typhoon forecast' }
}

function Tx {
    param([string]$Key)

    $entry = $script:Text[$Key]
    if ($null -eq $entry) {
        return $Key
    }
    if ($script:Language -eq 'zh') {
        return (T $entry.Zh)
    }
    return $entry.En
}

function Get-WidgetTitle {
    if ($script:Language -eq 'en') {
        return 'Weather'
    }
    return (T '5L2g5LiA5p2l5bCx5piv5aW95aSp5rCU')
}

function Choice {
    param(
        [string]$Zh,
        [string]$En
    )

    if ($script:Language -eq 'zh') {
        return (T $Zh)
    }
    return $En
}

function Get-DisplayName {
    param([object]$Item)

    if ($script:Language -eq 'zh') {
        return (T $Item.Zh)
    }
    return $Item.En
}

function Set-DefaultLocation {
    $script:SelectedProvinceKey = $script:DefaultProvinceKey
    $script:SelectedCityKey = $script:DefaultCityKey
    $script:SelectedDistrictKey = $script:DefaultDistrictKey
}

function Get-ProvinceByKey {
    param([string]$Key)

    return $script:Provinces | Where-Object { $_.Key -eq $Key } | Select-Object -First 1
}

function Find-ProvinceForCityKey {
    param([string]$CityKey)

    foreach ($province in $script:Provinces) {
        $city = @($province.Cities) | Where-Object { $_.Key -eq $CityKey } | Select-Object -First 1
        if ($null -ne $city) {
            return $province
        }
    }
    return $null
}

function Test-LocationKeys {
    param(
        [string]$ProvinceKey,
        [string]$CityKey,
        [string]$DistrictKey
    )

    $province = Get-ProvinceByKey -Key $ProvinceKey
    if ($null -eq $province) {
        return $false
    }
    $city = @($province.Cities) | Where-Object { $_.Key -eq $CityKey } | Select-Object -First 1
    if ($null -eq $city) {
        return $false
    }
    $district = @($city.Districts) | Where-Object { $_.Key -eq $DistrictKey } | Select-Object -First 1
    return ($null -ne $district)
}

function Get-SelectedCity {
    $province = Get-SelectedProvince
    $city = @($province.Cities) | Where-Object { $_.Key -eq $script:SelectedCityKey } | Select-Object -First 1
    if ($null -eq $city) {
        $city = @($province.Cities)[0]
        $script:SelectedCityKey = $city.Key
    }
    return $city
}

function Get-SelectedProvince {
    $province = Get-ProvinceByKey -Key $script:SelectedProvinceKey
    if ($null -eq $province) {
        Set-DefaultLocation
        $province = Get-ProvinceByKey -Key $script:SelectedProvinceKey
    }
    if ($null -eq $province) {
        $province = $script:Provinces[0]
        $script:SelectedProvinceKey = $province.Key
    }
    return $province
}

function Get-SelectedDistrict {
    $city = Get-SelectedCity
    $district = @($city.Districts) | Where-Object { $_.Key -eq $script:SelectedDistrictKey } | Select-Object -First 1
    if ($null -eq $district) {
        $district = @($city.Districts)[0]
        $script:SelectedDistrictKey = $district.Key
    }
    return $district
}

function Get-LocationTitle {
    $province = Get-SelectedProvince
    $city = Get-SelectedCity
    $district = Get-SelectedDistrict
    return '{0} {1} {2}' -f (Get-DisplayName $province), (Get-DisplayName $city), (Get-DisplayName $district)
}

function Get-LocationLineText {
    return Get-LocationCardText
}

function Normalize-LocationKeyPart {
    param([object]$Value)

    if ($null -eq $Value) {
        return '_'
    }

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return '_'
    }

    return $text.Replace('|', '%7C')
}

function New-LocationKey {
    param(
        [object]$ProvinceKey,
        [object]$CityKey,
        [object]$DistrictKey
    )

    return '{0}|{1}|{2}' -f `
        (Normalize-LocationKeyPart $ProvinceKey),
        (Normalize-LocationKeyPart $CityKey),
        (Normalize-LocationKeyPart $DistrictKey)
}

function Get-SelectedLocationKey {
    $province = Get-SelectedProvince
    $city = Get-SelectedCity
    $district = Get-SelectedDistrict

    $provincePart = if (-not [string]::IsNullOrWhiteSpace([string]$province.Key)) { $province.Key } elseif (-not [string]::IsNullOrWhiteSpace([string]$script:SelectedProvinceKey)) { $script:SelectedProvinceKey } else { Get-DisplayName $province }
    $cityPart = if (-not [string]::IsNullOrWhiteSpace([string]$city.Key)) { $city.Key } elseif (-not [string]::IsNullOrWhiteSpace([string]$script:SelectedCityKey)) { $script:SelectedCityKey } else { Get-DisplayName $city }
    $districtPart = if (-not [string]::IsNullOrWhiteSpace([string]$district.Key)) { $district.Key } elseif (-not [string]::IsNullOrWhiteSpace([string]$script:SelectedDistrictKey)) { $script:SelectedDistrictKey } else { Get-DisplayName $district }

    return New-LocationKey -ProvinceKey $provincePart -CityKey $cityPart -DistrictKey $districtPart
}

function Get-LocationCardText {
    $province = Get-SelectedProvince
    $city = Get-SelectedCity
    $district = Get-SelectedDistrict
    return '{0}{1}{2}{1}{3}' -f (Get-DisplayName $province), (T 'IMK3IA=='), (Get-DisplayName $city), (Get-DisplayName $district)
}

function Get-LanguageCardText {
    if ($script:Language -eq 'zh') {
        return 'CN'
    }
    return 'EN'
}

function Reset-CityForSelectedProvince {
    $province = Get-SelectedProvince
    $defaultCity = @($province.Cities) | Where-Object { $_.Key -eq $script:DefaultCityKey } | Select-Object -First 1
    if ($province.Key -eq $script:DefaultProvinceKey -and $null -ne $defaultCity) {
        $script:SelectedCityKey = $defaultCity.Key
    } else {
        $script:SelectedCityKey = @($province.Cities)[0].Key
    }
    Reset-DistrictForSelectedCity
}

function Reset-DistrictForSelectedCity {
    $province = Get-SelectedProvince
    $city = Get-SelectedCity
    $defaultDistrict = @($city.Districts) | Where-Object { $_.Key -eq $script:DefaultDistrictKey } | Select-Object -First 1
    if ($province.Key -eq $script:DefaultProvinceKey -and $city.Key -eq $script:DefaultCityKey -and $null -ne $defaultDistrict) {
        $script:SelectedDistrictKey = $defaultDistrict.Key
    } else {
        $script:SelectedDistrictKey = @($city.Districts)[0].Key
    }
}

function Test-CoordinateValue {
    param([object]$Value)

    $converted = ConvertTo-CoordinateDouble -Value $Value
    return [bool]$converted.HasValue
}

function ConvertTo-CoordinateDouble {
    param([object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return [pscustomobject]@{ HasValue = $false; Value = $null; Reason = 'missing' }
    }

    try {
        $number = [double]$Value
    } catch {
        return [pscustomobject]@{ HasValue = $false; Value = $null; Reason = 'not numeric' }
    }

    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) {
        return [pscustomobject]@{ HasValue = $false; Value = $number; Reason = 'not finite' }
    }

    return [pscustomobject]@{ HasValue = $true; Value = $number; Reason = '' }
}

function Get-LocationCoordinateProperty {
    param(
        [object]$Location,
        [string]$Name,
        [object]$Default = $null
    )

    if ($null -eq $Location -or $null -eq $Location.PSObject.Properties[$Name]) {
        return $Default
    }

    return $Location.PSObject.Properties[$Name].Value
}

function Test-LocationCoordinateValidity {
    param(
        [object]$Latitude,
        [object]$Longitude,
        [string]$ProvinceKey = '',
        [string]$CityKey = '',
        [string]$DistrictKey = '',
        [string]$LocationKey = '',
        [object]$RequestLatitude = $null,
        [object]$RequestLongitude = $null,
        [string]$CoordinatePrecision = '',
        [string]$CoordinateSource = ''
    )

    $lat = ConvertTo-CoordinateDouble -Value $Latitude
    $lon = ConvertTo-CoordinateDouble -Value $Longitude
    $key = if ([string]::IsNullOrWhiteSpace($LocationKey)) { New-LocationKey -ProvinceKey $ProvinceKey -CityKey $CityKey -DistrictKey $DistrictKey } else { $LocationKey }

    $fail = {
        param([string]$Code, [string]$Message)
        $reason = switch ($Code) {
            'ZeroZero' { 'ZeroZeroCoordinate' }
            'LatitudeLongitudeSwapped' { 'LatitudeLongitudeSwapped' }
            'OutsideChinaBounds' { 'CoordinateOutsideChinaBounds' }
            'LatitudeOutOfRange' { 'CoordinateOutOfGlobalRange' }
            'LongitudeOutOfRange' { 'CoordinateOutOfGlobalRange' }
            default { 'MissingOrNonNumericCoordinate' }
        }
        return [pscustomobject]@{
            IsValid = $false
            ReasonCode = $Code
            Reason = $reason
            FailureReason = $Message
            IsZeroZero = ($Code -eq 'ZeroZero')
            IsSwapped = ($Code -eq 'LatitudeLongitudeSwapped')
            LocationKey = $key
            Latitude = $(if ($lat.HasValue) { $lat.Value } else { $null })
            Longitude = $(if ($lon.HasValue) { $lon.Value } else { $null })
            CoordinatePrecision = $CoordinatePrecision
            CoordinateSource = $CoordinateSource
        }
    }

    if (-not $lat.HasValue) { return & $fail 'LatitudeInvalid' ('latitude {0}' -f $lat.Reason) }
    if (-not $lon.HasValue) { return & $fail 'LongitudeInvalid' ('longitude {0}' -f $lon.Reason) }

    if ($lat.Value -ge 73 -and $lat.Value -le 135 -and $lon.Value -ge 18 -and $lon.Value -le 54) { return & $fail 'LatitudeLongitudeSwapped' ('latitude/longitude appear swapped: {0},{1}' -f $lat.Value, $lon.Value) }
    if ($lat.Value -lt -90 -or $lat.Value -gt 90) { return & $fail 'LatitudeOutOfRange' ('latitude out of range: {0}' -f $lat.Value) }
    if ($lon.Value -lt -180 -or $lon.Value -gt 180) { return & $fail 'LongitudeOutOfRange' ('longitude out of range: {0}' -f $lon.Value) }
    if ([Math]::Abs($lat.Value) -lt 0.000001 -and [Math]::Abs($lon.Value) -lt 0.000001) { return & $fail 'ZeroZero' 'latitude and longitude are both zero' }

    if ($lat.Value -lt 18 -or $lat.Value -gt 54 -or $lon.Value -lt 73 -or $lon.Value -gt 135) {
        return & $fail 'OutsideChinaBounds' ('coordinate outside China bounds: {0},{1}' -f $lat.Value, $lon.Value)
    }

    if ($null -ne $RequestLatitude -or $null -ne $RequestLongitude) {
        $requestLat = ConvertTo-CoordinateDouble -Value $RequestLatitude
        $requestLon = ConvertTo-CoordinateDouble -Value $RequestLongitude
        if (-not $requestLat.HasValue -or -not $requestLon.HasValue) { return & $fail 'RequestCoordinateInvalid' 'request coordinate missing or invalid' }
        if ([Math]::Abs($requestLat.Value - $lat.Value) -gt 0.000001 -or [Math]::Abs($requestLon.Value - $lon.Value) -gt 0.000001) {
            return & $fail 'RequestCoordinateMismatch' ('request coordinate {0},{1} does not match catalog {2},{3}' -f $requestLat.Value, $requestLon.Value, $lat.Value, $lon.Value)
        }
    }

    [pscustomobject]@{
        IsValid = $true
        ReasonCode = 'OK'
        Reason = ''
        FailureReason = ''
        IsZeroZero = $false
        IsSwapped = $false
        LocationKey = $key
        Latitude = $lat.Value
        Longitude = $lon.Value
        CoordinatePrecision = $CoordinatePrecision
        CoordinateSource = $CoordinateSource
    }
}

function Get-SelectedWeatherLocation {
    $province = Get-SelectedProvince
    $city = Get-SelectedCity
    $district = Get-SelectedDistrict
    $locationKey = Get-SelectedLocationKey
    $precision = [string](Get-LocationCoordinateProperty -Location $district -Name 'CoordinatePrecision' -Default 'District')
    $source = [string](Get-LocationCoordinateProperty -Location $district -Name 'CoordinateSource' -Default 'LocalCatalog')
    $validatedAt = [string](Get-LocationCoordinateProperty -Location $district -Name 'CoordinateValidatedAt' -Default '')
    $isApproximate = [bool](Get-LocationCoordinateProperty -Location $district -Name 'IsApproximateCoordinate' -Default $false)

    $validation = Test-LocationCoordinateValidity `
        -Latitude $district.Lat `
        -Longitude $district.Lon `
        -ProvinceKey $province.Key `
        -CityKey $city.Key `
        -DistrictKey $district.Key `
        -LocationKey $locationKey `
        -CoordinatePrecision $precision `
        -CoordinateSource $source

    if (-not $validation.IsValid) {
        throw ('LOCATION_DATA_FAIL: {0}: {1}' -f $locationKey, $validation.FailureReason)
    }

    return [pscustomobject]@{
        Lat = [double]$validation.Latitude
        Lon = [double]$validation.Longitude
        Level = $precision
        Label = Get-DisplayName $district
        LocationKey = $locationKey
        CoordinateSource = $source
        CoordinatePrecision = $precision
        CoordinateValidatedAt = $validatedAt
        IsApproximateCoordinate = $isApproximate
    }
}
function Load-Settings {
    if (-not (Test-Path -LiteralPath $script:SettingsPath)) {
        return
    }

    try {
        $settings = Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json
        if (@('zh', 'en') -contains $settings.Language) {
            $script:Language = $settings.Language
        }
        if (@(60, 3600, 86400) -contains [int]$settings.RefreshSeconds) {
            $script:RefreshSeconds = [int]$settings.RefreshSeconds
        }
        if ($settings.ProvinceKey) {
            $script:SelectedProvinceKey = [string]$settings.ProvinceKey
        }
        if ($settings.CityKey) {
            $script:SelectedCityKey = [string]$settings.CityKey
        }
        if ($settings.DistrictKey) {
            $script:SelectedDistrictKey = [string]$settings.DistrictKey
        }
        if (@('Left', 'Right') -contains [string]$settings.DrawerEdge) {
            $script:DrawerEdge = [string]$settings.DrawerEdge
        }
        $expandedProperty = $settings.PSObject.Properties['DrawerExpanded']
        if ($null -ne $expandedProperty -and $null -ne $expandedProperty.Value) {
            $script:DrawerExpanded = [bool]$expandedProperty.Value
        }
        $topProperty = $settings.PSObject.Properties['DrawerTop']
        if ($null -ne $topProperty -and $null -ne $topProperty.Value) {
            try {
                $script:DrawerTop = [double]$topProperty.Value
            } catch {
                $script:DrawerTop = $null
            }
        }
        if ($settings.DrawerScreenDeviceName) {
            $script:DrawerScreenDeviceName = [string]$settings.DrawerScreenDeviceName
        }
        if (-not $settings.ProvinceKey -and $settings.CityKey) {
            $province = Find-ProvinceForCityKey -CityKey ([string]$settings.CityKey)
            if ($null -ne $province) {
                $script:SelectedProvinceKey = $province.Key
            }
        }
        if (-not (Test-LocationKeys -ProvinceKey $script:SelectedProvinceKey -CityKey $script:SelectedCityKey -DistrictKey $script:SelectedDistrictKey)) {
            Set-DefaultLocation
        }
        Get-SelectedDistrict | Out-Null
    } catch {
        $script:Language = 'zh'
        Set-DefaultLocation
        $script:RefreshSeconds = 60
    }
}

function Save-Settings {
    $settings = [ordered]@{
        Language = $script:Language
        ProvinceKey = $script:SelectedProvinceKey
        CityKey = $script:SelectedCityKey
        DistrictKey = $script:SelectedDistrictKey
        RefreshSeconds = $script:RefreshSeconds
        DrawerEdge = $(if ($script:DrawerEdge) { $script:DrawerEdge } else { 'Left' })
        DrawerExpanded = [bool]$script:DrawerExpanded
        DrawerTop = $script:DrawerTop
        DrawerScreenDeviceName = $script:DrawerScreenDeviceName
        SavedAt = (Get-Date).ToString('s')
    }

    $settings | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
}

function Get-WeatherText {
    param([int]$Code)

    switch ($Code) {
        0 { Choice '5pm0' 'Clear' }
        1 { Choice '5aSn6Ie05pm05pyX' 'Mainly clear' }
        2 { Choice '5bGA6YOo5aSa5LqR' 'Partly cloudy' }
        3 { Choice '6Zi0' 'Overcast' }
        45 { Choice '6Zu+' 'Fog' }
        48 { Choice '6Zu+5YeH' 'Rime fog' }
        51 { Choice '5bCP5q+b5q+b6Zuo' 'Light drizzle' }
        53 { Choice '5q+b5q+b6Zuo' 'Drizzle' }
        55 { Choice '5aSn5q+b5q+b6Zuo' 'Heavy drizzle' }
        56 { Choice '5Ya76Zuo' 'Freezing drizzle' }
        57 { Choice '5aSn5Ya76Zuo' 'Heavy freezing drizzle' }
        61 { Choice '5bCP6Zuo' 'Light rain' }
        63 { Choice '5Lit6Zuo' 'Rain' }
        65 { Choice '5aSn6Zuo' 'Heavy rain' }
        66 { Choice '5Ya76Zuo' 'Freezing rain' }
        67 { Choice '5aSn5Ya76Zuo' 'Heavy freezing rain' }
        71 { Choice '5bCP6Zuq' 'Light snow' }
        73 { Choice '5Lit6Zuq' 'Snow' }
        75 { Choice '5aSn6Zuq' 'Heavy snow' }
        77 { Choice '6Zuq57KS' 'Snow grains' }
        80 { Choice '5bCP6Zi16Zuo' 'Light showers' }
        81 { Choice '6Zi16Zuo' 'Showers' }
        82 { Choice '5by66Zi16Zuo' 'Heavy showers' }
        85 { Choice '5bCP6Zi16Zuq' 'Light snow showers' }
        86 { Choice '6Zi16Zuq' 'Snow showers' }
        95 { Choice '6Zu35pq0' 'Thunderstorm' }
        96 { Choice '6Zu35pq05Ly05Yaw6Zu5' 'Thunderstorm with hail' }
        99 { Choice '5by66Zu35pq05Ly05Yaw6Zu5' 'Severe thunderstorm with hail' }
        default { 'Code {0}' -f $Code }
    }
}

function Get-WttrWeatherText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return (Choice '5b2T5YmN5aSp5rCU' 'Current weather')
    }

    switch -Regex ($Text) {
        'Thunder' { return (Choice '6Zu36Zuo' 'Thunderstorm') }
        'Torrential|Heavy rain' { return (Choice '5aSn6Zuo' 'Heavy rain') }
        'Light Rain Shower|Patchy rain|Light rain|Drizzle|Shower' { return (Choice '5bCP6Zuo' 'Light rain') }
        'Moderate rain|Rain' { return (Choice '6Zuo' 'Rain') }
        'Overcast' { return (Choice '6Zi0' 'Overcast') }
        'Cloudy' { return (Choice '5aSa5LqR' 'Cloudy') }
        'Sunny|Clear' { return (Choice '5pm0' 'Clear') }
        'Mist|Fog|Haze' { return (Choice '6Zy+6Zu+' 'Haze') }
        default { return $Text }
    }
}

function Test-TextContainsCjk {
    param([string]$Text)

    return (-not [string]::IsNullOrWhiteSpace($Text) -and $Text -match '[\u3400-\u9FFF\uF900-\uFAFF]')
}

function Get-ZhTextForKey {
    param([string]$Key)

    if ($script:Text.ContainsKey($Key)) {
        return T $script:Text[$Key].Zh
    }
    return ''
}

function Convert-WeatherDisplayTextForLanguage {
    param(
        [string]$Text,
        [string]$WarningLevel = ''
    )

    if ($script:Language -ne 'en' -or [string]::IsNullOrWhiteSpace($Text) -or -not (Test-TextContainsCjk -Text $Text)) {
        return $Text
    }

    $result = [string]$Text
    $replacements = @(
        @{ Zh = Get-ZhTextForKey 'CurrentNoRain'; En = Tx 'CurrentNoRain' },
        @{ Zh = Get-ZhTextForKey 'CurrentUnavailable'; En = Tx 'CurrentUnavailable' },
        @{ Zh = Get-ZhTextForKey 'CurrentUncertain'; En = Tx 'CurrentUncertain' },
        @{ Zh = Get-ZhTextForKey 'CurrentHeavyRain'; En = Tx 'CurrentHeavyRain' },
        @{ Zh = Get-ZhTextForKey 'CurrentRainstorm'; En = Tx 'CurrentRainstorm' },
        @{ Zh = Get-ZhTextForKey 'NearTermNoHeavyRain'; En = Tx 'NearTermNoHeavyRain' },
        @{ Zh = Get-ZhTextForKey 'NearTermUnavailable'; En = Tx 'NearTermUnavailable' },
        @{ Zh = Get-ZhTextForKey 'FetchingNearTerm'; En = Tx 'FetchingNearTerm' },
        @{ Zh = Get-ZhTextForKey 'FetchingWeather'; En = Tx 'FetchingWeather' },
        @{ Zh = Get-ZhTextForKey 'WeatherUnavailable'; En = Tx 'WeatherUnavailable' },
        @{ Zh = Get-ZhTextForKey 'NoWeatherAlert'; En = Tx 'NoWeatherAlert' },
        @{ Zh = Get-ZhTextForKey 'ThunderstormAlert'; En = Tx 'ThunderstormAlert' },
        @{ Zh = Get-ZhTextForKey 'HeavyRainAlert'; En = Tx 'HeavyRainAlert' },
        @{ Zh = Get-ZhTextForKey 'Updated'; En = Tx 'Updated' },
        @{ Zh = Get-ZhTextForKey 'Source'; En = Tx 'Source' },
        @{ Zh = Get-ZhTextForKey 'LastTry'; En = Tx 'LastTry' },
        @{ Zh = Get-ZhTextForKey 'UpdatingFooter'; En = Tx 'UpdatingFooter' },
        @{ Zh = T '5pm0'; En = 'Clear' },
        @{ Zh = T '5aSn6Ie05pm05pyX'; En = 'Mainly clear' },
        @{ Zh = T '5bGA6YOo5aSa5LqR'; En = 'Partly cloudy' },
        @{ Zh = T '5aSa5LqR'; En = 'Cloudy' },
        @{ Zh = T '6Zi0'; En = 'Overcast' },
        @{ Zh = T '6Zu+'; En = 'Fog' },
        @{ Zh = T '6Zu+5YeH'; En = 'Rime fog' },
        @{ Zh = T '5bCP5q+b5q+b6Zuo'; En = 'Light drizzle' },
        @{ Zh = T '5q+b5q+b6Zuo'; En = 'Drizzle' },
        @{ Zh = T '5aSn5q+b5q+b6Zuo'; En = 'Heavy drizzle' },
        @{ Zh = T '5bCP6Zuo'; En = 'Light rain' },
        @{ Zh = T '5Lit6Zuo'; En = 'Rain' },
        @{ Zh = T '5aSn6Zuo'; En = 'Heavy rain' },
        @{ Zh = T '6Zu35pq0'; En = 'Thunderstorm' },
        @{ Zh = T '6Zu36Zuo'; En = 'Thunderstorm' }
    )

    foreach ($entry in $replacements) {
        if (-not [string]::IsNullOrWhiteSpace([string]$entry.Zh)) {
            $result = $result.Replace([string]$entry.Zh, [string]$entry.En)
        }
    }

    if (-not (Test-TextContainsCjk -Text $result)) {
        return $result
    }

    if ($result -match [regex]::Escape((T '6Zu35pq0')) -or $result -match [regex]::Escape((T '6Zu36Zuo'))) {
        return Tx 'ThunderstormAlert'
    }

    if ($result -match [regex]::Escape((T '5by66ZmN6Zuo')) -or $result -match [regex]::Escape((T '5pq06Zuo'))) {
        if ([string]::IsNullOrWhiteSpace($WarningLevel) -or $WarningLevel -eq 'ModelTip') {
            return Tx 'HeavyRainAlert'
        }
        return 'Heavy rain alert'
    }

    if ($result -match [regex]::Escape((T '5aSn6aOO'))) {
        return Tx 'GaleAlert'
    }

    if ($result -match [regex]::Escape((T '5Y+w6aOO'))) {
        return Tx 'TyphoonAlert'
    }

    return 'Weather notice'
}

function Get-LocalizedWeatherText {
    param(
        [object]$WeatherText,
        [object]$WeatherCode
    )

    $text = [string]$WeatherText
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        $containsCjk = Test-TextContainsCjk -Text $text
        if ($null -ne $WeatherCode -and (($script:Language -eq 'en' -and $containsCjk) -or ($script:Language -eq 'zh' -and -not $containsCjk))) {
            return Get-WeatherText -Code ([int]$WeatherCode)
        }
        return Convert-WeatherDisplayTextForLanguage -Text $text
    }

    if ($null -ne $WeatherCode) {
        return Get-WeatherText -Code ([int]$WeatherCode)
    }

    return Choice '5b2T5YmN5aSp5rCU' 'Current weather'
}
function Format-Number {
    param(
        [object]$Value,
        [int]$Digits = 1
    )

    if ($null -eq $Value -or ([string]$Value) -eq '') {
        return '--'
    }

    $format = 'N{0}' -f $Digits
    return ([double]$Value).ToString($format)
}

function Format-Celsius {
    param(
        [object]$Value,
        [int]$Digits = 1
    )

    return '{0} {1}C' -f (Format-Number $Value $Digits), ([char]0x00B0)
}
function Get-RefreshLabel {
    param([int]$Seconds)

    switch ($Seconds) {
        86400 { Tx 'Refresh1Day' }
        3600 { Tx 'Refresh1Hour' }
        default { Tx 'Refresh1Minute' }
    }
}

function Format-CountdownText {
    param([int]$Seconds)

    $Seconds = [Math]::Max(0, $Seconds)
    $days = [Math]::Floor($Seconds / 86400)
    $hours = [Math]::Floor(($Seconds % 86400) / 3600)
    $minutes = [Math]::Floor(($Seconds % 3600) / 60)
    $remainingSeconds = $Seconds % 60

    if ($script:Language -eq 'zh') {
        if ($days -gt 0) {
            return '{0}{1}{2}{3}{4}' -f $days, (T '5aSp'), $hours, (T '5bCP5pe2'), (T '5ZCO5Yi35paw')
        }
        if ($hours -gt 0) {
            return '{0}{1}{2}{3}{4}' -f $hours, (T '5bCP5pe2'), $minutes, (T '5YiG'), (T '5ZCO5Yi35paw')
        }
        if ($minutes -gt 0) {
            return '{0}{1}{2}{3}' -f $minutes, (T '5YiG'), $remainingSeconds, (T '56eS5ZCO5Yi35paw')
        }
        return '{0}{1}' -f $remainingSeconds, (T '56eS5ZCO5Yi35paw')
    }

    if ($days -gt 0) {
        return 'Refresh in {0}d {1}h' -f $days, $hours
    }
    if ($hours -gt 0) {
        return 'Refresh in {0}h {1:00}m' -f $hours, $minutes
    }
    if ($minutes -gt 0) {
        return 'Refresh in {0}m {1:00}s' -f $minutes, $remainingSeconds
    }
    return 'Refresh in 00:{0:00}' -f $remainingSeconds
}

function Update-Countdown {
    if ($null -eq $countdownBlock) {
        return
    }

    $remaining = [int][Math]::Ceiling(($script:NextRefreshAt - (Get-Date)).TotalSeconds)
    $countdownBlock.Text = Format-CountdownText -Seconds $remaining
}

function Reset-RefreshCountdown {
    $script:NextRefreshAt = (Get-Date).AddSeconds($script:RefreshSeconds)
    Update-Countdown
}

function New-TextBlock {
    param(
        [string]$Text = '',
        [double]$FontSize = 12,
        [string]$Foreground = '#141413',
        [string]$FontWeight = 'Normal',
        [double]$Opacity = 1.0
    )

    $block = New-Object System.Windows.Controls.TextBlock
    $block.Text = $Text
    $block.FontFamily = 'Segoe UI Variable Text, Segoe UI, Microsoft YaHei UI'
    $block.FontSize = $FontSize
    $block.Foreground = $Foreground
    $block.FontWeight = $FontWeight
    $block.Opacity = $Opacity
    $block.TextWrapping = 'NoWrap'
    $block.VerticalAlignment = 'Center'
    return $block
}

function New-XamlObject {
    param([string]$Xaml)

    return [System.Windows.Markup.XamlReader]::Parse($Xaml)
}

function New-GlowEffect {
    param(
        [string]$Color = '#000000',
        [double]$BlurRadius = 18,
        [double]$ShadowDepth = 1,
        [double]$Opacity = 0.25
    )

    return New-Object System.Windows.Media.Effects.DropShadowEffect -Property @{
        BlurRadius = $BlurRadius
        ShadowDepth = $ShadowDepth
        Opacity = $Opacity
        Color = [System.Windows.Media.ColorConverter]::ConvertFromString($Color)
    }
}

function Set-BorderGlassHover {
    param(
        [System.Windows.Controls.Border]$Border,
        [string]$NormalBackground,
        [string]$HoverBackground,
        [string]$NormalBorder,
        [string]$HoverBorder,
        [string]$GlowColor = '#D97757',
        [double]$GlowOpacity = 0.18
    )

    $Border.Add_MouseEnter({
        $Border.Background = $HoverBackground
        $Border.BorderBrush = $HoverBorder
        $Border.Effect = New-GlowEffect -Color $GlowColor -BlurRadius 18 -ShadowDepth 1 -Opacity $GlowOpacity
    }.GetNewClosure())
    $Border.Add_MouseLeave({
        $Border.Background = $NormalBackground
        $Border.BorderBrush = $NormalBorder
        $Border.Effect = New-GlowEffect -Color '#F3DED5' -BlurRadius 10 -ShadowDepth 1 -Opacity 0.14
    }.GetNewClosure())
}

function Enable-MagneticHover {
    param(
        [System.Windows.Controls.Border]$Border,
        [double]$Strength = 3.0
    )

    $translate = New-Object System.Windows.Media.TranslateTransform
    $Border.RenderTransform = $translate
    $Border.RenderTransformOrigin = '0.5,0.5'
    $Border.Add_MouseMove({
        param($sender, $eventArgs)
        if ($script:ReduceMotion) {
            return
        }
        $point = $eventArgs.GetPosition($Border)
        $translate.X = (($point.X / [Math]::Max(1, $Border.ActualWidth)) - 0.5) * $Strength
        $translate.Y = (($point.Y / [Math]::Max(1, $Border.ActualHeight)) - 0.5) * $Strength
    }.GetNewClosure())
    $Border.Add_MouseLeave({
        $translate.X = 0
        $translate.Y = 0
    }.GetNewClosure())
}

function New-ComboBoxItemStyle {
    $xaml = @'
<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
       xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
       TargetType="{x:Type ComboBoxItem}">
    <Setter Property="MinHeight" Value="31"/>
    <Setter Property="Padding" Value="11,6,11,6"/>
    <Setter Property="Margin" Value="4,2"/>
    <Setter Property="Background" Value="#FFFAF9F5"/>
    <Setter Property="Foreground" Value="#141413"/>
    <Setter Property="BorderBrush" Value="#00FFFFFF"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
    <Setter Property="VerticalContentAlignment" Value="Center"/>
    <Setter Property="AutomationProperties.Name" Value="{Binding Display}"/>
    <Setter Property="Template">
        <Setter.Value>
            <ControlTemplate TargetType="{x:Type ComboBoxItem}">
                <Border x:Name="ItemBorder"
                        Background="{TemplateBinding Background}"
                        BorderBrush="{TemplateBinding BorderBrush}"
                        BorderThickness="{TemplateBinding BorderThickness}"
                        CornerRadius="8"
                        Padding="{TemplateBinding Padding}"
                        SnapsToDevicePixels="True">
                    <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                      VerticalAlignment="{TemplateBinding VerticalContentAlignment}"
                                      SnapsToDevicePixels="{TemplateBinding SnapsToDevicePixels}"/>
                </Border>
                <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="ItemBorder" Property="Background" Value="#FFF3DED5"/>
                        <Setter TargetName="ItemBorder" Property="BorderBrush" Value="#00FFFFFF"/>
                        <Setter Property="Foreground" Value="#141413"/>
                    </Trigger>
                    <Trigger Property="IsHighlighted" Value="True">
                        <Setter TargetName="ItemBorder" Property="Background" Value="#FFF3DED5"/>
                        <Setter TargetName="ItemBorder" Property="BorderBrush" Value="#00FFFFFF"/>
                        <Setter Property="Foreground" Value="#141413"/>
                    </Trigger>
                    <Trigger Property="IsSelected" Value="True">
                        <Setter TargetName="ItemBorder" Property="Background" Value="#D97757"/>
                        <Setter TargetName="ItemBorder" Property="BorderBrush" Value="#00FFFFFF"/>
                        <Setter Property="Foreground" Value="#FFFFFF"/>
                    </Trigger>
                    <Trigger Property="IsKeyboardFocusWithin" Value="True">
                        <Setter TargetName="ItemBorder" Property="BorderBrush" Value="#00FFFFFF"/>
                    </Trigger>
                </ControlTemplate.Triggers>
            </ControlTemplate>
        </Setter.Value>
    </Setter>
</Style>
'@

    return [System.Windows.Markup.XamlReader]::Parse($xaml)
}

function New-ComboBoxStyle {
    $xaml = @'
<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
       xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
       TargetType="{x:Type ComboBox}">
    <Setter Property="SnapsToDevicePixels" Value="True"/>
    <Setter Property="OverridesDefaultStyle" Value="True"/>
    <Setter Property="Foreground" Value="#141413"/>
    <Setter Property="Background" Value="#FFFAF9F5"/>
    <Setter Property="BorderBrush" Value="#00FFFFFF"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="Padding" Value="10,3,32,3"/>
    <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Disabled"/>
    <Setter Property="ScrollViewer.VerticalScrollBarVisibility" Value="Auto"/>
    <Setter Property="ScrollViewer.CanContentScroll" Value="True"/>
    <Setter Property="Template">
        <Setter.Value>
            <ControlTemplate TargetType="{x:Type ComboBox}">
                <Grid SnapsToDevicePixels="True">
                    <ToggleButton x:Name="ToggleButton"
                                  Background="{TemplateBinding Background}"
                                  BorderBrush="{TemplateBinding BorderBrush}"
                                  Focusable="False"
                                  ClickMode="Press"
                                  IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                        <ToggleButton.Template>
                            <ControlTemplate TargetType="{x:Type ToggleButton}">
                                <Border x:Name="Chrome"
                                        Background="{TemplateBinding Background}"
                                        BorderBrush="{TemplateBinding BorderBrush}"
                                        BorderThickness="1"
                                        CornerRadius="9"
                                        SnapsToDevicePixels="True">
                                    <Border.Effect>
                                        <DropShadowEffect BlurRadius="10"
                                                          ShadowDepth="1"
                                                          Opacity="0.22"
                                                          Color="#F3DED5"/>
                                    </Border.Effect>
                                    <Grid>
                                        <Border Margin="1"
                                                CornerRadius="8"
                                                BorderBrush="#00FFFFFF"
                                                BorderThickness="0"
                                                Background="#33F3F1EA"/>
                                        <Border Margin="2,1,2,0"
                                                Height="11"
                                                VerticalAlignment="Top"
                                                CornerRadius="7,7,4,4"
                                                 Background="#88F3F1EA"/>
                                        <Path x:Name="Arrow"
                                              Width="8"
                                              Height="5"
                                              HorizontalAlignment="Right"
                                              VerticalAlignment="Center"
                                              Margin="0,0,11,0"
                                              Data="M 0 0 L 4 5 L 8 0 Z"
                                               Fill="#6F6B60"/>
                                    </Grid>
                                </Border>
                                <ControlTemplate.Triggers>
                                    <Trigger Property="IsMouseOver" Value="True">
                                        <Setter TargetName="Chrome" Property="Background" Value="#FFF3DED5"/>
                                        <Setter TargetName="Chrome" Property="BorderBrush" Value="#00FFFFFF"/>
                                        <Setter TargetName="Arrow" Property="Fill" Value="#6F6B60"/>
                                    </Trigger>
                                    <Trigger Property="IsChecked" Value="True">
                                        <Setter TargetName="Chrome" Property="Background" Value="#FFF3DED5"/>
                                        <Setter TargetName="Chrome" Property="BorderBrush" Value="#00FFFFFF"/>
                                        <Setter TargetName="Arrow" Property="Fill" Value="#6F6B60"/>
                                    </Trigger>
                                    <Trigger Property="IsEnabled" Value="False">
                                        <Setter TargetName="Chrome" Property="Opacity" Value="0.55"/>
                                    </Trigger>
                                </ControlTemplate.Triggers>
                            </ControlTemplate>
                        </ToggleButton.Template>
                    </ToggleButton>
                    <TextBlock x:Name="SelectionText"
                               Margin="{TemplateBinding Padding}"
                               IsHitTestVisible="False"
                               HorizontalAlignment="Stretch"
                               VerticalAlignment="Center"
                               Text="{Binding SelectedItem.Display, RelativeSource={RelativeSource TemplatedParent}}"
                               TextTrimming="CharacterEllipsis"
                               ToolTip="{Binding SelectedItem.Display, RelativeSource={RelativeSource TemplatedParent}}"
                               AutomationProperties.Name="{Binding SelectedItem.Display, RelativeSource={RelativeSource TemplatedParent}}"
                               Foreground="{TemplateBinding Foreground}"/>
                    <Popup x:Name="PART_Popup"
                           AllowsTransparency="True"
                           Focusable="False"
                           IsOpen="{TemplateBinding IsDropDownOpen}"
                           Placement="Bottom"
                           PopupAnimation="None">
                        <Grid MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}"
                              MaxHeight="{TemplateBinding MaxDropDownHeight}">
                            <Border Background="#FFFAF9F5"
                                    BorderBrush="#00FFFFFF"
                                    BorderThickness="0"
                                    CornerRadius="11"
                                    Padding="4"
                                    SnapsToDevicePixels="True">
                                <Border.Effect>
                                    <DropShadowEffect BlurRadius="18"
                                                      ShadowDepth="6"
                                                      Opacity="0.48"
                                                      Color="#F3DED5"/>
                                </Border.Effect>
                                <ScrollViewer Margin="0"
                                              SnapsToDevicePixels="True">
                                    <ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/>
                                </ScrollViewer>
                            </Border>
                        </Grid>
                    </Popup>
                </Grid>
                <ControlTemplate.Triggers>
                    <Trigger Property="IsKeyboardFocusWithin" Value="True">
                        <Setter Property="BorderBrush" Value="#D97757"/>
                    </Trigger>
                    <Trigger Property="HasItems" Value="False">
                        <Setter TargetName="PART_Popup" Property="MinHeight" Value="44"/>
                    </Trigger>
                </ControlTemplate.Triggers>
            </ControlTemplate>
        </Setter.Value>
    </Setter>
    <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
            <Setter Property="Background" Value="#FFF3DED5"/>
            <Setter Property="BorderBrush" Value="#00FFFFFF"/>
            <Setter Property="Foreground" Value="#141413"/>
        </Trigger>
        <Trigger Property="IsKeyboardFocusWithin" Value="True">
            <Setter Property="Background" Value="#FFF3DED5"/>
            <Setter Property="BorderBrush" Value="#D97757"/>
            <Setter Property="Foreground" Value="#141413"/>
        </Trigger>
    </Style.Triggers>
</Style>
'@

    return [System.Windows.Markup.XamlReader]::Parse($xaml)
}

function New-ComboBoxItemTemplate {
    $xaml = @'
<DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
              xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <TextBlock Text="{Binding Display}"
               ToolTip="{Binding Display}"
               AutomationProperties.Name="{Binding Display}"
               VerticalAlignment="Center"/>
</DataTemplate>
'@
    return [System.Windows.Markup.XamlReader]::Parse($xaml)
}
function New-ComboBox {
    param(
        [double]$Width,
        [string]$Margin = '0,0,6,0'
    )

    $combo = New-Object System.Windows.Controls.ComboBox
    $combo.Width = $Width
    $combo.Height = 34
    $combo.Margin = $Margin
    $combo.FontFamily = 'Segoe UI'
    $combo.FontSize = 13
    $combo.SelectedValuePath = 'Key'
    $combo.SetValue([System.Windows.Controls.TextSearch]::TextPathProperty, 'Display')
    $combo.Background = '#FFFAF9F5'
    $combo.Foreground = '#141413'
    $combo.BorderBrush = '#00FFFFFF'
    $combo.Padding = '10,3,32,3'
    $combo.MaxDropDownHeight = 360
    $combo.IsTextSearchEnabled = $true
    $combo.IsTabStop = $true
    $combo.FocusVisualStyle = $null
    $combo.Style = New-ComboBoxStyle
    $combo.ItemContainerStyle = New-ComboBoxItemStyle
    $combo.ItemTemplate = New-ComboBoxItemTemplate
    return $combo
}

function Update-ComboSelectedMetadata {
    param([System.Windows.Controls.ComboBox]$Combo)
    if ($null -eq $Combo -or $null -eq $Combo.SelectedItem) { return }
    $display = [string](Get-PropertyValue -Object $Combo.SelectedItem -Name 'Display')
    if (-not [string]::IsNullOrWhiteSpace($display)) {
        $Combo.ToolTip = $display
        $Combo.SetValue([System.Windows.Automation.AutomationProperties]::HelpTextProperty, $display)
        $Combo.SetValue([System.Windows.Automation.AutomationProperties]::NameProperty, $display)
    }
}
function Select-ComboItem {
    param(
        [System.Windows.Controls.ComboBox]$Combo,
        [string]$Property,
        [object]$Value
    )

    for ($i = 0; $i -lt $Combo.Items.Count; $i++) {
        if ($Combo.Items[$i].$Property -eq $Value) {
            $Combo.SelectedIndex = $i
            Update-ComboSelectedMetadata -Combo $Combo
            return
        }
    }
    if ($Combo.Items.Count -gt 0) {
        $Combo.SelectedIndex = 0
        Update-ComboSelectedMetadata -Combo $Combo
    }
}

function Set-ControlAutomationName {
    param(
        [System.Windows.DependencyObject]$Control,
        [string]$Name
    )

    if ($null -ne $Control -and -not [string]::IsNullOrWhiteSpace($Name)) {
        $Control.SetValue([System.Windows.Automation.AutomationProperties]::NameProperty, $Name)
    }
}

function Set-ControlAutomationId {
    param(
        [System.Windows.DependencyObject]$Control,
        [string]$AutomationId
    )

    if ($null -ne $Control -and -not [string]::IsNullOrWhiteSpace($AutomationId)) {
        $Control.SetValue([System.Windows.Automation.AutomationProperties]::AutomationIdProperty, $AutomationId)
    }
}

function New-SettingsField {
    param(
        [string]$Label,
        [System.Windows.UIElement]$Control,
        [string]$AutomationName = $Label
    )

    $stack = New-Object System.Windows.Controls.StackPanel
    $labelBlock = New-TextBlock -Text $Label -FontSize 9.6 -Foreground '#6F6B60' -FontWeight 'SemiBold'
    $labelBlock.Margin = '1,0,0,3'
    $labelBlock.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    $stack.Children.Add($labelBlock) | Out-Null
    $stack.Children.Add($Control) | Out-Null
    Set-ControlAutomationName -Control $Control -Name $AutomationName

    return [pscustomobject]@{
        Panel = $stack
        Label = $labelBlock
        Control = $Control
    }
}

function New-Row {
    param(
        [string]$Label,
        [string]$Value
    )

    $card = New-Object System.Windows.Controls.Border
    $card.Height = 34
    $card.CornerRadius = 6
    $card.Padding = '8,3,8,3'
    $card.Background = '#00FFFFFF'
    $card.BorderBrush = '#00FFFFFF'
    $card.BorderThickness = 0
    $card.RenderTransform = New-Object System.Windows.Media.TranslateTransform
    $card.RenderTransformOrigin = '0.5,0.5'

    $stack = New-Object System.Windows.Controls.StackPanel
    $card.Child = $stack

    $labelBlock = New-TextBlock -Text $Label -FontSize 9.4 -Foreground '#6F6B60'
    $labelBlock.Margin = '0,0,0,0'
    $stack.Children.Add($labelBlock) | Out-Null

    $valueBlock = New-TextBlock -Text $Value -FontSize 12.4 -Foreground '#141413' -FontWeight 'SemiBold'
    $stack.Children.Add($valueBlock) | Out-Null

    $card.Add_MouseEnter({
        $card.Background = '#45FFFFFF'
        if (-not $script:ReduceMotion) {
            $card.RenderTransform.Y = -0.5
        }
    }.GetNewClosure())
    $card.Add_MouseLeave({
        $card.Background = '#00FFFFFF'
        if (-not $script:ReduceMotion) {
            $card.RenderTransform.Y = 0
        }
    }.GetNewClosure())

    return [pscustomobject]@{
        Grid = $card
        Label = $labelBlock
        Value = $valueBlock
    }
}

function New-InfoCard {
    param(
        [string]$Label,
        [string]$Value,
        [double]$Height = 48
    )

    $card = New-Object System.Windows.Controls.Border
    $card.Height = $Height
    $card.CornerRadius = 8
    $card.Padding = '9,5,9,5'
    $card.Background = '#FFFAF9F5'
    $card.BorderBrush = '#00FFFFFF'
    $card.BorderThickness = 1
    $card.Cursor = [System.Windows.Input.Cursors]::Hand
    $card.Focusable = $true
    $card.FocusVisualStyle = $null
    $card.SetValue([System.Windows.Input.KeyboardNavigation]::IsTabStopProperty, $true)
    $card.Effect = New-GlowEffect -Color '#F3DED5' -BlurRadius 9 -ShadowDepth 1 -Opacity 0.12
    $card.RenderTransform = New-Object System.Windows.Media.TranslateTransform
    $card.RenderTransformOrigin = '0.5,0.5'

    $stack = New-Object System.Windows.Controls.StackPanel
    $card.Child = $stack

    $labelBlock = New-TextBlock -Text $Label -FontSize 9.5 -Foreground '#8A867A'
    $labelBlock.Margin = '0,0,0,2'
    $stack.Children.Add($labelBlock) | Out-Null

    $valueBlock = New-TextBlock -Text $Value -FontSize 11.5 -Foreground '#141413' -FontWeight 'SemiBold'
    $valueBlock.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    $stack.Children.Add($valueBlock) | Out-Null

    $card.Add_MouseEnter({
        $card.Background = '#FFF3DED5'
        if (-not $script:ReduceMotion) {
            $card.RenderTransform.Y = -1
        }
    }.GetNewClosure())
    $card.Add_MouseLeave({
        $card.Background = '#FFFAF9F5'
        if (-not $card.IsKeyboardFocusWithin) { $card.BorderBrush = '#00FFFFFF' }
        if (-not $script:ReduceMotion) {
            $card.RenderTransform.Y = 0
        }
    }.GetNewClosure())
    $card.Add_GotKeyboardFocus({
        $card.Background = '#FFF3DED5'
        $card.BorderBrush = '#D97757'
    }.GetNewClosure())
    $card.Add_LostKeyboardFocus({
        $card.Background = '#FFFAF9F5'
        $card.BorderBrush = '#00FFFFFF'
    }.GetNewClosure())

    return [pscustomobject]@{
        Grid = $card
        Label = $labelBlock
        Value = $valueBlock
    }
}

function Set-ForecastChipVisual {
    param(
        [object]$Chip,
        [bool]$Selected
    )

    if ($Selected) {
        $Chip.Grid.Background = '#D97757'
        $Chip.Grid.BorderBrush = '#00FFFFFF'
        $Chip.Text.Foreground = '#FFFFFF'
        $Chip.Text.FontWeight = 'Bold'
        $Chip.Grid.Effect = New-GlowEffect -Color '#D97757' -BlurRadius 14 -ShadowDepth 1 -Opacity 0.22
    } else {
        $Chip.Grid.Background = '#FFFAF9F5'
        $Chip.Grid.BorderBrush = '#00FFFFFF'
        $Chip.Text.Foreground = '#6F6B60'
        $Chip.Text.FontWeight = 'SemiBold'
        $Chip.Grid.Effect = New-GlowEffect -Color '#F3DED5' -BlurRadius 8 -ShadowDepth 1 -Opacity 0.12
    }
}

function New-ForecastChip {
    param([object]$Definition)

    $scale = New-Object System.Windows.Media.ScaleTransform
    $translate = New-Object System.Windows.Media.TranslateTransform
    $transformGroup = New-Object System.Windows.Media.TransformGroup
    $transformGroup.Children.Add($scale) | Out-Null
    $transformGroup.Children.Add($translate) | Out-Null

    $chip = New-Object System.Windows.Controls.Border
    $chip.Width = 70
    $chip.Height = 28
    $chip.Margin = '0,0,5,5'
    $chip.CornerRadius = 9
    $chip.Padding = '8,3,8,3'
    $chip.BorderBrush = '#00FFFFFF'
    $chip.BorderThickness = 1
    $chip.Cursor = [System.Windows.Input.Cursors]::Hand
    $chip.Focusable = $true
    $chip.FocusVisualStyle = $null
    $chip.SetValue([System.Windows.Input.KeyboardNavigation]::IsTabStopProperty, $true)
    $chip.RenderTransform = $transformGroup
    $chip.RenderTransformOrigin = '0.5,0.5'

    $text = New-TextBlock -Text (Tx $Definition.LabelKey) -FontSize 11 -Foreground '#6F6B60' -FontWeight 'SemiBold'
    $text.HorizontalAlignment = 'Center'
    $chip.Child = $text

    $chipObject = [pscustomobject]@{
        Key = $Definition.Key
        LabelKey = $Definition.LabelKey
        Grid = $chip
        Text = $text
        Scale = $scale
        Translate = $translate
    }

    $chip.Add_MouseEnter({
        if (-not $script:ReduceMotion) {
            $chipObject.Scale.ScaleX = 1.03
            $chipObject.Scale.ScaleY = 1.03
        }
        if ($script:SelectedForecastSlotKey -ne $chipObject.Key) {
            $chipObject.Grid.Background = '#FFF3DED5'
            if (-not $chipObject.Grid.IsKeyboardFocusWithin) { $chipObject.Grid.BorderBrush = '#00FFFFFF' }
        }
    }.GetNewClosure())
    $chip.Add_MouseMove({
        param($sender, $eventArgs)
        if ($script:ReduceMotion) {
            return
        }
        $point = $eventArgs.GetPosition($chipObject.Grid)
        $chipObject.Translate.X = (($point.X / [Math]::Max(1, $chipObject.Grid.ActualWidth)) - 0.5) * 4
        $chipObject.Translate.Y = (($point.Y / [Math]::Max(1, $chipObject.Grid.ActualHeight)) - 0.5) * 3
    }.GetNewClosure())
    $chip.Add_MouseLeave({
        $chipObject.Scale.ScaleX = 1
        $chipObject.Scale.ScaleY = 1
        $chipObject.Translate.X = 0
        $chipObject.Translate.Y = 0
        Set-ForecastChipVisual -Chip $chipObject -Selected ($script:SelectedForecastSlotKey -eq $chipObject.Key)
    }.GetNewClosure())
    $chip.Add_GotKeyboardFocus({
        $chipObject.Grid.BorderBrush = '#D97757'
    }.GetNewClosure())
    $chip.Add_LostKeyboardFocus({
        Set-ForecastChipVisual -Chip $chipObject -Selected ($script:SelectedForecastSlotKey -eq $chipObject.Key)
    }.GetNewClosure())
    $chip.Add_MouseLeftButtonUp({
        param($sender, $eventArgs)
        $eventArgs.Handled = $true
        Set-ForecastSlot -SlotKey $chipObject.Key
    }.GetNewClosure())
    $chip.Add_KeyDown({
        param($sender, $eventArgs)
        if ($eventArgs.Key -eq [System.Windows.Input.Key]::Enter -or $eventArgs.Key -eq [System.Windows.Input.Key]::Space) {
            $eventArgs.Handled = $true
            Set-ForecastSlot -SlotKey $chipObject.Key
        }
    }.GetNewClosure())

    Set-ForecastChipVisual -Chip $chipObject -Selected ($script:SelectedForecastSlotKey -eq $chipObject.Key)
    return $chipObject
}

function Move-ToDefaultPosition {
    param([System.Windows.Window]$Window)

    if ($null -eq $Window) {
        return
    }

    $area = Get-WindowWorkingArea -Window $Window -PreferredDeviceName $script:DrawerScreenDeviceName
    $Window.Height = [Math]::Min($script:WindowClosedHeight, [Math]::Max($script:WindowMinHeight, $area.Height - 54))

    $defaultTop = $area.Top + 27
    $targetTop = if ($null -ne $script:DrawerTop) { [double]$script:DrawerTop } else { [double]$defaultTop }
    $Window.Top = Limit-Double -Value $targetTop -Min ($area.Top + 4) -Max ($area.Bottom - (Get-WindowActualHeight -Window $Window) - 4)

    if (@('Left', 'Right') -notcontains [string]$script:DrawerEdge) {
        $script:DrawerEdge = 'Left'
    }

    Set-DrawerEdgePosition -Window $Window -Expanded $script:DrawerExpanded
}

function Get-WindowActualWidth {
    param([System.Windows.Window]$Window)

    if ($null -eq $Window) {
        return [double]$script:WindowExpandedWidth
    }

    if ($Window.ActualWidth -gt 0) {
        return [double]$Window.ActualWidth
    }

    return [double]$Window.Width
}

function Get-WindowActualHeight {
    param([System.Windows.Window]$Window)

    if ($null -eq $Window) {
        return [double]$script:WindowClosedHeight
    }

    if ($Window.ActualHeight -gt 0) {
        return [double]$Window.ActualHeight
    }

    return [double]$Window.Height
}

function Get-WindowScreen {
    param(
        [System.Windows.Window]$Window,
        [string]$PreferredDeviceName = $null
    )

    if (-not [string]::IsNullOrWhiteSpace($PreferredDeviceName)) {
        foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
            if ($screen.DeviceName -eq $PreferredDeviceName) {
                return $screen
            }
        }
    }

    if ($null -ne $Window) {
        try {
            $helper = New-Object System.Windows.Interop.WindowInteropHelper -ArgumentList $Window
            if ($helper.Handle -ne [IntPtr]::Zero) {
                return [System.Windows.Forms.Screen]::FromHandle($helper.Handle)
            }
        } catch {
        }
    }

    return [System.Windows.Forms.Screen]::PrimaryScreen
}

function Convert-DeviceRectangleToDip {
    param(
        [System.Drawing.Rectangle]$Rectangle,
        [System.Windows.Window]$Window
    )

    try {
        if ($null -ne $Window) {
            $source = [System.Windows.PresentationSource]::FromVisual($Window)
            if ($null -ne $source -and $null -ne $source.CompositionTarget) {
                $matrix = $source.CompositionTarget.TransformFromDevice
                $topLeft = $matrix.Transform([System.Windows.Point]::new([double]$Rectangle.Left, [double]$Rectangle.Top))
                $bottomRight = $matrix.Transform([System.Windows.Point]::new([double]$Rectangle.Right, [double]$Rectangle.Bottom))
                return [pscustomobject]@{
                    Left = [double]$topLeft.X
                    Top = [double]$topLeft.Y
                    Right = [double]$bottomRight.X
                    Bottom = [double]$bottomRight.Y
                    Width = [double]($bottomRight.X - $topLeft.X)
                    Height = [double]($bottomRight.Y - $topLeft.Y)
                }
            }
        }
    } catch {
    }

    return [pscustomobject]@{
        Left = [double]$Rectangle.Left
        Top = [double]$Rectangle.Top
        Right = [double]$Rectangle.Right
        Bottom = [double]$Rectangle.Bottom
        Width = [double]$Rectangle.Width
        Height = [double]$Rectangle.Height
    }
}

function Get-WindowWorkingArea {
    param(
        [System.Windows.Window]$Window,
        [string]$PreferredDeviceName = $null
    )

    $screen = Get-WindowScreen -Window $Window -PreferredDeviceName $PreferredDeviceName
    return Convert-DeviceRectangleToDip -Rectangle $screen.WorkingArea -Window $Window
}

function Limit-Double {
    param(
        [double]$Value,
        [double]$Min,
        [double]$Max
    )

    if ($Max -lt $Min) {
        return $Min
    }

    return [Math]::Min($Max, [Math]::Max($Min, $Value))
}

function Get-WidgetTargetHeight {
    param([bool]$SettingsOpen)

    if ($SettingsOpen) {
        return [double]$script:WindowSettingsHeight
    }
    return [double]$script:WindowClosedHeight
}

function Get-DrawerVisibleStrip {
    return [Math]::Min(32, [Math]::Max(20, [double]$script:DrawerVisibleStrip))
}

function Get-NearestHorizontalDrawerEdge {
    param([System.Windows.Window]$Window)

    if ($null -eq $Window) {
        return 'Left'
    }

    $area = Get-WindowWorkingArea -Window $Window
    $width = Get-WindowActualWidth -Window $Window
    $centerX = $Window.Left + ($width / 2)
    $leftDistance = [Math]::Abs($centerX - $area.Left)
    $rightDistance = [Math]::Abs($area.Right - $centerX)

    if ($leftDistance -le $rightDistance) {
        return 'Left'
    }
    return 'Right'
}

function Get-DrawerTargetLeft {
    param(
        [System.Windows.Window]$Window,
        [object]$Area,
        [bool]$Expanded
    )

    $width = Get-WindowActualWidth -Window $Window
    $gap = 4
    $strip = Get-DrawerVisibleStrip

    if ($script:DrawerEdge -eq 'Right') {
        if ($Expanded) {
            return [double]($Area.Right - $width - $gap)
        }
        return [double]($Area.Right - $strip)
    }

    if ($Expanded) {
        return [double]($Area.Left + $gap)
    }
    return [double]($Area.Left - $width + $strip)
}

function Update-DrawerWindowState {
    param([System.Windows.Window]$Window)

    if ($null -eq $Window) {
        return
    }

    $script:DrawerTop = [double]$Window.Top
    try {
        $screen = Get-WindowScreen -Window $Window
        if ($null -ne $screen) {
            $script:DrawerScreenDeviceName = [string]$screen.DeviceName
        }
    } catch {
    }
}

function Set-DrawerCollapsedVisualState {
    param(
        [System.Windows.Window]$Window,
        [bool]$Collapsed
    )

    if ($null -eq $Window) {
        return
    }

    if ($Collapsed) {
        $Window.Width = [double](Get-DrawerVisibleStrip)
        $Window.Height = [double]$script:DrawerHandleHeight
        if ($null -ne $border) {
            $border.Padding = '0'
            $border.CornerRadius = 0
            $border.Background = 'Transparent'
            $border.BorderBrush = '#00FFFFFF'
            $border.BorderThickness = 0
            $border.Effect = $null
        }
        if ($null -ne $scrollViewer) { $scrollViewer.Visibility = [System.Windows.Visibility]::Collapsed }
        if ($null -ne $panelGlow) { $panelGlow.Visibility = [System.Windows.Visibility]::Collapsed }
        if ($null -ne $panelSheen) { $panelSheen.Visibility = [System.Windows.Visibility]::Collapsed }
        if ($null -ne $rainLayer) { $rainLayer.Visibility = [System.Windows.Visibility]::Collapsed }
        if ($null -ne $lightningLayer) { $lightningLayer.Visibility = [System.Windows.Visibility]::Collapsed }
        return
    }

    $Window.Width = [double]$script:WindowExpandedWidth
    $area = Get-WindowWorkingArea -Window $Window
    $targetHeight = Get-WidgetTargetHeight -SettingsOpen $script:SettingsOpen
    $targetHeight = [Math]::Min($targetHeight, [Math]::Max([double]$script:WindowMinHeight, [double]$area.Height - 54))
    $Window.Height = $targetHeight
    if ($null -ne $border) {
        $border.Padding = '12'
        $border.CornerRadius = 14
        if ($null -ne $script:WidgetBorderBackground) { $border.Background = $script:WidgetBorderBackground }
        if ($null -ne $script:WidgetBorderEffect) { $border.Effect = $script:WidgetBorderEffect }
    }
    if ($null -ne $scrollViewer) { $scrollViewer.Visibility = [System.Windows.Visibility]::Visible }
    if ($null -ne $panelGlow) { $panelGlow.Visibility = [System.Windows.Visibility]::Visible }
    if ($null -ne $panelSheen) { $panelSheen.Visibility = [System.Windows.Visibility]::Visible }
}
function Update-DrawerHandleVisual {
    if ($null -eq $drawerHandle) {
        return
    }

    $isCollapsed = (@('Left', 'Right') -contains [string]$script:DrawerEdge) -and (-not $script:DrawerExpanded)
    $drawerHandle.Visibility = if ($isCollapsed) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    $drawerHandle.ToolTip = Tx 'DrawerExpand'

    if ($script:DrawerEdge -eq 'Right') {
        $drawerHandle.HorizontalAlignment = 'Left'
        $drawerHandle.CornerRadius = '12,0,0,12'
        $drawerHandleLineA.X1 = 15
        $drawerHandleLineA.Y1 = 10
        $drawerHandleLineA.X2 = 8
        $drawerHandleLineA.Y2 = 17
        $drawerHandleLineB.X1 = 15
        $drawerHandleLineB.Y1 = 24
        $drawerHandleLineB.X2 = 8
        $drawerHandleLineB.Y2 = 17
    } else {
        $drawerHandle.HorizontalAlignment = 'Right'
        $drawerHandle.CornerRadius = '0,12,12,0'
        $drawerHandleLineA.X1 = 8
        $drawerHandleLineA.Y1 = 10
        $drawerHandleLineA.X2 = 15
        $drawerHandleLineA.Y2 = 17
        $drawerHandleLineB.X1 = 8
        $drawerHandleLineB.Y1 = 24
        $drawerHandleLineB.X2 = 15
        $drawerHandleLineB.Y2 = 17
    }
}

function Start-DrawerLeftAnimation {
    param(
        [System.Windows.Window]$Window,
        [double]$TargetLeft,
        [bool]$Persist
    )

    if ($null -eq $Window) {
        return
    }

    $currentLeft = [double]$Window.GetValue([System.Windows.Window]::LeftProperty)
    $Window.BeginAnimation([System.Windows.Window]::LeftProperty, $null)
    $Window.Left = $currentLeft

    if ($script:ReduceMotion -or [Math]::Abs($currentLeft - $TargetLeft) -lt 0.5) {
        $Window.Left = $TargetLeft
        $script:DrawerAnimationInProgress = $false
        $script:DrawerAnimationToken = $null
        Update-DrawerWindowState -Window $Window
        Update-DrawerHandleVisual
        if ($Persist) {
            Save-Settings
        }
        return
    }

    $script:DrawerAnimationInProgress = $true
    $animationToken = [Guid]::NewGuid().ToString('n')
    $script:DrawerAnimationToken = $animationToken

    $animation = New-Object System.Windows.Media.Animation.DoubleAnimation
    $animation.From = $currentLeft
    $animation.To = $TargetLeft
    $animation.Duration = New-Object System.Windows.Duration -ArgumentList ([TimeSpan]::FromMilliseconds([double]$script:DrawerAnimationDurationMs))
    $animation.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $animation.EasingFunction = $ease
    $animation.Add_Completed({
        if ($script:DrawerAnimationToken -ne $animationToken) {
            return
        }
        $Window.BeginAnimation([System.Windows.Window]::LeftProperty, $null)
        $Window.Left = $TargetLeft
        $script:DrawerAnimationInProgress = $false
        $script:DrawerAnimationToken = $null
        Update-DrawerWindowState -Window $Window
        Update-DrawerHandleVisual
        if ($Persist) {
            Save-Settings
        }
    }.GetNewClosure())

    $Window.BeginAnimation(
        [System.Windows.Window]::LeftProperty,
        $animation,
        [System.Windows.Media.Animation.HandoffBehavior]::SnapshotAndReplace
    )
}

function Set-WidgetWindowHeight {
    param(
        [System.Windows.Window]$Window,
        [bool]$SettingsOpen
    )

    if ($null -eq $Window) {
        return
    }

    $area = Get-WindowWorkingArea -Window $Window
    $targetHeight = Get-WidgetTargetHeight -SettingsOpen $SettingsOpen
    $targetHeight = [Math]::Min($targetHeight, [Math]::Max([double]$script:WindowMinHeight, [double]$area.Height - 54))
    $Window.Height = $targetHeight

    if (@('Left', 'Right') -contains [string]$script:DrawerEdge) {
        Set-DrawerEdgePosition -Window $Window -Expanded $script:DrawerExpanded
        return
    }

    $gap = 4
    $width = Get-WindowActualWidth -Window $Window
    $Window.Top = Limit-Double -Value $Window.Top -Min ($area.Top + $gap) -Max ($area.Bottom - $targetHeight - $gap)
    $Window.Left = Limit-Double -Value $Window.Left -Min ($area.Left + $gap) -Max ($area.Right - $width - $gap)
}

function Set-DrawerEdgePosition {
    param(
        [System.Windows.Window]$Window,
        [bool]$Expanded,
        [switch]$Animate,
        [switch]$Persist
    )

    if ($null -eq $Window) {
        return
    }

    if (@('Left', 'Right') -notcontains [string]$script:DrawerEdge) {
        $script:DrawerEdge = Get-NearestHorizontalDrawerEdge -Window $Window
    }
    if (-not $Expanded -and $script:DrawerExpanded -and (Get-WindowActualWidth -Window $Window) -gt 100) {
        $script:WindowExpandedWidth = [double](Get-WindowActualWidth -Window $Window)
    }

    Set-DrawerCollapsedVisualState -Window $Window -Collapsed (-not $Expanded)
    $area = Get-WindowWorkingArea -Window $Window
    $height = Get-WindowActualHeight -Window $Window
    $gap = 4
    $Window.Top = Limit-Double -Value $Window.Top -Min ($area.Top + $gap) -Max ($area.Bottom - $height - $gap)
    $targetLeft = Get-DrawerTargetLeft -Window $Window -Area $area -Expanded $Expanded

    $script:DrawerAdjusting = $true
    try {
        $script:DrawerExpanded = $Expanded
        Update-DrawerHandleVisual
        if ($Animate) {
            Start-DrawerLeftAnimation -Window $Window -TargetLeft $targetLeft -Persist ([bool]$Persist)
        } else {
            $script:DrawerAnimationToken = $null
            $Window.BeginAnimation([System.Windows.Window]::LeftProperty, $null)
            $Window.Left = $targetLeft
            $script:DrawerAnimationInProgress = $false
            Update-DrawerWindowState -Window $Window
            if ($Persist) {
                Save-Settings
            }
        }
    } finally {
        $script:DrawerAdjusting = $false
    }
}

function Set-WindowDrawerState {
    param(
        [System.Windows.Window]$Window,
        [string]$Edge,
        [bool]$Expanded,
        [switch]$Animate,
        [switch]$Persist
    )

    if (@('Left', 'Right') -notcontains [string]$Edge) {
        $Edge = Get-NearestHorizontalDrawerEdge -Window $Window
    }

    $script:DrawerEdge = $Edge
    Set-DrawerEdgePosition -Window $Window -Expanded $Expanded -Animate:$Animate -Persist:$Persist
}

function Update-DrawerDockAfterDrag {
    param([System.Windows.Window]$Window)

    if ($null -eq $Window -or $script:DrawerAdjusting) {
        return
    }

    $area = Get-WindowWorkingArea -Window $Window
    $width = Get-WindowActualWidth -Window $Window
    $height = Get-WindowActualHeight -Window $Window
    $gap = 4

    $Window.Top = Limit-Double -Value $Window.Top -Min ($area.Top + $gap) -Max ($area.Bottom - $height - $gap)
    $Window.Left = Limit-Double -Value $Window.Left -Min ($area.Left + $gap) -Max ($area.Right - $width - $gap)
    $script:DrawerEdge = Get-NearestHorizontalDrawerEdge -Window $Window
    $script:DrawerExpanded = $true
    Update-DrawerWindowState -Window $Window
    Update-DrawerHandleVisual
    Save-Settings
}

function Expand-WindowDrawer {
    param([System.Windows.Window]$Window)

    if ($null -eq $Window) {
        return
    }

    if (@('Left', 'Right') -notcontains [string]$script:DrawerEdge) {
        $script:DrawerEdge = Get-NearestHorizontalDrawerEdge -Window $Window
    }

    if (-not $script:DrawerExpanded) {
        Set-WindowDrawerState -Window $Window -Edge $script:DrawerEdge -Expanded $true -Animate -Persist
    }
}

function Collapse-WindowDrawer {
    param([System.Windows.Window]$Window)

    if ($null -eq $Window -or $script:DraggingWindow) {
        return
    }

    $edge = Get-NearestHorizontalDrawerEdge -Window $Window
    Set-WindowDrawerState -Window $Window -Edge $edge -Expanded $false -Animate -Persist
}
function Test-DragOriginInteractive {
    param([object]$OriginalSource)

    $interactiveElements = @(
        $settingsButton,
        $collapseButton,
        $closeButton,
        $drawerHandle,
        $locationStrip,
        $locationInfoCard.Grid,
        $refreshInfoCard.Grid,
        $languageInfoCard.Grid,
        $provinceCombo,
        $cityCombo,
        $districtCombo,
        $refreshCombo,
        $forecastDateCombo,
        $forecastHourCombo,
        $languagePill,
        $zhSegment,
        $enSegment
    )

    if ($null -ne $script:ForecastChips) {
        foreach ($chip in $script:ForecastChips.Values) {
            if ($null -ne $chip -and $null -ne $chip.Grid) {
                $interactiveElements += $chip.Grid
            }
        }
    }

    $current = $OriginalSource
    while ($null -ne $current) {
        if ($interactiveElements -contains $current) {
            return $true
        }

        if ($current -is [System.Windows.Controls.ComboBox] -or
            $current -is [System.Windows.Controls.TextBox] -or
            $current -is [System.Windows.Controls.MenuItem] -or
            $current -is [System.Windows.Controls.ContextMenu] -or
            $current -is [System.Windows.Controls.Primitives.ButtonBase] -or
            $current -is [System.Windows.Controls.Primitives.ScrollBar]) {
            return $true
        }

        $parent = $null
        if ($current -is [System.Windows.DependencyObject]) {
            try {
                $parent = [System.Windows.Media.VisualTreeHelper]::GetParent($current)
            } catch {
                $parent = $null
            }
        }

        if ($null -eq $parent -and $current -is [System.Windows.FrameworkElement]) {
            $parent = $current.Parent
        }

        $current = $parent
    }

    return $false
}

function Start-WidgetWindowDrag {
    param(
        [System.Windows.Window]$Window,
        [object]$EventArgs
    )

    if ($null -eq $Window -or $null -eq $EventArgs -or $EventArgs.Handled) {
        return
    }

    if (Test-DragOriginInteractive -OriginalSource $EventArgs.OriginalSource) {
        return
    }

    if ([System.Windows.Input.Mouse]::LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed) {
        return
    }

    $EventArgs.Handled = $true
    $script:DraggingWindow = $true
    try {
        if ($script:DrawerEdge -and -not $script:DrawerExpanded) {
            Set-WindowDrawerState -Window $Window -Edge $script:DrawerEdge -Expanded $true -Persist
        }

        try {
            $Window.DragMove()
        } catch {
            return
        }

        Update-DrawerDockAfterDrag -Window $Window
    } finally {
        $script:DraggingWindow = $false
    }
}

function Get-PropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        return $Default
    }

    return $property.Value
}

function Get-SeriesValue {
    param(
        [object]$Series,
        [int]$Index,
        [object]$Default = $null
    )

    if ($null -eq $Series) {
        return $Default
    }

    $items = @($Series)
    if ($Index -lt 0 -or $Index -ge $items.Count) {
        return $Default
    }

    if ($null -eq $items[$Index] -or [string]::IsNullOrWhiteSpace([string]$items[$Index])) {
        return $Default
    }

    return $items[$Index]
}

function ConvertTo-NullableDouble {
    param([object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    return [double]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-NullableInt {
    param([object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    return [int][double]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture)
}

function Get-WeatherLocalTimeZone {
    try {
        return [System.TimeZoneInfo]::FindSystemTimeZoneById('China Standard Time')
    } catch {
        return [System.TimeZoneInfo]::Local
    }
}

function ConvertTo-WeatherDateTime {
    param([object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    $text = ([string]$Value).Trim()
    if ($text -match '(Z|[+-]\d{2}:?\d{2})$') {
        $offsetTime = [DateTimeOffset]::Parse($text, [Globalization.CultureInfo]::InvariantCulture)
        return [System.TimeZoneInfo]::ConvertTime($offsetTime, (Get-WeatherLocalTimeZone)).DateTime
    }

    return [DateTime]::Parse($text, [Globalization.CultureInfo]::InvariantCulture)
}

function Test-RainWeatherCode {
    param([object]$Code)

    if ($null -eq $Code) {
        return $false
    }

    return (@(51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82) -contains [int]$Code)
}
function Test-ThunderWeatherCode {
    param([object]$Code)

    if ($null -eq $Code) {
        return $false
    }

    return (@(95, 96, 99) -contains [int]$Code)
}

function Get-CloudDerivedWeatherCode {
    param([object]$CloudCoverPercent)

    $cloud = if ($null -ne $CloudCoverPercent) { [double]$CloudCoverPercent } else { 0.0 }
    if ($cloud -ge 85) {
        return 3
    }
    if ($cloud -ge 25) {
        return 2
    }
    if ($cloud -ge 10) {
        return 1
    }
    return 0
}

function Test-DryCurrentThunderstormSignal {
    param(
        [object]$Code,
        [object]$RainAmount,
        [object]$RainProbability,
        [object]$CloudCoverPercent,
        [bool]$IsCurrent
    )

    if (-not $IsCurrent -or -not (Test-ThunderWeatherCode -Code $Code)) {
        return $false
    }

    $rain = if ($null -ne $RainAmount) { [double]$RainAmount } else { 0.0 }
    $probability = if ($null -ne $RainProbability) { [double]$RainProbability } else { 0.0 }
    $cloud = if ($null -ne $CloudCoverPercent) { [double]$CloudCoverPercent } else { 0.0 }

    return ($rain -le 0 -and $probability -lt 50 -and $cloud -lt 60)
}

function Test-StrongRainWeatherCode {
    param([object]$Code)

    if ($null -eq $Code) {
        return $false
    }

    return (@(65, 67, 82) -contains [int]$Code)
}

function Test-HeavyRainWeatherCode {
    param([object]$Code)

    return Test-StrongRainWeatherCode -Code $Code
}

function Get-WeatherRecordRainAmount {
    param([object]$Record)

    if ($null -eq $Record) {
        return 0.0
    }

    $precipitation = if ($null -ne $Record.PrecipitationMm) { [double]$Record.PrecipitationMm } else { 0.0 }
    $rain = if ($null -ne $Record.RainMm) { [double]$Record.RainMm } else { 0.0 }
    $showers = if ($null -ne $Record.ShowersMm) { [double]$Record.ShowersMm } else { 0.0 }
    return [Math]::Max($precipitation, ($rain + $showers))
}

function Get-WeatherRecordIntervalSeconds {
    param([object]$Record)

    if ($null -eq $Record -or $null -eq $Record.PSObject.Properties['IntervalSeconds'] -or $null -eq $Record.IntervalSeconds) {
        return $null
    }

    return [int]$Record.IntervalSeconds
}

function Test-RainstormAccumulationCriterion {
    param(
        [double]$RainAmount,
        [object]$IntervalSeconds,
        [object]$Past12HourRainMm = $null,
        [object]$Past24HourRainMm = $null
    )

    if ($null -ne $IntervalSeconds -and [int]$IntervalSeconds -ge 3600 -and $RainAmount -ge 16.0) {
        return $true
    }

    if ($null -ne $Past12HourRainMm -and [double]$Past12HourRainMm -ge 30.0) {
        return $true
    }

    if ($null -ne $Past24HourRainMm -and [double]$Past24HourRainMm -ge 50.0) {
        return $true
    }

    return $false
}

function Get-CurrentDataKind {
    param(
        [object]$Model,
        [object]$Record
    )

    if ($null -eq $Record) {
        return 'Unavailable'
    }

    $explicitKind = Get-PropertyValue -Object $Record -Name 'DataKind'
    if (-not [string]::IsNullOrWhiteSpace([string]$explicitKind)) {
        return [string]$explicitKind
    }

    $source = [string](Get-PropertyValue -Object $Model -Name 'Source')
    if ($source -eq 'wttr.in') {
        return 'Observation'
    }

    return 'CurrentModel'
}

function Test-CurrentDataTimeMatches {
    param(
        [object]$DataTime,
        [datetime]$Now
    )

    if ($null -eq $DataTime) {
        return $false
    }

    $deltaMinutes = (([datetime]$DataTime) - $Now).TotalMinutes
    return ($deltaMinutes -ge -90 -and $deltaMinutes -le 5)
}

function Test-CurrentStrongRainSignal {
    param(
        [object]$WeatherCode,
        [double]$RainAmount,
        [object]$DataTime,
        [string]$DataKind,
        [datetime]$Now
    )

    if (@('Observation', 'CurrentModel') -notcontains $DataKind) {
        return $false
    }

    if (-not (Test-CurrentDataTimeMatches -DataTime $DataTime -Now $Now)) {
        return $false
    }

    return ($RainAmount -ge 8.0 -or (Test-StrongRainWeatherCode -Code $WeatherCode))
}

function Test-CurrentRainstormSignal {
    param(
        [double]$RainAmount,
        [object]$IntervalSeconds,
        [object]$DataTime,
        [string]$DataKind,
        [datetime]$Now,
        [object]$Past12HourRainMm = $null,
        [object]$Past24HourRainMm = $null
    )

    if (@('Observation', 'CurrentModel') -notcontains $DataKind) {
        return $false
    }

    if (-not (Test-CurrentDataTimeMatches -DataTime $DataTime -Now $Now)) {
        return $false
    }

    return Test-RainstormAccumulationCriterion -RainAmount $RainAmount -IntervalSeconds $IntervalSeconds -Past12HourRainMm $Past12HourRainMm -Past24HourRainMm $Past24HourRainMm
}
function Format-NearTermHeavyRainText {
    param([double]$MinutesUntil)

    $minutes = [Math]::Max(1, [int][Math]::Ceiling($MinutesUntil))
    if ($minutes -le 60) {
        if ($script:Language -eq 'zh') {
            if ($minutes -ge 55) {
                return T '6aKE6K6hIDEg5bCP5pe25YaF5pyJ5by66ZmN6Zuo'
            }
            return (T '6aKE6K6hIHswfSDliIbpkp/lkI7mnInlvLrpmY3pm6g=') -f $minutes
        }
        if ($minutes -ge 55) {
            return 'Heavy rain risk within 1 hour'
        }
        return 'Heavy rain risk in about {0} min' -f $minutes
    }

    if ($script:Language -eq 'zh') {
        return T '6aKE6K6hIDHvvZ4yIOWwj+aXtuWGheacieW8uumZjembqA=='
    }
    return 'Heavy rain risk within 1-2 hours'
}

function Resolve-NearTermForecast {
    param(
        [object]$Model,
        [datetime]$Now
    )

    $unavailable = [pscustomobject]@{
        Text = Tx 'NearTermUnavailable'
        Time = $null
        WeatherCode = $null
        PrecipitationMm = $null
    }
    $noHeavyRain = [pscustomobject]@{
        Text = Tx 'NearTermNoHeavyRain'
        Time = $null
        WeatherCode = $null
        PrecipitationMm = $null
    }

    if ($null -eq $Model -or $null -eq $Model.PSObject.Properties['Hourly'] -or @($Model.Hourly).Count -eq 0) {
        return $unavailable
    }

    $futureRecords = @($Model.Hourly) |
        Where-Object { $null -ne $_.Time -and ([datetime]$_.Time) -gt $Now -and ([datetime]$_.Time) -le $Now.AddHours(2) } |
        Sort-Object Time

    if (@($futureRecords).Count -eq 0) {
        return $unavailable
    }

    foreach ($entry in $futureRecords) {
        $rainAmount = Get-WeatherRecordRainAmount -Record $entry
        $code = Get-PropertyValue -Object $entry -Name 'WeatherCode'
        if ($rainAmount -ge 8.0 -or (Test-HeavyRainWeatherCode -Code $code)) {
            $minutes = (([datetime]$entry.Time) - $Now).TotalMinutes
            return [pscustomobject]@{
                Text = Format-NearTermHeavyRainText -MinutesUntil $minutes
                Time = [datetime]$entry.Time
                WeatherCode = $code
                PrecipitationMm = $rainAmount
            }
        }
    }

    return $noHeavyRain
}
function Resolve-WeatherDisplaySemantics {
    param(
        [object]$Model,
        [datetime]$Now
    )

    $diagnostics = New-Object System.Collections.Generic.List[string]
    $currentRecord = Get-PropertyValue -Object $Model -Name 'Current'
    $currentDataKind = Get-CurrentDataKind -Model $Model -Record $currentRecord
    $currentDataTime = Get-PropertyValue -Object $currentRecord -Name 'Time'
    $currentWeatherCode = Get-PropertyValue -Object $currentRecord -Name 'WeatherCode'
    $currentPrecipitation = if ($null -ne $currentRecord -and $null -ne $currentRecord.PrecipitationMm) { [double]$currentRecord.PrecipitationMm } else { 0.0 }
    $currentRain = if ($null -ne $currentRecord -and $null -ne $currentRecord.RainMm) { [double]$currentRecord.RainMm } else { 0.0 }
    $currentRainAmount = Get-WeatherRecordRainAmount -Record $currentRecord
    $currentIntervalSeconds = Get-WeatherRecordIntervalSeconds -Record $currentRecord
    $past12HourRain = Get-PropertyValue -Object $Model -Name 'Past12HourRainMm'
    $past24HourRain = Get-PropertyValue -Object $Model -Name 'Past24HourRainMm'
    $timeMatches = Test-CurrentDataTimeMatches -DataTime $currentDataTime -Now $Now
    $hasCurrent = ($null -ne $currentRecord)
    $strongCode = Test-StrongRainWeatherCode -Code $currentWeatherCode
    $inconsistentRainSignal = ($hasCurrent -and $strongCode -and $currentRainAmount -le 0)
    if ($inconsistentRainSignal) {
        $diagnostics.Add('InconsistentCurrentRainSignal') | Out-Null
    }
    if ($hasCurrent -and -not $timeMatches) {
        $diagnostics.Add('CurrentDataTimeNotMatched') | Out-Null
    }

    $isCurrentRainstorm = (-not $inconsistentRainSignal) -and (Test-CurrentRainstormSignal -RainAmount $currentRainAmount -IntervalSeconds $currentIntervalSeconds -DataTime $currentDataTime -DataKind $currentDataKind -Now $Now -Past12HourRainMm $past12HourRain -Past24HourRainMm $past24HourRain)
    $isCurrentStrongRain = (-not $inconsistentRainSignal) -and (Test-CurrentStrongRainSignal -WeatherCode $currentWeatherCode -RainAmount $currentRainAmount -DataTime $currentDataTime -DataKind $currentDataKind -Now $Now)
    $displayWeatherCode = $currentWeatherCode
    if ($inconsistentRainSignal) {
        $displayWeatherCode = Get-CloudDerivedWeatherCode -CloudCoverPercent $currentRecord.CloudCoverPercent
    }

    if (-not $hasCurrent -or $currentDataKind -eq 'Unavailable') {
        $currentCondition = Tx 'CurrentUnavailable'
    } elseif ($inconsistentRainSignal) {
        $currentCondition = Tx 'CurrentUncertain'
    } elseif ($isCurrentRainstorm) {
        $currentCondition = Tx 'CurrentRainstorm'
    } elseif ($isCurrentStrongRain) {
        $currentCondition = Tx 'CurrentHeavyRain'
    } else {
        $baseText = Get-LocalizedWeatherText -WeatherText (Get-PropertyValue -Object $currentRecord -Name 'WeatherText') -WeatherCode $displayWeatherCode
        if ([string]::IsNullOrWhiteSpace([string]$baseText)) {
            $baseText = Tx 'Weather'
        }
        if ($currentRainAmount -le 0) {
            $currentCondition = '{0} {1} {2}' -f $baseText, ([char]0x00B7), (Tx 'CurrentNoRain')
        } else {
            $currentCondition = $baseText
        }
    }

    $nearTerm = Resolve-NearTermForecast -Model $Model -Now $Now
    $warningLevel = Get-PropertyValue -Object $Model -Name 'WarningLevel'
    $warningText = Get-PropertyValue -Object $Model -Name 'WarningText'
    if ([string]::IsNullOrWhiteSpace([string]$warningText)) {
        $warningText = Get-PropertyValue -Object $Model -Name 'UiSmokeAlertText'
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$warningText)) {
        $warningText = Convert-WeatherDisplayTextForLanguage -Text ([string]$warningText) -WarningLevel ([string]$warningLevel)
    }

    return [pscustomobject]@{
        CurrentCondition = $currentCondition
        CurrentWeatherCode = $currentWeatherCode
        CurrentDisplayWeatherCode = $displayWeatherCode
        CurrentPrecipitation = $currentPrecipitation
        CurrentRain = $currentRain
        CurrentRainAmount = $currentRainAmount
        CurrentIntervalSeconds = $currentIntervalSeconds
        CurrentDataTime = $currentDataTime
        CurrentDataKind = $currentDataKind
        CurrentIsHeavyRain = $isCurrentStrongRain
        CurrentIsStrongRain = $isCurrentStrongRain
        CurrentIsRainstorm = $isCurrentRainstorm
        CurrentIsRaining = ($currentRainAmount -gt 0 -and -not $inconsistentRainSignal)
        NearTermForecast = $nearTerm.Text
        NearTermForecastTime = $nearTerm.Time
        NearTermWeatherCode = $nearTerm.WeatherCode
        NearTermPrecipitation = $nearTerm.PrecipitationMm
        WarningText = if ([string]::IsNullOrWhiteSpace([string]$warningText)) { '' } else { [string]$warningText }
        WarningLevel = if ([string]::IsNullOrWhiteSpace([string]$warningLevel)) { '' } else { [string]$warningLevel }
        Diagnostics = @($diagnostics)
    }
}
function Get-WeatherWarningDisplayText {
    param([object]$Snapshot)

    if ($null -eq $Snapshot) {
        return Tx 'NoWeatherAlert'
    }

    if ($null -ne $Snapshot.PSObject.Properties['WarningText'] -and -not [string]::IsNullOrWhiteSpace([string]$Snapshot.WarningText)) {
        $warningLevel = Get-PropertyValue -Object $Snapshot -Name 'WarningLevel'
        return Convert-WeatherDisplayTextForLanguage -Text ([string]$Snapshot.WarningText) -WarningLevel ([string]$warningLevel)
    }

    $derived = Get-WeatherAlertInfo -Snapshot $Snapshot
    if ($null -ne $derived -and $derived.Key -ne 'NoWeatherAlert' -and $derived.Key -ne 'OfflineAlert') {
        return Tx $derived.Key
    }

    return Tx 'NoWeatherAlert'
}function New-WeatherGlyph {
    param([int]$CodePoint)

    return [System.Char]::ConvertFromUtf32($CodePoint)
}

function Get-WeatherAlertInfo {
    param([object]$Snapshot)

    if ($null -eq $Snapshot) {
        return [pscustomobject]@{
            Key = 'OfflineAlert'
            Icon = New-WeatherGlyph 0x26A0
            Background = '#FFF3DED5'
            Foreground = '#D97757'
            Glow = '#D97757'
            Active = $true
        }
    }

    $isCurrent = $true
    if ($null -ne $Snapshot.PSObject.Properties['IsCurrent']) {
        $isCurrent = [bool]$Snapshot.IsCurrent
    }

    $wind = if ($null -ne $Snapshot.WindKmh) { [double]$Snapshot.WindKmh } else { 0.0 }
    $gust = if ($null -ne $Snapshot.WindGustKmh) { [double]$Snapshot.WindGustKmh } else { 0.0 }
    $rainNow = if ($null -ne $Snapshot.RainNowMm) { [double]$Snapshot.RainNowMm } else { 0.0 }
    $dayRain = if ($null -ne $Snapshot.TodayRainMm) { [double]$Snapshot.TodayRainMm } else { 0.0 }
    $rainProbability = if ($null -ne $Snapshot.RainProbability) { [double]$Snapshot.RainProbability } else { 0.0 }

    if (-not $isCurrent) {
        if ($wind -ge 62 -or $gust -ge 88) {
            return [pscustomobject]@{
                Key = 'ForecastTyphoon'
                Icon = New-WeatherGlyph 0x1F300
                Background = '#FFF3DED5'
                Foreground = '#6F6B60'
                Glow = '#D97757'
                Active = $false
            }
        }

        if ($Snapshot.IsThunderstorm) {
            return [pscustomobject]@{
                Key = 'ForecastThunderstorm'
                Icon = New-WeatherGlyph 0x26C8
                Background = '#FFF3DED5'
                Foreground = '#6F6B60'
                Glow = '#D97757'
                Active = $false
            }
        }

        if ($rainNow -ge 8 -or $dayRain -ge 50 -or ($rainProbability -ge 90 -and $dayRain -ge 20)) {
            return [pscustomobject]@{
                Key = 'ForecastHeavyRain'
                Icon = New-WeatherGlyph 0x1F327
                Background = '#FFF3DED5'
                Foreground = '#6F6B60'
                Glow = '#D97757'
                Active = $false
            }
        }

        if ($wind -ge 39 -or $gust -ge 62) {
            return [pscustomobject]@{
                Key = 'ForecastGale'
                Icon = New-WeatherGlyph 0x1F32C
                Background = '#FFF3F1EA'
                Foreground = '#6F6B60'
                Glow = '#F3DED5'
                Active = $false
            }
        }

        return [pscustomobject]@{
            Key = 'NoWeatherAlert'
            Icon = New-WeatherGlyph 0x2600
            Background = '#00FFFFFF'
            Foreground = '#8A867A'
            Glow = '#F3DED5'
            Active = $false
        }
    }

    if ($wind -ge 62 -or $gust -ge 88) {
        return [pscustomobject]@{
            Key = 'TyphoonAlert'
            Icon = New-WeatherGlyph 0x1F300
            Background = '#FFF3DED5'
            Foreground = '#6F6B60'
            Glow = '#D97757'
            Active = $true
        }
    }

    if ($Snapshot.IsThunderstorm) {
        return [pscustomobject]@{
            Key = 'ThunderstormAlert'
            Icon = New-WeatherGlyph 0x26C8
            Background = '#FFF3DED5'
            Foreground = '#6F6B60'
            Glow = '#D97757'
            Active = $true
        }
    }

    if ($rainNow -ge 8 -or $dayRain -ge 50 -or ($rainProbability -ge 90 -and $dayRain -ge 20)) {
        return [pscustomobject]@{
            Key = 'HeavyRainAlert'
            Icon = New-WeatherGlyph 0x1F327
            Background = '#FFF3DED5'
            Foreground = '#6F6B60'
            Glow = '#D97757'
            Active = $true
        }
    }

    if ($wind -ge 39 -or $gust -ge 62) {
        return [pscustomobject]@{
            Key = 'GaleAlert'
            Icon = New-WeatherGlyph 0x1F32C
            Background = '#FFF3F1EA'
            Foreground = '#6F6B60'
            Glow = '#F3DED5'
            Active = $true
        }
    }

    return [pscustomobject]@{
        Key = 'NoWeatherAlert'
        Icon = New-WeatherGlyph 0x2600
        Background = '#00FFFFFF'
        Foreground = '#8A867A'
        Glow = '#F3DED5'
        Active = $false
    }
}
function Get-WeatherVisualInfo {
    param([object]$Snapshot)

    if ($null -eq $Snapshot) {
        return [pscustomobject]@{
            IconKey = 'Offline'
            Icon = New-WeatherGlyph 0x26A0
            Background = '#FFF3DED5'
            Foreground = '#B5473C'
            Glow = '#D97757'
        }
    }

    $alert = Get-WeatherAlertInfo -Snapshot $Snapshot
    if (@('TyphoonAlert', 'ForecastTyphoon') -contains $alert.Key) {
        return [pscustomobject]@{
            IconKey = 'Typhoon'
            Icon = $alert.Icon
            Background = '#FFF3DED5'
            Foreground = '#6F6B60'
            Glow = '#D97757'
        }
    }

    if (@('GaleAlert', 'ForecastGale') -contains $alert.Key) {
        return [pscustomobject]@{
            IconKey = 'Wind'
            Icon = $alert.Icon
            Background = '#FFF3F1EA'
            Foreground = '#6F6B60'
            Glow = '#F3DED5'
        }
    }

    $code = if ($null -ne $Snapshot.WeatherCode) { [int]$Snapshot.WeatherCode } else { -1 }
    $isNight = ($Snapshot.IsDay -eq 0)

    if ($Snapshot.IsThunderstorm -or (@(95, 96, 99) -contains $code)) {
        return [pscustomobject]@{
            IconKey = 'Thunderstorm'
            Icon = New-WeatherGlyph 0x26C8
            Background = '#FFF3DED5'
            Foreground = '#6F6B60'
            Glow = '#D97757'
        }
    }

    if (@(71, 73, 75, 77, 85, 86) -contains $code) {
        return [pscustomobject]@{
            IconKey = 'Snow'
            Icon = New-WeatherGlyph 0x2744
            Background = '#FFFAF9F5'
            Foreground = '#6F6B60'
            Glow = '#F3DED5'
        }
    }

    if (@(45, 48) -contains $code) {
        return [pscustomobject]@{
            IconKey = 'Fog'
            Icon = New-WeatherGlyph 0x1F32B
            Background = '#FFF3F1EA'
            Foreground = '#6F6B60'
            Glow = '#F3DED5'
        }
    }

    if (@(80, 81, 82) -contains $code) {
        return [pscustomobject]@{
            IconKey = 'Showers'
            Icon = if ($isNight) { New-WeatherGlyph 0x1F327 } else { New-WeatherGlyph 0x1F326 }
            Background = '#FFF3DED5'
            Foreground = '#6F6B60'
            Glow = '#D97757'
        }
    }

    if ($Snapshot.IsRainingNow -or (@(51, 53, 55, 56, 57, 61, 63, 65, 66, 67) -contains $code)) {
        return [pscustomobject]@{
            IconKey = 'Rain'
            Icon = New-WeatherGlyph 0x1F327
            Background = '#FFF3DED5'
            Foreground = '#6F6B60'
            Glow = '#D97757'
        }
    }

    if ($code -eq 2 -or ($code -lt 0 -and $Snapshot.CloudCoverPercent -ge 25 -and $Snapshot.CloudCoverPercent -lt 70)) {
        return [pscustomobject]@{
            IconKey = if ($isNight) { 'Cloud' } else { 'PartlyCloudy' }
            Icon = if ($isNight) { New-WeatherGlyph 0x2601 } else { New-WeatherGlyph 0x26C5 }
            Background = '#FFF3F1EA'
            Foreground = '#6F6B60'
            Glow = '#F3DED5'
        }
    }

    if ($code -eq 3 -or $Snapshot.CloudCoverPercent -ge 70) {
        return [pscustomobject]@{
            IconKey = 'Cloud'
            Icon = New-WeatherGlyph 0x2601
            Background = '#FFF3F1EA'
            Foreground = '#6F6B60'
            Glow = '#F3DED5'
        }
    }

    if ($isNight) {
        return [pscustomobject]@{
            IconKey = 'Night'
            Icon = New-WeatherGlyph 0x1F319
            Background = '#FFF3F1EA'
            Foreground = '#6F6B60'
            Glow = '#D8D4C8'
        }
    }

    return [pscustomobject]@{
        IconKey = 'Clear'
        Icon = New-WeatherGlyph 0x2600
        Background = '#FFFAF9F5'
        Foreground = '#D97757'
        Glow = '#F3DED5'
    }
}

function New-WeatherIconElement {
    param(
        [string]$IconKey,
        [string]$Foreground = '#D97757'
    )

    switch ($IconKey) {
        'Clear' {
            $xaml = @"
<Canvas xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="42" Height="42" SnapsToDevicePixels="True">
  <Ellipse Canvas.Left="15" Canvas.Top="15" Width="12" Height="12" Fill="$Foreground"/>
  <Rectangle Canvas.Left="20" Canvas.Top="4" Width="2" Height="7" RadiusX="1" RadiusY="1" Fill="$Foreground"/>
  <Rectangle Canvas.Left="20" Canvas.Top="31" Width="2" Height="7" RadiusX="1" RadiusY="1" Fill="$Foreground"/>
  <Rectangle Canvas.Left="4" Canvas.Top="20" Width="7" Height="2" RadiusX="1" RadiusY="1" Fill="$Foreground"/>
  <Rectangle Canvas.Left="31" Canvas.Top="20" Width="7" Height="2" RadiusX="1" RadiusY="1" Fill="$Foreground"/>
  <Line X1="10" Y1="10" X2="14" Y2="14" Stroke="$Foreground" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
  <Line X1="32" Y1="10" X2="28" Y2="14" Stroke="$Foreground" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
  <Line X1="10" Y1="32" X2="14" Y2="28" Stroke="$Foreground" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
  <Line X1="32" Y1="32" X2="28" Y2="28" Stroke="$Foreground" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
</Canvas>
"@
        }
        'Night' {
            $xaml = @"
<Canvas xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="42" Height="42" SnapsToDevicePixels="True">
  <Path Fill="$Foreground" Data="M 27 7 C 21 10 18 16 20 23 C 22 30 28 34 35 33 C 31 38 23 39 17 35 C 9 30 7 20 12 12 C 15 8 21 5 27 7 Z"/>
</Canvas>
"@
        }
        'PartlyCloudy' {
            $xaml = @"
<Canvas xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="42" Height="42" SnapsToDevicePixels="True">
  <Ellipse Canvas.Left="7" Canvas.Top="8" Width="14" Height="14" Fill="$Foreground" Opacity="0.42"/>
  <Ellipse Canvas.Left="10" Canvas.Top="19" Width="13" Height="13" Fill="$Foreground"/>
  <Ellipse Canvas.Left="18" Canvas.Top="14" Width="17" Height="17" Fill="$Foreground"/>
  <Ellipse Canvas.Left="27" Canvas.Top="20" Width="10" Height="10" Fill="$Foreground"/>
  <Rectangle Canvas.Left="10" Canvas.Top="25" Width="27" Height="8" RadiusX="4" RadiusY="4" Fill="$Foreground"/>
</Canvas>
"@
        }
        'Cloud' {
            $xaml = @"
<Canvas xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="42" Height="42" SnapsToDevicePixels="True">
  <Ellipse Canvas.Left="8" Canvas.Top="20" Width="13" Height="13" Fill="$Foreground"/>
  <Ellipse Canvas.Left="17" Canvas.Top="13" Width="18" Height="18" Fill="$Foreground"/>
  <Ellipse Canvas.Left="29" Canvas.Top="20" Width="9" Height="9" Fill="$Foreground"/>
  <Rectangle Canvas.Left="8" Canvas.Top="25" Width="30" Height="9" RadiusX="4.5" RadiusY="4.5" Fill="$Foreground"/>
</Canvas>
"@
        }
        'Fog' {
            $xaml = @"
<Canvas xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="42" Height="42" SnapsToDevicePixels="True">
  <Ellipse Canvas.Left="10" Canvas.Top="14" Width="13" Height="13" Fill="$Foreground" Opacity="0.78"/>
  <Ellipse Canvas.Left="19" Canvas.Top="9" Width="16" Height="16" Fill="$Foreground" Opacity="0.78"/>
  <Rectangle Canvas.Left="10" Canvas.Top="21" Width="27" Height="7" RadiusX="3.5" RadiusY="3.5" Fill="$Foreground" Opacity="0.78"/>
  <Line X1="7" Y1="31" X2="35" Y2="31" Stroke="$Foreground" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
  <Line X1="12" Y1="36" X2="31" Y2="36" Stroke="$Foreground" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
</Canvas>
"@
        }
        'Rain' {
            $xaml = @"
<Canvas xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="42" Height="42" SnapsToDevicePixels="True">
  <Ellipse Canvas.Left="8" Canvas.Top="13" Width="13" Height="13" Fill="$Foreground"/>
  <Ellipse Canvas.Left="17" Canvas.Top="8" Width="18" Height="18" Fill="$Foreground"/>
  <Rectangle Canvas.Left="8" Canvas.Top="20" Width="30" Height="9" RadiusX="4.5" RadiusY="4.5" Fill="$Foreground"/>
  <Line X1="15" Y1="32" X2="12" Y2="38" Stroke="$Foreground" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
  <Line X1="23" Y1="32" X2="20" Y2="38" Stroke="$Foreground" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
  <Line X1="31" Y1="32" X2="28" Y2="38" Stroke="$Foreground" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
</Canvas>
"@
        }
        'Showers' {
            $xaml = @"
<Canvas xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="42" Height="42" SnapsToDevicePixels="True">
  <Ellipse Canvas.Left="7" Canvas.Top="7" Width="12" Height="12" Fill="$Foreground" Opacity="0.38"/>
  <Ellipse Canvas.Left="9" Canvas.Top="14" Width="13" Height="13" Fill="$Foreground"/>
  <Ellipse Canvas.Left="18" Canvas.Top="9" Width="18" Height="18" Fill="$Foreground"/>
  <Rectangle Canvas.Left="9" Canvas.Top="21" Width="29" Height="8" RadiusX="4" RadiusY="4" Fill="$Foreground"/>
  <Line X1="16" Y1="32" X2="13" Y2="38" Stroke="$Foreground" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
  <Line X1="25" Y1="32" X2="22" Y2="38" Stroke="$Foreground" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
  <Line X1="33" Y1="32" X2="30" Y2="38" Stroke="$Foreground" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
</Canvas>
"@
        }
        'Thunderstorm' {
            $xaml = @"
<Canvas xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="42" Height="42" SnapsToDevicePixels="True">
  <Ellipse Canvas.Left="7" Canvas.Top="12" Width="13" Height="13" Fill="$Foreground"/>
  <Ellipse Canvas.Left="16" Canvas.Top="7" Width="19" Height="19" Fill="$Foreground"/>
  <Rectangle Canvas.Left="7" Canvas.Top="19" Width="31" Height="9" RadiusX="4.5" RadiusY="4.5" Fill="$Foreground"/>
  <Line X1="13" Y1="31" X2="10" Y2="37" Stroke="$Foreground" StrokeThickness="1.8" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Opacity="0.82"/>
  <Line X1="31" Y1="31" X2="28" Y2="37" Stroke="$Foreground" StrokeThickness="1.8" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Opacity="0.82"/>
  <Polygon Points="23,27 17,39 24,36 21,42 32,29 25,32" Fill="$Foreground"/>
</Canvas>
"@
        }
        'Snow' {
            $xaml = @"
<Canvas xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="42" Height="42" SnapsToDevicePixels="True">
  <Ellipse Canvas.Left="8" Canvas.Top="12" Width="13" Height="13" Fill="$Foreground"/>
  <Ellipse Canvas.Left="17" Canvas.Top="7" Width="18" Height="18" Fill="$Foreground"/>
  <Rectangle Canvas.Left="8" Canvas.Top="19" Width="30" Height="9" RadiusX="4.5" RadiusY="4.5" Fill="$Foreground"/>
  <Line X1="15" Y1="33" X2="15" Y2="39" Stroke="$Foreground" StrokeThickness="1.6" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
  <Line X1="12" Y1="36" X2="18" Y2="36" Stroke="$Foreground" StrokeThickness="1.6" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
  <Line X1="27" Y1="33" X2="27" Y2="39" Stroke="$Foreground" StrokeThickness="1.6" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
  <Line X1="24" Y1="36" X2="30" Y2="36" Stroke="$Foreground" StrokeThickness="1.6" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
</Canvas>
"@
        }
        'Wind' {
            $xaml = @"
<Canvas xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="42" Height="42" SnapsToDevicePixels="True">
  <Line X1="7" Y1="15" X2="32" Y2="15" Stroke="$Foreground" StrokeThickness="2.4" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
  <Line X1="12" Y1="23" X2="36" Y2="23" Stroke="$Foreground" StrokeThickness="2.4" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
  <Line X1="7" Y1="31" X2="27" Y2="31" Stroke="$Foreground" StrokeThickness="2.4" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
</Canvas>
"@
        }
        'Typhoon' {
            $xaml = @"
<Canvas xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="42" Height="42" SnapsToDevicePixels="True">
  <Path Stroke="$Foreground" StrokeThickness="3" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Fill="Transparent" Data="M 32 14 C 25 8 13 11 10 21 C 8 29 16 36 25 33 C 32 31 35 23 29 19 C 24 16 17 19 17 24"/>
  <Ellipse Canvas.Left="18" Canvas.Top="18" Width="6" Height="6" Fill="$Foreground"/>
</Canvas>
"@
        }
        default {
            $xaml = @"
<Canvas xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="42" Height="42" SnapsToDevicePixels="True">
  <Polygon Points="21,6 37,35 5,35" Fill="$Foreground" Opacity="0.88"/>
  <Rectangle Canvas.Left="20" Canvas.Top="16" Width="2" Height="10" RadiusX="1" RadiusY="1" Fill="#FFFFFFFF"/>
  <Ellipse Canvas.Left="19" Canvas.Top="29" Width="4" Height="4" Fill="#FFFFFFFF"/>
</Canvas>
"@
        }
    }

    return New-XamlObject $xaml
}
function ConvertTo-OpenMeteoForecastModel {
    param([object]$Weather)

    $current = $Weather.current
    $currentRecord = [pscustomobject]@{
        Time = ConvertTo-WeatherDateTime (Get-PropertyValue -Object $current -Name 'time')
        TemperatureC = ConvertTo-NullableDouble (Get-PropertyValue -Object $current -Name 'temperature_2m')
        HumidityPercent = ConvertTo-NullableDouble (Get-PropertyValue -Object $current -Name 'relative_humidity_2m')
        DewPointC = $null
        FeelsLikeC = ConvertTo-NullableDouble (Get-PropertyValue -Object $current -Name 'apparent_temperature')
        PrecipitationProbability = $null
        PrecipitationMm = ConvertTo-NullableDouble (Get-PropertyValue -Object $current -Name 'precipitation')
        RainMm = ConvertTo-NullableDouble (Get-PropertyValue -Object $current -Name 'rain')
        ShowersMm = ConvertTo-NullableDouble (Get-PropertyValue -Object $current -Name 'showers')
        WeatherCode = ConvertTo-NullableInt (Get-PropertyValue -Object $current -Name 'weather_code')
        CloudCoverPercent = ConvertTo-NullableDouble (Get-PropertyValue -Object $current -Name 'cloud_cover')
        PressureMslHpa = ConvertTo-NullableDouble (Get-PropertyValue -Object $current -Name 'pressure_msl')
        SurfacePressureHpa = ConvertTo-NullableDouble (Get-PropertyValue -Object $current -Name 'surface_pressure')
        VisibilityM = $null
        WindKmh = ConvertTo-NullableDouble (Get-PropertyValue -Object $current -Name 'wind_speed_10m')
        WindDirectionDeg = ConvertTo-NullableDouble (Get-PropertyValue -Object $current -Name 'wind_direction_10m')
        WindGustKmh = ConvertTo-NullableDouble (Get-PropertyValue -Object $current -Name 'wind_gusts_10m')
        UvIndex = $null
        IntervalSeconds = ConvertTo-NullableInt (Get-PropertyValue -Object $current -Name 'interval')
        IsDay = ConvertTo-NullableInt (Get-PropertyValue -Object $current -Name 'is_day')
        WeatherText = $null
    }

    $hourlyRecords = @()
    $hourly = $Weather.hourly
    $hourlyTimes = @((Get-PropertyValue -Object $hourly -Name 'time' -Default @()))
    for ($i = 0; $i -lt $hourlyTimes.Count; $i++) {
        $hourlyRecords += [pscustomobject]@{
            Time = ConvertTo-WeatherDateTime $hourlyTimes[$i]
            TemperatureC = ConvertTo-NullableDouble (Get-SeriesValue -Series $hourly.temperature_2m -Index $i)
            HumidityPercent = ConvertTo-NullableDouble (Get-SeriesValue -Series $hourly.relative_humidity_2m -Index $i)
            DewPointC = ConvertTo-NullableDouble (Get-SeriesValue -Series $hourly.dew_point_2m -Index $i)
            FeelsLikeC = ConvertTo-NullableDouble (Get-SeriesValue -Series $hourly.apparent_temperature -Index $i)
            PrecipitationProbability = ConvertTo-NullableInt (Get-SeriesValue -Series $hourly.precipitation_probability -Index $i)
            PrecipitationMm = ConvertTo-NullableDouble (Get-SeriesValue -Series $hourly.precipitation -Index $i)
            RainMm = ConvertTo-NullableDouble (Get-SeriesValue -Series $hourly.rain -Index $i)
            ShowersMm = ConvertTo-NullableDouble (Get-SeriesValue -Series $hourly.showers -Index $i)
            WeatherCode = ConvertTo-NullableInt (Get-SeriesValue -Series $hourly.weather_code -Index $i)
            CloudCoverPercent = ConvertTo-NullableDouble (Get-SeriesValue -Series $hourly.cloud_cover -Index $i)
            PressureMslHpa = ConvertTo-NullableDouble (Get-SeriesValue -Series $hourly.pressure_msl -Index $i)
            SurfacePressureHpa = ConvertTo-NullableDouble (Get-SeriesValue -Series $hourly.surface_pressure -Index $i)
            VisibilityM = ConvertTo-NullableDouble (Get-SeriesValue -Series $hourly.visibility -Index $i)
            WindKmh = ConvertTo-NullableDouble (Get-SeriesValue -Series $hourly.wind_speed_10m -Index $i)
            WindDirectionDeg = ConvertTo-NullableDouble (Get-SeriesValue -Series $hourly.wind_direction_10m -Index $i)
            WindGustKmh = ConvertTo-NullableDouble (Get-SeriesValue -Series $hourly.wind_gusts_10m -Index $i)
            UvIndex = ConvertTo-NullableDouble (Get-SeriesValue -Series $hourly.uv_index -Index $i)
            IsDay = ConvertTo-NullableInt (Get-SeriesValue -Series $hourly.is_day -Index $i)
            WeatherText = $null
        }
    }

    $dailyRecords = @()
    $daily = $Weather.daily
    $dailyTimes = @((Get-PropertyValue -Object $daily -Name 'time' -Default @()))
    for ($i = 0; $i -lt $dailyTimes.Count; $i++) {
        $dailyRecords += [pscustomobject]@{
            Date = (ConvertTo-WeatherDateTime $dailyTimes[$i]).Date
            WeatherCode = ConvertTo-NullableInt (Get-SeriesValue -Series $daily.weather_code -Index $i)
            TemperatureMaxC = ConvertTo-NullableDouble (Get-SeriesValue -Series $daily.temperature_2m_max -Index $i)
            TemperatureMinC = ConvertTo-NullableDouble (Get-SeriesValue -Series $daily.temperature_2m_min -Index $i)
            FeelsLikeMaxC = ConvertTo-NullableDouble (Get-SeriesValue -Series $daily.apparent_temperature_max -Index $i)
            FeelsLikeMinC = ConvertTo-NullableDouble (Get-SeriesValue -Series $daily.apparent_temperature_min -Index $i)
            Sunrise = ConvertTo-WeatherDateTime (Get-SeriesValue -Series $daily.sunrise -Index $i)
            Sunset = ConvertTo-WeatherDateTime (Get-SeriesValue -Series $daily.sunset -Index $i)
            DaylightSeconds = ConvertTo-NullableDouble (Get-SeriesValue -Series $daily.daylight_duration -Index $i)
            SunshineSeconds = ConvertTo-NullableDouble (Get-SeriesValue -Series $daily.sunshine_duration -Index $i)
            UvIndexMax = ConvertTo-NullableDouble (Get-SeriesValue -Series $daily.uv_index_max -Index $i)
            PrecipitationSumMm = ConvertTo-NullableDouble (Get-SeriesValue -Series $daily.precipitation_sum -Index $i)
            RainSumMm = ConvertTo-NullableDouble (Get-SeriesValue -Series $daily.rain_sum -Index $i)
            PrecipitationHours = ConvertTo-NullableDouble (Get-SeriesValue -Series $daily.precipitation_hours -Index $i)
            PrecipitationProbabilityMax = ConvertTo-NullableInt (Get-SeriesValue -Series $daily.precipitation_probability_max -Index $i)
            WindSpeedMaxKmh = ConvertTo-NullableDouble (Get-SeriesValue -Series $daily.wind_speed_10m_max -Index $i)
            WindGustMaxKmh = ConvertTo-NullableDouble (Get-SeriesValue -Series $daily.wind_gusts_10m_max -Index $i)
            WindDirectionDominantDeg = ConvertTo-NullableDouble (Get-SeriesValue -Series $daily.wind_direction_10m_dominant -Index $i)
        }
    }

    [pscustomobject]@{
        Source = 'Open-Meteo'
        Timezone = Get-PropertyValue -Object $Weather -Name 'timezone' -Default 'auto'
        Current = $currentRecord
        Hourly = @($hourlyRecords)
        Daily = @($dailyRecords)
        SupportsForecastSlots = $true
        AirQuality = $null
        # TODO: Add Open-Meteo Air Quality API with AQI, PM2.5, PM10, O3, and NO2 using a second bounded request.
    }
}

function Get-ForecastSlotDefinition {
    param([string]$SlotKey)

    $definition = $script:ForecastSlotDefinitions | Where-Object { $_.Key -eq $SlotKey } | Select-Object -First 1
    if ($null -ne $definition) {
        return $definition
    }

    if ($SlotKey -match '^D(?<Day>\d{1,2})T(?<Hour>\d{1,2})$') {
        $dayOffset = [Math]::Max(0, [Math]::Min($script:ForecastDayCount - 1, [int]$Matches.Day))
        $hour = [Math]::Max(0, [Math]::Min(23, [int]$Matches.Hour))
        return [pscustomobject]@{
            Key = ('D{0}T{1:00}' -f $dayOffset, $hour)
            Kind = 'DayHour'
            DayOffset = $dayOffset
            Hour = $hour
        }
    }

    return $script:ForecastSlotDefinitions[0]
}

function Get-ForecastTargetTime {
    param(
        [object]$Definition,
        [DateTime]$BaseTime
    )

    switch ($Definition.Kind) {
        'Current' {
            return $BaseTime
        }
        'Offset' {
            return $BaseTime.AddHours([double]$Definition.OffsetHours)
        }
        'Tonight' {
            $target = $BaseTime.Date.AddHours(20)
            if ($target -le $BaseTime) {
                $target = $target.AddDays(1)
            }
            return $target
        }
        'Tomorrow' {
            return $BaseTime.Date.AddDays(1).AddHours(9)
        }
        'DayHour' {
            return $BaseTime.Date.AddDays([int]$Definition.DayOffset).AddHours([int]$Definition.Hour)
        }
        default {
            return $BaseTime
        }
    }
}

function Get-ForecastDayKeyFromSlot {
    param([string]$SlotKey)

    if ($SlotKey -match '^D(?<Day>\d{1,2})T(?<Hour>\d{1,2})$') {
        return 'D{0}' -f ([int]$Matches.Day)
    }

    return 'Now'
}

function Get-ForecastHourFromSlot {
    param([string]$SlotKey)

    if ($SlotKey -match '^D(?<Day>\d{1,2})T(?<Hour>\d{1,2})$') {
        return [Math]::Max(0, [Math]::Min(23, [int]$Matches.Hour))
    }

    $baseTime = if ($null -ne $script:LatestWeatherModel -and $null -ne $script:LatestWeatherModel.Current.Time) { $script:LatestWeatherModel.Current.Time } else { Get-Date }
    return [int]$baseTime.Hour
}

function Get-ForecastDayDisplay {
    param(
        [int]$DayOffset,
        [DateTime]$Date
    )

    $dateText = $Date.ToString('MM-dd')
    if ($DayOffset -eq 0) {
        return '{0} {1}' -f (Choice '5LuK5aSp' 'Today'), $dateText
    }
    if ($DayOffset -eq 1) {
        return '{0} {1}' -f (Tx 'Tomorrow'), $dateText
    }

    return '+{0}d {1}' -f $DayOffset, $dateText
}

function Select-NearestHourlyForecast {
    param(
        [object[]]$Hourly,
        [DateTime]$TargetTime
    )

    $best = $null
    $bestDiff = [double]::MaxValue
    foreach ($entry in @($Hourly)) {
        if ($null -eq $entry.Time) {
            continue
        }
        $diff = [Math]::Abs(($entry.Time - $TargetTime).TotalMinutes)
        if ($diff -lt $bestDiff) {
            $best = $entry
            $bestDiff = $diff
        }
    }
    return $best
}

function Select-DailyForecastForTime {
    param(
        [object[]]$Daily,
        [DateTime]$TargetTime
    )

    $targetDate = $TargetTime.Date
    $sameDay = @($Daily) | Where-Object { $_.Date -eq $targetDate } | Select-Object -First 1
    if ($null -ne $sameDay) {
        return $sameDay
    }
    return @($Daily) | Select-Object -First 1
}

function ConvertTo-DisplayWeatherSnapshot {
    param(
        [object]$Model,
        [object]$Record,
        [object]$DailyRecord,
        [string]$SlotKey,
        [bool]$IsCurrent,
        [datetime]$Now = (Get-Date)
    )

    $semantics = Resolve-WeatherDisplaySemantics -Model $Model -Now $Now
    $rawCode = $Record.WeatherCode
    $precipitation = if ($null -ne $Record.PrecipitationMm) { $Record.PrecipitationMm } else { 0.0 }
    $rain = if ($null -ne $Record.RainMm) { $Record.RainMm } else { 0.0 }
    $showers = if ($null -ne $Record.ShowersMm) { $Record.ShowersMm } else { 0.0 }
    $rainAmount = [Math]::Max($precipitation, ($rain + $showers))
    $dailyRain = if ($null -ne $DailyRecord -and $null -ne $DailyRecord.PrecipitationSumMm) { $DailyRecord.PrecipitationSumMm } else { $rainAmount }
    $rainProbability = if ($null -ne $Record.PrecipitationProbability) {
        $Record.PrecipitationProbability
    } elseif ($null -ne $DailyRecord -and $null -ne $DailyRecord.PrecipitationProbabilityMax) {
        $DailyRecord.PrecipitationProbabilityMax
    } else {
        0
    }

    $dryCurrentThunderstorm = Test-DryCurrentThunderstormSignal `
        -Code $rawCode `
        -RainAmount $rainAmount `
        -RainProbability $rainProbability `
        -CloudCoverPercent $Record.CloudCoverPercent `
        -IsCurrent $IsCurrent

    $code = if ($dryCurrentThunderstorm) { Get-CloudDerivedWeatherCode -CloudCoverPercent $Record.CloudCoverPercent } else { $rawCode }
    if ($IsCurrent -and $null -ne $semantics.CurrentDisplayWeatherCode) {
        $code = $semantics.CurrentDisplayWeatherCode
    }

    $weatherText = if ($dryCurrentThunderstorm) { Get-WeatherText -Code ([int]$code) } else { Get-LocalizedWeatherText -WeatherText $Record.WeatherText -WeatherCode $code }
    if ([string]::IsNullOrWhiteSpace($weatherText)) {
        $weatherText = Choice '5b2T5YmN5aSp5rCU' 'Current weather'
    }

    [pscustomobject]@{
        Source = $Model.Source
        SourceTime = if ($IsCurrent -and $null -ne $Model.PSObject.Properties['SourceTime'] -and -not [string]::IsNullOrWhiteSpace([string]$Model.SourceTime)) {
            $Model.SourceTime
        } elseif ($null -ne $Record.Time) {
            $Record.Time.ToString('HH:mm')
        } else {
            'current'
        }
        SourceTimestamp = $Record.Time
        SlotKey = $SlotKey
        IsCurrent = $IsCurrent
        SlotTime = $Record.Time
        WeatherCode = $code
        RawWeatherCode = $rawCode
        WeatherText = $weatherText
        CurrentCondition = $semantics.CurrentCondition
        CurrentWeatherCode = $semantics.CurrentWeatherCode
        CurrentPrecipitation = $semantics.CurrentPrecipitation
        CurrentRain = $semantics.CurrentRain
        CurrentIntervalSeconds = $semantics.CurrentIntervalSeconds
        CurrentDataTime = $semantics.CurrentDataTime
        CurrentDataKind = $semantics.CurrentDataKind
        CurrentIsStrongRain = $semantics.CurrentIsStrongRain
        CurrentIsRainstorm = $semantics.CurrentIsRainstorm
        NearTermForecast = $semantics.NearTermForecast
        NearTermForecastTime = $semantics.NearTermForecastTime
        NearTermWeatherCode = $semantics.NearTermWeatherCode
        NearTermPrecipitation = $semantics.NearTermPrecipitation
        WarningText = $semantics.WarningText
        WarningLevel = $semantics.WarningLevel
        Diagnostics = @($semantics.Diagnostics)
        TemperatureC = $Record.TemperatureC
        FeelsLikeC = $Record.FeelsLikeC
        HumidityPercent = $Record.HumidityPercent
        DewPointC = $Record.DewPointC
        CloudCoverPercent = $Record.CloudCoverPercent
        PressureHpa = if ($null -ne $Record.SurfacePressureHpa) { $Record.SurfacePressureHpa } else { $Record.PressureMslHpa }
        PressureMslHpa = $Record.PressureMslHpa
        SurfacePressureHpa = $Record.SurfacePressureHpa
        WindKmh = $Record.WindKmh
        WindDirectionDeg = $Record.WindDirectionDeg
        WindGustKmh = $Record.WindGustKmh
        UvIndex = if ($null -ne $Record.UvIndex) { $Record.UvIndex } elseif ($null -ne $DailyRecord) { $DailyRecord.UvIndexMax } else { $null }
        VisibilityM = $Record.VisibilityM
        RainNowMm = $rainAmount
        TodayRainMm = $dailyRain
        RainProbability = $rainProbability
        IsDay = $Record.IsDay
        IsRainingNow = if ($IsCurrent) { [bool]$semantics.CurrentIsRaining } else { ($rainAmount -gt 0 -or (Test-RainWeatherCode -Code $code)) }
        IsThunderstorm = Test-ThunderWeatherCode -Code $code
        UiSmokeAlertText = Get-PropertyValue -Object $Model -Name 'UiSmokeAlertText'
        LocationKey = Get-PropertyValue -Object $Model -Name 'LocationKey'
        FetchedAt = Get-PropertyValue -Object $Model -Name 'FetchedAt'
        IsCacheData = [bool](Get-PropertyValue -Object $Model -Name 'IsCacheData' -Default $false)
    }
}
function Get-WeatherSnapshotFromModel {
    param(
        [object]$Model,
        [string]$SlotKey = $script:SelectedForecastSlotKey,
        [datetime]$Now = (Get-Date)
    )

    $definition = Get-ForecastSlotDefinition -SlotKey $SlotKey
    $baseTime = if ($null -ne $Model.Current.Time) { $Model.Current.Time } else { $Now }

    if ($definition.Kind -eq 'Current' -or -not $Model.SupportsForecastSlots -or @($Model.Hourly).Count -eq 0) {
        $daily = Select-DailyForecastForTime -Daily @($Model.Daily) -TargetTime $baseTime
        return ConvertTo-DisplayWeatherSnapshot -Model $Model -Record $Model.Current -DailyRecord $daily -SlotKey 'Now' -IsCurrent $true -Now $Now
    }

    $target = Get-ForecastTargetTime -Definition $definition -BaseTime $baseTime
    $hourly = Select-NearestHourlyForecast -Hourly @($Model.Hourly) -TargetTime $target
    if ($null -eq $hourly) {
        $daily = Select-DailyForecastForTime -Daily @($Model.Daily) -TargetTime $baseTime
        return ConvertTo-DisplayWeatherSnapshot -Model $Model -Record $Model.Current -DailyRecord $daily -SlotKey 'Now' -IsCurrent $true -Now $Now
    }

    $dailyRecord = Select-DailyForecastForTime -Daily @($Model.Daily) -TargetTime $hourly.Time
    return ConvertTo-DisplayWeatherSnapshot -Model $Model -Record $hourly -DailyRecord $dailyRecord -SlotKey $definition.Key -IsCurrent $false -Now $Now
}
function Format-ForecastModeLabel {
    param([object]$Snapshot)

    if ($null -eq $Snapshot -or $Snapshot.IsCurrent) {
        return Tx 'Now'
    }

    $slotTime = if ($null -ne $Snapshot.SlotTime) { $Snapshot.SlotTime.ToString('MM-dd HH:mm') } else { $Snapshot.SourceTime }
    return '{0} {1} {2}' -f (Tx 'Forecast'), ([char]0x00B7), $slotTime
}

function Get-WeatherConditionDisplayText {
    param([object]$Snapshot)

    if ($null -eq $Snapshot) {
        return Tx 'WeatherUnavailable'
    }

    if ($null -ne $Snapshot.PSObject.Properties['CurrentCondition'] -and -not [string]::IsNullOrWhiteSpace([string]$Snapshot.CurrentCondition)) {
        return Convert-WeatherDisplayTextForLanguage -Text ([string]$Snapshot.CurrentCondition)
    }

    if ($null -ne $Snapshot.PSObject.Properties['WeatherText'] -and -not [string]::IsNullOrWhiteSpace([string]$Snapshot.WeatherText)) {
        return Get-LocalizedWeatherText -WeatherText $Snapshot.WeatherText -WeatherCode (Get-PropertyValue -Object $Snapshot -Name 'WeatherCode')
    }

    if ($null -ne $Snapshot.PSObject.Properties['WeatherCode'] -and $null -ne $Snapshot.WeatherCode) {
        return Get-WeatherText -Code ([int]$Snapshot.WeatherCode)
    }

    return Tx 'Weather'
}
function Get-WeatherStatusDisplayText {
    param([object]$Snapshot)

    if ($null -ne $Snapshot -and $null -ne $Snapshot.PSObject.Properties['IsCacheData'] -and [bool]$Snapshot.IsCacheData) {
        return Tx 'CachedData'
    }

    return Tx 'Live'
}

function Format-CachedNearTermForecastText {
    param(
        [string]$Text,
        [datetime]$FetchedAt = [datetime]::MinValue
    )

    $core = if ([string]::IsNullOrWhiteSpace($Text)) { Tx 'NearTermUnavailable' } else { Convert-WeatherDisplayTextForLanguage -Text ([string]$Text) }

    $label = (Tx 'CachedNearTerm') -f $core
    if ($FetchedAt -ne [datetime]::MinValue) {
        return '{0} {1}' -f $label, $FetchedAt.ToString('HH:mm:ss')
    }

    return $label
}
function Set-ObjectNoteProperty {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Value
    )

    if ($null -eq $Object) {
        return
    }

    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Set-WeatherModelMetadata {
    param(
        [object]$Model,
        [string]$LocationKey,
        [datetime]$FetchedAt,
        [bool]$IsCacheData = $false
    )

    if ($null -eq $Model) {
        return $null
    }

    if ($FetchedAt -eq [datetime]::MinValue) {
        $FetchedAt = Get-Date
    }

    $source = Get-PropertyValue -Object $Model -Name 'Source' -Default 'unknown'
    Set-ObjectNoteProperty -Object $Model -Name 'LocationKey' -Value $LocationKey
    Set-ObjectNoteProperty -Object $Model -Name 'FetchedAt' -Value $FetchedAt
    Set-ObjectNoteProperty -Object $Model -Name 'DataSource' -Value $source
    Set-ObjectNoteProperty -Object $Model -Name 'IsCacheData' -Value $IsCacheData
    return $Model
}

function New-WeatherCacheEntry {
    param(
        [string]$LocationKey,
        [object]$Model,
        [datetime]$FetchedAt
    )

    [pscustomobject]@{
        LocationKey = $LocationKey
        Model = $Model
        FetchedAt = $FetchedAt
        Source = Get-PropertyValue -Object $Model -Name 'Source' -Default 'unknown'
        IsCacheData = $true
    }
}

function Save-WeatherModelCache {
    param(
        [string]$LocationKey,
        [object]$Model,
        [datetime]$FetchedAt = (Get-Date)
    )

    $modelWithMetadata = Set-WeatherModelMetadata -Model $Model -LocationKey $LocationKey -FetchedAt $FetchedAt -IsCacheData $false
    $entry = New-WeatherCacheEntry -LocationKey $LocationKey -Model $modelWithMetadata -FetchedAt $FetchedAt
    $script:WeatherModelCache[$LocationKey] = $entry
    $script:LatestWeatherModel = $modelWithMetadata
    $script:LatestWeatherLocationKey = $LocationKey
    $script:LatestWeatherFetchedAt = $FetchedAt
    $script:LatestWeatherDataSource = $entry.Source
    $script:LatestWeatherIsCacheData = $false
    return $entry
}

function Get-WeatherCacheEntry {
    param([string]$LocationKey)

    if ([string]::IsNullOrWhiteSpace($LocationKey)) {
        return $null
    }

    if ($null -ne $script:WeatherModelCache -and $script:WeatherModelCache.ContainsKey($LocationKey)) {
        return $script:WeatherModelCache[$LocationKey]
    }

    return $null
}

function Clear-ActiveWeatherModelForLocationChange {
    $script:LatestWeatherModel = $null
    $script:LatestWeatherLocationKey = $null
    $script:LatestWeatherFetchedAt = $null
    $script:LatestWeatherDataSource = $null
    $script:LatestWeatherIsCacheData = $false
}

function Set-UiSmokeItemStatus {
    param(
        [string]$State,
        [string]$LocationKey = (Get-SelectedLocationKey),
        [int]$RequestId = [int]$script:ActiveWeatherRequestId
    )
    if (-not $script:UiSmokeMode -or $null -eq $window) { return }
    $selectionCount = if ($null -ne $script:UiSmokeSelectionChangedCount) { [int]$script:UiSmokeSelectionChangedCount } else { 0 }
    $status = 'State={0};LocationKey={1};RequestId={2};SelectionChangedCount={3}' -f $State, $LocationKey, $RequestId, $selectionCount
    try { $window.SetValue([System.Windows.Automation.AutomationProperties]::ItemStatusProperty, $status) } catch {}
    try { if ($null -ne $border) { $border.SetValue([System.Windows.Automation.AutomationProperties]::ItemStatusProperty, $status) } } catch {}
}
function Start-WeatherRequestContext {
    param([string]$LocationKey = (Get-SelectedLocationKey))

    $script:WeatherRequestSequence++
    $script:ActiveWeatherRequestId = $script:WeatherRequestSequence
    $script:ActiveWeatherRequestLocationKey = $LocationKey
    Set-UiSmokeItemStatus -State 'Loading' -LocationKey $LocationKey -RequestId $script:WeatherRequestSequence

    [pscustomobject]@{
        RequestId = $script:WeatherRequestSequence
        LocationKey = $LocationKey
        ProvinceKey = $script:SelectedProvinceKey
        CityKey = $script:SelectedCityKey
        DistrictKey = $script:SelectedDistrictKey
        StartedAt = Get-Date
    }
}

function Test-WeatherRequestIsCurrent {
    param([object]$Request)

    if ($null -eq $Request) {
        return $false
    }

    if ([int]$Request.RequestId -ne [int]$script:ActiveWeatherRequestId) {
        return $false
    }

    if ([string]$Request.LocationKey -ne [string]$script:ActiveWeatherRequestLocationKey) {
        return $false
    }

    return ((Get-SelectedLocationKey) -eq [string]$Request.LocationKey)
}

function Test-WeatherModelMatchesLocation {
    param(
        [object]$Model,
        [string]$LocationKey
    )

    $modelLocationKey = Get-PropertyValue -Object $Model -Name 'LocationKey'
    if ([string]::IsNullOrWhiteSpace([string]$modelLocationKey)) {
        return $true
    }

    return ([string]$modelLocationKey -eq [string]$LocationKey)
}

function Resolve-WeatherRequestSuccess {
    param(
        [object]$Request,
        [object]$Model,
        [datetime]$FetchedAt = (Get-Date)
    )

    if (-not (Test-WeatherRequestIsCurrent -Request $Request)) {
        return [pscustomobject]@{ ShouldApply = $false; Status = 'StaleRequest'; LocationKey = $Request.LocationKey; Model = $null; UseCache = $false }
    }

    if (-not (Test-WeatherModelMatchesLocation -Model $Model -LocationKey $Request.LocationKey)) {
        return [pscustomobject]@{ ShouldApply = $false; Status = 'LocationMismatch'; LocationKey = $Request.LocationKey; Model = $null; UseCache = $false }
    }

    $entry = Save-WeatherModelCache -LocationKey $Request.LocationKey -Model $Model -FetchedAt $FetchedAt
    return [pscustomobject]@{ ShouldApply = $true; Status = 'Success'; LocationKey = $Request.LocationKey; Model = $entry.Model; CacheEntry = $entry; UseCache = $false }
}

function Resolve-WeatherRequestFailure {
    param(
        [object]$Request,
        [string]$ErrorMessage = ''
    )

    if (-not (Test-WeatherRequestIsCurrent -Request $Request)) {
        return [pscustomobject]@{ ShouldApply = $false; Status = 'StaleRequest'; LocationKey = $Request.LocationKey; Model = $null; UseCache = $false; ErrorMessage = $ErrorMessage }
    }

    $entry = Get-WeatherCacheEntry -LocationKey $Request.LocationKey
    if ($null -ne $entry) {
        $cachedModel = Set-WeatherModelMetadata -Model $entry.Model -LocationKey $Request.LocationKey -FetchedAt $entry.FetchedAt -IsCacheData $true
        $script:LatestWeatherModel = $cachedModel
        $script:LatestWeatherLocationKey = $Request.LocationKey
        $script:LatestWeatherFetchedAt = $entry.FetchedAt
        $script:LatestWeatherDataSource = $entry.Source
        $script:LatestWeatherIsCacheData = $true
        return [pscustomobject]@{ ShouldApply = $true; Status = 'Cache'; LocationKey = $Request.LocationKey; Model = $cachedModel; CacheEntry = $entry; UseCache = $true; ErrorMessage = $ErrorMessage }
    }

    Clear-ActiveWeatherModelForLocationChange
    return [pscustomobject]@{ ShouldApply = $true; Status = 'NoCache'; LocationKey = $Request.LocationKey; Model = $null; UseCache = $false; ErrorMessage = $ErrorMessage }
}

function Get-WeatherUrls {
    $location = Get-SelectedWeatherLocation
    $lat = $location.Lat.ToString([Globalization.CultureInfo]::InvariantCulture)
    $lon = $location.Lon.ToString([Globalization.CultureInfo]::InvariantCulture)
    $openMeteo = [string]::Concat(
        'https://api.open-meteo.com/v1/forecast?latitude=',
        $lat,
        '&longitude=',
        $lon,
        '&current=',
        $script:CurrentFields,
        '&hourly=',
        $script:HourlyFields,
        '&daily=',
        $script:DailyFields,
        '&timezone=auto',
        '&forecast_days=',
        [string]$script:ForecastDayCount,
        '&forecast_hours=',
        [string]$script:ForecastHourCount,
        '&temperature_unit=celsius',
        '&wind_speed_unit=kmh',
        '&precipitation_unit=mm'
    )
    $wttr = [string]::Concat('https://wttr.in/', $lat, ',', $lon, '?format=j1')

    [pscustomobject]@{
        OpenMeteo = $openMeteo
        Wttr = $wttr
    }
}

function Get-OpenMeteoForecastModel {
    $urls = Get-WeatherUrls
    $json = $script:Client.DownloadString($urls.OpenMeteo + '&_=' + [DateTimeOffset]::Now.ToUnixTimeSeconds())
    $weather = $json | ConvertFrom-Json
    return ConvertTo-OpenMeteoForecastModel -Weather $weather
}

function Get-WttrForecastModel {
    $urls = Get-WeatherUrls
    $json = $script:Client.DownloadString($urls.Wttr + '&_=' + [DateTimeOffset]::Now.ToUnixTimeSeconds())
    $weather = $json | ConvertFrom-Json
    $current = @($weather.current_condition)[0]
    $today = @($weather.weather)[0]
    $hourly = @($today.hourly)

    $todayRain = 0.0
    $rainProb = 0
    foreach ($hour in $hourly) {
        if ($null -ne $hour.precipMM -and ([string]$hour.precipMM) -ne '') {
            $todayRain += [double]$hour.precipMM
        }
        if ($null -ne $hour.chanceofrain -and ([string]$hour.chanceofrain) -ne '') {
            $rainProb = [Math]::Max($rainProb, [int]$hour.chanceofrain)
        }
    }

    $rawText = ''
    if ($current.weatherDesc) {
        $rawText = @($current.weatherDesc)[0].value
    }

    $sourceTime = $current.localObsDateTime
    if ([string]::IsNullOrWhiteSpace($sourceTime)) {
        $sourceTime = $current.observation_time
    }
    if ([string]::IsNullOrWhiteSpace($sourceTime)) {
        $sourceTime = 'current'
    }

    $rainNow = [double]$current.precipMM

    $currentRecord = [pscustomobject]@{
        Time = $Time
        TemperatureC = [double]$current.temp_C
        HumidityPercent = [double]$current.humidity
        DewPointC = $null
        FeelsLikeC = [double]$current.FeelsLikeC
        PrecipitationProbability = $null
        PrecipitationMm = $rainNow
        RainMm = $rainNow
        ShowersMm = 0.0
        WeatherCode = $null
        CloudCoverPercent = ConvertTo-NullableDouble (Get-PropertyValue -Object $current -Name 'cloudcover')
        PressureMslHpa = [double]$current.pressure
        SurfacePressureHpa = [double]$current.pressure
        VisibilityM = $null
        WindKmh = [double]$current.windspeedKmph
        WindDirectionDeg = ConvertTo-NullableDouble (Get-PropertyValue -Object $current -Name 'winddirDegree')
        WindGustKmh = ConvertTo-NullableDouble (Get-PropertyValue -Object $current -Name 'WindGustKmph')
        UvIndex = ConvertTo-NullableDouble (Get-PropertyValue -Object $current -Name 'uvIndex')
        IsDay = $null
        WeatherText = Get-WttrWeatherText -Text $rawText
    }

    $dailyRecord = [pscustomobject]@{
        Date = (Get-Date).Date
        WeatherCode = $null
        TemperatureMaxC = $null
        TemperatureMinC = $null
        FeelsLikeMaxC = $null
        FeelsLikeMinC = $null
        Sunrise = $null
        Sunset = $null
        DaylightSeconds = $null
        SunshineSeconds = $null
        UvIndexMax = $currentRecord.UvIndex
        PrecipitationSumMm = $todayRain
        RainSumMm = $todayRain
        PrecipitationHours = $null
        PrecipitationProbabilityMax = $rainProb
        WindSpeedMaxKmh = $currentRecord.WindKmh
        WindGustMaxKmh = $currentRecord.WindGustKmh
        WindDirectionDominantDeg = $currentRecord.WindDirectionDeg
    }

    [pscustomobject]@{
        Source = 'wttr.in'
        SourceTime = $sourceTime
        Timezone = 'local'
        Current = $currentRecord
        Hourly = @()
        Daily = @($dailyRecord)
        SupportsForecastSlots = $false
        AirQuality = $null
        RawText = $rawText
    }
}

function Get-UiSmokeCommand {
    if (-not $script:UiSmokeMode -or [string]::IsNullOrWhiteSpace($script:UiSmokeOutput)) {
        return [pscustomobject]@{}
    }

    $commandPath = Join-Path $script:UiSmokeOutput 'ui-smoke-command.json'
    if (-not (Test-Path -LiteralPath $commandPath)) {
        return [pscustomobject]@{}
    }

    try {
        return Get-Content -LiteralPath $commandPath -Raw | ConvertFrom-Json
    } catch {
        return [pscustomobject]@{}
    }
}

function New-UiSmokeRecord {
    param(
        [datetime]$Time = (Get-Date),
        [double]$TemperatureC,
        [int]$WeatherCode,
        [string]$WeatherText,
        [double]$RainMm = 0.0,
        [double]$HumidityPercent = 65.0,
        [double]$PressureHpa = 1008.0,
        [double]$WindKmh = 12.0,
        [double]$CloudCoverPercent = 40.0,
        [double]$PrecipitationProbability = 10.0,
        [Nullable[int]]$IntervalSeconds = $null
    )

    [pscustomobject]@{
        Time = $Time
        TemperatureC = $TemperatureC
        HumidityPercent = $HumidityPercent
        DewPointC = $null
        FeelsLikeC = $TemperatureC
        PrecipitationMm = $RainMm
        RainMm = $RainMm
        ShowersMm = 0.0
        WeatherCode = $WeatherCode
        CloudCoverPercent = $CloudCoverPercent
        PressureMslHpa = $PressureHpa
        SurfacePressureHpa = $PressureHpa
        WindKmh = $WindKmh
        WindDirectionDeg = 135.0
        WindGustKmh = [Math]::Max($WindKmh, $WindKmh + 5.0)
        UvIndex = 2.0
        VisibilityM = 10000.0
        IsDay = 1
        IntervalSeconds = $IntervalSeconds
        WeatherText = $WeatherText
        PrecipitationProbability = $PrecipitationProbability
    }
}
function New-UiSmokeWeatherModel {
    param(
        [double]$TemperatureC,
        [int]$WeatherCode,
        [string]$WeatherText,
        [string]$AlertText = $null,
        [string]$WarningLevel = '',
        [double]$RainMm = 0.0,
        [double]$HumidityPercent = 65.0,
        [double]$PressureHpa = 1008.0,
        [double]$WindKmh = 12.0,
        [double]$CloudCoverPercent = 40.0,
        [double]$PrecipitationProbability = 10.0,
        [Nullable[int]]$ForecastWeatherCode = $null,
        [double]$ForecastRainMm = 0.0,
        [int]$ForecastMinutesAhead = 45,
        [Nullable[int]]$CurrentIntervalSeconds = $null
    )

    $now = Get-Date
    $record = New-UiSmokeRecord -Time $now -TemperatureC $TemperatureC -WeatherCode $WeatherCode -WeatherText $WeatherText -RainMm $RainMm -HumidityPercent $HumidityPercent -PressureHpa $PressureHpa -WindKmh $WindKmh -CloudCoverPercent $CloudCoverPercent -PrecipitationProbability $PrecipitationProbability -IntervalSeconds $CurrentIntervalSeconds
    $hourly = @($record)
    if ($null -ne $ForecastWeatherCode) {
        $forecastText = Get-WeatherText -Code ([int]$ForecastWeatherCode)
        $hourly += New-UiSmokeRecord -Time ($now.AddMinutes($ForecastMinutesAhead)) -TemperatureC ($TemperatureC - 0.6) -WeatherCode ([int]$ForecastWeatherCode) -WeatherText $forecastText -RainMm $ForecastRainMm -HumidityPercent ([Math]::Min(99.0, $HumidityPercent + 12.0)) -PressureHpa ($PressureHpa - 1.0) -WindKmh ([Math]::Max($WindKmh, $WindKmh + 8.0)) -CloudCoverPercent 100.0 -PrecipitationProbability 95.0 -IntervalSeconds 3600
    }

    $dailyRain = [Math]::Max($RainMm, $ForecastRainMm)
    $daily = [pscustomobject]@{
        Date = $now.Date
        WeatherCode = if ($null -ne $ForecastWeatherCode) { [int]$ForecastWeatherCode } else { $WeatherCode }
        TemperatureMaxC = $TemperatureC
        TemperatureMinC = $TemperatureC
        FeelsLikeMaxC = $TemperatureC
        FeelsLikeMinC = $TemperatureC
        Sunrise = $null
        Sunset = $null
        DaylightDuration = $null
        SunshineDuration = $null
        UvIndexMax = 2.0
        PrecipitationSumMm = $dailyRain
        RainSumMm = $dailyRain
        PrecipitationHours = if ($dailyRain -gt 0) { 1.0 } else { 0.0 }
        PrecipitationProbabilityMax = [Math]::Max($PrecipitationProbability, $(if ($null -ne $ForecastWeatherCode) { 95.0 } else { 0.0 }))
        WindSpeedMaxKmh = $WindKmh
        WindGustMaxKmh = [Math]::Max($WindKmh, $WindKmh + 5.0)
        WindDirectionDeg = 135.0
    }

    [pscustomobject]@{
        Source = 'UiSmokeFixture'
        SourceTime = $now.ToString('HH:mm')
        Timezone = 'Asia/Shanghai'
        Current = $record
        Hourly = @($hourly)
        Daily = @($daily)
        SupportsForecastSlots = $true
        AirQuality = $null
        LocationKey = Get-SelectedLocationKey
        FetchedAt = $now
        IsCacheData = $false
        WarningText = $AlertText
        WarningLevel = $WarningLevel
        UiSmokeAlertText = $AlertText
    }
}
function Get-UiSmokeWeatherModel {
    $command = Get-UiSmokeCommand
    $mode = if ($null -ne $command.PSObject.Properties['Mode']) { [string]$command.Mode } else { '' }
    $districtKey = [string]$script:SelectedDistrictKey
    $fixture = [string]$script:UiFixture

    if ($mode -eq 'Delay') {
        Start-Sleep -Milliseconds 1200
    }

    switch ($fixture) {
        'current-no-rain-future-heavy-rain' {
            return New-UiSmokeWeatherModel -TemperatureC 29.5 -WeatherCode 3 -WeatherText (Get-WeatherText -Code 3) -RainMm 0.0 -HumidityPercent 72.0 -PressureHpa 1004.0 -WindKmh 9.0 -CloudCoverPercent 96.0 -PrecipitationProbability 10.0 -ForecastWeatherCode 65 -ForecastRainMm 12.0 -ForecastMinutesAhead 45
        }
        'current-no-rain-with-warning' {
            return New-UiSmokeWeatherModel -TemperatureC 29.5 -WeatherCode 3 -WeatherText (Get-WeatherText -Code 3) -AlertText (T '5rex5Zyz5biC5by66ZmN6Zuo6aOO6Zmp5o+Q56S6') -WarningLevel 'ModelTip' -RainMm 0.0 -HumidityPercent 72.0 -PressureHpa 1004.0 -WindKmh 9.0 -CloudCoverPercent 96.0 -PrecipitationProbability 10.0 -ForecastWeatherCode 65 -ForecastRainMm 12.0 -ForecastMinutesAhead 75
        }
        'current-heavy-rain' {
            return New-UiSmokeWeatherModel -TemperatureC 27.8 -WeatherCode 65 -WeatherText (Get-WeatherText -Code 65) -AlertText (T '5rex5Zyz5biC5by66ZmN6Zuo6aOO6Zmp5o+Q56S6') -WarningLevel 'ModelTip' -RainMm 16.0 -CurrentIntervalSeconds 3600 -HumidityPercent 91.0 -PressureHpa 1001.0 -WindKmh 18.0 -CloudCoverPercent 100.0 -PrecipitationProbability 95.0
        }
    }

    if ($districtKey -eq 'SmokeB') {
        if ($mode -eq 'FailDelay') {
            Start-Sleep -Milliseconds 1600
            throw 'UiSmoke simulated B request failure.'
        }
        if ($mode -eq 'Fail') {
            throw 'UiSmoke simulated B request failure.'
        }
        if ($mode -eq 'SlowSuccess') {
            Start-Sleep -Milliseconds 1400
        }
        return New-UiSmokeWeatherModel -TemperatureC 22.2 -WeatherCode 3 -WeatherText (Choice '5aSa5LqR' 'Cloudy') -RainMm 0.0 -HumidityPercent 58.0 -PressureHpa 1006.0 -WindKmh 9.0 -CloudCoverPercent 72.0 -PrecipitationProbability 5.0
    }

    if ($districtKey -eq 'SmokeC') {
        return New-UiSmokeWeatherModel -TemperatureC 33.3 -WeatherCode 0 -WeatherText (Choice '5pm0' 'Clear') -RainMm 0.0 -HumidityPercent 42.0 -PressureHpa 1012.0 -WindKmh 6.0 -CloudCoverPercent 5.0 -PrecipitationProbability 0.0
    }

    return New-UiSmokeWeatherModel -TemperatureC 11.1 -WeatherCode 95 -WeatherText (Choice '6Zu36Zuo' 'Thunderstorm') -AlertText (Choice 'QSDlnLDljLrpm7fmmrTpooToraY=' 'Area A thunderstorm alert') -RainMm 6.6 -HumidityPercent 88.0 -PressureHpa 996.0 -WindKmh 24.0 -CloudCoverPercent 96.0 -PrecipitationProbability 90.0
}
function Get-WeatherModel {
    if ($script:UiSmokeMode -and [string]$script:UiFixture -ne 'Live') {
        return Get-UiSmokeWeatherModel
    }

    try {
        return Get-OpenMeteoForecastModel
    } catch {
        if ($_.Exception.Message -like 'LOCATION_DATA_FAIL:*') { throw }
        return Get-WttrForecastModel
    }
}

if ($TestMode -or $env:LONGHUA_WEATHER_WIDGET_TEST_MODE -eq '1') {
    return
}

Load-Settings
Reset-RefreshCountdown

$window = New-Object System.Windows.Window
$window.Title = if ($script:UiSmokeMode) { "LonghuaWeatherWidget-UiSmoke-$PID" } else { 'LonghuaWeatherWidget - Anthropic-inspired Edition' }
$window.Width = $script:WindowExpandedWidth
$window.Height = $script:WindowClosedHeight
$window.WindowStyle = 'None'
$window.ResizeMode = 'NoResize'
$window.AllowsTransparency = $true
$window.Background = 'Transparent'
$window.ShowInTaskbar = [bool]$script:UiSmokeMode
$window.Topmost = if ($script:UiSmokeMode) { $true } else { -not $NoTopMost }

$border = New-Object System.Windows.Controls.Border
$border.CornerRadius = 14
$border.Padding = '12'
$border.ClipToBounds = $true
$border.Background = New-XamlObject @'
<LinearGradientBrush xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" StartPoint="0,0" EndPoint="1,1">
    <GradientStop Color="#FFFAF9F5" Offset="0"/>
    <GradientStop Color="#FFF3F1EA" Offset="0.55"/>
    <GradientStop Color="#FFFFFFFF" Offset="1"/>
</LinearGradientBrush>
'@
$border.BorderBrush = '#00FFFFFF'
$border.BorderThickness = 0
$border.Effect = New-GlowEffect -Color '#D8D4C8' -BlurRadius 18 -ShadowDepth 4 -Opacity 0.18
$script:WidgetBorderBackground = $border.Background
$script:WidgetBorderEffect = $border.Effect

$surfaceGrid = New-Object System.Windows.Controls.Grid
$surfaceGrid.ClipToBounds = $false
$border.Child = $surfaceGrid

$panelGlowTransform = New-Object System.Windows.Media.TranslateTransform
$panelGlow = New-Object System.Windows.Controls.Border
$panelGlow.Width = 210
$panelGlow.Height = 210
$panelGlow.HorizontalAlignment = 'Left'
$panelGlow.VerticalAlignment = 'Top'
$panelGlow.Opacity = 0.18
$panelGlow.IsHitTestVisible = $false
$panelGlow.RenderTransform = $panelGlowTransform
$panelGlow.Background = New-XamlObject @'
<RadialGradientBrush xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Center="0.5,0.5" GradientOrigin="0.5,0.5" RadiusX="0.56" RadiusY="0.56">
    <GradientStop Color="#55F3DED5" Offset="0"/>
    <GradientStop Color="#22D8D4C8" Offset="0.42"/>
    <GradientStop Color="#00FAF9F5" Offset="1"/>
</RadialGradientBrush>
'@
$surfaceGrid.Children.Add($panelGlow) | Out-Null

$panelSheen = New-Object System.Windows.Controls.Border
$panelSheen.IsHitTestVisible = $false
$panelSheen.Opacity = 0.26
$panelSheen.Background = New-XamlObject @'
<LinearGradientBrush xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" StartPoint="0,0" EndPoint="1,1">
    <GradientStop Color="#66FFFFFF" Offset="0"/>
    <GradientStop Color="#18D8D4C8" Offset="0.36"/>
    <GradientStop Color="#00FAF9F5" Offset="1"/>
</LinearGradientBrush>
'@
$surfaceGrid.Children.Add($panelSheen) | Out-Null

$rainLayer = New-Object System.Windows.Controls.Canvas
$rainLayer.IsHitTestVisible = $false
$rainLayer.Visibility = [System.Windows.Visibility]::Collapsed
$rainLayer.Opacity = 0.0
for ($i = 0; $i -lt 18; $i++) {
    $streak = New-Object System.Windows.Controls.Border
    $streak.Width = 1.2
    $streak.Height = 42 + (($i % 4) * 8)
    $streak.CornerRadius = 1
    $streak.Opacity = 0.20 + (($i % 3) * 0.04)
    $streak.Background = New-XamlObject @'
<LinearGradientBrush xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" StartPoint="0,0" EndPoint="0,1">
    <GradientStop Color="#00F5A7C7" Offset="0"/>
    <GradientStop Color="#88D97757" Offset="0.45"/>
    <GradientStop Color="#00F5A7C7" Offset="1"/>
</LinearGradientBrush>
'@
    $streak.RenderTransform = New-Object System.Windows.Media.RotateTransform -ArgumentList 14
    [System.Windows.Controls.Canvas]::SetLeft($streak, 18 + ($i * 21 % 340))
    [System.Windows.Controls.Canvas]::SetTop($streak, -20 + ($i * 31 % 470))
    $rainLayer.Children.Add($streak) | Out-Null
}
$surfaceGrid.Children.Add($rainLayer) | Out-Null

$lightningLayer = New-Object System.Windows.Controls.Border
$lightningLayer.IsHitTestVisible = $false
$lightningLayer.Visibility = [System.Windows.Visibility]::Collapsed
$lightningLayer.Opacity = 0.0
$lightningLayer.Background = New-XamlObject @'
<RadialGradientBrush xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Center="0.74,0.12" GradientOrigin="0.74,0.12" RadiusX="0.92" RadiusY="0.78">
    <GradientStop Color="#B9FFFFFF" Offset="0"/>
    <GradientStop Color="#42F3DED5" Offset="0.30"/>
    <GradientStop Color="#00FAF9F5" Offset="1"/>
</RadialGradientBrush>
'@
$surfaceGrid.Children.Add($lightningLayer) | Out-Null

$scrollViewer = New-Object System.Windows.Controls.ScrollViewer
$scrollViewer.VerticalScrollBarVisibility = 'Hidden'
$scrollViewer.HorizontalScrollBarVisibility = 'Disabled'
$scrollViewer.CanContentScroll = $false
$scrollViewer.PanningMode = 'VerticalOnly'
$scrollViewer.Background = 'Transparent'
$surfaceGrid.Children.Add($scrollViewer) | Out-Null

$drawerHandle = New-Object System.Windows.Controls.Border
$drawerHandle.Width = Get-DrawerVisibleStrip
$drawerHandle.Height = 92
$drawerHandle.VerticalAlignment = 'Center'
$drawerHandle.Background = '#F7D97757'
$drawerHandle.BorderBrush = '#00FFFFFF'
$drawerHandle.BorderThickness = 0
$drawerHandle.Cursor = [System.Windows.Input.Cursors]::Hand
$drawerHandle.Focusable = $true
$drawerHandle.FocusVisualStyle = $null
$drawerHandle.Visibility = [System.Windows.Visibility]::Collapsed
$drawerHandle.ToolTip = Tx 'DrawerExpand'
$drawerHandle.SetValue([System.Windows.Input.KeyboardNavigation]::IsTabStopProperty, $true)
$drawerHandle.Effect = $null
$drawerHandleCanvas = New-Object System.Windows.Controls.Canvas
$drawerHandleCanvas.Width = 22
$drawerHandleCanvas.Height = 34
$drawerHandleCanvas.HorizontalAlignment = 'Center'
$drawerHandleCanvas.VerticalAlignment = 'Center'
$drawerHandleLineA = New-Object System.Windows.Shapes.Line
$drawerHandleLineA.Stroke = '#FFFFFFFF'
$drawerHandleLineA.StrokeThickness = 3
$drawerHandleLineA.StrokeStartLineCap = [System.Windows.Media.PenLineCap]::Round
$drawerHandleLineA.StrokeEndLineCap = [System.Windows.Media.PenLineCap]::Round
$drawerHandleLineB = New-Object System.Windows.Shapes.Line
$drawerHandleLineB.Stroke = '#FFFFFFFF'
$drawerHandleLineB.StrokeThickness = 3
$drawerHandleLineB.StrokeStartLineCap = [System.Windows.Media.PenLineCap]::Round
$drawerHandleLineB.StrokeEndLineCap = [System.Windows.Media.PenLineCap]::Round
$drawerHandleCanvas.Children.Add($drawerHandleLineA) | Out-Null
$drawerHandleCanvas.Children.Add($drawerHandleLineB) | Out-Null
$drawerHandleHost = New-Object System.Windows.Controls.Grid
$drawerHandleHost.Children.Add($drawerHandleCanvas) | Out-Null
$drawerHandleAutomationButton = New-Object System.Windows.Controls.Button
$drawerHandleAutomationButton.Background = 'Transparent'
$drawerHandleAutomationButton.BorderThickness = 0
$drawerHandleAutomationButton.Opacity = 0.01
$drawerHandleAutomationButton.Focusable = $true
$drawerHandleAutomationButton.Cursor = [System.Windows.Input.Cursors]::Hand
$drawerHandleAutomationButton.ToolTip = Tx 'DrawerExpand'
Set-ControlAutomationId -Control $drawerHandleAutomationButton -AutomationId 'DrawerHandle'
Set-ControlAutomationName -Control $drawerHandleAutomationButton -Name (Tx 'DrawerExpand')
$drawerHandleAutomationButton.Add_Click({ Expand-WindowDrawer -Window $window }.GetNewClosure())
$drawerHandleHost.Children.Add($drawerHandleAutomationButton) | Out-Null

$drawerHandle.Child = $drawerHandleHost
$surfaceGrid.Children.Add($drawerHandle) | Out-Null
Update-DrawerHandleVisual
$drawerHandle.Add_MouseLeftButtonUp({
    param($sender, $eventArgs)
    $eventArgs.Handled = $true
    Expand-WindowDrawer -Window $window
}.GetNewClosure())
$drawerHandle.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::Enter -or $eventArgs.Key -eq [System.Windows.Input.Key]::Space) {
        $eventArgs.Handled = $true
        Expand-WindowDrawer -Window $window
    }
}.GetNewClosure())
$drawerHandle.Add_GotKeyboardFocus({
    $drawerHandle.BorderBrush = '#00FFFFFF'
}.GetNewClosure())
$drawerHandle.Add_LostKeyboardFocus({
    $drawerHandle.BorderBrush = '#00FFFFFF'
}.GetNewClosure())

$border.Add_MouseMove({
    param($sender, $eventArgs)
    if ($script:ReduceMotion) {
        return
    }

    $point = $eventArgs.GetPosition($border)
    $panelGlow.Opacity = 0.2
    $panelGlowTransform.X = ($point.X - 105) * 0.78
    $panelGlowTransform.Y = ($point.Y - 105) * 0.78
}.GetNewClosure())
$border.Add_MouseLeave({
    if ($script:ReduceMotion) {
        return
    }

    $panelGlow.Opacity = 0.1
    $panelGlowTransform.X = 0
    $panelGlowTransform.Y = 0
}.GetNewClosure())
$border.Add_MouseLeftButtonDown({
    param($sender, $eventArgs)
    Start-WidgetWindowDrag -Window $window -EventArgs $eventArgs
}.GetNewClosure())
$widgetDragPreviewHandler = [System.Windows.Input.MouseButtonEventHandler]{
    param($sender, $eventArgs)
    Start-WidgetWindowDrag -Window $window -EventArgs $eventArgs
}
$border.AddHandler([System.Windows.UIElement]::PreviewMouseLeftButtonDownEvent, $widgetDragPreviewHandler, $true)

$panel = New-Object System.Windows.Controls.StackPanel
$scrollViewer.Content = $panel

$titleRow = New-Object System.Windows.Controls.Grid
$titleRow.Margin = '0,0,0,6'
$titleLeft = New-Object System.Windows.Controls.ColumnDefinition
$titleLeft.Width = '*'
$titleRight = New-Object System.Windows.Controls.ColumnDefinition
$titleRight.Width = 'Auto'
$titleCountdown = New-Object System.Windows.Controls.ColumnDefinition
$titleCountdown.Width = 'Auto'
$titleSettings = New-Object System.Windows.Controls.ColumnDefinition
$titleSettings.Width = [string]$script:TopChromeColumnWidth
$titleCollapse = New-Object System.Windows.Controls.ColumnDefinition
$titleCollapse.Width = [string]$script:TopChromeColumnWidth
$titleClose = New-Object System.Windows.Controls.ColumnDefinition
$titleClose.Width = [string]$script:TopChromeColumnWidth
$titleRow.ColumnDefinitions.Add($titleLeft)
$titleRow.ColumnDefinitions.Add($titleRight)
$titleRow.ColumnDefinitions.Add($titleCountdown)
$titleRow.ColumnDefinitions.Add($titleSettings)
$titleRow.ColumnDefinitions.Add($titleCollapse)
$titleRow.ColumnDefinitions.Add($titleClose)

$titleBlock = New-TextBlock -Text (Get-WidgetTitle) -FontSize 13.2 -FontWeight 'Bold' -Foreground '#141413'
$titleBlock.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
[System.Windows.Controls.Grid]::SetColumn($titleBlock, 0)
$titleRow.Children.Add($titleBlock) | Out-Null
$titleBlock.Add_MouseLeftButtonDown({
    param($sender, $eventArgs)
    Start-WidgetWindowDrag -Window $window -EventArgs $eventArgs
})

function Set-TopChromePlain {
    param([System.Windows.Controls.Border]$Border)

    if ($null -eq $Border) {
        return
    }

    $Border.Background = '#00FFFFFF'
    $Border.BorderBrush = '#00FFFFFF'
    $Border.BorderThickness = 1
    $Border.Effect = $null
}

$statusShell = New-Object System.Windows.Controls.Border
$statusShell.Height = 23
$statusShell.MinWidth = 48
$statusShell.CornerRadius = 12
$statusShell.Padding = '9,1,9,2'
$statusShell.Margin = '0,0,8,0'
$statusShell.HorizontalAlignment = 'Right'
Set-TopChromePlain -Border $statusShell
$statusBlock = New-TextBlock -Text (Tx 'Loading') -FontSize 12 -Foreground '#D97757'
$statusBlock.HorizontalAlignment = 'Center'
$statusShell.Child = $statusBlock
[System.Windows.Controls.Grid]::SetColumn($statusShell, 1)
$titleRow.Children.Add($statusShell) | Out-Null

$countdownShell = New-Object System.Windows.Controls.Border
$countdownShell.Height = 23
$countdownShell.MinWidth = 76
$countdownShell.CornerRadius = 12
$countdownShell.Padding = '8,1,8,2'
$countdownShell.Margin = '0,0,4,0'
$countdownShell.HorizontalAlignment = 'Right'
Set-TopChromePlain -Border $countdownShell
$countdownBlock = New-TextBlock -Text (Format-CountdownText -Seconds $script:RefreshSeconds) -FontSize 11 -Foreground '#6F6B60'
$countdownBlock.HorizontalAlignment = 'Center'
$countdownShell.Child = $countdownBlock
[System.Windows.Controls.Grid]::SetColumn($countdownShell, 2)
$titleRow.Children.Add($countdownShell) | Out-Null

$settingsButton = New-Object System.Windows.Controls.Border
$settingsButton.Width = $script:TopChromeButtonSize
$settingsButton.Height = $script:TopChromeButtonSize
$settingsButton.CornerRadius = ($script:TopChromeButtonSize / 2)
Set-TopChromePlain -Border $settingsButton
$settingsButton.Visibility = [System.Windows.Visibility]::Visible
$settingsButton.Cursor = [System.Windows.Input.Cursors]::Hand
$settingsButton.HorizontalAlignment = 'Right'
$settingsButton.Focusable = $true
$settingsButton.FocusVisualStyle = $null
$settingsButton.ToolTip = Tx 'Settings'
$settingsButton.SetValue([System.Windows.Input.KeyboardNavigation]::IsTabStopProperty, $true)
$settingsIconGrid = New-Object System.Windows.Controls.Grid
$settingsIconGrid.Width = 18
$settingsIconGrid.Height = 18
$settingsIconGrid.HorizontalAlignment = 'Center'
$settingsIconGrid.VerticalAlignment = 'Center'
$settingsIconGrid.SnapsToDevicePixels = $true
$settingsIconGrid.UseLayoutRounding = $true
$settingsIconGrid.RenderTransformOrigin = '0.5,0.5'
$settingsIconRotate = New-Object System.Windows.Media.RotateTransform
$settingsIconGrid.RenderTransform = $settingsIconRotate
$settingsIconText = New-TextBlock -Text (New-WeatherGlyph 0x2699) -FontSize 16 -Foreground '#D97757' -FontWeight 'SemiBold'
$settingsIconText.FontFamily = 'Segoe UI Symbol'
$settingsIconText.HorizontalAlignment = 'Center'
$settingsIconText.VerticalAlignment = 'Center'
$settingsIconGrid.Children.Add($settingsIconText) | Out-Null
$settingsIconHost = New-Object System.Windows.Controls.Grid
$settingsIconHost.Children.Add($settingsIconGrid) | Out-Null
$settingsAutomationButton = New-Object System.Windows.Controls.Button
$settingsAutomationButton.Background = 'Transparent'
$settingsAutomationButton.BorderThickness = 0
$settingsAutomationButton.Width = $script:TopChromeButtonSize
$settingsAutomationButton.Height = $script:TopChromeButtonSize
$settingsAutomationButton.HorizontalAlignment = 'Stretch'
$settingsAutomationButton.VerticalAlignment = 'Stretch'
$settingsAutomationButton.Opacity = 0.01
$settingsAutomationButton.Focusable = $true
$settingsAutomationButton.Cursor = [System.Windows.Input.Cursors]::Hand
$settingsAutomationButton.ToolTip = Tx 'Settings'
Set-ControlAutomationId -Control $settingsAutomationButton -AutomationId 'SettingsButton'
Set-ControlAutomationName -Control $settingsAutomationButton -Name (Tx 'Settings')
$settingsAutomationButton.Add_Click({ Toggle-SettingsPanel }.GetNewClosure())
$settingsIconHost.Children.Add($settingsAutomationButton) | Out-Null

$settingsButton.Child = $settingsIconHost
[System.Windows.Controls.Grid]::SetColumn($settingsButton, 3)
$titleRow.Children.Add($settingsButton) | Out-Null

function Set-SettingsIconColor {
    param([string]$Color)

    $settingsIconText.Foreground = $Color
}

function Set-SettingsIconExpanded {
    param([bool]$Expanded)

    if ($Expanded) {
        $settingsIconRotate.Angle = 28
    } else {
        $settingsIconRotate.Angle = 0
    }
}
$settingsButton.Add_MouseEnter({
    Set-TopChromePlain -Border $settingsButton
    Set-SettingsIconColor -Color '#B5473C'
})
$settingsButton.Add_MouseLeave({
    Set-TopChromePlain -Border $settingsButton
    if ($script:SettingsOpen) {
        Set-SettingsIconColor -Color '#B5473C'
    } else {
        Set-SettingsIconColor -Color '#D97757'
    }
})
$settingsButton.Add_GotKeyboardFocus({
    Set-TopChromePlain -Border $settingsButton
    $settingsButton.BorderBrush = '#D97757'
    $settingsButton.BorderThickness = 1
    Set-SettingsIconColor -Color '#B5473C'
})
$settingsButton.Add_LostKeyboardFocus({
    Set-TopChromePlain -Border $settingsButton
    if (-not $script:SettingsOpen) {
        Set-SettingsIconColor -Color '#D97757'
    }
})
Enable-MagneticHover -Border $settingsButton -Strength 3

$collapseButton = New-Object System.Windows.Controls.Border
$collapseButton.Width = $script:TopChromeButtonSize
$collapseButton.Height = $script:TopChromeButtonSize
$collapseButton.CornerRadius = ($script:TopChromeButtonSize / 2)
Set-TopChromePlain -Border $collapseButton
$collapseButton.Cursor = [System.Windows.Input.Cursors]::Hand
$collapseButton.HorizontalAlignment = 'Right'
$collapseButton.Focusable = $true
$collapseButton.FocusVisualStyle = $null
$collapseButton.ToolTip = Tx 'DrawerCollapse'
$collapseButton.SetValue([System.Windows.Input.KeyboardNavigation]::IsTabStopProperty, $true)
$collapseIconCanvas = New-Object System.Windows.Controls.Canvas
$collapseIconCanvas.Width = 18
$collapseIconCanvas.Height = 18
$collapseIconCanvas.HorizontalAlignment = 'Center'
$collapseIconCanvas.VerticalAlignment = 'Center'
$collapseIconCanvas.SnapsToDevicePixels = $true
$collapseIconCanvas.UseLayoutRounding = $true
$collapseLine = New-Object System.Windows.Shapes.Line
$collapseLine.X1 = 5
$collapseLine.Y1 = 9
$collapseLine.X2 = 13
$collapseLine.Y2 = 9
$collapseLine.Stroke = '#D97757'
$collapseLine.StrokeThickness = 3
$collapseLine.StrokeStartLineCap = [System.Windows.Media.PenLineCap]::Round
$collapseLine.StrokeEndLineCap = [System.Windows.Media.PenLineCap]::Round
$collapseIconCanvas.Children.Add($collapseLine) | Out-Null
$collapseIconHost = New-Object System.Windows.Controls.Grid
$collapseIconHost.Children.Add($collapseIconCanvas) | Out-Null
$drawerCollapseAutomationButton = New-Object System.Windows.Controls.Button
$drawerCollapseAutomationButton.Background = 'Transparent'
$drawerCollapseAutomationButton.BorderThickness = 0
$drawerCollapseAutomationButton.Width = $script:TopChromeButtonSize
$drawerCollapseAutomationButton.Height = $script:TopChromeButtonSize
$drawerCollapseAutomationButton.HorizontalAlignment = 'Stretch'
$drawerCollapseAutomationButton.VerticalAlignment = 'Stretch'
$drawerCollapseAutomationButton.Opacity = 0.01
$drawerCollapseAutomationButton.Focusable = $true
$drawerCollapseAutomationButton.Cursor = [System.Windows.Input.Cursors]::Hand
$drawerCollapseAutomationButton.ToolTip = Tx 'DrawerCollapse'
Set-ControlAutomationId -Control $drawerCollapseAutomationButton -AutomationId 'DrawerCollapseButton'
Set-ControlAutomationName -Control $drawerCollapseAutomationButton -Name (Tx 'DrawerCollapse')
$drawerCollapseAutomationButton.Add_Click({ Collapse-WindowDrawer -Window $window }.GetNewClosure())
$collapseIconHost.Children.Add($drawerCollapseAutomationButton) | Out-Null
$collapseButton.Child = $collapseIconHost
[System.Windows.Controls.Grid]::SetColumn($collapseButton, 4)
$titleRow.Children.Add($collapseButton) | Out-Null

function Set-CollapseIconColor {
    param([string]$Color)

    $collapseLine.Stroke = $Color
}

$collapseButton.Add_MouseEnter({
    Set-TopChromePlain -Border $collapseButton
    Set-CollapseIconColor -Color '#B5473C'
})
$collapseButton.Add_MouseLeave({
    Set-TopChromePlain -Border $collapseButton
    Set-CollapseIconColor -Color '#D97757'
})
$collapseButton.Add_GotKeyboardFocus({
    Set-TopChromePlain -Border $collapseButton
    $collapseButton.BorderBrush = '#D97757'
    $collapseButton.BorderThickness = 1
    Set-CollapseIconColor -Color '#B5473C'
})
$collapseButton.Add_LostKeyboardFocus({
    Set-TopChromePlain -Border $collapseButton
    Set-CollapseIconColor -Color '#D97757'
})
Enable-MagneticHover -Border $collapseButton -Strength 3
$collapseButton.Add_MouseLeftButtonUp({
    param($sender, $eventArgs)
    $eventArgs.Handled = $true
    Collapse-WindowDrawer -Window $window
}.GetNewClosure())
$collapseButton.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::Enter -or $eventArgs.Key -eq [System.Windows.Input.Key]::Space) {
        $eventArgs.Handled = $true
        Collapse-WindowDrawer -Window $window
    }
}.GetNewClosure())

$closeButton = New-Object System.Windows.Controls.Border
$closeButton.Width = $script:TopChromeButtonSize
$closeButton.Height = $script:TopChromeButtonSize
$closeButton.CornerRadius = ($script:TopChromeButtonSize / 2)
Set-TopChromePlain -Border $closeButton
$closeButton.Cursor = [System.Windows.Input.Cursors]::Hand
$closeButton.HorizontalAlignment = 'Right'
$closeButton.Focusable = $true
$closeButton.FocusVisualStyle = $null
$closeButton.ToolTip = Tx 'Exit'
$closeButton.SetValue([System.Windows.Input.KeyboardNavigation]::IsTabStopProperty, $true)
$closeIconCanvas = New-Object System.Windows.Controls.Canvas
$closeIconCanvas.Width = 18
$closeIconCanvas.Height = 18
$closeIconCanvas.HorizontalAlignment = 'Center'
$closeIconCanvas.VerticalAlignment = 'Center'
$closeIconCanvas.SnapsToDevicePixels = $true
$closeIconCanvas.UseLayoutRounding = $true
$closeLineA = New-Object System.Windows.Shapes.Line
$closeLineA.X1 = 5
$closeLineA.Y1 = 5
$closeLineA.X2 = 13
$closeLineA.Y2 = 13
$closeLineA.Stroke = '#D97757'
$closeLineA.StrokeThickness = 3
$closeLineA.StrokeStartLineCap = [System.Windows.Media.PenLineCap]::Round
$closeLineA.StrokeEndLineCap = [System.Windows.Media.PenLineCap]::Round
$closeLineB = New-Object System.Windows.Shapes.Line
$closeLineB.X1 = 13
$closeLineB.Y1 = 5
$closeLineB.X2 = 5
$closeLineB.Y2 = 13
$closeLineB.Stroke = '#D97757'
$closeLineB.StrokeThickness = 3
$closeLineB.StrokeStartLineCap = [System.Windows.Media.PenLineCap]::Round
$closeLineB.StrokeEndLineCap = [System.Windows.Media.PenLineCap]::Round
$closeIconCanvas.Children.Add($closeLineA) | Out-Null
$closeIconCanvas.Children.Add($closeLineB) | Out-Null
$closeIconHost = New-Object System.Windows.Controls.Grid
$closeIconHost.Children.Add($closeIconCanvas) | Out-Null
$closeAutomationButton = New-Object System.Windows.Controls.Button
$closeAutomationButton.Background = 'Transparent'
$closeAutomationButton.BorderThickness = 0
$closeAutomationButton.Width = $script:TopChromeButtonSize
$closeAutomationButton.Height = $script:TopChromeButtonSize
$closeAutomationButton.HorizontalAlignment = 'Stretch'
$closeAutomationButton.VerticalAlignment = 'Stretch'
$closeAutomationButton.Opacity = 0.01
$closeAutomationButton.Focusable = $true
$closeAutomationButton.Cursor = [System.Windows.Input.Cursors]::Hand
$closeAutomationButton.ToolTip = Tx 'Exit'
Set-ControlAutomationId -Control $closeAutomationButton -AutomationId 'CloseButton'
Set-ControlAutomationName -Control $closeAutomationButton -Name (Tx 'Exit')
$closeAutomationButton.Add_Click({ $window.Close() }.GetNewClosure())
$closeIconHost.Children.Add($closeAutomationButton) | Out-Null
$closeButton.Child = $closeIconHost
[System.Windows.Controls.Grid]::SetColumn($closeButton, 5)
$titleRow.Children.Add($closeButton) | Out-Null

function Set-CloseIconColor {
    param([string]$Color)

    $closeLineA.Stroke = $Color
    $closeLineB.Stroke = $Color
}

$closeButton.Add_MouseEnter({
    Set-TopChromePlain -Border $closeButton
    Set-CloseIconColor -Color '#B5473C'
})
$closeButton.Add_MouseLeave({
    Set-TopChromePlain -Border $closeButton
    Set-CloseIconColor -Color '#D97757'
})
$closeButton.Add_GotKeyboardFocus({
    Set-TopChromePlain -Border $closeButton
    $closeButton.BorderBrush = '#D97757'
    $closeButton.BorderThickness = 1
    Set-CloseIconColor -Color '#B5473C'
})
$closeButton.Add_LostKeyboardFocus({
    Set-TopChromePlain -Border $closeButton
    Set-CloseIconColor -Color '#D97757'
})
Enable-MagneticHover -Border $closeButton -Strength 3
$closeButton.Add_MouseLeftButtonUp({
    param($sender, $eventArgs)
    $eventArgs.Handled = $true
    $window.Close()
})
$closeButton.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::Enter -or $eventArgs.Key -eq [System.Windows.Input.Key]::Space) {
        $eventArgs.Handled = $true
        $window.Close()
    }
})
$panel.Children.Add($titleRow) | Out-Null

$locationStrip = New-Object System.Windows.Controls.Border
$locationStrip.Height = 24
$locationStrip.CornerRadius = 8
$locationStrip.Padding = '9,3,9,3'
$locationStrip.Margin = '0,0,0,6'
$locationStrip.Background = '#E6FFFFFF'
$locationStrip.BorderBrush = '#00FFFFFF'
$locationStrip.BorderThickness = 1
$locationStrip.Cursor = [System.Windows.Input.Cursors]::Hand
$locationStrip.Focusable = $true
$locationStrip.FocusVisualStyle = $null
$locationStrip.SetValue([System.Windows.Input.KeyboardNavigation]::IsTabStopProperty, $true)
$locationLineBlock = New-TextBlock -Text (Get-LocationCardText) -FontSize 11 -Foreground '#6F6B60' -FontWeight 'SemiBold'
$locationLineBlock.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
$locationStrip.Child = $locationLineBlock
$locationStrip.Add_MouseEnter({
    $locationStrip.Background = '#FFF3DED5'
    if (-not $locationStrip.IsKeyboardFocusWithin) { $locationStrip.BorderBrush = '#00FFFFFF' }
})
$locationStrip.Add_MouseLeave({
    $locationStrip.Background = '#E6FFFFFF'
    if (-not $locationStrip.IsKeyboardFocusWithin) { $locationStrip.BorderBrush = '#00FFFFFF' }
})
$locationStrip.Add_GotKeyboardFocus({
    $locationStrip.BorderBrush = '#D97757'
})
$locationStrip.Add_LostKeyboardFocus({
    $locationStrip.BorderBrush = '#00FFFFFF'
})
$panel.Children.Add($locationStrip) | Out-Null

$infoGrid = New-Object System.Windows.Controls.Grid
$infoGrid.Margin = '0,0,0,7'
foreach ($width in @('*', '*')) {
    $col = New-Object System.Windows.Controls.ColumnDefinition
    $col.Width = $width
    $infoGrid.ColumnDefinitions.Add($col)
}
foreach ($height in @('Auto', 'Auto')) {
    $rowDef = New-Object System.Windows.Controls.RowDefinition
    $rowDef.Height = $height
    $infoGrid.RowDefinitions.Add($rowDef)
}

$locationInfoCard = New-InfoCard -Label (Tx 'Location') -Value (Get-LocationCardText) -Height 40
$locationInfoCard.Grid.Margin = '0,0,0,6'
[System.Windows.Controls.Grid]::SetColumn($locationInfoCard.Grid, 0)
[System.Windows.Controls.Grid]::SetColumnSpan($locationInfoCard.Grid, 2)
[System.Windows.Controls.Grid]::SetRow($locationInfoCard.Grid, 0)
$infoGrid.Children.Add($locationInfoCard.Grid) | Out-Null

$refreshInfoCard = New-InfoCard -Label (Tx 'Refresh') -Value (Get-RefreshLabel -Seconds $script:RefreshSeconds) -Height 40
$refreshInfoCard.Grid.Margin = '0,0,4,0'
[System.Windows.Controls.Grid]::SetColumn($refreshInfoCard.Grid, 0)
[System.Windows.Controls.Grid]::SetRow($refreshInfoCard.Grid, 1)
$infoGrid.Children.Add($refreshInfoCard.Grid) | Out-Null

$languageInfoCard = New-InfoCard -Label (Tx 'Language') -Value (Get-LanguageCardText) -Height 40
$languageInfoCard.Grid.Margin = '4,0,0,0'
[System.Windows.Controls.Grid]::SetColumn($languageInfoCard.Grid, 1)
[System.Windows.Controls.Grid]::SetRow($languageInfoCard.Grid, 1)
$infoGrid.Children.Add($languageInfoCard.Grid) | Out-Null

$settingsPanel = New-Object System.Windows.Controls.Border
$settingsPanel.CornerRadius = 11
$settingsPanel.Padding = '8'
$settingsPanel.Margin = '0,0,0,7'
$settingsPanel.Background = '#FFFAF9F5'
$settingsPanel.BorderBrush = '#55E8E6DC'
$settingsPanel.BorderThickness = 1
$settingsPanel.Visibility = [System.Windows.Visibility]::Collapsed
$settingsPanel.Effect = New-GlowEffect -Color '#F3DED5' -BlurRadius 8 -ShadowDepth 1 -Opacity 0.06
$settingsStack = New-Object System.Windows.Controls.StackPanel
$settingsPanel.Child = $settingsStack
$panel.Children.Add($settingsPanel) | Out-Null

$settingsHeaderBlock = New-TextBlock -Text (Tx 'SettingsControls') -FontSize 10.5 -Foreground '#6F6B60' -FontWeight 'SemiBold'
$settingsHeaderBlock.Margin = '1,0,0,6'
$settingsStack.Children.Add($settingsHeaderBlock) | Out-Null

$selectorGrid = New-Object System.Windows.Controls.Grid
$selectorGrid.Margin = '0,0,0,7'
foreach ($width in @('*', '*', '*')) {
    $col = New-Object System.Windows.Controls.ColumnDefinition
    $col.Width = $width
    $selectorGrid.ColumnDefinitions.Add($col)
}

$provinceCombo = New-ComboBox -Width 102 -Margin '0,0,0,0'
$provinceCombo.HorizontalAlignment = 'Left'
$provinceField = New-SettingsField -Label (Tx 'Province') -Control $provinceCombo -AutomationName (Tx 'Province')
[System.Windows.Controls.Grid]::SetColumn($provinceField.Panel, 0)
$selectorGrid.Children.Add($provinceField.Panel) | Out-Null

$cityCombo = New-ComboBox -Width 102 -Margin '0,0,0,0'
$cityCombo.HorizontalAlignment = 'Center'
$cityField = New-SettingsField -Label (Tx 'City') -Control $cityCombo -AutomationName (Tx 'City')
$cityField.Panel.Margin = '4,0,4,0'
[System.Windows.Controls.Grid]::SetColumn($cityField.Panel, 1)
$selectorGrid.Children.Add($cityField.Panel) | Out-Null

$districtCombo = New-ComboBox -Width 102 -Margin '0,0,0,0'
$districtCombo.HorizontalAlignment = 'Right'
$districtField = New-SettingsField -Label (Tx 'District') -Control $districtCombo -AutomationName (Tx 'District')
[System.Windows.Controls.Grid]::SetColumn($districtField.Panel, 2)
$selectorGrid.Children.Add($districtField.Panel) | Out-Null
$settingsStack.Children.Add($selectorGrid) | Out-Null

$toolRow = New-Object System.Windows.Controls.Grid
$toolRow.Margin = '0,0,0,7'
$toolLeft = New-Object System.Windows.Controls.ColumnDefinition
$toolLeft.Width = '*'
$toolRight = New-Object System.Windows.Controls.ColumnDefinition
$toolRight.Width = 'Auto'
$toolRow.ColumnDefinitions.Add($toolLeft)
$toolRow.ColumnDefinitions.Add($toolRight)

$refreshCombo = New-ComboBox -Width 156 -Margin '0,0,0,0'
$refreshCombo.HorizontalAlignment = 'Left'
$refreshCombo.SelectedValuePath = 'Seconds'
$refreshCombo.ToolTip = Tx 'RefreshInterval'
$refreshField = New-SettingsField -Label (Tx 'RefreshInterval') -Control $refreshCombo -AutomationName (Tx 'RefreshInterval')
[System.Windows.Controls.Grid]::SetColumn($refreshField.Panel, 0)
$toolRow.Children.Add($refreshField.Panel) | Out-Null

$languagePill = New-Object System.Windows.Controls.Border
$languagePill.Width = 126
$languagePill.Height = 34
$languagePill.HorizontalAlignment = 'Right'
$languagePill.CornerRadius = 17
$languagePill.Background = '#FFFAF9F5'
$languagePill.BorderBrush = '#55E8E6DC'
$languagePill.BorderThickness = 1
$languagePill.Cursor = [System.Windows.Input.Cursors]::Hand
$languagePill.ToolTip = Tx 'Language'
$languagePill.Effect = New-GlowEffect -Color '#F3DED5' -BlurRadius 8 -ShadowDepth 1 -Opacity 0.06
$languagePill.Add_MouseEnter({
    $languagePill.BorderBrush = '#88D97757'
    $languagePill.Effect = New-GlowEffect -Color '#D97757' -BlurRadius 10 -ShadowDepth 1 -Opacity 0.10
})
$languagePill.Add_MouseLeave({
    $languagePill.BorderBrush = '#55E8E6DC'
    $languagePill.Effect = New-GlowEffect -Color '#F3DED5' -BlurRadius 8 -ShadowDepth 1 -Opacity 0.06
})
Enable-MagneticHover -Border $languagePill -Strength 2

$pillGrid = New-Object System.Windows.Controls.Grid
$pillGrid.ClipToBounds = $true
$pillLeft = New-Object System.Windows.Controls.ColumnDefinition
$pillLeft.Width = '*'
$pillRight = New-Object System.Windows.Controls.ColumnDefinition
$pillRight.Width = '*'
$pillGrid.ColumnDefinitions.Add($pillLeft)
$pillGrid.ColumnDefinitions.Add($pillRight)

$zhSegment = New-Object System.Windows.Controls.Border
$zhSegment.CornerRadius = '16,0,0,16'
$zhSegment.BorderThickness = 1
$zhSegment.BorderBrush = '#00000000'
$zhSegment.Focusable = $true
$zhSegment.FocusVisualStyle = $null
$zhSegment.SetValue([System.Windows.Input.KeyboardNavigation]::IsTabStopProperty, $true)
$zhText = New-TextBlock -Text (Tx 'Chinese') -FontSize 10.5 -FontWeight 'SemiBold'
$zhText.HorizontalAlignment = 'Center'
$zhSegmentHost = New-Object System.Windows.Controls.Grid
$zhSegmentHost.Children.Add($zhText) | Out-Null
$zhAutomationButton = New-Object System.Windows.Controls.Button
$zhAutomationButton.Background = 'Transparent'
$zhAutomationButton.BorderThickness = 0
$zhAutomationButton.MinWidth = 58
$zhAutomationButton.Height = 28
$zhAutomationButton.HorizontalAlignment = 'Stretch'
$zhAutomationButton.VerticalAlignment = 'Stretch'
$zhAutomationButton.Opacity = 0.01
$zhAutomationButton.Focusable = $true
$zhAutomationButton.Cursor = [System.Windows.Input.Cursors]::Hand
Set-ControlAutomationId -Control $zhAutomationButton -AutomationId 'LanguageCnButton'
Set-ControlAutomationName -Control $zhAutomationButton -Name (Tx 'Chinese')
$zhAutomationButton.Add_Click({ Set-WidgetLanguage -Language 'zh' }.GetNewClosure())
$zhSegmentHost.Children.Add($zhAutomationButton) | Out-Null

$zhSegment.Child = $zhSegmentHost
Set-ControlAutomationName -Control $zhSegment -Name (Tx 'Chinese')
[System.Windows.Controls.Grid]::SetColumn($zhSegment, 0)
$pillGrid.Children.Add($zhSegment) | Out-Null

$enSegment = New-Object System.Windows.Controls.Border
$enSegment.CornerRadius = '0,16,16,0'
$enSegment.BorderThickness = 1
$enSegment.BorderBrush = '#00000000'
$enSegment.Focusable = $true
$enSegment.FocusVisualStyle = $null
$enSegment.SetValue([System.Windows.Input.KeyboardNavigation]::IsTabStopProperty, $true)
$enText = New-TextBlock -Text (Tx 'English') -FontSize 10.5 -FontWeight 'SemiBold'
$enText.HorizontalAlignment = 'Center'
$enSegmentHost = New-Object System.Windows.Controls.Grid
$enSegmentHost.Children.Add($enText) | Out-Null
$enAutomationButton = New-Object System.Windows.Controls.Button
$enAutomationButton.Background = 'Transparent'
$enAutomationButton.BorderThickness = 0
$enAutomationButton.MinWidth = 58
$enAutomationButton.Height = 28
$enAutomationButton.HorizontalAlignment = 'Stretch'
$enAutomationButton.VerticalAlignment = 'Stretch'
$enAutomationButton.Opacity = 0.01
$enAutomationButton.Focusable = $true
$enAutomationButton.Cursor = [System.Windows.Input.Cursors]::Hand
Set-ControlAutomationId -Control $enAutomationButton -AutomationId 'LanguageEnButton'
Set-ControlAutomationName -Control $enAutomationButton -Name (Tx 'English')
$enAutomationButton.Add_Click({ Set-WidgetLanguage -Language 'en' }.GetNewClosure())
$enSegmentHost.Children.Add($enAutomationButton) | Out-Null

$enSegment.Child = $enSegmentHost
Set-ControlAutomationName -Control $enSegment -Name (Tx 'English')
[System.Windows.Controls.Grid]::SetColumn($enSegment, 1)
$pillGrid.Children.Add($enSegment) | Out-Null

$languagePill.Child = $pillGrid
$languageField = New-SettingsField -Label (Tx 'Language') -Control $languagePill -AutomationName (Tx 'Language')
$languageField.Panel.Margin = '8,0,0,0'
[System.Windows.Controls.Grid]::SetColumn($languageField.Panel, 1)
$toolRow.Children.Add($languageField.Panel) | Out-Null
$settingsStack.Children.Add($toolRow) | Out-Null

$timelineLabel = New-TextBlock -Text (Tx 'ForecastTime') -FontSize 10.5 -Foreground '#6F6B60' -FontWeight 'SemiBold'
$timelineLabel.Margin = '1,0,0,6'
$settingsStack.Children.Add($timelineLabel) | Out-Null

$script:ForecastChips = [ordered]@{}

$forecastControlGrid = New-Object System.Windows.Controls.Grid
$forecastControlGrid.Margin = '0,0,0,2'
foreach ($width in @('*', '*')) {
    $col = New-Object System.Windows.Controls.ColumnDefinition
    $col.Width = $width
    $forecastControlGrid.ColumnDefinitions.Add($col)
}

$forecastDateCombo = New-ComboBox -Width 156 -Margin '0,0,0,0'
$forecastDateCombo.HorizontalAlignment = 'Left'
$forecastDateCombo.ToolTip = Tx 'StartTime'
$forecastDateField = New-SettingsField -Label (Tx 'StartTime') -Control $forecastDateCombo -AutomationName (Tx 'StartTime')
[System.Windows.Controls.Grid]::SetColumn($forecastDateField.Panel, 0)
$forecastControlGrid.Children.Add($forecastDateField.Panel) | Out-Null

$forecastHourCombo = New-ComboBox -Width 156 -Margin '0,0,0,0'
$forecastHourCombo.HorizontalAlignment = 'Right'
$forecastHourCombo.ToolTip = Tx 'EndTime'
$forecastHourField = New-SettingsField -Label (Tx 'EndTime') -Control $forecastHourCombo -AutomationName (Tx 'EndTime')
$forecastHourField.Panel.Margin = '8,0,0,0'
[System.Windows.Controls.Grid]::SetColumn($forecastHourField.Panel, 1)
$forecastControlGrid.Children.Add($forecastHourField.Panel) | Out-Null

$settingsStack.Children.Add($forecastControlGrid) | Out-Null
$conditionCard = New-Object System.Windows.Controls.Border
$conditionCard.CornerRadius = 9
$conditionCard.Padding = '10,7,10,8'
$conditionCard.Background = '#FFFFFFFF'
$conditionCard.BorderBrush = '#AAE8E6DC'
$conditionCard.BorderThickness = 1
$conditionCard.Margin = '0,0,0,6'
$conditionCard.Effect = New-GlowEffect -Color '#D8D4C8' -BlurRadius 14 -ShadowDepth 2 -Opacity 0.11
$conditionCard.RenderTransformOrigin = '0.5,0.5'
$conditionTransform = New-Object System.Windows.Media.TransformGroup
$conditionScale = New-Object System.Windows.Media.ScaleTransform
$conditionSkew = New-Object System.Windows.Media.SkewTransform
$conditionRotate = New-Object System.Windows.Media.RotateTransform
$conditionTranslate = New-Object System.Windows.Media.TranslateTransform
$conditionTransform.Children.Add($conditionScale) | Out-Null
$conditionTransform.Children.Add($conditionSkew) | Out-Null
$conditionTransform.Children.Add($conditionRotate) | Out-Null
$conditionTransform.Children.Add($conditionTranslate) | Out-Null
$conditionCard.RenderTransform = $conditionTransform

$conditionLayout = New-Object System.Windows.Controls.Grid
$conditionTextColumn = New-Object System.Windows.Controls.ColumnDefinition
$conditionTextColumn.Width = '*'
$conditionIconColumn = New-Object System.Windows.Controls.ColumnDefinition
$conditionIconColumn.Width = '64'
$conditionLayout.ColumnDefinitions.Add($conditionTextColumn)
$conditionLayout.ColumnDefinitions.Add($conditionIconColumn)
$conditionMainRow = New-Object System.Windows.Controls.RowDefinition
$conditionMainRow.Height = 'Auto'
$conditionAlertRow = New-Object System.Windows.Controls.RowDefinition
$conditionAlertRow.Height = 'Auto'
$conditionLayout.RowDefinitions.Add($conditionMainRow)
$conditionLayout.RowDefinitions.Add($conditionAlertRow)
$conditionCard.Child = $conditionLayout

$conditionPanel = New-Object System.Windows.Controls.StackPanel
[System.Windows.Controls.Grid]::SetColumn($conditionPanel, 0)
[System.Windows.Controls.Grid]::SetRow($conditionPanel, 0)
$conditionLayout.Children.Add($conditionPanel) | Out-Null

$modeBlock = New-TextBlock -Text (Tx 'Now') -FontSize 10.5 -Foreground '#D97757' -FontWeight 'SemiBold'
$modeBlock.Margin = '0,0,0,2'
$conditionPanel.Children.Add($modeBlock) | Out-Null

$conditionBlock = New-TextBlock -Text (Tx 'Loading') -FontSize 12 -Foreground '#6F6B60'
$conditionBlock.Margin = '0,0,0,2'
$conditionPanel.Children.Add($conditionBlock) | Out-Null

$nearTermBlock = New-TextBlock -Text (Tx 'NearTermNoHeavyRain') -FontSize 10 -Foreground '#8A867A' -FontWeight 'SemiBold'
$nearTermBlock.Margin = '0,0,0,3'
$nearTermBlock.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
$conditionPanel.Children.Add($nearTermBlock) | Out-Null

$temperatureBlock = New-TextBlock -Text '-- C' -FontSize 29 -Foreground '#141413' -FontWeight 'Bold'
$temperatureBlock.Margin = '0,0,0,1'
$conditionPanel.Children.Add($temperatureBlock) | Out-Null

$feelsBlock = New-TextBlock -Text '--' -FontSize 12 -Foreground '#6F6B60'
$conditionPanel.Children.Add($feelsBlock) | Out-Null

$weatherIconShell = New-Object System.Windows.Controls.Border
$weatherIconShell.Width = 54
$weatherIconShell.Height = 54
$weatherIconShell.CornerRadius = 16
$weatherIconShell.Padding = '3'
$weatherIconShell.HorizontalAlignment = 'Right'
$weatherIconShell.VerticalAlignment = 'Center'
$weatherIconShell.Background = '#FFFAF9F5'
$weatherIconShell.BorderBrush = '#00FFFFFF'
$weatherIconShell.BorderThickness = 0
$weatherIconShell.Effect = New-GlowEffect -Color '#F3DED5' -BlurRadius 10 -ShadowDepth 1 -Opacity 0.10
$weatherIconShell.Child = New-WeatherIconElement -IconKey 'Clear' -Foreground '#D97757'
[System.Windows.Controls.Grid]::SetColumn($weatherIconShell, 1)
[System.Windows.Controls.Grid]::SetRow($weatherIconShell, 0)
$conditionLayout.Children.Add($weatherIconShell) | Out-Null

$alertStrip = New-Object System.Windows.Controls.Border
$alertStrip.Height = 22
$alertStrip.CornerRadius = 8
$alertStrip.Padding = '7,1,7,2'
$alertStrip.Margin = '0,5,0,0'
$alertStrip.Background = '#00FFFFFF'
$alertStrip.BorderBrush = '#00FFFFFF'
$alertStrip.BorderThickness = '3,0,0,0'
$alertGrid = New-Object System.Windows.Controls.Grid
$alertIconColumn = New-Object System.Windows.Controls.ColumnDefinition
$alertIconColumn.Width = 'Auto'
$alertTextColumn = New-Object System.Windows.Controls.ColumnDefinition
$alertTextColumn.Width = '*'
$alertGrid.ColumnDefinitions.Add($alertIconColumn)
$alertGrid.ColumnDefinitions.Add($alertTextColumn)
$alertStrip.Child = $alertGrid
$alertIconBlock = New-TextBlock -Text (New-WeatherGlyph 0x2600) -FontSize 12 -Foreground '#8A867A'
$alertIconBlock.FontFamily = 'Segoe UI Emoji'
$alertIconBlock.Margin = '0,0,5,0'
[System.Windows.Controls.Grid]::SetColumn($alertIconBlock, 0)
$alertGrid.Children.Add($alertIconBlock) | Out-Null
$alertTextBlock = New-TextBlock -Text (Tx 'NoWeatherAlert') -FontSize 10 -Foreground '#8A867A' -FontWeight 'SemiBold'
$alertTextBlock.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
[System.Windows.Controls.Grid]::SetColumn($alertTextBlock, 1)
$alertGrid.Children.Add($alertTextBlock) | Out-Null
[System.Windows.Controls.Grid]::SetColumnSpan($alertStrip, 2)
[System.Windows.Controls.Grid]::SetRow($alertStrip, 1)
$conditionLayout.Children.Add($alertStrip) | Out-Null

$conditionCard.Add_MouseMove({
    param($sender, $eventArgs)
    if ($script:ReduceMotion) {
        return
    }
    $point = $eventArgs.GetPosition($conditionCard)
    $width = [Math]::Max(1, $conditionCard.ActualWidth)
    $height = [Math]::Max(1, $conditionCard.ActualHeight)
    $conditionScale.ScaleX = 1.012
    $conditionScale.ScaleY = 1.012
    $conditionTranslate.Y = -2
    $conditionRotate.Angle = (($point.X / $width) - 0.5) * 1.6
    $conditionSkew.AngleX = -(($point.Y / $height) - 0.5) * 1.8
    $conditionSkew.AngleY = (($point.X / $width) - 0.5) * 1.4
}.GetNewClosure())
$conditionCard.Add_MouseLeave({
    $conditionScale.ScaleX = 1
    $conditionScale.ScaleY = 1
    $conditionTranslate.Y = 0
    $conditionRotate.Angle = 0
    $conditionSkew.AngleX = 0
    $conditionSkew.AngleY = 0
}.GetNewClosure())

$panel.Children.Add($conditionCard) | Out-Null

$rows = [ordered]@{}
$rowKeys = @(
    @('Rain', 'RainNow'),
    @('DayRain', 'TodayRain'),
    @('Probability', 'Probability'),
    @('Humidity', 'Humidity'),
    @('Cloud', 'Cloud'),
    @('Pressure', 'Pressure'),
    @('Wind', 'Wind'),
    @('Gust', 'Gust')
)

$metricsPanel = New-Object System.Windows.Controls.Border
$metricsPanel.CornerRadius = 9
$metricsPanel.Padding = '6,5,6,5'
$metricsPanel.Margin = '0,0,0,0'
$metricsPanel.Background = '#EFFFFFFF'
$metricsPanel.BorderBrush = '#66E8E6DC'
$metricsPanel.BorderThickness = 1
$metricsPanel.Effect = $null

$metricsGrid = New-Object System.Windows.Controls.Grid
$metricsGrid.Margin = '0,0,0,0'
foreach ($width in @('*', '*')) {
    $col = New-Object System.Windows.Controls.ColumnDefinition
    $col.Width = $width
    $metricsGrid.ColumnDefinitions.Add($col)
}
foreach ($height in @('Auto', 'Auto', 'Auto', 'Auto')) {
    $rowDef = New-Object System.Windows.Controls.RowDefinition
    $rowDef.Height = $height
    $metricsGrid.RowDefinitions.Add($rowDef)
}

for ($i = 0; $i -lt $rowKeys.Count; $i++) {
    $item = $rowKeys[$i]
    $row = New-Row -Label (Tx $item[1]) -Value '--'
    $rows[$item[0]] = [pscustomobject]@{
        LabelKey = $item[1]
        Row = $row
    }
    $gridColumn = $i % 2
    $gridRow = [Math]::Floor($i / 2)
    [System.Windows.Controls.Grid]::SetColumn($row.Grid, $gridColumn)
    [System.Windows.Controls.Grid]::SetRow($row.Grid, $gridRow)
    $bottom = if ($gridRow -lt 3) { 3 } else { 0 }
    if ($gridColumn -eq 0) {
        $row.Grid.Margin = "0,0,4,$bottom"
    } else {
        $row.Grid.Margin = "4,0,0,$bottom"
    }
    $metricsGrid.Children.Add($row.Grid) | Out-Null
}
$metricsPanel.Child = $metricsGrid
$panel.Children.Add($metricsPanel) | Out-Null
$updatedBlock = New-TextBlock -Text '--' -FontSize 9.5 -Foreground '#8A867A'
$updatedBlock.Margin = '0,6,0,0'
$panel.Children.Add($updatedBlock) | Out-Null
$errorAutomationBlock = New-TextBlock -Text '' -Width 0 -Height 0 -Opacity 0
$errorAutomationBlock.IsHitTestVisible = $false
$panel.Children.Add($errorAutomationBlock) | Out-Null
Set-ControlAutomationId -Control $provinceCombo -AutomationId 'ProvinceSelector'
Set-ControlAutomationId -Control $cityCombo -AutomationId 'CitySelector'
Set-ControlAutomationId -Control $districtCombo -AutomationId 'DistrictSelector'
Set-ControlAutomationId -Control $refreshCombo -AutomationId 'RefreshIntervalSelector'
Set-ControlAutomationId -Control $forecastDateCombo -AutomationId 'ForecastStartSelector'
Set-ControlAutomationId -Control $forecastHourCombo -AutomationId 'ForecastEndSelector'
Set-ControlAutomationId -Control $languageInfoCard.Value -AutomationId 'LanguageStatusText'
Set-ControlAutomationId -Control $zhAutomationButton -AutomationId 'LanguageCnButton'
Set-ControlAutomationId -Control $enAutomationButton -AutomationId 'LanguageEnButton'
Set-ControlAutomationId -Control $settingsAutomationButton -AutomationId 'SettingsButton'
Set-ControlAutomationId -Control $drawerCollapseAutomationButton -AutomationId 'DrawerCollapseButton'
Set-ControlAutomationId -Control $drawerHandleAutomationButton -AutomationId 'DrawerHandle'
Set-ControlAutomationId -Control $locationLineBlock -AutomationId 'LocationTitle'
Set-ControlAutomationId -Control $conditionBlock -AutomationId 'WeatherDescription'
Set-ControlAutomationId -Control $nearTermBlock -AutomationId 'NearTermForecast'
Set-ControlAutomationId -Control $temperatureBlock -AutomationId 'TemperatureText'
Set-ControlAutomationId -Control $alertTextBlock -AutomationId 'WarningPanel'
Set-ControlAutomationId -Control $errorAutomationBlock -AutomationId 'ErrorPanel'
Set-ControlAutomationId -Control $statusBlock -AutomationId 'LoadingPanel'
Set-ControlAutomationId -Control $updatedBlock -AutomationId 'StatusFooter'
Set-ControlAutomationId -Control $rows['Rain'].Row.Value -AutomationId 'RainfallText'
Set-ControlAutomationId -Control $rows['Humidity'].Row.Value -AutomationId 'HumidityText'
Set-ControlAutomationId -Control $rows['Pressure'].Row.Value -AutomationId 'PressureText'
Set-ControlAutomationId -Control $rows['Wind'].Row.Value -AutomationId 'WindText'
$menu = New-Object System.Windows.Controls.ContextMenu
$refreshItem = New-Object System.Windows.Controls.MenuItem
$refreshItem.Header = Tx 'RefreshNow'
$exitItem = New-Object System.Windows.Controls.MenuItem
$exitItem.Header = Tx 'Exit'
$menu.Items.Add($refreshItem) | Out-Null
$menu.Items.Add($exitItem) | Out-Null
$border.ContextMenu = $menu

$window.Content = $border
Set-UiSmokeItemStatus -State 'Idle' -LocationKey (Get-SelectedLocationKey) -RequestId $script:ActiveWeatherRequestId
$exitItem.Add_Click({ $window.Close() })

$script:Client = New-Object LonghuaWeatherTimeoutWebClient
$script:Client.TimeoutMilliseconds = $script:WeatherRequestTimeoutMs
$script:Client.Headers.Add('User-Agent', 'LonghuaWeatherWidget/2.0')

function Update-LanguagePill {
    $zhText.Text = Tx 'Chinese'
    $enText.Text = Tx 'English'
    Set-ControlAutomationName -Control $zhSegment -Name (Tx 'Chinese')
    Set-ControlAutomationName -Control $enSegment -Name (Tx 'English')

    if ($script:Language -eq 'zh') {
        $zhSegment.Background = '#D97757'
        $enSegment.Background = '#00FFFFFF'
        $zhText.Foreground = '#FFFFFF'
        $enText.Foreground = '#6F6B60'
    } else {
        $zhSegment.Background = '#00FFFFFF'
        $enSegment.Background = '#D97757'
        $zhText.Foreground = '#6F6B60'
        $enText.Foreground = '#FFFFFF'
    }
}
function Update-InfoCards {
    if ($null -eq $locationInfoCard) {
        return
    }
    if ($null -ne $locationLineBlock) {
        $locationLineBlock.Text = Get-LocationCardText
        $locationStrip.ToolTip = Tx 'Settings'
    }
    $locationInfoCard.Label.Text = Tx 'Location'
    $locationInfoCard.Value.Text = Get-LocationCardText
    $locationInfoCard.Grid.ToolTip = Tx 'Settings'
    $refreshInfoCard.Label.Text = Tx 'Refresh'
    $refreshInfoCard.Value.Text = Get-RefreshLabel -Seconds $script:RefreshSeconds
    $refreshInfoCard.Grid.ToolTip = Tx 'Settings'
    $languageInfoCard.Label.Text = Tx 'Language'
    $languageInfoCard.Value.Text = Get-LanguageCardText
    $languageInfoCard.Grid.ToolTip = Tx 'Settings'
}

function Update-ForecastControls {
    if ($null -eq $forecastDateCombo -or $null -eq $forecastHourCombo) {
        return
    }

    $script:UpdatingForecastControls = $true
    try {
        $baseTime = if ($null -ne $script:LatestWeatherModel -and $null -ne $script:LatestWeatherModel.Current.Time) { $script:LatestWeatherModel.Current.Time } else { Get-Date }
        $supportsForecast = ($null -eq $script:LatestWeatherModel -or $script:LatestWeatherModel.SupportsForecastSlots)
        $dayKey = if ($supportsForecast) { Get-ForecastDayKeyFromSlot -SlotKey $script:SelectedForecastSlotKey } else { 'Now' }
        $hour = Get-ForecastHourFromSlot -SlotKey $script:SelectedForecastSlotKey

        $forecastDateCombo.Items.Clear()
        $forecastDateCombo.Items.Add([pscustomobject]@{
            Key = 'Now'
            DayOffset = -1
            Display = Tx 'Now'
        }) | Out-Null

        if ($supportsForecast) {
            for ($day = 0; $day -lt $script:ForecastDayCount; $day++) {
                $date = $baseTime.Date.AddDays($day)
                $forecastDateCombo.Items.Add([pscustomobject]@{
                    Key = 'D{0}' -f $day
                    DayOffset = $day
                    Display = Get-ForecastDayDisplay -DayOffset $day -Date $date
                }) | Out-Null
            }
        }

        Select-ComboItem -Combo $forecastDateCombo -Property 'Key' -Value $dayKey

        $forecastHourCombo.Items.Clear()
        if ($dayKey -eq 'Now' -or -not $supportsForecast) {
            $forecastHourCombo.IsEnabled = $false
            $forecastHourCombo.Opacity = 0.58
            $forecastHourCombo.Items.Add([pscustomobject]@{
                Key = 'Current'
                Hour = -1
                Display = Tx 'Now'
            }) | Out-Null
            Select-ComboItem -Combo $forecastHourCombo -Property 'Key' -Value 'Current'
        } else {
            $forecastHourCombo.IsEnabled = $true
            $forecastHourCombo.Opacity = 1.0
            for ($forecastHour = 0; $forecastHour -lt 24; $forecastHour++) {
                $forecastHourCombo.Items.Add([pscustomobject]@{
                    Key = 'H{0:00}' -f $forecastHour
                    Hour = $forecastHour
                    Display = '{0:00}:00' -f $forecastHour
                }) | Out-Null
            }
            Select-ComboItem -Combo $forecastHourCombo -Property 'Key' -Value ('H{0:00}' -f $hour)
        }
    } finally {
        $script:UpdatingForecastControls = $false
    }
}

function Update-ForecastChips {
    Update-ForecastControls

    if ($null -eq $script:ForecastChips) {
        return
    }

    foreach ($definition in $script:ForecastSlotDefinitions) {
        $chip = $script:ForecastChips[$definition.Key]
        if ($null -eq $chip) {
            continue
        }
        $chip.Text.Text = Tx $definition.LabelKey
        Set-ForecastChipVisual -Chip $chip -Selected ($script:SelectedForecastSlotKey -eq $definition.Key)
    }
}

function Set-WidgetGradient {
    param(
        [string]$StartColor,
        [string]$MidColor,
        [string]$EndColor,
        [string]$GlowColor,
        [double]$GlowOpacity = 0.16
    )

    $border.Background = New-XamlObject @"
<LinearGradientBrush xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" StartPoint="0,0" EndPoint="1,1">
    <GradientStop Color="$StartColor" Offset="0"/>
    <GradientStop Color="$MidColor" Offset="0.52"/>
    <GradientStop Color="$EndColor" Offset="1"/>
</LinearGradientBrush>
"@
    $panelGlow.Opacity = $GlowOpacity
    $panelGlow.Background = New-XamlObject @"
<RadialGradientBrush xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Center="0.5,0.5" GradientOrigin="0.5,0.5" RadiusX="0.56" RadiusY="0.56">
    <GradientStop Color="$GlowColor" Offset="0"/>
    <GradientStop Color="#1FD8D4C8" Offset="0.42"/>
    <GradientStop Color="#00FAF9F5" Offset="1"/>
</RadialGradientBrush>
"@
}

function Apply-WeatherAmbience {
    param([object]$Snapshot)

    $script:ThunderActive = $false
    $rainLayer.Visibility = [System.Windows.Visibility]::Collapsed
    $rainLayer.Opacity = 0.0
    $lightningLayer.Visibility = [System.Windows.Visibility]::Collapsed
    $lightningLayer.Opacity = 0.0
    $panelSheen.Opacity = 0.24

    if ($null -eq $Snapshot) {
        Set-WidgetGradient -StartColor '#FFFAF9F5' -MidColor '#FFF3F1EA' -EndColor '#FFFFFFFF' -GlowColor '#55F3DED5' -GlowOpacity 0.18
        return
    }

    if ($Snapshot.IsThunderstorm) {
        Set-WidgetGradient -StartColor '#FFFAF9F5' -MidColor '#FFF3DED5' -EndColor '#FFFFFFFF' -GlowColor '#70D97757' -GlowOpacity 0.22
        $rainLayer.Visibility = [System.Windows.Visibility]::Visible
        $rainLayer.Opacity = 0.20
        $lightningLayer.Visibility = [System.Windows.Visibility]::Visible
        $script:ThunderActive = $true
        return
    }

    if ($Snapshot.IsRainingNow) {
        Set-WidgetGradient -StartColor '#FFFAF9F5' -MidColor '#FFF3F1EA' -EndColor '#FFFFFFFF' -GlowColor '#556A9BCC' -GlowOpacity 0.20
        $rainLayer.Visibility = [System.Windows.Visibility]::Visible
        $rainLayer.Opacity = 0.16
        $panelSheen.Opacity = 0.18
        return
    }

    if ($Snapshot.IsDay -eq 0) {
        Set-WidgetGradient -StartColor '#FFFAF9F5' -MidColor '#FFF3F1EA' -EndColor '#FFFFFFFF' -GlowColor '#55D8D4C8' -GlowOpacity 0.18
        return
    }

    if (@(0, 1) -contains $Snapshot.WeatherCode) {
        Set-WidgetGradient -StartColor '#FFFAF9F5' -MidColor '#FFF3F1EA' -EndColor '#FFFFFFFF' -GlowColor '#55F3DED5' -GlowOpacity 0.18
        return
    }

    Set-WidgetGradient -StartColor '#FFFAF9F5' -MidColor '#FFF3F1EA' -EndColor '#FFFFFFFF' -GlowColor '#55F3DED5' -GlowOpacity 0.18
}

function Update-WeatherVisualUi {
    param(
        [object]$Snapshot,
        [switch]$Offline,
        [switch]$Loading
    )

    if ($null -eq $weatherIconShell -or $null -eq $alertTextBlock) {
        return
    }

    if ($Loading) {
        $visual = [pscustomobject]@{
            IconKey = 'Cloud'
            Background = '#FFFAF9F5'
            Foreground = '#D97757'
            Glow = '#F3DED5'
        }
    } else {
        $visual = Get-WeatherVisualInfo -Snapshot $Snapshot
    }
    $weatherIconShell.Child = New-WeatherIconElement -IconKey $visual.IconKey -Foreground $visual.Foreground
    $weatherIconShell.Background = $visual.Background
    $weatherIconShell.Effect = New-GlowEffect -Color $visual.Glow -BlurRadius 14 -ShadowDepth 1 -Opacity 0.18

    if ($Loading) {
        $alert = [pscustomobject]@{
            Key = 'Loading'
            Icon = New-WeatherGlyph 0x231B
            Background = '#00FFFFFF'
            Foreground = '#8A867A'
            Glow = '#F3DED5'
            Active = $false
        }
    } elseif ($Offline) {
        $alert = [pscustomobject]@{
            Key = $(if ($null -eq $Snapshot) { 'WeatherUnavailable' } else { 'OfflineAlert' })
            Icon = New-WeatherGlyph 0x26A0
            Background = '#FFF3DED5'
            Foreground = '#D97757'
            Glow = '#D97757'
            Active = $true
        }
    } else {
        $alert = Get-WeatherAlertInfo -Snapshot $Snapshot
    }

    $alertIconBlock.Text = $alert.Icon
    $alertIconBlock.Foreground = $alert.Foreground
    if ($Loading) {
        $alertTextBlock.Text = ''
    } elseif ($Offline -and $null -eq $Snapshot) {
        $alertTextBlock.Text = Tx 'WeatherUnavailable'
    } else {
        $alertTextBlock.Text = Get-WeatherWarningDisplayText -Snapshot $Snapshot
    }
    $alertTextBlock.Foreground = $alert.Foreground
    Set-ControlAutomationName -Control $alertStrip -Name $alertTextBlock.Text
    $alertStrip.Background = $alert.Background
    if ($alert.Active) {
        $alertStrip.Effect = New-GlowEffect -Color $alert.Glow -BlurRadius 10 -ShadowDepth 1 -Opacity 0.14
    } else {
        $alertStrip.Effect = $null
    }
}

function Update-WeatherDisplay {
    param([object]$Snapshot)

    if ($null -ne $Snapshot -and $null -ne $Snapshot.PSObject.Properties['LocationKey'] -and -not [string]::IsNullOrWhiteSpace([string]$Snapshot.LocationKey) -and [string]$Snapshot.LocationKey -ne (Get-SelectedLocationKey)) {
        return
    }

    Apply-WeatherAmbience -Snapshot $Snapshot
    Update-ForecastChips
    Update-WeatherVisualUi -Snapshot $Snapshot
    $alertInfo = Get-WeatherAlertInfo -Snapshot $Snapshot

    Set-TopChromePlain -Border $statusShell
    if ($Snapshot.IsThunderstorm) {
        $statusBlock.Foreground = '#D97757'
    } elseif ($Snapshot.IsRainingNow) {
        $statusBlock.Foreground = '#B5473C'
    } elseif ($Snapshot.TodayRainMm -gt 0) {
        $statusBlock.Foreground = '#B5473C'
    } else {
        $statusBlock.Foreground = '#D97757'
    }

    $weatherText = Get-WeatherConditionDisplayText -Snapshot $Snapshot
    $script:CurrentStatusKey = 'Loaded'
    Set-UiSmokeItemStatus -State 'Loaded' -LocationKey (Get-SelectedLocationKey) -RequestId $script:ActiveWeatherRequestId
    $statusBlock.Text = Get-WeatherStatusDisplayText -Snapshot $Snapshot
    $titleBlock.Text = Get-WidgetTitle
    $modeBlock.Text = Format-ForecastModeLabel -Snapshot $Snapshot
    $conditionBlock.Text = $weatherText
    $nearTermBlock.Text = Convert-WeatherDisplayTextForLanguage -Text ([string]$Snapshot.NearTermForecast)
    $temperatureBlock.Text = Format-Celsius $Snapshot.TemperatureC 1
    $feelsBlock.Text = '{0} {1}' -f (Tx 'Feels'), (Format-Celsius $Snapshot.FeelsLikeC 1)

    $rows['Rain'].Row.Label.Text = if ($Snapshot.IsCurrent) { Tx 'RainNow' } else { Tx 'Rain' }
    $rows['DayRain'].Row.Label.Text = if ($Snapshot.IsCurrent) { Tx 'TodayRain' } else { Tx 'DayRain' }
    $rows['Rain'].Row.Value.Text = '{0} mm' -f (Format-Number $Snapshot.RainNowMm 1)
    $rows['DayRain'].Row.Value.Text = '{0} mm' -f (Format-Number $Snapshot.TodayRainMm 1)
    $rows['Probability'].Row.Value.Text = '{0}%' -f $Snapshot.RainProbability
    $rows['Humidity'].Row.Value.Text = '{0}%' -f (Format-Number $Snapshot.HumidityPercent 0)
    $rows['Cloud'].Row.Value.Text = '{0}%' -f (Format-Number $Snapshot.CloudCoverPercent 0)
    $rows['Pressure'].Row.Value.Text = '{0} hPa' -f (Format-Number $Snapshot.PressureHpa 1)
    $rows['Wind'].Row.Value.Text = '{0} km/h' -f (Format-Number $Snapshot.WindKmh 1)
    $rows['Gust'].Row.Value.Text = '{0} km/h' -f (Format-Number $Snapshot.WindGustKmh 1)

    $localTime = Get-Date
    $updatedBlock.Text = '{0} {1} | {2} {3} {4}' -f (Tx 'Updated'), $localTime.ToString('HH:mm:ss'), (Tx 'Source'), $Snapshot.Source, $Snapshot.SourceTime
    $updatedBlock.ToolTip = $null
}

function Set-ForecastSlot {
    param([string]$SlotKey)

    $definition = Get-ForecastSlotDefinition -SlotKey $SlotKey
    $script:SelectedForecastSlotKey = $definition.Key
    Update-ForecastChips

    if ($null -ne $script:LatestWeatherModel -and $script:LatestWeatherLocationKey -eq (Get-SelectedLocationKey)) {
        if (-not $script:LatestWeatherModel.SupportsForecastSlots -and $script:SelectedForecastSlotKey -ne 'Now') {
            $script:SelectedForecastSlotKey = 'Now'
            Update-ForecastChips
        }
        $snapshot = Get-WeatherSnapshotFromModel -Model $script:LatestWeatherModel -SlotKey $script:SelectedForecastSlotKey
        Update-WeatherDisplay -Snapshot $snapshot
    }
}

function Set-SettingsPanelOpen {
    param([bool]$Open)

    $script:SettingsOpen = $Open
    if ($Open) {
        $settingsPanel.Visibility = [System.Windows.Visibility]::Visible
        Set-TopChromePlain -Border $settingsButton
        Set-SettingsIconExpanded -Expanded $true
        Set-SettingsIconColor -Color '#B5473C'
    } else {
        $settingsPanel.Visibility = [System.Windows.Visibility]::Collapsed
        Set-TopChromePlain -Border $settingsButton
        Set-SettingsIconExpanded -Expanded $false
        Set-SettingsIconColor -Color '#D97757'
    }

    Set-WidgetWindowHeight -Window $window -SettingsOpen $Open
}
function Toggle-SettingsPanel {
    Set-SettingsPanelOpen -Open (-not $script:SettingsOpen)
}

function Refresh-ProvinceCombo {
    $provinceCombo.Items.Clear()
    foreach ($province in $script:Provinces) {
        $provinceCombo.Items.Add([pscustomobject]@{
            Key = $province.Key
            Display = Get-DisplayName $province
        }) | Out-Null
    }
    Select-ComboItem -Combo $provinceCombo -Property 'Key' -Value $script:SelectedProvinceKey
}

function Refresh-CityCombo {
    $cityCombo.Items.Clear()
    $province = Get-SelectedProvince
    foreach ($city in @($province.Cities)) {
        $cityCombo.Items.Add([pscustomobject]@{
            Key = $city.Key
            Display = Get-DisplayName $city
        }) | Out-Null
    }
    Select-ComboItem -Combo $cityCombo -Property 'Key' -Value $script:SelectedCityKey
}

function Refresh-DistrictCombo {
    $districtCombo.Items.Clear()
    $city = Get-SelectedCity
    foreach ($district in @($city.Districts)) {
        $districtCombo.Items.Add([pscustomobject]@{
            Key = $district.Key
            Display = Get-DisplayName $district
        }) | Out-Null
    }
    Select-ComboItem -Combo $districtCombo -Property 'Key' -Value $script:SelectedDistrictKey
}

function Refresh-ControlText {
    $script:UpdatingControls = $true
    try {
        $titleBlock.Text = Get-WidgetTitle
        $provinceCombo.ToolTip = Tx 'Province'
        $cityCombo.ToolTip = Tx 'City'
        $districtCombo.ToolTip = Tx 'District'
        $refreshCombo.ToolTip = Tx 'RefreshInterval'
        $forecastDateCombo.ToolTip = Tx 'StartTime'
        $forecastHourCombo.ToolTip = Tx 'EndTime'
        $languagePill.ToolTip = Tx 'Language'
        $settingsButton.ToolTip = Tx 'Settings'
        $closeButton.ToolTip = Tx 'Exit'
        $drawerHandle.ToolTip = Tx 'DrawerExpand'
        Set-ControlAutomationName -Control $provinceCombo -Name (Tx 'Province')
        Set-ControlAutomationName -Control $cityCombo -Name (Tx 'City')
        Set-ControlAutomationName -Control $districtCombo -Name (Tx 'District')
        Set-ControlAutomationName -Control $refreshCombo -Name (Tx 'RefreshInterval')
        Set-ControlAutomationName -Control $forecastDateCombo -Name (Tx 'StartTime')
        Set-ControlAutomationName -Control $forecastHourCombo -Name (Tx 'EndTime')
        Set-ControlAutomationName -Control $settingsButton -Name (Tx 'Settings')
        Set-ControlAutomationName -Control $closeButton -Name (Tx 'Exit')
        Set-ControlAutomationName -Control $drawerHandle -Name (Tx 'DrawerExpand')
        $settingsHeaderBlock.Text = Tx 'SettingsControls'
        $provinceField.Label.Text = Tx 'Province'
        $cityField.Label.Text = Tx 'City'
        $districtField.Label.Text = Tx 'District'
        $refreshField.Label.Text = Tx 'RefreshInterval'
        $languageField.Label.Text = Tx 'Language'
        $forecastDateField.Label.Text = Tx 'StartTime'
        $forecastHourField.Label.Text = Tx 'EndTime'
        Update-DrawerHandleVisual
        $refreshItem.Header = Tx 'RefreshNow'
        $exitItem.Header = Tx 'Exit'
        $timelineLabel.Text = Tx 'ForecastTime'

        foreach ($entry in $rows.GetEnumerator()) {
            $entry.Value.Row.Label.Text = Tx $entry.Value.LabelKey
        }
        if ($script:SelectedForecastSlotKey -eq 'Now') {
            $modeBlock.Text = Tx 'Now'
        }

        Refresh-ProvinceCombo
        Refresh-CityCombo
        Refresh-DistrictCombo

        $refreshCombo.Items.Clear()
        foreach ($seconds in @(60, 3600, 86400)) {
            $refreshCombo.Items.Add([pscustomobject]@{
                Key = [string]$seconds
                Seconds = $seconds
                Display = Get-RefreshLabel -Seconds $seconds
            }) | Out-Null
        }
        Select-ComboItem -Combo $refreshCombo -Property 'Seconds' -Value $script:RefreshSeconds
        Update-LanguagePill
        Update-ForecastChips
        Update-InfoCards
        Update-Countdown
    } finally {
        $script:UpdatingControls = $false
    }
}
function Set-RefreshInterval {
    param([int]$Seconds)

    if (-not (@(60, 3600, 86400) -contains $Seconds)) {
        $Seconds = 60
    }
    $script:RefreshSeconds = $Seconds
    if ($null -ne $timer) {
        $timer.Stop()
        $timer.Interval = [TimeSpan]::FromSeconds($script:RefreshSeconds)
        $timer.Start()
    }
    Reset-RefreshCountdown
    Update-InfoCards
}

function Set-WidgetLanguage {
    param([string]$Language)

    if ($script:Language -eq $Language) {
        return
    }

    $script:Language = $Language
    Refresh-ControlText
    Save-Settings
    Update-Weather
}

function Set-WeatherMetricPlaceholders {
    $rows['Rain'].Row.Label.Text = Tx 'RainNow'
    $rows['DayRain'].Row.Label.Text = Tx 'TodayRain'
    $rows['Rain'].Row.Value.Text = '-- mm'
    $rows['DayRain'].Row.Value.Text = '-- mm'
    $rows['Probability'].Row.Value.Text = '--%'
    $rows['Humidity'].Row.Value.Text = '--%'
    $rows['Cloud'].Row.Value.Text = '--%'
    $rows['Pressure'].Row.Value.Text = '-- hPa'
    $rows['Wind'].Row.Value.Text = '-- km/h'
    $rows['Gust'].Row.Value.Text = '-- km/h'
}

function Set-WeatherLoadingState {
    $script:CurrentStatusKey = 'Loading'
    $titleBlock.Text = Get-WidgetTitle
    $statusBlock.Text = Tx 'Loading'
    $statusBlock.Foreground = '#B5473C'
    Set-TopChromePlain -Border $statusShell
    $modeBlock.Text = Tx 'Now'
    $conditionBlock.Text = Tx 'FetchingWeather'
    $nearTermBlock.Text = Tx 'FetchingNearTerm'
    $temperatureBlock.Text = Format-Celsius $null 1
    $feelsBlock.Text = '--'
    Set-WeatherMetricPlaceholders
    Update-WeatherVisualUi -Snapshot $null -Loading
    $updatedBlock.Text = Tx 'UpdatingFooter'
    $updatedBlock.ToolTip = $null
    if ($null -ne $errorAutomationBlock) { $errorAutomationBlock.Text = '' }
}

function Set-WeatherUnavailableState {
    param([string]$ErrorMessage = '')

    $script:CurrentStatusKey = 'Offline'
    Set-UiSmokeItemStatus -State 'Error' -LocationKey (Get-SelectedLocationKey) -RequestId $script:ActiveWeatherRequestId
    $titleBlock.Text = Get-WidgetTitle
    $statusBlock.Text = Tx 'Offline'
    $statusBlock.Foreground = '#B5473C'
    Set-TopChromePlain -Border $statusShell
    $unavailableText = if ($ErrorMessage -like 'LOCATION_DATA_FAIL:*') { Tx 'CoordinateUnavailable' } else { Tx 'WeatherUnavailable' }
    $conditionBlock.Text = $unavailableText
    if ($null -ne $errorAutomationBlock) { $errorAutomationBlock.Text = $unavailableText }
    $nearTermBlock.Text = Tx 'NearTermUnavailable'
    $temperatureBlock.Text = Format-Celsius $null 1
    $feelsBlock.Text = '--'
    $modeBlock.Text = Tx 'Now'
    Set-WeatherMetricPlaceholders
    Update-WeatherVisualUi -Snapshot $null -Offline
    $updatedBlock.Text = '{0} {1}' -f (Tx 'LastTry'), (Get-Date -Format 'HH:mm:ss')
    $updatedBlock.ToolTip = $ErrorMessage
}

function Prepare-LocationChangedWeatherRefresh {
    Clear-ActiveWeatherModelForLocationChange
    if ($script:UiSmokeMode) {
        Set-UiSmokeItemStatus -State 'Loading' -LocationKey (Get-SelectedLocationKey) -RequestId ([int]$script:ActiveWeatherRequestId + 1)
    }
    Set-WeatherLoadingState
}

function Invoke-LocationChangedWeatherUpdate {
    if ($script:UiSmokeMode -and $null -ne $window) {
        if ($null -ne $script:PendingUiSmokeWeatherUpdateTimer) {
            try { $script:PendingUiSmokeWeatherUpdateTimer.Stop() } catch {}
            $script:PendingUiSmokeWeatherUpdateTimer = $null
        }

$timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(5000)
        $timer.Add_Tick({
            try { $script:PendingUiSmokeWeatherUpdateTimer.Stop() } catch {}
            $script:PendingUiSmokeWeatherUpdateTimer = $null
            Update-Weather
        }.GetNewClosure())
        $script:PendingUiSmokeWeatherUpdateTimer = $timer
        $timer.Start()
        return
    }

    Update-Weather
}

function Update-Weather {
    $request = Start-WeatherRequestContext
    $hadCurrentLocationModel = ($null -ne $script:LatestWeatherModel -and $script:LatestWeatherLocationKey -eq $request.LocationKey)

    try {
        $script:CurrentStatusKey = 'Updating'
        Set-UiSmokeItemStatus -State 'Loading' -LocationKey $request.LocationKey -RequestId $request.RequestId
        $statusBlock.Text = Tx 'Updating'
        $statusBlock.Foreground = '#B5473C'
        Set-TopChromePlain -Border $statusShell
        if (-not $hadCurrentLocationModel) {
            Set-WeatherLoadingState
        }
        [System.Windows.Forms.Application]::DoEvents()
        if ($script:UiSmokeMode -and $script:UiSmokeDelayMs -gt 0) {
            Start-Sleep -Milliseconds $script:UiSmokeDelayMs
            [System.Windows.Forms.Application]::DoEvents()
        }

        if (-not (Test-WeatherRequestIsCurrent -Request $request)) {
            return
        }

        $model = Get-WeatherModel
        $result = Resolve-WeatherRequestSuccess -Request $request -Model $model
        if (-not $result.ShouldApply) {
            if ($result.Status -eq 'LocationMismatch' -and (Test-WeatherRequestIsCurrent -Request $request)) {
                Set-WeatherUnavailableState -ErrorMessage 'Weather response location mismatch.'
            }
            return
        }

        $snapshot = Get-WeatherSnapshotFromModel -Model $result.Model -SlotKey $script:SelectedForecastSlotKey
        Update-WeatherDisplay -Snapshot $snapshot
    } catch {
        $refreshError = $_.Exception.Message
        $result = Resolve-WeatherRequestFailure -Request $request -ErrorMessage $refreshError
        if (-not $result.ShouldApply) {
            return
        }

        if ($result.UseCache -and $null -ne $result.Model) {
            try {
                $snapshot = Get-WeatherSnapshotFromModel -Model $result.Model -SlotKey $script:SelectedForecastSlotKey
                Update-WeatherDisplay -Snapshot $snapshot
                $nearTermBlock.Text = Format-CachedNearTermForecastText -Text $snapshot.NearTermForecast -FetchedAt $result.CacheEntry.FetchedAt
                Update-WeatherVisualUi -Snapshot $snapshot -Offline
                $script:CurrentStatusKey = 'Offline'
                $statusBlock.Text = Tx 'Offline'
                $statusBlock.Foreground = '#B5473C'
                Set-TopChromePlain -Border $statusShell
                $updatedBlock.Text = '{0} {1} | {2} {3}' -f (Tx 'LastTry'), (Get-Date -Format 'HH:mm:ss'), (Tx 'CachedData'), $result.CacheEntry.FetchedAt.ToString('HH:mm:ss')
                $updatedBlock.ToolTip = $refreshError
                return
            } catch {
                Set-WeatherUnavailableState -ErrorMessage $_.Exception.Message
                return
            }
        }

        Set-WeatherUnavailableState -ErrorMessage $refreshError
    } finally {
        if ($request.RequestId -eq $script:ActiveWeatherRequestId) {
            Reset-RefreshCountdown
        }
    }
}
$provinceCombo.Add_SelectionChanged({
    if ($script:UpdatingControls -or $null -eq $provinceCombo.SelectedItem) {
        return
    }

    if ($script:UiSmokeMode) { $script:UiSmokeSelectionChangedCount++ }
    $script:SelectedProvinceKey = $provinceCombo.SelectedItem.Key
    Reset-CityForSelectedProvince
    Refresh-ControlText
    Prepare-LocationChangedWeatherRefresh
    Save-Settings
    Invoke-LocationChangedWeatherUpdate
})

$cityCombo.Add_SelectionChanged({
    if ($script:UpdatingControls -or $null -eq $cityCombo.SelectedItem) {
        return
    }

    if ($script:UiSmokeMode) { $script:UiSmokeSelectionChangedCount++ }
    $script:SelectedCityKey = $cityCombo.SelectedItem.Key
    Reset-DistrictForSelectedCity
    Refresh-ControlText
    Prepare-LocationChangedWeatherRefresh
    Save-Settings
    Invoke-LocationChangedWeatherUpdate
})

$districtCombo.Add_SelectionChanged({
    if ($script:UpdatingControls -or $null -eq $districtCombo.SelectedItem) {
        return
    }

    if ($script:UiSmokeMode) { $script:UiSmokeSelectionChangedCount++ }
    $script:SelectedDistrictKey = $districtCombo.SelectedItem.Key
    $titleBlock.Text = Get-WidgetTitle
    $locationText = Get-LocationCardText
    $locationLineBlock.Text = $locationText
    $locationInfoCard.Value.Text = $locationText
    Prepare-LocationChangedWeatherRefresh
    Save-Settings
    Invoke-LocationChangedWeatherUpdate
})

$refreshCombo.Add_SelectionChanged({
    if ($script:UpdatingControls -or $null -eq $refreshCombo.SelectedItem) {
        return
    }

    Set-RefreshInterval -Seconds ([int]$refreshCombo.SelectedItem.Seconds)
    Save-Settings
    Update-Weather
})

$forecastDateCombo.Add_SelectionChanged({
    if ($script:UpdatingForecastControls -or $null -eq $forecastDateCombo.SelectedItem) {
        return
    }

    $dayItem = $forecastDateCombo.SelectedItem
    if ($dayItem.Key -eq 'Now') {
        Set-ForecastSlot -SlotKey 'Now'
        return
    }

    $hour = Get-ForecastHourFromSlot -SlotKey $script:SelectedForecastSlotKey
    if ($null -ne $forecastHourCombo.SelectedItem -and [int]$forecastHourCombo.SelectedItem.Hour -ge 0) {
        $hour = [int]$forecastHourCombo.SelectedItem.Hour
    }

    Set-ForecastSlot -SlotKey ('D{0}T{1:00}' -f ([int]$dayItem.DayOffset), $hour)
})

$forecastHourCombo.Add_SelectionChanged({
    if ($script:UpdatingForecastControls -or $null -eq $forecastDateCombo.SelectedItem -or $null -eq $forecastHourCombo.SelectedItem) {
        return
    }

    $dayItem = $forecastDateCombo.SelectedItem
    $hourItem = $forecastHourCombo.SelectedItem
    if ($dayItem.Key -eq 'Now' -or [int]$hourItem.Hour -lt 0) {
        return
    }

    Set-ForecastSlot -SlotKey ('D{0}T{1:00}' -f ([int]$dayItem.DayOffset), ([int]$hourItem.Hour))
})

$zhSegment.Add_GotKeyboardFocus({ $zhSegment.BorderBrush = if ($script:Language -eq 'zh') { '#FFFFFFFF' } else { '#D97757' } })
$zhSegment.Add_LostKeyboardFocus({ $zhSegment.BorderBrush = '#00000000' })
$zhSegment.Add_MouseLeftButtonUp({ Set-WidgetLanguage -Language 'zh' })
$zhSegment.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::Enter -or $eventArgs.Key -eq [System.Windows.Input.Key]::Space) {
        $eventArgs.Handled = $true
        Set-WidgetLanguage -Language 'zh'
    }
})

$enSegment.Add_GotKeyboardFocus({ $enSegment.BorderBrush = if ($script:Language -eq 'en') { '#FFFFFFFF' } else { '#D97757' } })
$enSegment.Add_LostKeyboardFocus({ $enSegment.BorderBrush = '#00000000' })
$enSegment.Add_MouseLeftButtonUp({ Set-WidgetLanguage -Language 'en' })
$enSegment.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::Enter -or $eventArgs.Key -eq [System.Windows.Input.Key]::Space) {
        $eventArgs.Handled = $true
        Set-WidgetLanguage -Language 'en'
    }
})

$settingsButton.Add_MouseLeftButtonUp({
    param($sender, $eventArgs)
    $eventArgs.Handled = $true
    Toggle-SettingsPanel
})
$settingsButton.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::Enter -or $eventArgs.Key -eq [System.Windows.Input.Key]::Space) {
        $eventArgs.Handled = $true
        Toggle-SettingsPanel
    }
})
$locationStrip.Add_MouseLeftButtonUp({
    param($sender, $eventArgs)
    $eventArgs.Handled = $true
    Toggle-SettingsPanel
})
$locationStrip.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::Enter -or $eventArgs.Key -eq [System.Windows.Input.Key]::Space) {
        $eventArgs.Handled = $true
        Toggle-SettingsPanel
    }
})
$locationInfoCard.Grid.Add_MouseLeftButtonUp({
    param($sender, $eventArgs)
    $eventArgs.Handled = $true
    Toggle-SettingsPanel
})
$locationInfoCard.Grid.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::Enter -or $eventArgs.Key -eq [System.Windows.Input.Key]::Space) {
        $eventArgs.Handled = $true
        Toggle-SettingsPanel
    }
})
$refreshInfoCard.Grid.Add_MouseLeftButtonUp({
    param($sender, $eventArgs)
    $eventArgs.Handled = $true
    Toggle-SettingsPanel
})
$refreshInfoCard.Grid.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::Enter -or $eventArgs.Key -eq [System.Windows.Input.Key]::Space) {
        $eventArgs.Handled = $true
        Toggle-SettingsPanel
    }
})
$languageInfoCard.Grid.Add_MouseLeftButtonUp({
    param($sender, $eventArgs)
    $eventArgs.Handled = $true
    Toggle-SettingsPanel
})
$languageInfoCard.Grid.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::Enter -or $eventArgs.Key -eq [System.Windows.Input.Key]::Space) {
        $eventArgs.Handled = $true
        Toggle-SettingsPanel
    }
})


$uiSmokeCommandTimer = New-Object System.Windows.Threading.DispatcherTimer
$uiSmokeCommandTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$uiSmokeCommandTimer.Add_Tick({ Invoke-UiSmokeControlCommand })

function Write-UiSmokeCommandTrace {
    param(
        [string]$Event,
        [object]$Command = $null
    )
    if (-not $script:UiSmokeMode -or [string]::IsNullOrWhiteSpace($script:UiSmokeOutput)) { return }
    try {
        $entry = [ordered]@{
            At = (Get-Date).ToString('HH:mm:ss.fff')
            Event = $Event
            LastCommandId = $script:UiSmokeLastCommandId
            ItemStatus = if ($null -ne $window) { [string]$window.GetValue([System.Windows.Automation.AutomationProperties]::ItemStatusProperty) } else { '' }
        }
        if ($null -ne $Command) {
            $entry.Command = $Command
        }
        ($entry | ConvertTo-Json -Depth 6 -Compress) | Add-Content -LiteralPath (Join-Path $script:UiSmokeOutput 'ui-smoke-command-trace.jsonl') -Encoding UTF8
    } catch {}
}

function Save-UiSmokeWindowRender {
    param([string]$Path)

    if (-not $script:UiSmokeMode -or [string]::IsNullOrWhiteSpace($Path) -or $null -eq $window) { return }
    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
    }
    $window.UpdateLayout()
    $width = [int][Math]::Ceiling($window.ActualWidth)
    $height = [int][Math]::Ceiling($window.ActualHeight)
    if ($width -le 0) { $width = [int][Math]::Ceiling($window.Width) }
    if ($height -le 0) { $height = [int][Math]::Ceiling($window.Height) }
    if ($width -le 0 -or $height -le 0) { throw 'Window render size is unavailable.' }

    $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap -ArgumentList $width, $height, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($window)
    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    try {
        $encoder.Save($stream)
    } finally {
        $stream.Dispose()
    }
}

function Invoke-UiSmokeControlCommand {
    if (-not $script:UiSmokeMode -or [string]::IsNullOrWhiteSpace($script:UiSmokeOutput)) { return }
    $commandPath = Join-Path $script:UiSmokeOutput 'ui-smoke-command.json'
    if (-not (Test-Path -LiteralPath $commandPath)) { return }

    try {
        $command = Get-Content -LiteralPath $commandPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return
    }

    $id = if ($null -ne $command.PSObject.Properties['Id']) { [string]$command.Id } else { '' }
    if ([string]::IsNullOrWhiteSpace($id) -or $id -eq $script:UiSmokeLastCommandId) { return }
    Write-UiSmokeCommandTrace -Event 'Received' -Command $command
    $script:UiSmokeLastCommandId = $id

    $action = if ($null -ne $command.PSObject.Properties['Action']) { [string]$command.Action } else { '' }
    switch ($action) {
        'SelectLocation' {
            Write-UiSmokeCommandTrace -Event 'SelectLocation' -Command $command
            if ($null -ne $command.PSObject.Properties['ProvinceKey']) {
                Select-ComboItem -Combo $provinceCombo -Property 'Key' -Value ([string]$command.ProvinceKey)
                [System.Windows.Forms.Application]::DoEvents()
            }
            if ($null -ne $command.PSObject.Properties['CityKey']) {
                Select-ComboItem -Combo $cityCombo -Property 'Key' -Value ([string]$command.CityKey)
                [System.Windows.Forms.Application]::DoEvents()
            }
            if ($null -ne $command.PSObject.Properties['DistrictKey']) {
                Select-ComboItem -Combo $districtCombo -Property 'Key' -Value ([string]$command.DistrictKey)
                [System.Windows.Forms.Application]::DoEvents()
            }
        }
        'Refresh' {
            Write-UiSmokeCommandTrace -Event 'Refresh' -Command $command
            Update-Weather
        }
        'Language' {
            Write-UiSmokeCommandTrace -Event 'Language' -Command $command
            if ($null -ne $command.PSObject.Properties['Language']) { Set-WidgetLanguage -Language ([string]$command.Language) }
        }
        'InjectFixtureWeather' {
            Write-UiSmokeCommandTrace -Event 'InjectFixtureWeather' -Command $command
            $fixtureName = if ($null -ne $command.PSObject.Properties['Fixture']) { [string]$command.Fixture } else { 'current-no-rain-future-heavy-rain' }
            $previousFixture = $script:UiFixture
            try {
                $script:UiFixture = $fixtureName
                $request = Start-WeatherRequestContext
                $model = Get-UiSmokeWeatherModel
                $result = Resolve-WeatherRequestSuccess -Request $request -Model $model
                if ($result.ShouldApply) {
                    $snapshot = Get-WeatherSnapshotFromModel -Model $result.Model -SlotKey $script:SelectedForecastSlotKey
                    Update-WeatherDisplay -Snapshot $snapshot
                }
            } finally {
                $script:UiFixture = $previousFixture
            }
        }
        'CaptureWindow' {
            Write-UiSmokeCommandTrace -Event 'CaptureWindow' -Command $command
            $capturePath = if ($null -ne $command.PSObject.Properties['Path']) { [string]$command.Path } else { Join-Path $script:UiSmokeOutput 'ui-smoke-window.png' }
            Save-UiSmokeWindowRender -Path $capturePath
        }
    }
}
$refreshItem.Add_Click({ Update-Weather })

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds($script:RefreshSeconds)
$timer.Add_Tick({ Update-Weather })

$countdownTimer = New-Object System.Windows.Threading.DispatcherTimer
$countdownTimer.Interval = [TimeSpan]::FromSeconds(1)
$countdownTimer.Add_Tick({ Update-Countdown })

$lightningResetTimer = New-Object System.Windows.Threading.DispatcherTimer
$lightningResetTimer.Interval = [TimeSpan]::FromMilliseconds(120)
$lightningResetTimer.Add_Tick({
    $lightningResetTimer.Stop()
    $lightningLayer.Opacity = 0.0
})

$lightningTimer = New-Object System.Windows.Threading.DispatcherTimer
$lightningTimer.Interval = [TimeSpan]::FromSeconds(7)
$lightningTimer.Add_Tick({
    if ($script:ReduceMotion -or -not $script:ThunderActive) {
        return
    }
    $lightningLayer.Visibility = [System.Windows.Visibility]::Visible
    $lightningLayer.Opacity = 0.18
    $lightningResetTimer.Start()
})

$initialRefreshTimer = New-Object System.Windows.Threading.DispatcherTimer
$initialRefreshTimer.Interval = [TimeSpan]::FromMilliseconds(900)
$initialRefreshTimer.Add_Tick({
    $initialRefreshTimer.Stop()
    Update-Weather
})

Refresh-ControlText

$window.Add_SourceInitialized({
    Move-ToDefaultPosition -Window $window
})

$window.Add_Closing({
    Update-DrawerWindowState -Window $window
    Save-Settings
})

$window.Add_ContentRendered({
    $timer.Start()
    $countdownTimer.Start()
    $lightningTimer.Start()
    $initialRefreshTimer.Start()
    if ($script:UiSmokeMode) { $uiSmokeCommandTimer.Start() }
})

[void]$window.ShowDialog()
