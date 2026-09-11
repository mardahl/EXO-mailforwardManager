function Install-ExoModule {
    # Zero-touch dependency: ExchangeOnlineManagement >= 3.7.2 required.
    # 3.7.0 integrated WAM (Web Account Manager) broker auth; 3.7.2 added the
    # -DisableWAM fallback switch. Older versions fall back to the legacy MSAL
    # embedded browser, which hosts a COM ActiveX control and is the source of
    # the "ActiveX control 8856f961-... cannot be instantiated" failures.
    # https://learn.microsoft.com/powershell/exchange/exchange-online-powershell-v2
    $minVersion = [version]'3.7.2'
    $installed = Get-Module -ListAvailable -Name ExchangeOnlineManagement |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $installed -or $installed.Version -lt $minVersion) {
        Write-Host "ExchangeOnlineManagement >= $minVersion required (found: $($installed.Version)); installing/updating for current user..."
        $nuget = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
        if (-not $nuget -or $nuget.Version -lt [version]'2.8.5.201') {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
        }
        if ((Get-PSRepository -Name PSGallery).InstallationPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        }
        Install-Module -Name ExchangeOnlineManagement -Scope CurrentUser -Force -AllowClobber -MinimumVersion $minVersion
    }
    # Import newest available version explicitly: an already-installed old copy
    # can shadow the fresh one on PSModulePath.
    $newest = Get-Module -ListAvailable -Name ExchangeOnlineManagement |
        Sort-Object Version -Descending | Select-Object -First 1
    Import-Module (Join-Path $newest.ModuleBase "$($newest.Name).psd1") -ErrorAction Stop -Global
}

