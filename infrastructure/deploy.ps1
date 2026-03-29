# ============================================================================
# Zava DNS POC - Bicep Deployment Script
# ============================================================================
# Deploys complete DNS POC infrastructure to Azure subscription
# Validates template before deployment and captures all outputs
# ============================================================================

param(
    [Parameter(Mandatory=$false)]
    [string]$Location = "southcentralus",
    
    [Parameter(Mandatory=$false)]
    [string]$DeploymentName = "Zava-dns-poc-$(Get-Date -Format 'yyyyMMdd-HHmmss')",
    
    [Parameter(Mandatory=$false)]
    [string]$TemplateFile = "$PSScriptRoot\main.bicep",
    
    [Parameter(Mandatory=$false)]
    [string]$ParametersFile = "$PSScriptRoot\main.bicepparam",

    [Parameter(Mandatory=$false)]
    [string[]]$AdditionalParameters = @(),

    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName = "rg-dns-poc",

    # When set, deletes the existing rg-dns-poc resource group and all
    # subscription-level diagnostics before deploying. Use this to cleanly
    # redeploy with a new domain name.
    [Parameter(Mandatory=$false)]
    [switch]$Redeploy,
    
    [Parameter(Mandatory=$false)]
    [switch]$ValidateOnly,
    
    [Parameter(Mandatory=$false)]
    [switch]$WhatIf
)

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Write-Step {
    param([string]$Message)
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "✓ $Message" -ForegroundColor Green
}

function Write-Warning {
    param([string]$Message)
    Write-Host "⚠ $Message" -ForegroundColor Yellow
}

function Write-Error {
    param([string]$Message)
    Write-Host "✗ $Message" -ForegroundColor Red
}

function Get-AppSettingValue {
        param(
                [array]$Settings,
                [string]$Name,
                [string]$Default = ""
        )

        $match = $Settings | Where-Object { $_.name -eq $Name } | Select-Object -First 1
        if ($match) {
                return $match.value
        }

        return $Default
}

