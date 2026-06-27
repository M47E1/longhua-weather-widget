[CmdletBinding()]
param(
    [string]$RegionSmokeReportDir = $null,
    [string]$OutputDir = $null,
    [int]$RegionCount = 24,
    [int]$TimeoutSeconds = 35,
    [int]$RegionOffset = 0,
    [int]$ChunkSize = 8,
    [switch]$NoChunk
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { $script:ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path } else { $script:ScriptRoot = $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($RegionSmokeReportDir)) {
    $latest = Get-ChildItem -LiteralPath (Join-Path $script:ScriptRoot 'reports\region-smoke-200') -Directory -ErrorAction Stop | Sort-Object Name -Descending | Select-Object -First 1
    if ($null -eq $latest) { throw 'No region smoke report directory found.' }
    $RegionSmokeReportDir = $latest.FullName
}
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $script:ScriptRoot ('reports\ui-smoke-real\{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

. (Join-Path $script:ScriptRoot 'LonghuaWeatherWidget.ps1') -TestMode
$script:CatalogProvinces = @($script:Provinces)

if (-not ('RealRegionUiSmokeWin32' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class RealRegionUiSmokeWin32 {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr hWnd);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder className, int count);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT point);
  [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
  [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool repaint);
}
"@
}

$script:Report = [ordered]@{
    StartedAt = (Get-Date).ToString('s')
    RegionSmokeReportDir = $RegionSmokeReportDir
    OutputDir = $OutputDir
    Pid = $null
    Hwnd = $null
    SelectedRegions = @()
    SelectedRegionCount = 0
    ActualSwitchAttemptCount = 0
    ActualSwitchSuccessCount = 0
    ActualSwitchFailureCount = 0
    LoadingStateObservedCount = 0
    LoadingObserverSamples = @()
    ScreenshotCount = 0
    AutomationIdUniqueness = @()
    Coverage = [ordered]@{}
    Assertions = @()
    Failures = @()
    Screenshots = [ordered]@{}
    TextSnapshots = [ordered]@{}
    VisualCheck = 'PENDING_VISUAL_REVIEW'
    ChunkMode = $false
    Chunks = @()
    HarnessDiagnostics = @()
    RootRecoveries = @()
    WindowDiagnostics = @()
    SettingsRestored = $false
}
$script:HadFailure = $false
$script:Process = $null
$script:Hwnd = [IntPtr]::Zero
$script:CurrentScenario = 'Setup'
$script:SettingsPath = Join-Path $script:ScriptRoot 'LonghuaWeatherWidget.settings.json'
$script:SettingsBackup = $null
$script:SettingsHadFile = Test-Path -LiteralPath $script:SettingsPath
if ($script:SettingsHadFile) { $script:SettingsBackup = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 }

function Add-Assert {
    param([string]$Name, [bool]$Passed, [string]$Details = '')
    $entry = [pscustomobject]@{ Scenario=$script:CurrentScenario; Name=$Name; Passed=[bool]$Passed; Details=$Details }
    $script:Report.Assertions += $entry
    if (-not $Passed) { $script:HadFailure = $true; $script:Report.Failures += $entry; throw "ASSERT FAILED [$($script:CurrentScenario)] $Name $Details" }
}

function Add-SoftAssert {
    param([string]$Name, [bool]$Passed, [string]$Details = '')
    $entry = [pscustomobject]@{ Scenario=$script:CurrentScenario; Name=$Name; Passed=[bool]$Passed; Details=$Details; Soft=$true }
    $script:Report.Assertions += $entry
    if (-not $Passed) { $script:Report.Failures += $entry }
}

function Get-WindowRectForHwnd {
    param([IntPtr]$Hwnd)
    $rect = New-Object RealRegionUiSmokeWin32+RECT
    if (-not [RealRegionUiSmokeWin32]::GetWindowRect($Hwnd, [ref]$rect)) { throw 'GetWindowRect failed.' }
    [pscustomobject]@{ Left=$rect.Left; Top=$rect.Top; Right=$rect.Right; Bottom=$rect.Bottom; Width=($rect.Right-$rect.Left); Height=($rect.Bottom-$rect.Top) }
}

function Get-WindowTextForHwnd {
    param([IntPtr]$Hwnd)
    $sb = New-Object System.Text.StringBuilder 512
    [RealRegionUiSmokeWin32]::GetWindowText($Hwnd, $sb, $sb.Capacity) | Out-Null
    return $sb.ToString()
}

function Get-WindowClassNameForHwnd {
    param([IntPtr]$Hwnd)
    $sb = New-Object System.Text.StringBuilder 256
    [RealRegionUiSmokeWin32]::GetClassName($Hwnd, $sb, $sb.Capacity) | Out-Null
    return $sb.ToString()
}

function Get-TopLevelWindowsForPid {
    param([int]$ProcessId)
    $script:EnumWindowRows = @()
    $callback = [RealRegionUiSmokeWin32+EnumWindowsProc]{
        param([IntPtr]$hWnd, [IntPtr]$lParam)
        [uint32]$windowPid = 0
        [RealRegionUiSmokeWin32]::GetWindowThreadProcessId($hWnd, [ref]$windowPid) | Out-Null
        if ([int]$windowPid -eq $ProcessId) {
            $rectObj = $null
            try { $rectObj = Get-WindowRectForHwnd -Hwnd $hWnd } catch {}
            $script:EnumWindowRows += [pscustomobject]@{
                Hwnd = ('0x{0:X}' -f $hWnd.ToInt64())
                HwndInt64 = $hWnd.ToInt64()
                ProcessId = [int]$windowPid
                Title = Get-WindowTextForHwnd -Hwnd $hWnd
                ClassName = Get-WindowClassNameForHwnd -Hwnd $hWnd
                Visible = [RealRegionUiSmokeWin32]::IsWindowVisible($hWnd)
                Enabled = [RealRegionUiSmokeWin32]::IsWindowEnabled($hWnd)
                IsWindow = [RealRegionUiSmokeWin32]::IsWindow($hWnd)
                Rect = $rectObj
            }
        }
        return $true
    }
    [RealRegionUiSmokeWin32]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null
    return @($script:EnumWindowRows)
}

function Find-WindowByPid {
    param([int]$ProcessId, [int]$TimeoutMs = 20000)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    do {
        $windows = @(Get-TopLevelWindowsForPid -ProcessId $ProcessId)
        $script:Report.WindowDiagnostics += [pscustomobject]@{ At=(Get-Date).ToString('s'); ProcessId=$ProcessId; Windows=$windows }
        $candidate = @($windows | Where-Object { $_.IsWindow -and $_.Visible -and $_.Title -match 'Basic Weather Widget|LonghuaWeatherWidget' } | Select-Object -First 1)
        if ($candidate.Count -gt 0) { return [IntPtr][int64]$candidate[0].HwndInt64 }
        Start-Sleep -Milliseconds 150
    } while ((Get-Date) -lt $deadline)
    throw "No widget window found for PID $ProcessId."
}

function Test-WidgetHwnd {
    param([IntPtr]$Hwnd)
    if ($Hwnd -eq [IntPtr]::Zero) { return $false }
    if (-not [RealRegionUiSmokeWin32]::IsWindow($Hwnd)) { return $false }
    if (-not [RealRegionUiSmokeWin32]::IsWindowVisible($Hwnd)) { return $false }
    [uint32]$windowPid = 0
    [RealRegionUiSmokeWin32]::GetWindowThreadProcessId($Hwnd, [ref]$windowPid) | Out-Null
    if ($null -eq $script:Process -or [int]$windowPid -ne [int]$script:Process.Id) { return $false }
    return $true
}

function Recover-WindowRoot {
    param([string]$Reason)
    if ($null -eq $script:Process) { throw "Cannot recover window root: no process. Reason=$Reason" }
    try { $script:Process.Refresh() } catch {}
    if ($script:Process.HasExited) { throw "Widget process exited during UI smoke. Reason=$Reason ExitCode=$($script:Process.ExitCode)" }
    $old = $script:Hwnd
    $script:Hwnd = Find-WindowByPid -ProcessId $script:Process.Id -TimeoutMs 5000
    $script:Report.Hwnd = ('0x{0:X}' -f $script:Hwnd.ToInt64())
    $script:Report.RootRecoveries += [pscustomobject]@{ At=(Get-Date).ToString('s'); Reason=$Reason; OldHwnd=('0x{0:X}' -f $old.ToInt64()); NewHwnd=$script:Report.Hwnd; ProcessId=$script:Process.Id }
}

function Get-FreshAutomationRoot {
    param([string]$Reason = 'root')
    $lastError = $null
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            if (-not (Test-WidgetHwnd -Hwnd $script:Hwnd)) { Recover-WindowRoot -Reason "$Reason invalid-hwnd attempt-$attempt" }
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($script:Hwnd)
            if ($null -eq $root) { throw 'FromHandle returned null.' }
            if ([int]$root.Current.ProcessId -ne [int]$script:Process.Id) { throw "Root PID mismatch root=$($root.Current.ProcessId) expected=$($script:Process.Id)" }
            $rect = $root.Current.BoundingRectangle
            if ($rect.Width -le 0 -or $rect.Height -le 0) { throw "Root empty rect $($rect.Width)x$($rect.Height)" }
            return $root
        } catch {
            $lastError = $_.Exception.Message
            $script:Report.HarnessDiagnostics += [pscustomobject]@{ At=(Get-Date).ToString('s'); Reason=$Reason; Attempt=$attempt; Error=$lastError; Hwnd=('0x{0:X}' -f $script:Hwnd.ToInt64()); ProcessId=if($script:Process){$script:Process.Id}else{$null} }
            try { Recover-WindowRoot -Reason "$Reason fromhandle-failed attempt-$attempt" } catch { $lastError = $_.Exception.Message }
            Start-Sleep -Milliseconds (200 * $attempt)
        }
    }
    throw "Unable to get fresh automation root for $Reason. LastError=$lastError"
}

