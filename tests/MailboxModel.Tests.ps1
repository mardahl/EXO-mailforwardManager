. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$config = [pscustomobject]@{ ForwardingDomain = 'archive.example.com'; DeliverToMailboxAndForward = $true }

# --- New-MailboxRows -------------------------------------------------------

$raw = @('alice', 'bob') | ForEach-Object {
    [pscustomobject]@{
        PrimarySmtpAddress          = "$_@example.com"
        ForwardingSmtpAddress       = ''
        DeliverToMailboxAndForward  = $false
        HasOnPremForwardingAddress  = $false
    }
}
$items = @(New-MailboxRows -Mailboxes @($raw) -Config $config)
Assert ($items.Count -eq 2) 'Expected one row per mailbox.'
Assert ($items[0].PrimarySmtpAddress -eq 'alice@example.com') 'Address not copied.'
Assert ($items[0].ForwardingPrefix -eq 'alice') 'Prefix must default to local-part.'
Assert ($items[0].WillForwardTo -eq 'alice@archive.example.com') 'WillForwardTo must combine prefix+domain.'
Assert ($items[0].DeliverAndStore -eq $true) 'DeliverAndStore must come from config default.'
Assert ($items[0].Selected -eq $false) 'Rows must start unselected.'

$blankPrefixRaw = [pscustomobject]@{
    PrimarySmtpAddress = '@example.com'; ForwardingSmtpAddress = ''
    DeliverToMailboxAndForward = $false; HasOnPremForwardingAddress = $false
}
$blankPrefixItem = @(New-MailboxRows -Mailboxes @($blankPrefixRaw) -Config $config)[0]
Assert ($blankPrefixItem.WillForwardTo -eq '') 'Blank prefix must yield blank WillForwardTo.'

$onPremRaw = [pscustomobject]@{
    PrimarySmtpAddress = 'carol@example.com'; ForwardingSmtpAddress = 'legacy@onprem.example.com'
    DeliverToMailboxAndForward = $false; HasOnPremForwardingAddress = $true
}
$onPremItem = @(New-MailboxRows -Mailboxes @($onPremRaw) -Config $config)[0]
Assert ($onPremItem.HasOnPremForwarding -eq $true) 'On-prem flag must surface as boolean true.'

Assert (@(New-MailboxRows -Mailboxes @() -Config $config).Count -eq 0) 'Empty mailbox list must yield no rows.'

# --- Update-MailboxView: filters, search, cursor clamp ---------------------

$state = @{ Items = $items; View = @(); Search = 'alice'; Filter = 'All'; Cursor = 0; Scroll = 0; Height = 20 }
Update-MailboxView -State $state
Assert ($state.View.Count -eq 1 -and $state.View[0].PrimarySmtpAddress -eq 'alice@example.com') 'Search must filter to Alice.'

$state.Search = 'ALICE'
Update-MailboxView -State $state
Assert ($state.View.Count -eq 1) 'Search must be case-insensitive.'

$items[0].CurrentForwarding = 'x@y.com'
$state.Search = ''
$state.Filter = 'HasForward'
Update-MailboxView -State $state
Assert ($state.View.Count -eq 1 -and $state.View[0].PrimarySmtpAddress -eq 'alice@example.com') 'HasForward filter wrong.'

$state.Filter = 'NoForward'
Update-MailboxView -State $state
Assert ($state.View.Count -eq 1 -and $state.View[0].PrimarySmtpAddress -eq 'bob@example.com') 'NoForward filter wrong.'

$state.Filter = 'All'
$state.Cursor = 99
Update-MailboxView -State $state
Assert ($state.Cursor -eq 1) 'Cursor must clamp to last row.'

$state.Search = 'nobody'
Update-MailboxView -State $state
Assert ($state.View.Count -eq 0 -and $state.Cursor -eq 0) 'Empty view must clamp cursor to zero.'

$state.Search = 'alice'
$state.Cursor = 5
Update-MailboxView -State $state
Assert ($state.Cursor -eq 0) 'Singleton view must clamp cursor to only row.'

# --- Cursor/scroll bounds: empty view and smaller viewport ------------------

$scrollState = @{ Items = $items; View = @(); Search = 'nobody'; Filter = 'All'; Cursor = 3; Scroll = 3; Height = 20 }
Update-MailboxView -State $scrollState
Assert ($scrollState.Cursor -eq 0 -and $scrollState.Scroll -eq 0) 'Empty view must reset both cursor and scroll to zero.'

