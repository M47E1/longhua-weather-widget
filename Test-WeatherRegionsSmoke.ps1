param(
    [int]$Seed = 20260626,
    [int]$TargetCount = 200,
    [int]$RetryCount = 2,
    [int]$RetryDelayMs = 900,
    [int]$MaxConsecutiveTransportFailures = 10,
    [string]$ReportRoot = (Join-Path $PSScriptRoot 'reports\region-smoke-200')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LonghuaWeatherWidget.ps1') -TestMode
$script:Client = New-Object LonghuaWeatherTimeoutWebClient
$script:Client.TimeoutMilliseconds = $script:WeatherRequestTimeoutMs
$script:Client.Headers.Add('User-Agent', 'LonghuaWeatherWidget/2.0')

function New-SmokeReportDirectory {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dir = Join-Path $ReportRoot $stamp
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dir 'failures') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dir 'sanitized-responses') -Force | Out-Null
    'No raw weather responses are saved by this smoke test. Failures contain sanitized exception text only.' | Set-Content -LiteralPath (Join-Path $dir 'sanitized-responses\README.txt') -Encoding UTF8
    return $dir
}

function Set-SmokeLocation {
    param([object]$Region)
    $script:SelectedProvinceKey = [string]$Region.ProvinceKey
    $script:SelectedCityKey = [string]$Region.CityKey
    $script:SelectedDistrictKey = [string]$Region.DistrictKey
    Get-SelectedDistrict | Out-Null
}

function Get-SmokeRegions {
    $regions = New-Object System.Collections.Generic.List[object]
    foreach ($province in @($script:Provinces)) {
        foreach ($city in @($province.Cities)) {
            foreach ($district in @($city.Districts)) {
                $locationKey = New-LocationKey -ProvinceKey $province.Key -CityKey $city.Key -DistrictKey $district.Key
                $precision = [string](Get-LocationCoordinateProperty -Location $district -Name 'CoordinatePrecision' -Default 'District')
                $source = [string](Get-LocationCoordinateProperty -Location $district -Name 'CoordinateSource' -Default 'LocalCatalog')
                $validatedAt = [string](Get-LocationCoordinateProperty -Location $district -Name 'CoordinateValidatedAt' -Default '')
                $isApproximate = [bool](Get-LocationCoordinateProperty -Location $district -Name 'IsApproximateCoordinate' -Default $false)
                $validation = Test-LocationCoordinateValidity -Latitude $district.Lat -Longitude $district.Lon -ProvinceKey $province.Key -CityKey $city.Key -DistrictKey $district.Key -LocationKey $locationKey -CoordinatePrecision $precision -CoordinateSource $source
                $regions.Add([pscustomobject]@{
                    ProvinceKey = [string]$province.Key
                    CityKey = [string]$city.Key
                    DistrictKey = [string]$district.Key
                    LocationKey = [string]$locationKey
                    DisplayNameZh = ('{0} / {1} / {2}' -f (T $province.Zh), (T $city.Zh), (T $district.Zh))
                    DisplayNameEn = ('{0} / {1} / {2}' -f $province.En, $city.En, $district.En)
                    Latitude = $validation.Latitude
                    Longitude = $validation.Longitude
                    Timezone = 'Asia/Shanghai'
                    CoordinateKey = if ($validation.IsValid) { ('{0:N6},{1:N6}' -f [double]$validation.Latitude, [double]$validation.Longitude) } else { '' }
                    CoordinatePrecision = $precision
                    CoordinateSource = $source
                    CoordinateValidatedAt = $validatedAt
                    IsApproximateCoordinate = $isApproximate
                    CoordinateValidationStatus = if ($validation.IsValid) { 'PASS' } else { 'FAIL' }
                    CoordinateFailureReason = [string]$validation.FailureReason
                }) | Out-Null
            }
        }
    }

    $byLocation = @{}
    $byCoordinate = @{}
    $deduped = New-Object System.Collections.Generic.List[object]
    foreach ($region in @($regions | Sort-Object ProvinceKey, CityKey, DistrictKey)) {
        if ($byLocation.ContainsKey($region.LocationKey)) { continue }
        if ($region.CoordinateValidationStatus -eq 'PASS' -and $byCoordinate.ContainsKey($region.CoordinateKey)) { continue }
        $byLocation[$region.LocationKey] = $true
        if ($region.CoordinateValidationStatus -eq 'PASS') { $byCoordinate[$region.CoordinateKey] = $true }
        $deduped.Add($region) | Out-Null
    }
    if ($deduped.Count -le $TargetCount) { return @($deduped | ForEach-Object { $_ }) }
    $rng = [Random]::new($Seed)
    return @($deduped | Sort-Object @{ Expression = { $rng.NextDouble() } } | Select-Object -First $TargetCount)
}
function Test-SmokeText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return 'empty text' }
    if ($Text -match '(?<![A-Za-z0-9_])(null|undefined|NaN|Infinity)(?![A-Za-z0-9_])|System\.Object\[\]|\{[A-Za-z0-9_]+\}|Exception|At .+ char:|Cannot bind|You cannot call') { return "bad text token: $Text" }
    return $null
}

