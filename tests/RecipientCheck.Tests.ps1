. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$script:SmtpRetryDelaySec = 0   # no real waits in offline tests

function New-Row($addr, $target, $fwd = '', $onPrem = $false) {
    [pscustomobject]@{
        Selected = $true; PrimarySmtpAddress = $addr; CurrentForwarding = $fwd
        HasOnPremForwarding = $onPrem; WillForwardTo = $target; TargetCheck = ''
    }
}

# --- Invoke-SmtpRcptDialog: protocol over fake streams -----------------------

# One transaction per address (EXO allows 1 RCPT per null-sender transaction,
# else 452 4.5.3): MAIL, RCPT, RSET for each address.
$server = "220 mx ready`r`n250-mx hello`r`n250 SIZE`r`n" +
    "250 OK`r`n250 2.1.5 Recipient OK`r`n250 reset`r`n" +
    "250 OK`r`n550 5.4.1 Recipient address rejected`r`n250 reset`r`n"
$writer = [System.IO.StringWriter]::new()
$res = @(Invoke-SmtpRcptDialog -Reader ([System.IO.StringReader]::new($server)) -Writer $writer -Address 'a@t.com', 'b@t.com' -HeloName 'probe')
Assert ($res.Count -eq 2) 'Expected one result per address.'
Assert ($res[0].Exists -and -not $res[1].Exists) '250 must mean exists, 550 must not.'
Assert ($res[1].Response -like '550*') 'Response text must be kept.'
$sent = $writer.ToString()
Assert ($sent -match 'EHLO probe' -and $sent -match 'MAIL FROM:<>' -and $sent -match 'RCPT TO:<b@t.com>' -and $sent -match 'QUIT') 'Client commands missing.'
Assert (([regex]::Matches($sent, 'MAIL FROM:<>')).Count -eq 2) 'Each address needs its own MAIL FROM transaction.'
Assert (([regex]::Matches($sent, 'RSET')).Count -eq 2) 'Each transaction must be reset.'

$threw = $false
try { @(Invoke-SmtpRcptDialog -Reader ([System.IO.StringReader]::new("554 go away`r`n")) -Writer ([System.IO.StringWriter]::new()) -Address 'a@t.com') } catch { $threw = $true }
Assert $threw 'Non-220 banner must throw.'

$threw = $false
try { @(Invoke-SmtpRcptDialog -Reader ([System.IO.StringReader]::new("220 ok`r`n250 ok`r`n250 ok`r`n")) -Writer ([System.IO.StringWriter]::new()) -Address 'a@t.com') } catch { $threw = $true }
Assert $threw 'Connection closed mid-session must throw.'

# --- Invoke-TargetValidation: preflight abort leaves selection untouched -----

$rows = @((New-Row 'u1@s.com' 'u1@t.com'), (New-Row 'u2@s.com' 'u2@t.com' 'x@y.com'))
$called = $false
$r = Invoke-TargetValidation -Rows $rows -ResolveMx { 'mx.t.com' } -TestPort { throw 'Connection refused' } -CheckRecipients { $script:called = $true }
Assert $r.Aborted 'Blocked port 25 must abort.'
Assert (-not $called) 'No RCPT probing after failed preflight.'
Assert ($rows[0].Selected -and $rows[1].Selected) 'Aborted run must not change selection.'
Assert (($r.Messages -join ' ') -match 'Test-NetConnection mx.t.com -Port 25') 'Abort must give actionable command.'

$r = Invoke-TargetValidation -Rows @(New-Row 'u1@s.com' 'u1@t.com') -ResolveMx { throw 'NXDOMAIN' } -TestPort {} -CheckRecipients {}
Assert ($r.Aborted -and ($r.Messages -join ' ') -match 'no MX') 'DNS failure must abort.'

# --- Invoke-TargetValidation: outcomes -----------------------------------------

