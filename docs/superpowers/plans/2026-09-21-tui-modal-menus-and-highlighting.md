# TUI Modal Menus and Highlighting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the PowerShell TUI popup action menus (Enter on a row, M for global), bordered popups drawn over a dimmed table, one consistent focus highlight, and semantic table colors.

**Architecture:** All popups go through `Write-DialogFrame` (src/20-dialogs.ps1), which gains a backdrop, a border and styled body lines. A new `Show-MenuDialog` renders a list of hotkeyed actions with the same frame. `src/80-input.ps1` routes both hotkeys and menu picks through one `Invoke-TuiAction -Name` dispatcher. `Get-MailboxFrame` (src/70-views.ps1) colors cells after sanitizing them.

**Tech Stack:** PowerShell 7 / Windows PowerShell 5.1, raw ANSI SGR (256-color), `[Console]` key input. No modules beyond `ExchangeOnlineManagement` (untouched here). Tests are plain assertion scripts run with `pwsh -NoProfile -File tests/<File>.Tests.ps1`.

Spec: `docs/superpowers/specs/2026-09-21-tui-modal-menus-and-highlighting-design.md`

## Global Constraints

- Minimum terminal 80x20 (`$script:MinTuiWidth`/`$script:MinTuiHeight`); actions that write (Save, Y apply) stay refused below floor via `Test-TuiBelowFloor`.
- Untrusted text (addresses, config, errors) always passes through `ConvertTo-DisplayText` before any color prefix is added; never emit an ESC that originated in data.
- `-Ascii` mode (`$script:StartupOptions.Ascii`) must render with 7-bit characters only.
- Dialog input only through `Read-DialogKey`; every dialog calls `Clear-DialogKeyQueue` on open; Ctrl+C and Escape return `$null`/`$false`.
- Preview apply remains explicit `Y`; Enter never applies.
- Existing hotkeys on the main table keep working.
- All test files must pass: `Get-ChildItem ./tests -Filter *.Tests.ps1 | ForEach-Object { pwsh -NoProfile -File $_.FullName }`
- Test conventions (tests/Tui.Tests.ps1): `Test-Case 'name' { ... }`, `Assert $cond 'msg'`, key factory `New-Key ([char]13) Enter`, stub `function Read-DialogKey { $keys.Dequeue() }`, stub `function Clear-DialogKeyQueue { }`, capture output via `[Console]::SetOut($writer)`. `New-DispatchState [n]` sets up `$script:UI` with n rows at 120 wide and `$script:Config.ForwardingDomain = 'archive.example.com'`.
- New tests go into `tests/Tui.Tests.ps1` before the final `} finally {` block, after the section they relate to.
- Commit after each task; message prefix `feat:`/`test:`/`docs:` matching repo history.

---

### Task 1: Theme tokens and box glyphs

**Files:**
- Modify: `src/00-state.ps1:36-68`
- Test: `tests/Tui.Tests.ps1`

**Interfaces:**
- Produces: `$script:T.FocusBg, Button, ButtonHot, Border, BorderDanger, Backdrop, Selected, SelectedCursor, Proposed, KeepOn, WarnFlag, HotKey` (SGR strings); `$script:G.TL, TR, BL, BR` (box corners).

- [ ] **Step 1: Write failing test**

Append before `} finally {` in `tests/Tui.Tests.ps1`:

```powershell
# --- Theme tokens and glyphs --------------------------------------------------
Test-Case 'Theme exposes every semantic token used by menus, popups and table cells' {
    foreach ($k in 'FocusBg','Button','ButtonHot','Border','BorderDanger','Backdrop','Selected','SelectedCursor','Proposed','KeepOn','WarnFlag','HotKey') {
        Assert ($script:T.ContainsKey($k) -and $script:T[$k].StartsWith([string][char]27)) "Missing or non-SGR theme token: $k"
    }
    foreach ($k in 'TL','TR','BL','BR') {
        Assert ($script:G.ContainsKey($k) -and ([string]$script:G[$k]).Length -eq 1) "Missing box glyph: $k"
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -File tests/Tui.Tests.ps1`
Expected: throws with `Missing or non-SGR theme token: FocusBg`.

- [ ] **Step 3: Implement**

In `src/00-state.ps1`, replace the `$script:G` block (lines 36-45) with:

```powershell
if ($script:StartupOptions -and $script:StartupOptions.Ascii) {
    $script:G = @{
        H = '-'; V = '|'; Ell = '..'; ChkOn = '[x]'; ChkOff = '[ ]'; Arrow = '->'
        TL = '+'; TR = '+'; BL = '+'; BR = '+'
    }
} else {
    $script:G = @{
        H = ([char]0x2500); V = ([char]0x2502); Ell = ([char]0x2026)
        ChkOn = ('[' + [char]0x25A0 + ']'); ChkOff = '[ ]'; Arrow = ([char]0x2192)
        TL = ([char]0x250C); TR = ([char]0x2510); BL = ([char]0x2514); BR = ([char]0x2518)
    }
}
```

Append to the `$script:T` hashtable (before the closing `}` at line 68):

```powershell
    # Semantic tokens: blue = focus, cyan = selected, yellow = press this key,
    # amber = will change on apply, red = danger, green = kept, gray = inactive.
    FocusBg        = "$e[1;38;5;231;48;5;25m"
    Button         = "$e[38;5;250;48;5;238m"
    ButtonHot      = "$e[1;38;5;16;48;5;45m"
    Border         = "$e[38;5;45m"
    BorderDanger   = "$e[1;38;5;196m"
    Backdrop       = "$e[38;5;240m"
    Selected       = "$e[38;5;51;48;5;235m"
    SelectedCursor = "$e[1;38;5;231;48;5;31m"
    Proposed       = "$e[38;5;214m"
    KeepOn         = "$e[38;5;42m"
    WarnFlag       = "$e[1;38;5;196;48;5;52m"
    HotKey         = "$e[1;38;5;220m"
```

- [ ] **Step 4: Run tests**

Run: `pwsh -NoProfile -File tests/Tui.Tests.ps1`
Expected: `TUI console/view checks passed ...`

- [ ] **Step 5: Commit**

```bash
git add src/00-state.ps1 tests/Tui.Tests.ps1
git commit -m "feat: add semantic theme tokens and box-corner glyphs"
```

---

### Task 2: Bordered popup frame over dimmed backdrop

**Files:**
- Modify: `src/20-dialogs.ps1:21-81` (`Get-DialogBox`, `Write-DialogFrame`), add `Format-KeyHint`, `Get-BackdropFrame`, `Get-StyledLine`
- Test: `tests/Tui.Tests.ps1`

**Interfaces:**
- Consumes: Task 1 tokens/glyphs; `Get-MailboxFrame -State -Width -Height` (src/70-views.ps1); `$script:UI`.
- Produces:
  - `Format-KeyHint -Text <string>` -> string with key tokens wrapped in `$T.HotKey` and remaining text in `$T.FootTxt`.
  - `Get-BackdropFrame` -> string: main table frame, all SGR stripped, every line prefixed `$T.Backdrop`.
  - `Write-DialogFrame -Title -BodyLines <object[]> [-FooterHint] [-Danger]` where each body line is a `string` or `@{ Text=<string>; Style='Row'|'Focus'|'Button'|'ButtonHot'|'Dim'|'Danger' }`. Returns box hashtable (unchanged keys).
  - `Get-DialogBox -BodyHeight -MinWidth` box height now `bodyH + 3` (top border/title, body, footer, bottom border -> footer row is `Y + 1 + BodyCapacity`, bottom border `Y + 2 + BodyCapacity`).

- [ ] **Step 1: Write failing tests**

