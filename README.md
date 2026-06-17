# Scout Email Categorizer Toolkit

Toolkit for Microsoft Scout users to apply Outlook categories to Inbox messages via Microsoft Graph, without moving mail out of Inbox.

## What is included

- `scripts/set-email-category.ps1` - core Graph helper (single-tenant, delegated auth, token cache + refresh, idempotent category updates)
- `scripts/invoke-category-batch.ps1` - batch wrapper that applies categories from CSV, grouped by category
- `scripts/sample-assignments.csv` - example batch input format

## Prerequisites

1. An Entra app registration with:
   - **Application type:** single-tenant
   - **Redirect URI:** `http://localhost`
   - **Public client flows:** enabled
   - **Delegated permissions:** `Mail.ReadWrite`, `offline_access`
2. User has consent (or tenant admin consent configured).
3. PowerShell execution policy allows script execution in your user scope.

## Quick start

1. Edit `scripts/sample-assignments.csv` with target message IDs and categories.
2. Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\invoke-category-batch.ps1 `
  -TenantIdOrDomain "<tenant-id-or-domain>" `
  -AssignmentsCsvPath .\scripts\sample-assignments.csv `
  -Verify
```

## Notes

- First run is interactive sign-in.
- Later runs reuse `scripts\graph-token-cache.json` and usually run without prompts.
- Reauth can still occur due to tenant policy/MFA/refresh-token expiry.
- Category writes are idempotent: reruns skip messages that already have the target category, and preserve existing categories.

## Sharing inside your org

1. Create a new repo in `InterlinkCloudAdvisors` (for example: `scout-email-categorizer-toolkit`).
2. Upload all files from this folder.
3. Teammates clone/download and run the same quick-start command.
