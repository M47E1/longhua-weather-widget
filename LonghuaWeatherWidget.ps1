param(
    [int]$RefreshSeconds = 60,
    [switch]$NoTopMost,
    [switch]$TestMode
)

$ErrorActionPreference = 'Stop'

if (-not $TestMode -and $env:LONGHUA_WEATHER_WIDGET_TEST_MODE -ne '1' -and [Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    throw 'Longhua Weather Widget must run in STA mode. Start it with powershell.exe -Sta or use the packaged EXE.'
}

function T {
    param([string]$Base64)

    try {
        return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Base64))
    } catch {
        return $Base64
    }
}

function Get-LonghuaWeatherSettingsPath {
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = $env:LOCALAPPDATA
    }
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        throw 'LOCALAPPDATA is not available. Cannot resolve the widget settings path.'
    }

    return (Join-Path (Join-Path $localAppData 'LonghuaWeatherWidget') 'settings.json')
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

$script:SettingsPath = Get-LonghuaWeatherSettingsPath
$script:LastSettingsError = $null
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
$script:WindowClosedHeight = 420
$script:WindowSettingsHeight = 548
$script:TopChromeButtonSize = 32
$script:TopChromeColumnWidth = 36
$script:UpdatingForecastControls = $false
$script:LatestWeatherModel = $null
$script:ThunderActive = $false
$script:DrawerEdge = $null
$script:DrawerExpanded = $true
$script:DrawerVisibleStrip = 34
$script:DrawerSnapThreshold = 28
$script:DrawerAdjusting = $false
$script:DraggingWindow = $false
$script:DrawerHoverArmed = $true

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
        [object]$Lon = $null
    )

    [pscustomobject]@{
        Key = $Key
        En = $En
        Zh = $Zh
        Lat = $Lat
        Lon = $Lon
    }
}

function New-City {
    param(
        [string]$Key,
        [string]$En,
        [string]$Zh,
        [object]$Lat,
        [object]$Lon,
        [object[]]$Districts
    )

    [pscustomobject]@{
        Key = $Key
        En = $En
        Zh = $Zh
        Lat = $Lat
        Lon = $Lon
        Districts = $Districts
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
            New-District 'Nancheng' 'Nancheng' '5Y2X5Z+O'
            New-District 'Songshanhu' 'Songshan Lake' '5p2+5bGx5rmW'
            New-District 'Guancheng' 'Guancheng' '6I6e5Z+O'
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

$script:Text = @{
    Loading = @{ Zh = '5Yqg6L295Lit'; En = 'Loading' }
    Updating = @{ Zh = '5q2j5Zyo5pu05paw'; En = 'Updating' }
    Live = @{ Zh = '5a6e5pe2'; En = 'Live' }
    Offline = @{ Zh = '56a757q/'; En = 'Offline' }
    Weather = @{ Zh = '5aSp5rCU'; En = 'Weather' }
    Settings = @{ Zh = '6K6+572u'; En = 'Settings' }
    Location = @{ Zh = '5L2N572u'; En = 'Location' }
    Province = @{ Zh = '55yB'; En = 'Province' }
    City = @{ Zh = '5Z+O5biC'; En = 'City' }
    District = @{ Zh = '5Yy6'; En = 'District' }
    Language = @{ Zh = '6K+t6KiA'; En = 'Language' }
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
    RefreshNow = @{ Zh = '56uL5Y2z5Yi35paw'; En = 'Refresh now' }
    Exit = @{ Zh = '6YCA5Ye6'; En = 'Exit' }
    RainingNow = @{ Zh = '5b2T5YmN6ZmN6Zuo'; En = 'Raining now' }
    RainedToday = @{ Zh = '5LuK5aSp5LiL6L+H6Zuo'; En = 'Rained today' }
    NoRain = @{ Zh = '5pqC5peg6Zuo'; En = 'No rain' }
    LastTry = @{ Zh = '5LiK5qyh5bCd6K+V'; En = 'Last try' }
    AlertStatus = @{ Zh = '6aKE6K2m'; En = 'Alert' }
    ActiveAlert = @{ Zh = '5b2T5YmN6aKE6K2m'; En = 'Active alert' }
    NoWeatherAlert = @{ Zh = '5aSp5rCU5bmz56iz'; En = 'No active alert' }
    ThunderstormAlert = @{ Zh = '6Zu35pq06aKE6K2m'; En = 'Thunderstorm alert' }
    HeavyRainAlert = @{ Zh = '5by66ZmN6Zuo6aKE6K2m'; En = 'Heavy rain alert' }
    GaleAlert = @{ Zh = '5aSn6aOO6aKE6K2m'; En = 'Gale alert' }
    TyphoonAlert = @{ Zh = '5Y+w6aOO6aKE6K2m'; En = 'Typhoon alert' }
    OfflineAlert = @{ Zh = '56a757q/77ya5pi+56S65pyA6L+R5pWw5o2u'; En = 'Offline: showing last data' }
    ForecastThunderstorm = @{ Zh = '6aKE5oql6Zu35pq0'; En = 'Thunderstorm forecast' }
    ForecastHeavyRain = @{ Zh = '6aKE5oql5by66ZmN6Zuo'; En = 'Heavy rain forecast' }
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

    return ($null -ne $Value -and -not [string]::IsNullOrWhiteSpace([string]$Value))
}

function Get-SelectedWeatherLocation {
    $city = Get-SelectedCity
    $district = Get-SelectedDistrict

    if ((Test-CoordinateValue $district.Lat) -and (Test-CoordinateValue $district.Lon)) {
        return [pscustomobject]@{
            Lat = [double]$district.Lat
            Lon = [double]$district.Lon
            Level = 'District'
            Label = Get-DisplayName $district
        }
    }

    # District coordinates are optional in the local data. When absent, the
    # selected district is kept in settings/UI and weather falls back to city coordinates.
    return [pscustomobject]@{
        Lat = [double]$city.Lat
        Lon = [double]$city.Lon
        Level = 'City'
        Label = Get-DisplayName $city
    }
}

function Ensure-SettingsDirectory {
    $settingsDirectory = Split-Path -Parent $script:SettingsPath
    if ([string]::IsNullOrWhiteSpace($settingsDirectory)) {
        throw 'Cannot resolve the widget settings directory.'
    }
    if (-not (Test-Path -LiteralPath $settingsDirectory)) {
        New-Item -ItemType Directory -Path $settingsDirectory -Force | Out-Null
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
        SavedAt = (Get-Date).ToString('s')
    }

    try {
        Ensure-SettingsDirectory
        $settings | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
        $script:LastSettingsError = $null
    } catch {
        $script:LastSettingsError = $_.Exception.Message
    }
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
        [string]$Foreground = '#EAF2F8',
        [string]$FontWeight = 'Normal',
        [double]$Opacity = 1.0
    )

    $block = New-Object System.Windows.Controls.TextBlock
    $block.Text = $Text
    $block.FontFamily = 'Segoe UI'
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
        [string]$GlowColor = '#E95A96',
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
        $Border.Effect = New-GlowEffect -Color '#EFB4CA' -BlurRadius 10 -ShadowDepth 1 -Opacity 0.14
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
    <Setter Property="Background" Value="#FFFFF7FB"/>
    <Setter Property="Foreground" Value="#432333"/>
    <Setter Property="BorderBrush" Value="#00FFFFFF"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
    <Setter Property="VerticalContentAlignment" Value="Center"/>
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
                        <Setter TargetName="ItemBorder" Property="Background" Value="#FFFFEAF3"/>
                        <Setter TargetName="ItemBorder" Property="BorderBrush" Value="#00FFFFFF"/>
                        <Setter Property="Foreground" Value="#432333"/>
                    </Trigger>
                    <Trigger Property="IsHighlighted" Value="True">
                        <Setter TargetName="ItemBorder" Property="Background" Value="#FFFFEAF3"/>
                        <Setter TargetName="ItemBorder" Property="BorderBrush" Value="#00FFFFFF"/>
                        <Setter Property="Foreground" Value="#432333"/>
                    </Trigger>
                    <Trigger Property="IsSelected" Value="True">
                        <Setter TargetName="ItemBorder" Property="Background" Value="#E95A96"/>
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
    <Setter Property="Foreground" Value="#432333"/>
    <Setter Property="Background" Value="#FFFFF7FB"/>
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
                                        BorderThickness="0"
                                        CornerRadius="9"
                                        SnapsToDevicePixels="True">
                                    <Border.Effect>
                                        <DropShadowEffect BlurRadius="10"
                                                          ShadowDepth="1"
                                                          Opacity="0.22"
                                                          Color="#EFB4CA"/>
                                    </Border.Effect>
                                    <Grid>
                                        <Border Margin="1"
                                                CornerRadius="8"
                                                BorderBrush="#00FFFFFF"
                                                BorderThickness="0"
                                                Background="#10FFFFFF"/>
                                        <Border Margin="2,1,2,0"
                                                Height="11"
                                                VerticalAlignment="Top"
                                                CornerRadius="7,7,4,4"
                                                 Background="#40FFFFFF"/>
                                        <Path x:Name="Arrow"
                                              Width="8"
                                              Height="5"
                                              HorizontalAlignment="Right"
                                              VerticalAlignment="Center"
                                              Margin="0,0,11,0"
                                              Data="M 0 0 L 4 5 L 8 0 Z"
                                               Fill="#B85277"/>
                                    </Grid>
                                </Border>
                                <ControlTemplate.Triggers>
                                    <Trigger Property="IsMouseOver" Value="True">
                                        <Setter TargetName="Chrome" Property="Background" Value="#FFFFEAF3"/>
                                        <Setter TargetName="Chrome" Property="BorderBrush" Value="#00FFFFFF"/>
                                        <Setter TargetName="Arrow" Property="Fill" Value="#8A3857"/>
                                    </Trigger>
                                    <Trigger Property="IsChecked" Value="True">
                                        <Setter TargetName="Chrome" Property="Background" Value="#FFFFEAF3"/>
                                        <Setter TargetName="Chrome" Property="BorderBrush" Value="#00FFFFFF"/>
                                        <Setter TargetName="Arrow" Property="Fill" Value="#8A3857"/>
                                    </Trigger>
                                    <Trigger Property="IsEnabled" Value="False">
                                        <Setter TargetName="Chrome" Property="Opacity" Value="0.55"/>
                                    </Trigger>
                                </ControlTemplate.Triggers>
                            </ControlTemplate>
                        </ToggleButton.Template>
                    </ToggleButton>
                    <ContentPresenter x:Name="ContentSite"
                                      Margin="{TemplateBinding Padding}"
                                      IsHitTestVisible="False"
                                      HorizontalAlignment="Left"
                                      VerticalAlignment="Center"
                                      Content="{TemplateBinding SelectionBoxItem}"
                                      ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                      ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}"
                                      TextElement.Foreground="{TemplateBinding Foreground}"/>
                    <Popup x:Name="PART_Popup"
                           AllowsTransparency="True"
                           Focusable="False"
                           IsOpen="{TemplateBinding IsDropDownOpen}"
                           Placement="Bottom"
                           PopupAnimation="None">
                        <Grid MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}"
                              MaxHeight="{TemplateBinding MaxDropDownHeight}">
                            <Border Background="#FFFFF7FB"
                                    BorderBrush="#00FFFFFF"
                                    BorderThickness="0"
                                    CornerRadius="11"
                                    Padding="4"
                                    SnapsToDevicePixels="True">
                                <Border.Effect>
                                    <DropShadowEffect BlurRadius="18"
                                                      ShadowDepth="6"
                                                      Opacity="0.48"
                                                      Color="#EFB4CA"/>
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
                        <Setter Property="BorderBrush" Value="#00FFFFFF"/>
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
            <Setter Property="Background" Value="#FFFFEAF3"/>
            <Setter Property="BorderBrush" Value="#00FFFFFF"/>
            <Setter Property="Foreground" Value="#432333"/>
        </Trigger>
        <Trigger Property="IsKeyboardFocusWithin" Value="True">
            <Setter Property="Background" Value="#FFFFEAF3"/>
            <Setter Property="BorderBrush" Value="#00FFFFFF"/>
            <Setter Property="Foreground" Value="#432333"/>
        </Trigger>
    </Style.Triggers>
