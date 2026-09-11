# Offline forwarding-action regression checks. Run with PowerShell 5.1 or newer.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$script:Calls = @()
$script:MailboxParams = @{}
function Set-Mailbox {
    [CmdletBinding()]
    param($Identity, $ForwardingSmtpAddress, [bool]$DeliverToMailboxAndForward)
    $script:Calls += $Identity
    $script:MailboxParams[$Identity] = @{ Destination = $ForwardingSmtpAddress; Keep = $DeliverToMailboxAndForward }
    if ($Identity -eq 'bad@example.com') { throw 'Denied' }
}

$failures = New-Object 'System.Collections.Generic.List[string]'

function NewRow([string]$Tag, [bool]$OnPrem = $false) {
    [pscustomobject]@{
        Selected = $true; PrimarySmtpAddress = "$Tag@example.com"
        CurrentForwarding = 'old@example.net'; HasOnPremForwarding = $OnPrem
        DeliverAndStore = $true; ForwardingPrefix = $Tag; WillForwardTo = "$Tag@archive.example.com"
    }
}

function WithTempScriptDir([scriptblock]$Body) {
    $originalDir = $script:ScriptDir
    $originalCache = $script:CachePath
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
    [void][IO.Directory]::CreateDirectory($temporary)
    try {
        $script:ScriptDir = $temporary
        $script:CachePath = Join-Path $temporary 'cache.json'
        & $Body $temporary
    } finally {
        $script:ScriptDir = $originalDir
        $script:CachePath = $originalCache
        Remove-Item $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- New-ForwardingPreview: snapshot independence and Action assignment -----

try {
    $rows = @('ok', 'skip', 'bad') | ForEach-Object { NewRow $_ ($_ -eq 'skip') }
    $snapshot = @(New-ForwardingPreview -Rows @($rows))
    $rows[0].WillForwardTo = 'changed@example.net'
    Assert ($snapshot[0].WillForwardTo -eq 'ok@archive.example.com') 'Preview must snapshot proposals.'
    Assert ($snapshot[0].Action -eq 'Overwrite') 'Non-empty differing current forward must be Overwrite.'
    Assert ($snapshot[1].Action -eq 'Skip') 'On-prem row must be Skip.'
    Assert ($snapshot[2].Action -eq 'Overwrite') 'Bad row (not yet called) must still preview as actionable.'

    $blankCurrent = NewRow 'fresh'
    $blankCurrent.CurrentForwarding = ''
    $previewBlank = @(New-ForwardingPreview -Rows @($blankCurrent))
    Assert ($previewBlank[0].Action -eq 'Set') 'Empty current forward must be Set.'

    $noChange = NewRow 'same'
    $noChange.WillForwardTo = $noChange.CurrentForwarding
    $previewNoChange = @(New-ForwardingPreview -Rows @($noChange))
    Assert ($previewNoChange[0].Action -eq 'Skip') 'Unchanged destination must be Skip.'

    $blankTarget = NewRow 'blank'
    $blankTarget.WillForwardTo = ''
    $threw = $false
    try { [void](New-ForwardingPreview -Rows @($blankTarget)) } catch { $threw = $true }
    Assert $threw 'Blank target on a non-on-prem row must throw, not preview as Skip.'

    $onPremBlankTarget = NewRow 'onpremblank' $true
    $onPremBlankTarget.WillForwardTo = ''
    $previewOnPremBlank = @(New-ForwardingPreview -Rows @($onPremBlankTarget))
    Assert ($previewOnPremBlank[0].Action -eq 'Skip') 'On-prem row with invalid destination must still preview as Skip.'
} catch { $failures.Add("Preview: $_") }

# --- Set-MailboxForwards: mixed outcomes, cache, audit ----------------------

try {
    $script:Calls = @(); $script:MailboxParams = @{}
    $rows = @('ok', 'skip', 'bad') | ForEach-Object { NewRow $_ ($_ -eq 'skip') }
    $snapshot = @(New-ForwardingPreview -Rows @($rows))
    WithTempScriptDir {
        $result = Set-MailboxForwards -Rows $snapshot
        Assert ($result.Applied -eq 1 -and $result.Skipped -eq 1 -and $result.Errors -eq 1) 'Mixed counts incorrect.'
        Assert ($script:Calls.Count -eq 2 -and $script:Calls -notcontains 'skip@example.com') 'On-prem row reached Exchange.'
        Assert ($script:MailboxParams['ok@example.com'].Destination -eq 'ok@archive.example.com') 'Wrong destination passed to Set-Mailbox.'
        Assert ($script:MailboxParams['ok@example.com'].Keep -eq $true) 'Wrong keep-copy flag passed to Set-Mailbox.'
        Assert (@(Import-Csv $result.LogPath).Count -eq 3) 'Audit record missing.'
        Assert ($result.PersistenceErrors.Count -eq 0) 'Unexpected persistence errors.'
    }
} catch { $failures.Add("Mixed outcomes: $_") }

# --- Empty input: zero counts, no CSV, no Exchange call ---------------------

try {
    $script:Calls = @()
    WithTempScriptDir {
        $result = Set-MailboxForwards -Rows @()
        Assert ($result.Applied -eq 0 -and $result.Skipped -eq 0 -and $result.Errors -eq 0) 'Empty input must yield zero counts.'
        Assert ($script:Calls.Count -eq 0) 'Empty input must not call Exchange.'
        Assert (-not $result.LogPath -or -not (Test-Path $result.LogPath)) 'Empty input must not write an audit CSV.'
    }
} catch { $failures.Add("Empty input: $_") }

# --- Mixed valid+invalid: whole call aborts before any remote write --------

try {
    $script:Calls = @()
    $rows = @(
        (NewRow 'first'),
        (NewRow 'blank')
    )
    $rows[1].WillForwardTo = ''
    WithTempScriptDir {
        Save-MailboxCache -Mailboxes @(
            [pscustomobject]@{ PrimarySmtpAddress = 'first@example.com'; ForwardingSmtpAddress = 'old@example.net'; DeliverToMailboxAndForward = $false }
        )
        $cacheBefore = Get-Content $script:CachePath -Raw
        $threw = $false
        try { [void](Set-MailboxForwards -Rows $rows) } catch { $threw = $true }
        Assert $threw 'A blank/invalid non-on-prem destination must abort the whole call.'
        Assert ($script:Calls.Count -eq 0) 'Invalid destination in the batch must prevent every remote write, including valid rows.'
        Assert ((Get-Content $script:CachePath -Raw) -eq $cacheBefore) 'Aborted call must not touch the cache.'
        Assert (@(Get-ChildItem $script:ScriptDir -Filter 'changelog-*.csv').Count -eq 0) 'Aborted call must not write an audit file.'
    }
} catch { $failures.Add("Mixed valid+invalid: $_") }

# --- On-prem rows skipped even with an invalid draft destination ------------

try {
    $script:Calls = @()
    $row = NewRow 'onprem' $true
    $row.WillForwardTo = ''
    WithTempScriptDir {
        $result = Set-MailboxForwards -Rows @($row)
        Assert ($result.Skipped -eq 1 -and $result.Errors -eq 0) 'Invalid destination on on-prem row must still be Skipped, not Error.'
        Assert ($script:Calls.Count -eq 0) 'On-prem row must never reach Exchange.'
    }
} catch { $failures.Add("On-prem invalid destination: $_") }

# --- Failed/skipped rows leave cache untouched; successful rows update it ---

try {
    $script:Calls = @()
    $rows = @('ok', 'skip', 'bad') | ForEach-Object { NewRow $_ ($_ -eq 'skip') }
    WithTempScriptDir {
        Save-MailboxCache -Mailboxes @(
            [pscustomobject]@{ PrimarySmtpAddress = 'ok@example.com'; ForwardingSmtpAddress = 'old@example.net'; DeliverToMailboxAndForward = $false },
            [pscustomobject]@{ PrimarySmtpAddress = 'skip@example.com'; ForwardingSmtpAddress = 'old@example.net'; DeliverToMailboxAndForward = $false },
            [pscustomobject]@{ PrimarySmtpAddress = 'bad@example.com'; ForwardingSmtpAddress = 'old@example.net'; DeliverToMailboxAndForward = $false }
        )
        [void](Set-MailboxForwards -Rows $rows)
        $cache = Read-MailboxCache
        $byAddr = @{}
        foreach ($m in $cache.Mailboxes) { $byAddr[$m.PrimarySmtpAddress] = $m }
        Assert ($byAddr['ok@example.com'].ForwardingSmtpAddress -eq 'ok@archive.example.com') 'Successful row must update cache.'
        Assert ($byAddr['skip@example.com'].ForwardingSmtpAddress -eq 'old@example.net') 'Skipped row must not update cache.'
        Assert ($byAddr['bad@example.com'].ForwardingSmtpAddress -eq 'old@example.net') 'Failed row must not update cache.'
    }
} catch { $failures.Add("Cache selectivity: $_") }

# --- Snapshot independence: mutating source rows after preview must not ----
# --- alter what Set-MailboxForwards later applies ---------------------------

try {
    $script:Calls = @()
    $rows = @(NewRow 'indep')
    $snapshot = @(New-ForwardingPreview -Rows @($rows))
    $rows[0].WillForwardTo = 'tampered@example.net'
    WithTempScriptDir {
        $result = Set-MailboxForwards -Rows $snapshot
        Assert ($script:MailboxParams['indep@example.com'].Destination -eq 'indep@archive.example.com') 'Set-MailboxForwards must use the snapshot, not the mutated source.'
        Assert ($result.Applied -eq 1) 'Snapshot row must apply.'
    }
} catch { $failures.Add("Snapshot independence: $_") }

# --- Audit collision: never overwrite an existing changelog file ------------

try {
    $script:Calls = @()
    $rows = @(NewRow 'coll')
    WithTempScriptDir {
        param($dir)
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $existingPath = Join-Path $dir "changelog-$stamp.csv"
        'placeholder' | Set-Content -Path $existingPath -Encoding UTF8
        $result = Set-MailboxForwards -Rows $rows
        Assert ($result.LogPath -ne $existingPath) 'Must not reuse a colliding audit filename.'
        Assert (Test-Path $result.LogPath) 'New audit file must exist.'
        Assert ((Get-Content $existingPath -Raw).TrimEnd() -eq 'placeholder') 'Existing audit file must not be overwritten.'
        Assert (@(Import-Csv $result.LogPath).Count -eq 1) 'New audit file must contain the run record.'
    }
} catch { $failures.Add("Audit collision: $_") }

# --- Cache-save failure still attempts CSV; CSV failure still returns ------
# --- remote outcomes ---------------------------------------------------------

try {
    $script:Calls = @()
    $rows = @(NewRow 'persist')
    WithTempScriptDir {
        Save-MailboxCache -Mailboxes @([pscustomobject]@{ PrimarySmtpAddress = 'persist@example.com'; ForwardingSmtpAddress = 'old@example.net'; DeliverToMailboxAndForward = $false })
        function Save-MailboxCache { param($Mailboxes) throw 'disk full' }
        $result = Set-MailboxForwards -Rows $rows
        Assert ($result.Applied -eq 1) 'Cache-save failure must not hide the successful remote outcome.'
        Assert (Test-Path $result.LogPath) 'CSV must still be written when cache save fails.'
        Assert (($result.PersistenceErrors -join ' ') -match 'disk full') 'Cache-save failure must be reported.'
    }
} catch { $failures.Add("Cache-save failure: $_") }

try {
    $script:Calls = @()
    $rows = @(NewRow 'persist2')
    WithTempScriptDir {
        Save-MailboxCache -Mailboxes @([pscustomobject]@{ PrimarySmtpAddress = 'persist2@example.com'; ForwardingSmtpAddress = 'old@example.net'; DeliverToMailboxAndForward = $false })
        function Export-Csv {
            [CmdletBinding()]
            param([Parameter(ValueFromPipeline)]$InputObject, $Path, [switch]$NoTypeInformation, $Encoding, [switch]$NoClobber)
            throw 'no space left on device'
        }
        $result = Set-MailboxForwards -Rows $rows
        Assert ($result.Applied -eq 1) 'CSV export failure must not hide the successful remote outcome.'
        Assert ($result.Errors -eq 0 -and $result.Skipped -eq 0) 'CSV export failure must not be reported as an Exchange failure.'
        Assert (($result.PersistenceErrors -join ' ') -match 'no space left on device') 'CSV export failure must be reported.'
        $cache = Read-MailboxCache
        Assert ($cache.Mailboxes[0].ForwardingSmtpAddress -eq 'persist2@archive.example.com') 'CSV failure must not block cache update.'
    }
} catch { $failures.Add("CSV failure: $_") }

# --- Progress completion reported even when a row fails ---------------------

try {
    $script:Calls = @()
    $script:ProgressEvents = New-Object 'System.Collections.Generic.List[string]'
    $rows = @('ok', 'bad') | ForEach-Object { NewRow $_ }
    WithTempScriptDir {
        [void](Set-MailboxForwards -Rows $rows -OnProgress {
            param($Index, $Total, $Mailbox)
            $script:ProgressEvents.Add("$Index/${Total}:$Mailbox")
        })
        Assert ($script:ProgressEvents.Count -eq 2) 'Progress callback must fire once per row, including the failed one.'
    }
} catch { $failures.Add("Progress completion: $_") }

# --- OnProgress throwing after a successful write must not discard ----------
# --- already-recorded outcomes or the audit trail ----------------------------

try {
    $script:Calls = @()
    $rows = @('ok1', 'ok2') | ForEach-Object { NewRow $_ }
    WithTempScriptDir {
        $callIndex = 0
        $result = Set-MailboxForwards -Rows $rows -OnProgress {
            param($Index, $Total, $Mailbox)
            $script:callIndex = $Index
            if ($Index -eq 2) { throw 'renderer crashed' }
        }
        Assert ($result.Applied -eq 2) 'Remote successes must be recorded even when the progress callback later throws.'
        Assert ($script:Calls.Count -eq 2) 'Both rows must still be applied despite the callback failure.'
        Assert (Test-Path $result.LogPath) 'Audit file must still be written when the progress callback throws.'
        Assert (@(Import-Csv $result.LogPath).Count -eq 2) 'Audit file must contain both outcomes.'
        Assert (($result.PersistenceErrors -join ' ') -match 'renderer crashed') 'Progress callback failure must be reported, not silently swallowed.'
    }
} catch { $failures.Add("OnProgress failure isolation: $_") }

if ($failures.Count) { throw ($failures -join "`n") }
Write-Host 'Forwarding.Tests.ps1: all assertions passed.'
