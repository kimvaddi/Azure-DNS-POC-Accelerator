#!/usr/bin/env pwsh
# ============================================================================
# Certificate Import & Web App Binding
# ============================================================================
# Imports a PFX/PKCS#12 certificate into Key Vault, then binds it to
# App Service custom domain hostnames with HTTPS/SSL.
#
# Prerequisites:
#   - Certificate file (PFX format)
#   - Key Vault already created
#   - Custom domain hostnames already bound to web app
#   - CNAME records pointing to azurewebsites.net created
#
# Usage:
#   .\Import-Certificate-and-Bind.ps1 `
#       -SubscriptionId "<sub-id>" `
#       -ResourceGroup "rg-dns-poc" `
#       -KeyVaultName "kv-dcv-poc" `
#       -CertificateFile "C:\certs\app.zava-dnspoc-001.com.pfx" `
#       -CertificatePassword "your-cert-password" `
#       -WebAppName "webapp-poc-us-xxxxx" `
#       -CustomDomain "app.zava-dnspoc-001.com"
# ============================================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$KeyVaultName,

    [Parameter(Mandatory = $true)]
    [string]$CertificateFile,

    [Parameter(Mandatory = $true, HelpMessage = "Certificate password (if encrypted)")]
    [securestring]$CertificatePassword,

    [Parameter(Mandatory = $false, HelpMessage = "Web app names to bind to (array)")]
    [string[]]$WebAppNames,

    [Parameter(Mandatory = $false, HelpMessage = "Custom domain names (array)")]
    [string[]]$CustomDomains,

    [Parameter(Mandatory = $false, HelpMessage = "Certificate name in Key Vault")]
    [string]$CertificateName = ([System.IO.Path]::GetFileNameWithoutExtension((Split-Path $CertificateFile -Leaf)))
)

$ErrorActionPreference = 'Stop'

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Certificate Import & Web App Binding" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

# Step 1: Authenticate
Write-Host "[1/4] Authenticating to Azure..." -ForegroundColor Yellow
$context = Get-AzContext
if (-not $context) {
    Connect-AzAccount -Subscription $SubscriptionId
    Set-AzContext -Subscription $SubscriptionId
}
else {
    Set-AzContext -Subscription $SubscriptionId
}
Write-Host "✓ Connected" -ForegroundColor Green

# Step 2: Validate certificate file
Write-Host "[2/4] Validating certificate file..." -ForegroundColor Yellow

if (-not (Test-Path $CertificateFile)) {
    throw "Certificate file not found: $CertificateFile"
}

$certPath = Resolve-Path $CertificateFile
Write-Host "✓ Certificate file found: $certPath" -ForegroundColor Green

