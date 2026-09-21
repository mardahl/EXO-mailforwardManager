# TUI modal action menus and highlighting - design

Date: 2026-09-21
Scope: `src/00-state.ps1`, `src/20-dialogs.ps1`, `src/70-views.ps1`, `src/80-input.ps1`, `tests/Tui.Tests.ps1`, `README.md`

## Problem

The main table exposes every action as a single-letter hotkey listed in a
one-line footer (12 keys). Popups (Settings, Edit forwarding, Help) are drawn
as plain text on a cleared screen; the focused field is indicated only by a
trailing `_` and the Save button by `> Save <`. Selected rows, warnings,
keep-copy flags and pending changes in the table carry no color. Operators
report the interaction model as unfamiliar and unclear about where input is
currently going.

## Goals

1. Operator can discover and run every action from a popup menu instead of
   memorizing hotkeys. Hotkeys remain as shortcuts.
2. Every popup renders as a bordered box over a dimmed copy of the main table,
   so it reads as a modal.
3. Exactly one element on screen is visually "focused" at any time, using one
   consistent highlight style across table, menus and field editors.
4. Table cells carry semantic color (selected, pending change, keep-copy,
   warning).
5. No new dependencies; ASCII fallback (`-Ascii`) still renders correctly;
   80x20 floor and all existing safety rules (explicit `Y` to apply, no commit
   below floor, ESC stripping of untrusted text) unchanged.

## Non-goals

Mouse support, bulk-clear forwarding, undo, user-configurable themes, changing
the apply/preview semantics.

## 1. Color system (`src/00-state.ps1`)

Semantic meaning of colors, applied everywhere:

| Meaning | Color | Token(s) |
|---|---|---|
| Where input goes now (focus) | white on deep blue | `FocusBg`, `CursorFg` |
| What is selected | bright cyan | `Selected`, `SelectedCursor`, `SelMark` |
| Press this key | bold yellow | `HotKey` |
| Will change on apply | amber | `Proposed` |
| Destructive / error | red | `Danger`, `BorderDanger`, `WarnFlag` |
| Kept / success | green | `Good`, `KeepOn` |
| Inactive / background | gray | `RowDim`, `Backdrop`, `Muted` |

New `$script:T` entries (256-color SGR; `$e` = ESC):

```powershell
FocusBg        = "$e[1;38;5;231;48;5;25m"   # focused field / menu bar
Button         = "$e[38;5;250;48;5;238m"    # idle button
ButtonHot      = "$e[1;38;5;16;48;5;45m"    # focused button
Border         = "$e[38;5;45m"              # popup border + title
BorderDanger   = "$e[1;38;5;196m"
Backdrop       = "$e[38;5;240m"             # dimmed table behind popup
Selected       = "$e[38;5;51;48;5;235m"     # selected row, not cursor
SelectedCursor = "$e[1;38;5;231;48;5;31m"   # selected row under cursor
Proposed       = "$e[38;5;214m"             # proposed != current
KeepOn         = "$e[38;5;42m"
WarnFlag       = "$e[1;38;5;196;48;5;52m"
HotKey         = "$e[1;38;5;220m"
```

Existing tokens are kept. `$script:G` gains box corners:
`TL TR BL BR` = `0x250C 0x2510 0x2514 0x2518`, ASCII fallback `+`.

## 2. Popup frame (`src/20-dialogs.ps1`)

### Backdrop

New `Get-BackdropFrame`: renders `Get-MailboxFrame` for the current state and
size, strips every SGR sequence (`\x1b\[[0-9;]*m`) from the result, and
prefixes each line with `$T.Backdrop`. `Write-DialogFrame` writes this instead
of `ESC[2J`, then draws the box on top. Result: table visible in gray behind
the popup. `Show-PreviewDialog` stays full-screen (it needs the whole width for
addresses) and keeps `ESC[2J`.

### Box

`Write-DialogFrame` draws:

```
┌─ Title ──────────────────────────────┐
│  body line                           │
│  body line                           │
│ Tab next  Space toggle  Esc cancel   │
└──────────────────────────────────────┘
```

- Border and title: `Border` (or `BorderDanger` when `-Danger`).
- Box height = body + 3 (top, footer, bottom); `Get-DialogBox` updated so
  `BodyCapacity` and centering account for the extra row.
- Footer hint: single letters / key names before a space are rendered
  `HotKey`, the rest `FootTxt`. Implemented by one helper
  `Format-KeyHint -Text` that colors tokens matching
  `^(Tab|Space|Enter|Esc|PgUp/PgDn|Up/Dn|Up/Down|Y|N|[A-Z?/])$`.

### Styled body lines

`-BodyLines` accepts strings (rendered `Row`) or hashtables
`@{ Text = '...'; Style = 'Focus' | 'Button' | 'ButtonHot' | 'Dim' | 'Danger' | 'Row' }`.
`Style='Focus'` paints the full inner width with `FocusBg`. Text is still
passed through `ConvertTo-DisplayText` before the style prefix is added, so
untrusted text cannot inject escapes.

Settings and Edit forwarding dialogs:

- Focused text field: line style `Focus`; trailing `_` kept as caret.
- Focused checkbox: style `Focus`.
- Save: `Button` when not focused, `ButtonHot` when focused; label `[ Save ]`.
- Error line: style `Danger`.
- Logic (Tab order, validation, Esc, floor check) unchanged.

## 3. Action menus

### `Show-MenuDialog`

```powershell
Show-MenuDialog -Title <string> -Items <array> [-Danger]
```

`Items` entries:

- `@{ Key = 'E'; Label = 'Edit forwarding...'; Action = 'Edit'; Disabled = $false }`
- `@{ Sep = $true }` renders a `Border`-colored horizontal rule.

