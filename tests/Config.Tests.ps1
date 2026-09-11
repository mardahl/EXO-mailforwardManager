. (Join-Path $PSScriptRoot 'TestSupport.ps1')

# --- Test-ForwardingConfig ---------------------------------------------------

$config = [pscustomobject]@{
    ForwardingDomain           = 'archive.example.com'
    ServiceAccountUPN          = 'admin@example.com'
    DeliverToMailboxAndForward = $true
    CacheTtlHours              = 24
}
Assert (@(Test-ForwardingConfig -Config $config).Count -eq 0) 'Valid config rejected.'

$config.CacheTtlHours = -1
Assert (@(Test-ForwardingConfig -Config $config).Count -gt 0) 'Negative TTL accepted.'

$config.CacheTtlHours = 0
Assert (@(Test-ForwardingConfig -Config $config).Count -eq 0) 'Zero TTL must disable cache reuse, not be rejected as invalid.'
$config.CacheTtlHours = 24

Assert (@(Test-ForwardingConfig -Config $null).Count -gt 0) 'Missing config must be rejected (setup required).'

$blankDomain = $config.PSObject.Copy()
$blankDomain.ForwardingDomain = ''
Assert (@(Test-ForwardingConfig -Config $blankDomain).Count -gt 0) 'Blank ForwardingDomain accepted.'

$badDomain = $config.PSObject.Copy()
$badDomain.ForwardingDomain = 'not a host!'
Assert (@(Test-ForwardingConfig -Config $badDomain).Count -gt 0) 'Invalid hostname accepted.'

$blankUpn = $config.PSObject.Copy()
$blankUpn.ServiceAccountUPN = ''
Assert (@(Test-ForwardingConfig -Config $blankUpn).Count -gt 0) 'Blank ServiceAccountUPN accepted.'

$badUpn = $config.PSObject.Copy()
$badUpn.ServiceAccountUPN = 'not-an-address'
Assert (@(Test-ForwardingConfig -Config $badUpn).Count -gt 0) 'Invalid ServiceAccountUPN accepted.'

$badBool = $config.PSObject.Copy()
$badBool.DeliverToMailboxAndForward = 'yes'
Assert (@(Test-ForwardingConfig -Config $badBool).Count -gt 0) 'Non-boolean DeliverToMailboxAndForward accepted.'

# --- Test-ForwardingDestination ----------------------------------------------

Assert (Test-ForwardingDestination -Address 'alice@example.com') 'Plain valid address rejected.'
Assert (-not (Test-ForwardingDestination -Address "alice`n@example.com")) 'Control character accepted.'
Assert (-not (Test-ForwardingDestination -Address '')) 'Blank destination could clear forwarding.'
Assert (-not (Test-ForwardingDestination -Address 'alice @example.com')) 'Embedded space accepted.'
Assert (-not (Test-ForwardingDestination -Address 'Alice Example <alice@example.com>')) 'Display-name syntax accepted.'
Assert (-not (Test-ForwardingDestination -Address 'alice@')) 'Blank domain part accepted.'
Assert (-not (Test-ForwardingDestination -Address '@example.com')) 'Blank local part accepted.'
Assert (-not (Test-ForwardingDestination -Address 'alice@not_a_host!')) 'Invalid hostname accepted.'

# --- Test-CacheFresh: TTL zero must always disable reuse --------------------

$Script:Config = [pscustomobject]@{ CacheTtlHours = 0 }
$freshCache = [pscustomobject]@{ FetchedAt = (Get-Date).ToUniversalTime().ToString('o') }
Assert (-not (Test-CacheFresh -Cache $freshCache)) 'TTL zero must reject even a just-fetched cache.'

$futureCache = [pscustomobject]@{ FetchedAt = (Get-Date).ToUniversalTime().AddHours(1).ToString('o') }
Assert (-not (Test-CacheFresh -Cache $futureCache)) 'TTL zero must reject even a future-timestamped cache (clock skew).'

$Script:Config = [pscustomobject]@{ CacheTtlHours = 24 }
Assert (Test-CacheFresh -Cache $freshCache) 'Positive TTL must accept a just-fetched cache (sanity check).'

# --- CacheTtlHours as typed by Show-SettingsDialog's Save handler -----------
# src/20-dialogs.ps1's Show-SettingsDialog always TryParses the typed TTL
# field to an [int] before calling Test-ForwardingConfig (defaulting to 0 on
# a non-numeric string), so it can never hand this function a string TTL
# directly - this locks that contract down from the config side.
# Note: builds a fresh base object rather than reusing $config - PowerShell
# variable names are case-insensitive, so the $Script:Config reassignments
# above (Test-CacheFresh section) are the *same* variable as $config here.

$baseConfig = [pscustomobject]@{
    ForwardingDomain           = 'archive.example.com'
    ServiceAccountUPN          = 'admin@example.com'
    DeliverToMailboxAndForward = $true
    CacheTtlHours              = 24
}

$typedTtlConfig = $baseConfig.PSObject.Copy()
$typedTtlConfig.CacheTtlHours = 10
Assert (@(Test-ForwardingConfig -Config $typedTtlConfig).Count -eq 0) 'An already-parsed integer TTL must be accepted.'

