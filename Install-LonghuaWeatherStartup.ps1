param(
    [int]$RefreshSeconds = 60
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$widgetPath = Join-Path $scriptDir 'LonghuaWeatherWidget.ps1'
if (-not (Test-Path -LiteralPath $widgetPath)) {
    throw "Widget script not found: $widgetPath"
}

$startup = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startup 'Longhua Weather Widget.lnk'
$target = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Sta -File `"$widgetPath`" -RefreshSeconds $RefreshSeconds"

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $target
$shortcut.Arguments = $arguments
$shortcut.WorkingDirectory = $scriptDir
$shortcut.IconLocation = "$target,0"
$shortcut.Description = 'Basic weather widget for Shenzhen Longhua.'
$shortcut.Save()

Write-Host "Startup shortcut created: $shortcutPath"
Write-Host "Widget script: $widgetPath"
Write-Host "Refresh interval: $RefreshSeconds seconds"
