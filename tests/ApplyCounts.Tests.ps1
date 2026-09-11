# Exercise the real Set-MailboxForwards summary counts (zero/single OK/skip/error/mixed).
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

function NewRow([string]$Tag, [bool]$OnPrem = $false) {
    [pscustomobject]@{
        Selected = $true; PrimarySmtpAddress = "$Tag@example.com"
        CurrentForwarding = 'old@example.net'; HasOnPremForwarding = $OnPrem
        DeliverAndStore = $true; ForwardingPrefix = $Tag; WillForwardTo = "$Tag@archive.example.com"
    }
}

$failures = New-Object 'System.Collections.Generic.List[string]'

foreach ($case in @(
    @{ Name = 'zero'; Rows = @(); Expected = @{ Applied = 0; Skipped = 0; Errors = 0 } },
    @{ Name = 'single OK'; Rows = @((NewRow 'a')); Expected = @{ Applied = 1; Skipped = 0; Errors = 0 } },
    @{ Name = 'single skip'; Rows = @((NewRow 'skip' $true)); Expected = @{ Applied = 0; Skipped = 1; Errors = 0 } },
    @{ Name = 'single error'; Rows = @((NewRow 'bad')); Expected = @{ Applied = 0; Skipped = 0; Errors = 1 } },
    @{ Name = 'mixed'; Rows = @((NewRow 'a'), (NewRow 'skip' $true), (NewRow 'bad')); Expected = @{ Applied = 1; Skipped = 1; Errors = 1 } }
)) {
    try {
        function Set-Mailbox {
            [CmdletBinding()]
            param($Identity, $ForwardingSmtpAddress, [bool]$DeliverToMailboxAndForward)
            if ($Identity -eq 'bad@example.com') { throw 'Denied' }
        }
        $originalDir = $script:ScriptDir
        $originalCache = $script:CachePath
        $temporary = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
        [void][IO.Directory]::CreateDirectory($temporary)
        try {
            $script:ScriptDir = $temporary
            $script:CachePath = Join-Path $temporary 'cache.json'
            $result = Set-MailboxForwards -Rows $case.Rows
            Assert ($result.Applied -eq $case.Expected.Applied) "$($case.Name): Applied mismatch (got $($result.Applied))."
            Assert ($result.Skipped -eq $case.Expected.Skipped) "$($case.Name): Skipped mismatch (got $($result.Skipped))."
            Assert ($result.Errors -eq $case.Expected.Errors) "$($case.Name): Errors mismatch (got $($result.Errors))."
        } finally {
            $script:ScriptDir = $originalDir
            $script:CachePath = $originalCache
            Remove-Item $temporary -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch { $failures.Add($_.ToString()) }
}

if ($failures.Count) { throw ($failures -join "`n") }
Write-Host 'Apply count checks passed (zero, single success/skip/error, mixed results).'