function Get-RootElement { Get-FreshAutomationRoot -Reason 'Get-RootElement' }

function Find-ElementById {
    param([string]$AutomationId, [int]$TimeoutMs = 5000)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    $condition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $AutomationId)
    do {
        $root = Get-RootElement
        if ($null -ne $root) {
            $element = $root.FindFirst([System.Windows.Automation.TreeScope]::Subtree, $condition)
            if ($null -ne $element) { return $element }
        }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    throw "AutomationId not found: $AutomationId"
}

function Test-ElementVisible {
    param([System.Windows.Automation.AutomationElement]$Element)
    if ($null -eq $Element) { return $false }
    $rect = $Element.Current.BoundingRectangle
    return ($rect.Width -gt 0 -and $rect.Height -gt 0 -and -not $Element.Current.IsOffscreen)
}

function Wait-ElementVisibleById {
    param([string]$AutomationId, [int]$TimeoutMs = 4000)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    do {
        try {
            $element = Find-ElementById -AutomationId $AutomationId -TimeoutMs 250
            if (Test-ElementVisible -Element $element) { return $element }
        } catch {}
        Start-Sleep -Milliseconds 120
    } while ((Get-Date) -lt $deadline)
    $element = Find-ElementById -AutomationId $AutomationId -TimeoutMs 500
    $rect = $element.Current.BoundingRectangle
    throw "AutomationId not visible: $AutomationId rect=$($rect.Width)x$($rect.Height) offscreen=$($element.Current.IsOffscreen)"
}
function Find-ElementsById {
    param([string]$AutomationId)
    $condition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $AutomationId)
    $root = Get-RootElement
    if ($null -eq $root) { return @() }
    return @($root.FindAll([System.Windows.Automation.TreeScope]::Subtree, $condition))
}

function Assert-AutomationIdUnique {
    param([string]$AutomationId)
    $matches = @(Find-ElementsById -AutomationId $AutomationId)
    $entry = [pscustomobject]@{ AutomationId = $AutomationId; Count = $matches.Count }
    $script:Report.AutomationIdUniqueness += $entry
    Add-Assert -Name "AutomationId $AutomationId unique" -Passed ($matches.Count -eq 1) -Details ("count={0}" -f $matches.Count)
}

function Get-ElementText {
    param([System.Windows.Automation.AutomationElement]$Element)
    if ($null -eq $Element) { return '' }
    $name = [string]$Element.Current.Name
    $valuePattern = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$valuePattern)) {
        if (-not [string]::IsNullOrWhiteSpace($valuePattern.Current.Value)) { return [string]$valuePattern.Current.Value }
    }
    return $name
}

function Get-UiTextSnapshot {
    param([string]$Name)
    $ids = @('LocationTitle','WeatherDescription','NearTermForecast','TemperatureText','WarningPanel','RainfallText','HumidityText','PressureText','WindText','LoadingPanel','ErrorPanel','StatusFooter','ProvinceSelector','CitySelector','DistrictSelector','RefreshIntervalSelector','ForecastStartSelector','ForecastEndSelector','LanguageCnButton','LanguageEnButton')
    $byId = [ordered]@{}
    foreach ($id in $ids) {
        try { $byId[$id] = Get-ElementText (Find-ElementById -AutomationId $id -TimeoutMs 600) } catch { $byId[$id] = '<missing>' }
    }
    $allNames = New-Object System.Collections.Generic.List[string]
    try {
        $elements = (Get-RootElement).FindAll([System.Windows.Automation.TreeScope]::Subtree, [System.Windows.Automation.Condition]::TrueCondition)
        foreach ($element in $elements) { $n = [string]$element.Current.Name; if (-not [string]::IsNullOrWhiteSpace($n)) { $allNames.Add($n) | Out-Null } }
    } catch {}
    $snapshot = [ordered]@{ ById=$byId; AllText=(($allNames | Select-Object -Unique) -join "`n") }
    $script:Report.TextSnapshots[$Name] = $snapshot
    return $snapshot
}

function Get-AutomationIdCount {
    param([string]$AutomationId)
    $condition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $AutomationId)
    return (Get-RootElement).FindAll([System.Windows.Automation.TreeScope]::Subtree, $condition).Count
}

function Assert-RequiredAutomationIdsUnique {
    $required = @('SettingsButton','ProvinceSelector','CitySelector','DistrictSelector','RefreshIntervalSelector','LanguageCnButton','LanguageEnButton','ForecastStartSelector','ForecastEndSelector','DrawerCollapseButton','DrawerHandle','LocationTitle','WeatherDescription','NearTermForecast','TemperatureText','WarningPanel','RainfallText','HumidityText','PressureText','WindText','LoadingPanel','ErrorPanel','StatusFooter')
    $details = New-Object System.Collections.Generic.List[string]
    $allUnique = $true
    foreach ($id in $required) {
        $count = Get-AutomationIdCount -AutomationId $id
        $details.Add("${id}=$count") | Out-Null
        if ($count -ne 1) { $allUnique = $false }
    }
    $script:Report.AutomationIdUniqueCheck = if ($allUnique) { 'PASS' } else { 'FAIL' }
    Add-Assert -Name 'Required AutomationIds are unique' -Passed $allUnique -Details (($details | ForEach-Object { $_ }) -join '; ')
}
function Wait-UntilText {
    param([scriptblock]$Predicate, [string]$Name, [int]$TimeoutMs = 22000)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    do {
        $snapshot = Get-UiTextSnapshot -Name $Name
        if (& $Predicate $snapshot) { return $snapshot }
        Start-Sleep -Milliseconds 350
    } while ((Get-Date) -lt $deadline)
    throw "Timed out waiting for UI text condition: $Name"
}

function Test-LoadingSnapshot {
    param([object]$Snapshot)
    if ($null -eq $Snapshot) { return $false }
    $loadingText = [string]$Snapshot.ById.LoadingPanel
    $weatherText = [string]$Snapshot.ById.WeatherDescription
    $tempText = [string]$Snapshot.ById.TemperatureText
    $errorText = [string]$Snapshot.ById.ErrorPanel
    return ($loadingText -match '加载|更新|Loading|Updating' -or $weatherText -match '加载|更新|Loading|Updating' -or ($tempText -match '^--' -and [string]::IsNullOrWhiteSpace($errorText)))
}

function Observe-LoadingState {
    param([string]$Name, [int]$TimeoutMs = 2500)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    do {
        $snapshot = Get-UiTextSnapshot -Name $Name
        if (Test-LoadingSnapshot -Snapshot $snapshot) { return $true }
        Start-Sleep -Milliseconds 75
    } while ((Get-Date) -lt $deadline)
    return $false
}
function Click-Element {
    param([System.Windows.Automation.AutomationElement]$Element, [int]$AfterMs = 180)
    if ($null -eq $Element) { throw 'Cannot click null element.' }
    [RealRegionUiSmokeWin32]::SetForegroundWindow($script:Hwnd) | Out-Null
    Start-Sleep -Milliseconds 80
    $rect = $Element.Current.BoundingRectangle
    if ($rect.Width -le 0 -or $rect.Height -le 0) { throw "Element has empty bounding rectangle: $($Element.Current.AutomationId)" }
    $original = New-Object RealRegionUiSmokeWin32+POINT
    $hasOriginal = $false
    try { $hasOriginal = [RealRegionUiSmokeWin32]::GetCursorPos([ref]$original) } catch {}
    $x = [int]($rect.Left + ($rect.Width / 2)); $y = [int]($rect.Top + ($rect.Height / 2))
    [RealRegionUiSmokeWin32]::SetCursorPos($x, $y) | Out-Null
    Start-Sleep -Milliseconds 40
    [RealRegionUiSmokeWin32]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 30
    [RealRegionUiSmokeWin32]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    if ($hasOriginal) { try { [RealRegionUiSmokeWin32]::SetCursorPos($original.X, $original.Y) | Out-Null } catch {} }
    Start-Sleep -Milliseconds $AfterMs
}

