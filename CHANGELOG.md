# Changelog

All notable changes to this project are documented here. The format is based
on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.9] - 2026-09-07

- Fix: searching or switching All / Has forward / No forward no longer tries
  to hide the current bound row, avoiding the WinForms CurrencyManager error.
- Fix: prefix edits in filtered results update the correct mailbox. Unsaved
  prefix and delivery-option edits are retained when filters change.
- Change: changing filters clears row selection so rebinding does not select
  a mailbox for Preview automatically.
- Add: offline filtering regression checks and native WinForms checks in
  Windows PowerShell 5.1 CI.

## [1.0.8] - 2026-09-07

- Fix: mailbox retrieval stops on Exchange errors instead of reporting zero
  results and then failing with a null-argument error. Partial results are
  discarded and existing cache is preserved. Refresh reports the error
  without changing displayed rows.
- Fix: successful empty mailbox lists can be cached and displayed.
- Change: connections request native pages of up to 100 entries. Mailbox
  loading warns that large tenants can take several minutes and reports
  count and elapsed time every 100 results, plus the final count.
- Add: offline mailbox-loading regression checks in PowerShell 7 and
  Windows PowerShell 5.1 CI.

### Known limitations

- Smaller pages do not guarantee resolution of underlying Exchange transport
  failures. Progress depends on results arriving from Exchange. Live tenant
  paging and Windows dialog behavior still require manual validation.

## [1.0.7] - 2026-09-07

- Fix: silent gap between sign-in and main window - mailbox enumeration ran
  with zero feedback, and the console window closed right after the form,
  taking all output (including errors) with it. Now: console messages at
  each step, `Write-Progress` during enumeration and during apply, fatal
  errors printed with stack trace, and the console pauses before closing
  when launched via the .bat or a relaunch (`EXOMFT_PAUSE_ON_EXIT`), so
  the operator can read/copy what happened.

## [1.0.6] - 2026-09-07

- Fix: connect no longer passes the service-account UPN to
  `Connect-ExchangeOnline`. A login hint makes MSAL do directed broker auth
  against an account that may not be registered in Windows, producing
  "Missing wamcompat_id_token in WAM case" and a sign-in window that
  flashes and closes. Without the hint, WAM shows the account picker and
  the operator signs in with the credentials. The configured UPN is printed
  to the console as sign-in guidance instead.

## [1.0.5] - 2026-09-07

- Fix: `-DisableWAM` retry inside the same PowerShell process still hit the
  WAM broker (module 3.10.1) - the EXO module appears to latch MSAL broker /
  native msalruntime state at first connect. On WAM failure the tool now
  relaunches itself in a fresh process with a new `-DisableWAM` script
  switch, so the retry connects with the broker disabled from the start.
  New script parameter: `-DisableWAM` (also usable directly to skip WAM on
  machines known to have broker problems).

## [1.0.4] - 2026-09-07

- Fix: `-DisableWAM` retry passed `ErrorAction` twice (once via splat, once
  explicitly), which aborts the retry with a parameter binding error. The
  `-DisableWAM` fallback was therefore unreachable in 1.0.3.

## [1.0.3] - 2026-09-07

