# Exercise production summary expressions, including the Windows PowerShell 5.1 singleton shape.
$ErrorActionPreference = 'Stop'
$path = Join-Path (Split-Path $PSScriptRoot -Parent) 'MailboxForwardingTool.ps1'
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw "Parse errors: $parseErrors" }
$action = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-MailboxForwards'
}, $true)
$counts = $action.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -in '$ok', '$skip', '$err'
}, $true)
if ($counts.Count -ne 3) { throw 'Apply summary assignments missing.' }
$summary = [scriptblock]::Create(($counts.Extent.Text -join "`n") + "`n" + '$ok, $skip, $err')
foreach ($case in @(
    @{ Results = @(); Expected = '0,0,0' },
    @{ Results = @('OK'); Expected = '1,0,0' },
    @{ Results = @('Skipped'); Expected = '0,1,0' },
    @{ Results = @('Error'); Expected = '0,0,1' },
    @{ Results = @('OK', 'OK', 'Skipped', 'Error'); Expected = '2,1,1' }
)) {
    foreach ($legacyShape in @($false, $true)) {
        $log = [System.Collections.Generic.List[object]]::new()
        foreach ($result in $case.Results) {
            $entry = [pscustomobject]@{ Result = $result }
            # PS7 adds a synthetic Count; model PS5.1's absent singleton Count offline.
            if ($legacyShape) { $entry | Add-Member NoteProperty Count $null }
            $log.Add($entry)
        }
        $actual = (& $summary) -join ','
        if ($actual -ne $case.Expected) { throw "Expected $($case.Expected), got '$actual' (PS5.1 shape: $legacyShape)." }
    }
}
Write-Host 'Apply count checks passed (zero, single success/skip/error, mixed results).'
