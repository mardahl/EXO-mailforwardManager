# Modal dialogs for the TUI: settings, mailbox editor, forwarding preview,
# scrollable report, and a progress line. Built on src/10-console.ps1's
# frame primitives (Add-FrameLine, ConvertTo-DisplayText, Get-ConsoleSize,
# $script:T/$script:G/$script:ESC) and src/70-views.ps1's Get-PreviewFrame/
# Split-DisplayChunks for wrapped body text. Every loop here reads input
# through Read-DialogKey so tests can stub key input at this one boundary
# without touching [Console] or the model - that indirection stays local to
# this file rather than becoming a general input abstraction.

function Read-DialogKey {
    while (-not [Console]::KeyAvailable) { Start-Sleep -Milliseconds 15 }
    [Console]::ReadKey($true)
}

function Clear-DialogKeyQueue {
    # Drain any keys queued before/while a dialog opens or a busy operation
    # (apply) ran, so leftover keystrokes never leak into the next read.
    while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }
}

function Get-DialogBox {
    param([Parameter(Mandatory)][int]$BodyHeight, [int]$MinWidth = 50)
    $size = Get-ConsoleSize
    $w = $size[0]; $h = $size[1]
    # Boxes take ~80% of the screen (never below MinWidth, never past w-4)
    # so long domains/UPNs and error text stay on one line on normal terminals.
    $boxW = [Math]::Min([Math]::Max($MinWidth, [int]($w * 0.8)), [Math]::Max(20, $w - 4))
    $maxBodyCap = [Math]::Max(1, $h - 5)
    $bodyH = [Math]::Max(1, [Math]::Min($BodyHeight, $maxBodyCap))
    $boxH = $bodyH + 3
    $x = [Math]::Max(1, [int](($w - $boxW) / 2) + 1)
    $y = [Math]::Max(1, [int](($h - $boxH) / 2) + 1)
    # BodyCapacity is the actual per-call clamped body height ($bodyH), not the
    # screen's raw maximum ($maxBodyCap): the box's H/Y were centered on
    # $bodyH, so Write-DialogFrame's footer row (Y + 1 + BodyCapacity) must use
    # the same value or the footer is drawn past the visually centered box -
    # and, on a short body with a tall terminal, potentially off-screen.
    return @{ X = $x; Y = $y; W = $boxW; H = $boxH; InnerW = $boxW - 4; BodyCapacity = $bodyH; ScreenW = $w; ScreenH = $h }
}

function Get-DialogScrollOffset {
    # Shared scroll-follow math for field-editor dialogs (Settings, mailbox
    # editor): keeps $FocusLine inside the viewport, clamped to the actual
    # scrollable range. Callers re-derive $FocusLine themselves; PageUp/
    # PageDown callers pass their own already-adjusted $Offset with
    # $FocusLine set to a value already inside the desired window so this
    # only clamps, never re-snaps to focus.
    param(
        [Parameter(Mandatory)][int]$Offset,
        [Parameter(Mandatory)][int]$FocusLine,
        [Parameter(Mandatory)][int]$TotalLines,
        [Parameter(Mandatory)][int]$Capacity
    )
    if ($FocusLine -lt $Offset) { $Offset = $FocusLine }
    elseif ($FocusLine -ge $Offset + $Capacity) { $Offset = $FocusLine - $Capacity + 1 }
    $maxOffset = [Math]::Max(0, $TotalLines - $Capacity)
    return [Math]::Max(0, [Math]::Min($Offset, $maxOffset))
}

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
            [void]$sb.Append($t.FootBg + $t.HotKey + $tok)
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
        if ($i -lt $BodyLines.Count -and ($BodyLines[$i] -is [hashtable]) -and $BodyLines[$i].HotKey) {
            $hk = [string]$BodyLines[$i].HotKey
            # $cell = "  " + hotkey + rest; recolor the hotkey char only.
            $cell = $cell.Substring(0, 2) + $t.HotKey + $hk + $pair[0] + $cell.Substring(2 + $hk.Length)
        }
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


