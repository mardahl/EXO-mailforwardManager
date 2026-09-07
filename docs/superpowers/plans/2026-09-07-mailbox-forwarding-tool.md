# Mailbox Forwarding Tool — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Single-file PowerShell + WinForms tool for bulk-setting mailbox forwarding in Exchange Online during tenant migrations.

**Architecture:** One `.ps1` script divided into regions: Config, EXO session, Cache, UI, Actions. WinForms UI built in code. ExchangeOnlineManagement module does all Exchange work. JSON for config + cache, CSV for change log.

**Tech Stack:** Windows PowerShell 5.1, WinForms (System.Windows.Forms), ExchangeOnlineManagement ≥ 3.0.

## Global Constraints

- Single file `MailboxForwardingTool.ps1` at repo root. No modules, no build step.
- Windows PowerShell 5.1 compatible (not just pwsh 7). Test with `powershell.exe`, not only `pwsh`.
- No external dependencies beyond ExchangeOnlineManagement module.
- All Exchange calls must use REST-based cmdlets (`Get-EXOMailbox`, `Set-Mailbox` is fine; avoid legacy `Get-Mailbox` for enumeration).
- Forwarding must use `ForwardingSmtpAddress` (string), not `ForwardingAddress` (recipient object). If mailbox has `ForwardingAddress` set, skip + flag.
- Never clear an existing forward implicitly — every overwrite goes through Preview.
- Apply writes one CSV per run: `changelog-yyyyMMdd-HHmmss.csv` in script dir.

---

### Task 1: Project skeleton + config load/save + Settings dialog

**Files:**
- Create: `MailboxForwardingTool.ps1`
- Create: `config.example.json`

**Interfaces:**
- Produces:
  - `Get-Config` → returns hashtable `{ ForwardingDomain, DeliverToMailboxAndForward, ServiceAccountUPN, CacheTtlHours }` or `$null` if missing/invalid
  - `Save-Config -Config <hashtable>` → writes `config.json`
  - `Show-SettingsDialog -Config <hashtable>` → returns updated hashtable or `$null` if cancelled
  - `$Script:ConfigPath`, `$Script:CachePath`, `$Script:ScriptDir` — paths

- [ ] **Step 1: Write skeleton with regions + config IO**

```powershell
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
    } catch { return $null }
    if (-not $raw.ForwardingDomain -or -not $raw.ServiceAccountUPN) { return $null }
    [pscustomobject]@{
        ForwardingDomain           = [string]$raw.ForwardingDomain
        DeliverToMailboxAndForward = [bool]$raw.DeliverToMailboxAndForward
        ServiceAccountUPN          = [string]$raw.ServiceAccountUPN
        CacheTtlHours              = if ($raw.PSObject.Properties.Name -contains 'CacheTtlHours') { [int]$raw.CacheTtlHours } else { 24 }
    }
}

function Save-Config {
    param([Parameter(Mandatory)]$Config)
    $Config | ConvertTo-Json | Set-Content -Path $Script:ConfigPath -Encoding UTF8
}

#endregion
```

- [ ] **Step 2: Verify config roundtrip**

Run: `powershell.exe -NoProfile -Command ". .\MailboxForwardingTool.ps1; Save-Config -Config @{ForwardingDomain='t.com';DeliverToMailboxAndForward=$true;ServiceAccountUPN='u@t.com';CacheTtlHours=24}; Get-Config | ConvertTo-Json"`
Expected: JSON with the four fields.

- [ ] **Step 3: Add WinForms Settings dialog**

Add at top of script: `Add-Type -AssemblyName System.Windows.Forms, System.Drawing`.

In `#region Config` append:

```powershell
function Show-SettingsDialog {
    param($Config)
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
```

- [ ] **Step 4: Verify Settings dialog roundtrip**