function Send-VirtualKey {
    param([byte]$VirtualKey)
    [RealRegionUiSmokeWin32]::keybd_event($VirtualKey, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 20
    [RealRegionUiSmokeWin32]::keybd_event($VirtualKey, 0, 0x0002, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 35
}

function Send-AltDownKey {
    [RealRegionUiSmokeWin32]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 20
    Send-VirtualKey -VirtualKey 0x28
    [RealRegionUiSmokeWin32]::keybd_event(0x12, 0, 0x0002, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
}

function Invoke-ElementAction {
    param([System.Windows.Automation.AutomationElement]$Element, [int]$AfterMs = 180)
    if ($null -eq $Element) { throw 'Cannot invoke null element.' }
    [RealRegionUiSmokeWin32]::SetForegroundWindow($script:Hwnd) | Out-Null
    Start-Sleep -Milliseconds 80
    $invokePattern = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$invokePattern)) {
        try {
            $invokePattern.Invoke()
            Start-Sleep -Milliseconds $AfterMs
            return
        } catch {}
    }
    if (Test-ElementVisible -Element $Element) {
        Click-Element $Element -AfterMs $AfterMs
        return
    }
    try { $Element.SetFocus(); Send-VirtualKey -VirtualKey 0x0D; Start-Sleep -Milliseconds $AfterMs; return } catch {}
    throw "Element cannot be invoked: $($Element.Current.AutomationId)"
}
function Find-VisibleComboListItemByName {
    param([string]$ItemName)
    $desktop = [System.Windows.Automation.AutomationElement]::RootElement
     $condition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)
    $all = $desktop.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
    foreach ($item in $all) {
        $name = [string]$item.Current.Name
        if ($name -eq $ItemName -or $name -like "*$ItemName*") {
            $rect = $item.Current.BoundingRectangle
            if ($rect.Width -gt 0 -and $rect.Height -gt 0) { return $item }
        }
    }
    return $null
}

function Get-CatalogComboIndex {
    param(
        [string]$ComboAutomationId,
        [string]$ItemKey,
        [string]$ParentProvinceKey,
        [string]$ParentCityKey
    )

    if ([string]::IsNullOrWhiteSpace($ItemKey)) { return -1 }
    if ($ComboAutomationId -eq 'ProvinceSelector') {
        $items = @($script:CatalogProvinces)
        for ($i = 0; $i -lt $items.Count; $i++) { if ([string]$items[$i].Key -eq $ItemKey) { return $i } }
        return -1
    }

    $province = @($script:CatalogProvinces | Where-Object { [string]$_.Key -eq $ParentProvinceKey } | Select-Object -First 1)
    if ($null -eq $province -or $province.Count -eq 0) { return -1 }
    $province = $province[0]
    if ($ComboAutomationId -eq 'CitySelector') {
        $items = @($province.Cities)
        for ($i = 0; $i -lt $items.Count; $i++) { if ([string]$items[$i].Key -eq $ItemKey) { return $i } }
        return -1
    }

    $city = @($province.Cities | Where-Object { [string]$_.Key -eq $ParentCityKey } | Select-Object -First 1)
    if ($null -eq $city -or $city.Count -eq 0) { return -1 }
    $city = $city[0]
    if ($ComboAutomationId -eq 'DistrictSelector') {
        $items = @($city.Districts)
        for ($i = 0; $i -lt $items.Count; $i++) { if ([string]$items[$i].Key -eq $ItemKey) { return $i } }
    }
    return -1
}

function Select-ComboByKeyboardIndex {
    param([System.Windows.Automation.AutomationElement]$Combo, [int]$Index)
    if ($Index -lt 0) { throw 'Invalid ComboBox index.' }
    [RealRegionUiSmokeWin32]::SetForegroundWindow($script:Hwnd) | Out-Null
    try { $Combo.SetFocus() } catch {}
    Start-Sleep -Milliseconds 80
    $expandPattern = $null
    if ($Combo.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$expandPattern)) {
        try { $expandPattern.Expand() } catch {}
    } else {
        try { Send-AltDownKey } catch {}
    }
    Start-Sleep -Milliseconds 180
    Send-VirtualKey -VirtualKey 0x24
    Start-Sleep -Milliseconds 35
    for ($i = 0; $i -lt $Index; $i++) { Send-VirtualKey -VirtualKey 0x28 }
    Send-VirtualKey -VirtualKey 0x0D
    Start-Sleep -Milliseconds 240
}
function Invoke-ComboItemSelection {
    param([System.Windows.Automation.AutomationElement]$Element, [string]$ItemName)
    if ($null -eq $Element) { return $false }
    if (Test-ElementVisible -Element $Element) {
        try {
            Click-Element $Element -AfterMs 60
            return $true
        } catch {}
    }
    $selectionPattern = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$selectionPattern)) {
        try {
            $selectionPattern.Select()
            Start-Sleep -Milliseconds 90
            return $true
        } catch {}
    }
    $invokePattern = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$invokePattern)) {
        try {
            $invokePattern.Invoke()
            Start-Sleep -Milliseconds 90
            return $true
        } catch {}
    }
    return $false
}
function Select-ComboItemByName {
    param(
        [string]$ComboAutomationId,
        [string]$ItemName,
        [string]$ItemKey = '',
        [string]$ParentProvinceKey = '',
        [string]$ParentCityKey = ''
    )

    $combo = Find-ElementById -AutomationId $ComboAutomationId -TimeoutMs 6000
    $lastSample = @()
    $index = Get-CatalogComboIndex -ComboAutomationId $ComboAutomationId -ItemKey $ItemKey -ParentProvinceKey $ParentProvinceKey -ParentCityKey $ParentCityKey

    for ($attempt = 1; $attempt -le 4; $attempt++) {
        [RealRegionUiSmokeWin32]::SetForegroundWindow($script:Hwnd) | Out-Null
        try { Send-VirtualKey -VirtualKey 0x1B; Start-Sleep -Milliseconds 100 } catch {}
        try { $combo = Find-ElementById -AutomationId $ComboAutomationId -TimeoutMs 1200; $combo.SetFocus() } catch {}

        $expanded = $false
        $expandPattern = $null
        if ($combo.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$expandPattern)) {
            try { $expandPattern.Expand(); $expanded = $true } catch {}
        }
        if (-not $expanded -and (Test-ElementVisible -Element $combo)) {
            try { Click-Element $combo -AfterMs 100; $expanded = $true } catch {}
        }
        if (-not $expanded) { Start-Sleep -Milliseconds 160; continue }

        $deadline = (Get-Date).AddMilliseconds(2500)
        do {
            $target = Find-VisibleComboListItemByName -ItemName $ItemName
            if ($null -ne $target -and (Invoke-ComboItemSelection -Element $target -ItemName $ItemName)) {
                Start-Sleep -Milliseconds 180
                return
            }
            Start-Sleep -Milliseconds 150
        } while ((Get-Date) -lt $deadline)

        $sample = New-Object System.Collections.Generic.List[string]
        try {
            $desktop = [System.Windows.Automation.AutomationElement]::RootElement
            $condition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)
            $all = $desktop.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
            foreach ($item in $all) {
                $name = [string]$item.Current.Name
                $rect = $item.Current.BoundingRectangle
                if (-not [string]::IsNullOrWhiteSpace($name) -and $rect.Width -gt 0 -and $rect.Height -gt 0) { $sample.Add($name) | Out-Null }
                if ($sample.Count -ge 18) { break }
            }
        } catch {}
        $lastSample = @($sample)
        if ($index -ge 0) {
            try {
                Select-ComboByKeyboardIndex -Combo $combo -Index $index
                return
            } catch {
                $lastSample = @($lastSample + "keyboard-index-$index failed: $($_.Exception.Message)")
            }
        }
        try { Send-VirtualKey -VirtualKey 0x1B; Start-Sleep -Milliseconds 220 } catch {}
    }

    throw "Combo item '$ItemName' not found for $ComboAutomationId after retries. Visible list sample: $($lastSample -join ' | ')"
}
function Dismiss-TransientUi {
    param([int]$WaitMs = 1000)
    try { Send-VirtualKey -VirtualKey 0x1B; Start-Sleep -Milliseconds 120; Send-VirtualKey -VirtualKey 0x1B } catch {}
    try {
        $neutral = Find-ElementById -AutomationId 'LocationTitle' -TimeoutMs 700
        if ($null -ne $neutral) { try { $neutral.SetFocus() } catch {} }
    } catch {}
    $original = New-Object RealRegionUiSmokeWin32+POINT
    $hasOriginal = $false
    try { $hasOriginal = [RealRegionUiSmokeWin32]::GetCursorPos([ref]$original) } catch {}
    try {
        $rect = Get-WindowRectForHwnd -Hwnd $script:Hwnd
        $virtual = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $x = [Math]::Min($virtual.Right - 2, [Math]::Max($virtual.Left + 2, $rect.Right + 24))
        $y = [Math]::Min($virtual.Bottom - 2, [Math]::Max($virtual.Top + 2, $rect.Top + 24))
        [RealRegionUiSmokeWin32]::SetCursorPos([int]$x, [int]$y) | Out-Null
    } catch {}
    Start-Sleep -Milliseconds $WaitMs
    return [pscustomobject]@{ HasOriginal=$hasOriginal; X=$original.X; Y=$original.Y }
}