```powershell
# --- Popup frame: border, backdrop, styled lines, key hints -------------------
function Capture-Console([scriptblock]$Action) {
    $writer = New-Object System.IO.StringWriter
    $prev = [Console]::Out
    [Console]::SetOut($writer)
    try { & $Action } finally { [Console]::SetOut($prev) }
    $writer.ToString()
}

Test-Case 'Format-KeyHint colors key tokens and leaves labels in footer text color' {
    $out = Format-KeyHint -Text 'Tab next  Esc cancel  Y apply'
    Assert ($out.Contains($script:T.HotKey + 'Tab')) 'Tab must be a hotkey token.'
    Assert ($out.Contains($script:T.HotKey + 'Esc')) 'Esc must be a hotkey token.'
    Assert ($out.Contains($script:T.HotKey + 'Y')) 'Single capital letters are hotkey tokens.'
    Assert ($out.Contains($script:T.FootTxt + 'next')) 'Labels stay in FootTxt.'
}

Test-Case 'Get-BackdropFrame renders the table with only the Backdrop style' {
    $items = New-DispatchState 3
    $items[0].Selected = $true
    function Get-ConsoleSize { return @(100, 24) }
    $frame = Get-BackdropFrame
    $sgr = [regex]::Matches($frame, "$([char]27)\[[0-9;]*m") | ForEach-Object { $_.Value } | Sort-Object -Unique
    foreach ($s in $sgr) {
        Assert ($s -eq $script:T.Backdrop -or $s -eq $script:T.Reset) "Backdrop leaked style: $s"
    }
    Assert ($frame.Contains('user0@example.com')) 'Backdrop must still show table content.'
}

Test-Case 'Write-DialogFrame draws a bordered box with title, styled body and hint over the backdrop' {
    New-DispatchState 2 | Out-Null
    function Get-ConsoleSize { return @(100, 24) }
    $out = Capture-Console {
        Write-DialogFrame -Title 'Demo' -BodyLines @('plain', @{ Text = 'focused'; Style = 'Focus' }, @{ Text = '[ Save ]'; Style = 'ButtonHot' }) -FooterHint 'Esc cancel' | Out-Null
    }
    Assert (-not $out.Contains("$([char]27)[2J")) 'Popup must not clear the screen; it draws over the backdrop.'
    Assert ($out.Contains($script:T.Backdrop)) 'Backdrop must be drawn.'
    Assert ($out.Contains($script:T.Border + [string]$script:G.TL)) 'Top-left corner must be in Border color.'
    Assert ($out.Contains(' Demo ')) 'Title must be in the top border.'
    Assert ($out.Contains($script:T.FocusBg)) 'Focus style must be emitted for the focused line.'
    Assert ($out.Contains($script:T.ButtonHot)) 'ButtonHot style must be emitted.'
    Assert ($out.Contains($script:T.HotKey + 'Esc')) 'Footer hint must go through Format-KeyHint.'
    Assert ($out.Contains([string]$script:G.BR)) 'Bottom-right corner must be drawn.'
}

Test-Case 'Write-DialogFrame -Danger uses the danger border and styled text is sanitized' {
    New-DispatchState 1 | Out-Null
    function Get-ConsoleSize { return @(100, 24) }
    $esc = [string][char]27
    $out = Capture-Console {
        Write-DialogFrame -Title 'Bad' -BodyLines @(@{ Text = ("x" + $esc + "[31mINJECT"); Style = 'Focus' }) -Danger | Out-Null
    }
    Assert ($out.Contains($script:T.BorderDanger + [string]$script:G.TL)) 'Danger popups use BorderDanger.'
    Assert (-not $out.Contains($esc + '[31m')) 'Body text must be sanitized before styling.'
}
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -File tests/Tui.Tests.ps1`
Expected: failures mentioning `Format-KeyHint` / `Get-BackdropFrame` not recognized.

- [ ] **Step 3: Implement**

In `src/20-dialogs.ps1`, replace `Get-DialogBox` line 28 `$boxH = $bodyH + 4` with `$boxH = $bodyH + 3` and `$maxBodyCap = [Math]::Max(1, $h - 6)` with `$maxBodyCap = [Math]::Max(1, $h - 5)`.

Insert after `Get-DialogScrollOffset` (before `Write-DialogFrame`):

```powershell
function Format-KeyHint {
    # Colors key tokens (Tab, Esc, Y, single capitals, ...) in HotKey and the
    # remaining words in FootTxt so the operator can spot "press this" at a
    # glance. Input is trusted static hint text, not user data.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $t = $script:T
    $sb = New-Object System.Text.StringBuilder
    foreach ($tok in ($Text -split '(\s+)')) {
        if ($tok -match '^\s+$' -or $tok -eq '') { [void]$sb.Append($t.FootTxt + $tok); continue }
        if ($tok -match '^(Tab|Space|Enter|Esc|PgUp/PgDn|Up/Dn|Up/Down|Up/Down/PgUp/PgDn|Y|N|N/Esc|Enter/Esc|M|[A-Z?/])$') {
            [void]$sb.Append($t.HotKey + $tok)
        } else {
            [void]$sb.Append($t.FootTxt + $tok)
        }
    }
    return $sb.ToString()
}

function Get-BackdropFrame {
    # The main table, re-rendered for the current size with every SGR
    # stripped and repainted in Backdrop gray. Popups draw on top of this so
    # the operator still sees the list they were working in.
    $size = Get-ConsoleSize
    $frame = Get-MailboxFrame -State $script:UI -Width $size[0] -Height $size[1]
    $plain = [regex]::Replace($frame, "$script:ESC\[[0-9;]*m", '')
    # Every line starts with the absolute cursor move ESC[row;1H; put the
    # backdrop color right after it so the whole row is dimmed.
    return [regex]::Replace($plain, "($script:ESC\[\d+;1H)", ('$1' + $script:T.Backdrop))
}

function Get-StyledLine {
    # Resolve a body line (string or @{Text;Style}) to (style, text). Text is
    # sanitized by the caller via ConvertTo-DisplayText *before* the style is
    # prefixed, so this only maps names to SGR strings.
    param([Parameter(Mandatory)][AllowNull()]$Line)
    $t = $script:T
    if ($Line -is [hashtable]) {
        $style = switch ([string]$Line.Style) {
            'Focus'     { $t.FocusBg }
            'Button'    { $t.Button }
            'ButtonHot' { $t.ButtonHot }
            'Dim'       { $t.RowDim }
            'Danger'    { $t.Danger }
            default     { $t.Row }
        }
        return @($style, [string]$Line.Text)
    }
    return @($t.Row, [string]$Line)
}
```

Replace `Write-DialogFrame` (lines 58-81) with:

```powershell
function Write-DialogFrame {
    # Draws a bordered, titled box over the dimmed main table. Body lines are
    # strings or @{ Text; Style } hashtables (see Get-StyledLine). Recomputes
    # geometry from the current console size on every call, so a resize
    # between keystrokes is picked up on the next repaint.
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][object[]]$BodyLines,
        [string]$FooterHint = '',
        [switch]$Danger
    )
    $t = $script:T; $g = $script:G
    $box = Get-DialogBox -BodyHeight $BodyLines.Count
    $border = if ($Danger) { $t.BorderDanger } else { $t.Border }
    $innerW = $box.W - 2
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append((Get-BackdropFrame))

    $titleText = ConvertTo-DisplayText -Text " $Title " -Width ([Math]::Min($innerW - 2, $Title.Length + 2))
    $topFill = [string]$g.H * [Math]::Max(0, $innerW - 1 - $titleText.Length)
    Add-BoxLine -Sb $sb -Row $box.Y -Col $box.X -Content ($border + [string]$g.TL + [string]$g.H + $titleText + $topFill + [string]$g.TR)

    for ($i = 0; $i -lt $box.BodyCapacity; $i++) {
        $pair = if ($i -lt $BodyLines.Count) { Get-StyledLine -Line $BodyLines[$i] } else { @($t.Row, '') }
        $cell = ConvertTo-DisplayText -Text ("  " + $pair[1]) -Width $innerW
        Add-BoxLine -Sb $sb -Row ($box.Y + 1 + $i) -Col $box.X -Content ($border + [string]$g.V + $pair[0] + $cell + $t.Reset + $border + [string]$g.V)
    }
    $hint = ConvertTo-DisplayText -Text " $FooterHint" -Width $innerW
    Add-BoxLine -Sb $sb -Row ($box.Y + 1 + $box.BodyCapacity) -Col $box.X -Content ($border + [string]$g.V + $t.FootBg + (Format-KeyHint -Text $hint) + $t.Reset + $border + [string]$g.V)
    Add-BoxLine -Sb $sb -Row ($box.Y + 2 + $box.BodyCapacity) -Col $box.X -Content ($border + [string]$g.BL + ([string]$g.H * $innerW) + [string]$g.BR)
    [Console]::Write($sb.ToString())
    return $box
}

function Add-BoxLine {
    # Like Add-FrameLine but positioned at a column and *not* clearing to end
    # of line, so the backdrop to the right of the box survives.
    param([System.Text.StringBuilder]$Sb, [int]$Row, [int]$Col, [string]$Content)
    [void]$Sb.Append("$script:ESC[$Row;${Col}H")
    [void]$Sb.Append($Content)
    [void]$Sb.Append($script:T.Reset)
}
```