function Publish-FriendlyPage {
        param(
                [string]$ResourceGroupName,
                [string]$AppName
        )

        Write-Host "Publishing friendly landing page to $AppName..."

        $rawSettings = az webapp config appsettings list --resource-group $ResourceGroupName --name $AppName --output json 2>&1
        if ($LASTEXITCODE -ne 0) {
                Write-Error "Failed to read app settings for $AppName"
                Write-Host $rawSettings -ForegroundColor Red
                exit 1
        }

        $settings = $rawSettings | ConvertFrom-Json
        $siteTitle = Get-AppSettingValue -Settings $settings -Name 'POC_SITE_TITLE' -Default 'Zava Azure DNS POC'
        $regionName = Get-AppSettingValue -Settings $settings -Name 'POC_REGION_NAME' -Default 'unknown'
        $regionDisplayName = Get-AppSettingValue -Settings $settings -Name 'POC_REGION_DISPLAY_NAME' -Default $regionName
        $regionRole = Get-AppSettingValue -Settings $settings -Name 'POC_REGION_ROLE' -Default 'active'
        $publicDomain = Get-AppSettingValue -Settings $settings -Name 'POC_PUBLIC_DNS_ZONE' -Default ''
        $privateDomain = Get-AppSettingValue -Settings $settings -Name 'POC_PRIVATE_DNS_ZONE' -Default ''
        $regionEndpoint = Get-AppSettingValue -Settings $settings -Name 'POC_REGION_ENDPOINT' -Default '/region.txt'
        $metadataEndpoint = Get-AppSettingValue -Settings $settings -Name 'POC_METADATA_ENDPOINT' -Default '/metadata.json'

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dns-poc-" + [System.Guid]::NewGuid().ToString('N'))
        $siteRoot = Join-Path $tempRoot 'site'
        $packagePath = Join-Path $tempRoot ($AppName + '.zip')

        New-Item -ItemType Directory -Path $siteRoot -Force | Out-Null

        $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>$siteTitle</title>
    <style>
        :root {
            color-scheme: light;
            --bg-top: #f4efe2;
            --bg-bottom: #d9e7f2;
            --panel: rgba(255, 255, 255, 0.92);
            --text: #163047;
            --muted: #4b6478;
            --accent: #0078d4;
            --border: rgba(22, 48, 71, 0.12);
        }
        * { box-sizing: border-box; }
        body {
            margin: 0;
            min-height: 100vh;
            font-family: "Segoe UI", Tahoma, Geneva, Verdana, sans-serif;
            color: var(--text);
            background: radial-gradient(circle at top left, #fff8df 0%, var(--bg-top) 35%, var(--bg-bottom) 100%);
            display: grid;
            place-items: center;
            padding: 24px;
        }
        main {
            width: min(760px, 100%);
            background: var(--panel);
            border: 1px solid var(--border);
            border-radius: 24px;
            padding: 32px;
            box-shadow: 0 18px 40px rgba(22, 48, 71, 0.12);
            backdrop-filter: blur(8px);
        }
        .eyebrow {
            text-transform: uppercase;
            letter-spacing: 0.12em;
            font-size: 12px;
            color: var(--accent);
            margin-bottom: 12px;
            font-weight: 700;
        }
        h1 {
            margin: 0 0 12px;
            font-size: clamp(32px, 5vw, 48px);
            line-height: 1.05;
        }
        p {
            margin: 0 0 20px;
            color: var(--muted);
            font-size: 18px;
            line-height: 1.55;
        }
        .grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
            gap: 14px;
            margin: 28px 0;
        }
        .card {
            padding: 18px;
            border-radius: 18px;
            background: rgba(255, 255, 255, 0.9);
            border: 1px solid var(--border);
        }
        .label {
            font-size: 12px;
            text-transform: uppercase;
            letter-spacing: 0.08em;
            color: var(--muted);
            margin-bottom: 8px;
        }
        .value {
            font-size: 22px;
            font-weight: 700;
            word-break: break-word;
        }
        code {
            font-family: Consolas, "Courier New", monospace;
            font-size: 14px;
            background: #eef5fb;
            border-radius: 8px;
            padding: 2px 6px;
        }
    </style>
</head>
<body>
    <main>
        <div class="eyebrow">Azure DNS POC</div>
        <h1>$regionDisplayName web app</h1>
        <p>This App Service instance is serving the Zava DNS POC landing page from the <strong>$regionDisplayName</strong> region. Use the plain-text endpoint below for quick curl-based checks.</p>
        <div class="grid">
            <section class="card">
                <div class="label">Region</div>
                <div class="value">$regionDisplayName</div>
            </section>
            <section class="card">
                <div class="label">Azure region code</div>
                <div class="value">$regionName</div>
            </section>
            <section class="card">
                <div class="label">Role</div>
                <div class="value">$regionRole</div>
            </section>
            <section class="card">
                <div class="label">App Service name</div>
                <div class="value">$AppName</div>
            </section>
        </div>
        <p>curl endpoint: <code>$regionEndpoint</code></p>
        <p>Metadata endpoint: <code>$metadataEndpoint</code></p>
        <p>Public zone: <code>$publicDomain</code><br>Private zone: <code>$privateDomain</code></p>
    </main>
</body>
</html>
"@

        $regionText = @"
$regionDisplayName
region=$regionName
role=$regionRole
app=$AppName
publicZone=$publicDomain
privateZone=$privateDomain
"@

        $metadata = [ordered]@{
                siteTitle = $siteTitle
                appName = $AppName
                region = $regionName
                regionDisplayName = $regionDisplayName
                role = $regionRole
                publicDnsZone = $publicDomain
                privateDnsZone = $privateDomain
                regionEndpoint = $regionEndpoint
                metadataEndpoint = $metadataEndpoint
                generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json -Depth 5

        $webConfig = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
    <system.webServer>
        <defaultDocument enabled="true">
            <files>
                <clear />
                <add value="index.html" />
            </files>
        </defaultDocument>
    </system.webServer>
</configuration>
"@

        Set-Content -Path (Join-Path $siteRoot 'index.html') -Value $html -Encoding UTF8
        Set-Content -Path (Join-Path $siteRoot 'region.txt') -Value $regionText.Trim() -Encoding UTF8
        Set-Content -Path (Join-Path $siteRoot 'metadata.json') -Value $metadata -Encoding UTF8
        Set-Content -Path (Join-Path $siteRoot 'web.config') -Value $webConfig -Encoding UTF8

        Compress-Archive -Path (Join-Path $siteRoot '*') -DestinationPath $packagePath -Force

        $deployOutput = az webapp deployment source config-zip --resource-group $ResourceGroupName --name $AppName --src $packagePath 2>&1
        if ($LASTEXITCODE -ne 0) {
                Write-Error "Content deployment failed for $AppName"
                Write-Host $deployOutput -ForegroundColor Red
                Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
                exit 1
        }

        Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        Write-Success "Friendly landing page deployed to $AppName"
}

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================

Write-Step "Pre-Flight Checks"

# Check Azure CLI
Write-Host "Checking Azure CLI..."
try {
    $azVersion = az version --output json | ConvertFrom-Json
    Write-Success "Azure CLI version: $($azVersion.'azure-cli')"
} catch {
    Write-Error "Azure CLI not found. Install from: https://aka.ms/azure-cli"
    exit 1
}

# Check Azure CLI login
Write-Host "Checking Azure authentication..."
$account = az account show --output json 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Warning "Not logged in to Azure. Initiating login..."
    az login
    $account = az account show --output json | ConvertFrom-Json
}
Write-Success "Logged in as: $($account.user.name)"
Write-Success "Subscription: $($account.name) ($($account.id))"