function Add-SmokeAssertion {
    param([System.Collections.Generic.List[object]]$Assertions, [string]$Name, [bool]$Pass, [string]$Detail = '')
    $Assertions.Add([pscustomobject]@{ Name = $Name; Pass = [bool]$Pass; Detail = $Detail }) | Out-Null
}

function Test-SmokeSnapshot {
    param([object]$Region, [object]$Model, [object]$Resolved, [object]$Snapshot, [object]$PreviousSnapshot, [bool]$RunEnglish)
    $assertions = New-Object System.Collections.Generic.List[object]
    $now = Get-Date
    $script:Language = 'zh'
    $currentTextZh = Get-WeatherConditionDisplayText -Snapshot $Snapshot
    $nearTextZh = [string]$Snapshot.NearTermForecast
    $warningTextZh = Get-WeatherWarningDisplayText -Snapshot $Snapshot
    $statusTextZh = Get-WeatherStatusDisplayText -Snapshot $Snapshot
    $locationTitleZh = Get-LocationLineText
    $currentTextEn = ''; $nearTextEn = ''; $warningTextEn = ''; $statusTextEn = ''; $locationTitleEn = ''
    if ($RunEnglish) {
        $script:Language = 'en'
        $currentTextEn = Get-WeatherConditionDisplayText -Snapshot $Snapshot
        $nearTextEn = [string]$Snapshot.NearTermForecast
        $warningTextEn = Get-WeatherWarningDisplayText -Snapshot $Snapshot
        $statusTextEn = Get-WeatherStatusDisplayText -Snapshot $Snapshot
        $locationTitleEn = Get-LocationLineText
    }
    $script:Language = 'zh'

    Add-SmokeAssertion $assertions 'CoordinateCatalogValidation' ([string]$Region.CoordinateValidationStatus -eq 'PASS') ([string]$Region.CoordinateFailureReason)
    Add-SmokeAssertion $assertions 'CoordinateNotZeroZero' (-not ([double]$Region.Latitude -eq 0 -and [double]$Region.Longitude -eq 0)) ("lat={0};lon={1}" -f $Region.Latitude,$Region.Longitude)
    Add-SmokeAssertion $assertions 'CoordinateSourcePresent' (-not [string]::IsNullOrWhiteSpace([string]$Region.CoordinateSource)) ([string]$Region.CoordinateSource)
    Add-SmokeAssertion $assertions 'LocationKeyMatches' ([string]$Resolved.LocationKey -eq [string]$Region.LocationKey) ([string]$Resolved.LocationKey)
    Add-SmokeAssertion $assertions 'SnapshotLocationKeyMatches' ([string]$Snapshot.LocationKey -eq [string]$Region.LocationKey) ([string]$Snapshot.LocationKey)
    Add-SmokeAssertion $assertions 'LocationTitleMatches' ($locationTitleZh -match [regex]::Escape((T (Get-SelectedDistrict).Zh))) $locationTitleZh
    Add-SmokeAssertion $assertions 'CurrentDataKindAllowed' (@('Observation','CurrentModel','Unavailable') -contains [string]$Snapshot.CurrentDataKind) ([string]$Snapshot.CurrentDataKind)
    Add-SmokeAssertion $assertions 'CurrentDataTimePresent' ($null -ne $Snapshot.CurrentDataTime) ([string]$Snapshot.CurrentDataTime)
    if ($null -ne $Snapshot.CurrentDataTime) { Add-SmokeAssertion $assertions 'CurrentDataTimeNotFuture' (([datetime]$Snapshot.CurrentDataTime) -le $now.AddMinutes(10)) ([string]$Snapshot.CurrentDataTime) }
    if ([string]$Model.Source -eq 'Open-Meteo') { Add-SmokeAssertion $assertions 'OpenMeteoCurrentIntervalSaved' ($null -ne $Model.Current.IntervalSeconds -and $null -ne $Snapshot.CurrentIntervalSeconds -and [int]$Model.Current.IntervalSeconds -eq [int]$Snapshot.CurrentIntervalSeconds) ("model={0};snapshot={1}" -f $Model.Current.IntervalSeconds,$Snapshot.CurrentIntervalSeconds) }

    foreach ($pair in @(@('CurrentZh',$currentTextZh),@('NearTermZh',$nearTextZh),@('WarningZh',$warningTextZh),@('StatusZh',$statusTextZh))) {
        $bad = Test-SmokeText -Text ([string]$pair[1])
        Add-SmokeAssertion $assertions ("TextClean_{0}" -f $pair[0]) ($null -eq $bad) ([string]$bad)
    }
    if ($RunEnglish) {
        foreach ($pair in @(@('CurrentEn',$currentTextEn),@('NearTermEn',$nearTextEn),@('WarningEn',$warningTextEn),@('StatusEn',$statusTextEn),@('LocationEn',$locationTitleEn))) {
            $bad = Test-SmokeText -Text ([string]$pair[1])
            Add-SmokeAssertion $assertions ("TextClean_{0}" -f $pair[0]) ($null -eq $bad) ([string]$bad)
        }
    }

    Add-SmokeAssertion $assertions 'Wmo65NotRainstorm' ((Get-WeatherText -Code 65) -notmatch '暴雨') (Get-WeatherText -Code 65)
    Add-SmokeAssertion $assertions 'NoCurrentRainstormWhenDryFutureStrongRain' (-not (($Snapshot.CurrentRainAmount -le 0) -and $nearTextZh -match '强降雨|大雨|暴雨' -and $currentTextZh -match '正在暴雨')) ("current=$currentTextZh;near=$nearTextZh")
    Add-SmokeAssertion $assertions 'ModelTipNotOfficialWarning' (-not ([string]$Snapshot.WarningText -eq '' -and $warningTextZh -match '预警')) $warningTextZh
    Add-SmokeAssertion $assertions 'NoStaleWarningText' (-not ($null -ne $PreviousSnapshot -and [string]$PreviousSnapshot.LocationKey -ne [string]$Snapshot.LocationKey -and -not [string]::IsNullOrWhiteSpace([string]$PreviousSnapshot.WarningText) -and [string]$PreviousSnapshot.WarningText -eq [string]$Snapshot.WarningText)) ([string]$Snapshot.WarningText)
    Add-SmokeAssertion $assertions 'ContradictoryCurrentConservative' (-not ((Test-StrongRainWeatherCode -Code $Snapshot.CurrentWeatherCode) -and [double]$Snapshot.CurrentRainAmount -le 0 -and $currentTextZh -match '正在暴雨')) $currentTextZh
    $precip = if ($null -ne $Snapshot.CurrentPrecipitation) { [double]$Snapshot.CurrentPrecipitation } else { 0.0 }
    $rain = if ($null -ne $Snapshot.CurrentRain) { [double]$Snapshot.CurrentRain } else { 0.0 }
    Add-SmokeAssertion $assertions 'PrecipitationNonNegative' ($precip -ge 0 -and $rain -ge 0) ("precip=$precip;rain=$rain")
    Add-SmokeAssertion $assertions 'HumidityRange' ($null -eq $Snapshot.HumidityPercent -or ([double]$Snapshot.HumidityPercent -ge 0 -and [double]$Snapshot.HumidityPercent -le 100)) ([string]$Snapshot.HumidityPercent)
    Add-SmokeAssertion $assertions 'WindNonNegative' ($null -eq $Snapshot.WindKmh -or [double]$Snapshot.WindKmh -ge 0) ([string]$Snapshot.WindKmh)
    Add-SmokeAssertion $assertions 'PressurePositiveOrMissing' ($null -eq $Snapshot.PressureHpa -or [double]$Snapshot.PressureHpa -gt 0) ([string]$Snapshot.PressureHpa)
    if ($null -ne $Snapshot.NearTermForecastTime) { Add-SmokeAssertion $assertions 'NearTermStrictlyFuture' ([datetime]$Snapshot.NearTermForecastTime -gt $now) ([string]$Snapshot.NearTermForecastTime) }
    $hourlyTimes = @($Model.Hourly | Where-Object { $null -ne $_.Time } | ForEach-Object { [datetime]$_.Time })
    $hourlyOrdered = $true
    for ($i=1; $i -lt $hourlyTimes.Count; $i++) { if ($hourlyTimes[$i] -lt $hourlyTimes[$i-1]) { $hourlyOrdered = $false; break } }
    Add-SmokeAssertion $assertions 'HourlyTimesIncreasing' $hourlyOrdered ("count={0}" -f $hourlyTimes.Count)

    $failures = @($assertions | Where-Object { -not $_.Pass })
    [pscustomobject]@{ Assertions=@($assertions | ForEach-Object { $_ }); Failures=@($failures | ForEach-Object { $_ }); CurrentTextZh=$currentTextZh; NearTermTextZh=$nearTextZh; WarningTextZh=$warningTextZh; StatusTextZh=$statusTextZh; CurrentTextEn=$currentTextEn; NearTermTextEn=$nearTextEn; WarningTextEn=$warningTextEn; StatusTextEn=$statusTextEn }
}