Note: `Format-KeyHint` receives the already-padded hint, so background from `$t.FootBg` covers the full footer row; `FootTxt` already carries the footer background, `HotKey` does not - prefix `HotKey` tokens with `$t.FootBg` inside `Format-KeyHint`: change the hotkey branch to `[void]$sb.Append($t.FootBg + $t.HotKey + $tok)`. Update the Format-KeyHint test assertions to `Contains($script:T.HotKey + 'Tab')` still holds (FootBg precedes HotKey, HotKey immediately precedes token).

- [ ] **Step 4: Run tests**

Run: `pwsh -NoProfile -File tests/Tui.Tests.ps1`
Expected: pass. If existing Settings/Mailbox dialog tests assert on frame row positions of the footer (search for `BodyCapacity` or `+ 4` in tests), adjust to `+ 3` box height.

- [ ] **Step 5: Commit**

```bash
git add src/20-dialogs.ps1 tests/Tui.Tests.ps1
git commit -m "feat: draw popups as bordered boxes over a dimmed table backdrop"
```

---

### Task 3: Focus highlighting in Settings and Edit forwarding dialogs

**Files:**
- Modify: `src/20-dialogs.ps1` (`Show-SettingsDialog` lines 112-125, `Show-MailboxDialog` lines 229-244)
- Test: `tests/Tui.Tests.ps1`

**Interfaces:**
- Consumes: `Write-DialogFrame` styled body lines from Task 2.
- Produces: no new public API. Focused field line -> `Style='Focus'`; Save -> `Style='Button'`/`'ButtonHot'` with label `[ Save ]`; error -> `Style='Danger'`.

- [ ] **Step 1: Write failing tests**

```powershell
# --- Field-editor focus highlighting ------------------------------------------
Test-Case 'Show-MailboxDialog highlights the focused field and the Save button distinctly' {
    New-DispatchState 1 | Out-Null
    function Get-ConsoleSize { return @(100, 24) }
    $row = [pscustomobject]@{
        Selected = $false; PrimarySmtpAddress = 'bob@example.com'; CurrentForwarding = ''
        HasOnPremForwarding = $false; DeliverAndStore = $false
        ForwardingPrefix = 'bob'; WillForwardTo = 'bob@archive.example.com'
    }
    $keys = New-Object System.Collections.Generic.Queue[object]
    [void]$keys.Enqueue((New-Key ([char]9) Tab))
    [void]$keys.Enqueue((New-Key ([char]9) Tab))
    [void]$keys.Enqueue((New-Key ([char]27) Escape))
    function Read-DialogKey { $keys.Dequeue() }
    function Clear-DialogKeyQueue { }
    $out = Capture-Console { Show-MailboxDialog -Row $row -Domain 'archive.example.com' | Out-Null }
    $frames = $out -split [regex]::Escape($script:T.Border + [string]$script:G.TL)
    # frames[1] = first paint (focus Prefix), frames[3] = third paint (focus Save)
    Assert ($frames[1].Contains($script:T.FocusBg + '  Prefix:')) 'First paint must paint the Prefix line in FocusBg.'
    Assert ($frames[1].Contains($script:T.Button + '  [ Save ]')) 'Save is an idle Button when not focused.'
    Assert ($frames[3].Contains($script:T.ButtonHot + '  [ Save ]')) 'Save becomes ButtonHot when focused.'
    Assert (-not $frames[3].Contains($script:T.FocusBg + '  Prefix:')) 'Prefix loses focus style when Save is focused.'
}

Test-Case 'Show-SettingsDialog paints validation errors in Danger style' {
    New-DispatchState 1 | Out-Null
    function Get-ConsoleSize { return @(100, 24) }
    $cfg = [pscustomobject]@{ ForwardingDomain = 'invalid domain'; ServiceAccountUPN = 'svc@example.com'; CacheTtlHours = 24; DeliverToMailboxAndForward = $false }
    $keys = New-Object System.Collections.Generic.Queue[object]
    foreach ($i in 1..4) { [void]$keys.Enqueue((New-Key ([char]9) Tab)) }
    [void]$keys.Enqueue((New-Key ([char]13) Enter))
    [void]$keys.Enqueue((New-Key ([char]27) Escape))
    function Read-DialogKey { $keys.Dequeue() }
    function Clear-DialogKeyQueue { }
    $out = Capture-Console { Show-SettingsDialog -Config $cfg | Out-Null }
    Assert ($out.Contains($script:T.Danger + '  Error: ')) 'Error line must use Danger style.'
}
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -File tests/Tui.Tests.ps1`
Expected: fails on `First paint must paint the Prefix line in FocusBg.`

- [ ] **Step 3: Implement**

`Show-SettingsDialog`: change `$lines` to `System.Collections.Generic.List[object]` and build styled entries. Replace lines 112-125 with:

```powershell
        $lines = New-Object System.Collections.Generic.List[object]
        $fieldLine = @{}
        $fieldLine['ForwardingDomain'] = $lines.Count
        $chunks = @(Split-DisplayChunks -Text ('Forwarding domain:      ' + $draft.ForwardingDomain + $(if ($focus -eq 0) { '_' } else { '' })) -Width $wrapWidth)
        foreach ($chunk in $chunks) { [void]$lines.Add(@{ Text = $chunk; Style = $(if ($focus -eq 0) { 'Focus' } else { 'Row' }) }) }
        $fieldLine['ServiceAccountUPN'] = $lines.Count
        $chunks = @(Split-DisplayChunks -Text ('Service account UPN:    ' + $draft.ServiceAccountUPN + $(if ($focus -eq 1) { '_' } else { '' })) -Width $wrapWidth)
        foreach ($chunk in $chunks) { [void]$lines.Add(@{ Text = $chunk; Style = $(if ($focus -eq 1) { 'Focus' } else { 'Row' }) }) }
        $fieldLine['CacheTtlHours'] = $lines.Count
        [void]$lines.Add(@{ Text = ('Cache TTL (hours):      ' + $draft.CacheTtlHours + $(if ($focus -eq 2) { '_' } else { '' })); Style = $(if ($focus -eq 2) { 'Focus' } else { 'Row' }) })
        $fieldLine['DeliverToMailboxAndForward'] = $lines.Count
        [void]$lines.Add(@{ Text = ('Deliver to mbx+forward: ' + $(if ($draft.DeliverToMailboxAndForward) { '[x]' } else { '[ ]' })); Style = $(if ($focus -eq 3) { 'Focus' } else { 'Row' }) })
        [void]$lines.Add('')
        $fieldLine['Save'] = $lines.Count
        [void]$lines.Add(@{ Text = '[ Save ]'; Style = $(if ($focus -eq 4) { 'ButtonHot' } else { 'Button' }) })
        if ($errorText) { [void]$lines.Add(''); [void]$lines.Add(@{ Text = "Error: $errorText"; Style = 'Danger' }) }
```

`$visible = @($lines | Select-Object -Skip $offset -First $box.BodyCapacity)` stays (works on object list).

`Show-MailboxDialog`: replace lines 229-244 with:

