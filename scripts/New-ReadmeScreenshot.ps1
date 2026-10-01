<#
.SYNOPSIS
    Renders the main TUI frame with Contoso sample data to docs/screenshot-main.svg.
.DESCRIPTION
    Uses the real Get-MailboxFrame renderer (no Exchange connection), then
    converts its ANSI/SGR output (256-color palette) into a terminal-styled
    SVG for the README. Re-run after UI changes to keep the image current.
#>
param([string]$OutFile = (Join-Path (Split-Path $PSScriptRoot -Parent) 'docs/screenshot-main.svg'))
$ErrorActionPreference = 'Stop'
[System.Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]::InvariantCulture  # SVG needs '.' decimals

$script:ScriptDir = Split-Path $PSScriptRoot -Parent
$script:EntryScriptPath = Join-Path $script:ScriptDir 'MailboxForwardingTool.ps1'
$script:StartupOptions = @{ SelfTest = $false; DisableWAM = $false }
Get-ChildItem (Join-Path $script:ScriptDir 'src') -Filter '*.ps1' | Sort-Object Name | ForEach-Object { . $_.FullName }

# --- Sample data -------------------------------------------------------------
$people = @(
    @('Adele Vance', 'adelev', '', $false), @('Alex Wilber', 'alexw', 'alexw@fabrikam.com', $false),
    @('Allan Deyoung', 'allande', '', $false), @('Christie Cline', 'christiec', '', $true),
    @('Debra Berger', 'debrab', 'debra.berger@fabrikam.com', $false), @('Diego Siciliani', 'diegos', '', $false),
    @('Grady Archie', 'gradya', '', $false), @('Isaiah Langer', 'isaiahl', 'isaiahl@fabrikam.com', $false),
    @('Johanna Lorenz', 'johannal', '', $false), @('Lee Gu', 'leeg', '', $false),
    @('Lidia Holloway', 'lidiah', '', $false), @('Megan Bowen', 'meganb', '', $false)
)
$mailboxes = foreach ($p in $people) {
    [pscustomobject]@{
        PrimarySmtpAddress = "$($p[1])@contoso.com"; DisplayName = $p[0]
        ForwardingSmtpAddress = $p[2]; DeliverToMailboxAndForward = $true
        HasOnPremForwardingAddress = $p[3]; ForwardingRecipient = $(if ($p[3]) { 'christie.cline@contoso-legacy.com' } else { '' })
    }
}
$config = [pscustomobject]@{ ForwardingDomain = 'fabrikam.com'; DeliverToMailboxAndForward = $true }
$state = $script:UI
$state.Items = @(New-MailboxRows -Mailboxes $mailboxes -Config $config)
foreach ($i in 0, 2, 5, 6) { $state.Items[$i].Selected = $true }
$state.Account = 'svc-migration@contoso.onmicrosoft.com'
$state.CacheFetchedAt = '2026-10-01T08:00:00Z'
$state.Status = 'Loaded 12 mailboxes.'
Update-MailboxView -State $state
$state.Cursor = 2

$cols = 130; $rows = 20
$frame = Get-MailboxFrame -State $state -Width $cols -Height $rows

