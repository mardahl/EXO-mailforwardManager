# PowerShell TUI migration design

Status: design approved for implementation planning; implementation not started.

## Goal

Replace WinForms with a full-terminal PowerShell interface modeled on SOAconverter. Use available terminal space for mailbox data and split the monolithic script into focused, numbered source files.

This design supersedes the WinForms and single-file requirements in the September 7 design for this migration. Forwarding rules and persisted data remain applicable.

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

## Approach

Adapt SOAconverter's console lifecycle, drawing, keyboard navigation, and modal patterns into local source files. Keep the forwarding-specific data model and Exchange queries. Do not extract a shared library or copy Graph, SOA conversion, rollback, or multi-object tab infrastructure.

Reference implementation:

- `../SOAconverter/SOA-Manager.ps1`: sorted source loading and dirty-screen event loop.
- `../SOAconverter/src/00-globals.ps1`: theme, glyphs, and separate item/view/cursor state.
- `../SOAconverter/src/10-console-vt.ps1`: alternate buffer, VT setup, console restoration, and normal-buffer operations.
- `../SOAconverter/src/15-drawing.ps1`: width-aware text and frame construction.
- `../SOAconverter/src/20-modals.ps1`: input, confirmation, scrolling reports, and progress presentation.
- `../SOAconverter/src/65-views.ps1`: dynamic geometry and resize handling.
- `../SOAconverter/src/75-key-dispatch.ps1`: navigation, search, and selection conventions.

These are implementation references, not dependencies. Verify terminal setup return values and cleanup behavior rather than copying unchecked assumptions.

## Screen and interaction

Use one mailbox workspace with no permanent sidebar or tab strip. Reserve two compact header rows, one column-header row, and one footer row. Remaining `height - 4` rows display mailbox records.

Header content: connection state, actual authenticated account when available, forwarding domain, cache age, visible/total count, and selected/hidden-selected count. The configured service-account UPN is an authentication hint, not proof of the authenticated identity. At narrow widths, shorten account/domain text before hiding counts; full values remain available in settings/details.

Table columns: selection, mailbox, current forwarding, proposed forwarding, keep-copy, warning. Selection and compact flags use fixed widths; three address columns share remaining width. Distinguish cursor highlight from selection. Preserve SOA's theme and expose `-Ascii` for glyph fallback without adding a library.

Terminal resizing recalculates columns, visible rows, cursor, and scroll bounds. Below 80x20, display a resize message and allow quit; suppress edit/apply commands. Truncated cells are display-only. Details and preview wrap full values with scrolling; Exchange and CSV output always use original values.

| Key | Action |
| --- | --- |
| Up/Down, PageUp/PageDown, Home/End | Move cursor and keep it visible |
| Space | Toggle selected row and advance, following SOA behavior |
| A | Select all rows in current filtered view |
| N | Clear all selections, including hidden rows |
| / | Enter live mailbox-address search |
| F | Cycle All, Has forward, No forward |
| Enter | Open highlighted mailbox details/editor |
| R | Force refresh |
| S | Open settings |
| P | Preview all selected mailboxes |
| ? | Show help |
| Q or Ctrl+C | Exit while idle |

Search uses existing case-insensitive PowerShell wildcard matching on primary SMTP address. Enter retains the search; Escape clears it. While text entry is active, ordinary letters are text, not global shortcuts. Escape cancels dialogs without mutation. Settings and row edits use draft values and explicit Save.

Mailbox editor shows the full mailbox, current forwarding, proposed destination, on-prem warning, editable forwarding prefix, and keep-copy toggle. Prefix and domain must produce a nonempty SMTP destination; blank prefix is not a clear-forward command. Reject control characters and malformed input before saving or applying. Settings retain the four existing fields. TTL must parse as a nonnegative integer; zero explicitly disables cache reuse. Changing the domain recalculates proposals without resetting selection, prefixes, or per-row keep-copy edits. Changing the keep-copy default affects subsequently created rows, not existing edits.

## Source structure

| File | Responsibility |
| --- | --- |
| `MailboxForwardingTool.ps1` | Parameters, root path capture, source loading, STA bootstrap, main loop, cleanup |
| `src/00-state.ps1` | Paths derived from root, theme, console state, full mailbox collection and current view |
| `src/10-console.ps1` | VT setup, screen lifecycle, terminal size, text sanitization, padding and drawing helpers |
| `src/20-dialogs.ps1` | Message, input, settings, mailbox editor, confirmation, report, and progress dialogs |
| `src/30-config-cache.ps1` | Config/cache reads, validation, writes, freshness |
| `src/40-exchange.ps1` | Module bootstrap, authentication, mailbox query and mapping |
| `src/50-forwarding.ps1` | Preview records, sequential Apply, audit output, successful state updates |
| `src/60-mailbox-model.ps1` | Row creation, filtered view, selection, edits, successful refresh merge |
| `src/70-views.ps1` | Main table and forwarding-preview rendering |
| `src/80-input.ps1` | Keyboard dispatch and orchestration of model, dialogs, and operations |

Source files define functions or initialize local app state only. Dot-sourcing must not install modules, authenticate, enter the terminal, or start the application. Tests can load source files directly without AST extraction. No `.psm1` package, dependency container, event bus, or plugin layer.

