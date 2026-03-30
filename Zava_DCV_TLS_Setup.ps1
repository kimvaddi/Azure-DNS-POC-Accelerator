#!/usr/bin/env pwsh
# ============================================================================
# DCV & TLS Certificate Automation for Zava DNS POC
# ============================================================================
# Supports two certificate modes (prompted at runtime if -CertificateSource
# is not specified):
#
#   Option 1 — DigiCert + Azure Key Vault Integration
#     Requires DigiCert CertCentral with API-ordering product enabled.
#     Certificates issued via Key Vault issuer; auto-renewed 60 days before
#     expiry. Blocked if account lacks API-ordering entitlement (product_not_allowed).
#
#   Option 2 — App Service Managed Certificate  [Recommended for POC]
#     Free Microsoft-issued certs, no external CA account required.
#     Domain validated via asuid TXT records already in Azure DNS.
#     Auto-renewed by App Service (6-month validity, auto-rotated).
#
# All Azure operations use Azure CLI (az). Run 'az login' first.
#
# Usage (interactive — prompts for cert type if not given):
#   .\Zava_DCV_TLS_Setup.ps1
#
# Usage (App Service Managed, fully scripted):
#   .\Zava_DCV_TLS_Setup.ps1 -CertificateSource AppServiceManaged
#
# Usage (DigiCert path):
#   .\Zava_DCV_TLS_Setup.ps1 -CertificateSource DigiCert `
#       -DigiCertAccountId "3002535" -DigiCertOrgId "665582"
# ============================================================================

param(
    [Parameter(HelpMessage = "Azure subscription ID")]
    [string]$SubscriptionId = '43d55e51-58fe-486f-9e2a-ba56b8dd15de',

    [Parameter(HelpMessage = "Resource group name")]
    [string]$ResourceGroup = 'rg-dns-poc',

    [Parameter(HelpMessage = "Public DNS zone name")]
    [string]$DnsZoneName = 'zava-dnspoc-001.com',

    [Parameter(HelpMessage = "Custom domains (FQDN) to issue certs for")]
    [string[]]$CustomDomains = @(
        'webfailover.zava-dnspoc-001.com',
        'webgeo.zava-dnspoc-001.com',
        'webweighted.zava-dnspoc-001.com'
    ),

    [Parameter(HelpMessage = "Key Vault name (used for DigiCert path and optional cert storage)")]
    [string]$KeyVaultName = '',

    [Parameter(HelpMessage = "Web app names (auto-discovered if not provided)")]
    [string[]]$WebAppNames,

    [Parameter(HelpMessage = "For App Service Managed Certificates in multi-region deployments, choose the single web app that will host the managed certificates")]
    [string]$ManagedCertificateWebAppName,

    # ---- Certificate source selection (prompted if omitted) ----
    [Parameter(HelpMessage = "Certificate source: DigiCert or AppServiceManaged")]
    [ValidateSet('DigiCert', 'AppServiceManaged')]
    [string]$CertificateSource,

    # ---- DigiCert-specific (only required when CertificateSource = DigiCert) ----
    [Parameter(HelpMessage = "DigiCert CertCentral account ID")]
    [string]$DigiCertAccountId,

    [Parameter(HelpMessage = "DigiCert organization ID")]
    [string]$DigiCertOrgId,

    [Parameter(HelpMessage = "Key Vault issuer alias for DigiCert")]
    [string]$DigiCertIssuerName = 'digicert-zava',

    [Parameter(HelpMessage = "Name of Key Vault secret holding the DigiCert API key")]
    [string]$DigiCertApiKeySecretName = 'digicert-api-key'
)

# ============================================================================
# INITIALIZATION
# ============================================================================

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$logFile   = Join-Path $scriptDir "dcv-tls-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
}

