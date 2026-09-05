#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
foreach ($file in Get-ChildItem $repoRoot -Filter '*.ps1' -Recurse -File) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
}
. (Join-Path $repoRoot 'kenk-vk-enricher-functions.ps1')

# Use synthetic cookies; never read the user's browser in tests.
function Get-FirefoxVkCookieHeader { return 'test_session=synthetic' }
$ctx = Build-Context (Join-Path $repoRoot 'profiles/test-offline')
$ctx.Browser = 'firefox'
Initialize-WebRequestHeaders $ctx
if ($ctx.WebRequestHeaders.ContainsKey('Cookie')) { throw 'Raw cookie header found' }
if (-not $ctx.WebRequestSession.Cookies.GetCookieHeader([uri]'https://vk.com/').Contains('synthetic')) {
    throw 'VK session cookie missing'
}
foreach ($url in @('https://example.org/', 'https://notvk.com/', 'https://vk.com.example.org/', 'https://userapi.com/', 'http://vk.com/')) {
    if ($ctx.WebRequestSession.Cookies.GetCookieHeader([uri]$url)) { throw "Cookie leaked to $url" }
}

$tokens = $null
$errors = $null
$mainAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'kenk-vk-enricher.ps1'), [ref]$tokens, [ref]$errors)
$settings = $mainAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Apply-Settings' }, $true)
. ([scriptblock]::Create($settings.Extent.Text))
$DownloadDelay = 0.4
$Browser = 'firefox'
$SkipVideos = [System.Management.Automation.SwitchParameter]$true
$RetryErrors = [System.Management.Automation.SwitchParameter]$false
$YTDLPExtraArgs = '--max-filesize 700M'
$OnlyMessageFolders = @('123,456', '456;789')
Apply-Settings $ctx
if ($ctx.DoDownloadVideo) { throw 'SkipVideos did not disable video' }
if (($ctx.MessageFolderFilter -join ',') -ne '123,456,789') { throw 'Folder filter incorrect' }

function Ensure-FileDb { throw 'Skipped video reached the database/download path' }
$result = @(DownloadVideoPlease 'https://vk.com/video1_1' $ctx)
if ($result.Count -ne 4 -or $result[3] -ne $false) { throw 'Unexpected skipped-video result' }
Write-Host 'PASS: syntax, cookie isolation, settings, folder selection, video skip'