$rows = @(
    (New-Row 'ok@s.com' 'ok@t.com'),
    (New-Row 'bad@s.com' 'bad@t.com'),
    (New-Row 'fwd@s.com' 'fwd@t.com' 'old@x.com'),
    (New-Row 'prem@s.com' 'prem@t.com' '' $true),
    (New-Row 'other@s.com' 'other@u.com')
)
$rows += New-Row 'unsel@s.com' 'unsel@t.com'; $rows[-1].Selected = $false
$check = {
    param($mx, $addrs)
    if ($mx -eq 'mx.u.com') { throw 'session dropped' }
    foreach ($a in $addrs) { [pscustomobject]@{ Address = $a; Exists = ($a -like 'ok@*'); Response = $(if ($a -like 'ok@*') { '250 OK' } else { '550 5.4.1 rejected' }) } }
}
$r = Invoke-TargetValidation -Rows $rows -ResolveMx { param($d) "mx.$d" } -TestPort {} -CheckRecipients $check
Assert (-not $r.Aborted) 'Valid preflight must not abort.'
Assert ($rows[0].Selected -and $rows[0].TargetCheck -eq 'OK') '250 target must stay selected.'
Assert (-not $rows[1].Selected -and $rows[1].TargetCheck -like 'Rejected: 550*') 'Rejected target must be deselected.'
Assert (-not $rows[2].Selected -and -not $rows[3].Selected) 'Already-forwarding/on-prem rows must be deselected.'
Assert (-not $rows[4].Selected -and $rows[4].TargetCheck -like 'Error: session dropped') 'Session error must deselect.'
Assert ($rows[5].TargetCheck -eq '') 'Unselected rows must not be touched.'
Assert ($r.Kept -eq 1 -and $r.Rejected -eq 1 -and $r.AlreadyForwarded -eq 1 -and $r.RecipientForward -eq 1 -and $r.Errors -eq 1) "Counts wrong: $($r | Out-String)"

# --- Batching ---------------------------------------------------------------

$old = $script:SmtpBatchSize; $script:SmtpBatchSize = 2
$script:batches = 0
$rows = @(1..5 | ForEach-Object { New-Row "u$_@s.com" "ok$_@t.com" })
$r = Invoke-TargetValidation -Rows $rows -ResolveMx { 'mx' } -TestPort {} -CheckRecipients {
    param($mx, $addrs) $script:batches++
    foreach ($a in $addrs) { [pscustomobject]@{ Address = $a; Exists = $true; Response = '250 OK' } }
}
$script:SmtpBatchSize = $old
Assert ($script:batches -eq 3) "Expected 3 sessions for 5 rows at batch 2, got $script:batches."
Assert ($r.Kept -eq 5) 'All batched rows must be kept.'

# --- Throttling: partial replies kept, 4xx / dropped retried -----------------

$script:session = 0
$rows = @(1..4 | ForEach-Object { New-Row "u$_@s.com" "ok$_@t.com" })
$r = Invoke-TargetValidation -Rows $rows -ResolveMx { 'mx' } -TestPort {} -CheckRecipients {
    param($mx, $addrs)
    $script:session++
    if ($script:session -eq 1) {
        # 1st answered, 2nd throttled (4xx), then session dies before 3rd/4th
        [pscustomobject]@{ Address = $addrs[0]; Exists = $true; Response = '250 OK' }
        [pscustomobject]@{ Address = $addrs[1]; Exists = $false; Response = '421 4.7.0 Too many connections' }
        throw 'connection reset'
    }
    foreach ($a in $addrs) { [pscustomobject]@{ Address = $a; Exists = $true; Response = '250 OK' } }
}
Assert ($r.Kept -eq 4 -and $r.Errors -eq 0) "Throttled/dropped rows must be retried, got Kept=$($r.Kept) Errors=$($r.Errors)."
Assert ($script:session -eq 2) "Retry must only resend unanswered rows in one more session, got $script:session."

$script:session = 0
$rows = @(New-Row 'u@s.com' 'tmp@t.com')
$r = Invoke-TargetValidation -Rows $rows -ResolveMx { 'mx' } -TestPort {} -CheckRecipients {
    param($mx, $addrs) $script:session++
    foreach ($a in $addrs) { [pscustomobject]@{ Address = $a; Exists = $false; Response = '451 4.7.500 Server busy' } }
}
Assert ($script:session -eq $script:SmtpMaxAttempts) 'Persistent 4xx must stop after max attempts.'
Assert (-not $rows[0].Selected -and $rows[0].TargetCheck -like 'Error: 451*' -and $r.Errors -eq 1) 'Persistent 4xx is an error, not a rejection.'

Write-Host 'RecipientCheck tests passed.'
