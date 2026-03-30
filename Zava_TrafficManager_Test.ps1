#Requires -Version 7.0
# ============================================================================
# Zava Azure DNS POC — Traffic Manager Test Suite
# ============================================================================
# Tests all three Traffic Manager routing scenarios from two geographic
# locations simultaneously:
#
#   US client  → runs on your local machine (assumes US network location)
#   EU client  → runs via a temporary Azure Container Instance in UK South
#
# ACI containers are created, used, and deleted per test session.
# The /metadata.json endpoint on each web app identifies which backend responded.
#
# Scenarios:
#   Failover  (Priority)   — US=primary, UK=backup. Disables US to prove failover.
#   Geographic (Geo)       — US/CA/MX→US app, GB/WORLD→UK app.
#   Weighted               — 70% US, 30% UK. Statistical distribution check.
#
# Usage:
#   .\Zava_TrafficManager_Test.ps1                      # interactive menu
#   .\Zava_TrafficManager_Test.ps1 -Scenario Failover
#   .\Zava_TrafficManager_Test.ps1 -Scenario Geo   -Iterations 20
#   .\Zava_TrafficManager_Test.ps1 -Scenario All
#   .\Zava_TrafficManager_Test.ps1 -Scenario Weighted -SkipAci  # local only
# ============================================================================

param(
    [Parameter(HelpMessage = 'Scenario to test: Failover, Geo, Weighted, or All')]
    [ValidateSet('Failover', 'Geo', 'Weighted', 'All', '')]
    [string]$Scenario = '',

    [Parameter(HelpMessage = 'Resource group where Traffic Manager profiles live')]
    [string]$ResourceGroup = 'rg-dns-poc',

    [Parameter(HelpMessage = 'Domain (e.g. zava-dnspoc-001.com). Auto-discovered from deployment-output.json if omitted.')]
    [string]$Domain = '',

    [Parameter(HelpMessage = 'Number of HTTP probe requests per run (min 5)')]
    [ValidateRange(5, 200)]
    [int]$Iterations = 15,

    [Parameter(HelpMessage = 'Skip the ACI-based EU probe (local machine only)')]
    [switch]$SkipAci,

    [Parameter(HelpMessage = 'Leave ACI containers running after the test (for debugging)')]
    [switch]$SkipCleanup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================================
# CONSTANTS — match infrastructure/main.bicep variable names
# ============================================================================
$TmFailoverProfile      = 'tm-poc-failover'
$TmGeoProfile           = 'tm-poc-geo'
$TmWeightedProfile      = 'tm-poc-weighted'
$TmFailoverEndpointUs   = 'us-primary'
$AciImage               = 'mcr.microsoft.com/powershell:7.4'
$AciLocation            = 'uksouth'       # EU probe region

# ============================================================================
# DISPLAY HELPERS
# ============================================================================
function Write-Banner {
    param([string]$Text, [ConsoleColor]$Color = 'Cyan')
    $line = '═' * 58
    Write-Host ""
    Write-Host "  $line" -ForegroundColor $Color
    Write-Host "  $Text" -ForegroundColor $Color
    Write-Host "  $line" -ForegroundColor $Color
    Write-Host ""
}

function Write-Step ([string]$Text) {
    Write-Host "  ▶ $Text" -ForegroundColor Yellow
}

function Write-Ok ([string]$Text) {
    Write-Host "  ✓ $Text" -ForegroundColor Green
}

function Write-Warn ([string]$Text) {
    Write-Host "  ⚠ $Text" -ForegroundColor Yellow
}

function Show-Distribution {
    param([string[]]$Results, [string]$Label, [string]$Expected = '')
    $total = $Results.Count
    if ($total -eq 0) { Write-Warn "No results for: $Label"; return }

    $groups = $Results | Group-Object | Sort-Object Count -Descending
    Write-Host ""
    Write-Host "  ── $Label ($total requests) ──" -ForegroundColor White
    foreach ($g in $groups) {
        $pct = [Math]::Round(($g.Count / $total) * 100)
        $bars = '█' * [int][Math]::Max(1, $pct / 4)
        $color = if ($g.Name -match 'ERROR') { 'Red' } elseif ($pct -ge 60) { 'Green' } else { 'Cyan' }
        Write-Host ("    {0,-30} {1,3}%  {2}" -f $g.Name, $pct, $bars) -ForegroundColor $color
    }
    if ($Expected) {
        Write-Host "    Expected: $Expected" -ForegroundColor Gray
    }
}

# ============================================================================
# DEPLOYMENT INFO DISCOVERY
# ============================================================================
function Get-DeploymentDomain {
    param([string]$Override)
    if ($Override) { return $Override }

    # 1. Fixed file saved by deploy.ps1
    $fixed = Join-Path $PSScriptRoot 'infrastructure\deployment-output.json'
    if (Test-Path $fixed) {
        $data = Get-Content $fixed -Raw | ConvertFrom-Json
        $d = if ($data.publicDnsZoneName.value) { $data.publicDnsZoneName.value } else { $data.publicDnsZoneName }
        if ($d) {
            Write-Host "  Domain auto-discovered: $d  (from infrastructure/deployment-output.json)" -ForegroundColor Gray
            return $d
        }
    }

    # 2. Most recent timestamped file
    $latest = Get-ChildItem -Path $PSScriptRoot -Filter 'deployment-outputs-*.json' -Recurse -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) {
        $data = Get-Content $latest.FullName -Raw | ConvertFrom-Json
        $d = if ($data.publicDnsZoneName.value) { $data.publicDnsZoneName.value } else { $data.publicDnsZoneName }
        if ($d) {
            Write-Host "  Domain auto-discovered: $d  (from $($latest.Name))" -ForegroundColor Gray
            return $d
        }
    }

    # 3. Prompt
    return (Read-Host "  Enter domain (e.g. zava-dnspoc-001.com)").Trim()
}

