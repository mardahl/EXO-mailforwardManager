# Side-effect-free loader shared by test scripts that need the extracted
# backend functions (config/cache, Exchange) without executing the root
# script's STA relaunch check, module install, or WinForms startup.
$script:EntryScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'MailboxForwardingTool.ps1'
$script:ScriptDir = Split-Path $script:EntryScriptPath -Parent
$script:StartupOptions = @{ SelfTest = $false; DisableWAM = $false; Ascii = $true }
foreach ($source in (Get-ChildItem (Join-Path $script:ScriptDir 'src') -Filter '*.ps1' | Sort-Object Name)) {
    . $source.FullName
}
function Assert($Condition, $Message) {
    if (-not $Condition) { throw $Message }
}
