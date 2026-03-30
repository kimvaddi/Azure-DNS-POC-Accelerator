# ============================================================================
# Create DCV Service Principal - Simple Version
# ============================================================================

param(
    [string]$SubscriptionId = "43d55e51-58fe-486f-9e2a-ba56b8dd15de",
    [string]$ResourceGroup = "rg-dns-poc",
    [string]$DnsZoneName = "zava-dnspoc-001.com",
    [string]$ServicePrincipalName = "DCV-Automation-zava-dnspoc-001"
)

$ErrorActionPreference = "Continue"

Write-Host "`n=========================================" -ForegroundColor Cyan
Write-Host "DCV Service Principal Setup" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

# Step 1: Set subscription
Write-Host "`n[1/5] Setting subscription..." -ForegroundColor Yellow
az account set --subscription $SubscriptionId
Write-Host "✓ Subscription set" -ForegroundColor Green

# Step 2: Create custom RBAC role
Write-Host "`n[2/5] Creating custom RBAC role..." -ForegroundColor Yellow
$roleDefFile = "$env:TEMP\dns-role-def.json"
$roleDef = @{
    "Name" = "DNS Record Writer - zava-dnspoc-001"
    "Description" = "Cannot delete DNS records. Used for DCV automation with minimal privileges."
    "Type" = "CustomRole"
    "Permissions" = @(
        @{
            "Actions" = @(
                "Microsoft.Network/dnsZones/read",
                "Microsoft.Network/dnsZones/recordSets/*/read",
                "Microsoft.Network/dnsZones/recordSets/A/write",
                "Microsoft.Network/dnsZones/recordSets/AAAA/write",
                "Microsoft.Network/dnsZones/recordSets/CNAME/write",
                "Microsoft.Network/dnsZones/recordSets/MX/write",
                "Microsoft.Network/dnsZones/recordSets/NS/write",
                "Microsoft.Network/dnsZones/recordSets/PTR/write",
                "Microsoft.Network/dnsZones/recordSets/SRV/write",
                "Microsoft.Network/dnsZones/recordSets/TXT/write",
                "Microsoft.Network/dnsZones/recordSets/SOA/write",
                "Microsoft.Network/dnsZones/recordSets/CAA/write"
            )
            "NotActions" = @(
                "Microsoft.Network/dnsZones/recordSets/delete",
                "Microsoft.Network/dnsZones/recordSets/*/delete"
            )
        }
    )
    "AssignableScopes" = "/subscriptions/$SubscriptionId"
} | ConvertTo-Json -Depth 10

$roleDef | Out-File -FilePath $roleDefFile -Encoding utf8 -Force -ErrorAction SilentlyContinue

# Try to create; it might already exist
az role definition create --role-definition "$roleDefFile" 2>&1 | Select-String "Warning" -NotMatch | Select-String "Error" -NotMatch | Where-Object {$_}

# Get the role ID
$roleId = az role definition list --query "[?roleName=='DNS Record Writer - zava-dnspoc-001'].name" -o tsv
if ($roleId) {
    Write-Host "✓ Custom role: $roleId" -ForegroundColor Green
} else {
    Write-Host "✓ Custom role already exists" -ForegroundColor Green
}

# Step 3: Create app registration
Write-Host "`n[3/5] Creating app registration..." -ForegroundColor Yellow
$appJson = az ad app create --display-name $ServicePrincipalName --output json 2>&1 | Select-String "^{" -Raw
if (!$appJson) {
    # Try to get existing
    $appList = az ad app list --display-name $ServicePrincipalName --output json 2>&1 | Select-String "^\[" -Raw
    if ($appList) {
        $appArray = ($appList | ConvertFrom-Json)
        $app = $appArray[0]
        Write-Host "✓ App registration already exists" -ForegroundColor Green
    } else {
        Write-Host "ERROR: Could not create or find app registration" -ForegroundColor Red
        exit 1
    }
} else {
    $app = $appJson | ConvertFrom-Json
    Write-Host "✓ App registration created" -ForegroundColor Green
}