function Show-SettingsDialog {
    # Multi-field editor over a copied draft; $Config itself is never
    # mutated. Tab/Shift+Tab moves focus (wraps), Space toggles the boolean
    # field, Enter only commits when focus is on Save (validated via
    # Test-ForwardingConfig; failures redisplay the same draft with an error
    # line instead of returning). Escape/Ctrl+C cancels with $null, no save.
    param($Config)
    $draft = @{
        ForwardingDomain           = if ($Config) { [string]$Config.ForwardingDomain } else { '' }
        ServiceAccountUPN          = if ($Config) { [string]$Config.ServiceAccountUPN } else { '' }
        CacheTtlHours              = if ($Config) { [string]$Config.CacheTtlHours } else { '24' }
        DeliverToMailboxAndForward = if ($Config) { [bool]$Config.DeliverToMailboxAndForward } else { $false }
    }
    $fields = @('ForwardingDomain', 'ServiceAccountUPN', 'CacheTtlHours', 'DeliverToMailboxAndForward', 'Save')
    $focus = 0
    $prevFocus = -1
    $offset = 0
    $errorText = ''
    $prevErrorText = ''
    $anchorErrorTail = $false
    Clear-DialogKeyQueue
    while ($true) {
        # Wrap each labeled field independently so a long domain/UPN stays
        # fully inspectable (recoverable via Split-DisplayChunks) instead of
        # being cut off at the box width; a probe pass with BodyHeight 1
        # gives InnerW before the real body height (which depends on the
        # wrapped line count) is known.
        $probe = Get-DialogBox -BodyHeight 1
        $wrapWidth = [Math]::Max(10, $probe.InnerW)
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

        $box = Get-DialogBox -BodyHeight $lines.Count
        if ($focus -ne $prevFocus) {
            $offset = Get-DialogScrollOffset -Offset $offset -FocusLine $fieldLine[$fields[$focus]] -TotalLines $lines.Count -Capacity $box.BodyCapacity
            $prevFocus = $focus
            $anchorErrorTail = $false
        } elseif ($anchorErrorTail -or ($errorText -and ($errorText -ne $prevErrorText))) {
            # A failed Save keeps focus on Save; realign to the tail only when
            # an error first appears or changes so the freshly appended error is
            # visible without preventing subsequent user paging.
            $offset = [Math]::Max(0, $lines.Count - $box.BodyCapacity)
            $anchorErrorTail = $false
        } else {
            $maxOffset = [Math]::Max(0, $lines.Count - $box.BodyCapacity)
            $offset = [Math]::Max(0, [Math]::Min($offset, $maxOffset))
        }
        $prevErrorText = $errorText
        $visible = @($lines | Select-Object -Skip $offset -First $box.BodyCapacity)
        [void](Write-DialogFrame -Title 'Settings' -BodyLines $visible `
            -FooterHint 'Tab next field  Space toggle  PgUp/PgDn scroll  Enter on Save  Esc cancel')

        $key = Read-DialogKey
        if (($key.Modifiers -band [ConsoleModifiers]::Control) -and $key.Key -eq 'C') { return $null }
        if ($key.Key -eq 'Escape') { return $null }
        if ($key.Key -eq 'PageUp') { $offset = [Math]::Max(0, $offset - $box.BodyCapacity); continue }
        if ($key.Key -eq 'PageDown') { $offset = [Math]::Min([Math]::Max(0, $lines.Count - $box.BodyCapacity), $offset + $box.BodyCapacity); continue }
        if ($key.Key -eq 'Tab') {
            $delta = if ($key.Modifiers -band [ConsoleModifiers]::Shift) { -1 } else { 1 }
            $focus = ($focus + $delta + $fields.Count) % $fields.Count
            continue
        }
        $current = $fields[$focus]
        if ($current -eq 'DeliverToMailboxAndForward') {
            if ($key.Key -eq 'Spacebar') { $draft.DeliverToMailboxAndForward = -not $draft.DeliverToMailboxAndForward }
            continue
        }
        if ($current -eq 'Save') {
            if ($key.Key -eq 'Enter' -and -not (Test-TuiBelowFloor)) {
                # Validate the raw typed text first - do not pre-coerce with
                # TryParse (its out-param is 0 on failure, which would
                # silently turn "not a number" into an accepted TTL of 0)
                # before Test-ForwardingConfig ever sees it. Save is also
                # refused outright below the 80x20 floor (Test-TuiBelowFloor)
                # so a garbled layout can never commit a config change.
                $candidate = [pscustomobject]@{
                    ForwardingDomain           = $draft.ForwardingDomain.Trim()
                    ServiceAccountUPN          = $draft.ServiceAccountUPN.Trim()
                    CacheTtlHours              = $draft.CacheTtlHours
                    DeliverToMailboxAndForward = [bool]$draft.DeliverToMailboxAndForward
                }
                $errors = @(Test-ForwardingConfig -Config $candidate)
                if ($errors.Count -gt 0) {
                    $errorText = $errors -join '; '
                    $anchorErrorTail = $true
                    continue
                }
                $ttlInt = 0
                [void][int]::TryParse([string]$candidate.CacheTtlHours, [ref]$ttlInt)
                $candidate.CacheTtlHours = $ttlInt
                return $candidate
            }
            continue
        }
        # Text field (ForwardingDomain / ServiceAccountUPN / CacheTtlHours).
        if ($key.Key -eq 'Enter') { continue } # Enter only commits from Save.
        if ($key.Key -eq 'Backspace') {
            if ($draft[$current].Length -gt 0) { $draft[$current] = $draft[$current].Substring(0, $draft[$current].Length - 1) }
            continue
        }
        if ($key.KeyChar -and -not [char]::IsControl($key.KeyChar)) {
            $draft[$current] += $key.KeyChar
        }
    }
}

function Show-MailboxDialog {
    # Per-row prefix/keep-copy editor. Validates against a throwaway clone
    # of $Row via Set-MailboxDraft (never the real row, so a cancel/invalid
    # attempt leaves $Row untouched); only the returned hashtable lets the
    # caller commit to the real row. The proposed destination is wrapped
    # with Split-DisplayChunks so a long address is fully inspectable
    # rather than being cut off at the box width.
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][string]$Domain
    )
    $prefix = [string]$Row.ForwardingPrefix
    $deliver = [bool]$Row.DeliverAndStore
    $fields = @('Prefix', 'DeliverAndStore', 'Save')
    $focus = 0
    $prevFocus = -1
    $offset = 0
    $errorText = ''
    $prevErrorText = ''
    $anchorErrorTail = $false
    Clear-DialogKeyQueue
    while ($true) {
        $willTo = if ($prefix) { "$prefix@$Domain" } else { '' }
        $probe = Get-DialogBox -BodyHeight 1
        $wrapWidth = [Math]::Max(10, $probe.InnerW)
        $mailboxWrapped = @(Split-DisplayChunks -Text "Mailbox: $($Row.PrimarySmtpAddress)" -Width $wrapWidth)
        $wrapped = @(Split-DisplayChunks -Text $willTo -Width $wrapWidth)

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

        $box = Get-DialogBox -BodyHeight $lines.Count
        if ($focus -ne $prevFocus) {
            $offset = Get-DialogScrollOffset -Offset $offset -FocusLine $fieldLine[$fields[$focus]] -TotalLines $lines.Count -Capacity $box.BodyCapacity
            $prevFocus = $focus
            $anchorErrorTail = $false
        } elseif ($anchorErrorTail -or ($errorText -and ($errorText -ne $prevErrorText))) {
            # A failed Save keeps focus on Save; realign to the tail only when
            # an error first appears or changes so the freshly appended error is
            # visible without preventing subsequent user paging.
            $offset = [Math]::Max(0, $lines.Count - $box.BodyCapacity)
            $anchorErrorTail = $false
        } else {
            $maxOffset = [Math]::Max(0, $lines.Count - $box.BodyCapacity)
            $offset = [Math]::Max(0, [Math]::Min($offset, $maxOffset))
        }
        $prevErrorText = $errorText
        $visible = @($lines | Select-Object -Skip $offset -First $box.BodyCapacity)
        [void](Write-DialogFrame -Title 'Edit forwarding' -BodyLines $visible `
            -FooterHint 'Tab next field  Space toggle  PgUp/PgDn scroll  Enter on Save  Esc cancel')

        $key = Read-DialogKey
        if (($key.Modifiers -band [ConsoleModifiers]::Control) -and $key.Key -eq 'C') { return $null }
        if ($key.Key -eq 'Escape') { return $null }
        if ($key.Key -eq 'PageUp') { $offset = [Math]::Max(0, $offset - $box.BodyCapacity); continue }
        if ($key.Key -eq 'PageDown') { $offset = [Math]::Min([Math]::Max(0, $lines.Count - $box.BodyCapacity), $offset + $box.BodyCapacity); continue }
        if ($key.Key -eq 'Tab') {
            $delta = if ($key.Modifiers -band [ConsoleModifiers]::Shift) { -1 } else { 1 }
            $focus = ($focus + $delta + $fields.Count) % $fields.Count
            continue
        }
        $current = $fields[$focus]
        if ($current -eq 'DeliverAndStore') {
            if ($key.Key -eq 'Spacebar') { $deliver = -not $deliver }
            continue
        }
        if ($current -eq 'Save') {
            if ($key.Key -eq 'Enter' -and -not (Test-TuiBelowFloor)) {
                $clone = [pscustomobject]@{
                    ForwardingPrefix = $Row.ForwardingPrefix
                    DeliverAndStore  = $Row.DeliverAndStore
                    WillForwardTo    = $Row.WillForwardTo
                }
                try {
                    Set-MailboxDraft -Row $clone -Prefix $prefix -DeliverAndStore $deliver -Domain $Domain
                } catch {
                    $errorText = $_.Exception.Message
                    $anchorErrorTail = $true
                    continue
                }
                return @{ Prefix = $prefix; DeliverAndStore = $deliver }
            }
            continue
        }
        if ($key.Key -eq 'Enter') { continue }
        if ($key.Key -eq 'Backspace') {
            if ($prefix.Length -gt 0) { $prefix = $prefix.Substring(0, $prefix.Length - 1) }
            continue
        }
        if ($key.KeyChar -and -not [char]::IsControl($key.KeyChar)) {
            $prefix += $key.KeyChar
        }
    }
}