# ============================================================================
# LOCAL PROBE — runs HTTP requests on this machine
# ============================================================================
function Invoke-LocalProbe {
    param([string]$Url, [int]$N, [string]$Label)

    Write-Step "Local probe: $Label  ($N × GET $Url/metadata.json)"
    $results = [System.Collections.Generic.List[string]]::new()

    for ($i = 1; $i -le $N; $i++) {
        try {
            $r = Invoke-WebRequest -Uri "$Url/metadata.json" -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
            $j = $r.Content | ConvertFrom-Json
            $hit = "$($j.regionDisplayName) [$($j.region)]"
            $results.Add($hit)
            Write-Host ("    [{0,2}/{1}] {2}" -f $i, $N, $hit) -ForegroundColor Gray
        }
        catch {
            $results.Add('ERROR')
            Write-Host ("    [{0,2}/{1}] ERROR: {2}" -f $i, $N, $_.Exception.Message) -ForegroundColor Red
        }
        if ($i -lt $N) { Start-Sleep -Milliseconds 600 }
    }
    return [string[]]$results
}

# ============================================================================
# ACI PROBE — spins up a container in UK South and runs the same probe remotely
# This is key for Geographic routing: the container gets a UK IP, so TM routes
# its DNS queries to the UK-mapped endpoint.
# ============================================================================
function Invoke-AciProbe {
    param([string]$Url, [int]$N)

    if ($SkipAci) {
        Write-Warn "ACI probe skipped (-SkipAci flag set)."
        return $null
    }

    Write-Step "EU probe via ACI in $AciLocation  ($N × GET $Url/metadata.json)"
    Write-Host "    Spawning temporary container — image pull ~60 s on first run." -ForegroundColor Gray

    # Script that runs INSIDE the ACI container.
    # Uses single-quote heredoc so outer PS variables are NOT expanded here.
    $aciScript = @'
$url = $env:TEST_URL
$n   = [int]$env:TEST_N
$results = [System.Collections.Generic.List[string]]::new()
for ($i = 1; $i -le $n; $i++) {
    try {
        $r   = Invoke-WebRequest -Uri "$url/metadata.json" -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
        $j   = $r.Content | ConvertFrom-Json
        $hit = "$($j.regionDisplayName) [$($j.region)]"
        $results.Add($hit)
        Write-Output ("[$i/$n] $hit")
    } catch {
        $results.Add('ERROR')
        Write-Output ("[$i/$n] ERROR")
    }
    if ($i -lt $n) { Start-Sleep -Seconds 1 }
}
Write-Output '--- SUMMARY ---'
$results | Group-Object | Sort-Object Count -Descending | ForEach-Object {
    $pct = [Math]::Round(($_.Count / $results.Count) * 100)
    Write-Output ("{0,3}%  {1}  ({2}x)" -f $pct, $_.Name, $_.Count)
}
'@

    $encoded  = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($aciScript))
    $aciName  = "aci-tmtest-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"

    Write-Host "    Container name: $aciName" -ForegroundColor Gray

    $null = az container create `
        --name $aciName `
        --resource-group $ResourceGroup `
        --image $AciImage `
        --location $AciLocation `
        --cpu 0.5 --memory 0.5 `
        --restart-policy Never `
        --command-line "pwsh -NonInteractive -EncodedCommand $encoded" `
        --environment-variables TEST_URL=$Url TEST_N=$N `
        --output none 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Failed to create ACI '$aciName'. EU probe skipped."
        return $null
    }

    # Poll until container terminates (max 5 minutes)
    $timeout = 300; $elapsed = 0
    do {
        Start-Sleep -Seconds 10; $elapsed += 10
        $state = az container show --name $aciName --resource-group $ResourceGroup `
                    --query instanceView.state -o tsv 2>$null
        Write-Host "    [${elapsed}s] ACI state: $state" -ForegroundColor Gray
    } while ($state -eq 'Running' -and $elapsed -lt $timeout)

    $logs = az container logs --name $aciName --resource-group $ResourceGroup 2>&1

    if (-not $SkipCleanup) {
        $null = az container delete --name $aciName --resource-group $ResourceGroup --yes --output none 2>&1
        Write-Ok "ACI '$aciName' deleted."
    } else {
        Write-Warn "ACI '$aciName' kept (-SkipCleanup). Delete manually when done."
    }

    return $logs
}

