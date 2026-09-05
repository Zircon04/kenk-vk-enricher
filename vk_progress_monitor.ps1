#Requires -Version 5.1
param(
    [string]$ProfileName = "my_vk",
    [string[]]$MessageIds = @(),
    [int]$IntervalSeconds = 30,
    [switch]$StopWhenIdle
)

$ErrorActionPreference = "Stop"

$RepoRoot = $PSScriptRoot
$ProfileRoot = Join-Path $RepoRoot "profiles\$ProfileName"
$LogsPath = Join-Path $RepoRoot "logs"
$TextStatusPath = Join-Path $LogsPath "vk_progress_status.txt"
$HtmlStatusPath = Join-Path $LogsPath "vk_progress_status.html"
$MonitorLogPath = Join-Path $LogsPath ("vk_progress_monitor_{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

function Write-MonitorLog([string]$Message) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -LiteralPath $MonitorLogPath -Value $line -Encoding UTF8
}

function Format-Bytes([Nullable[Int64]]$Bytes) {
    if ($null -eq $Bytes) { return "0 B" }
    if ($Bytes -ge 1GB) { return ("{0:N2} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N2} MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:N2} KB" -f ($Bytes / 1KB)) }
    return ("{0} B" -f $Bytes)
}

function Get-FilesSummary([string]$Path, [string[]]$Include = $null) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return [pscustomobject]@{ Count = 0; Bytes = 0 }
    }

    if ($Include) {
        $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Include $Include -ErrorAction SilentlyContinue)
    }
    else {
        $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue)
    }
    $bytes = ($files | Measure-Object Length -Sum).Sum
    if ($null -eq $bytes) { $bytes = 0 }
    return [pscustomobject]@{ Count = $files.Count; Bytes = [int64]$bytes }
}

function Get-ActiveWorkerProcesses {
    Get-CimInstance Win32_Process |
        Where-Object {
            $_.CommandLine -like "*kenk-vk-enricher.ps1*" -or
            $_.CommandLine -like "*run_vk_photos_only.ps1*" -or
            $_.CommandLine -like "*watch_targeted_then_resume.ps1*" -or
            $_.CommandLine -like "*yt-dlp*"
        } |
        Where-Object { $_.ProcessId -ne $PID }
}

