#Requires -Version 5.1
param(
    [string]$Version = '1.0.0',
    [switch]$SkipPs2ExeDownload
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw 'Version must use Major.Minor.Patch format, for example 1.0.0.'
}

$repoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repoRoot = [IO.Path]::GetFullPath($repoRoot)
$sourcePath = Join-Path $repoRoot 'LonghuaWeatherWidget.ps1'
$licensePath = Join-Path $repoRoot 'LICENSE'
$distDir = Join-Path $repoRoot 'dist'
$distFullPath = [IO.Path]::GetFullPath($distDir)

if (-not (Test-Path -LiteralPath $sourcePath)) {
    throw "Source script not found: $sourcePath"
}
if (-not (Test-Path -LiteralPath $licensePath)) {
    throw "LICENSE not found: $licensePath"
}
if (-not $distFullPath.StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean dist outside repo: $distFullPath"
}

$exeName = "LonghuaWeatherWidget-v$Version-win-x64.exe"
$zipName = "LonghuaWeatherWidget-v$Version-win-x64.zip"
$exePath = Join-Path $distDir $exeName
$zipPath = Join-Path $distDir $zipName
$shaPath = Join-Path $distDir 'SHA256SUMS.txt'

function Import-PS2EXEForBuild {
    param([switch]$SkipDownload)

    $command = Get-Command Invoke-PS2EXE -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return
    }

    $existingModule = Get-Module -ListAvailable -Name ps2exe | Select-Object -First 1
    if ($null -ne $existingModule) {
        Import-Module ps2exe -ErrorAction Stop
        return
    }

    if ($SkipDownload) {
        throw 'PS2EXE is not available. Re-run without -SkipPs2ExeDownload or install it for the build machine only.'
    }

    if (-not (Get-Command Save-Module -ErrorAction SilentlyContinue)) {
        throw 'Save-Module is required to fetch PS2EXE as a build dependency.'
    }

    $moduleRoot = Join-Path ([IO.Path]::GetTempPath()) 'LonghuaWeatherWidget-build-modules'
    if (-not (Test-Path -LiteralPath $moduleRoot)) {
        New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null
    }

    if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    }

    Save-Module -Name ps2exe -Path $moduleRoot -Repository PSGallery -Force
    $env:PSModulePath = $moduleRoot + [IO.Path]::PathSeparator + $env:PSModulePath
    Import-Module ps2exe -ErrorAction Stop
}

Import-PS2EXEForBuild -SkipDownload:$SkipPs2ExeDownload

if (Test-Path -LiteralPath $distDir) {
    Remove-Item -LiteralPath $distDir -Recurse -Force
}
New-Item -ItemType Directory -Path $distDir -Force | Out-Null

$fileVersion = "$Version.0"
$ps2exeParams = @{
    InputFile = $sourcePath
    OutputFile = $exePath
    NoConsole = $true
    STA = $true
    DPIAware = $true
    SupportOS = $true
    X64 = $true
    Title = 'Longhua Weather Widget'
    Description = 'Portable Windows PowerShell WPF weather widget for Shenzhen Longhua.'
    Product = 'Longhua Weather Widget'
    Company = 'Longhua Weather Widget Project'
    Copyright = 'Copyright (c) 2026 Longhua Weather Widget contributors'
    Version = $fileVersion
}

Invoke-PS2EXE @ps2exeParams

if (-not (Test-Path -LiteralPath $exePath)) {
    throw "PS2EXE did not create: $exePath"
}

$packageDir = Join-Path ([IO.Path]::GetTempPath()) ('LonghuaWeatherWidget-package-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $packageDir -Force | Out-Null
try {
    Copy-Item -LiteralPath $exePath -Destination (Join-Path $packageDir 'LonghuaWeatherWidget.exe') -Force
    Copy-Item -LiteralPath $licensePath -Destination (Join-Path $packageDir 'LICENSE') -Force

    $packageReadme = @"
Longhua Weather Widget v$Version

Run LonghuaWeatherWidget.exe. No administrator rights are required.

Settings are stored at:
%LOCALAPPDATA%\LonghuaWeatherWidget\settings.json

The app uses Open-Meteo as the primary weather provider and wttr.in as fallback. No API key is required.
Weather data by Open-Meteo.

This build is unsigned. Windows SmartScreen may show an unknown publisher warning on first launch.
"@
    Set-Content -LiteralPath (Join-Path $packageDir 'README.txt') -Value $packageReadme -Encoding UTF8

    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    Compress-Archive -Path (Join-Path $packageDir '*') -DestinationPath $zipPath -Force
} finally {
    if (Test-Path -LiteralPath $packageDir) {
        Remove-Item -LiteralPath $packageDir -Recurse -Force
    }
}

$hashLines = foreach ($artifact in @($exePath, $zipPath)) {
    $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $artifact
    '{0}  {1}' -f $hash.Hash.ToLowerInvariant(), (Split-Path -Leaf $artifact)
}
Set-Content -LiteralPath $shaPath -Value $hashLines -Encoding ASCII

Write-Host "EXE: $exePath"
Write-Host "ZIP: $zipPath"
Write-Host "SHA256: $shaPath"