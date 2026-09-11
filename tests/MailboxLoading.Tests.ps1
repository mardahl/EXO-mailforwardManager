# Offline mailbox-loading regression checks. Run with PowerShell 5.1 or newer.
$ErrorActionPreference = 'Stop'
# Load backend functions without executing module installation, authentication, or WinForms startup.
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

Assert ((Split-Path $script:EntryScriptPath -Leaf) -eq 'MailboxForwardingTool.ps1') 'Relaunch must target root script.'
Assert ($script:ConfigPath -eq (Join-Path $script:ScriptDir 'config.json')) 'Config path moved into src.'
Assert ($script:CachePath -eq (Join-Path $script:ScriptDir 'cache.json')) 'Cache path moved into src.'

function Write-Host {
    param($Object)
    $script:Messages.Add([string]$Object)
}
function Write-Progress {
    param($Activity, $Status, [switch]$Completed)
    if ($Completed) { $script:ProgressCleared = $true }
    else { $script:Statuses.Add([string]$Status) }
}
function Get-ConnectionInformation { if ($script:Connected) { [pscustomobject]@{ State = 'Connected' } } }
function Connect-ExchangeOnline {
    [CmdletBinding()]
    param($PageSize, [switch]$ShowBanner, [switch]$DisableWAM)
    Assert ($PageSize -eq 100) 'Connection must request native 100-entry pages.'
    $script:ConnectCalls++
    $script:UsedDisableWAM = [bool]$DisableWAM
    $script:Connected = $true
}
function Get-EXOMailbox {
    [CmdletBinding()]
    param($ResultSize, $RecipientTypeDetails, $Properties)
    Assert ($ResultSize -eq 'Unlimited' -and $RecipientTypeDetails -eq 'UserMailbox') 'Query must retrieve all user mailboxes.'
    Assert (($Properties -join ',') -eq 'ForwardingSmtpAddress,DeliverToMailboxAndForward,ForwardingAddress') 'Forwarding properties missing.'
    $script:FetchCalls++
    for ($i = 0; $i -le $script:MailboxCount; $i++) {
        if ($i -eq $script:FailAfter) {
            # Model the non-terminating transport error in the original failure report.
            if ($ErrorActionPreference -eq 'Stop') { Write-Error 'Underlying connection closed during receive.' }
            else { Write-Error 'Underlying connection closed during receive.' -ErrorAction SilentlyContinue }
            return
        }
        if ($i -eq $script:MailboxCount) { break }
        if ($i -eq 100) {
            Assert (@($script:Statuses | Where-Object { $_ -match '\b100\b' }).Count -gt 0) 'Progress must appear before the next 100 mailboxes are consumed.'
        }
        [pscustomobject]@{
            PrimarySmtpAddress = "user$i@example.com"
            ForwardingSmtpAddress = 'smtp:archive@example.net'
            DeliverToMailboxAndForward = $true
            ForwardingAddress = $null
        }
    }
}

