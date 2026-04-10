# ============================================================================
# Zava DNS POC - Bicep Deployment Script
# ============================================================================
# Deploys complete DNS POC infrastructure to Azure subscription
# Validates template before deployment and captures all outputs
# ============================================================================

<#
.SYNOPSIS
Deploys the Zava Azure DNS POC infrastructure using Bicep.

.DESCRIPTION
Performs pre-flight checks, discovers or accepts a domain, validates the template,
optionally runs what-if/validation-only modes, and executes a subscription-scope
deployment. Deployment outputs are printed and saved to JSON files.

.PARAMETER Location
Azure region used for the subscription deployment operation.

.PARAMETER DeploymentName
Name of the deployment record created in Azure.

.PARAMETER TemplateFile
Path to the Bicep template file.

.PARAMETER ParametersFile
Path to the Bicep parameters file.

.PARAMETER AdditionalParameters
Extra deployment parameter overrides in key=value format.

.PARAMETER ResourceGroupName
Resource group name used for cleanup/redeploy and post-deployment operations.

.PARAMETER DomainSelectionMode
Selects how the public domain is chosen:
Auto = reuse existing deployed public zone when present, otherwise find the first available zava-dnspoc-###.com domain.
CustomerInput = use the domain supplied with -CustomerDomain.

.PARAMETER CustomerDomain
Customer-owned domain or subdomain to use when DomainSelectionMode is CustomerInput.

.PARAMETER Redeploy
Deletes existing DNS POC resource group and related subscription diagnostics before
deploying again.

.PARAMETER ValidateOnly
Runs template validation only, then exits.

.PARAMETER WhatIf
Runs Azure what-if preview, then exits.

.PARAMETER Help
Prints script help/usage and exits.

.EXAMPLE
.\deploy.ps1 -Help

.EXAMPLE
.\deploy.ps1 -ValidateOnly

.EXAMPLE
.\deploy.ps1 -WhatIf -DomainSelectionMode CustomerInput -CustomerDomain contoso.com

.EXAMPLE
.\deploy.ps1 -Redeploy -AdditionalParameters @('deployAppServiceDomain=false')

.NOTES
For full documentation use:
Get-Help .\deploy.ps1 -Detailed
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$Location = '',
    
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

    [Parameter(Mandatory=$false)]
    [ValidateSet('Auto', 'CustomerInput')]
    [string]$DomainSelectionMode = 'Auto',

    [Parameter(Mandatory=$false)]
    [string]$CustomerDomain,

    # When set, deletes the existing rg-dns-poc resource group and all
    # subscription-level diagnostics before deploying. Use this to cleanly
    # redeploy with a new domain name.
    [Parameter(Mandatory=$false)]
    [switch]$Redeploy,
    
    [Parameter(Mandatory=$false)]
    [switch]$ValidateOnly,
    
    [Parameter(Mandatory=$false)]
    [switch]$WhatIf,

    [Parameter(Mandatory=$false)]
    [switch]$Help
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

function Get-DefaultLocationFromParametersFile {
    param(
        [string]$Path,
        [string]$Fallback = 'centralus'
    )

    if (-not $Path -or -not (Test-Path $Path)) {
        return $Fallback
    }

    $line = Select-String -Path $Path -Pattern "^\s*param\s+location\s*=\s*'([^']+)'" | Select-Object -First 1
    if ($line -and $line.Matches.Count -gt 0) {
        return $line.Matches[0].Groups[1].Value
    }

    return $Fallback
}

$defaultLocation = Get-DefaultLocationFromParametersFile -Path $ParametersFile
if ([string]::IsNullOrWhiteSpace($Location)) {
    $Location = $defaultLocation
}

if ($Help) {
    Write-Host "Zava DNS POC deployment script"
    Write-Host ""
    Write-Host "Usage:"
    Write-Host "  .\deploy.ps1 [options]"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -Location <string>               Azure deployment location (default: from parameters file)"
    Write-Host "  -DeploymentName <string>         Deployment record name"
    Write-Host "  -TemplateFile <path>             Bicep template path"
    Write-Host "  -ParametersFile <path>           Bicep parameter file path"
    Write-Host "  -AdditionalParameters <string[]> Additional key=value deployment overrides"
    Write-Host "  -ResourceGroupName <string>      Resource group for redeploy and post-deploy tasks"
    Write-Host "  -DomainSelectionMode <mode>      Auto or CustomerInput (Auto reuses existing deployed zone first)"
    Write-Host "  -CustomerDomain <string>         Required when DomainSelectionMode is CustomerInput"
    Write-Host "  -Redeploy                        Delete and recreate deployment resources"
    Write-Host "  -ValidateOnly                    Validate template only, then exit"
    Write-Host "  -WhatIf                          Show planned changes, then exit"
    Write-Host "  -Help                            Show this help"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  .\deploy.ps1 -Help"
    Write-Host "  .\deploy.ps1 -ValidateOnly"
    Write-Host "  .\deploy.ps1 -WhatIf -DomainSelectionMode CustomerInput -CustomerDomain contoso.com"
    Write-Host "  .\deploy.ps1 -Redeploy -AdditionalParameters @('deployAppServiceDomain=false')"
    Write-Host ""
    Write-Host "Full help: Get-Help .\deploy.ps1 -Detailed"
    exit 0
}

# Prompt for region when -Location is omitted in interactive sessions.
if (-not $PSBoundParameters.ContainsKey('Location') -and [Environment]::UserInteractive) {
    $enteredLocation = Read-Host "Azure deployment location (press Enter for $defaultLocation)"
    if (-not [string]::IsNullOrWhiteSpace($enteredLocation)) {
        $Location = $enteredLocation.Trim()
    }
    Write-Host "Using deployment location: $Location" -ForegroundColor Cyan
}

