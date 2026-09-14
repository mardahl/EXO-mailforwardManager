# Regression checks for scripts/Build-Release.ps1: the release stage must
# contain exactly four files, the generated MailboxForwardingTool.ps1 must
# be a standalone UTF-8-with-BOM bundle (no src/ dot-source loader, no
# runtime dependency on src/), every function defined across src/*.ps1 must
# be present in the bundle in the same relative order, and a pre-existing
# non-empty destination must be rejected untouched.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repoRoot = Split-Path $PSScriptRoot -Parent
$builder = Join-Path $repoRoot 'scripts/Build-Release.ps1'
Assert (Test-Path $builder) 'scripts/Build-Release.ps1 must exist.'

$stageRoot = Join-Path ([IO.Path]::GetTempPath()) ("exomft release test " + [guid]::NewGuid())
try {
    & $builder -OutputDirectory $stageRoot
    Assert ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE) 'Build-Release.ps1 must exit 0.'

    $files = @(Get-ChildItem $stageRoot -File | Sort-Object Name)
    Assert ($files.Count -eq 4) "Release stage must contain exactly 4 files, found $($files.Count): $($files.Name -join ', ')."
    $expectedNames = @('LICENSE', 'Launch-MailboxForwardingTool.bat', 'MailboxForwardingTool.ps1', 'QUICKSTART.txt') | Sort-Object
    Assert ((($files.Name | Sort-Object) -join ',') -eq ($expectedNames -join ',')) "Unexpected file set: $($files.Name -join ', ')."

    $bundlePath = Join-Path $stageRoot 'MailboxForwardingTool.ps1'
    $tokens = $null; $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($bundlePath, [ref]$tokens, [ref]$parseErrors)
    Assert ($parseErrors.Count -eq 0) "Bundled script has parse errors: $($parseErrors -join '; ')"

    $bomBytes = [IO.File]::ReadAllBytes($bundlePath)[0..2]
    Assert (($bomBytes -join ',') -eq '239,187,191') "Generated MailboxForwardingTool.ps1 must be UTF-8 with a BOM (0xEF,0xBB,0xBF), got $($bomBytes -join ',')."

    $bundleText = Get-Content $bundlePath -Raw
    Assert (-not ($bundleText -match "Get-ChildItem\s*\(Join-Path\s*\`$script:ScriptDir\s*'src'\)")) 'Bundled script must not contain the src/ dot-source loader.'
    Assert (-not ($bundleText -match "\.\s+\`$source\.FullName")) 'Bundled script must not dot-source anything at runtime.'

    # Every function defined in src/*.ps1 (sorted, the same order the root
    # loader used to dot-source them) must appear in the bundle, in order.
    $srcFiles = @(Get-ChildItem (Join-Path $repoRoot 'src') -Filter '*.ps1' | Sort-Object Name)
    $expectedFunctions = New-Object 'System.Collections.Generic.List[string]'
    foreach ($file in $srcFiles) {
        $fileTokens = $null; $fileErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$fileTokens, [ref]$fileErrors)
        $fns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        foreach ($fn in $fns) { $expectedFunctions.Add($fn.Name) }
    }
    Assert ($expectedFunctions.Count -gt 0) 'Sanity: src/*.ps1 must define at least one function.'

    $bundleAst = [System.Management.Automation.Language.Parser]::ParseFile($bundlePath, [ref]$tokens, [ref]$parseErrors)
    # 'Main' is defined in the root script itself, not in src/ - exclude it
    # before comparing the inlined src/ function set/order.
    $bundleFns = @($bundleAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | Select-Object -ExpandProperty Name | Where-Object { $_ -ne 'Main' })
    Assert (($bundleFns -join ',') -eq ($expectedFunctions -join ',')) "Bundle function order/set mismatch.`nExpected: $($expectedFunctions -join ', ')`nActual:   $($bundleFns -join ', ')"

    # Run the bundle standalone (no src/ present next to it, no repo files
    # around it - a temp dir with a space in its name, matching how a
    # released zip is extracted) as a real child process. Redirected
    # stdin/stdout forces the host-support check (or, off Windows, the
    # platform check) to reject before any module install or network call -
    # a controlled exit that proves the bundle needs nothing from src/ to
    # even start.
    #
    # On Windows the bundle's own STA-relaunch check runs before that
    # rejection: if this test process itself is MTA (pwsh's default), the
    # bundle would spawn a *second*, undirected `powershell.exe` process
    # with its own console instead of inheriting our redirected pipes,
    # hanging the test. Launch the test child with -Sta on Windows only
    # (meaningless/unsupported off Windows) so it is already the apartment
    # state the bundle wants and never relaunches. Also strip
    # EXOMFT_PAUSE_ON_EXIT so an inherited value from an outer run can't
    # make the child block on Read-Host.
    $isolatedDir = Join-Path ([IO.Path]::GetTempPath()) ("exomft isolated " + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $isolatedDir | Out-Null
    try {
        $isolatedScript = Join-Path $isolatedDir 'MailboxForwardingTool.ps1'
        Copy-Item $bundlePath $isolatedScript
        $engine = (Get-Process -Id $PID).Path
        $engineArgs = @('-NoProfile', '-File', $isolatedScript)
        if ($script:IsWin) { $engineArgs = @('-Sta') + $engineArgs }
        $savedPause = $env:EXOMFT_PAUSE_ON_EXIT
        Remove-Item Env:EXOMFT_PAUSE_ON_EXIT -ErrorAction SilentlyContinue
        try {
            $output = '' | & $engine @engineArgs 2>&1
        } finally {
            if ($null -ne $savedPause) { $env:EXOMFT_PAUSE_ON_EXIT = $savedPause }
        }
        Assert ($LASTEXITCODE -eq 1) "Standalone bundle must exit 1 on controlled platform/host rejection (no config, no network), got $LASTEXITCODE. Output: $($output -join ' | ')"
        Assert (-not ($output -join ' ' | Select-String -Pattern 'FATAL')) "Standalone run must reject cleanly, not throw: $($output -join ' | ')"
    } finally {
        Remove-Item $isolatedDir -Recurse -Force -ErrorAction SilentlyContinue
    }
} finally {
    Remove-Item $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Destination guard: a non-empty existing directory (or a file at the
# path) must be rejected untouched before any read/write; an existing but
# empty directory is fine. ---------------------------------------------------
$nonEmptyDir = Join-Path ([IO.Path]::GetTempPath()) ("exomft nonempty " + [guid]::NewGuid())
New-Item -ItemType Directory -Path $nonEmptyDir | Out-Null
try {
    $sentinel = Join-Path $nonEmptyDir 'keepme.txt'
    'do not touch' | Set-Content -LiteralPath $sentinel -Encoding UTF8
    $threw = $false
    try { & $builder -OutputDirectory $nonEmptyDir } catch { $threw = $true }
    Assert $threw 'Build-Release.ps1 must reject a non-empty existing -OutputDirectory.'
    Assert ((Get-Content -LiteralPath $sentinel -Raw) -match 'do not touch') 'A rejected non-empty -OutputDirectory must be left untouched.'
    Assert (-not (Test-Path (Join-Path $nonEmptyDir 'MailboxForwardingTool.ps1'))) 'Rejected build must not have written any release files.'
} finally {
    Remove-Item $nonEmptyDir -Recurse -Force -ErrorAction SilentlyContinue
}

$fileAsDestination = Join-Path ([IO.Path]::GetTempPath()) ("exomft file " + [guid]::NewGuid())
'placeholder' | Set-Content -LiteralPath $fileAsDestination -Encoding UTF8
try {
    $threw = $false
    try { & $builder -OutputDirectory $fileAsDestination } catch { $threw = $true }
    Assert $threw 'Build-Release.ps1 must reject an existing file at -OutputDirectory.'
} finally {
    Remove-Item $fileAsDestination -Force -ErrorAction SilentlyContinue
}

$emptyExistingDir = Join-Path ([IO.Path]::GetTempPath()) ("exomft empty " + [guid]::NewGuid())
New-Item -ItemType Directory -Path $emptyExistingDir | Out-Null
try {
    & $builder -OutputDirectory $emptyExistingDir
    Assert (Test-Path (Join-Path $emptyExistingDir 'MailboxForwardingTool.ps1')) 'Build-Release.ps1 must accept a pre-existing empty -OutputDirectory.'
} finally {
    Remove-Item $emptyExistingDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'ReleaseBundle.Tests.ps1: all assertions passed.'