```powershell
        $lines = New-Object System.Collections.Generic.List[object]
        $fieldLine = @{}
        foreach ($chunk in $mailboxWrapped) { [void]$lines.Add(@{ Text = $chunk; Style = 'Dim' }) }
        $currentFwd = if ([string]::IsNullOrEmpty($Row.CurrentForwarding)) { '(none)' } else { [string]$Row.CurrentForwarding }
        [void]$lines.Add("Current forwarding:     $currentFwd")
        $onPrem = if ($Row.HasOnPremForwarding) { 'yes' } else { 'no' }
        [void]$lines.Add(@{ Text = "On-prem forwarding:     $onPrem"; Style = $(if ($Row.HasOnPremForwarding) { 'Danger' } else { 'Row' }) })
        $fieldLine['Prefix'] = $lines.Count
        [void]$lines.Add(@{ Text = ('Prefix:                 ' + $prefix + $(if ($focus -eq 0) { '_' } else { '' })); Style = $(if ($focus -eq 0) { 'Focus' } else { 'Row' }) })
        foreach ($chunk in $wrapped) { [void]$lines.Add(@{ Text = ('  -> ' + $chunk); Style = 'Dim' }) }
        $fieldLine['DeliverAndStore'] = $lines.Count
        [void]$lines.Add(@{ Text = ('Deliver to mbx+forward: ' + $(if ($deliver) { '[x]' } else { '[ ]' })); Style = $(if ($focus -eq 1) { 'Focus' } else { 'Row' }) })
        [void]$lines.Add('')
        $fieldLine['Save'] = $lines.Count
        [void]$lines.Add(@{ Text = '[ Save ]'; Style = $(if ($focus -eq 2) { 'ButtonHot' } else { 'Button' }) })
        if ($errorText) { [void]$lines.Add(''); [void]$lines.Add(@{ Text = "Error: $errorText"; Style = 'Danger' }) }
```

Existing tests that regex the captured frame for literal text such as `'Forwarding domain:      invalid domain'` or `'> Save <'` : the text is unchanged except Save. Search tests for `> Save <` and replace with `[ Save ]`.

- [ ] **Step 4: Run tests**

Run: `pwsh -NoProfile -File tests/Tui.Tests.ps1`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add src/20-dialogs.ps1 tests/Tui.Tests.ps1
git commit -m "feat: highlight focused field and Save button in editor dialogs"
```

---

### Task 4: Show-MenuDialog

**Files:**
- Modify: `src/20-dialogs.ps1` (append after `Show-ReportDialog`)
- Test: `tests/Tui.Tests.ps1`

**Interfaces:**
- Consumes: `Write-DialogFrame`, `Read-DialogKey`, `Clear-DialogKeyQueue`, `Format-KeyHint`.
- Produces: `Show-MenuDialog -Title <string> -Items <array> [-Danger]` -> `[string]` Action or `$null`. Item shape: `@{ Key='E'; Label='Edit forwarding...'; Action='Edit'; Disabled=$false }` or `@{ Sep=$true }`.

- [ ] **Step 1: Write failing tests**

```powershell
# --- Show-MenuDialog -----------------------------------------------------------
function New-MenuItems {
    @(
        @{ Key = 'S'; Label = 'Select / Deselect'; Action = 'ToggleSelect' },
        @{ Key = 'E'; Label = 'Edit forwarding...'; Action = 'Edit' },
        @{ Sep = $true },
        @{ Key = 'P'; Label = 'Preview & apply selected (0)'; Action = 'Apply'; Disabled = $true }
    )
}
function Invoke-Menu([object[]]$KeyList) {
    New-DispatchState 1 | Out-Null
    function Get-ConsoleSize { return @(100, 24) }
    $keys = New-Object System.Collections.Generic.Queue[object]
    foreach ($k in $KeyList) { [void]$keys.Enqueue($k) }
    function Read-DialogKey { $keys.Dequeue() }
    function Clear-DialogKeyQueue { }
    Show-MenuDialog -Title 'Test' -Items (New-MenuItems)
}

Test-Case 'Show-MenuDialog Enter returns the highlighted action' {
    $r = Invoke-Menu @((New-Key ([char]13) Enter))
    Assert ($r -eq 'ToggleSelect') "Expected ToggleSelect, got '$r'."
}
Test-Case 'Show-MenuDialog Down then Enter returns the second action' {
    $r = Invoke-Menu @((New-Key ([char]0) DownArrow), (New-Key ([char]13) Enter))
    Assert ($r -eq 'Edit') "Expected Edit, got '$r'."
}
Test-Case 'Show-MenuDialog hotkey letter (either case) returns immediately' {
    Assert ((Invoke-Menu @((New-Key 'e' E))) -eq 'Edit') 'lowercase e must pick Edit.'
    Assert ((Invoke-Menu @((New-Key 'E' E))) -eq 'Edit') 'uppercase E must pick Edit.'
}
Test-Case 'Show-MenuDialog Escape and Ctrl+C return $null' {
    Assert ($null -eq (Invoke-Menu @((New-Key ([char]27) Escape)))) 'Escape must return $null.'
    Assert ($null -eq (Invoke-Menu @((New-Key ([char]3) C -Control)))) 'Ctrl+C must return $null.'
}
Test-Case 'Show-MenuDialog skips separators and disabled items; Down wraps; disabled hotkey ignored' {
    # Down from Edit skips Sep and disabled Apply, wraps to first.
    $r = Invoke-Menu @((New-Key ([char]0) DownArrow), (New-Key ([char]0) DownArrow), (New-Key ([char]13) Enter))
    Assert ($r -eq 'ToggleSelect') "Down past the end must wrap to the first enabled item, got '$r'."
    $r = Invoke-Menu @((New-Key ([char]0) UpArrow), (New-Key ([char]13) Enter))
    Assert ($r -eq 'Edit') "Up from first must wrap to last enabled item, got '$r'."
    $r = Invoke-Menu @((New-Key 'p' P), (New-Key ([char]27) Escape))
    Assert ($null -eq $r) 'Hotkey of a disabled item must be ignored.'
}
Test-Case 'Show-MenuDialog paints the highlighted item in Focus and hotkeys in HotKey' {
    $out = Capture-Console { Invoke-Menu @((New-Key ([char]27) Escape)) | Out-Null }
    Assert ($out.Contains($script:T.FocusBg)) 'Highlighted item must use FocusBg.'
    Assert ($out.Contains($script:T.HotKey + 'E')) 'Item hotkeys must be painted in HotKey.'
    Assert ($out.Contains($script:T.RowDim)) 'Disabled item must be dimmed.'
}
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -File tests/Tui.Tests.ps1`
Expected: `Show-MenuDialog` not recognized.

- [ ] **Step 3: Implement**

Append to `src/20-dialogs.ps1`:

```powershell
function Show-MenuDialog {
    # Vertical action menu: Up/Down move the highlight (wrapping, skipping
    # separators and disabled items), Enter returns the highlighted item's
    # Action, an item's Key returns its Action immediately, Esc/Ctrl+C return
    # $null. Item: @{ Key; Label; Action; Disabled } or @{ Sep = $true }.
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][array]$Items,
        [switch]$Danger
    )
    $selectable = @(0..($Items.Count - 1) | Where-Object { -not $Items[$_].Sep -and -not $Items[$_].Disabled })
    if ($selectable.Count -eq 0) { return $null }
    $pos = 0  # index into $selectable
    Clear-DialogKeyQueue
    while ($true) {
        $lines = New-Object System.Collections.Generic.List[object]
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $it = $Items[$i]
            if ($it.Sep) { [void]$lines.Add(@{ Text = ([string]$script:G.H * 30); Style = 'Dim' }); continue }
            $label = "$($it.Key)  $($it.Label)"
            $style = if ($i -eq $selectable[$pos]) { 'Focus' } elseif ($it.Disabled) { 'Dim' } else { 'Row' }
            [void]$lines.Add(@{ Text = $label; Style = $style; HotKey = [string]$it.Key })
        }
        [void](Write-DialogFrame -Title $Title -BodyLines $lines.ToArray() -FooterHint 'Up/Dn move  Enter pick  Esc close' -Danger:$Danger)

        $key = Read-DialogKey
        if (($key.Modifiers -band [ConsoleModifiers]::Control) -and $key.Key -eq 'C') { return $null }
        switch ($key.Key) {
            'Escape'    { return $null }
            'Enter'     { return [string]$Items[$selectable[$pos]].Action }
            'UpArrow'   { $pos = ($pos - 1 + $selectable.Count) % $selectable.Count; continue }
            'DownArrow' { $pos = ($pos + 1) % $selectable.Count; continue }
        }
        if ($key.KeyChar) {
            $ch = [string][char]::ToUpper($key.KeyChar)
            foreach ($idx in $selectable) {
                if ([string]$Items[$idx].Key -eq $ch) { return [string]$Items[$idx].Action }
            }
        }
    }
}
```

Make `Get-StyledLine`/`Write-DialogFrame` honor the optional `HotKey` field so the first character is painted `HotKey`: in `Write-DialogFrame`'s body loop, after computing `$cell`, add:

```powershell
        if ($BodyLines[$i] -is [hashtable] -and $BodyLines[$i].HotKey) {
            $hk = [string]$BodyLines[$i].HotKey
            # $cell = "  " + hotkey + rest; recolor the hotkey char only.
            $cell = $cell.Substring(0, 2) + $t.HotKey + $hk + $pair[0] + $cell.Substring(2 + $hk.Length)
        }
