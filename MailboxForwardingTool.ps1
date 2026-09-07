# MailboxForwardingTool.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'SelfTest',
    Justification = 'Bound via $PSBoundParameters at script scope; analyzer cannot see usage inside Main when dot-sourced.')]
[CmdletBinding()]
param([switch]$SelfTest)

$Script:ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:ConfigPath = Join-Path $Script:ScriptDir 'config.json'
$Script:CachePath  = Join-Path $Script:ScriptDir 'cache.json'

# MSAL interactive auth (legacy embedded browser fallback) instantiates a COM
# ActiveX control, which requires a single-threaded apartment (STA). Apartment
# state is fixed once per thread, so an MTA host can never be fixed in-place:
# relaunch the script in an explicit STA PowerShell process. This covers being
# started from hosts that default to MTA (e.g. some ISE-like or -Mta launches).
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $argList = @('-Sta','-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
    if ($SelfTest) { $argList += '-SelfTest' }
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Wait -PassThru
    exit $p.ExitCode
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

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
    Import-Module -Name ExchangeOnlineManagement -RequiredVersion $newest.Version -ErrorAction Stop
}

Install-ExoModule

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
        Text='Initial setup'; Width=640; Height=420; StartPosition='CenterScreen'; FormBorderStyle='FixedDialog'
        MaximizeBox=$false; MinimizeBox=$false
    }
    $font = New-Object Drawing.Font('Segoe UI', 9)
    $hintFont = New-Object Drawing.Font('Segoe UI', 8)
    $hintColor = [Drawing.Color]::FromArgb(90, 90, 90)
    $form.Font = $font

    $intro = New-Object Windows.Forms.Label -Property @{
        Left=16; Top=14; Width=592; Height=36
        Text='One-time setup. Values are saved to config.json next to the script and can be changed later by deleting that file.'
    }
    $form.Controls.Add($intro)

    $fields = @(
        @{ Key='ForwardingDomain'; Label='Forwarding domain';
           Hint='Target domain all selected mailboxes will forward to, e.g. archive.contoso.com. The tool proposes user@domain per row; you can edit individual rows before applying.' },
        @{ Key='ServiceAccountUPN'; Label='Service account UPN';
           Hint='Sign-in used for Exchange Online, e.g. svc-exo@contoso.com. Needs Exchange Administrator (or equivalent) rights. MFA is handled by the sign-in prompt on first connect.' },
        @{ Key='CacheTtlHours'; Label='Cache TTL (hours)';
           Hint='How long the mailbox list is reused before re-querying Exchange Online. 24 = refresh once a day. Use the Refresh button in the main window to bypass the cache at any time.' }
    )
    $boxes = @{}
    $y = 58
    foreach ($f in $fields) {
        $l = New-Object Windows.Forms.Label -Property @{ Text=$f.Label; Left=16; Top=$y+4; Width=170 }
        $t = New-Object Windows.Forms.TextBox -Property @{ Left=194; Top=$y; Width=414 }
        $h = New-Object Windows.Forms.Label -Property @{
            Text=$f.Hint; Left=194; Top=$y+26; Width=414; Height=42
            Font=$hintFont; ForeColor=$hintColor
        }
        $form.Controls.AddRange(@($l,$t,$h))
        $boxes[$f.Key] = $t
        $y += 74
    }
    $cb = New-Object Windows.Forms.CheckBox -Property @{
        Text='Deliver to mailbox AND forward'; Left=194; Top=$y; Width=220
    }
    $cbHint = New-Object Windows.Forms.Label -Property @{
        Left=194; Top=$y+24; Width=414; Height=42; Font=$hintFont; ForeColor=$hintColor
        Text='Checked: incoming mail is kept in the mailbox and also forwarded. Unchecked: mail is only forwarded, nothing is stored locally.'
    }
    $form.Controls.AddRange(@($cb,$cbHint))

    if ($Config) {
        $boxes['ForwardingDomain'].Text  = $Config.ForwardingDomain
        $boxes['ServiceAccountUPN'].Text = $Config.ServiceAccountUPN
        $boxes['CacheTtlHours'].Text     = "$($Config.CacheTtlHours)"
        $cb.Checked = $Config.DeliverToMailboxAndForward
    } else {
        $boxes['CacheTtlHours'].Text = '24'
    }

    $ok = New-Object Windows.Forms.Button -Property @{
        Text='Save'; Left=448; Top=$y+72; Width=80; DialogResult='OK'
    }
    $cancel = New-Object Windows.Forms.Button -Property @{
        Text='Cancel'; Left=536; Top=$y+72; Width=80; DialogResult='Cancel'
    }
    $form.AcceptButton = $ok; $form.CancelButton = $cancel
    $form.Controls.AddRange(@($ok,$cancel))

    if ($form.ShowDialog() -ne 'OK') { return $null }
    $ttl = 24
    [void][int]::TryParse($boxes['CacheTtlHours'].Text, [ref]$ttl)
    [pscustomobject]@{
        ForwardingDomain           = $boxes['ForwardingDomain'].Text.Trim()
        DeliverToMailboxAndForward = $cb.Checked
        ServiceAccountUPN          = $boxes['ServiceAccountUPN'].Text.Trim()
        CacheTtlHours              = $ttl
    }
}

