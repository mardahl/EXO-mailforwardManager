# Main-table key dispatch. Acts on $script:UI (Task 2's model functions:
# Update-MailboxView, Set-MailboxSelection, Set-MailboxDraft, Merge-
# MailboxRefresh) and opens the Task 5 dialogs (src/20-dialogs.ps1). One
# switch, no command registry, per the brief.

function Invoke-TuiRefresh {
    try {
        # Get-MailboxList buffers the whole result before returning (see
        # src/40-exchange.ps1) - a mid-fetch failure throws before this line,
        # so Merge-MailboxRefresh (and the existing cache/model state) is
        # never reached and nothing is discarded. -OnProgress renders the
        # busy state directly into the TUI frame instead of the console.
        $fresh = @(Get-MailboxList -Force -OnProgress { param($p) Show-FetchProgress -Progress $p })
        Clear-DialogKeyQueue
        Merge-MailboxRefresh -State $script:UI -Mailboxes $fresh
        Update-MailboxView -State $script:UI
        $script:UI.Status = 'Refresh complete.'
    } catch {
        Clear-DialogKeyQueue
        Show-ReportDialog -Title 'Refresh failed' -Lines @("Refresh failed; existing list and cache were not changed.", $_.Exception.Message)
    }
    $script:UI.Dirty = $true
}

function Invoke-TuiSettings {
    $new = Show-SettingsDialog -Config $script:Config
    if ($null -eq $new) { $script:UI.Dirty = $true; return }
    # Write config before replacing $script:Config, per spec.
    Save-Config $new
    $script:Config = $new
    # Recompute proposed forwarding for every row; per-row keep-copy edits
    # (DeliverAndStore) are left untouched.
    foreach ($row in $script:UI.Items) {
        $row.WillForwardTo = if ($row.ForwardingPrefix) { "$($row.ForwardingPrefix)@$($script:Config.ForwardingDomain)" } else { '' }
    }
    Update-MailboxView -State $script:UI
    $script:UI.Dirty = $true
}

function Invoke-TuiApply {
    $selected = @($script:UI.Items | Where-Object Selected)
    if ($selected.Count -eq 0) {
        $script:UI.Status = 'No mailboxes selected.'
        $script:UI.Dirty = $true
        return
    }
    try {
        $preview = @(New-ForwardingPreview -Rows $selected)
    } catch {
        Show-ReportDialog -Title 'Preview failed' -Lines @($_.Exception.Message)
        $script:UI.Dirty = $true
        return
    }
    if (Show-PreviewDialog -Rows $preview) {
        try {
            $result = Set-MailboxForwards -Rows $preview -OnProgress {
                param($i, $t, $m)
                Show-OperationProgress -Progress @{ Index = $i; Total = $t; Mailbox = $m }
            }
        } catch {
            Clear-DialogKeyQueue
            Show-ReportDialog -Title 'Apply aborted' -Lines @("Apply aborted before any change was made: $($_.Exception.Message)")
            $script:UI.Dirty = $true
            return
        }
        Clear-DialogKeyQueue
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
    $script:UI.Dirty = $true
}

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

function Invoke-TuiKey {
    param([Parameter(Mandatory)][System.ConsoleKeyInfo]$Key)

    # Minimum-size guard: below the 80x20 floor (src/70-views.ps1's
    # Get-MailboxFrame already shows resize guidance instead of the table),
    # only allow quitting - no search/edit/apply on an unusable layout.
    # $script:UI.Height is table-row *capacity* (screen height - 4).
    $screenHeight = [int]$script:UI.Height + 4
    if ([int]$script:UI.Width -lt 80 -or $screenHeight -lt 20) {
        if ((($Key.Modifiers -band [ConsoleModifiers]::Control) -and $Key.Key -eq 'C') -or
            [char]::ToUpper($Key.KeyChar) -eq 'Q') {
            $script:UI.Running = $false
        }
        return
    }

    if ($script:UI.Searching) {
        # Search input capture owns every key here; no global shortcut can
        # fire while the operator is typing a query.
        switch ($Key.Key) {
            'Escape' {
                $script:UI.Searching = $false; $script:UI.Search = ''
                Update-MailboxView -State $script:UI; $script:UI.Dirty = $true
                return
            }
            'Enter' { $script:UI.Searching = $false; $script:UI.Dirty = $true; return }
            'Backspace' {
                if ($script:UI.Search.Length -gt 0) {
                    $script:UI.Search = $script:UI.Search.Substring(0, $script:UI.Search.Length - 1)
                    Update-MailboxView -State $script:UI
                }
                $script:UI.Dirty = $true
                return
            }
        }
        if (($Key.Modifiers -band [ConsoleModifiers]::Control) -and $Key.Key -eq 'C') {
            $script:UI.Searching = $false; $script:UI.Search = ''
            Update-MailboxView -State $script:UI; $script:UI.Dirty = $true
            return
        }
        if ($Key.KeyChar -and -not [char]::IsControl($Key.KeyChar)) {
            $script:UI.Search += $Key.KeyChar
            Update-MailboxView -State $script:UI
        }
        $script:UI.Dirty = $true
        return
    }

    if (($Key.Modifiers -band [ConsoleModifiers]::Control) -and $Key.Key -eq 'C') {
        $script:UI.Running = $false
        return
    }

    switch ($Key.Key) {
        'UpArrow' {
            if ($script:UI.Cursor -gt 0) { $script:UI.Cursor--; Update-MailboxView -State $script:UI; $script:UI.Dirty = $true }
            return
        }
        'DownArrow' {
            if ($script:UI.Cursor -lt (@($script:UI.View).Count - 1)) { $script:UI.Cursor++; Update-MailboxView -State $script:UI; $script:UI.Dirty = $true }
            return
        }
        'PageUp' {
            $cap = [Math]::Max(1, [int]$script:UI.Height)
            $script:UI.Cursor = [Math]::Max(0, $script:UI.Cursor - $cap)
            Update-MailboxView -State $script:UI; $script:UI.Dirty = $true
            return
        }
        'PageDown' {
            $cap = [Math]::Max(1, [int]$script:UI.Height)
            $script:UI.Cursor = [Math]::Min([Math]::Max(0, @($script:UI.View).Count - 1), $script:UI.Cursor + $cap)
            Update-MailboxView -State $script:UI; $script:UI.Dirty = $true
            return
        }
        'Home' { $script:UI.Cursor = 0; Update-MailboxView -State $script:UI; $script:UI.Dirty = $true; return }
        'End' {
            $script:UI.Cursor = [Math]::Max(0, @($script:UI.View).Count - 1)
            Update-MailboxView -State $script:UI; $script:UI.Dirty = $true
            return
        }
        'Spacebar' {
            Set-MailboxSelection -State $script:UI -Mode Toggle
            $script:UI.Dirty = $true
            return
        }
        'Enter' {
            # Enter opens the action menu; it never applies forwarding directly.
            Invoke-TuiRowMenu
            return
        }
        'Escape' { return }
    }

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
}