function Write-OK   { param([string]$m); Write-Host "  [OK]   $m" -ForegroundColor Green;  Write-Log $m 'SUCCESS' }
function Write-Warn { param([string]$m); Write-Host "  [WARN] $m" -ForegroundColor Yellow; Write-Log $m 'WARNING' }
function Write-Fail { param([string]$m); Write-Host "  [FAIL] $m" -ForegroundColor Red;    Write-Log $m 'ERROR';   throw $m }

function Get-AppServiceCertificateThumbprint {
    param([string]$CertificateName)

    $queryUrl = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Web/certificates?api-version=2023-01-01"
    $json = az rest --method get --url $queryUrl -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) {
        return $null
    }

    $match = $json | ConvertFrom-Json |
        Select-Object -ExpandProperty value |
        Where-Object { $_.name -eq $CertificateName } |
        Select-Object -First 1

    if ($match) {
        return $match.properties.thumbprint
    }

    return $null
}

# ============================================================================
# STEP 0 — CERTIFICATE SOURCE SELECTION
# ============================================================================

Write-Log "====== Zava DNS POC — DCV & TLS Certificate Setup ======"
Write-Log "Subscription : $SubscriptionId"
Write-Log "Resource Group: $ResourceGroup | DNS Zone: $DnsZoneName"
Write-Log "Custom Domains: $($CustomDomains -join ', ')"

if (-not $CertificateSource) {
    Write-Host ""
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host "  Select Certificate Source" -ForegroundColor Cyan
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  (1) DigiCert + Azure Key Vault Integration" -ForegroundColor White
    Write-Host "      - Requires DigiCert CertCentral account with API-ordering enabled" -ForegroundColor Gray
    Write-Host "      - Contact DigiCert admin if you see product_not_allowed errors" -ForegroundColor Gray
    Write-Host "      - Certificates auto-renewed 60 days before expiry via Key Vault" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  (2) App Service Managed Certificate  [Recommended for POC]" -ForegroundColor White
    Write-Host "      - FREE Microsoft-issued certificates, no external CA account needed" -ForegroundColor Gray
    Write-Host "      - Domain validated via asuid TXT records (already configured in DNS)" -ForegroundColor Gray
    Write-Host "      - Auto-renewed by App Service, valid 6 months (auto-rotated)" -ForegroundColor Gray
    Write-Host ""

    do {
        $choice = Read-Host "  Enter choice [1 or 2, default=2]"
        if ($choice -eq '') { $choice = '2' }
    } until ($choice -in @('1','2'))

    $CertificateSource = if ($choice -eq '1') { 'DigiCert' } else { 'AppServiceManaged' }
    Write-Log "User selected: $CertificateSource"
}

Write-Host ""
Write-Log "Certificate source: $CertificateSource"

# ============================================================================
# STEP 1 — AUTHENTICATE & SET SUBSCRIPTION
# ============================================================================

Write-Log "--- Step 1: Azure CLI authentication ---"

$currentSub = az account show --query id -o tsv 2>$null
if ($currentSub -ne $SubscriptionId) {
    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) { Write-Fail "Could not set subscription $SubscriptionId — run 'az login' first." }
}
Write-OK "Subscription set: $SubscriptionId"

if (-not $KeyVaultName) {
    $kvSuffix = ("$SubscriptionId$ResourceGroup" -replace '[^a-zA-Z0-9]', '').ToLower()
    if ($kvSuffix.Length -gt 15) { $kvSuffix = $kvSuffix.Substring(0, 15) }
    $KeyVaultName = "kvdcv$kvSuffix"
    Write-Log "KeyVaultName not provided; using unique default: $KeyVaultName"
}

# Auto-discover web apps if not provided
if (-not $WebAppNames) {
    Write-Log "Auto-discovering web apps in $ResourceGroup..."
    $WebAppNames = (az webapp list -g $ResourceGroup --query "[].name" -o tsv 2>$null) -split "`n" |
                   Where-Object { $_.Trim() -ne '' }
    if (-not $WebAppNames) { Write-Fail "No web apps found in $ResourceGroup." }
    Write-OK "Discovered web apps: $($WebAppNames -join ', ')"
}

