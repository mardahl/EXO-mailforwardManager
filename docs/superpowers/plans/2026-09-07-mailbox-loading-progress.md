# Mailbox loading progress implementation plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Fetch user mailboxes using native 100-entry pages, report progress, and preserve existing cache on enumeration failure.

**Architecture:** Configure `Connect-ExchangeOnline -PageSize 100` once per script run, including both authentication paths. Stream `Get-EXOMailbox -ResultSize Unlimited` through the existing object mapping, reporting each 100 results and final count. Publish results and save cache only after enumeration succeeds.

**Tech Stack:** Windows PowerShell 5.1, WinForms, ExchangeOnlineManagement >= 3.7.2; framework-free PowerShell regression check.

## Constraints

- Keep application in `MailboxForwardingTool.ps1`; no new runtime dependencies.
- Console progress reports counts and elapsed time, not an unknown percentage or ETA.
- Keep original Exchange error details and discard partial enumeration on failure.
- Successful empty results must serialize as an empty mailbox array and open an empty grid.
- Refresh failures leave displayed data unchanged and show an error dialog.
- Smaller pages do not guarantee resolution of an underlying transport failure.

## Task 1: Regression check and implementation

**Files:** `MailboxForwardingTool.ps1`, `tests/MailboxLoading.Tests.ps1`, `.github/workflows/ci.yml`, `README.md`.

- [x] Load production function definitions via the PowerShell AST in a standalone check, avoiding Windows GUI startup and real authentication.
- [x] Stub only Exchange and console boundaries. Exercise actual cache serialization with a temporary file. Cover 0, 1, 99, 100, 101, 200, and 250 results; failure before results and after 100 results; cache reuse; default and DisableWAM connection paths.
- [x] Run `pwsh -NoProfile -File ./tests/MailboxLoading.Tests.ps1` against unchanged production code and confirm regression failures.
- [x] Add `PageSize = 100` to connection arguments and track successful configuration for this script run. Use `-ErrorAction Stop` on enumeration, buffer mapped results until success, and clear progress in `finally`.
- [x] Update `Write-Progress` and console output every 100 results, including elapsed time. Print final result count after success. Preserve existing cache if enumeration throws.
- [x] Wrap call-site results in `@(...)`, allow empty arrays at cache/UI boundaries, and catch Refresh errors before changing rows.
- [x] Run regression check again and require all assertions to pass. Add it to both PowerShell 7 and Windows PowerShell CI jobs.
- [x] Update README with loading behavior and transport limitations. Run PSScriptAnalyzer and `git diff --check`; inspect diff for unintended changes.

## Verification limits

Offline checks verify script behavior, not Exchange server paging or Windows dialog rendering. Validate a fresh connection and Refresh against a Windows tenant before release.
