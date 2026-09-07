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

$rows = [System.ComponentModel.BindingList[object]]::new()
foreach ($entry in @(@('alice', ''), @('bob', 'archive@example.net'), @('carol', ''))) {
    $rows.Add([pscustomobject]@{
        PrimarySmtpAddress = "$($entry[0])@example.com"; CurrentForwarding = $entry[1]
        ForwardingPrefix = $entry[0]; WillForwardTo = "$($entry[0])@example.net"
        DeliverAndStore = $false; HasOnPremForwarding = ''
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
    $rows.Clear()
    & $applyFilter
    Assert ($grid.DataSource.Count -eq 0) 'Empty mailbox list must be supported.'
} finally { if ($form) { $form.Dispose() } }
Write-Host "Grid filtering checks passed (real WinForms: $windows)."