$webAppDetails = foreach ($appName in $WebAppNames) {
    $location = az webapp show -g $ResourceGroup -n $appName --query location -o tsv 2>$null
    [PSCustomObject]@{
        Name = $appName
        Location = $location
    }
}

# ============================================================================
# STEP 2 — VERIFY DNS OWNERSHIP RECORDS (asuid TXT)
# ============================================================================
# asuid.<subdomain> TXT records prove domain ownership for App Service.
# Both certificate paths require these records to be present in the DNS zone.

Write-Log "--- Step 2: Verify asuid domain-ownership TXT records ---"

foreach ($fqdn in $CustomDomains) {
    $subdomain  = $fqdn -replace "\.$(([regex]::Escape($DnsZoneName)))`$", ''
    $recordName = "asuid.$subdomain"

    $existing = az network dns record-set txt show -g $ResourceGroup -z $DnsZoneName -n $recordName `
                    --query "txtRecords[0].value[0]" -o tsv 2>$null

    if ($existing) {
        Write-OK "asuid record exists: $recordName = $existing"
    } else {
        Write-Log "Creating asuid record for $subdomain..."
        $verId = az webapp show -g $ResourceGroup -n $WebAppNames[0] `
                     --query "customDomainVerificationId" -o tsv 2>$null
        if (-not $verId) { Write-Fail "Could not read customDomainVerificationId from $($WebAppNames[0])" }

        az network dns record-set txt create -g $ResourceGroup -z $DnsZoneName -n $recordName --ttl 3600 -o none
        az network dns record-set txt add-record -g $ResourceGroup -z $DnsZoneName -n $recordName `
            --value $verId -o none
        Write-OK "Created asuid record: $recordName = $verId"
    }
}

# ============================================================================
# STEP 3 — VERIFY HOSTNAME BINDINGS
# ============================================================================

Write-Log "--- Step 3: Verify custom hostname bindings on web apps ---"

foreach ($fqdn in $CustomDomains) {
    foreach ($app in $WebAppNames) {
        $bound = az webapp config hostname list -g $ResourceGroup --webapp-name $app `
                     --query "[?name=='$fqdn'].name" -o tsv 2>$null
        if ($bound) {
            Write-OK "Hostname bound: $fqdn -> $app"
        } else {
            Write-Log "Binding $fqdn to $app..."
            $bindResult = az webapp config hostname add -g $ResourceGroup --webapp-name $app --hostname $fqdn -o none 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-OK "Hostname bound: $fqdn -> $app"
            } else {
                Write-Warn "Could not bind $fqdn to ${app}: $bindResult"
            }
        }
    }
}

# ============================================================================
# STEP 4 — CERTIFICATE ISSUANCE
# ============================================================================

