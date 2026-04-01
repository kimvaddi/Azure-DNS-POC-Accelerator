#Requires -Version 7.0
# ============================================================================
# Zava Azure DNS POC — Traffic Manager Test Suite
# ============================================================================
# Tests all three Traffic Manager routing scenarios from two geographic
# locations simultaneously:
#
#   US client  → runs on your local machine (assumes US network location)
#   EU client  → runs via a temporary Azure Container Instance in West Europe
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
#   .\TrafficManager_Test.ps1                      # interactive menu
#   .\TrafficManager_Test.ps1 -Scenario Failover
#   .\TrafficManager_Test.ps1 -Scenario Geo   -Iterations 20
#   .\TrafficManager_Test.ps1 -Scenario All
#   .\TrafficManager_Test.ps1 -Scenario Weighted -SkipAci  # local only
# ============================================================================

param(
    [Parameter(HelpMessage = 'Scenario to test: Failover, Geo, Weighted, or All')]
    [ValidateSet('Failover', 'Geo', 'Weighted', 'All', '')]
    [string]$Scenario = '',

    [Parameter(HelpMessage = 'Resource group where Traffic Manager profiles live. Auto-discovered from current deployment if omitted.')]
    [string]$ResourceGroup = '',

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
$AciImage               = 'mcr.microsoft.com/azure-cli:latest'
$AciLocation            = 'westeurope'    # EU probe region

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
}

function Test-AciProviderRegistration {
    try {
        $state = az provider show --namespace Microsoft.ContainerInstance --query registrationState -o tsv 2>$null
        return ($state -in @('Registered', 'Registering'))
    } catch {
        return $false
    }
}

function Get-WestEuropeContainerRegistry {
    param([string]$ResourceGroup)

    try {
        Write-Step "Checking for existing container registries in $AciLocation..."
        
        # Query for ACR resources in westeurope in the same resource group
        $registries = az acr list --resource-group $ResourceGroup `
            --query "[?location=='$AciLocation']" `
            --output json 2>$null
        
        if ($LASTEXITCODE -eq 0 -and $registries) {
            $regList = $registries | ConvertFrom-Json -ErrorAction SilentlyContinue
            
            if ($regList -and ($regList | Measure-Object).Count -gt 0) {
                if ($regList -is [array]) {
                    $registry = $regList[0]
                } else {
                    $registry = $regList
                }
                
                Write-Ok "Found existing container registry: $($registry.name) in $AciLocation"
                Write-Host ("    Login server: {0}" -f $registry.loginServer) -ForegroundColor Gray
                return $registry
            }
        }
        
        Write-Warn "No container registry found in $AciLocation. Using public image."
        return $null
    } catch {
        Write-Warn "Could not check for container registries: $($_.Exception.Message)"
        Write-Warn "Will proceed with public image (mcr.microsoft.com)"
        return $null
    }
}

function ConvertFrom-JsonLoose {
    param([string]$RawText)

    if (-not $RawText -or $RawText.Trim().Length -eq 0) {
        return $null
    }

    # Some files include CLI preamble/warnings before JSON. Parse from the first '{'.
    $trimmed = $RawText.Trim()
    $firstBrace = $trimmed.IndexOf('{')
    if ($firstBrace -lt 0) {
        return $null
    }

    $jsonCandidate = $trimmed.Substring($firstBrace)
    try {
        return $jsonCandidate | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }
}

# ============================================================================
# DEPLOYMENT INFO DISCOVERY
# ============================================================================
function Get-DeploymentDomain {
    param([string]$Override)
    if ($Override) { return $Override }

    function Resolve-DomainFromObject {
        param([object]$Obj)

        if (-not $Obj) { return $null }

        $candidate = $null
        try { $candidate = $Obj.publicDnsZoneName.value } catch {}
        if (-not $candidate) {
            try { $candidate = $Obj.publicDnsZoneName } catch {}
        }
        if (-not $candidate) {
            try { $candidate = $Obj.properties.outputs.publicDnsZoneName.value } catch {}
        }

        return $candidate
    }

    # 1. Fixed file saved by deploy.ps1
    $fixed = Join-Path $PSScriptRoot 'infrastructure\deployment-output.json'
    if (Test-Path $fixed) {
        $raw = Get-Content $fixed -Raw
        $data = ConvertFrom-JsonLoose -RawText $raw
        if ($data) {
            # Handle both shapes safely:
            # 1) outputs-only object: { publicDnsZoneName: { value: "..." } }
            # 2) full deployment object: { properties: { outputs: { publicDnsZoneName: { value: "..." } } } }
            $d = Resolve-DomainFromObject -Obj $data

            if ($d) {
                Write-Host "  Domain auto-discovered: $d  (from infrastructure/deployment-output.json)" -ForegroundColor Gray
                return $d
            }
        }
    }

    # 2. Most recent timestamped file
    $latest = Get-ChildItem -Path $PSScriptRoot -Filter 'deployment-outputs-*.json' -Recurse -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) {
        $raw = Get-Content $latest.FullName -Raw
        $data = ConvertFrom-JsonLoose -RawText $raw
        if ($data) {
            $d = Resolve-DomainFromObject -Obj $data

            if ($d) {
                Write-Host "  Domain auto-discovered: $d  (from $($latest.Name))" -ForegroundColor Gray
                return $d
            }
        }
    }

    # 3. Prompt when discovery did not find a domain.
    return (Read-Host "  Enter domain (e.g. zava-dnspoc-001.com)").Trim()
}