$script:Messages = New-Object 'System.Collections.Generic.List[string]'
$script:Statuses = New-Object 'System.Collections.Generic.List[string]'
$script:Config = [pscustomobject]@{ ServiceAccountUPN = 'admin@example.com'; CacheTtlHours = 24 }
$script:CachePath = [IO.Path]::GetTempFileName()
$failures = New-Object 'System.Collections.Generic.List[string]'
try {
    foreach ($disable in @($false, $true)) {
        try {
            $script:StartupOptions.DisableWAM = $disable
            $script:ExoPagingConfigured = $false
            $script:Connected = $true
            $script:ConnectCalls = 0
            Connect-Exo
            Connect-Exo
            Assert ($script:ConnectCalls -eq 1) 'Existing connection must be configured once, then reused.'
            Assert ($script:UsedDisableWAM -eq $disable) 'Authentication path changed.'
        } catch { $failures.Add("Connection (DisableWAM=$disable): $_") }
    }
    foreach ($case in @(
        @{ Count = 0; Fail = -1 }, @{ Count = 1; Fail = -1 }, @{ Count = 99; Fail = -1 },
        @{ Count = 100; Fail = -1 }, @{ Count = 101; Fail = -1 }, @{ Count = 200; Fail = -1 },
        @{ Count = 250; Fail = -1 }, @{ Count = 250; Fail = 0 }, @{ Count = 250; Fail = 100 }
    )) {
        try {
            $script:MailboxCount = $case.Count; $script:FailAfter = $case.Fail
            $script:FetchCalls = 0; $script:ProgressCleared = $false
            $script:Messages.Clear(); $script:Statuses.Clear()
            Save-MailboxCache -Mailboxes @([pscustomobject]@{ PrimarySmtpAddress = 'cached@example.com' })
            $before = Get-Content $script:CachePath -Raw
            $received = New-Object 'System.Collections.Generic.List[object]'
            $caught = $null
            # A caller's default Continue preference must not hide an Exchange failure.
            $ErrorActionPreference = 'Continue'
            try { Get-MailboxList -Force | ForEach-Object { $received.Add($_) } } catch { $caught = $_ }
            finally { $ErrorActionPreference = 'Stop' }
            if ($case.Fail -ge 0) {
                Assert ($null -ne $caught -and $caught.Exception.Message -match 'Underlying connection closed') 'Original transport error must reach caller.'
                Assert ($received.Count -eq 0) 'Partial mailbox list escaped to caller.'
                Assert ((Get-Content $script:CachePath -Raw) -eq $before) 'Failed enumeration changed cache.'
                Assert (@($script:Messages | Where-Object { $_ -match 'Retrieved 0|complete' }).Count -eq 0) 'Failure reported as successful enumeration.'
            } else {
                Assert ($null -eq $caught) "Successful enumeration threw: $caught"
                Assert ($received.Count -eq $case.Count) 'Mailbox count changed.'
                $cache = Read-MailboxCache
                Assert ($null -ne $cache.Mailboxes -and @($cache.Mailboxes).Count -eq $case.Count) 'Cache must contain a mailbox array, including for zero results.'
                if ($case.Count -gt 0) {
                    Assert ($received[0].ForwardingSmtpAddress -eq 'archive@example.net' -and $received[0].DeliverToMailboxAndForward -and -not $received[0].HasOnPremForwardingAddress) 'Forwarding mapping changed.'
                }
                for ($boundary = 100; $boundary -le $case.Count; $boundary += 100) {
                    Assert (@($script:Messages | Where-Object { $_ -match "\b$boundary\b.*elapsed" }).Count -gt 0) "Missing console progress at $boundary."
                }
                Assert (@($script:Messages | Where-Object { $_ -match "Retrieved $($case.Count) mailboxes" }).Count -gt 0) 'Final count missing.'
                $cached = @(Get-MailboxList)
                Assert ($cached.Count -eq $case.Count -and $script:FetchCalls -eq 1) 'Fresh cache was not reused.'
            }
            Assert $script:ProgressCleared 'Progress not cleared after enumeration.'
        } catch { $failures.Add("Count=$($case.Count), FailAfter=$($case.Fail): $_") }
    }
} finally { Remove-Item $script:CachePath -Force }