# Check Bicep CLI
Write-Host "Checking Bicep CLI..."
try {
    $bicepVersion = az bicep version
    Write-Success "Bicep version: $bicepVersion"
} catch {
    Write-Warning "Bicep not installed. Installing..."
    az bicep install
    Write-Success "Bicep installed successfully"
}

# Verify template file exists
if (-not (Test-Path $TemplateFile)) {
    Write-Error "Template file not found: $TemplateFile"
    exit 1
}
Write-Success "Template file found: $TemplateFile"

# Verify parameters file exists
if (-not (Test-Path $ParametersFile)) {
    Write-Warning "Parameters file not found: $ParametersFile (using defaults)"
    $ParametersFile = $null
}

# ============================================================================
# DOMAIN AVAILABILITY DISCOVERY
# ============================================================================
# Check zava-dnspoc-001.com through zava-dnspoc-999.com and use the first
# available name. Availability is verified against the App Service Domain API
# (which checks both GoDaddy registration status and Azure subscription).

Write-Step "Discovering Available App Service Domain"

$subscriptionId = (az account show --query id --output tsv)
$domainBase = 'zava-dnspoc'
$discoveredDomain = $null
$bearerToken = (az account get-access-token --query accessToken -o tsv)

for ($i = 1; $i -le 999; $i++) {
    $candidate = '{0}-{1:D3}.com' -f $domainBase, $i
    Write-Host "  Checking: $candidate ..."

    $checkUri  = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.DomainRegistration/checkDomainAvailability?api-version=2022-03-01"
    $checkBody = @{ name = $candidate } | ConvertTo-Json -Compress
    try {
        $checkResult = Invoke-RestMethod -Uri $checkUri -Method POST `
            -Headers @{ Authorization = "Bearer $bearerToken"; "Content-Type" = "application/json" } `
            -Body $checkBody -ErrorAction Stop
    } catch {
        Write-Warning "  Availability check failed for $candidate — skipping."
        continue
    }
    if ($checkResult.available -eq $true) {
        $discoveredDomain = $candidate
        Write-Success "Available domain found: $discoveredDomain"
        break
    } else {
        Write-Host "  Not available ($($checkResult.reason)). Trying next..." -ForegroundColor Yellow
    }
}

if (-not $discoveredDomain) {
    Write-Error "No available domain found in range $domainBase-001.com to $domainBase-999.com"
    exit 1
}

# Capture operator public IP for the domain registration consent record.
# Falls back to 0.0.0.0 if the lookup fails (e.g., in a restricted network).
try {
    $publicIp = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 10).ip
    Write-Success "Operator public IP: $publicIp"
} catch {
    $publicIp = '0.0.0.0'
    Write-Warning "Could not determine public IP; using 0.0.0.0 for consent record."
}
$consentTimestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

