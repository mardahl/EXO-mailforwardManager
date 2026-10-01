# Target-address validation over SMTP (RCPT TO probe against the target
# domain's MX, e.g. Exchange Online Directory-Based Edge Blocking). Rows whose
# proposed forwarding target is not accepted with 250 are deselected.
# Network primitives are injectable scriptblocks so the logic tests offline.

$script:SmtpBatchSize = 100   # reconnect after this many RCPTs; EXO throttles long sessions
$script:SmtpTimeoutMs = 15000
$script:SmtpMaxAttempts = 3     # 4xx / dropped-session retries per address
$script:SmtpRetryDelaySec = 10  # pause before retry n = delay * (n-1)

function Resolve-TargetMx {
    param([Parameter(Mandatory)][string]$Domain)
    $mx = Resolve-DnsName -Name $Domain -Type MX -ErrorAction Stop |
        Where-Object { $_.Type -eq 'MX' } | Sort-Object Preference | Select-Object -First 1
    if (-not $mx) { throw "No MX record for '$Domain'." }
    [string]$mx.NameExchange
}

function Test-TcpPort25 {
    param([Parameter(Mandatory)][string]$HostName)
    $tcp = [System.Net.Sockets.TcpClient]::new()
    try {
        $task = $tcp.ConnectAsync($HostName, 25)
        if (-not $task.Wait(5000)) { throw "Timed out connecting to ${HostName}:25." }
        if (-not $tcp.Connected) { throw "Could not connect to ${HostName}:25." }
    } catch {
        $msg = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        throw $msg
    } finally { $tcp.Close() }
}

function Read-SmtpReply {
    param([Parameter(Mandatory)][System.IO.TextReader]$Reader)
    do {
        $line = $Reader.ReadLine()
        if ($null -eq $line) { throw 'SMTP connection closed by server.' }
    } while ($line -match '^\d{3}-')
    $line
}

function Invoke-SmtpRcptDialog {
    # Speaks SMTP over an already-open reader/writer pair. Returns one
    # result per address; throws if the session itself fails.
    param(
        [Parameter(Mandatory)][System.IO.TextReader]$Reader,
        [Parameter(Mandatory)][System.IO.TextWriter]$Writer,
        [Parameter(Mandatory)][string[]]$Address,
        [string]$HeloName = $(if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { 'localhost' })
    )
    $expect = {
        param($prefix, $step)
        $r = Read-SmtpReply -Reader $Reader
        if ($r -notmatch "^$prefix") { throw "SMTP $step rejected: $r" }
    }
    & $expect '220' 'banner'
    $Writer.WriteLine("EHLO $HeloName");  & $expect '250' 'EHLO'
    # One transaction per address: Exchange Online allows a single RCPT per
    # null-sender (MAIL FROM:<>) transaction and answers the 2nd with
    # "452 4.5.3 Too many recipients". RSET keeps the session open.
    foreach ($a in $Address) {
        $Writer.WriteLine('MAIL FROM:<>'); & $expect '250' 'MAIL FROM'
        $Writer.WriteLine("RCPT TO:<$a>")
        $resp = Read-SmtpReply -Reader $Reader
        [pscustomobject]@{ Address = $a; Exists = ($resp -match '^250'); Response = $resp }
        $Writer.WriteLine('RSET');         & $expect '250' 'RSET'
    }
    try { $Writer.WriteLine('QUIT') } catch { $null = $_ }
}

function Test-SmtpRecipient {
    param([Parameter(Mandatory)][string]$Mx, [Parameter(Mandatory)][string[]]$Address)
    $tcp = [System.Net.Sockets.TcpClient]::new($Mx, 25)
    try {
        $tcp.ReceiveTimeout = $script:SmtpTimeoutMs
        $tcp.SendTimeout = $script:SmtpTimeoutMs
        $stream = $tcp.GetStream()
        $reader = [System.IO.StreamReader]::new($stream)
        $writer = [System.IO.StreamWriter]::new($stream)
        $writer.AutoFlush = $true; $writer.NewLine = "`r`n"
        Invoke-SmtpRcptDialog -Reader $reader -Writer $writer -Address $Address
    } finally { $tcp.Close() }
}

function Set-TargetCheck($Row, [string]$Value) {
    $Row | Add-Member -NotePropertyName TargetCheck -NotePropertyValue $Value -Force
}

