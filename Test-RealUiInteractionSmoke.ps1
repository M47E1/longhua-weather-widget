[CmdletBinding()]
param(
    [string]$OutputDir = $null,
    [int]$TimeoutSeconds = 35
)

$ErrorActionPreference = 'Stop'
$script:ScriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $script:ScriptRoot ('reports\ui-final-gate\{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
New-Item -ItemType Directory -Path $OutputDir -Force -ErrorAction Stop | Out-Null

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
. (Join-Path $script:ScriptRoot 'LonghuaWeatherWidget.ps1') -TestMode
$script:Catalog = @($script:Provinces)

if (-not ('FinalGateWin32' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class FinalGateWin32 {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint flags, UIntPtr extra);
}
"@
}

$script:Report = [ordered]@{
    Name = 'RealUiInteractionSmoke'
    StartedAt = (Get-Date).ToString('s')
    OutputDir = $OutputDir
    AttemptCount = 0
    SuccessCount = 0
    FailureCount = 0
    LoadingObservedByTarget = [ordered]@{}
    LoadingObserver = $null
    Screenshots = [ordered]@{}
    Assertions = @()
    Failures = @()
    Result = 'FAIL'
}
$script:Process = $null
$script:Hwnd = [IntPtr]::Zero
$script:ObserverProcess = $null
$script:ObserverStopPath = Join-Path $OutputDir 'loading-observer.stop'
$script:ObserverOutPath = Join-Path $OutputDir 'loading-observer.json'

function Add-Result {
    param([string]$Scenario, [bool]$Passed, [string]$Details = '')
    $entry = [pscustomobject]@{ Scenario=$Scenario; Passed=[bool]$Passed; Details=$Details }
    $script:Report.Assertions += $entry
    if ($Passed) { $script:Report.SuccessCount++ } else { $script:Report.FailureCount++; $script:Report.Failures += $entry }
}

function Get-CatalogRegion {
    param([string]$ProvinceKey, [string]$CityKey, [string]$DistrictKey, [string]$Language = 'zh')
    $oldLang = $script:Language
    $script:Language = $Language
    try {
        $province = @($script:Catalog | Where-Object { $_.Key -eq $ProvinceKey } | Select-Object -First 1)[0]
        $city = @($province.Cities | Where-Object { $_.Key -eq $CityKey } | Select-Object -First 1)[0]
        $district = @($city.Districts | Where-Object { $_.Key -eq $DistrictKey } | Select-Object -First 1)[0]
        [pscustomobject]@{
            ProvinceKey=$ProvinceKey; CityKey=$CityKey; DistrictKey=$DistrictKey
            ProvinceName=(Get-DisplayName $province); CityName=(Get-DisplayName $city); DistrictName=(Get-DisplayName $district)
            LocationKey=('{0}|{1}|{2}' -f $ProvinceKey,$CityKey,$DistrictKey)
            Title=('{0} · {1} · {2}' -f (Get-DisplayName $province),(Get-DisplayName $city),(Get-DisplayName $district))
        }
    } finally { $script:Language = $oldLang }
}

function Find-WindowByPid {
    param([int]$ProcessId, [int]$TimeoutMs = 20000)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    do {
        $script:FoundHwnd = [IntPtr]::Zero
        $cb = [FinalGateWin32+EnumWindowsProc]{
            param([IntPtr]$h, [IntPtr]$l)
            [uint32]$windowProcessId = 0
            [FinalGateWin32]::GetWindowThreadProcessId($h, [ref]$windowProcessId) | Out-Null
            if ([int]$windowProcessId -eq $ProcessId -and [FinalGateWin32]::IsWindowVisible($h)) {
                $sb = New-Object System.Text.StringBuilder 512
                [FinalGateWin32]::GetWindowText($h, $sb, $sb.Capacity) | Out-Null
                if ($sb.ToString() -match 'LonghuaWeatherWidget|Basic Weather Widget') { $script:FoundHwnd = $h; return $false }
            }
            return $true
        }
        [FinalGateWin32]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
        if ($script:FoundHwnd -ne [IntPtr]::Zero) { return $script:FoundHwnd }
        Start-Sleep -Milliseconds 120
    } while ((Get-Date) -lt $deadline)
    throw "No window found for PID $ProcessId"
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
    throw "AutomationId not found: $AutomationId"
}
function Get-TextById {
    param([string]$AutomationId)
    try {
        $e = Find-ById $AutomationId 600
        $vp = $null
        if ($e.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp) -and -not [string]::IsNullOrWhiteSpace($vp.Current.Value)) { return [string]$vp.Current.Value }
        return [string]$e.Current.Name
    } catch { return '<missing>' }
}
function Get-ItemStatus {
    try { return [string](Get-Root).Current.ItemStatus } catch { return '' }
}
function Get-StatusMap {
    $status = Get-ItemStatus
    $map = @{}
    foreach ($part in ($status -split ';')) {
        $kv = $part -split '=',2
        if ($kv.Count -eq 2) { $map[$kv[0]] = $kv[1] }
    }
    return $map
}
function Wait-Status {
    param([string]$State, [string]$LocationKey = '', [int]$TimeoutMs = 25000)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    do {
        $map = Get-StatusMap
        if ($map['State'] -eq $State -and ([string]::IsNullOrWhiteSpace($LocationKey) -or $map['LocationKey'] -eq $LocationKey)) { return $map }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    throw "Timed out waiting State=$State LocationKey=$LocationKey Last=$(Get-ItemStatus)"
}
function Wait-LoadedOrError {
    param([string]$LocationKey, [int]$TimeoutMs = 35000)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    do {
        $map = Get-StatusMap
        if (($map['State'] -in @('Loaded','Error')) -and $map['LocationKey'] -eq $LocationKey) { return $map }
        Start-Sleep -Milliseconds 150
    } while ((Get-Date) -lt $deadline)
    throw "Timed out waiting Loaded/Error for $LocationKey Last=$(Get-ItemStatus)"
}
function Send-VirtualKey {
    param([byte]$VirtualKey, [int]$AfterMs = 45)
    [FinalGateWin32]::keybd_event($VirtualKey, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 20
    [FinalGateWin32]::keybd_event($VirtualKey, 0, 0x0002, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds $AfterMs
}

function Get-VisiblePopupListItems {
    $condition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)
    $items = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
    $visible = New-Object System.Collections.Generic.List[object]
    foreach ($item in $items) {
        if (Test-Visible $item) {
            $r = $item.Current.BoundingRectangle
            $visible.Add([pscustomobject]@{ Element=$item; Name=[string]$item.Current.Name; Top=[double]$r.Top; Left=[double]$r.Left }) | Out-Null
        }
    }
    return @($visible | Sort-Object Top,Left)
}
function Invoke-Element {
    param([System.Windows.Automation.AutomationElement]$Element, [int]$AfterMs = 250)
    [FinalGateWin32]::SetForegroundWindow($script:Hwnd) | Out-Null
    Start-Sleep -Milliseconds 60
    $invoke = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$invoke)) {
        try { $invoke.Invoke(); Start-Sleep -Milliseconds $AfterMs; return } catch {}
    }
    $rect = $Element.Current.BoundingRectangle
    if ($rect.Width -le 0 -or $rect.Height -le 0) { throw 'Cannot click invisible element.' }
    [FinalGateWin32]::SetCursorPos([int]($rect.Left + $rect.Width/2), [int]($rect.Top + $rect.Height/2)) | Out-Null
    Start-Sleep -Milliseconds 40
    [FinalGateWin32]::mouse_event(0x0002,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 30
    [FinalGateWin32]::mouse_event(0x0004,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds $AfterMs
}
function Test-Visible {
    param($Element)
    if ($null -eq $Element) { return $false }
    $r = $Element.Current.BoundingRectangle
    return ($r.Width -gt 0 -and $r.Height -gt 0 -and -not $Element.Current.IsOffscreen)
}
function Find-PopupListItem {
    param([string]$Name, [int]$TimeoutMs = 5000)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    $condition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)
    do {
        $items = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
        foreach ($item in $items) {
            if ([string]$item.Current.Name -eq $Name -and (Test-Visible $item)) { return $item }
        }
        Start-Sleep -Milliseconds 120
    } while ((Get-Date) -lt $deadline)
    throw "Popup ListItem not found by full name: $Name"
}
function Select-ComboPopupItem {
    param([string]$ComboId, [string]$ItemName)
    $lastError = ''
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $combo = Find-ById $ComboId 6000
            if (-not (Test-Visible $combo)) {
                Invoke-Element (Find-ById 'SettingsButton') 350
                $combo = Find-ById $ComboId 3000
            }
            $expand = $null
            if ($combo.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$expand)) {
                try { $expand.Expand() } catch { Invoke-Element $combo 180 }
            } else {
                Invoke-Element $combo 180
            }
            Start-Sleep -Milliseconds 260
            try {
                $item = Find-PopupListItem -Name $ItemName -TimeoutMs 2500
            } catch {
                Invoke-Element $combo 220
                Start-Sleep -Milliseconds 260
                $item = Find-PopupListItem -Name $ItemName -TimeoutMs 3500
            }
            if ([string]$item.Current.Name -ne $ItemName) { throw "ComboBoxItem name mismatch: $($item.Current.Name) vs $ItemName" }
            $selection = $null
            $selectedByPattern = $false
            if ($item.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$selection)) {
                try { $selection.Select(); $selectedByPattern = $true } catch { $selectedByPattern = $false }
            }
            if (-not $selectedByPattern) { Invoke-Element $item 260 }
            Start-Sleep -Milliseconds 600
            $comboAfter = Find-ById $ComboId 3000
            $exposed = @([string]$comboAfter.Current.HelpText, [string]$comboAfter.Current.Name) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            if ($exposed -contains $ItemName) { return }
            if ($ItemName -in $exposed) { return }
            try {
                $comboRetry = Find-ById $ComboId 3000
                $expandRetry = $null
                if ($comboRetry.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$expandRetry)) { try { $expandRetry.Expand() } catch { Invoke-Element $comboRetry 180 } } else { Invoke-Element $comboRetry 180 }
                Start-Sleep -Milliseconds 220
                $itemRetry = Find-PopupListItem -Name $ItemName -TimeoutMs 3000
                Invoke-Element $itemRetry 420
                $comboAfterClick = Find-ById $ComboId 3000
                $exposedAfterClick = @([string]$comboAfterClick.Current.HelpText, [string]$comboAfterClick.Current.Name) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                if ($exposedAfterClick -contains $ItemName) { return }
                $lastError = "selection pattern and click fallback did not stick; exposed=$($exposedAfterClick -join '|')"
            } catch {
                $lastError = "selection pattern did not stick and click fallback failed: $($_.Exception.Message)"
            }
            try {
                $comboKeyboard = Find-ById $ComboId 3000
                [FinalGateWin32]::SetForegroundWindow($script:Hwnd) | Out-Null
                try { $comboKeyboard.SetFocus() } catch {}
                $expandKeyboard = $null
                if ($comboKeyboard.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$expandKeyboard)) { try { $expandKeyboard.Expand() } catch { Invoke-Element $comboKeyboard 180 } } else { Invoke-Element $comboKeyboard 180 }
                Start-Sleep -Milliseconds 220
                $visibleItems = @(Get-VisiblePopupListItems)
                $targetIndex = -1
                for ($k = 0; $k -lt $visibleItems.Count; $k++) { if ($visibleItems[$k].Name -eq $ItemName) { $targetIndex = $k; break } }
                if ($targetIndex -ge 0) {
                    Send-VirtualKey 0x24 80
                    for ($k = 0; $k -lt $targetIndex; $k++) { Send-VirtualKey 0x28 25 }
                    Send-VirtualKey 0x0D 420
                    $comboAfterKeyboard = Find-ById $ComboId 3000
                    $exposedAfterKeyboard = @([string]$comboAfterKeyboard.Current.HelpText, [string]$comboAfterKeyboard.Current.Name) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                    if ($exposedAfterKeyboard -contains $ItemName) { return }
                    $lastError = "keyboard fallback index=$targetIndex did not stick; exposed=$($exposedAfterKeyboard -join '|')"
                } else {
                    $lastError = "keyboard fallback could not find visible index; visible=$((@($visibleItems | Select-Object -ExpandProperty Name) -join '|'))"
                }
            } catch {
                $lastError = "keyboard fallback failed: $($_.Exception.Message)"
            }
            $lastError = "selected item did not stick; exposed=$($exposed -join '|')"
        } catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Milliseconds 250
        }
    }
    throw "Combo item '$ItemName' not selected for $ComboId after retries. Last: $lastError"
}
function Save-Screenshot {
    param([string]$FileName)
    $rect = New-Object FinalGateWin32+RECT
    if (-not [FinalGateWin32]::GetWindowRect($script:Hwnd, [ref]$rect)) { throw 'GetWindowRect failed.' }
    $virtual = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $left = [Math]::Max($rect.Left, $virtual.Left); $top = [Math]::Max($rect.Top, $virtual.Top)
    $right = [Math]::Min($rect.Right, $virtual.Right); $bottom = [Math]::Min($rect.Bottom, $virtual.Bottom)
    $width = [Math]::Max(1, $right - $left); $height = [Math]::Max(1, $bottom - $top)
    $file = Join-Path $OutputDir $FileName
    $bmp = New-Object System.Drawing.Bitmap $width,$height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try { $g.CopyFromScreen($left,$top,0,0,$bmp.Size); $bmp.Save($file,[System.Drawing.Imaging.ImageFormat]::Png) }
    finally { $g.Dispose(); $bmp.Dispose() }
    $script:Report.Screenshots[$FileName] = $file
    return $file
}
function Start-App {
    param([string]$Fixture = 'Live', [string]$SubDir = '', [int]$DelayMs = 900)
    $dir = if ([string]::IsNullOrWhiteSpace($SubDir)) { $OutputDir } else { Join-Path $OutputDir $SubDir }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $settings = [ordered]@{ Language='zh'; ProvinceKey='Guangdong'; CityKey='Shenzhen'; DistrictKey='Longhua'; RefreshSeconds=60; DrawerEdge='Left'; DrawerExpanded=$true; DrawerTop=$null; DrawerScreenDeviceName=$null; SavedAt=(Get-Date).ToString('s') }
    $settings | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'LonghuaWeatherWidget.ui-smoke.settings.json') -Encoding UTF8
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',(Join-Path $script:ScriptRoot 'LonghuaWeatherWidget.ps1'),'-NoTopMost','-UiSmokeMode','-UiFixture',$Fixture,'-UiSmokeOutput',$dir,'-UiSmokeDelayMs',[string]$DelayMs,'-RefreshSeconds','60')
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $dir 'widget.stdout.txt') -RedirectStandardError (Join-Path $dir 'widget.stderr.txt')
    $script:Process = $p
    $script:Hwnd = Find-WindowByPid -ProcessId $p.Id -TimeoutMs ($TimeoutSeconds * 1000)
    return $dir
}
function Close-App {
    if ($script:Hwnd -ne [IntPtr]::Zero) { [FinalGateWin32]::PostMessage($script:Hwnd,0x0010,[IntPtr]::Zero,[IntPtr]::Zero) | Out-Null }
    if ($null -ne $script:Process) {
        try { $script:Process.WaitForExit(4000) | Out-Null } catch {}
        if (-not $script:Process.HasExited) { Stop-Process -Id $script:Process.Id -Force -ErrorAction SilentlyContinue }
    }
    $script:Hwnd = [IntPtr]::Zero; $script:Process = $null
}
function Write-CommandFile {
    param([string]$Dir, [hashtable]$Command)
    $Command['Id'] = [guid]::NewGuid().ToString('N')
    $Command | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Dir 'ui-smoke-command.json') -Encoding UTF8
}
function Start-Observer {
    Remove-Item -LiteralPath $script:ObserverStopPath,$script:ObserverOutPath -Force -ErrorAction SilentlyContinue
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',(Join-Path $script:ScriptRoot 'loading-observer.ps1'),'-HwndValue',[string]$script:Hwnd.ToInt64(),'-OutPath',$script:ObserverOutPath,'-StopPath',$script:ObserverStopPath)
    $script:ObserverProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -PassThru -WindowStyle Hidden
}
function Stop-Observer {
    if ($null -eq $script:ObserverProcess) { return }
    New-Item -ItemType File -Path $script:ObserverStopPath -Force | Out-Null
    try { $script:ObserverProcess.WaitForExit(8000) | Out-Null } catch {}
    if (-not $script:ObserverProcess.HasExited) { Stop-Process -Id $script:ObserverProcess.Id -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $script:ObserverOutPath) { $script:Report.LoadingObserver = Get-Content -LiteralPath $script:ObserverOutPath -Raw -Encoding UTF8 | ConvertFrom-Json }
}
function Record-Loading {
    param([string]$LocationKey)
    if (-not $script:Report.LoadingObservedByTarget.Contains($LocationKey)) { $script:Report.LoadingObservedByTarget[$LocationKey] = 0 }
    $script:Report.LoadingObservedByTarget[$LocationKey] = [int]$script:Report.LoadingObservedByTarget[$LocationKey] + 1
}
function Run-Scenario {
    param([string]$Name, [scriptblock]$Body)
    $script:Report.AttemptCount++
    try { & $Body; Add-Result -Scenario $Name -Passed $true }
    catch { Add-Result -Scenario $Name -Passed $false -Details $_.Exception.Message }
}

