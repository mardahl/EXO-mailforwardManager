# Offline filter regression checks. Windows also exercises real WinForms binding.
$ErrorActionPreference = 'Stop'
$path = Join-Path (Split-Path $PSScriptRoot -Parent) 'MailboxForwardingTool.ps1'
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw "Parse errors: $parseErrors" }
$filter = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$applyFilter'
}, $true)
$applyFilter = [scriptblock]::Create($filter.Right.Expression.ScriptBlock.Extent.Text.TrimStart('{').TrimEnd('}'))
$edit = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -eq 'add_CellValueChanged'
}, $true)
$onEdit = [scriptblock]::Create($edit.Arguments[0].ScriptBlock.Extent.Text.TrimStart('{').TrimEnd('}'))
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }

function Get-Handler($Control, $EventName) {
    $node = $ast.Find({ param($n)
        $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        $n.Expression.Extent.Text -eq $Control -and $n.Member.Value -eq $EventName
    }, $true)
    Assert ($null -ne $node) "Missing handler: $Control.$EventName"
    [scriptblock]::Create($node.Arguments[0].ScriptBlock.Extent.Text.TrimStart('{').TrimEnd('}'))
}
$selectAll = Get-Handler '$btnSelectAll' 'add_Click'
$clearSelection = Get-Handler '$btnClearSelection' 'add_Click'
$preview = Get-Handler '$btnPreview' 'add_Click'
$update = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$updateSelection'
}, $true)
Assert ($null -ne $update) 'Selection count updater missing.'
$updateSelection = [scriptblock]::Create($update.Right.Expression.ScriptBlock.Extent.Text.TrimStart('{').TrimEnd('}'))
$selectionLabel = [pscustomobject]@{ Text = '' }
$btnPreview = [pscustomobject]@{ Enabled = $false }
function Show-PreviewDialog {
    param([array]$Rows)
    $script:Previewed = $Rows
    $false
}

