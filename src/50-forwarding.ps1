# Forwarding actions - decide what would happen (New-ForwardingPreview) and
# apply it against Exchange (Set-MailboxForwards). No WinForms/terminal calls
# here; callers render the returned data however they like.

function New-ForwardingPreview {
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Rows)
    foreach ($r in $Rows) {
        # Contract: invalid drafts must never reach Apply. A non-on-prem row
        # with a blank/invalid destination is a data bug upstream (Set-
        # MailboxDraft should have rejected it) - fail fast here rather than
        # inventing a third Action value the UI would have to special-case.
        if (-not $r.HasOnPremForwarding -and -not (Test-ForwardingDestination -Address $r.WillForwardTo)) {
            throw "Invalid forwarding destination for '$($r.PrimarySmtpAddress)': '$($r.WillForwardTo)'."
        }
        $action =
            if ($r.HasOnPremForwarding) { 'Skip' }
            elseif ($r.WillForwardTo -eq $r.CurrentForwarding) { 'Skip' }
            elseif ([string]::IsNullOrEmpty($r.CurrentForwarding)) { 'Set' }
            else { 'Overwrite' }
        [pscustomobject]@{
            Selected            = $r.Selected
            PrimarySmtpAddress  = $r.PrimarySmtpAddress
            CurrentForwarding   = $r.CurrentForwarding
            HasOnPremForwarding = $r.HasOnPremForwarding
            DeliverAndStore     = $r.DeliverAndStore
            ForwardingPrefix    = $r.ForwardingPrefix
            WillForwardTo       = $r.WillForwardTo
            Action              = $action
        }
    }
}

function Set-MailboxForwards {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Rows,
        [scriptblock]$OnProgress
    )

    if ($Rows.Count -eq 0) {
        return [pscustomobject]@{
            Records = @(); Applied = 0; Skipped = 0; Errors = 0
            LogPath = $null; PersistenceErrors = @()
        }
    }

    # Validate every actionable (non-on-prem) destination before the first
    # remote write. On-prem rows stay Skip regardless of destination
    # validity; any other row with a blank/invalid destination aborts the
    # whole call before Set-Mailbox is ever invoked - no partial application.
    foreach ($r in $Rows) {
        if (-not $r.HasOnPremForwarding -and -not (Test-ForwardingDestination -Address $r.WillForwardTo)) {
            throw "Invalid forwarding destination for '$($r.PrimarySmtpAddress)': '$($r.WillForwardTo)'."
        }
    }

    $persistenceErrors = New-Object System.Collections.Generic.List[string]
    $log = New-Object System.Collections.Generic.List[object]
    $i = 0
    try {
        foreach ($r in $Rows) {
            $i++
            if ($OnProgress) {
                # Presentation-only: a broken progress callback must not
                # discard remote outcomes already recorded (or yet to be
                # recorded) for this run.
                try { & $OnProgress $i $Rows.Count $r.PrimarySmtpAddress }
                catch { $persistenceErrors.Add("Progress callback failed: $($_.Exception.Message)") }
            } else {
                Write-Progress -Activity 'Applying forwarding' -Status "$i of $($Rows.Count): $($r.PrimarySmtpAddress)" `
                    -PercentComplete (100 * $i / $Rows.Count)
            }
            $old = $r.CurrentForwarding
            $new = $r.WillForwardTo
            if ($r.HasOnPremForwarding) {
                $log.Add([pscustomobject]@{
                    Timestamp=(Get-Date).ToString('o'); Mailbox=$r.PrimarySmtpAddress
                    OldForwardingSmtpAddress=$old; NewForwardingSmtpAddress=$new
                    DeliverToMailboxAndForward=$r.DeliverAndStore
                    Result='Skipped'; Error='On-prem ForwardingAddress set'
                })
                continue
            }
            try {
                Set-Mailbox -Identity $r.PrimarySmtpAddress `
                    -ForwardingSmtpAddress $new `
                    -DeliverToMailboxAndForward:$($r.DeliverAndStore) -ErrorAction Stop
                $log.Add([pscustomobject]@{
                    Timestamp=(Get-Date).ToString('o'); Mailbox=$r.PrimarySmtpAddress
                    OldForwardingSmtpAddress=$old; NewForwardingSmtpAddress=$new
                    DeliverToMailboxAndForward=$r.DeliverAndStore
                    Result='OK'; Error=''
                })
            } catch {
                $log.Add([pscustomobject]@{
                    Timestamp=(Get-Date).ToString('o'); Mailbox=$r.PrimarySmtpAddress
                    OldForwardingSmtpAddress=$old; NewForwardingSmtpAddress=$new
                    DeliverToMailboxAndForward=$r.DeliverAndStore
                    Result='Error'; Error=$_.Exception.Message
                })
            }
        }
    } finally {
        if (-not $OnProgress) { Write-Progress -Activity 'Applying forwarding' -Completed }
    }

    # Audit CSV first, never overwriting an existing changelog for this stamp.
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $logPath = Join-Path $Script:ScriptDir "changelog-$stamp.csv"
    $suffix = 1
    while (Test-Path $logPath) {
        $logPath = Join-Path $Script:ScriptDir "changelog-$stamp-$suffix.csv"
        $suffix++
    }
    try {
        $log | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8 -NoClobber -ErrorAction Stop
    } catch {
        $persistenceErrors.Add("Audit log write failed: $($_.Exception.Message)")
    }

    # Cache update only from rows that actually succeeded against Exchange.
    try {
        $cache = Read-MailboxCache
        if ($cache) {
            $okRows = $log | Where-Object Result -eq 'OK'
            foreach ($okRow in $okRows) {
                foreach ($m in $cache.Mailboxes) {
                    if ($m.PrimarySmtpAddress -eq $okRow.Mailbox) {
                        $m.ForwardingSmtpAddress      = $okRow.NewForwardingSmtpAddress
                        $m.DeliverToMailboxAndForward = $okRow.DeliverToMailboxAndForward
                    }
                }
            }
            Save-MailboxCache -Mailboxes $cache.Mailboxes
        }
    } catch {
        $persistenceErrors.Add("Cache update failed: $($_.Exception.Message)")
    }

    [pscustomobject]@{
        Records           = @($log.ToArray())
        Applied           = @($log | Where-Object Result -eq 'OK').Count
        Skipped           = @($log | Where-Object Result -eq 'Skipped').Count
        Errors            = @($log | Where-Object Result -eq 'Error').Count
        LogPath           = $logPath
        PersistenceErrors = @($persistenceErrors.ToArray())
    }
}