```

Guard `$i -lt $BodyLines.Count` around that block (the padding rows have no source line).

- [ ] **Step 4: Run tests**

Run: `pwsh -NoProfile -File tests/Tui.Tests.ps1`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add src/20-dialogs.ps1 tests/Tui.Tests.ps1
git commit -m "feat: add Show-MenuDialog hotkeyed action menu"
```

---

### Task 5: Semantic table coloring and new footer

**Files:**
- Modify: `src/70-views.ps1:54-96` (`Get-MailboxFrame` header row 2, table rows, footer)
- Test: `tests/Tui.Tests.ps1`

**Interfaces:**
- Consumes: Task 1 tokens; `Format-KeyHint` (Task 2).
- Produces: footer text `' Enter Actions  M Menu  Space Sel  / Search  P Preview  ? Help  Q Quit  '` + status.

- [ ] **Step 1: Write failing tests**

```powershell
# --- Semantic table coloring ---------------------------------------------------
Test-Case 'Get-MailboxFrame colors selected rows, proposed changes, keep-copy and warnings' {
    $rows = New-Rows 4
    $rows[0].Selected = $true
    $rows[1].CurrentForwarding = 'old@x.com'; $rows[1].WillForwardTo = 'new@x.com'
    $rows[2].DeliverAndStore = $true
    $rows[3].HasOnPremForwarding = $true
    $state = New-State $rows -Capacity 16
    $state.Cursor = 3
    $frame = Get-MailboxFrame -State $state -Width 100 -Height 20
    $lines = $frame -split [regex]::Escape("$([char]27)[")
    $r0 = ($lines | Where-Object { $_.Contains('user0@example.com') }) -join ''
    $r1 = ($lines | Where-Object { $_.Contains('user1@example.com') }) -join ''
    Assert ($frame.Contains($script:T.Selected + ' ')) 'Selected non-cursor row must use Selected style.'
    Assert ($frame.Contains($script:T.SelMark)) 'Selected checkbox must use SelMark.'
    Assert ($frame.Contains($script:T.Proposed + 'new@x.com')) 'Proposed != current must be amber.'
    Assert ($frame.Contains($script:T.KeepOn + 'Yes')) 'Keep=Yes must be green.'
    Assert ($frame.Contains($script:T.RowDim + 'No')) 'Keep=No must be dim.'
    Assert ($frame.Contains($script:T.WarnFlag + 'Y')) 'Warn=Y must use WarnFlag.'
    Assert ($frame.Contains($script:T.CursorFg)) 'Cursor row (unselected) keeps CursorFg.'
}
Test-Case 'Get-MailboxFrame uses SelectedCursor when the cursor sits on a selected row' {
    $rows = New-Rows 2; $rows[0].Selected = $true
    $state = New-State $rows -Capacity 16
    $frame = Get-MailboxFrame -State $state -Width 100 -Height 20
    Assert ($frame.Contains($script:T.SelectedCursor)) 'Selected row under cursor must use SelectedCursor.'
}
Test-Case 'Get-MailboxFrame strips control characters from cells even with coloring' {
    $rows = New-Rows 1
    $rows[0].WillForwardTo = "evil$([char]27)[31m@x.com"; $rows[0].CurrentForwarding = 'a@x.com'
    $state = New-State $rows -Capacity 16
    $frame = Get-MailboxFrame -State $state -Width 100 -Height 20
    Assert (-not $frame.Contains("$([char]27)[31m")) 'Cell text must be sanitized before color is applied.'
}
Test-Case 'Get-MailboxFrame footer advertises Enter Actions and M Menu with hotkey coloring' {
    $state = New-State (New-Rows 1) -Capacity 16
    $frame = Get-MailboxFrame -State $state -Width 100 -Height 20
    Assert ($frame.Contains($script:T.HotKey + 'Enter')) 'Footer Enter must be a hotkey token.'
    Assert ($frame.Contains('Actions') -and $frame.Contains('Menu')) 'Footer must mention Actions and Menu.'
    Assert (-not $frame.Contains('Enter Edit')) 'Old footer text must be gone.'
}
Test-Case 'Get-MailboxFrame header highlights the selected count when non-zero' {
    $rows = New-Rows 2; $rows[1].Selected = $true
    $state = New-State $rows -Capacity 16
    $frame = Get-MailboxFrame -State $state -Width 100 -Height 20
    Assert ($frame.Contains($script:T.SelMark + 'Selected: 1')) 'Selected count must be highlighted.'
}
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -File tests/Tui.Tests.ps1`
Expected: fails on `Selected non-cursor row must use Selected style.`

- [ ] **Step 3: Implement**

In `Get-MailboxFrame`, replace row 2 (lines 56-57) with:

```powershell
    $selStyle = if ($counts.Total -gt 0) { $t.SelMark } else { $t.HeaderTxt }
    $h2a = ConvertTo-DisplayText -Text " Visible: $visible/$total  " -Width (" Visible: $visible/$total  ").Length
    $h2b = "Selected: $($counts.Total) ($($counts.Hidden) hidden)"
    $h2c = "  Search: '$($State.Search)'  Filter: $($State.Filter)"
    $rest = [Math]::Max(0, $Width - $h2a.Length - $h2b.Length)
    Add-FrameLine -Sb $sb -Row 2 -Content ($t.HeaderTxt + $h2a + $selStyle + $t.HeaderBg + $h2b + $t.HeaderTxt + (ConvertTo-DisplayText -Text $h2c -Width $rest))
```

(`$t.SelMark` sets bold+cyan fg; `$t.HeaderBg` after it keeps the header background.)

Replace the row loop body (lines 75-87) with:

```powershell
        if ($idx -lt $visible) {
            $item = $State.View[$idx]
            $isCur = ($idx -eq [int]$State.Cursor)
            $base = if ($isCur -and $item.Selected) { $t.SelectedCursor }
                    elseif ($isCur) { $t.CursorFg }
                    elseif ($item.Selected) { $t.Selected }
                    else { $t.Row }
            $selTxt  = ConvertTo-DisplayText -Text $(if ($item.Selected) { $script:G.ChkOn } else { $script:G.ChkOff }) -Width $layout.Sel
            $mbxTxt  = ConvertTo-DisplayText -Text ([string]$item.PrimarySmtpAddress) -Width $layout.Addr1
            $curTxt  = ConvertTo-DisplayText -Text ([string]$item.CurrentForwarding) -Width $layout.Addr2
            $newTxt  = ConvertTo-DisplayText -Text ([string]$item.WillForwardTo) -Width $layout.Addr3
            $keepTxt = ConvertTo-DisplayText -Text $(if ($item.DeliverAndStore) { 'Yes' } else { 'No' }) -Width $layout.Keep
            $warnTxt = ConvertTo-DisplayText -Text $(if ($item.HasOnPremForwarding) { 'Y' } else { '' }) -Width $layout.Warn
            # Cell overrides are foreground-only SGR so the row background
            # (cursor/selected) survives; $base is re-emitted after each cell.
            $selCol  = if ($item.Selected) { $t.SelMark } else { '' }
            $newCol  = if ($item.WillForwardTo -and ($item.WillForwardTo -ne $item.CurrentForwarding)) { $t.Proposed } else { '' }
            $keepCol = if ($item.DeliverAndStore) { $t.KeepOn } else { $t.RowDim }
            $warnCol = if ($item.HasOnPremForwarding) { $t.WarnFlag } else { '' }
            $line = $base + ' ' + $selCol + $selTxt + $base + ' ' + $mbxTxt + ' ' + $curTxt + ' ' +
                $newCol + $newTxt + $base + ' ' + $keepCol + $keepTxt + $base + ' ' + $warnCol + $warnTxt + $base
            Add-FrameLine -Sb $sb -Row $row -Content $line
        } else {
```

