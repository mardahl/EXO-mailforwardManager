# Changelog

All notable changes to this project are documented here. The format is based
on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/mardahl/EXO-mailforwardManager/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/mardahl/EXO-mailforwardManager/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/mardahl/EXO-mailforwardManager/releases/tag/v1.0.0