if ($CertificateSource -eq 'AppServiceManaged') {

    $managedCertificateApps = @($WebAppNames)
    $managedCertificateLocations = $webAppDetails | Select-Object -ExpandProperty Location -Unique

    if ($managedCertificateLocations.Count -gt 1) {
        Write-Warn "App Service Managed Certificates cannot cover the same hostname across multiple regional App Service webspaces."
        Write-Warn "This deployment has web apps in multiple regions: $($managedCertificateLocations -join ', ')."
        Write-Warn "Managed certificates will be created for one web app only. Traffic Manager routes that land on other regional apps will still need an imported/shared certificate solution."

        if (-not $ManagedCertificateWebAppName) {
            Write-Host ""
            Write-Host "Select the single web app that should host the App Service Managed Certificates:" -ForegroundColor Cyan
            for ($index = 0; $index -lt $webAppDetails.Count; $index++) {
                $candidate = $webAppDetails[$index]
                Write-Host "  ($($index + 1)) $($candidate.Name) [$($candidate.Location)]"
            }

            do {
                $selection = Read-Host "  Enter choice [1-$($webAppDetails.Count)]"
            } until ($selection -match '^\d+$' -and [int]$selection -ge 1 -and [int]$selection -le $webAppDetails.Count)

            $ManagedCertificateWebAppName = $webAppDetails[[int]$selection - 1].Name
        }

        if ($ManagedCertificateWebAppName -notin $WebAppNames) {
            Write-Fail "ManagedCertificateWebAppName '$ManagedCertificateWebAppName' is not one of the discovered/provided web apps."
        }

        $managedCertificateApps = @($ManagedCertificateWebAppName)
        Write-Log "Managed certificates will be created and bound only on: $ManagedCertificateWebAppName"
    }

    # ---- 4a: Create App Service Managed Certificates ---------------------
    Write-Log "--- Step 4 (App Service Managed): Creating free managed certificates ---"
    Write-Log "Certificates are issued by Microsoft — no DigiCert account required."

    $thumbprints = @{}   # key = "appName|fqdn"

    foreach ($fqdn in $CustomDomains) {
        foreach ($app in $managedCertificateApps) {
            Write-Log "Creating managed certificate: $fqdn on $app ..."

            $existingThumbprint = Get-AppServiceCertificateThumbprint -CertificateName $fqdn
            if ($existingThumbprint) {
                $thumbprints["$app|$fqdn"] = $existingThumbprint
                Write-OK "Certificate already exists: $fqdn (thumbprint: $existingThumbprint)"
                continue
            }

            $certJson = az webapp config ssl create `
                            --resource-group $ResourceGroup `
                            --name $app `
                            --hostname $fqdn `
                            --only-show-errors `
                            -o json 2>&1

            if ($LASTEXITCODE -ne 0) {
                Write-Warn "First attempt failed for $fqdn on ${app}: $certJson"
                Write-Log "Waiting 15 s for DNS propagation, then retrying..."
                Start-Sleep -Seconds 15
                $certJson = az webapp config ssl create `
                                --resource-group $ResourceGroup `
                                --name $app `
                                --hostname $fqdn `
                                --only-show-errors `
                                -o json 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Warn "  Still failing — skipping $fqdn on $app : $certJson"
                    continue
                }
            }

            $certObj    = $certJson | ConvertFrom-Json
            $thumbprint = if ($certObj.thumbprint) { $certObj.thumbprint } else { $certObj.properties.thumbprint }
            $thumbprints["$app|$fqdn"] = $thumbprint
            Write-OK "Certificate created: $fqdn on $app  (thumbprint: $thumbprint)"
        }
    }

    # ---- 4b: Bind managed certificates to custom hostnames ---------------
    Write-Log "--- Step 4b: Binding managed certificates to custom hostnames ---"

    foreach ($key in $thumbprints.Keys) {
        $parts = $key -split '\|', 2
        $app   = $parts[0]
        $fqdn  = $parts[1]
        $tp    = $thumbprints[$key]

        Write-Log "Binding cert ($tp) for $fqdn on $app ..."
        $bindResult = az webapp config ssl bind `
                          --resource-group $ResourceGroup `
                          --name $app `
                          --certificate-thumbprint $tp `
                          --ssl-type SNI `
                          -o none 2>&1

        if ($LASTEXITCODE -eq 0) {
            Write-OK "TLS bound (SNI): $fqdn on $app"
        } else {
            Write-Warn "Bind failed for $fqdn on ${app}: $bindResult"
        }
    }

} else {

    # ---- 4c: DigiCert + Key Vault Integration ----------------------------
    Write-Log "--- Step 4 (DigiCert Key Vault): Configuring DigiCert issuer and certificates ---"

    if (-not $DigiCertAccountId) {
        $DigiCertAccountId = Read-Host "  DigiCert account ID (e.g. 3002535)"
    }
    if (-not $DigiCertOrgId) {
        $DigiCertOrgId = Read-Host "  DigiCert organization ID (e.g. 665582)"
    }

    # Retrieve or prompt for API key
    $apiKey = az keyvault secret show --vault-name $KeyVaultName `
                  --name $DigiCertApiKeySecretName --query value -o tsv 2>$null
    if (-not $apiKey) {
        Write-Warn "DigiCert API key not found in Key Vault secret '$DigiCertApiKeySecretName'."
        $secureKey = Read-Host "  Enter DigiCert API key" -AsSecureString
        $apiKey = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                      [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey))
        az keyvault secret set --vault-name $KeyVaultName `
            --name $DigiCertApiKeySecretName --value $apiKey -o none
        Write-OK "API key saved to Key Vault secret: $DigiCertApiKeySecretName"
    } else {
        Write-OK "DigiCert API key loaded from Key Vault"
    }

    # Upsert Key Vault issuer
    $issuerExists = az keyvault certificate issuer show --vault-name $KeyVaultName `
                        --issuer-name $DigiCertIssuerName --query name -o tsv 2>$null
    if ($issuerExists) {
        az keyvault certificate issuer update --vault-name $KeyVaultName `
            --issuer-name $DigiCertIssuerName `
            --account-id $DigiCertAccountId `
            --organization-id $DigiCertOrgId `
            --password $apiKey -o none
        Write-OK "Key Vault issuer updated: $DigiCertIssuerName"
    } else {
        az keyvault certificate issuer create --vault-name $KeyVaultName `
            --issuer-name $DigiCertIssuerName `
            --provider-name DigiCert `
            --account-id $DigiCertAccountId `
            --org-id $DigiCertOrgId `
            --password $apiKey -o none
        Write-OK "Key Vault issuer created: $DigiCertIssuerName"
    }

    # Create _dnsauth TXT records (DCV placeholders — update with real tokens from CertCentral)
    Write-Log "--- Step 4d: Creating DigiCert _dnsauth DCV TXT records (placeholders) ---"
    Write-Log "NOTE: Replace placeholder values with actual DCV tokens from DigiCert CertCentral."

    foreach ($fqdn in $CustomDomains) {
        $subdomain  = $fqdn -replace "\.$(([regex]::Escape($DnsZoneName)))`$", ''
        $recordName = "$subdomain._dnsauth"
        $token      = "digicert-dcv-pending-$(Get-Date -Format 'yyyyMMddHHmmss')"

        az network dns record-set txt create -g $ResourceGroup -z $DnsZoneName `
            -n $recordName --ttl 300 -o none 2>$null
        $vals = (az network dns record-set txt show -g $ResourceGroup -z $DnsZoneName `
                     -n $recordName --query "txtRecords[].value[]" -o tsv 2>$null) -split "`n" |
                 Where-Object { $_.Trim() -ne '' }
        foreach ($v in $vals) {
            az network dns record-set txt remove-record -g $ResourceGroup -z $DnsZoneName `
                -n $recordName --value $v -o none 2>$null
        }
        az network dns record-set txt add-record -g $ResourceGroup -z $DnsZoneName `
            -n $recordName --value $token -o none
        Write-OK "DCV record set: $recordName  (update with real token from CertCentral)"
    }

    # Submit Key Vault certificate requests
    Write-Log "--- Step 4e: Creating Key Vault certificate objects (DigiCert issuer) ---"

    foreach ($fqdn in $CustomDomains) {
        $subdomain = $fqdn -replace "\.$(([regex]::Escape($DnsZoneName)))`$", ''
        $certName  = "cert-$subdomain"

        $policy = az keyvault certificate get-default-policy | ConvertFrom-Json
        $policy.issuerParameters.name = $DigiCertIssuerName
        $policy.x509CertificateProperties.subject = "CN=$fqdn"
        $policy.lifetimeActions[0].trigger.daysBeforeExpiry = 60
        $policyPath = Join-Path $env:TEMP "$certName-policy.json"
        ($policy | ConvertTo-Json -Depth 30) | Set-Content $policyPath -Encoding utf8

        az keyvault certificate create --vault-name $KeyVaultName `
            --name $certName --policy "@$policyPath" -o none 2>$null
        Write-OK "Certificate request submitted: $certName  (DigiCert issuance pending)"
    }

    Write-Host ""
    Write-Warn "DigiCert certificates are in 'pending' state."
    Write-Warn "NEXT STEPS to unblock:"
    Write-Warn "  1. Log in to DigiCert CertCentral (account $DigiCertAccountId / org $DigiCertOrgId)"
    Write-Warn "  2. Ensure API-ordering TLS product is enabled for this account"
    Write-Warn "  3. Update _dnsauth TXT records in DNS zone with real DCV tokens"
    Write-Warn "  4. Once DigiCert validates, the KV certificate auto-merges"
    Write-Warn "  Workaround: re-run with -CertificateSource AppServiceManaged"
}

# ============================================================================
# STEP 5 — VERIFY HTTPS
# ============================================================================

Write-Log "--- Step 5: HTTPS verification ---"
Write-Host ""
$allOk = $true

foreach ($fqdn in $CustomDomains) {
    foreach ($app in $WebAppNames) {
        $sslState = az webapp config hostname list -g $ResourceGroup --webapp-name $app `
                        --query "[?name=='$fqdn'].sslState" -o tsv 2>$null
        if ($sslState -eq 'SniEnabled') {
            Write-OK "SSL SNI active : $fqdn on $app"
        } else {
            Write-Warn "SSL not bound   : $fqdn on $app  (sslState=$sslState)"
            $allOk = $false
        }
    }
}

