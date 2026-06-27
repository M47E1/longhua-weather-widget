$ErrorActionPreference = 'Stop'

$repoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$pesterScript = Join-Path $repoRoot 'LonghuaWeatherWidget.Tests.ps1'
$standaloneScript = Join-Path $repoRoot 'Test-LonghuaWeatherWidget.ps1'

function Get-ResultCount {
    param(
        [object]$Result,
        [string[]]$Names
    )

    foreach ($name in $Names) {
        if ($null -ne $Result -and $null -ne $Result.PSObject.Properties[$name]) {
            return [int]$Result.$name
        }
    }

    return 0
}

function Fail-ProjectTests {
    param([string]$Message)

    Write-Host "PROJECT_TEST_ERROR $Message"
    exit 1
}

$command = Get-Command Invoke-Pester -ErrorAction SilentlyContinue
if ($null -eq $command) {
    Fail-ProjectTests 'Invoke-Pester is not available.'
}

$parameterKeys = @($command.Parameters.Keys)
$pesterVersion = $null
$pesterModule = Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1
if ($null -ne $pesterModule) {
    $pesterVersion = [string]$pesterModule.Version
}

Write-Host "PesterVersion=$pesterVersion"

$pesterParams = @{ PassThru = $true }
if ($parameterKeys -contains 'Path') {
    $pesterParams.Path = $pesterScript
} elseif ($parameterKeys -contains 'Script') {
    $pesterParams.Script = $pesterScript
}
if ($parameterKeys -contains 'Output') {
    $pesterParams.Output = 'Detailed'
}

try {
    if ($pesterParams.ContainsKey('Path') -or $pesterParams.ContainsKey('Script')) {
        $pesterResult = Invoke-Pester @pesterParams
    } else {
        $pesterResult = Invoke-Pester $pesterScript -PassThru
    }
} catch {
    Write-Host $_.Exception.Message
    Fail-ProjectTests 'Pester execution failed.'
}

$pesterTotal = Get-ResultCount -Result $pesterResult -Names @('TotalCount', 'Total', 'Tests')
$pesterPassed = Get-ResultCount -Result $pesterResult -Names @('PassedCount', 'Passed')
$pesterFailed = Get-ResultCount -Result $pesterResult -Names @('FailedCount', 'Failed')
$pesterSkipped = Get-ResultCount -Result $pesterResult -Names @('SkippedCount', 'Skipped', 'NotRunCount')

if ($pesterTotal -le 0) {
    Fail-ProjectTests 'Pester completed with zero tests.'
}

$standaloneOutput = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $standaloneScript 2>&1
$standaloneExit = $LASTEXITCODE
$standaloneOutput | ForEach-Object { Write-Host $_ }

$summaryLine = @($standaloneOutput | Where-Object { [string]$_ -match '^TEST_SUMMARY ' } | Select-Object -Last 1)
if ($summaryLine.Count -eq 0) {
    Fail-ProjectTests 'Standalone test script did not emit TEST_SUMMARY.'
}

$summaryText = [string]$summaryLine[-1]
if ($summaryText -notmatch 'Total=(\d+)\s+Passed=(\d+)\s+Failed=(\d+)\s+Skipped=(\d+)') {
    Fail-ProjectTests 'Standalone TEST_SUMMARY could not be parsed.'
}

$standaloneTotal = [int]$Matches[1]
$standalonePassed = [int]$Matches[2]
$standaloneFailed = [int]$Matches[3]
$standaloneSkipped = [int]$Matches[4]

if ($standaloneExit -ne 0) {
    $standaloneFailed = [Math]::Max(1, $standaloneFailed)
}
if ($standaloneTotal -le 0) {
    Fail-ProjectTests 'Standalone test script completed with zero tests.'
}

$total = $pesterTotal + $standaloneTotal
$passed = $pesterPassed + $standalonePassed
$failed = $pesterFailed + $standaloneFailed
$skipped = $pesterSkipped + $standaloneSkipped

Write-Host "PROJECT_TEST_SUMMARY Total=$total Passed=$passed Failed=$failed Skipped=$skipped"

if ($failed -gt 0) {
    exit 1
}

exit 0