function Restore-CursorPosition {
    param([object]$CursorState)
    if ($null -ne $CursorState -and $CursorState.HasOriginal) {
        try { [RealRegionUiSmokeWin32]::SetCursorPos([int]$CursorState.X, [int]$CursorState.Y) | Out-Null } catch {}
    }
}

function Save-WindowScreenshot {
    param([string]$FileName)
    $cursorState = Dismiss-TransientUi -WaitMs 900
    $rect = Get-WindowRectForHwnd -Hwnd $script:Hwnd
    $virtual = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $left = [Math]::Max($rect.Left, $virtual.Left); $top = [Math]::Max($rect.Top, $virtual.Top)
    $right = [Math]::Min($rect.Right, $virtual.Right); $bottom = [Math]::Min($rect.Bottom, $virtual.Bottom)
    $width = [Math]::Max(1, $right - $left); $height = [Math]::Max(1, $bottom - $top)
    $path = Join-Path $OutputDir $FileName
    $bmp = New-Object System.Drawing.Bitmap $width, $height
    $graphics = [System.Drawing.Graphics]::FromImage($bmp)
    try { $graphics.CopyFromScreen($left, $top, 0, 0, $bmp.Size); $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png) }
    finally { $graphics.Dispose(); $bmp.Dispose(); Restore-CursorPosition -CursorState $cursorState }
    $item = Get-Item -LiteralPath $path
    Add-Assert -Name "Screenshot $FileName exists" -Passed ($item.Length -gt 0) -Details $path
    $script:Report.Screenshots[$FileName] = $path
}

function Select-RepresentativeRegions {
    param([object[]]$Records, [int]$Limit = $RegionCount)
    $selected = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    function Add-Group([object[]]$Items, [string]$Tag, [int]$Limit) {
        $added = 0
        foreach ($item in $Items) {
            if ($added -ge $Limit) { break }
            if ($seen.ContainsKey($item.LocationKey)) { continue }
            $item | Add-Member -NotePropertyName UiSmokeTag -NotePropertyValue $Tag -Force
            $selected.Add($item) | Out-Null
            $seen[$item.LocationKey] = $true
            $added++
        }
        $script:Report.Coverage[$Tag] = $added
    }
    Add-Group -Items @($Records | Sort-Object @{Expression={$_.DisplayNameZh.Length};Descending=$true}) -Tag 'long-name' -Limit 4
    Add-Group -Items @($Records | Where-Object { [double]$_.CurrentPrecipitation -eq 0 -and [double]$_.CurrentRain -eq 0 }) -Tag 'dry-current' -Limit 4
    Add-Group -Items @($Records | Where-Object { [double]$_.CurrentPrecipitation -gt 0 -or [double]$_.CurrentRain -gt 0 -or (-not [string]::IsNullOrWhiteSpace($_.NearTermForecast) -and $_.NearTermForecast -notmatch 'No near-term') }) -Tag 'rain-or-forecast' -Limit 4
    Add-Group -Items @($Records | Where-Object { [int]$_.Attempts -gt 1 -or $_.DataSource -ne 'Open-Meteo' }) -Tag 'retry-or-fallback' -Limit 4
    Add-Group -Items @($Records | Group-Object ProvinceKey,CityKey | Where-Object { $_.Count -gt 3 } | Select-Object -First 1 | ForEach-Object { $_.Group | Sort-Object DistrictKey }) -Tag 'similar-name' -Limit 4
    Add-Group -Items @($Records | Sort-Object @{Expression={$_.DisplayNameEn.Length};Descending=$true}) -Tag 'english-mode' -Limit 4
    Add-Group -Items @($Records) -Tag 'fill' -Limit ([Math]::Max(0, $Limit - $selected.Count))
    return @($selected | Select-Object -First $Limit)
}

