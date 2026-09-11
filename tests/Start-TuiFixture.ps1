# Start-TuiFixture.ps1 - interactive, fully-offline driver for the TUI.
#
# Loads src/*.ps1 (the same files the real tool loads) and overrides every
# Exchange/module/write boundary before entering the TUI, so no code path in
# a fixture run can reach a real tenant. Never invoked from CI (headless
# hosts have no interactive console); run it by hand in a real terminal to
# exercise resize, search/filter, editing, preview, and apply against fake
# data.
#
# Root application entry point (MailboxForwardingTool.ps1) is never invoked
# here - this script builds its own minimal Enter-Tui/Show-Tui flow directly
# against src/*.ps1, skipping Main's platform/STA-relaunch/module-install
# logic entirely.
[CmdletBinding()]
param(
    [switch]$Ascii,
    # Defaults to a fresh directory under the OS temp path so config.json/
    # cache.json/changelog CSVs never touch the real checkout or collide
    # with a previous run. Override only to inspect artifacts afterward.
    [string]$ArtifactDir
)

$ErrorActionPreference = 'Stop'
$script:FixtureSrcRoot = Split-Path $PSScriptRoot -Parent

# Track whether this run generated the directory itself; only a
# self-generated directory is ours to delete on exit - an explicitly passed
# -ArtifactDir belongs to the caller and is left alone either way.
$script:OwnsArtifactDir = -not $ArtifactDir
if (-not $ArtifactDir) {
    $ArtifactDir = Join-Path ([IO.Path]::GetTempPath()) ("exomft-fixture-" + [guid]::NewGuid().ToString('N'))
}
New-Item -ItemType Directory -Path $ArtifactDir -Force | Out-Null

# src/30-config-cache.ps1 derives $script:ConfigPath/$script:CachePath from
# $script:ScriptDir at dot-source time - pointing it at the fixture's own
# temp directory before sourcing means every config/cache/audit file this
# run writes lands there, never in the real checkout.
$script:EntryScriptPath = Join-Path $script:FixtureSrcRoot 'MailboxForwardingTool.ps1'
$script:ScriptDir = $ArtifactDir
$script:StartupOptions = @{ SelfTest = $false; DisableWAM = $false; Ascii = [bool]$Ascii }

foreach ($source in (Get-ChildItem (Join-Path $script:FixtureSrcRoot 'src') -Filter '*.ps1' | Sort-Object Name)) {
    . $source.FullName
}

# --- Offline boundary stubs -------------------------------------------------
# Every function a real run would use to reach EXO or the module gallery is
# replaced here. No stub below calls through to the real cmdlet/module.
function Install-ExoModule { }
function Connect-Exo { }
function Get-EXOMailbox { throw 'Fixture bug: Get-EXOMailbox must never be called; Get-MailboxList is stubbed instead.' }
function Get-ConnectionInformation { @() }

function Set-Mailbox {
    [CmdletBinding()]
    param($Identity, $ForwardingSmtpAddress, [bool]$DeliverToMailboxAndForward)
    if ($Identity -eq 'user2@example.com') { throw 'Fixture write failure' }
}

# ~110 fake mailboxes: long addresses (wrap-testing), a mix of existing
# forwards, on-prem flags, and deliver-and-store, plus 'user2@example.com'
# so the write-failure stub above is reachable from the fixture's own data.
$script:FixtureMailboxes = @(
    0..109 | ForEach-Object {
        $i = $_
        $local = if ($i -eq 2) { 'user2' } else { "user$i.longlonglonglonglonglocalpart-wraptest" }
        [pscustomobject]@{
            PrimarySmtpAddress         = "$local@example.com"
            ForwardingSmtpAddress      = if ($i % 3 -eq 0) { "existing-forward-$i@already-forwarded.example.net" } else { '' }
            DeliverToMailboxAndForward = ($i % 5 -eq 0)
            HasOnPremForwardingAddress = ($i % 7 -eq 0)
        }
    }
)

function Get-MailboxList {
    param([switch]$Force, [scriptblock]$OnProgress)
    if ($OnProgress) {
        & $OnProgress @{
            Activity = 'Exchange Online'; Status = 'OFFLINE FIXTURE: loaded fake mailboxes'
            Count = $script:FixtureMailboxes.Count; Total = $null; Completed = $false
        }
    }
    return $script:FixtureMailboxes
}

# --- Fixture config (no config.json required/written) -----------------------
$script:Config = [pscustomobject]@{
    ForwardingDomain           = 'fixture-archive.example.com'
    ServiceAccountUPN          = 'fixture.user@example.com'
    CacheTtlHours              = 24
    DeliverToMailboxAndForward = $false
}

Write-Host "OFFLINE FIXTURE: artifacts in $ArtifactDir"

try {
    Enter-Tui
    Connect-Exo
    $mailboxes = @(Get-MailboxList -OnProgress { param($p) Show-FetchProgress -Progress $p })
    $script:UI.Items = @(New-MailboxRows -Mailboxes $mailboxes -Config $script:Config)
    $script:UI.Account = 'OFFLINE FIXTURE'
    $script:UI.Status = 'OFFLINE FIXTURE'
    Update-MailboxView -State $script:UI
    Show-Tui
} finally {
    Exit-Tui
    if ($script:OwnsArtifactDir) {
        # Only remove a directory this run generated itself (config.json/
        # cache.json/changelog CSVs it wrote) - never a caller-supplied path.
        Remove-Item -Recurse -Force -Path $ArtifactDir -ErrorAction SilentlyContinue
        Write-Host "OFFLINE FIXTURE: exited; fixture artifacts removed ($ArtifactDir)."
    } else {
        Write-Host "OFFLINE FIXTURE: exited; artifacts remain in $ArtifactDir"
    }
}