Rendering reads state and returns a frame; input dispatch changes state. Exchange functions return data and report progress through an optional callback. No Exchange calls inside rendering functions.

## Data flow

1. Capture root script path and directory before source loading. Store the root entry point explicitly for STA/WAM relaunch; `$PSCommandPath` inside a moved source function is not the root entry point.
2. Load source files, validate the interactive host for normal TUI startup, and initialize configuration.
3. Install/import ExchangeOnlineManagement and authenticate on the normal console buffer. Preserve no-UPN login-hint behavior, PageSize 100, and fresh-process `-DisableWAM` fallback. Forward supported switches on relaunch.
4. Reuse a fresh cache or fetch the complete user-mailbox list. Publish/cache results only after successful enumeration. Empty successful results are an explicit array; failures preserve previous data.
5. Build model rows, then derive a filtered view referencing the same objects. Cursor and scroll belong to the view; selection and edits belong to full records.
6. A successful refresh updates current forwarding/on-prem flags on existing matching records without replacing edited fields. Preserve the current refresh membership behavior: existing rows remain; newly discovered or removed mailboxes are reflected after restart. Do not silently redefine refresh membership during UI migration.
7. Preview snapshots all selected rows into plain records. On-prem skips and overwrites have text labels as well as color. Display old destination, exact proposed destination, and keep-copy choice.
8. Apply requires an explicit confirmation from preview: `Y` confirms, `N`/Escape cancels. Enter alone does not apply. No editable state changes between preview and execution.
9. Apply processes snapshot records sequentially, skipping on-prem rows and continuing after individual Exchange failures. Return structured results. Update current forwarding in the model/cache only for `OK` records.
10. Show applied/skipped/error counts, per-mailbox error details, audit path, and any persistence failures in a scrollable report. Return to the table with selection retained.

## Progress, errors, and cleanup

Display a busy frame before a blocking call. Fetch totals remain unknown until enumeration completes; update retrieved count and elapsed time at existing 100-record boundaries. Apply displays item number and counts between requests. Route host/progress text to TUI presentation while active; keep console progress for `-SelfTest`. Do not animate a fake spinner or advertise responsive cancellation while Exchange blocks.

Drain buffered operation keystrokes before returning to normal input or confirmation. Require new input after preview opens, so queued keys cannot confirm changes accidentally.

Failed refresh retains rows and cache. Failed/skipped Apply records retain their current forwarding values. Successful remote writes remain successful even if local cache/audit persistence fails; report that distinction and retain results for inspection. Attempt audit output before cache persistence so a cache-write failure cannot prevent the audit attempt. Prevent a second Apply from overwriting an existing changelog file; retain the `changelog-*.csv` naming family and existing columns.

Wrap terminal ownership in `try/finally`. Restore normal buffer, cursor visibility, encoding, Ctrl+C behavior, and changed Windows console mode on normal exit, initialization failure, or exception. Disconnect only an EXO connection opened by this application; do not tear down a pre-existing operator connection. Cleanup failure must not hide the original error. Installation, sign-in, fatal diagnostics, and launcher pause occur on the normal buffer.

Interactive mode rejects redirected input/output and unsupported terminal hosts before installing modules or authenticating. `-SelfTest` remains a live read-only connectivity/enumeration check, not an offline TUI test; with missing/invalid config it reports setup instructions instead of waiting for terminal input.

## Verification and delivery

- Retain loading cases at 0, 1, 99, 100, 101, 200, and 250 records, failure before results and after 100, cache reuse, progress cleanup, and both authentication parameter paths.
- Replace WinForms-specific filtering tests with direct model/input checks for selection, hidden counts, filtered editing, empty lists, and singleton counts.
- Test actual Apply behavior with stubbed `Set-Mailbox`, including success, skip, failure, audit rows, success-only state updates, and persistence errors.
- Test frames and key dispatch offline with supplied dimensions. Include 80x20, larger terminals, undersized terminals, long addresses, and control characters in display data.
- Run parse, analyzer, and offline tests over root and source files on Windows PowerShell 5.1 and PowerShell 7 on Windows. Keep Linux PowerShell offline checks without claiming Linux runtime support.
- Manually verify a real terminal's resize, dialogs, cleanup, normal-buffer sign-in, and launcher behavior. Use fixture-backed test startup without adding a public demo feature.
- Validate authentication, `-SelfTest`, and a small confirmed Apply in an explicitly authorized test tenant before release. Offline tests do not prove EXO authentication or terminal-host behavior.
- Package the entire `src/` directory and update README, contributor guidance, changelog, and CI in the migration.

## Limitations and deferred work

- macOS/Linux operation is outside the supported runtime scope.
- Sequential Exchange calls can block repaint and key handling; responsive cancellation would require a separate design for connection-bound execution.
- No undo, bulk clear, CSV selection import, Graph integration, shared TUI package, or persistent log subsystem is added.
- Existing cache is not tenant-keyed. The migration retains that format; changing signed-in tenants requires clearing cache and restarting before selecting targets.
- Refresh preserves existing row membership, matching current behavior. Full membership reconciliation is separate work.
- Cache and CSV contain mailbox addresses; existing local file handling and security guidance still apply.
- An interrupted process or disk failure can prevent audit persistence after remote writes. Reports must never imply rollback or full audit durability.
