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
    [string]$TemplateFile = "main.bicep",
    
    [Parameter(Mandatory=$false)]
    [string]$ParametersFile = "main.bicepparam",
    
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
# BUILD TEMPLATE
# ============================================================================

Write-Step "Building Bicep Template"

Write-Host "Compiling Bicep to ARM JSON..."
try {
    az bicep build --file $TemplateFile
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
$validateCmd = "az deployment sub validate --location $Location --template-file $TemplateFile"
if ($ParametersFile) {
    $validateCmd += " --parameters $ParametersFile"
}

try {
    $validation = Invoke-Expression "$validateCmd --output json" | ConvertFrom-Json
    
    if ($validation.error) {
        Write-Error "Validation failed: $($validation.error.message)"
        exit 1
    }
    
    Write-Success "Template validation passed"
} catch {
    Write-Error "Validation command failed: $_"
    exit 1
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
    
    $whatIfCmd = "az deployment sub what-if --location $Location --template-file $TemplateFile"
    if ($ParametersFile) {
        $whatIfCmd += " --parameters $ParametersFile"
    }
    
    Write-Host "Generating what-if preview..."
    Invoke-Expression $whatIfCmd
    
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

$deployCmd = "az deployment sub create --name $DeploymentName --location $Location --template-file $TemplateFile"
if ($ParametersFile) {
    $deployCmd += " --parameters $ParametersFile"
}

Write-Host "Starting deployment... (this may take 15-20 minutes)`n"
$startTime = Get-Date

try {
    $deployment = Invoke-Expression "$deployCmd --output json" | ConvertFrom-Json
    
    if ($deployment.properties.provisioningState -eq "Succeeded") {
        $duration = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 2)
        Write-Success "Deployment completed successfully in $duration minutes"
    } else {
        Write-Error "Deployment failed with state: $($deployment.properties.provisioningState)"
        exit 1
    }
} catch {
    Write-Error "Deployment command failed: $_"
    exit 1
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

Write-Host "Web Apps:"
Write-Host "  US Region: $($outputs.webAppUSUrl.value)"
Write-Host "  UK Region: $($outputs.webAppUKUrl.value)`n"

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