Note `$t.RowDim`/`$t.KeepOn`/`$t.Proposed`/`$t.SelMark` are fg-only; `$t.WarnFlag` sets its own bg intentionally (red badge).

Replace footer (lines 94-96) with:

```powershell
    $status = if ($State.Status) { [string]$State.Status } else { '' }
    $foot = ConvertTo-DisplayText -Text (' Enter Actions  M Menu  Space Sel  / Search  P Preview  ? Help  Q Quit  ' + $status) -Width $Width
    Add-FrameLine -Sb $sb -Row $Height -Content ($t.FootBg + (Format-KeyHint -Text $foot))
```

`Format-KeyHint` lives in `src/20-dialogs.ps1`, loaded before `70-views.ps1`; function resolution is at call time anyway.

- [ ] **Step 4: Run tests**

Run: `pwsh -NoProfile -File tests/Tui.Tests.ps1`
Expected: pass. Also run `pwsh -NoProfile -File tests/MailboxModel.Tests.ps1` (unchanged, sanity).

- [ ] **Step 5: Commit**

```bash
git add src/70-views.ps1 tests/Tui.Tests.ps1
git commit -m "feat: semantic cell colors and hotkey-colored footer in mailbox table"
```

---

### Task 6: Action dispatcher, row menu and global menu

**Files:**
- Modify: `src/80-input.ps1:136-206`
- Test: `tests/Tui.Tests.ps1:257-285` (update), new cases

**Interfaces:**
- Consumes: `Show-MenuDialog` (Task 4), `Show-MailboxDialog`, `Set-MailboxSelection -State -Mode Toggle|Visible|None`, `Set-MailboxDraft -Row -Prefix -DeliverAndStore -Domain`, `Invoke-TuiRefresh/Settings/Apply`.
- Produces:
  - `Invoke-TuiAction -Name <string>` handles: `ToggleSelect, Edit, ToggleKeep, SelectVisible, SelectNone, CycleFilter, Search, Apply, Refresh, Settings, Help, Quit`.
  - `Invoke-TuiRowMenu`, `Invoke-TuiGlobalMenu`.
  - `Enter` -> row menu (global menu when view empty); `M` -> global menu.

- [ ] **Step 1: Update existing Enter tests and add new tests**

Replace the three cases at `tests/Tui.Tests.ps1:257-285` with:

```powershell
Test-Case 'Space selects the cursor row and advances the cursor; Enter never applies' {
    $items = New-DispatchState
    $items[0].Selected = $false
    Invoke-TuiKey -Key (New-Key ' ' Spacebar)
    Assert $items[0].Selected 'Space must select the cursor row.'
    Assert ($script:UI.Cursor -eq 1) 'Space must advance the cursor.'

    $script:ApplyCalls = 0
    function Set-MailboxForwards { $script:ApplyCalls++ }
    function Show-MenuDialog { return $null }
    Invoke-TuiKey -Key (New-Key ([char]13) Enter)
    Assert ($script:ApplyCalls -eq 0) 'Enter on the main table must never apply.'
}

Test-Case 'Enter opens the row menu; Edit with a canceled editor preserves the row unchanged' {
    $items = New-DispatchState
    $before = $items[0].WillForwardTo
    $script:MenuTitle = ''
    function Show-MenuDialog { param($Title, $Items) $script:MenuTitle = $Title; return 'Edit' }
    function Show-MailboxDialog { return $null }
    Invoke-TuiKey -Key (New-Key ([char]13) Enter)
    Assert ($script:MenuTitle -eq 'user0@example.com') 'Row menu title must be the mailbox address.'
    Assert ($items[0].WillForwardTo -eq $before) 'Canceled editor must leave the row untouched.'
}

Test-Case 'Row menu Edit with an accepted editor result commits via the real Set-MailboxDraft' {
    $items = New-DispatchState
    function Show-MenuDialog { return 'Edit' }
    function Show-MailboxDialog { return @{ Prefix = 'newprefix'; DeliverAndStore = $true } }
    Invoke-TuiKey -Key (New-Key ([char]13) Enter)
    Assert ($items[0].WillForwardTo -eq 'newprefix@archive.example.com') 'Accepted editor result must update WillForwardTo via Set-MailboxDraft.'
    Assert ($items[0].DeliverAndStore -eq $true) 'Accepted editor result must update DeliverAndStore.'
}

Test-Case 'Row menu ToggleSelect flips selection without moving the cursor' {
    $items = New-DispatchState 3
    function Show-MenuDialog { return 'ToggleSelect' }
    Invoke-TuiKey -Key (New-Key ([char]13) Enter)
    Assert $items[0].Selected 'ToggleSelect must select the row.'
    Assert ($script:UI.Cursor -eq 0) 'ToggleSelect must not advance the cursor.'
    Invoke-TuiKey -Key (New-Key ([char]13) Enter)
    Assert (-not $items[0].Selected) 'Second ToggleSelect must deselect.'
}

Test-Case 'Row menu ToggleKeep flips DeliverAndStore through Set-MailboxDraft' {
    $items = New-DispatchState
    function Show-MenuDialog { return 'ToggleKeep' }
    Invoke-TuiKey -Key (New-Key ([char]13) Enter)
    Assert ($items[0].DeliverAndStore -eq $true) 'ToggleKeep must set keep-copy on.'
}

Test-Case 'Row menu disables Preview when nothing is selected and enables it with a count' {
    $items = New-DispatchState 3
    $script:MenuItems = $null
    function Show-MenuDialog { param($Title, $Items) $script:MenuItems = $Items; return $null }
    Invoke-TuiKey -Key (New-Key ([char]13) Enter)
    $p = $script:MenuItems | Where-Object { $_.Action -eq 'Apply' }
    Assert ($p.Disabled -eq $true -and $p.Label -like '*(0)') 'Preview must be disabled with (0).'
    $items[1].Selected = $true; $items[2].Selected = $true
    Invoke-TuiKey -Key (New-Key ([char]13) Enter)
    $p = $script:MenuItems | Where-Object { $_.Action -eq 'Apply' }
    Assert (-not $p.Disabled -and $p.Label -like '*(2)') 'Preview must be enabled with (2).'
}

Test-Case 'M opens the global menu; Quit stops the loop; Escape leaves state untouched' {
    New-DispatchState 2 | Out-Null
    $script:MenuTitle = ''
    function Show-MenuDialog { param($Title, $Items) $script:MenuTitle = $Title; return 'Quit' }
    $script:UI.Running = $true
    Invoke-TuiKey -Key (New-Key 'm' M)
    Assert ($script:MenuTitle -eq 'Actions') 'Global menu title must be Actions.'
    Assert (-not $script:UI.Running) 'Quit action must stop the loop.'
    $script:UI.Running = $true
    function Show-MenuDialog { return $null }
    Invoke-TuiKey -Key (New-Key 'm' M)
    Assert $script:UI.Running 'Escaped menu must change nothing.'
}

Test-Case 'Global menu SelectVisible and CycleFilter reuse the hotkey handlers' {
    $items = New-DispatchState 3
    function Show-MenuDialog { return 'SelectVisible' }
    Invoke-TuiKey -Key (New-Key 'm' M)
    Assert (@($items | Where-Object Selected).Count -eq 3) 'SelectVisible must select all visible rows.'
    function Show-MenuDialog { return 'CycleFilter' }
    Invoke-TuiKey -Key (New-Key 'm' M)
    Assert ($script:UI.Filter -eq 'HasForward') 'CycleFilter must advance the filter.'
}

Test-Case 'Enter on an empty view opens the global menu instead of a row menu' {
    New-DispatchState 0 | Out-Null
    $script:MenuTitle = ''
    function Show-MenuDialog { param($Title, $Items) $script:MenuTitle = $Title; return $null }
    Invoke-TuiKey -Key (New-Key ([char]13) Enter)
    Assert ($script:MenuTitle -eq 'Actions') 'Empty view Enter must open the global menu.'
}
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -File tests/Tui.Tests.ps1`
Expected: fails on `Row menu title must be the mailbox address.` (Enter still calls Show-MailboxDialog directly).