# Merge domain overrides into AdditionalParameters so every az deployment
# command (validate, what-if, create) uses the discovered domain.
$AdditionalParameters += @(
    "domain=$discoveredDomain",
    "domainConsentAgreedBy=$publicIp",
    "domainConsentAgreedAt=$consentTimestamp"
)

Write-Host "`nUsing domain   : $discoveredDomain" -ForegroundColor Cyan
Write-Host "Consent IP     : $publicIp"
Write-Host "Consent time   : $consentTimestamp`n"

# ============================================================================
# DELETE EXISTING DEPLOYMENT (Redeploy mode)
# ============================================================================

if ($Redeploy) {
    Write-Step "Deleting Existing Deployment (-Redeploy)"

    Write-Host "Removing CanNotDelete lock on DNS zone (if present)..."
    az lock delete --name lock-dns-zone --resource-group $ResourceGroupName 2>$null

    Write-Host "Removing subscription-level Activity Log diagnostic settings (if present)..."
    az monitor diagnostic-settings subscription delete --name activity-log-to-eventhub --yes 2>$null

    $rgExists = az group exists --name $ResourceGroupName --output tsv
    if ($rgExists -eq 'true') {
        Write-Host "Deleting resource group '$ResourceGroupName' — this may take several minutes..."
        az group delete --name $ResourceGroupName --yes
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to delete resource group '$ResourceGroupName'. Aborting."
            exit 1
        }
        Write-Success "Resource group '$ResourceGroupName' deleted."
    } else {
        Write-Host "Resource group '$ResourceGroupName' does not exist — skipping deletion." -ForegroundColor Yellow
    }
}

# ============================================================================
# BUILD TEMPLATE
# ============================================================================

Write-Step "Building Bicep Template"

Write-Host "Compiling Bicep to ARM JSON..."
try {
    az bicep build --file "$TemplateFile"
    Write-Success "Bicep template compiled successfully"
} catch {
    Write-Error "Bicep compilation failed. Check template syntax."
    exit 1
}

# ============================================================================
# VALIDATE TEMPLATE
# ============================================================================

Write-Step "Validating Template"

Write-Host "Running pre-deployment validation..."
$validateArgs = @('deployment', 'sub', 'validate', '--location', $Location, '--template-file', $TemplateFile)
if ($ParametersFile) { $validateArgs += @('--parameters', $ParametersFile) }
if ($AdditionalParameters.Count -gt 0) { $validateArgs += @('--parameters') + $AdditionalParameters }

$rawValidation = az @validateArgs --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host $rawValidation -ForegroundColor Red
    Write-Error "Validation failed (exit code $LASTEXITCODE)"
    exit 1
}

try {
    $validation = $rawValidation | ConvertFrom-Json
    if ($validation.error) {
        Write-Error "Validation failed: $($validation.error.message)"
        exit 1
    }
    Write-Success "Template validation passed"
} catch {
    # Likely warnings mixed into output — if az exited 0, treat as success
    Write-Host "Validation output (raw):" -ForegroundColor Yellow
    Write-Host $rawValidation
    Write-Success "Template validation passed (az exit code: 0)"
}

# Exit if validate-only flag is set
if ($ValidateOnly) {
    Write-Step "Validation Complete (Validate-Only Mode)"
    Write-Success "Template is valid and ready to deploy"
    exit 0
}

# ============================================================================
# WHAT-IF PREVIEW
# ============================================================================

if ($WhatIf) {
    Write-Step "What-If Analysis"
    
    $whatIfArgs = @('deployment', 'sub', 'what-if', '--location', $Location, '--template-file', $TemplateFile)
    if ($ParametersFile) { $whatIfArgs += @('--parameters', $ParametersFile) }
    if ($AdditionalParameters.Count -gt 0) { $whatIfArgs += @('--parameters') + $AdditionalParameters }
    
    Write-Host "Generating what-if preview..."
    az @whatIfArgs
    
    Write-Step "What-If Complete"
    Write-Host "Review the changes above. Run without -WhatIf to deploy." -ForegroundColor Yellow
    exit 0
}

