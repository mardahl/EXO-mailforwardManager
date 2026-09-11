# Geometry, cursor, wrapping, and control-safety checks for the console
# lifecycle and resize-aware views (src/10-console.ps1, src/70-views.ps1).
# No console/network required - Get-MailboxFrame/Get-PreviewFrame take
# explicit dimensions and return plain strings.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$failures = New-Object 'System.Collections.Generic.List[string]'

function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body } catch { $script:failures.Add("$Name`: $_") }
}

# Dialog/frame rendering below writes real ANSI frames via [Console]::Write;
# mute that to stdout while the test body runs so failures/assertion output
# is not drowned in escape sequences, without changing any production code.
$script:OriginalConsoleOut = [Console]::Out
[Console]::SetOut([System.IO.TextWriter]::Null)
try {

# --- No legacy WinForms/DataGridView references anywhere in the tool -------
Test-Case 'Root and src contain no legacy WinForms references' {
    $paths = @($script:EntryScriptPath) + @(Get-ChildItem (Join-Path $script:ScriptDir 'src') -Filter '*.ps1' | Select-Object -ExpandProperty FullName)
    foreach ($path in $paths) {
        Assert ((Get-Content $path -Raw) -notmatch 'Windows\.Forms|System\.Drawing|Show-MainForm|BindingList|DataGridView') "Legacy GUI reference: $path"
    }
}

function New-Rows([int]$Count) {
    $rows = @()
    for ($i = 0; $i -lt $Count; $i++) {
        $rows += [pscustomobject]@{
            Selected = $false; PrimarySmtpAddress = "user$i@example.com"
            CurrentForwarding = ''; HasOnPremForwarding = $false
            DeliverAndStore = $false; ForwardingPrefix = ''; WillForwardTo = ''
        }
    }
    return $rows
}

function New-State([array]$Items, [int]$Capacity = 0) {
    $s = @{
        Items = $Items; View = @(); Cursor = 0; Scroll = 0; Search = ''; Filter = 'All'
        Status = ''; Account = ''; CacheFetchedAt = $null; Height = $Capacity
    }
    Update-MailboxView -State $s
    return $s
}

# --- Control-character / cell-width sanitization ---------------------------
Test-Case 'ConvertTo-DisplayText sanitizes and pads to exact width' {
    $esc = [string][char]27
    $safe = ConvertTo-DisplayText -Text ("alice" + $esc + '[2J' + "`t@example.com") -Width 18
    Assert ($safe.Length -eq 18) 'Cell width mismatch.'
    Assert ($safe.IndexOf([char]27) -lt 0 -and $safe.IndexOf([char]9) -lt 0) 'Untrusted terminal controls escaped sanitization.'
}
Test-Case 'ConvertTo-DisplayText truncates overlong text without changing the width contract' {
    $safe = ConvertTo-DisplayText -Text ('x' * 50) -Width 10
    Assert ($safe.Length -eq 10) 'Truncated cell must still be exactly Width.'
}
Test-Case 'ConvertTo-DisplayText handles empty text and zero width' {
    Assert ((ConvertTo-DisplayText -Text '' -Width 5).Length -eq 5) 'Empty text must still pad to Width.'
    Assert ((ConvertTo-DisplayText -Text 'x' -Width 0) -eq '') 'Zero width must return empty string.'
}

# --- Undersized-terminal guidance ------------------------------------------
Test-Case 'Get-MailboxFrame flags an undersized terminal' {
    $state = New-State (New-Rows 0)
    $frame = Get-MailboxFrame -State $state -Width 79 -Height 19
    Assert ($frame -match '80.*20') 'Undersized terminal needs resize guidance mentioning 80x20.'
}
Test-Case 'Get-MailboxFrame renders counts for an empty view without indexing a row' {
    $state = New-State (New-Rows 0)
    $frame = Get-MailboxFrame -State $state -Width 80 -Height 20
    Assert ($frame -match '0') 'Empty table must render counts without indexing a row.'
}

# --- Geometry across sizes: 80x20, 120x30, 180x50 ---------------------------
foreach ($dim in @(@(80, 20), @(120, 30), @(180, 50))) {
    $w = $dim[0]; $h = $dim[1]
    Test-Case "Get-MailboxFrame at ${w}x${h} places footer on the last row and stays in bounds" {
        $state = New-State (New-Rows 5) -Capacity ($h - 4)
        $frame = Get-MailboxFrame -State $state -Width $w -Height $h
        Assert ($frame.Contains("$([char]27)[$h;1H")) "Footer must be positioned at absolute row $h."
        Assert (-not $frame.EndsWith("`n")) 'Frame must not end with a trailing newline.'
        for ($row = ($h + 1); $row -le ($h + 3); $row++) {
            Assert (-not $frame.Contains("$([char]27)[$row;1H")) "Frame referenced row $row, out of the ${h}-row bounds."
        }
    }
}

# --- Empty / singleton / large views ---------------------------------------
Test-Case 'Get-MailboxFrame renders an empty view' {
    $state = New-State (New-Rows 0) -Capacity 16
    $frame = Get-MailboxFrame -State $state -Width 80 -Height 20
    Assert ($frame.Length -gt 0) 'Empty view must still produce a frame.'
}
Test-Case 'Get-MailboxFrame renders a singleton view with cursor on the one row' {
    $state = New-State (New-Rows 1) -Capacity 16
    $frame = Get-MailboxFrame -State $state -Width 80 -Height 20
    Assert ($frame.Contains('user0@example.com')) 'Singleton row must render.'
}
Test-Case 'Get-MailboxFrame renders a large view (250 rows) at capacity' {
    $state = New-State (New-Rows 250) -Capacity 16
    $state.Cursor = 200
    Update-MailboxView -State $state
    $frame = Get-MailboxFrame -State $state -Width 80 -Height 20
    Assert ($state.Cursor -ge $state.Scroll -and $state.Cursor -lt ($state.Scroll + 16)) 'Cursor must remain within the visible window.'
    Assert ($frame.Length -gt 0) 'Large view must still produce a bounded frame.'
}

# --- Resize down/up keeps cursor visible and model text unchanged ----------
Test-Case 'Resizing down then up keeps cursor visible and leaves model text unchanged' {
    $state = New-State (New-Rows 50) -Capacity 16
    $state.Cursor = 40
    Update-MailboxView -State $state
    $originalAddr = $state.Items[40].PrimarySmtpAddress

    # Resize down: capacity shrinks.
    $state.Height = 6
    Update-MailboxView -State $state
    Assert ($state.Cursor -ge $state.Scroll -and $state.Cursor -lt ($state.Scroll + 6)) 'Cursor must stay visible after shrinking.'
    [void](Get-MailboxFrame -State $state -Width 80 -Height 10)

    # Resize up: capacity grows back.
    $state.Height = 16
    Update-MailboxView -State $state
    Assert ($state.Cursor -ge $state.Scroll -and $state.Cursor -lt ($state.Scroll + 16)) 'Cursor must stay visible after growing.'
    [void](Get-MailboxFrame -State $state -Width 80 -Height 20)

    Assert ($state.Items[40].PrimarySmtpAddress -eq $originalAddr) 'Underlying model text must be unchanged by rendering/resizing.'
}

# --- Long addresses / control characters in display data --------------------
Test-Case 'Get-MailboxFrame tolerates long addresses and control characters without throwing' {
    $rows = New-Rows 2
    $rows[0].PrimarySmtpAddress = ('a' * 200) + '@example.com'
    $rows[1].PrimarySmtpAddress = "weird" + [string][char]27 + "[31mname@example.com"
    $state = New-State $rows -Capacity 16
    $frame = Get-MailboxFrame -State $state -Width 80 -Height 20
    Assert ($frame.IndexOf(([char]27 + '[31m'), [StringComparison]::Ordinal) -lt 0) 'Row-supplied ANSI must be sanitized, not passed through.'
    Assert ($rows[1].PrimarySmtpAddress.Contains([char]27)) 'Sanitization must be display-only; stored address must be untouched.'
}

# --- Preview frame: wrapping, recoverability, LineCount ---------------------
Test-Case 'Get-PreviewFrame wraps addresses reversibly and reports full LineCount' {
    $longAddr = ('user.' * 20) + '@example.com'
    $rows = @([pscustomobject]@{
        PrimarySmtpAddress = $longAddr; CurrentForwarding = 'old@example.net'
        WillForwardTo = 'new@example.net'; DeliverAndStore = $true; Action = 'Overwrite'
    })
    $result = Get-PreviewFrame -Rows $rows -Offset 0 -Width 20 -Height 4
    Assert ($result.LineCount -gt 4) 'Long address must wrap into more lines than one small viewport.'
    $wide = Get-PreviewFrame -Rows $rows -Offset 0 -Width 40 -Height $result.LineCount
    Assert ($wide.Frame -match 'Overwrite') 'Explicit Overwrite text must appear.'

    $full = Get-PreviewFrame -Rows $rows -Offset 0 -Width 20 -Height $result.LineCount
    $rebuilt = ($full.Frame -split ("$([char]27)\[K")) | ForEach-Object {
        ($_ -replace ("$([char]27)\[\d+;1H"), '')
    }
    $joined = ($rebuilt -join '').Replace($script:T.Row, '').Replace($script:T.Reset, '')
    Assert ($joined.Contains($longAddr)) 'Wrapped address must be recoverable by concatenating chunks.'
}
Test-Case 'Get-PreviewFrame Skip action renders explicit Skip text' {
    $rows = @([pscustomobject]@{
        PrimarySmtpAddress = 'a@example.com'; CurrentForwarding = ''
        WillForwardTo = ''; DeliverAndStore = $false; Action = 'Skip'
    })
    $result = Get-PreviewFrame -Rows $rows -Offset 0 -Width 40 -Height 5
    Assert ($result.Frame -match 'Skip') 'Explicit Skip text must appear.'
}
Test-Case 'Get-PreviewFrame Offset scrolls without changing LineCount' {
    $rows = New-Rows 10 | ForEach-Object {
        [pscustomobject]@{
            PrimarySmtpAddress = $_.PrimarySmtpAddress; CurrentForwarding = ''
            WillForwardTo = ''; DeliverAndStore = $false; Action = 'Set'
        }
    }
    $a = Get-PreviewFrame -Rows $rows -Offset 0 -Width 40 -Height 5
    $b = Get-PreviewFrame -Rows $rows -Offset 5 -Width 40 -Height 5
    Assert ($a.LineCount -eq $b.LineCount) 'LineCount describes the whole body, independent of Offset.'
    Assert ($a.Frame -ne $b.Frame) 'Different Offset must render a different window.'
}

# --- Console lifecycle: mocked Enter-Tui/Exit-Tui around Invoke-OnMainBuffer -
Test-Case 'Invoke-OnMainBuffer restores the TUI after a normal action' {
    $script:enterCalls = 0; $script:exitCalls = 0
    function Enter-Tui { $script:enterCalls++; $script:TuiActive = $true }
    function Exit-Tui { $script:exitCalls++; $script:TuiActive = $false }
    $script:TuiActive = $true
    [void](Invoke-OnMainBuffer -Action { 1 + 1 })
    Assert ($script:exitCalls -eq 1 -and $script:enterCalls -eq 1) 'Invoke-OnMainBuffer must exit then re-enter around the action.'
    Assert ($script:TuiActive -eq $true) 'TUI must be re-entered after a normal action.'
}
Test-Case 'Invoke-OnMainBuffer restores the TUI even when the action throws' {
    $script:enterCalls = 0; $script:exitCalls = 0
    function Enter-Tui { $script:enterCalls++; $script:TuiActive = $true }
    function Exit-Tui { $script:exitCalls++; $script:TuiActive = $false }
    $script:TuiActive = $true
    $threw = $false
    try { Invoke-OnMainBuffer -Action { throw 'boom' } } catch { $threw = $true }
    Assert $threw 'The throwing action''s exception must propagate.'
    Assert ($script:exitCalls -eq 1 -and $script:enterCalls -eq 1) 'Invoke-OnMainBuffer must still restore the TUI when the action throws.'
    Assert ($script:TuiActive -eq $true) 'TUI must be re-entered even after a throwing action.'
}
Test-Case 'Invoke-OnMainBuffer is a no-op wrapper when the TUI was not active' {
    $script:enterCalls = 0; $script:exitCalls = 0
    function Enter-Tui { $script:enterCalls++ }
    function Exit-Tui { $script:exitCalls++ }
    $script:TuiActive = $false
    [void](Invoke-OnMainBuffer -Action { 1 + 1 })
    Assert ($script:enterCalls -eq 0 -and $script:exitCalls -eq 0) 'Invoke-OnMainBuffer must not touch console state when the TUI was never active.'
}

# --- Get-ConsoleSize never returns a non-positive dimension -----------------
Test-Case 'Get-ConsoleSize returns two positive integers' {
    $size = Get-ConsoleSize
    Assert ($size.Count -eq 2 -and $size[0] -gt 0 -and $size[1] -gt 0) 'Get-ConsoleSize must return positive [width,height].'
}

# --- Invoke-TuiKey: real key dispatch, modal functions stubbed at the ------
# test boundary (never the model: Update-MailboxView/Set-MailboxSelection/
# Set-MailboxDraft/Merge-MailboxRefresh run for real in every case below).
# Clear-DialogKeyQueue's real implementation reads [Console]::KeyAvailable,
# which is not available under this non-interactive test host; every
# dialog/apply path calls it, so it is stubbed once here for the whole file.
function Clear-DialogKeyQueue { }

function New-Key([char]$Char, [ConsoleKey]$Key, [switch]$Shift, [switch]$Control) {
    [ConsoleKeyInfo]::new($Char, $Key, [bool]$Shift, $false, [bool]$Control)
}

function New-DispatchState([int]$Count = 2, [int]$Capacity = 30) {
    $config = [pscustomobject]@{ ForwardingDomain = 'archive.example.com'; DeliverToMailboxAndForward = $true }
    $raw = @()
    for ($i = 0; $i -lt $Count; $i++) {
        $raw += [pscustomobject]@{
            PrimarySmtpAddress = "user$i@example.com"; ForwardingSmtpAddress = ''
            DeliverToMailboxAndForward = $false; HasOnPremForwardingAddress = $false
        }
    }
    $items = @(New-MailboxRows -Mailboxes $raw -Config $config)
    $script:Config = $config
    $script:UI.Items = $items
    $script:UI.View = $items
    $script:UI.Cursor = 0
    $script:UI.Scroll = 0
    $script:UI.Width = 120
    $script:UI.Height = $Capacity
    $script:UI.Search = ''
    $script:UI.Filter = 'All'
    $script:UI.Searching = $false
    $script:UI.Status = ''
    $items
}

Test-Case 'Space selects the cursor row and advances the cursor; Enter never applies' {
    $items = New-DispatchState
    $items[0].Selected = $false
    Invoke-TuiKey -Key (New-Key ' ' Spacebar)
    Assert $items[0].Selected 'Space must select the cursor row.'
    Assert ($script:UI.Cursor -eq 1) 'Space must advance the cursor.'

    $script:ApplyCalls = 0
    function Set-MailboxForwards { $script:ApplyCalls++ }
    function Show-MailboxDialog { return $null }
    Invoke-TuiKey -Key (New-Key ([char]13) Enter)
    Assert ($script:ApplyCalls -eq 0) 'Enter on the main table must never apply.'
}

Test-Case 'Enter opens the row editor; a canceled editor preserves the row unchanged' {
    $items = New-DispatchState
    $before = $items[0].WillForwardTo
    function Show-MailboxDialog { return $null }
    Invoke-TuiKey -Key (New-Key ([char]13) Enter)
    Assert ($items[0].WillForwardTo -eq $before) 'Canceled editor must leave the row untouched.'
}

Test-Case 'Enter with an accepted editor result commits via the real Set-MailboxDraft' {
    $items = New-DispatchState
    function Show-MailboxDialog { return @{ Prefix = 'newprefix'; DeliverAndStore = $true } }
    Invoke-TuiKey -Key (New-Key ([char]13) Enter)
    Assert ($items[0].WillForwardTo -eq 'newprefix@archive.example.com') 'Accepted editor result must update WillForwardTo via Set-MailboxDraft.'
    Assert ($items[0].DeliverAndStore -eq $true) 'Accepted editor result must update DeliverAndStore.'
}

Test-Case 'Search mode captures letters; they never trigger main-table commands' {
    $items = New-DispatchState 3
    Invoke-TuiKey -Key (New-Key '/' ([ConsoleKey]::Oem2))
    Assert $script:UI.Searching 'Slash must enter search mode.'
    foreach ($row in $items) { $row.Selected = $false }
    # 'a' would select-all outside search mode; inside search mode it must
    # only extend the query, never call Set-MailboxSelection's Visible mode.
    Invoke-TuiKey -Key (New-Key 'a' A)
    Assert ($script:UI.Search -eq 'a') 'Typed letters must extend the search query while searching.'
    Assert (-not ($items | Where-Object Selected)) 'Letters typed while searching must never select rows.'
    Invoke-TuiKey -Key (New-Key ([char]13) Enter)
    Assert (-not $script:UI.Searching) 'Enter must close search mode.'
    Assert ($script:UI.Search -eq 'a') 'Enter must keep the typed query.'
}

Test-Case 'Escape while searching clears the query and exits search mode' {
    New-DispatchState 3 | Out-Null
    Invoke-TuiKey -Key (New-Key '/' ([ConsoleKey]::Oem2))
    Invoke-TuiKey -Key (New-Key 'x' X)
    Invoke-TuiKey -Key (New-Key ([char]27) Escape)
    Assert (-not $script:UI.Searching) 'Escape must exit search mode.'
    Assert ($script:UI.Search -eq '') 'Escape must clear the search query.'
}

Test-Case 'F cycles the filter and A/N select/clear the visible set' {
    $items = New-DispatchState 3
    Assert ($script:UI.Filter -eq 'All') 'Filter must start at All.'
    Invoke-TuiKey -Key (New-Key 'f' F)
    Assert ($script:UI.Filter -eq 'HasForward') 'F must cycle All -> HasForward.'
    Invoke-TuiKey -Key (New-Key 'f' F)
    Assert ($script:UI.Filter -eq 'NoForward') 'F must cycle HasForward -> NoForward.'
    Invoke-TuiKey -Key (New-Key 'f' F)
    Assert ($script:UI.Filter -eq 'All') 'F must wrap NoForward -> All.'
    Invoke-TuiKey -Key (New-Key 'a' A)
    Assert (@($items | Where-Object Selected).Count -eq 3) 'A must select every visible row.'
    Invoke-TuiKey -Key (New-Key 'n' N)
    Assert (@($items | Where-Object Selected).Count -eq 0) 'N must clear every selection.'
}

Test-Case 'Empty view tolerates every navigation key without throwing' {
    New-DispatchState 0 | Out-Null
    foreach ($k in @(
        (New-Key ([char]0) UpArrow), (New-Key ([char]0) DownArrow), (New-Key ([char]0) PageUp),
        (New-Key ([char]0) PageDown), (New-Key ([char]0) Home), (New-Key ([char]0) End),
        (New-Key ' ' Spacebar), (New-Key ([char]13) Enter)
    )) {
        Invoke-TuiKey -Key $k
    }
    Assert ($script:UI.Cursor -eq 0) 'Cursor must stay clamped to 0 on an empty view.'
}

Test-Case 'Minimum-size guard blocks everything except quit below 80x20' {
    New-DispatchState 3 | Out-Null
    $script:UI.Width = 79
    $script:UI.Height = [Math]::Max(0, 19 - 4)
    $before = @($script:UI.Items | Where-Object Selected).Count
    Invoke-TuiKey -Key (New-Key ' ' Spacebar)
    Assert ((@($script:UI.Items | Where-Object Selected).Count) -eq $before) 'Undersized terminal must ignore Space.'
    Assert $script:UI.Running 'Undersized terminal must not quit on a non-quit key.'
    Invoke-TuiKey -Key (New-Key 'q' Q)
    Assert (-not $script:UI.Running) 'Q must still quit even when undersized.'
    $script:UI.Running = $true
}

Test-Case 'Preview: empty selection never opens the preview dialog' {
    New-DispatchState 3 | Out-Null
    $script:PreviewCalls = 0
    function Show-PreviewDialog { $script:PreviewCalls++; return $true }
    Invoke-TuiKey -Key (New-Key 'p' P)
    Assert ($script:PreviewCalls -eq 0) 'Preview must not open with nothing selected.'
    Assert ($script:UI.Status -match 'selected') 'Empty-selection Preview must report a status message.'
}

Test-Case 'Preview: canceled confirmation makes zero Apply calls; hidden selections still reach preview' {
    $items = New-DispatchState 3
    $items[0].Selected = $true   # will be hidden by the search below
    $items[1].Selected = $true
    $script:UI.Search = 'user1'
    Update-MailboxView -State $script:UI
    Assert (@($script:UI.View).Count -eq 1) 'Search must hide user0 from View.'

    $script:PreviewRows = $null
    function Show-PreviewDialog { param($Rows) $script:PreviewRows = $Rows; return $false }
    $script:ApplyCalls = 0
    function Set-MailboxForwards { $script:ApplyCalls++ }
    Invoke-TuiKey -Key (New-Key 'p' P)
    Assert ($script:ApplyCalls -eq 0) 'A canceled (N/Esc) preview must make zero Apply calls.'
    Assert ($script:PreviewRows.Count -eq 2) 'Every selected row (including hidden ones) must reach the preview, not just the visible ones.'
}

Test-Case 'Preview: confirmed apply updates only OK rows and survives a search filter' {
    $items = New-DispatchState 2
    $items[0].Selected = $true
    $items[1].Selected = $true
    function Show-PreviewDialog { param($Rows) return $true }
    function Set-MailboxForwards {
        param($Rows, $OnProgress)
        if ($OnProgress) { & $OnProgress 1 2 $Rows[0].PrimarySmtpAddress }
        [pscustomobject]@{
            Records = @(
                [pscustomobject]@{ Mailbox = $Rows[0].PrimarySmtpAddress; Result = 'OK'; NewForwardingSmtpAddress = $Rows[0].WillForwardTo; Error = '' }
                [pscustomobject]@{ Mailbox = $Rows[1].PrimarySmtpAddress; Result = 'Error'; NewForwardingSmtpAddress = ''; Error = 'boom' }
            )
            Applied = 1; Skipped = 0; Errors = 1; LogPath = 'x.csv'; PersistenceErrors = @()
        }
    }
    function Show-OperationProgress { param($Progress) }
    function Show-ReportDialog { param($Title, $Lines) }
    $script:UI.Search = 'user0'
    Update-MailboxView -State $script:UI
    Invoke-TuiKey -Key (New-Key 'p' P)
    Assert ($items[0].CurrentForwarding -eq $items[0].WillForwardTo) 'Only the OK record must update CurrentForwarding.'
    Assert ([string]::IsNullOrEmpty($items[1].CurrentForwarding)) 'A non-OK record must not touch CurrentForwarding.'
    Assert (@($script:UI.View).Count -eq 1) 'The active search filter must still apply after the model update.'
}

Test-Case 'Settings: a canceled settings dialog leaves the active config untouched' {
    New-DispatchState 2 | Out-Null
    $original = $script:Config
    function Show-SettingsDialog { param($Config) return $null }
    Invoke-TuiKey -Key (New-Key 's' S)
    Assert ([object]::ReferenceEquals($script:Config, $original)) 'A canceled Settings dialog must not replace $script:Config.'
}

Test-Case 'Settings: an accepted save recomputes proposals but preserves per-row keep-copy edits' {
    $items = New-DispatchState 2
    $items[0].DeliverAndStore = $true
    $items[1].DeliverAndStore = $false
    $script:SavedConfig = $null
    function Show-SettingsDialog {
        param($Config)
        return [pscustomobject]@{ ForwardingDomain = 'new.example.com'; ServiceAccountUPN = 'svc@example.com'; DeliverToMailboxAndForward = $true; CacheTtlHours = 24 }
    }
    function Save-Config { param($Config) $script:SavedConfig = $Config }
    Invoke-TuiKey -Key (New-Key 's' S)
    Assert ($null -ne $script:SavedConfig) 'Accepted Settings must call Save-Config.'
    Assert ($script:Config.ForwardingDomain -eq 'new.example.com') 'Accepted Settings must replace $script:Config.'
    Assert ($items[0].WillForwardTo -eq 'user0@new.example.com') 'Proposals must recompute against the new domain.'
    Assert ($items[0].DeliverAndStore -eq $true -and $items[1].DeliverAndStore -eq $false) 'Per-row keep-copy edits must survive a Settings save.'
}

Test-Case 'Refresh: a mid-fetch exception retains existing rows and shows details' {
    $items = New-DispatchState 2
    $items[0].CurrentForwarding = 'kept@example.net'
    function Get-MailboxList { param([switch]$Force, [scriptblock]$OnProgress) throw 'Exchange unavailable' }
    $script:ReportLines = $null
    function Show-ReportDialog { param($Title, $Lines) $script:ReportLines = $Lines }
    Invoke-TuiKey -Key (New-Key 'r' R)
    Assert ($items[0].CurrentForwarding -eq 'kept@example.net') 'A failed refresh must retain existing row state.'
    Assert ($script:ReportLines -match 'Exchange unavailable') 'A failed refresh must show the underlying error detail.'
}

Test-Case 'Refresh: a successful fetch merges via the real Merge-MailboxRefresh' {
    $items = New-DispatchState 2
    function Get-MailboxList {
        param([switch]$Force, [scriptblock]$OnProgress)
        @(
            [pscustomobject]@{ PrimarySmtpAddress = 'user0@example.com'; ForwardingSmtpAddress = 'archive@example.net'; HasOnPremForwardingAddress = $false }
            [pscustomobject]@{ PrimarySmtpAddress = 'user1@example.com'; ForwardingSmtpAddress = ''; HasOnPremForwardingAddress = $false }
        )
    }
    Invoke-TuiKey -Key (New-Key 'r' R)
    Assert ($items[0].CurrentForwarding -eq 'archive@example.net') 'A successful refresh must merge fresh CurrentForwarding via the real model function.'
}

# --- Show-MailboxDialog: invalid drafts never escape the editor ------------
Test-Case 'Show-MailboxDialog rejects an invalid prefix, corrects in place, and never mutates the original row until commit' {
    $row = [pscustomobject]@{
        Selected = $false; PrimarySmtpAddress = 'alice@example.com'; CurrentForwarding = ''
        HasOnPremForwarding = $false; DeliverAndStore = $false; ForwardingPrefix = 'alice'; WillForwardTo = 'alice@archive.example.com'
    }
    $originalWillTo = $row.WillForwardTo
    $keys = New-Object System.Collections.Generic.Queue[object]
    # Type '@' (invalid prefix char), Tab to Save, Enter -> rejected, stays open.
    [void]$keys.Enqueue((New-Key '@' ([ConsoleKey]::D2)))
    [void]$keys.Enqueue((New-Key ([char]9) Tab))
    [void]$keys.Enqueue((New-Key ([char]9) Tab))
    [void]$keys.Enqueue((New-Key ([char]13) Enter))
    # Tab back to Prefix, backspace out the '@', Tab to Save, Enter -> accepted.
    [void]$keys.Enqueue((New-Key ([char]9) Tab -Shift))
    [void]$keys.Enqueue((New-Key ([char]9) Tab -Shift))
    [void]$keys.Enqueue((New-Key ([char]8) Backspace))
    [void]$keys.Enqueue((New-Key ([char]9) Tab))
    [void]$keys.Enqueue((New-Key ([char]9) Tab))
    [void]$keys.Enqueue((New-Key ([char]13) Enter))
    function Read-DialogKey { $keys.Dequeue() }
    function Clear-DialogKeyQueue { }
    $result = Show-MailboxDialog -Row $row -Domain 'archive.example.com'
    Assert ($row.WillForwardTo -eq $originalWillTo) 'Show-MailboxDialog must never mutate the real row directly.'
    Assert ($null -ne $result -and $result.Prefix -eq 'alice') 'A corrected, valid draft must eventually be returned.'
}

Test-Case 'Show-MailboxDialog rejects a blank prefix on Save; never clears forwarding' {
    $row = [pscustomobject]@{
        Selected = $false; PrimarySmtpAddress = 'dave@example.com'; CurrentForwarding = ''
        HasOnPremForwarding = $false; DeliverAndStore = $false; ForwardingPrefix = 'dave'; WillForwardTo = 'dave@archive.example.com'
    }
    $originalWillTo = $row.WillForwardTo
    $keys = New-Object System.Collections.Generic.Queue[object]
    # Backspace the whole prefix out, Tab to Save, Enter -> rejected, stays open.
    for ($i = 0; $i -lt 'dave'.Length; $i++) { [void]$keys.Enqueue((New-Key ([char]8) Backspace)) }
    [void]$keys.Enqueue((New-Key ([char]9) Tab))
    [void]$keys.Enqueue((New-Key ([char]9) Tab))
    [void]$keys.Enqueue((New-Key ([char]13) Enter))
    # Tab back to Prefix, retype a valid prefix, Tab to Save, Enter -> accepted.
    [void]$keys.Enqueue((New-Key ([char]9) Tab -Shift))
    [void]$keys.Enqueue((New-Key ([char]9) Tab -Shift))
    foreach ($c in [char[]]'dave2') { [void]$keys.Enqueue((New-Key $c ([ConsoleKey]::D2))) }
    [void]$keys.Enqueue((New-Key ([char]9) Tab))
    [void]$keys.Enqueue((New-Key ([char]9) Tab))
    [void]$keys.Enqueue((New-Key ([char]13) Enter))
    function Read-DialogKey { $keys.Dequeue() }
    function Clear-DialogKeyQueue { }
    $result = Show-MailboxDialog -Row $row -Domain 'archive.example.com'
    Assert ($row.WillForwardTo -eq $originalWillTo) 'A blank-prefix Save attempt must never mutate the real row.'
    Assert ($null -ne $result -and $result.Prefix -ne '') 'Blank prefix must be rejected; only a non-blank prefix can be saved.'
}

Test-Case 'Show-MailboxDialog Escape cancels without any commit attempt' {
    $row = [pscustomobject]@{
        Selected = $false; PrimarySmtpAddress = 'bob@example.com'; CurrentForwarding = ''
        HasOnPremForwarding = $false; DeliverAndStore = $false; ForwardingPrefix = 'bob'; WillForwardTo = 'bob@archive.example.com'
    }
    $keys = New-Object System.Collections.Generic.Queue[object]
    [void]$keys.Enqueue((New-Key 'x' X))
    [void]$keys.Enqueue((New-Key ([char]27) Escape))
    function Read-DialogKey { $keys.Dequeue() }
    function Clear-DialogKeyQueue { }
    $result = Show-MailboxDialog -Row $row -Domain 'archive.example.com'
    Assert ($null -eq $result) 'Escape must cancel with a $null result.'
    Assert ($row.ForwardingPrefix -eq 'bob') 'A canceled editor must never touch the original row.'
}

# --- Show-PreviewDialog: Enter never confirms; Y/N are explicit -----------
Test-Case 'Show-PreviewDialog: Enter is ignored, only explicit Y confirms' {
    $rows = @([pscustomobject]@{ PrimarySmtpAddress = 'a@example.com'; CurrentForwarding = ''; WillForwardTo = 'a@x.com'; DeliverAndStore = $false; Action = 'Set' })
    $keys = New-Object System.Collections.Generic.Queue[object]
    [void]$keys.Enqueue((New-Key ([char]13) Enter))
    [void]$keys.Enqueue((New-Key 'y' Y))
    function Read-DialogKey { $keys.Dequeue() }
    Assert (Show-PreviewDialog -Rows $rows) 'Enter must be ignored; the queued Y must be the confirming key.'
}

Test-Case 'Show-PreviewDialog: N cancels' {
    $rows = @([pscustomobject]@{ PrimarySmtpAddress = 'a@example.com'; CurrentForwarding = ''; WillForwardTo = 'a@x.com'; DeliverAndStore = $false; Action = 'Set' })
    $keys = New-Object System.Collections.Generic.Queue[object]
    [void]$keys.Enqueue((New-Key 'n' N))
    function Read-DialogKey { $keys.Dequeue() }
    Assert (-not (Show-PreviewDialog -Rows $rows)) 'N must cancel the preview.'
}

# --- Modals below 80x20 floor: Test-TuiBelowFloor blocks commits -----------
Test-Case 'Show-PreviewDialog rejects Y below floor, then cancels with Escape' {
    $rows = @([pscustomobject]@{ PrimarySmtpAddress = 'a@example.com'; CurrentForwarding = ''; WillForwardTo = 'a@x.com'; DeliverAndStore = $false; Action = 'Set' })
    $keys = New-Object System.Collections.Generic.Queue[object]
    # Queued keys: Y while undersized (must not return), then Escape to cancel
    [void]$keys.Enqueue((New-Key 'y' Y))
    [void]$keys.Enqueue((New-Key ([char]27) Escape))
    function Read-DialogKey { $keys.Dequeue() }
    function Get-ConsoleSize { return @(70, 15) }
    $res = Show-PreviewDialog -Rows $rows
    Assert (-not $res) 'Show-PreviewDialog must refuse Y below 80x20 and cancel on Escape.'
}

Test-Case 'Show-PreviewDialog rejects Y below floor, then confirms when resized back' {
    $rows = @([pscustomobject]@{ PrimarySmtpAddress = 'a@example.com'; CurrentForwarding = ''; WillForwardTo = 'a@x.com'; DeliverAndStore = $false; Action = 'Set' })
    $keys = New-Object System.Collections.Generic.Queue[object]
    $sizes = New-Object System.Collections.Generic.Queue[object]
    # First iteration: undersized, Y ignored
    [void]$sizes.Enqueue(@(70, 15))
    [void]$keys.Enqueue((New-Key 'y' Y))
    # Second iteration: resized back above floor, Y confirms
    [void]$sizes.Enqueue(@(80, 24))
    [void]$keys.Enqueue((New-Key 'y' Y))
    function Read-DialogKey { $keys.Dequeue() }
    function Get-ConsoleSize { if ($sizes.Count -gt 0) { $sizes.Dequeue() } else { @(80, 24) } }
    $res = Show-PreviewDialog -Rows $rows
    Assert $res 'Show-PreviewDialog must accept Y after terminal is resized back above 80x20.'
}

Test-Case 'Show-SettingsDialog rejects Save Enter below floor, then cancels with Escape' {
    $config = [pscustomobject]@{
        ForwardingDomain           = 'example.com'
        ServiceAccountUPN          = 'admin@example.com'
        CacheTtlHours              = 24
        DeliverToMailboxAndForward = $false
    }
    $keys = New-Object System.Collections.Generic.Queue[object]
    # Tab to Save button (focus: 0 -> 1 -> 2 -> 3 -> 4 = Save)
    [void]$keys.Enqueue((New-Key ([char]9) Tab))
    [void]$keys.Enqueue((New-Key ([char]9) Tab))
    [void]$keys.Enqueue((New-Key ([char]9) Tab))
    [void]$keys.Enqueue((New-Key ([char]9) Tab))
    # Enter on Save while undersized (must not commit)
    [void]$keys.Enqueue((New-Key ([char]13) Enter))
    # Escape to cancel
    [void]$keys.Enqueue((New-Key ([char]27) Escape))
    function Read-DialogKey { $keys.Dequeue() }
    function Clear-DialogKeyQueue { }
    function Get-ConsoleSize { return @(70, 15) }
    $res = Show-SettingsDialog -Config $config
    Assert ($null -eq $res) 'Show-SettingsDialog must refuse Save Enter below 80x20 and cancel on Escape.'
}

Test-Case 'Show-SettingsDialog rejects Save Enter below floor, then commits when resized back' {
    $config = [pscustomobject]@{
        ForwardingDomain           = 'example.com'
        ServiceAccountUPN          = 'admin@example.com'
        CacheTtlHours              = 24
        DeliverToMailboxAndForward = $false
    }
    $keys = New-Object System.Collections.Generic.Queue[object]
    $sizes = New-Object System.Collections.Generic.Queue[object]
    # Tab to Save button (focus 4)
    [void]$sizes.Enqueue(@(70, 15))
    [void]$keys.Enqueue((New-Key ([char]9) Tab))
    [void]$sizes.Enqueue(@(70, 15))
    [void]$keys.Enqueue((New-Key ([char]9) Tab))
    [void]$sizes.Enqueue(@(70, 15))
    [void]$keys.Enqueue((New-Key ([char]9) Tab))
    [void]$sizes.Enqueue(@(70, 15))
    [void]$keys.Enqueue((New-Key ([char]9) Tab))
    # Enter on Save while undersized (must not commit)
    [void]$sizes.Enqueue(@(70, 15))
    [void]$keys.Enqueue((New-Key ([char]13) Enter))
    # Resized back above floor, Enter on Save commits
    [void]$sizes.Enqueue(@(80, 24))
    [void]$keys.Enqueue((New-Key ([char]13) Enter))
    function Read-DialogKey { $keys.Dequeue() }
    function Clear-DialogKeyQueue { }
    function Get-ConsoleSize { if ($sizes.Count -gt 0) { $sizes.Dequeue() } else { @(80, 24) } }
    $res = Show-SettingsDialog -Config $config
    Assert ($null -ne $res) 'Show-SettingsDialog must commit Save Enter after terminal is resized back above 80x20.'
    Assert ($res.ForwardingDomain -eq 'example.com') 'Committed settings draft must match.'
}

Test-Case 'Show-MailboxDialog rejects Save Enter below floor, then cancels with Escape' {
    $row = [pscustomobject]@{
        Selected = $false; PrimarySmtpAddress = 'carol@example.com'; CurrentForwarding = ''
        HasOnPremForwarding = $false; DeliverAndStore = $false; ForwardingPrefix = 'carol'; WillForwardTo = 'carol@archive.example.com'
    }
    $keys = New-Object System.Collections.Generic.Queue[object]
    # Tab to Save button (focus: 0 -> 1 -> 2 = Save)
    [void]$keys.Enqueue((New-Key ([char]9) Tab))
    [void]$keys.Enqueue((New-Key ([char]9) Tab))
    # Enter on Save while undersized (must not commit)
    [void]$keys.Enqueue((New-Key ([char]13) Enter))
    # Escape to cancel
    [void]$keys.Enqueue((New-Key ([char]27) Escape))
    function Read-DialogKey { $keys.Dequeue() }
    function Clear-DialogKeyQueue { }
    function Get-ConsoleSize { return @(70, 15) }
    $res = Show-MailboxDialog -Row $row -Domain 'archive.example.com'
    Assert ($null -eq $res) 'Show-MailboxDialog must refuse Save Enter below 80x20 and cancel on Escape.'
}

Test-Case 'Show-MailboxDialog rejects Save Enter below floor, then commits when resized back' {
    $row = [pscustomobject]@{
        Selected = $false; PrimarySmtpAddress = 'carol@example.com'; CurrentForwarding = ''
        HasOnPremForwarding = $false; DeliverAndStore = $false; ForwardingPrefix = 'carol'; WillForwardTo = 'carol@archive.example.com'
    }
    $keys = New-Object System.Collections.Generic.Queue[object]
    $sizes = New-Object System.Collections.Generic.Queue[object]
    # Tab to Save button (focus 2)
    [void]$sizes.Enqueue(@(70, 15))
    [void]$keys.Enqueue((New-Key ([char]9) Tab))
    [void]$sizes.Enqueue(@(70, 15))
    [void]$keys.Enqueue((New-Key ([char]9) Tab))
    # Enter on Save while undersized (must not commit)
    [void]$sizes.Enqueue(@(70, 15))
    [void]$keys.Enqueue((New-Key ([char]13) Enter))
    # Resized back above floor, Enter on Save commits
    [void]$sizes.Enqueue(@(80, 24))
    [void]$keys.Enqueue((New-Key ([char]13) Enter))
    function Read-DialogKey { $keys.Dequeue() }
    function Clear-DialogKeyQueue { }
    function Get-ConsoleSize { if ($sizes.Count -gt 0) { $sizes.Dequeue() } else { @(80, 24) } }
    $res = Show-MailboxDialog -Row $row -Domain 'archive.example.com'
    Assert ($null -ne $res) 'Show-MailboxDialog must commit Save Enter after terminal is resized back above 80x20.'
    Assert ($res.Prefix -eq 'carol') 'Committed draft prefix must match.'
}

# --- Get-DialogScrollOffset: focus-following viewport math (pure) ----------
Test-Case 'Get-DialogScrollOffset scrolls down to reveal a focus line below the viewport' {
    $result = Get-DialogScrollOffset -Offset 0 -FocusLine 20 -TotalLines 30 -Capacity 5
    Assert ($result -eq 16) 'Focus below the viewport must pull the offset down so focus is the last visible line.'
}
Test-Case 'Get-DialogScrollOffset scrolls up to reveal a focus line above the viewport' {
    $result = Get-DialogScrollOffset -Offset 10 -FocusLine 2 -TotalLines 30 -Capacity 5
    Assert ($result -eq 2) 'Focus above the viewport must pull the offset up to the focus line.'
}
Test-Case 'Get-DialogScrollOffset leaves the offset unchanged when focus is already visible' {
    $result = Get-DialogScrollOffset -Offset 3 -FocusLine 4 -TotalLines 30 -Capacity 5
    Assert ($result -eq 3) 'Focus already inside the viewport must not move the offset.'
}
Test-Case 'Get-DialogScrollOffset clamps to the maximum valid offset' {
    $result = Get-DialogScrollOffset -Offset 0 -FocusLine 29 -TotalLines 30 -Capacity 5
    Assert ($result -eq 25) 'Offset must clamp so the viewport never scrolls past the last line.'
}

# --- Dialog scroll capture: real Show-MailboxDialog/Show-SettingsDialog frames,
# muting each captured frame's ANSI to a StringWriter instead of the console. --
function Get-CapturedDialogFrames([scriptblock]$Action) {
    $writer = New-Object System.IO.StringWriter
    $prev = [Console]::Out
    [Console]::SetOut($writer)
    try { & $Action } finally { [Console]::SetOut($prev) }
    $text = $writer.ToString()
    return @($text -split ([regex]::Escape("$([char]27)[2J")) | Where-Object { $_ })
}

Test-Case 'Show-MailboxDialog: a 200+ char address stays inspectable and Save stays reachable at 80x20' {
    $longLocal = 'a' * 220
    $row = [pscustomobject]@{
        Selected = $false; PrimarySmtpAddress = "$longLocal@example.com"; CurrentForwarding = ''
        HasOnPremForwarding = $false; DeliverAndStore = $false; ForwardingPrefix = $longLocal; WillForwardTo = "$longLocal@archive.example.com"
    }
    $keys = New-Object System.Collections.Generic.Queue[object]
    [void]$keys.Enqueue((New-Key ([char]9) Tab)) # -> DeliverAndStore
    [void]$keys.Enqueue((New-Key ([char]9) Tab)) # -> Save
    [void]$keys.Enqueue((New-Key ([char]13) Enter)) # commit (prefix already valid)
    function Read-DialogKey { $keys.Dequeue() }
    function Clear-DialogKeyQueue { }
    function Get-ConsoleSize { return @(80, 20) }
    $frames = Get-CapturedDialogFrames {
        $script:MailboxDialogResult = Show-MailboxDialog -Row $row -Domain 'archive.example.com'
    }
    Assert ($null -ne $script:MailboxDialogResult) 'Save must remain reachable (committable) even with a very long address at 80x20.'
    $lastFrame = $frames[-1]
    Assert ($lastFrame -match 'Save') 'The final frame before commit must show Save, not scroll past it.'
    $allFrames = $frames -join ''
    Assert ($allFrames.Contains($longLocal.Substring(0, 20))) 'The long address must be inspectable (its wrapped chunks appear) across the rendered frames.'
}

Test-Case 'Show-MailboxDialog: PageDown reaches the final content (Save + error) after a rejected blank Save at 80x20' {
    $row = [pscustomobject]@{
        Selected = $false; PrimarySmtpAddress = 'erin@example.com'; CurrentForwarding = ''
        HasOnPremForwarding = $false; DeliverAndStore = $false; ForwardingPrefix = 'erin'; WillForwardTo = 'erin@archive.example.com'
    }
    $keys = New-Object System.Collections.Generic.Queue[object]
    for ($i = 0; $i -lt 'erin'.Length; $i++) { [void]$keys.Enqueue((New-Key ([char]8) Backspace)) }
    [void]$keys.Enqueue((New-Key ([char]9) Tab))
    [void]$keys.Enqueue((New-Key ([char]9) Tab))
    [void]$keys.Enqueue((New-Key ([char]13) Enter)) # rejected: blank prefix, error appended
    [void]$keys.Enqueue((New-Key ([char]0) PageDown))
    [void]$keys.Enqueue((New-Key ([char]27) Escape))
    function Read-DialogKey { $keys.Dequeue() }
    function Clear-DialogKeyQueue { }
    function Get-ConsoleSize { return @(80, 20) }
    $frames = Get-CapturedDialogFrames {
        [void](Show-MailboxDialog -Row $row -Domain 'archive.example.com')
    }
    $lastFrame = $frames[-1]
    Assert ($lastFrame -match 'Error: Forwarding prefix cannot be blank') 'PageDown must reach the final content: the rejection error at the bottom of the body.'
}

Test-Case 'Show-SettingsDialog: a 200+ char domain stays inspectable and Save stays reachable at 80x20' {
    $config = [pscustomobject]@{
        ForwardingDomain           = (('d' * 60) + '.') * 4 + 'example.com'
        ServiceAccountUPN          = 'admin@example.com'
        CacheTtlHours              = 24
        DeliverToMailboxAndForward = $false
    }
    $keys = New-Object System.Collections.Generic.Queue[object]
    [void]$keys.Enqueue((New-Key ([char]9) Tab)) # -> ServiceAccountUPN
    [void]$keys.Enqueue((New-Key ([char]9) Tab)) # -> CacheTtlHours
    [void]$keys.Enqueue((New-Key ([char]9) Tab)) # -> DeliverToMailboxAndForward
    [void]$keys.Enqueue((New-Key ([char]9) Tab)) # -> Save
    [void]$keys.Enqueue((New-Key ([char]13) Enter)) # commit
    function Read-DialogKey { $keys.Dequeue() }
    function Clear-DialogKeyQueue { }
    function Get-ConsoleSize { return @(80, 20) }
    $frames = Get-CapturedDialogFrames {
        $script:SettingsDialogResult = Show-SettingsDialog -Config $config
    }
    Assert ($null -ne $script:SettingsDialogResult) 'Save must remain reachable even with a very long forwarding domain at 80x20.'
    $lastFrame = $frames[-1]
    Assert ($lastFrame -match 'Save') 'The final frame before commit must show Save, not scroll past it.'
    $allFrames = $frames -join ''
    Assert ($allFrames.Contains($config.ForwardingDomain.Substring(0, 20))) 'The long domain must be inspectable across the rendered frames.'
}

Test-Case 'Show-MailboxDialog: invalid long prefix at 80x20 anchors error tail then PageUp captures earlier content distinct from tail' {
    $longPrefix = 'bad prefix ' + ('x' * 300)
    $row = [pscustomobject]@{
        Selected = $false; PrimarySmtpAddress = 'user@example.com'; CurrentForwarding = ''
        HasOnPremForwarding = $false; DeliverAndStore = $false; ForwardingPrefix = $longPrefix; WillForwardTo = ''
    }
    $keys = New-Object System.Collections.Generic.Queue[object]
    [void]$keys.Enqueue((New-Key ([char]9) Tab)) # -> DeliverAndStore
    [void]$keys.Enqueue((New-Key ([char]9) Tab)) # -> Save
    [void]$keys.Enqueue((New-Key ([char]13) Enter)) # commit attempt fails validation -> anchors error tail
    [void]$keys.Enqueue((New-Key ([char]0) PageUp)) # PageUp scrolls up toward earlier content
    [void]$keys.Enqueue((New-Key ([char]27) Escape)) # exit
    function Read-DialogKey { $keys.Dequeue() }
    function Clear-DialogKeyQueue { }
    function Get-ConsoleSize { return @(80, 20) }
    $frames = Get-CapturedDialogFrames {
        [void](Show-MailboxDialog -Row $row -Domain 'example.com')
    }
    $errorTailFrame = $frames[3]
    $pagedUpFrame = $frames[4]

    Assert ($errorTailFrame -match 'Error: Invalid forwarding prefix') 'Validation failure must anchor the frame to show the error message at the tail.'
    Assert ($errorTailFrame -notmatch 'Mailbox: user@example.com') 'Error tail frame must have scrolled the initial mailbox header out of view.'

    Assert ($pagedUpFrame -match 'Mailbox: user@example.com') 'PageUp after validation error must capture earlier content instead of remaining stuck at tail.'
    Assert ($pagedUpFrame -notmatch 'Error: Invalid forwarding prefix') 'Paged-up frame must be distinct from the tail error frame.'
}

Test-Case 'Show-SettingsDialog: invalid long domain at 80x20 anchors error tail then PageUp captures earlier content distinct from tail' {
    $config = [pscustomobject]@{
        ForwardingDomain           = ('invalid domain ' + ('d' * 350))
        ServiceAccountUPN          = 'admin@example.com'
        CacheTtlHours              = 24
        DeliverToMailboxAndForward = $false
    }
    $keys = New-Object System.Collections.Generic.Queue[object]
    [void]$keys.Enqueue((New-Key ([char]9) Tab)) # -> ServiceAccountUPN
    [void]$keys.Enqueue((New-Key ([char]9) Tab)) # -> CacheTtlHours
    [void]$keys.Enqueue((New-Key ([char]9) Tab)) # -> DeliverToMailboxAndForward
    [void]$keys.Enqueue((New-Key ([char]9) Tab)) # -> Save
    [void]$keys.Enqueue((New-Key ([char]13) Enter)) # commit attempt fails validation -> anchors error tail
    [void]$keys.Enqueue((New-Key ([char]0) PageUp)) # PageUp scrolls up toward earlier content
    [void]$keys.Enqueue((New-Key ([char]27) Escape)) # exit
    function Read-DialogKey { $keys.Dequeue() }
    function Clear-DialogKeyQueue { }
    function Get-ConsoleSize { return @(80, 20) }
    $frames = Get-CapturedDialogFrames {
        [void](Show-SettingsDialog -Config $config)
    }
    $errorTailFrame = $frames[5]
    $pagedUpFrame = $frames[6]

    Assert ($errorTailFrame -match 'Error: ForwardingDomain is not a valid hostname') 'Validation failure must anchor the frame to show the error message at the tail.'
    Assert ($errorTailFrame -notmatch 'Forwarding domain:      invalid domain') 'Error tail frame must have scrolled the initial domain label line out of view.'

    Assert ($pagedUpFrame -match 'Forwarding domain:      invalid domain') 'PageUp after validation error must capture earlier content instead of remaining stuck at tail.'
    Assert ($pagedUpFrame -notmatch 'Error: ForwardingDomain is not a valid hostname') 'Paged-up frame must be distinct from the tail error frame.'
}
} finally {
    try {
        [Console]::SetOut($script:OriginalConsoleOut)
    } catch { }
}

if ($failures.Count) { throw ($failures -join "`n") }
Write-Host 'TUI console/view checks passed (geometry, cursor, wrapping, control safety, lifecycle restoration).'
