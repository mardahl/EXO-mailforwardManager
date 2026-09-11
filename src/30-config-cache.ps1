$script:ConfigPath = Join-Path $script:ScriptDir 'config.json'
$script:CachePath  = Join-Path $script:ScriptDir 'cache.json'

function Get-Config {
    if (-not (Test-Path $Script:ConfigPath)) { return $null }
    try {
        $raw = Get-Content $Script:ConfigPath -Raw | ConvertFrom-Json
    } catch { return $null }
    # Preserve CacheTtlHours exactly as stored when the key is *present*
    # (including a JSON null or garbage string) so Test-ForwardingConfig's
    # own TryParse-based check catches it - do not pre-coerce an unparsable
    # value into a false-valid default (int.TryParse sets its out-param to 0
    # on failure, which would otherwise silently turn "not a number" into
    # "TTL 0 (never cache)"). A key that is *absent* entirely is legacy
    # behavior, not invalid: default it to 24 before validation, same as
    # every config.json written before CacheTtlHours existed.
    $hasTtl = $raw.PSObject.Properties.Name -contains 'CacheTtlHours'
    $ttlRaw = if ($hasTtl) { $raw.CacheTtlHours } else { 24 }
    $candidate = [pscustomobject]@{
        ForwardingDomain           = [string]$raw.ForwardingDomain
        DeliverToMailboxAndForward = [bool]$raw.DeliverToMailboxAndForward
        ServiceAccountUPN          = [string]$raw.ServiceAccountUPN
        CacheTtlHours              = $ttlRaw
    }
    if (@(Test-ForwardingConfig -Config $candidate).Count -gt 0) { return $null }
    # Validated above, so this TryParse cannot fail; it just converts the
    # already-checked value to the int type the rest of the tool expects.
    $ttl = 24
    [void][int]::TryParse([string]$candidate.CacheTtlHours, [ref]$ttl)
    $candidate.CacheTtlHours = $ttl
    $candidate
}

function Save-Config {
    param([Parameter(Mandatory)]$Config)
    $Config | ConvertTo-Json -Depth 5 | Set-Content -Path $Script:ConfigPath -Encoding UTF8
}

function Save-MailboxCache {
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Mailboxes)
    [pscustomobject]@{
        FetchedAt = (Get-Date).ToUniversalTime().ToString('o')
        Mailboxes = $Mailboxes
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $Script:CachePath -Encoding UTF8
}

function Read-MailboxCache {
    if (-not (Test-Path $Script:CachePath)) { return $null }
    try { Get-Content $Script:CachePath -Raw | ConvertFrom-Json } catch { $null }
}

function Test-CacheFresh {
    param($Cache)
    if (-not $Cache -or -not $Cache.FetchedAt) { return $false }
    # TTL <= 0 always disables reuse. Explicit guard (rather than relying on
    # age -lt 0) because a future FetchedAt (clock skew, or a cache written
    # by a host with a fast clock) makes age negative, which would otherwise
    # satisfy "-lt 0" and reuse a cache TTL=0 is supposed to always reject.
    if ($Script:Config.CacheTtlHours -le 0) { return $false }
    $age = (Get-Date).ToUniversalTime() - [datetime]$Cache.FetchedAt
    $age.TotalHours -lt $Script:Config.CacheTtlHours
}

function Test-ForwardingDestination {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Address)
    if ([string]::IsNullOrWhiteSpace($Address)) { return $false }
    if ($Address -match '[\x00-\x1F\x7F]' -or $Address -match '\s') { return $false }

    $parts = $Address -split '@'
    if ($parts.Count -ne 2 -or [string]::IsNullOrEmpty($parts[0]) -or [string]::IsNullOrEmpty($parts[1])) {
        return $false
    }
    if ([System.Uri]::CheckHostName($parts[1]) -eq [System.UriHostNameType]::Unknown) { return $false }

    try {
        # Exact-equality check rejects display-name syntax ("Name <a@b>")
        # that MailAddress otherwise happily parses.
        $parsed = [System.Net.Mail.MailAddress]::new($Address)
        return $parsed.Address -eq $Address
    } catch { return $false }
}

function Test-ForwardingConfig {
    param([Parameter(Mandatory)][AllowNull()]$Config)
    $errors = [System.Collections.Generic.List[string]]::new()
    if (-not $Config) {
        $errors.Add('Configuration is missing; run setup.')
        return $errors.ToArray()
    }

    if ([string]::IsNullOrWhiteSpace($Config.ForwardingDomain) -or
        [System.Uri]::CheckHostName([string]$Config.ForwardingDomain) -eq [System.UriHostNameType]::Unknown -or
        -not (Test-ForwardingDestination -Address "probe@$($Config.ForwardingDomain)")) {
        $errors.Add('ForwardingDomain is not a valid hostname.')
    }

    if ([string]::IsNullOrWhiteSpace($Config.ServiceAccountUPN)) {
        $errors.Add('ServiceAccountUPN is required.')
    } else {
        try { [void][System.Net.Mail.MailAddress]::new([string]$Config.ServiceAccountUPN) }
        catch { $errors.Add('ServiceAccountUPN is not a valid address.') }
    }

    if ($Config.DeliverToMailboxAndForward -isnot [bool]) {
        $errors.Add('DeliverToMailboxAndForward must be a boolean.')
    }

    $ttl = $Config.CacheTtlHours
    $ttlInt = 0
    if ($null -eq $ttl -or -not [int]::TryParse([string]$ttl, [ref]$ttlInt)) {
        $errors.Add('CacheTtlHours must be an integer.')
    } elseif ($ttlInt -lt 0) {
        $errors.Add('CacheTtlHours must be zero or greater.')
    }

    $errors.ToArray()
}