- [ ] **Step 3: Implement**

In `src/80-input.ps1`, insert before `Invoke-TuiKey`:

```powershell
function Get-TuiSelectedCount { @($script:UI.Items | Where-Object Selected).Count }

function Invoke-TuiAction {
    # Single dispatcher shared by main-table hotkeys and popup menus so both
    # paths run identical code.
    param([Parameter(Mandatory)][string]$Name)
    switch ($Name) {
        'ToggleSelect' {
            if (@($script:UI.View).Count -gt 0) {
                $row = $script:UI.View[$script:UI.Cursor]
                $row.Selected = -not $row.Selected
            }
        }
        'Edit' {
            if (@($script:UI.View).Count -eq 0) { break }
            $row = $script:UI.View[$script:UI.Cursor]
            $result = Show-MailboxDialog -Row $row -Domain $script:Config.ForwardingDomain
            if ($null -ne $result) {
                Set-MailboxDraft -Row $row -Prefix $result.Prefix -DeliverAndStore $result.DeliverAndStore -Domain $script:Config.ForwardingDomain
            }
        }
        'ToggleKeep' {
            if (@($script:UI.View).Count -eq 0) { break }
            $row = $script:UI.View[$script:UI.Cursor]
            try {
                Set-MailboxDraft -Row $row -Prefix ([string]$row.ForwardingPrefix) -DeliverAndStore (-not [bool]$row.DeliverAndStore) -Domain $script:Config.ForwardingDomain
            } catch {
                Show-ReportDialog -Title 'Keep-copy not changed' -Lines @($_.Exception.Message)
            }
        }
        'SelectVisible' { Set-MailboxSelection -State $script:UI -Mode Visible }
        'SelectNone'    { Set-MailboxSelection -State $script:UI -Mode None }
        'Search'        { $script:UI.Searching = $true }
        'CycleFilter' {
            $order = @('All', 'HasForward', 'NoForward')
            $idx = [Array]::IndexOf($order, $script:UI.Filter)
            $script:UI.Filter = $order[(($idx + 1) % $order.Count)]
            Update-MailboxView -State $script:UI
        }
        'Refresh'  { Invoke-TuiRefresh }
        'Settings' { Invoke-TuiSettings }
        'Apply'    { Invoke-TuiApply }
        'Help' {
            Show-ReportDialog -Title 'Help' -Lines @(
                'Enter  action menu for the highlighted mailbox', 'M  global actions menu',
                'Up/Down/PgUp/PgDn/Home/End  move cursor', 'Space  select/toggle & advance',
                'A  select all shown   N  clear selection', '/  live search (Enter keep, Esc clear)',
                'F  cycle filter   R  refresh   S  settings', 'P  preview & apply (explicit Y to confirm)',
                'Colors: blue = focus, cyan = selected, yellow = key, amber = will change, red = warning, green = keep copy',
                'Q or Ctrl+C  quit')
        }
        'Quit' { $script:UI.Running = $false }
    }
    $script:UI.Dirty = $true
}

function Invoke-TuiRowMenu {
    if (@($script:UI.View).Count -eq 0) { Invoke-TuiGlobalMenu; return }
    $row = $script:UI.View[$script:UI.Cursor]
    $n = Get-TuiSelectedCount
    $items = @(
        @{ Key = 'S'; Label = $(if ($row.Selected) { 'Deselect' } else { 'Select' }); Action = 'ToggleSelect' },
        @{ Key = 'E'; Label = 'Edit forwarding...'; Action = 'Edit' },
        @{ Key = 'K'; Label = $(if ($row.DeliverAndStore) { 'Keep copy: on  (turn off)' } else { 'Keep copy: off (turn on)' }); Action = 'ToggleKeep' },
        @{ Sep = $true },
        @{ Key = 'P'; Label = "Preview & apply selected ($n)"; Action = 'Apply'; Disabled = ($n -eq 0) }
    )
    $action = Show-MenuDialog -Title ([string]$row.PrimarySmtpAddress) -Items $items
    if ($action) { Invoke-TuiAction -Name $action } else { $script:UI.Dirty = $true }
}

function Invoke-TuiGlobalMenu {
    $n = Get-TuiSelectedCount
    $items = @(
        @{ Key = 'A'; Label = 'Select all visible'; Action = 'SelectVisible' },
        @{ Key = 'N'; Label = 'Clear selection'; Action = 'SelectNone' },
        @{ Key = 'F'; Label = "Filter: $($script:UI.Filter) (cycle)"; Action = 'CycleFilter' },
        @{ Key = '/'; Label = 'Search'; Action = 'Search' },
        @{ Sep = $true },
        @{ Key = 'P'; Label = "Preview & apply selected ($n)"; Action = 'Apply'; Disabled = ($n -eq 0) },
        @{ Key = 'R'; Label = 'Refresh mailboxes'; Action = 'Refresh' },
        @{ Key = 'S'; Label = 'Settings...'; Action = 'Settings' },
        @{ Key = '?'; Label = 'Help'; Action = 'Help' },
        @{ Key = 'Q'; Label = 'Quit'; Action = 'Quit' }
    )
    $action = Show-MenuDialog -Title 'Actions' -Items $items
    if ($action) { Invoke-TuiAction -Name $action } else { $script:UI.Dirty = $true }
}
```

In `Invoke-TuiKey`, replace the `'Enter'` case (lines 168-179) with:

```powershell
        'Enter' {
            # Enter opens the action menu; it never applies forwarding directly.
            Invoke-TuiRowMenu
            return
        }
```

Replace the second `switch` (lines 183-205) with:

```powershell
    switch ([char]::ToUpper($Key.KeyChar)) {
        'A' { Invoke-TuiAction -Name 'SelectVisible'; return }
        'N' { Invoke-TuiAction -Name 'SelectNone'; return }
        '/' { Invoke-TuiAction -Name 'Search'; return }
        'F' { Invoke-TuiAction -Name 'CycleFilter'; return }
        'R' { Invoke-TuiAction -Name 'Refresh'; return }
        'S' { Invoke-TuiAction -Name 'Settings'; return }
        'P' { Invoke-TuiAction -Name 'Apply'; return }
        'M' { Invoke-TuiGlobalMenu; return }
        '?' { Invoke-TuiAction -Name 'Help'; return }
        'Q' { Invoke-TuiAction -Name 'Quit'; return }
    }
```

- [ ] **Step 4: Run all tests**

Run: `Get-ChildItem ./tests -Filter *.Tests.ps1 | ForEach-Object { pwsh -NoProfile -File $_.FullName }`
Expected: every file prints its `... passed` line. Any existing test asserting `Q` via `Invoke-TuiKey` or filter cycling still passes because behaviour is unchanged.

- [ ] **Step 5: Commit**

```bash
git add src/80-input.ps1 tests/Tui.Tests.ps1
git commit -m "feat: row and global action menus with shared Invoke-TuiAction dispatcher"
```

---

### Task 7: Preview coloring and README