$fiveRaw = 1..5 | ForEach-Object {
    [pscustomobject]@{ PrimarySmtpAddress = "u$_@example.com"; ForwardingSmtpAddress = ''
        DeliverToMailboxAndForward = $false; HasOnPremForwardingAddress = $false }
}
$fiveItems = @(New-MailboxRows -Mailboxes @($fiveRaw) -Config $config)
$viewportState = @{ Items = $fiveItems; View = @(); Search = ''; Filter = 'All'; Cursor = 0; Scroll = 0; Height = 3 }
Update-MailboxView -State $viewportState
Assert ($viewportState.Scroll -eq 0) 'Viewport smaller than list must start scrolled to top.'

$viewportState.Cursor = 4
Update-MailboxView -State $viewportState
Assert ($viewportState.Scroll -eq 2) 'Cursor past bottom of viewport must pull scroll down to keep cursor visible.'

$viewportState.Cursor = 0
Update-MailboxView -State $viewportState
Assert ($viewportState.Scroll -eq 0) 'Cursor above viewport must pull scroll back up to keep cursor visible.'

$viewportState.Cursor = 2
Update-MailboxView -State $viewportState
Assert ($viewportState.Scroll -eq 0) 'Cursor still inside current viewport must not move scroll.'

# --- Selection: Visible/None + hidden accounting ---------------------------

$state.Search = ''
Update-MailboxView -State $state
$items[1].Selected = $true
$state.Search = 'alice'
Update-MailboxView -State $state
Set-MailboxSelection -State $state -Mode Visible
$counts = Get-SelectionCounts -State $state
Assert ($counts.Total -eq 2 -and $counts.Hidden -eq 1) 'Hidden selections lost.'

[void](Set-MailboxDraft -Row $state.View[0] -Prefix 'archive-alice' -DeliverAndStore $false -Domain $config.ForwardingDomain)
Assert ($items[0].WillForwardTo -eq 'archive-alice@archive.example.com') 'Filtered edit targeted wrong object.'

Set-MailboxSelection -State $state -Mode None
Assert ((Get-SelectionCounts -State $state).Total -eq 0) 'Clear must include hidden rows.'

# --- Selection: Toggle advances cursor --------------------------------------

$state.Search = ''
Update-MailboxView -State $state
$state.Cursor = 0
Set-MailboxSelection -State $state -Mode Toggle
Assert ($state.View[0].Selected -eq $true) 'Toggle must select current row.'
Assert ($state.Cursor -eq 1) 'Toggle must advance cursor.'
Set-MailboxSelection -State $state -Mode Toggle
Assert ($state.View[1].Selected -eq $true) 'Toggle must select second row.'
Assert ($state.Cursor -eq 1) 'Toggle must not run past last row.'
Set-MailboxSelection -State $state -Mode Toggle
Assert ($state.View[1].Selected -eq $false) 'Second toggle on same row must un-select.'

# --- Draft validation: canceled/invalid edits preserve original values -----
# Contract: invalid edits throw (no row mutation, no success-stream output);
# a valid edit mutates the row and produces no output either (dialogs catch
# the exception on the invalid path; there is nothing to catch on success).

function Assert-DraftRejected([scriptblock]$Attempt, [string]$Message) {
    $threw = $false
    try { & $Attempt } catch { $threw = $true }
    Assert $threw $Message
}

$row = [pscustomobject]@{
    ForwardingPrefix = 'orig'; WillForwardTo = 'orig@archive.example.com'
    DeliverAndStore = $true; Selected = $false
}
Assert-DraftRejected { Set-MailboxDraft -Row $row -Prefix 'has@at' -DeliverAndStore $false -Domain 'archive.example.com' } `
    'Prefix containing @ must be rejected.'
Assert ($row.ForwardingPrefix -eq 'orig' -and $row.WillForwardTo -eq 'orig@archive.example.com') 'Invalid edit must not mutate row.'

Assert-DraftRejected { Set-MailboxDraft -Row $row -Prefix "bad`nprefix" -DeliverAndStore $false -Domain 'archive.example.com' } `
    'Prefix with control character must be rejected.'
Assert ($row.ForwardingPrefix -eq 'orig') 'Control-char edit must not mutate row.'