function Get-SmokeFailureClass {
    param([string]$Message)
    if ($Message -match 'LOCATION_DATA_FAIL') { return 'LOCATION_DATA_FAIL' }
    if ($Message -match 'ConvertFrom-Json|JSON|parse|Cannot convert') { return 'PARSE_FAIL' }
    return 'TRANSPORT_FAIL'
}

function Invoke-SmokeRegion {
    param([object]$Region, [object]$PreviousSnapshot, [bool]$RunEnglish)
    Set-SmokeLocation -Region $Region
    Clear-ActiveWeatherModelForLocationChange
    $started = Get-Date
    try {
        $requestLocation = Get-SelectedWeatherLocation
        $requestCoordinateCheck = Test-LocationCoordinateValidity -Latitude $Region.Latitude -Longitude $Region.Longitude -ProvinceKey $Region.ProvinceKey -CityKey $Region.CityKey -DistrictKey $Region.DistrictKey -LocationKey $Region.LocationKey -RequestLatitude $requestLocation.Lat -RequestLongitude $requestLocation.Lon -CoordinatePrecision $Region.CoordinatePrecision -CoordinateSource $Region.CoordinateSource
        if (-not $requestCoordinateCheck.IsValid) {
            return [pscustomobject]@{ Region=$Region; Attempts=0; RequestStatus='LocationDataFail'; Category='LOCATION_DATA_FAIL'; Model=$null; Snapshot=$null; Check=$null; Error=$requestCoordinateCheck.FailureReason; ElapsedMs=[Math]::Round(((Get-Date)-$started).TotalMilliseconds,0) }
        }
    } catch {
        return [pscustomobject]@{ Region=$Region; Attempts=0; RequestStatus='LocationDataFail'; Category='LOCATION_DATA_FAIL'; Model=$null; Snapshot=$null; Check=$null; Error=$_.Exception.Message; ElapsedMs=[Math]::Round(((Get-Date)-$started).TotalMilliseconds,0) }
    }
    try { Get-SelectedWeatherLocation | Out-Null } catch { return [pscustomobject]@{ Region=$Region; Attempts=0; RequestStatus='CoordinateInvalid'; Category='LOCATION_DATA_FAIL'; Model=$null; Snapshot=$null; Check=$null; Error=$_.Exception.Message; ElapsedMs=[Math]::Round(((Get-Date)-$started).TotalMilliseconds,0) } }
    $attempt = 0
    $lastError = $null
    while ($attempt -le $RetryCount) {
        $attempt++
        $request = Start-WeatherRequestContext
        try {
            $model = Get-WeatherModel
            $resolved = Resolve-WeatherRequestSuccess -Request $request -Model $model
            if (-not $resolved.ShouldApply -or $null -eq $resolved.Model) {
                return [pscustomobject]@{ Region=$Region; Attempts=$attempt; RequestStatus=$resolved.Status; Category='SEMANTIC_FAIL'; Model=$null; Snapshot=$null; Check=$null; Error="request resolution failed: $($resolved.Status)"; ElapsedMs=[Math]::Round(((Get-Date)-$started).TotalMilliseconds,0) }
            }
            $snapshot = Get-WeatherSnapshotFromModel -Model $resolved.Model -SlotKey 'Now'
            $check = Test-SmokeSnapshot -Region $Region -Model $resolved.Model -Resolved $resolved -Snapshot $snapshot -PreviousSnapshot $PreviousSnapshot -RunEnglish $RunEnglish
            $category = if (@($check.Failures).Count -eq 0) { if ($attempt -eq 1) { 'PASS' } else { 'RETRY_PASS' } } else { 'SEMANTIC_FAIL' }
            return [pscustomobject]@{ Region=$Region; Attempts=$attempt; RequestStatus=$resolved.Status; Category=$category; Model=$resolved.Model; Snapshot=$snapshot; Check=$check; Error=''; ElapsedMs=[Math]::Round(((Get-Date)-$started).TotalMilliseconds,0) }
        } catch {
            $lastError = $_
            try { Resolve-WeatherRequestFailure -Request $request -ErrorMessage $_.Exception.Message | Out-Null } catch {}
            if ($attempt -le $RetryCount) { Start-Sleep -Milliseconds ($RetryDelayMs * $attempt) }
        }
    }
    [pscustomobject]@{ Region=$Region; Attempts=$attempt; RequestStatus='Exception'; Category=(Get-SmokeFailureClass -Message $lastError.Exception.Message); Model=$null; Snapshot=$null; Check=$null; Error=$lastError.Exception.Message; ElapsedMs=[Math]::Round(((Get-Date)-$started).TotalMilliseconds,0) }
}

