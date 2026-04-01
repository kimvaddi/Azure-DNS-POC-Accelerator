# Zava DNSSEC Demo Process

This document captures the DNSSEC demo flow for the current Azure DNS deployment, where the parent public zone is `zava-dnspoc-001.com` and the delegated child zone is `demo.zava-dnspoc-001.com`.

## Goal

Demonstrate a signed delegated subdomain in Azure DNS by ensuring:

- The parent zone `zava-dnspoc-001.com` exists and is DNSSEC-enabled.
- The child zone `demo.zava-dnspoc-001.com` exists and is delegated from the parent zone.
- The child zone is DNSSEC-enabled.
- The parent zone publishes a DS record for `demo` using the child zone's KSK digest.
- The child zone exposes a demo host record: `test.demo.zava-dnspoc-001.com -> 1.1.1.1`.

## Current Azure Layout

- Parent zone: `zava-dnspoc-001.com`
- Child zone: `demo.zava-dnspoc-001.com`
- Delegation record in parent: `demo NS ...`
- DS record in parent: `demo DS ...`
- Demo record in child: `test A 1.1.1.1`

## DNSSEC Flow

1. Discover the deployed parent zone.
2. Create `demo.<parent-zone>` if it does not already exist.
3. Read the Azure-assigned child zone name servers.
4. Create or refresh the parent `demo` NS delegation so it points at the child zone name servers.
5. Create or refresh the child `test` A record so the demo subdomain has a visible workload target.
6. Enable DNSSEC on the parent zone if it is not already enabled.
7. Enable DNSSEC on the child zone if it is not already enabled.
8. Read the child zone KSK delegation signer information.
9. Create or refresh the parent `demo` DS record using the child zone digest.
10. Verify NS delegation, DS publication, and child record resolution.

## Automation Script

Use [Setup-DNSSEC-Demo.ps1](c:/Users/dmauser/OneDrive%20-%20Microsoft/Documents/GitHub/Azure-DNS-POC-Accelerator/Setup-DNSSEC-Demo.ps1) to apply the demo end to end.

The script uses `infrastructure/deployment-output.json` as the domain source of truth.

- Reads `infrastructure/deployment-output.json` to discover the deployed zone.
- Validates that the discovered zone still exists in Azure DNS.
- If the file is missing or stale, the script exits and tells you to refresh `deployment-output.json` by running the initial deployment script.

Example:

```powershell
.\Setup-DNSSEC-Demo.ps1
```

Domain customization (for root domain or subdomain such as `contoso.com` or `subdomain.contoso.com`) is handled during the initial Bicep deployment in [infrastructure/deploy.ps1](c:/Users/dmauser/OneDrive%20-%20Microsoft/Documents/GitHub/Azure-DNS-POC-Accelerator/infrastructure/deploy.ps1), not in this DNSSEC script.

## Manual Verification

Run these commands after the script completes:

```powershell
az network dns record-set ns show -g rg-dns-poc -z zava-dnspoc-001.com -n demo -o json
az network dns record-set ds show -g rg-dns-poc -z zava-dnspoc-001.com -n demo -o json
az network dns dnssec-config show -g rg-dns-poc -z demo.zava-dnspoc-001.com -o json
Resolve-DnsName -Name test.demo.zava-dnspoc-001.com -Type A
```

If `dig` is available, you can also inspect DNSSEC material directly:

```bash
dig +dnssec demo.zava-dnspoc-001.com NS
dig +dnssec demo.zava-dnspoc-001.com DS
dig +dnssec test.demo.zava-dnspoc-001.com A
```

## Notes

- The Azure CLI DNSSEC and DS commands are still marked experimental, so the script uses `--only-show-errors` to keep output clean.
- The script is intentionally idempotent for demo use. It recreates the delegation NS set, the `test` A record, and the parent DS record so the `demo` chain always matches the current child zone signing keys.
- This workflow signs a delegated child zone inside Azure DNS. It does not depend on an external registrar because the parent zone is also hosted in Azure DNS.
