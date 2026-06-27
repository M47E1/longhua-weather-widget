[CmdletBinding()]
param(
    [string]$OutputDir = $null,
    [int]$TimeoutSeconds = 90
)

$ErrorActionPreference = 'Stop'
$script:ScriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $script:ScriptRoot ('reports\ui-final-gate\english-no-cjk-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
New-Item -ItemType Directory -Path $OutputDir -Force -ErrorAction Stop | Out-Null

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

if (-not ('EnglishNoCjkWin32' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class EnglishNoCjkWin32 {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@
}

$script:Process = $null
$script:Hwnd = [IntPtr]::Zero
$report = [ordered]@{
    Name = 'EnglishModeNoCjk'
    StartedAt = (Get-Date).ToString('s')
    OutputDir = $OutputDir
    Screenshot = (Join-Path $OutputDir 'normal-english-long-location.png')
    Result = 'FAIL'
    ItemStatus = ''
    Texts = [ordered]@{}
    CjkMatches = @()
    Error = ''
}

function Find-WindowByPid {
    param([int]$ProcessId, [int]$TimeoutMs = 30000)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    do {
        $script:FoundHwnd = [IntPtr]::Zero
        $cb = [EnglishNoCjkWin32+EnumWindowsProc]{
            param([IntPtr]$h, [IntPtr]$l)
            [uint32]$windowProcessId = 0
            [EnglishNoCjkWin32]::GetWindowThreadProcessId($h, [ref]$windowProcessId) | Out-Null
            if ([int]$windowProcessId -eq $ProcessId -and [EnglishNoCjkWin32]::IsWindowVisible($h)) {
                $sb = New-Object System.Text.StringBuilder 512
                [EnglishNoCjkWin32]::GetWindowText($h, $sb, $sb.Capacity) | Out-Null
                if ($sb.ToString() -match 'LonghuaWeatherWidget|Basic Weather Widget') { $script:FoundHwnd = $h; return $false }
            }
            return $true
        }
        [EnglishNoCjkWin32]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
        if ($script:FoundHwnd -ne [IntPtr]::Zero) { return $script:FoundHwnd }
        Start-Sleep -Milliseconds 120
    } while ((Get-Date) -lt $deadline)
    throw "No window for PID $ProcessId"
}
function Get-Root { [System.Windows.Automation.AutomationElement]::FromHandle($script:Hwnd) }
function Find-ById {
    param([string]$AutomationId, [int]$TimeoutMs = 5000)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    $condition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $AutomationId)
    do {
        $root = Get-Root
        if ($null -ne $root) {
            $e = $root.FindFirst([System.Windows.Automation.TreeScope]::Subtree, $condition)
            if ($null -ne $e) { return $e }
        }
        Start-Sleep -Milliseconds 80
    } while ((Get-Date) -lt $deadline)
    return $null
}
function Get-TextById {
    param([string]$AutomationId)
    $e = Find-ById $AutomationId 6000
    if ($null -eq $e) { return '<missing>' }
    $vp = $null
    if ($e.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp) -and -not [string]::IsNullOrWhiteSpace($vp.Current.Value)) { return [string]$vp.Current.Value }
    return [string]$e.Current.Name
}
function Get-AllUiText {
    $items = New-Object System.Collections.Generic.List[string]
    $root = Get-Root
    if ($null -eq $root) { return @() }
    $all = $root.FindAll([System.Windows.Automation.TreeScope]::Subtree, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($e in $all) {
        try {
            $name = [string]$e.Current.Name
            if (-not [string]::IsNullOrWhiteSpace($name)) { $items.Add($name) | Out-Null }
            $vp = $null
            if ($e.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp) -and -not [string]::IsNullOrWhiteSpace($vp.Current.Value)) { $items.Add([string]$vp.Current.Value) | Out-Null }
        } catch {}
    }
    return @($items | Select-Object -Unique)
}

function Get-ItemStatus { try { [string](Get-Root).Current.ItemStatus } catch { '' } }
function Wait-FinalState {
    param([int]$TimeoutMs)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    do {
        $status = Get-ItemStatus
        if ($status -match 'State=(Loaded|Error);' -and $status -match 'LocationKey=Jiangsu\|Suzhou\|SIP') { return $status }
        Start-Sleep -Milliseconds 150
    } while ((Get-Date) -lt $deadline)
    return Get-ItemStatus
}
function Show-TargetWindow {
    if ($script:Hwnd -eq [IntPtr]::Zero) { return }
    [EnglishNoCjkWin32]::ShowWindow($script:Hwnd, 9) | Out-Null
    [EnglishNoCjkWin32]::SetForegroundWindow($script:Hwnd) | Out-Null
    Start-Sleep -Milliseconds 600
}
function Test-ImageHasDetail {
    param([string]$Path)
    $bmp = [System.Drawing.Bitmap]::FromFile((Resolve-Path $Path))
    try {
        $colors = @{}
        for ($x = 0; $x -lt $bmp.Width; $x += 20) {
            for ($y = 0; $y -lt $bmp.Height; $y += 20) {
                $colors[$bmp.GetPixel($x, $y).ToArgb()] = 1
                if ($colors.Count -gt 4) { return $true }
            }
        }
        return $false
    } finally {
        $bmp.Dispose()
    }
}
function Write-CommandFile {
    param([hashtable]$Command)
    $Command['Id'] = [guid]::NewGuid().ToString('N')
    $Command | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDir 'ui-smoke-command.json') -Encoding UTF8
}
function Wait-LoadedState {
    param([int]$TimeoutMs)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    do {
        $status = Get-ItemStatus
        if ($status -match 'State=Loaded;' -and $status -match 'LocationKey=Jiangsu\\|Suzhou\\|SIP') { return $status }
        Start-Sleep -Milliseconds 150
    } while ((Get-Date) -lt $deadline)
    return Get-ItemStatus
}
function Wait-RenderedScreenshot {
    param([string]$Path, [int]$TimeoutMs = 10000)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    do {
        if (Test-Path -LiteralPath $Path) {
            try {
                if (Test-ImageHasDetail -Path $Path) { return }
            } catch {}
        }
        Start-Sleep -Milliseconds 120
    } while ((Get-Date) -lt $deadline)
    throw 'Rendered screenshot was not created or appears blank.'
}

