# PowerShell TUI Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace WinForms with a space-efficient PowerShell TUI and maintainable numbered source files, preserving forwarding workflows and safety rules.

**Architecture:** Adapt SOAconverter's native ANSI/VT console and interaction patterns into local files. Keep full mailbox records separate from the filtered view and cursor. Exchange operations remain synchronous and return structured data; rendering does not call Exchange.

**Tech Stack:** Windows PowerShell 5.1, PowerShell 7 on Windows, ExchangeOnlineManagement, native .NET console APIs, existing assert-based PowerShell tests, PSScriptAnalyzer, GitHub Actions.

## Global constraints

- Supported runtime: Windows PowerShell 5.1 and PowerShell 7 on Windows.
- UI: native PowerShell and ANSI/VT; no new runtime dependencies.
- ExchangeOnlineManagement minimum version: 3.7.2; installed version must also support the running PowerShell version.
- Minimum interactive terminal size: 80 columns by 20 rows.
- Source loading: numbered `src/*.ps1` files, sorted by name and dot-sourced with a language-keyword `foreach`.
- Runtime files must be local to this repository; no runtime dependency on `../SOAconverter`.
- Preserve `-SelfTest`, `-DisableWAM`, root launcher names, existing config/cache schemas, and artifact locations beside the root script.
- Preserve mandatory preview, hidden selections, on-prem forwarding skips, and one audit record per selected mailbox.
- Exchange operations remain sequential; no new jobs, worker processes, or runspaces for data operations.
- Do not commit, publish, connect to a tenant, or apply mailbox changes as part of documentation work.

Design: `docs/superpowers/specs/2026-09-10-powershell-tui-design.md`.

Implementation requires separate execution authorization. Task boundaries are review checkpoints, not authorization to commit. If commits are requested during execution, stage only reviewed task files and use the suggested message.

## File map

| Path | Responsibility |
| --- | --- |
| `MailboxForwardingTool.ps1` | Parameters, root path capture, ordered loading, STA bootstrap, startup, main loop, cleanup |
| `src/00-state.ps1` | Root-derived paths, theme/glyphs, UI state |
| `src/10-console.ps1` | VT lifecycle, terminal size, drawing/text helpers |
| `src/20-dialogs.ps1` | Input, settings, mailbox editor, confirmation, progress, results |
| `src/30-config-cache.ps1` | Config/cache IO, config validation, freshness |
| `src/40-exchange.ps1` | Module setup, authentication, complete mailbox fetch |
| `src/50-forwarding.ps1` | Preview snapshots, validation, Apply, audit/cache outcomes |
| `src/60-mailbox-model.ps1` | Model construction, filtering, selection, edits, refresh merging |
| `src/70-views.ps1` | Main and preview frame construction |
| `src/80-input.ps1` | Key dispatch, operation/dialog orchestration |
| `tests/TestSupport.ps1` | Side-effect-free source loader and existing-style Assert helper |
| `tests/MailboxLoading.Tests.ps1` | Existing fetch/auth/cache regression checks |
| `tests/ApplyCounts.Tests.ps1` | Real result counts, replacing AST-expression extraction |
| `tests/MailboxModel.Tests.ps1` | Replacement for `tests/GridFiltering.Tests.ps1` |
| `tests/Forwarding.Tests.ps1` | Stubbed mutation, snapshots, audit and state checks |
| `tests/Tui.Tests.ps1` | Frames, key dispatch, dialog cancellation, lifecycle orchestration |
| `tests/Config.Tests.ps1` | Settings validation and persistence |
| `tests/Start-TuiFixture.ps1` | Manual offline terminal startup with fake Exchange calls |
| `.github/workflows/ci.yml` | All-file lint/parse and offline tests across supported Windows runtimes |
| `.github/workflows/release.yml` | Include `src/` in release ZIP |
| `Launch-MailboxForwardingTool.bat` | Preserve startup flags and pass-through |
| `README.md`, `CONTRIBUTING.md`, `CHANGELOG.md` | TUI usage, architecture, tests, release notes |

## Shared contracts

Keep existing row property names to minimize change:

```powershell
[pscustomobject]@{
    Selected = $false
    PrimarySmtpAddress = 'alice@example.com'
    CurrentForwarding = ''
    HasOnPremForwarding = $false
    DeliverAndStore = $true
    ForwardingPrefix = 'alice'
    WillForwardTo = 'alice@archive.example.com'
}
```

`HasOnPremForwarding` becomes a Boolean everywhere; convert to warning text only in rendering. Raw/cache records retain `PrimarySmtpAddress`, `ForwardingSmtpAddress`, `DeliverToMailboxAndForward`, and `HasOnPremForwardingAddress`.