function Show-PreviewDialog {
    # Explicit Y/N confirmation over the (already selected/copied) preview
    # rows. Scrolling is allowed before any decision; Enter is deliberately
    # not wired to confirm, so an accidental Enter from the main table can
    # never apply a batch. Returns $true only on an explicit Y.
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Rows)
    Clear-DialogKeyQueue
    $offset = 0
    while ($true) {
        $size = Get-ConsoleSize
        $bodyH = [Math]::Max(4, $size[1] - 1)
        $bodyW = [Math]::Max(20, $size[0])
        $preview = Get-PreviewFrame -Rows $Rows -Offset $offset -Width $bodyW -Height $bodyH

        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append("$script:ESC[2J")
        [void]$sb.Append($preview.Frame)
        $hint = ConvertTo-DisplayText -Text " $($Rows.Count) selected - Up/Down/PgUp/PgDn scroll  Y apply  N/Esc cancel" -Width $bodyW
        $colored = (Format-KeyHint -Text $hint).Replace($script:T.HotKey + 'Y', $script:T.FootBg + $script:T.Good + 'Y').Replace($script:T.HotKey + 'N/Esc', $script:T.FootBg + $script:T.Danger + 'N/Esc')
        Add-FrameLine -Sb $sb -Row $size[1] -Content ($script:T.FootBg + $colored)
        [Console]::Write($sb.ToString())

        $key = Read-DialogKey
        if (($key.Modifiers -band [ConsoleModifiers]::Control) -and $key.Key -eq 'C') { return $false }
        switch ($key.Key) {
            'UpArrow'   { if ($offset -gt 0) { $offset-- }; continue }
            'DownArrow' { if ($offset -lt [Math]::Max(0, $preview.LineCount - $bodyH)) { $offset++ }; continue }
            'PageUp'    { $offset = [Math]::Max(0, $offset - $bodyH); continue }
            'PageDown'  { $offset = [Math]::Min([Math]::Max(0, $preview.LineCount - $bodyH), $offset + $bodyH); continue }
            'Escape'    { return $false }
        }
        $upper = [char]::ToUpper($key.KeyChar)
        if ($upper -eq 'N') { return $false }
        # Below the 80x20 floor the frame itself may be truncated/garbled;
        # never let Y commit a batch of writes against a layout the operator
        # cannot actually read in full. Resizing back above the floor makes
        # Y work again on the next loop iteration.
        if ($upper -eq 'Y' -and -not (Test-TuiBelowFloor)) { return $true }
        # Any other key (including Enter) is ignored - confirmation is Y/N only.
    }
}

