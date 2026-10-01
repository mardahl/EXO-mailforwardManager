# Main table and forwarding-preview rendering. Reads state and returns a
# frame string; never mutates state and never calls Exchange. Adapted
# layout conventions (fixed/flex columns, absolute-positioned frame lines)
# from SOAconverter's src/65-views.ps1 and src/15-drawing.ps1.

$script:MinTuiWidth  = 80
$script:MinTuiHeight = 20

function Get-TableLayout {
    # Selection + keep + warn are fixed-width; the three address columns
    # (mailbox, current forwarding, proposed forwarding) share whatever
    # width remains, per spec: "three address columns share remaining
    # width" / "flags compact".
    param([Parameter(Mandatory)][int]$Width)
    $sel = 3; $keep = 4; $warn = 4; $gaps = 5 # Sel|Addr|Addr|Addr|Keep|Warn = 5 gaps
    $fixed = $sel + $keep + $warn + $gaps
    $flex = $Width - $fixed
    if ($flex -lt 21) { $flex = 21 }
    # Display name column only on wide windows (>=120 cols); capped at 30
    # chars, longer names truncate with an ellipsis. Eats one extra gap.
    $name = 0
    if ($Width -ge 120) { $name = [Math]::Min(30, [int]($flex / 4)); $flex -= $name + 1 }
    $addr = [int]($flex / 3)
    $last = $flex - ($addr * 2)
    return @{ Sel = $sel; Keep = $keep; Warn = $warn; Name = $name; Addr1 = $addr; Addr2 = $addr; Addr3 = $last }
}

function Get-MailboxFrame {
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][int]$Height
    )
    $sb = New-Object System.Text.StringBuilder

    if ($Width -lt $script:MinTuiWidth -or $Height -lt $script:MinTuiHeight) {
        $msg = "Terminal too small ($Width x $Height). Resize to at least ${script:MinTuiWidth}x${script:MinTuiHeight} or press Q to quit."
        for ($r = 1; $r -le $Height; $r++) {
            $content = if ($r -eq [Math]::Max(1, [int]($Height / 2))) {
                $script:T.Danger + (ConvertTo-DisplayText -Text $msg -Width $Width)
            } else { '' }
            Add-FrameLine -Sb $sb -Row $r -Content $content
        }
        return $sb.ToString()
    }

    $t = $script:T
    $counts = Get-SelectionCounts -State $State
    $total = @($State.Items).Count
    $visible = @($State.View).Count

    # Row 1: connection/account/domain/cache-age header.
    $account = if ($State.Account) { [string]$State.Account } else { '(not signed in)' }
    $cacheAge = if ($State.CacheFetchedAt) { [string]$State.CacheFetchedAt } else { 'none' }
    $h1 = " ExoMft  Account: $account  Cache: $cacheAge"
    Add-FrameLine -Sb $sb -Row 1 -Content ($t.HeaderHi + (ConvertTo-DisplayText -Text $h1 -Width $Width))

    # Row 2: visible/total, selection, search/filter - counts always render
    # from Items/View counts, never by indexing a possibly-empty row.
    $selStyle = if ($counts.Total -gt 0) { $t.SelMark } else { $t.HeaderTxt }
    $h2a = ConvertTo-DisplayText -Text " Visible: $visible/$total  " -Width (" Visible: $visible/$total  ").Length
    $h2b = "Selected: $($counts.Total) ($($counts.Hidden) hidden)"
    $h2c = "  Search: '$($State.Search)'  Filter: $($State.Filter)"
    $rest = [Math]::Max(0, $Width - $h2a.Length - $h2b.Length)
    if ($State.Searching) {
        # Active search: yellow input field, black text, blinking block caret.
        $label = '  SEARCH: '
        $tail = "  Filter: $($State.Filter)"
        $fieldW = [Math]::Max(1, $rest - $label.Length - $tail.Length - 1)
        $q = [string]$State.Search
        if ($q.Length -gt $fieldW - 2) { $q = $q.Substring($q.Length - ($fieldW - 2)) }
        $field = $t.SearchHi + ' ' + $q + $t.SearchCaret + $script:G.Bar + $t.SearchHi + (' ' * [Math]::Max(0, $fieldW - $q.Length - 2))
        $h2cOut = $t.HeaderHi + $label + $field + $t.HeaderTxt + (ConvertTo-DisplayText -Text $tail -Width ([Math]::Max(0, $rest - $label.Length - $fieldW)))
    } else {
        $h2cOut = ConvertTo-DisplayText -Text $h2c -Width $rest
    }
    Add-FrameLine -Sb $sb -Row 2 -Content ($t.HeaderTxt + $h2a + $t.HeaderBg + $selStyle + $h2b + $t.HeaderTxt + $h2cOut)

    # Row 3: column heading.
    $layout = Get-TableLayout -Width $Width
    $head = ' ' + (ConvertTo-DisplayText -Text ' ' -Width $layout.Sel) + ' ' +
        $(if ($layout.Name) { (ConvertTo-DisplayText -Text 'Name' -Width $layout.Name) + ' ' }) +
        (ConvertTo-DisplayText -Text 'Mailbox' -Width $layout.Addr1) + ' ' +
        (ConvertTo-DisplayText -Text 'Current forwarding' -Width $layout.Addr2) + ' ' +
        (ConvertTo-DisplayText -Text 'Proposed forwarding' -Width $layout.Addr3) + ' ' +
        (ConvertTo-DisplayText -Text 'Keep' -Width $layout.Keep) + ' ' +
        (ConvertTo-DisplayText -Text 'Warn' -Width $layout.Warn)
    Add-FrameLine -Sb $sb -Row 3 -Content ($t.ColHead + $head)

    # Rows 4..(Height-1): table capacity is Height - 4 rows.
    $capacity = $Height - 4
    $scroll = if ($State.ContainsKey('Scroll')) { [int]$State.Scroll } else { 0 }
    for ($i = 0; $i -lt $capacity; $i++) {
        $row = 4 + $i
        $idx = $scroll + $i
        if ($idx -lt $visible) {
            $item = $State.View[$idx]
            $isCur = ($idx -eq [int]$State.Cursor)
            $base = if ($isCur -and $item.Selected) { $t.SelectedCursor }
                    elseif ($isCur) { $t.CursorFg }
                    elseif ($item.Selected) { $t.Selected }
                    else { $t.Row }
            $selTxt  = ConvertTo-DisplayText -Text $(if ($item.Selected) { $script:G.ChkOn } else { $script:G.ChkOff }) -Width $layout.Sel
            $mbxTxt  = ConvertTo-DisplayText -Text ([string]$item.PrimarySmtpAddress) -Width $layout.Addr1
            if ($layout.Name) { $mbxTxt = (ConvertTo-DisplayText -Text ([string]$item.DisplayName) -Width $layout.Name) + ' ' + $mbxTxt }
            $cur = [string]$item.CurrentForwarding
            if (-not $cur -and $item.HasOnPremForwarding) {
                $cur = '(recipient) ' + $(if ($item.ForwardingRecipient) { [string]$item.ForwardingRecipient } else { 'press R to resolve' })
            }
            $curTxt  = ConvertTo-DisplayText -Text $cur -Width $layout.Addr2
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
            Add-FrameLine -Sb $sb -Row $row -Content ''
        }
    }

    # Footer: key hints + status.
    $status = if ($State.Status) { [string]$State.Status } else { '' }
    $foot = ConvertTo-DisplayText -Text (' Enter Actions  M Menu  Space Sel  / Search  V Validate  P Preview  ? Help  Q Quit  ' + $status) -Width $Width
    Add-FrameLine -Sb $sb -Row $Height -Content ($t.FootBg + (Format-KeyHint -Text $foot))

    return $sb.ToString()
}