# Load certificate to extract details
try {
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
    $cert.Import($certPath, $CertificatePassword, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
    
    $certSubject = $cert.Subject
    $certThumbprint = $cert.Thumbprint
    $certExpires = $cert.NotAfter
    
    Write-Host "  Subject:   $certSubject" -ForegroundColor Cyan
    Write-Host "  Thumbprint: $certThumbprint" -ForegroundColor Cyan
    Write-Host "  Expires:   $certExpires" -ForegroundColor Cyan
}
catch {
    throw "Failed to load certificate: $_"
}

# Step 3: Import certificate to Key Vault
Write-Host "[3/4] Importing certificate to Key Vault..." -ForegroundColor Yellow

$certBytes = [System.IO.File]::ReadAllBytes($certPath)
$certContent = [System.Convert]::ToBase64String($certBytes)

try {
    $keyVault = Get-AzKeyVault -ResourceGroupName $ResourceGroup -Name $KeyVaultName -ErrorAction Stop
    Write-Host "✓ Key Vault found: $($keyVault.VaultUri)" -ForegroundColor Green
    
    # Check if certificate already exists
    $existingCert = Get-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $CertificateName -ErrorAction SilentlyContinue
    
    if ($existingCert) {
        Write-Host "  Certificate already exists in Key Vault, updating..." -ForegroundColor Yellow
        $flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
        $certUpdate = Import-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $CertificateName -FilePath $certPath -Password $CertificatePassword -ErrorAction Stop
    }
    else {
        Write-Host "  Importing new certificate..." -ForegroundColor Cyan
        $certImport = Import-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $CertificateName -FilePath $certPath -Password $CertificatePassword -ErrorAction Stop
    }
    
    Write-Host "✓ Certificate imported to Key Vault: $CertificateName" -ForegroundColor Green
    
    # Get certificate details from Key Vault
    $kvCert = Get-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $CertificateName -ErrorAction Stop
    $certThumbprintKv = ($kvCert.Certificate.Thumbprint).ToLower()
}
catch {
    throw "Failed to import certificate to Key Vault: $_"
}

# Step 4: Bind certificate to web app custom domains
if ($WebAppNames -and $CustomDomains) {
    Write-Host "[4/4] Binding certificate to web app custom domains..." -ForegroundColor Yellow
    
    foreach ($webAppName in $WebAppNames) {
        Write-Host "  Processing web app: $webAppName" -ForegroundColor Cyan
        
        $webApp = Get-AzWebApp -ResourceGroupName $ResourceGroup -Name $webAppName -ErrorAction Stop
        
        foreach ($customDomain in $CustomDomains) {
            Write-Host "    Binding domain: $customDomain" -ForegroundColor Cyan
            
            try {
                # Create SSL binding
                $binding = New-AzWebAppSSLBinding `
                    -ResourceGroupName $ResourceGroup `
                    -WebAppName $webAppName `
                    -Name $customDomain `
                    -CertificateThumbprint $certThumbprintKv `
                    -SslState 'SniEnabled' `
                    -ErrorAction Stop
                
                Write-Host "    ✓ SSL binding created for $customDomain" -ForegroundColor Green
            }
            catch {
                # Check if binding already exists
                $existingBinding = Get-AzWebAppSSLBinding -ResourceGroupName $ResourceGroup -WebAppName $webAppName -Name $customDomain -ErrorAction SilentlyContinue
                
                if ($existingBinding) {
                    Write-Host "    ✓ SSL binding already exists for $customDomain" -ForegroundColor Green
                }
                else {
                    Write-Host "    ✗ Failed to create SSL binding: $_" -ForegroundColor Yellow
                }
            }
        }
    }
}
else {
    Write-Host "[4/4] Skipping web app binding (no web app or domain names provided)" -ForegroundColor Yellow
    Write-Host "  To bind manually, use:"
    Write-Host "    New-AzWebAppSSLBinding -ResourceGroupName '$ResourceGroup' -WebAppName '<webAppName>' -Name '<customDomain>' -CertificateThumbprint '$certThumbprintKv' -SslState 'SniEnabled'"
}

# Summary
Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Certificate Import Complete" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Certificate Details:" -ForegroundColor Cyan
Write-Host "  Name (Key Vault):  $CertificateName"
Write-Host "  Thumbprint:        $certThumbprintKv"
Write-Host "  Subject:           $certSubject"
Write-Host "  Valid Until:       $certExpires"
Write-Host ""

if ($WebAppNames -and $CustomDomains) {
    Write-Host "Bindings Created:" -ForegroundColor Cyan
    foreach ($webApp in $WebAppNames) {
        Write-Host "  Web App: $webApp"
        foreach ($domain in $CustomDomains) {
            Write-Host "    ✓ $domain (HTTPS/SNI enabled)"
        }
    }
}

Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Yellow
Write-Host "1. Test HTTPS connection: https://$($CustomDomains[0])"
Write-Host "2. Verify certificate in browser (should show valid)"
Write-Host "3. Check Azure App Service Custom domains blade for binding status"
Write-Host "4. Monitor certificate expiration (consider auto-renewal)"
Write-Host ""