$nonNumericTtlConfig = $baseConfig.PSObject.Copy()
$ttlInt = 0
[void][int]::TryParse('not-a-number', [ref]$ttlInt)
$nonNumericTtlConfig.CacheTtlHours = $ttlInt
Assert ($nonNumericTtlConfig.CacheTtlHours -eq 0) 'TryParse must default a non-numeric typed TTL to 0, matching the Settings dialog Save handler.'
Assert (@(Test-ForwardingConfig -Config $nonNumericTtlConfig).Count -eq 0) 'A TryParse-defaulted TTL of 0 must still be accepted (it disables cache reuse, not invalid).'

# --- Get-Config: loaded file must be validated through Test-ForwardingConfig,
# not just checked for two non-blank strings -------------------------------
# Isolate from the repo's real config.json (if any) with a temp file path.
$originalConfigPath = $Script:ConfigPath
$tempConfigPath = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString() + '.json')
try {
    $Script:ConfigPath = $tempConfigPath

    '{"ForwardingDomain":"archive.example.com","ServiceAccountUPN":"admin@example.com","CacheTtlHours":24,"DeliverToMailboxAndForward":true}' |
        Set-Content -Path $tempConfigPath -Encoding UTF8
    $loaded = Get-Config
    Assert ($null -ne $loaded) 'A valid config.json must load.'
    Assert ($loaded.CacheTtlHours -eq 24 -and $loaded.CacheTtlHours -is [int]) 'CacheTtlHours must load as an int.'
    Assert ($loaded.ForwardingDomain -eq 'archive.example.com') 'ForwardingDomain must round-trip.'

    # Garbage CacheTtlHours must reject the whole file, not silently become 0
    # (int.TryParse's failure default) and be accepted as "cache never reused".
    '{"ForwardingDomain":"archive.example.com","ServiceAccountUPN":"admin@example.com","CacheTtlHours":"not-a-number","DeliverToMailboxAndForward":true}' |
        Set-Content -Path $tempConfigPath -Encoding UTF8
    Assert ($null -eq (Get-Config)) 'A non-numeric CacheTtlHours must be rejected, not coerced to 0.'

    # Negative CacheTtlHours is syntactically numeric but semantically invalid.
    '{"ForwardingDomain":"archive.example.com","ServiceAccountUPN":"admin@example.com","CacheTtlHours":-5,"DeliverToMailboxAndForward":true}' |
        Set-Content -Path $tempConfigPath -Encoding UTF8
    Assert ($null -eq (Get-Config)) 'A negative CacheTtlHours must be rejected.'

    # Missing CacheTtlHours entirely: legacy behavior default to 24, not
    # rejected - only a *present* but malformed/null/negative TTL is invalid.
    '{"ForwardingDomain":"archive.example.com","ServiceAccountUPN":"admin@example.com","DeliverToMailboxAndForward":true}' |
        Set-Content -Path $tempConfigPath -Encoding UTF8
    $missingTtl = Get-Config
    Assert ($null -ne $missingTtl) 'A missing CacheTtlHours must default to 24 (legacy behavior), not reject the config.'
    Assert ($missingTtl.CacheTtlHours -eq 24 -and $missingTtl.CacheTtlHours -is [int]) 'A missing CacheTtlHours must load as int 24.'

    # An explicit JSON null for CacheTtlHours is present-but-invalid, not
    # absent - it must still be rejected, not defaulted.
    '{"ForwardingDomain":"archive.example.com","ServiceAccountUPN":"admin@example.com","CacheTtlHours":null,"DeliverToMailboxAndForward":true}' |
        Set-Content -Path $tempConfigPath -Encoding UTF8
    Assert ($null -eq (Get-Config)) 'An explicit null CacheTtlHours must be rejected, not defaulted to 24.'

    # Invalid ForwardingDomain (syntactically present, semantically bad).
    '{"ForwardingDomain":"not a host!","ServiceAccountUPN":"admin@example.com","CacheTtlHours":24,"DeliverToMailboxAndForward":true}' |
        Set-Content -Path $tempConfigPath -Encoding UTF8
    Assert ($null -eq (Get-Config)) 'An invalid ForwardingDomain must be rejected.'

    # Blank ServiceAccountUPN.
    '{"ForwardingDomain":"archive.example.com","ServiceAccountUPN":"","CacheTtlHours":24,"DeliverToMailboxAndForward":true}' |
        Set-Content -Path $tempConfigPath -Encoding UTF8
    Assert ($null -eq (Get-Config)) 'A blank ServiceAccountUPN must be rejected.'

    # Missing file entirely.
    Remove-Item $tempConfigPath -Force
    Assert ($null -eq (Get-Config)) 'A missing config.json must return $null.'

    # Malformed JSON.
    'not json at all {' | Set-Content -Path $tempConfigPath -Encoding UTF8
    Assert ($null -eq (Get-Config)) 'Malformed JSON must return $null, not throw.'
} finally {
    $Script:ConfigPath = $originalConfigPath
    Remove-Item $tempConfigPath -Force -ErrorAction SilentlyContinue
}

Write-Host 'Config.Tests.ps1: all assertions passed.'
