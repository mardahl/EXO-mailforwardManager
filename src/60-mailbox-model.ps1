# Pure mailbox row/state model - no WinForms, no Exchange calls.
# Consumed by the legacy WinForms UI today and by the TUI once it cuts over.

function New-MailboxRows {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Mailboxes,
        [Parameter(Mandatory)]$Config
    )
    foreach ($m in $Mailboxes) {
        $prefix = ($m.PrimarySmtpAddress -split '@')[0]
        $willTo = if ($prefix) { "$prefix@$($Config.ForwardingDomain)" } else { '' }
        [pscustomobject]@{
            Selected            = $false
            PrimarySmtpAddress  = $m.PrimarySmtpAddress
            CurrentForwarding   = $m.ForwardingSmtpAddress
            HasOnPremForwarding = [bool]$m.HasOnPremForwardingAddress
            DeliverAndStore     = [bool]$Config.DeliverToMailboxAndForward
            ForwardingPrefix    = $prefix
            WillForwardTo       = $willTo
        }
    }
}

function Update-MailboxView {
    param([Parameter(Mandatory)][hashtable]$State)

    $State.View = @($State.Items | Where-Object {
        (-not $State.Search -or $_.PrimarySmtpAddress -like "*$($State.Search)*") -and
        ($State.Filter -eq 'All' -or
         ($State.Filter -eq 'HasForward' -and -not [string]::IsNullOrEmpty($_.CurrentForwarding)) -or
         ($State.Filter -eq 'NoForward' -and [string]::IsNullOrEmpty($_.CurrentForwarding)))
    })

    $State.Cursor = [Math]::Max(0, [Math]::Min($State.Cursor, $State.View.Count - 1))

    if (-not $State.ContainsKey('Height') -or [int]$State.Height -le 0 -or $State.View.Count -eq 0) {
        $State.Scroll = 0
        return
    }
    if (-not $State.ContainsKey('Scroll')) { $State.Scroll = 0 }
    $maxScroll = [Math]::Max(0, $State.View.Count - [int]$State.Height)
    $State.Scroll = [Math]::Max(0, [Math]::Min([int]$State.Scroll, $maxScroll))
    if ($State.Cursor -lt $State.Scroll) {
        $State.Scroll = $State.Cursor
    } elseif ($State.Cursor -ge $State.Scroll + [int]$State.Height) {
        $State.Scroll = $State.Cursor - [int]$State.Height + 1
    }
}

function Get-SelectionCounts {
    param([Parameter(Mandatory)][hashtable]$State)
    $total = @($State.Items | Where-Object Selected).Count
    $shown = @($State.View | Where-Object Selected).Count
    [pscustomobject]@{ Total = $total; Hidden = $total - $shown }
}

function Set-MailboxSelection {
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][ValidateSet('Visible', 'None', 'Toggle')][string]$Mode
    )
    switch ($Mode) {
        'Visible' { foreach ($row in $State.View) { $row.Selected = $true } }
        'None'    { foreach ($row in $State.Items) { $row.Selected = $false } }
        'Toggle'  {
            if ($State.View.Count -gt 0) {
                $row = $State.View[$State.Cursor]
                $row.Selected = -not $row.Selected
                $State.Cursor = [Math]::Min($State.Cursor + 1, $State.View.Count - 1)
            }
        }
    }
}

function Set-MailboxDraft {
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Prefix,
        [Parameter(Mandatory)][bool]$DeliverAndStore,
        [Parameter(Mandatory)][string]$Domain
    )
    # Contract: throw before any mutation on invalid input, no output on a
    # valid edit. Callers (dialogs) catch the exception; there is nothing to
    # inspect on success, so mutators never leak a value onto the success
    # stream.
    # ponytail: reject syntax locally; full RFC edge cases aren't worth
    # owning when .NET MailAddress + CheckHostName already cover the ones
    # that matter for a forwarding destination.
    if ([string]::IsNullOrWhiteSpace($Prefix)) {
        throw 'Forwarding prefix cannot be blank.'
    }
    if ($Prefix -match '[\x00-\x1F\x7F]' -or $Prefix -match '\s' -or $Prefix.Contains('@')) {
        throw "Invalid forwarding prefix: '$Prefix'."
    }

    $willTo = "$Prefix@$Domain"
    if (-not (Test-ForwardingDestination -Address $willTo)) {
        throw "Invalid forwarding destination: '$willTo'."
    }

    $Row.ForwardingPrefix = $Prefix
    $Row.DeliverAndStore  = $DeliverAndStore
    $Row.WillForwardTo    = $willTo
}

function Merge-MailboxRefresh {
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Mailboxes
    )
    $byAddr = @{}
    foreach ($m in $Mailboxes) { $byAddr[$m.PrimarySmtpAddress] = $m }
    foreach ($row in $State.Items) {
        if ($byAddr.ContainsKey($row.PrimarySmtpAddress)) {
            $m = $byAddr[$row.PrimarySmtpAddress]
            $row.CurrentForwarding   = $m.ForwardingSmtpAddress
            $row.HasOnPremForwarding = [bool]$m.HasOnPremForwardingAddress
        }
    }
}
