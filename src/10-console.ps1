# Console/VT lifecycle - alternate screen buffer, cursor, encoding, and
# Ctrl+C state. Adapted from SOAconverter's src/10-console-vt.ps1: native
# type renamed to avoid a `SoaTui.Native` collision if both tools are ever
# dot-sourced in the same process, and native calls are gated on their
# Boolean return values before this touches any console state.
# No console/terminal side effects happen just from dot-sourcing this file;
# Enter-Tui/Exit-Tui/Show-Tui only touch the console when actually called.

$script:SavedOutputEncoding = $null
$script:SavedCtrlC          = $null
$script:SavedCursorVisible  = $null
$script:TuiActive           = $false
$script:IsWin = ($PSVersionTable.PSVersion.Major -lt 6) -or
    ($null -ne (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) -and $IsWindows)

function Enable-ExoMftVirtualTerminal {
    # Best-effort: on a host/stream that already supports VT (or isn't
    # Windows), there is nothing to change. Reject failure quietly - callers
    # decide whether to proceed without color, not this helper.
    if (-not $script:IsWin) { return $true }
    try {
        if (-not ('ExoMftTui.Native' -as [type])) {
            Add-Type -Namespace ExoMftTui -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@
        }
        $handle = [ExoMftTui.Native]::GetStdHandle(-11) # STD_OUTPUT_HANDLE
        $mode = 0
        if (-not [ExoMftTui.Native]::GetConsoleMode($handle, [ref]$mode)) { return $false }
        # ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x4
        return [bool][ExoMftTui.Native]::SetConsoleMode($handle, $mode -bor 4)
    } catch {
        return $false
    }
}

function Test-TuiHostSupported {
    # Reject redirected streams and non-interactive hosts before Enter-Tui
    # changes any console state, per spec: "reject unsupported host/
    # redirected streams before changing state".
    try {
        if ([Console]::IsOutputRedirected -or [Console]::IsInputRedirected) { return $false }
    } catch { return $false }
    return $true
}

function Enter-Tui {
    if ($script:TuiActive) { return }
    if (-not (Test-TuiHostSupported)) {
        throw 'Interactive console required: input/output is redirected or unsupported.'
    }
    # Save everything this function might change before changing anything,
    # so a partially-initialized session can still be restored by Exit-Tui.
    $script:SavedOutputEncoding = [Console]::OutputEncoding
    try { $script:SavedCursorVisible = [Console]::CursorVisible } catch { $script:SavedCursorVisible = $null }
    try { $script:SavedCtrlC = [Console]::TreatControlCAsInput } catch { $script:SavedCtrlC = $null }
    $script:TuiActive = $true
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
    [void](Enable-ExoMftVirtualTerminal)
    try { [Console]::TreatControlCAsInput = $true } catch { }
    [Console]::Write("$script:ESC[?1049h") # alternate screen buffer
    [Console]::Write("$script:ESC[?25l")   # hide cursor
    [Console]::Write("$script:ESC[2J")
    $script:UI.Dirty = $true
}

function Exit-Tui {
    if (-not $script:TuiActive) { return }
    # Restore in reverse order, idempotently, and never let a restoration
    # failure hide whatever error (if any) the caller is already unwinding
    # for - each step is independently best-effort.
    try { [Console]::Write("$script:ESC[0m") } catch { }
    try { [Console]::Write("$script:ESC[?25h") } catch { }
    try { [Console]::Write("$script:ESC[?1049l") } catch { }
    if ($null -ne $script:SavedCtrlC) {
        try { [Console]::TreatControlCAsInput = $script:SavedCtrlC } catch { }
    }
    if ($null -ne $script:SavedCursorVisible) {
        try { [Console]::CursorVisible = $script:SavedCursorVisible } catch { }
    }
    if ($null -ne $script:SavedOutputEncoding) {
        try { [Console]::OutputEncoding = $script:SavedOutputEncoding } catch { }
    }
    $script:TuiActive = $false
}

function Invoke-OnMainBuffer {
    # Temporarily leave the TUI (for interactive auth, module install, ...)
    # and guarantee re-entry, even if $Action throws.
    param([Parameter(Mandatory)][scriptblock]$Action)
    $wasActive = $script:TuiActive
    if ($wasActive) { Exit-Tui }
    try {
        & $Action
    } finally {
        if ($wasActive) { Enter-Tui }
    }
}

function Get-ConsoleSize {
    $w = 80; $h = 24
    try { $w = [Console]::WindowWidth; $h = [Console]::WindowHeight } catch { }
    if ($w -lt 1) { $w = 80 }
    if ($h -lt 1) { $h = 24 }
    return @($w, $h)
}

function Test-TuiBelowFloor {
    # Shared 80x20 floor check ($script:MinTuiWidth/MinTuiHeight, set in
    # src/70-views.ps1) so every modal - not just the main table frame -
    # can refuse a confirming action (Save/Y) rather than silently
    # committing over a too-small, potentially garbled layout.
    $size = Get-ConsoleSize
    return ($size[0] -lt $script:MinTuiWidth -or $size[1] -lt $script:MinTuiHeight)
}

function ConvertTo-DisplayText {
    # Sanitize untrusted remote/config/error text before it reaches a cell:
    # strip C0/DEL control characters (including ESC and tab) so pasted or
    # remote-sourced text cannot inject terminal escape sequences, then pad
    # or truncate to an exact cell width. Never call this on stored
    # addresses used for writes - only on text about to be displayed.
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][int]$Width
    )
    if ($Width -le 0) { return '' }
    $clean = [regex]::Replace($Text, '[\x00-\x1F\x7F]', '')
    if ($clean.Length -gt $Width) {
        $ell = [string]$script:G.Ell
        if ($Width -le $ell.Length) { return $clean.Substring(0, $Width) }
        return $clean.Substring(0, $Width - $ell.Length) + $ell
    }
    return $clean.PadRight($Width)
}

function Add-FrameLine {
    # Append one full absolute-positioned screen line to the frame builder.
    param([System.Text.StringBuilder]$Sb, [int]$Row, [string]$Content)
    [void]$Sb.Append("$script:ESC[$Row;1H")
    [void]$Sb.Append($Content)
    [void]$Sb.Append("$($script:T.Reset)$script:ESC[K")
}

function Show-Tui {
    # Idle render/input loop. Invoke-TuiKey is defined in Task 5's
    # src/80-input.ps1; it is resolved at call time, not when this file is
    # dot-sourced, so loading this file before Task 5 exists has no effect.
    $script:UI.Running = $true
    try {
        Enter-Tui
        while ($script:UI.Running) {
            $size = Get-ConsoleSize
            if ($size[0] -ne $script:UI.Width -or $size[1] -ne $script:UI.Height + 4) {
                $script:UI.Width = $size[0]
                $script:UI.Height = [Math]::Max(0, $size[1] - 4)
                Update-MailboxView -State $script:UI
                $script:UI.Dirty = $true
            }
            if ($script:UI.Dirty) {
                [Console]::Write((Get-MailboxFrame -State $script:UI -Width $size[0] -Height $size[1]))
                $script:UI.Dirty = $false
            }
            if ([Console]::KeyAvailable) {
                Invoke-TuiKey -Key ([Console]::ReadKey($true))
            } else {
                Start-Sleep -Milliseconds 25
            }
        }
    } finally {
        Exit-Tui
    }
}
