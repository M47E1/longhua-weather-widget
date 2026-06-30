[CmdletBinding()]
param(
    [string]$OutputDir = $null,
    [int]$TimeoutSeconds = 45
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $script:ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    $script:ScriptRoot = $PSScriptRoot
}
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $script:ScriptRoot 'reports\ui-smoke'
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

if (-not ('UiSmokeWin32' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class UiSmokeWin32
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool repaint);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int X, int Y);

    [DllImport("user32.dll")]
    public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);

    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
}
"@
}

$script:Report = [ordered]@{
    StartedAt = (Get-Date).ToString('s')
    Pid = $null
    Hwnd = $null
    WorkArea = $null
    Screenshots = [ordered]@{}
    Scenarios = [ordered]@{}
    Assertions = @()
    TextSnapshots = [ordered]@{}
    Failures = @()
    StdErr = ''
    VisualCheck = 'NOT VERIFIED BY SCRIPT'
}
$script:Process = $null
$script:Hwnd = [IntPtr]::Zero
$script:CurrentScenario = 'Setup'
$script:HadFailure = $false

function Decode-Base64Text {
    param([string]$Value)
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value))
}

$Text = @{
    AreaA = Decode-Base64Text 'QSDljLo='
    AreaB = Decode-Base64Text 'QiDljLo='
    AreaC = Decode-Base64Text 'QyDljLo='
    AlertA = Decode-Base64Text 'QSDlnLDljLrpm7fmmrTpooToraY='
}

function Set-ScenarioStatus {
    param([string]$Name, [string]$Status, [string]$Details = '')
    $script:Report.Scenarios[$Name] = [ordered]@{
        Status = $Status
        Details = $Details
    }
}

function Add-Assert {
    param([string]$Name, [bool]$Passed, [string]$Details = '')
    $entry = [ordered]@{
        Scenario = $script:CurrentScenario
        Name = $Name
        Passed = [bool]$Passed
        Details = $Details
    }
    $script:Report.Assertions += [pscustomobject]$entry
    if (-not $Passed) {
        $script:HadFailure = $true
        $script:Report.Failures += [pscustomobject]$entry
        throw "ASSERT FAILED [$($script:CurrentScenario)] $Name $Details"
    }
}

function Get-WindowRectForHwnd {
    param([IntPtr]$Hwnd)
    $rect = New-Object UiSmokeWin32+RECT
    if (-not [UiSmokeWin32]::GetWindowRect($Hwnd, [ref]$rect)) {
        throw 'GetWindowRect failed.'
    }
    return [pscustomobject]@{
        Left = $rect.Left
        Top = $rect.Top
        Right = $rect.Right
        Bottom = $rect.Bottom
        Width = $rect.Right - $rect.Left
        Height = $rect.Bottom - $rect.Top
    }
}

function Find-WindowByPid {
    param([int]$ProcessId, [int]$TimeoutMs = 15000)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    do {
        $script:FoundHwnd = [IntPtr]::Zero
        $callback = [UiSmokeWin32+EnumWindowsProc]{
            param([IntPtr]$hWnd, [IntPtr]$lParam)
            [uint32]$windowPid = 0
            [UiSmokeWin32]::GetWindowThreadProcessId($hWnd, [ref]$windowPid) | Out-Null
            if ([int]$windowPid -eq $ProcessId -and [UiSmokeWin32]::IsWindowVisible($hWnd)) {
                $sb = New-Object System.Text.StringBuilder 512
                [UiSmokeWin32]::GetWindowText($hWnd, $sb, $sb.Capacity) | Out-Null
                $title = $sb.ToString()
                $expectedTitles = @(
                    ("LonghuaWeatherWidget-UiSmoke-{0}" -f $ProcessId),
                    ("AnthropicWeatherWidget-UiSmoke-{0}" -f $ProcessId),
                    ("PaperWeatherWidget-UiSmoke-{0}" -f $ProcessId)
                )
                if ($expectedTitles -contains $title) {
                    $script:FoundHwnd = $hWnd
                    return $false
                }
            }
            return $true
        }
        [UiSmokeWin32]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null
        if ($script:FoundHwnd -ne [IntPtr]::Zero) { return $script:FoundHwnd }
        Start-Sleep -Milliseconds 150
    } while ((Get-Date) -lt $deadline)
    throw "No top-level widget window found for PID $ProcessId."
}

function Get-RootElement {
    return [System.Windows.Automation.AutomationElement]::FromHandle($script:Hwnd)
}

function Find-ElementById {
    param([string]$AutomationId, [int]$TimeoutMs = 5000)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
        $AutomationId
    )
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

