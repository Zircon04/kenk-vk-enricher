#Requires -Version 5.1
param(
    [Parameter(Mandatory = $true)]
    [int]$TargetPid,
    [string]$ProfileName = "my_vk"
)

$ErrorActionPreference = "Stop"

$RepoRoot = $PSScriptRoot
$LogsPath = Join-Path $RepoRoot "logs"
$PhotosOnlyPath = Join-Path $RepoRoot "run_vk_photos_only.ps1"
$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$RunLogPath = Join-Path $LogsPath "watch_targeted_then_resume_$Timestamp.log"

function Write-RunLog([string]$Message) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line
    Add-Content -LiteralPath $RunLogPath -Value $line -Encoding UTF8
}

function Get-EnricherProcesses {
    Get-CimInstance Win32_Process -Filter "name = 'powershell.exe'" |
        Where-Object {
            $_.CommandLine -like "*kenk-vk-enricher.ps1*" -or
            $_.CommandLine -like "*run_vk_photos_only.ps1*"
        }
}

New-Item -ItemType Directory -Path $LogsPath -Force | Out-Null
Set-Location -LiteralPath $RepoRoot

Write-RunLog "Watcher started for targeted PID $TargetPid."

try {
    $target = [System.Diagnostics.Process]::GetProcessById($TargetPid)
    Write-RunLog "Waiting for targeted process to exit."
    $target.WaitForExit()
    $targetExitCode = $target.ExitCode
    if ($null -eq $targetExitCode -or $targetExitCode -eq "") {
        Write-RunLog "Targeted exit code is unavailable; check its log before resuming."
        $targetExitCode = 1
    }
    Write-RunLog "Targeted process exited with code $targetExitCode."
}
catch [System.ArgumentException] {
    Write-RunLog "Targeted PID $TargetPid is no longer available; check its log before resuming."
    $targetExitCode = 1
}

if ($targetExitCode -ne 0) {
    Write-RunLog "Targeted run did not finish cleanly; broad photos-only resume will not be started."
    exit $targetExitCode
}

if (-not (Test-Path -LiteralPath $PhotosOnlyPath -PathType Leaf)) {
    throw "run_vk_photos_only.ps1 not found: $PhotosOnlyPath"
}

$running = @(Get-EnricherProcesses | Where-Object {
    $_.ProcessId -ne $PID -and $_.CommandLine -like "*run_vk_photos_only.ps1*"
})
if ($running.Count -gt 0) {
    Write-RunLog "Photos-only resume is already running; not starting another copy."
    $running | ForEach-Object { Write-RunLog "Existing photos-only PID: $($_.ProcessId)" }
    exit 0
}

Write-RunLog "Starting broad photos-only resume without videos."
$resumeArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$PhotosOnlyPath`""
$resumeProc = Start-Process -FilePath powershell.exe `
    -ArgumentList $resumeArgs `
    -WorkingDirectory $RepoRoot `
    -WindowStyle Hidden `
    -PassThru
Write-RunLog "Broad photos-only resume PID: $($resumeProc.Id)"
exit 0
