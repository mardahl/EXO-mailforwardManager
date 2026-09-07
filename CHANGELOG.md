# Changelog

All notable changes to this project are documented here. The format is based
on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Add: `Launch-MailboxForwardingTool.bat` launcher. Unblocks all files
  (removes Mark of the Web) and starts the script with Windows PowerShell
  5.1, matching the pattern used in related repos.

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

[Unreleased]: https://github.com/mardahl/EXO-mailforwardManager/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/mardahl/EXO-mailforwardManager/releases/tag/v1.0.0
