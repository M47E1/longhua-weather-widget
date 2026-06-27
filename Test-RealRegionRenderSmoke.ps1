[CmdletBinding()]
param(
    [string]$RegionSmokeReportDir = '.\reports\region-smoke-200\20260626-091229',
    [string]$OutputDir = $null,
    [int]$RegionCount = 24
)
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($PSScriptRoot)){ $script:ScriptRoot=Split-Path -Parent $MyInvocation.MyCommand.Path } else { $script:ScriptRoot=$PSScriptRoot }
if([string]::IsNullOrWhiteSpace($OutputDir)){ $OutputDir=Join-Path $script:ScriptRoot ('reports\ui-smoke-real-render\{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
if(-not ('RealRenderWin32' -as [type])){
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices; using System.Text;
public static class RealRenderWin32 { public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam); [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; } [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc f, IntPtr l); [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint p); [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h); [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int c); [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out RECT r); [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l); }
"@
}
$settingsPath=Join-Path $script:ScriptRoot 'LonghuaWeatherWidget.settings.json'
$settingsHadFile=Test-Path -LiteralPath $settingsPath
$settingsBackup=if($settingsHadFile){Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8}else{$null}
$report=[ordered]@{StartedAt=(Get-Date).ToString('s');RegionSmokeReportDir=$RegionSmokeReportDir;OutputDir=$OutputDir;SelectedRegions=@();Coverage=[ordered]@{};Results=@();Screenshots=[ordered]@{};Failures=@();VisualCheck='NOT VERIFIED BY SCRIPT';SettingsRestored=$false}
function Restore-Settings{ if($settingsHadFile){Set-Content -LiteralPath $settingsPath -Value $settingsBackup -Encoding UTF8}elseif(Test-Path -LiteralPath $settingsPath){Remove-Item -LiteralPath $settingsPath -Force}; $report.SettingsRestored=$true }
function Find-WindowByPid([int]$ProcessId,[int]$TimeoutMs=18000){ $deadline=(Get-Date).AddMilliseconds($TimeoutMs); do{ $script:found=[IntPtr]::Zero; $cb=[RealRenderWin32+EnumWindowsProc]{param([IntPtr]$h,[IntPtr]$l) [uint32]$windowPid=0; [RealRenderWin32]::GetWindowThreadProcessId($h,[ref]$windowPid)|Out-Null; if([int]$windowPid -eq $ProcessId -and [RealRenderWin32]::IsWindowVisible($h)){ $script:found=$h; return $false}; return $true}; [RealRenderWin32]::EnumWindows($cb,[IntPtr]::Zero)|Out-Null; if($script:found -ne [IntPtr]::Zero){return $script:found}; Start-Sleep -Milliseconds 150 }while((Get-Date)-lt $deadline); throw "No window for PID $ProcessId" }
function Find-ElementById($root,[string]$id){ $c=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty,$id); $root.FindFirst([System.Windows.Automation.TreeScope]::Subtree,$c) }
function Get-ElementText($root,[string]$id){ $e=Find-ElementById $root $id; if($null -eq $e){return '<missing>'}; $name=[string]$e.Current.Name; $vp=$null; if($e.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$vp) -and -not [string]::IsNullOrWhiteSpace($vp.Current.Value)){return [string]$vp.Current.Value}; return $name }
function Get-Snapshot([IntPtr]$hwnd){ $root=[System.Windows.Automation.AutomationElement]::FromHandle($hwnd); $ids='LocationTitle','WeatherDescription','NearTermForecast','TemperatureText','WarningPanel','RainfallText','HumidityText','PressureText','WindText','LoadingPanel','ErrorPanel'; $by=[ordered]@{}; foreach($id in $ids){$by[$id]=Get-ElementText $root $id}; [pscustomobject]@{ById=$by} }
function Wait-Snapshot([IntPtr]$hwnd,[scriptblock]$predicate,[int]$TimeoutMs=26000){ $deadline=(Get-Date).AddMilliseconds($TimeoutMs); do{ $s=Get-Snapshot $hwnd; if(& $predicate $s){return $s}; Start-Sleep -Milliseconds 350 }while((Get-Date)-lt $deadline); throw 'Timed out waiting for rendered weather.' }
function Save-Screenshot([IntPtr]$hwnd,[string]$path){ $r=New-Object RealRenderWin32+RECT; if(-not [RealRenderWin32]::GetWindowRect($hwnd,[ref]$r)){throw 'GetWindowRect failed'}; $v=[System.Windows.Forms.SystemInformation]::VirtualScreen; $left=[Math]::Max($r.Left,$v.Left); $top=[Math]::Max($r.Top,$v.Top); $right=[Math]::Min($r.Right,$v.Right); $bottom=[Math]::Min($r.Bottom,$v.Bottom); $w=[Math]::Max(1,$right-$left); $h=[Math]::Max(1,$bottom-$top); $bmp=New-Object Drawing.Bitmap $w,$h; $g=[Drawing.Graphics]::FromImage($bmp); try{$g.CopyFromScreen($left,$top,0,0,$bmp.Size); $bmp.Save($path,[Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$bmp.Dispose()} }
function Add-Group([System.Collections.Generic.List[object]]$selected,[hashtable]$seen,[object[]]$items,[string]$tag,[int]$limit){ $added=0; foreach($item in $items){ if($added -ge $limit){break}; if($seen.ContainsKey($item.LocationKey)){continue}; $item | Add-Member -NotePropertyName UiSmokeTag -NotePropertyValue $tag -Force; $selected.Add($item)|Out-Null; $seen[$item.LocationKey]=$true; $added++ }; $report.Coverage[$tag]=$added }
function Select-RepresentativeRegions([object[]]$records){ $selected=New-Object System.Collections.Generic.List[object]; $seen=@{}; Add-Group $selected $seen @($records|Sort-Object @{Expression={$_.DisplayNameZh.Length};Descending=$true}) 'long-name' 4; Add-Group $selected $seen @($records|Where-Object{[double]$_.CurrentPrecipitation -eq 0 -and [double]$_.CurrentRain -eq 0 -and $_.CurrentDisplayText -match '当前无降雨'}) 'dry-current' 4; Add-Group $selected $seen @($records|Where-Object{[double]$_.CurrentPrecipitation -gt 0 -or [double]$_.CurrentRain -gt 0 -or ($_.NearTermForecast -notmatch '暂无' -and -not [string]::IsNullOrWhiteSpace($_.NearTermForecast))}) 'rain-or-forecast' 4; Add-Group $selected $seen @($records|Where-Object{[int]$_.Attempts -gt 1 -or $_.DataSource -ne 'Open-Meteo'}) 'retry-or-fallback' 4; Add-Group $selected $seen @($records|Group-Object -Property ProvinceKey,CityKey|Where-Object{$_.Count -gt 3}|Select-Object -First 1|ForEach-Object{$_.Group|Sort-Object DistrictKey}) 'similar-name' 4; Add-Group $selected $seen @($records|Sort-Object @{Expression={$_.DisplayNameEn.Length};Descending=$true}) 'english-mode' 4; Add-Group $selected $seen @($records) 'fill' ([Math]::Max(0,$RegionCount-$selected.Count)); @($selected|Select-Object -First $RegionCount) }
$records=@(Import-Csv -LiteralPath (Join-Path $RegionSmokeReportDir 'weather-smoke-200.csv')|Where-Object{$_.Category -in @('PASS','RETRY_PASS')})
$targets=@(Select-RepresentativeRegions $records)
$report.SelectedRegions=@($targets|Select-Object ProvinceKey,CityKey,DistrictKey,LocationKey,DisplayNameZh,DisplayNameEn,UiSmokeTag,CurrentDisplayText,NearTermForecast)
try{
  $index=0
  foreach($region in $targets){
    $index++
    $isEnglish=($region.UiSmokeTag -eq 'english-mode' -or $index -gt ($RegionCount-4))
    $settings=[ordered]@{Language=$(if($isEnglish){'en'}else{'zh'});ProvinceKey=$region.ProvinceKey;CityKey=$region.CityKey;DistrictKey=$region.DistrictKey;RefreshSeconds=60;DrawerEdge='Left';DrawerExpanded=$true;DrawerTop=$null;DrawerScreenDeviceName=$null;SavedAt=(Get-Date).ToString('s')}
    $settings|ConvertTo-Json|Set-Content -LiteralPath $settingsPath -Encoding UTF8
    $stdout=Join-Path $OutputDir ("region-{0:D2}.stdout.txt" -f $index); $stderr=Join-Path $OutputDir ("region-{0:D2}.stderr.txt" -f $index)
    $p=Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',(Join-Path $script:ScriptRoot 'LonghuaWeatherWidget.ps1'),'-NoTopMost','-RefreshSeconds','60') -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $hwnd=[IntPtr]::Zero
    try{
      $hwnd=Find-WindowByPid $p.Id
      $zhParts=@($region.DisplayNameZh -split '\s*/\s*'); $enParts=@($region.DisplayNameEn -split '\s*/\s*'); $targetDistrict=if($isEnglish -and $enParts.Count -ge 3){$enParts[2]}elseif($zhParts.Count -ge 3){$zhParts[2]}else{$region.DistrictKey}
      $snap=Wait-Snapshot $hwnd { param($s) ($s.ById.LocationTitle -like "*$targetDistrict*") -and ($s.ById.WeatherDescription -notmatch '加载中|Loading') -and ($s.ById.TemperatureText -notmatch '^--') }
      $failures=@()
      if($snap.ById.WeatherDescription -match '(?<![A-Za-z0-9_])(null|undefined|NaN|Infinity)(?![A-Za-z0-9_])|System\.Object\[\]|\{[A-Za-z0-9_]+\}|Exception|Cannot bind'){$failures+='dirty weather text'}
      if($snap.ById.NearTermForecast -eq '<missing>' -or $snap.ById.NearTermForecast -match 'System\.Object'){$failures+='near-term invalid'}
      if($snap.ById.WarningPanel -match '黄色预警|橙色预警|红色预警'){$failures+='model tip shown as official warning'}
      if($region.CurrentPrecipitation -eq '0' -and $region.CurrentRain -eq '0' -and $snap.ById.WeatherDescription -match '正在暴雨|当前暴雨|现在暴雨'){$failures+='dry current rainstorm false positive'}
      $shot=''
      if($index -in @(1,4,7,10,13,16,20,24)){ $shot=Join-Path $OutputDir ("region-{0:D2}.png" -f $index); Save-Screenshot $hwnd $shot; $report.Screenshots[("region-{0:D2}.png" -f $index)]=$shot }
      $row=[pscustomobject]@{Index=$index;LocationKey=$region.LocationKey;Language=$settings.Language;Tag=$region.UiSmokeTag;Title=$snap.ById.LocationTitle;Weather=$snap.ById.WeatherDescription;NearTerm=$snap.ById.NearTermForecast;Warning=$snap.ById.WarningPanel;Temperature=$snap.ById.TemperatureText;Screenshot=$shot;Pass=($failures.Count -eq 0);Failures=($failures -join '; ')}
      $report.Results+=$row
      if(-not $row.Pass){$report.Failures+=$row}
    }catch{ $row=[pscustomobject]@{Index=$index;LocationKey=$region.LocationKey;Language=$settings.Language;Tag=$region.UiSmokeTag;Title='';Weather='';NearTerm='';Warning='';Temperature='';Screenshot='';Pass=$false;Failures=$_.Exception.Message}; $report.Results+=$row; $report.Failures+=$row }
    finally{ if($hwnd -ne [IntPtr]::Zero){[RealRenderWin32]::PostMessage($hwnd,0x0010,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null}; try{$p.WaitForExit(3000)|Out-Null}catch{}; if(-not $p.HasExited){Stop-Process -Id $p.Id -Force} }
  }
}finally{ Restore-Settings }
$report.CompletedAt=(Get-Date).ToString('s')
$report.Result=if($report.Failures.Count -gt 0){'FAIL'}elseif([int]$report.Coverage['retry-or-fallback'] -lt 4){'PARTIAL'}else{'PASS'}
$report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $OutputDir 'real-render-ui-smoke.json') -Encoding UTF8
$report.Results|Export-Csv -LiteralPath (Join-Path $OutputDir 'real-render-ui-smoke.csv') -NoTypeInformation -Encoding UTF8
$lines=New-Object System.Collections.Generic.List[string]; $lines.Add('# Real Region Render UI Smoke')|Out-Null; $lines.Add("- Result: $($report.Result)")|Out-Null; $lines.Add("- Regions: $($report.Results.Count)")|Out-Null; $lines.Add("- Screenshots: $($report.Screenshots.Count)")|Out-Null; $lines.Add("- Visual check: $($report.VisualCheck)")|Out-Null; $lines.Add('')|Out-Null; $lines.Add('## Coverage')|Out-Null; foreach($k in $report.Coverage.Keys){$lines.Add("- ${k}: $($report.Coverage[$k])")|Out-Null}; $lines.Add('')|Out-Null; $lines.Add('## Screenshots')|Out-Null; foreach($k in $report.Screenshots.Keys){$lines.Add("- ${k}: $($report.Screenshots[$k])")|Out-Null}; $lines.Add('')|Out-Null; $lines.Add('## Failures')|Out-Null; if($report.Failures.Count -eq 0){$lines.Add('- None')|Out-Null}else{foreach($f in $report.Failures){$lines.Add("- $($f.LocationKey): $($f.Failures)")|Out-Null}}; $lines|Set-Content -LiteralPath (Join-Path $OutputDir 'real-render-ui-smoke.md') -Encoding UTF8
$report|Select-Object Result,OutputDir,@{Name='Regions';Expression={$_.Results.Count}},@{Name='Screenshots';Expression={$_.Screenshots.Count}},@{Name='Failures';Expression={$_.Failures.Count}}|Format-List
if($report.Result -eq 'FAIL'){exit 1}else{exit 0}