if ($CertificateSource -eq 'AppServiceManaged' -and $allOk) {
    Write-Log "Probing HTTPS endpoints..."
    foreach ($fqdn in $CustomDomains) {
        try {
            $resp = Invoke-WebRequest -Uri "https://$fqdn" -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
            Write-OK "HTTPS OK: https://$fqdn  ($($resp.StatusCode))"
        } catch {
            Write-Warn "HTTPS probe failed for https://$fqdn  — $_"
            Write-Warn "  DNS may still be propagating, or Traffic Manager health probe not green yet."
        }
    }
}

# ============================================================================
# SUMMARY
# ============================================================================

Write-Host ""
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "  DCV & TLS Setup — Summary" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "  Certificate source : $CertificateSource" -ForegroundColor White
Write-Host "  DNS Zone           : $DnsZoneName"        -ForegroundColor White
Write-Host "  Key Vault          : $KeyVaultName"       -ForegroundColor White
Write-Host "  Domains            :"                     -ForegroundColor White
foreach ($fqdn in $CustomDomains) { Write-Host "    - $fqdn" -ForegroundColor Gray }
Write-Host "  Web Apps           :"                     -ForegroundColor White
foreach ($app in $WebAppNames) { Write-Host "    - $app" -ForegroundColor Gray }
Write-Host ""

if ($CertificateSource -eq 'AppServiceManaged') {
    Write-Host "  DNS DCV ownership records (asuid TXT):" -ForegroundColor White
    foreach ($fqdn in $CustomDomains) {
        $sub = $fqdn -replace "\.$(([regex]::Escape($DnsZoneName)))`$", ''
        Write-Host "    asuid.$sub.$DnsZoneName" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "  App Service Managed Certificates auto-renew every 6 months." -ForegroundColor Green
    Write-Host "  No manual action required — App Service handles renewal."     -ForegroundColor Green
    if ($ManagedCertificateWebAppName) {
        Write-Host "  Managed certificate hosting app: $ManagedCertificateWebAppName" -ForegroundColor Yellow
        Write-Host "  Other regional apps still require an imported/shared certificate for end-to-end HTTPS." -ForegroundColor Yellow
    }
} else {
    Write-Host "  DigiCert KV issuer : $DigiCertIssuerName" -ForegroundColor White
    Write-Host "  See warnings above for steps to unblock issuance." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  Log : $logFile" -ForegroundColor DarkGray
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host ""
Write-OK "DCV & TLS Certificate setup complete!"
