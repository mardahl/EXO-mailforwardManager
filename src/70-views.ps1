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
    $addr = [int]($flex / 3)
    $last = $flex - ($addr * 2)
    return @{ Sel = $sel; Keep = $keep; Warn = $warn; Addr1 = $addr; Addr2 = $addr; Addr3 = $last }
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
    $h2 = " Visible: $visible/$total  Selected: $($counts.Total) ($($counts.Hidden) hidden)  Search: '$($State.Search)'  Filter: $($State.Filter)"
    Add-FrameLine -Sb $sb -Row 2 -Content ($t.HeaderTxt + (ConvertTo-DisplayText -Text $h2 -Width $Width))

    # Row 3: column heading.
    $layout = Get-TableLayout -Width $Width
    $head = ' ' + (ConvertTo-DisplayText -Text ' ' -Width $layout.Sel) + ' ' +
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
            $sel = if ($item.Selected) { $script:G.ChkOn } else { $script:G.ChkOff }
            $warn = if ($item.HasOnPremForwarding) { 'Y' } else { '' }
            $keep = if ($item.DeliverAndStore) { 'Yes' } else { 'No' }
            $line = ' ' + (ConvertTo-DisplayText -Text $sel -Width $layout.Sel) + ' ' +
                (ConvertTo-DisplayText -Text ([string]$item.PrimarySmtpAddress) -Width $layout.Addr1) + ' ' +
                (ConvertTo-DisplayText -Text ([string]$item.CurrentForwarding) -Width $layout.Addr2) + ' ' +
                (ConvertTo-DisplayText -Text ([string]$item.WillForwardTo) -Width $layout.Addr3) + ' ' +
                (ConvertTo-DisplayText -Text $keep -Width $layout.Keep) + ' ' +
                (ConvertTo-DisplayText -Text $warn -Width $layout.Warn)
            $style = if ($idx -eq [int]$State.Cursor) { $t.CursorFg } else { $t.Row }
            Add-FrameLine -Sb $sb -Row $row -Content ($style + $line)
        } else {
            Add-FrameLine -Sb $sb -Row $row -Content ''
        }
    }

    # Footer: key hints + status.
    $status = if ($State.Status) { [string]$State.Status } else { '' }
    $foot = ' Up/Dn Move  Space Sel  A All  N None  / Search  F Filter  Enter Edit  R Refresh  S Settings  P Preview  ? Help  Q Quit  ' + $status
    Add-FrameLine -Sb $sb -Row $Height -Content ($t.FootBg + (ConvertTo-DisplayText -Text $foot -Width $Width))

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
    # Renders wrapped labeled records (old/proposed destination, keep-copy,
    # explicit Overwrite/Skip/Set text) for the forwarding-preview dialog.
    # LineCount describes the complete wrapped body (independent of Offset)
    # so the caller can scroll to the end.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Rows,
        [Parameter(Mandatory)][int]$Offset,
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][int]$Height
    )
    $t = $script:T
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($r in $Rows) {
        foreach ($chunk in (Split-DisplayChunks -Text ([string]$r.PrimarySmtpAddress) -Width $Width)) {
            [void]$lines.Add($chunk)
        }
        $old = [string]$r.CurrentForwarding
        $new = [string]$r.WillForwardTo
        foreach ($chunk in (Split-DisplayChunks -Text "  $old -> $new" -Width $Width)) {
            [void]$lines.Add($chunk)
        }
        $keep = if ($r.DeliverAndStore) { 'Yes' } else { 'No' }
        [void]$lines.Add("  Keep copy: $keep  [$($r.Action)]")
        [void]$lines.Add('')
    }

    $sb = New-Object System.Text.StringBuilder
    for ($row = 1; $row -le $Height; $row++) {
        $idx = $Offset + $row - 1
        $content = if ($idx -ge 0 -and $idx -lt $lines.Count) {
            $t.Row + (ConvertTo-DisplayText -Text $lines[$idx] -Width $Width)
        } else { '' }
        Add-FrameLine -Sb $sb -Row $row -Content $content
    }

    return [pscustomobject]@{ Frame = $sb.ToString(); LineCount = $lines.Count }
}