</Style>
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
    $combo.DisplayMemberPath = 'Display'
    $combo.SelectedValuePath = 'Key'
    $combo.Background = '#FFFFF7FB'
    $combo.Foreground = '#432333'
    $combo.BorderBrush = '#00FFFFFF'
    $combo.Padding = '10,3,32,3'
    $combo.MaxDropDownHeight = 360
    $combo.IsTextSearchEnabled = $true
    $combo.IsTabStop = $true
    $combo.Style = New-ComboBoxStyle
    $combo.ItemContainerStyle = New-ComboBoxItemStyle
    return $combo
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
            return
        }
    }
    if ($Combo.Items.Count -gt 0) {
        $Combo.SelectedIndex = 0
    }
}

function New-Row {
    param(
        [string]$Label,
        [string]$Value
    )

    $card = New-Object System.Windows.Controls.Border
    $card.Height = 38
    $card.CornerRadius = 8
    $card.Padding = '9,4,9,4'
    $card.Background = '#FDFDF4F8'
    $card.BorderBrush = '#00FFFFFF'
    $card.BorderThickness = 0
    $card.Effect = New-GlowEffect -Color '#EFB4CA' -BlurRadius 9 -ShadowDepth 1 -Opacity 0.14
    $card.RenderTransform = New-Object System.Windows.Media.TranslateTransform
    $card.RenderTransformOrigin = '0.5,0.5'

    $stack = New-Object System.Windows.Controls.StackPanel
    $card.Child = $stack

    $labelBlock = New-TextBlock -Text $Label -FontSize 9.5 -Foreground '#9B5F75'
    $labelBlock.Margin = '0,0,0,0'
    $stack.Children.Add($labelBlock) | Out-Null

    $valueBlock = New-TextBlock -Text $Value -FontSize 12.5 -Foreground '#432333' -FontWeight 'SemiBold'
    $stack.Children.Add($valueBlock) | Out-Null

    $card.Add_MouseEnter({
        $card.Background = '#FFFFEAF3'
        if (-not $script:ReduceMotion) {
            $card.RenderTransform.Y = -1
        }
    }.GetNewClosure())
    $card.Add_MouseLeave({
        $card.Background = '#FDFDF4F8'
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
    $card.Background = '#F8FFF7FB'
    $card.BorderBrush = '#00FFFFFF'
    $card.BorderThickness = 0
    $card.Cursor = [System.Windows.Input.Cursors]::Hand
    $card.Focusable = $true
    $card.SetValue([System.Windows.Input.KeyboardNavigation]::IsTabStopProperty, $true)
    $card.Effect = New-GlowEffect -Color '#EFB4CA' -BlurRadius 9 -ShadowDepth 1 -Opacity 0.12
    $card.RenderTransform = New-Object System.Windows.Media.TranslateTransform
    $card.RenderTransformOrigin = '0.5,0.5'

    $stack = New-Object System.Windows.Controls.StackPanel
    $card.Child = $stack

    $labelBlock = New-TextBlock -Text $Label -FontSize 9.5 -Foreground '#9B5F75'
    $labelBlock.Margin = '0,0,0,2'
    $stack.Children.Add($labelBlock) | Out-Null

    $valueBlock = New-TextBlock -Text $Value -FontSize 11.5 -Foreground '#432333' -FontWeight 'SemiBold'
    $valueBlock.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    $stack.Children.Add($valueBlock) | Out-Null

    $card.Add_MouseEnter({
        $card.Background = '#FFFFEAF3'
        if (-not $script:ReduceMotion) {
            $card.RenderTransform.Y = -1
        }
    }.GetNewClosure())
    $card.Add_MouseLeave({
        $card.Background = '#F8FFF7FB'
        if (-not $script:ReduceMotion) {
            $card.RenderTransform.Y = 0
        }
    }.GetNewClosure())
    $card.Add_GotKeyboardFocus({
        $card.Background = '#FFFFEAF3'
    }.GetNewClosure())
    $card.Add_LostKeyboardFocus({
        $card.Background = '#F8FFF7FB'
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
        $Chip.Grid.Background = '#E95A96'
        $Chip.Grid.BorderBrush = '#00FFFFFF'
        $Chip.Text.Foreground = '#FFFFFF'
        $Chip.Text.FontWeight = 'Bold'
        $Chip.Grid.Effect = New-GlowEffect -Color '#E95A96' -BlurRadius 14 -ShadowDepth 1 -Opacity 0.22
    } else {
        $Chip.Grid.Background = '#F8FFF7FB'
        $Chip.Grid.BorderBrush = '#00FFFFFF'
        $Chip.Text.Foreground = '#74384F'
        $Chip.Text.FontWeight = 'SemiBold'
        $Chip.Grid.Effect = New-GlowEffect -Color '#EFB4CA' -BlurRadius 8 -ShadowDepth 1 -Opacity 0.12
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
    $chip.Cursor = [System.Windows.Input.Cursors]::Hand
    $chip.Focusable = $true
    $chip.SetValue([System.Windows.Input.KeyboardNavigation]::IsTabStopProperty, $true)
    $chip.RenderTransform = $transformGroup
    $chip.RenderTransformOrigin = '0.5,0.5'

    $text = New-TextBlock -Text (Tx $Definition.LabelKey) -FontSize 11 -Foreground '#74384F' -FontWeight 'SemiBold'
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
            $chipObject.Grid.Background = '#FFFFEAF3'
            $chipObject.Grid.BorderBrush = '#00FFFFFF'
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
        $chipObject.Grid.BorderBrush = '#00FFFFFF'
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

    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $Window.Height = [Math]::Min($script:WindowClosedHeight, [Math]::Max($script:WindowMinHeight, $area.Height - 54))
    $Window.Left = $area.Left + 8
    $Window.Top = $area.Top + 27
}

function Get-WindowActualWidth {
    param([System.Windows.Window]$Window)

    if ($null -eq $Window) {
        return 386
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

function Get-WindowWorkingArea {
    param([System.Windows.Window]$Window)

    $primary = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    if ($null -eq $Window) {
        return $primary
    }

    $width = Get-WindowActualWidth -Window $Window
    $height = Get-WindowActualHeight -Window $Window
    $centerX = $Window.Left + ($width / 2)
    $centerY = $Window.Top + ($height / 2)

    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        $bounds = $screen.Bounds
        if ($centerX -ge $bounds.Left -and $centerX -le $bounds.Right -and
            $centerY -ge $bounds.Top -and $centerY -le $bounds.Bottom) {
            return $screen.WorkingArea
        }
    }

    return $primary
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

    if (-not [string]::IsNullOrWhiteSpace([string]$script:DrawerEdge)) {
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
        [bool]$Expanded
    )

    if ($null -eq $Window -or [string]::IsNullOrWhiteSpace([string]$script:DrawerEdge)) {
        return
    }

    $area = Get-WindowWorkingArea -Window $Window
    $width = Get-WindowActualWidth -Window $Window
    $height = Get-WindowActualHeight -Window $Window
    $gap = 4
    $strip = [Math]::Max(22, [double]$script:DrawerVisibleStrip)

    $script:DrawerAdjusting = $true
    try {
        switch ($script:DrawerEdge) {
            'Left' {
                $Window.Top = Limit-Double -Value $Window.Top -Min ($area.Top + $gap) -Max ($area.Bottom - $height - $gap)
                $Window.Left = if ($Expanded) { $area.Left + $gap } else { $area.Left - $width + $strip }
            }
            'Right' {
                $Window.Top = Limit-Double -Value $Window.Top -Min ($area.Top + $gap) -Max ($area.Bottom - $height - $gap)
                $Window.Left = if ($Expanded) { $area.Right - $width - $gap } else { $area.Right - $strip }
            }
            'Top' {
                $Window.Left = Limit-Double -Value $Window.Left -Min ($area.Left + $gap) -Max ($area.Right - $width - $gap)
                $Window.Top = if ($Expanded) { $area.Top + $gap } else { $area.Top - $height + $strip }
            }
            'Bottom' {
                $Window.Left = Limit-Double -Value $Window.Left -Min ($area.Left + $gap) -Max ($area.Right - $width - $gap)
                $Window.Top = if ($Expanded) { $area.Bottom - $height - $gap } else { $area.Bottom - $strip }
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
        [bool]$Expanded
    )

    if ([string]::IsNullOrWhiteSpace($Edge)) {
        $script:DrawerEdge = $null
        $script:DrawerExpanded = $true
        $script:DrawerHoverArmed = $true
        return
    }

    $script:DrawerEdge = $Edge
    $script:DrawerExpanded = $Expanded
    $script:DrawerHoverArmed = $Expanded
    Set-DrawerEdgePosition -Window $Window -Expanded $Expanded
}

function Update-DrawerDockAfterDrag {
    param([System.Windows.Window]$Window)

    if ($null -eq $Window -or $script:DrawerAdjusting) {
        return
    }

    $area = Get-WindowWorkingArea -Window $Window
    $width = Get-WindowActualWidth -Window $Window
    $height = Get-WindowActualHeight -Window $Window
    $threshold = [double]$script:DrawerSnapThreshold
    $cursor = [System.Windows.Forms.Cursor]::Position
    $edges = @()

    if ($cursor.X -le ($area.Left + $threshold) -or $Window.Left -lt $area.Left) {
        $edges += [pscustomobject]@{
            Name = 'Left'
            Distance = [Math]::Min(($cursor.X - $area.Left), ($Window.Left - $area.Left))
        }
    }
    if ($cursor.X -ge ($area.Right - $threshold) -or ($Window.Left + $width) -gt $area.Right) {
        $edges += [pscustomobject]@{
            Name = 'Right'
            Distance = [Math]::Min(($area.Right - $cursor.X), ($area.Right - ($Window.Left + $width)))
        }
    }
    if ($cursor.Y -le ($area.Top + $threshold) -or $Window.Top -lt $area.Top) {
        $edges += [pscustomobject]@{
            Name = 'Top'
            Distance = [Math]::Min(($cursor.Y - $area.Top), ($Window.Top - $area.Top))
        }
    }
    if ($cursor.Y -ge ($area.Bottom - $threshold) -or ($Window.Top + $height) -gt $area.Bottom) {
        $edges += [pscustomobject]@{
            Name = 'Bottom'
            Distance = [Math]::Min(($area.Bottom - $cursor.Y), ($area.Bottom - ($Window.Top + $height)))
        }
    }

    $bestEdge = $edges | Sort-Object -Property Distance | Select-Object -First 1

    if ($null -ne $bestEdge) {
        Set-WindowDrawerState -Window $Window -Edge $bestEdge.Name -Expanded $false
    } else {
        Set-WindowDrawerState -Window $Window -Edge $null -Expanded $true
    }
}

function Expand-WindowDrawer {
    param([System.Windows.Window]$Window)

    if ($script:DrawerEdge -and -not $script:DrawerExpanded -and $script:DrawerHoverArmed) {
        $script:DrawerExpanded = $true
        $script:DrawerHoverArmed = $true
        Set-DrawerEdgePosition -Window $Window -Expanded $true
    }
}

function Collapse-WindowDrawer {
    param([System.Windows.Window]$Window)

    if ($script:DrawerEdge -and $script:DrawerExpanded -and -not $script:DraggingWindow) {
        $script:DrawerExpanded = $false
        $script:DrawerHoverArmed = $true
        Set-DrawerEdgePosition -Window $Window -Expanded $false
    }
}

function Test-DragOriginInteractive {
    param([object]$OriginalSource)

    $interactiveElements = @(
        $settingsButton,
        $closeButton,
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
            $script:DrawerHoverArmed = $true
            Expand-WindowDrawer -Window $Window
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

function ConvertTo-WeatherDateTime {
    param([object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    return [DateTime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture)
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
function New-WeatherGlyph {
    param([int]$CodePoint)

    return [System.Char]::ConvertFromUtf32($CodePoint)
}

function Get-WeatherAlertInfo {
    param([object]$Snapshot)

    if ($null -eq $Snapshot) {
        return [pscustomobject]@{
            Key = 'OfflineAlert'
            Icon = New-WeatherGlyph 0x26A0
            Background = '#FFFFEAF3'
            Foreground = '#9A3363'
            Glow = '#E95A96'
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
                Background = '#FFFFEAF3'
                Foreground = '#8A244F'
                Glow = '#D94D83'
                Active = $false
            }
        }

        if ($Snapshot.IsThunderstorm) {
            return [pscustomobject]@{
                Key = 'ForecastThunderstorm'
                Icon = New-WeatherGlyph 0x26C8
                Background = '#FFFFEAF3'
                Foreground = '#8A244F'
                Glow = '#E95A96'
                Active = $false
            }
        }

        if ($rainNow -ge 8 -or $dayRain -ge 50 -or ($rainProbability -ge 90 -and $dayRain -ge 20)) {
            return [pscustomobject]@{
                Key = 'ForecastHeavyRain'
                Icon = New-WeatherGlyph 0x1F327
                Background = '#FFFFEAF3'
                Foreground = '#8A3857'
                Glow = '#E95A96'
                Active = $false
            }
        }

        if ($wind -ge 39 -or $gust -ge 62) {
            return [pscustomobject]@{
                Key = 'ForecastGale'
                Icon = New-WeatherGlyph 0x1F32C
                Background = '#FFFFEEF6'
                Foreground = '#8A3857'
                Glow = '#EFB4CA'
                Active = $false
            }
        }

        return [pscustomobject]@{
            Key = 'NoWeatherAlert'
            Icon = New-WeatherGlyph 0x2600
            Background = '#00FFFFFF'
            Foreground = '#9B5F75'
            Glow = '#EFB4CA'
            Active = $false
        }
    }

    if ($wind -ge 62 -or $gust -ge 88) {
        return [pscustomobject]@{
            Key = 'TyphoonAlert'
            Icon = New-WeatherGlyph 0x1F300
            Background = '#FFFFE1EA'
            Foreground = '#8A244F'
            Glow = '#D94D83'
            Active = $true
        }
    }

    if ($Snapshot.IsThunderstorm) {
        return [pscustomobject]@{
            Key = 'ThunderstormAlert'
            Icon = New-WeatherGlyph 0x26C8
            Background = '#FFFFE6EF'
            Foreground = '#8A244F'
            Glow = '#E95A96'
            Active = $true
        }
    }

    if ($rainNow -ge 8 -or $dayRain -ge 50 -or ($rainProbability -ge 90 -and $dayRain -ge 20)) {
        return [pscustomobject]@{
            Key = 'HeavyRainAlert'
            Icon = New-WeatherGlyph 0x1F327
            Background = '#FFFFEAF3'
            Foreground = '#8A3857'
            Glow = '#E95A96'
            Active = $true
        }
    }

    if ($wind -ge 39 -or $gust -ge 62) {
        return [pscustomobject]@{
            Key = 'GaleAlert'
            Icon = New-WeatherGlyph 0x1F32C
            Background = '#FFFFEEF6'
            Foreground = '#8A3857'
            Glow = '#EFB4CA'
            Active = $true
        }
    }

    return [pscustomobject]@{
        Key = 'NoWeatherAlert'
        Icon = New-WeatherGlyph 0x2600
        Background = '#00FFFFFF'
        Foreground = '#9B5F75'
        Glow = '#EFB4CA'
        Active = $false
    }
}
function Get-WeatherVisualInfo {
    param([object]$Snapshot)

    if ($null -eq $Snapshot) {
        return [pscustomobject]@{
            IconKey = 'Offline'
            Icon = New-WeatherGlyph 0x26A0
            Background = '#FFFFEAF3'
            Foreground = '#B73567'
            Glow = '#E95A96'
        }
    }

    $alert = Get-WeatherAlertInfo -Snapshot $Snapshot
    if (@('TyphoonAlert', 'ForecastTyphoon') -contains $alert.Key) {
        return [pscustomobject]@{
            IconKey = 'Typhoon'
            Icon = $alert.Icon
            Background = '#FFFFE1EA'
            Foreground = '#8A244F'
            Glow = '#D94D83'
        }
    }

    if (@('GaleAlert', 'ForecastGale') -contains $alert.Key) {
        return [pscustomobject]@{
            IconKey = 'Wind'
            Icon = $alert.Icon
            Background = '#FFFFEEF6'
            Foreground = '#8A3857'
            Glow = '#EFB4CA'
        }
    }

    $code = if ($null -ne $Snapshot.WeatherCode) { [int]$Snapshot.WeatherCode } else { -1 }
    $isNight = ($Snapshot.IsDay -eq 0)

    if ($Snapshot.IsThunderstorm -or (@(95, 96, 99) -contains $code)) {
        return [pscustomobject]@{
            IconKey = 'Thunderstorm'
            Icon = New-WeatherGlyph 0x26C8
            Background = '#FFFFE6EF'
            Foreground = '#8A244F'
            Glow = '#E95A96'
        }
    }

    if (@(71, 73, 75, 77, 85, 86) -contains $code) {
        return [pscustomobject]@{
            IconKey = 'Snow'
            Icon = New-WeatherGlyph 0x2744
            Background = '#FFFFF7FB'
            Foreground = '#7A3A53'
            Glow = '#EFB4CA'
        }
    }

    if (@(45, 48) -contains $code) {
        return [pscustomobject]@{
            IconKey = 'Fog'
            Icon = New-WeatherGlyph 0x1F32B
            Background = '#FFFFF0F7'
            Foreground = '#7A3A53'
            Glow = '#EFB4CA'
        }
    }

    if (@(80, 81, 82) -contains $code) {
        return [pscustomobject]@{
            IconKey = 'Showers'
            Icon = if ($isNight) { New-WeatherGlyph 0x1F327 } else { New-WeatherGlyph 0x1F326 }
            Background = '#FFFFEAF3'
            Foreground = '#8A3857'
            Glow = '#E95A96'
        }
    }

    if ($Snapshot.IsRainingNow -or (@(51, 53, 55, 56, 57, 61, 63, 65, 66, 67) -contains $code)) {
        return [pscustomobject]@{
            IconKey = 'Rain'
            Icon = New-WeatherGlyph 0x1F327
            Background = '#FFFFEAF3'
            Foreground = '#8A3857'
            Glow = '#E95A96'
        }
    }

    if ($code -eq 2 -or ($code -lt 0 -and $Snapshot.CloudCoverPercent -ge 25 -and $Snapshot.CloudCoverPercent -lt 70)) {
        return [pscustomobject]@{
            IconKey = if ($isNight) { 'Cloud' } else { 'PartlyCloudy' }
            Icon = if ($isNight) { New-WeatherGlyph 0x2601 } else { New-WeatherGlyph 0x26C5 }
            Background = '#FFFFF0F7'
            Foreground = '#7A3A53'
            Glow = '#EFB4CA'
        }
    }

    if ($code -eq 3 -or $Snapshot.CloudCoverPercent -ge 70) {
        return [pscustomobject]@{
            IconKey = 'Cloud'
            Icon = New-WeatherGlyph 0x2601
            Background = '#FFFFF0F7'
            Foreground = '#7A3A53'
            Glow = '#EFB4CA'
        }
    }

    if ($isNight) {
        return [pscustomobject]@{
            IconKey = 'Night'
            Icon = New-WeatherGlyph 0x1F319
            Background = '#FFFFF0F7'
            Foreground = '#7A3A53'
            Glow = '#DFA4C8'
        }
    }

    return [pscustomobject]@{
        IconKey = 'Clear'
        Icon = New-WeatherGlyph 0x2600
        Background = '#FFFFF3F9'
        Foreground = '#D94D83'
        Glow = '#F5A7C7'
    }
}

function New-WeatherIconElement {
    param(
        [string]$IconKey,
        [string]$Foreground = '#D94D83'
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
        [bool]$IsCurrent
    )

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
    $weatherText = $Record.WeatherText
    if (($dryCurrentThunderstorm -or [string]::IsNullOrWhiteSpace($weatherText)) -and $null -ne $code) {
        $weatherText = Get-WeatherText -Code ([int]$code)
    }
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
        SlotKey = $SlotKey
        IsCurrent = $IsCurrent
        SlotTime = $Record.Time
        WeatherCode = $code
        RawWeatherCode = $rawCode
        WeatherText = $weatherText
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
        IsRainingNow = ($rainAmount -gt 0 -or (Test-RainWeatherCode -Code $code))
        IsThunderstorm = Test-ThunderWeatherCode -Code $code
    }
}
function Get-WeatherSnapshotFromModel {
    param(
        [object]$Model,
        [string]$SlotKey = $script:SelectedForecastSlotKey
    )

    $definition = Get-ForecastSlotDefinition -SlotKey $SlotKey
    $baseTime = if ($null -ne $Model.Current.Time) { $Model.Current.Time } else { Get-Date }

    if ($definition.Kind -eq 'Current' -or -not $Model.SupportsForecastSlots -or @($Model.Hourly).Count -eq 0) {
        $daily = Select-DailyForecastForTime -Daily @($Model.Daily) -TargetTime $baseTime
        return ConvertTo-DisplayWeatherSnapshot -Model $Model -Record $Model.Current -DailyRecord $daily -SlotKey 'Now' -IsCurrent $true
    }

    $target = Get-ForecastTargetTime -Definition $definition -BaseTime $baseTime
    $hourly = Select-NearestHourlyForecast -Hourly @($Model.Hourly) -TargetTime $target
    if ($null -eq $hourly) {
        $daily = Select-DailyForecastForTime -Daily @($Model.Daily) -TargetTime $baseTime
        return ConvertTo-DisplayWeatherSnapshot -Model $Model -Record $Model.Current -DailyRecord $daily -SlotKey 'Now' -IsCurrent $true
    }

    $dailyRecord = Select-DailyForecastForTime -Daily @($Model.Daily) -TargetTime $hourly.Time
    return ConvertTo-DisplayWeatherSnapshot -Model $Model -Record $hourly -DailyRecord $dailyRecord -SlotKey $definition.Key -IsCurrent $false
}

function Format-ForecastModeLabel {
    param([object]$Snapshot)

    if ($null -eq $Snapshot -or $Snapshot.IsCurrent) {
        return Tx 'Now'
    }

    $slotTime = if ($null -ne $Snapshot.SlotTime) { $Snapshot.SlotTime.ToString('MM-dd HH:mm') } else { $Snapshot.SourceTime }
    return '{0} {1} {2}' -f (Tx 'Forecast'), ([char]0x00B7), $slotTime
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
        Time = Get-Date
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

function Get-WeatherModel {
    try {
        return Get-OpenMeteoForecastModel
    } catch {
        return Get-WttrForecastModel
    }
}

if ($TestMode -or $env:LONGHUA_WEATHER_WIDGET_TEST_MODE -eq '1') {
    return
}

Load-Settings
Save-Settings
Reset-RefreshCountdown

$window = New-Object System.Windows.Window
$window.Title = 'Basic Weather Widget'
$window.Width = 386
$window.Height = $script:WindowClosedHeight
$window.WindowStyle = 'None'
$window.ResizeMode = 'NoResize'
$window.AllowsTransparency = $true
$window.Background = 'Transparent'
$window.ShowInTaskbar = $false
$window.Topmost = -not $NoTopMost

$border = New-Object System.Windows.Controls.Border
$border.CornerRadius = 14
$border.Padding = '12'
$border.ClipToBounds = $true
$border.Background = New-XamlObject @'
<LinearGradientBrush xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" StartPoint="0,0" EndPoint="1,1">
    <GradientStop Color="#FFFFF8FC" Offset="0"/>
    <GradientStop Color="#FFFFEEF6" Offset="0.55"/>
    <GradientStop Color="#FFFFFAFD" Offset="1"/>
</LinearGradientBrush>
'@
$border.BorderBrush = '#00FFFFFF'
$border.BorderThickness = 0
$border.Effect = New-GlowEffect -Color '#E7A9C1' -BlurRadius 24 -ShadowDepth 6 -Opacity 0.24

$surfaceGrid = New-Object System.Windows.Controls.Grid
$surfaceGrid.ClipToBounds = $true
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
    <GradientStop Color="#66F5A7C7" Offset="0"/>
    <GradientStop Color="#26F8C1D4" Offset="0.42"/>
    <GradientStop Color="#00FFF8FC" Offset="1"/>
</RadialGradientBrush>
'@
$surfaceGrid.Children.Add($panelGlow) | Out-Null

$panelSheen = New-Object System.Windows.Controls.Border
$panelSheen.IsHitTestVisible = $false
$panelSheen.Opacity = 0.26
$panelSheen.Background = New-XamlObject @'
<LinearGradientBrush xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" StartPoint="0,0" EndPoint="1,1">
    <GradientStop Color="#66FFFFFF" Offset="0"/>
    <GradientStop Color="#18F7B5CC" Offset="0.36"/>
    <GradientStop Color="#00FFF8FC" Offset="1"/>
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
    <GradientStop Color="#88F5A7C7" Offset="0.45"/>
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
    <GradientStop Color="#42F5A7C7" Offset="0.30"/>
    <GradientStop Color="#0014212D" Offset="1"/>
</RadialGradientBrush>
'@
$surfaceGrid.Children.Add($lightningLayer) | Out-Null

$scrollViewer = New-Object System.Windows.Controls.ScrollViewer
$scrollViewer.VerticalScrollBarVisibility = 'Hidden'
$scrollViewer.HorizontalScrollBarVisibility = 'Disabled'
$scrollViewer.CanContentScroll = $true
$scrollViewer.PanningMode = 'VerticalOnly'
$scrollViewer.Background = 'Transparent'
$surfaceGrid.Children.Add($scrollViewer) | Out-Null

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
$border.Add_MouseEnter({
    Expand-WindowDrawer -Window $window
}.GetNewClosure())
$border.Add_MouseLeave({
    $script:DrawerHoverArmed = $true
    Collapse-WindowDrawer -Window $window
}.GetNewClosure())

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
$titleClose = New-Object System.Windows.Controls.ColumnDefinition
$titleClose.Width = [string]$script:TopChromeColumnWidth
$titleRow.ColumnDefinitions.Add($titleLeft)
$titleRow.ColumnDefinitions.Add($titleRight)
$titleRow.ColumnDefinitions.Add($titleCountdown)
$titleRow.ColumnDefinitions.Add($titleSettings)
$titleRow.ColumnDefinitions.Add($titleClose)

$titleBlock = New-TextBlock -Text (Get-WidgetTitle) -FontSize 14.5 -FontWeight 'Bold' -Foreground '#3F2030'
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
    $Border.BorderThickness = 0
    $Border.Effect = $null
}

$statusShell = New-Object System.Windows.Controls.Border
$statusShell.Height = 23
$statusShell.MinWidth = 58
$statusShell.CornerRadius = 12
$statusShell.Padding = '9,1,9,2'
$statusShell.Margin = '0,0,8,0'
$statusShell.HorizontalAlignment = 'Right'
Set-TopChromePlain -Border $statusShell
$statusBlock = New-TextBlock -Text (Tx 'Loading') -FontSize 12 -Foreground '#D94D83'
$statusBlock.HorizontalAlignment = 'Center'
$statusShell.Child = $statusBlock
[System.Windows.Controls.Grid]::SetColumn($statusShell, 1)
$titleRow.Children.Add($statusShell) | Out-Null

$countdownShell = New-Object System.Windows.Controls.Border
$countdownShell.Height = 23
$countdownShell.MinWidth = 86
$countdownShell.CornerRadius = 12
$countdownShell.Padding = '8,1,8,2'
$countdownShell.Margin = '0,0,8,0'
$countdownShell.HorizontalAlignment = 'Right'
Set-TopChromePlain -Border $countdownShell
$countdownBlock = New-TextBlock -Text (Format-CountdownText -Seconds $script:RefreshSeconds) -FontSize 11 -Foreground '#6B354A'
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
$settingsButton.ToolTip = Tx 'Settings'
$settingsButton.SetValue([System.Windows.Input.KeyboardNavigation]::IsTabStopProperty, $true)
$settingsIconGrid = New-Object System.Windows.Controls.Grid
$settingsIconGrid.Width = 18
$settingsIconGrid.Height = 18
$settingsIconGrid.HorizontalAlignment = 'Center'
$settingsIconGrid.VerticalAlignment = 'Center'
$settingsIconGrid.SnapsToDevicePixels = $true
$settingsIconGrid.UseLayoutRounding = $true
$settingsIconHorizontal = New-Object System.Windows.Controls.Border
$settingsIconHorizontal.Width = 15
$settingsIconHorizontal.Height = 3
$settingsIconHorizontal.CornerRadius = 1.5
$settingsIconHorizontal.Background = '#C73A79'
$settingsIconHorizontal.HorizontalAlignment = 'Center'
$settingsIconHorizontal.VerticalAlignment = 'Center'
$settingsIconVertical = New-Object System.Windows.Controls.Border
$settingsIconVertical.Width = 3
$settingsIconVertical.Height = 15
$settingsIconVertical.CornerRadius = 1.5
$settingsIconVertical.Background = '#C73A79'
$settingsIconVertical.HorizontalAlignment = 'Center'
$settingsIconVertical.VerticalAlignment = 'Center'
$settingsIconGrid.Children.Add($settingsIconHorizontal) | Out-Null
$settingsIconGrid.Children.Add($settingsIconVertical) | Out-Null
$settingsButton.Child = $settingsIconGrid
[System.Windows.Controls.Grid]::SetColumn($settingsButton, 3)
$titleRow.Children.Add($settingsButton) | Out-Null

function Set-SettingsIconColor {
    param([string]$Color)

    $settingsIconHorizontal.Background = $Color
    $settingsIconVertical.Background = $Color
}

function Set-SettingsIconExpanded {
    param([bool]$Expanded)

    if ($Expanded) {
        $settingsIconVertical.Visibility = [System.Windows.Visibility]::Collapsed
    } else {
        $settingsIconVertical.Visibility = [System.Windows.Visibility]::Visible
    }
}

$settingsButton.Add_MouseEnter({
    Set-TopChromePlain -Border $settingsButton
    Set-SettingsIconColor -Color '#B73567'
})
$settingsButton.Add_MouseLeave({
    Set-TopChromePlain -Border $settingsButton
    if ($script:SettingsOpen) {
        Set-SettingsIconColor -Color '#B73567'
    } else {
        Set-SettingsIconColor -Color '#C73A79'
    }
})
$settingsButton.Add_GotKeyboardFocus({
    Set-TopChromePlain -Border $settingsButton
    Set-SettingsIconColor -Color '#B73567'
})
$settingsButton.Add_LostKeyboardFocus({
    Set-TopChromePlain -Border $settingsButton
    if (-not $script:SettingsOpen) {
        Set-SettingsIconColor -Color '#C73A79'
    }
})
Enable-MagneticHover -Border $settingsButton -Strength 3

$closeButton = New-Object System.Windows.Controls.Border
$closeButton.Width = $script:TopChromeButtonSize
$closeButton.Height = $script:TopChromeButtonSize
$closeButton.CornerRadius = ($script:TopChromeButtonSize / 2)
Set-TopChromePlain -Border $closeButton
$closeButton.Cursor = [System.Windows.Input.Cursors]::Hand
$closeButton.HorizontalAlignment = 'Right'
$closeButton.Focusable = $true
$closeButton.SetValue([System.Windows.Input.KeyboardNavigation]::IsTabStopProperty, $true)
$closeIconCanvas = New-Object System.Windows.Controls.Canvas
$closeIconCanvas.Width = 18
$closeIconCanvas.Height = 18
$closeIconCanvas.HorizontalAlignment = 'Center'
$closeIconCanvas.VerticalAlignment = 'Center'
$closeIconCanvas.SnapsToDevicePixels = $true
$closeIconCanvas.UseLayoutRounding = $true
$closeLineA = New-Object System.Windows.Shapes.Line
$closeLineA.X1 = 4
$closeLineA.Y1 = 4
$closeLineA.X2 = 14
$closeLineA.Y2 = 14
$closeLineA.Stroke = '#C73A79'
$closeLineA.StrokeThickness = 3
$closeLineA.StrokeStartLineCap = [System.Windows.Media.PenLineCap]::Round
$closeLineA.StrokeEndLineCap = [System.Windows.Media.PenLineCap]::Round
$closeLineB = New-Object System.Windows.Shapes.Line
$closeLineB.X1 = 14
$closeLineB.Y1 = 4
$closeLineB.X2 = 4
$closeLineB.Y2 = 14
$closeLineB.Stroke = '#C73A79'
$closeLineB.StrokeThickness = 3
$closeLineB.StrokeStartLineCap = [System.Windows.Media.PenLineCap]::Round
$closeLineB.StrokeEndLineCap = [System.Windows.Media.PenLineCap]::Round
$closeIconCanvas.Children.Add($closeLineA) | Out-Null
$closeIconCanvas.Children.Add($closeLineB) | Out-Null
$closeButton.Child = $closeIconCanvas
[System.Windows.Controls.Grid]::SetColumn($closeButton, 4)
$titleRow.Children.Add($closeButton) | Out-Null

function Set-CloseIconColor {
    param([string]$Color)

    $closeLineA.Stroke = $Color
    $closeLineB.Stroke = $Color
}

$closeButton.Add_MouseEnter({
    Set-TopChromePlain -Border $closeButton
    Set-CloseIconColor -Color '#B73567'
})
$closeButton.Add_MouseLeave({
    Set-TopChromePlain -Border $closeButton
    Set-CloseIconColor -Color '#C73A79'
})
$closeButton.Add_GotKeyboardFocus({
    Set-TopChromePlain -Border $closeButton
    Set-CloseIconColor -Color '#B73567'
})
$closeButton.Add_LostKeyboardFocus({
    Set-TopChromePlain -Border $closeButton
    Set-CloseIconColor -Color '#C73A79'
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
$locationStrip.Background = '#BFFFFFFF'
$locationStrip.BorderBrush = '#00FFFFFF'
$locationStrip.BorderThickness = 0
$locationStrip.Cursor = [System.Windows.Input.Cursors]::Hand
$locationStrip.Focusable = $true
$locationStrip.SetValue([System.Windows.Input.KeyboardNavigation]::IsTabStopProperty, $true)
$locationLineBlock = New-TextBlock -Text (Get-LocationCardText) -FontSize 11 -Foreground '#7A3A53' -FontWeight 'SemiBold'
$locationLineBlock.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
$locationStrip.Child = $locationLineBlock
$locationStrip.Add_MouseEnter({
    $locationStrip.Background = '#FFFFEAF3'
    $locationStrip.BorderBrush = '#00FFFFFF'
})
$locationStrip.Add_MouseLeave({
    $locationStrip.Background = '#BFFFFFFF'
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
$settingsPanel.Background = '#FBFFF7FB'
$settingsPanel.BorderBrush = '#00FFFFFF'
$settingsPanel.BorderThickness = 0
$settingsPanel.Visibility = [System.Windows.Visibility]::Collapsed
$settingsPanel.Effect = New-GlowEffect -Color '#EFB4CA' -BlurRadius 10 -ShadowDepth 1 -Opacity 0.14
$settingsStack = New-Object System.Windows.Controls.StackPanel
$settingsPanel.Child = $settingsStack
$panel.Children.Add($settingsPanel) | Out-Null

$selectorGrid = New-Object System.Windows.Controls.Grid
$selectorGrid.Margin = '0,0,0,6'
foreach ($width in @('*', '*', '*')) {
    $col = New-Object System.Windows.Controls.ColumnDefinition
    $col.Width = $width
    $selectorGrid.ColumnDefinitions.Add($col)
}

$provinceCombo = New-ComboBox -Width 110
$provinceCombo.HorizontalAlignment = 'Left'
[System.Windows.Controls.Grid]::SetColumn($provinceCombo, 0)
$selectorGrid.Children.Add($provinceCombo) | Out-Null

$cityCombo = New-ComboBox -Width 110 -Margin '4,0,4,0'
$cityCombo.HorizontalAlignment = 'Center'
[System.Windows.Controls.Grid]::SetColumn($cityCombo, 1)
$selectorGrid.Children.Add($cityCombo) | Out-Null

$districtCombo = New-ComboBox -Width 110 -Margin '0,0,0,0'
$districtCombo.HorizontalAlignment = 'Right'
[System.Windows.Controls.Grid]::SetColumn($districtCombo, 2)
$selectorGrid.Children.Add($districtCombo) | Out-Null
$settingsStack.Children.Add($selectorGrid) | Out-Null

$toolRow = New-Object System.Windows.Controls.Grid
$toolRow.Margin = '0,0,0,0'
$toolLeft = New-Object System.Windows.Controls.ColumnDefinition
$toolLeft.Width = '*'
$toolRight = New-Object System.Windows.Controls.ColumnDefinition
$toolRight.Width = 'Auto'
$toolRow.ColumnDefinitions.Add($toolLeft)
$toolRow.ColumnDefinitions.Add($toolRight)

$refreshCombo = New-ComboBox -Width 144 -Margin '0,0,0,0'
$refreshCombo.HorizontalAlignment = 'Left'
$refreshCombo.SelectedValuePath = 'Seconds'
$refreshCombo.ToolTip = Tx 'Refresh'
[System.Windows.Controls.Grid]::SetColumn($refreshCombo, 0)
$toolRow.Children.Add($refreshCombo) | Out-Null

$languagePill = New-Object System.Windows.Controls.Border
$languagePill.Width = 86
$languagePill.Height = 34
$languagePill.HorizontalAlignment = 'Right'
$languagePill.CornerRadius = 17
$languagePill.Background = '#FFFFF7FB'
$languagePill.BorderBrush = '#00FFFFFF'
$languagePill.BorderThickness = 0
$languagePill.Cursor = [System.Windows.Input.Cursors]::Hand
$languagePill.ToolTip = 'CN / EN'
$languagePill.Effect = New-GlowEffect -Color '#EFB4CA' -BlurRadius 10 -ShadowDepth 1 -Opacity 0.12
$languagePill.Add_MouseEnter({
    $languagePill.BorderBrush = '#00FFFFFF'
    $languagePill.Effect = New-GlowEffect -Color '#E95A96' -BlurRadius 14 -ShadowDepth 1 -Opacity 0.18
})
$languagePill.Add_MouseLeave({
    $languagePill.BorderBrush = '#00FFFFFF'
    $languagePill.Effect = New-GlowEffect -Color '#EFB4CA' -BlurRadius 10 -ShadowDepth 1 -Opacity 0.12
})
Enable-MagneticHover -Border $languagePill -Strength 3

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
$zhSegment.BorderThickness = 0
$zhSegment.BorderBrush = '#00000000'
$zhSegment.Focusable = $true
$zhSegment.SetValue([System.Windows.Input.KeyboardNavigation]::IsTabStopProperty, $true)
$zhText = New-TextBlock -Text 'CN' -FontSize 11 -FontWeight 'SemiBold'
$zhText.HorizontalAlignment = 'Center'
$zhSegment.Child = $zhText
[System.Windows.Controls.Grid]::SetColumn($zhSegment, 0)
$pillGrid.Children.Add($zhSegment) | Out-Null

$enSegment = New-Object System.Windows.Controls.Border
$enSegment.CornerRadius = '0,16,16,0'
$enSegment.BorderThickness = 0
$enSegment.BorderBrush = '#00000000'
$enSegment.Focusable = $true
$enSegment.SetValue([System.Windows.Input.KeyboardNavigation]::IsTabStopProperty, $true)
$enText = New-TextBlock -Text 'EN' -FontSize 11 -FontWeight 'SemiBold'
$enText.HorizontalAlignment = 'Center'
$enSegment.Child = $enText
[System.Windows.Controls.Grid]::SetColumn($enSegment, 1)
$pillGrid.Children.Add($enSegment) | Out-Null

$languagePill.Child = $pillGrid
[System.Windows.Controls.Grid]::SetColumn($languagePill, 1)
$toolRow.Children.Add($languagePill) | Out-Null
$settingsStack.Children.Add($toolRow) | Out-Null

$timelineLabel = New-TextBlock -Text (Tx 'ForecastTimeline') -FontSize 11 -Foreground '#9B5F75' -FontWeight 'SemiBold'
$timelineLabel.Margin = '1,8,0,5'
$settingsStack.Children.Add($timelineLabel) | Out-Null

$script:ForecastChips = [ordered]@{}

$forecastControlGrid = New-Object System.Windows.Controls.Grid
$forecastControlGrid.Margin = '0,0,0,2'
foreach ($width in @('*', '*')) {
    $col = New-Object System.Windows.Controls.ColumnDefinition
    $col.Width = $width
    $forecastControlGrid.ColumnDefinitions.Add($col)
}

$forecastDateCombo = New-ComboBox -Width 164 -Margin '0,0,4,0'
$forecastDateCombo.HorizontalAlignment = 'Left'
$forecastDateCombo.ToolTip = Tx 'ForecastTimeline'
[System.Windows.Controls.Grid]::SetColumn($forecastDateCombo, 0)
$forecastControlGrid.Children.Add($forecastDateCombo) | Out-Null

$forecastHourCombo = New-ComboBox -Width 164 -Margin '4,0,0,0'
$forecastHourCombo.HorizontalAlignment = 'Right'
$forecastHourCombo.ToolTip = Tx 'ForecastTimeline'
[System.Windows.Controls.Grid]::SetColumn($forecastHourCombo, 1)
$forecastControlGrid.Children.Add($forecastHourCombo) | Out-Null

$settingsStack.Children.Add($forecastControlGrid) | Out-Null

$conditionCard = New-Object System.Windows.Controls.Border
$conditionCard.CornerRadius = 9
$conditionCard.Padding = '10,7,10,8'
$conditionCard.Background = '#FDFFF7FB'
$conditionCard.BorderBrush = '#00FFFFFF'
$conditionCard.BorderThickness = 0
$conditionCard.Margin = '0,0,0,6'
$conditionCard.Effect = New-GlowEffect -Color '#EFB4CA' -BlurRadius 10 -ShadowDepth 1 -Opacity 0.14
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

$modeBlock = New-TextBlock -Text (Tx 'Now') -FontSize 10.5 -Foreground '#D94D83' -FontWeight 'SemiBold'
$modeBlock.Margin = '0,0,0,2'
$conditionPanel.Children.Add($modeBlock) | Out-Null

$conditionBlock = New-TextBlock -Text (Tx 'Loading') -FontSize 12 -Foreground '#7A3A53'
$conditionBlock.Margin = '0,0,0,3'
$conditionPanel.Children.Add($conditionBlock) | Out-Null

$temperatureBlock = New-TextBlock -Text '-- C' -FontSize 29 -Foreground '#3F2030' -FontWeight 'Bold'
$temperatureBlock.Margin = '0,0,0,1'
$conditionPanel.Children.Add($temperatureBlock) | Out-Null

$feelsBlock = New-TextBlock -Text '--' -FontSize 12 -Foreground '#7A3A53'
$conditionPanel.Children.Add($feelsBlock) | Out-Null

$weatherIconShell = New-Object System.Windows.Controls.Border
$weatherIconShell.Width = 54
$weatherIconShell.Height = 54
$weatherIconShell.CornerRadius = 16
$weatherIconShell.Padding = '3'
$weatherIconShell.HorizontalAlignment = 'Right'
$weatherIconShell.VerticalAlignment = 'Center'
$weatherIconShell.Background = '#FFFFF3F9'
$weatherIconShell.BorderBrush = '#00FFFFFF'
$weatherIconShell.BorderThickness = 0
$weatherIconShell.Effect = New-GlowEffect -Color '#F5A7C7' -BlurRadius 14 -ShadowDepth 1 -Opacity 0.18
$weatherIconShell.Child = New-WeatherIconElement -IconKey 'Clear' -Foreground '#D94D83'
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
$alertStrip.BorderThickness = 0
$alertGrid = New-Object System.Windows.Controls.Grid
$alertIconColumn = New-Object System.Windows.Controls.ColumnDefinition
$alertIconColumn.Width = 'Auto'
$alertTextColumn = New-Object System.Windows.Controls.ColumnDefinition
$alertTextColumn.Width = '*'
$alertGrid.ColumnDefinitions.Add($alertIconColumn)
$alertGrid.ColumnDefinitions.Add($alertTextColumn)
$alertStrip.Child = $alertGrid
$alertIconBlock = New-TextBlock -Text (New-WeatherGlyph 0x2600) -FontSize 12 -Foreground '#9B5F75'
$alertIconBlock.FontFamily = 'Segoe UI Emoji'
$alertIconBlock.Margin = '0,0,5,0'
[System.Windows.Controls.Grid]::SetColumn($alertIconBlock, 0)
$alertGrid.Children.Add($alertIconBlock) | Out-Null
$alertTextBlock = New-TextBlock -Text (Tx 'NoWeatherAlert') -FontSize 10 -Foreground '#9B5F75' -FontWeight 'SemiBold'
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
    $bottom = if ($gridRow -lt 3) { 5 } else { 0 }
    if ($gridColumn -eq 0) {
        $row.Grid.Margin = "0,0,4,$bottom"
    } else {
        $row.Grid.Margin = "4,0,0,$bottom"
    }
    $metricsGrid.Children.Add($row.Grid) | Out-Null
}
$panel.Children.Add($metricsGrid) | Out-Null

$updatedBlock = New-TextBlock -Text '--' -FontSize 9.5 -Foreground '#9B5F75'
$updatedBlock.Margin = '0,6,0,0'
$panel.Children.Add($updatedBlock) | Out-Null

$attributionBlock = New-TextBlock -Text 'Weather data by Open-Meteo.' -FontSize 9 -Foreground '#B7728C'
$attributionBlock.Margin = '0,1,0,0'
$panel.Children.Add($attributionBlock) | Out-Null
$menu = New-Object System.Windows.Controls.ContextMenu
$refreshItem = New-Object System.Windows.Controls.MenuItem
$refreshItem.Header = Tx 'RefreshNow'
$exitItem = New-Object System.Windows.Controls.MenuItem
$exitItem.Header = Tx 'Exit'
$menu.Items.Add($refreshItem) | Out-Null
$menu.Items.Add($exitItem) | Out-Null
$border.ContextMenu = $menu

$window.Content = $border
$exitItem.Add_Click({ $window.Close() })

$script:Client = New-Object LonghuaWeatherTimeoutWebClient
$script:Client.TimeoutMilliseconds = $script:WeatherRequestTimeoutMs
$script:Client.Headers.Add('User-Agent', 'LonghuaWeatherWidget/2.0')

function Update-LanguagePill {
    if ($script:Language -eq 'zh') {
        $zhSegment.Background = '#E95A96'
        $enSegment.Background = '#00FFFFFF'
        $zhText.Foreground = '#FFFFFF'
        $enText.Foreground = '#9B5F75'
    } else {
        $zhSegment.Background = '#00FFFFFF'
        $enSegment.Background = '#E95A96'
        $zhText.Foreground = '#9B5F75'
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
    <GradientStop Color="#1FF8B5CC" Offset="0.42"/>
    <GradientStop Color="#00FFF8FC" Offset="1"/>
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
        Set-WidgetGradient -StartColor '#FFFFF8FC' -MidColor '#FFFFEEF6' -EndColor '#FFFFFAFD' -GlowColor '#66F5A7C7' -GlowOpacity 0.18
        return
    }

    if ($Snapshot.IsThunderstorm) {
        Set-WidgetGradient -StartColor '#FFFFF5FA' -MidColor '#FFFFE3EF' -EndColor '#FFFFFAFD' -GlowColor '#70E95A96' -GlowOpacity 0.22
        $rainLayer.Visibility = [System.Windows.Visibility]::Visible
        $rainLayer.Opacity = 0.20
        $lightningLayer.Visibility = [System.Windows.Visibility]::Visible
        $script:ThunderActive = $true
        return
    }

    if ($Snapshot.IsRainingNow) {
        Set-WidgetGradient -StartColor '#FFFFF6FB' -MidColor '#FFFFE8F2' -EndColor '#FFFFFAFD' -GlowColor '#66F59ABC' -GlowOpacity 0.20
        $rainLayer.Visibility = [System.Windows.Visibility]::Visible
        $rainLayer.Opacity = 0.16
        $panelSheen.Opacity = 0.18
        return
    }

    if ($Snapshot.IsDay -eq 0) {
        Set-WidgetGradient -StartColor '#FFFFF7FC' -MidColor '#FFF8E8F4' -EndColor '#FFFFFAFD' -GlowColor '#55DFA4C8' -GlowOpacity 0.18
        return
    }

    if (@(0, 1) -contains $Snapshot.WeatherCode) {
        Set-WidgetGradient -StartColor '#FFFFF9FC' -MidColor '#FFFFF0F7' -EndColor '#FFFFFCFE' -GlowColor '#66F8B5CC' -GlowOpacity 0.18
        return
    }

    Set-WidgetGradient -StartColor '#FFFFF8FC' -MidColor '#FFFFEEF6' -EndColor '#FFFFFAFD' -GlowColor '#66F5A7C7' -GlowOpacity 0.18
}

function Update-WeatherVisualUi {
    param(
        [object]$Snapshot,
        [switch]$Offline
    )

    if ($null -eq $weatherIconShell -or $null -eq $alertTextBlock) {
        return
    }

    $visual = Get-WeatherVisualInfo -Snapshot $Snapshot
    $weatherIconShell.Child = New-WeatherIconElement -IconKey $visual.IconKey -Foreground $visual.Foreground
    $weatherIconShell.Background = $visual.Background
    $weatherIconShell.Effect = New-GlowEffect -Color $visual.Glow -BlurRadius 14 -ShadowDepth 1 -Opacity 0.18

    if ($Offline) {
        $alert = [pscustomobject]@{
            Key = 'OfflineAlert'
            Icon = New-WeatherGlyph 0x26A0
            Background = '#FFFFEAF3'
            Foreground = '#9A3363'
            Glow = '#E95A96'
            Active = $true
        }
    } else {
        $alert = Get-WeatherAlertInfo -Snapshot $Snapshot
    }

    $alertIconBlock.Text = $alert.Icon
    $alertIconBlock.Foreground = $alert.Foreground
    $alertTextBlock.Text = Tx $alert.Key
    $alertTextBlock.Foreground = $alert.Foreground
    $alertStrip.Background = $alert.Background
    if ($alert.Active) {
        $alertStrip.Effect = New-GlowEffect -Color $alert.Glow -BlurRadius 10 -ShadowDepth 1 -Opacity 0.14
    } else {
        $alertStrip.Effect = $null
    }
}

function Update-WeatherDisplay {
    param([object]$Snapshot)

    Apply-WeatherAmbience -Snapshot $Snapshot
    Update-ForecastChips
    Update-WeatherVisualUi -Snapshot $Snapshot
    $alertInfo = Get-WeatherAlertInfo -Snapshot $Snapshot

    Set-TopChromePlain -Border $statusShell
    if ($Snapshot.IsThunderstorm) {
        $rainText = $Snapshot.WeatherText
        $statusBlock.Foreground = '#9A3363'
    } elseif ($Snapshot.IsRainingNow) {
        $rainText = if ($Snapshot.IsCurrent) { Tx 'RainingNow' } else { Tx 'Rain' }
        $statusBlock.Foreground = '#B73567'
    } elseif ($Snapshot.TodayRainMm -gt 0) {
        $rainText = if ($Snapshot.IsCurrent) { Tx 'RainedToday' } else { Tx 'DayRain' }
        $statusBlock.Foreground = '#B73567'
    } else {
        $rainText = Tx 'NoRain'
        $statusBlock.Foreground = '#D94D83'
    }

    $script:CurrentStatusKey = 'Live'
    $statusBlock.Text = if ($alertInfo.Active -and $Snapshot.IsCurrent) { Tx 'AlertStatus' } else { $rainText }
    $titleBlock.Text = Get-WidgetTitle
    $modeBlock.Text = Format-ForecastModeLabel -Snapshot $Snapshot
    $conditionBlock.Text = if ($alertInfo.Active -and $Snapshot.IsCurrent) { Tx 'ActiveAlert' } else { $Snapshot.WeatherText }
    $temperatureBlock.Text = '{0} C' -f (Format-Number $Snapshot.TemperatureC 1)
    $feelsBlock.Text = '{0} {1} C' -f (Tx 'Feels'), (Format-Number $Snapshot.FeelsLikeC 1)

    $rows['Rain'].Row.Label.Text = if ($Snapshot.IsCurrent) { Tx 'RainNow' } else { Tx 'Rain' }
    $rows['DayRain'].Row.Label.Text = if ($Snapshot.IsCurrent) { Tx 'TodayRain' } else { Tx 'DayRain' }
    $rows['Rain'].Row.Value.Text = '{0} mm' -f (Format-Number $Snapshot.RainNowMm 2)
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

    if ($null -ne $script:LatestWeatherModel) {
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
        Set-SettingsIconColor -Color '#B73567'
    } else {
        $settingsPanel.Visibility = [System.Windows.Visibility]::Collapsed
        Set-TopChromePlain -Border $settingsButton
        Set-SettingsIconExpanded -Expanded $false
        Set-SettingsIconColor -Color '#C73A79'
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
        $refreshCombo.ToolTip = Tx 'Refresh'
        $settingsButton.ToolTip = Tx 'Settings'
        $refreshItem.Header = Tx 'RefreshNow'
        $exitItem.Header = Tx 'Exit'
        $timelineLabel.Text = Tx 'ForecastTimeline'

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

function Update-Weather {
    try {
        $script:CurrentStatusKey = 'Updating'
        $statusBlock.Text = Tx 'Updating'
        $statusBlock.Foreground = '#B73567'
        Set-TopChromePlain -Border $statusShell
        [System.Windows.Forms.Application]::DoEvents()

        $model = Get-WeatherModel
        $script:LatestWeatherModel = $model
        if (-not $model.SupportsForecastSlots -and $script:SelectedForecastSlotKey -ne 'Now') {
            $script:SelectedForecastSlotKey = 'Now'
        }
        $snapshot = Get-WeatherSnapshotFromModel -Model $model -SlotKey $script:SelectedForecastSlotKey
        Update-WeatherDisplay -Snapshot $snapshot
    } catch {
        $refreshError = $_.Exception.Message
        if ($null -ne $script:LatestWeatherModel) {
            try {
                $snapshot = Get-WeatherSnapshotFromModel -Model $script:LatestWeatherModel -SlotKey $script:SelectedForecastSlotKey
                Update-WeatherDisplay -Snapshot $snapshot
                Update-WeatherVisualUi -Snapshot $snapshot -Offline
                $script:CurrentStatusKey = 'Offline'
                $statusBlock.Text = Tx 'Offline'
                $statusBlock.Foreground = '#B73567'
                Set-TopChromePlain -Border $statusShell
                $updatedBlock.Text = '{0} {1}' -f (Tx 'LastTry'), (Get-Date -Format 'HH:mm:ss')
                $updatedBlock.ToolTip = $refreshError
                return
            } catch {
            }
        }

        $script:CurrentStatusKey = 'Offline'
        $statusBlock.Text = Tx 'Offline'
        $statusBlock.Foreground = '#B73567'
        Set-TopChromePlain -Border $statusShell
        $conditionBlock.Text = Tx 'WeatherUnavailable'
        $temperatureBlock.Text = '-- C'
        $feelsBlock.Text = '--'
        $modeBlock.Text = Tx 'Now'
        Update-WeatherVisualUi -Snapshot $null -Offline
        $updatedBlock.Text = '{0} {1}' -f (Tx 'LastTry'), (Get-Date -Format 'HH:mm:ss')
        $updatedBlock.ToolTip = $refreshError
    } finally {
        Reset-RefreshCountdown
    }
}

$provinceCombo.Add_SelectionChanged({
    if ($script:UpdatingControls -or $null -eq $provinceCombo.SelectedItem) {
        return
    }

    $script:SelectedProvinceKey = $provinceCombo.SelectedItem.Key
    Reset-CityForSelectedProvince
    Refresh-ControlText
    Save-Settings
    Update-Weather
})

$cityCombo.Add_SelectionChanged({
    if ($script:UpdatingControls -or $null -eq $cityCombo.SelectedItem) {
        return
    }

    $script:SelectedCityKey = $cityCombo.SelectedItem.Key
    Reset-DistrictForSelectedCity
    Refresh-ControlText
    Save-Settings
    Update-Weather
})

$districtCombo.Add_SelectionChanged({
    if ($script:UpdatingControls -or $null -eq $districtCombo.SelectedItem) {
        return
    }

    $script:SelectedDistrictKey = $districtCombo.SelectedItem.Key
    $titleBlock.Text = Get-WidgetTitle
    Save-Settings
    Update-Weather
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

$zhSegment.Add_GotKeyboardFocus({ $zhSegment.BorderBrush = '#D94D83' })
$zhSegment.Add_LostKeyboardFocus({ $zhSegment.BorderBrush = '#00000000' })
$zhSegment.Add_MouseLeftButtonUp({ Set-WidgetLanguage -Language 'zh' })
$zhSegment.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::Enter -or $eventArgs.Key -eq [System.Windows.Input.Key]::Space) {
        $eventArgs.Handled = $true
        Set-WidgetLanguage -Language 'zh'
    }
})

$enSegment.Add_GotKeyboardFocus({ $enSegment.BorderBrush = '#D94D83' })
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

$window.Add_ContentRendered({
    $timer.Start()
    $countdownTimer.Start()
    $lightningTimer.Start()
    $initialRefreshTimer.Start()
})

[void]$window.ShowDialog()
