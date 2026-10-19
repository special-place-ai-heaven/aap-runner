# P03 verified artifact acquisition. Pester 5 on Windows PowerShell 5.1 and PowerShell 7.
# Fixture files are served by a local loopback HttpListener or read from the temp directory; one optional
# test fetches a real small file (tagged Network) and is skipped when github.com does not resolve.

BeforeDiscovery {
    $script:HasPython = [bool](Get-Command python -ErrorAction SilentlyContinue)
    $script:HasNet = $false
    try { [void][Net.Dns]::GetHostAddresses('github.com'); $script:HasNet = $true } catch { $script:HasNet = $false }
}

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
    $script:Common = Join-Path $script:Repo 'images\common'
    $script:ManifestPath = Join-Path $script:Common 'artifacts.manifest.json'
    $script:Validator = Join-Path $script:Repo 'parity\contracts\validate.py'
    Import-Module (Join-Path $script:Common 'AapArtifact.psm1') -Force

    function Get-Sha([byte[]]$Bytes, [string]$Algo = 'SHA256') {
        $h = [Security.Cryptography.HashAlgorithm]::Create($Algo)
        ([BitConverter]::ToString($h.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant()
    }
    function Get-Ascii([string]$Text) { [Text.Encoding]::ASCII.GetBytes($Text) }
    $script:OkBytes = Get-Ascii 'hello artifact'
    $script:OkSha = Get-Sha $script:OkBytes
    $script:Head = '0123456789abcdef0123456789abcdef01234567'

    function New-Entry([string]$Name, [string]$File, [string]$Url, [string]$Sha = $script:OkSha, [hashtable]$Over = @{}) {
        $e = [ordered]@{
            name = $Name; version = '1.0.0'; profiles = @('ubuntu-24.04-x64'); file_name = $File; urls = @($Url); redirect_hosts = @()
            hash = [ordered]@{ algorithm = 'sha256'; source = 'literal'; value = $Sha; upstream_entry = $null; upstream_key = $null }
            size_bytes = $null; size_max_bytes = 1000; content_types = @('application/octet-stream')
            license = [ordered]@{ class = 'open-source'; redistribution = 'allowed'; note = 'fixture' }
            retry = [ordered]@{ max_attempts = 2; backoff_seconds = 0; timeout_seconds = 10 }
            scripts = @(); evidence_ref = 'tests/images/common fixture'
        }
        foreach ($k in $Over.Keys) { $e[$k] = $Over[$k] }
        [pscustomobject]$e
    }
    function New-Staging { $p = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $p | Out-Null; $p }
    function Get-Rejected($Staging, $Entry) { Get-Content -Raw -LiteralPath ((Get-AapStagedPath $Staging $Entry) + '.rejected.json') | ConvertFrom-Json }
    function Invoke-Fetch($Entry, $Staging, [hashtable]$More = @{}) {
        Get-AapArtifact -Entry $Entry -StagingRoot $Staging -AllowLoopbackHttp @More
    }

    # --- loopback test server -------------------------------------------------------------------
    $tcp = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $tcp.Start(); $script:Port = $tcp.LocalEndpoint.Port; $tcp.Stop()
    $script:Base = "http://127.0.0.1:$($script:Port)"
    $script:ClosedBase = $null
    $tcp = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $tcp.Start(); $closed = $tcp.LocalEndpoint.Port; $tcp.Stop()
    $script:ClosedBase = "http://127.0.0.1:$closed"

    $script:State = [hashtable]::Synchronized(@{ Hits = @{}; Sums = ''; Release = $false })
    $script:Listener = New-Object Net.HttpListener
    $script:Listener.Prefixes.Add("http://127.0.0.1:$($script:Port)/")
    $script:Listener.Prefixes.Add("http://localhost:$($script:Port)/")
    $script:Listener.Start()
    $server = {
        param($listener, $state, $port)
        function Send($res, [byte[]]$b, [string]$type, [int]$code = 200) {
            $res.StatusCode = $code; $res.ContentType = $type; $res.ContentLength64 = $b.Length
            $res.OutputStream.Write($b, 0, $b.Length); $res.Close()
        }
        while ($listener.IsListening) {
            try { $ctx = $listener.GetContext() } catch { break }
            try {
                $res = $ctx.Response; $p = $ctx.Request.Url.AbsolutePath
                $state.Hits[$p] = 1 + $(if ($state.Hits.ContainsKey($p)) { $state.Hits[$p] } else { 0 })
                $ok = [Text.Encoding]::ASCII.GetBytes('hello artifact')
                switch ($p) {
                    '/ok.bin' { Send $res $ok 'application/octet-stream' }
                    '/ok512.bin' { Send $res $ok 'application/octet-stream' }
                    '/changed.bin' { Send $res ([Text.Encoding]::ASCII.GetBytes('hello CHANGED!!')) 'application/octet-stream' }
                    '/sums.txt' { Send $res ([Text.Encoding]::ASCII.GetBytes($state.Sums)) 'text/plain' }
                    '/page.html' { Send $res ([Text.Encoding]::ASCII.GetBytes('<html>login</html>')) 'text/html' }
                    '/gone' { Send $res $ok 'text/plain' 404 }
                    '/flaky.bin' { if ($state.Hits[$p] -eq 1) { Send $res $ok 'text/plain' 503 } else { Send $res $ok 'application/octet-stream' } }
                    '/redir-same' { $res.StatusCode = 302; $res.RedirectLocation = '/ok.bin'; $res.Close() }
                    '/redir-other' { $res.StatusCode = 302; $res.RedirectLocation = "http://localhost:$port/ok.bin"; $res.Close() }
                    '/big-announced' { $res.ContentType = 'application/octet-stream'; $res.ContentLength64 = 5000000; $res.OutputStream.Write($ok, 0, 5); $res.Abort() }
                    '/big-chunked' {
                        $res.ContentType = 'application/octet-stream'; $res.SendChunked = $true
                        $chunk = New-Object byte[] 4096
                        try { 1..200 | ForEach-Object { $res.OutputStream.Write($chunk, 0, $chunk.Length) } } catch { $null = $_ }
                        try { $res.Close() } catch { $null = $_ }
                    }
                    '/partial.bin' { $res.ContentType = 'application/octet-stream'; $res.ContentLength64 = 100; $res.OutputStream.Write($ok, 0, 10); $res.OutputStream.Flush(); $res.Abort() }
                    # A stalled server holds the connection until the test sets Release (or 20 s pass); this server is single-threaded.
                    '/stall.bin' {
                        $res.ContentType = 'application/octet-stream'; $res.ContentLength64 = 1000
                        $res.OutputStream.Write($ok, 0, 5); $res.OutputStream.Flush()
                        $i = 0; while (-not $state.Release -and $i -lt 200) { Start-Sleep -Milliseconds 100; $i++ }
                        try { $res.Abort() } catch { $null = $_ }
                    }
                    '/stall-headers' {
                        $i = 0; while (-not $state.Release -and $i -lt 200) { Start-Sleep -Milliseconds 100; $i++ }
                        try { $res.Abort() } catch { $null = $_ }
                    }
                    default { Send $res $ok 'text/plain' 404 }
                }
            } catch { try { $ctx.Response.Abort() } catch { $null = $_ } }
        }
    }
    $script:Ps = [powershell]::Create()
    [void]$script:Ps.AddScript($server).AddArgument($script:Listener).AddArgument($script:State).AddArgument($script:Port)
    $script:Handle = $script:Ps.BeginInvoke()
}

AfterAll {
    try { $script:Listener.Stop(); $script:Listener.Close() } catch { $null = $_ }
    try { $script:Ps.Stop(); $script:Ps.Dispose() } catch { $null = $_ }
}

Describe 'manifest' {
    It 'the committed manifest passes the module checks' {
        $m = Read-AapManifest -Path $script:ManifestPath
        @($m.entries).Count | Should -BeGreaterThan 5
    }
    It 'pins every entry to an exact version, an https source and a hash plan' {
        $m = Read-AapManifest -Path $script:ManifestPath
        foreach ($e in $m.entries) {
            $e.version | Should -Not -Match '(?i)latest|stable|nightly|\*'
            foreach ($u in $e.urls) { $u | Should -Match '^https://' }
            $e.hash.source | Should -BeIn @('literal', 'upstream-file', 'first-fetch')
            if ($e.hash.source -eq 'literal') { $e.hash.value | Should -Not -BeNullOrEmpty }
            $e.size_max_bytes | Should -BeGreaterThan 0
        }
    }
    It 'lists the unreproducible inputs as blockers, never as entries' {
        $m = Read-AapManifest -Path $script:ManifestPath
        $ids = @($m.not_reproducible | ForEach-Object id)
        $ids | Should -Contain 'windows-server-2025-media'
        $ids | Should -Contain 'visual-studio-2026-bootstrapper'
        $ids | Should -Contain 'azure-base-image-windows-server-2025'
        $ids | Should -Contain 'azure-base-image-ubuntu-24.04'
        foreach ($b in $m.not_reproducible) { $b.owner_action | Should -Not -BeNullOrEmpty }
        foreach ($e in $m.entries) { $e.name | Should -Not -BeIn $ids }
    }
    It 'is exactly what New-AapManifest.ps1 generates' {
        $tmp = Join-Path $TestDrive 'regen.json'
        & (Join-Path $script:Common 'New-AapManifest.ps1') -OutPath $tmp
        $norm = { param($p) (Get-Content -Raw -LiteralPath $p | ConvertFrom-Json | ConvertTo-Json -Depth 10 -Compress) }
        (& $norm $tmp) | Should -BeExactly (& $norm $script:ManifestPath)
    }
    It 'validates against its schema with the contract validator' -Skip:(-not $HasPython) {
        $out = & python -I (Join-Path $PSScriptRoot 'validate_manifest.py') $script:Validator (Join-Path $script:Common 'artifacts.manifest.schema.json') $script:ManifestPath
        $LASTEXITCODE | Should -Be 0 -Because "$out"
    }
    It 'the schema validator rejects a floating version and an http url' -Skip:(-not $HasPython) {
        $doc = Get-Content -Raw -LiteralPath $script:ManifestPath | ConvertFrom-Json
        $doc.entries[0].version = 'latest'
        $bad = Join-Path $TestDrive 'bad1.json'
        $doc | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $bad
        $null = & python -I (Join-Path $PSScriptRoot 'validate_manifest.py') $script:Validator (Join-Path $script:Common 'artifacts.manifest.schema.json') $bad
        $LASTEXITCODE | Should -Be 1
        $doc = Get-Content -Raw -LiteralPath $script:ManifestPath | ConvertFrom-Json
        $doc.entries[0].urls = @('http://example.com/x')
        $doc | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $bad
        $null = & python -I (Join-Path $PSScriptRoot 'validate_manifest.py') $script:Validator (Join-Path $script:Common 'artifacts.manifest.schema.json') $bad
        $LASTEXITCODE | Should -Be 1
    }
    It 'rejects a manifest whose upstream hash file is missing or has no literal hash' {
        $m = Get-Content -Raw -LiteralPath $script:ManifestPath | ConvertFrom-Json
        $m.entries[1].hash.upstream_entry = 'nope'
        @(Test-AapManifest -Manifest $m) -join "`n" | Should -Match 'upstream_entry not in manifest'
    }
}

Describe 'version and source policy' {
    It 'rejects <v> as a version' -ForEach @(
        @{ v = 'latest' }, @{ v = 'stable' }, @{ v = '1.*' }, @{ v = 'main' }, @{ v = '2.0-nightly' }, @{ v = '' }
    ) {
        $e = New-Entry 'floaty' 'a.bin' "$($script:Base)/ok.bin" -Over @{ version = $v }
        $st = New-Staging
        { Invoke-Fetch $e $st } | Should -Throw 'AAP_VersionNotExact*'
        Test-Path -LiteralPath (Join-Path $st 'floaty') | Should -BeFalse
    }
    It 'rejects plain http to a non-loopback host even in test mode' {
        $e = New-Entry 'plain' 'a.bin' 'http://example.com/a.bin'
        { Invoke-Fetch $e (New-Staging) } | Should -Throw 'AAP_SchemeRejected*'
    }
    It 'rejects loopback http without the test switch' {
        $e = New-Entry 'plain' 'a.bin' "$($script:Base)/ok.bin"
        { Get-AapArtifact -Entry $e -StagingRoot (New-Staging) } | Should -Throw 'AAP_SchemeRejected*'
    }
    It 'rejects a file source without -AllowFileSource' {
        $src = Join-Path $TestDrive 'src.bin'; [IO.File]::WriteAllBytes($src, $script:OkBytes)
        $e = New-Entry 'filesrc' 'a.bin' ([Uri]$src).AbsoluteUri
        { Invoke-Fetch $e (New-Staging) } | Should -Throw 'AAP_SchemeRejected*'
        $a = Invoke-Fetch $e (New-Staging) @{ AllowFileSource = $true }
        $a.Provenance.outcome | Should -Be 'accepted'
    }
    It 'rejects credentials in a url' {
        $e = New-Entry 'cred' 'a.bin' 'https://user:pw@example.com/a.bin'
        { Get-AapArtifact -Entry $e -StagingRoot (New-Staging) } | Should -Throw 'AAP_*'
    }
}

Describe 'acquisition' {
    BeforeEach { $script:State.Hits.Clear() }

    It 'publishes a verified file with a provenance record' {
        $st = New-Staging
        $e = New-Entry 'good' 'good.bin' "$($script:Base)/ok.bin"
        $a = Invoke-Fetch $e $st
        $a.Path | Should -Exist
        "$($a.Path).part" | Should -Not -Exist
        $p = Get-Content -Raw -LiteralPath $a.ProvenancePath | ConvertFrom-Json
        $p.outcome | Should -Be 'accepted'
        $p.sha256 | Should -Be $script:OkSha
        $p.bytes | Should -Be $script:OkBytes.Length
        $p.hash.source | Should -Be 'literal'
        $p.hash.verified | Should -BeTrue
        $p.requested_url | Should -Be "$($script:Base)/ok.bin"
        $p.final_url | Should -Be "$($script:Base)/ok.bin"
        @($p.url_chain).Count | Should -Be 1
        $p.license.class | Should -Be 'open-source'
        $p.evidence_ref | Should -Not -BeNullOrEmpty
        (Get-Content -Raw -LiteralPath $a.ProvenancePath) | Should -Match '"started_at":\s+"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ"'
    }
    It 'rejects a hash mismatch and publishes nothing' {
        $st = New-Staging
        $e = New-Entry 'mismatch' 'm.bin' "$($script:Base)/ok.bin" ('0' * 64)
        { Invoke-Fetch $e $st } | Should -Throw 'AAP_HashMismatch*'
        $f = Get-AapStagedPath $st $e
        $f | Should -Not -Exist
        "$f.part" | Should -Not -Exist
        (Get-Rejected $st $e).reason | Should -Be 'AAP_HashMismatch'
        $script:State.Hits['/ok.bin'] | Should -Be 1 -Because 'a changed or corrupt body is not retried'
    }
    It 'rejects a changed upstream installer' {
        $st = New-Staging
        $e = New-Entry 'changed' 'c.bin' "$($script:Base)/changed.bin" $script:OkSha
        { Invoke-Fetch $e $st } | Should -Throw 'AAP_HashMismatch*'
        (Get-AapStagedPath $st $e) | Should -Not -Exist
    }
    It 'never records a query string (signed redirect targets) in provenance' {
        $e = New-Entry 'signed' 's.bin' "$($script:Base)/ok.bin?sig=SIGNEDVALUE123"
        $a = Invoke-Fetch $e (New-Staging)
        $raw = Get-Content -Raw -LiteralPath $a.ProvenancePath
        $raw | Should -Not -Match 'SIGNEDVALUE123'
        $a.Provenance.requested_url | Should -Be "$($script:Base)/ok.bin?<query-stripped>"
    }
    It 'rejects a body larger than the bound announced by the server' {        $st = New-Staging
        $e = New-Entry 'big1' 'b.bin' "$($script:Base)/big-announced"
        { Invoke-Fetch $e $st } | Should -Throw 'AAP_SizeExceeded*'
        (Get-AapStagedPath $st $e) + '.part' | Should -Not -Exist
    }
    It 'rejects a chunked body that grows past the bound' {
        $st = New-Staging
        $e = New-Entry 'big2' 'b.bin' "$($script:Base)/big-chunked"
        { Invoke-Fetch $e $st } | Should -Throw 'AAP_SizeExceeded*'
        (Get-AapStagedPath $st $e) | Should -Not -Exist
        (Get-AapStagedPath $st $e) + '.part' | Should -Not -Exist
    }
    It 'rejects an exact-size mismatch' {
        $e = New-Entry 'size' 's.bin' "$($script:Base)/ok.bin" -Over @{ size_bytes = 5 }
        { Invoke-Fetch $e (New-Staging) } | Should -Throw 'AAP_SizeMismatch*'
    }
    It 'rejects an unexpected content type' {
        $st = New-Staging
        $e = New-Entry 'html' 'h.bin' "$($script:Base)/page.html"
        { Invoke-Fetch $e $st } | Should -Throw 'AAP_ContentTypeRejected*'
        (Get-AapStagedPath $st $e) | Should -Not -Exist
    }
    It 'rejects a redirect to a host that is not allowlisted' {
        $st = New-Staging
        $e = New-Entry 'redir' 'r.bin' "$($script:Base)/redir-other"
        { Invoke-Fetch $e $st } | Should -Throw 'AAP_RedirectRejected*'
        $script:State.Hits.ContainsKey('/ok.bin') | Should -BeFalse -Because 'the redirect target is never requested'
        (Get-Rejected $st $e).reason | Should -Be 'AAP_RedirectRejected'
    }
    It 'follows a redirect on the same host and records the chain' {
        $e = New-Entry 'same' 'r.bin' "$($script:Base)/redir-same"
        $a = Invoke-Fetch $e (New-Staging)
        @($a.Provenance.url_chain).Count | Should -Be 2
        $a.Provenance.url_chain[0].status | Should -Be 302
        $a.Provenance.final_url | Should -Be "$($script:Base)/ok.bin"
    }
    It 'follows a redirect to an allowlisted host' {
        $e = New-Entry 'allow' 'r.bin' "$($script:Base)/redir-other" -Over @{ redirect_hosts = @('localhost') }
        $a = Invoke-Fetch $e (New-Staging)
        $a.Provenance.final_url | Should -Be "http://localhost:$($script:Port)/ok.bin"
    }
    It 'treats an interrupted download as unavailable after the bounded retries' {
        $st = New-Staging
        $e = New-Entry 'partial' 'p.bin' "$($script:Base)/partial.bin" -Over @{ size_max_bytes = 1000 }
        { Invoke-Fetch $e $st } | Should -Throw 'AAP_SourceUnavailable*2 attempt*'
        $script:State.Hits['/partial.bin'] | Should -Be 2
        (Get-AapStagedPath $st $e) | Should -Not -Exist
        (Get-AapStagedPath $st $e) + '.part' | Should -Not -Exist
        (Get-Rejected $st $e).attempts | Should -Be 2
    }
    It 'retries a transient failure and then succeeds' {
        $e = New-Entry 'flaky' 'f.bin' "$($script:Base)/flaky.bin"
        $a = Invoke-Fetch $e (New-Staging)
        $a.Provenance.attempts | Should -Be 2
    }
    It 'rejects when every retry fails (nothing listens)' {
        $st = New-Staging
        $e = New-Entry 'dead' 'd.bin' "$($script:ClosedBase)/ok.bin" -Over @{ retry = [ordered]@{ max_attempts = 3; backoff_seconds = 0; timeout_seconds = 5 } }
        { Invoke-Fetch $e $st } | Should -Throw 'AAP_SourceUnavailable*3 attempt*'
        (Get-Rejected $st $e).attempts | Should -Be 3
    }
    It 'does not retry a permanent 404' {
        $e = New-Entry 'gone' 'g.bin' "$($script:Base)/gone"
        { Invoke-Fetch $e (New-Staging) } | Should -Throw 'AAP_SourceUnavailable*404*'
        $script:State.Hits['/gone'] | Should -Be 1
    }
    It 'falls over to the next mirror' {
        $e = New-Entry 'mirror' 'm.bin' "$($script:ClosedBase)/ok.bin" -Over @{ urls = @("$($script:ClosedBase)/ok.bin", "$($script:Base)/ok.bin") }
        $a = Invoke-Fetch $e (New-Staging)
        $a.Provenance.final_url | Should -Be "$($script:Base)/ok.bin"
    }
    It 'ignores a stale partial file from an interrupted publication' {
        $st = New-Staging
        $e = New-Entry 'stale' 's.bin' "$($script:Base)/ok.bin"
        $f = Get-AapStagedPath $st $e
        New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
        [IO.File]::WriteAllBytes("$f.part", (Get-Ascii 'junk'))
        $a = Invoke-Fetch $e $st
        (Get-Sha ([IO.File]::ReadAllBytes($a.Path))) | Should -Be $script:OkSha
        "$f.part" | Should -Not -Exist
    }
    It 'replaces a corrupt staged file online and says so' {
        $st = New-Staging
        $e = New-Entry 'corrupt' 'c.bin' "$($script:Base)/ok.bin"
        $f = Get-AapStagedPath $st $e
        New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
        [IO.File]::WriteAllBytes($f, (Get-Ascii 'bit rot'))
        $a = Invoke-Fetch $e $st
        $a.Provenance.detail | Should -Match 'replaced an existing staged file'
        (Get-Sha ([IO.File]::ReadAllBytes($f))) | Should -Be $script:OkSha
    }
    It 'reuses a verified staged file without touching the network' {
        $st = New-Staging
        $e = New-Entry 'reuse' 'r.bin' "$($script:Base)/ok.bin"
        [void](Invoke-Fetch $e $st)
        $script:State.Hits.Clear()
        $a = Invoke-Fetch $e $st
        $a.Provenance.mode | Should -Be 'reuse'
        $script:State.Hits.Count | Should -Be 0
    }
    It 'verifies a sha512 entry' {
        $sha512 = Get-Sha $script:OkBytes 'SHA512'
        $h = [ordered]@{ algorithm = 'sha512'; source = 'literal'; value = $sha512; upstream_entry = $null; upstream_key = $null }
        $e = New-Entry 'five12' 'x.bin' "$($script:Base)/ok512.bin" -Over @{ hash = $h }
        $a = Invoke-Fetch $e (New-Staging)
        $a.Provenance.sha256 | Should -Be $script:OkSha
        $bad = [ordered]@{ algorithm = 'sha512'; source = 'literal'; value = ('0' * 128); upstream_entry = $null; upstream_key = $null }
        { Invoke-Fetch (New-Entry 'five12b' 'x.bin' "$($script:Base)/ok512.bin" -Over @{ hash = $bad }) (New-Staging) } | Should -Throw 'AAP_HashMismatch*'
    }
    It 'refuses a first-fetch entry unless recording is requested, then records it unverified' {
        $h = [ordered]@{ algorithm = 'sha256'; source = 'first-fetch'; value = $null; upstream_entry = $null; upstream_key = $null }
        $e = New-Entry 'tofu' 't.bin' "$($script:Base)/ok.bin" -Over @{ hash = $h }
        $st = New-Staging
        { Invoke-Fetch $e $st } | Should -Throw 'AAP_HashSourceMissing*'
        $script:State.Hits.Count | Should -Be 0
        $a = Invoke-Fetch $e $st @{ RecordFirstFetch = $true }
        $a.Provenance.hash.verified | Should -BeFalse
        $a.Provenance.hash.source | Should -Be 'first-fetch'
        $a.Provenance.sha256 | Should -Be $script:OkSha
    }
}

Describe 'upstream hash files' {
    BeforeEach { $script:State.Hits.Clear() }
    BeforeAll {
        function New-UpstreamManifest([string]$ArchiveKey = 'archive-a.bin', $Pinned = $null) {
            $script:State.Sums = ('{0}  {1}' -f ('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'), 'SUMS') + "`n" + ('{0}  {1}' -f $script:OkSha, 'archive-a.bin') + "`n"
            $sumsSha = Get-Sha (Get-Ascii $script:State.Sums)
            $sums = New-Entry 'sums' 'SUMS' "$($script:Base)/sums.txt" $sumsSha -Over @{ content_types = @('text/plain') }
            $h = [ordered]@{ algorithm = 'sha256'; source = 'upstream-file'; value = $Pinned; upstream_entry = 'sums'; upstream_key = $ArchiveKey }
            $arc = New-Entry 'archive' 'archive-a.bin' "$($script:Base)/ok.bin" -Over @{ hash = $h }
            [pscustomobject]@{ schema = 1; entries = @($sums, $arc); not_reproducible = @() }
        }
    }
    It 'verifies an archive against the staged upstream sums file and records the source' {
        $m = New-UpstreamManifest
        $st = New-Staging
        $r = Invoke-AapManifest -Manifest $m -StagingRoot $st -AllowLoopbackHttp
        $r.Complete | Should -BeTrue -Because (($r.Results.Message) -join ';')
        $p = Get-Content -Raw -LiteralPath ((Get-AapStagedPath $st $m.entries[1]) + '.provenance.json') | ConvertFrom-Json
        $p.hash.source | Should -Be 'upstream-file:sums'
        $p.hash.expected | Should -Be $script:OkSha
    }
    It 'fetches the hash file first even when it is listed last' {
        $m = New-UpstreamManifest
        $m.entries = @($m.entries[1], $m.entries[0])
        (Invoke-AapManifest -Manifest $m -StagingRoot (New-Staging) -AllowLoopbackHttp).Complete | Should -BeTrue
    }
    It 'rejects a pinned value that disagrees with the upstream file' {
        $m = New-UpstreamManifest -Pinned ('1' * 64)
        $r = Invoke-AapManifest -Manifest $m -StagingRoot (New-Staging) -AllowLoopbackHttp
        ($r.Results | Where-Object Name -eq 'archive').Reason | Should -Be 'AAP_HashSourceConflict'
    }
    It 'rejects a name that the upstream file does not list' {
        $m = New-UpstreamManifest -ArchiveKey 'other.bin'
        $r = Invoke-AapManifest -Manifest $m -StagingRoot (New-Staging) -AllowLoopbackHttp
        ($r.Results | Where-Object Name -eq 'archive').Reason | Should -Be 'AAP_HashSourceMissing'
    }
    It 'rejects the archive when the staged hash file was tampered with' {
        $m = New-UpstreamManifest
        $st = New-Staging
        [void](Invoke-AapManifest -Manifest $m -StagingRoot $st -AllowLoopbackHttp)
        Remove-Item -LiteralPath (Get-AapStagedPath $st $m.entries[1])
        [IO.File]::AppendAllText((Get-AapStagedPath $st $m.entries[0]), "deadbeef  archive-a.bin`n")
        { Get-AapArtifact -Entry $m.entries[1] -StagingRoot $st -Manifest $m -AllowLoopbackHttp } | Should -Throw 'AAP_Hash*'
    }
    It 'does not accept the empty-string self hash line as the hash of a real file' {
        $m = New-UpstreamManifest -ArchiveKey 'SUMS'
        $r = Invoke-AapManifest -Manifest $m -StagingRoot (New-Staging) -AllowLoopbackHttp
        ($r.Results | Where-Object Name -eq 'archive').Reason | Should -Be 'AAP_HashSourceMissing'
    }
}

Describe 'offline staging' {
    BeforeAll {
        function New-OfflineSet {
            $dead = $script:ClosedBase
            $sumsText = ('{0}  {1}' -f $script:OkSha, 'a.bin') + "`n"
            $sums = New-Entry 'sums' 'SUMS' "$dead/sums.txt" (Get-Sha (Get-Ascii $sumsText)) -Over @{ content_types = @('text/plain') }
            $lit = New-Entry 'lit' 'l.bin' "$dead/l.bin"
            $up = New-Entry 'up' 'a.bin' "$dead/a.bin" -Over @{ hash = [ordered]@{ algorithm = 'sha256'; source = 'upstream-file'; value = $null; upstream_entry = 'sums'; upstream_key = 'a.bin' } }
            $m = [pscustomobject]@{ schema = 1; entries = @($sums, $lit, $up); not_reproducible = @([pscustomobject]@{ id = 'media'; owner_action = 'owner supplies the ISO' }) }
            $st = New-Staging
            foreach ($x in @(@($sums, (Get-Ascii $sumsText)), @($lit, $script:OkBytes), @($up, $script:OkBytes))) {
                $f = Get-AapStagedPath $st $x[0]
                New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
                [IO.File]::WriteAllBytes($f, $x[1])
            }
            [pscustomobject]@{ Manifest = $m; Staging = $st }
        }
    }
    It 'accepts a complete staging set without any network' {
        $s = New-OfflineSet
        $r = Invoke-AapManifest -Manifest $s.Manifest -StagingRoot $s.Staging -Offline -AllowLoopbackHttp
        $r.Complete | Should -BeTrue
        @($r.Results | ForEach-Object Status) | Should -Not -Contain 'rejected'
        $r.Results[0].Name | Should -Be 'sums'
        @($r.Blockers).Count | Should -Be 1
        $p = Get-Content -Raw -LiteralPath ((Get-AapStagedPath $s.Staging $s.Manifest.entries[1]) + '.provenance.json') | ConvertFrom-Json
        $p.mode | Should -Be 'offline'
    }
    It 'rejects an incomplete staging set and names the missing file' {
        $s = New-OfflineSet
        Remove-Item -LiteralPath (Get-AapStagedPath $s.Staging $s.Manifest.entries[1])
        $r = Invoke-AapManifest -Manifest $s.Manifest -StagingRoot $s.Staging -Offline -AllowLoopbackHttp
        $r.Complete | Should -BeFalse
        ($r.Results | Where-Object Name -eq 'lit').Reason | Should -Be 'AAP_OfflineIncomplete'
        ($r.Results | Where-Object Name -eq 'up').Status | Should -Be 'accepted'
    }
    It 'rejects a corrupt staged file' {
        $s = New-OfflineSet
        [IO.File]::WriteAllBytes((Get-AapStagedPath $s.Staging $s.Manifest.entries[1]), (Get-Ascii 'corrupt'))
        $r = Invoke-AapManifest -Manifest $s.Manifest -StagingRoot $s.Staging -Offline -AllowLoopbackHttp
        ($r.Results | Where-Object Name -eq 'lit').Reason | Should -Be 'AAP_HashMismatch'
    }
    It 'treats a lone partial file as not staged' {
        $s = New-OfflineSet
        $f = Get-AapStagedPath $s.Staging $s.Manifest.entries[1]
        Move-Item -LiteralPath $f -Destination "$f.part"
        $r = Invoke-AapManifest -Manifest $s.Manifest -StagingRoot $s.Staging -Offline -AllowLoopbackHttp
        ($r.Results | Where-Object Name -eq 'lit').Reason | Should -Be 'AAP_OfflineIncomplete'
    }
    It 'rejects an oversized staged file' {
        $s = New-OfflineSet
        [IO.File]::WriteAllBytes((Get-AapStagedPath $s.Staging $s.Manifest.entries[1]), (New-Object byte[] 2000))
        $r = Invoke-AapManifest -Manifest $s.Manifest -StagingRoot $s.Staging -Offline -AllowLoopbackHttp
        ($r.Results | Where-Object Name -eq 'lit').Reason | Should -Be 'AAP_SizeExceeded'
    }
    It 'reports a missing upstream hash file instead of trusting the archive' {
        $s = New-OfflineSet
        Remove-Item -LiteralPath (Get-AapStagedPath $s.Staging $s.Manifest.entries[0])
        $r = Invoke-AapManifest -Manifest $s.Manifest -StagingRoot $s.Staging -Offline -AllowLoopbackHttp
        ($r.Results | Where-Object Name -eq 'up').Reason | Should -Be 'AAP_HashSourceMissing'
    }
}

Describe 'evidence record' {
    BeforeAll {
        function Test-Evidence([string]$Path) {
            $out = & python -I $script:Validator evidence-bundle $Path 2>&1
            [pscustomobject]@{ Exit = $LASTEXITCODE; Out = "$out" }
        }
    }
    BeforeEach { $script:State.Hits.Clear() }
    It 'an accepted acquisition validates as an evidence-bundle record' -Skip:(-not $HasPython) {
        $a = Invoke-Fetch (New-Entry 'ev1' 'e.bin' "$($script:Base)/ok.bin") (New-Staging)
        $out = Join-Path $TestDrive 'ev1.json'
        [void](New-AapEvidenceRecord -ProvenancePath $a.ProvenancePath -OutPath $out -HeadSha $script:Head -ManifestPath $script:ManifestPath)
        $v = Test-Evidence $out
        $v.Exit | Should -Be 0 -Because $v.Out
        $rec = Get-Content -Raw -LiteralPath $out | ConvertFrom-Json
        $rec.result | Should -Be 'pass'
        $rec.artifacts[0].sha256 | Should -Be $script:OkSha
        @($rec.artifacts).Count | Should -Be 2
    }
    It 'a rejected acquisition validates as a failed record, and as a pass when failure was the expectation' -Skip:(-not $HasPython) {
        $st = New-Staging
        $e = New-Entry 'ev2' 'e.bin' "$($script:Base)/ok.bin" ('0' * 64)
        try { Invoke-Fetch $e $st } catch { $null = $_ }
        $rej = (Get-AapStagedPath $st $e) + '.rejected.json'
        $a = Join-Path $TestDrive 'ev2a.json'; $b = Join-Path $TestDrive 'ev2b.json'
        [void](New-AapEvidenceRecord -ProvenancePath $rej -OutPath $a -HeadSha $script:Head)
        [void](New-AapEvidenceRecord -ProvenancePath $rej -OutPath $b -HeadSha $script:Head -ExpectedReason 'AAP_HashMismatch')
        (Test-Evidence $a).Exit | Should -Be 0
        (Test-Evidence $b).Exit | Should -Be 0
        (Get-Content -Raw -LiteralPath $a | ConvertFrom-Json).result | Should -Be 'fail'
        (Get-Content -Raw -LiteralPath $b | ConvertFrom-Json).result | Should -Be 'pass'
    }
    It 'a negative test passes only for the expected rejection reason' -Skip:(-not $HasPython) {
        # "corrupt input rejects" must not pass because the source was merely unreachable.
        $st = New-Staging
        $e = New-Entry 'ev6' 'e.bin' "$($script:ClosedBase)/ok.bin"
        try { Invoke-Fetch $e $st } catch { $null = $_ }
        $rej = (Get-AapStagedPath $st $e) + '.rejected.json'
        (Get-Content -Raw -LiteralPath $rej | ConvertFrom-Json).reason | Should -Be 'AAP_SourceUnavailable'
        $wrong = Join-Path $TestDrive 'ev6a.json'; $right = Join-Path $TestDrive 'ev6b.json'
        [void](New-AapEvidenceRecord -ProvenancePath $rej -OutPath $wrong -HeadSha $script:Head -ExpectedReason 'AAP_HashMismatch')
        [void](New-AapEvidenceRecord -ProvenancePath $rej -OutPath $right -HeadSha $script:Head -ExpectedReason 'AAP_SourceUnavailable')
        (Test-Evidence $wrong).Exit | Should -Be 0
        (Test-Evidence $right).Exit | Should -Be 0
        $w = Get-Content -Raw -LiteralPath $wrong | ConvertFrom-Json
        $w.result | Should -Be 'unknown'
        $w.oracle.observed | Should -Be 'unknown'
        $w.command | Should -Match 'expected-reason=AAP_HashMismatch observed-reason=AAP_SourceUnavailable'
        (Get-Content -Raw -LiteralPath $right | ConvertFrom-Json).result | Should -Be 'pass'
    }
    It 'an unexpected success is a failed negative test' -Skip:(-not $HasPython) {
        $a = Invoke-Fetch (New-Entry 'ev7' 'e.bin' "$($script:Base)/ok.bin") (New-Staging)
        $out = Join-Path $TestDrive 'ev7.json'
        [void](New-AapEvidenceRecord -ProvenancePath $a.ProvenancePath -OutPath $out -HeadSha $script:Head -ExpectedReason 'AAP_HashMismatch')
        (Test-Evidence $out).Exit | Should -Be 0
        (Get-Content -Raw -LiteralPath $out | ConvertFrom-Json).result | Should -Be 'fail'
    }
    It 'requires the expected reason to look like a rejection code' {
        $a = Invoke-Fetch (New-Entry 'ev8' 'e.bin' "$($script:Base)/ok.bin") (New-Staging)
        { New-AapEvidenceRecord -ProvenancePath $a.ProvenancePath -OutPath (Join-Path $TestDrive 'ev8.json') -HeadSha $script:Head -ExpectedReason 'hash mismatch' } | Should -Throw
    }
    It 'a first-fetch record is unknown, never a pass' -Skip:(-not $HasPython) {
        $h = [ordered]@{ algorithm = 'sha256'; source = 'first-fetch'; value = $null; upstream_entry = $null; upstream_key = $null }
        $a = Invoke-Fetch (New-Entry 'ev3' 'e.bin' "$($script:Base)/ok.bin" -Over @{ hash = $h }) (New-Staging) @{ RecordFirstFetch = $true }
        $out = Join-Path $TestDrive 'ev3.json'
        [void](New-AapEvidenceRecord -ProvenancePath $a.ProvenancePath -OutPath $out -HeadSha $script:Head)
        (Test-Evidence $out).Exit | Should -Be 0
        (Get-Content -Raw -LiteralPath $out | ConvertFrom-Json).result | Should -Be 'unknown'
    }
    It 'refuses a head that is not a full commit sha' {
        $a = Invoke-Fetch (New-Entry 'ev4' 'e.bin' "$($script:Base)/ok.bin") (New-Staging)
        { New-AapEvidenceRecord -ProvenancePath $a.ProvenancePath -OutPath (Join-Path $TestDrive 'ev4.json') -HeadSha 'abc123' } | Should -Throw '*40-hex*'
    }
    It 'holds no secret-shaped field names in provenance or evidence' {
        $a = Invoke-Fetch (New-Entry 'ev5' 'e.bin' "$($script:Base)/ok.bin") (New-Staging)
        $out = Join-Path $TestDrive 'ev5.json'
        [void](New-AapEvidenceRecord -ProvenancePath $a.ProvenancePath -OutPath $out -HeadSha $script:Head)
        foreach ($f in $a.ProvenancePath, $out) {
            $names = @([regex]::Matches((Get-Content -Raw -LiteralPath $f), '"([A-Za-z0-9_-]+)"\s*:') | ForEach-Object { $_.Groups[1].Value })
            @($names | Where-Object { $_ -match '(?i)token|secret|password|private_key|credential|jit_config|pem' }).Count | Should -Be 0
        }
    }
}

Describe 'first-fetch records' {
    BeforeAll {
        function New-FirstFetchEntry([string]$Url = "$($script:Base)/ok.bin") {
            $h = [ordered]@{ algorithm = 'sha256'; source = 'first-fetch'; value = $null; upstream_entry = $null; upstream_key = $null }
            New-Entry 'tofu' 't.bin' $Url -Over @{ hash = $h }
        }
        function Get-RecordPath($Staging, $Entry) { (Get-AapStagedPath $Staging $Entry) + '.first-fetch.json' }
        function Get-RawField([string]$Path, [string]$Field) {
            if ((Get-Content -Raw -LiteralPath $Path) -match ('"' + $Field + '":\s+"([^"]*)"')) { $Matches[1] } else { $null }
        }
    }
    BeforeEach { $script:State.Hits.Clear() }

    It 'records the hash seen by the first accepted download' {
        $st = New-Staging; $e = New-FirstFetchEntry
        [void](Invoke-Fetch $e $st @{ RecordFirstFetch = $true })
        $rec = Get-Content -Raw -LiteralPath (Get-RecordPath $st $e) | ConvertFrom-Json
        $rec.schema | Should -Be 'aap-first-fetch/1'
        $rec.hash | Should -Be $script:OkSha
        $rec.bytes | Should -Be $script:OkBytes.Length
    }
    It 'offline rejects a file overwritten after the first fetch, and the record survives the rejection' {
        $st = New-Staging; $e = New-FirstFetchEntry
        $a = Invoke-Fetch $e $st @{ RecordFirstFetch = $true }
        $before = Get-Content -Raw -LiteralPath (Get-RecordPath $st $e)
        [IO.File]::WriteAllBytes($a.Path, (Get-Ascii 'other bytes'))
        { Get-AapArtifact -Entry $e -StagingRoot $st -Offline -AllowLoopbackHttp } | Should -Throw 'AAP_HashMismatch*first-fetch-recorded*'
        (Get-Content -Raw -LiteralPath (Get-RecordPath $st $e)) | Should -BeExactly $before
        $a.ProvenancePath | Should -Not -Exist
        ($a.Path + '.rejected.json') | Should -Exist
    }
    It 'online repairs a damaged file from the same upstream bytes and leaves the record alone' {
        $st = New-Staging; $e = New-FirstFetchEntry
        $a = Invoke-Fetch $e $st @{ RecordFirstFetch = $true }
        $before = Get-Content -Raw -LiteralPath (Get-RecordPath $st $e)
        [IO.File]::WriteAllBytes($a.Path, (Get-Ascii 'bit rot'))
        $b = Invoke-Fetch $e $st
        $b.Provenance.detail | Should -Match 'replaced an existing staged file'
        $b.Provenance.hash.source | Should -Be 'first-fetch-recorded'
        $b.Provenance.hash.verified | Should -BeFalse
        (Get-Sha ([IO.File]::ReadAllBytes($b.Path))) | Should -Be $script:OkSha
        (Get-Content -Raw -LiteralPath (Get-RecordPath $st $e)) | Should -BeExactly $before
    }
    It 'online rejects an upstream that changed since the first fetch, even with -RecordFirstFetch, and keeps the record' {
        $st = New-Staging; $e = New-FirstFetchEntry
        $a = Invoke-Fetch $e $st @{ RecordFirstFetch = $true }
        $before = Get-Content -Raw -LiteralPath (Get-RecordPath $st $e)
        [IO.File]::WriteAllBytes($a.Path, (Get-Ascii 'bit rot'))
        $changed = New-FirstFetchEntry "$($script:Base)/changed.bin"
        { Invoke-Fetch $changed $st @{ RecordFirstFetch = $true } } | Should -Throw 'AAP_HashMismatch*'
        (Get-Content -Raw -LiteralPath (Get-RecordPath $st $e)) | Should -BeExactly $before
        $a.Path | Should -Not -Exist
    }
    It 'does not trust a staged file that has no record: offline says it is not staged' {
        $st = New-Staging; $e = New-FirstFetchEntry
        $f = Get-AapStagedPath $st $e
        New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
        [IO.File]::WriteAllBytes($f, $script:OkBytes)
        { Get-AapArtifact -Entry $e -StagingRoot $st -Offline -AllowLoopbackHttp } | Should -Throw 'AAP_OfflineIncomplete*first-fetch record*'
        ($f + '.provenance.json') | Should -Not -Exist
        $script:State.Hits.Count | Should -Be 0
    }
    It 'online without -RecordFirstFetch still refuses an unrecorded staged file and leaves it alone' {
        $st = New-Staging; $e = New-FirstFetchEntry
        $f = Get-AapStagedPath $st $e
        New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
        [IO.File]::WriteAllBytes($f, (Get-Ascii 'unknown origin'))
        { Invoke-Fetch $e $st } | Should -Throw 'AAP_HashSourceMissing*'
        (Get-Sha ([IO.File]::ReadAllBytes($f))) | Should -Be (Get-Sha (Get-Ascii 'unknown origin'))
    }
    It 'online with -RecordFirstFetch replaces an unrecorded staged file and records the new one' {
        $st = New-Staging; $e = New-FirstFetchEntry
        $f = Get-AapStagedPath $st $e
        New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
        [IO.File]::WriteAllBytes($f, (Get-Ascii 'unknown origin'))
        $a = Invoke-Fetch $e $st @{ RecordFirstFetch = $true }
        $a.Provenance.detail | Should -Match 'no first-fetch record'
        (Get-Sha ([IO.File]::ReadAllBytes($f))) | Should -Be $script:OkSha
        (Get-Content -Raw -LiteralPath (Get-RecordPath $st $e) | ConvertFrom-Json).hash | Should -Be $script:OkSha
    }
    It 'offline and reuse accept a file that matches the record, as unverified, and keep where it came from' {
        $st = New-Staging; $e = New-FirstFetchEntry
        $a = Invoke-Fetch $e $st @{ RecordFirstFetch = $true }
        $firstStart = Get-RawField $a.ProvenancePath 'started_at'
        $off = Get-AapArtifact -Entry $e -StagingRoot $st -Offline -AllowLoopbackHttp
        $off.Provenance.mode | Should -Be 'offline'
        $off.Provenance.hash.source | Should -Be 'first-fetch-recorded'
        $off.Provenance.hash.verified | Should -BeFalse
        $off.Provenance.requested_url | Should -Be "$($script:Base)/ok.bin"
        @($off.Provenance.url_chain).Count | Should -Be 1
        (Get-RawField $off.ProvenancePath 'acquired_at') | Should -Be $firstStart
        $script:State.Hits.Clear()
        $re = Invoke-Fetch $e $st
        $re.Provenance.mode | Should -Be 'reuse'
        $script:State.Hits.Count | Should -Be 0
        (Get-RawField $re.ProvenancePath 'acquired_at') | Should -Be $firstStart
    }
    It 'a deleted record makes offline report the file as not staged' {
        $st = New-Staging; $e = New-FirstFetchEntry
        [void](Invoke-Fetch $e $st @{ RecordFirstFetch = $true })
        Remove-Item -LiteralPath (Get-RecordPath $st $e)
        { Get-AapArtifact -Entry $e -StagingRoot $st -Offline -AllowLoopbackHttp } | Should -Throw 'AAP_OfflineIncomplete*'
    }
    It 'an invalid record is an error, not a chance to record again' {
        $st = New-Staging; $e = New-FirstFetchEntry
        [void](Invoke-Fetch $e $st @{ RecordFirstFetch = $true })
        [IO.File]::WriteAllText((Get-RecordPath $st $e), '{ "schema": "aap-first-fetch/1", "hash": "nothex" }')
        { Invoke-Fetch $e $st @{ RecordFirstFetch = $true } } | Should -Throw 'AAP_HashSourceMissing*not valid*'
    }
}

Describe 'timeouts' {
    BeforeEach { $script:State.Hits.Clear(); $script:State.Release = $false }
    AfterEach { $script:State.Release = $true; Start-Sleep -Milliseconds 500; $script:State.Release = $false }

    It 'bounds a body that stalls after the headers (a read cancellation token is not honoured on 5.1)' {
        $st = New-Staging
        $e = New-Entry 'stall' 's.bin' "$($script:Base)/stall.bin" -Over @{ retry = [ordered]@{ max_attempts = 1; backoff_seconds = 0; timeout_seconds = 2 } }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        { Invoke-Fetch $e $st } | Should -Throw 'AAP_SourceUnavailable*timed out*'
        $sw.Stop()
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 12
        $f = Get-AapStagedPath $st $e
        $f | Should -Not -Exist
        "$f.part" | Should -Not -Exist
    }
    It 'bounds a server that never sends headers' {
        $st = New-Staging
        $e = New-Entry 'stallh' 's.bin' "$($script:Base)/stall-headers" -Over @{ retry = [ordered]@{ max_attempts = 1; backoff_seconds = 0; timeout_seconds = 2 } }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        { Invoke-Fetch $e $st } | Should -Throw 'AAP_SourceUnavailable*'
        $sw.Stop()
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 12
    }
}

Describe 'selection and stale records' {
    BeforeAll { $script:Real = Read-AapManifest -Path $script:ManifestPath }
    BeforeEach { $script:State.Hits.Clear() }

    It 'rejects a -Name that is not in the manifest and fetches nothing' {
        $st = New-Staging
        { Invoke-AapManifest -Manifest $script:Real -StagingRoot $st -Name 'zccache-sha256sums', 'typo' -Offline } | Should -Throw "AAP_ManifestInvalid*'typo' is not in the manifest*"
        @(Get-ChildItem -LiteralPath $st).Count | Should -Be 0
    }
    It 'says so when the requested name is a documented blocker' {
        { Invoke-AapManifest -Manifest $script:Real -StagingRoot (New-Staging) -Name 'windows-server-2025-media' -Offline } | Should -Throw "*'windows-server-2025-media' is a documented blocker*"
    }
    It 'rejects a manifest with nothing to acquire' {
        $empty = [pscustomobject]@{ schema = 1; entries = @(); not_reproducible = @() }
        { Invoke-AapManifest -Manifest $empty -StagingRoot (New-Staging) } | Should -Throw 'AAP_ManifestInvalid*no entries*'
    }
    It 'makes the command-line script exit non-zero for a mistyped name' {
        $exe = (Get-Process -Id $PID).Path
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'   # Windows PowerShell 5.1 turns merged native stderr into a terminating error under 'Stop'
        try { $null = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Common 'Get-AapArtifact.ps1') -Manifest $script:ManifestPath -Staging (New-Staging) -Name 'typo' -Offline 2>&1 }
        finally { $ErrorActionPreference = $saved }
        $LASTEXITCODE | Should -Be 1
    }
    It 'a rejection removes the accepted provenance and an acceptance removes the rejection' {
        $st = New-Staging; $e = New-Entry 'stale' 's.bin' "$($script:Base)/ok.bin"
        $a = Invoke-Fetch $e $st
        $prov = $a.Path + '.provenance.json'; $rej = $a.Path + '.rejected.json'
        $prov | Should -Exist
        $rej | Should -Not -Exist
        [IO.File]::WriteAllBytes($a.Path, (Get-Ascii 'corrupt'))
        { Get-AapArtifact -Entry $e -StagingRoot $st -Offline -AllowLoopbackHttp } | Should -Throw 'AAP_HashMismatch*'
        $prov | Should -Not -Exist
        $rej | Should -Exist
        $b = Invoke-Fetch $e $st
        $b.Provenance.outcome | Should -Be 'accepted'
        $prov | Should -Exist
        $rej | Should -Not -Exist
    }
}

