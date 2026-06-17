# Setup Checklist (Org Users)

## Entra app registration

Use the shared single-tenant app registration and confirm:

- Redirect URI: `http://localhost`
- Public client flows: enabled
- Delegated permissions: `Mail.ReadWrite`, `offline_access`
- Consent: granted for users who will run the tool

## Local setup

1. Download/clone this repo.
2. Open PowerShell in the repo root.
3. Edit `scripts/sample-assignments.csv`.
4. Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\invoke-category-batch.ps1 `
  -TenantIdOrDomain "<tenant-id-or-domain>" `
  -AssignmentsCsvPath .\scripts\sample-assignments.csv `
  -Verify
```

## Operational behavior

- Messages stay in Inbox.
- Existing categories are preserved.
- Re-runs are safe (already-matching messages are skipped).
