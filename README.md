# EXO Mailbox Forward Manager

[![CI](https://github.com/mardahl/EXO-mailforwardManager/actions/workflows/ci.yml/badge.svg)](https://github.com/mardahl/EXO-mailforwardManager/actions/workflows/ci.yml)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](#requirements)
[![Platform](https://img.shields.io/badge/platform-Windows-555)](#requirements)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)
[![Downloads](https://img.shields.io/github/downloads/mardahl/EXO-mailforwardManager/total)](https://github.com/mardahl/EXO-mailforwardManager/releases)
![Visitors](https://hits.sh/github.com/mardahl/EXO-mailforwardManager.svg)

A single-command PowerShell **terminal UI** for bulk-setting mailbox forwarding in **Exchange Online** during tenant migrations - fixed target domain, per-user prefix override, deliver-and-store toggle, preview-before-apply, and a CSV audit trail for every run.

## TL;DR

Copy `config.example.json` to `config.json` and fill in the target domain and service-account UPN, then run:

```powershell
.\MailboxForwardingTool.ps1
```

The tool lists every user mailbox (cached locally), lets you search/filter and select the mailboxes to update, edit the forwarding prefix per row, then **Preview → Apply**. A timestamped changelog CSV is written per apply-run.

```
 ExoMft  Account: svc-migration@source.example.com  Cache: 2026-09-10T08:00:00Z
 Visible: 3/3  Selected: 1 (0 hidden)  Search: ''  Filter: All
    Mailbox                  Current forwarding       Proposed forwarding        Keep Warn
 [x] alice@source.example.com                          alice@target.example.com  Yes
 [ ] bob@source.example.com   bob@target.example.com    bob@target.example.com    Yes
 [ ] carol@source.example.com                           carol@target.example.com  Yes  Y
 Up/Dn Move  Space Sel  A All  N None  / Search  F Filter  Enter Edit  R Refresh  S Settings  P Preview  ? Help  Q Quit
```

---

- [TL;DR](#tldr)
- [Why](#why)
- [Features](#features)
- [Quick start](#quick-start)
- [Select mailboxes](#select-mailboxes)
- [Requirements](#requirements)
- [Files the tool writes](#files-the-tool-writes)
- [Caveats](#caveats)
- [Contributing](#contributing) · [Security](#security) · [Changelog](CHANGELOG.md)

## Why

Tenant-to-tenant mailbox migrations end with the same tedious step: setting a forwarding rule on each source mailbox so mail keeps flowing to the new tenant while DNS and clients catch up. Doing this one-by-one in the Exchange admin center is slow and error-prone; doing it with a raw CSV-driven script means the operator maintains yet another file outside the tool.

This tool puts a terminal UI over `Set-Mailbox -ForwardingSmtpAddress`: the mailbox list is fetched and cached inside the tool, the forwarding prefix defaults to each mailbox's existing local-part (the common case), and the rare exception is edited in-place. The operator sees existing forwards before overwriting them, previews every change, and gets an audit CSV per run.

| Action | Handled | Not handled |
|---|---|---|
| Set `ForwardingSmtpAddress` to `prefix@<target-domain>` | Any user mailbox, bulk | - |
| Per-row prefix override | Editable in the row editor (Enter) | - |
| Deliver-to-mailbox-and-forward | On by default, per-row toggle | - |
| Mailboxes with on-prem `ForwardingAddress` set | Flagged, skipped on Apply | Migrating on-prem forwarding to cloud - do by hand |
| Existing forward present | Shown, overwrite confirmed in Preview | Silently clearing forwards - not supported |

## Features

- **Single-command launch** - no build step; only dependency is `ExchangeOnlineManagement`
- **PowerShell 5.1** on Windows (works on pwsh 7 too, but the console UI requires a real Windows terminal)
- **Terminal UI** with live search, All / Has forward / No forward filter, row selection, and a selected count including hidden rows
- **Mailbox enumeration cached locally** with configurable TTL - no full tenant re-enumeration per launch
- **Editable forwarding prefix per row** (Enter opens the row editor), defaults to the mailbox's primary SMTP local part; the proposed destination recomputes live
- **Preview dialog** showing old → new forward per mailbox before applying; on-prem-forward mailboxes flagged and skipped
- **Apply with per-row try/catch** - failures are logged and the run continues
- **Changelog CSV per run** with timestamp, mailbox, old forward, new forward, deliver-and-store flag, result, error
- **Settings dialog** for target domain, service-account UPN, cache TTL, deliver-and-store default - persists to `config.json`
- **`-SelfTest` switch** - validates config and EXO connectivity, touches no mailboxes
- **`-Ascii` switch** - plain ASCII box-drawing/glyphs for terminals without Unicode/256-color support

## Quick start

Download the zip from [Releases](https://github.com/mardahl/EXO-mailforwardManager/releases/latest), extract, then double-click **`Launch-MailboxForwardingTool.bat`** - it unblocks the files (removes the Mark of the Web) and starts the tool. Or run it yourself:

```powershell
git clone https://github.com/mardahl/EXO-mailforwardManager.git
cd EXO-mailforwardManager
copy config.example.json config.json
# edit config.json: ForwardingDomain, ServiceAccountUPN
.\MailboxForwardingTool.ps1
```

If `config.json` is missing, the tool opens its Settings dialog on first launch instead of failing - fill in the fields there and it writes `config.json` for you.

Each run configures an Exchange Online connection with a page size of 100 via `Connect-ExchangeOnline` (MFA handled by the module). Authentication may reuse an existing sign-in and always happens on the normal screen buffer (never inside the terminal UI's alternate screen). Refresh (`R`) reuses the connection configured by that run.

Mailbox loading can take several minutes on large tenants. The tool shows a busy indicator and the running count while fetching, and the total is unknown until loading finishes. Failed retrievals discard partial results and leave the existing cache unchanged; Refresh also keeps the displayed rows if retrieval fails.

Dry-run config + connectivity without touching mailboxes:

```powershell
.\MailboxForwardingTool.ps1 -SelfTest
```

`-SelfTest` never opens the terminal UI; if `config.json` is missing it prints setup instructions and exits with a nonzero code instead of prompting.

## Select mailboxes

1. Search (`/`) for a mailbox, then press **Enter** on a row to edit its forwarding prefix or Deliver+Store option. Check the proposed destination before continuing.
2. Press **Space** on a row to select it; the cursor advances automatically. Selections stay checked across searches and filter changes.
3. Press **A** to select every mailbox matching the current filter/search. **N** clears every selection, including hidden ones.
4. The header shows **Selected: N (M hidden)**. Preview includes every selected mailbox, even those hidden by the current filter.
5. Press **P** to preview, review every destination, then **Y** to apply (**N**/Esc cancels; Enter alone never applies).

**Deliver+Store is not a selection control.** It controls whether incoming mail is kept in the source mailbox as well as forwarded. Apply reports numeric totals for applied, skipped, and failed mailboxes, including single-mailbox runs.

Press **?** at any time for the full key list.

## Requirements

### Modules

- [`ExchangeOnlineManagement`](https://www.powershellgallery.com/packages/ExchangeOnlineManagement) v3.7.2+ - the only dependency. 3.7.0+ signs in via the Windows Web Account Manager (WAM) broker; older versions use the legacy embedded browser and fail on some machines.

The script installs or upgrades it automatically (CurrentUser scope) on first run if missing or too old. To install manually instead:

```powershell
Install-Module ExchangeOnlineManagement -Scope CurrentUser
```

### Terminal/runtime requirements

- **Windows only.** The terminal UI uses console VT APIs and the same sign-in stack as the EXO module; both are Windows-specific. Running on macOS/Linux prints an explicit unsupported-platform message and exits before any module install or network call.
- **An interactive console**, at least 80x20. A redirected/piped input or output stream (or a host that doesn't support reading key input, such as some CI runners) is rejected up front with a clear error, before any console state is touched. Resizing the window itself below 80x20 while the tool is running is not rejected outright: the main table switches to a "resize" message, and every modal (Settings, row editor, Preview, reports) refuses to commit (Save/Y) until the window is back at or above the floor - shrinking never crashes or corrupts the layout, it just pauses input until you resize back up.
- Windows PowerShell 5.1 or PowerShell 7+.

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

- Mailbox loading and Apply both run on the calling thread; the terminal UI shows a busy indicator during either, but does not accept key input until the operation finishes. Smaller pages do not guarantee that Exchange transport errors disappear - if loading reports an underlying connection failure, check connectivity, proxy/TLS inspection, and Exchange service health before retrying.
- **Windows-only.** The console VT lifecycle and the EXO module's WAM sign-in are Windows-specific. PowerShell 7 on macOS/Linux is rejected with an explicit message before any module install or network call.
- **On-prem `ForwardingAddress` not migrated.** Mailboxes whose forwarding points at an on-prem recipient object are flagged and skipped; they are not converted to `ForwardingSmtpAddress` automatically. Handle these manually.
- **No bulk-clear.** Clearing an existing forward (setting it to `$null`) is not exposed in the UI. Run `Set-Mailbox -ForwardingSmtpAddress $null` by hand if needed.
- **Cache can be stale.** The table shows cache contents if within TTL; press **R** to force re-enumeration. The changelog is authoritative for what was actually applied.
- **No undo.** Apply overwrites `ForwardingSmtpAddress` immediately. The Preview dialog (explicit `Y`/`N`, Enter never confirms) and the changelog CSV are the safety rails - review before pressing Y.
- **Single-tenant per config.** One `config.json` per install directory. For multiple tenants, keep separate clones (or extend - PRs welcome).
- **`-SelfTest` still performs a real network connection.** It validates config and connectivity against the live tenant (no mailbox mutation) - it is not fully offline.

## References

- [Set-Mailbox (ExchangeOnlineManagement)](https://learn.microsoft.com/powershell/module/exchangepowershell/set-mailbox)
- [Configure mail forwarding for a mailbox (Microsoft Learn)](https://learn.microsoft.com/exchange/recipients-in-exchange-online/manage-user-mailboxes/configuring-mailbox-forwarding)
- [Connect-ExchangeOnline](https://learn.microsoft.com/powershell/exchange/connect-to-exchange-online-powershell)

## Contributing

Bug reports and PRs are welcome - see [CONTRIBUTING.md](CONTRIBUTING.md) for the ground rules (source layout, PS 5.1 syntax, safety UX) and the lint/test commands. CI enforces PSScriptAnalyzer, a parse check, and the offline test suite on both PowerShell 7 and Windows PowerShell 5.1. Release notes live in [CHANGELOG.md](CHANGELOG.md).

## Security

No telemetry. Authentication is delegated to `ExchangeOnlineManagement` (MSAL under the hood) - the tool never sees, stores, or logs credentials. `cache.json` and `changelog-*.csv` contain directory data; do not commit or share them unredacted. See [SECURITY.md](SECURITY.md) for the full policy and how to report vulnerabilities privately.

## License

MIT - see [LICENSE](LICENSE).

Provided as-is, without warranty. Test in a non-production tenant first.
