param(
    [string]$ReportDir = (Join-Path $PSScriptRoot 'reports')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LonghuaWeatherWidget.ps1') -TestMode

if (-not (Test-Path -LiteralPath $ReportDir)) {
    New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
}

function New-LocationCatalogAuditRecord {
    param([object]$Province, [object]$City, [object]$District)

    $locationKey = New-LocationKey -ProvinceKey $Province.Key -CityKey $City.Key -DistrictKey $District.Key
    $script:SelectedProvinceKey = [string]$Province.Key
    $script:SelectedCityKey = [string]$City.Key
    $script:SelectedDistrictKey = [string]$District.Key
    $location = $null
    $validationResult = 'PASS'
    $failureReason = ''
    $isZeroZero = $false
    $isSwapped = $false
    try {
        $location = Get-SelectedWeatherLocation
        $validation = Test-LocationCoordinateValidity -Latitude $location.Lat -Longitude $location.Lon -ProvinceKey $Province.Key -CityKey $City.Key -DistrictKey $District.Key -LocationKey $locationKey -CoordinatePrecision $location.CoordinatePrecision -CoordinateSource $location.CoordinateSource -RequestLatitude $location.Lat -RequestLongitude $location.Lon
        $validationResult = if ($validation.IsValid) { 'PASS' } else { 'FAIL' }
        $failureReason = [string]$validation.FailureReason
        $isZeroZero = [bool]$validation.IsZeroZero
        $isSwapped = [bool]$validation.IsSwapped
    } catch {
        $validationResult = 'FAIL'
        $failureReason = $_.Exception.Message
    }

    [pscustomobject]@{
        LocationKey = $locationKey
        ProvinceKey = [string]$Province.Key
        CityKey = [string]$City.Key
        DistrictKey = [string]$District.Key
        DisplayNameZh = ('{0} / {1} / {2}' -f (T $Province.Zh), (T $City.Zh), (T $District.Zh))
        DisplayNameEn = ('{0} / {1} / {2}' -f $Province.En, $City.En, $District.En)
        Latitude = if ($null -ne $location) { [double]$location.Lat } else { '' }
        Longitude = if ($null -ne $location) { [double]$location.Lon } else { '' }
        CoordinateSource = if ($null -ne $location) { [string]$location.CoordinateSource } else { '' }
        CoordinatePrecision = if ($null -ne $location) { [string]$location.CoordinatePrecision } else { '' }
        CoordinateValidatedAt = if ($null -ne $location) { [string]$location.CoordinateValidatedAt } else { '' }
        IsApproximateCoordinate = if ($null -ne $location) { [bool]$location.IsApproximateCoordinate } else { $false }
        ValidationResult = $validationResult
        FailureReason = $failureReason
        IsZeroZero = $isZeroZero
        IsSwapped = $isSwapped
        RequestCoordinateMatchesCatalog = ($validationResult -eq 'PASS')
        CoordinateKey = if ($null -ne $location) { ('{0:N6},{1:N6}' -f [double]$location.Lat, [double]$location.Lon) } else { '' }
    }
}

$raw = New-Object System.Collections.Generic.List[object]
foreach ($province in @($script:Provinces)) {
    foreach ($city in @($province.Cities)) {
        foreach ($district in @($city.Districts)) {
            $raw.Add((New-LocationCatalogAuditRecord -Province $province -City $city -District $district)) | Out-Null
        }
    }
}

$seenLocation = @{}
$seenCoordinate = @{}
$records = New-Object System.Collections.Generic.List[object]
foreach ($row in @($raw | Sort-Object ProvinceKey, CityKey, DistrictKey)) {
    if ($seenLocation.ContainsKey($row.LocationKey)) { continue }
    if ($row.ValidationResult -eq 'PASS' -and $seenCoordinate.ContainsKey($row.CoordinateKey)) { continue }
    $seenLocation[$row.LocationKey] = $true
    if ($row.ValidationResult -eq 'PASS') { $seenCoordinate[$row.CoordinateKey] = $true }
    $records.Add($row) | Out-Null
}

$invalid = @($records | Where-Object { $_.ValidationResult -ne 'PASS' })
$zeroZero = @($records | Where-Object { $_.IsZeroZero })
$swapped = @($records | Where-Object { $_.IsSwapped })
$mismatch = @($records | Where-Object { -not $_.RequestCoordinateMatchesCatalog })
$uniqueLocationKeys = @($records.LocationKey | Select-Object -Unique)
$summary = [pscustomobject]@{
    RawCatalogRegionCount = $raw.Count
    AuditedRegionCount = $records.Count
    UniqueLocationKeyCount = $uniqueLocationKeys.Count
    InvalidCoordinateCount = $invalid.Count
    ZeroZeroCount = $zeroZero.Count
    SwappedCoordinateCount = $swapped.Count
    RequestCatalogMismatchCount = $mismatch.Count
    ApproximateCoordinateCount = @($records | Where-Object { $_.IsApproximateCoordinate }).Count
    Result = if ($records.Count -eq 47 -and $uniqueLocationKeys.Count -eq 47 -and $invalid.Count -eq 0 -and $zeroZero.Count -eq 0 -and $swapped.Count -eq 0 -and $mismatch.Count -eq 0) { 'PASS' } else { 'FAIL' }
}

$jsonPath = Join-Path $ReportDir 'location-catalog-audit.json'
$csvPath = Join-Path $ReportDir 'location-catalog-audit.csv'
$mdPath = Join-Path $ReportDir 'location-catalog-audit.md'
[pscustomobject]@{ Summary = $summary; Records = @($records | ForEach-Object { $_ }) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
$records | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# Location Catalog Audit') | Out-Null
$lines.Add(('- Result: {0}' -f $summary.Result)) | Out-Null
$lines.Add(('- Raw catalog regions: {0}' -f $summary.RawCatalogRegionCount)) | Out-Null
$lines.Add(('- Audited unique-coordinate regions: {0}' -f $summary.AuditedRegionCount)) | Out-Null
$lines.Add(('- Unique LocationKeys: {0}' -f $summary.UniqueLocationKeyCount)) | Out-Null
$lines.Add(('- Invalid coordinates: {0}' -f $summary.InvalidCoordinateCount)) | Out-Null
$lines.Add(('- 0,0 coordinates: {0}' -f $summary.ZeroZeroCount)) | Out-Null
$lines.Add(('- Swapped coordinates: {0}' -f $summary.SwappedCoordinateCount)) | Out-Null
$lines.Add(('- Request/catalog mismatches: {0}' -f $summary.RequestCatalogMismatchCount)) | Out-Null
$lines.Add(('- Approximate coordinates: {0}' -f $summary.ApproximateCoordinateCount)) | Out-Null
$lines.Add('') | Out-Null
$lines.Add('## Failures') | Out-Null
if ($invalid.Count -eq 0 -and $zeroZero.Count -eq 0 -and $swapped.Count -eq 0 -and $mismatch.Count -eq 0) { $lines.Add('- None') | Out-Null } else { foreach ($f in @($invalid + $zeroZero + $swapped + $mismatch)) { $lines.Add(('- {0}: {1}' -f $f.LocationKey, $f.FailureReason)) | Out-Null } }
$lines | Set-Content -LiteralPath $mdPath -Encoding UTF8

[pscustomobject]@{
    Result = $summary.Result
    RawCatalogRegionCount = $summary.RawCatalogRegionCount
    AuditedRegionCount = $summary.AuditedRegionCount
    UniqueLocationKeyCount = $summary.UniqueLocationKeyCount
    InvalidCoordinateCount = $summary.InvalidCoordinateCount
    ZeroZeroCount = $summary.ZeroZeroCount
    SwappedCoordinateCount = $summary.SwappedCoordinateCount
    RequestCatalogMismatchCount = $summary.RequestCatalogMismatchCount
    Json = $jsonPath
    Csv = $csvPath
    Markdown = $mdPath
} | Format-List

if ($summary.Result -ne 'PASS') { exit 1 }
exit 0