function Test-ValidDnsZoneName {
    param([string]$ZoneName)

    if (-not $ZoneName) {
        return $false
    }

    return ($ZoneName -match '^(?=.{1,253}$)(?!-)(?:[a-zA-Z0-9-]{1,63}\.)+[A-Za-z]{2,63}$')
}

function Get-ResourceGroupNameFromDomain {
    param(
        [string]$Domain,
        [string]$FallbackResourceGroupName
    )

    if ($Domain -match '^zava-dnspoc-(\d{3})\.com$') {
        return "rg-dnspoc-$($Matches[1])"
    }

    # For customer domains, derive a predictable RG name from the full domain.
    # Example: poc.danmauser.com -> rg-poc-danmauser-com
    $normalizedDomain = ($Domain.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($normalizedDomain) {
        $derivedName = "rg-$normalizedDomain"
        # Azure resource group names can be up to 90 characters.
        if ($derivedName.Length -gt 90) {
            $derivedName = $derivedName.Substring(0, 90).TrimEnd('-')
        }
        return $derivedName
    }

    return $FallbackResourceGroupName
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
        $pocAppName = Get-AppSettingValue -Settings $settings -Name 'POC_APP_NAME' -Default $AppName

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dns-poc-" + [System.Guid]::NewGuid().ToString('N'))
        $siteRoot = Join-Path $tempRoot 'site'
        $packagePath = Join-Path $tempRoot ($AppName + '.zip')

        New-Item -ItemType Directory -Path $siteRoot -Force | Out-Null

        # Region-specific visual theme
        $accentColor  = if ($regionRole -eq 'primary') { '#0078d4' } else { '#107c10' }
        $accentBgTop  = if ($regionRole -eq 'primary') { '#e8f4fd' } else { '#e8f5e9' }
        $accentBgBot  = if ($regionRole -eq 'primary') { '#cce7f6' } else { '#c8e6c9' }
        $regionFlag   = if ($regionRole -eq 'primary') { '&#127482;&#127480;' } else { '&#127468;&#127463;' }
        $roleLabel    = if ($regionRole -eq 'primary') { 'PRIMARY &mdash; US REGION' } else { 'SECONDARY &mdash; UK REGION' }
        $deployedAt   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm UTC')

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
            --bg-top: $accentBgTop;
            --bg-bottom: $accentBgBot;
            --panel: rgba(255, 255, 255, 0.94);
            --text: #163047;
            --muted: #4b6478;
            --accent: $accentColor;
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
        <div class="eyebrow">$regionFlag $roleLabel</div>
        <h1>$regionDisplayName</h1>
        <p>You are connected to the <strong>$regionDisplayName</strong> App Service instance (<code>$pocAppName</code>). This identifies which Traffic Manager endpoint routed this request. Use <code>/metadata.json</code> or <code>/health.json</code> for automated test probes.</p>
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
                <div class="value">$pocAppName</div>
            </section>
        </div>
        <p>Health check: <code>/health.json</code> &nbsp;|&nbsp; Metadata: <code>$metadataEndpoint</code> &nbsp;|&nbsp; Plain text: <code>$regionEndpoint</code></p>
        <p>Public zone: <code>$publicDomain</code>&nbsp;&nbsp;Private zone: <code>$privateDomain</code></p>
        <p style="font-size:12px;color:var(--muted)">Page deployed: $deployedAt</p>
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
        <staticContent>
            <mimeMap fileExtension=".json" mimeType="application/json" />
            <mimeMap fileExtension=".txt" mimeType="text/plain" />
        </staticContent>
    </system.webServer>
</configuration>
"@

        Set-Content -Path (Join-Path $siteRoot 'index.html') -Value $html -Encoding UTF8
        Set-Content -Path (Join-Path $siteRoot 'region.txt') -Value $regionText.Trim() -Encoding UTF8
        Set-Content -Path (Join-Path $siteRoot 'metadata.json') -Value $metadata -Encoding UTF8

        # /health.json — lightweight endpoint used by Traffic Manager probes and test scripts
        $healthJson = [ordered]@{
            status           = 'ok'
            appName          = $pocAppName
            region           = $regionName
            regionDisplayName = $regionDisplayName
            role             = $regionRole
            publicDnsZone    = $publicDomain
            deployedAtUtc    = (Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json -Depth 3
        Set-Content -Path (Join-Path $siteRoot 'health.json') -Value $healthJson -Encoding UTF8

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

function Test-DomainRegisteredInRegistry {
    <#
    .SYNOPSIS
    Queries the RDAP registry (Verisign .com authoritative) to see if a domain is already registered.
    Returns $true if registered (unavailable), $false if not found (potentially purchasable).
    This is more reliable than checkDomainAvailability which only queries GoDaddy's reseller API.
    #>
    param([string]$DomainName)
    try {
        $null = Invoke-RestMethod -Uri "https://rdap.verisign.com/com/v1/domain/$DomainName" `
            -TimeoutSec 10 -ErrorAction Stop
        return $true   # 200 OK = domain exists in registry = taken
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -eq 404) { return $false }   # Not in registry = available
        # Any other error (timeout, network) = unknown, don't block
        return $false
    }
}

function Test-AppServiceDomainPurchasable {
    <#
    .SYNOPSIS
    Tests whether a domain can be purchased via GoDaddy by doing a real ARM deployment
    of just the DNS zone + domain registration. The purchase is made directly in the
    final rg-dnspoc-NNN resource group — no separate precheck RG — so the domain lands
    in the right place from the start (Azure does not support moving App Service Domains
    between resource groups).

    ARM 'validate' does NOT call GoDaddy's backend — it only checks template schema.
    Only an actual 'create' surfaces UNAVAILABLE_DOMAIN from GoDaddy. If the purchase
    succeeds the RG name is returned so the full deployment can target it. If GoDaddy
    rejects the domain the RG is deleted and the next candidate is tried.

    Returns a hashtable: { Purchasable, ResourceGroup, DnsZoneId, Reason }
    #>
    param(
        [string]$SubscriptionId,
        [string]$DomainName,
        [string]$Location,
        [string]$ConsentAgreedBy,
        [string]$ConsentAgreedAt
    )

    # Derive the final resource group name from the domain (same logic as Get-ResourceGroupNameFromDomain).
    $seq = ($DomainName -replace '[^0-9]','').TrimStart('0')
    if (-not $seq) { $seq = '0' }
    $targetRg = "rg-dnspoc-$($seq.PadLeft(3,'0'))"

    # Ensure a clean RG (delete any leftover from a prior run).
    $existing = az group exists --name $targetRg 2>$null
    if ($existing -eq 'true') {
        $null = az group delete --name $targetRg --yes --only-show-errors 2>&1
    }
    $null = az group create --name $targetRg --location $Location --only-show-errors 2>&1

    # Create the DNS zone first — required by DomainRegistration.
    $null = az network dns zone create --resource-group $targetRg --name $DomainName --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) {
        $null = az group delete --name $targetRg --yes --no-wait --only-show-errors 2>&1
        return @{ Purchasable=$false; ResourceGroup=$null; DnsZoneId=$null; Reason='Failed to create DNS zone in target RG' }
    }

    $dnsZoneId = "/subscriptions/$SubscriptionId/resourceGroups/$targetRg/providers/Microsoft.Network/dnszones/$DomainName"
    $contactInfo = @{
        addressMailing = @{ address1='1 Microsoft Way'; city='Redmond'; state='WA'; postalCode='98052'; country='US' }
        email     = 'dnsadmin@zava.com'
        nameFirst = 'DNS'; nameLast = 'Admin'; phone = '+1.4258829080'
    }
    $armTemplate = @{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
        contentVersion = '1.0.0.0'
        resources      = @(@{
            type='Microsoft.DomainRegistration/domains'; apiVersion='2022-09-01'
            name=$DomainName; location='global'
            properties=@{
                autoRenew=$false; dnsType='AzureDns'; dnsZoneId=$dnsZoneId; privacy=$false
                consent=@{ agreementKeys=@('DNRA'); agreedBy=$ConsentAgreedBy; agreedAt=$ConsentAgreedAt }
                contactAdmin=$contactInfo; contactBilling=$contactInfo
                contactRegistrant=$contactInfo; contactTech=$contactInfo
            }
        })
    } | ConvertTo-Json -Depth 15

    $tempFile = [System.IO.Path]::Combine(
        [System.IO.Path]::GetTempPath(),
        "dnspoc-purchase-$([System.Guid]::NewGuid().ToString('N').Substring(0,8)).json"
    )
    Set-Content -Path $tempFile -Value $armTemplate -Encoding UTF8

    try {
        $out = az deployment group create `
            --resource-group $targetRg `
            --template-file $tempFile --output json 2>&1
        $text = $out -join ' '

        if ($LASTEXITCODE -eq 0) {
            # Purchase succeeded — domain and DNS zone are now in the final RG.
            return @{ Purchasable=$true; ResourceGroup=$targetRg; DnsZoneId=$dnsZoneId; Reason='Domain purchased successfully' }
        }

        # GoDaddy/reseller domain rejection — domain is not purchasable.
        if ($text -match 'UNAVAILABLE_DOMAIN' -or
            $text -match "isn'?t available for purchase" -or
            $text -match 'is not available for purchase' -or
            $text -match 'DomainResellerWebService' -or
            $text -match 'Cannot find DomainRegistrationResourceGroup') {
            $null = az group delete --name $targetRg --yes --no-wait --only-show-errors 2>&1
            return @{ Purchasable=$false; ResourceGroup=$null; DnsZoneId=$null; Reason='GoDaddy rejected the domain purchase' }
        }

        # Any other failure — clean up and treat as non-purchasable to be safe.
        $snippet = $text.Substring(0, [Math]::Min(200, $text.Length))
        $null = az group delete --name $targetRg --yes --no-wait --only-show-errors 2>&1
        return @{ Purchasable=$false; ResourceGroup=$null; DnsZoneId=$null; Reason="Deployment failed (non-GoDaddy reason): $snippet" }
    } finally {
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-ParameterOverrideValue {
    param(
        [string[]]$Parameters,
        [string]$Name
    )

    foreach ($parameter in $Parameters) {
        if ($parameter -match "^$([regex]::Escape($Name))=(.*)$") {
            return $Matches[1]
        }
    }

    return $null
}

function Invoke-LocalLetsEncryptTlsSetup {
    param(
        [object]$Outputs,
        [object]$Account,
        [string[]]$AdditionalParameters
    )

    if (-not $Outputs.webAppUSName.value -or -not $Outputs.webAppUKName.value -or -not $Outputs.publicDnsZoneName.value) {
        return
    }

    $tlsMode = Get-ParameterOverrideValue -Parameters $AdditionalParameters -Name 'postDeployTlsMode'
    if (-not $tlsMode) {
        $tlsMode = 'Auto'
    }

    if ($tlsMode -eq 'Skip') {
        Write-Warning "Skipping post-deployment TLS setup because postDeployTlsMode=Skip."
        return
    }

    $shouldRunLocalLetsEncrypt = $tlsMode -in @('Auto', 'LetsEncrypt')
    if (-not $shouldRunLocalLetsEncrypt) {
        return
    }

    $tlsScript = Join-Path $PSScriptRoot 'Invoke-LetsEncryptKeyVaultTls.ps1'
    if (-not (Test-Path $tlsScript)) {
        Write-Warning "TLS setup script not found at $tlsScript."
        return
    }

    $publicZone = $Outputs.publicDnsZoneName.value
    $customDomains = @(
        "webfailover.$publicZone"
        "webgeo.$publicZone"
        "webweighted.$publicZone"
    )

    Write-Step "Post-Deployment TLS Setup"
    Write-Warning "Azure deploymentScripts are blocked in this subscription by storage shared-key policy."
    Write-Warning "Running local Let's Encrypt automation with Azure DNS challenge, Key Vault import, and SNI binding instead."

    $shellExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }

    $tlsArgs = @(
        '-File', $tlsScript,
        '-SubscriptionId', $Account.id,
        '-ResourceGroup', $Outputs.resourceGroupName.value,
        '-DnsZoneName', $publicZone,
        '-KeyVaultName', $Outputs.tlsKeyVaultName.value,
        '-WebAppNames', "$($Outputs.webAppUSName.value),$($Outputs.webAppUKName.value)",
        '-CustomDomains', ($customDomains -join ','),
        '-ContactEmail', "dnsadmin@$publicZone"
    )

    & $shellExe -ExecutionPolicy Bypass @tlsArgs
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Local Let's Encrypt TLS setup completed."
    } else {
        Write-Warning "Local Let's Encrypt TLS setup did not complete successfully. Review the log output above."
    }
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
# REDEPLOY: SELECT EXISTING DEPLOYMENT
# ============================================================================
# When -Redeploy is passed, show all existing POC deployments BEFORE domain
# discovery so the user can target a specific RG. If an RG with a known DNS
# zone is chosen, $discoveredDomain is set here and the Pre-flight domain
# purchase check is skipped entirely.

$redeploySelectedDomain = $false

if ($Redeploy) {
    Write-Step "Select Existing Deployment to Redeploy"
    Write-Host "  Scanning for existing POC deployments in the subscription..." -ForegroundColor Gray

    $pocRgs = az group list --query "[?starts_with(name,'rg-dnspoc-') && !contains(name,'precheck')].{name:name, state:properties.provisioningState, location:location}" -o json 2>$null | ConvertFrom-Json

    if (-not $pocRgs -or $pocRgs.Count -eq 0) {
        Write-Host "  No existing POC deployments found — proceeding as a fresh deployment." -ForegroundColor Yellow
    } else {
        Write-Host ""
        Write-Host "  Existing POC deployments:" -ForegroundColor Cyan
        $idx = 1
        foreach ($rg in $pocRgs) {
            $zoneName = az network dns zone list --resource-group $rg.name --query "[0].name" -o tsv 2>$null
            $zoneLabel = if ($zoneName) { "  domain: $zoneName" } else { "  (no DNS zone)" }
            Write-Host ("  [{0}] {1,-35} [{2}]  $zoneLabel" -f $idx, $rg.name, $rg.state)
            $idx++
        }
        Write-Host ""

        $selection = Read-Host "  Enter number to target (or press Enter to use current: $ResourceGroupName)"
        if ($selection -match '^\d+$') {
            $pick = [int]$selection - 1
            if ($pick -ge 0 -and $pick -lt $pocRgs.Count) {
                $selectedRg = $pocRgs[$pick]
                $ResourceGroupName = $selectedRg.name
                $zoneName = az network dns zone list --resource-group $ResourceGroupName --query "[0].name" -o tsv 2>$null
                if ($zoneName) {
                    $discoveredDomain = $zoneName
                    $redeploySelectedDomain = $true
                    Write-Success "Selected: $ResourceGroupName  (domain: $discoveredDomain — Pre-flight check skipped)"
                } else {
                    Write-Success "Selected: $ResourceGroupName  (no DNS zone found — domain will be discovered)"
                }
                $AdditionalParameters = @($AdditionalParameters | Where-Object { $_ -notmatch '^rgName=' })
                $AdditionalParameters += "rgName=$ResourceGroupName"
            } else {
                Write-Warning "  Invalid selection — using current: $ResourceGroupName"
            }
        } else {
            Write-Host "  Using current target: $ResourceGroupName" -ForegroundColor Gray
        }
    }
    Write-Host ""
}

# ============================================================================
# DOMAIN AVAILABILITY DISCOVERY
# ============================================================================
$subscriptionId = (az account show --query id --output tsv)
$domainBase = 'zava-dnspoc'
$discoveredDomain = $null
$useCustomerDomain = $false
$reusedExistingDeploymentDomain = $false
$nonDestructiveDomainCheck = $ValidateOnly -or $WhatIf

if ($DomainSelectionMode -eq 'CustomerInput') {
    if (-not $CustomerDomain) {
        Write-Error "DomainSelectionMode=CustomerInput requires -CustomerDomain (example: contoso.com or subdomain.contoso.com)."
        exit 1
    }

    $normalizedDomain = $CustomerDomain.Trim().TrimEnd('.')
    if (-not (Test-ValidDnsZoneName -ZoneName $normalizedDomain)) {
        Write-Error "Invalid -CustomerDomain value '$CustomerDomain'. Use values like contoso.com or subdomain.contoso.com."
        exit 1
    }

    Write-Step "Using Customer Input Domain"
    $discoveredDomain = $normalizedDomain
    $useCustomerDomain = $true
    Write-Success "Customer domain selected: $discoveredDomain"
} else {
    # Reuse the currently deployed public DNS zone first when the resource group
    # already contains one. This keeps reruns idempotent and avoids suggesting a
    # new domain for an existing deployment.
    $existingZonesRaw = az network dns zone list --resource-group $ResourceGroupName --query "[].name" --output tsv 2>$null
    $existingZones = @($existingZonesRaw | Where-Object { $_ -and (Test-ValidDnsZoneName -ZoneName $_) })

    if ($existingZones.Count -gt 0) {
        $preferredExistingZone = $existingZones | Where-Object { $_ -like "$domainBase-*.com" } | Select-Object -First 1
        if (-not $preferredExistingZone) {
            $preferredExistingZone = $existingZones | Select-Object -First 1
        }

        Write-Step "Reusing Existing Deployed Domain"
        $discoveredDomain = $preferredExistingZone
        $reusedExistingDeploymentDomain = $true
        Write-Success "Existing public DNS zone selected: $discoveredDomain"
    } elseif ($redeploySelectedDomain) {
        # Domain was already resolved from the selected redeploy RG — skip Pre-flight.
        Write-Host "  Skipping Pre-flight: domain '$discoveredDomain' resolved from selected deployment." -ForegroundColor Gray
    } else {
        # -----------------------------------------------------------------------
        # PRE-CHECK: Verify this subscription can purchase App Service Domains
        # at all before iterating through candidate names. Does a REAL purchase
        # attempt (not validate) so GoDaddy's backend actually responds.
        # Each candidate gets its own temp RG. If purchase succeeds → reuse that
        # RG and domain for the full deployment. If GoDaddy rejects → try next.
        # -----------------------------------------------------------------------

        # Gather public IP + consent timestamp once.
        try {
            $publicIp = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 10).ip
        } catch {
            $publicIp = '0.0.0.0'
        }
        $consentTimestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $bearerToken = (az account get-access-token --query accessToken -o tsv)

        Write-Step "Pre-flight: Domain Purchase Availability Check"
        if ($nonDestructiveDomainCheck) {
            Write-Host "  Running non-destructive availability checks only (ValidateOnly/WhatIf mode)." -ForegroundColor Gray
            Write-Host "  GoDaddy purchase attempt is skipped in preview modes." -ForegroundColor Gray
        } else {
            Write-Host "  Testing real domain purchase eligibility (RDAP → Azure API → GoDaddy)..." -ForegroundColor Gray
            Write-Host "  Note: The GoDaddy check performs an actual purchase attempt in a temp resource group." -ForegroundColor Gray
        }

        $preCheckResult = $null

        # Randomise the candidate pool (1–999) so parallel runs and retries
        # don't collide on the same suffix, and there is no need to scan
        # sequentially through numbers with GoDaddy holds.
        $candidateNumbers = 1..999 | Get-Random -Count 999

        foreach ($i in $candidateNumbers) {
            $candidate = '{0}-{1:D3}.com' -f $domainBase, $i
            Write-Host "  Checking: $candidate ..."

            # Stage 1: RDAP — authoritative .com registry (Verisign).
            Write-Host "  [1/3] RDAP registry ..." -ForegroundColor Gray
            if (Test-DomainRegisteredInRegistry -DomainName $candidate) {
                Write-Host "  -> Registered in .com registry. Skipping." -ForegroundColor Yellow
                continue
            }
            Write-Host "  -> Not in registry." -ForegroundColor Green

            # Stage 2: Azure checkDomainAvailability (fast pre-filter).
            Write-Host "  [2/3] Azure availability API ..." -ForegroundColor Gray
            $checkUri = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.DomainRegistration/checkDomainAvailability?api-version=2022-03-01"
            try {
                $checkResult = Invoke-RestMethod -Uri $checkUri -Method POST `
                    -Headers @{ Authorization = "Bearer $bearerToken"; "Content-Type" = "application/json" } `
                    -Body (@{ name = $candidate } | ConvertTo-Json -Compress) -ErrorAction Stop
                if ($checkResult.available -ne $true) {
                    Write-Host "  -> Not available ($($checkResult.reason)). Skipping." -ForegroundColor Yellow
                    continue
                }
                Write-Host "  -> Available." -ForegroundColor Green
            } catch {
                Write-Host "  -> API check failed — continuing to GoDaddy check." -ForegroundColor Gray
            }

            if ($nonDestructiveDomainCheck) {
                Write-Host "  [3/3] Skipping GoDaddy purchase check (preview mode)." -ForegroundColor Gray
                Write-Success "Pre-flight passed (preview mode): '$candidate' appears available."
                $discoveredDomain = $candidate
                break
            }

            # Stage 3: Real GoDaddy purchase attempt via ARM create (not validate).
            # This is the only reliable way to detect GoDaddy-level holds.
            Write-Host "  [3/3] GoDaddy — real purchase attempt ..." -ForegroundColor Gray
            $purchaseTest = Test-AppServiceDomainPurchasable `
                -SubscriptionId $subscriptionId `
                -DomainName $candidate `
                -Location $Location `
                -ConsentAgreedBy $publicIp `
                -ConsentAgreedAt $consentTimestamp

            if (-not $purchaseTest.Purchasable) {
                Write-Host "  -> GoDaddy says not available — skipping to next." -ForegroundColor Yellow
                continue
            }

            Write-Host "  -> GoDaddy approved purchase." -ForegroundColor Green
            Write-Success "Pre-flight passed: '$candidate' purchased successfully."
            $discoveredDomain = $candidate
            $preCheckResult = $purchaseTest
            break
        }
    }
}

if (-not $discoveredDomain) {
    if ($DomainSelectionMode -eq 'Auto') {
        Write-Error "No purchasable domain found after checking all 999 candidates in range $domainBase-001.com to $domainBase-999.com (random order)."
        Write-Host ""
        Write-Host "Possible causes:" -ForegroundColor Yellow
        Write-Host "  - Previous failed purchase attempts left GoDaddy internal holds on candidate domains." -ForegroundColor Yellow
        Write-Host "  - Your Azure subscription type (e.g. lab/MCA) may not support App Service domain purchases." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Recommended actions:" -ForegroundColor Cyan
        Write-Host "  1. Set deployAppServiceDomain=false in main.bicepparam to skip domain purchase." -ForegroundColor Cyan
        Write-Host "     The Azure DNS zone still gets created and all POC workstreams function normally." -ForegroundColor Cyan
        Write-Host "  2. Or supply a domain you already own:" -ForegroundColor Cyan
        Write-Host "     -DomainSelectionMode CustomerInput -CustomerDomain <your-domain.com>" -ForegroundColor Cyan
    } else {
        Write-Error "No domain selected. Provide -CustomerDomain when using DomainSelectionMode=CustomerInput."
    }
    exit 1
}

# If domain was found via pre-check purchase, the domain is ALREADY registered
# in the temp pre-check RG. The full deployment must go into the properly-named
# rg-dnspoc-NNN RG — NOT the precheck RG. The domain registration resource stays
# in the precheck RG (Azure allows the DNS zone and domain to be in different RGs).
# We pass deployAppServiceDomain=false so the full deployment doesn't try to
# re-purchase the domain that's already been bought.
if ($preCheckResult -and $preCheckResult.ResourceGroup) {
    Write-Host "  Domain purchased in: $($preCheckResult.ResourceGroup)" -ForegroundColor Cyan
    Write-Host "  Setting deployAppServiceDomain=false — purchase already complete." -ForegroundColor Cyan
    $AdditionalParameters = @($AdditionalParameters | Where-Object { $_ -notmatch '^deployAppServiceDomain=' })
    $AdditionalParameters += 'deployAppServiceDomain=false'
    # ResourceGroupName will be derived from the domain name below (rg-dnspoc-NNN),
    # so do NOT override it here — let Get-ResourceGroupNameFromDomain run normally.
}

# If domain was found via Auto scan, publicIp and consentTimestamp were set in the loop above.
# If domain came from CustomerInput or existing zone reuse, capture them now.
if (-not $publicIp) {
    try {
        $publicIp = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 10).ip
        Write-Success "Operator public IP: $publicIp"
    } catch {
        $publicIp = '0.0.0.0'
        Write-Warning "Could not determine public IP; using 0.0.0.0 for consent record."
    }
    $consentTimestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

# Merge domain overrides into AdditionalParameters so every az deployment
# command (validate, what-if, create) uses the discovered domain.
$AdditionalParameters += @(
    "domain=$discoveredDomain",
    "domainConsentAgreedBy=$publicIp",
    "domainConsentAgreedAt=$consentTimestamp"
)

if ($reusedExistingDeploymentDomain) {
    Write-Success "Reusing previously deployed domain without probing for a new one"
}

if ($useCustomerDomain) {
    $isSubdomainInput = ($discoveredDomain.Split('.').Count -gt 2)
    $existingDeployAppServiceDomain = $null
    foreach ($p in $AdditionalParameters) {
        if ($p -match '^deployAppServiceDomain=') {
            $existingDeployAppServiceDomain = ($p -split '=', 2)[1]
        }
    }

    if ($isSubdomainInput -and $existingDeployAppServiceDomain -eq 'true') {
        Write-Error "deployAppServiceDomain=true is not supported with subdomain input '$discoveredDomain'. Set deployAppServiceDomain=false."
        exit 1
    }

    if (-not $existingDeployAppServiceDomain) {
        # Customer-supplied domains are treated as pre-owned/delegated domains.
        # Domain purchase should be disabled unless the operator explicitly overrides it.
        $AdditionalParameters += 'deployAppServiceDomain=false'
        Write-Warning "Customer domain mode detected. Setting deployAppServiceDomain=false unless explicitly overridden."
    }

    # For customer-owned domains, DNS delegation must complete before ACME DNS-01 can validate.
    # Always skip immediate local Let's Encrypt so deployment can finish cleanly.
    $AdditionalParameters = @($AdditionalParameters | Where-Object { $_ -notmatch '^postDeployTlsMode=' })
    $AdditionalParameters += 'postDeployTlsMode=Skip'
    Write-Warning "Customer domain mode detected. Skipping post-deployment Let's Encrypt TLS setup for now."
    Write-Host "  Complete DNS delegation first, then run Invoke-LetsEncryptKeyVaultTls.ps1 separately." -ForegroundColor Yellow
}

# Derive the Let's Encrypt ACME contact email from the discovered domain.
# Using dnsadmin@<domain> keeps the contact tied to the deployment domain
# rather than any individual engineer's personal account.
$acmeContactEmail = "dnsadmin@$discoveredDomain"
$AdditionalParameters += "letsEncryptContactEmail=$acmeContactEmail"
Write-Success "ACME contact email (auto-derived): $acmeContactEmail"

# Derive resource group name from discovered domain when the domain follows
# zava-dnspoc-###.com convention. Example: zava-dnspoc-003.com -> rg-dnspoc-003.
$ResourceGroupName = Get-ResourceGroupNameFromDomain -Domain $discoveredDomain -FallbackResourceGroupName $ResourceGroupName
$AdditionalParameters = @($AdditionalParameters | Where-Object { $_ -notmatch '^rgName=' })
$AdditionalParameters += "rgName=$ResourceGroupName"
Write-Success "Resource group selected: $ResourceGroupName"

# If the target resource group already exists, force deployment/template location
# to match its immutable Azure region.
$existingRgLocation = az group show --name $ResourceGroupName --query location --output tsv 2>$null
if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($existingRgLocation)) {
    if ($existingRgLocation -ne $Location) {
        Write-Warning "Resource group '$ResourceGroupName' already exists in '$existingRgLocation'. Using that location instead of '$Location'."
        $Location = $existingRgLocation
    }
}

Write-Host "`nUsing domain   : $discoveredDomain" -ForegroundColor Cyan
Write-Host "Using RG       : $ResourceGroupName" -ForegroundColor Cyan
Write-Host "Consent IP     : $publicIp"
Write-Host "Consent time   : $consentTimestamp`n"

# Keep template resource-group location aligned with deployment location.
# This avoids InvalidResourceGroupLocation when rerunning against an existing RG.
$AdditionalParameters = @($AdditionalParameters | Where-Object { $_ -notmatch '^location=' })
$AdditionalParameters += "location=$Location"
Write-Success "Template location override set: location=$Location"

# ============================================================================
# DELETE EXISTING DEPLOYMENT (Redeploy mode)
# ============================================================================

if ($Redeploy) {
    Write-Step "Deleting Existing Deployment (-Redeploy)"

    $allLockIds= az lock list --resource-group $ResourceGroupName --query "[].id" -o tsv 2>$null
    if ($allLockIds) {
        foreach ($lockId in $allLockIds) {
            az lock delete --ids $lockId 2>$null
        }
        Write-Success "Resource locks removed."
    } else {
        Write-Host "  No locks found in resource group." -ForegroundColor Gray
    }

    Write-Host "Removing subscription-level Activity Log diagnostic settings (if present)..."
    az monitor diagnostic-settings subscription delete --name activity-log-to-eventhub --yes 2>$null

    # Remove any soft-deleted Key Vaults that match this deployment's naming pattern.
    # Attempt purge for eligible vaults; if purge protection is on, recover instead
    # so the Bicep deployment can re-use the existing vault name cleanly.
    Write-Host "Checking for soft-deleted Key Vaults to purge or recover..."
    $kvsToPurge = az keyvault list-deleted --query "[].{name:name,location:properties.location,purgeProtectionEnabled:properties.purgeProtectionEnabled}" --output json 2>$null | ConvertFrom-Json
    if ($kvsToPurge) {
        foreach ($kv in $kvsToPurge) {
            if ($kv.name -like 'kv-dcv-poc*' -or $kv.name -like 'kvdns*') {
                if ($kv.purgeProtectionEnabled) {
                    Write-Host "  Purge protection enabled on $($kv.name) — will recover after RG is recreated (Bicep or TLS script handles it)." -ForegroundColor Gray
                } else {
                    Write-Host "  Purging soft-deleted Key Vault: $($kv.name)..."
                    az keyvault purge --name $kv.name --location $kv.location 2>$null
                    if ($LASTEXITCODE -eq 0) {
                        Write-Success "  Purged: $($kv.name)"
                    } else {
                        Write-Warning "  Could not purge $($kv.name). Deployment will retry with recovery."
                    }
                }
            }
        }
    } else {
        Write-Host "  No soft-deleted Key Vaults found." -ForegroundColor Gray
    }

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

# Extract postDeployTlsMode from AdditionalParameters before passing to Bicep.
# postDeployTlsMode is only for PowerShell script control flow, not a Bicep parameter.
$postDeployTlsMode = Get-ParameterOverrideValue -Parameters $AdditionalParameters -Name 'postDeployTlsMode' -DefaultValue 'Auto'
$BicepParameters = @($AdditionalParameters | Where-Object { $_ -notmatch '^postDeployTlsMode=' })

Write-Host "Running pre-deployment validation..."
$validateArgs = @('deployment', 'sub', 'validate', '--location', $Location, '--template-file', $TemplateFile)
if ($ParametersFile) { $validateArgs += @('--parameters', $ParametersFile) }
if ($BicepParameters.Count -gt 0) { $validateArgs += @('--parameters') + $BicepParameters }

$rawValidation = az @validateArgs --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    ($rawValidation | Where-Object { $_ -notmatch '^Bicep CLI' }) | Write-Host -ForegroundColor Red
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
    # Bicep CLI warnings/info messages may be mixed into the output,
    # preventing clean JSON parse — if az exited 0, treat as success.
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
    if ($BicepParameters.Count -gt 0) { $whatIfArgs += @('--parameters') + $BicepParameters }
    
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
Write-Host "  Bicep Parameter Overrides: $(if ($BicepParameters.Count -gt 0) { $BicepParameters -join ', ' } else { 'None' })"
Write-Host "  Post-Deploy TLS Mode: $postDeployTlsMode"
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
if ($BicepParameters.Count -gt 0) { $deployArgs += @('--parameters') + $BicepParameters }

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
$sendConnectionString = $outputs.eventHubSendConnectionString.value
$listenConnectionString = $outputs.eventHubListenConnectionString.value

if ([string]::IsNullOrWhiteSpace($sendConnectionString)) {
    Write-Host "  Send Connection String: (secure output hidden/null in deployment output)"
}
else {
    Write-Host "  Send Connection String: $($sendConnectionString.Substring(0, [Math]::Min(50, $sendConnectionString.Length)))..."
}

if ([string]::IsNullOrWhiteSpace($listenConnectionString)) {
    Write-Host "  Listen Connection String: (secure output hidden/null in deployment output)`n"
}
else {
    Write-Host "  Listen Connection String: $($listenConnectionString.Substring(0, [Math]::Min(50, $listenConnectionString.Length)))...`n"
}

Write-Host "Traffic Manager Profiles:"
Write-Host "  Failover: $($outputs.trafficManagerFailoverFqdn.value)"
Write-Host "  Geographic: $($outputs.trafficManagerGeoFqdn.value)"
Write-Host "  Weighted: $($outputs.trafficManagerWeightedFqdn.value)`n"

Write-Host "App Service Domain:"
# Query domain name/status from ARM outputs first, then fall back to direct RG query.
$displayDomainName   = $outputs.appServiceDomainName.value
$displayDomainStatus = $outputs.appServiceDomainStatus.value

if (-not $displayDomainName) {
    # Domain was purchased via pre-check (deployAppServiceDomain=false) — query the
    # deployment RG directly since the resource is there, not in ARM outputs.
    $domainResource = az resource list `
        --resource-group $ResourceGroupName `
        --resource-type 'Microsoft.DomainRegistration/domains' `
        --query "[0].{name:name, state:properties.registrationStatus}" `
        -o json 2>$null | ConvertFrom-Json
    if ($domainResource) {
        $displayDomainName   = $domainResource.name
        $displayDomainStatus = $domainResource.state
    }
}

if (-not $displayDomainName) {
    $displayDomainName   = $discoveredDomain
    $displayDomainStatus = '(purchased — status query unavailable)'
}

Write-Host "  Name  : $displayDomainName"
Write-Host "  Status: $displayDomainStatus`n"

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

Invoke-LocalLetsEncryptTlsSetup -Outputs $outputs -Account $account -AdditionalParameters $AdditionalParameters

Write-Host "DNS Test URLs:"
$testUrls = $outputs.dnsTestUrls.value
foreach ($key in $testUrls.PSObject.Properties.Name) {
    Write-Host "  $($key): $($testUrls.$key)" -ForegroundColor Green
}

# ============================================================================
# POST-DEPLOYMENT ACTIONS
# ============================================================================

Write-Step "Post-Deployment Actions Required"

# ── Precheck RG cleanup ────────────────────────────────────────────────────
# Remove all rg-dnspoc-precheck-* resource groups left over from domain
# availability scans. The winning domain is now in the main deployment RG
# Domain purchases now go directly into rg-dnspoc-NNN, so any rg-dnspoc-precheck-*
# groups are leftover from prior runs and can all be deleted safely.
$precheckRgs = az group list --query "[?starts_with(name,'rg-dnspoc-precheck-')].name" -o tsv 2>$null
if ($precheckRgs) {
    Write-Host "Cleaning up pre-check resource groups..." -ForegroundColor Gray
    foreach ($prg in $precheckRgs) {
        Write-Host "  Deleting $prg ..." -ForegroundColor Gray
        $precheckLocks = az lock list --resource-group $prg --query "[].id" -o tsv 2>$null
        if ($precheckLocks) {
            foreach ($lid in $precheckLocks) { az lock delete --ids $lid 2>$null }
        }
        az group delete --name $prg --yes --no-wait --only-show-errors 2>$null
    }
    Write-Success "Pre-check resource groups queued for deletion."
} else {
    Write-Host "  No pre-check resource groups found." -ForegroundColor Gray
}
Write-Host ""

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

if ($useCustomerDomain) {
    Write-Host "5. RUN TLS SCRIPT AFTER DELEGATION" -ForegroundColor Yellow
    Write-Host "   After NS delegation is complete and TXT queries resolve from public DNS, run:" -ForegroundColor Yellow
    Write-Host ('   pwsh -ExecutionPolicy Bypass -File "{0}\Invoke-LetsEncryptKeyVaultTls.ps1" `' -f $PSScriptRoot) -ForegroundColor Gray
    Write-Host ('     -SubscriptionId "{0}" `' -f $account.id) -ForegroundColor Gray
    Write-Host ('     -ResourceGroup "{0}" `' -f $outputs.resourceGroupName.value) -ForegroundColor Gray
    Write-Host ('     -DnsZoneName "{0}" `' -f $outputs.publicDnsZoneName.value) -ForegroundColor Gray
    Write-Host ('     -KeyVaultName "{0}" `' -f $outputs.tlsKeyVaultName.value) -ForegroundColor Gray
    Write-Host ('     -WebAppNames "{0},{1}" `' -f $outputs.webAppUSName.value, $outputs.webAppUKName.value) -ForegroundColor Gray
    Write-Host ('     -CustomDomains "webfailover.{0},webgeo.{0},webweighted.{0}" `' -f $outputs.publicDnsZoneName.value) -ForegroundColor Gray
    Write-Host ('     -ContactEmail "{0}"' -f $acmeContactEmail) -ForegroundColor Gray
    Write-Host ""
}

# ============================================================================
# SAVE OUTPUTS TO FILE
# ============================================================================

$outputFile = "deployment-outputs-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$outputs | ConvertTo-Json -Depth 10 | Out-File $outputFile
Write-Success "Outputs saved to: $outputFile"

# Also save a fixed-name copy so TrafficManager_Test.ps1 can find it without a timestamp
$fixedOutputFile = Join-Path $PSScriptRoot 'deployment-output.json'
$outputs | ConvertTo-Json -Depth 10 | Out-File $fixedOutputFile -Force
Write-Success "Outputs also saved to: $fixedOutputFile"

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