Rendering: ` E  Edit forwarding...` with `Key` in `HotKey`; highlighted item
style `Focus`; disabled items `Dim` and skipped by cursor movement.
Keys: Up/Down move (wrap, skipping separators/disabled); Enter returns the
highlighted `Action`; pressing an item's `Key` (case-insensitive) returns its
`Action` immediately unless disabled; Esc / Ctrl+C return `$null`. Reads input
via `Read-DialogKey`, clears queue on open.

### Row menu - `Enter` on a table row

Title: the mailbox primary SMTP address (truncated via `ConvertTo-DisplayText`).

| Key | Label | Action |
|---|---|---|
| S | Select / Deselect | toggles `Selected` on the row (no cursor advance) |
| E | Edit forwarding... | opens `Show-MailboxDialog` (existing) |
| K | Toggle keep-copy | flips `DeliverAndStore` via `Set-MailboxDraft` on the real row |
| - | separator | |
| P | Preview & apply selected (n) | `Invoke-TuiApply`; disabled when n = 0 |

### Global menu - `M` on the table

Title: `Actions`.

| Key | Label | Action |
|---|---|---|
| A | Select all visible | existing `Set-MailboxSelection -Mode All` |
| N | Clear selection | existing `-Mode None` |
| F | Filter: <current> (cycle) | existing filter cycle |
| / | Search | enters search mode |
| - | separator | |
| P | Preview & apply selected (n) | `Invoke-TuiApply`; disabled when n = 0 |
| R | Refresh mailboxes | existing refresh |
| S | Settings... | existing |
| ? | Help | existing |
| Q | Quit | sets `Running = $false` |

`Enter` with an empty view opens the global menu instead of the row menu.

### Hotkeys and footer

All existing table hotkeys keep working. New footer:

```
 Enter Actions  M Menu  Space Sel  / Search  P Preview  ? Help  Q Quit  <status>
```

rendered through `Format-KeyHint`.

### Preview dialog coloring

`Show-PreviewDialog` footer: `Y apply` in `Good`, `N/Esc cancel` in `Danger`.
`Get-PreviewFrame` action tags: `[Set]` `Good`, `[Overwrite]` `Proposed`,
`[Skip]` `RowDim`.

## 4. Table coloring (`src/70-views.ps1`)

Per row in `Get-MailboxFrame`, each cell is sanitized/padded individually with
`ConvertTo-DisplayText`, then color prefixes are concatenated (sanitizer runs
first, so colors survive and text cannot inject escapes).

Row base style:

| Cursor | Selected | Style |
|---|---|---|
| no | no | `Row` |
| no | yes | `Selected` |
| yes | no | `CursorFg` |
| yes | yes | `SelectedCursor` |

Cell overrides (foreground-only SGR, so the base background remains):

- Checkbox: `SelMark` when selected.
- Proposed forwarding: `Proposed` when `WillForwardTo` is non-empty and
  differs from `CurrentForwarding`.
- Keep: `KeepOn` when `Yes`, `RowDim` when `No`.
- Warn: `WarnFlag` when `Y`.

After every cell the base style is re-emitted so overrides do not leak into the
next cell. Header row 2: `Selected: n (...)` fragment in `SelMark` when n > 0.

## 5. Input wiring (`src/80-input.ps1`)

- `Enter` -> `Invoke-TuiRowMenu` (builds items, calls `Show-MenuDialog`,
  dispatches action, sets `Dirty`).
- `M` -> `Invoke-TuiGlobalMenu`.
- Menu actions reuse the existing handlers; no duplicated logic. Refactor the
  existing `switch` bodies for A/N/F/R/S/P/?/Q into small functions or a
  single `Invoke-TuiAction -Name` so both hotkeys and menus call the same code.

## 6. Error handling

- Menus and dialogs read keys only through `Read-DialogKey`; Ctrl+C anywhere
  returns `$null` and leaves state untouched.
- Actions that write (Preview/apply, Save) keep the `Test-TuiBelowFloor` guard.
- Backdrop rendering failures (for example `Get-MailboxFrame` returning the
  "Terminal too small" frame) are acceptable: the popup is still drawn on top.

## 7. Testing (`tests/Tui.Tests.ps1`, existing assertion-script style)

- `Show-MenuDialog`: Down+Enter returns second action; hotkey letter returns
  matching action; lowercase hotkey works; Esc returns `$null`; disabled item
  skipped by cursor and ignored by hotkey; Up from first wraps to last
  selectable.
- `Enter` on a row opens the row menu; choosing `Edit` calls the stubbed
  `Show-MailboxDialog`; choosing `S` toggles selection without moving cursor.
- `M` opens the global menu; `Q` action sets `Running = $false`.
- `Get-MailboxFrame`: selected row contains `Selected` SGR; row with
  `HasOnPremForwarding` contains `WarnFlag`; row with proposed != current
  contains `Proposed`; cell text containing ESC/control chars is still stripped.
- `Get-BackdropFrame`: output contains no SGR other than `Backdrop` and `Reset`.
- `Write-DialogFrame` with `-Ascii`: corners are `+`, no characters above
  0x7F.
- All existing tests pass unchanged except footer-text assertions, which are
  updated to the new footer.

## 8. Documentation

`README.md`: update the main-screen mock and key list for `Enter Actions` /
`M Menu`, add one paragraph on the color legend.

## Known issues / limitations

- Backdrop is a re-render of the table, not a true alpha overlay; on very slow
  terminals popups repaint the whole screen on each keystroke (same cost as
  the current `ESC[2J` approach plus one table render).
- Colors assume a 256-color terminal, as the existing theme already does. No
  16-color fallback.
- Row menu `K Toggle keep-copy` edits the row directly without the Edit dialog;
  validation still runs through `Set-MailboxDraft`.
