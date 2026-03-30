# ============================================================================
# Create DCV Service Principal with Minimal DNS Permissions
# ============================================================================
# This script uses Azure CLI to create:
# 1. Custom RBAC role for DNS record writing (no delete)
# 2. App registration and service principal
# 3. RBAC role assignment scoped to the DNS zone
# ============================================================================

param(
    [string]$SubscriptionId = "43d55e51-58fe-486f-9e2a-ba56b8dd15de",
    [string]$ResourceGroup = "rg-dns-poc",
    [string]$DnsZoneName = "zava-dnspoc-001.com",
    [string]$ServicePrincipalName = "DCV-Automation-zava-dnspoc-001"
)

$ErrorActionPreference = "Stop"
$WarningPreference = "Continue"

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "DCV Service Principal Setup via Azure CLI" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan


# ============================================================================
# STEP 1: Set subscription context via Azure CLI
# ============================================================================
Write-Host "`n[1/5] Setting subscription context..." -ForegroundColor Yellow
az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) {
    throw "Failed to set Azure subscription context"
}
Write-Host "✓ Subscription set: $SubscriptionId" -ForegroundColor Green


# ============================================================================
# STEP 2: Create custom RBAC role definition
# ============================================================================
Write-Host "`n[2/5] Creating custom RBAC role (DNS Record Writer)..." -ForegroundColor Yellow

# Create role definition file
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
    "AssignableScopes" = @(
        "/subscriptions/$SubscriptionId"
    )
} | ConvertTo-Json -Depth 5

$roleDef | Out-File -FilePath $roleDefFile -Encoding utf8 -Force

# Create the role
$roleOutput = az role definition create --role-definition "$roleDefFile" --output json 2>&1
if ($LASTEXITCODE -eq 0) {
    $roleObj = $roleOutput | ConvertFrom-Json
    $roleId = $roleObj.name
    Write-Host "✓ Custom role created: $roleId" -ForegroundColor Green
} else {
    Write-Host "Role creation output: $roleOutput" -ForegroundColor Yellow
    # Role might already exist, try to get it
    $roleId = az role definition list --query "[?roleName=='DNS Record Writer - zava-dnspoc-001'].name" -o json 2>&1 | ConvertFrom-Json | Select-Object -First 1
    if ($roleId) {
        Write-Host "✓ Custom role already exists: $roleId" -ForegroundColor Green
    } else {
        throw "Failed to create or find custom RBAC role"
    }
}


# ============================================================================
# STEP 3: Create app registration
# ============================================================================
Write-Host "`n[3/5] Creating app registration..." -ForegroundColor Yellow

# Try to create app registration
$appJsonRaw = az ad app create --display-name $ServicePrincipalName --output json 2>&1 | Out-String
$appJson = $appJsonRaw -replace '(?ms)^WARNING:.*?$', '' -replace '(?ms)^ERROR:.*?$', '' | ForEach-Object {$_.Trim()} | Where-Object {$_ -and -not $_.StartsWith("{")}

if (!$appJson) {
    $appJson = $appJsonRaw | ForEach-Object {$_.Trim()} | Select-String '{' -Raw | Select-Object -First 1
}

