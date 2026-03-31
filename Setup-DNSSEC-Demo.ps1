[CmdletBinding()]
param(
    [string]$ResourceGroup = 'rg-dns-poc',
    [string]$DeploymentOutputPath = (Join-Path $PSScriptRoot 'infrastructure\deployment-output.json'),
    [string]$ChildLabel = 'demo',
    [string]$DemoRecordName = 'test',
    [string]$DemoIpAddress = '1.1.1.1',
    [int]$DelegationTtl = 3600,
    [int]$RecordTtl = 3600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Text)
    Write-Host "`n=== $Text ===" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Text)
    Write-Host "[OK] $Text" -ForegroundColor Green
}

function Write-WarnLine {
    param([string]$Text)
    Write-Host "[WARN] $Text" -ForegroundColor Yellow
}

function ConvertFrom-JsonLoose {
    param([string]$RawText)

    if (-not $RawText) {
        return $null
    }

    $trimmed = $RawText.Trim()
    if (-not $trimmed) {
        return $null
    }

    $firstBrace = $trimmed.IndexOf('{')
    if ($firstBrace -lt 0) {
        return $null
    }

    $jsonCandidate = $trimmed.Substring($firstBrace)
    try {
        return $jsonCandidate | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }
}

function Resolve-DomainFromObject {
    param([object]$Object)

    if (-not $Object) {
        return $null
    }

    $candidate = $null
    try { $candidate = $Object.publicDnsZoneName.value } catch {}
    if (-not $candidate) {
        try { $candidate = $Object.publicDnsZoneName } catch {}
    }
    if (-not $candidate) {
        try { $candidate = $Object.properties.outputs.publicDnsZoneName.value } catch {}
    }

    return $candidate
}

function Test-DnsZoneExists {
    param([string]$ZoneName)

    if (-not $ZoneName) {
        return $false
    }

    az network dns zone show --resource-group $ResourceGroup --name $ZoneName --only-show-errors -o none 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Get-LiveParentZoneCandidates {
    $raw = az network dns zone list --resource-group $ResourceGroup --query "[].name" --only-show-errors -o json
    $zones = $raw | ConvertFrom-Json
    if (-not $zones) {
        return @()
    }

    $zones = @($zones)
    return $zones |
        Where-Object { $_ -and ($_ -notlike "$ChildLabel.*") } |
        Sort-Object @{ Expression = { ($_.ToString().Split('.')).Count } }, @{ Expression = { $_.ToString().Length } }
}

function Get-DeployedParentZone {
    if (-not (Test-Path $DeploymentOutputPath)) {
        throw "deployment-output.json not found at '$DeploymentOutputPath'. Run infrastructure/deploy.ps1 first."
    }

    $raw = Get-Content -Raw -Path $DeploymentOutputPath
    $data = ConvertFrom-JsonLoose -RawText $raw
    $candidate = Resolve-DomainFromObject -Object $data
    if (-not $candidate) {
        throw "Could not resolve publicDnsZoneName from '$DeploymentOutputPath'."
    }

    if (-not (Test-DnsZoneExists -ZoneName $candidate)) {
        throw "Domain '$candidate' from deployment-output.json was not found in resource group '$ResourceGroup'. Refresh deployment-output.json by re-running infrastructure/deploy.ps1."
    }

    Write-Ok "Parent zone discovered from deployment-output.json: $candidate"
    return $candidate
}

function Ensure-Zone {
    param([string]$ZoneName)

    if (Test-DnsZoneExists -ZoneName $ZoneName) {
        Write-Ok "Zone exists: $ZoneName"
        return
    }

    az network dns zone create --resource-group $ResourceGroup --name $ZoneName --only-show-errors -o none | Out-Null
    Write-Ok "Zone created: $ZoneName"
}

function Get-ZoneNameServers {
    param([string]$ZoneName)

    $raw = az network dns zone show --resource-group $ResourceGroup --name $ZoneName --query nameServers --only-show-errors -o json
    return @($raw | ConvertFrom-Json)
}

function Reset-DelegationNsRecord {
    param(
        [string]$ParentZone,
        [string]$ChildZone,
        [string[]]$NameServers
    )

    az network dns record-set ns delete --resource-group $ResourceGroup --zone-name $ParentZone --name $ChildLabel --yes --only-show-errors -o none 2>$null | Out-Null
    az network dns record-set ns create --resource-group $ResourceGroup --zone-name $ParentZone --name $ChildLabel --ttl $DelegationTtl --only-show-errors -o none | Out-Null
    foreach ($nameServer in $NameServers) {
        az network dns record-set ns add-record --resource-group $ResourceGroup --zone-name $ParentZone --record-set-name $ChildLabel --nsdname $nameServer --only-show-errors -o none | Out-Null
    }

    Write-Ok "Delegation NS record reset for $ChildZone in parent zone $ParentZone"
}

function Reset-DemoARecord {
    param([string]$ChildZone)

    az network dns record-set a delete --resource-group $ResourceGroup --zone-name $ChildZone --name $DemoRecordName --yes --only-show-errors -o none 2>$null | Out-Null
    az network dns record-set a create --resource-group $ResourceGroup --zone-name $ChildZone --name $DemoRecordName --ttl $RecordTtl --only-show-errors -o none | Out-Null
    az network dns record-set a add-record --resource-group $ResourceGroup --zone-name $ChildZone --record-set-name $DemoRecordName --ipv4-address $DemoIpAddress --only-show-errors -o none | Out-Null

    Write-Ok "A record ensured: $DemoRecordName.$ChildZone -> $DemoIpAddress"
}

function Ensure-DnssecEnabled {
    param([string]$ZoneName)

    az network dns dnssec-config show --resource-group $ResourceGroup --zone-name $ZoneName --only-show-errors -o none 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "DNSSEC already enabled on $ZoneName"
        return
    }

    az network dns dnssec-config create --resource-group $ResourceGroup --zone-name $ZoneName --only-show-errors -o none | Out-Null
    Write-Ok "DNSSEC enabled on $ZoneName"
}

