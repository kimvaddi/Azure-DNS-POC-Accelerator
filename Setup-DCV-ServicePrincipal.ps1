#!/usr/bin/env pwsh
# ============================================================================
# Service Principal Setup for DCV Automation
# ============================================================================
# Creates a Microsoft Entra ID service principal with minimal DNS permissions
# for automated Domain Control Validation (DCV).
#
# This service principal can:
#   ✓ Create DNS TXT records (for DCV validation)
#   ✓ Read DNS zone information
#   ✗ DELETE DNS records (explicitly denied for safety)
#
# Usage:
#   .\Setup-DCV-ServicePrincipal.ps1 `
#       -SubscriptionId "<sub-id>" `
#       -ResourceGroup "rg-dns-poc" `
#       -DnsZonyName "zava-dnspoc-001.com" `
#       -ServicePrincipalName "DCV-Automation-zava-dnspoc-001"
#
# Outputs:
#   - Service Principal Object ID
#   - Application ID (Client ID)
#   - Custom role definition ID
#   - RBAC role assignment ID
# ============================================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$DnsZoneName,

    [Parameter(Mandatory = $false)]
    [string]$ServicePrincipalName = "DCV-Automation-$DnsZoneName",

    [Parameter(Mandatory = $false)]
    [int]$AppPasswordExpirationMonths = 12,

    [Parameter(Mandatory = $false)]
    [switch]$GenerateClientSecret
)

$ErrorActionPreference = 'Stop'

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Service Principal Setup for DCV" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

# Step 1: Authenticate
Write-Host "[1/5] Authenticating to Azure..." -ForegroundColor Yellow
$context = Get-AzContext
if (-not $context) {
    Connect-AzAccount -Subscription $SubscriptionId
    Set-AzContext -Subscription $SubscriptionId
}
else {
    Set-AzContext -Subscription $SubscriptionId
}

Write-Host "✓ Connected to subscription $SubscriptionId" -ForegroundColor Green

# Step 2: Get DNS Zone reference
Write-Host "[2/5] Getting DNS Zone reference..." -ForegroundColor Yellow
$dnsZone = Get-AzDnsZone -ResourceGroupName $ResourceGroup -Name $DnsZoneName -ErrorAction Stop
Write-Host "✓ DNS Zone: $($dnsZone.Id)" -ForegroundColor Green

# Step 3: Create custom RBAC role
Write-Host "[3/5] Creating custom RBAC role (DNS Record Writer)..." -ForegroundColor Yellow

$customRoleJson = @{
    Name             = 'DNS Record Writer'
    Description      = 'Create and update DNS records. Cannot delete. Used for DCV automation.'
    Type             = 'CustomRole'
    Actions          = @(
        'Microsoft.Network/dnsZones/read',
        'Microsoft.Network/dnsZones/recordSets/read',
        'Microsoft.Network/dnsZones/recordSets/*/read',
        'Microsoft.Network/dnsZones/recordSets/A/write',
        'Microsoft.Network/dnsZones/recordSets/AAAA/write',
        'Microsoft.Network/dnsZones/recordSets/CNAME/write',
        'Microsoft.Network/dnsZones/recordSets/MX/write',
        'Microsoft.Network/dnsZones/recordSets/NS/write',
        'Microsoft.Network/dnsZones/recordSets/PTR/write',
        'Microsoft.Network/dnsZones/recordSets/SRV/write',
        'Microsoft.Network/dnsZones/recordSets/TXT/write',
        'Microsoft.Network/dnsZones/recordSets/CAA/write'
    )
    NotActions       = @(
        'Microsoft.Network/dnsZones/recordSets/delete',
        'Microsoft.Network/dnsZones/recordSets/*/delete'
    )
    AssignableScopes = @(
        "/subscriptions/$SubscriptionId"
    )
} | ConvertTo-Json

$tempRolePath = [System.IO.Path]::GetTempFileName()
$customRoleJson | Out-File -FilePath $tempRolePath -Force

try {
    # Check if role already exists
    $existingRole = Get-AzRoleDefinition -Name "DNS Record Writer" -ErrorAction SilentlyContinue
    if ($existingRole) {
        Write-Host "✓ Custom role already exists: $($existingRole.Id)" -ForegroundColor Green
        $customRoleId = $existingRole.Id
    }
    else {
        $newRole = New-AzRoleDefinition -InputFile $tempRolePath -ErrorAction Stop
        Write-Host "✓ Custom role created: $($newRole.Id)" -ForegroundColor Green
        $customRoleId = $newRole.Id
    }
}
finally {
    Remove-Item -Path $tempRolePath -Force -ErrorAction SilentlyContinue
}

# Step 4: Create or retrieve service principal
Write-Host "[4/5] Creating/retrieving service principal..." -ForegroundColor Yellow

$existingApp = Get-AzADApplication -DisplayName $ServicePrincipalName -ErrorAction SilentlyContinue