function Invoke-TargetValidation {
    # Preflight (DNS + TCP 25) for every target domain first; on any failure
    # nothing is changed and Aborted=$true with actionable messages. Then
    # deselects selected rows that already forward / are on-prem, probes the
    # rest, and deselects every target not answered with 250.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Rows,
        [scriptblock]$ResolveMx = { param($d) Resolve-TargetMx -Domain $d },
        [scriptblock]$TestPort = { param($h) Test-TcpPort25 -HostName $h },
        [scriptblock]$CheckRecipients = { param($mx, $addrs) Test-SmtpRecipient -Mx $mx -Address $addrs },
        [scriptblock]$OnProgress
    )
    $result = [pscustomobject]@{ Aborted = $false; Messages = @(); Kept = 0; AlreadyForwarded = 0; RecipientForward = 0; Rejected = 0; Errors = 0; Details = @() }

    $selected = @($Rows | Where-Object Selected)
    $hasFwd = @($selected | Where-Object { $_.HasOnPremForwarding -or -not [string]::IsNullOrEmpty($_.CurrentForwarding) })
    $toCheck = @($selected | Where-Object { $hasFwd -notcontains $_ -and $_.WillForwardTo })
    $noTarget = @($selected | Where-Object { $hasFwd -notcontains $_ -and -not $_.WillForwardTo })

    # --- Preflight ---------------------------------------------------------
    $mxByDomain = @{}
    foreach ($domain in @($toCheck | ForEach-Object { ($_.WillForwardTo -split '@')[1].ToLowerInvariant() } | Sort-Object -Unique)) {
        try { $mxByDomain[$domain] = [string](& $ResolveMx $domain) } catch {
            $result.Messages += "DNS: no MX for '$domain' ($($_.Exception.Message)). Check ForwardingDomain in Settings."
            continue
        }
        try { & $TestPort $mxByDomain[$domain] } catch {
            $mx = $mxByDomain[$domain]
            $result.Messages += "Outbound TCP 25 to $mx is blocked or unreachable: $($_.Exception.Message)"
            $result.Messages += "Run from a network that allows outbound port 25 (ISPs/corporate firewalls often block it)."
            $result.Messages += "Verify with: Test-NetConnection $mx -Port 25"
        }
    }
    if ($result.Messages.Count -gt 0) { $result.Aborted = $true; return $result }

    # --- Validation --------------------------------------------------------
    foreach ($row in $hasFwd) {
        $row.Selected = $false
        if ($row.HasOnPremForwarding) {
            Set-TargetCheck $row 'Warn: recipient forward (ForwardingAddress) set'; $result.RecipientForward++
            $result.Details += "$($row.PrimarySmtpAddress): $($row.TargetCheck)$(if ($row.ForwardingRecipient) { " -> $($row.ForwardingRecipient)" })"
        } else {
            Set-TargetCheck $row 'Has SMTP forward'; $result.AlreadyForwarded++
        }
    }
    foreach ($row in $noTarget) { $row.Selected = $false; Set-TargetCheck $row 'No target'; $result.Errors++ }

    # Only 2xx (exists) and 5xx (rejected) are final. 4xx replies and
    # addresses left unanswered by a dropped session (EXO throttling on large
    # runs) are retried on a fresh session after a growing pause; replies
    # received before a drop are kept (pipeline streams them out).
    $done = 0
    foreach ($group in @($toCheck | Group-Object { ($_.WillForwardTo -split '@')[1].ToLowerInvariant() })) {
        $mx = $mxByDomain[$group.Name]
        $pending = @($group.Group)
        $lastError = @{}
        for ($attempt = 1; $attempt -le $script:SmtpMaxAttempts -and $pending.Count; $attempt++) {
            if ($attempt -gt 1 -and $script:SmtpRetryDelaySec -gt 0) { Start-Sleep -Seconds ($script:SmtpRetryDelaySec * ($attempt - 1)) }
            $retry = @()
            for ($i = 0; $i -lt $pending.Count; $i += $script:SmtpBatchSize) {
                $batch = @($pending[$i..([Math]::Min($i + $script:SmtpBatchSize, $pending.Count) - 1)])
                if ($OnProgress) { & $OnProgress $done $toCheck.Count $batch[0].WillForwardTo }
                $answers = @{}
                $sessionError = $null
                try {
                    & $CheckRecipients $mx @($batch.WillForwardTo) | ForEach-Object { $answers[$_.Address] = $_ }
                } catch { $sessionError = $_.Exception.Message }
                foreach ($row in $batch) {
                    $ans = $answers[$row.WillForwardTo]
                    if ($ans -and $ans.Exists) {
                        Set-TargetCheck $row 'OK'; $result.Kept++; $done++
                    } elseif ($ans -and $ans.Response -match '^5') {
                        $row.Selected = $false
                        Set-TargetCheck $row "Rejected: $($ans.Response)"; $result.Rejected++; $done++
                        $result.Details += "$($row.PrimarySmtpAddress) -> $($row.WillForwardTo): $($row.TargetCheck)"
                    } else {
                        $lastError[$row.WillForwardTo] = if ($ans) { $ans.Response } elseif ($sessionError) { $sessionError } else { 'no reply' }
                        $retry += $row
                    }
                }
            }
            $pending = $retry
        }
        foreach ($row in $pending) {
            $row.Selected = $false
            Set-TargetCheck $row "Error: $($lastError[$row.WillForwardTo])"; $result.Errors++; $done++
            $result.Details += "$($row.PrimarySmtpAddress) -> $($row.WillForwardTo): $($row.TargetCheck)"
        }
    }
    if ($OnProgress -and $toCheck.Count) { & $OnProgress $toCheck.Count $toCheck.Count '' }
    $result
}