**Files:**
- Modify: `src/70-views.ps1:116-153` (`Get-PreviewFrame`), `src/20-dialogs.ps1` (`Show-PreviewDialog` footer), `README.md:21-30` and key list section (~lines 101-111)
- Test: `tests/Tui.Tests.ps1`

**Interfaces:**
- Consumes: Task 1 tokens, `Format-KeyHint`.
- Produces: no API change. `Get-PreviewFrame` output object unchanged (`Frame`, `LineCount`).

- [ ] **Step 1: Write failing test**

```powershell
# --- Preview coloring ---------------------------------------------------------
Test-Case 'Get-PreviewFrame colors action tags Set/Overwrite/Skip without changing LineCount' {
    $rows = @(
        [pscustomobject]@{ PrimarySmtpAddress = 'a@x.com'; CurrentForwarding = ''; WillForwardTo = 'a@y.com'; DeliverAndStore = $false; Action = 'Set' },
        [pscustomobject]@{ PrimarySmtpAddress = 'b@x.com'; CurrentForwarding = 'o@y.com'; WillForwardTo = 'b@y.com'; DeliverAndStore = $true; Action = 'Overwrite' },
        [pscustomobject]@{ PrimarySmtpAddress = 'c@x.com'; CurrentForwarding = 'c@y.com'; WillForwardTo = 'c@y.com'; DeliverAndStore = $false; Action = 'Skip' }
    )
    $r = Get-PreviewFrame -Rows $rows -Offset 0 -Width 80 -Height 20
    Assert ($r.LineCount -eq 12) "Three records of four lines each, got $($r.LineCount)."
    Assert ($r.Frame.Contains($script:T.Good + '[Set]')) 'Set must be green.'
    Assert ($r.Frame.Contains($script:T.Proposed + '[Overwrite]')) 'Overwrite must be amber.'
    Assert ($r.Frame.Contains($script:T.RowDim + '[Skip]')) 'Skip must be dim.'
}
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -File tests/Tui.Tests.ps1`
Expected: fails on `Set must be green.`

- [ ] **Step 3: Implement**

In `Get-PreviewFrame`, change the `$lines` collection to hold `@{Text;Tag}` pairs and color the tag on render. Replace lines 128-150 with:

```powershell
    $lines = New-Object System.Collections.Generic.List[object]
    foreach ($r in $Rows) {
        foreach ($chunk in (Split-DisplayChunks -Text ([string]$r.PrimarySmtpAddress) -Width $Width)) {
            [void]$lines.Add(@{ Text = $chunk; Tag = '' })
        }
        $old = [string]$r.CurrentForwarding
        $new = [string]$r.WillForwardTo
        foreach ($chunk in (Split-DisplayChunks -Text "  $old -> $new" -Width $Width)) {
            [void]$lines.Add(@{ Text = $chunk; Tag = '' })
        }
        $keep = if ($r.DeliverAndStore) { 'Yes' } else { 'No' }
        [void]$lines.Add(@{ Text = "  Keep copy: $keep  "; Tag = "[$($r.Action)]" })
        [void]$lines.Add(@{ Text = ''; Tag = '' })
    }

    $sb = New-Object System.Text.StringBuilder
    for ($row = 1; $row -le $Height; $row++) {
        $idx = $Offset + $row - 1
        $content = ''
        if ($idx -ge 0 -and $idx -lt $lines.Count) {
            $l = $lines[$idx]
            if ($l.Tag) {
                $tagCol = switch ($l.Tag) { '[Set]' { $t.Good } '[Overwrite]' { $t.Proposed } '[Skip]' { $t.RowDim } default { $t.Row } }
                $textW = [Math]::Max(0, $Width - $l.Tag.Length)
                $content = $t.Row + (ConvertTo-DisplayText -Text $l.Text -Width $textW) + $tagCol + (ConvertTo-DisplayText -Text $l.Tag -Width $l.Tag.Length)
            } else {
                $content = $t.Row + (ConvertTo-DisplayText -Text $l.Text -Width $Width)
            }
        }
        Add-FrameLine -Sb $sb -Row $row -Content $content
    }
```

In `Show-PreviewDialog`, replace lines 327-328 with:

```powershell
        $hint = ConvertTo-DisplayText -Text " $($Rows.Count) selected - Up/Down/PgUp/PgDn scroll  Y apply  N/Esc cancel" -Width $bodyW
        $colored = (Format-KeyHint -Text $hint).Replace($script:T.HotKey + 'Y', $script:T.FootBg + $script:T.Good + 'Y').Replace($script:T.HotKey + 'N/Esc', $script:T.FootBg + $script:T.Danger + 'N/Esc')
        Add-FrameLine -Sb $sb -Row $size[1] -Content ($script:T.FootBg + $colored)
```

README `README.md:30`: replace the footer line with

```
 Enter Actions  M Menu  Space Sel  / Search  P Preview  ? Help  Q Quit
```

In the selection-workflow / key section (~lines 101-111) add:

```markdown
- `Enter` opens an action menu for the highlighted mailbox (Select/Deselect, Edit forwarding, Keep copy on/off, Preview & apply). `M` opens the global Actions menu (select all, clear, filter, search, preview, refresh, settings, help, quit). Every menu item shows its hotkey; the same letters work directly on the table.
- Color legend: **blue bar** = where input goes now (cursor row, focused field, highlighted menu item); **cyan** = selected mailboxes; **yellow** = a key to press; **amber** = proposed forwarding that will change on apply; **red** = warning / cancel; **green** = keep-copy on / apply.
```

- [ ] **Step 4: Run all tests**

Run: `Get-ChildItem ./tests -Filter *.Tests.ps1 | ForEach-Object { pwsh -NoProfile -File $_.FullName }`
Expected: all pass. Existing test `Get-PreviewFrame wraps addresses reversibly and reports full LineCount` (tests/Tui.Tests.ps1:146) still passes: line structure unchanged.

- [ ] **Step 5: Manual smoke (no Exchange needed)**

Run in a terminal at least 100x30: `pwsh -NoProfile -Command ". ./tests/TestSupport.ps1; New-DispatchState 5 | Out-Null"` is not a runnable app; instead verify visually by launching `pwsh -NoProfile -File ./MailboxForwardingTool.ps1` if a cached mailbox list exists, press `Enter`, `M`, `Esc`, confirm: dimmed table behind bordered popup, blue highlight bar, yellow hotkeys. Then `-Ascii` flag: corners are `+`.

- [ ] **Step 6: Commit**

```bash
git add src/70-views.ps1 src/20-dialogs.ps1 README.md tests/Tui.Tests.ps1
git commit -m "feat: color preview action tags; document action menus and color legend"
```

---

## Self-review

- Spec §1 color system -> Task 1. §2 backdrop/box/styled lines/key hints -> Task 2; Settings/Edit focus -> Task 3. §3 `Show-MenuDialog`, row menu, global menu, footer, preview coloring -> Tasks 4, 6, 5, 7. §4 table coloring -> Task 5. §5 input wiring/`Invoke-TuiAction` -> Task 6. §6 error handling: Ctrl+C/Esc in Task 4; floor guards untouched. §7 tests: each task; ASCII corners covered in Task 1 (glyph presence) - add to Task 2 Step 4 if desired: run `pwsh -NoProfile -Command '$script:StartupOptions=@{Ascii=$true}; . ./tests/Tui.Tests.ps1'` is not supported by TestSupport; ASCII guarantee rests on `$script:G` fallback in Task 1 and the box code using only `$g.*`. §8 README -> Task 7.
- Names consistent: `Show-MenuDialog`, `Invoke-TuiAction`, `Invoke-TuiRowMenu`, `Invoke-TuiGlobalMenu`, `Get-BackdropFrame`, `Format-KeyHint`, `Get-StyledLine`, `Add-BoxLine`, `Capture-Console` (test helper, Task 2, reused Tasks 3-4), `Get-TuiSelectedCount`.
- Action names used in Task 6 tests match dispatcher cases: `ToggleSelect, Edit, ToggleKeep, SelectVisible, SelectNone, CycleFilter, Search, Apply, Refresh, Settings, Help, Quit`.