function Show-AciResults {
    param([string[]]$Logs, [string]$Label, [string]$Expected = '')
    Write-Host ""
    Write-Host "  ── ACI probe ($AciLocation) — $Label ──" -ForegroundColor White
    if (-not $Logs) {
        Write-Warn "No ACI results."
        return
    }
    foreach ($line in $Logs) {
        $color = if ($line -match 'ERROR') { 'Red' } elseif ($line -match '---') { 'White' } else { 'Gray' }
        Write-Host "    $line" -ForegroundColor $color
    }
    if ($Expected) {
        Write-Host "    Expected: $Expected" -ForegroundColor Yellow
    }
}

# ============================================================================
# SCENARIO 1 — FAILOVER (Priority routing)
# ============================================================================
function Test-Failover {
    param([string]$DomainName, [int]$N)

    $url = "https://webfailover.$DomainName"
    Write-Banner "FAILOVER TEST  (Priority Routing)" Cyan

    Write-Host "  Profile      : $TmFailoverProfile"
    Write-Host "  Endpoint URL : $url"
    Write-Host "  Routing logic: US = priority 1 (primary), UK = priority 2 (backup)"
    Write-Host "  What this test does:"
    Write-Host "    1. Normal operation — both endpoints enabled (expect US)"
    Write-Host "    2. Disables US endpoint (simulates failure)"
    Write-Host "    3. Waits for TM probe cycle + TTL drain (~40 s)"
    Write-Host "    4. Re-probes (expect UK)"
    Write-Host "    5. Re-enables US endpoint"
    Write-Host ""
    Write-Warn "This test temporarily DISABLES the US endpoint."
    Write-Warn "It will be re-enabled automatically at the end."
    Write-Host ""
    if ((Read-Host "  Proceed? (yes/no)") -ne 'yes') {
        Write-Host "  Skipped." -ForegroundColor Gray
        return
    }

    # === Step 1: Normal ===
    Write-Host ""; Write-Host "  STEP 1 — Normal operation (US primary expected)" -ForegroundColor Cyan
    $normalLocal = Invoke-LocalProbe -Url $url -N $N -Label "US client (local machine)"
    $normalAci   = Invoke-AciProbe  -Url $url -N $N

    # === Step 2: Disable US ===
    Write-Host ""; Write-Host "  STEP 2 — Disabling US endpoint..." -ForegroundColor Cyan
    $null = az network traffic-manager endpoint update `
        --name $TmFailoverEndpointUs `
        --profile-name $TmFailoverProfile `
        --resource-group $ResourceGroup `
        --type azureEndpoints `
        --endpoint-status Disabled `
        --output none
    Write-Ok "US endpoint disabled."

    Write-Host "  Waiting 40 s for TM probe failure detection + TTL drain..." -ForegroundColor Yellow
    for ($w = 40; $w -gt 0; $w -= 5) {
        Write-Host "    ${w}s remaining..." -ForegroundColor Gray
        Start-Sleep -Seconds 5
    }

    # === Step 3: Re-probe ===
    Write-Host ""; Write-Host "  STEP 3 — Re-probing after US failure (UK expected)" -ForegroundColor Cyan
    $failLocal = Invoke-LocalProbe -Url $url -N $N -Label "US client (local machine)"
    $failAci   = Invoke-AciProbe  -Url $url -N $N

    # === Restore US ===
    Write-Host ""; Write-Step "Restoring US endpoint..."
    $null = az network traffic-manager endpoint update `
        --name $TmFailoverEndpointUs `
        --profile-name $TmFailoverProfile `
        --resource-group $ResourceGroup `
        --type azureEndpoints `
        --endpoint-status Enabled `
        --output none
    Write-Ok "US endpoint re-enabled."

    # === Results ===
    Write-Banner "FAILOVER RESULTS" Green
    Show-Distribution $normalLocal "Step 1 — Local (expected: US primary)"     "South Central US [southcentralus]"
    if ($normalAci)  { Show-AciResults $normalAci  "Step 1 — Normal operation"         "South Central US [follows priority, not geography]" }
    Show-Distribution $failLocal   "Step 3 — Local after failure (expected: UK)"  "UK South [uksouth]"
    if ($failAci)    { Show-AciResults $failAci    "Step 3 — After failure"             "UK South" }
    Write-Host ""
}

