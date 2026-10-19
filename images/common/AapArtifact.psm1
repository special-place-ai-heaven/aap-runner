# Verified artifact acquisition (P03). Windows PowerShell 5.1 and PowerShell 7.
# Downloads only; nothing fetched here is ever executed, extracted or piped to a shell.
# Every rejection throws a message that starts with AAP_<Reason>: so callers and tests can match it.
# Reasons: ManifestInvalid VersionNotExact SchemeRejected RedirectRejected SourceUnavailable
#          SizeExceeded SizeMismatch ContentTypeRejected HashSourceMissing HashSourceConflict
#          HashMismatch OfflineIncomplete

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { Write-Verbose 'TLS 1.2 flag not settable on this host' }
Add-Type -AssemblyName System.Net.Http

$script:ToolVersion = '1'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:Placeholder = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' # SHA-256 of zero bytes; a sums file lists it for itself and it is never a pass

function Get-AapProp($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } else { return $null } }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Format-AapTime($v) { if ($v -is [DateTime]) { $v.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { [string]$v } }

# Recorded urls drop the query and fragment: redirect targets carry short-lived signed tokens that must not reach disk.
function Format-AapUrl($u) { $x = [Uri]$u; $x.GetLeftPart([UriPartial]::Path) + $(if ($x.Query) { '?<query-stripped>' } else { '' }) }

function Write-AapJson($Object, [string]$Path) {
    $text = (ConvertTo-Json -InputObject $Object -Depth 8) -replace "`r`n", "`n"
    [IO.File]::WriteAllText($Path, $text + "`n", $script:Utf8NoBom)
}

function Get-AapLowerHash([string]$Path, [string]$Algorithm) {
    (Get-FileHash -Algorithm $Algorithm -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Test-AapLoopback([string]$HostName) {
    $HostName -in @('127.0.0.1', 'localhost', '[::1]', '::1')
}

# ---- manifest validation ---------------------------------------------------------------------

function Test-AapEntry {
    <# Returns the list of problems (empty when the entry is acceptable). #>
    param([Parameter(Mandatory)]$Entry, [switch]$AllowTestSources)
    $e = New-Object System.Collections.Generic.List[string]
    $name = Get-AapProp $Entry 'name'
    if ($name -isnot [string] -or $name -cnotmatch '^[a-z0-9][a-z0-9._-]{0,79}$') { $e.Add('AAP_ManifestInvalid: name must match ^[a-z0-9][a-z0-9._-]{0,79}$') }
    $v = Get-AapProp $Entry 'version'
    if ($v -isnot [string] -or $v -cnotmatch '^[0-9A-Za-z][0-9A-Za-z._+-]{0,79}$' -or $v -match '(?i)latest|stable|nightly|current|^(head|main|master|lts|newest)$') {
        $e.Add("AAP_VersionNotExact: version '$v' is not an exact pinned version")
    }
    $fn = Get-AapProp $Entry 'file_name'
    if ($fn -isnot [string] -or $fn -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._+~-]{0,199}$') { $e.Add('AAP_ManifestInvalid: file_name must be a plain file name') }
    $urls = @(Get-AapProp $Entry 'urls')
    if ($urls.Count -lt 1 -or $urls.Count -gt 8) { $e.Add('AAP_ManifestInvalid: urls needs 1 to 8 entries') }
    foreach ($u in $urls) {
        $uri = $null
        if ($u -isnot [string] -or -not [Uri]::TryCreate($u, [UriKind]::Absolute, [ref]$uri)) { $e.Add("AAP_ManifestInvalid: url is not absolute: $u"); continue }
        if ($uri.UserInfo) { $e.Add('AAP_ManifestInvalid: url carries credentials') }
        $ok = ($uri.Scheme -eq 'https') -or ($AllowTestSources -and (($uri.Scheme -eq 'file') -or ($uri.Scheme -eq 'http' -and (Test-AapLoopback $uri.Host))))
        if (-not $ok) { $e.Add("AAP_SchemeRejected: only https sources are allowed: $($uri.Scheme)://$($uri.Host)") }
    }
    $h = Get-AapProp $Entry 'hash'
    $algo = Get-AapProp $h 'algorithm'
    $src = Get-AapProp $h 'source'
    $val = Get-AapProp $h 'value'
    if ($algo -notin @('sha256', 'sha512')) { $e.Add('AAP_ManifestInvalid: hash.algorithm is sha256 or sha512') }
    if ($src -notin @('literal', 'upstream-file', 'first-fetch')) { $e.Add('AAP_ManifestInvalid: hash.source is literal, upstream-file or first-fetch') }
    $len = if ($algo -eq 'sha512') { 128 } else { 64 }
    if ($null -ne $val -and ($val -isnot [string] -or $val -cnotmatch "^[0-9a-f]{$len}$")) { $e.Add("AAP_ManifestInvalid: hash.value must be $len lowercase hex digits") }
    if ($src -eq 'literal' -and $null -eq $val) { $e.Add('AAP_HashSourceMissing: literal hash source needs hash.value') }
    if ($src -eq 'first-fetch' -and $null -ne $val) { $e.Add('AAP_ManifestInvalid: first-fetch carries no hash.value') }
    if ($src -eq 'upstream-file') {
        if (-not (Get-AapProp $h 'upstream_entry') -or -not (Get-AapProp $h 'upstream_key')) { $e.Add('AAP_HashSourceMissing: upstream-file needs upstream_entry and upstream_key') }
        if ($algo -ne 'sha256') { $e.Add('AAP_ManifestInvalid: upstream sums files are read as sha256') }
    }
    $max = Get-AapProp $Entry 'size_max_bytes'
    if ($max -isnot [ValueType] -or $max -lt 1 -or $max -gt 10737418240) { $e.Add('AAP_ManifestInvalid: size_max_bytes must be 1..10737418240') }
    $exact = Get-AapProp $Entry 'size_bytes'
    if ($null -ne $exact -and ($exact -isnot [ValueType] -or $exact -lt 0 -or ($max -is [ValueType] -and $exact -gt $max))) { $e.Add('AAP_ManifestInvalid: size_bytes must be within size_max_bytes') }
    $ct = @(Get-AapProp $Entry 'content_types' | Where-Object { $_ })
    if ($ct.Count -lt 1) { $e.Add('AAP_ManifestInvalid: content_types needs at least one media type') }
    $lic = Get-AapProp $Entry 'license'
    if ((Get-AapProp $lic 'class') -notin @('open-source', 'vendor-redistributable', 'proprietary-eula', 'unknown')) { $e.Add('AAP_ManifestInvalid: license.class') }
    if ((Get-AapProp $lic 'redistribution') -notin @('allowed', 'restricted', 'forbidden', 'unknown')) { $e.Add('AAP_ManifestInvalid: license.redistribution') }
    $r = Get-AapProp $Entry 'retry'
    $ma = Get-AapProp $r 'max_attempts'; $bs = Get-AapProp $r 'backoff_seconds'; $ts = Get-AapProp $r 'timeout_seconds'
    if ($ma -isnot [ValueType] -or $ma -lt 1 -or $ma -gt 10) { $e.Add('AAP_ManifestInvalid: retry.max_attempts 1..10') }
    if ($bs -isnot [ValueType] -or $bs -lt 0 -or $bs -gt 60) { $e.Add('AAP_ManifestInvalid: retry.backoff_seconds 0..60') }
    if ($ts -isnot [ValueType] -or $ts -lt 1 -or $ts -gt 3600) { $e.Add('AAP_ManifestInvalid: retry.timeout_seconds 1..3600') }
    if ((Get-AapProp $Entry 'evidence_ref') -isnot [string] -or -not (Get-AapProp $Entry 'evidence_ref')) { $e.Add('AAP_ManifestInvalid: evidence_ref is required') }
    return $e.ToArray()
}

function Test-AapManifest {
    <# Returns every problem in the manifest; an empty list means it is acceptable. #>
    param([Parameter(Mandatory)]$Manifest, [switch]$AllowTestSources)
    $e = New-Object System.Collections.Generic.List[string]
    if ((Get-AapProp $Manifest 'schema') -ne 1) { $e.Add('AAP_ManifestInvalid: schema must be 1') }
    $entries = @(Get-AapProp $Manifest 'entries')
    $seen = @{}
    foreach ($en in $entries) {
        $id = "$(Get-AapProp $en 'name')@$(Get-AapProp $en 'version')"
        foreach ($p in @(Test-AapEntry -Entry $en -AllowTestSources:$AllowTestSources)) { $e.Add("$id -> $p") }
        if ($seen.ContainsKey($id)) { $e.Add("AAP_ManifestInvalid: duplicate entry $id") }
        $seen[$id] = $true
        $h = Get-AapProp $en 'hash'
        if ((Get-AapProp $h 'source') -eq 'upstream-file') {
            $up = $entries | Where-Object { (Get-AapProp $_ 'name') -eq (Get-AapProp $h 'upstream_entry') } | Select-Object -First 1
            if (-not $up) { $e.Add("AAP_ManifestInvalid: $id upstream_entry not in manifest") }
            elseif ((Get-AapProp (Get-AapProp $up 'hash') 'source') -ne 'literal') { $e.Add("AAP_ManifestInvalid: $id upstream file must itself have a literal hash") }
        }
    }
    $nr = @(Get-AapProp $Manifest 'not_reproducible')
    foreach ($b in $nr) {
        foreach ($f in 'id', 'profiles', 'name', 'blocker_kind', 'reason', 'owner_action', 'evidence_ref') {
            if (-not (Get-AapProp $b $f)) { $e.Add("AAP_ManifestInvalid: not_reproducible '$(Get-AapProp $b 'id')' lacks $f") }
        }
        if ($entries | Where-Object { (Get-AapProp $_ 'name') -eq (Get-AapProp $b 'id') }) { $e.Add("AAP_ManifestInvalid: '$(Get-AapProp $b 'id')' is both an entry and a blocker") }
    }
    return $e.ToArray()
}

function Read-AapManifest {
    param([Parameter(Mandatory)][string]$Path, [switch]$AllowTestSources)
    $m = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    $errs = @(Test-AapManifest -Manifest $m -AllowTestSources:$AllowTestSources)
    if ($errs.Count) { throw ($errs -join "`n") }
    return $m
}

# ---- hash resolution and file verification ----------------------------------------------------

function Get-AapStagedPath([string]$StagingRoot, $Entry) {
    Join-Path (Join-Path (Join-Path $StagingRoot (Get-AapProp $Entry 'name')) (Get-AapProp $Entry 'version')) (Get-AapProp $Entry 'file_name')
}

function Resolve-AapExpectedHash {
    <# Returns @{ Value; Source } or $null when the entry is first-fetch. Throws on a missing or conflicting source. #>
    param([Parameter(Mandatory)]$Entry, $Manifest, [Parameter(Mandatory)][string]$StagingRoot)
    $h = Get-AapProp $Entry 'hash'
    $source = Get-AapProp $h 'source'
    $value = Get-AapProp $h 'value'
    if ($source -eq 'literal') { return @{ Value = $value; Source = 'literal' } }
    if ($source -eq 'first-fetch') { return $null }
    $upName = Get-AapProp $h 'upstream_entry'
    $key = Get-AapProp $h 'upstream_key'
    $up = $null
    if ($Manifest) { $up = @(Get-AapProp $Manifest 'entries') | Where-Object { (Get-AapProp $_ 'name') -eq $upName } | Select-Object -First 1 }
    if (-not $up) { throw "AAP_HashSourceMissing: upstream hash file entry '$upName' is not in the manifest" }
    $upPath = Get-AapStagedPath $StagingRoot $up
    if (-not (Test-Path -LiteralPath $upPath -PathType Leaf)) { throw "AAP_HashSourceMissing: upstream hash file '$upName' is not staged at $upPath" }
    $upExpected = Resolve-AapExpectedHash -Entry $up -Manifest $Manifest -StagingRoot $StagingRoot
    [void](Confirm-AapFile -Path $upPath -Entry $up -Expected $upExpected)
    $found = @()
    foreach ($line in [IO.File]::ReadAllLines($upPath)) {
        if ($line -match '^([0-9A-Fa-f]{64})[ \t]+\*?(.+?)\s*$' -and ($Matches[2] -replace '^\./', '') -eq $key -and $Matches[1].ToLowerInvariant() -ne $script:Placeholder) { $found += $Matches[1].ToLowerInvariant() }
    }
    if ($found.Count -ne 1) { throw "AAP_HashSourceMissing: '$key' appears $($found.Count) times in upstream file '$upName'" }
    if ($null -ne $value -and $value -ne $found[0]) { throw "AAP_HashSourceConflict: pinned value for '$(Get-AapProp $Entry 'name')' differs from upstream file '$upName'" }
    return @{ Value = $found[0]; Source = "upstream-file:$upName" + $(if ($null -ne $value) { '+literal' } else { '' }) }
}

function Confirm-AapFile {
    <# Size bound, exact size and hash. Returns bytes and both digests, or throws. $Expected $null means first-fetch (record only). #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Entry, $Expected)
    $bytes = (Get-Item -LiteralPath $Path).Length
    $max = [long](Get-AapProp $Entry 'size_max_bytes')
    $exact = Get-AapProp $Entry 'size_bytes'
    if ($bytes -gt $max) { throw "AAP_SizeExceeded: $bytes bytes exceeds the bound of $max" }
    if ($null -ne $exact -and $bytes -ne [long]$exact) { throw "AAP_SizeMismatch: $bytes bytes, manifest says $exact" }
    $algo = Get-AapProp (Get-AapProp $Entry 'hash') 'algorithm'
    $sha256 = Get-AapLowerHash $Path 'SHA256'
    $actual = if ($algo -eq 'sha512') { Get-AapLowerHash $Path 'SHA512' } else { $sha256 }
    if ($null -ne $Expected -and $actual -ne $Expected.Value) { throw "AAP_HashMismatch: $algo is $actual, expected $($Expected.Value)" }
    return @{ Bytes = $bytes; Sha256 = $sha256; Actual = $actual; Algorithm = $algo }
}

# ---- download --------------------------------------------------------------------------------

function Assert-AapSource {
    param([Uri]$Uri, [string[]]$Hosts, [bool]$Loopback, [string]$Code)
    $okScheme = ($Uri.Scheme -eq 'https') -or ($Loopback -and $Uri.Scheme -eq 'http' -and (Test-AapLoopback $Uri.Host))
    if (-not $okScheme) { throw "AAP_SchemeRejected: $($Uri.Scheme)://$($Uri.Host) is not an allowed source" }
    if ($Uri.UserInfo) { throw "AAP_SchemeRejected: credentials in url" }
    if ($Uri.Host.ToLowerInvariant() -notin $Hosts) { throw "${Code}: host '$($Uri.Host)' is not allowlisted for this artifact" }
}

function Invoke-AapHttpAttempt {
    param($Entry, [string]$Url, [string]$Part, [string[]]$Hosts, [bool]$Loopback)
    $max = [long](Get-AapProp $Entry 'size_max_bytes')
    $timeout = [int](Get-AapProp (Get-AapProp $Entry 'retry') 'timeout_seconds')
    $types = @(Get-AapProp $Entry 'content_types' | ForEach-Object { $_.ToLowerInvariant() })
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($timeout)
    $chain = New-Object System.Collections.ArrayList
    $resp = $null
    try {
        $uri = [Uri]$Url
        $hop = 0
        while ($true) {
            Assert-AapSource -Uri $uri -Hosts $Hosts -Loopback $Loopback -Code $(if ($hop -eq 0) { 'AAP_SchemeRejected' } else { 'AAP_RedirectRejected' })
            try { $resp = $client.GetAsync($uri, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult() }
            catch { throw "AAP_Transient: request failed: $($_.Exception.Message)" }
            $code = [int]$resp.StatusCode
            [void]$chain.Add([ordered]@{ url = (Format-AapUrl $uri); status = $code })
            if ($code -ge 300 -and $code -lt 400) {
                $loc = $resp.Headers.Location
                if (-not $loc) { throw 'AAP_SourceUnavailable: redirect without a Location header' }
                $hop++
                if ($hop -gt 5) { throw 'AAP_RedirectRejected: more than 5 redirects' }
                $uri = if ($loc.IsAbsoluteUri) { $loc } else { New-Object Uri($uri, $loc) }
                $resp.Dispose(); $resp = $null
                continue
            }
            break
        }
        if ($code -eq 408 -or $code -eq 429 -or $code -ge 500) { throw "AAP_Transient: HTTP $code" }
        if ($code -ne 200) { throw "AAP_SourceUnavailable: HTTP $code from $($uri.Host)" }
        $mt = $resp.Content.Headers.ContentType
        $media = if ($mt) { $mt.MediaType.ToLowerInvariant() } else { '' }
        if ($media -notin $types) { throw "AAP_ContentTypeRejected: '$media' is not one of $($types -join ', ')" }
        $cl = $resp.Content.Headers.ContentLength
        if ($null -ne $cl -and $cl -gt $max) { throw "AAP_SizeExceeded: server announces $cl bytes, bound is $max" }
        $cts = New-Object System.Threading.CancellationTokenSource
        $cts.CancelAfter([TimeSpan]::FromSeconds($timeout))
        $in = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $out = [IO.File]::Open($Part, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $total = 0L
        try {
            $buf = New-Object byte[] 81920
            while ($true) {
                try { $n = $in.ReadAsync($buf, 0, $buf.Length, $cts.Token).GetAwaiter().GetResult() }
                catch { throw "AAP_Transient: read failed: $($_.Exception.Message)" }
                if ($n -le 0) { break }
                $total += $n
                if ($total -gt $max) { throw "AAP_SizeExceeded: body passed the bound of $max bytes" }
                $out.Write($buf, 0, $n)
            }
        } finally { $out.Dispose(); $in.Dispose(); $cts.Dispose() }
        if ($null -ne $cl -and $total -ne $cl) { throw "AAP_Transient: partial body, $total of $cl bytes" }
        return @{ Chain = $chain; FinalUrl = (Format-AapUrl $uri); ContentType = $media }
    } finally {
        if ($resp) { $resp.Dispose() }
        $client.Dispose()
    }
}

function Copy-AapFileSource {
    param($Entry, [string]$Url, [string]$Part)
    $src = ([Uri]$Url).LocalPath
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw "AAP_Transient: file source missing: $src" }
    if ((Get-Item -LiteralPath $src).Length -gt [long](Get-AapProp $Entry 'size_max_bytes')) { throw 'AAP_SizeExceeded: file source is larger than the bound' }
    Copy-Item -LiteralPath $src -Destination $Part -Force
    return @{ Chain = @([ordered]@{ url = $Url; status = 200 }); FinalUrl = $Url; ContentType = 'file' }
}

# ---- acquisition -----------------------------------------------------------------------------

function Get-AapArtifact {
    <#
    .SYNOPSIS
      Fetch (or, with -Offline, verify) one manifest entry into <StagingRoot>/<name>/<version>/<file_name>.
    .DESCRIPTION
      The file is published into staging only after size and hash verification; a partial or rejected
      download never appears under its final name. A provenance record is written beside it
      (<file>.provenance.json, or <file>.rejected.json on rejection) and also returned.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$StagingRoot,
        $Manifest,
        [switch]$Offline,
        [switch]$RecordFirstFetch,
        [switch]$AllowLoopbackHttp,
        [switch]$AllowFileSource
    )
    $started = [DateTime]::UtcNow
    $name = [string](Get-AapProp $Entry 'name')
    $version = [string](Get-AapProp $Entry 'version')
    $lic = Get-AapProp $Entry 'license'
    $prov = [ordered]@{
        schema = 'aap-provenance/1'; name = $name; version = $version; file_name = Get-AapProp $Entry 'file_name'
        outcome = 'rejected'; reason = $null; detail = $null; mode = $(if ($Offline) { 'offline' } else { 'online' })
        requested_url = $null; url_chain = @(); final_url = $null; content_type = $null; attempts = 0
        started_at = $started.ToString('yyyy-MM-ddTHH:mm:ssZ'); ended_at = $null; bytes = $null; sha256 = $null
        hash = [ordered]@{ algorithm = Get-AapProp (Get-AapProp $Entry 'hash') 'algorithm'; expected = $null; source = $null; verified = $false }
        license = [ordered]@{ class = Get-AapProp $lic 'class'; redistribution = Get-AapProp $lic 'redistribution'; note = Get-AapProp $lic 'note' }
        evidence_ref = Get-AapProp $Entry 'evidence_ref'
        tool = [ordered]@{ name = 'Get-AapArtifact'; version = $script:ToolVersion }
    }
    $final = $null
    $part = $null
    try {
        $errs = @(Test-AapEntry -Entry $Entry -AllowTestSources:($AllowLoopbackHttp -or $AllowFileSource))
        if ($errs.Count) { throw $errs[0] }
        $final = Get-AapStagedPath $StagingRoot $Entry
        $dir = Split-Path -Parent $final
        $part = $final + '.part'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $expected = Resolve-AapExpectedHash -Entry $Entry -Manifest $Manifest -StagingRoot $StagingRoot
        if ($expected) { $prov.hash.expected = $expected.Value; $prov.hash.source = $expected.Source } else { $prov.hash.source = 'first-fetch' }
        if (-not $expected -and -not $RecordFirstFetch) { throw "AAP_HashSourceMissing: '$name' has no published hash; pass -RecordFirstFetch to record one unverified" }

        $verified = $null
        if (Test-Path -LiteralPath $final -PathType Leaf) {
            try { $verified = Confirm-AapFile -Path $final -Entry $Entry -Expected $expected; $prov.mode = $(if ($Offline) { 'offline' } else { 'reuse' }) }
            catch {
                if ($Offline) { throw }
                $prov.detail = "replaced an existing staged file that failed verification: $($_.Exception.Message)"
                Remove-Item -LiteralPath $final -Force
            }
        } elseif ($Offline) { throw "AAP_OfflineIncomplete: $final is not staged" }

        if (-not $verified) {
            $urls = @(Get-AapProp $Entry 'urls')
            $hosts = @($urls | ForEach-Object { ([Uri]$_).Host.ToLowerInvariant() }) + @(Get-AapProp $Entry 'redirect_hosts' | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
            $retry = Get-AapProp $Entry 'retry'
            $max = [int](Get-AapProp $retry 'max_attempts')
            $got = $null
            $last = $null
            for ($i = 1; $i -le $max -and -not $got; $i++) {
                $prov.attempts = $i
                $url = $urls[($i - 1) % $urls.Count]
                if ($i -eq 1) { $prov.requested_url = (Format-AapUrl $url) }
                try {
                    if (([Uri]$url).Scheme -eq 'file') {
                        if (-not $AllowFileSource) { throw "AAP_SchemeRejected: file sources need -AllowFileSource" }
                        $got = Copy-AapFileSource -Entry $Entry -Url $url -Part $part
                    } else {
                        $got = Invoke-AapHttpAttempt -Entry $Entry -Url $url -Part $part -Hosts $hosts -Loopback ([bool]$AllowLoopbackHttp)
                    }
                } catch {
                    $msg = $_.Exception.Message
                    if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }
                    if ($msg -notlike 'AAP_Transient:*' -and $msg -like 'AAP_*') { throw }
                    $last = $msg -replace '^AAP_Transient: ', ''
                    if ($i -lt $max) { Start-Sleep -Seconds ([int](Get-AapProp $retry 'backoff_seconds') * $i) }
                }
            }
            if (-not $got) { throw "AAP_SourceUnavailable: $max attempt(s) failed, last: $last" }
            $prov.url_chain = @($got.Chain); $prov.final_url = $got.FinalUrl; $prov.content_type = $got.ContentType
            try { $verified = Confirm-AapFile -Path $part -Entry $Entry -Expected $expected }
            catch { Remove-Item -LiteralPath $part -Force; throw }
            Move-Item -LiteralPath $part -Destination $final -Force
        }
        $prov.bytes = $verified.Bytes; $prov.sha256 = $verified.Sha256
        $prov.hash.verified = [bool]$expected
        if (-not $expected) { $prov.hash.expected = $verified.Actual; $prov.detail = 'first fetch: hash recorded, not verified against an upstream source' }
        $prov.outcome = 'accepted'
    } catch {
        $m = $_.Exception.Message
        $prov.reason = if ($m -match '^(AAP_[A-Za-z]+):') { $Matches[1] } else { 'AAP_Unexpected' }
        $prov.detail = $m
        $prov.ended_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        if ($final) { Write-AapJson $prov ($final + '.rejected.json') }
        throw
    }
    $prov.ended_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $provPath = $final + '.provenance.json'
    Write-AapJson $prov $provPath
    return [pscustomobject]@{ Path = $final; ProvenancePath = $provPath; Provenance = $prov }
}

function Invoke-AapManifest {
    <# Acquire (or with -Offline verify) every entry, or only -Name. Never stops at the first rejection.
       Unreproducible inputs are returned as blockers; Complete says nothing about them. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$StagingRoot,
        [string[]]$Name,
        [switch]$Offline, [switch]$RecordFirstFetch, [switch]$AllowLoopbackHttp, [switch]$AllowFileSource
    )
    $entries = @(Get-AapProp $Manifest 'entries')
    if ($Name) { $entries = @($entries | Where-Object { (Get-AapProp $_ 'name') -in $Name }) }
    $ordered = @($entries | Where-Object { (Get-AapProp (Get-AapProp $_ 'hash') 'source') -ne 'upstream-file' }) + @($entries | Where-Object { (Get-AapProp (Get-AapProp $_ 'hash') 'source') -eq 'upstream-file' })
    $results = foreach ($en in $ordered) {
        try {
            $a = Get-AapArtifact -Entry $en -StagingRoot $StagingRoot -Manifest $Manifest -Offline:$Offline -RecordFirstFetch:$RecordFirstFetch -AllowLoopbackHttp:$AllowLoopbackHttp -AllowFileSource:$AllowFileSource
            [pscustomobject]@{ Name = Get-AapProp $en 'name'; Status = 'accepted'; Reason = $null; Path = $a.Path; Message = $null }
        } catch {
            $m = $_.Exception.Message
            [pscustomobject]@{ Name = Get-AapProp $en 'name'; Status = 'rejected'; Reason = $(if ($m -match '^(AAP_[A-Za-z]+):') { $Matches[1] } else { 'AAP_Unexpected' }); Path = $null; Message = $m }
        }
    }
    $results = @($results)
    [pscustomobject]@{
        Complete = (@($results | Where-Object Status -eq 'rejected').Count -eq 0)
        Results = $results
        Blockers = @(Get-AapProp $Manifest 'not_reproducible')
    }
}

# ---- evidence --------------------------------------------------------------------------------

function New-AapEvidenceRecord {
    <# Writes an evidence-bundle record (parity/contracts/evidence-bundle.schema.json) for one provenance file.
       The provenance file itself is listed as an artifact by hash, so URL chain and license class stay retrievable. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProvenancePath,
        [Parameter(Mandatory)][string]$OutPath,
        [string]$HeadSha,
        [string]$ManifestPath,
        [string]$Item = 'P03',
        [string]$Verifier = 'pending-independent-verifier',
        [switch]$ExpectFailure
    )
    $p = [IO.File]::ReadAllText($ProvenancePath) | ConvertFrom-Json
    if (-not $HeadSha) { $HeadSha = (& git -C (Split-Path -Parent $ProvenancePath) rev-parse HEAD 2>$null) }
    if ($HeadSha -cnotmatch '^[0-9a-f]{40}$') { throw 'New-AapEvidenceRecord: pass -HeadSha, a full 40-hex commit' }
    $san = { param($s) ($s -replace '[^A-Za-z0-9._-]', '_') }
    $accepted = $p.outcome -eq 'accepted'
    $verified = $accepted -and $p.hash.verified
    $observed = if ($verified) { 'success' } elseif ($accepted) { 'unknown' } else { 'failure' }
    $expected = if ($ExpectFailure) { 'failure' } else { 'success' }
    $result = if ($observed -eq 'unknown') { 'unknown' } elseif ($observed -eq $expected) { 'pass' } else { 'fail' }
    $exit = if ($observed -eq 'success') { 0 } elseif ($observed -eq 'failure') { 1 } else { $null }
    $artifacts = @([ordered]@{ name = (& $san ([IO.Path]::GetFileName($ProvenancePath))); bytes = (Get-Item -LiteralPath $ProvenancePath).Length; sha256 = Get-AapLowerHash $ProvenancePath 'SHA256' })
    if ($accepted) { $artifacts = @([ordered]@{ name = (& $san $p.file_name); bytes = [long]$p.bytes; sha256 = $p.sha256 }) + $artifacts }
    $manifestHash = if ($ManifestPath) { Get-AapLowerHash $ManifestPath 'SHA256' } else { $null }
    $fixture = ("images/common/$($p.name)-$($p.version)").ToLowerInvariant() -replace '[^a-z0-9._/-]', '.'
    $rec = [ordered]@{
        schema = 1; item = $Item; contract_revision = 'evidence-bundle@1'; head_sha = $HeadSha; action_shas = @()
        reference_image = $null; candidate_image = $null; inputs_manifest_sha256 = $manifestHash; fixture_id = $fixture
        os_version = ([Environment]::OSVersion.VersionString -replace '[^ -~]', '?')
        tool_versions = [ordered]@{ powershell = $PSVersionTable.PSVersion.ToString(); 'get-aap-artifact' = $script:ToolVersion }
        command = "Get-AapArtifact $($p.name) $($p.version) mode=$($p.mode)"
        started_at = (Format-AapTime $p.started_at); ended_at = (Format-AapTime $p.ended_at); exit_status = $exit
        oracle = [ordered]@{ expected = $expected; observed = $observed }
        result = $result; artifacts = $artifacts; verifier = $Verifier
    }
    Write-AapJson $rec $OutPath
    return $OutPath
}

Export-ModuleMember -Function Test-AapEntry, Test-AapManifest, Read-AapManifest, Resolve-AapExpectedHash, Confirm-AapFile, Get-AapArtifact, Invoke-AapManifest, New-AapEvidenceRecord, Get-AapStagedPath