try {
    $liveDir = Start-App -Fixture 'Live'
    Start-Observer
    $longhua = Get-CatalogRegion 'Guangdong' 'Shenzhen' 'Longhua' 'zh'
    Wait-LoadedOrError -LocationKey $longhua.LocationKey -TimeoutMs 35000 | Out-Null
    Invoke-Element (Find-ById 'SettingsButton') 350
    Save-Screenshot 'normal-chinese.png' | Out-Null

    $current = $longhua
    Run-Scenario 'Shenzhen Longhua -> Shenzhen Futian district only' {
        $futian = Get-CatalogRegion 'Guangdong' 'Shenzhen' 'Futian' 'zh'
        Select-ComboPopupItem 'DistrictSelector' $futian.DistrictName
        Wait-Status -State 'Loading' -LocationKey $futian.LocationKey -TimeoutMs 8000 | Out-Null
        Record-Loading $futian.LocationKey
        Wait-LoadedOrError $futian.LocationKey 40000 | Out-Null
        $current = $futian
    }

    # Restore the required starting point for the cross-province scenario without counting it as a separate gate scenario.
    $longhuaSetup = Get-CatalogRegion 'Guangdong' 'Shenzhen' 'Longhua' 'zh'
    Write-CommandFile -Dir $liveDir -Command @{ Action='SelectLocation'; ProvinceKey='Guangdong'; CityKey='Shenzhen'; DistrictKey='Longhua' }
    Wait-LoadedOrError $longhuaSetup.LocationKey 40000 | Out-Null
    $current = $longhuaSetup

    Run-Scenario 'Guangdong Shenzhen Longhua -> Shanghai Pudong New Area' {
        $target = Get-CatalogRegion 'Shanghai' 'Shanghai' 'Pudong' 'zh'
        $huangpu = Get-CatalogRegion 'Shanghai' 'Shanghai' 'Huangpu' 'zh'
        Select-ComboPopupItem 'ProvinceSelector' $target.ProvinceName
        Wait-Status -State 'Loading' -LocationKey $target.LocationKey -TimeoutMs 8000 | Out-Null
        Record-Loading $target.LocationKey
        Save-Screenshot 'cross-region-loading.png' | Out-Null
        Wait-LoadedOrError $target.LocationKey 40000 | Out-Null
        Select-ComboPopupItem 'CitySelector' $target.CityName
        Select-ComboPopupItem 'DistrictSelector' $huangpu.DistrictName
        Wait-LoadedOrError $huangpu.LocationKey 40000 | Out-Null
        Select-ComboPopupItem 'DistrictSelector' $target.DistrictName
        Wait-LoadedOrError $target.LocationKey 40000 | Out-Null
        $current = $target
    }

    Run-Scenario 'Shanghai Pudong New Area -> Jiangsu Suzhou Industrial Park' {
        $target = Get-CatalogRegion 'Jiangsu' 'Suzhou' 'SIP' 'zh'
        $jiangsuDefault = Get-CatalogRegion 'Jiangsu' 'Nanjing' 'Xuanwu' 'zh'
        $suzhouDefault = Get-CatalogRegion 'Jiangsu' 'Suzhou' 'Gusu' 'zh'
        Select-ComboPopupItem 'ProvinceSelector' $target.ProvinceName
        Wait-Status -State 'Loading' -LocationKey $jiangsuDefault.LocationKey -TimeoutMs 8000 | Out-Null
        Record-Loading $jiangsuDefault.LocationKey
        Wait-LoadedOrError $jiangsuDefault.LocationKey 40000 | Out-Null
        Select-ComboPopupItem 'CitySelector' $target.CityName
        Wait-LoadedOrError $suzhouDefault.LocationKey 40000 | Out-Null
        Select-ComboPopupItem 'DistrictSelector' $target.DistrictName
        Wait-LoadedOrError $target.LocationKey 40000 | Out-Null
        Invoke-Element (Find-ById 'LanguageEnButton') 600
        Save-Screenshot 'normal-english-long-location.png' | Out-Null
        $districtCombo = Find-ById 'DistrictSelector'
        if ([string]$districtCombo.Current.HelpText -ne 'Industrial Park' -and [string]$districtCombo.Current.Name -ne 'Industrial Park') { throw 'District ComboBox does not expose full Industrial Park name.' }
        Select-ComboPopupItem 'DistrictSelector' 'Industrial Park'
        $current = $target
    }

    Run-Scenario 'Chinese -> English -> Chinese buttons' {
        Invoke-Element (Find-ById 'LanguageEnButton') 500
        if ((Get-TextById 'LanguageEnButton') -notmatch 'English') { throw 'English button not readable after click.' }
        Invoke-Element (Find-ById 'LanguageCnButton') 500
        if ((Get-TextById 'LanguageCnButton') -notmatch '中文') { throw 'Chinese button not readable after click.' }
    }

    Run-Scenario 'Settings collapse and expand' {
        Invoke-Element (Find-ById 'SettingsButton') 500
        Start-Sleep -Milliseconds 300
        Invoke-Element (Find-ById 'SettingsButton') 500
        Find-ById 'ProvinceSelector' 3000 | Out-Null
    }

    Run-Scenario 'Drawer collapse expand rapid 10' {
        for ($i=0; $i -lt 10; $i++) {
            Invoke-Element (Find-ById 'DrawerCollapseButton') 160
            Invoke-Element (Find-ById 'DrawerHandle') 160
        }
        Invoke-Element (Find-ById 'DrawerCollapseButton') 350
        Save-Screenshot 'drawer-collapsed.png' | Out-Null
        Invoke-Element (Find-ById 'DrawerHandle') 350
        Save-Screenshot 'drawer-expanded.png' | Out-Null
        Save-Screenshot 'rapid-switch-final.png' | Out-Null
    }

    Stop-Observer
    Close-App

    # Deterministic state screenshots that do not alter production data logic.
    $stateDir = Start-App -Fixture 'current-no-rain-future-heavy-rain' -SubDir 'state-screenshots' -DelayMs 5000
    Wait-LoadedOrError 'SmokeProvince|SmokeCity|SmokeA' 20000 | Out-Null
    Write-CommandFile -Dir $stateDir -Command @{ Action='Refresh'; Mode='Delay' }
    Start-Sleep -Milliseconds 1000
    Save-Screenshot 'same-region-updating.png' | Out-Null
    Wait-LoadedOrError 'SmokeProvince|SmokeCity|SmokeA' 30000 | Out-Null
    Close-App

    $failDir = Start-App -Fixture 'A' -SubDir 'fail-screenshot' -DelayMs 1200
    Wait-LoadedOrError 'SmokeProvince|SmokeCity|SmokeA' 20000 | Out-Null
    Write-CommandFile -Dir $failDir -Command @{ Action='SelectLocation'; ProvinceKey='SmokeProvince'; CityKey='SmokeCity'; DistrictKey='SmokeB'; Mode='Fail' }
    Wait-Status -State 'Error' -LocationKey 'SmokeProvince|SmokeCity|SmokeB' -TimeoutMs 25000 | Out-Null
    Save-Screenshot 'request-failed-no-cache.png' | Out-Null
    Close-App
}
finally {
    try { Stop-Observer } catch {}
    Close-App
}

$script:Report.CompletedAt = (Get-Date).ToString('s')
if ($script:Report.AttemptCount -eq 6 -and $script:Report.SuccessCount -eq 6 -and $script:Report.FailureCount -eq 0) { $script:Report.Result = 'PASS' } else { $script:Report.Result = 'FAIL' }
$script:Report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $OutputDir 'real-ui-interaction-smoke.json') -Encoding UTF8
[pscustomobject]$script:Report | Select-Object Name,Result,OutputDir,AttemptCount,SuccessCount,FailureCount,@{Name='Screenshots';Expression={$_.Screenshots.Count}} | Format-List
if ($script:Report.Result -ne 'PASS') { exit 1 }
