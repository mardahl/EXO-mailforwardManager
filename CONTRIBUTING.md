# Contributing

Thanks for helping improve EXO Mailbox Forward Manager. The project is a
single-file PowerShell script: `MailboxForwardingTool.ps1` contains every
region (Config / Exchange / Actions / UI / Main) - please keep that shape.

## Ground rules

1. **Single file.** All runtime code lives in `MailboxForwardingTool.ps1`,
   split into `#region` blocks. No modules, no `src/` split, no DLLs, no
   embedded binaries, no dependencies beyond `ExchangeOnlineManagement`.
   The tool must stay portable - clone and run.
2. **Windows PowerShell 5.1 compatible.** No PS 7-only syntax (no
   null-coalescing `??`, no ternary `?:`, no `using namespace` at script
   scope that breaks 5.1). Test with `powershell.exe`, not just `pwsh`.
3. **No telemetry, no phoning home.** The only network calls are to
   Exchange Online via the EXO module, triggered explicitly by the
   operator (Refresh or Apply).
4. **Safety UX is not optional.** Every destructive path must go through
   the Preview dialog. Bulk changes must append a row per mailbox to the
   changelog CSV. No silent overwrites, no silent clears of existing
   forwards.
5. **`ForwardingSmtpAddress`, not `ForwardingAddress`.** The tool manages
   SMTP-based forwarding only. Mailboxes with an on-prem recipient-based
   forward are flagged and skipped, not migrated.

## Dev setup

```powershell
Install-Module ExchangeOnlineManagement -Scope CurrentUser
.\MailboxForwardingTool.ps1 -SelfTest   # validates config + connectivity
.\MailboxForwardingTool.ps1             # launches the GUI
```

A test tenant with a handful of user mailboxes, some with existing
forwards, some with on-prem `ForwardingAddress` set, is the fastest way
to exercise every code path.

### Lint (must be clean before a PR)

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-ScriptAnalyzer -Path .\MailboxForwardingTool.ps1 -Settings .\PSScriptAnalyzerSettings.psd1 -Severity Error, Warning
```

CI runs the same analyzer plus a parse check
(`[System.Management.Automation.Language.Parser]::ParseFile`) on the
script. GUI behavior is verified manually against a test tenant - CI
cannot host WinForms.

## What to test before a PR

- `-SelfTest` succeeds against a real tenant.
- Settings dialog roundtrips config (change domain, reopen, values match).
- Refresh re-enumerates and preserves unsaved prefix edits on mailboxes
  that still exist.
- Prefix edit recomputes `Will forward to` in the same row.
- Filter: search box + All / Has forward / No forward radios.
- Preview shows overwrites in red, on-prem rows in orange with skip text.
- Apply writes a changelog CSV with one row per mailbox and the correct
  Result per row; grid updates to show the new forward.
- Cache TTL honored: relaunch within TTL skips enumeration, past TTL
  re-enumerates.

## Style

- `#region` / `#endregion` blocks: Config, Exchange, Actions, UI, Main.
- Functions are `Verb-Noun`, PascalCase. Internal helpers used only by one
  caller stay inline in that caller.
- Comment only where intent is non-obvious. Do not restate the code.
