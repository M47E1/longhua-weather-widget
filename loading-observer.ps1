[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][long]$HwndValue,
    [Parameter(Mandatory=$true)][string]$OutPath,
    [Parameter(Mandatory=$true)][string]$StopPath,
    [string]$TargetLocationKey = '',
    [string]$TargetDisplayName = '',
    [int]$PollIntervalMs = 75,
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
$stats = [ordered]@{
    PollCount = 0
    RootFoundCount = 0
    ValidReadCount = 0
    RootMissCount = 0
    ElementMissCount = 0
    ReadErrorCount = 0
    LastException = ''
    LoadingObservedCount = 0
    Samples = @()
}

function Ensure-OutputDirectory {
    param([string]$Path)
    $dir = Split-Path -Parent $Path
    if ([string]::IsNullOrWhiteSpace($dir)) { throw 'Output path must include a directory.' }
    New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
}

function Get-UiaTextById {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string]$AutomationId,
        [hashtable]$Stats
    )
    $condition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $AutomationId)
    $element = $Root.FindFirst([System.Windows.Automation.TreeScope]::Subtree, $condition)
    if ($null -eq $element) {
        $Stats.ElementMissCount++
        return [pscustomobject]@{ Text=''; IsVisible=$false }
    }
    $valuePattern = $null
    $text = [string]$element.Current.Name
    if ($element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$valuePattern)) {
        if (-not [string]::IsNullOrWhiteSpace($valuePattern.Current.Value)) { $text = [string]$valuePattern.Current.Value }
    }
    $rect = $element.Current.BoundingRectangle
    return [pscustomobject]@{ Text=$text; IsVisible=($rect.Width -gt 0 -and $rect.Height -gt 0 -and -not $element.Current.IsOffscreen) }
}

Ensure-OutputDirectory -Path $OutPath
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

try {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $StopPath)) {
        $stats.PollCount++
        try {
            $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$HwndValue)
            if ($null -eq $root) {
                $stats.RootMissCount++
                Start-Sleep -Milliseconds $PollIntervalMs
                continue
            }
            $stats.RootFoundCount++
            $itemStatus = [string]$root.Current.ItemStatus
            $location = Get-UiaTextById -Root $root -AutomationId 'LocationTitle' -Stats $stats
            $loading = Get-UiaTextById -Root $root -AutomationId 'LoadingPanel' -Stats $stats
            $weather = Get-UiaTextById -Root $root -AutomationId 'WeatherDescription' -Stats $stats
            $temp = Get-UiaTextById -Root $root -AutomationId 'TemperatureText' -Stats $stats
            $errorPanel = Get-UiaTextById -Root $root -AutomationId 'ErrorPanel' -Stats $stats
            $stats.ValidReadCount++

            $isLoading = ($itemStatus -match 'State=Loading' -or $loading.Text -match '加载|更新|Loading|Updating' -or $weather.Text -match '获取|Fetching|Loading|Updating')
            if ($isLoading) {
                $stats.LoadingObservedCount++
                if (@($stats.Samples).Count -lt 60) {
                    $stats.Samples += [pscustomobject]@{
                        At = (Get-Date).ToString('HH:mm:ss.fff')
                        LocationTitle = $location.Text
                        LocationKey = ($(if ($itemStatus -match 'LocationKey=([^;]+)') { $Matches[1] } else { '' }))
                        RequestId = ($(if ($itemStatus -match 'RequestId=([^;]+)') { $Matches[1] } else { '' }))
                        ItemStatus = $itemStatus
                        LoadingPanelVisible = [bool]$loading.IsVisible
                        WeatherDescription = $weather.Text
                        TemperatureText = $temp.Text
                        ErrorPanel = $errorPanel.Text
                        TargetLocationKey = $TargetLocationKey
                        TargetDisplayName = $TargetDisplayName
                    }
                }
            }
        } catch {
            $stats.ReadErrorCount++
            $stats.LastException = $_.Exception.Message
        }
        Start-Sleep -Milliseconds $PollIntervalMs
    }
} finally {
    $stats | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutPath -Encoding UTF8 -ErrorAction Stop
}
