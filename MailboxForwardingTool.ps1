# MailboxForwardingTool.ps1
[CmdletBinding()]
param([switch]$SelfTest)

$Script:ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:ConfigPath = Join-Path $Script:ScriptDir 'config.json'
$Script:CachePath  = Join-Path $Script:ScriptDir 'cache.json'

#region Config

function Get-Config {
    if (-not (Test-Path $Script:ConfigPath)) { return $null }
    try {
        $raw = Get-Content $Script:ConfigPath -Raw | ConvertFrom-Json
        if (-not $raw.ForwardingDomain -or -not $raw.ServiceAccountUPN) { return $null }
        $ttl = 24
        if ($raw.PSObject.Properties.Name -contains 'CacheTtlHours') {
            [int]::TryParse([string]$raw.CacheTtlHours, [ref]$ttl) | Out-Null
        }
        [pscustomobject]@{
            ForwardingDomain           = [string]$raw.ForwardingDomain
            DeliverToMailboxAndForward = [bool]$raw.DeliverToMailboxAndForward
            ServiceAccountUPN          = [string]$raw.ServiceAccountUPN
            CacheTtlHours              = $ttl
        }
    } catch { return $null }
}

function Save-Config {
    param([Parameter(Mandatory)]$Config)
    $Config | ConvertTo-Json -Depth 5 | Set-Content -Path $Script:ConfigPath -Encoding UTF8
}

function Show-SettingsDialog {
    param($Config)
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $form = New-Object Windows.Forms.Form -Property @{
        Text='Settings'; Width=420; Height=260; StartPosition='CenterScreen'; FormBorderStyle='FixedDialog'
    }
    $y = 16
    $labels = 'Forwarding domain','Service account UPN','Cache TTL (hours)'
    $boxes  = @{}
    foreach ($label in $labels) {
        $l = New-Object Windows.Forms.Label -Property @{ Text=$label; Left=16; Top=$y+4; Width=160 }
        $t = New-Object Windows.Forms.TextBox -Property @{ Left=184; Top=$y; Width=200 }
        $form.Controls.AddRange(@($l,$t))
        $boxes[$label] = $t
        $y += 32
    }
    $cb = New-Object Windows.Forms.CheckBox -Property @{
        Text='Deliver to mailbox AND forward'; Left=184; Top=$y; Width=220
    }
    $form.Controls.Add($cb)

    if ($Config) {
        $boxes['Forwarding domain'].Text      = $Config.ForwardingDomain
        $boxes['Service account UPN'].Text    = $Config.ServiceAccountUPN
        $boxes['Cache TTL (hours)'].Text      = "$($Config.CacheTtlHours)"
        $cb.Checked = $Config.DeliverToMailboxAndForward
    } else {
        $boxes['Cache TTL (hours)'].Text = '24'
    }

    $ok = New-Object Windows.Forms.Button -Property @{
        Text='Save'; Left=224; Top=$y+40; Width=80; DialogResult='OK'
    }
    $cancel = New-Object Windows.Forms.Button -Property @{
        Text='Cancel'; Left=312; Top=$y+40; Width=80; DialogResult='Cancel'
    }
    $form.AcceptButton = $ok; $form.CancelButton = $cancel
    $form.Controls.AddRange(@($ok,$cancel))

    if ($form.ShowDialog() -ne 'OK') { return $null }
    $ttl = 24
    [void][int]::TryParse($boxes['Cache TTL (hours)'].Text, [ref]$ttl)
    [pscustomobject]@{
        ForwardingDomain           = $boxes['Forwarding domain'].Text.Trim()
        DeliverToMailboxAndForward = $cb.Checked
        ServiceAccountUPN          = $boxes['Service account UPN'].Text.Trim()
        CacheTtlHours              = $ttl
    }
}

#endregion

#region Exchange

function Connect-Exo {
    if (Get-ConnectionInformation -ErrorAction SilentlyContinue) { return }
    Connect-ExchangeOnline -UserPrincipalName $Script:Config.ServiceAccountUPN -ShowBanner:$false
}

function Save-MailboxCache {
    param([Parameter(Mandatory)]$Mailboxes)
    [pscustomobject]@{
        FetchedAt = (Get-Date).ToUniversalTime().ToString('o')
        Mailboxes = $Mailboxes
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $Script:CachePath -Encoding UTF8
}

function Read-MailboxCache {
    if (-not (Test-Path $Script:CachePath)) { return $null }
    try { Get-Content $Script:CachePath -Raw | ConvertFrom-Json } catch { $null }
}

function Test-CacheFresh {
    param($Cache)
    if (-not $Cache -or -not $Cache.FetchedAt) { return $false }
    $age = (Get-Date).ToUniversalTime() - [datetime]$Cache.FetchedAt
    $age.TotalHours -lt $Script:Config.CacheTtlHours
}

function Get-MailboxList {
    param([switch]$Force)
    $cache = Read-MailboxCache
    if (-not $Force -and (Test-CacheFresh $cache)) {
        return $cache.Mailboxes
    }
    Connect-Exo
    $mbx = Get-EXOMailbox -ResultSize Unlimited -RecipientTypeDetails UserMailbox `
        -Properties ForwardingSmtpAddress, DeliverToMailboxAndForward, ForwardingAddress
    $list = foreach ($m in $mbx) {
        [pscustomobject]@{
            PrimarySmtpAddress           = [string]$m.PrimarySmtpAddress
            ForwardingSmtpAddress        = if ($m.ForwardingSmtpAddress) { ($m.ForwardingSmtpAddress -replace '^smtp:','') } else { '' }
            DeliverToMailboxAndForward   = [bool]$m.DeliverToMailboxAndForward
            HasOnPremForwardingAddress   = [bool]$m.ForwardingAddress
        }
    }
    Save-MailboxCache -Mailboxes $list
    $list
}

#endregion
