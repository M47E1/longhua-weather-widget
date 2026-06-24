$repoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$scriptPath = Join-Path $repoRoot 'LonghuaWeatherWidget.ps1'
$scriptText = Get-Content -LiteralPath $scriptPath -Raw

function Get-WeatherFieldBlock {
    param([string]$VariableName)

    $match = [regex]::Match(
        $scriptText,
        "\`$script:$VariableName\s*=\s*@\((?<body>.*?)\)\s*-join",
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    if (-not $match.Success) {
        throw "Could not find field block: $VariableName"
    }
    return $match.Groups['body'].Value
}

Describe 'Open-Meteo field contracts' {
    It 'requests the required current fields' {
        $currentFieldsBlock = Get-WeatherFieldBlock -VariableName 'CurrentFields'
        foreach ($field in @(
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
        )) {
            $currentFieldsBlock | Should Match ([regex]::Escape("'$field'"))
        }
    }

    It 'requests the required hourly fields' {
        $hourlyFieldsBlock = Get-WeatherFieldBlock -VariableName 'HourlyFields'
        foreach ($field in @(
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
        )) {
            $hourlyFieldsBlock | Should Match ([regex]::Escape("'$field'"))
        }
    }

    It 'requests the required daily fields' {
        $dailyFieldsBlock = Get-WeatherFieldBlock -VariableName 'DailyFields'
        foreach ($field in @(
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
        )) {
            $dailyFieldsBlock | Should Match ([regex]::Escape("'$field'"))
        }
    }

    It 'uses the required Open-Meteo forecast window and units' {
        $scriptText | Should Match 'timezone=auto'
        $scriptText | Should Match 'ForecastDayCount = 14'
        $scriptText | Should Match 'ForecastHourCount = 336'
        $scriptText | Should Match 'temperature_unit=celsius'
        $scriptText | Should Match 'wind_speed_unit=kmh'
        $scriptText | Should Match 'precipitation_unit=mm'
    }
}
Describe 'Release packaging contracts' {
    $buildPath = Join-Path $repoRoot 'build-release.ps1'
    $buildText = if (Test-Path -LiteralPath $buildPath) { Get-Content -LiteralPath $buildPath -Raw } else { '' }

    It 'stores runtime settings under LocalAppData' {
        $scriptText | Should Match 'LocalApplicationData'
        $expectedSettingsExpression = "Join-Path (Join-Path `$localAppData 'LonghuaWeatherWidget') 'settings.json'"
        $legacySettingsExpression = "Join-Path `$PSScriptRoot 'LonghuaWeatherWidget.settings.json'"
        $scriptText | Should Match ([regex]::Escape($expectedSettingsExpression))
        $scriptText | Should Not Match ([regex]::Escape($legacySettingsExpression))
    }

    It 'declares STA and Open-Meteo attribution in the runtime script' {
        $scriptText | Should Match 'GetApartmentState\(\)'
        $scriptText | Should Match '\[Threading\.ApartmentState\]::STA'
        $scriptText | Should Match 'Weather data by Open-Meteo\.'
    }

    It 'builds the required PS2EXE release shape' {
        $buildText | Should Match 'Invoke-PS2EXE'
        $buildText | Should Match 'NoConsole\s*=\s*\$true'
        $buildText | Should Match 'STA\s*=\s*\$true'
        $buildText | Should Match 'DPIAware\s*=\s*\$true'
        $buildText | Should Match 'SupportOS\s*=\s*\$true'
        $buildText | Should Match 'X64\s*=\s*\$true'
        $buildText | Should Match 'LonghuaWeatherWidget-v\$Version-win-x64\.exe'
        $buildText | Should Match 'LonghuaWeatherWidget-v\$Version-win-x64\.zip'
        $buildText | Should Match 'SHA256SUMS\.txt'
        $buildText | Should Not Match 'RequireAdmin\s*=\s*\$true'
    }
}