function Start-LoadingObserver {
    $script:LoadingObserverPath = Join-Path $OutputDir 'loading-observer.json'
    $script:LoadingObserverStopPath = Join-Path $OutputDir 'loading-observer.stop'
    $script:LoadingObserverScriptPath = Join-Path $OutputDir 'loading-observer.ps1'
    Remove-Item -LiteralPath $script:LoadingObserverPath,$script:LoadingObserverStopPath,$script:LoadingObserverScriptPath -Force -ErrorAction SilentlyContinue
    $observerScript = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('cGFyYW0oW2xvbmddJEh3bmRWYWx1ZSwgW3N0cmluZ10kT3V0UGF0aCwgW3N0cmluZ10kU3RvcFBhdGgpCiRFcnJvckFjdGlvblByZWZlcmVuY2UgPSAnU2lsZW50bHlDb250aW51ZScKQWRkLVR5cGUgLUFzc2VtYmx5TmFtZSBVSUF1dG9tYXRpb25DbGllbnQKQWRkLVR5cGUgLUFzc2VtYmx5TmFtZSBVSUF1dG9tYXRpb25UeXBlcwpmdW5jdGlvbiBHZXQtRWxlbWVudFRleHRCeUlkIHsKICAgIHBhcmFtKFtTeXN0ZW0uV2luZG93cy5BdXRvbWF0aW9uLkF1dG9tYXRpb25FbGVtZW50XSRSb290LCBbc3RyaW5nXSRBdXRvbWF0aW9uSWQpCiAgICBpZiAoJG51bGwgLWVxICRSb290KSB7IHJldHVybiAnJyB9CiAgICAkY29uZGl0aW9uID0gTmV3LU9iamVjdCBTeXN0ZW0uV2luZG93cy5BdXRvbWF0aW9uLlByb3BlcnR5Q29uZGl0aW9uKFtTeXN0ZW0uV2luZG93cy5BdXRvbWF0aW9uLkF1dG9tYXRpb25FbGVtZW50XTo6QXV0b21hdGlvbklkUHJvcGVydHksICRBdXRvbWF0aW9uSWQpCiAgICAkZWxlbWVudCA9ICRSb290LkZpbmRGaXJzdChbU3lzdGVtLldpbmRvd3MuQXV0b21hdGlvbi5UcmVlU2NvcGVdOjpTdWJ0cmVlLCAkY29uZGl0aW9uKQogICAgaWYgKCRudWxsIC1lcSAkZWxlbWVudCkgeyByZXR1cm4gJycgfQogICAgJHZhbHVlUGF0dGVybiA9ICRudWxsCiAgICBpZiAoJGVsZW1lbnQuVHJ5R2V0Q3VycmVudFBhdHRlcm4oW1N5c3RlbS5XaW5kb3dzLkF1dG9tYXRpb24uVmFsdWVQYXR0ZXJuXTo6UGF0dGVybiwgW3JlZl0kdmFsdWVQYXR0ZXJuKSkgewogICAgICAgIGlmICgtbm90IFtzdHJpbmddOjpJc051bGxPcldoaXRlU3BhY2UoJHZhbHVlUGF0dGVybi5DdXJyZW50LlZhbHVlKSkgeyByZXR1cm4gW3N0cmluZ10kdmFsdWVQYXR0ZXJuLkN1cnJlbnQuVmFsdWUgfQogICAgfQogICAgcmV0dXJuIFtzdHJpbmddJGVsZW1lbnQuQ3VycmVudC5OYW1lCn0KJHNhbXBsZXMgPSBOZXctT2JqZWN0IFN5c3RlbS5Db2xsZWN0aW9ucy5HZW5lcmljLkxpc3Rbb2JqZWN0XQokY291bnQgPSAwCiRkZWFkbGluZSA9IChHZXQtRGF0ZSkuQWRkTWludXRlcygzMCkKd2hpbGUgKChHZXQtRGF0ZSkgLWx0ICRkZWFkbGluZSAtYW5kIC1ub3QgKFRlc3QtUGF0aCAtTGl0ZXJhbFBhdGggJFN0b3BQYXRoKSkgewogICAgdHJ5IHsKICAgICAgICAkcm9vdCA9IFtTeXN0ZW0uV2luZG93cy5BdXRvbWF0aW9uLkF1dG9tYXRpb25FbGVtZW50XTo6RnJvbUhhbmRsZShbSW50UHRyXSRId25kVmFsdWUpCiAgICAgICAgJGxvYWRpbmcgPSBHZXQtRWxlbWVudFRleHRCeUlkIC1Sb290ICRyb290IC1BdXRvbWF0aW9uSWQgJ0xvYWRpbmdQYW5lbCcKICAgICAgICAkd2VhdGhlciA9IEdldC1FbGVtZW50VGV4dEJ5SWQgLVJvb3QgJHJvb3QgLUF1dG9tYXRpb25JZCAnV2VhdGhlckRlc2NyaXB0aW9uJwogICAgICAgICR0ZW1wID0gR2V0LUVsZW1lbnRUZXh0QnlJZCAtUm9vdCAkcm9vdCAtQXV0b21hdGlvbklkICdUZW1wZXJhdHVyZVRleHQnCiAgICAgICAgJGVycm9yVGV4dCA9IEdldC1FbGVtZW50VGV4dEJ5SWQgLVJvb3QgJHJvb3QgLUF1dG9tYXRpb25JZCAnRXJyb3JQYW5lbCcKICAgICAgICAkaXNMb2FkaW5nID0gKCRsb2FkaW5nIC1tYXRjaCAn5Yqg6L29fOabtOaWsHxMb2FkaW5nfFVwZGF0aW5nJyAtb3IgJHdlYXRoZXIgLW1hdGNoICfliqDovb185pu05pawfExvYWRpbmd8VXBkYXRpbmcnIC1vciAoJHRlbXAgLW1hdGNoICdeLS0nIC1hbmQgW3N0cmluZ106OklzTnVsbE9yV2hpdGVTcGFjZSgkZXJyb3JUZXh0KSkpCiAgICAgICAgaWYgKCRpc0xvYWRpbmcpIHsKICAgICAgICAgICAgJGNvdW50KysKICAgICAgICAgICAgaWYgKCRzYW1wbGVzLkNvdW50IC1sdCAyMCkgewogICAgICAgICAgICAgICAgJHNhbXBsZXMuQWRkKFtwc2N1c3RvbW9iamVjdF1AeyBBdD0oR2V0LURhdGUpLlRvU3RyaW5nKCdISDptbTpzcy5mZmYnKTsgTG9hZGluZ1BhbmVsPSRsb2FkaW5nOyBXZWF0aGVyRGVzY3JpcHRpb249JHdlYXRoZXI7IFRlbXBlcmF0dXJlVGV4dD0kdGVtcDsgRXJyb3JQYW5lbD0kZXJyb3JUZXh0IH0pIHwgT3V0LU51bGwKICAgICAgICAgICAgfQogICAgICAgIH0KICAgIH0gY2F0Y2gge30KICAgIFN0YXJ0LVNsZWVwIC1NaWxsaXNlY29uZHMgNzUKfQpbcHNjdXN0b21vYmplY3RdQHsgQ291bnQ9JGNvdW50OyBTYW1wbGVzPUAoJHNhbXBsZXMpIH0gfCBDb252ZXJ0VG8tSnNvbiAtRGVwdGggNiB8IFNldC1Db250ZW50IC1MaXRlcmFsUGF0aCAkT3V0UGF0aCAtRW5jb2RpbmcgVVRGOA=='))
    $observerScript | Set-Content -LiteralPath $script:LoadingObserverScriptPath -Encoding UTF8
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',$script:LoadingObserverScriptPath,[string]$script:Hwnd.ToInt64(),$script:LoadingObserverPath,$script:LoadingObserverStopPath)
    $script:LoadingObserverProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -PassThru -WindowStyle Hidden
}