Describe 'relative paths' {
    BeforeEach { $script:State.Hits.Clear() }
    It 'resolve against the PowerShell location, not the process directory' {
        $work = New-Staging
        $elsewhere = New-Staging
        $saved = [Environment]::CurrentDirectory
        Push-Location -LiteralPath $work
        try {
            [Environment]::CurrentDirectory = $elsewhere
            $e = New-Entry 'rel' 'r.bin' "$($script:Base)/ok.bin"
            $a = Get-AapArtifact -Entry $e -StagingRoot 'stage' -AllowLoopbackHttp
            $a.Path | Should -Be (Join-Path $work 'stage\rel\1.0.0\r.bin')
            $a.ProvenancePath | Should -Exist
            $off = Get-AapArtifact -Entry $e -StagingRoot '.\stage\..\stage' -Offline -AllowLoopbackHttp
            $off.Provenance.mode | Should -Be 'offline'
            $man = [pscustomobject]@{ schema = 1; entries = @($e); not_reproducible = @() }
            (Invoke-AapManifest -Manifest $man -StagingRoot 'stage' -Offline -AllowLoopbackHttp).Complete | Should -BeTrue
            Copy-Item -LiteralPath $script:ManifestPath -Destination 'm.json'
            (Read-AapManifest -Path 'm.json').schema | Should -Be 1
            $ev = New-AapEvidenceRecord -ProvenancePath 'stage\rel\1.0.0\r.bin.provenance.json' -OutPath 'ev.json' -HeadSha $script:Head -ManifestPath 'm.json'
            $ev | Should -Be (Join-Path $work 'ev.json')
        } finally { [Environment]::CurrentDirectory = $saved; Pop-Location }
        (Join-Path $work 'ev.json') | Should -Exist
        Test-Path -LiteralPath (Join-Path $elsewhere 'stage') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $elsewhere 'ev.json') | Should -BeFalse
    }
}

