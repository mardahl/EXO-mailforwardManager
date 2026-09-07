# MailboxForwardingTool.ps1
[CmdletBinding()]
param([switch]$SelfTest)

$Script:ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:ConfigPath = Join-Path $Script:ScriptDir 'config.json'
$Script:CachePath  = Join-Path $Script:ScriptDir 'cache.json'

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

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

#region Actions

function Show-PreviewDialog {
    param([Parameter(Mandatory)][array]$Rows)
    $f = New-Object Windows.Forms.Form -Property @{
        Text='Preview changes'; Width=820; Height=520; StartPosition='CenterParent'
    }
    $lv = New-Object Windows.Forms.ListView -Property @{
        Left=12; Top=12; Width=780; Height=430; View='Details'; FullRowSelect=$true; GridLines=$true
    }
    [void]$lv.Columns.Add('Mailbox',200)
    [void]$lv.Columns.Add('Old forward',220)
    [void]$lv.Columns.Add('New forward',220)
    [void]$lv.Columns.Add('Deliver+Store',110)

    foreach ($r in $Rows) {
        $item = New-Object Windows.Forms.ListViewItem($r.PrimarySmtpAddress)
        [void]$item.SubItems.Add($r.CurrentForwarding)
        [void]$item.SubItems.Add($r.WillForwardTo)
        [void]$item.SubItems.Add($(if ($r.DeliverAndStore) { 'yes' } else { 'no' }))
        if ($r.CurrentForwarding -and $r.CurrentForwarding -ne $r.WillForwardTo) {
            $item.ForeColor = [Drawing.Color]::DarkRed
        }
        if ($r.HasOnPremForwarding) {
            $item.ForeColor = [Drawing.Color]::DarkOrange
            $item.SubItems[2].Text = '(skip — on-prem forward set)'
        }
        [void]$lv.Items.Add($item)
    }

    $btnApply  = New-Object Windows.Forms.Button -Property @{ Text='Apply';  Left=600; Top=452; Width=90; DialogResult='OK' }
    $btnCancel = New-Object Windows.Forms.Button -Property @{ Text='Cancel'; Left=702; Top=452; Width=90; DialogResult='Cancel' }
    $f.AcceptButton=$btnApply; $f.CancelButton=$btnCancel
    $f.Controls.AddRange(@($lv,$btnApply,$btnCancel))
    ($f.ShowDialog() -eq 'OK')
}

function Apply-Forwards {
    param([Parameter(Mandatory)][array]$Rows)

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $logPath = Join-Path $Script:ScriptDir "changelog-$stamp.csv"
    $log = New-Object System.Collections.Generic.List[object]

    foreach ($r in $Rows) {
        $old = $r.CurrentForwarding
        $new = $r.WillForwardTo
        if ($r.HasOnPremForwarding) {
            $log.Add([pscustomobject]@{
                Timestamp=(Get-Date).ToString('o'); Mailbox=$r.PrimarySmtpAddress
                OldForwardingSmtpAddress=$old; NewForwardingSmtpAddress=$new
                DeliverToMailboxAndForward=$r.DeliverAndStore
                Result='Skipped'; Error='On-prem ForwardingAddress set'
            })
            continue
        }
        try {
            Set-Mailbox -Identity $r.PrimarySmtpAddress `
                -ForwardingSmtpAddress $new `
                -DeliverToMailboxAndForward:$($r.DeliverAndStore) -ErrorAction Stop
            $log.Add([pscustomobject]@{
                Timestamp=(Get-Date).ToString('o'); Mailbox=$r.PrimarySmtpAddress
                OldForwardingSmtpAddress=$old; NewForwardingSmtpAddress=$new
                DeliverToMailboxAndForward=$r.DeliverAndStore
                Result='OK'; Error=''
            })
        } catch {
            $log.Add([pscustomobject]@{
                Timestamp=(Get-Date).ToString('o'); Mailbox=$r.PrimarySmtpAddress
                OldForwardingSmtpAddress=$old; NewForwardingSmtpAddress=$new
                DeliverToMailboxAndForward=$r.DeliverAndStore
                Result='Error'; Error=$_.Exception.Message
            })
        }
    }

    # Update cache with new forward values for OK rows
    $cache = Read-MailboxCache
    if ($cache) {
        $okRows = $log | Where-Object Result -eq 'OK'
        foreach ($okRow in $okRows) {
            foreach ($m in $cache.Mailboxes) {
                if ($m.PrimarySmtpAddress -eq $okRow.Mailbox) {
                    $m.ForwardingSmtpAddress      = $okRow.NewForwardingSmtpAddress
                    $m.DeliverToMailboxAndForward = $okRow.DeliverToMailboxAndForward
                }
            }
        }
        Save-MailboxCache -Mailboxes $cache.Mailboxes
    }

    $log | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8

    $ok   = ($log | Where-Object Result -eq 'OK').Count
    $skip = ($log | Where-Object Result -eq 'Skipped').Count
    $err  = ($log | Where-Object Result -eq 'Error').Count
    [Windows.Forms.MessageBox]::Show(
        "Applied: $ok`nSkipped: $skip`nErrors: $err`n`nLog: $logPath",
        'Apply complete')
}