function Show-ReportDialog {
    # Read-only scrollable report; no return value.
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines
    )
    Clear-DialogKeyQueue
    $offset = 0
    while ($true) {
        # Wrap each logical line to the box's inner width before paginating
        # so a long line (e.g. an Exchange error message) remains fully
        # readable across multiple rows instead of being clipped with an
        # ellipsis by Write-DialogFrame's fixed-width cell rendering.
        $probe = Get-DialogBox -BodyHeight ([Math]::Max(1, $Lines.Count))
        $wrapWidth = [Math]::Max(10, $probe.InnerW)
        $wrapped = New-Object System.Collections.Generic.List[string]
        foreach ($line in $Lines) {
            foreach ($chunk in (Split-DisplayChunks -Text ([string]$line) -Width $wrapWidth)) {
                [void]$wrapped.Add($chunk)
            }
        }
        $box = Get-DialogBox -BodyHeight $wrapped.Count
        $visible = @($wrapped | Select-Object -Skip $offset -First $box.BodyCapacity)
        [void](Write-DialogFrame -Title $Title -BodyLines $visible -FooterHint 'Up/Down/PgUp/PgDn scroll  Enter/Esc close')
        $key = Read-DialogKey
        if (($key.Modifiers -band [ConsoleModifiers]::Control) -and $key.Key -eq 'C') { return }
        switch ($key.Key) {
            'Enter'     { return }
            'Escape'    { return }
            'UpArrow'   { if ($offset -gt 0) { $offset-- } }
            'DownArrow' { if ($offset -lt [Math]::Max(0, $wrapped.Count - $box.BodyCapacity)) { $offset++ } }
            'PageUp'    { $offset = [Math]::Max(0, $offset - $box.BodyCapacity) }
            'PageDown'  { $offset = [Math]::Min([Math]::Max(0, $wrapped.Count - $box.BodyCapacity), $offset + $box.BodyCapacity) }
        }
    }
}

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