function Connect-Exo {
    if ($Script:ExoPagingConfigured -and (Get-ConnectionInformation -ErrorAction SilentlyContinue)) { return }
    # Interactive sign-in (WAM account picker or the MSAL embedded browser)
    # needs the normal screen buffer, not the TUI's alternate buffer - route
    # it through Invoke-OnMainBuffer so it works whether Connect-Exo is
    # called before the TUI starts or later, from Refresh.
    Invoke-OnMainBuffer -Action {
        # Deliberately no -UserPrincipalName: passing the UPN as a login hint
        # makes MSAL do directed auth against an account that may not exist
        # in the Windows account broker -> "Missing wamcompat_id_token in WAM
        # case" (MSAL bug #4095) and a sign-in window that flashes and dies.
        # Without the hint, WAM shows the account picker / the browser flow
        # prompts for credentials, and the operator just signs in. The
        # configured UPN is shown to the operator as guidance instead.
        $connectArgs = @{
            ShowBanner  = $false
            ErrorAction = 'Stop'
            PageSize    = 100
        }
        Write-Host "Sign in as $($Script:Config.ServiceAccountUPN) when prompted."
        # Snapshot connection IDs before dialing so the connection(s) this
        # call actually creates can be told apart from any pre-existing
        # (borrowed) connection already in this process - Disconnect-
        # ExchangeOnline with no -ConnectionId tears down every connection,
        # including a borrowed one, so ownership must be tracked per-ID.
        $before = @(Get-ConnectionInformation -ErrorAction SilentlyContinue | ForEach-Object { $_.ConnectionId })
        if ($script:StartupOptions.DisableWAM) {
            # Relaunched with -DisableWAM: skip the WAM broker entirely and
            # use the MSAL interactive browser from the start of this fresh
            # process.
            Connect-ExchangeOnline @connectArgs -DisableWAM
        } else {
            try {
                # Module >= 3.7.0: WAM broker auth (default). No embedded
                # browser, no ActiveX control, works on any apartment state.
                Connect-ExchangeOnline @connectArgs
            } catch {
                # Flatten the whole exception chain: MSAL wraps broker
                # failures ("Error Acquiring Token: ... Missing
                # wamcompat_id_token in WAM case", known MSAL bug
                # AzureAD/MSAL.NET#4095, no fix) inside generic outer
                # exceptions, so the top-level message often lacks "WAM".
                $fullMessage = ''
                $e = $_.Exception
                while ($e) { $fullMessage += " " + $e.Message; $e = $e.InnerException }
                if ($fullMessage -notmatch 'WAM|Web Account Manager|broker|wamcompat') { throw }
                # -DisableWAM only reliably takes effect when set before the
                # first connect in a process: the EXO module latches MSAL
                # broker/native msalruntime state, so an in-session retry
                # hits WAM again (observed with module 3.10.1). Relaunch in
                # a fresh process with the switch instead. The relaunched
                # instance skips the WAM attempt entirely.
                Write-Warning "WAM sign-in failed; restarting with broker auth disabled (-DisableWAM)."
                $argList = @('-Sta','-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$script:EntryScriptPath`"",'-DisableWAM')
                if ($script:StartupOptions.SelfTest) { $argList += '-SelfTest' }
                if ($script:StartupOptions.Ascii)    { $argList += '-Ascii' }
                $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Wait -PassThru
                exit $p.ExitCode
            }
        }
        # Only IDs that appeared after this call are ours; a pre-existing
        # (borrowed) connection's ID was already in $before and is excluded.
        $newIds = @(Get-ConnectionInformation -ErrorAction SilentlyContinue |
            Where-Object { $_.ConnectionId -and $_.ConnectionId -notin $before } |
            ForEach-Object { $_.ConnectionId })
        $script:ExoOwnedConnectionIds = @($script:ExoOwnedConnectionIds) + $newIds
        $Script:ExoPagingConfigured = $true
    }
}

function Disconnect-OwnedExoConnections {
    # Best-effort cleanup for the root script's finally block: disconnect
    # only connection IDs this run itself opened (tracked above). Never call
    # Disconnect-ExchangeOnline with no -ConnectionId - that disconnects
    # every connection in the process, including one this run only found
    # already active and reused.
    foreach ($id in @($script:ExoOwnedConnectionIds)) {
        try { Disconnect-ExchangeOnline -ConnectionId $id -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { }
    }
    $script:ExoOwnedConnectionIds = @()
}

function Get-ExoAccountName {
    # The configured ServiceAccountUPN is a sign-in hint, not proof of the
    # authenticated identity (the operator can sign in as a different
    # account, e.g. via WAM's account picker). Prefer the actual connected
    # UserPrincipalName; fall back to an explicit "unknown" rather than
    # silently presenting the configured hint as if it were the real account.
    param([string]$ConfiguredHint)
    try {
        $info = @(Get-ConnectionInformation -ErrorAction SilentlyContinue) | Select-Object -First 1
        if ($info -and $info.UserPrincipalName) { return [string]$info.UserPrincipalName }
    } catch { }
    if ($ConfiguredHint) { return "(unknown; sign-in hint: $ConfiguredHint)" }
    return '(unknown)'
}

function Send-ExoProgress {
    # Single choke point for mailbox-loading progress: with -OnProgress, hand
    # the caller a plain hashtable (no console/host calls at all, so the TUI
    # never gets Write-Host/Write-Progress bleed into its frame); without it,
    # fall back to the original console-only behavior unchanged.
    param(
        [string]$Status,
        [scriptblock]$OnProgress,
        [int]$Count = 0,
        [switch]$Completed
    )
    if ($OnProgress) {
        $progress = @{ Activity = 'Exchange Online'; Status = $Status; Count = $Count; Total = $null; Completed = [bool]$Completed }
        # Presentation-only: a broken callback must never replace or
        # masquerade as a real fetch/Exchange error - especially from inside
        # a `finally` block, where an uncaught exception here would silently
        # discard whatever error was already propagating out of the try.
        try { & $OnProgress $progress | Out-Null } catch { }
        return
    }
    if ($Completed) { Write-Progress -Activity 'Exchange Online' -Completed; return }
    Write-Host $Status
    Write-Progress -Activity 'Exchange Online' -Status $Status
}

function Get-MailboxList {
    param([switch]$Force, [scriptblock]$OnProgress)
    $cache = Read-MailboxCache
    if (-not $Force -and (Test-CacheFresh $cache)) {
        # Route through Send-ExoProgress, same as every other status below:
        # with -OnProgress supplied (i.e. called from inside the active TUI)
        # this must never fall back to Write-Host, or console text leaks
        # into the alternate screen buffer's frame.
        Send-ExoProgress -OnProgress $OnProgress -Count (@($cache.Mailboxes).Count) -Completed:$false `
            -Status "Using cached mailbox list ($(@($cache.Mailboxes).Count) mailboxes, fetched $($cache.FetchedAt))."
        return $cache.Mailboxes
    }
    Connect-Exo
    Send-ExoProgress -OnProgress $OnProgress -Status 'Loading user mailboxes in pages of up to 100. Large tenants can take several minutes; total count is not known yet.'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $count = 0
    try {
        # Buffer mapped results until the whole query succeeds; never publish a partial list.
        $list = @(Get-EXOMailbox -ResultSize Unlimited -RecipientTypeDetails UserMailbox `
            -Properties ForwardingSmtpAddress, DeliverToMailboxAndForward, ForwardingAddress -ErrorAction Stop |
            ForEach-Object {
                $m = $_
                [pscustomobject]@{
                    PrimarySmtpAddress           = [string]$m.PrimarySmtpAddress
                    ForwardingSmtpAddress        = if ($m.ForwardingSmtpAddress) { ($m.ForwardingSmtpAddress -replace '^smtp:','') } else { '' }
                    DeliverToMailboxAndForward   = [bool]$m.DeliverToMailboxAndForward
                    HasOnPremForwardingAddress   = [bool]$m.ForwardingAddress
                }
                $count++
                if ($count % 100 -eq 0) {
                    $status = "Retrieved $count mailboxes; elapsed $($timer.Elapsed.ToString('hh\:mm\:ss')). Still loading..."
                    Send-ExoProgress -OnProgress $OnProgress -Count $count -Status $status
                }
            })
    } catch {
        throw "Mailbox loading failed after receiving $count mailboxes. Partial results were discarded; existing cache was not changed. Exchange error: $($_.Exception.Message)"
    } finally {
        $timer.Stop()
        Send-ExoProgress -OnProgress $OnProgress -Completed
    }
    Save-MailboxCache -Mailboxes $list
    Send-ExoProgress -OnProgress $OnProgress -Count $list.Count -Status "Retrieved $($list.Count) mailboxes; elapsed $($timer.Elapsed.ToString('hh\:mm\:ss')). Loading complete."
    $list
}