if ($appJson -match '{') {
    try {
        $app = $appJson | ConvertFrom-Json
        $appId = $app.appId
        $appObjId = $app.id
        Write-Host "✓ App registration created: $appId" -ForegroundColor Green
    } catch {
        # App might already exist, try listing
        Write-Host "  Checking if app already exists..." -ForegroundColor Yellow
        $appListRaw = az ad app list --display-name $ServicePrincipalName --output json 2>&1 | Out-String
        $appListJson = $appListRaw -replace '(?ms)^WARNING:.*?$', '' -replace '(?ms)^ERROR:.*?$', '' | ForEach-Object {$_.Trim()} | Where-Object {$_} | Out-String
        
        if ($appListJson -match '^\[') {
            $appArray = $appListJson | ConvertFrom-Json
            if ($appArray.Count -gt 0) {
                $app = $appArray[0]
                $appId = $app.appId
                $appObjId = $app.id
                Write-Host "✓ App registration already exists: $appId" -ForegroundColor Green
            } else {
                throw "Failed to create or find app registration"
            }
        } else {
            throw "Failed to create or find app registration. Error: $_"
        }
    }
} else {
    # Try to get existing app
    Write-Host "  Checking if app already exists..." -ForegroundColor Yellow
    $appListRaw = az ad app list --display-name $ServicePrincipalName --output json 2>&1 | Out-String
    $appListJson = $appListRaw -replace '(?ms)^WARNING:.*?$', '' -replace '(?ms)^ERROR:.*?$', '' | Where-Object {$_ -and $_ -match '^\['} | Out-String
    
    if ($appListJson) {
        $appArray = $appListJson | ConvertFrom-Json
        if ($appArray.Count -gt 0) {
            $app = $appArray[0]
            $appId = $app.appId
            $appObjId = $app.id
            Write-Host "✓ App registration already exists: $appId" -ForegroundColor Green
        } else {
            throw "Failed to create or find app registration"
        }
    } else {
        throw "Failed to create or find app registration"
    }
}


# ============================================================================
# STEP 4: Create service principal
# ============================================================================
Write-Host "`n[4/5] Creating service principal..." -ForegroundColor Yellow

# Try to create service principal
$spOutput = @()
az ad sp create --id $appId --output json 2>&1 | Foreach-Object {
    if ($_ -and -not $_.StartsWith("WARNING:")) {
        $spOutput += $_
    }
}
$spJson = $spOutput -join "`n"

if ($spJson) {
    $sp = $spJson | ConvertFrom-Json
    $spObjId = $sp.id
    Write-Host "✓ Service principal created: $spObjId" -ForegroundColor Green
} else {
    # SP might already exist
    Write-Host "  Checking if service principal already exists..." -ForegroundColor Yellow
    $spListOutput = @()
    az ad sp list --display-name $ServicePrincipalName --output json 2>&1 | Foreach-Object {
        if ($_ -and -not $_.StartsWith("WARNING:")) {
            $spListOutput += $_
        }
    }
    $spListJson = $spListOutput -join "`n"
    
    if ($spListJson) {
        $spArray = $spListJson | ConvertFrom-Json
        if ($spArray -is [array] -and $spArray.Count -gt 0) {
            $sp = $spArray[0]
        } elseif ($spArray -is [object]) {
            $sp = $spArray
        } else {
            throw "Failed to create service principal"
        }
        
        $spObjId = $sp.id
        Write-Host "✓ Service principal already exists: $spObjId" -ForegroundColor Green
    } else {
        throw "Failed to create or find service principal"
    }
}


# ============================================================================
# STEP 5: Assign RBAC role to service principal (scoped to DNS zone)
# ============================================================================
Write-Host "`n[5/5] Assigning RBAC role to service principal..." -ForegroundColor Yellow

# Get DNS zone resource ID
$dnsZoneOutput = @()
az network dns zone show --name $DnsZoneName -g $ResourceGroup --query "id" -o json 2>&1 | Foreach-Object {
    if ($_ -and -not $_.StartsWith("WARNING:")) {
        $dnsZoneOutput += $_
    }
}
$dnsZoneJson = $dnsZoneOutput -join "`n"

if (-not $dnsZoneJson) {
    throw "Failed to find DNS zone: $DnsZoneName"
}

$dnsZoneId = $dnsZoneJson | ConvertFrom-Json
Write-Host "  DNS Zone ID: $dnsZoneId" -ForegroundColor Yellow

# Check if role assignment already exists
$assignmentOutput = @()
az role assignment list `
    --assignee $spObjId `
    --scope $dnsZoneId `
    --role "DNS Record Writer - zava-dnspoc-001" `
    --output json 2>&1 | Foreach-Object {
    if ($_ -and -not $_.StartsWith("WARNING:")) {
        $assignmentOutput += $_
    }
}
$assignmentJson = $assignmentOutput -join "`n"