# --- ANSI -> cell grid -------------------------------------------------------
function Get-XtermColor([int]$n) {
    $base = '000000','800000','008000','808000','000080','800080','008080','c0c0c0',
            '808080','ff0000','00ff00','ffff00','0000ff','ff00ff','00ffff','ffffff'
    if ($n -lt 16) { return '#' + $base[$n] }
    if ($n -ge 232) { $v = 8 + 10 * ($n - 232); return '#{0:x2}{0:x2}{0:x2}' -f $v }
    $n -= 16; $lv = 0, 95, 135, 175, 215, 255
    return '#{0:x2}{1:x2}{2:x2}' -f $lv[[int][Math]::Floor($n / 36)], $lv[[int][Math]::Floor($n / 6) % 6], $lv[$n % 6]
}
$defFg = '#d0d0d0'; $defBg = '#121212'
$grid = @{}
$row = 1; $col = 1; $fg = $defFg; $bg = $null; $bold = $false
foreach ($m in [regex]::Matches($frame, "\x1b\[([0-9;]*)([A-Za-z])|([^\x1b])")) {
    if ($m.Groups[3].Success) {
        if ($col -le $cols) { $grid["$row,$col"] = @{ Ch = $m.Groups[3].Value; Fg = $fg; Bg = $bg; Bold = $bold } }
        $col++; continue
    }
    $params = $m.Groups[1].Value; $cmd = $m.Groups[2].Value
    if ($cmd -eq 'H') { $p = $params -split ';'; $row = [int]$p[0]; $col = [int]$p[1]; continue }
    if ($cmd -eq 'K') {
        # Erase-to-end-of-line paints the current background.
        for ($c = $col; $c -le $cols; $c++) { $grid["$row,$c"] = @{ Ch = ' '; Fg = $fg; Bg = $bg; Bold = $false } }
        continue
    }
    if ($cmd -ne 'm') { continue }
    $p = @(if ($params) { $params -split ';' | ForEach-Object { [int]$_ } } else { 0 })
    for ($i = 0; $i -lt $p.Count; $i++) {
        switch ($p[$i]) {
            0  { $fg = $defFg; $bg = $null; $bold = $false }
            1  { $bold = $true }
            38 { $fg = Get-XtermColor $p[$i + 2]; $i += 2 }
            48 { $bg = Get-XtermColor $p[$i + 2]; $i += 2 }
        }
    }
}

# --- Cell grid -> SVG --------------------------------------------------------
$cw = 8.4; $lh = 19; $padX = 16; $top = 40
$w = [int]($cols * $cw + 2 * $padX); $h = [int]($rows * $lh + $top + 14)
$esc = { param($s) [System.Security.SecurityElement]::Escape($s) }
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("<svg xmlns=`"http://www.w3.org/2000/svg`" width=`"$w`" height=`"$h`" viewBox=`"0 0 $w $h`" font-family=`"Cascadia Mono, Consolas, Menlo, monospace`" font-size=`"14`">")
[void]$sb.AppendLine("<rect width=`"$w`" height=`"$h`" rx=`"8`" fill=`"$defBg`"/>")
[void]$sb.AppendLine("<rect width=`"$w`" height=`"28`" rx=`"8`" fill=`"#2b2b2b`"/><rect y=`"20`" width=`"$w`" height=`"8`" fill=`"#2b2b2b`"/>")
[void]$sb.AppendLine("<text x=`"$($w / 2)`" y=`"19`" fill=`"#bbbbbb`" font-size=`"12`" text-anchor=`"middle`" font-family=`"Segoe UI, Helvetica, Arial, sans-serif`">Windows PowerShell - MailboxForwardingTool.ps1</text>")
for ($r = 1; $r -le $rows; $r++) {
    $y = $top + ($r - 1) * $lh
    # Backgrounds and text runs: merge adjacent cells with identical style.
    $c = 1
    while ($c -le $cols) {
        $cell = $grid["$r,$c"]; if (-not $cell) { $c++; continue }
        $start = $c; $text = ''
        while ($c -le $cols -and $grid["$r,$c"] -and $grid["$r,$c"].Fg -eq $cell.Fg -and $grid["$r,$c"].Bg -eq $cell.Bg -and $grid["$r,$c"].Bold -eq $cell.Bold) {
            $text += $grid["$r,$c"].Ch; $c++
        }
        $x = $padX + ($start - 1) * $cw
        if ($cell.Bg) { [void]$sb.AppendLine(("<rect x=`"{0:0.#}`" y=`"{1}`" width=`"{2:0.#}`" height=`"$lh`" fill=`"$($cell.Bg)`"/>" -f $x, $y, ($text.Length * $cw))) }
        if ($text.Trim()) {
            $weight = if ($cell.Bold) { ' font-weight="bold"' } else { '' }
            [void]$sb.AppendLine(("<text x=`"{0:0.#}`" y=`"{1}`" fill=`"$($cell.Fg)`"$weight textLength=`"{2:0.#}`" xml:space=`"preserve`">{3}</text>" -f $x, ($y + 14), ($text.Length * $cw), (& $esc $text)))
        }
    }
}
[void]$sb.AppendLine('</svg>')
[System.IO.File]::WriteAllText($OutFile, $sb.ToString())
Write-Host "Wrote $OutFile"