$appId = $app.appId
$appObjId = $app.id

# Step 4: Create service principal
Write-Host "`n[4/5] Creating service principal..." -ForegroundColor Yellow
$spJson = az ad sp create --id $appId --output json 2>&1 | Select-String "^{" -Raw
if (!$spJson) {
    $spList = az ad sp list --display-name $ServicePrincipalName --output json 2>&1 | Select-String "^\[" -Raw
    if ($spList) {
        $spArray = ($spList | ConvertFrom-Json)
        $sp = $spArray[0]
        Write-Host "✓ Service principal already exists" -ForegroundColor Green
    } else {
        Write-Host "ERROR: Could not create or find service principal" -ForegroundColor Red
        exit 1
    }
} else {
    $sp = $spJson | ConvertFrom-Json
    Write-Host "✓ Service principal created" -ForegroundColor Green
}

$spObjId = $sp.id

# Step 5: Assign RBAC role
Write-Host "`n[5/5] Assigning RBAC role..." -ForegroundColor Yellow
$dnsZoneId = az network dns zone show --name $DnsZoneName -g $ResourceGroup --query "id" -o tsv

if (!$dnsZoneId) {
    Write-Host "ERROR: DNS zone not found: $DnsZoneName" -ForegroundColor Red
    exit 1
}

Write-Host "  DNS Zone: $dnsZoneId" -ForegroundColor Yellow

# Try to create role assignment (might already exist)
az role assignment create `
    --assignee-object-id $spObjId `
    --assignee-principal-type ServicePrincipal `
    --role "DNS Record Writer - zava-dnspoc-001" `
    --scope $dnsZoneId `
    2>&1 | Select-String "Warning" -NotMatch | Select-String "Error" -NotMatch | Where-Object {$_}

Write-Host "✓ RBAC role assigned (or already exists)" -ForegroundColor Green

# Step 6: Generate client secret
Write-Host "`n[6/6] Generating client secret..." -ForegroundColor Yellow
$secretJson = az ad app credential create --id $appId --display-name "DCV-Secret-$(Get-Date -Format 'yyyyMMdd')" --output json 2>&1 | Select-String "^{" -Raw
if ($secretJson) {
    $secret = $secretJson | ConvertFrom-Json
    $clientSecret = $secret.password
    Write-Host "✓ Client secret generated" -ForegroundColor Green
} else {
    Write-Host "⚠ Could not generate secret (may already exist)" -ForegroundColor Yellow
    $clientSecret = "(not generated - use existing or regenerate manually)"
}

# Save credentials
Write-Host "`n=========================================" -ForegroundColor Cyan
Write-Host "SETUP COMPLETE" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

$output = @{
    "applicationId" = $appId
    "servicePrincipalId" = $spObjId
    "tenantId" = "ebf541ac-cacf-4a40-b46e-1accc3810ef8"
    "subscriptionId" = $SubscriptionId
    "dnsZoneResourceId" = $dnsZoneId
    "clientSecret" = $clientSecret
}

Write-Host "`nCredentials:" -ForegroundColor Cyan
foreach ($key in $output.Keys) {
    $val = if ($key -eq "clientSecret" -and $output[$key]) {
        $output[$key].Substring(0, [Math]::Min(20, $output[$key].Length)) + "..."
    } else {
        $output[$key]
    }
    Write-Host "  $($key): $val" -ForegroundColor Green
}

# Save to JSON file
$output | ConvertTo-Json | Out-File -FilePath "dcv-sp-credentials.json" -Encoding utf8 -Force
Write-Host "`n✓ Credentials saved to: dcv-sp-credentials.json" -ForegroundColor Green
Write-Host "`n⚠  KEEP CLIENT SECRET SECURE!" -ForegroundColor Yellow
Write-Host "`nNext: Run Zava_DCV_TLS_Setup.ps1" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