Run: `powershell.exe -NoProfile -Command ". .\MailboxForwardingTool.ps1; `$c = Show-SettingsDialog; `$c | ConvertTo-Json; if (`$c) { Save-Config `$c; Get-Config | ConvertTo-Json }"`
Expected: Dialog appears, values entered, JSON echoed, `config.json` written.

- [ ] **Step 5: Commit**

```bash
git add MailboxForwardingTool.ps1 config.example.json
git commit -m "feat: script skeleton, config IO, Settings dialog"
```

---

### Task 2: EXO connection + mailbox cache

**Files:**
- Modify: `MailboxForwardingTool.ps1`

**Interfaces:**
- Consumes: `$Script:Config` (from Task 1)
- Produces:
  - `Connect-Exo` → throws on failure
  - `Get-MailboxList -Force` → array of PSCustomObjects with `PrimarySmtpAddress`, `ForwardingSmtpAddress`, `DeliverToMailboxAndForward`, `HasOnPremForwardingAddress`
  - `Save-MailboxCache -Mailboxes <array>`
  - `Read-MailboxCache` → cache object or `$null`
  - `Test-CacheFresh -Cache <obj>` → bool

- [ ] **Step 1: Add EXO connection**

In new `#region Exchange`:

```powershell
function Connect-Exo {
    if (Get-ConnectionInformation -ErrorAction SilentlyContinue) { return }
    Connect-ExchangeOnline -UserPrincipalName $Script:Config.ServiceAccountUPN -ShowBanner:$false
}
```

- [ ] **Step 2: Add cache IO**

```powershell
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
```

- [ ] **Step 3: Add mailbox enumeration**

```powershell
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
```

- [ ] **Step 4: Verify against tenant (manual)**

Run `powershell.exe -NoProfile -File .\MailboxForwardingTool.ps1 -SelfTest` (stub `-SelfTest` for now: load config, `Connect-Exo`, call `Get-MailboxList -Force`, print count).
Expected: prints mailbox count, `cache.json` written.

- [ ] **Step 5: Commit**

```bash
git add MailboxForwardingTool.ps1
git commit -m "feat: EXO connection and mailbox cache"
```

---

### Task 3: Main grid UI with filter

**Files:**
- Modify: `MailboxForwardingTool.ps1`

**Interfaces:**
- Consumes: `Get-MailboxList`, `$Script:Config`
- Produces:
  - `Show-MainForm -Mailboxes <array>` → blocks; returns array of row-view objects (including edited `ForwardingPrefix` and `Selected` flag) or `$null` if cancelled
  - Row view object shape: `{ PrimarySmtpAddress, CurrentForwarding, HasOnPremForwarding, DeliverAndStore, ForwardingPrefix, WillForwardTo, Selected }`

- [ ] **Step 1: Build main form skeleton**

In new `#region UI`:

```powershell
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
```

- [ ] **Step 2: Build row-view model + binding**

Continue in `Show-MainForm`, after grid setup:

```powershell
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
```

- [ ] **Step 3: Preview / Settings / Refresh handlers**

Continue in `Show-MainForm`:

```powershell
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
```

- [ ] **Step 4: Wire main()**

In new `#region Main` at end:

```powershell
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
```

- [ ] **Step 5: Manual smoke — form renders, filter works**

Run: `powershell.exe -NoProfile -File .\MailboxForwardingTool.ps1`
Expected: form opens, grid shows mailboxes from cache (or fetches), search filters, radios filter, prefix edit updates `Will forward to`.

- [ ] **Step 6: Commit**

```bash
git add MailboxForwardingTool.ps1
git commit -m "feat: main grid UI with filter"
```

---

### Task 4: Preview + Apply + change log

**Files:**
- Modify: `MailboxForwardingTool.ps1`

**Interfaces:**
- Consumes: `Show-MainForm` row objects
- Produces:
  - `Show-PreviewDialog -Rows <array>` → bool (`$true` = Apply clicked)
  - `Apply-Forwards -Rows <array>` → writes changelog CSV, shows result dialog

- [ ] **Step 1: Preview dialog**

In `#region UI`:

```powershell
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
```

- [ ] **Step 2: Apply**

In new `#region Actions`:

```powershell
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
    $log | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8

    $ok   = ($log | Where-Object Result -eq 'OK').Count
    $skip = ($log | Where-Object Result -eq 'Skipped').Count
    $err  = ($log | Where-Object Result -eq 'Error').Count
    [Windows.Forms.MessageBox]::Show(
        "Applied: $ok`nSkipped: $skip`nErrors: $err`n`nLog: $logPath",
        'Apply complete')
}
```

- [ ] **Step 3: Update cache after apply**

In `Apply-Forwards`, before `Export-Csv`, add cache update:

```powershell
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
```

- [ ] **Step 4: Manual test on test tenant**

- Select 2-3 mailboxes, click Preview, confirm overwrite highlighted red, click Apply.
- Verify `changelog-*.csv` written with old + new values.
- Verify cache.json reflects new forwards.
- Re-run tool → grid shows new forwards under "Current forward".

- [ ] **Step 5: Commit**

```bash
git add MailboxForwardingTool.ps1
git commit -m "feat: preview dialog, apply, changelog CSV"
```

---

### Task 5: README + config.example.json polish

**Files:**
- Create: `README.md`
- Modify: `config.example.json`

**Interfaces:**
- Consumes: everything above
- Produces: operator docs

- [ ] **Step 1: Write config.example.json**

```json
{
  "ForwardingDomain": "target.example.com",
  "DeliverToMailboxAndForward": true,
  "ServiceAccountUPN": "svc-migration@source.example.com",
  "CacheTtlHours": 24
}
```

- [ ] **Step 2: Write README.md**

```markdown
# Mailbox Forwarding Tool

Bulk-set mailbox forwarding in Exchange Online during tenant migrations.

## Prereqs
- Windows PowerShell 5.1
- `Install-Module ExchangeOnlineManagement -Scope CurrentUser`
- Service account with Exchange Admin (or Global Admin) role

## Setup
1. Copy `config.example.json` → `config.json` and edit, or run the tool and use the Settings dialog.
2. Run `.\MailboxForwardingTool.ps1`.

## Use
- Grid lists all user mailboxes (cached; Refresh button re-fetches).
- Search box + Has forward / No forward filters narrow the list.
- Prefix column defaults to mailbox local part; edit for exceptions.
- Select rows → Preview → Apply. Changelog CSV written per run.

## Self-test
`.\MailboxForwardingTool.ps1 -SelfTest` — validates config + EXO connectivity, touches no mailboxes.

## Notes
- Mailboxes with on-prem `ForwardingAddress` set are skipped and flagged.
- Existing forwards are overwritten only after Preview confirmation.
```

- [ ] **Step 3: Commit**

```bash
git add README.md config.example.json
git commit -m "docs: README and example config"
```

---

## Self-review

- Spec coverage: config (T1), cache + EXO (T2), grid + filter + editable prefix (T3), preview + apply + changelog + on-prem skip (T4), docs (T5). All spec sections covered.
- No placeholders.
- Type consistency: `Show-PreviewDialog -Rows`, `Apply-Forwards -Rows`, `Get-MailboxList` shape (`PrimarySmtpAddress`, `ForwardingSmtpAddress`, `DeliverToMailboxAndForward`, `HasOnPremForwardingAddress`) consistent across tasks. Row view adds `ForwardingPrefix`, `WillForwardTo`, `DeliverAndStore`, `CurrentForwarding`, `HasOnPremForwarding`, `Selected` — used consistently.
