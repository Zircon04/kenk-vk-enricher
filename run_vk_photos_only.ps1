#Requires -Version 5.1
param(
    [string]$ZipPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'vk-export.zip'),
    [switch]$ResetProfile,
    [ValidateRange(1, 3)]
    [int]$MaxAttempts = 3,
    [ValidateRange(1, 1440)]
    [int]$InactivityTimeoutMinutes = 10
)

$ErrorActionPreference = "Stop"

$RepoRoot = $PSScriptRoot
$ProfileName = "my_vk"
$ProfilesRoot = Join-Path $RepoRoot "profiles"
$ProfilePath = Join-Path $ProfilesRoot $ProfileName
$EnricherPath = Join-Path $RepoRoot "kenk-vk-enricher.ps1"
$LogsPath = Join-Path $RepoRoot "logs"
$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$LogPath = Join-Path $LogsPath "vk_photos_only_$Timestamp.log"

function Write-RunLog([string]$Message) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Quote-Arg([string]$Value) {
    if ($null -eq $Value) { return '""' }
    if ($Value -eq "") { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Quote-PSString([string]$Value) {
    return "'" + ($Value -replace "'", "''") + "'"
}

function Format-InvocationToken([string]$Value) {
    $parameterTokens = @(
        "-Init",
        "-Profile",
        "-SkipPhotos",
        "-SkipVideos",
        "-Browser",
        "-YTDLPExtraArgs",
        "-RetryErrors",
        "-ReportOnly"
    )
    if ($parameterTokens -contains $Value) { return $Value }
    return Quote-PSString $Value
}

function Get-LatestActivityTime([string[]]$KnownFiles, [string]$ProfilePath, [datetime]$Fallback) {
    $latest = $Fallback
    foreach ($file in $KnownFiles) {
        if (Test-Path -LiteralPath $file) {
            $item = Get-Item -LiteralPath $file
            if ($item.LastWriteTime -gt $latest) { $latest = $item.LastWriteTime }
        }
    }

    $profileLogs = Join-Path $ProfilePath ".logs"
    if (Test-Path -LiteralPath $profileLogs) {
        $lastProfileLog = Get-ChildItem -LiteralPath $profileLogs -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($null -ne $lastProfileLog -and $lastProfileLog.LastWriteTime -gt $latest) {
            $latest = $lastProfileLog.LastWriteTime
        }
    }
    return $latest
}

function Append-FileToRunLog([string]$Title, [string]$Path) {
    Add-Content -LiteralPath $LogPath -Value ""
    Add-Content -LiteralPath $LogPath -Value "===== $Title ====="
    if (Test-Path -LiteralPath $Path) {
        Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue | Add-Content -LiteralPath $LogPath -Encoding UTF8
    } else {
        Add-Content -LiteralPath $LogPath -Value "(missing)"
    }
}

function Stop-ChildProcess([int]$ProcessId) {
    Write-RunLog "Stopping process $ProcessId after inactivity timeout."
    Stop-Process -Id $ProcessId -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 10
    $stillRunning = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -ne $stillRunning) {
        Write-RunLog "Process $ProcessId did not stop cleanly; forcing stop."
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-EnricherWithRetry([string[]]$EnricherArgs) {
    $powerShellExe = (Get-Command powershell.exe).Source

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $attemptLogPath = Join-Path $LogsPath "vk_photos_only_$Timestamp.attempt$attempt.combined.log"
        if (Test-Path -LiteralPath $attemptLogPath) { Remove-Item -LiteralPath $attemptLogPath -Force }

        $command = "& $(Quote-PSString $EnricherPath)"
        foreach ($arg in $EnricherArgs) {
            $command += " $(Format-InvocationToken $arg)"
        }
        $command += " *> $(Quote-PSString $attemptLogPath)"

        $psArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $command)
        $argLine = ($psArgs | ForEach-Object { Quote-Arg $_ }) -join " "

        Write-RunLog "Attempt $attempt of ${MaxAttempts}: powershell.exe $argLine"
        $startTime = Get-Date
        $lastActivity = $startTime
        $timedOut = $false

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $powerShellExe
        $psi.Arguments = $argLine
        $psi.WorkingDirectory = $RepoRoot
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $null = $proc.Start()

        while (-not $proc.HasExited) {
            Start-Sleep -Seconds 15
            $proc.Refresh()
            $latest = Get-LatestActivityTime @($attemptLogPath) $ProfilePath $lastActivity
            if ($latest -gt $lastActivity) { $lastActivity = $latest }

            $idleMinutes = ((Get-Date) - $lastActivity).TotalMinutes
            if ($idleMinutes -ge $InactivityTimeoutMinutes) {
                $timedOut = $true
                Write-RunLog ("No log activity for {0:N1} minutes." -f $idleMinutes)
                Stop-ChildProcess $proc.Id
                break
            }
        }

        if (-not $timedOut) {
            $proc.WaitForExit()
            $proc.Refresh()
        }

        Append-FileToRunLog "attempt $attempt combined stdout/stderr" $attemptLogPath

        $exitCode = if ($timedOut) { 124 } else { $proc.ExitCode }
        Write-RunLog "Attempt $attempt finished with exit code $exitCode."

        if ($exitCode -eq 0) { return 0 }
        if ($attempt -lt $MaxAttempts) {
            Write-RunLog "Retrying after failed or stalled attempt."
            Start-Sleep -Seconds 10
        }
    }

    return 1
}

function Format-Bytes([double]$Bytes) {
    if ($Bytes -ge 1GB) { return "{0:N2} GiB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MiB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KiB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Write-ProfileSummary {
    $indexPath = Join-Path $ProfilePath "index.html"
    $files = @()
    if (Test-Path -LiteralPath $ProfilePath) {
        $files = @(Get-ChildItem -LiteralPath $ProfilePath -Recurse -File -ErrorAction SilentlyContinue)
    }

    $totalSize = ($files | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $totalSize) { $totalSize = 0 }

    $imageExt = @(".jpg", ".jpeg", ".png", ".webp", ".gif")
    $mediaExt = @(".mp4", ".webm", ".ogg", ".mp3")
    $imageCount = @($files | Where-Object { $imageExt -contains $_.Extension.ToLowerInvariant() }).Count
    $mediaCount = @($files | Where-Object { $mediaExt -contains $_.Extension.ToLowerInvariant() }).Count

    Write-RunLog "Result index.html: $indexPath"
    Write-RunLog "Profile size: $(Format-Bytes $totalSize)"
    Write-RunLog "Images found (jpg/jpeg/png/webp/gif): $imageCount"
    Write-RunLog "Media found (mp4/webm/ogg/mp3): $mediaCount"
    Write-RunLog "Top 30 largest files:"

    $files |
        Sort-Object Length -Descending |
        Select-Object -First 30 |
        ForEach-Object {
            Write-RunLog ("  {0,12}  {1}" -f (Format-Bytes $_.Length), $_.FullName)
        }
}

Set-Location -LiteralPath $RepoRoot
New-Item -ItemType Directory -Path $LogsPath -Force | Out-Null
New-Item -ItemType Directory -Path $ProfilesRoot -Force | Out-Null

Write-RunLog "Photos-only wrapper started."
Write-RunLog "Repository root: $RepoRoot"
Write-RunLog "Log file: $LogPath"

if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
    throw "VK archive not found: $ZipPath"
}
if (-not (Test-Path -LiteralPath $EnricherPath -PathType Leaf)) {
    throw "kenk-vk-enricher.ps1 not found: $EnricherPath"
}

if ($ResetProfile) {
    $expectedProfilePath = Join-Path (Resolve-Path -LiteralPath $ProfilesRoot) $ProfileName
    if (Test-Path -LiteralPath $ProfilePath) {
        $resolvedProfilePath = (Resolve-Path -LiteralPath $ProfilePath).Path
        if ($resolvedProfilePath -ne $expectedProfilePath) {
            throw "Refusing to remove unexpected profile path: $resolvedProfilePath"
        }
        Write-RunLog "ResetProfile specified; removing only: $resolvedProfilePath"
        Remove-Item -LiteralPath $resolvedProfilePath -Recurse -Force
    }
}

if (Test-Path -LiteralPath $ProfilePath) {
    $args = @("-Profile", $ProfileName, "-SkipVideos", "-Browser", "firefox")
} else {
    $args = @("-Init", $ZipPath, "-Profile", $ProfileName, "-SkipVideos", "-Browser", "firefox")
}

$result = Invoke-EnricherWithRetry $args
Write-ProfileSummary

if ($result -ne 0) {
    Write-RunLog "Photos-only processing failed after $MaxAttempts attempts."
    exit $result
}

Write-RunLog "Photos-only processing finished successfully."
exit 0
