#!/usr/bin/env pwsh

param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$DnsZoneName,

    [Parameter(Mandatory = $true)]
    [string]$KeyVaultName,

    [Parameter(Mandatory = $true)]
    [string[]]$WebAppNames,

    [Parameter(Mandatory = $true)]
    [string[]]$CustomDomains,

    [Parameter(Mandatory = $false)]
    [string]$CertificateName = 'le-wildcard-zava',

    [Parameter(Mandatory = $false)]
    [string]$ContactEmail = '',

    [Parameter(Mandatory = $false)]
    [string]$Location = '',

    [Parameter(Mandatory = $false)]
    [switch]$RemoveManagedCertificates = $true
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$WebAppNames = @($WebAppNames | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$CustomDomains = @($CustomDomains | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

function Write-Step {
    param([string]$Message)
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "OK $Message" -ForegroundColor Green
}

function Write-WarningMessage {
    param([string]$Message)
    Write-Host "WARN $Message" -ForegroundColor Yellow
}

function Ensure-Module {
    param([string]$Name)

    if (-not (Get-Module -ListAvailable -Name $Name)) {
        Install-Module -Name $Name -Scope CurrentUser -Force -AllowClobber
    }

    Import-Module $Name -Force
}

function Ensure-AzureCliLogin {
    param([string]$TargetSubscriptionId)

    az account show --output none 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'Azure CLI is not authenticated. Run az login first.'
    }

    az account set --subscription $TargetSubscriptionId | Out-Null
}

function Ensure-KeyVault {
    param(
        [string]$TargetResourceGroup,
        [string]$TargetKeyVaultName,
        [string]$TargetLocation
    )

    $existingKeyVaultId = az keyvault show -g $TargetResourceGroup -n $TargetKeyVaultName --query id -o tsv 2>$null
    if ($existingKeyVaultId) {
        return $existingKeyVaultId
    }

    # Check for soft-deleted vault. When purge protection is enabled we cannot
    # purge, but we can recover the vault back to the (already recreated) RG.
    $deletedVault = az keyvault list-deleted --query "[?name=='$TargetKeyVaultName'] | [0]" -o json 2>$null | ConvertFrom-Json
    if ($deletedVault) {
        Write-WarningMessage "Key Vault '$TargetKeyVaultName' is in soft-deleted state. Recovering..."
        az keyvault recover --name $TargetKeyVaultName --only-show-errors -o none | Out-Null
        Start-Sleep -Seconds 15
        # Ensure RBAC authorization is enabled after recovery
        az keyvault update -g $TargetResourceGroup -n $TargetKeyVaultName --enable-rbac-authorization true --only-show-errors -o none | Out-Null
        return az keyvault show -g $TargetResourceGroup -n $TargetKeyVaultName --query id -o tsv
    }

    if (-not $TargetLocation) {
        $TargetLocation = az group show -n $TargetResourceGroup --query location -o tsv
    }

    az keyvault create --resource-group $TargetResourceGroup --name $TargetKeyVaultName --location $TargetLocation --enable-rbac-authorization true --retention-days 7 --only-show-errors -o none | Out-Null
    return az keyvault show -g $TargetResourceGroup -n $TargetKeyVaultName --query id -o tsv
}

function Ensure-KeyVaultRoleAssignment {
    param(
        [string]$Scope,
        [string]$PrincipalId,
        [string]$RoleName
    )

    $assignmentId = az role assignment list --scope $Scope --assignee-object-id $PrincipalId --query "[?roleDefinitionName=='$RoleName'] | [0].id" -o tsv 2>$null
    if ($assignmentId) {
        return
    }

    az role assignment create --scope $Scope --assignee-object-id $PrincipalId --assignee-principal-type User --role $RoleName --only-show-errors -o none | Out-Null
}

function Ensure-KeyVaultRoleAssignmentSP {
    param(
        [string]$Scope,
        [string]$PrincipalId,
        [string]$RoleName
    )

    $assignmentId = az role assignment list --scope $Scope --assignee-object-id $PrincipalId --query "[?roleDefinitionName=='$RoleName'] | [0].id" -o tsv 2>$null
    if ($assignmentId) {
        return
    }

    az role assignment create --scope $Scope --assignee-object-id $PrincipalId --assignee-principal-type ServicePrincipal --role $RoleName --only-show-errors -o none | Out-Null
}

function Remove-DnsZoneLock {
    param(
        [string]$TargetResourceGroup,
        [string]$TargetDnsZoneName
    )

    $lock = az lock list -g $TargetResourceGroup --query "[?name=='lock-dns-zone'] | [0]" -o json | ConvertFrom-Json
    if (-not $lock) {
        return $false
    }

    az lock delete -g $TargetResourceGroup -n lock-dns-zone --resource-name $TargetDnsZoneName --resource-type Microsoft.Network/dnsZones --only-show-errors | Out-Null
    return $true
}

function Restore-DnsZoneLock {
    param(
        [string]$TargetResourceGroup,
        [string]$TargetDnsZoneName
    )

    az lock create -g $TargetResourceGroup -n lock-dns-zone --lock-type CanNotDelete --resource-name $TargetDnsZoneName --resource-type Microsoft.Network/dnsZones --notes "Prevent accidental deletion of POC DNS zone" --only-show-errors -o none | Out-Null
}

if (-not $ContactEmail) {
    $ContactEmail = "dnsadmin@$DnsZoneName"
}

Write-Step "Preparing Local Let's Encrypt TLS Automation"

Ensure-AzureCliLogin -TargetSubscriptionId $SubscriptionId
Ensure-Module -Name Posh-ACME

$keyVaultId = Ensure-KeyVault -TargetResourceGroup $ResourceGroup -TargetKeyVaultName $KeyVaultName -TargetLocation $Location
$principalId = az ad signed-in-user show --query id -o tsv
if (-not $principalId) {
    throw 'Unable to resolve the current signed-in user object ID for Key Vault RBAC assignment.'
}

Ensure-KeyVaultRoleAssignment -Scope $keyVaultId -PrincipalId $principalId -RoleName 'Key Vault Certificates Officer'
Ensure-KeyVaultRoleAssignment -Scope $keyVaultId -PrincipalId $principalId -RoleName 'Key Vault Secrets Officer'

# Grant Key Vault Secrets User to the App Service resource provider SP so it can
# pull certificates from Key Vault when binding them to web apps.
# App Service RP first-party app ID is the same in all public Azure tenants.
$appServiceRpAppId = 'abfa0a7c-a6b6-4736-8310-5855508787cd'
$appServiceRpObjectId = az ad sp show --id $appServiceRpAppId --query id -o tsv 2>$null
if ($appServiceRpObjectId) {
    Ensure-KeyVaultRoleAssignmentSP -Scope $keyVaultId -PrincipalId $appServiceRpObjectId -RoleName 'Key Vault Secrets User'
}

Start-Sleep -Seconds 20

$lockRemoved = $false

try {
    $thumbprint = az keyvault certificate show --vault-name $KeyVaultName --name $CertificateName --query x509ThumbprintHex -o tsv 2>$null

    if (-not $thumbprint) {
        Write-Step "Issuing Let's Encrypt Wildcard Certificate"
        $lockRemoved = Remove-DnsZoneLock -TargetResourceGroup $ResourceGroup -TargetDnsZoneName $DnsZoneName
        if ($lockRemoved) {
            Write-WarningMessage 'Temporarily removed DNS zone lock to allow ACME TXT create and cleanup.'
        }

        Set-PAServer LE_PROD
        $existingAccount = Get-PAAccount -ErrorAction SilentlyContinue
        if (-not $existingAccount) {
            New-PAAccount -Contact $ContactEmail -AcceptTOS | Out-Null
        }

        $armToken = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
        if (-not $armToken) {
            throw 'Unable to acquire ARM token for Posh-ACME Azure plugin.'
        }

        $pluginArgs = @{
            AZSubscriptionId = $SubscriptionId
            AZAccessToken    = $armToken
        }

        $issuedCertificate = $null
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            try {
                $issuedCertificate = New-PACertificate -Domain "*.$DnsZoneName" -Plugin Azure -PluginArgs $pluginArgs -ErrorAction Stop
                break
            }
            catch {
                if ($attempt -eq 5) {
                    throw
                }

                Start-Sleep -Seconds 30
            }
        }

        if (-not $issuedCertificate -or -not $issuedCertificate.PfxFile) {
            throw 'Let''s Encrypt certificate issuance did not produce a PFX file.'
        }

        $plainPfxPassword = if ($issuedCertificate.PfxPass -is [securestring]) {
            [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($issuedCertificate.PfxPass))
        }
        else {
            [string]$issuedCertificate.PfxPass
        }

        Write-Success "Issued wildcard certificate for *.$DnsZoneName"

        Write-Step "Importing Certificate Into Key Vault"
        az keyvault certificate import --vault-name $KeyVaultName --name $CertificateName --file $issuedCertificate.PfxFile --password $plainPfxPassword --only-show-errors -o none | Out-Null
        $thumbprint = az keyvault certificate show --vault-name $KeyVaultName --name $CertificateName --query x509ThumbprintHex -o tsv
        if (-not $thumbprint) {
            throw 'Unable to determine thumbprint from Key Vault certificate.'
        }
        Write-Success "Imported certificate '$CertificateName' into Key Vault '$KeyVaultName'"
    }
    else {
        Write-Success "Reusing existing Key Vault certificate '$CertificateName'"
    }

    Write-Step "Importing Certificate Into App Services And Binding TLS"
    foreach ($app in $WebAppNames) {
        $appCertificateName = "$CertificateName-$app"
        $importOutput = az webapp config ssl import --resource-group $ResourceGroup --name $app --key-vault $KeyVaultName --key-vault-certificate-name $CertificateName --certificate-name $appCertificateName --only-show-errors -o none 2>&1
        if ($LASTEXITCODE -ne 0) {
            if ($importOutput -match 'Another certificate exists with the same key vault Id and secret name') {
                Write-Success "Key Vault certificate already imported into the webspace for '$app'"
            }
            else {
                throw $importOutput
            }
        }
        else {
            Write-Success "Imported Key Vault certificate into the webspace for '$app' as '$appCertificateName'"
        }

        foreach ($domain in $CustomDomains) {
            az webapp config ssl bind --resource-group $ResourceGroup --name $app --certificate-thumbprint $thumbprint --ssl-type SNI --hostname $domain --only-show-errors -o none | Out-Null
            Write-Success "Bound SNI TLS for '$domain' on '$app'"
        }
    }

    if ($RemoveManagedCertificates) {
        Write-Step "Removing App Service Managed Certificates"
        foreach ($domain in $CustomDomains) {
            $managedCertId = az resource show -g $ResourceGroup -n $domain --resource-type Microsoft.Web/certificates --query id -o tsv 2>$null
            if ($managedCertId) {
                az resource delete --ids $managedCertId --only-show-errors | Out-Null
                Write-Success "Removed managed certificate resource '$domain'"
            }
        }
    }

    Write-Step "Let's Encrypt TLS Automation Complete"
    Write-Success "Key Vault: $KeyVaultName"
    Write-Success "Certificate Name: $CertificateName"
    Write-Success "Thumbprint: $thumbprint"
}
finally {
    if ($lockRemoved) {
        Restore-DnsZoneLock -TargetResourceGroup $ResourceGroup -TargetDnsZoneName $DnsZoneName
        Write-Success 'Restored DNS zone delete lock.'
    }
}