if ($existingApp) {
    Write-Host "✓ Application already exists: $($existingApp.Id)" -ForegroundColor Green
    $appId = $existingApp.Id
    $app = Get-AzADApplication -ApplicationId $existingApp.AppId -ErrorAction Stop
}
else {
    $app = New-AzADApplication -DisplayName $ServicePrincipalName -ErrorAction Stop
    Write-Host "✓ Application created: $($app.Id)" -ForegroundColor Green
    $appId = $app.Id
    Start-Sleep -Seconds 3 # Wait for replication
}

# Create service principal from application
$existingSp = Get-AzADServicePrincipal -ApplicationId $app.AppId -ErrorAction SilentlyContinue
if ($existingSp) {
    Write-Host "✓ Service principal already exists: $($existingSp.Id)" -ForegroundColor Green
    $spId = $existingSp.Id
}
else {
    $sp = New-AzADServicePrincipal -ApplicationId $app.AppId -ErrorAction Stop
    Write-Host "✓ Service principal created: $($sp.Id)" -ForegroundColor Green
    $spId = $sp.Id
    Start-Sleep -Seconds 5 # Wait for replication
}

# Step 5: Assign RBAC role to service principal
Write-Host "[5/5] Assigning RBAC role to service principal..." -ForegroundColor Yellow

# Check if role assignment already exists
$existingAssignment = Get-AzRoleAssignment -ObjectId $spId -RoleDefinitionId $customRoleId -Scope $dnsZone.Id -ErrorAction SilentlyContinue

if ($existingAssignment) {
    Write-Host "✓ Role assignment already exists" -ForegroundColor Green
}
else {
    $assignment = New-AzRoleAssignment -ObjectId $spId -RoleDefinitionId $customRoleId -Scope $dnsZone.Id -ErrorAction Stop
    Write-Host "✓ Role assigned to service principal" -ForegroundColor Green
}

# Optional: Generate client secret
$clientSecretInfo = $null
if ($GenerateClientSecret) {
    Write-Host ""
    Write-Host "Generating client secret..." -ForegroundColor Yellow
    
    $expirationDate = (Get-Date).AddMonths($AppPasswordExpirationMonths)
    $credentialParams = @{
        ApplicationId = $app.AppId
        EndDate       = $expirationDate
    }
    
    $secret = New-AzADAppCredential @credentialParams -ErrorAction Stop
    
    $clientSecretInfo = @{
        ClientId     = $app.AppId
        ClientSecret = $secret.SecretText
        TenantId     = $context.Tenant.Id
        ExpiresOn    = $expirationDate
    }
    
    Write-Host "✓ Client secret generated (expires: $expirationDate)" -ForegroundColor Green
}

# Output summary
Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Service Principal Setup Complete" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Service Principal Details:" -ForegroundColor Cyan
Write-Host "  Display Name:        $ServicePrincipalName"
Write-Host "  Service Principal ID: $spId"
Write-Host "  Application ID:      $($app.AppId)"
Write-Host "  Tenant ID:           $($context.Tenant.Id)"
Write-Host ""
Write-Host "Custom RBAC Role:" -ForegroundColor Cyan
Write-Host "  Role Name:           DNS Record Writer"
Write-Host "  Role ID:             $customRoleId"
Write-Host "  Scope:               $($dnsZone.Id)"
Write-Host "  Permissions:         Create/Update DNS records (no delete)"
Write-Host ""

if ($clientSecretInfo) {
    Write-Host "Client Secret (Save immediately — shown only once!):" -ForegroundColor Yellow
    Write-Host "  Client ID:     $($clientSecretInfo.ClientId)"
    Write-Host "  Client Secret: $($clientSecretInfo.ClientSecret)"
    Write-Host "  Expires:       $($clientSecretInfo.ExpiresOn)"
    Write-Host ""
    Write-Host "⚠ Save this secret in a secure location (Azure Key Vault, password manager, etc.)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Yellow
Write-Host "1. Store this service principal's credentials securely"
Write-Host "2. Use these credentials in DCV automation scripts"
Write-Host "3. For production, store credentials in Azure Key Vault"
Write-Host ""

# Output as JSON for programmatic use
$output = @{
    servicePrincipalId = $spId
    applicationId      = $app.AppId
    tenantId           = $context.Tenant.Id
    customRoleId       = $customRoleId
    dnsZoneScope       = $dnsZone.Id
    dnsZoneName        = $DnsZoneName
}

if ($clientSecretInfo) {
    $output.clientSecret = $clientSecretInfo.ClientSecret
    $output.secretExpiresOn = $clientSecretInfo.ExpiresOn
}

$jsonOutput = $output | ConvertTo-Json
Write-Host "JSON Output (for automation/CI-CD):" -ForegroundColor Cyan
Write-Host $jsonOutput
Write-Host ""