# ============================================================================
# DEPLOYMENT CONFIRMATION
# ============================================================================

Write-Step "Deployment Confirmation"

Write-Host "Deployment Details:" -ForegroundColor Yellow
Write-Host "  Deployment Name: $DeploymentName"
Write-Host "  Location: $Location"
Write-Host "  Template: $TemplateFile"
Write-Host "  Parameters: $(if ($ParametersFile) { $ParametersFile } else { 'None (using defaults)' })"
Write-Host "  Parameter Overrides: $(if ($AdditionalParameters.Count -gt 0) { $AdditionalParameters -join ', ' } else { 'None' })"
Write-Host "  Domain: $discoveredDomain"
Write-Host "  Subscription: $($account.name)`n"

$confirm = Read-Host "Proceed with deployment? (yes/no)"
if ($confirm -ne "yes") {
    Write-Warning "Deployment cancelled by user"
    exit 0
}

# ============================================================================
# DEPLOY
# ============================================================================

Write-Step "Deploying Infrastructure"

$deployArgs = @('deployment', 'sub', 'create', '--name', $DeploymentName, '--location', $Location, '--template-file', $TemplateFile)
if ($ParametersFile) { $deployArgs += @('--parameters', $ParametersFile) }
if ($AdditionalParameters.Count -gt 0) { $deployArgs += @('--parameters') + $AdditionalParameters }

Write-Host "Starting deployment... (this may take 15-20 minutes)`n"
$startTime = Get-Date

$rawDeployment = az @deployArgs --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    # Print only non-Bicep-installer lines to avoid noise
    ($rawDeployment | Where-Object { $_ -notmatch '^Bicep CLI' }) | Write-Host -ForegroundColor Red
    Write-Error "Deployment failed (exit code $LASTEXITCODE)"
    exit 1
}

# The az CLI sometimes writes "Bicep CLI is already installed..." to stderr which
# gets mixed into stdout via 2>&1. Strip those lines before JSON parsing.
$jsonLines = ($rawDeployment | Where-Object { $_ -notmatch '^Bicep CLI' }) -join "`n"
try {
    $deployment = $jsonLines | ConvertFrom-Json
    $duration = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 2)
    if ($deployment.properties.provisioningState -eq "Succeeded") {
        Write-Success "Deployment completed successfully in $duration minutes"
    } else {
        Write-Error "Deployment ended with state: $($deployment.properties.provisioningState)"
        exit 1
    }
} catch {
    # Fall back to querying Azure directly — handles any remaining parse issues
    $deployState = az deployment sub show --name $DeploymentName --query properties.provisioningState -o tsv 2>&1
    $duration = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 2)
    if ($deployState -eq "Succeeded") {
        Write-Success "Deployment completed successfully in $duration minutes (state confirmed via Azure query)"
    } else {
        Write-Error "Deployment ended with state: $deployState"
        exit 1
    }
}

# ============================================================================
# OUTPUT RESULTS
# ============================================================================

Write-Step "Deployment Outputs"

Write-Host "Fetching deployment outputs...`n"
$outputs = az deployment sub show --name $DeploymentName --query properties.outputs --output json | ConvertFrom-Json

Write-Host "Resource Group:"
Write-Host "  Name: $($outputs.resourceGroupName.value)"
Write-Host "  ID: $($outputs.resourceGroupId.value)`n"

Write-Host "Public DNS Zone:"
Write-Host "  Name: $($outputs.publicDnsZoneName.value)"
Write-Host "  Name Servers:"
foreach ($ns in $outputs.publicDnsNameServers.value) {
    Write-Host "    - $ns" -ForegroundColor Cyan
}

Write-Host "`nPrivate DNS Zone:"
Write-Host "  Name: $($outputs.privateDnsZoneName.value)`n"

Write-Host "Event Hub Integration (QRadar):"
Write-Host "  Namespace: $($outputs.eventHubNamespaceId.value)"
Write-Host "  Event Hub: $($outputs.eventHubName.value)"
Write-Host "  Send Connection String: $($outputs.eventHubSendConnectionString.value.substring(0, 50))..."
Write-Host "  Listen Connection String: $($outputs.eventHubListenConnectionString.value.substring(0, 50))...`n"