Describe 'coverage of the P01 inputs' {
    BeforeAll {
        $script:Man = Read-AapManifest -Path $script:ManifestPath
        $script:Profiles = @('windows-2025-vs2026-x64', 'ubuntu-24.04-x64')
        function Get-InputsLines([string]$Profile) { [IO.File]::ReadAllLines((Join-Path $script:Repo "parity\baselines\$Profile\inputs.md")) }
        function Get-ScriptTable([string]$Profile) {
            $all = New-Object System.Collections.Generic.List[string]
            $sourced = New-Object System.Collections.Generic.List[string]
            foreach ($l in (Get-InputsLines $Profile)) {
                if ($l -match '^\| \d+ \| `([^`]+)` \| (.*)$') {
                    $all.Add($Matches[1])
                    if ($Matches[2] -notmatch '^\(no URL or helper source detected') { $sourced.Add($Matches[1]) }
                }
            }
            [pscustomobject]@{ All = $all.ToArray(); Sourced = $sourced.ToArray() }
        }
        function Get-PinnedTokens([string]$Profile) {
            $on = $false
            $tokens = New-Object System.Collections.Generic.List[string]
            foreach ($l in (Get-InputsLines $Profile)) {
                if ($l -like '## Version- or hash-pinned values*') { $on = $true; continue }
                if ($on -and $l -like 'Tool cache manifests*') { break }
                if ($on -and $l.StartsWith('| ') -and $l -notmatch '^\| Input ' -and $l -notmatch '^\|---') {
                    foreach ($m in [regex]::Matches($l.Split('|')[2], '\d+(?:\.\d+)+')) { $tokens.Add($m.Value) }
                }
            }
            $tokens | Sort-Object -Unique
        }
    }
    It 'accounts for every script of <p> that has an external source, as an entry or a blocker' -ForEach @(
        @{ p = 'windows-2025-vs2026-x64' }, @{ p = 'ubuntu-24.04-x64' }
    ) {
        $t = Get-ScriptTable $p
        $t.Sourced.Count | Should -BeGreaterThan 40 -Because 'the table was parsed'
        $covered = @(@($script:Man.entries) + @($script:Man.not_reproducible) | Where-Object { $p -in $_.profiles } | ForEach-Object { $_.scripts })
        $missing = @($t.Sourced | Where-Object { $_ -notin $covered })
        $missing.Count | Should -Be 0 -Because "not accounted for: $($missing -join ', ')"
    }
    It 'lists only scripts that exist in the script table of one of the profiles of the record' {
        $tables = @{}
        foreach ($pr in $script:Profiles) { $tables[$pr] = (Get-ScriptTable $pr).All }
        $unknown = New-Object System.Collections.Generic.List[string]
        foreach ($rec in @($script:Man.entries) + @($script:Man.not_reproducible)) {
            foreach ($s in $rec.scripts) {
                if (-not (@($rec.profiles | Where-Object { $s -in $tables[$_] }).Count)) { $unknown.Add($s) }
            }
        }
        $unknown.Count | Should -Be 0 -Because "unknown scripts: $($unknown -join ', ')"
    }
    It 'names every dotted version in the pinned-value table of <p>' -ForEach @(
        @{ p = 'windows-2025-vs2026-x64' }, @{ p = 'ubuntu-24.04-x64' }
    ) {
        $text = [regex]::Replace([IO.File]::ReadAllText($script:ManifestPath), '[0-9a-f]{32,}', '')
        $tokens = @(Get-PinnedTokens $p)
        $tokens.Count | Should -BeGreaterThan 8 -Because 'the table was parsed'
        $missing = @($tokens | Where-Object { -not $text.Contains($_) })
        $missing.Count | Should -Be 0 -Because "not named in the manifest: $($missing -join ', ')"
    }
    It 'carries the three inputs the code review found missing: Pester 5.9.0, Az 15.6.1 and Cobertura 2.1.1' {
        ($script:Man.entries | Where-Object { $_.name -eq 'pester' -and $_.version -eq '5.9.0' }) | Should -Not -BeNullOrEmpty
        ($script:Man.entries | Where-Object { $_.name -eq 'cobertura' -and $_.version -eq '2.1.1' }) | Should -Not -BeNullOrEmpty
        ($script:Man.not_reproducible | Where-Object { $_.id -eq 'powershell-gallery-modules' -and $_.reason -match 'Az 15\.6\.1' }) | Should -Not -BeNullOrEmpty
    }
    It 'explains every unknown licence and records the upstream licence of the zccache assets' {
        foreach ($e in $script:Man.entries) {
            if ($e.license.class -eq 'unknown' -or $e.license.redistribution -eq 'unknown') { $e.license.note.Length | Should -BeGreaterThan 20 -Because $e.name }
        }
        foreach ($e in @($script:Man.entries | Where-Object { $_.name -like 'zccache-*' })) {
            $e.license.class | Should -Be 'open-source' -Because $e.name
            $e.license.note | Should -Match 'AGPL-3.0-only' -Because $e.name
        }
        ($script:Man.entries | Where-Object { $_.name -eq 'docker-ce-install-helper' }).license.note | Should -Match 'MIT License'
    }
}