function Get-ElementText {
    param([System.Windows.Automation.AutomationElement]$Element)
    if ($null -eq $Element) { return '' }
    $name = $Element.Current.Name
    $valuePattern = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$valuePattern)) {
        if (-not [string]::IsNullOrWhiteSpace($valuePattern.Current.Value)) {
            return [string]$valuePattern.Current.Value
        }
    }
    return [string]$name
}

function Get-UiTextSnapshot {
    param([string]$Name)
    $ids = @(
        'LocationTitle','WeatherDescription','TemperatureText','WarningPanel','WarningText',
        'RainfallText','HumidityText','PressureText','WindText','LoadingPanel','ErrorPanel',
        'ProvinceSelector','CitySelector','DistrictSelector','LanguageCnButton','LanguageEnButton'
    )
    $byId = [ordered]@{}
    foreach ($id in $ids) {
        try {
            $byId[$id] = Get-ElementText (Find-ElementById -AutomationId $id -TimeoutMs 600)
        } catch {
            $byId[$id] = '<missing>'
        }
    }

    $allNames = New-Object System.Collections.Generic.List[string]
    try {
        $elements = (Get-RootElement).FindAll([System.Windows.Automation.TreeScope]::Subtree, [System.Windows.Automation.Condition]::TrueCondition)
        foreach ($element in $elements) {
            $n = [string]$element.Current.Name
            if (-not [string]::IsNullOrWhiteSpace($n)) { $allNames.Add($n) }
        }
    } catch {}

    $snapshot = [ordered]@{
        ById = $byId
        AllText = ($allNames | Select-Object -Unique) -join "`n"
    }
    $script:Report.TextSnapshots[$Name] = $snapshot
    return $snapshot
}

function Wait-UntilText {
    param([scriptblock]$Predicate, [string]$Name, [int]$TimeoutMs = 12000)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    do {
        $snapshot = Get-UiTextSnapshot -Name $Name
        if (& $Predicate $snapshot) { return $snapshot }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw "Timed out waiting for UI text condition: $Name"
}

function Click-Element {
    param([System.Windows.Automation.AutomationElement]$Element)
    if ($null -eq $Element) { throw 'Cannot click null AutomationElement.' }
    [UiSmokeWin32]::SetForegroundWindow($script:Hwnd) | Out-Null
    Start-Sleep -Milliseconds 80

    $invokePattern = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$invokePattern)) {
        $invokePattern.Invoke()
        Start-Sleep -Milliseconds 250
        return
    }

    $rect = $Element.Current.BoundingRectangle
    if ($rect.Width -le 0 -or $rect.Height -le 0) {
        throw "Element has empty bounding rectangle: $($Element.Current.AutomationId)"
    }
    $x = [int]($rect.Left + ($rect.Width / 2))
    $y = [int]($rect.Top + ($rect.Height / 2))
    [UiSmokeWin32]::SetCursorPos($x, $y) | Out-Null
    Start-Sleep -Milliseconds 60
    [UiSmokeWin32]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 40
    [UiSmokeWin32]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 300
}

function Select-ComboItemByName {
    param([string]$ComboAutomationId, [string]$ItemName)
    $combo = Find-ElementById -AutomationId $ComboAutomationId -TimeoutMs 5000
    [UiSmokeWin32]::SetForegroundWindow($script:Hwnd) | Out-Null
    try { $combo.SetFocus() } catch {}
    $expandPattern = $null
    if ($combo.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$expandPattern)) {
        $expandPattern.Expand()
    } else {
        Click-Element $combo
    }
    Start-Sleep -Milliseconds 500

    $desktop = [System.Windows.Automation.AutomationElement]::RootElement
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::ListItem
    )
    $items = $desktop.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
    $target = $null
    foreach ($item in $items) {
        $name = [string]$item.Current.Name
        if ($name -eq $ItemName -or $name -like "*$ItemName*") {
            $target = $item
            break
        }
    }

    if ($null -eq $target) {
        $all = $desktop.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
        foreach ($item in $all) {
            $name = [string]$item.Current.Name
            if ($name -eq $ItemName -or $name -like "*$ItemName*") {
                $rect = $item.Current.BoundingRectangle
                if ($rect.Width -gt 0 -and $rect.Height -gt 0) {
                    $target = $item
                    break
                }
            }
        }
    }

    if ($null -ne $target) {
        $selectionPattern = $null
        if ($target.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$selectionPattern)) {
            $selectionPattern.Select()
            Start-Sleep -Milliseconds 550
        } else {
            Click-Element $target
            Start-Sleep -Milliseconds 550
        }
        return
    }

    $indexMap = @{}
    $indexMap[$Text.AreaA] = 0
    $indexMap[$Text.AreaB] = 1
    $indexMap[$Text.AreaC] = 2
    if (-not $indexMap.ContainsKey($ItemName)) {
        throw "Combo item '$ItemName' not found for $ComboAutomationId."
    }

    Click-Element $combo
    Start-Sleep -Milliseconds 250
    [System.Windows.Forms.SendKeys]::SendWait('{F4}')
    Start-Sleep -Milliseconds 250
    [System.Windows.Forms.SendKeys]::SendWait('{HOME}')
    Start-Sleep -Milliseconds 100
    for ($i = 0; $i -lt [int]$indexMap[$ItemName]; $i++) {
        [System.Windows.Forms.SendKeys]::SendWait('{DOWN}')
        Start-Sleep -Milliseconds 100
    }
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    Start-Sleep -Milliseconds 650
}