function Convert-SmokeRecord {
    param([object]$Result)
    $snapshot=$Result.Snapshot; $model=$Result.Model; $check=$Result.Check
    [pscustomobject]@{
        ProvinceKey=$Result.Region.ProvinceKey
        CityKey=$Result.Region.CityKey
        DistrictKey=$Result.Region.DistrictKey
        LocationKey=$Result.Region.LocationKey
        DisplayNameZh=$Result.Region.DisplayNameZh
        DisplayNameEn=$Result.Region.DisplayNameEn
        Latitude=$Result.Region.Latitude
        Longitude=$Result.Region.Longitude
        CoordinatePrecision=$Result.Region.CoordinatePrecision
        CoordinateSource=$Result.Region.CoordinateSource
        CoordinateValidatedAt=$Result.Region.CoordinateValidatedAt
        IsApproximateCoordinate=$Result.Region.IsApproximateCoordinate
        CoordinateValidationStatus=$Result.Region.CoordinateValidationStatus
        CoordinateFailureReason=$Result.Region.CoordinateFailureReason
        Timezone=$(if($null -ne $model){[string]$model.Timezone}else{$Result.Region.Timezone})
        Attempts=$Result.Attempts
        DataSource=$(if($null -ne $model){[string]$model.Source}else{''})
        RequestStatus=$Result.RequestStatus
        CurrentDataTime=$(if($null -ne $snapshot){[string]$snapshot.CurrentDataTime}else{''})
        CurrentIntervalSeconds=$(if($null -ne $snapshot){[string]$snapshot.CurrentIntervalSeconds}else{''})
        CurrentWeatherCode=$(if($null -ne $snapshot){[string]$snapshot.CurrentWeatherCode}else{''})
        CurrentPrecipitation=$(if($null -ne $snapshot){[string]$snapshot.CurrentPrecipitation}else{''})
        CurrentRain=$(if($null -ne $snapshot){[string]$snapshot.CurrentRain}else{''})
        CurrentDisplayText=$(if($null -ne $check){[string]$check.CurrentTextZh}else{''})
        NearTermForecast=$(if($null -ne $check){[string]$check.NearTermTextZh}else{''})
        WarningText=$(if($null -ne $snapshot){[string]$snapshot.WarningText}else{''})
        WarningDisplayText=$(if($null -ne $check){[string]$check.WarningTextZh}else{''})
        ZhFormatting=$(if($null -ne $check){'PASS'}else{''})
        EnFormatting=$(if($null -ne $check -and -not [string]::IsNullOrWhiteSpace($check.CurrentTextEn)){'PASS'}elseif($null -ne $check){'NOT_RUN'}else{''})
        AssertionResults=$(if($null -ne $check){$check.Assertions|ConvertTo-Json -Depth 5 -Compress}else{''})
        FailureDetails=$(if($null -ne $check){(($check.Failures|ForEach-Object{"$($_.Name):$($_.Detail)"}) -join '; ')}else{$Result.Error})
        Category=$Result.Category
        ElapsedMs=$Result.ElapsedMs
    }
}