function Get-DeploymentResourceGroup {
    param([string]$Override)
    if ($Override) { return $Override }

    function Resolve-ResourceGroupFromObject {
        param([object]$Obj)

        if (-not $Obj) { return $null }

        $candidate = $null
        try { $candidate = $Obj.resourceGroupName.value } catch {}
        if (-not $candidate) {
            try { $candidate = $Obj.resourceGroupName } catch {}
        }
        if (-not $candidate) {
            try { $candidate = $Obj.properties.outputs.resourceGroupName.value } catch {}
        }

        return $candidate
    }

    # 1. Fixed file saved by deploy.ps1
    $fixed = Join-Path $PSScriptRoot 'infrastructure\deployment-output.json'
    if (Test-Path $fixed) {
        $raw = Get-Content $fixed -Raw
        $data = ConvertFrom-JsonLoose -RawText $raw
        if ($data) {
            $rg = Resolve-ResourceGroupFromObject -Obj $data
            if ($rg) {
                Write-Host "  Resource group auto-discovered: $rg  (from infrastructure/deployment-output.json)" -ForegroundColor Gray
                return $rg
            }
        }
    }

    # 2. Most recent timestamped output file
    $latest = Get-ChildItem -Path $PSScriptRoot -Filter 'deployment-outputs-*.json' -Recurse -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) {
        $raw = Get-Content $latest.FullName -Raw
        $data = ConvertFrom-JsonLoose -RawText $raw
        if ($data) {
            $rg = Resolve-ResourceGroupFromObject -Obj $data
            if ($rg) {
                Write-Host "  Resource group auto-discovered: $rg  (from $($latest.Name))" -ForegroundColor Gray
                return $rg
            }
        }
    }

    # 3. Query latest successful subscription deployment outputs in Azure.
    try {
        $latestDeploymentName = az deployment sub list --query "sort_by([?properties.provisioningState=='Succeeded'], &properties.timestamp)[-1].name" -o tsv 2>$null
        if ($latestDeploymentName) {
            $rg = az deployment sub show --name $latestDeploymentName --query "properties.outputs.resourceGroupName.value" -o tsv 2>$null
            if ($rg) {
                Write-Host "  Resource group auto-discovered: $rg  (from Azure deployment $latestDeploymentName)" -ForegroundColor Gray
                return $rg
            }
        }
    }
    catch {
        # Ignore Azure query failures and fall through to prompt.
    }

    # 4. Prompt when discovery did not find a resource group.
    return (Read-Host "  Enter resource group (e.g. rg-dnspoc-001)").Trim()
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
            $probePath = '/metadata.json'
            try {
                $r = Invoke-WebRequest -Uri "$Url$probePath" -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
            } catch {
                $probePath = '/health.json'
                $r = Invoke-WebRequest -Uri "$Url$probePath" -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
            }

            $j = $r.Content | ConvertFrom-Json
            $regionDisplay = if ($j.regionDisplayName) { $j.regionDisplayName } elseif ($j.region) { $j.region } else { 'unknown' }
            $regionCode = if ($j.region) { $j.region } else { 'unknown' }
            $hit = "$regionDisplay [$regionCode]"
            $results.Add($hit)
            Write-Host ("    [{0,2}/{1}] {2} via {3}" -f $i, $N, $hit, $probePath) -ForegroundColor Gray
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
# ACI PROBE — spins up a container in West Europe and runs the same probe remotely
# This is key for Geographic routing: the container gets a UK IP, so TM routes
# its DNS queries to the UK-mapped endpoint.
# ============================================================================
function Invoke-AciProbe {
    param([string]$Url, [int]$N)

    if ($SkipAci) {
        Write-Warn "ACI probe skipped (-SkipAci flag set)."
        return $null
    }

    if (-not (Test-AciProviderRegistration)) {
        Write-Warn "Microsoft.ContainerInstance is not registered in this subscription."
        Write-Warn "Run: az provider register --namespace Microsoft.ContainerInstance"
        Write-Warn "EU probe skipped until the provider registration completes."
        return $null
    }

    Write-Step "EU probe via ACI in $AciLocation  ($N × GET $Url/metadata.json)"
    Write-Host "    Spawning temporary container — image pull ~60 s on first run." -ForegroundColor Gray

    # Script that runs INSIDE the ACI container.
    # Use Python because the Azure CLI base image is accessible from ACI and already contains Python.
    $aciScript = @'
import json
import os
import time
import urllib.request

url = os.environ['TEST_URL']
n = int(os.environ['TEST_N'])
results = []

for i in range(1, n + 1):
    try:
        probe_path = '/metadata.json'
        try:
            with urllib.request.urlopen(url + probe_path, timeout=15) as resp:
                payload = json.loads(resp.read().decode('utf-8'))
        except Exception:
            probe_path = '/health.json'
            with urllib.request.urlopen(url + probe_path, timeout=15) as resp:
                payload = json.loads(resp.read().decode('utf-8'))

        region_display = payload.get('regionDisplayName') or payload.get('region') or 'unknown'
        region_code = payload.get('region') or 'unknown'
        hit = f"{region_display} [{region_code}]"
        results.append(hit)
        print(f"[{i}/{n}] {hit} via {probe_path}", flush=True)
    except Exception:
        results.append('ERROR')
        print(f"[{i}/{n}] ERROR", flush=True)

    if i < n:
        time.sleep(1)

print('--- SUMMARY ---', flush=True)
for name in sorted(set(results), key=lambda item: results.count(item), reverse=True):
    count = results.count(name)
    pct = round((count / len(results)) * 100)
    print(f"{pct:>3}%  {name}  ({count}x)", flush=True)
'@

        $encoded  = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($aciScript))
        $aciName  = "aci-tmtest-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
        $aciSpecPath = Join-Path ([System.IO.Path]::GetTempPath()) ("$aciName.json")
        $aciSpec = @{
                apiVersion = '2021-10-01'
                location = $AciLocation
                name = $aciName
                type = 'Microsoft.ContainerInstance/containerGroups'
                properties = @{
                        osType = 'Linux'
                        restartPolicy = 'Never'
                        containers = @(
                                @{
                                        name = $aciName
                                        properties = @{
                                                image = $AciImage
                                                command = @(
                                                        'python3'
                                                        '-c'
                                                        'import os,base64; exec(base64.b64decode(os.environ["PROBE_SCRIPT_B64"]).decode("utf-8"))'
                                                )
                                                environmentVariables = @(
                                                        @{ name = 'TEST_URL'; value = $Url }
                                                        @{ name = 'TEST_N'; value = "$N" }
                                                        @{ name = 'PROBE_SCRIPT_B64'; value = $encoded }
                                                )
                                                resources = @{
                                                        requests = @{
                                                                cpu = 1
                                                                memoryInGB = 1
                                                        }
                                                }
                                        }
                                }
                        )
                }
        }
        $aciSpec | ConvertTo-Json -Depth 20 | Set-Content -Path $aciSpecPath -Encoding UTF8

    Write-Host "    Container name: $aciName" -ForegroundColor Gray

        $createOutput = az container create `
                --resource-group $ResourceGroup `
            --file $aciSpecPath `
                --output json 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Failed to create ACI '$aciName'. EU probe skipped."
        if ($createOutput) {
            Write-Host "    Azure error:" -ForegroundColor DarkYellow
            $createOutput | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkYellow }
        }
                Remove-Item -Path $aciSpecPath -Force -ErrorAction SilentlyContinue
        return $null
    }

    # Poll until container terminates (max 5 minutes)
    $timeout = 300; $elapsed = 0
    do {
        Start-Sleep -Seconds 10; $elapsed += 10
        $state = az container show --name $aciName --resource-group $ResourceGroup `
                    --query instanceView.state -o tsv 2>$null
        Write-Host "    [${elapsed}s] ACI state: $state" -ForegroundColor Gray
    } while ($state -in @('Pending', 'Running') -and $elapsed -lt $timeout)

    $logs = az container logs --name $aciName --resource-group $ResourceGroup 2>&1

    Remove-Item -Path $aciSpecPath -Force -ErrorAction SilentlyContinue

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
    Write-Host "    6. Waits 40 s for TTL drain, re-probes to confirm US is back"
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

    # === Step 4: Confirm restore ===
    Write-Host ""; Write-Host "  STEP 4 — Waiting 40 s for TTL drain before confirming restore..." -ForegroundColor Yellow
    for ($w = 40; $w -gt 0; $w -= 5) {
        Write-Host "    ${w}s remaining..." -ForegroundColor Gray
        Start-Sleep -Seconds 5
    }
    Write-Host ""; Write-Host "  STEP 4 — Re-probing after restore (US primary expected)" -ForegroundColor Cyan
    $restoreLocal = Invoke-LocalProbe -Url $url -N $N -Label "US client (local machine)"

    # === Results ===
    Write-Banner "FAILOVER RESULTS" Green
    Show-Distribution $normalLocal  "Step 1 — Normal (expected: US primary)"        "South Central US [southcentralus]"
    Show-Distribution $failLocal    "Step 3 — After US disabled (expected: UK)"     "West Europe [westeurope]"
    Show-Distribution $restoreLocal "Step 4 — After restore (expected: US back)"    "South Central US [southcentralus]"
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
    Write-Host "  ACI probe   = runs in Azure West Europe (expected: EU/UK app — EU IP)"
    Write-Host ""
    Write-Host "  Note: Traffic Manager geo-routing uses the DNS resolver IP, not client IP."
    Write-Host "  Azure DNS resolvers in West Europe are classified as EU geography for this probe." -ForegroundColor Gray
    Write-Host ""

    $localResults = Invoke-LocalProbe -Url $url -N $N -Label "Local machine"
    $aciLogs      = Invoke-AciProbe  -Url $url -N $N

    Write-Banner "GEOGRAPHIC RESULTS" Green
    Show-Distribution $localResults "Local probe (expected: US app)"          "South Central US [southcentralus]"
    if ($aciLogs) { Show-AciResults $aciLogs "ACI probe, West Europe (expected: EU/UK app)"  "West Europe [westeurope]" }
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
Write-Host "  ║  Local (US) + ACI in West Europe (EU) dual-region probe   ║" -ForegroundColor Cyan
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