function Set-SmokeCommand {
    param([string]$Mode)
    $commandPath = Join-Path $OutputDir 'ui-smoke-command.json'
    if ([string]::IsNullOrWhiteSpace($Mode)) {
        if (Test-Path -LiteralPath $commandPath) { Remove-Item -LiteralPath $commandPath -Force }
        return
    }
    [pscustomobject]@{ Mode = $Mode; WrittenAt = (Get-Date).ToString('s') } |
        ConvertTo-Json | Set-Content -LiteralPath $commandPath -Encoding UTF8
}
function Get-UiSmokeTraceEvents {
    $tracePath = Join-Path $OutputDir 'ui-smoke-command-trace.jsonl'
    if (-not (Test-Path -LiteralPath $tracePath)) { return @() }
    $events = New-Object System.Collections.Generic.List[object]
    foreach ($line in (Get-Content -LiteralPath $tracePath -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $events.Add(($line | ConvertFrom-Json)) } catch {}
    }
    return @($events)
}

function Wait-UiSmokeTrace {
    param([scriptblock]$Predicate, [string]$Name, [int]$TimeoutMs = 5000)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    do {
        $events = Get-UiSmokeTraceEvents
        if (& $Predicate $events) { return $events }
        Start-Sleep -Milliseconds 150
    } while ((Get-Date) -lt $deadline)
    throw "Timed out waiting for UI smoke trace: $Name"
}

function Move-CursorAwayFromWindow {
    $rect = Get-WindowRectForHwnd -Hwnd $script:Hwnd
    $virtual = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $midX = $virtual.Left + ($virtual.Width / 2)
    if (($rect.Left + ($rect.Width / 2)) -lt $midX) {
        $x = [int]($virtual.Right - 4)
    } else {
        $x = [int]($virtual.Left + 4)
    }
    $y = [int]($virtual.Top + 4)
    [UiSmokeWin32]::SetCursorPos($x, $y) | Out-Null
    Start-Sleep -Milliseconds 650
}

function Save-WindowScreenshot {
    param([string]$FileName)
    Move-CursorAwayFromWindow
    $rect = Get-WindowRectForHwnd -Hwnd $script:Hwnd
    $virtual = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $left = [Math]::Max($rect.Left, $virtual.Left)
    $top = [Math]::Max($rect.Top, $virtual.Top)
    $right = [Math]::Min($rect.Right, $virtual.Right)
    $bottom = [Math]::Min($rect.Bottom, $virtual.Bottom)
    $width = [Math]::Max(1, $right - $left)
    $height = [Math]::Max(1, $bottom - $top)
    $path = Join-Path $OutputDir $FileName

    $bmp = New-Object System.Drawing.Bitmap $width, $height
    $graphics = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $graphics.CopyFromScreen($left, $top, 0, 0, $bmp.Size)
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $graphics.Dispose()
        $bmp.Dispose()
    }

    $item = Get-Item -LiteralPath $path
    Add-Assert -Name "Screenshot $FileName exists" -Passed ($item.Length -gt 0) -Details $path
    $script:Report.Screenshots[$FileName] = $path
    return $path
}

function Move-WidgetWindow {
    param([int]$Left, [int]$Top)
    $rect = Get-WindowRectForHwnd -Hwnd $script:Hwnd
    [UiSmokeWin32]::MoveWindow($script:Hwnd, $Left, $Top, [int]$rect.Width, [int]$rect.Height, $true) | Out-Null
    Start-Sleep -Milliseconds 300
}

