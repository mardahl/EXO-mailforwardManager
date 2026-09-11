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
    $boxW = [Math]::Min([Math]::Max($MinWidth, 40), [Math]::Max(20, $w - 4))
    $maxBodyCap = [Math]::Max(1, $h - 6)
    $bodyH = [Math]::Max(1, [Math]::Min($BodyHeight, $maxBodyCap))
    $boxH = $bodyH + 4
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

function Write-DialogFrame {
    # Draws a titled box with body text lines and a footer hint. Recomputes
    # geometry from the current console size on every call, so a resize
    # between keystrokes is picked up on the next repaint.
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$BodyLines,
        [string]$FooterHint = '',
        [switch]$Danger
    )
    $t = $script:T
    $box = Get-DialogBox -BodyHeight $BodyLines.Count
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("$script:ESC[2J")
    $border = if ($Danger) { $t.Danger } else { $t.HeaderHi }
    Add-FrameLine -Sb $sb -Row $box.Y -Content ($border + (ConvertTo-DisplayText -Text " $Title " -Width $box.W))
    for ($i = 0; $i -lt $box.BodyCapacity; $i++) {
        $text = if ($i -lt $BodyLines.Count) { [string]$BodyLines[$i] } else { '' }
        Add-FrameLine -Sb $sb -Row ($box.Y + 1 + $i) -Content ($t.Row + (ConvertTo-DisplayText -Text "  $text" -Width $box.W))
    }
    Add-FrameLine -Sb $sb -Row ($box.Y + 1 + $box.BodyCapacity) -Content ($t.FootTxt + (ConvertTo-DisplayText -Text " $FooterHint" -Width $box.W))
    [Console]::Write($sb.ToString())
    return $box
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
        $wrapWidth = [Math]::Max(10, $probe.InnerW - 4)
        $lines = New-Object System.Collections.Generic.List[string]
        $fieldLine = @{}
        $fieldLine['ForwardingDomain'] = $lines.Count
        foreach ($chunk in (Split-DisplayChunks -Text ('Forwarding domain:      ' + $draft.ForwardingDomain + $(if ($focus -eq 0) { '_' } else { '' })) -Width $wrapWidth)) { [void]$lines.Add($chunk) }
        $fieldLine['ServiceAccountUPN'] = $lines.Count
        foreach ($chunk in (Split-DisplayChunks -Text ('Service account UPN:    ' + $draft.ServiceAccountUPN + $(if ($focus -eq 1) { '_' } else { '' })) -Width $wrapWidth)) { [void]$lines.Add($chunk) }
        $fieldLine['CacheTtlHours'] = $lines.Count
        [void]$lines.Add('Cache TTL (hours):      ' + $draft.CacheTtlHours + $(if ($focus -eq 2) { '_' } else { '' }))
        $fieldLine['DeliverToMailboxAndForward'] = $lines.Count
        [void]$lines.Add('Deliver to mbx+forward: ' + $(if ($draft.DeliverToMailboxAndForward) { '[x]' } else { '[ ]' }))
        [void]$lines.Add('')
        $fieldLine['Save'] = $lines.Count
        [void]$lines.Add($(if ($focus -eq 4) { '> Save <' } else { '  Save  ' }))
        if ($errorText) { [void]$lines.Add(''); [void]$lines.Add("Error: $errorText") }

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
        $wrapWidth = [Math]::Max(10, $probe.InnerW - 4)
        $mailboxWrapped = @(Split-DisplayChunks -Text "Mailbox: $($Row.PrimarySmtpAddress)" -Width $wrapWidth)
        $wrapped = @(Split-DisplayChunks -Text $willTo -Width $wrapWidth)

        $lines = New-Object System.Collections.Generic.List[string]
        $fieldLine = @{}
        foreach ($chunk in $mailboxWrapped) { [void]$lines.Add($chunk) }
        $currentFwd = if ([string]::IsNullOrEmpty($Row.CurrentForwarding)) { '(none)' } else { [string]$Row.CurrentForwarding }
        [void]$lines.Add("Current forwarding:     $currentFwd")
        $onPrem = if ($Row.HasOnPremForwarding) { 'yes' } else { 'no' }
        [void]$lines.Add("On-prem forwarding:     $onPrem")
        $fieldLine['Prefix'] = $lines.Count
        [void]$lines.Add('Prefix:                 ' + $prefix + $(if ($focus -eq 0) { '_' } else { '' }))
        foreach ($chunk in $wrapped) { [void]$lines.Add('  -> ' + $chunk) }
        $fieldLine['DeliverAndStore'] = $lines.Count
        [void]$lines.Add('Deliver to mbx+forward: ' + $(if ($deliver) { '[x]' } else { '[ ]' }))
        [void]$lines.Add('')
        $fieldLine['Save'] = $lines.Count
        [void]$lines.Add($(if ($focus -eq 2) { '> Save <' } else { '  Save  ' }))
        if ($errorText) { [void]$lines.Add(''); [void]$lines.Add("Error: $errorText") }

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
        $hint = " $($Rows.Count) selected - Up/Down/PgUp/PgDn scroll  Y apply  N/Esc cancel"
        Add-FrameLine -Sb $sb -Row $size[1] -Content ($script:T.FootBg + (ConvertTo-DisplayText -Text $hint -Width $bodyW))
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

function Show-FetchProgress {
    # Busy indicator for Get-MailboxList's -OnProgress callback (initial
    # state and 100-record boundaries). Total mailbox count is unknown until
    # the fetch finishes, so this is a single status line - no bar, no
    # spinner, no worker thread.
    param([Parameter(Mandatory)][hashtable]$Progress)
    $size = Get-ConsoleSize
    $text = " $($Progress.Status)"
    if ($Progress.Count) { $text += " ($($Progress.Count) so far)" }
    $sb = New-Object System.Text.StringBuilder
    Add-FrameLine -Sb $sb -Row ([Math]::Max(1, [int]($size[1] / 2))) -Content ($script:T.HeaderHi + (ConvertTo-DisplayText -Text $text -Width $size[0]))
    [Console]::Write($sb.ToString())
}

function Show-OperationProgress {
    # Draws a single progress line only - no key reads, so it is safe to
    # call synchronously from Set-MailboxForwards's -OnProgress callback
    # once per row without blocking the apply loop.
    param([Parameter(Mandatory)][hashtable]$Progress)
    $size = Get-ConsoleSize
    $w = $size[0]; $h = $size[1]
    $index = [int]$Progress.Index
    $total = [Math]::Max(1, [int]$Progress.Total)
    $mailbox = [string]$Progress.Mailbox
    $pct = [int](100 * $index / $total)
    $barW = [Math]::Max(4, [Math]::Min(40, $w - 24))
    $fill = [Math]::Min($barW, [int]($barW * $index / $total))
    $bar = ('#' * $fill) + ('-' * ($barW - $fill))
    $text = " Applying $index/$total [$bar] $pct% - $mailbox"
    $sb = New-Object System.Text.StringBuilder
    Add-FrameLine -Sb $sb -Row ([Math]::Max(1, [int]($h / 2))) -Content ($script:T.HeaderHi + (ConvertTo-DisplayText -Text $text -Width $w))
    [Console]::Write($sb.ToString())
}