# --- Cache-hit path must route through -OnProgress, never Write-Host -------
try {
    $tempCache = [IO.Path]::GetTempFileName()
    try {
        $script:CachePath = $tempCache
        $script:Config = [pscustomobject]@{ ServiceAccountUPN = 'admin@example.com'; CacheTtlHours = 24 }
        Save-MailboxCache -Mailboxes @([pscustomobject]@{ PrimarySmtpAddress = 'cached@example.com' })
        # Host stub deliberately fails if called, so any Write-Host leak from
        # the cache-hit path (even with -OnProgress supplied) is caught.
        function Write-Host { param($Object) throw "Write-Host must not be called when -OnProgress is supplied (cache-hit path): $Object" }
        $progressCalls = New-Object 'System.Collections.Generic.List[hashtable]'
        $result = @(Get-MailboxList -OnProgress { param($p) $progressCalls.Add($p) })
        Assert ($result.Count -eq 1 -and $result[0].PrimarySmtpAddress -eq 'cached@example.com') 'Cache-hit path with -OnProgress must still return the cached list.'
        Assert ($progressCalls.Count -gt 0) 'Cache-hit path with -OnProgress must report status via the callback, not the console.'

        # Cache-hit path without a callback keeps the original console behavior.
        function Write-Host { param($Object) $script:PlainMessages.Add([string]$Object) }
        $script:PlainMessages = New-Object 'System.Collections.Generic.List[string]'
        $result2 = @(Get-MailboxList)
        Assert ($result2.Count -eq 1) 'Cache-hit path without -OnProgress must still return the cached list.'
        Assert (@($script:PlainMessages | Where-Object { $_ -match 'Using cached mailbox list' }).Count -gt 0) 'Cache-hit path without -OnProgress must keep console reporting.'
    } finally {
        Remove-Item $tempCache -Force -ErrorAction SilentlyContinue
    }
} catch { $failures.Add("Cache-hit with -OnProgress: $_") }

# --- A broken -OnProgress callback must never mask a real fetch failure, or
# crash a successful fetch -------------------------------------------------
try {
    $tempCache = [IO.Path]::GetTempFileName()
    try {
        $script:CachePath = $tempCache
        $script:Config = [pscustomobject]@{ ServiceAccountUPN = 'admin@example.com'; CacheTtlHours = 24 }
        function Write-Host { param($Object) }
        function Write-Progress { param($Activity, $Status, [switch]$Completed) }

        # Success case: a callback that always throws must not stop a
        # successful fetch from returning its results.
        $script:MailboxCount = 5; $script:FailAfter = -1; $script:FetchCalls = 0
        Save-MailboxCache -Mailboxes @([pscustomobject]@{ PrimarySmtpAddress = 'stale@example.com' })
        $throwingCallback = { param($p) throw 'callback boom' }
        $ok = $null
        try { $ok = @(Get-MailboxList -Force -OnProgress $throwingCallback) } catch { $ok = $_ }
        Assert ($ok -isnot [System.Management.Automation.ErrorRecord]) "A broken -OnProgress callback must not turn a successful fetch into a failure: $ok"
        Assert (@($ok).Count -eq 5) 'A broken -OnProgress callback must not affect the returned mailbox count.'

        # Failure case: the real Exchange error must still be the one that
        # reaches the caller, not a callback error from the finally block's
        # completion notification.
        $script:MailboxCount = 250; $script:FailAfter = 100; $script:FetchCalls = 0
        $beforeCache = Get-Content $tempCache -Raw
        $caught = $null
        try { Get-MailboxList -Force -OnProgress $throwingCallback | Out-Null } catch { $caught = $_ }
        Assert ($null -ne $caught -and $caught.Exception.Message -match 'Underlying connection closed') "A broken -OnProgress callback must not mask the original Exchange error: $caught"
        Assert ((Get-Content $tempCache -Raw) -eq $beforeCache) 'A masked/failed fetch must never publish to the cache.'
    } finally {
        Remove-Item $tempCache -Force -ErrorAction SilentlyContinue
    }
} catch { $failures.Add("Broken OnProgress callback: $_") }

