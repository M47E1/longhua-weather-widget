[CmdletBinding()]
param(
    [string]$RegionSmokeReportDir = $null,
    [string]$OutputDir = $null,
    [int]$RegionCount = 24,
    [int]$TimeoutSeconds = 45
)

$ErrorActionPreference = 'Stop'
$script:ScriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($RegionSmokeReportDir)) {
    $root = Join-Path $script:ScriptRoot 'reports\region-smoke-200'
    $latest = Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop | Sort-Object Name -Descending | Select-Object -First 1
    if ($null -eq $latest) { throw 'No region smoke report directory found.' }
    $RegionSmokeReportDir = $latest.FullName
}
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $script:ScriptRoot ('reports\ui-region-render-smoke\{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
New-Item -ItemType Directory -Path $OutputDir -Force -ErrorAction Stop | Out-Null

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
. (Join-Path $script:ScriptRoot 'LonghuaWeatherWidget.ps1') -TestMode

if (-not ('RegionRenderWin32' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class RegionRenderWin32 {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr w, IntPtr l);
}
"@
}

$script:Report = [ordered]@{
    Name='UiRegionRenderSmoke'
    StartedAt=(Get-Date).ToString('s')
    RegionSmokeReportDir=$RegionSmokeReportDir
    OutputDir=$OutputDir
    ActualRegionCount=0
    SuccessCount=0
    FailureCount=0
    LoadingObservedByTarget=[ordered]@{}
    Screenshots=[ordered]@{}
    Results=@()
    Failures=@()
    Observer=$null
    Result='FAIL'
}
$script:Process=$null
$script:Hwnd=[IntPtr]::Zero
$script:ObserverStopPath=Join-Path $OutputDir 'loading-observer.stop'
$script:ObserverOutPath=Join-Path $OutputDir 'loading-observer.json'
$script:ObserverProcess=$null

function Select-RepresentativeRegions {
    param([object[]]$Records, [int]$Count)
    $selected = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    function Add-Group([object[]]$Items, [int]$Limit) {
        $added = 0
        foreach ($item in $Items) {
            if ($added -ge $Limit) { break }
            if ($seen.ContainsKey($item.LocationKey)) { continue }
            $selected.Add($item) | Out-Null
            $seen[$item.LocationKey] = $true
            $added++
        }
    }
    Add-Group @($Records | Sort-Object @{Expression={$_.DisplayNameEn.Length};Descending=$true}) 4
    Add-Group @($Records | Where-Object { $_.DistrictKey -in @('Longhua','Futian','Pudong','SIP','Gaoxin') }) 5
    Add-Group @($Records | Where-Object { [int]$_.Attempts -gt 1 -or $_.Category -eq 'RETRY_PASS' }) 3
    Add-Group @($Records | Where-Object { [double]$_.CurrentPrecipitation -eq 0 -and [double]$_.CurrentRain -eq 0 }) 5
    Add-Group @($Records | Where-Object { [double]$_.CurrentPrecipitation -gt 0 -or [double]$_.CurrentRain -gt 0 }) 4
    Add-Group @($Records) ([Math]::Max(0, $Count - $selected.Count))
    return @($selected | Select-Object -First $Count)
}
function Find-WindowByPid {
    param([int]$ProcessId, [int]$TimeoutMs=25000)
    $deadline=(Get-Date).AddMilliseconds($TimeoutMs)
    do {
        $script:FoundHwnd=[IntPtr]::Zero
        $cb=[RegionRenderWin32+EnumWindowsProc]{
            param([IntPtr]$h,[IntPtr]$l)
            [uint32]$windowProcessId=0
            [RegionRenderWin32]::GetWindowThreadProcessId($h,[ref]$windowProcessId)|Out-Null
            if([int]$windowProcessId -eq $ProcessId -and [RegionRenderWin32]::IsWindowVisible($h)){
                $sb=New-Object System.Text.StringBuilder 512
                [RegionRenderWin32]::GetWindowText($h,$sb,$sb.Capacity)|Out-Null
                if($sb.ToString() -match 'LonghuaWeatherWidget|Basic Weather Widget'){ $script:FoundHwnd=$h; return $false }
            }
            return $true
        }
        [RegionRenderWin32]::EnumWindows($cb,[IntPtr]::Zero)|Out-Null
        if($script:FoundHwnd -ne [IntPtr]::Zero){return $script:FoundHwnd}
        Start-Sleep -Milliseconds 120
    } while((Get-Date)-lt $deadline)
    throw "No window for PID $ProcessId"
}
function Get-Root { [System.Windows.Automation.AutomationElement]::FromHandle($script:Hwnd) }
function Find-ById {
    param([string]$AutomationId,[int]$TimeoutMs=4000)
    $deadline=(Get-Date).AddMilliseconds($TimeoutMs)
    $condition=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty,$AutomationId)
    do{
        $root=Get-Root
        if($null -ne $root){$e=$root.FindFirst([System.Windows.Automation.TreeScope]::Subtree,$condition); if($null -ne $e){return $e}}
        Start-Sleep -Milliseconds 80
    }while((Get-Date)-lt $deadline)
    throw "AutomationId not found: $AutomationId"
}
function Get-TextById {
    param([string]$AutomationId)
    try{ $e=Find-ById $AutomationId 600; $vp=$null; if($e.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$vp) -and -not [string]::IsNullOrWhiteSpace($vp.Current.Value)){return [string]$vp.Current.Value}; return [string]$e.Current.Name }catch{return '<missing>'}
}
function Get-ItemStatus { try { [string](Get-Root).Current.ItemStatus } catch { '' } }
function Get-StatusMap {
    $map=@{}
    foreach($part in ((Get-ItemStatus) -split ';')){ $kv=$part -split '=',2; if($kv.Count -eq 2){$map[$kv[0]]=$kv[1]} }
    return $map
}
function Wait-State {
    param([string[]]$States,[string]$LocationKey,[int]$TimeoutMs=30000)
    $deadline=(Get-Date).AddMilliseconds($TimeoutMs)
    do{ $map=Get-StatusMap; if($map['State'] -in $States -and $map['LocationKey'] -eq $LocationKey){return $map}; Start-Sleep -Milliseconds 120 }while((Get-Date)-lt $deadline)
    throw "Timed out waiting states=$($States -join ',') key=$LocationKey last=$(Get-ItemStatus)"
}
function Write-CommandFile {
    param([hashtable]$Command)
    $Command['Id']=[guid]::NewGuid().ToString('N')
    $Command | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDir 'ui-smoke-command.json') -Encoding UTF8
}
function Test-ImageHasDetail {
    param([string]$Path)
    $bmp=[System.Drawing.Bitmap]::FromFile((Resolve-Path $Path))
    try{
        $colors=@{}
        for($x=0;$x -lt $bmp.Width;$x+=20){
            for($y=0;$y -lt $bmp.Height;$y+=20){
                $colors[$bmp.GetPixel($x,$y).ToArgb()]=1
                if($colors.Count -gt 4){return $true}
            }
        }
        return $false
    }finally{$bmp.Dispose()}
}
function Save-Screenshot {
    param([string]$FileName)
    $file=Join-Path $OutputDir $FileName
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    Write-CommandFile @{Action='CaptureWindow';Path=$file}
    $deadline=(Get-Date).AddSeconds(10)
    do{
        if(Test-Path -LiteralPath $file){
            try{ if(Test-ImageHasDetail -Path $file){ $script:Report.Screenshots[$FileName]=$file; return } }catch{}
        }
        Start-Sleep -Milliseconds 120
    }while((Get-Date)-lt $deadline)
    throw "Screenshot was not rendered or appears blank: $FileName"
}
function Start-App {
    $settings=[ordered]@{Language='zh';ProvinceKey='Guangdong';CityKey='Shenzhen';DistrictKey='Longhua';RefreshSeconds=60;DrawerEdge='Left';DrawerExpanded=$true;DrawerTop=$null;DrawerScreenDeviceName=$null;SavedAt=(Get-Date).ToString('s')}
    $settings|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $OutputDir 'LonghuaWeatherWidget.ui-smoke.settings.json') -Encoding UTF8
    $args=@('-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',(Join-Path $script:ScriptRoot 'LonghuaWeatherWidget.ps1'),'-NoTopMost','-UiSmokeMode','-UiFixture','Live','-UiSmokeOutput',$OutputDir,'-UiSmokeDelayMs','700','-RefreshSeconds','60')
    $script:Process=Start-Process -FilePath 'powershell.exe' -ArgumentList $args -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $OutputDir 'widget.stdout.txt') -RedirectStandardError (Join-Path $OutputDir 'widget.stderr.txt')
    $script:Hwnd=Find-WindowByPid -ProcessId $script:Process.Id -TimeoutMs ($TimeoutSeconds*1000)
}
function Close-App {
    if($script:Hwnd -ne [IntPtr]::Zero){[RegionRenderWin32]::PostMessage($script:Hwnd,0x0010,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null}
    if($null -ne $script:Process){try{$script:Process.WaitForExit(4000)|Out-Null}catch{}; if(-not $script:Process.HasExited){Stop-Process -Id $script:Process.Id -Force -ErrorAction SilentlyContinue}}
}
function Start-Observer {
    Remove-Item -LiteralPath $script:ObserverStopPath,$script:ObserverOutPath -Force -ErrorAction SilentlyContinue
    $args=@('-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',(Join-Path $script:ScriptRoot 'loading-observer.ps1'),'-HwndValue',[string]$script:Hwnd.ToInt64(),'-OutPath',$script:ObserverOutPath,'-StopPath',$script:ObserverStopPath)
    $script:ObserverProcess=Start-Process -FilePath 'powershell.exe' -ArgumentList $args -PassThru -WindowStyle Hidden
}
function Stop-Observer {
    if($null -eq $script:ObserverProcess){return}
    New-Item -ItemType File -Path $script:ObserverStopPath -Force|Out-Null
    try{$script:ObserverProcess.WaitForExit(8000)|Out-Null}catch{}
    if(-not $script:ObserverProcess.HasExited){Stop-Process -Id $script:ObserverProcess.Id -Force -ErrorAction SilentlyContinue}
    if(Test-Path -LiteralPath $script:ObserverOutPath){$script:Report.Observer=Get-Content -LiteralPath $script:ObserverOutPath -Raw -Encoding UTF8|ConvertFrom-Json}
}
function Add-LoadingObservation([string]$LocationKey){ if(-not $script:Report.LoadingObservedByTarget.Contains($LocationKey)){$script:Report.LoadingObservedByTarget[$LocationKey]=0}; $script:Report.LoadingObservedByTarget[$LocationKey]=[int]$script:Report.LoadingObservedByTarget[$LocationKey]+1 }

$csv=Join-Path $RegionSmokeReportDir 'weather-smoke-200.csv'
if(-not (Test-Path -LiteralPath $csv)){throw "Region smoke CSV not found: $csv"}
$records=@(Import-Csv -LiteralPath $csv|Where-Object{$_.Category -in @('PASS','RETRY_PASS') -and $_.LocationKey -ne 'Guangdong|Shenzhen|Longhua'})
$targets=@(Select-RepresentativeRegions -Records $records -Count $RegionCount)
$script:Report.ActualRegionCount=$targets.Count

$index=0
foreach($region in $targets){
    $index++
    $row=[ordered]@{Index=$index;LocationKey=$region.LocationKey;ProvinceKey=$region.ProvinceKey;CityKey=$region.CityKey;DistrictKey=$region.DistrictKey;LoadingObserved=$false;SelectionChangedDelta=0;OldDataCleared=$false;FinalState='';Weather='';Temperature='';Error='';Pass=$false;Failure=''}
    try{
        Remove-Item -LiteralPath (Join-Path $OutputDir 'ui-smoke-command.json') -Force -ErrorAction SilentlyContinue
        Start-App
        Start-Observer
        Wait-State -States @('Loaded','Error') -LocationKey 'Guangdong|Shenzhen|Longhua' -TimeoutMs 90000 | Out-Null
        Find-ById 'ProvinceSelector' 10000 | Out-Null
        Find-ById 'CitySelector' 10000 | Out-Null
        Find-ById 'DistrictSelector' 10000 | Out-Null
        $before=Get-StatusMap
        $beforeSelection=[int]($before['SelectionChangedCount'] | ForEach-Object { if($_){$_}else{0} })
        Write-CommandFile @{Action='SelectLocation';ProvinceKey=$region.ProvinceKey;CityKey=$region.CityKey;DistrictKey=$region.DistrictKey}
        $loading=Wait-State -States @('Loading') -LocationKey $region.LocationKey -TimeoutMs 20000
        Add-LoadingObservation $region.LocationKey
        $row.LoadingObserved=$true
        $weatherDuring=Get-TextById 'WeatherDescription'
        $tempDuring=Get-TextById 'TemperatureText'
        $nearDuring=Get-TextById 'NearTermForecast'
        $row.OldDataCleared=($weatherDuring -match '正在获取天气|Fetching weather' -and $tempDuring -match '^--' -and $nearDuring -notmatch '暂不可用|unavailable')
        $final=Wait-State -States @('Loaded','Error') -LocationKey $region.LocationKey -TimeoutMs 90000
        $afterSelection=[int]($final['SelectionChangedCount'] | ForEach-Object { if($_){$_}else{0} })
        $row.SelectionChangedDelta=$afterSelection-$beforeSelection
        $row.FinalState=$final['State']
        $row.Weather=Get-TextById 'WeatherDescription'
        $row.Temperature=Get-TextById 'TemperatureText'
        $row.Error=Get-TextById 'ErrorPanel'
        if($row.SelectionChangedDelta -le 0){throw 'SelectionChangedCount did not increase.'}
        if(-not $row.OldDataCleared){throw "Old data not cleared during cross-region loading: weather=$weatherDuring temp=$tempDuring near=$nearDuring"}
        if($row.FinalState -eq 'Loaded' -and $row.Temperature -match '^--'){throw 'Loaded state still has missing temperature placeholder.'}
        if($row.FinalState -eq 'Error' -and $row.Error -notmatch '天气服务暂不可用|Weather service unavailable'){throw "Error state missing service unavailable text: $($row.Error)"}
        $row.Pass=$true
        $script:Report.SuccessCount++
        if($index -in @(1,4,7,10,13,16,20,24)){Save-Screenshot ('ui-region-{0:D2}.png' -f $index)}
    }catch{
        $row.Failure=$_.Exception.Message
        $script:Report.FailureCount++
        $script:Report.Failures += [pscustomobject]$row
    }finally{
        try{Stop-Observer}catch{}
        Close-App
        $script:Hwnd=[IntPtr]::Zero
        $script:Process=$null
    }
    $script:Report.Results += [pscustomobject]$row
}

$script:Report.CompletedAt=(Get-Date).ToString('s')
$script:Report.Result=if($script:Report.ActualRegionCount -eq $RegionCount -and $script:Report.FailureCount -eq 0){'PASS'}else{'FAIL'}
$script:Report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $OutputDir 'ui-region-render-smoke.json') -Encoding UTF8
$script:Report.Results|Export-Csv -LiteralPath (Join-Path $OutputDir 'ui-region-render-smoke.csv') -NoTypeInformation -Encoding UTF8
[pscustomobject]$script:Report|Select-Object Name,Result,OutputDir,ActualRegionCount,SuccessCount,FailureCount,@{Name='Screenshots';Expression={$_.Screenshots.Count}}|Format-List
if($script:Report.Result -ne 'PASS'){exit 1}