$domain = ''
$ResourceGroup = Get-DeploymentResourceGroup -Override $ResourceGroup
$resolvedDomain = Get-DeploymentDomain -Override $Domain

# Pre-check: Look for existing container registry in westeurope
Write-Host ""
$existingRegistry = Get-WestEuropeContainerRegistry -ResourceGroup $ResourceGroup
Write-Host ""

# Scenario selection menu
if (-not $Scenario) {
    Write-Host "  Usage:" -ForegroundColor Yellow
    Write-Host "    .\TrafficManager_Test.ps1 -Scenario <Failover|Geo|Weighted|All> [options]"
    Write-Host ""
    Write-Host "  Examples:" -ForegroundColor Yellow
    Write-Host "    .\TrafficManager_Test.ps1 -Scenario Geo -Domain zava-dnspoc-001.com -Iterations 20"
    Write-Host "    .\TrafficManager_Test.ps1 -Scenario Failover -Domain zava-dnspoc-001.com"
    Write-Host "    .\TrafficManager_Test.ps1 -Scenario Weighted -Iterations 50"
    Write-Host "    .\TrafficManager_Test.ps1 -Scenario All -Domain zava-dnspoc-001.com"
    Write-Host "    .\TrafficManager_Test.ps1 -Scenario Geo -SkipAci   # local-only run"
    Write-Host ""

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

    # In interactive mode, always confirm the target domain to test.
    $domainPrompt = "  Enter target domain to test"
    if ($resolvedDomain) {
        $domainPrompt += " [$resolvedDomain]"
    }

    $domainInput = (Read-Host $domainPrompt).Trim()
    if ($domainInput) {
        $domain = $domainInput
    }
    else {
        $domain = $resolvedDomain
    }
}
else {
    $domain = $resolvedDomain
}

if (-not $domain) {
    Write-Error "Target domain is required. Use -Domain or provide a value when prompted."
    exit 1
}

Write-Host "  Domain        : $domain" -ForegroundColor Cyan
Write-Host "  Resource group: $ResourceGroup" -ForegroundColor Cyan
Write-Host "  ACI Location  : $AciLocation" -ForegroundColor Cyan
if ($existingRegistry) {
    Write-Host "  Container Reg : $($existingRegistry.name)" -ForegroundColor Green
} else {
    Write-Host "  Container Reg : Using public image (mcr.microsoft.com)" -ForegroundColor Gray
}
Write-Host "  Iterations    : $Iterations (weighted uses max($Iterations, 30))" -ForegroundColor Cyan
if ($SkipAci) { Write-Warn "ACI probes disabled — running local probes only." }
Write-Host ""

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