Assert-DraftRejected { Set-MailboxDraft -Row $row -Prefix 'newname' -DeliverAndStore $false -Domain 'not_a_host!' } `
    'Invalid destination domain must be rejected.'
Assert ($row.ForwardingPrefix -eq 'orig') 'Rejected-domain edit must not mutate row.'

Assert-DraftRejected { Set-MailboxDraft -Row $row -Prefix '' -DeliverAndStore $true -Domain 'archive.example.com' } `
    'Blank prefix must be rejected (no clear-forward via blank prefix).'
Assert-DraftRejected { Set-MailboxDraft -Row $row -Prefix '   ' -DeliverAndStore $true -Domain 'archive.example.com' } `
    'Whitespace-only prefix must be rejected.'
Assert ($row.ForwardingPrefix -eq 'orig' -and $row.WillForwardTo -eq 'orig@archive.example.com') 'Rejected blank/whitespace edit must not mutate row.'

$output = Set-MailboxDraft -Row $row -Prefix 'newname' -DeliverAndStore $true -Domain 'archive.example.com'
Assert ($null -eq $output) 'Successful edit must produce no success-stream output.'
Assert ($row.WillForwardTo -eq 'newname@archive.example.com' -and $row.DeliverAndStore -eq $true) 'Valid edit must update row.'

# --- Domain recalculation preserves prefix/keep-copy/selection --------------

$row2 = [pscustomobject]@{
    ForwardingPrefix = 'kept'; WillForwardTo = 'kept@old.example.com'
    DeliverAndStore = $true; Selected = $true
}
$output = Set-MailboxDraft -Row $row2 -Prefix $row2.ForwardingPrefix -DeliverAndStore $row2.DeliverAndStore -Domain 'new.example.com'
Assert ($null -eq $output) 'Domain recalculation must produce no success-stream output.'
Assert ($row2.ForwardingPrefix -eq 'kept') 'Domain recalculation must preserve prefix.'
Assert ($row2.DeliverAndStore -eq $true) 'Domain recalculation must preserve keep-copy flag.'
Assert ($row2.WillForwardTo -eq 'kept@new.example.com') 'Domain recalculation must update WillForwardTo.'
Assert ($row2.Selected -eq $true) 'Domain recalculation must not touch selection (function does not own it).'

# --- Merge-MailboxRefresh: matches update, drafts survive, membership fixed -

$mergeItems = @(
    [pscustomobject]@{
        PrimarySmtpAddress = 'alice@example.com'; CurrentForwarding = ''
        HasOnPremForwarding = $false; ForwardingPrefix = 'archive-alice'
        WillForwardTo = 'archive-alice@archive.example.com'; DeliverAndStore = $false; Selected = $true
    },
    [pscustomobject]@{
        PrimarySmtpAddress = 'bob@example.com'; CurrentForwarding = ''
        HasOnPremForwarding = $false; ForwardingPrefix = 'bob'
        WillForwardTo = 'bob@archive.example.com'; DeliverAndStore = $false; Selected = $false
    }
)
$mergeState = @{ Items = $mergeItems; View = $mergeItems; Search = ''; Filter = 'All'; Cursor = 0; Scroll = 0; Height = 20 }
$fresh = @(
    [pscustomobject]@{ PrimarySmtpAddress = 'alice@example.com'; ForwardingSmtpAddress = 'x@onprem.com'; HasOnPremForwardingAddress = $true },
    [pscustomobject]@{ PrimarySmtpAddress = 'carol@example.com'; ForwardingSmtpAddress = ''; HasOnPremForwardingAddress = $false }
)
Merge-MailboxRefresh -State $mergeState -Mailboxes $fresh
Assert ($mergeState.Items.Count -eq 2) 'Merge must not add or drop records (extra source record ignored).'
Assert ($mergeItems[0].CurrentForwarding -eq 'x@onprem.com') 'Matching record must update CurrentForwarding.'
Assert ($mergeItems[0].HasOnPremForwarding -eq $true) 'Matching record must update HasOnPremForwarding.'
Assert ($mergeItems[0].ForwardingPrefix -eq 'archive-alice') 'Draft prefix must survive refresh.'
Assert ($mergeItems[0].WillForwardTo -eq 'archive-alice@archive.example.com') 'Draft WillForwardTo must survive refresh.'
Assert ($mergeItems[0].Selected -eq $true) 'Selection must survive refresh.'
Assert ($mergeItems[1].CurrentForwarding -eq '') 'Unmatched record (bob dropped from source) must be left alone.'

Write-Host 'MailboxModel.Tests.ps1: all assertions passed.'
