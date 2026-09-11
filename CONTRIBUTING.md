# Contributing

Thanks for helping improve EXO Mailbox Forward Manager. The project is a
PowerShell script split by responsibility:

- `MailboxForwardingTool.ps1` - entry point. Apartment/relaunch check, then
  `Main`: platform/host support check, module install, config, sign-in,
  mailbox load, `Show-Tui`. Loads `src/` via an ordered `foreach` at startup.
- `src/00-state.ps1` - shared module-scope state (`$script:UI`, glyphs,
  theme), loaded first.
- `src/10-console.ps1` - console/VT lifecycle: `Enter-Tui`, `Exit-Tui`,
  `Invoke-OnMainBuffer` (leaves the alternate screen buffer for interactive
  auth/module install, then restores it), `Test-TuiHostSupported`,
  `Get-ConsoleSize`, frame-building primitives, and the `Show-Tui` loop.
- `src/20-dialogs.ps1` - modal dialogs: settings, per-row editor, preview
  confirmation, scrollable report, and progress lines.
- `src/30-config-cache.ps1` - `Get-Config`, `Save-Config`, mailbox cache
  read/write/freshness, forwarding-address/config validation.
- `src/40-exchange.ps1` - `Install-ExoModule`, `Connect-Exo`,
  `Get-MailboxList` (optional `-OnProgress` callback).
- `src/50-forwarding.ps1` - `New-ForwardingPreview`, `Set-MailboxForwards`.
- `src/60-mailbox-model.ps1` - pure row/state model: `New-MailboxRows`,
  `Update-MailboxView`, `Set-MailboxSelection`, `Set-MailboxDraft`,
  `Merge-MailboxRefresh`.
- `src/70-views.ps1` - `Get-MailboxFrame`, `Get-PreviewFrame`; renders state
  to a plain string, never mutates state, never calls Exchange.
- `src/80-input.ps1` - `Invoke-TuiKey`, the main-table key dispatcher.

## Ground rules

1. **`src/` files are side-effect-free at load time.** Dot-sourcing any file
   in `src/` must only define functions and module-scope state - no network
   calls, no console/terminal calls, no module installation. Installation,
   connection, and any console state change happen only when the entry
   point (or a function it calls) is explicitly invoked. No modules, no
   DLLs, no embedded binaries, no dependencies beyond
   `ExchangeOnlineManagement`. The tool must stay portable - clone and run.
2. **Windows PowerShell 5.1 compatible.** No PS 7-only syntax (no
   null-coalescing `??`, no ternary `?:`, no `using namespace` at script
   scope that breaks 5.1). Test with `powershell.exe`, not just `pwsh`.
3. **No telemetry, no phoning home.** The only network calls are to
   Exchange Online via the EXO module, triggered explicitly by the
   operator (Refresh or Apply) or by the entry point at startup.
4. **Interactive auth and module install run on the normal screen buffer,
   never inside the terminal UI's alternate buffer.** Route anything that
   needs the normal buffer through `Invoke-OnMainBuffer`, which restores
   the TUI afterward even if the action throws.
5. **Safety UX is not optional.** Every destructive path must go through
   the Preview dialog, which only accepts an explicit `Y`; Enter never
   confirms. Bulk changes must append a row per mailbox to the changelog
   CSV. No silent overwrites, no silent clears of existing forwards.
6. **`ForwardingSmtpAddress`, not `ForwardingAddress`.** The tool manages
   SMTP-based forwarding only. Mailboxes with an on-prem recipient-based
   forward are flagged and skipped, not migrated.

## Dev setup

```powershell
Install-Module ExchangeOnlineManagement -Scope CurrentUser
.\MailboxForwardingTool.ps1 -SelfTest   # validates config + connectivity, no TUI
.\MailboxForwardingTool.ps1             # launches the terminal UI
.\MailboxForwardingTool.ps1 -Ascii      # plain ASCII glyphs (no Unicode/256-color)
```

A test tenant with a handful of user mailboxes, some with existing
forwards, some with on-prem `ForwardingAddress` set, is the fastest way
to exercise every code path.

### Lint (must be clean before a PR)

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-ScriptAnalyzer -Path .\MailboxForwardingTool.ps1 -Settings .\PSScriptAnalyzerSettings.psd1 -Severity Error, Warning
Invoke-ScriptAnalyzer -Path .\src -Recurse -Settings .\PSScriptAnalyzerSettings.psd1 -Severity Error, Warning
```

### Tests (must pass before a PR)

```powershell
Get-ChildItem .\tests -Filter *.Tests.ps1 | ForEach-Object { & $_.FullName }
```

Every test dot-sources `tests/TestSupport.ps1`, the same side-effect-free
`src/` loader the entry point uses, so no test installs modules, connects
to Exchange, or touches the console. `tests/Tui.Tests.ps1` also asserts
there is no lingering `Windows.Forms`/`DataGridView`/legacy-GUI reference
anywhere in the entry point or `src/`.

CI runs the same analyzer, a parse check
(`[System.Management.Automation.Language.Parser]::ParseFile`) on the entry
script and every file in `src/`, and the full test suite on both
PowerShell 7 (ubuntu) and Windows PowerShell 5.1 (windows-latest). Live
Exchange behavior and real keyboard interaction in a real terminal still
require manual testing.

## What to test before a PR

- `-SelfTest` succeeds against a real tenant, and prints setup instructions
  with a nonzero exit when `config.json` is missing (no dialog).
- First launch with no `config.json` opens the Settings dialog inside the
  terminal UI and writes `config.json` on Save.
- Settings dialog roundtrips config (change domain, reopen, values match);
  Escape cancels without touching the saved config.
- Refresh (`R`) re-enumerates and preserves unsaved prefix edits on
  mailboxes that still exist; a failed refresh keeps the existing rows and
  shows the error.
- Enter opens the row editor; Escape cancels without mutating the row; an
  invalid prefix or destination is rejected in place with an error line.
- Search (`/`) plus the All / Has forward / No forward filter (`F`).
- Space selects/toggles and advances the cursor; `A` selects everything
  visible; `N` clears every selection, including hidden rows. Selections
  survive filter/search changes and reach Preview.
- Preview (`P`) is a no-op with zero selected. It shows every selected
  mailbox (even hidden ones), explicit Skip/Overwrite/Set text per row, and
  only `Y` applies - Enter must not confirm.
- Apply writes a changelog CSV with one row per mailbox and the correct
  Result per row; the table updates to show the new forward for OK rows
  only.
- Apply summary shows numeric counts for a single success, skip, or error.
- Cache TTL honored: relaunch within TTL skips enumeration, past TTL
  re-enumerates.
- Resize the terminal during use: below 80x20 only quitting works; above
  it, the table and dialogs reflow without losing the cursor or selection.
- Interactive auth (first sign-in, or a forced retry) briefly leaves the
  terminal UI screen and returns to it afterward, even on failure.

## Style

- Functions are `Verb-Noun`, PascalCase. Internal helpers used only by one
  caller stay inline in that caller.
- Comment only where intent is non-obvious. Do not restate the code.
- Keep `src/` files single-purpose per the numbered prefix; add a new
  numbered file rather than growing an unrelated one.