#endregion

#region Exchange

function Connect-Exo {
    if (Get-ConnectionInformation -ErrorAction SilentlyContinue) { return }
    $connectArgs = @{
        UserPrincipalName = $Script:Config.ServiceAccountUPN
        ShowBanner        = $false
        ErrorAction       = 'Stop'
    }
    try {
        # Module >= 3.7.0: WAM broker auth (default). No embedded browser, no
        # ActiveX control, works on any apartment state.
        Connect-ExchangeOnline @connectArgs
    } catch {
        $wamFailed = $_.Exception.Message -match 'WAM|Web Account Manager|broker'
        if (-not $wamFailed) { throw }
        # -DisableWAM (module >= 3.7.2) falls back to the MSAL interactive
        # browser flow. On STA (guaranteed by the relaunch guard above) the
        # legacy path works; WAM problems are usually machine-specific.
        Write-Warning "WAM sign-in failed ($($_.Exception.Message)); retrying with -DisableWAM."
        Connect-ExchangeOnline @connectArgs -DisableWAM
    }
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
            $item.SubItems[2].Text = '(skip - on-prem forward set)'
        }
        [void]$lv.Items.Add($item)
    }

    $btnApply  = New-Object Windows.Forms.Button -Property @{ Text='Apply';  Left=600; Top=452; Width=90; DialogResult='OK' }
    $btnCancel = New-Object Windows.Forms.Button -Property @{ Text='Cancel'; Left=702; Top=452; Width=90; DialogResult='Cancel' }
    $f.AcceptButton=$btnApply; $f.CancelButton=$btnCancel
    $f.Controls.AddRange(@($lv,$btnApply,$btnCancel))
    ($f.ShowDialog() -eq 'OK')
}

function Set-MailboxForwards {
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
    $btnPreview  = New-Object Windows.Forms.Button -Property @{ Text='Preview >'; Left=948; Top=560; Width=140 }

    $grid = New-Object Windows.Forms.DataGridView -Property @{
        Left=16; Top=48; Width=1056; Height=500
        AutoGenerateColumns=$false; AllowUserToAddRows=$false; SelectionMode='FullRowSelect'; MultiSelect=$true
        EditMode='EditOnEnter'
    }

    [void]$grid.Columns.Add((New-Object Windows.Forms.DataGridViewTextBoxColumn -Property @{ Name='PrimarySmtpAddress'; HeaderText='Mailbox'; ReadOnly=$true; Width=240; DataPropertyName='PrimarySmtpAddress'; SortMode='NotSortable' }))
    [void]$grid.Columns.Add((New-Object Windows.Forms.DataGridViewTextBoxColumn -Property @{ Name='CurrentForwarding'; HeaderText='Current forward'; ReadOnly=$true; Width=240; DataPropertyName='CurrentForwarding'; SortMode='NotSortable' }))
    [void]$grid.Columns.Add((New-Object Windows.Forms.DataGridViewTextBoxColumn -Property @{ Name='HasOnPremForwarding'; HeaderText='On-prem?'; ReadOnly=$true; Width=70; DataPropertyName='HasOnPremForwarding'; SortMode='NotSortable' }))
    [void]$grid.Columns.Add((New-Object Windows.Forms.DataGridViewCheckBoxColumn -Property @{ Name='DeliverAndStore'; HeaderText='Deliver+Store'; Width=90; DataPropertyName='DeliverAndStore'; SortMode='NotSortable' }))
    [void]$grid.Columns.Add((New-Object Windows.Forms.DataGridViewTextBoxColumn -Property @{ Name='ForwardingPrefix'; HeaderText='Prefix'; Width=180; DataPropertyName='ForwardingPrefix'; SortMode='NotSortable' }))
    [void]$grid.Columns.Add((New-Object Windows.Forms.DataGridViewTextBoxColumn -Property @{ Name='WillForwardTo'; HeaderText='Will forward to'; ReadOnly=$true; Width=240; DataPropertyName='WillForwardTo'; SortMode='NotSortable' }))

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
        })
    }
    $grid.DataSource = $rows

    # Recompute WillForwardTo when prefix edited
    $grid.add_CellValueChanged({
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 's',
            Justification = 'Event sender parameter required by .NET event signature.')]
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
            Set-MailboxForwards -Rows $sel
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