function Invoke-StaleRequestSmoke {
    param([object[]]$SuccessfulResults)
    $usable=@($SuccessfulResults|Where-Object{$null -ne $_.Model -and $_.Category -in @('PASS','RETRY_PASS')})
    $groups=New-Object System.Collections.Generic.List[object]
    if($usable.Count -lt 3){return [pscustomobject]@{Total=0;Failures=0;Records=@()}}
    for($i=0;$i -lt [Math]::Min(20,$usable.Count-2);$i++){
        $a=$usable[$i];$b=$usable[($i+1)%$usable.Count];$c=$usable[($i+2)%$usable.Count]
        Set-SmokeLocation -Region $a.Region; Clear-ActiveWeatherModelForLocationChange
        Set-SmokeLocation -Region $b.Region; $requestB=Start-WeatherRequestContext
        Set-SmokeLocation -Region $c.Region; Clear-ActiveWeatherModelForLocationChange; $requestC=Start-WeatherRequestContext
        $resultC=Resolve-WeatherRequestSuccess -Request $requestC -Model $c.Model
        $resultB=Resolve-WeatherRequestSuccess -Request $requestB -Model $b.Model
        $finalSnapshot=if($null -ne $script:LatestWeatherModel){Get-WeatherSnapshotFromModel -Model $script:LatestWeatherModel -SlotKey 'Now'}else{$null}
        $pass=($resultC.ShouldApply -and -not $resultB.ShouldApply -and [string]$resultB.Status -eq 'StaleRequest' -and [string]$script:LatestWeatherLocationKey -eq [string]$c.Region.LocationKey -and $null -ne $finalSnapshot -and [string]$finalSnapshot.LocationKey -eq [string]$c.Region.LocationKey)
        $groups.Add([pscustomobject]@{A=$a.Region.LocationKey;B=$b.Region.LocationKey;C=$c.Region.LocationKey;BStatus=[string]$resultB.Status;FinalLocationKey=[string]$script:LatestWeatherLocationKey;Pass=[bool]$pass})|Out-Null
    }
    [pscustomobject]@{Total=$groups.Count;Failures=@($groups|Where-Object{-not $_.Pass}).Count;Records=@($groups | ForEach-Object { $_ })}
}