function Get-LatestProfileLog {
    $profileLogsPath = Join-Path $ProfileRoot ".logs"
    if (-not (Test-Path -LiteralPath $profileLogsPath -PathType Container)) { return $null }
    Get-ChildItem -LiteralPath $profileLogsPath -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Html([string]$Text) {
    if ($null -eq $Text) { return "" }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

New-Item -ItemType Directory -Path $LogsPath -Force | Out-Null

$sourceRoot = Join-Path $ProfileRoot ".source\messages"
$allFolderTotals = @{}
Get-ChildItem -LiteralPath $sourceRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $allFolderTotals[$_.Name] = @(Get-ChildItem -LiteralPath $_.FullName -Filter "*.html" -File -ErrorAction SilentlyContinue).Count
}
$targetTotals = @{}
foreach ($id in $MessageIds) {
    if ($allFolderTotals.ContainsKey($id)) {
        $targetTotals[$id] = $allFolderTotals[$id]
    }
    else {
        $targetTotals[$id] = 0
    }
}
$targetTotalHtml = ($targetTotals.Values | Measure-Object -Sum).Sum
if ($null -eq $targetTotalHtml) { $targetTotalHtml = 0 }
$allTotalHtml = ($allFolderTotals.Values | Measure-Object -Sum).Sum
if ($null -eq $allTotalHtml) { $allTotalHtml = 0 }

Write-MonitorLog "Progress monitor started. Text: $TextStatusPath HTML: $HtmlStatusPath"

$idleTicks = 0
while ($true) {
    try {
        $now = Get-Date
        $active = @(Get-ActiveWorkerProcesses)
        $latestLog = Get-LatestProfileLog
        $logLines = @()
        if ($latestLog) {
            $logLines = @(Get-Content -LiteralPath $latestLog.FullName -ErrorAction SilentlyContinue)
        }

        $processedSet = New-Object "System.Collections.Generic.HashSet[string]"
        $processedByFolder = @{}
        $foldersStarted = New-Object "System.Collections.Generic.HashSet[string]"
        $currentFolder = ""
        $lastVideoDb = ""

        foreach ($line in $logLines) {
            if ($line -match "processing messages for folder ID (.+)$") {
                $folderId = $matches[1].Trim()
                [void]$foldersStarted.Add($folderId)
                $currentFolder = $folderId
            }
            if ($line -match "\\.source\\messages\\([^\\]+)\\([^\\\]]+\.html)") {
                $folderId = $matches[1]
                $fileName = $matches[2]
                $key = "$folderId/$fileName"
                if ($processedSet.Add($key)) {
                    if (-not $processedByFolder.ContainsKey($folderId)) { $processedByFolder[$folderId] = 0 }
                    $processedByFolder[$folderId]++
                }
            }
            if ($line -match "DB: total=") { $lastVideoDb = $line }
        }

        $targetProcessed = 0
        foreach ($id in $MessageIds) {
            if ($processedByFolder.ContainsKey($id)) { $targetProcessed += $processedByFolder[$id] }
        }
        $targetPercent = 0
        if ($targetTotalHtml -gt 0) {
            $targetPercent = [math]::Round(($targetProcessed * 100.0) / $targetTotalHtml, 1)
        }
        $allProcessed = $processedSet.Count
        $allPercent = 0
        if ($allTotalHtml -gt 0) {
            $allPercent = [math]::Round(($allProcessed * 100.0) / $allTotalHtml, 1)
        }

        $currentFolderProcessed = 0
        $currentFolderTotal = 0
        if ($currentFolder) {
            if ($processedByFolder.ContainsKey($currentFolder)) { $currentFolderProcessed = $processedByFolder[$currentFolder] }
            if ($allFolderTotals.ContainsKey($currentFolder)) { $currentFolderTotal = $allFolderTotals[$currentFolder] }
        }

        $images = Get-FilesSummary -Path (Join-Path $ProfileRoot "messages") -Include @("*.jpg", "*.jpeg", "*.png", "*.webp", "*.gif")
        $filesDl = Get-FilesSummary -Path (Join-Path $ProfileRoot "files-dl")
        $videosDl = Get-FilesSummary -Path (Join-Path $ProfileRoot "videos-dl")

        $ytDlp = @($active | Where-Object { $_.CommandLine -like "*yt-dlp*" } | Select-Object -First 1)
        $ytDlpText = ""
        if ($ytDlp.Count -gt 0) { $ytDlpText = $ytDlp[0].CommandLine }

        $activeText = if ($active.Count -gt 0) {
            ($active | ForEach-Object { "{0} PID={1} started={2}" -f $_.Name, $_.ProcessId, $_.CreationDate }) -join "`r`n"
        }
        else {
            "No active worker processes found."
        }

        $logAge = ""
        if ($latestLog) {
            $age = New-TimeSpan -Start $latestLog.LastWriteTime -End $now
            $logAge = "{0:N0}s ago" -f $age.TotalSeconds
        }

        $folderRowsText = foreach ($id in $MessageIds) {
            $done = 0
            if ($processedByFolder.ContainsKey($id)) { $done = $processedByFolder[$id] }
            $total = $targetTotals[$id]
            $pct = if ($total -gt 0) { [math]::Round(($done * 100.0) / $total, 1) } else { 0 }
            "{0}: {1}/{2} HTML ({3}%)" -f $id, $done, $total, $pct
        }

        $text = @"
VK enrich progress
Updated: $($now.ToString("yyyy-MM-dd HH:mm:ss"))

Active workers:
$activeText

Latest profile log: $($latestLog.FullName)
Latest log activity: $logAge
Current folder: $currentFolder
Current folder progress: $currentFolderProcessed / $currentFolderTotal HTML
Latest-run all-message progress: $allProcessed / $allTotalHtml HTML ($allPercent%)
Targeted progress: $targetProcessed / $targetTotalHtml HTML ($targetPercent%)
Folders started in latest run: $($foldersStarted.Count)
Last video DB line: $lastVideoDb

Downloaded so far:
Message images: $($images.Count) files, $(Format-Bytes $images.Bytes)
files-dl: $($filesDl.Count) files, $(Format-Bytes $filesDl.Bytes)
videos-dl: $($videosDl.Count) files, $(Format-Bytes $videosDl.Bytes)

Current yt-dlp:
$ytDlpText

Target folders:
$($folderRowsText -join "`r`n")
"@
        Set-Content -LiteralPath $TextStatusPath -Value $text -Encoding UTF8

        $folderRowsHtml = foreach ($id in $MessageIds) {
            $done = 0
            if ($processedByFolder.ContainsKey($id)) { $done = $processedByFolder[$id] }
            $total = $targetTotals[$id]
            $pct = if ($total -gt 0) { [math]::Round(($done * 100.0) / $total, 1) } else { 0 }
            "<tr><td>$(Html $id)</td><td>$done</td><td>$total</td><td>$pct%</td></tr>"
        }
        $activeHtml = ($active | ForEach-Object {
            "<tr><td>$(Html $_.Name)</td><td>$($_.ProcessId)</td><td>$(Html ([string]$_.CreationDate))</td><td><code>$(Html $_.CommandLine)</code></td></tr>"
        }) -join "`r`n"
        if (-not $activeHtml) { $activeHtml = "<tr><td colspan='4'>No active worker processes found.</td></tr>" }

        $html = @"
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="$IntervalSeconds">
<title>VK enrich progress</title>
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #202124; background: #f7f7f8; }
h1 { font-size: 24px; margin: 0 0 16px; }
h2 { font-size: 17px; margin: 24px 0 8px; }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 12px; }
.card { background: #fff; border: 1px solid #ddd; border-radius: 8px; padding: 14px; }
.label { color: #666; font-size: 12px; text-transform: uppercase; }
.value { font-size: 22px; margin-top: 4px; }
.bar { height: 16px; background: #e5e7eb; border-radius: 8px; overflow: hidden; }
.fill { height: 100%; width: $targetPercent%; background: #2563eb; }
table { width: 100%; border-collapse: collapse; background: #fff; }
th, td { border: 1px solid #ddd; padding: 7px 9px; text-align: left; vertical-align: top; }
th { background: #eceff3; }
code, pre { white-space: pre-wrap; overflow-wrap: anywhere; }
</style>
</head>
<body>
<h1>VK enrich progress</h1>
<div class="grid">
<div class="card"><div class="label">Updated</div><div class="value">$($now.ToString("HH:mm:ss"))</div></div>
<div class="card"><div class="label">Current folder</div><div class="value">$(Html $currentFolder)</div></div>
<div class="card"><div class="label">Current folder HTML</div><div class="value">$currentFolderProcessed / $currentFolderTotal</div></div>
<div class="card"><div class="label">All messages HTML</div><div class="value">$allProcessed / $allTotalHtml ($allPercent%)</div></div>
<div class="card"><div class="label">Targeted HTML</div><div class="value">$targetProcessed / $targetTotalHtml ($targetPercent%)</div></div>
</div>
<h2>All Message Progress</h2>
<div class="bar"><div class="fill" style="width: $allPercent%;"></div></div>
<h2>Targeted progress</h2>
<div class="bar"><div class="fill"></div></div>
<h2>Downloaded</h2>
<table>
<tr><th>Type</th><th>Files</th><th>Size</th></tr>
<tr><td>Message images</td><td>$($images.Count)</td><td>$(Format-Bytes $images.Bytes)</td></tr>
<tr><td>files-dl</td><td>$($filesDl.Count)</td><td>$(Format-Bytes $filesDl.Bytes)</td></tr>
<tr><td>videos-dl</td><td>$($videosDl.Count)</td><td>$(Format-Bytes $videosDl.Bytes)</td></tr>
</table>
<h2>Run State</h2>
<table>
<tr><th>Latest profile log</th><td><code>$(Html $latestLog.FullName)</code></td></tr>
<tr><th>Latest log activity</th><td>$(Html $logAge)</td></tr>
<tr><th>Folders started</th><td>$($foldersStarted.Count)</td></tr>
<tr><th>Last video DB line</th><td><code>$(Html $lastVideoDb)</code></td></tr>
<tr><th>Current yt-dlp</th><td><code>$(Html $ytDlpText)</code></td></tr>
</table>
<h2>Target Folders</h2>
<table>
<tr><th>Folder</th><th>Processed HTML</th><th>Total HTML</th><th>Percent</th></tr>
$($folderRowsHtml -join "`r`n")
</table>
<h2>Processes</h2>
<table>
<tr><th>Name</th><th>PID</th><th>Started</th><th>Command</th></tr>
$activeHtml
</table>
</body>
</html>
"@
        Set-Content -LiteralPath $HtmlStatusPath -Value $html -Encoding UTF8

        if ($StopWhenIdle -and $active.Count -eq 0) {
            $idleTicks++
            if ($idleTicks -ge 2) {
                Write-MonitorLog "No active workers; monitor exiting."
                break
            }
        }
        else {
            $idleTicks = 0
        }
    }
    catch {
        Write-MonitorLog "Monitor iteration error: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds $IntervalSeconds
}