`$script:UI` is a hashtable with `Items` and `View` arrays, `Cursor` and `Scroll` integers, `Search` string, `Searching` Boolean, `Filter` (`All`, `HasForward`, `NoForward`), `Dirty` and `Running` Booleans, `Width` and `Height`, `Status` string, `Account` string, and `CacheFetchedAt`. Callers wrap pipeline collections in `@(...)`, including empty/singleton results. Mutating helpers produce no success-stream output.

Progress callbacks accept one hashtable:

```powershell
@{ Activity = 'Loading mailboxes'; Status = 'Waiting for Exchange Online';
   Count = 0; Total = $null; Completed = $false }
```

`Total = $null` means indeterminate; completion is emitted from `finally`. Optional callbacks replace direct host output during TUI operations, not mailbox return values. With no callback, retain console feedback for `-SelfTest` and existing loading tests.

## Task 1: Extract backend without changing UI

**Files:** Create `src/00-state.ps1`, `src/30-config-cache.ps1`, `src/40-exchange.ps1`, `tests/TestSupport.ps1`; modify root script, `tests/MailboxLoading.Tests.ps1`, CI, release workflow, and `CONTRIBUTING.md`.

**Interfaces:** Preserve `Get-Config`, `Save-Config -Config`, `Save-MailboxCache -Mailboxes`, `Read-MailboxCache`, `Test-CacheFresh -Cache`, `Install-ExoModule`, `Connect-Exo`, and `Get-MailboxList -Force`. Root captures `$script:EntryScriptPath`, `$script:ScriptDir`, and `$script:StartupOptions` before loading. Source loading has no network/UI side effects.

- [ ] Establish baseline with existing checks. Record failures before changing source.

```powershell
pwsh -NoProfile -File ./tests/MailboxLoading.Tests.ps1
pwsh -NoProfile -File ./tests/GridFiltering.Tests.ps1
pwsh -NoProfile -File ./tests/ApplyCounts.Tests.ps1
```

- [ ] Add the side-effect-free loader to `tests/TestSupport.ps1`. Move the loading test from root AST extraction to this helper; run the test before extraction and confirm missing backend functions cause failure.

```powershell
$script:EntryScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'MailboxForwardingTool.ps1'
$script:ScriptDir = Split-Path $script:EntryScriptPath -Parent
$script:StartupOptions = @{ SelfTest = $false; DisableWAM = $false; Ascii = $true }
foreach ($source in (Get-ChildItem (Join-Path $script:ScriptDir 'src') -Filter '*.ps1' | Sort-Object Name)) {
    . $source.FullName
}
function Assert($Condition, $Message) {
    if (-not $Condition) { throw $Message }
}
```

- [ ] Move config/cache functions from current root lines 64-85 and 217-235; move module/auth/fetch functions from lines 32-58, 168-214, and 237-277. Leave WinForms functions in root during this checkpoint. Keep installation inside startup, never at source-file top level. Root uses the same ordered `foreach` loader as the test helper.

```powershell
$script:EntryScriptPath = $PSCommandPath
$script:ScriptDir = $PSScriptRoot
$script:StartupOptions = @{ SelfTest = [bool]$SelfTest; DisableWAM = [bool]$DisableWAM; Ascii = $false }
foreach ($source in (Get-ChildItem (Join-Path $script:ScriptDir 'src') -Filter '*.ps1' | Sort-Object Name)) {
    . $source.FullName
}
```

- [ ] Replace moved auth function references to `$PSCommandPath` with `$script:EntryScriptPath` and switch access with `$script:StartupOptions`. Keep existing STA and fresh-process WAM fallback. Track whether the app opened the connection for later cleanup. Update loading test switch setup accordingly. Assert root-path identity, PageSize 100, and both `DisableWAM` choices; do not cause a real relaunch from tests.

```powershell
Assert ((Split-Path $script:EntryScriptPath -Leaf) -eq 'MailboxForwardingTool.ps1') 'Relaunch must target root script.'
Assert ($script:ConfigPath -eq (Join-Path $script:ScriptDir 'config.json')) 'Config path moved into src.'
Assert ($script:CachePath -eq (Join-Path $script:ScriptDir 'cache.json')) 'Cache path moved into src.'
```

- [ ] Update CI file enumeration immediately so new sources are parsed and linted. Add `cp -R src "$stage/"` to release staging. Replace CONTRIBUTING's ban on `src/` with the file map and side-effect-free loading rule. Retain WinForms checks until Task 6.

- [ ] If the retained grid test needs extracted functions, load `TestSupport.ps1` before its existing root UI/AST extraction. Keep event-handler assertions until their replacements exist; do not drop coverage to accommodate source movement.

- [ ] Run the baseline commands again, including `powershell.exe -NoProfile -File` equivalents on Windows. Expected: existing checks pass, source loading makes no Exchange calls. Review diff. Suggested authorized commit: `refactor: split config and Exchange source files`.