# ============================================================================
# SCENARIO 2 — GEOGRAPHIC routing
# ============================================================================
function Test-Geographic {
    param([string]$DomainName, [int]$N)

    $url = "https://webgeo.$DomainName"
    Write-Banner "GEOGRAPHIC ROUTING TEST" Cyan

    Write-Host "  Profile      : $TmGeoProfile"
    Write-Host "  Endpoint URL : $url"
    Write-Host "  Routing logic: US/CA/MX → US app,  GB + WORLD → UK app"
    Write-Host ""
    Write-Host "  Local probe = runs on YOUR machine (expected: US app because your IP is in US)"
    Write-Host "  ACI probe   = runs in Azure UK South (expected: UK app — UK IP)"
    Write-Host ""
    Write-Host "  Note: Traffic Manager geo-routing uses the DNS resolver IP, not client IP."
    Write-Host "  Azure DNS resolvers in UK South are classified as GB region." -ForegroundColor Gray
    Write-Host ""

    $localResults = Invoke-LocalProbe -Url $url -N $N -Label "Local machine"
    $aciLogs      = Invoke-AciProbe  -Url $url -N $N

    Write-Banner "GEOGRAPHIC RESULTS" Green
    Show-Distribution $localResults "Local probe (expected: US app)"          "South Central US [southcentralus]"
    if ($aciLogs) { Show-AciResults $aciLogs "ACI probe, UK South (expected: UK app)"  "UK South [uksouth]" }
    Write-Host ""
}