function Save-Screenshot {
    param([string]$Path)
    $rect = New-Object EnglishNoCjkWin32+RECT
    if (-not [EnglishNoCjkWin32]::GetWindowRect($script:Hwnd, [ref]$rect)) { throw 'GetWindowRect failed' }
    $virtual = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $left = [Math]::Max($rect.Left, $virtual.Left); $top = [Math]::Max($rect.Top, $virtual.Top)
    $right = [Math]::Min($rect.Right, $virtual.Right); $bottom = [Math]::Min($rect.Bottom, $virtual.Bottom)
    $w = [Math]::Max(1, $right - $left); $h = [Math]::Max(1, $bottom - $top)
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        try {
            $g.CopyFromScreen($left, $top, 0, 0, $bmp.Size)
        } catch {
            $hdc = $g.GetHdc()
            try {
                if (-not [EnglishNoCjkWin32]::PrintWindow($script:Hwnd, $hdc, 0)) { throw 'PrintWindow failed' }
            } finally {
                $g.ReleaseHdc($hdc)
            }
        }
        $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally { $g.Dispose(); $bmp.Dispose() }
}

try {
    $settings = [ordered]@{
        Language = 'en'
        ProvinceKey = 'Jiangsu'
        CityKey = 'Suzhou'
        DistrictKey = 'SIP'
        RefreshSeconds = 60
        DrawerEdge = 'Left'
        DrawerExpanded = $true
        DrawerTop = $null
        DrawerScreenDeviceName = $null
        SavedAt = (Get-Date).ToString('s')
    }
    $settings | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDir 'LonghuaWeatherWidget.ui-smoke.settings.json') -Encoding UTF8
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',(Join-Path $script:ScriptRoot 'LonghuaWeatherWidget.ps1'),'-NoTopMost','-UiSmokeMode','-UiFixture','Live','-UiSmokeOutput',$OutputDir,'-UiSmokeDelayMs','700','-RefreshSeconds','60')
    $script:Process = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $OutputDir 'widget.stdout.txt') -RedirectStandardError (Join-Path $OutputDir 'widget.stderr.txt')
    $script:Hwnd = Find-WindowByPid -ProcessId $script:Process.Id -TimeoutMs 30000
    $report['InitialItemStatus'] = Wait-FinalState -TimeoutMs ($TimeoutSeconds * 1000)
    Write-CommandFile @{ Action = 'InjectFixtureWeather'; Fixture = 'current-no-rain-future-heavy-rain' }
    $report.ItemStatus = Wait-LoadedState -TimeoutMs 20000
    if ($report.ItemStatus -notmatch 'State=Loaded;') { throw ('Fixture weather did not reach Loaded state: ' + $report.ItemStatus) }
    foreach ($id in @('LocationTitle','WeatherDescription','NearTermForecast','WarningPanel','LoadingPanel','StatusFooter','ProvinceSelector','CitySelector','DistrictSelector')) {
        $report.Texts[$id] = Get-TextById $id
    }
    Show-TargetWindow
    Write-CommandFile @{ Action = 'CaptureWindow'; Path = $report.Screenshot }
    Wait-RenderedScreenshot -Path $report.Screenshot -TimeoutMs 10000
    $allUiTexts = Get-AllUiText
    $report.Texts['AllTextCount'] = @($allUiTexts).Count
    $allText = ($allUiTexts -join "`n")
    $matches = [regex]::Matches($allText, '[\u3400-\u9FFF\uF900-\uFAFF]') | ForEach-Object { $_.Value } | Select-Object -Unique
    $report.CjkMatches = @($matches)
    if (@($matches).Count -gt 0) { throw ('English UI contains CJK characters: ' + (@($matches) -join '')) }
    if ($report.Texts['LocationTitle'] -ne 'Jiangsu · Suzhou · Industrial Park') { throw ('Unexpected English location title: ' + $report.Texts['LocationTitle']) }
    $report.Result = 'PASS'
} catch {
    $report.Error = $_.Exception.Message
    throw
} finally {
    if ($script:Hwnd -ne [IntPtr]::Zero) { [EnglishNoCjkWin32]::PostMessage($script:Hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null }
    if ($null -ne $script:Process) { try { $script:Process.WaitForExit(4000) | Out-Null } catch {}; if (-not $script:Process.HasExited) { Stop-Process -Id $script:Process.Id -Force -ErrorAction SilentlyContinue } }
    $report.CompletedAt = (Get-Date).ToString('s')
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDir 'english-mode-no-cjk.json') -Encoding UTF8
}

Write-Host ("ENGLISH_NO_CJK Result={0} Screenshot={1}" -f $report.Result, $report.Screenshot)
