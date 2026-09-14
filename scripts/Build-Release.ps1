<#
.SYNOPSIS
    Stages the four-file release bundle: the launcher .bat, a standalone
    MailboxForwardingTool.ps1 (src/*.ps1 inlined in place of the root
    script's dot-source loader), QUICKSTART.txt, and LICENSE.

.DESCRIPTION
    The segmented src/ layout stays the source of truth for development;
    this script only produces the release artifact. It locates the
    '# === SRC-LOADER-START ===' / '# === SRC-LOADER-END ===' marker pair in
    the root script (each must appear exactly once) and replaces the block
    between them with the sorted contents of src/*.ps1, in the same order
    the root script's loader used to dot-source them.

.PARAMETER OutputDirectory
    Directory to stage the four release files into. Created if missing;
    an existing directory must be empty, and an existing file at this path
    is rejected - nothing here is ever overwritten with a stale/partial
    build.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent

# Guard the destination before anything is read or written: a pre-existing
# file, or a non-empty directory (which could hold a stale/unrelated build
# or arbitrary caller data), must never be silently overwritten.
if (Test-Path -LiteralPath $OutputDirectory) {
    $item = Get-Item -LiteralPath $OutputDirectory
    if (-not $item.PSIsContainer) {
        throw "-OutputDirectory '$OutputDirectory' is an existing file, not a directory."
    }
    if (@(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count -gt 0) {
        throw "-OutputDirectory '$OutputDirectory' already exists and is not empty."
    }
} else {
    New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
}

$rootScriptPath = Join-Path $repoRoot 'MailboxForwardingTool.ps1'
$startMarker = '# === SRC-LOADER-START ==='
$endMarker = '# === SRC-LOADER-END ==='
# Explicit -Encoding UTF8 on every read: Windows PowerShell 5.1's Get-Content
# defaults to the system ANSI code page, not UTF-8, and would corrupt any
# non-ASCII character (e.g. in a comment or string) on read.
$lines = @(Get-Content -LiteralPath $rootScriptPath -Encoding UTF8)

$startMatches = @($lines | Select-String -SimpleMatch $startMarker)
$endMatches = @($lines | Select-String -SimpleMatch $endMarker)
if ($startMatches.Count -ne 1) { throw "Expected exactly one '$startMarker' line in MailboxForwardingTool.ps1, found $($startMatches.Count)." }
if ($endMatches.Count -ne 1) { throw "Expected exactly one '$endMarker' line in MailboxForwardingTool.ps1, found $($endMatches.Count)." }
$startIndex = $startMatches[0].LineNumber - 1
$endIndex = $endMatches[0].LineNumber - 1
if ($endIndex -le $startIndex) { throw 'SRC-LOADER-END must come after SRC-LOADER-START.' }

$srcFiles = @(Get-ChildItem (Join-Path $repoRoot 'src') -Filter '*.ps1' | Sort-Object Name)
if ($srcFiles.Count -eq 0) { throw 'No src/*.ps1 files found to inline.' }

$inlined = New-Object 'System.Collections.Generic.List[string]'
foreach ($file in $srcFiles) {
    $inlined.Add("# --- inlined from src/$($file.Name) ---")
    $inlined.AddRange([string[]](Get-Content -LiteralPath $file.FullName -Encoding UTF8))
}

$bundleLines = @($lines[0..($startIndex - 1)]) + @($inlined) + @($lines[($endIndex + 1)..($lines.Count - 1)])
$bundleText = ($bundleLines -join "`r`n") + "`r`n"

# Validate the generated text parses *before* anything is written to disk -
# a broken bundle must never reach the package.
$parseTokens = $null; $parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($bundleText, [ref]$parseTokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw "Generated MailboxForwardingTool.ps1 has parse errors: $($parseErrors -join '; ')" }

$bundlePath = Join-Path $OutputDirectory 'MailboxForwardingTool.ps1'
# Set-Content -Encoding UTF8 does NOT emit a BOM on PowerShell 7 (only on
# Windows PowerShell 5.1) - write the bytes directly so the generated
# script is UTF-8 with BOM on every PowerShell version that builds it.
[IO.File]::WriteAllText($bundlePath, $bundleText, (New-Object Text.UTF8Encoding($true)))

Copy-Item (Join-Path $repoRoot 'Launch-MailboxForwardingTool.bat') $OutputDirectory
Copy-Item (Join-Path $repoRoot 'LICENSE') $OutputDirectory

$quickstart = @'
EXO Mailbox Forward Manager - Quick start
==========================================

1. Extract every file from this zip into its own folder.
2. Double-click Launch-MailboxForwardingTool.bat.
   (It unblocks the extracted files, then starts the tool with Windows
   PowerShell 5.1.)
3. First launch: the Settings dialog opens automatically. Fill in the
   forwarding domain and service-account UPN. Tab/Shift+Tab moves between
   fields, Space toggles a checkbox field, then Save.
4. Sign in to Exchange Online when prompted (MFA supported).
5. Select mailboxes (Space), edit a row's prefix if needed (Enter), then
   press P to preview every change and Y to apply.

Requirements: Windows, PowerShell 5.1 or newer, and network access to
Exchange Online. The ExchangeOnlineManagement module is installed
automatically on first run if missing.

config.json, cache.json, and changelog-*.csv are written next to the
tool on first use - none of them ship in this zip.

Full documentation: https://github.com/mardahl/EXO-mailforwardManager
License: see LICENSE in this folder.
'@
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'QUICKSTART.txt'), $quickstart, (New-Object Text.UTF8Encoding($true)))

Write-Host "Release staged at $OutputDirectory"
