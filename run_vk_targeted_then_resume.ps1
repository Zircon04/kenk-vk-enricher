#Requires -Version 5.1
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$MessageIds,
    [ValidateSet("firefox", "chrome")]
    [string]$Browser = "firefox",
    [ValidateSet(360, 480)]
    [int]$MaxResolution = 480,
    [ValidatePattern('^[1-9][0-9]*[KMG]$')]
    [string]$MaxFilesize = "700M",
    [switch]$NoResume
)

$ErrorActionPreference = "Stop"

$RepoRoot = $PSScriptRoot
$ProfileName = "my_vk"
$LogsPath = Join-Path $RepoRoot "logs"
$EnricherPath = Join-Path $RepoRoot "kenk-vk-enricher.ps1"
$PhotosOnlyPath = Join-Path $RepoRoot "run_vk_photos_only.ps1"
$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$RunLogPath = Join-Path $LogsPath "vk_targeted_then_resume_$Timestamp.log"

function Write-RunLog([string]$Message) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line
    Add-Content -LiteralPath $RunLogPath -Value $line -Encoding UTF8
}

function Quote-Arg([string]$Value) {
    if ($null -eq $Value) { return '""' }
    if ($Value -eq "") { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '"', '\"') + '"'
}

New-Item -ItemType Directory -Path $LogsPath -Force | Out-Null
Set-Location -LiteralPath $RepoRoot

Write-RunLog "Targeted run started."
Write-RunLog "Message IDs: $($MessageIds -join ', ')"
Write-RunLog "Video limits: max-filesize=$MaxFilesize max-resolution=${MaxResolution}p browser=$Browser"

if (-not (Test-Path -LiteralPath $EnricherPath -PathType Leaf)) {
    throw "kenk-vk-enricher.ps1 not found: $EnricherPath"
}
if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot "profiles\$ProfileName") -PathType Container)) {
    throw "Profile not found. Run photos-only init first."
}

$targetedCombinedLog = Join-Path $LogsPath "vk_targeted_$Timestamp.combined.log"
$ytDlpExtraArgs = "--max-filesize $MaxFilesize -S res:$MaxResolution --format best[height<=$MaxResolution]"

$targetedArgs = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $EnricherPath,
    "-Profile", $ProfileName,
    "-MessagesOnly",
    "-Browser", $Browser,
    "-YTDLPExtraArgs", $ytDlpExtraArgs,
    "-OnlyMessageFolders", ($MessageIds -join ',')
)

Write-RunLog "Running targeted command."
$targetedArgLine = ($targetedArgs | ForEach-Object { Quote-Arg $_ }) -join " "
Write-RunLog "powershell.exe $targetedArgLine"
& powershell.exe @targetedArgs *> $targetedCombinedLog
$targetedExitCode = $LASTEXITCODE
Write-RunLog "Targeted run exit code: $targetedExitCode"

if ($targetedExitCode -ne 0) {
    Write-RunLog "Targeted run failed. Not resuming broad photos-only run."
    exit $targetedExitCode
}

if ($NoResume) {
    Write-RunLog "NoResume specified; stopping after targeted run."
    exit 0
}

if (-not (Test-Path -LiteralPath $PhotosOnlyPath -PathType Leaf)) {
    throw "run_vk_photos_only.ps1 not found: $PhotosOnlyPath"
}

Write-RunLog "Starting broad photos-only resume in background."
$resumeArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$PhotosOnlyPath`""
$resumeProc = Start-Process -FilePath powershell.exe `
    -ArgumentList $resumeArgs `
    -WorkingDirectory $RepoRoot `
    -WindowStyle Hidden `
    -PassThru
Write-RunLog "Broad photos-only resume PID: $($resumeProc.Id)"
exit 0