## Task 2: Extract mailbox state and validation

**Files:** Create `src/60-mailbox-model.ps1`, `tests/MailboxModel.Tests.ps1`, `tests/Config.Tests.ps1`; modify `src/00-state.ps1` and `src/30-config-cache.ps1`. Leave legacy UI tests until cutover.

**Interfaces:** `New-MailboxRows -Mailboxes [array] -Config [object]` emits row records. `Update-MailboxView -State [hashtable]` sets `View` and clamps cursor/scroll. `Get-SelectionCounts -State` returns `{ Total; Hidden }`. `Set-MailboxSelection -State -Mode Visible|None|Toggle` mutates selection. `Set-MailboxDraft -Row -Prefix [string] -DeliverAndStore [bool] -Domain [string]` validates then updates one row. `Merge-MailboxRefresh -State -Mailboxes [array]` updates only current fields of matching records. `Test-ForwardingConfig -Config` emits error strings, zero for valid config. `Test-ForwardingDestination -Address [string]` returns Boolean.

- [ ] Add representative real-model tests, then run `pwsh -NoProfile -File ./tests/MailboxModel.Tests.ps1` and confirm missing-function failure.

```powershell
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$config = [pscustomobject]@{ ForwardingDomain = 'archive.example.com'; DeliverToMailboxAndForward = $true }
$raw = @('alice','bob') | ForEach-Object {
    [pscustomobject]@{ PrimarySmtpAddress = "$_@example.com"; ForwardingSmtpAddress = '';
        DeliverToMailboxAndForward = $false; HasOnPremForwardingAddress = $false }
}
$items = @(New-MailboxRows -Mailboxes @($raw) -Config $config)
$state = @{ Items = $items; View = @(); Search = 'alice'; Filter = 'All'; Cursor = 0; Scroll = 0; Height = 20 }
$items[1].Selected = $true
Update-MailboxView -State $state
Set-MailboxSelection -State $state -Mode Visible
$counts = Get-SelectionCounts -State $state
Assert ($counts.Total -eq 2 -and $counts.Hidden -eq 1) 'Hidden selections lost.'
Set-MailboxDraft -Row $state.View[0] -Prefix 'archive-alice' -DeliverAndStore $false -Domain $config.ForwardingDomain
Assert ($items[0].WillForwardTo -eq 'archive-alice@archive.example.com') 'Filtered edit targeted wrong object.'
Set-MailboxSelection -State $state -Mode None
Assert ((Get-SelectionCounts -State $state).Total -eq 0) 'Clear must include hidden rows.'
```

- [ ] Implement model extraction using existing row/filter/selection logic at root lines 426-517. Filter references, not copies. Do not import BindingList or any WinForms type. For selection counts use `@(...).Count` to retain PowerShell 5.1 singleton behavior.

```powershell
$State.View = @($State.Items | Where-Object {
    (-not $State.Search -or $_.PrimarySmtpAddress -like "*$($State.Search)*") -and
    ($State.Filter -eq 'All' -or
     ($State.Filter -eq 'HasForward' -and -not [string]::IsNullOrEmpty($_.CurrentForwarding)) -or
     ($State.Filter -eq 'NoForward' -and [string]::IsNullOrEmpty($_.CurrentForwarding)))
})
$State.Cursor = [Math]::Max(0, [Math]::Min($State.Cursor, $State.View.Count - 1))
```

- [ ] Add validation cases and implement validation before mutation. Use `.NET MailAddress` parsing with exact address equality to reject display-name syntax; additionally reject controls/whitespace, blank local/domain parts, and a prefix containing `@`. Validate the domain through `Uri.CheckHostName` as DNS and a constructed destination. Require a nonempty UPN parsed as an address, Boolean keep-copy, and integer TTL >= 0. Do not use Exchange to validate syntax.