if ($assignmentJson) {
    $assignmentArray = $assignmentJson | ConvertFrom-Json
    if (($assignmentArray -is [array] -and $assignmentArray.Count -gt 0) -or ($assignmentArray -is [object] -and $assignmentArray.principalId)) {
        Write-Host "✓ Role assignment already exists" -ForegroundColor Green
    } else {
        # Create the assignment
        Write-Host "  Creating role assignment..." -ForegroundColor Yellow
        az role assignment create `
            --assignee-object-id $spObjId `
            --assignee-principal-type ServicePrincipal `
            --role "DNS Record Writer - zava-dnspoc-001" `
            --scope $dnsZoneId `
            --output json > $null
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to assign RBAC role"
        }
        Write-Host "✓ RBAC role assigned to service principal (scoped to DNS zone)" -ForegroundColor Green
    }
} else {
    # No assignments found, try to create one
    Write-Host "  Creating role assignment..." -ForegroundColor Yellow
    az role assignment create `
        --assignee-object-id $spObjId `
        --assignee-principal-type ServicePrincipal `
        --role "DNS Record Writer - zava-dnspoc-001" `
        --scope $dnsZoneId `
        --output json > $null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ RBAC role assigned to service principal (scoped to DNS zone)" -ForegroundColor Green
    } else {
        throw "Failed to assign RBAC role"
    }
}


# ============================================================================
# STEP 6: Generate client secret
# ============================================================================
Write-Host "`n[6/6] Generating client secret..." -ForegroundColor Yellow

$secretOutput = @()
az ad app credential create --id $appId --display-name "DCV-Automation-Secret" --output json 2>&1 | Foreach-Object {
    if ($_ -and -not $_.StartsWith("WARNING:")) {
        $secretOutput += $_
    }
}
$secretJson = $secretOutput -join "`n"

if ($secretJson) {
    try {
        $secret = $secretJson | ConvertFrom-Json
        $clientSecret = $secret.password
        Write-Host "✓ Client secret generated (expires in 12 months)" -ForegroundColor Green
    } catch {
        Write-Host "WARNING: Could not parse secret response. Secret may not have been created." -ForegroundColor Yellow
        $clientSecret = "<ERROR: Could not parse secret>"
    }
} else {
    Write-Host "WARNING: Could not generate new secret. Use existing secret or regenerate manually." -ForegroundColor Yellow
    $clientSecret = "<ERROR: Could not generate secret>"
}


# ============================================================================
# OUTPUT RESULTS
# ============================================================================
Write-Host "`n=============================================" -ForegroundColor Cyan
Write-Host "SERVICE PRINCIPAL SETUP COMPLETE" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

$output = @{
    "applicationId" = $appId
    "servicePrincipalId" = $spObjId
    "servicePrincipalObjectId" = $sp.id
    "tenantId" = "ebf541ac-cacf-4a40-b46e-1accc3810ef8"
    "subscriptionId" = $SubscriptionId
    "dnsZoneName" = $DnsZoneName
    "dnsZoneResourceId" = $dnsZoneId
    "customRoleId" = $roleId
    "customRoleName" = "DNS Record Writer - zava-dnspoc-001"
    "clientSecret" = $clientSecret
    "clientSecretExpiresIn" = "12 months"
}

Write-Host "`nCredentials (store in secure location):" -ForegroundColor Cyan
$output | Format-Table -Property @{Name="Key"; Expression={$_.Name}}, Value

# Save credentials JSON
$credentialsFile = "dcv-service-principal-credentials.json"
$output | ConvertTo-Json | Out-File -FilePath $credentialsFile -Encoding utf8 -Force
Write-Host "`n✓ Credentials exported to: $credentialsFile" -ForegroundColor Green
Write-Host "  ⚠️  KEEP THIS FILE SECURE - IT CONTAINS YOUR CLIENT SECRET" -ForegroundColor Yellow

Write-Host "`nNext steps:" -ForegroundColor Cyan
Write-Host "  1. Store the client secret in a secure location (e.g., Azure Key Vault, password manager)" -ForegroundColor White
Write-Host "  2. Use these credentials to run DCV-enabled deployments" -ForegroundColor White
Write-Host "  3. Run: .\Zava_DCV_TLS_Setup.ps1 -SubscriptionId ... -ServicePrincipalName '$ServicePrincipalName'" -ForegroundColor White

Write-Host "`n=============================================" -ForegroundColor Cyan