# --- Owned-connection tracking: only IDs this run itself opened are ever ---
# disconnected; a pre-existing (borrowed) connection is left alone ----------
try {
    $script:ExoPagingConfigured = $false
    $script:ExoOwnedConnectionIds = @()
    $script:Config = [pscustomobject]@{ ServiceAccountUPN = 'admin@example.com'; CacheTtlHours = 24 }
    $script:StartupOptions.DisableWAM = $false
    $script:ConnList = @([pscustomobject]@{ ConnectionId = 'borrowed-conn-0'; UserPrincipalName = 'other@example.com'; State = 'Connected' })
    $script:DisconnectedIds = New-Object 'System.Collections.Generic.List[string]'
    function Get-ConnectionInformation { @($script:ConnList) }
    function Connect-ExchangeOnline {
        [CmdletBinding()]
        param($PageSize, [switch]$ShowBanner, [switch]$DisableWAM)
        Assert ($PageSize -eq 100) 'Owned-connection test: PageSize must stay 100.'
        Assert (-not $PSBoundParameters.ContainsKey('UserPrincipalName')) 'Owned-connection test: no UPN login hint.'
        $script:ConnList = @($script:ConnList) + @([pscustomobject]@{ ConnectionId = 'new-conn-1'; UserPrincipalName = 'svc@example.com'; State = 'Connected' })
    }
    function Disconnect-ExchangeOnline {
        [CmdletBinding()]
        param([string]$ConnectionId, [switch]$Confirm)
        Assert ($PSBoundParameters.ContainsKey('ConnectionId')) 'Cleanup must always target a specific -ConnectionId, never a blanket disconnect.'
        $script:DisconnectedIds.Add($ConnectionId)
    }

    Connect-Exo

    Assert ($script:ExoOwnedConnectionIds -contains 'new-conn-1') 'The connection this run opened must be tracked as owned.'
    Assert (-not ($script:ExoOwnedConnectionIds -contains 'borrowed-conn-0')) 'A pre-existing connection must never be tracked as owned.'

    Disconnect-OwnedExoConnections

    Assert ($script:DisconnectedIds -contains 'new-conn-1') 'The owned connection must be disconnected on cleanup.'
    Assert (-not ($script:DisconnectedIds -contains 'borrowed-conn-0')) 'A borrowed connection must never be disconnected on cleanup.'
    Assert ($script:ExoOwnedConnectionIds.Count -eq 0) 'The owned-ID list must clear after cleanup.'

    # A second cleanup call (e.g. a second finally in some future code path)
    # must be a harmless no-op, not re-disconnect or throw.
    $script:DisconnectedIds.Clear()
    Disconnect-OwnedExoConnections
    Assert ($script:DisconnectedIds.Count -eq 0) 'Cleanup must be idempotent once the owned list is already empty.'
} catch { $failures.Add("Owned-connection tracking/cleanup: $_") }

# --- Get-ExoAccountName: real connected identity, never the configured hint
try {
    $script:ConnList = @([pscustomobject]@{ ConnectionId = 'c1'; UserPrincipalName = 'actual-signed-in@example.com'; State = 'Connected' })
    function Get-ConnectionInformation { @($script:ConnList) }
    $name = Get-ExoAccountName -ConfiguredHint 'configured-hint@example.com'
    Assert ($name -eq 'actual-signed-in@example.com') 'Get-ExoAccountName must prefer the real connected UserPrincipalName over the configured hint.'

    $script:ConnList = @()
    $name2 = Get-ExoAccountName -ConfiguredHint 'configured-hint@example.com'
    Assert ($name2 -ne 'configured-hint@example.com') 'Get-ExoAccountName must never present the configured hint as if it were the authenticated identity.'
    Assert ($name2 -match 'configured-hint@example.com') 'Get-ExoAccountName must still surface the hint as guidance when the real identity is unavailable.'

    $name3 = Get-ExoAccountName
    Assert ($name3 -eq '(unknown)') 'Get-ExoAccountName with no hint and no connection must return an explicit unknown, not blank.'
} catch { $failures.Add("Get-ExoAccountName: $_") }

if ($failures.Count) { throw ($failures -join "`n") }
Microsoft.PowerShell.Utility\Write-Host 'Mailbox loading checks passed (2 connection paths, 9 enumeration cases).'