function Assert-WindowOriginUnchanged {
    param([object]$Before, [object]$After, [string]$Action, [int]$Tolerance = 2)
    Add-Assert -Name "$Action keeps window Left" -Passed ([Math]::Abs([double]$After.Left - [double]$Before.Left) -le $Tolerance) -Details ("before={0}; after={1}" -f $Before.Left,$After.Left)
    Add-Assert -Name "$Action keeps window Top" -Passed ([Math]::Abs([double]$After.Top - [double]$Before.Top) -le $Tolerance) -Details ("before={0}; after={1}" -f $Before.Top,$After.Top)
}

function Assert-DrawerIconOnlyInWorkArea {
    param([string]$Side)
    $rect = Get-WindowRectForHwnd -Hwnd $script:Hwnd
    $area = $script:WorkArea
    Add-Assert -Name "$Side collapsed drawer is icon width" -Passed ($rect.Width -ge 20 -and $rect.Width -le 48) -Details ("width={0}; rect={1},{2},{3},{4}" -f $rect.Width,$rect.Left,$rect.Top,$rect.Right,$rect.Bottom)
    Add-Assert -Name "$Side collapsed drawer is icon height" -Passed ($rect.Height -ge 70 -and $rect.Height -le 130) -Details ("height={0}; rect={1},{2},{3},{4}" -f $rect.Height,$rect.Left,$rect.Top,$rect.Right,$rect.Bottom)
    Add-Assert -Name "$Side collapsed drawer icon in work area vertically" -Passed ($rect.Top -ge $area.Top -and $rect.Bottom -le $area.Bottom) -Details ("rectTop={0}; rectBottom={1}; work={2},{3}" -f $rect.Top,$rect.Bottom,$area.Top,$area.Bottom)
    Add-Assert -Name "$Side collapsed drawer has no forced edge snap assertion" -Passed $true -Details 'Click handlers must not move Window.Left/Top.'
}

function Assert-ExpandedInWorkArea {
    $rect = Get-WindowRectForHwnd -Hwnd $script:Hwnd
    $area = $script:WorkArea
    Add-Assert -Name 'Expanded window width positive' -Passed ($rect.Width -gt 200 -and $rect.Height -gt 200) -Details ("{0}x{1}" -f $rect.Width,$rect.Height)
    Add-Assert -Name 'Expanded main area in work area' -Passed ($rect.Left -ge ($area.Left - 4) -and $rect.Right -le ($area.Right + 4) -and $rect.Top -ge ($area.Top - 4) -and $rect.Bottom -le ($area.Bottom + 4)) -Details ("rect={0},{1},{2},{3}; area={4},{5},{6},{7}" -f $rect.Left,$rect.Top,$rect.Right,$rect.Bottom,$area.Left,$area.Top,$area.Right,$area.Bottom)
}

function Start-WidgetApp {
    $stderrPath = Join-Path $OutputDir 'widget.stderr.txt'
    $stdoutPath = Join-Path $OutputDir 'widget.stdout.txt'
    if (Test-Path -LiteralPath $stderrPath) { Remove-Item -LiteralPath $stderrPath -Force }
    if (Test-Path -LiteralPath $stdoutPath) { Remove-Item -LiteralPath $stdoutPath -Force }
    $appPath = Join-Path $script:ScriptRoot 'LonghuaWeatherWidget.ps1'
    $args = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $appPath,
        '-UiSmokeMode', '-UiSmokeOutput', $OutputDir, '-RefreshSeconds', '60'
    )
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -PassThru -WindowStyle Hidden -RedirectStandardError $stderrPath -RedirectStandardOutput $stdoutPath
    $script:Process = $p
    $script:Report.Pid = $p.Id
    $script:Hwnd = Find-WindowByPid -ProcessId $p.Id -TimeoutMs ($TimeoutSeconds * 1000)
    $script:Report.Hwnd = ('0x{0:X}' -f $script:Hwnd.ToInt64())
    $rect = Get-WindowRectForHwnd -Hwnd $script:Hwnd
    Add-Assert -Name 'Found target HWND' -Passed ($script:Hwnd -ne [IntPtr]::Zero) -Details $script:Report.Hwnd
    Add-Assert -Name 'Window rect has size' -Passed ($rect.Width -gt 0 -and $rect.Height -gt 0) -Details ("{0}x{1}" -f $rect.Width,$rect.Height)
    $screen = [System.Windows.Forms.Screen]::FromHandle($script:Hwnd)
    $script:WorkArea = [pscustomobject]@{
        Left = $screen.WorkingArea.Left
        Top = $screen.WorkingArea.Top
        Right = $screen.WorkingArea.Right
        Bottom = $screen.WorkingArea.Bottom
        Width = $screen.WorkingArea.Width
        Height = $screen.WorkingArea.Height
        DeviceName = $screen.DeviceName
        ScreenCount = [System.Windows.Forms.Screen]::AllScreens.Count
    }
    $script:Report.WorkArea = $script:WorkArea
}

