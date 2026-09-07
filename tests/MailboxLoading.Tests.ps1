# Offline mailbox-loading regression checks. Run with PowerShell 5.1 or newer.
$ErrorActionPreference = 'Stop'
$path = Join-Path (Split-Path $PSScriptRoot -Parent) 'MailboxForwardingTool.ps1'
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw "Parse errors: $parseErrors" }
# Load functions without executing module installation, authentication, or WinForms startup.
foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}

function Assert($Condition, $Message) {
    if (-not $Condition) { throw $Message }
}
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
            $DisableWAM = $disable
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
if ($failures.Count) { throw ($failures -join "`n") }
Microsoft.PowerShell.Utility\Write-Host 'Mailbox loading checks passed (2 connection paths, 9 enumeration cases).'
