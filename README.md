# Mailbox Forwarding Tool

Bulk-set mailbox forwarding in Exchange Online during tenant migrations.

## Prereqs
- Windows PowerShell 5.1
- `Install-Module ExchangeOnlineManagement -Scope CurrentUser`
- Service account with Exchange Admin (or Global Admin) role

## Setup
1. Copy `config.example.json` → `config.json` and edit, or run the tool and use the Settings dialog.
2. Run `.\MailboxForwardingTool.ps1`.

## Use
- Grid lists all user mailboxes (cached; Refresh button re-fetches).
- Search box + Has forward / No forward filters narrow the list.
- Prefix column defaults to mailbox local part; edit for exceptions.
- Select rows → Preview → Apply. Changelog CSV written per run.

## Self-test
`.\MailboxForwardingTool.ps1 -SelfTest` — validates config + EXO connectivity, touches no mailboxes.

## Notes
- Mailboxes with on-prem `ForwardingAddress` set are skipped and flagged.
- Existing forwards are overwritten only after Preview confirmation.