- Fix: WAM broker failures ("Missing wamcompat_id_token in WAM case", tag
  0x20714047 - known unfixed MSAL.NET bug #4095) were not retried with
  `-DisableWAM` because MSAL nests the real error inside a generic outer
  exception. The whole exception chain is now inspected before deciding.
- Fix: module import now loads the newest installed ExchangeOnlineManagement
  by exact path; an old copy in Program Files (AllUsers scope) could shadow
  the upgraded CurrentUser copy.
- Add: clearer error when the loaded module predates `-DisableWAM` (< 3.7.2),
  with the exact update command. Retry warning now reports the module
  version for diagnosis.

## [1.0.2] - 2026-09-07

- Fix: machines with an outdated ExchangeOnlineManagement module (< 3.7.0)
  still hit the ActiveX/MSAL embedded-browser sign-in failure. The module
  bootstrap now enforces version >= 3.7.2: installs or upgrades
  automatically, and imports the newest installed copy explicitly. 3.7.0+
  uses the Windows Web Account Manager (WAM) broker for interactive auth,
  which has no embedded browser and no COM apartment dependency.
- Add: `Connect-Exo` falls back to `Connect-ExchangeOnline -DisableWAM`
  when the WAM broker itself errors (per Microsoft's guidance for
  WAM-related connection errors).

## [1.0.1] - 2026-09-07

- Fix: interactive sign-in could fail with "ActiveX control
  '8856f961-340a-11d0-a96b-00c04fd705a2' cannot be instantiated because the
  current thread is not in a single-threaded apartment" when the script ran
  on an MTA thread. Launcher now passes `-Sta`, and the script detects an
  MTA host at startup and relaunches itself under `powershell.exe -Sta`.
- Add: ExchangeOnlineManagement module is now bootstrapped automatically -
  if missing, the script installs it (CurrentUser scope) and imports it; no
  manual setup step required.
- Change: initial setup dialog enlarged with inline explanations for every
  field (forwarding domain, service account UPN, cache TTL, deliver-and-
  store), including examples and where to change values later.

## [1.0.0] - 2026-09-07

Initial release.

- Single-file WinForms GUI over ExchangeOnlineManagement for bulk-setting
  mailbox forwarding during tenant migrations.
- Fixed target forwarding domain configured by the operator; per-mailbox
  forwarding prefix defaults to the primary SMTP local part and is editable
  in the grid.
- Deliver-to-mailbox-and-forward enabled by default, toggleable per row.
- Mailbox enumeration cached locally with configurable TTL; Refresh button
  forces re-enumeration while preserving unsaved prefix edits.
- Live search plus Has forward / No forward filter.
- Preview dialog shows old → new forward per mailbox; overwrites
  highlighted, mailboxes with on-prem `ForwardingAddress` flagged and
  skipped.
- Apply writes a timestamped changelog CSV with per-mailbox result.
- Settings dialog for domain, service-account UPN, cache TTL, and
  deliver-and-store default; persists to `config.json`.
- `-SelfTest` switch validates config and EXO connectivity without
  touching mailboxes.
- `Launch-MailboxForwardingTool.bat` launcher. Unblocks all files
  (removes Mark of the Web) and starts the script with Windows PowerShell
  5.1, matching the pattern used in related repos.
- Release workflow. Tagging `v*.*.*` builds a clean zip containing
  only the script, launcher, example config, README, LICENSE, and
  CHANGELOG - no source-repo bloat - and attaches it to the GitHub
  release with the matching changelog section as notes.

[Unreleased]: https://github.com/mardahl/EXO-mailforwardManager/compare/v1.0.9...HEAD
[1.0.9]: https://github.com/mardahl/EXO-mailforwardManager/compare/v1.0.8...v1.0.9
[1.0.8]: https://github.com/mardahl/EXO-mailforwardManager/compare/v1.0.7...v1.0.8
[1.0.7]: https://github.com/mardahl/EXO-mailforwardManager/compare/v1.0.6...v1.0.7
[1.0.6]: https://github.com/mardahl/EXO-mailforwardManager/compare/v1.0.5...v1.0.6
[1.0.5]: https://github.com/mardahl/EXO-mailforwardManager/compare/v1.0.4...v1.0.5
[1.0.4]: https://github.com/mardahl/EXO-mailforwardManager/compare/v1.0.3...v1.0.4
[1.0.3]: https://github.com/mardahl/EXO-mailforwardManager/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/mardahl/EXO-mailforwardManager/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/mardahl/EXO-mailforwardManager/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/mardahl/EXO-mailforwardManager/releases/tag/v1.0.0
