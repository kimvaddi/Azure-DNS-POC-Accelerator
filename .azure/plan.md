# Azure Deployment Plan

Status: Approved

Scope: Extend the existing Azure DNS POC deployment with a public DNS monitoring workbook that highlights who changed the zone and record sets, exposes public Azure DNS metrics from Azure Monitor, and returns a direct workbook portal URL from deployment outputs.

Decisions:
- Keep change tracking on Azure Activity Log data already routed to Log Analytics.
- Render Azure DNS metrics with workbook-native metric controls because public DNS zones do not support diagnostic settings export.
- Scope the workbook to the public DNS zone only.
- Deploy the workbook as a shared Azure Monitor workbook associated to the public DNS zone resource.

Execution Steps:
1. Add a resource-group-scoped observability module for the public DNS zone.
2. Add the workbook JSON payload and deploy it through Bicep.
3. Expose workbook ID, name, and direct portal URL from the root template.
4. Add deeper record-set change drilldowns in the workbook.
5. Validate the updated template.
6. Deploy the workbook changes into the current Azure environment.