# ============================================================================
# SCENARIO 3 — WEIGHTED load balancing
# ============================================================================
function Test-Weighted {
    param([string]$DomainName, [int]$N)

    $url    = "https://webweighted.$DomainName"
    $actualN = [Math]::Max($N, 30)   # need enough samples for statistical accuracy

    Write-Banner "WEIGHTED LOAD BALANCING TEST" Cyan

    Write-Host "  Profile      : $TmWeightedProfile"
    Write-Host "  Endpoint URL : $url"
    Write-Host "  Routing logic: US endpoint weight=70, UK endpoint weight=30"
    Write-Host "  Samples      : $actualN (more = closer to actual distribution)"
    Write-Host ""
    Write-Host "  Weighted routing ignores client geography — same distribution from anywhere."
    Write-Host "  DNS TTL caching may skew short runs; results converge with >30 requests." -ForegroundColor Gray
    Write-Host ""

    $localResults = Invoke-LocalProbe -Url $url -N $actualN -Label "Local machine"
    $aciLogs      = Invoke-AciProbe  -Url $url -N $actualN

    Write-Banner "WEIGHTED RESULTS" Green
    Show-Distribution $localResults "Local probe distribution"   "~70% US, ~30% UK"
    if ($aciLogs) { Show-AciResults $aciLogs "ACI probe distribution"  "~70% US, ~30% UK (same from any region)" }
    Write-Host ""
}

# ============================================================================
# MAIN
# ============================================================================
Write-Host ""
Write-Host "  ╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║   Zava Azure DNS POC — Traffic Manager Test Suite         ║" -ForegroundColor Cyan
Write-Host "  ║   Local (US) + ACI in UK South (EU) dual-region probing   ║" -ForegroundColor Cyan
Write-Host "  ╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Pre-flight: Azure CLI auth
try {
    $null = az account show --output none 2>&1
    if ($LASTEXITCODE -ne 0) { throw }
    Write-Ok "Azure CLI authenticated."
} catch {
    Write-Warn "Not logged in. Running az login..."
    az login
}

$domain = Get-DeploymentDomain -Override $Domain
Write-Host "  Domain        : $domain" -ForegroundColor Cyan
Write-Host "  Resource group: $ResourceGroup" -ForegroundColor Cyan
Write-Host "  Iterations    : $Iterations (weighted uses max($Iterations, 30))" -ForegroundColor Cyan
if ($SkipAci) { Write-Warn "ACI probes disabled — running local probes only." }
Write-Host ""

# Scenario selection menu
if (-not $Scenario) {
    Write-Host "  Select Traffic Manager scenario to test:"
    Write-Host ""
    Write-Host "  [1]  Failover   — Priority routing — disable US, verify UK takes over"
    Write-Host "  [2]  Geographic — Geo routing — US clients go to US, EU clients go to UK"
    Write-Host "  [3]  Weighted   — 70%/30% load distribution across US + UK"
    Write-Host "  [4]  All        — Run all three in sequence"
    Write-Host ""
    $choice   = Read-Host "  Enter choice (1-4)"
    $Scenario = switch ($choice.Trim()) {
        '1' { 'Failover' }
        '2' { 'Geo' }
        '3' { 'Weighted' }
        '4' { 'All' }
        default { Write-Error "Invalid choice '$choice'. Valid: 1, 2, 3, 4."; exit 1 }
    }
}

switch ($Scenario) {
    'Failover' { Test-Failover  -DomainName $domain -N $Iterations }
    'Geo'      { Test-Geographic -DomainName $domain -N $Iterations }
    'Weighted' { Test-Weighted  -DomainName $domain -N $Iterations }
    'All' {
        Test-Failover   -DomainName $domain -N $Iterations
        Test-Geographic -DomainName $domain -N $Iterations
        Test-Weighted   -DomainName $domain -N $Iterations
    }
}

Write-Host "  ✓ Test suite complete." -ForegroundColor Green
Write-Host ""