function Stop-LoadingObserver {
    if ($null -eq $script:LoadingObserverProcess) { return 0 }
    try { New-Item -ItemType File -Path $script:LoadingObserverStopPath -Force | Out-Null } catch {}
    try { $script:LoadingObserverProcess.WaitForExit(8000) | Out-Null } catch {}
    if (-not $script:LoadingObserverProcess.HasExited) {
        try { Stop-Process -Id $script:LoadingObserverProcess.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
    $script:LoadingObserverProcess = $null
    if (Test-Path -LiteralPath $script:LoadingObserverPath) {
        try {
            $observer = Get-Content -LiteralPath $script:LoadingObserverPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $script:Report.LoadingObserverSamples = @($observer.Samples)
            return [int]$observer.Count
        } catch {}
    }
    return 0
}
function Start-WidgetApp {
    $initialSettings = [ordered]@{ Language='zh'; ProvinceKey='Guangdong'; CityKey='Shenzhen'; DistrictKey='Longhua'; RefreshSeconds=60; DrawerEdge='Left'; DrawerExpanded=$true; DrawerTop=$null; DrawerScreenDeviceName=$null; SavedAt=(Get-Date).ToString('s') }
    $initialSettings | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDir 'LonghuaWeatherWidget.ui-smoke.settings.json') -Encoding UTF8
    $stderrPath = Join-Path $OutputDir 'widget.stderr.txt'; $stdoutPath = Join-Path $OutputDir 'widget.stdout.txt'
    $appPath = Join-Path $script:ScriptRoot 'LonghuaWeatherWidget.ps1'
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',$appPath,'-NoTopMost','-UiSmokeMode','-UiFixture','Live','-UiSmokeOutput',$OutputDir,'-UiSmokeDelayMs','650','-RefreshSeconds','60')
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -PassThru -WindowStyle Hidden -RedirectStandardError $stderrPath -RedirectStandardOutput $stdoutPath
    $script:Process = $p; $script:Report.Pid = $p.Id
    $script:Hwnd = Find-WindowByPid -ProcessId $p.Id -TimeoutMs ($TimeoutSeconds * 1000)
    $script:Report.Hwnd = ('0x{0:X}' -f $script:Hwnd.ToInt64())
    Add-Assert -Name 'Found target HWND' -Passed ($script:Hwnd -ne [IntPtr]::Zero) -Details $script:Report.Hwnd
    $rect = Get-WindowRectForHwnd -Hwnd $script:Hwnd
    Add-Assert -Name 'Window rect has size' -Passed ($rect.Width -gt 200 -and $rect.Height -gt 200) -Details ("{0}x{1}" -f $rect.Width,$rect.Height)
}

function Close-WidgetAppGracefully {
    if ($script:Hwnd -ne [IntPtr]::Zero) { [RealRegionUiSmokeWin32]::PostMessage($script:Hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null }
    if ($null -ne $script:Process) {
        try { $script:Process.WaitForExit(4000) | Out-Null } catch {}
        if (-not $script:Process.HasExited) { Stop-Process -Id $script:Process.Id -Force -ErrorAction SilentlyContinue }
    }
}

function Restore-Settings {
    if ($script:SettingsHadFile) { Set-Content -LiteralPath $script:SettingsPath -Value $script:SettingsBackup -Encoding UTF8 }
    elseif (Test-Path -LiteralPath $script:SettingsPath) { Remove-Item -LiteralPath $script:SettingsPath -Force }
    $script:Report.SettingsRestored = $true
}

function Invoke-Step {
    param([string]$Name, [scriptblock]$Body)
    $script:CurrentScenario = $Name
    try { & $Body } catch { $script:HadFailure = $true; $script:Report.Failures += [pscustomobject]@{Scenario=$Name;Name='Exception';Passed=$false;Details=$_.Exception.Message} }
}

function Write-Reports {
    Set-ReportValue -Key 'CompletedAt' -Value (Get-Date).ToString('s')
    $stderrPath = Join-Path $OutputDir 'widget.stderr.txt'
    $script:Report.StdErr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8 } else { '' }
    $jsonPath = Join-Path $OutputDir 'real-ui-smoke.json'
    $mdPath = Join-Path $OutputDir 'real-ui-smoke.md'
    $script:Report.ScreenshotCount = $script:Report.Screenshots.Count
    $script:Report.Result = if ($script:HadFailure) { 'FAIL' } elseif ($script:Report.ActualSwitchAttemptCount -ne $script:Report.SelectedRegionCount -or $script:Report.ActualSwitchSuccessCount -ne $script:Report.SelectedRegionCount) { 'FAIL' } else { 'PASS' }
    $script:Report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# Real Region UI Smoke') | Out-Null
    $lines.Add("- Result: $($script:Report.Result)") | Out-Null
    $lines.Add("- Region smoke report: $RegionSmokeReportDir") | Out-Null
    $lines.Add("- Tested regions: $($script:Report.SelectedRegions.Count)") | Out-Null
    $lines.Add("- Actual switch attempts: $($script:Report.ActualSwitchAttemptCount)") | Out-Null
    $lines.Add("- Actual switch successes: $($script:Report.ActualSwitchSuccessCount)") | Out-Null
    $lines.Add("- Loading observed: $($script:Report.LoadingStateObservedCount)") | Out-Null
    $lines.Add("- AutomationId unique check: $($script:Report.AutomationIdUniqueCheck)") | Out-Null
    $lines.Add("- Visual check: $($script:Report.VisualCheck)") | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('## Coverage') | Out-Null
    foreach ($key in $script:Report.Coverage.Keys) { $lines.Add("- ${key}: $($script:Report.Coverage[$key])") | Out-Null }
    $lines.Add('') | Out-Null
    $lines.Add('## Screenshots') | Out-Null
    foreach ($key in $script:Report.Screenshots.Keys) { $lines.Add("- ${key}: $($script:Report.Screenshots[$key])") | Out-Null }
    $lines.Add('') | Out-Null
    $lines.Add('## Failures') | Out-Null
    if ($script:Report.Failures.Count -eq 0) { $lines.Add('- None') | Out-Null } else { foreach ($f in $script:Report.Failures) { $lines.Add("- [$($f.Scenario)] $($f.Name): $($f.Details)") | Out-Null } }
    $lines | Set-Content -LiteralPath $mdPath -Encoding UTF8
}

function New-ContactSheet {
    param([string[]]$ImagePaths, [string]$OutputPath)
    $valid = @($ImagePaths | Where-Object { Test-Path -LiteralPath $_ })
    if ($valid.Count -eq 0) { return $null }
    $thumbW = 320; $thumbH = 220; $pad = 12
    $cols = [Math]::Min(4, [Math]::Max(1, [int][Math]::Ceiling([Math]::Sqrt($valid.Count))))
    $rows = [int][Math]::Ceiling($valid.Count / $cols)
    $sheetW = [int](($cols * ($thumbW + $pad)) + $pad)
    $sheetH = [int](($rows * ($thumbH + $pad)) + $pad)
    $sheet = New-Object System.Drawing.Bitmap -ArgumentList $sheetW, $sheetH
    $g = [System.Drawing.Graphics]::FromImage($sheet)
    try {
        $g.Clear([System.Drawing.Color]::White)
        for ($i = 0; $i -lt $valid.Count; $i++) {
            $img = [System.Drawing.Image]::FromFile($valid[$i])
            try {
                $ratio = [Math]::Min($thumbW / $img.Width, $thumbH / $img.Height)
                $w = [int]($img.Width * $ratio); $h = [int]($img.Height * $ratio)
                $x = $pad + (($i % $cols) * ($thumbW + $pad)) + [int](($thumbW - $w) / 2)
                $y = $pad + ([int][Math]::Floor($i / $cols) * ($thumbH + $pad)) + [int](($thumbH - $h) / 2)
                $g.DrawImage($img, $x, $y, $w, $h)
            } finally { $img.Dispose() }
        }
        $sheet.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $g.Dispose(); $sheet.Dispose() }
    return $OutputPath
}

function Set-ReportValue {
    param([string]$Key, [object]$Value)
    if ($script:Report.Contains($Key)) { $script:Report.Remove($Key) }
    $script:Report.Add($Key, $Value)
}

function Invoke-ChunkedRealWpfSmoke {
    $script:Report.ChunkMode = $true
    $chunkRoot = Join-Path $OutputDir 'chunks'
    New-Item -ItemType Directory -Path $chunkRoot -Force | Out-Null
    $scriptPath = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    $chunkRows = New-Object System.Collections.Generic.List[object]
    $allFailures = New-Object System.Collections.Generic.List[object]
    $allAssertions = New-Object System.Collections.Generic.List[object]
    $allSelected = New-Object System.Collections.Generic.List[object]
    $allScreenshots = [ordered]@{}
    $chunkIndex = 0
    for ($offset = 0; $offset -lt $RegionCount; $offset += $ChunkSize) {
        $chunkIndex++
        $count = [Math]::Min($ChunkSize, $RegionCount - $offset)
        $chunkDir = Join-Path $chunkRoot ('chunk-{0:D2}-offset-{1:D2}' -f $chunkIndex, $offset)
        New-Item -ItemType Directory -Path $chunkDir -Force | Out-Null
        $stdout = Join-Path $chunkDir 'chunk.stdout.txt'
        $stderr = Join-Path $chunkDir 'chunk.stderr.txt'
        $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptPath,'-RegionSmokeReportDir',$RegionSmokeReportDir,'-OutputDir',$chunkDir,'-RegionCount',[string]$count,'-RegionOffset',[string]$offset,'-ChunkSize',[string]$ChunkSize,'-TimeoutSeconds',[string]$TimeoutSeconds,'-NoChunk')
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $jsonPath = Join-Path $chunkDir 'real-ui-smoke.json'
        $chunkReport = $null
        if (Test-Path -LiteralPath $jsonPath) { $chunkReport = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json }
        $chunkRow = [pscustomobject]@{ Chunk=$chunkIndex; Offset=$offset; Count=$count; ExitCode=$p.ExitCode; OutputDir=$chunkDir; Result=if($chunkReport){$chunkReport.Result}else{'NO_REPORT'}; Attempts=if($chunkReport){$chunkReport.ActualSwitchAttemptCount}else{0}; Successes=if($chunkReport){$chunkReport.ActualSwitchSuccessCount}else{0}; Failures=if($chunkReport){@($chunkReport.Failures).Count}else{1}; Pid=if($chunkReport){$chunkReport.Pid}else{$null}; Hwnd=if($chunkReport){$chunkReport.Hwnd}else{$null} }
        $chunkRows.Add($chunkRow) | Out-Null
        if ($chunkReport) {
            foreach ($r in @($chunkReport.SelectedRegions)) { $allSelected.Add($r) | Out-Null }
            foreach ($a in @($chunkReport.Assertions)) { $allAssertions.Add($a) | Out-Null }
            foreach ($f in @($chunkReport.Failures)) { $allFailures.Add([pscustomobject]@{ Chunk=$chunkIndex; Scenario=$f.Scenario; Name=$f.Name; Passed=$false; Details=$f.Details }) | Out-Null }
            foreach ($prop in $chunkReport.Screenshots.PSObject.Properties) { $allScreenshots[('chunk-{0:D2}-{1}' -f $chunkIndex, $prop.Name)] = $prop.Value }
        } else {
            $allFailures.Add([pscustomobject]@{ Chunk=$chunkIndex; Scenario='Chunk'; Name='NO_REPORT'; Passed=$false; Details="No chunk report. ExitCode=$($p.ExitCode)" }) | Out-Null
        }
    }
    Set-ReportValue -Key 'Chunks' -Value $chunkRows.ToArray()
    Set-ReportValue -Key 'SelectedRegions' -Value $allSelected.ToArray()
    Set-ReportValue -Key 'SelectedRegionCount' -Value $allSelected.Count
    Set-ReportValue -Key 'ActualSwitchAttemptCount' -Value ($chunkRows | Measure-Object Attempts -Sum).Sum
    Set-ReportValue -Key 'ActualSwitchSuccessCount' -Value ($chunkRows | Measure-Object Successes -Sum).Sum
    Set-ReportValue -Key 'ActualSwitchFailureCount' -Value $allFailures.Count
    Set-ReportValue -Key 'LoadingStateObservedCount' -Value 0
    Set-ReportValue -Key 'Assertions' -Value $allAssertions.ToArray()
    Set-ReportValue -Key 'Failures' -Value $allFailures.ToArray()
    Set-ReportValue -Key 'Screenshots' -Value $allScreenshots
    Set-ReportValue -Key 'ScreenshotCount' -Value $allScreenshots.Count
    $allChunksPassed = (@($chunkRows | Where-Object { $_.Result -eq 'PASS' }).Count -eq $chunkRows.Count)
    $automationIdUniqueCheck = if ($allChunksPassed) { 'PASS' } else { 'PARTIAL' }
    Set-ReportValue -Key 'AutomationIdUniqueCheck' -Value $automationIdUniqueCheck
    Set-ReportValue -Key 'VisualCheck' -Value 'PENDING_VISUAL_REVIEW'
    $contactSheet = Join-Path $OutputDir 'contact-sheet.png'
    New-ContactSheet -ImagePaths @($allScreenshots.Values) -OutputPath $contactSheet | Out-Null
    if (Test-Path -LiteralPath $contactSheet) { $script:Report.Screenshots['contact-sheet.png'] = $contactSheet }
    Set-ReportValue -Key 'ScreenshotCount' -Value $script:Report.Screenshots.Count
    $chunkedResult = if ($script:Report['ActualSwitchSuccessCount'] -eq $RegionCount -and $allFailures.Count -eq 0) { 'PASS_CHUNKED_REAL_WPF' } else { 'FAIL' }
    Set-ReportValue -Key 'Result' -Value $chunkedResult
    Set-ReportValue -Key 'CompletedAt' -Value (Get-Date).ToString('s')
    $script:Report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputDir 'real-ui-smoke.json') -Encoding UTF8
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# Real Region UI Smoke') | Out-Null
    $lines.Add("- Result: $($script:Report.Result)") | Out-Null
    $lines.Add("- Chunk mode: true") | Out-Null
    $lines.Add("- Chunks: $($chunkRows.Count)") | Out-Null
    $lines.Add("- Tested regions: $($script:Report.SelectedRegionCount)") | Out-Null
    $lines.Add("- Actual switch attempts: $($script:Report.ActualSwitchAttemptCount)") | Out-Null
    $lines.Add("- Actual switch successes: $($script:Report.ActualSwitchSuccessCount)") | Out-Null
    $lines.Add("- Failures: $(@($script:Report.Failures).Count)") | Out-Null
    $lines.Add("- Screenshots: $($script:Report.Screenshots.Count)") | Out-Null
    $lines.Add("- Contact sheet: $contactSheet") | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('## Chunks') | Out-Null
    foreach ($c in $chunkRows) { $lines.Add("- chunk $($c.Chunk): result=$($c.Result), attempts=$($c.Attempts), successes=$($c.Successes), failures=$($c.Failures), dir=$($c.OutputDir)") | Out-Null }
    $lines.Add('') | Out-Null
    $lines.Add('## Failures') | Out-Null
    if ($allFailures.Count -eq 0) { $lines.Add('- None') | Out-Null } else { foreach ($f in $allFailures) { $lines.Add("- [chunk $($f.Chunk)] [$($f.Scenario)] $($f.Name): $($f.Details)") | Out-Null } }
    $lines | Set-Content -LiteralPath (Join-Path $OutputDir 'real-ui-smoke.md') -Encoding UTF8
    $visual = [ordered]@{ screenshot_count_seen=$script:Report.Screenshots.Count; all_images_visible=$null; tooltip_artifacts=$null; focus_artifacts=$null; clipping_detected=$null; footer_metrics_complete=$null; english_title_complete=$null; drawer_handles_pass=$null; service_failure_state_clear=$null; major_issues=@('PENDING_VISUAL_REVIEW'); verdict='PENDING_VISUAL_REVIEW' }
    $visual | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDir 'visual-review.json') -Encoding UTF8
    $script:Report | Select-Object Result,@{Name='Chunks';Expression={$_.Chunks.Count}},@{Name='Regions';Expression={$_.SelectedRegionCount}},@{Name='Screenshots';Expression={$_.Screenshots.Count}},@{Name='Failures';Expression={$_.Failures.Count}} | Format-List
    if ($script:Report.Result -eq 'PASS_CHUNKED_REAL_WPF') { exit 0 } else { exit 1 }
}
$csvPath = Join-Path $RegionSmokeReportDir 'weather-smoke-200.csv'
if (-not (Test-Path -LiteralPath $csvPath)) { throw "weather-smoke-200.csv not found: $csvPath" }
$records = @(Import-Csv -LiteralPath $csvPath | Where-Object { $_.Category -in @('PASS','RETRY_PASS') })
if ($RegionCount -gt $ChunkSize -and -not $NoChunk) { Invoke-ChunkedRealWpfSmoke }
$selectionLimit = [Math]::Max($RegionCount, $RegionOffset + $RegionCount)
$targets = @(Select-RepresentativeRegions -Records $records -Limit $selectionLimit | Select-Object -Skip $RegionOffset -First $RegionCount)
$script:Report.SelectedRegions = @($targets | Select-Object ProvinceKey,CityKey,DistrictKey,LocationKey,DisplayNameZh,DisplayNameEn,UiSmokeTag,CurrentDisplayText,NearTermForecast,Attempts,DataSource)
$script:Report.SelectedRegionCount = $script:Report.SelectedRegions.Count