$reportDir=New-SmokeReportDirectory
$regions=@(Get-SmokeRegions)
$regions|Export-Csv -LiteralPath (Join-Path $reportDir 'selected-regions.csv') -NoTypeInformation -Encoding UTF8
$results=New-Object System.Collections.Generic.List[object]
$modelsForStale=New-Object System.Collections.Generic.List[object]
$previousSnapshot=$null
$consecutiveTransportFailures=0
$startedAll=Get-Date
$englishBudget=[Math]::Min(40,$regions.Count)
$index=0
foreach($region in $regions){
    $result=Invoke-SmokeRegion -Region $region -PreviousSnapshot $previousSnapshot -RunEnglish ($index -lt $englishBudget)
    $results.Add($result)|Out-Null
    if($null -ne $result.Snapshot){$previousSnapshot=$result.Snapshot}
    if($result.Category -in @('PASS','RETRY_PASS')){$modelsForStale.Add($result)|Out-Null}
    if($result.Category -eq 'TRANSPORT_FAIL'){$consecutiveTransportFailures++}else{$consecutiveTransportFailures=0}
    if($result.Category -notin @('PASS','RETRY_PASS')){ $safe=($region.LocationKey -replace '[\\/:*?"<>|]','_'); Convert-SmokeRecord -Result $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $reportDir "failures\$safe.json") -Encoding UTF8 }
    if($consecutiveTransportFailures -ge $MaxConsecutiveTransportFailures){break}
    $index++
}
$staleSmoke=Invoke-StaleRequestSmoke -SuccessfulResults @($modelsForStale | ForEach-Object { $_ })
$records=@($results|ForEach-Object{Convert-SmokeRecord -Result $_})
$records|Export-Csv -LiteralPath (Join-Path $reportDir 'weather-smoke-200.csv') -NoTypeInformation -Encoding UTF8
$records|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $reportDir 'weather-smoke-200.json') -Encoding UTF8
$staleSmoke.Records|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $reportDir 'stale-request-smoke.json') -Encoding UTF8
$counts=@{}
foreach($category in @('PASS','RETRY_PASS','EXPECTED_NO_DATA','TRANSPORT_FAIL','LOCATION_DATA_FAIL','PARSE_FAIL','SEMANTIC_FAIL','STALE_OVERWRITE_FAIL','UNHANDLED_EXCEPTION')){$counts[$category]=@($results|Where-Object{$_.Category -eq $category}).Count}
if($staleSmoke.Failures -gt 0){$counts['STALE_OVERWRITE_FAIL']=[int]$counts['STALE_OVERWRITE_FAIL']+[int]$staleSmoke.Failures}
$hardFail=[int]$counts['LOCATION_DATA_FAIL']+[int]$counts['SEMANTIC_FAIL']+[int]$counts['STALE_OVERWRITE_FAIL']+[int]$counts['PARSE_FAIL']+[int]$counts['UNHANDLED_EXCEPTION']
$allSupportedRegionsSmoke=if($hardFail -eq 0 -and $results.Count -eq $regions.Count){'PASS'}else{'FAIL'}
$target200Coverage=if($regions.Count -ge $TargetCount){'PASS'}else{'PARTIAL'}
$gate2=if($hardFail -gt 0){'FAIL'}elseif($target200Coverage -eq 'PARTIAL' -or [int]$counts['TRANSPORT_FAIL'] -gt 0 -or [int]$counts['EXPECTED_NO_DATA'] -gt 0){'PARTIAL'}else{'PASS'}
$elapsedAll=[Math]::Round(((Get-Date)-$startedAll).TotalSeconds,2)
$avgMs=if($results.Count -gt 0){[Math]::Round((@($results|ForEach-Object{[double]$_.ElapsedMs})|Measure-Object -Average).Average,0)}else{0}
$rainstormFalsePositive=@($records|Where-Object{$_.CurrentPrecipitation -in @('0','0.0') -and $_.CurrentDisplayText -match '正在暴雨'}).Count
$locationBleed=@($records|Where-Object{$_.FailureDetails -match 'LocationKey|NoStale'}).Count
$uniqueLocationKeyCount=@($regions.LocationKey|Select-Object -Unique).Count
$summary=[pscustomobject]@{ReportDir=$reportDir;TargetCount=$TargetCount;ActualRegionCount=$regions.Count;UniqueLocationKeyCount=$uniqueLocationKeyCount;TestedCount=$results.Count;Counts=$counts;AllSupportedRegionsSmoke=$allSupportedRegionsSmoke;Target200Coverage=$target200Coverage;Gate2=$gate2;TotalSeconds=$elapsedAll;AverageMs=$avgMs;RainstormFalsePositiveCount=$rainstormFalsePositive;LocationBleedCount=$locationBleed;StaleOverwriteCount=$counts['STALE_OVERWRITE_FAIL'];StaleSmokeTotal=$staleSmoke.Total;StaleSmokeFailures=$staleSmoke.Failures;ChineseFormatting=$(if(@($records|Where-Object{$_.ZhFormatting -ne 'PASS'}).Count -eq 0){'PASS'}else{'FAIL'});EnglishFormatting=$(if(@($records|Where-Object{$_.EnFormatting -eq 'PASS'}).Count -ge [Math]::Min(40,$regions.Count)){'PASS'}else{'PARTIAL'});Failures=@($records|Where-Object{$_.Category -notin @('PASS','RETRY_PASS')}|Select-Object LocationKey,Category,FailureDetails)}
$summary|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $reportDir 'summary.json') -Encoding UTF8
$md=New-Object System.Collections.Generic.List[string]
$md.Add('# Weather Region Smoke')|Out-Null;$md.Add('')|Out-Null;$md.Add("- ReportDir: $reportDir")|Out-Null;$md.Add("- Target regions: $TargetCount")|Out-Null;$md.Add("- Actual unique regions: $($regions.Count)")|Out-Null;$md.Add("- Tested regions: $($results.Count)")|Out-Null;$md.Add("- AllSupportedRegionsSmoke: $allSupportedRegionsSmoke")|Out-Null;$md.Add("- Target200Coverage: $target200Coverage")|Out-Null;$md.Add("- Gate 2: $gate2")|Out-Null;$md.Add("- Total seconds: $elapsedAll")|Out-Null;$md.Add("- Average ms: $avgMs")|Out-Null;$md.Add("- Stale request smoke: $($staleSmoke.Total) groups, $($staleSmoke.Failures) failures")|Out-Null;$md.Add('')|Out-Null;$md.Add('## Counts')|Out-Null
foreach($category in $counts.Keys|Sort-Object){$md.Add("- ${category}: $($counts[$category])")|Out-Null}
$md.Add('')|Out-Null;$md.Add('## Failures')|Out-Null
$failRecords=@($summary.Failures)
if($failRecords.Count -eq 0){$md.Add('- None')|Out-Null}else{foreach($failure in $failRecords){$md.Add("- $($failure.LocationKey): $($failure.Category) - $($failure.FailureDetails)")|Out-Null}}
$md|Set-Content -LiteralPath (Join-Path $reportDir 'weather-smoke-200.md') -Encoding UTF8
$summary|Format-List
if($gate2 -eq 'FAIL'){exit 2}
exit 0
