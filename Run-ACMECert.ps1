param(
    [string]$LogFile = "$env:TEMP\posh-acme-run.log"
)

Start-Transcript -Path $LogFile -Force

$ErrorActionPreference = 'Stop'

try {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Loading Posh-ACME..."
    Import-Module Posh-ACME -Force

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Setting PA server to LE_PROD..."
    Set-PAServer LE_PROD

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Loading PA account 3193955291..."
    Set-PAAccount 3193955291

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Getting ARM access token..."
    $token = (az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
    if (-not $token -or $token.Length -lt 50) { throw "Failed to get ARM access token" }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Token length: $($token.Length)"

    # Azure plugin 'Token' parameter set: AZSubscriptionId + AZAccessToken (plain string)
    # No AZTenantId required for token-based auth
    $pluginArgs = @{
        AZSubscriptionId = '43d55e51-58fe-486f-9e2a-ba56b8dd15de'
        AZAccessToken    = $token
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Calling New-PACertificate for *.zava-dnspoc-001.com (plugin: Azure)..."
    $cert = New-PACertificate -Domain '*.zava-dnspoc-001.com' -Plugin Azure -PluginArgs $pluginArgs -Verbose

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] === CERTIFICATE ISSUED ==="
    $cert | Format-List

    $pfxPath = $cert.PfxFile
    Write-Host "PFX_PATH=$pfxPath"
    Write-Host "THUMBPRINT=$($cert.Thumbprint)"
    Write-Host "EXPIRY=$($cert.NotAfter)"

} catch {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] === ERROR ==="
    Write-Host $_.Exception.Message
    Write-Host $_.ScriptStackTrace
    Write-Host "Inner: $($_.Exception.InnerException)"
} finally {
    Stop-Transcript
}