```powershell
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$config = [pscustomobject]@{ ForwardingDomain = 'archive.example.com'; ServiceAccountUPN = 'admin@example.com';
    DeliverToMailboxAndForward = $true; CacheTtlHours = 24 }
Assert (@(Test-ForwardingConfig -Config $config).Count -eq 0) 'Valid config rejected.'
$config.CacheTtlHours = -1
Assert (@(Test-ForwardingConfig -Config $config).Count -gt 0) 'Negative TTL accepted.'
$config.CacheTtlHours = 0
Assert (@(Test-ForwardingConfig -Config $config).Count -eq 0) 'Zero TTL must disable cache reuse.'
Assert (-not (Test-ForwardingDestination -Address "alice`n@example.com")) 'Control character accepted.'
Assert (-not (Test-ForwardingDestination -Address '')) 'Blank destination could clear forwarding.'
```

- [ ] Extend model checks for all three filters, case-insensitive wildcard search, empty/singleton collections, Toggle advancing cursor, canceled/invalid edits preserving original values, and domain recalculation preserving prefix/keep-copy/selection. For refresh, use a matching record with changed current fields plus an extra record; assert matching fields update, drafts survive, and membership remains unchanged. Assert TTL zero never reuses cache and invalid/missing config returns setup-required status.

- [ ] Run `MailboxModel.Tests.ps1`, `Config.Tests.ps1`, and `MailboxLoading.Tests.ps1` under available runtimes. Expected: all assertions pass with no network. Suggested authorized commit: `refactor: separate mailbox model and validation`.

## Task 3: Make forwarding operations return truthful results

**Files:** Create `src/50-forwarding.ps1`, `tests/Forwarding.Tests.ps1`; modify `tests/ApplyCounts.Tests.ps1` and root's temporary WinForms apply handler.

**Interfaces:** `New-ForwardingPreview -Rows [array]` emits copies of row fields plus `Action` (`Set`, `Overwrite`, `Skip`). `Set-MailboxForwards -Rows [array] -OnProgress [scriptblock]` returns one object with `Records` array, `Applied`, `Skipped`, `Errors` integers, `LogPath` string, and `PersistenceErrors` string array. Records retain current CSV schema. No MessageBox or terminal drawing inside backend. Caller updates visible current-forward values only for `Result = OK` records.

- [ ] Add direct action tests with fake `Set-Mailbox`; run `pwsh -NoProfile -File ./tests/Forwarding.Tests.ps1` before extraction and verify failure. Use a temporary directory for config/cache/audit and remove only that directory in `finally`.

```powershell
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$script:Calls = @()
function Set-Mailbox {
    [CmdletBinding()]
    param($Identity, $ForwardingSmtpAddress, [bool]$DeliverToMailboxAndForward)
    $script:Calls += $Identity
    if ($Identity -eq 'bad@example.com') { throw 'Denied' }
}
$rows = @('ok','skip','bad') | ForEach-Object {
    [pscustomobject]@{ Selected = $true; PrimarySmtpAddress = "$_@example.com";
        CurrentForwarding = 'old@example.net'; HasOnPremForwarding = ($_ -eq 'skip');
        DeliverAndStore = $true; ForwardingPrefix = $_; WillForwardTo = "$_@archive.example.com" }
}
$snapshot = @(New-ForwardingPreview -Rows @($rows))
$rows[0].WillForwardTo = 'changed@example.net'
Assert ($snapshot[0].WillForwardTo -eq 'ok@archive.example.com') 'Preview must snapshot proposals.'
$originalDir = $script:ScriptDir
$originalCache = $script:CachePath
$temporary = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
[void][IO.Directory]::CreateDirectory($temporary)
try {
    $script:ScriptDir = $temporary
    $script:CachePath = Join-Path $temporary 'cache.json'
    $result = Set-MailboxForwards -Rows $snapshot
    Assert ($result.Applied -eq 1 -and $result.Skipped -eq 1 -and $result.Errors -eq 1) 'Mixed counts incorrect.'
    Assert ($script:Calls.Count -eq 2 -and $script:Calls -notcontains 'skip@example.com') 'On-prem row reached Exchange.'
    Assert (@(Import-Csv $result.LogPath).Count -eq 3) 'Audit record missing.'
} finally {
    $script:ScriptDir = $originalDir
    $script:CachePath = $originalCache
    Remove-Item $temporary -Recurse -Force
}
```

- [ ] Move Apply from root lines 318-385. Preserve per-mailbox try/catch and `-ErrorAction Stop`, but remove MessageBox and return the result object. Validate all actionable destinations before the first remote write. Skip on-prem rows even if their draft destination is invalid. Empty input returns zero counts without a CSV or Exchange call. Treat `HasOnPremForwarding` as Boolean, never the string `'no'`.

```powershell
[pscustomobject]@{
    Records = @($log.ToArray())
    Applied = @($log | Where-Object Result -eq 'OK').Count
    Skipped = @($log | Where-Object Result -eq 'Skipped').Count
    Errors = @($log | Where-Object Result -eq 'Error').Count
    LogPath = $logPath
    PersistenceErrors = @($persistenceErrors.ToArray())
}
```

- [ ] Attempt CSV output before cache update, with separate terminating-error catches. Preserve existing columns and UTF-8. If `changelog-yyyyMMdd-HHmmss.csv` exists, choose a numeric suffix and use `Export-Csv -NoClobber -ErrorAction Stop`; never overwrite an existing audit. Do not report remote successes as Exchange failures when persistence fails. Keep records available in the result report. Update cache only from successful records.

- [ ] Replace the root's temporary post-Apply loop at lines 547-550 so it matches result records by mailbox and updates only `OK`. Its MessageBox consumes result counts until Task 6 removes WinForms. Rewrite `ApplyCounts.Tests.ps1` to call the real function with zero/single OK/single skip/single error cases instead of parsing source expressions.

- [ ] Add assertions for exact Set-Mailbox destination/keep-copy parameters, unchanged failed/skipped cache entries, snapshot independence, blank-target rejection before any write, audit collision, cache-save failure still attempting CSV, CSV failure still returning remote outcomes, and progress completion after failure. Use function stubs for persistence failures rather than relying on OS permissions.

- [ ] Run `Forwarding.Tests.ps1`, `ApplyCounts.Tests.ps1`, and `MailboxLoading.Tests.ps1` on supported runtimes. Expected: result counts and persisted values reflect actual successful calls. Suggested authorized commit: `refactor: return audited forwarding results`.

## Task 4: Build console lifecycle and resize-aware views

**Files:** Create `src/10-console.ps1`, `src/70-views.ps1`, `tests/Tui.Tests.ps1`; extend `src/00-state.ps1`.

**Interfaces:** `Enter-Tui`, `Exit-Tui`, `Invoke-OnMainBuffer -Action [scriptblock]`, `Get-ConsoleSize` returning `[width,height]`, `ConvertTo-DisplayText -Text [string] -Width [int]` returning sanitized padded/truncated text, `Get-MailboxFrame -State [hashtable] -Width [int] -Height [int]` returning a frame string, `Get-PreviewFrame -Rows [array] -Offset [int] -Width [int] -Height [int]` returning `{ Frame; LineCount }`, and `Show-Tui` running the idle render/input loop. `Show-Tui` invokes `Invoke-TuiKey` from Task 5 at runtime; loading it before Task 5 has no side effects.

- [ ] Write geometry/display checks before implementation. Run `pwsh -NoProfile -File ./tests/Tui.Tests.ps1`; expect missing-function failure.

```powershell
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$esc = [string][char]27
$safe = ConvertTo-DisplayText -Text ("alice" + $esc + '[2J' + "`t@example.com") -Width 18
Assert ($safe.Length -eq 18) 'Cell width mismatch.'
Assert ($safe.IndexOf([char]27) -lt 0 -and $safe.IndexOf([char]9) -lt 0) 'Untrusted terminal controls escaped sanitization.'
$state = @{ Items = @(); View = @(); Cursor = 0; Scroll = 0; Search = ''; Filter = 'All';
    Status = ''; Account = ''; CacheFetchedAt = $null; Height = 20 }