function Get-ChildDelegationSigner {
    param([string]$ChildZone)

    $raw = az network dns dnssec-config show --resource-group $ResourceGroup --zone-name $ChildZone --only-show-errors -o json
    $config = $raw | ConvertFrom-Json

    foreach ($key in @($config.signingKeys)) {
        if ($key.flags -eq 257 -and $key.delegationSignerInfo -and $key.delegationSignerInfo.Count -gt 0) {
            $ds = $key.delegationSignerInfo[0]
            return [pscustomobject]@{
                KeyTag = $key.keyTag
                Algorithm = $key.securityAlgorithmType
                DigestType = $ds.digestAlgorithmType
                Digest = $ds.digestValue
                Record = $ds.record
            }
        }
    }

    throw "Unable to find a delegation signer record for child zone '$ChildZone'."
}

function Reset-ParentDsRecord {
    param(
        [string]$ParentZone,
        [pscustomobject]$DelegationSigner
    )

    az network dns record-set ds delete --resource-group $ResourceGroup --zone-name $ParentZone --name $ChildLabel --yes --only-show-errors -o none 2>$null | Out-Null
    az network dns record-set ds add-record --resource-group $ResourceGroup --zone-name $ParentZone --record-set-name $ChildLabel --ttl $DelegationTtl --key-tag $DelegationSigner.KeyTag --algorithm $DelegationSigner.Algorithm --digest-type $DelegationSigner.DigestType --digest $DelegationSigner.Digest --only-show-errors -o none | Out-Null

    Write-Ok "DS record reset for $ChildLabel.$ParentZone using child zone KSK digest"
}

function Show-VerificationSummary {
    param(
        [string]$ParentZone,
        [string]$ChildZone,
        [string[]]$NameServers,
        [pscustomobject]$DelegationSigner
    )

    Write-Step 'Verification Summary'
    Write-Host "Parent zone : $ParentZone"
    Write-Host "Child zone  : $ChildZone"
    Write-Host "Demo record : $DemoRecordName.$ChildZone -> $DemoIpAddress"
    Write-Host "Name servers:"
    foreach ($nameServer in $NameServers) {
        Write-Host "  - $nameServer"
    }
    Write-Host "DS record   : $($DelegationSigner.Record)"
    Write-Host ''
    Write-Host 'Verification commands:' -ForegroundColor White
    Write-Host "  az network dns record-set ns show -g $ResourceGroup -z $ParentZone -n $ChildLabel -o json"
    Write-Host "  az network dns record-set ds show -g $ResourceGroup -z $ParentZone -n $ChildLabel -o json"
    Write-Host "  az network dns dnssec-config show -g $ResourceGroup -z $ChildZone -o json"
    Write-Host "  Resolve-DnsName -Name $DemoRecordName.$ChildZone -Type A"
}

Write-Step 'Validating Azure Context'
az account show --only-show-errors -o none | Out-Null
Write-Ok 'Azure CLI context is available.'

$parentZone = Get-DeployedParentZone
$childZone = "$ChildLabel.$parentZone"

Write-Step 'Ensuring Parent And Child Zones'
Ensure-Zone -ZoneName $parentZone
Ensure-Zone -ZoneName $childZone

$childNameServers = Get-ZoneNameServers -ZoneName $childZone
if (-not $childNameServers -or $childNameServers.Count -eq 0) {
    throw "Child zone '$childZone' did not return any Azure DNS name servers."
}

Write-Step 'Ensuring Delegation And Demo Record'
Reset-DelegationNsRecord -ParentZone $parentZone -ChildZone $childZone -NameServers $childNameServers
Reset-DemoARecord -ChildZone $childZone

Write-Step 'Ensuring DNSSEC'
Ensure-DnssecEnabled -ZoneName $parentZone
Ensure-DnssecEnabled -ZoneName $childZone

$delegationSigner = Get-ChildDelegationSigner -ChildZone $childZone
Reset-ParentDsRecord -ParentZone $parentZone -DelegationSigner $delegationSigner

Show-VerificationSummary -ParentZone $parentZone -ChildZone $childZone -NameServers $childNameServers -DelegationSigner $delegationSigner