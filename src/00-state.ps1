# Module-scope state shared by the config/cache and Exchange source files.
# Dot-sourced first (00-) so later files can rely on it being set.
$script:ExoPagingConfigured = $false
# Connection IDs Connect-Exo itself opened (never a pre-existing/borrowed
# connection) - the only ones Disconnect-OwnedExoConnections may tear down.
$script:ExoOwnedConnectionIds = @()

# Shared UI-state shape consumed by src/60-mailbox-model.ps1's functions
# (Update-MailboxView, Set-MailboxSelection, etc.) and the TUI's render
# loop. Plain data only - no console/terminal calls here, so dot-sourcing
# this file (e.g. from tests) has no side effects.
# Height here is table row *capacity* (screen rows - 4), not the screen
# height - src/60-mailbox-model.ps1's scroll math already treats it that
# way, and src/70-views.ps1 keeps that meaning: callers pass the full
# screen size to Get-MailboxFrame and set $State.Height to size[1] - 4.
$script:UI = @{
    Items          = @()
    View           = @()
    Search         = ''
    Filter         = 'All'
    Cursor         = 0
    Scroll         = 0
    Height         = 0
    Status         = ''
    Account        = ''
    CacheFetchedAt = $null
    Width          = 0
    Dirty          = $true
    Running        = $true
    Searching      = $false
}

# Glyphs (Unicode with ASCII fallback via -Ascii / tests' TestSupport.ps1).
# [char] codes instead of literal Unicode source characters, matching
# SOAconverter's src/00-globals.ps1 convention.
if ($script:StartupOptions -and $script:StartupOptions.Ascii) {
    $script:G = @{
        H = '-'; V = '|'; Ell = '..'; ChkOn = '[x]'; ChkOff = '[ ]'; Arrow = '->'
    }
} else {
    $script:G = @{
        H = ([char]0x2500); V = ([char]0x2502); Ell = ([char]0x2026)
        ChkOn = ('[' + [char]0x25A0 + ']'); ChkOff = '[ ]'; Arrow = ([char]0x2192)
    }
}

# Theme (256-color SGR sequences), adapted from SOAconverter's src/00-globals.ps1.
$script:ESC = [char]27
$e = $script:ESC
$script:T = @{
    Reset     = "$e[0m"
    HeaderBg  = "$e[48;5;236m"
    HeaderTxt = "$e[38;5;252;48;5;236m"
    HeaderHi  = "$e[1;38;5;45;48;5;236m"
    ColHead   = "$e[1;38;5;250m"
    Row       = "$e[38;5;252m"
    RowDim    = "$e[38;5;245m"
    CursorBg  = "$e[48;5;24m"
    CursorFg  = "$e[38;5;231;48;5;24m"
    SelMark   = "$e[1;38;5;45m"
    Good      = "$e[38;5;42m"
    Warn      = "$e[38;5;220m"
    Danger    = "$e[1;38;5;196m"
    Muted     = "$e[38;5;245m"
    FootBg    = "$e[48;5;236m"
    FootKey   = "$e[1;38;5;45;48;5;236m"
    FootTxt   = "$e[38;5;245;48;5;236m"
}