Write-Host "Traffic Manager Profiles:"
Write-Host "  Failover: $($outputs.trafficManagerFailoverFqdn.value)"
Write-Host "  Geographic: $($outputs.trafficManagerGeoFqdn.value)"
Write-Host "  Weighted: $($outputs.trafficManagerWeightedFqdn.value)`n"

Write-Host "App Service Domain:"
Write-Host "  Name  : $($outputs.appServiceDomainName.value)"
Write-Host "  Status: $($outputs.appServiceDomainStatus.value)"`n

Write-Host "Web Apps:"
Write-Host "  US Region: $($outputs.webAppUSUrl.value)"
Write-Host "  UK Region: $($outputs.webAppUKUrl.value)`n"

if ($outputs.webAppUSRegionUrl.value -or $outputs.webAppUKRegionUrl.value) {
    Write-Host "Web App Region Endpoints:"
    if ($outputs.webAppUSRegionUrl.value) { Write-Host "  US Region TXT: $($outputs.webAppUSRegionUrl.value)" }
    if ($outputs.webAppUKRegionUrl.value) { Write-Host "  UK Region TXT: $($outputs.webAppUKRegionUrl.value)" }
    Write-Host ""
}

if ($outputs.webAppUSName.value -or $outputs.webAppUKName.value) {
    Write-Step "Publishing Friendly Web App Pages"

    if ($outputs.webAppUSName.value) {
        Publish-FriendlyPage -ResourceGroupName $outputs.resourceGroupName.value -AppName $outputs.webAppUSName.value
    }

    if ($outputs.webAppUKName.value) {
        Publish-FriendlyPage -ResourceGroupName $outputs.resourceGroupName.value -AppName $outputs.webAppUKName.value
    }
}

Write-Host "DNS Test URLs:"
$testUrls = $outputs.dnsTestUrls.value
foreach ($key in $testUrls.PSObject.Properties.Name) {
    Write-Host "  $($key): $($testUrls.$key)" -ForegroundColor Green
}

# ============================================================================
# POST-DEPLOYMENT ACTIONS
# ============================================================================

Write-Step "Post-Deployment Actions Required"

Write-Host "1. UPDATE DNS REGISTRAR" -ForegroundColor Yellow
Write-Host "   Update NS records for '$($outputs.publicDnsZoneName.value)' to:`n"
foreach ($ns in $outputs.publicDnsNameServers.value) {
    Write-Host "   • $ns" -ForegroundColor Cyan
}

Write-Host "`n2. CONFIGURE QRADAR" -ForegroundColor Yellow
Write-Host "   - Event Hub: $($outputs.eventHubName.value)"
Write-Host "   - Consumer Group: qradar-consumer"
Write-Host "   - Connection String: (see outputs above)`n"

Write-Host "3. VERIFY TRAFFIC MANAGER HEALTH" -ForegroundColor Yellow
Write-Host "   Run: az network traffic-manager endpoint list --profile-name tm-poc-failover --resource-group $($outputs.resourceGroupName.value)`n"

Write-Host "4. TEST DNS RESOLUTION" -ForegroundColor Yellow
Write-Host "   Run: nslookup failover.$($outputs.publicDnsZoneName.value)`n"

# ============================================================================
# SAVE OUTPUTS TO FILE
# ============================================================================

$outputFile = "deployment-outputs-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$outputs | ConvertTo-Json -Depth 10 | Out-File $outputFile
Write-Success "Outputs saved to: $outputFile"

# ============================================================================
# COMPLETE
# ============================================================================

Write-Step "Deployment Complete"

Write-Success "Infrastructure deployed successfully!"
Write-Host "`nNext Steps:"
Write-Host "  1. Review post-deployment actions above"
Write-Host "  2. Run POC test scenarios (see README.md)"
Write-Host "  3. Configure QRadar integration"
Write-Host "  4. Validate logging pipeline`n"

Write-Host "For cleanup: az group delete --name $($outputs.resourceGroupName.value) --yes`n" -ForegroundColor DarkGray
