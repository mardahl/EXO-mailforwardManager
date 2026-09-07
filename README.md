# EXO Mailbox Forward Manager

[![CI](https://github.com/mardahl/EXO-mailforwardManager/actions/workflows/ci.yml/badge.svg)](https://github.com/mardahl/EXO-mailforwardManager/actions/workflows/ci.yml)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](#requirements)
[![Platform](https://img.shields.io/badge/platform-Windows-555)](#requirements)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)
[![Downloads](https://img.shields.io/github/downloads/mardahl/EXO-mailforwardManager/total)](https://github.com/mardahl/EXO-mailforwardManager/releases)
![Visitors](https://hits.sh/github.com/mardahl/EXO-mailforwardManager.svg)

A single-file PowerShell **WinForms GUI** for bulk-setting mailbox forwarding in **Exchange Online** during tenant migrations - fixed target domain, per-user prefix override, deliver-and-store toggle, preview-before-apply, and a CSV audit trail for every run.

## TL;DR

Copy `config.example.json` to `config.json` and fill in the target domain and service-account UPN, then run:

```powershell
.\MailboxForwardingTool.ps1
```

The tool lists every user mailbox (cached locally), lets you filter and multi-select, edit the forwarding prefix per row, then **Preview → Apply**. A timestamped changelog CSV is written per apply-run.

```
 Mailbox Forwarding Tool
 [search___________________]  (•) All  ( ) Has forward  ( ) No forward      [Refresh] [Settings]
 ┌──────────────────────────┬──────────────────────────┬─────────┬────────────┬────────────┬──────────────────────────┐
 │ Mailbox                  │ Current forward          │ On-prem?│Deliver+Store│ Prefix    │ Will forward to          │
 ├──────────────────────────┼──────────────────────────┼─────────┼────────────┼────────────┼──────────────────────────┤
 │ alice@source.example.com │                          │         │ [x]        │ alice      │ alice@target.example.com │
 │ bob@source.example.com   │ bob@target.example.com   │         │ [x]        │ bob        │ bob@target.example.com   │
 │ carol@source.example.com │                          │  yes    │ [x]        │ carol      │ carol@target.example.com │
 └──────────────────────────┴──────────────────────────┴─────────┴────────────┴────────────┴──────────────────────────┘
                                                                                                  [Preview →]
```

---

- [TL;DR](#tldr)
- [Why](#why)
- [Features](#features)
- [Quick start](#quick-start)
- [Requirements](#requirements)
- [Files the tool writes](#files-the-tool-writes)
- [Caveats](#caveats)
- [Contributing](#contributing) · [Security](#security) · [Changelog](CHANGELOG.md)

## Why

Tenant-to-tenant mailbox migrations end with the same tedious step: setting a forwarding rule on each source mailbox so mail keeps flowing to the new tenant while DNS and clients catch up. Doing this one-by-one in the Exchange admin center is slow and error-prone; doing it with a raw CSV-driven script means the operator maintains yet another file outside the tool.

This tool puts a GUI over `Set-Mailbox -ForwardingSmtpAddress`: the mailbox list is fetched and cached inside the tool, the forwarding prefix defaults to each mailbox's existing local-part (the common case), and the rare exception is edited in-place in the grid. The operator sees existing forwards before overwriting them, previews every change, and gets an audit CSV per run.

| Action | Handled | Not handled |
|---|---|---|
| Set `ForwardingSmtpAddress` to `prefix@<target-domain>` | Any user mailbox, bulk | - |
| Per-row prefix override | Editable Prefix column | - |
| Deliver-to-mailbox-and-forward | On by default, per-row checkbox | - |
| Mailboxes with on-prem `ForwardingAddress` set | Flagged `yes`, skipped on Apply | Migrating on-prem forwarding to cloud - do by hand |
| Existing forward present | Shown, overwrite confirmed in Preview (red) | Silently clearing forwards - not supported |

## Features

- **Single `.ps1` file** - no modules, no build step; only dependency is `ExchangeOnlineManagement`
- **PowerShell 5.1** on Windows (works on pwsh 7 too, but the GUI requires Windows)
- **WinForms grid UI** with live search, Has forward / No forward filter, multi-select
- **Mailbox enumeration cached locally** with configurable TTL - no full tenant re-enumeration per launch
- **Editable Prefix column**, defaults to the mailbox's primary SMTP local part; `Will forward to` column recomputes live
- **Preview dialog** showing old → new forward per mailbox; overwrites highlighted red, on-prem-forward mailboxes flagged orange and skipped
- **Apply with per-row try/catch** - failures are logged and the run continues
- **Changelog CSV per run** with timestamp, mailbox, old forward, new forward, deliver-and-store flag, result, error
- **Settings dialog** for target domain, service-account UPN, cache TTL, deliver-and-store default - persists to `config.json`
- **`-SelfTest` switch** - validates config and EXO connectivity, touches no mailboxes

## Quick start

Download the zip from [Releases](https://github.com/mardahl/EXO-mailforwardManager/releases/latest), extract, then double-click **`Launch-MailboxForwardingTool.bat`** - it unblocks the files (removes the Mark of the Web) and starts the tool. Or run it yourself:

```powershell
git clone https://github.com/mardahl/EXO-mailforwardManager.git
cd EXO-mailforwardManager
copy config.example.json config.json
# edit config.json: ForwardingDomain, ServiceAccountUPN
.\MailboxForwardingTool.ps1
```

Each run configures an Exchange Online connection with a page size of 100 via `Connect-ExchangeOnline` (MFA handled by the module). Authentication may reuse an existing sign-in. Refresh reuses the connection configured by that run.

Mailbox loading can take several minutes on large tenants. The console warns before fetching and reports the count and elapsed time every 100 mailboxes, then prints the final count. The total is unknown until loading finishes. Failed retrievals discard partial results and leave the existing cache unchanged; Refresh also keeps the displayed rows if retrieval fails.

Dry-run config + connectivity without touching mailboxes:

```powershell
.\MailboxForwardingTool.ps1 -SelfTest
```

## Requirements

### Modules

- [`ExchangeOnlineManagement`](https://www.powershellgallery.com/packages/ExchangeOnlineManagement) v3.7.2+ - the only dependency. 3.7.0+ signs in via the Windows Web Account Manager (WAM) broker; older versions use the legacy embedded browser and fail on some machines.

The script installs or upgrades it automatically (CurrentUser scope) on first run if missing or too old. To install manually instead:

```powershell
Install-Module ExchangeOnlineManagement -Scope CurrentUser
```

### Roles & permissions

| Task | Requirement |
|---|---|
| Read mailboxes and set forwarding | **Exchange Administrator** (or **Global Administrator**) on the source tenant |
| Sign in | Interactive delegated auth as the service account; MFA supported via the EXO module |

The tool runs with the permissions of the signed-in account - no app registration required.

## Files the tool writes

| Location | Content |
|---|---|
| `config.json` | Operator settings: forwarding domain, service-account UPN, cache TTL, deliver-and-store default |
| `cache.json` | Mailbox enumeration snapshot (addresses + current forwarding state) with `FetchedAt` timestamp |
| `changelog-yyyyMMdd-HHmmss.csv` | One per Apply run: Timestamp, Mailbox, OldForwardingSmtpAddress, NewForwardingSmtpAddress, DeliverToMailboxAndForward, Result, Error |

All three are written next to the script and are `.gitignore`d. The cache and changelogs contain directory data - treat them accordingly.

## Caveats

Known limitations:

- Smaller pages do not guarantee that Exchange transport errors disappear. If loading reports an underlying connection failure, check connectivity, proxy/TLS inspection, and Exchange service health before retrying. Progress updates depend on results arriving from Exchange; they are not a continuous heartbeat.
- **Windows-only GUI.** WinForms requires a Windows desktop session. PowerShell 7 on macOS/Linux can parse the script but cannot display the forms.
- **On-prem `ForwardingAddress` not migrated.** Mailboxes whose forwarding points at an on-prem recipient object are flagged and skipped; they are not converted to `ForwardingSmtpAddress` automatically. Handle these manually.
- **No bulk-clear.** Clearing an existing forward (setting it to `$null`) is not exposed in the UI. Run `Set-Mailbox -ForwardingSmtpAddress $null` by hand if needed.
- **Cache can be stale.** The grid shows cache contents if within TTL; press **Refresh** to force re-enumeration. The changelog is authoritative for what was actually applied.
- **No undo.** Apply overwrites `ForwardingSmtpAddress` immediately. The Preview dialog and the changelog CSV are the safety rails - review before clicking Apply.
- **Single-tenant per config.** One `config.json` per install directory. For multiple tenants, keep separate clones (or extend - PRs welcome).

## References

- [Set-Mailbox (ExchangeOnlineManagement)](https://learn.microsoft.com/powershell/module/exchangepowershell/set-mailbox)
- [Configure mail forwarding for a mailbox (Microsoft Learn)](https://learn.microsoft.com/exchange/recipients-in-exchange-online/manage-user-mailboxes/configuring-mailbox-forwarding)
- [Connect-ExchangeOnline](https://learn.microsoft.com/powershell/exchange/connect-to-exchange-online-powershell)

## Contributing

Bug reports and PRs are welcome - see [CONTRIBUTING.md](CONTRIBUTING.md) for the ground rules (single file, regions, PS 5.1 syntax, safety UX) and the lint command. CI enforces PSScriptAnalyzer and a parse check. Release notes live in [CHANGELOG.md](CHANGELOG.md).

## Security

No telemetry. Authentication is delegated to `ExchangeOnlineManagement` (MSAL under the hood) - the tool never sees, stores, or logs credentials. `cache.json` and `changelog-*.csv` contain directory data; do not commit or share them unredacted. See [SECURITY.md](SECURITY.md) for the full policy and how to report vulnerabilities privately.

## License

MIT - see [LICENSE](LICENSE).

Provided as-is, without warranty. Test in a non-production tenant first.