$frame = Get-MailboxFrame -State $state -Width 79 -Height 19
Assert ($frame -match '80.*20') 'Undersized terminal needs resize guidance.'
$frame = Get-MailboxFrame -State $state -Width 80 -Height 20
Assert ($frame -match '0') 'Empty table must render counts without indexing a row.'
```

- [ ] Adapt SOA's `10-console-vt.ps1` and required drawing helpers only. Rename native type to avoid `SoaTui` collision. Check `GetConsoleMode`/`SetConsoleMode` Boolean results; reject unsupported host/redirected streams before changing state. Save native mode, encoding, cursor visibility, and Ctrl+C state before changes. Set ownership flags early enough that partial initialization can restore state. Restore in reverse order, idempotently, and preserve original errors.

```powershell
try {
    Enter-Tui
    while ($script:UI.Running) {
        $size = Get-ConsoleSize
        if ($size[0] -ne $script:UI.Width -or $size[1] -ne $script:UI.Height) {
            $script:UI.Width = $size[0]; $script:UI.Height = $size[1]
            $script:UI.Dirty = $true
        }
        if ($script:UI.Dirty) {
            [Console]::Write((Get-MailboxFrame -State $script:UI -Width $size[0] -Height $size[1]))
            $script:UI.Dirty = $false
        }
        if ([Console]::KeyAvailable) { Invoke-TuiKey -Key ([Console]::ReadKey($true)) }
        else { Start-Sleep -Milliseconds 25 }
    }
} finally { Exit-Tui }
```

- [ ] Use a single StringBuilder frame, absolute cursor positioning, row clearing, and no trailing newline at the bottom-right cell. Reserve two header rows, one column heading, and one footer; use `height - 4` table capacity consistently in model scrolling and PageUp/PageDown. Keep three address columns flexible and flags compact. Sanitize remote/config/error text before adding ANSI styles; never sanitize stored addresses used for writes.

- [ ] Preview renders wrapped labeled records with old/proposed destination, keep-copy, and explicit `Overwrite`/`Skip` text. `LineCount` describes the complete wrapped body so the dialog can scroll to the end. Full addresses must be recoverable from wrapped text, not irreversibly truncated. Add ASCII theme selection and `?` help labels without requiring Unicode source literals.

- [ ] Extend checks across 80x20, 120x30, 180x50, empty/singleton/large views, resize down/up, long addresses, and control-character strings. Assert cursor remains in view, footer remains at the last row, frame coordinates stay in bounds, and underlying model text is unchanged. Mock `Enter-Tui`/`Exit-Tui` around `Invoke-OnMainBuffer` and a throwing action to verify restoration is attempted on exceptions; reserve actual console state assertions for Task 7's terminal check.

- [ ] Run `Tui.Tests.ps1` and all model tests. Expected: deterministic frames and no console/network requirement for tests. Suggested authorized commit: `feat: add resize-aware terminal views`.

## Task 5: Add editing, navigation, preview, and confirmation

**Files:** Create `src/20-dialogs.ps1`, `src/80-input.ps1`; extend `tests/Tui.Tests.ps1`, `tests/Config.Tests.ps1`; rename temporary legacy dialog functions/call sites in root to avoid overriding new source functions before cutover.

**Interfaces:** `Invoke-TuiKey -Key [ConsoleKeyInfo]` acts on `$script:UI`. `Show-SettingsDialog -Config` returns a validated new config or `$null`; `Show-MailboxDialog -Row -Domain` returns `{ Prefix; DeliverAndStore }` or `$null`. `Show-PreviewDialog -Rows` returns Boolean only after explicit Y/N choice. `Show-ReportDialog -Title -Lines [string[]]` has no result. `Show-OperationProgress -Progress [hashtable]` draws progress only. These consume model/backend/frame functions from Tasks 2-4.

- [ ] Extend TUI tests with real key dispatch before writing it. Stub modal functions at the test boundary, never the model. Confirm tests fail first.

```powershell
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$config = [pscustomobject]@{ ForwardingDomain = 'archive.example.com'; DeliverToMailboxAndForward = $true }
$raw = @('alice','bob') | ForEach-Object {
    [pscustomobject]@{ PrimarySmtpAddress = "$_@example.com"; ForwardingSmtpAddress = '';
        DeliverToMailboxAndForward = $false; HasOnPremForwardingAddress = $false }
}
$items = @(New-MailboxRows -Mailboxes @($raw) -Config $config)
$script:UI.Items = $items
$script:UI.View = $items
$script:UI.Cursor = 0
$script:UI.Scroll = 0
$script:UI.Width = 120
$script:UI.Height = 30
$script:UI.Searching = $false
$items[0].Selected = $false
$space = [ConsoleKeyInfo]::new([char]' ', [ConsoleKey]::Spacebar, $false, $false, $false)
Invoke-TuiKey -Key $space
Assert $items[0].Selected 'Space must select cursor row.'
Assert ($script:UI.Cursor -eq 1) 'Space must advance cursor.'
$script:ApplyCalls = 0
function Set-MailboxForwards { $script:ApplyCalls++ }
function Show-MailboxDialog { return $null }
$enter = [ConsoleKeyInfo]::new([char]13, [ConsoleKey]::Enter, $false, $false, $false)
Invoke-TuiKey -Key $enter
Assert ($script:ApplyCalls -eq 0) 'Enter on main table must never apply.'
```

- [ ] Adapt SOA's message/input/report modal loops without spinner/runspace helpers. Add multi-field settings and mailbox editors using copied draft values. Tab/Shift+Tab changes fields, Space toggles a focused Boolean, Enter on Save validates and commits the draft, Escape/Ctrl+C cancels. Recompute widths/wrapping on resize. Show validation errors in the dialog without mutating original config/row.

- [ ] Rename root's temporary dialogs to `Show-LegacySettingsDialog` and `Show-LegacyPreviewDialog`, updating only legacy call sites. Remove these functions in Task 6. This prevents root definitions from shadowing the newly loaded TUI dialogs while keeping the intermediate WinForms checkpoint operational.

- [ ] Implement main key mapping from the spec, search input capture, minimum-size guard, and model calls. Use one switch and existing helpers; no command registry. Settings Save writes config before replacing `$script:Config`, recalculates proposals, and preserves per-row keep-copy edits. Refresh buffers the result before `Merge-MailboxRefresh`; on exceptions retain state/cache and show details.

- [ ] Connect preview using copied records and explicit Y/N confirmation. Drain queued keys when opening preview and after busy operations. Enter must not confirm. Permit scrolling before confirmation, show every selected row including hidden ones, and disable preview when selection is empty.

```powershell
$selected = @($script:UI.Items | Where-Object Selected)
if ($selected.Count -gt 0) {
    $preview = @(New-ForwardingPreview -Rows $selected)
    if (Show-PreviewDialog -Rows $preview) {
        $result = Set-MailboxForwards -Rows $preview -OnProgress { param($p) Show-OperationProgress -Progress $p }
        foreach ($record in @($result.Records | Where-Object Result -eq 'OK')) {
            foreach ($row in $script:UI.Items) {
                if ($row.PrimarySmtpAddress -eq $record.Mailbox) {
                    $row.CurrentForwarding = $record.NewForwardingSmtpAddress
                }
            }
        }
        Update-MailboxView -State $script:UI
        $lines = @("Applied: $($result.Applied)  Skipped: $($result.Skipped)  Errors: $($result.Errors)", "Log: $($result.LogPath)")
        $lines += @($result.Records | ForEach-Object { "$($_.Mailbox): $($_.Result) $($_.Error)" })
        $lines += @($result.PersistenceErrors)
        Show-ReportDialog -Title 'Apply results' -Lines $lines
    }
}
```

- [ ] Test canceled preview produces zero calls, hidden selections reach preview, search letters do not trigger commands, empty views tolerate every navigation key, canceled editors preserve data, invalid drafts cannot reach Apply, and success-only model updates survive filters. Feed scripted keys to modal loops by stubbing their key-reading function if needed; keep that helper confined to `20-dialogs.ps1` rather than adding a general input abstraction.

- [ ] Run `Tui.Tests.ps1`, `Config.Tests.ps1`, `MailboxModel.Tests.ps1`, and `Forwarding.Tests.ps1`. Expected: no production mutation path bypasses preview. Suggested authorized commit: `feat: add terminal mailbox editing and preview flow`.

## Task 6: Switch startup to TUI and remove WinForms

**Files:** Modify root script, `src/40-exchange.ps1`, `src/00-state.ps1`, launcher, CI, README, CONTRIBUTING, CHANGELOG; delete `tests/GridFiltering.Tests.ps1` after preserving its behavior checks in model tests.

**Interfaces:** Root adds `-Ascii` and initializes `$script:StartupOptions` with all switches. `Get-MailboxList` gains optional `-OnProgress [scriptblock]`, preserving no-callback behavior. `Connect-Exo` uses normal-buffer auth, captured root identity, and owned-connection tracking. `Show-Tui` becomes the only interactive UI loop. `-SelfTest` does not enter the alternate buffer.

- [ ] Add a source guard to `Tui.Tests.ps1`, then run it and confirm remaining WinForms references cause failure.

```powershell
$paths = @($script:EntryScriptPath) + @(Get-ChildItem (Join-Path $script:ScriptDir 'src') -Filter '*.ps1' | Select-Object -ExpandProperty FullName)
foreach ($path in $paths) {
    Assert ((Get-Content $path -Raw) -notmatch 'Windows\.Forms|System\.Drawing|Show-MainForm|BindingList|DataGridView') "Legacy GUI reference: $path"
}
```

- [ ] Replace root WinForms startup with host validation, config setup, module installation, authentication, mailbox load/model initialization, and `Show-Tui`. Missing config in normal mode opens the TUI settings dialog; missing config in `-SelfTest` produces clear setup instructions and nonzero exit. All module installation/authentication runs on the normal buffer. No new noninteractive mutation mode.

- [ ] Preserve launcher `-Sta`, `-NoProfile`, argument forwarding, and pause behavior. Forward `-Ascii` with `-SelfTest`/`-DisableWAM` on relaunch. Ensure STA/WAM fallback always targets root, not `src/40-exchange.ps1`. Keep existing Windows PowerShell fallback executable behavior and document that a fallback from PowerShell 7 can restart under Windows PowerShell 5.1. Restore terminal before invoking a child and before any `exit` path.

- [ ] Add optional progress delivery without emitting progress objects into mailbox/result pipelines. During TUI fetch display initial busy state and count at 100-record boundaries; keep console tests unchanged without callback. Drain queued input after completion. No worker or animated-spinner code.

```powershell
$progress = @{ Activity = 'Exchange Online'; Status = $status; Count = $count; Total = $null; Completed = $false }
if ($OnProgress) { & $OnProgress $progress | Out-Null }
else {
    Write-Host $status
    Write-Progress -Activity 'Exchange Online' -Status $status
}
```

- [ ] Add cleanup in root `finally`: restore console first, then best-effort disconnect only an app-opened EXO connection. Print original fatal diagnostics and pause on the normal buffer. Connection reuse must not mark a borrowed connection as app-owned. Guard Windows-specific APIs; unsupported platforms receive an explicit unsupported-runtime message while offline source tests remain usable.

- [ ] Remove all WinForms functions, assembly loads, and legacy UI tests. Update README keys, setup, terminal/runtime requirements, blocking-operation limitation, hidden selection semantics, preview, artifact paths, and unchanged `-SelfTest` network behavior. Replace CONTRIBUTING's GUI instructions with source map and test commands. Add unreleased changelog entry without tagging a release.

- [ ] Run all `*.Tests.ps1` scripts, root/source parse checks, and analyzer. Expected: no WinForms runtime references, no source-load side effects, no regressions in backend tests. Suggested authorized commit: `feat: replace WinForms startup with PowerShell TUI`.

## Task 7: Verify supported runtimes, terminal behavior, and package

**Files:** Create `tests/Start-TuiFixture.ps1`; finish `.github/workflows/ci.yml`, `.github/workflows/release.yml`, and testing documentation. No production feature added.

**Interfaces:** Fixture loads `TestSupport.ps1`, supplies at least 100 fake mailbox records with long addresses, existing forwards, on-prem flags, and one stubbed write failure. Overrides connection/module/query/write boundaries before starting `Show-Tui`; uses a test-owned temporary artifact directory. Root application is not invoked from fixture. Every exit removes only fixture artifacts and restores terminal.

- [ ] Build the fixture with existing model functions and stubbed `Set-Mailbox`/`Get-MailboxList`/`Connect-Exo`/`Install-ExoModule`; ensure no path can call real EXO commands. Display `OFFLINE FIXTURE` in status. Do not add a public `-Demo` switch or ship fixture scripts in release ZIP.

```powershell
function Connect-Exo { }
function Install-ExoModule { }
function Set-Mailbox {
    [CmdletBinding()]
    param($Identity, $ForwardingSmtpAddress, [bool]$DeliverToMailboxAndForward)
    if ($Identity -eq 'user2@example.com') { throw 'Fixture write failure' }
}
```

- [ ] Finalize CI with Windows `powershell` and Windows `pwsh` execution, plus existing Linux PowerShell offline coverage. Parse/lint all root/source files and execute each `tests/*.Tests.ps1` in a fresh process so stubs cannot leak between suites. Never execute `Start-TuiFixture.ps1` in headless CI.

```powershell
$paths = @('./MailboxForwardingTool.ps1') + @(Get-ChildItem ./src -Filter '*.ps1' | Select-Object -ExpandProperty FullName)
foreach ($path in $paths) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $path).Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Parse errors in ${path}: $errors" }
    $issues = @(Invoke-ScriptAnalyzer -Path $path -Settings ./PSScriptAnalyzerSettings.psd1 -Severity Error,Warning)
    if ($issues.Count) { $issues | Format-Table; throw "Analyzer findings in $path" }
}
$engine = (Get-Process -Id $PID).Path
foreach ($test in (Get-ChildItem ./tests -Filter '*.Tests.ps1' | Sort-Object Name)) {
    & $engine -NoProfile -File $test.FullName
    if ($LASTEXITCODE -ne 0) { throw "Failed: $($test.Name)" }
}
```

- [ ] In Windows Terminal run fixture under both runtimes. Exercise resize 80x20 -> 120x30 -> below minimum -> restored; search, hidden selections, select-visible, clear-all, prefix/keep-copy editing, canceled preview, confirmed mixed results, scrollable long addresses, and quit. Repeat with `-Ascii` support in fixture parameter handling. Compare behavior and theme against SOA, without copying its unused tabs.

- [ ] Force an operation exception and exit via Ctrl+C while idle; verify original buffer, cursor visibility, Ctrl+C setting, output encoding, and native console mode are restored. Confirm normal-buffer actions remain visible, Enter never applies, and queued keys during a fake slow operation cannot confirm preview afterward.

- [ ] Build the release ZIP locally without publishing. Extract into a temporary directory outside the checkout; verify every runtime source exists and source loading works there without access to the original checkout. Assert archive excludes config/cache/audit files and test fixture. Verify launcher resolves source/config paths from a directory containing spaces.

- [ ] With explicit tenant authorization, separately run `-SelfTest`, normal WAM sign-in, `-DisableWAM`, cache reuse/force refresh, and a small previewed Apply against test mailboxes. Verify remote forwarding and generated audit against results, including skipped and failed records. Do not claim live validation if access is unavailable.

- [ ] Review diff against every spec section and record exact checks run plus unavailable Windows/terminal/tenant checks. Suggested authorized commit: `test: cover TUI runtime and release packaging`.

## Completion criteria

- Root launcher opens the TUI, not WinForms, on both supported Windows PowerShell runtimes.
- Terminal dimensions drive layout; selected records survive filtering and editing, full addresses remain inspectable, and normal-buffer state is restored on exit.
- Only explicit confirmation of a complete preview can invoke forwarding writes.
- Failed/skipped writes do not appear as successful in model/cache; audit and persistence errors remain distinguishable from Exchange outcomes.
- Source files have clear boundaries and can be loaded offline without startup effects.
- Release ZIP contains all runtime sources; docs and CI match the segmented TUI application.
- Verification report distinguishes automated offline checks, real-terminal checks, and authorized live Exchange checks.

## Limitations

Sequential Exchange calls remain blocking. Full refresh membership reconciliation, tenant-keyed cache, cross-platform runtime support, undo, shared TUI packaging, and persistent operational logs are outside this plan. Existing cache requires clearing before changing tenants. No automated test can guarantee audit persistence after process termination or disk failure.
