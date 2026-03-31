param(
    [string]$ResourceGroup = 'rg-dns-poc',
    [string[]]$AppNames = @(
        'webapp-poc-us-yjpkzjlqt4dou',
        'webapp-poc-uk-yjpkzjlqt4dou'
    )
)

$ErrorActionPreference = 'Stop'

function Get-AppSettingValue {
    param([array]$Settings, [string]$Name, [string]$Default = '')
    $m = $Settings | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if ($m) { return $m.value }
    return $Default
}

foreach ($app in $AppNames) {
    Write-Host "Publishing friendly content to $app..." -ForegroundColor Cyan

    $settings = az webapp config appsettings list -g $ResourceGroup -n $app -o json | ConvertFrom-Json
    $siteTitle = Get-AppSettingValue -Settings $settings -Name 'POC_SITE_TITLE' -Default 'Zava Azure DNS POC'
    $regionName = Get-AppSettingValue -Settings $settings -Name 'POC_REGION_NAME' -Default 'unknown'
    $regionDisplayName = Get-AppSettingValue -Settings $settings -Name 'POC_REGION_DISPLAY_NAME' -Default $regionName
    $regionRole = Get-AppSettingValue -Settings $settings -Name 'POC_REGION_ROLE' -Default 'active'
    $publicDomain = Get-AppSettingValue -Settings $settings -Name 'POC_PUBLIC_DNS_ZONE' -Default ''

    $tempRoot = Join-Path $env:TEMP ("zava-friendly-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    $index = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>$siteTitle</title>
  <style>
    body { font-family: Segoe UI, Arial, sans-serif; margin: 0; padding: 24px; background: #f3f8fb; color: #163047; }
    .card { max-width: 760px; margin: 0 auto; background: #fff; border: 1px solid #d9e6ef; border-radius: 16px; padding: 24px; }
    h1 { margin-top: 0; }
    code { background: #eef5fb; padding: 2px 6px; border-radius: 6px; }
  </style>
</head>
<body>
  <div class="card">
    <h1>$regionDisplayName</h1>
    <p>App: <strong>$app</strong></p>
    <p>Region code: <strong>$regionName</strong></p>
    <p>Role: <strong>$regionRole</strong></p>
    <p>Health endpoint: <code>/health.json</code></p>
    <p>Metadata endpoint: <code>/metadata.json</code></p>
  </div>
</body>
</html>
"@

    $metadata = [ordered]@{
        siteTitle = $siteTitle
        appName = $app
        region = $regionName
        regionDisplayName = $regionDisplayName
        role = $regionRole
        publicDnsZone = $publicDomain
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json -Depth 4

    $health = [ordered]@{
        status = 'ok'
        appName = $app
        region = $regionName
        regionDisplayName = $regionDisplayName
        role = $regionRole
        publicDnsZone = $publicDomain
        deployedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json -Depth 4

    Set-Content -Path (Join-Path $tempRoot 'index.html') -Value $index -Encoding UTF8
    Set-Content -Path (Join-Path $tempRoot 'metadata.json') -Value $metadata -Encoding UTF8
    Set-Content -Path (Join-Path $tempRoot 'health.json') -Value $health -Encoding UTF8
    Set-Content -Path (Join-Path $tempRoot 'region.txt') -Value "$regionDisplayName`nregion=$regionName`nrole=$regionRole`napp=$app" -Encoding UTF8
    Set-Content -Path (Join-Path $tempRoot 'web.config') -Value "<?xml version='1.0' encoding='utf-8'?><configuration><system.webServer><defaultDocument enabled='true'><files><clear/><add value='index.html'/></files></defaultDocument><staticContent><mimeMap fileExtension='.json' mimeType='application/json' /><mimeMap fileExtension='.txt' mimeType='text/plain' /></staticContent></system.webServer></configuration>" -Encoding UTF8

    $zipPath = Join-Path $env:TEMP ("$app-friendly.zip")
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Compress-Archive -Path (Join-Path $tempRoot '*') -DestinationPath $zipPath -Force

    az webapp deploy -g $ResourceGroup -n $app --src-path $zipPath --type zip --clean true --restart true --track-status true --output none

    Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Published friendly content to $app" -ForegroundColor Green
}

Write-Host "Done." -ForegroundColor Green