function Close-WidgetAppGracefully {
    if ($script:Hwnd -ne [IntPtr]::Zero) {
        [UiSmokeWin32]::PostMessage($script:Hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    }
    if ($null -ne $script:Process) {
        try { $script:Process.WaitForExit(4000) | Out-Null } catch {}
        if (-not $script:Process.HasExited) { Stop-Process -Id $script:Process.Id -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-Step {
    param([string]$Name, [scriptblock]$Body)
    $script:CurrentScenario = $Name
    try {
        & $Body
        Set-ScenarioStatus -Name $Name -Status 'PASS'
    } catch {
        $script:HadFailure = $true
        $script:Report.Failures += [pscustomobject]@{ Scenario = $Name; Name = 'Exception'; Passed = $false; Details = $_.Exception.Message }
        Set-ScenarioStatus -Name $Name -Status 'FAIL' -Details $_.Exception.Message
    }
}

function Write-Reports {
    $script:Report.CompletedAt = (Get-Date).ToString('s')
    $stderrPath = Join-Path $OutputDir 'widget.stderr.txt'
    if (Test-Path -LiteralPath $stderrPath) { $script:Report.StdErr = Get-Content -LiteralPath $stderrPath -Raw }
    $jsonPath = Join-Path $OutputDir 'ui-smoke.json'
    $mdPath = Join-Path $OutputDir 'ui-smoke.md'
    $script:Report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# UI Smoke Report')
    $lines.Add('')
    $lines.Add(('- PID: {0}' -f $script:Report.Pid))
    $lines.Add(('- HWND: {0}' -f $script:Report.Hwnd))
    $lines.Add(('- Work area: {0}' -f (($script:Report.WorkArea | ConvertTo-Json -Compress))))
    $lines.Add(('- Visual check: {0}' -f $script:Report.VisualCheck))
    $lines.Add('')
    $lines.Add('## Scenarios')
    foreach ($key in $script:Report.Scenarios.Keys) {
        $lines.Add(('- {0}: {1} {2}' -f $key, $script:Report.Scenarios[$key].Status, $script:Report.Scenarios[$key].Details))
    }
    $lines.Add('')
    $lines.Add('## Screenshots')
    foreach ($key in $script:Report.Screenshots.Keys) {
        $lines.Add(('- {0}: {1}' -f $key, $script:Report.Screenshots[$key]))
    }
    $lines.Add('')
    $lines.Add('## Failures')
    if ($script:Report.Failures.Count -eq 0) {
        $lines.Add('- None')
    } else {
        foreach ($failure in $script:Report.Failures) {
            $lines.Add(('- [{0}] {1}: {2}' -f $failure.Scenario, $failure.Name, $failure.Details))
        }
    }
    $lines.Add('')
    $lines.Add('## stderr')
    $lines.Add('```')
    $lines.Add($script:Report.StdErr)
    $lines.Add('```')
    $lines | Set-Content -LiteralPath $mdPath -Encoding UTF8
}

if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}
Get-ChildItem -LiteralPath $OutputDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^(\d\d-|ui-smoke|widget\.|LonghuaWeatherWidget\.ui-smoke|ui-smoke-command)' } |
    Remove-Item -Force -ErrorAction SilentlyContinue

try {
    Start-WidgetApp

    Invoke-Step 'AutomationIds' {
        $requiredIds = @('ProvinceSelector','CitySelector','DistrictSelector','LanguageCnButton','LanguageEnButton','DrawerCollapseButton','DrawerHandle','RefreshNowCard','LocationTitle','WeatherDescription','TemperatureText','WarningPanel','RainfallText','HumidityText','PressureText','WindText','LoadingPanel','ErrorPanel')
        foreach ($id in $requiredIds) {
            Find-ElementById -AutomationId $id -TimeoutMs 8000 | Out-Null
            Add-Assert -Name "AutomationId $id found" -Passed $true
        }
    }

    Invoke-Step 'Scenario A location success' {
        $snapshot = Wait-UntilText -Name 'A-success' -TimeoutMs 16000 -Predicate { param($s) $s.ById.TemperatureText -match '11\.1' }
        Add-Assert -Name 'A title visible' -Passed ($snapshot.ById.LocationTitle -like "*$($Text.AreaA)*") -Details $snapshot.ById.LocationTitle
        Add-Assert -Name 'A temperature visible' -Passed ($snapshot.ById.TemperatureText -match '11\.1') -Details $snapshot.ById.TemperatureText
        Add-Assert -Name 'A weather visible' -Passed (-not [string]::IsNullOrWhiteSpace($snapshot.ById.WeatherDescription)) -Details $snapshot.ById.WeatherDescription
        Add-Assert -Name 'A warning visible' -Passed ($snapshot.AllText -like "*$($Text.AlertA)*") -Details $snapshot.ById.WarningPanel
        Save-WindowScreenshot '01-location-a-success.png' | Out-Null
    }


    Invoke-Step 'Manual refresh click' {
        $beforeRefreshClick = Get-WindowRectForHwnd -Hwnd $script:Hwnd
        Click-Element (Find-ElementById -AutomationId 'RefreshNowCard')
        Start-Sleep -Milliseconds 500
        $afterRefreshClick = Get-WindowRectForHwnd -Hwnd $script:Hwnd
        Assert-WindowOriginUnchanged -Before $beforeRefreshClick -After $afterRefreshClick -Action 'Refresh card click'
        $events = Wait-UiSmokeTrace -Name 'RefreshCardClick manual refresh' -TimeoutMs 5000 -Predicate {
            param($items)
            return (@($items | Where-Object { $_.Event -eq 'ManualRefresh' -and $_.Command.Reason -eq 'RefreshCardClick' }).Count -gt 0)
        }
        Add-Assert -Name 'Refresh click entered Start-ManualWeatherRefresh' -Passed (@($events | Where-Object { $_.Event -eq 'ManualRefresh' -and $_.Command.Reason -eq 'RefreshCardClick' }).Count -gt 0) -Details 'RefreshCardClick trace observed.'
    }

    Invoke-Step 'Open settings and selectors' {
        $beforeSettingsClick = Get-WindowRectForHwnd -Hwnd $script:Hwnd
        Click-Element (Find-ElementById -AutomationId 'SettingsButton')
        Start-Sleep -Milliseconds 500
        $afterSettingsClick = Get-WindowRectForHwnd -Hwnd $script:Hwnd
        Assert-WindowOriginUnchanged -Before $beforeSettingsClick -After $afterSettingsClick -Action 'Settings click'
        foreach ($id in @('ProvinceSelector','CitySelector','DistrictSelector','LanguageCnButton','LanguageEnButton')) {
            Find-ElementById -AutomationId $id -TimeoutMs 3000 | Out-Null
            Add-Assert -Name "Selector visible $id" -Passed $true
        }
    }

    Invoke-Step 'Scenario B loading and failure' {
        Set-SmokeCommand -Mode 'FailDelay'
        $beforeDistrictSelect = Get-WindowRectForHwnd -Hwnd $script:Hwnd
        Select-ComboItemByName -ComboAutomationId 'DistrictSelector' -ItemName $Text.AreaB
        Start-Sleep -Milliseconds 350
        $afterDistrictSelect = Get-WindowRectForHwnd -Hwnd $script:Hwnd
        Assert-WindowOriginUnchanged -Before $beforeDistrictSelect -After $afterDistrictSelect -Action 'District dropdown selection'
        $loading = Get-UiTextSnapshot -Name 'B-loading'
        Add-Assert -Name 'B loading title visible' -Passed ($loading.ById.LocationTitle -like "*$($Text.AreaB)*") -Details $loading.ById.LocationTitle
        Add-Assert -Name 'B loading old temp cleared' -Passed ($loading.AllText -notmatch '11\.1') -Details $loading.ById.TemperatureText
        Save-WindowScreenshot '02-location-b-loading.png' | Out-Null
        $failed = Wait-UntilText -Name 'B-failed' -TimeoutMs 8000 -Predicate { param($s) ($s.ById.TemperatureText -notmatch '11\.1') -and ($s.ById.LocationTitle -like "*$($Text.AreaB)*") }
        Add-Assert -Name 'B failure has no A temperature' -Passed ($failed.AllText -notmatch '11\.1') -Details $failed.ById.TemperatureText
        Add-Assert -Name 'B failure has no A warning' -Passed ($failed.AllText -notlike "*$($Text.AlertA)*") -Details $failed.ById.WarningPanel
        Add-Assert -Name 'B failure placeholders shown' -Passed ($failed.ById.TemperatureText -match '--') -Details $failed.ById.TemperatureText
        Save-WindowScreenshot '03-location-b-failed.png' | Out-Null
        Set-SmokeCommand -Mode ''
    }

    Invoke-Step 'Scenario C stale request guard' {
        Set-SmokeCommand -Mode ''
        $beforeSelectA = Get-WindowRectForHwnd -Hwnd $script:Hwnd
        Select-ComboItemByName -ComboAutomationId 'DistrictSelector' -ItemName $Text.AreaA
        $afterSelectA = Get-WindowRectForHwnd -Hwnd $script:Hwnd
        Assert-WindowOriginUnchanged -Before $beforeSelectA -After $afterSelectA -Action 'District dropdown select A'
        Wait-UntilText -Name 'A-before-race' -TimeoutMs 10000 -Predicate { param($s) $s.ById.TemperatureText -match '11\.1' } | Out-Null
        Set-SmokeCommand -Mode 'SlowSuccess'
        $beforeSelectB = Get-WindowRectForHwnd -Hwnd $script:Hwnd
        Select-ComboItemByName -ComboAutomationId 'DistrictSelector' -ItemName $Text.AreaB
        Start-Sleep -Milliseconds 100
        $afterSelectB = Get-WindowRectForHwnd -Hwnd $script:Hwnd
        Assert-WindowOriginUnchanged -Before $beforeSelectB -After $afterSelectB -Action 'District dropdown select B'
        Set-SmokeCommand -Mode ''
        $beforeSelectC = Get-WindowRectForHwnd -Hwnd $script:Hwnd
        Select-ComboItemByName -ComboAutomationId 'DistrictSelector' -ItemName $Text.AreaC
        $afterSelectC = Get-WindowRectForHwnd -Hwnd $script:Hwnd
        Assert-WindowOriginUnchanged -Before $beforeSelectC -After $afterSelectC -Action 'District dropdown select C'
        $c = Wait-UntilText -Name 'C-success' -TimeoutMs 14000 -Predicate { param($s) $s.ById.TemperatureText -match '33\.3' }
        Add-Assert -Name 'C title visible' -Passed ($c.ById.LocationTitle -like "*$($Text.AreaC)*") -Details $c.ById.LocationTitle
        Add-Assert -Name 'C final temperature visible' -Passed ($c.ById.TemperatureText -match '33\.3') -Details $c.ById.TemperatureText
        Add-Assert -Name 'B slow temperature not final' -Passed ($c.AllText -notmatch '22\.2') -Details $c.ById.TemperatureText
        Save-WindowScreenshot '04-location-c-success.png' | Out-Null
    }

    Invoke-Step 'Scenario D warning cleared' {
        $c = Get-UiTextSnapshot -Name 'C-warning-cleared'
        Add-Assert -Name 'C has no A alert text' -Passed ($c.AllText -notlike "*$($Text.AlertA)*") -Details $c.ById.WarningPanel
        Save-WindowScreenshot '05-warning-cleared.png' | Out-Null
    }

    Invoke-Step 'Drawer left collapsed expanded' {
        $rect = Get-WindowRectForHwnd -Hwnd $script:Hwnd
        Move-WidgetWindow -Left ($script:WorkArea.Left + 4) -Top ($script:WorkArea.Top + 80)
        $beforeCollapse = Get-WindowRectForHwnd -Hwnd $script:Hwnd
        Click-Element (Find-ElementById -AutomationId 'DrawerCollapseButton')
        Start-Sleep -Milliseconds 700
        $afterCollapse = Get-WindowRectForHwnd -Hwnd $script:Hwnd
        Assert-WindowOriginUnchanged -Before $beforeCollapse -After $afterCollapse -Action 'Left drawer collapse click'
        Save-WindowScreenshot '06-drawer-left-collapsed.png' | Out-Null
        Assert-DrawerIconOnlyInWorkArea -Side 'Left'
        $beforeExpand = Get-WindowRectForHwnd -Hwnd $script:Hwnd
        Click-Element (Find-ElementById -AutomationId 'DrawerHandle')
        Start-Sleep -Milliseconds 700
        $afterExpand = Get-WindowRectForHwnd -Hwnd $script:Hwnd
        Assert-WindowOriginUnchanged -Before $beforeExpand -After $afterExpand -Action 'Left drawer expand click'
        Save-WindowScreenshot '07-drawer-left-expanded.png' | Out-Null
        Assert-ExpandedInWorkArea
    }

    Invoke-Step 'Drawer right collapsed expanded' {
        $rect = Get-WindowRectForHwnd -Hwnd $script:Hwnd
        Move-WidgetWindow -Left ($script:WorkArea.Right - $rect.Width - 4) -Top ($script:WorkArea.Top + 80)
        $beforeCollapse = Get-WindowRectForHwnd -Hwnd $script:Hwnd
        Click-Element (Find-ElementById -AutomationId 'DrawerCollapseButton')
        Start-Sleep -Milliseconds 700
        $afterCollapse = Get-WindowRectForHwnd -Hwnd $script:Hwnd
        Assert-WindowOriginUnchanged -Before $beforeCollapse -After $afterCollapse -Action 'Right drawer collapse click'
        Save-WindowScreenshot '08-drawer-right-collapsed.png' | Out-Null
        Assert-DrawerIconOnlyInWorkArea -Side 'Right'
        $beforeExpand = Get-WindowRectForHwnd -Hwnd $script:Hwnd
        Click-Element (Find-ElementById -AutomationId 'DrawerHandle')
        Start-Sleep -Milliseconds 700
        $afterExpand = Get-WindowRectForHwnd -Hwnd $script:Hwnd
        Assert-WindowOriginUnchanged -Before $beforeExpand -After $afterExpand -Action 'Right drawer expand click'
        Save-WindowScreenshot '09-drawer-right-expanded.png' | Out-Null
        Assert-ExpandedInWorkArea
    }

    Invoke-Step 'Drawer rapid toggle and state restore'  {
        for ($i = 0; $i -lt 10; $i++) {
            $beforeToggle = Get-WindowRectForHwnd -Hwnd $script:Hwnd
            if (($i % 2) -eq 0) {
                Click-Element (Find-ElementById -AutomationId 'DrawerCollapseButton')
            } else {
                Click-Element (Find-ElementById -AutomationId 'DrawerHandle')
            }
            Start-Sleep -Milliseconds 320
            $afterToggle = Get-WindowRectForHwnd -Hwnd $script:Hwnd
            Assert-WindowOriginUnchanged -Before $beforeToggle -After $afterToggle -Action "Drawer rapid toggle $i"
            Add-Assert -Name "Process alive after drawer click $i" -Passed (-not $script:Process.HasExited)
        }
        Assert-ExpandedInWorkArea

        Click-Element (Find-ElementById -AutomationId 'DrawerCollapseButton')
        Start-Sleep -Milliseconds 700
        $collapsedBefore = Get-WindowRectForHwnd -Hwnd $script:Hwnd
        Close-WidgetAppGracefully
        $script:Process = $null
        $script:Hwnd = [IntPtr]::Zero
        Start-WidgetApp
        Start-Sleep -Milliseconds 1000
        $restored = Get-WindowRectForHwnd -Hwnd $script:Hwnd
        Add-Assert -Name 'Collapsed state restored after restart' -Passed ($restored.Width -ge 20 -and $restored.Width -le 48 -and $restored.Height -ge 70 -and $restored.Height -le 130 -and $restored.Top -ge $script:WorkArea.Top -and $restored.Bottom -le $script:WorkArea.Bottom) -Details ("before={0},{1},{2},{3}; restored={4},{5},{6},{7}" -f $collapsedBefore.Left,$collapsedBefore.Top,$collapsedBefore.Right,$collapsedBefore.Bottom,$restored.Left,$restored.Top,$restored.Right,$restored.Bottom)
        Click-Element (Find-ElementById -AutomationId 'DrawerHandle')
        Start-Sleep -Milliseconds 700
        Assert-ExpandedInWorkArea
    }

    Invoke-Step 'Scenario E language switch' {
        Click-Element (Find-ElementById -AutomationId 'SettingsButton')
        Start-Sleep -Milliseconds 400
        Click-Element (Find-ElementById -AutomationId 'LanguageEnButton')
        $en = Wait-UntilText -Name 'English-mode' -TimeoutMs 12000 -Predicate { param($s) $s.ById.TemperatureText -match '33\.3' }
        Add-Assert -Name 'English mode keeps C temperature' -Passed ($en.ById.TemperatureText -match '33\.3') -Details $en.ById.TemperatureText
        Add-Assert -Name 'English mode no old A alert' -Passed ($en.AllText -notlike "*$($Text.AlertA)*") -Details $en.ById.WarningPanel
        Add-Assert -Name 'English mode no System.Object[]' -Passed ($en.AllText -notmatch 'System\.Object\[\]|NaN|undefined|null|\{\{') -Details 'No invalid tokens'
        Save-WindowScreenshot '10-english-mode.png' | Out-Null
    }
}
finally {
    Close-WidgetAppGracefully
    $commandPath = Join-Path $OutputDir 'ui-smoke-command.json'
    if (Test-Path -LiteralPath $commandPath) { Remove-Item -LiteralPath $commandPath -Force -ErrorAction SilentlyContinue }
    $settingsPath = Join-Path $OutputDir 'LonghuaWeatherWidget.ui-smoke.settings.json'
    if (Test-Path -LiteralPath $settingsPath) { Remove-Item -LiteralPath $settingsPath -Force -ErrorAction SilentlyContinue }
    Write-Reports
}

if ($script:HadFailure) { exit 1 }
exit 0