$rows = [System.ComponentModel.BindingList[object]]::new()
foreach ($entry in @(@('alice', ''), @('bob', 'archive@example.net'), @('carol', ''))) {
    $rows.Add([pscustomobject]@{
        PrimarySmtpAddress = "$($entry[0])@example.com"; CurrentForwarding = $entry[1]
        ForwardingPrefix = $entry[0]; WillForwardTo = "$($entry[0])@example.net"
        DeliverAndStore = $false; HasOnPremForwarding = ''; Selected = $false
    })
}
$search = [pscustomobject]@{ Text = '' }
$rbHas = [pscustomobject]@{ Checked = $false }
$rbNone = [pscustomobject]@{ Checked = $false }
$script:Config = [pscustomobject]@{ ForwardingDomain = 'example.net' }
$windows = $env:OS -eq 'Windows_NT'
$form = $null
if ($windows) {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $form = New-Object Windows.Forms.Form
    $grid = New-Object Windows.Forms.DataGridView -Property @{ AutoGenerateColumns = $false; AllowUserToAddRows = $false }
    foreach ($name in @('PrimarySmtpAddress', 'ForwardingPrefix', 'WillForwardTo')) {
        [void]$grid.Columns.Add((New-Object Windows.Forms.DataGridViewTextBoxColumn -Property @{ Name = $name; DataPropertyName = $name }))
    }
    [void]$grid.Columns.Add((New-Object Windows.Forms.DataGridViewCheckBoxColumn -Property @{ Name = 'Selected'; DataPropertyName = 'Selected' }))
    $form.Controls.Add($grid)
    $grid.DataSource = $rows
    $form.Show()
    $grid.CurrentCell = $grid.Rows[0].Cells[0]
} else {
    # WinForms is Windows-only; model its current-row visibility restriction offline.
    $current = [pscustomobject]@{ DataBoundItem = $rows[0]; IsNewRow = $false }
    $current | Add-Member ScriptProperty Visible { $true } {
        if (-not $args[0]) { throw "Row associated with the currency manager's position cannot be made invisible." }
    }
    $grid = [pscustomobject]@{ DataSource = $rows; Rows = @($current); SelectedRows = @(); Columns = @() }
    $grid | Add-Member ScriptMethod EndEdit { $true }
    $grid | Add-Member ScriptMethod ClearSelection { }
    $grid | Add-Member ScriptMethod InvalidateRow { }
    $grid | Add-Member ScriptMethod Refresh { }
}
try {
    # Excluding the current row must not set its Visible property.
    $search.Text = 'BOB'
    & $applyFilter
    Assert ($grid.DataSource.Count -eq 1 -and $grid.DataSource[0].PrimarySmtpAddress -eq 'bob@example.com') 'Search must display only Bob.'
    Assert ([object]::ReferenceEquals($grid.DataSource[0], $rows[1])) 'Filtering must retain original edit objects.'

    # Display index zero is now Bob, not the first mailbox in the master list.
    if (-not $windows) {
        $grid.Rows = @([pscustomobject]@{ DataBoundItem = $grid.DataSource[0] })
        $grid.Columns = @([pscustomobject]@{ Name = 'PrimarySmtpAddress' }, [pscustomobject]@{ Name = 'ForwardingPrefix' })
    }
    $grid.DataSource[0].ForwardingPrefix = 'edited'
    $grid.DataSource[0].DeliverAndStore = $true
    & $onEdit $grid ([pscustomobject]@{ RowIndex = 0; ColumnIndex = 1 })
    Assert ($rows[1].WillForwardTo -eq 'edited@example.net' -and $rows[0].WillForwardTo -eq 'alice@example.net') 'Filtered edit must update Bob only.'

    foreach ($case in @(
        @{ Query = ''; Has = $true; None = $false; Expected = 'bob@example.com' },
        @{ Query = ''; Has = $false; None = $true; Expected = 'alice@example.com,carol@example.com' },
        @{ Query = 'bob'; Has = $false; None = $true; Expected = '' },
        @{ Query = 'missing'; Has = $false; None = $false; Expected = '' },
        @{ Query = ''; Has = $false; None = $false; Expected = 'alice@example.com,bob@example.com,carol@example.com' }
    )) {
        $search.Text = $case.Query; $rbHas.Checked = $case.Has; $rbNone.Checked = $case.None
        & $applyFilter
        Assert (($grid.DataSource.PrimarySmtpAddress -join ',') -eq $case.Expected) "Incorrect results for filter: $($case | Out-String)"
        if ($windows) {
            Assert ($grid.Rows.Count -eq $grid.DataSource.Count) 'Bound grid did not update.'
            Assert ($grid.SelectedRows.Count -eq 0) 'Filtering must not implicitly select mailboxes for Preview.'
        }
    }
    Assert ($rows[1].ForwardingPrefix -eq 'edited' -and $rows[1].DeliverAndStore) 'Edits lost after hiding and restoring a row.'

    & $updateSelection
    Assert ($selectionLabel.Text -eq 'Selected: 0 (0 hidden)' -and -not $btnPreview.Enabled) 'Empty selection must disable Preview.'
    $search.Text = 'bob'
    & $applyFilter
    if ($windows) {
        $grid.add_CellValueChanged($onEdit)
        $grid.add_CurrentCellDirtyStateChanged((Get-Handler '$grid' 'add_CurrentCellDirtyStateChanged'))
        $grid.Rows[0].Cells['Selected'].Value = $true
        [void]$grid.EndEdit()
    } else {
        $grid.Rows = @([pscustomobject]@{ DataBoundItem = $rows[1] })
        $grid.Columns = @([pscustomobject]@{ Name = 'Selected' })
        $rows[1].Selected = $true
        & $onEdit $grid ([pscustomobject]@{ RowIndex = 0; ColumnIndex = 0 })
    }
    Assert ($rows[1].Selected -and $selectionLabel.Text -eq 'Selected: 1 (0 hidden)') 'Checking one mailbox must update the counter.'
    if ($windows) {
        $grid.Rows[0].Cells['Selected'].Value = $false
        [void]$grid.EndEdit()
    } else {
        $rows[1].Selected = $false
        & $onEdit $grid ([pscustomobject]@{ RowIndex = 0; ColumnIndex = 0 })
    }
    Assert (-not $rows[1].Selected -and -not $btnPreview.Enabled) 'Unchecking the last mailbox must disable Preview.'
    & $selectAll
    Assert ($rows[1].Selected -and -not $rows[0].Selected -and -not $rows[2].Selected) 'Select all shown must not select hidden mailboxes.'
    Assert ($selectionLabel.Text -eq 'Selected: 1 (0 hidden)' -and $btnPreview.Enabled) 'Single checked row must show count 1.'
    $search.Text = 'alice'
    & $applyFilter
    Assert ($rows[1].Selected -and $selectionLabel.Text -eq 'Selected: 1 (1 hidden)') 'Filtering must retain and report hidden selections.'
    & $selectAll
    Assert ($selectionLabel.Text -eq 'Selected: 2 (1 hidden)') 'Selection must accumulate across searches.'
    & $preview
    Assert (($script:Previewed.PrimarySmtpAddress -join ',') -eq 'alice@example.com,bob@example.com') 'Preview must use all checked mailboxes, not highlighted rows.'
    & $clearSelection
    Assert (@($rows | Where-Object Selected).Count -eq 0 -and -not $btnPreview.Enabled) 'Clear selection must also clear hidden checkboxes.'
    & $selectAll
    & $preview
    Assert ($script:Previewed.Count -eq 1 -and $script:Previewed[0].PrimarySmtpAddress -eq 'alice@example.com') 'Preview must support one checked mailbox.'
    $search.Text = 'missing'
    & $applyFilter
    & $selectAll
    Assert ($selectionLabel.Text -eq 'Selected: 1 (1 hidden)') 'Select all shown on empty results must leave hidden selections unchanged.'
    & $clearSelection
    $rows.Clear()
    & $applyFilter
    Assert ($grid.DataSource.Count -eq 0) 'Empty mailbox list must be supported.'
} finally { if ($form) { $form.Dispose() } }
Write-Host "Grid filtering checks passed (real WinForms: $windows)."
