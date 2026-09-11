# MailboxForwardingTool.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'SelfTest',
    Justification = 'Bound via $PSBoundParameters at script scope; analyzer cannot see usage inside Main when dot-sourced.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'DisableWAM',
    Justification = 'Read inside Connect-Exo; analyzer cannot see usage when dot-sourced.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Ascii',
    Justification = 'Read inside src/00-state.ps1; analyzer cannot see usage when dot-sourced.')]
[CmdletBinding()]
param([switch]$SelfTest, [switch]$DisableWAM, [switch]$Ascii)

$script:EntryScriptPath = $PSCommandPath
$script:ScriptDir = $PSScriptRoot
$script:StartupOptions = @{ SelfTest = [bool]$SelfTest; DisableWAM = [bool]$DisableWAM; Ascii = [bool]$Ascii }
foreach ($source in (Get-ChildItem (Join-Path $script:ScriptDir 'src') -Filter '*.ps1' | Sort-Object Name)) {
    . $source.FullName
}

# MSAL interactive auth (legacy embedded browser fallback) instantiates a COM
# ActiveX control, which requires a single-threaded apartment (STA). Apartment
# state is fixed once per thread, so an MTA host can never be fixed in-place:
# relaunch the script in an explicit STA PowerShell process. This covers being
# started from hosts that default to MTA (e.g. some ISE-like or -Mta launches).
# Windows-only: apartment state and powershell.exe relaunch have no meaning
# on macOS/Linux, where Main() rejects the platform before any service call.
if ($script:IsWin -and [Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    # Spawned console windows close the instant the process exits, erasing
    # all log output - mark the child to pause before that happens.
    $env:EXOMFT_PAUSE_ON_EXIT = '1'
    $argList = @('-Sta','-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$script:EntryScriptPath`"")
    if ($script:StartupOptions.SelfTest)   { $argList += '-SelfTest' }
    if ($script:StartupOptions.DisableWAM) { $argList += '-DisableWAM' }
    if ($script:StartupOptions.Ascii)      { $argList += '-Ascii' }
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Wait -PassThru
    exit $p.ExitCode
}

function Main {
    # Reject an unsupported platform or host before touching config,
    # installing modules, or making any network call.
    if (-not $script:IsWin) {
        Write-Host 'Unsupported platform: this tool requires Windows (Exchange Online module sign-in and console VT APIs).'
        return 1
    }
    if (-not (Test-TuiHostSupported)) {
        Write-Host 'Interactive console required: input/output is redirected or unsupported. Run from a real terminal window, not a piped or redirected session.'
        return 1
    }

    # Config is loaded (and validated) before any module install: a
    # missing/invalid config.json must be reported without ever touching
    # the module or the network, especially for -SelfTest.
    $script:Config = Get-Config
    if (-not $script:Config -and $SelfTest) {
        Write-Host 'Configuration missing or invalid. Copy config.example.json to config.json next to the script, fill in ForwardingDomain and ServiceAccountUPN, then rerun.'
        return 1
    }

    Install-ExoModule

    if ($SelfTest) {
        # -SelfTest never touches the alternate screen buffer.
        Connect-Exo
        $list = @(Get-MailboxList -Force)
        Write-Host "Self-test OK. $($list.Count) mailboxes."
        return 0
    }

    try {
        Enter-Tui
        if (-not $script:Config) {
            # Missing config in normal mode: collect it through the same
            # settings dialog the TUI uses later, inside this one owned
            # TUI lifecycle (no extra Enter/Exit-Tui round trip).
            $script:Config = Show-SettingsDialog -Config $null
            if (-not $script:Config) { return 0 }
            Save-Config $script:Config
        }
        Connect-Exo
        Clear-DialogKeyQueue
        $mailboxes = @(Get-MailboxList -OnProgress { param($p) Show-FetchProgress -Progress $p })
        Clear-DialogKeyQueue
        $script:UI.Items = @(New-MailboxRows -Mailboxes $mailboxes -Config $script:Config)
        # The actual authenticated account, not the configured sign-in hint -
        # the operator can sign in as a different account (e.g. via WAM's
        # account picker).
        $script:UI.Account = Get-ExoAccountName -ConfiguredHint ([string]$script:Config.ServiceAccountUPN)
        $cache = Read-MailboxCache
        $script:UI.CacheFetchedAt = if ($cache) { [string]$cache.FetchedAt } else { $null }
        Update-MailboxView -State $script:UI
        Show-Tui
    } finally {
        Exit-Tui
    }
    return 0
}

$script:ExitCode = 0
try {
    $script:ExitCode = Main
} catch {
    # Restore the console first so fatal diagnostics land on the normal
    # buffer, not whatever was left of the TUI frame.
    Exit-Tui
    Write-Host "FATAL: $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    $script:ExitCode = 1
} finally {
    Exit-Tui
    # Best-effort disconnect of only connection IDs this run actually opened
    # (tracked in $script:ExoOwnedConnectionIds by Connect-Exo) - never a
    # connection this process merely found already active and reused.
    # Disconnect-ExchangeOnline with no -ConnectionId would tear down every
    # connection in the process, including a borrowed one.
    Disconnect-OwnedExoConnections
    # When double-clicked / launched via the .bat, or relaunched for STA/
    # -DisableWAM, the console closes the instant the script ends - taking
    # all log output with it. Keep it open on the normal buffer so the
    # operator can read or copy what happened.
    if ($env:EXOMFT_PAUSE_ON_EXIT -eq '1') {
        Read-Host 'Press Enter to close this window'
    }
}
exit $script:ExitCode