#endregion

#region UI

function Show-MainForm {
    param([Parameter(Mandatory)][array]$Mailboxes)

    $form = New-Object Windows.Forms.Form -Property @{
        Text='Mailbox Forwarding Tool'; Width=1100; Height=640; StartPosition='CenterScreen'
    }

    # Filter row
    $search = New-Object Windows.Forms.TextBox -Property @{ Left=16; Top=14; Width=280 }
    $rbAll  = New-Object Windows.Forms.RadioButton -Property @{ Text='All';          Left=312; Top=16; Width=60;  Checked=$true }
    $rbHas  = New-Object Windows.Forms.RadioButton -Property @{ Text='Has forward';  Left=376; Top=16; Width=110 }
    $rbNone = New-Object Windows.Forms.RadioButton -Property @{ Text='No forward';   Left=492; Top=16; Width=100 }
    $btnRefresh  = New-Object Windows.Forms.Button -Property @{ Text='Refresh';  Left=860; Top=12; Width=80 }
    $btnSettings = New-Object Windows.Forms.Button -Property @{ Text='Settings'; Left=948; Top=12; Width=80 }
    $btnPreview  = New-Object Windows.Forms.Button -Property @{ Text='Preview →'; Left=948; Top=560; Width=140 }

    $grid = New-Object Windows.Forms.DataGridView -Property @{
        Left=16; Top=48; Width=1056; Height=500
        AutoGenerateColumns=$false; AllowUserToAddRows=$false; SelectionMode='FullRowSelect'; MultiSelect=$true
        EditMode='EditOnEnter'
    }

    [void]$grid.Columns.Add((New-Object Windows.Forms.DataGridViewTextBoxColumn -Property @{ Name='PrimarySmtpAddress'; HeaderText='Mailbox'; ReadOnly=$true; Width=240; DataPropertyName='PrimarySmtpAddress' }))
    [void]$grid.Columns.Add((New-Object Windows.Forms.DataGridViewTextBoxColumn -Property @{ Name='CurrentForwarding'; HeaderText='Current forward'; ReadOnly=$true; Width=240; DataPropertyName='CurrentForwarding' }))
    [void]$grid.Columns.Add((New-Object Windows.Forms.DataGridViewTextBoxColumn -Property @{ Name='HasOnPremForwarding'; HeaderText='On-prem?'; ReadOnly=$true; Width=70; DataPropertyName='HasOnPremForwarding' }))
    [void]$grid.Columns.Add((New-Object Windows.Forms.DataGridViewCheckBoxColumn -Property @{ Name='DeliverAndStore'; HeaderText='Deliver+Store'; Width=90; DataPropertyName='DeliverAndStore' }))
    [void]$grid.Columns.Add((New-Object Windows.Forms.DataGridViewTextBoxColumn -Property @{ Name='ForwardingPrefix'; HeaderText='Prefix'; Width=180; DataPropertyName='ForwardingPrefix' }))
    [void]$grid.Columns.Add((New-Object Windows.Forms.DataGridViewTextBoxColumn -Property @{ Name='WillForwardTo'; HeaderText='Will forward to'; ReadOnly=$true; Width=240; DataPropertyName='WillForwardTo' }))

    $form.Controls.AddRange(@($search,$rbAll,$rbHas,$rbNone,$btnRefresh,$btnSettings,$grid,$btnPreview))

    # Build row view models
    $rows = [System.ComponentModel.BindingList[object]]::new()
    foreach ($m in $Mailboxes) {
        $prefix = ($m.PrimarySmtpAddress -split '@')[0]
        $willTo = if ($prefix) { "$prefix@$($Script:Config.ForwardingDomain)" } else { '' }
        $rows.Add([pscustomobject]@{
            PrimarySmtpAddress   = $m.PrimarySmtpAddress
            CurrentForwarding    = $m.ForwardingSmtpAddress
            HasOnPremForwarding  = if ($m.HasOnPremForwardingAddress) { 'yes' } else { '' }
            DeliverAndStore      = [bool]$Script:Config.DeliverToMailboxAndForward
            ForwardingPrefix     = $prefix
            WillForwardTo        = $willTo
            Selected             = $false
        })
    }
    $grid.DataSource = $rows

    # Recompute WillForwardTo when prefix edited
    $grid.add_CellValueChanged({
        param($s,$e)
        if ($e.RowIndex -lt 0) { return }
        $row = $rows[$e.RowIndex]
        if ($grid.Columns[$e.ColumnIndex].Name -eq 'ForwardingPrefix') {
            $row.WillForwardTo = if ($row.ForwardingPrefix) { "$($row.ForwardingPrefix)@$($Script:Config.ForwardingDomain)" } else { '' }
            $grid.InvalidateRow($e.RowIndex)
        }
    })

    # Filter logic
    $applyFilter = {
        $q = $search.Text
        foreach ($r in $grid.Rows) {
            if ($r.IsNewRow) { continue }
            $item = $r.DataBoundItem
            $matchQ = -not $q -or $item.PrimarySmtpAddress -like "*$q*"
            $matchF = $true
            if ($rbHas.Checked)  { $matchF = -not [string]::IsNullOrEmpty($item.CurrentForwarding) }
            if ($rbNone.Checked) { $matchF = [string]::IsNullOrEmpty($item.CurrentForwarding) }
            $r.Visible = ($matchQ -and $matchF)
        }
    }
    $search.add_TextChanged($applyFilter)
    $rbAll.add_CheckedChanged($applyFilter)
    $rbHas.add_CheckedChanged($applyFilter)
    $rbNone.add_CheckedChanged($applyFilter)

    # Selection tracking: mark Selected on selected rows only at Preview time

    $btnSettings.add_Click({
        $new = Show-SettingsDialog -Config $Script:Config
        if ($new) {
            Save-Config $new
            $Script:Config = $new
            # Recompute WillForwardTo for all rows
            foreach ($row in $rows) {
                $row.WillForwardTo = if ($row.ForwardingPrefix) { "$($row.ForwardingPrefix)@$($Script:Config.ForwardingDomain)" } else { '' }
            }
            $grid.Refresh()
        }
    })

    $btnRefresh.add_Click({
        $form.Cursor = 'WaitCursor'
        try {
            $fresh = Get-MailboxList -Force
            # update rows in-place so edits are kept where mailbox still exists
            $byAddr = @{}
            foreach ($m in $fresh) { $byAddr[$m.PrimarySmtpAddress] = $m }
            foreach ($row in $rows) {
                if ($byAddr.ContainsKey($row.PrimarySmtpAddress)) {
                    $m = $byAddr[$row.PrimarySmtpAddress]
                    $row.CurrentForwarding   = $m.ForwardingSmtpAddress
                    $row.HasOnPremForwarding = if ($m.HasOnPremForwardingAddress) { 'yes' } else { '' }
                }
            }
            $grid.Refresh()
        } finally { $form.Cursor = 'Default' }
    })

    $btnPreview.add_Click({
        $grid.EndEdit()
        $sel = foreach ($r in $grid.SelectedRows) { $r.DataBoundItem }
        if (-not $sel) { [Windows.Forms.MessageBox]::Show('Select at least one row.'); return }
        $result = Show-PreviewDialog -Rows $sel
        if ($result) {
            Apply-Forwards -Rows $sel
            # update row view with applied values
            foreach ($row in $sel) {
                $row.CurrentForwarding = $row.WillForwardTo
            }
            $grid.Refresh()
        }
    })

    $form.Add_Shown({ $form.Activate() })
    [void]$form.ShowDialog()
    $null
}

#endregion

#region Main

function Main {
    $Script:Config = Get-Config
    if (-not $Script:Config) {
        $Script:Config = Show-SettingsDialog
        if (-not $Script:Config) { return }
        Save-Config $Script:Config
    }
    if ($SelfTest) {
        Connect-Exo
        $list = Get-MailboxList -Force
        Write-Host "Self-test OK. $($list.Count) mailboxes."
        return
    }
    try { Connect-Exo } catch {
        [Windows.Forms.MessageBox]::Show("Connect failed: $($_.Exception.Message)",'Error')
        return
    }
    $mailboxes = Get-MailboxList
    Show-MainForm -Mailboxes $mailboxes
}
Main

#endregion