function Split-DisplayChunks {
    # Hard-wrap a string into exact-width chunks, no separators inserted,
    # so concatenating the chunks reproduces the original string exactly
    # (per spec: "Full addresses must be recoverable from wrapped text").
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][int]$Width)
    if ($Width -le 0) { return @($Text) }
    if ([string]::IsNullOrEmpty($Text)) { return @('') }
    $chunks = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $Text.Length; $i += $Width) {
        $len = [Math]::Min($Width, $Text.Length - $i)
        [void]$chunks.Add($Text.Substring($i, $len))
    }
    return $chunks.ToArray()
}

function Get-PreviewFrame {
    # Forwarding preview: fixed title + color-coded summary + column header
    # (rows 1-3), then one line per mailbox grouped by risk (Overwrite, Set,
    # Skip). Offset scrolls the body only; LineCount/BodyHeight describe the
    # complete body so the caller can clamp scrolling. Colors carry meaning:
    # amber = replaces an existing forward, green = new forward, gray = no
    # change. -ShowSkipped expands the Skip group (collapsed by default).
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Rows,
        [Parameter(Mandatory)][int]$Offset,
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][int]$Height,
        [switch]$ShowSkipped
    )
    $t = $script:T; $g = $script:G
    $groups = [ordered]@{
        Overwrite = @{ Color = $t.Proposed; Note = 'replaces existing forwarding' }
        Set       = @{ Color = $t.Good;     Note = 'new forwarding' }
        Skip      = @{ Color = $t.RowDim;   Note = 'not changed' }
    }
    $by = @{}
    foreach ($k in $groups.Keys) { $by[$k] = @($Rows | Where-Object { $_.Action -eq $k }) }
    $keepYes = @($Rows | Where-Object DeliverAndStore).Count
    $keepMixed = $keepYes -gt 0 -and $keepYes -lt $Rows.Count

    # Columns: Action | Mailbox | Current -> New [| Keep when mixed]
    $actW = 9; $arrow = " $($g.Arrow) "; $keepW = if ($keepMixed) { 5 } else { 0 }
    $flex = [Math]::Max(21, $Width - 1 - $actW - 1 - 1 - $arrow.Length - $(if ($keepW) { $keepW + 1 } else { 0 }))
    $mbxW = [int]($flex / 3); $curW = [int]($flex / 3); $newW = $flex - $mbxW - $curW
    $cell = { param($text, $w) ConvertTo-DisplayText -Text ([string]$text) -Width $w }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($k in $groups.Keys) {
        $rowsK = $by[$k]
        if (-not $rowsK.Count) { continue }
        $c = $groups[$k].Color
        $collapsed = $k -eq 'Skip' -and -not $ShowSkipped
        $label = " $k ($($rowsK.Count)) $($g.H) $($groups[$k].Note)" + $(if ($collapsed) { ' - press S to show' } else { '' }) + ' '
        $rule = [string]$g.H + [string]$g.H + $label
        [void]$lines.Add($c + (& $cell ($rule + ([string]$g.H * [Math]::Max(0, $Width - $rule.Length))) $Width))
        if ($collapsed) { [void]$lines.Add(''); continue }
        foreach ($r in $rowsK) {
            $line = ' ' + $c + (& $cell $k $actW) + ' ' + $t.Row + (& $cell $r.PrimarySmtpAddress $mbxW) + ' '
            if ($k -eq 'Skip') {
                $why = if ($r.HasOnPremForwarding) { $t.Warn } else { $t.Muted }
                $line += $why + (& $cell $r.SkipReason ($curW + $arrow.Length + $newW))
            } else {
                $cur = if ($r.CurrentForwarding) { $t.RowDim + (& $cell $r.CurrentForwarding $curW) } else { $t.Muted + (& $cell '(none)' $curW) }
                $line += $cur + $t.Muted + $arrow + $c + (& $cell $r.WillForwardTo $newW)
            }
            if ($keepW) {
                $line += ' ' + $(if ($r.DeliverAndStore) { $t.KeepOn + (& $cell 'Yes' $keepW) } else { $t.Muted + (& $cell 'No' $keepW) })
            }
            [void]$lines.Add($line)
        }
        [void]$lines.Add('')
    }

    $sb = New-Object System.Text.StringBuilder
    # Row 1: title. Row 2: summary chips. Row 3: column header.
    $writes = $by.Overwrite.Count + $by.Set.Count
    Add-FrameLine -Sb $sb -Row 1 -Content ($t.HeaderHi + (& $cell " Preview forwarding changes  $($g.V)  $($Rows.Count) selected, $writes to write" $Width))
    $keepTxt = if ($keepMixed) { $t.Warn + 'Mixed' } elseif ($keepYes) { $t.KeepOn + 'Yes' } else { $t.Muted + 'No' }
    $sum = ' ' + $t.Proposed + "$($by.Overwrite.Count) Overwrite" + $t.Muted + '  ' + $t.Good + "$($by.Set.Count) Set" + $t.Muted + '  ' +
        $t.RowDim + "$($by.Skip.Count) Skip" + $t.Muted + "  $($g.V)  Keep: " + $keepTxt
    if ($by.Overwrite.Count) { $sum += $t.Muted + "  $($g.V)  " + $t.Warn + "! review overwrites" }
    if (-not $writes) { $sum += $t.Muted + "  $($g.V)  " + $t.Warn + 'Nothing to apply' }
    Add-FrameLine -Sb $sb -Row 2 -Content $sum
    $head = ' ' + (& $cell 'Action' $actW) + ' ' + (& $cell 'Mailbox' $mbxW) + ' ' + (& $cell 'Current' $curW) + (' ' * $arrow.Length) + (& $cell 'New' $newW)
    if ($keepW) { $head += ' ' + (& $cell 'Keep' $keepW) }
    Add-FrameLine -Sb $sb -Row 3 -Content ($t.ColHead + $head)

    $bodyH = [Math]::Max(1, $Height - 3)
    for ($i = 0; $i -lt $bodyH; $i++) {
        $idx = $Offset + $i
        Add-FrameLine -Sb $sb -Row (4 + $i) -Content $(if ($idx -ge 0 -and $idx -lt $lines.Count) { $lines[$idx] } else { '' })
    }

    return [pscustomobject]@{ Frame = $sb.ToString(); LineCount = $lines.Count; BodyHeight = $bodyH; Writes = $writes }
}