function Get-ProgressBar {
    param([Parameter(Mandatory)][int]$Index, [Parameter(Mandatory)][int]$Total, [Parameter(Mandatory)][int]$Width)
    $total = [Math]::Max(1, $Total)
    $fill = [Math]::Min($Width, [int]($Width * $Index / $total))
    return ([string]$script:G.Bar * $fill) + ([string]$script:G.H * ($Width - $fill))
}

function Show-FetchProgress {
    # Busy modal for Get-MailboxList's -OnProgress callback (initial state
    # and 100-record boundaries). Total count is unknown until the fetch
    # finishes, so this shows a status line and a running count - no bar.
    # No key reads: safe to call synchronously from the callback.
    param([Parameter(Mandatory)][hashtable]$Progress)
    $text = [string]$Progress.Status
    if ($Progress.Count) { $text += " ($($Progress.Count) so far)" }
    [void](Write-DialogFrame -Title 'Refreshing mailboxes' -BodyLines @(
        '',
        @{ Text = $text; Style = 'Focus' },
        '',
        @{ Text = 'Please wait - keys are ignored until the fetch completes.'; Style = 'Dim' }
    ) -FooterHint 'Working...')
}

function Show-OperationProgress {
    # Progress modal for Set-MailboxForwards's -OnProgress callback, once
    # per row. No key reads, so it never blocks the apply loop.
    param([Parameter(Mandatory)][hashtable]$Progress)
    $index = [int]$Progress.Index
    $total = [Math]::Max(1, [int]$Progress.Total)
    $pct = [int](100 * $index / $total)
    $probe = Get-DialogBox -BodyHeight 1
    $barW = [Math]::Max(10, $probe.InnerW - 8)
    $bar = Get-ProgressBar -Index $index -Total $total -Width $barW
    [void](Write-DialogFrame -Title "Applying forwarding $index/$total" -BodyLines @(
        '',
        @{ Text = "$bar $($pct.ToString().PadLeft(3))%"; Style = 'Row' },
        '',
        @{ Text = [string]$Progress.Mailbox; Style = 'Focus' },
        '',
        @{ Text = 'Do not close the window; a report follows when done.'; Style = 'Dim' }
    ) -FooterHint 'Working...')
}
