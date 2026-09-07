# Mailbox Forwarding Tool — Design

Date: 2026-09-07

## Goal
Internal operator tool for tenant migrations. After mailboxes are migrated, operator must set mailbox forwarding in bulk to a fixed target domain, with occasional per-user prefix override.

## Stack
- Windows PowerShell 5.1, single script `MailboxForwardingTool.ps1`
- WinForms for GUI (no designer, built in code)
- ExchangeOnlineManagement module for all Exchange work

## Files
- `MailboxForwardingTool.ps1` — entry point, contains Config / EXO session / Cache / UI / Actions sections
- `config.json` — operator-editable settings; also editable via Settings dialog
- `cache.json` — mailbox enumeration cache with timestamp
- `changelog-yyyyMMdd-HHmmss.csv` — one file per apply-run, appended with per-mailbox result

## config.json
```json
{
  "ForwardingDomain": "target.example.com",
  "DeliverToMailboxAndForward": true,
  "ServiceAccountUPN": "svc@source.example.com",
  "CacheTtlHours": 24
}
```

## cache.json
```json
{
  "FetchedAt": "2026-09-07T12:34:56Z",
  "Mailboxes": [
    {
      "PrimarySmtpAddress": "alice@source.example.com",
      "ForwardingSmtpAddress": "alice@target.example.com",
      "DeliverToMailboxAndForward": true,
      "HasOnPremForwardingAddress": false
    }
  ]
}
```

## changelog CSV columns
`Timestamp, Mailbox, OldForwardingSmtpAddress, NewForwardingSmtpAddress, DeliverToMailboxAndForward, Result, Error`

## Operator flow
1. Launch script. If `config.json` missing/invalid → Settings dialog shown first, must be valid before continuing.
2. `Connect-ExchangeOnline -UserPrincipalName $cfg.ServiceAccountUPN` (interactive, MFA handled by module).
3. Mailbox list loaded:
   - If `cache.json` exists and younger than `CacheTtlHours` → use cache.
   - Else → `Get-EXOMailbox -ResultSize Unlimited -RecipientTypeDetails UserMailbox -Properties ForwardingSmtpAddress,DeliverToMailboxAndForward` → refresh cache.
   - Operator can force Refresh via button.
4. Main grid columns:
   - `PrimarySmtpAddress` (read-only)
   - `CurrentForwarding` (read-only, blank if none)
   - `HasOnPremForwarding` (read-only, yes/blank)
   - `DeliverAndStore` (checkbox, default = config value)
   - `ForwardingPrefix` (editable text, default = local part of primary SMTP)
   - `WillForwardTo` (read-only, computed `prefix@domain`, updates live as prefix edited)
5. Filter row above grid:
   - Search box, case-insensitive substring match on `PrimarySmtpAddress`
   - Radio: All / Has forward / No forward
6. Operator multi-selects rows → clicks **Preview**.
7. Preview dialog: one line per selected mailbox `mailbox : old-forward → new-forward (deliver-and-store=on|off)`. Overwrites shown in red.
8. **Apply** → per mailbox:
   - Skip if `HasOnPremForwardingAddress` — report as "manual review required".
   - `Set-Mailbox -Identity $mbx -ForwardingSmtpAddress $new -DeliverToMailboxAndForward $flag`
   - Capture per-mailbox success/error.
9. Result dialog: successes + failures. All rows appended to changelog CSV. Cache updated with new values.

## Error handling
- EXO connection failure → dialog with error, option to retry or exit.
- Per-mailbox `Set-Mailbox` failure → row logged, loop continues, failures summarized at end.
- Config load failure → Settings dialog with defaults, cannot proceed until valid.

## Safety
- Preview step is mandatory — Apply button only enabled from Preview dialog.
- Every apply-run writes a changelog CSV with old + new values.
- No auto-clear of existing forwards. Overwrite only after explicit preview + confirm.

## Out of scope
- Cross-platform support (Windows only).
- Clearing forwards in bulk (operator can set prefix blank? No — separate feature if needed later).
- Automated test project — manual verification against test tenant. Script has `-SelfTest` switch: validates config + EXO connectivity, touches no mailboxes.