Describe 'real download (integration)' -Tag Network {
    It 'fetches Pester 5.9.0 from the PowerShell Gallery and verifies its SHA-512' -Skip:(-not $HasNet) {
        $m = Read-AapManifest -Path $script:ManifestPath
        $st = New-Staging
        $r = Invoke-AapManifest -Manifest $m -StagingRoot $st -Name 'pester'
        $r.Complete | Should -BeTrue -Because "$($r.Results.Message)"
        $e = $m.entries | Where-Object name -eq 'pester'
        $p = Get-Content -Raw -LiteralPath ((Get-AapStagedPath $st $e) + '.provenance.json') | ConvertFrom-Json
        $p.hash.algorithm | Should -Be 'sha512'
        $p.hash.verified | Should -BeTrue
        $p.bytes | Should -Be 327975
        $p.sha256 | Should -Be '5a0fd80b361600bf4bbd4c307c1fd01b17f11668bab19e657add41b00ad22ab9'
        ([Uri]$p.final_url).Host | Should -Be 'cdn.powershellgallery.com'
    }
    It 'fetches the zccache 1.15.6 SHA256SUMS from GitHub and confirms every pinned archive hash against it' -Skip:(-not $HasNet) {
        $m = Read-AapManifest -Path $script:ManifestPath
        $st = New-Staging
        $r = Invoke-AapManifest -Manifest $m -StagingRoot $st -Name 'zccache-sha256sums'
        $r.Complete | Should -BeTrue -Because "$($r.Results.Message)"
        $sums = $m.entries | Where-Object name -eq 'zccache-sha256sums'
        $p = Get-Content -Raw -LiteralPath ((Get-AapStagedPath $st $sums) + '.provenance.json') | ConvertFrom-Json
        $p.sha256 | Should -Be '6b5c2b96c99ab876814cedf3c6c1801d80dc2491fb823fcd8b58f3662c0231c3'
        $p.bytes | Should -Be 1636
        (Get-Content -Raw -LiteralPath ((Get-AapStagedPath $st $sums) + '.provenance.json')) | Should -Not -Match 'jwt|sig='
        @($p.url_chain).Count | Should -BeGreaterThan 1
        Write-Host "zccache SHA256SUMS: bytes=$($p.bytes) sha256=$($p.sha256) final_host=$(([Uri]$p.final_url).Host) type=$($p.content_type)"
        foreach ($e in @($m.entries | Where-Object { $_.hash.source -eq 'upstream-file' -and $_.hash.upstream_entry -eq 'zccache-sha256sums' })) {
            $x = Resolve-AapExpectedHash -Entry $e -Manifest $m -StagingRoot $st
            $x.Value | Should -Be $e.hash.value -Because $e.name
        }
    }
}