try {
    Start-WidgetApp
    Invoke-Step 'Open settings' {
        Wait-UntilText -Name 'initial-load' -TimeoutMs 24000 -Predicate { param($s) $s.ById.LocationTitle -ne '<missing>' -and ($s.ById.TemperatureText -notmatch '^--' -or $s.ById.ErrorPanel -notin @('', '<missing>') -or $s.ById.WeatherDescription -notmatch '加载中|Loading|Updating') } | Out-Null
        Invoke-ElementAction (Find-ElementById -AutomationId 'SettingsButton') -AfterMs 350
        try { Wait-ElementVisibleById -AutomationId 'ProvinceSelector' -TimeoutMs 2500 | Out-Null } catch { Invoke-ElementAction (Find-ElementById -AutomationId 'SettingsButton') -AfterMs 350; Wait-ElementVisibleById -AutomationId 'ProvinceSelector' -TimeoutMs 3500 | Out-Null }
        Assert-RequiredAutomationIdsUnique
        foreach ($id in @('SettingsButton','ProvinceSelector','CitySelector','DistrictSelector','RefreshIntervalSelector','LanguageCnButton','LanguageEnButton','ForecastStartSelector','ForecastEndSelector','DrawerCollapseButton','DrawerHandle','LocationTitle','WeatherDescription','NearTermForecast','TemperatureText','WarningPanel','RainfallText','HumidityText','PressureText','WindText','LoadingPanel','ErrorPanel','StatusFooter')) { Find-ElementById -AutomationId $id -TimeoutMs 5000 | Out-Null; Assert-AutomationIdUnique -AutomationId $id }
        $initial = Get-UiTextSnapshot -Name 'automation-id-initial'
        Add-Assert -Name 'LoadingPanel is not weather description' -Passed ($initial.ById.LoadingPanel -ne $initial.ById.WeatherDescription) -Details ("loading={0};weather={1}" -f $initial.ById.LoadingPanel,$initial.ById.WeatherDescription)
        Add-Assert -Name 'ErrorPanel is not status footer' -Passed ($initial.ById.ErrorPanel -ne $initial.ById.StatusFooter) -Details ("error={0};footer={1}" -f $initial.ById.ErrorPanel,$initial.ById.StatusFooter)
        Save-WindowScreenshot '00-initial-settings.png'
    }

    $currentProvince = 'Guangdong'; $currentCity = 'Shenzhen'; $currentDistrict = 'Longhua'
    $i = 0; $script:loadingObserved = 0
    foreach ($region in $targets) {
        $i++
        $beforeFailureCount = @($script:Report.Failures).Count
        $script:Report.ActualSwitchAttemptCount++
        Invoke-Step ("Region {0:D2} {1}" -f $i, $region.LocationKey) {
            $parts = @($region.DisplayNameZh -split '\s*/\s*')
            if ($parts.Count -lt 3) { throw "Cannot parse DisplayNameZh: $($region.DisplayNameZh)" }
            $provinceName = $parts[0]; $cityName = $parts[1]; $districtName = $parts[2]
            $currentProvince = ''; $currentCity = ''; $currentDistrict = ''
            if ($currentProvince -ne $region.ProvinceKey) {
                Select-ComboItemByName -ComboAutomationId 'ProvinceSelector' -ItemName $provinceName -ItemKey $region.ProvinceKey
                Wait-UntilText -Name ("province-$i") -TimeoutMs 24000 -Predicate { param($s) ($s.ById.LocationTitle -like "*$provinceName*" -or $s.ById.ProvinceSelector -like "*$provinceName*") } | Out-Null
                $currentProvince = $region.ProvinceKey; $currentCity = ''; $currentDistrict = ''
            }
            if ($currentCity -ne $region.CityKey) {
                Select-ComboItemByName -ComboAutomationId 'CitySelector' -ItemName $cityName -ItemKey $region.CityKey -ParentProvinceKey $region.ProvinceKey
                Wait-UntilText -Name ("city-$i") -TimeoutMs 24000 -Predicate { param($s) ($s.ById.LocationTitle -like "*$cityName*" -or $s.ById.CitySelector -like "*$cityName*") } | Out-Null
                $currentCity = $region.CityKey; $currentDistrict = ''
            }
            if ($currentDistrict -ne $region.DistrictKey) {
                Select-ComboItemByName -ComboAutomationId 'DistrictSelector' -ItemName $districtName -ItemKey $region.DistrictKey -ParentProvinceKey $region.ProvinceKey -ParentCityKey $region.CityKey
                if (Observe-LoadingState -Name ("loading-$i") -TimeoutMs 2500) { $script:loadingObserved++ }
                $currentDistrict = $region.DistrictKey
            }
            $final = Wait-UntilText -Name ("final-$i") -TimeoutMs 30000 -Predicate { param($s) ($s.ById.LocationTitle -like "*$districtName*") -and ($s.ById.WeatherDescription -notmatch '加载中|Loading') -and (($s.ById.TemperatureText -notmatch '^--') -or ($s.ById.ErrorPanel -notin @('', '<missing>'))) }
            Add-Assert -Name 'Title matches target district' -Passed ($final.ById.LocationTitle -like "*$districtName*") -Details $final.ById.LocationTitle
            Add-Assert -Name 'Loaded data or explicit error state' -Passed (($final.ById.TemperatureText -notmatch '^--') -or ($final.ById.ErrorPanel -notin @('', '<missing>'))) -Details ("temp={0};error={1}" -f $final.ById.TemperatureText,$final.ById.ErrorPanel)
            Add-Assert -Name 'Weather text clean' -Passed ($final.ById.WeatherDescription -notmatch '(?<![A-Za-z0-9_])(null|undefined|NaN|Infinity)(?![A-Za-z0-9_])|System\.Object\[\]|\{[A-Za-z0-9_]+\}|Exception|Cannot bind') -Details $final.ById.WeatherDescription
            Add-Assert -Name 'No current rainstorm false positive' -Passed (-not ($region.CurrentPrecipitation -eq '0' -and $region.CurrentRain -eq '0' -and $final.ById.WeatherDescription -match '正在暴雨|当前暴雨|现在暴雨')) -Details $final.ById.WeatherDescription
            Add-Assert -Name 'Warning panel not official warning for model tip' -Passed ($final.ById.WarningPanel -notmatch '黄色预警|橙色预警|红色预警') -Details $final.ById.WarningPanel
            Add-Assert -Name 'Near term separated' -Passed ($final.ById.NearTermForecast -ne '<missing>' -and $final.ById.NearTermForecast -notmatch 'System\.Object') -Details $final.ById.NearTermForecast
            Save-WindowScreenshot ("region-{0:D2}.png" -f $i)
        }
        if ($script:Report.Failures.Count -eq $beforeFailureCount) { $script:Report.ActualSwitchSuccessCount++ } else { $script:Report.ActualSwitchFailureCount++ }
    }
    $script:Report.LoadingStateObservedCount = [int]$script:loadingObserved
    Add-Assert -Name 'Loading state observed during at least one real switch' -Passed ($script:loadingObserved -gt 0) -Details ("observed=$script:loadingObserved")

    Invoke-Step 'English mode and drawer' {
        Invoke-ElementAction (Find-ElementById -AutomationId 'LanguageEnButton') -AfterMs 500
        $en = Wait-UntilText -Name 'english-final' -TimeoutMs 12000 -Predicate { param($s) ($s.ById.TemperatureText -notmatch '^--' -or $s.ById.ErrorPanel -notin @('', '<missing>')) -and $s.ById.WeatherDescription -notmatch '加载中|Loading' }
        Add-Assert -Name 'English mode clean' -Passed ($en.AllText -notmatch 'System\.Object\[\]|(?<![A-Za-z0-9_])(undefined|NaN|Infinity)(?![A-Za-z0-9_])|\{[A-Za-z0-9_]+\}') -Details 'No invalid tokens'
        Save-WindowScreenshot 'english-mode.png'
        Invoke-ElementAction (Find-ElementById -AutomationId 'LanguageCnButton') -AfterMs 500
        $cn = Wait-UntilText -Name 'chinese-final' -TimeoutMs 12000 -Predicate { param($s) ($s.ById.TemperatureText -notmatch '^--' -or $s.ById.ErrorPanel -notin @('', '<missing>')) -and $s.ById.WeatherDescription -notmatch '加载中|Loading' }
        Add-Assert -Name 'Chinese mode clean' -Passed ($cn.AllText -notmatch 'System\.Object\[\]|(?<![A-Za-z0-9_])(undefined|NaN|Infinity)(?![A-Za-z0-9_])|\{[A-Za-z0-9_]+\}') -Details 'No invalid tokens'
        Save-WindowScreenshot 'chinese-mode.png'
        Invoke-ElementAction (Find-ElementById -AutomationId 'DrawerCollapseButton') -AfterMs 700
        Save-WindowScreenshot 'drawer-collapsed.png'
        Invoke-ElementAction (Find-ElementById -AutomationId 'DrawerHandle') -AfterMs 700
        Save-WindowScreenshot 'drawer-expanded.png'
    }

    Invoke-Step 'Rapid final switch' {
        Invoke-ElementAction (Find-ElementById -AutomationId 'SettingsButton') -AfterMs 300
        $lastFive = @($targets | Select-Object -Last ([Math]::Min(5,$targets.Count)))
        $rapidProvince = ''
        $rapidCity = ''
        $rapidDistrict = ''
        foreach ($r in $lastFive) {
            $parts = @($r.DisplayNameZh -split '\s*/\s*')
            if ($parts.Count -lt 3) { throw "Cannot parse DisplayNameZh: $($r.DisplayNameZh)" }
            if ($rapidProvince -ne $r.ProvinceKey) {
                Select-ComboItemByName -ComboAutomationId 'ProvinceSelector' -ItemName $parts[0] -ItemKey $r.ProvinceKey
                $rapidProvince = $r.ProvinceKey; $rapidCity = ''; $rapidDistrict = ''
                Start-Sleep -Milliseconds 120
            }
            if ($rapidCity -ne $r.CityKey) {
                Select-ComboItemByName -ComboAutomationId 'CitySelector' -ItemName $parts[1] -ItemKey $r.CityKey -ParentProvinceKey $r.ProvinceKey
                $rapidCity = $r.CityKey; $rapidDistrict = ''
                Start-Sleep -Milliseconds 120
            }
            if ($rapidDistrict -ne $r.DistrictKey) {
                Select-ComboItemByName -ComboAutomationId 'DistrictSelector' -ItemName $parts[2] -ItemKey $r.DistrictKey -ParentProvinceKey $r.ProvinceKey -ParentCityKey $r.CityKey
                $rapidDistrict = $r.DistrictKey
                Start-Sleep -Milliseconds 100
            }
        }
        $last = $lastFive[-1]; $lastParts = @($last.DisplayNameZh -split '\s*/\s*'); $lastDistrict = $lastParts[2]
        $final = Wait-UntilText -Name 'rapid-final' -TimeoutMs 30000 -Predicate { param($s) ($s.ById.LocationTitle -like "*$lastDistrict*") -and ($s.ById.WeatherDescription -notmatch '加载中|Loading') -and (($s.ById.TemperatureText -notmatch '^--') -or ($s.ById.ErrorPanel -notin @('', '<missing>'))) }
        Add-Assert -Name 'Rapid switch ends at final district' -Passed ($final.ById.LocationTitle -like "*$lastDistrict*") -Details $final.ById.LocationTitle
        Add-Assert -Name 'Process alive after rapid switch' -Passed (-not $script:Process.HasExited)
        Save-WindowScreenshot 'rapid-final.png'
    }
}
finally {
    Close-WidgetAppGracefully
    Restore-Settings
    Write-Reports
}

$script:Report | Select-Object Result,OutputDir,@{Name='Regions';Expression={$_.SelectedRegions.Count}},@{Name='Screenshots';Expression={$_.Screenshots.Count}},@{Name='Failures';Expression={$_.Failures.Count}} | Format-List
if ($script:HadFailure) { exit 1 }
if ([string]$script:Report.Result -eq 'PARTIAL') { exit 0 }
exit 0
