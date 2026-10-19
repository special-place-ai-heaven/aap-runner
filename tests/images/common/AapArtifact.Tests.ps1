# P03 verified artifact acquisition. Pester 5 on Windows PowerShell 5.1 and PowerShell 7.
# Fixture files are served by a local HttpListener on the loopback addresses 127.0.0.1 and 127.0.0.2 or read from the
# temp directory. Two optional tests fetch real small files (tagged Network). Their reachability probes run inside that
# block, not at discovery, so a run that excludes the Network tag never contacts the network; with the tag, a test is
# skipped unless an HTTPS request to the real host gets an answer. Python tests use a python 3 that really runs (not the
# Microsoft Store stub) and are skipped when there is none.
# Every staging folder the tests create is locked to the current user, SYSTEM and Administrators, and the tests pass
# -TrustedSid (the current user) and -SkipAncestorCheck by default, because the ACLs above a temp folder are not ours.
# The 'staging trust' tests turn that off or use mocked ACLs to test the real rules. Tests that need a strict run (the
# evidence of a pass) mock the ACLs the module reads, so the temp folder counts as locked and every check still runs.

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:HasPython = [bool](Find-RealPython)
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:Py = Find-RealPython
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
    $script:Common = Join-Path $script:Repo 'images\common'
    $script:ManifestPath = Join-Path $script:Common 'artifacts.manifest.json'
    $script:Validator = Join-Path $script:Repo 'parity\contracts\validate.py'
    Import-Module (Join-Path $script:Common 'AapArtifact.psm1') -Force
    $script:Me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $script:Exe = (Get-Process -Id $PID).Path
    $script:DefaultKeys = @('Get-AapArtifact', 'Invoke-AapManifest') | ForEach-Object { "${_}:TrustedSid"; "${_}:SkipAncestorCheck" }
    foreach ($c in 'Get-AapArtifact', 'Invoke-AapManifest') {
        $global:PSDefaultParameterValues["${c}:TrustedSid"] = @($script:Me)
        $global:PSDefaultParameterValues["${c}:SkipAncestorCheck"] = $true
    }

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
    # A folder only the current user, SYSTEM and Administrators can use: what a locked staging root looks like.
    # -AlsoSid adds Modify for more principals, to build a root that is not locked. icacls is used instead of Set-Acl
    # because a second Set-Acl on the same folder failed here with a missing SeSecurityPrivilege.
    function Lock-Dir([string]$Path, [string[]]$AlsoSid = @()) {
        $grants = @("*$($script:Me):(OI)(CI)F", '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F') + @($AlsoSid | ForEach-Object { "*${_}:(OI)(CI)M" })
        & "$env:SystemRoot\System32\icacls.exe" $Path /inheritance:r /grant:r @grants | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "icacls failed for $Path (exit $LASTEXITCODE)" }
    }
    function New-Staging { $p = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $p | Out-Null; Lock-Dir $p; $p }
    function Get-Rejected($Staging, $Entry) { Get-Content -Raw -LiteralPath ((Get-AapStagedPath $Staging $Entry) + '.rejected.json') | ConvertFrom-Json }
    function Invoke-Fetch($Entry, $Staging, [hashtable]$More = @{}) {
        Get-AapArtifact -Entry $Entry -StagingRoot $Staging -AllowLoopbackHttp @More
    }
    # ACLs the module reads are mocked from SDDL text. A mock body cannot see variables of the test, so the ACL it returns
    # is built from SDDL embedded in the body. GoodSddl is what a locked folder looks like: SYSTEM and Administrators only.
    $script:GoodSddl = 'O:BAG:BAD:PAI(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)'
    function New-MockAcl([string]$Sddl) {
        [scriptblock]::Create("`$a = New-Object System.Security.AccessControl.DirectorySecurity; `$a.SetSecurityDescriptorSddlForm('$Sddl'); `$a")
    }
    function New-PathFilter([string]$Path) { [scriptblock]::Create("`$LiteralPath -eq '$($Path.Replace("'", "''"))'") }
    # A strict run: no trusted account and the ancestor check on. Use after `Mock Get-Acl -ModuleName AapArtifact -MockWith (New-MockAcl $script:GoodSddl)`
    # so that the temp folder, which the current user owns, counts as locked.
    function Invoke-StrictFetch($Entry, $Staging) {
        Get-AapArtifact -Entry $Entry -StagingRoot $Staging -AllowLoopbackHttp -TrustedSid @() -SkipAncestorCheck:$false
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
    # Loopback addresses only: 127.0.0.1 is the artifact host, 127.0.0.2 plays "another host". Never "localhost" or a wildcard.
    $script:Listener.Prefixes.Add("http://127.0.0.1:$($script:Port)/")
    $script:Listener.Prefixes.Add("http://127.0.0.2:$($script:Port)/")
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
                    '/redir-other' { $res.StatusCode = 302; $res.RedirectLocation = "http://127.0.0.2:$port/ok.bin"; $res.Close() }
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
    foreach ($k in $script:DefaultKeys) { $global:PSDefaultParameterValues.Remove($k) }
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
        $out = & $script:Py -B -I (Join-Path $PSScriptRoot 'validate_manifest.py') $script:Validator (Join-Path $script:Common 'artifacts.manifest.schema.json') $script:ManifestPath
        $LASTEXITCODE | Should -Be 0 -Because "$out"
    }
    It 'the schema validator rejects a floating version and an http url' -Skip:(-not $HasPython) {
        $doc = Get-Content -Raw -LiteralPath $script:ManifestPath | ConvertFrom-Json
        $doc.entries[0].version = 'latest'
        $bad = Join-Path $TestDrive 'bad1.json'
        $doc | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $bad
        $null = & $script:Py -B -I (Join-Path $PSScriptRoot 'validate_manifest.py') $script:Validator (Join-Path $script:Common 'artifacts.manifest.schema.json') $bad
        $LASTEXITCODE | Should -Be 1
        $doc = Get-Content -Raw -LiteralPath $script:ManifestPath | ConvertFrom-Json
        $doc.entries[0].urls = @('http://example.com/x')
        $doc | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $bad
        $null = & $script:Py -B -I (Join-Path $PSScriptRoot 'validate_manifest.py') $script:Validator (Join-Path $script:Common 'artifacts.manifest.schema.json') $bad
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
    It 'rejects credentials in a url with the manifest error, and not as a scheme or host problem' {
        $e = New-Entry 'cred' 'a.bin' 'https://user:pw@example.com/a.bin'
        { Get-AapArtifact -Entry $e -StagingRoot (New-Staging) } | Should -Throw 'AAP_ManifestInvalid: url carries credentials'
        $problems = @(Test-AapEntry -Entry $e)
        $problems.Count | Should -Be 1
        $problems[0] | Should -BeExactly 'AAP_ManifestInvalid: url carries credentials'
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
        $e = New-Entry 'allow' 'r.bin' "$($script:Base)/redir-other" -Over @{ redirect_hosts = @('127.0.0.2') }
        $a = Invoke-Fetch $e (New-Staging)
        $a.Provenance.final_url | Should -Be "http://127.0.0.2:$($script:Port)/ok.bin"
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
            $blocker = [pscustomobject]@{ id = 'media'; name = 'installation media'; profiles = @('ubuntu-24.04-x64'); blocker_kind = 'licensed-media'; reason = 'fixture'; owner_action = 'owner supplies the ISO'; scripts = @(); evidence_ref = 'fixture' }
            $m = [pscustomobject]@{ schema = 1; entries = @($sums, $lit, $up); not_reproducible = @($blocker) }
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
            $out = & $script:Py -B -I $script:Validator evidence-bundle $Path 2>&1
            [pscustomobject]@{ Exit = $LASTEXITCODE; Out = "$out" }
        }
    }
    BeforeEach { $script:State.Hits.Clear() }
    It 'an accepted acquisition from a strict run validates as an evidence-bundle record and is a pass' -Skip:(-not $HasPython) {
        Mock Get-Acl -ModuleName AapArtifact -MockWith (New-MockAcl $script:GoodSddl)
        $a = Invoke-StrictFetch (New-Entry 'ev1' 'e.bin' "$($script:Base)/ok.bin") (New-Staging)
        $a.Provenance.staging_check | Should -Be 'strict'
        $out = Join-Path $TestDrive 'ev1.json'
        [void](New-AapEvidenceRecord -ProvenancePath $a.ProvenancePath -OutPath $out -HeadSha $script:Head -ManifestPath $script:ManifestPath)
        $v = Test-Evidence $out
        $v.Exit | Should -Be 0 -Because $v.Out
        $rec = Get-Content -Raw -LiteralPath $out | ConvertFrom-Json
        $rec.result | Should -Be 'pass'
        $rec.command | Should -Not -Match 'staging_check'
        $rec.artifacts[0].sha256 | Should -Be $script:OkSha
        @($rec.artifacts).Count | Should -Be 2
    }
    It 'a relaxed run is never a pass in the evidence: the result is unknown and the command says staging_check=relaxed' -Skip:(-not $HasPython) {
        $a = Invoke-Fetch (New-Entry 'ev9' 'e.bin' "$($script:Base)/ok.bin") (New-Staging)   # the test defaults relax the staging checks
        $a.Verified | Should -BeTrue
        $a.Provenance.staging_check | Should -Be 'relaxed'
        $out = Join-Path $TestDrive 'ev9.json'
        [void](New-AapEvidenceRecord -ProvenancePath $a.ProvenancePath -OutPath $out -HeadSha $script:Head)
        $v = Test-Evidence $out
        $v.Exit | Should -Be 0 -Because $v.Out
        $rec = Get-Content -Raw -LiteralPath $out | ConvertFrom-Json
        $rec.result | Should -Be 'unknown'
        $rec.oracle.observed | Should -Be 'unknown'
        $rec.exit_status | Should -BeNullOrEmpty
        $rec.command | Should -Match ' staging_check=relaxed$'
        $rec.artifacts[0].sha256 | Should -Be $script:OkSha -Because 'the file is still listed by hash'
    }
    It 'a relaxed run still reports a failure as a failure, and says so in the command' -Skip:(-not $HasPython) {
        $st = New-Staging
        $e = New-Entry 'ev10' 'e.bin' "$($script:Base)/ok.bin" ('0' * 64)
        try { Invoke-Fetch $e $st } catch { $null = $_ }
        $rej = (Get-AapStagedPath $st $e) + '.rejected.json'
        (Get-Content -Raw -LiteralPath $rej | ConvertFrom-Json).staging_check | Should -Be 'relaxed'
        $out = Join-Path $TestDrive 'ev10.json'
        [void](New-AapEvidenceRecord -ProvenancePath $rej -OutPath $out -HeadSha $script:Head)
        (Test-Evidence $out).Exit | Should -Be 0
        $rec = Get-Content -Raw -LiteralPath $out | ConvertFrom-Json
        $rec.result | Should -Be 'fail'
        $rec.command | Should -Match ' staging_check=relaxed$'
    }
    It 'treats a provenance file that does not say how the staging folder was checked as relaxed' -Skip:(-not $HasPython) {
        Mock Get-Acl -ModuleName AapArtifact -MockWith (New-MockAcl $script:GoodSddl)
        $a = Invoke-StrictFetch (New-Entry 'ev11' 'e.bin' "$($script:Base)/ok.bin") (New-Staging)
        $doc = Get-Content -Raw -LiteralPath $a.ProvenancePath | ConvertFrom-Json
        $doc.PSObject.Properties.Remove('staging_check')
        ($doc | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $a.ProvenancePath -Encoding UTF8
        $out = Join-Path $TestDrive 'ev11.json'
        [void](New-AapEvidenceRecord -ProvenancePath $a.ProvenancePath -OutPath $out -HeadSha $script:Head)
        $rec = Get-Content -Raw -LiteralPath $out | ConvertFrom-Json
        $rec.result | Should -Be 'unknown'
        $rec.command | Should -Match 'staging_check=relaxed'
    }
    It 'makes no evidence from a strict provenance record that others can change' {
        Mock Get-Acl -ModuleName AapArtifact -MockWith (New-MockAcl $script:GoodSddl)
        $a = Invoke-StrictFetch (New-Entry 'ev12' 'e.bin' "$($script:Base)/ok.bin") (New-Staging)
        Mock Get-Acl -ModuleName AapArtifact -MockWith (New-MockAcl ($script:GoodSddl + '(A;;0x2;;;WD)')) -ParameterFilter (New-PathFilter $a.ProvenancePath)
        $out = Join-Path $TestDrive 'ev12.json'
        { New-AapEvidenceRecord -ProvenancePath $a.ProvenancePath -OutPath $out -HeadSha $script:Head } | Should -Throw 'AAP_StagingUntrusted: provenance record*grants S-1-1-0*'
        $out | Should -Not -Exist
    }
    It 'reports a strict staged file that others can change as a failure, never a pass' -Skip:(-not $HasPython) {
        Mock Get-Acl -ModuleName AapArtifact -MockWith (New-MockAcl $script:GoodSddl)
        $a = Invoke-StrictFetch (New-Entry 'ev13' 'e.bin' "$($script:Base)/ok.bin") (New-Staging)
        Mock Get-Acl -ModuleName AapArtifact -MockWith (New-MockAcl ($script:GoodSddl + '(A;;0x2;;;WD)')) -ParameterFilter (New-PathFilter $a.Path)
        $out = Join-Path $TestDrive 'ev13.json'
        [void](New-AapEvidenceRecord -ProvenancePath $a.ProvenancePath -OutPath $out -HeadSha $script:Head)
        $v = Test-Evidence $out
        $v.Exit | Should -Be 0 -Because $v.Out
        $rec = Get-Content -Raw -LiteralPath $out | ConvertFrom-Json
        $rec.result | Should -Be 'fail'
        $rec.oracle.observed | Should -Be 'failure'
        $rec.command | Should -Match 'observed-reason=AAP_StagingUntrusted'
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
        Mock Get-Acl -ModuleName AapArtifact -MockWith (New-MockAcl $script:GoodSddl)
        $a = Invoke-StrictFetch (New-Entry 'ev7' 'e.bin' "$($script:Base)/ok.bin") (New-Staging)
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
    It 'keeps a good staged file when the online re-download fails or finds a changed upstream' {
        $st = New-Staging; $e = New-FirstFetchEntry
        $a = Invoke-Fetch $e $st @{ RecordFirstFetch = $true }
        $record = Get-Content -Raw -LiteralPath (Get-RecordPath $st $e)
        { Invoke-Fetch (New-FirstFetchEntry "$($script:ClosedBase)/ok.bin") $st } | Should -Throw 'AAP_SourceUnavailable*'
        (Get-Sha ([IO.File]::ReadAllBytes($a.Path))) | Should -Be $script:OkSha -Because 'a network error must not cost the staged file'
        ($a.Path + '.part') | Should -Not -Exist
        { Invoke-Fetch (New-FirstFetchEntry "$($script:Base)/changed.bin") $st } | Should -Throw 'AAP_HashMismatch*'
        (Get-Sha ([IO.File]::ReadAllBytes($a.Path))) | Should -Be $script:OkSha -Because 'a changed upstream does not replace the file the record vouches for'
        (Get-Content -Raw -LiteralPath (Get-RecordPath $st $e)) | Should -BeExactly $record
        ($a.Path + '.rejected.json') | Should -Exist
        $a.ProvenancePath | Should -Not -Exist
        $again = Invoke-Fetch $e $st
        $again.Provenance.detail | Should -Match 'downloaded again'
        $again.Verified | Should -BeFalse
        ($a.Path + '.rejected.json') | Should -Not -Exist
        (Get-Sha ([IO.File]::ReadAllBytes($a.Path))) | Should -Be $script:OkSha
    }
    It 'keeps an unrecorded staged file when the download fails, and replaces it when one succeeds' {
        $st = New-Staging; $e = New-FirstFetchEntry
        $f = Get-AapStagedPath $st $e
        New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
        [IO.File]::WriteAllBytes($f, (Get-Ascii 'unknown origin'))
        { Invoke-Fetch (New-FirstFetchEntry "$($script:ClosedBase)/ok.bin") $st @{ RecordFirstFetch = $true } } | Should -Throw 'AAP_SourceUnavailable*'
        (Get-Sha ([IO.File]::ReadAllBytes($f))) | Should -Be (Get-Sha (Get-Ascii 'unknown origin'))
        $a = Invoke-Fetch $e $st @{ RecordFirstFetch = $true }
        (Get-Sha ([IO.File]::ReadAllBytes($f))) | Should -Be $script:OkSha
        $a.Provenance.detail | Should -Match 'no first-fetch record'
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
    It 'offline accepts a file that matches the record, as unverified, and keeps where it came from; online never reuses it' {
        $st = New-Staging; $e = New-FirstFetchEntry
        $a = Invoke-Fetch $e $st @{ RecordFirstFetch = $true }
        $firstStart = Get-RawField $a.ProvenancePath 'started_at'
        $off = Get-AapArtifact -Entry $e -StagingRoot $st -Offline -AllowLoopbackHttp
        $off.Provenance.mode | Should -Be 'offline'
        $off.Provenance.hash.source | Should -Be 'first-fetch-recorded'
        $off.Provenance.hash.verified | Should -BeFalse
        $off.Verified | Should -BeFalse
        $off.Provenance.requested_url | Should -Be "$($script:Base)/ok.bin"
        @($off.Provenance.url_chain).Count | Should -Be 1
        (Get-RawField $off.ProvenancePath 'acquired_at') | Should -Be $firstStart
        $script:State.Hits.Clear()
        $re = Invoke-Fetch $e $st
        $re.Provenance.mode | Should -Be 'online'
        $script:State.Hits['/ok.bin'] | Should -Be 1 -Because 'a first-fetch entry is downloaded again on every online run'
        $re.Provenance.detail | Should -Match 'downloaded again'
        $re.Verified | Should -BeFalse
        @($re.Provenance.url_chain).Count | Should -BeGreaterThan 0
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
        try { $null = & $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $script:Common 'Get-AapArtifact.ps1') -Manifest $script:ManifestPath -Staging (New-Staging) -Name 'typo' -Offline 2>&1 }
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
    It 'pins every input that has an immutable source, and leaves only the Docker engine zip as first-fetch' {
        $ff = @($script:Man.entries | Where-Object { $_.hash.source -eq 'first-fetch' } | ForEach-Object name)
        $ff.Count | Should -Be 1
        $ff[0] | Should -Be 'docker-engine-windows-static'
        foreach ($n in 'docker-ce-install-helper', 'android-commandlinetools-linux', 'containernetworking-plugins') {
            $en = $script:Man.entries | Where-Object name -eq $n
            $en.hash.source | Should -Be 'literal' -Because $n
            $en.size_bytes | Should -BeGreaterThan 0 -Because $n
        }
    }
    It 'carries the exact archive sizes and cites the SDK index for both Android command-line tools' {
        $win = $script:Man.entries | Where-Object name -eq 'android-commandlinetools-win'
        $lin = $script:Man.entries | Where-Object name -eq 'android-commandlinetools-linux'
        $win.size_bytes | Should -Be 143040480
        $lin.size_bytes | Should -Be 153607504
        $win.note | Should -Match 'repository2-1\.xml'
        $win.note | Should -Match '54a582f3bf73e04253602f2d1c80bd5868aac115'
        $lin.note | Should -Match 'repository2-1\.xml'
        $lin.note | Should -Match 'd313adb7aedccf6cf0cfca51ec180f0059f5f8f8'
    }
    It 'names the commit and the git blob id of the pinned Docker CE helper, so the hash and the commit tree describe one file' {
        $en = $script:Man.entries | Where-Object name -eq 'docker-ce-install-helper'
        $en.version | Should -Be '8ea2a92d8dfa7815abcf5cc44a756a0ac3d0f513'
        $en.urls[0] | Should -Match '/8ea2a92d8dfa7815abcf5cc44a756a0ac3d0f513/'
        $en.hash.value | Should -Be '16e1e920eca45ead4dcb41b55bb6721b87d590452372bfebd2aad6aca9d2fca1'
        $en.note | Should -Match '8ea2a92'
        $en.note | Should -Match '4c29230619dbe2cb4f90f2c4b637b6db02906332'
    }
    It 'cites the signed Ubuntu archive chain for the containernetworking-plugins pin' {
        $en = $script:Man.entries | Where-Object name -eq 'containernetworking-plugins'
        $en.hash.value | Should -Be 'ce5852960eec1b1026c0f4ef8dee383cb99906ce54c12158d65e46417ba2decf'
        $en.size_bytes | Should -Be 7045220
        $en.note | Should -Match 'dists/noble/InRelease'
        $en.note | Should -Match 'F6EC B376 2474 EDA9 D21B 7022 8719 20D1 991B C93C'
    }
}

Describe 'staging trust' {
    BeforeAll {
        $script:Links = New-Object System.Collections.Generic.List[string]
        function New-Victim {
            $v = Join-Path $TestDrive ('victim-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $v | Out-Null
            $s = Join-Path $v 'sentinel.txt'
            [IO.File]::WriteAllText($s, 'untouched')
            [pscustomobject]@{ Dir = $v; Sentinel = $s }
        }
        # -Value is the target on both hosts (-Target is an alias on 7 only).
        function New-Junction([string]$Link, [string]$Target) {
            $null = New-Item -ItemType Junction -Path $Link -Value $Target
            $script:Links.Add($Link)
        }
        function Assert-Untouched($Victim) {
            (@(Get-ChildItem -LiteralPath $Victim.Dir -Force | ForEach-Object Name) -join ',') | Should -Be 'sentinel.txt'
            [IO.File]::ReadAllText($Victim.Sentinel) | Should -Be 'untouched'
        }
        # A folder that every local account can do anything in, as D:\ is on the lab host. icacls, not Set-Acl (see Lock-Dir).
        function Grant-Everyone([string]$Path) {
            & "$env:SystemRoot\System32\icacls.exe" $Path /grant '*S-1-1-0:(OI)(CI)F' | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "icacls failed for $Path (exit $LASTEXITCODE)" }
        }
        # One file that every local account can do anything with, one that only the trusted accounts can use, and how many
        # entries for Everyone a file or folder carries.
        function Grant-EveryoneFile([string]$Path) {
            & "$env:SystemRoot\System32\icacls.exe" $Path /grant '*S-1-1-0:F' | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "icacls failed for $Path (exit $LASTEXITCODE)" }
        }
        function Lock-File([string]$Path) {
            & "$env:SystemRoot\System32\icacls.exe" $Path /inheritance:r /grant:r "*$($script:Me):F" '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "icacls failed for $Path (exit $LASTEXITCODE)" }
        }
        function Get-EveryoneEntries([string]$Path) { @((Get-Acl -LiteralPath $Path).Access | Where-Object { $_.IdentityReference.Value -eq 'Everyone' }).Count }
        function New-TofuEntry2([string]$Name) {
            New-Entry $Name 'a.bin' "$($script:Base)/ok.bin" -Over @{ hash = [ordered]@{ algorithm = 'sha256'; source = 'first-fetch'; value = $null; upstream_entry = $null; upstream_key = $null } }
        }
    }
    BeforeEach { $script:State.Hits.Clear() }
    AfterEach {
        # Directory.Delete without recursion removes a junction and leaves its target alone; Remove-Item -Recurse would
        # follow it on Windows PowerShell 5.1.
        foreach ($l in $script:Links) { [IO.Directory]::Delete($l) }
        $script:Links.Clear()
    }

    It 'refuses a staging root that is a junction, and nothing is written through it' {
        $victim = New-Victim
        $root = Join-Path $TestDrive 'root-link'
        New-Junction $root $victim.Dir
        $e = New-Entry 'jroot' 'a.bin' "$($script:Base)/ok.bin"
        { Invoke-Fetch $e $root } | Should -Throw 'AAP_StagingLink: staging root*is a junction or symbolic link'
        $man = [pscustomobject]@{ schema = 1; entries = @($e); not_reproducible = @() }
        { Invoke-AapManifest -Manifest $man -StagingRoot $root -AllowLoopbackHttp } | Should -Throw 'AAP_StagingLink: staging root*'
        Assert-Untouched $victim
        $script:State.Hits.Count | Should -Be 0 -Because 'nothing is fetched for a root that cannot be trusted'
    }
    It 'refuses a name folder that is a junction' {
        $victim = New-Victim; $root = New-Staging
        $e = New-Entry 'jname' 'a.bin' "$($script:Base)/ok.bin"
        New-Junction (Join-Path $root 'jname') $victim.Dir
        { Invoke-Fetch $e $root } | Should -Throw 'AAP_StagingLink: name folder*is a junction or symbolic link*'
        Assert-Untouched $victim
        $script:State.Hits.Count | Should -Be 0
    }
    It 'refuses a version folder that is a junction' {
        $victim = New-Victim; $root = New-Staging
        $e = New-Entry 'jver' 'a.bin' "$($script:Base)/ok.bin"
        New-Item -ItemType Directory -Path (Join-Path $root 'jver') | Out-Null
        New-Junction (Join-Path $root 'jver\1.0.0') $victim.Dir
        { Invoke-Fetch $e $root } | Should -Throw 'AAP_StagingLink: version folder*is a junction or symbolic link*'
        Assert-Untouched $victim
        $script:State.Hits.Count | Should -Be 0
    }
    It 'refuses a link in place of <what> and writes nothing through it' -ForEach @(
        @{ what = 'the staged file'; suffix = ''; tofu = $false }
        @{ what = 'the partial download'; suffix = '.part'; tofu = $false }
        @{ what = 'the provenance record'; suffix = '.provenance.json'; tofu = $false }
        @{ what = 'the first-fetch record'; suffix = '.first-fetch.json'; tofu = $true }
    ) {
        $victim = New-Victim; $root = New-Staging
        $e = if ($tofu) { New-TofuEntry2 'jitem' } else { New-Entry 'jitem' 'a.bin' "$($script:Base)/ok.bin" }
        $f = Get-AapStagedPath $root $e
        New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
        New-Junction ($f + $suffix) $victim.Dir
        { Invoke-Fetch $e $root @{ RecordFirstFetch = $true } } | Should -Throw 'AAP_StagingLink*'
        Assert-Untouched $victim
    }
    It 'refuses a symbolic link planted in place of the staged file, online and offline' {
        $victim = New-Victim; $root = New-Staging
        $e = New-Entry 'jsym' 'a.bin' "$($script:Base)/ok.bin"
        $f = Get-AapStagedPath $root $e
        New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
        # cmd's mklink, not New-Item -ItemType SymbolicLink: Windows PowerShell 5.1 insists on elevation for the latter,
        # while mklink works without it when Developer Mode is on, so the test runs on both hosts.
        & "$env:SystemRoot\System32\cmd.exe" /d /c mklink "$f" "$($victim.Sentinel)" | Out-Null
        if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because 'creating a symbolic link needs Developer Mode or elevation'; return }
        try {
            { Invoke-Fetch $e $root } | Should -Throw 'AAP_StagingLink: staged file*'
            { Get-AapArtifact -Entry $e -StagingRoot $root -Offline -AllowLoopbackHttp } | Should -Throw 'AAP_StagingLink: staged file*'
            [IO.File]::ReadAllText($victim.Sentinel) | Should -Be 'untouched'
        } finally { [IO.File]::Delete($f) }
    }
    It 'refuses a staging root that lets Everyone write, and creates nothing in it' {
        $root = New-Staging
        Lock-Dir $root -AlsoSid 'S-1-1-0'
        $e = New-Entry 'jacl' 'a.bin' "$($script:Base)/ok.bin"
        { Invoke-Fetch $e $root } | Should -Throw 'AAP_StagingUntrusted: staging root*grants S-1-1-0*'
        @(Get-ChildItem -LiteralPath $root -Force).Count | Should -Be 0
        $script:State.Hits.Count | Should -Be 0
    }
    It 'trusts only SYSTEM, Administrators and TrustedInstaller unless an account is named' {
        if ($script:Me -in @('S-1-5-18', 'S-1-5-32-544')) { Set-ItResult -Skipped -Because 'the tests run as an account that is trusted by default'; return }
        $root = New-Staging
        $e = New-Entry 'jown' 'a.bin' "$($script:Base)/ok.bin"
        { Get-AapArtifact -Entry $e -StagingRoot $root -AllowLoopbackHttp -TrustedSid @() -SkipAncestorCheck } | Should -Throw "AAP_StagingUntrusted: *$($script:Me)*"
        { Get-AapArtifact -Entry $e -StagingRoot $root -AllowLoopbackHttp -TrustedSid $script:Me -SkipAncestorCheck } | Should -Not -Throw
        (Get-Content -Raw -LiteralPath ((Get-AapStagedPath $root $e) + '.provenance.json') | ConvertFrom-Json).staging_check | Should -Be 'relaxed'
    }

    It 'refuses a root that grants <who> the right to <what>' -ForEach @(
        @{ who = 'Everyone'; what = 'write data'; ace = '(A;;0x2;;;WD)'; sid = 'S-1-1-0' }
        @{ who = 'Users'; what = 'create folders'; ace = '(A;;0x4;;;BU)'; sid = 'S-1-5-32-545' }
        @{ who = 'Users'; what = 'write attributes'; ace = '(A;;0x100;;;BU)'; sid = 'S-1-5-32-545' }
        @{ who = 'Authenticated Users'; what = 'delete children'; ace = '(A;;0x40;;;AU)'; sid = 'S-1-5-11' }
        @{ who = 'Everyone'; what = 'delete the root'; ace = '(A;;0x10000;;;WD)'; sid = 'S-1-1-0' }
        @{ who = 'Users'; what = 'change permissions'; ace = '(A;;0x40000;;;BU)'; sid = 'S-1-5-32-545' }
        @{ who = 'Users'; what = 'take ownership'; ace = '(A;;0x80000;;;BU)'; sid = 'S-1-5-32-545' }
        @{ who = 'Everyone'; what = 'do anything (GENERIC_ALL)'; ace = '(A;;GA;;;WD)'; sid = 'S-1-1-0' }
        @{ who = 'Everyone'; what = 'write (GENERIC_WRITE)'; ace = '(A;;GW;;;WD)'; sid = 'S-1-1-0' }
    ) {
        $root = New-Staging
        Mock Get-Acl -ModuleName AapArtifact -MockWith (New-MockAcl ($script:GoodSddl + $ace))
        $p = @(Get-AapStagingProblems -Root $root -SkipAncestorCheck)
        $p.Count | Should -Be 1
        $p[0].Code | Should -Be 'AAP_StagingUntrusted'
        $p[0].Text | Should -Match ([regex]::Escape("staging root $root grants $sid"))
    }
    It 'accepts a root only SYSTEM and Administrators can use, and skips deny entries and inherit-only entries' {
        $root = New-Staging
        Mock Get-Acl -ModuleName AapArtifact -MockWith (New-MockAcl ($script:GoodSddl + '(D;;0x10000;;;WD)(A;OICIIO;GA;;;WD)(A;;0x1200a9;;;BU)'))
        @(Get-AapStagingProblems -Root $root -SkipAncestorCheck).Count | Should -Be 0
    }
    It 'accepts a real folder that the operating system locks (the Windows folder), so the rules are not only tested on mocks' {
        @(Get-AapStagingProblems -Root $env:SystemRoot -SkipAncestorCheck).Count | Should -Be 0
    }
    It 'refuses a root owned by someone else unless that account is trusted explicitly' {
        $root = New-Staging
        $stranger = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
        Mock Get-Acl -ModuleName AapArtifact -MockWith (New-MockAcl "O:${stranger}G:BAD:PAI(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)")
        $p = @(Get-AapStagingProblems -Root $root -SkipAncestorCheck)
        $p.Count | Should -Be 1
        $p[0].Text | Should -Match 'owner S-1-5-21-1111111111-2222222222-3333333333-1001 of staging root .* is not SYSTEM, Administrators or TrustedInstaller'
        @(Get-AapStagingProblems -Root $root -SkipAncestorCheck -TrustedSid $stranger).Count | Should -Be 0
    }
    It 'refuses a root with no DACL and a root with an ACE that is not a plain allow or deny' {
        $root = New-Staging
        Mock Get-Acl -ModuleName AapArtifact -MockWith (New-MockAcl 'O:BAG:BA')
        (@(Get-AapStagingProblems -Root $root -SkipAncestorCheck) | ForEach-Object Text) -join "`n" | Should -Match 'has no DACL'
        Mock Get-Acl -ModuleName AapArtifact -MockWith (New-MockAcl 'O:BAG:BAD:(OA;;RPWP;c9651a32-5a0b-4e8c-9a55-6b9a0a0a0a0a;;BU)')
        (@(Get-AapStagingProblems -Root $root -SkipAncestorCheck) | ForEach-Object Text) -join "`n" | Should -Match 'not a plain allow or deny'
    }
    It 'refuses an ancestor that grants <who> the right to <what>' -ForEach @(
        @{ who = 'Everyone'; what = 'delete it'; ace = '(A;;0x10000;;;WD)'; sid = 'S-1-1-0' }
        @{ who = 'Authenticated Users'; what = 'delete its children'; ace = '(A;;0x40;;;AU)'; sid = 'S-1-5-11' }
        @{ who = 'Users'; what = 'change its permissions'; ace = '(A;;0x40000;;;BU)'; sid = 'S-1-5-32-545' }
        @{ who = 'Users'; what = 'take ownership'; ace = '(A;;0x80000;;;BU)'; sid = 'S-1-5-32-545' }
        @{ who = 'Everyone'; what = 'do anything (GENERIC_ALL)'; ace = '(A;;GA;;;WD)'; sid = 'S-1-1-0' }
    ) {
        $root = New-Staging
        $parent = Split-Path -Parent $root
        Mock Get-Acl -ModuleName AapArtifact -MockWith (New-MockAcl $script:GoodSddl)
        Mock Get-Acl -ModuleName AapArtifact -MockWith (New-MockAcl ($script:GoodSddl + $ace)) -ParameterFilter (New-PathFilter $parent)
        $p = @(Get-AapStagingProblems -Root $root)
        $p.Count | Should -Be 1
        $p[0].Code | Should -Be 'AAP_StagingUntrusted'
        $p[0].Text | Should -Match ([regex]::Escape("ancestor $parent grants $sid"))
    }
    It 'accepts the default drive-root entries and write-attributes on an ancestor' {
        $root = New-Staging
        $parent = Split-Path -Parent $root
        Mock Get-Acl -ModuleName AapArtifact -MockWith (New-MockAcl $script:GoodSddl)
        Mock Get-Acl -ModuleName AapArtifact -MockWith (New-MockAcl ($script:GoodSddl + '(A;;0x4;;;AU)(A;OICIIO;0x1301bf;;;AU)(A;OICI;0x1200a9;;;BU)(A;;0x100;;;BU)')) -ParameterFilter (New-PathFilter $parent)
        @(Get-AapStagingProblems -Root $root).Count | Should -Be 0
    }
    It 'refuses an ancestor owned by someone else, and one with no DACL' {
        $root = New-Staging
        $parent = Split-Path -Parent $root
        Mock Get-Acl -ModuleName AapArtifact -MockWith (New-MockAcl $script:GoodSddl)
        Mock Get-Acl -ModuleName AapArtifact -MockWith (New-MockAcl 'O:S-1-5-21-1111111111-2222222222-3333333333-1001G:BAD:PAI(A;OICI;FA;;;BA)') -ParameterFilter (New-PathFilter $parent)
        (@(Get-AapStagingProblems -Root $root) | ForEach-Object Text) -join "`n" | Should -Match 'is not SYSTEM, Administrators or TrustedInstaller'
        Mock Get-Acl -ModuleName AapArtifact -MockWith (New-MockAcl 'O:BAG:BA') -ParameterFilter (New-PathFilter $parent)
        (@(Get-AapStagingProblems -Root $root) | ForEach-Object Text) -join "`n" | Should -Match "ancestor $([regex]::Escape($parent)) has no DACL"
    }
    It 'refuses an ancestor that is a junction without reading its ACL' {
        $victim = New-Victim
        $link = Join-Path $TestDrive 'anc-link'
        New-Junction $link $victim.Dir
        New-Item -ItemType Directory -Path (Join-Path $victim.Dir 'stage') | Out-Null
        $root = Join-Path $link 'stage'
        Mock Get-Acl -ModuleName AapArtifact -MockWith (New-MockAcl $script:GoodSddl)
        $p = @(Get-AapStagingProblems -Root $root)
        @($p | Where-Object { $_.Code -eq 'AAP_StagingLink' -and $_.Text -eq "ancestor $link is a junction or symbolic link" }).Count | Should -Be 1
        Should -Invoke Get-Acl -ModuleName AapArtifact -Times 0 -Exactly -ParameterFilter (New-PathFilter $link)
    }
    It 'does not create a missing root below an ancestor that others can delete' {
        $root = Join-Path $TestDrive 'not-yet'
        Mock Get-Acl -ModuleName AapArtifact -MockWith (New-MockAcl ($script:GoodSddl + '(A;;0x10000;;;WD)'))
        { Assert-AapStagingRoot -Root $root } | Should -Throw 'AAP_StagingUntrusted: ancestor*grants S-1-1-0*'
        Test-Path -LiteralPath $root | Should -BeFalse
    }
    It 'creates a missing root one level deep below an existing parent, then checks it like any other' {
        $parent = New-Staging
        $root = Join-Path $parent 'new-root'
        Assert-AapStagingRoot -Root $root -TrustedSid $script:Me -SkipAncestorCheck
        Test-Path -LiteralPath $root | Should -BeTrue
        { Assert-AapStagingRoot -Root (Join-Path $parent 'a\b\c') -TrustedSid $script:Me -SkipAncestorCheck } | Should -Throw 'AAP_StagingUntrusted: the parent of staging root*does not exist*'
        Test-Path -LiteralPath (Join-Path $parent 'a') | Should -BeFalse
    }
    It 'refuses a share or device path before touching it' {
        { Assert-AapStagingRoot -Root '\\server\share\stage' } | Should -Throw 'AAP_StagingUntrusted: staging root*is not a local drive path'
        { Assert-AapStagingRoot -Root '\\?\C:\stage' } | Should -Throw 'AAP_StagingUntrusted: staging root*is not a local drive path'
    }
    It 'refuses a root on a <type> drive, as the supervisor does, and creates nothing' -ForEach @(
        @{ type = 'Network' }, @{ type = 'Removable' }, @{ type = 'CDRom' }, @{ type = 'Ram' }, @{ type = 'NoRootDirectory' }, @{ type = 'Unknown' }
    ) {
        Mock Get-AapDriveType -ModuleName AapArtifact -MockWith ([scriptblock]::Create("'$type'"))
        $root = New-Staging
        $fresh = Join-Path $TestDrive 'fresh-root'
        (@(Get-AapStagingProblems -Root $root -SkipAncestorCheck | ForEach-Object Text) -join "`n") | Should -Match "staging root .* is on a drive of type $type; only a fixed local disk is accepted"
        { Assert-AapStagingRoot -Root $fresh -SkipAncestorCheck } | Should -Throw "AAP_StagingUntrusted: staging root*is on a drive of type $type*"
        Test-Path -LiteralPath $fresh | Should -BeFalse
        { Invoke-Fetch (New-Entry 'drv' 'a.bin' "$($script:Base)/ok.bin") $root } | Should -Throw "AAP_StagingUntrusted*drive of type $type*"
        @(Get-ChildItem -LiteralPath $root -Force).Count | Should -Be 0
        $script:State.Hits.Count | Should -Be 0
    }
    It 'asks Windows for the type of the drive root, not of the whole path' {
        Mock Get-AapDriveType -ModuleName AapArtifact -MockWith { 'Fixed' }
        @(Get-AapStagingProblems -Root (New-Staging) -SkipAncestorCheck -TrustedSid $script:Me).Count | Should -Be 0
        Should -Invoke Get-AapDriveType -ModuleName AapArtifact -Times 1 -Exactly -ParameterFilter { $DriveRoot -match '^[A-Za-z]:\\$' }
    }

    # ---- the folders below the root: the owner and ACL rule of the root, for ones that were there and ones just created ----
    It 'refuses a name folder that was there already and lets Everyone do anything, and writes nothing in it' {
        $root = New-Staging
        $dir = Join-Path $root 'desc'
        New-Item -ItemType Directory -Path $dir | Out-Null
        Grant-Everyone $dir
        $e = New-Entry 'desc' 'a.bin' "$($script:Base)/ok.bin"
        { Invoke-Fetch $e $root } | Should -Throw 'AAP_StagingUntrusted: name folder*desc grants S-1-1-0*'
        @(Get-ChildItem -LiteralPath $dir -Force).Count | Should -Be 0
        $script:State.Hits.Count | Should -Be 0
    }
    It 'refuses a version folder that was there already and lets Everyone do anything, and writes nothing in it' {
        $root = New-Staging
        $ver = Join-Path $root 'descv\1.0.0'
        New-Item -ItemType Directory -Path $ver -Force | Out-Null
        Grant-Everyone $ver
        $e = New-Entry 'descv' 'a.bin' "$($script:Base)/ok.bin"
        { Invoke-Fetch $e $root } | Should -Throw 'AAP_StagingUntrusted: version folder*1.0.0 grants S-1-1-0*'
        @(Get-ChildItem -LiteralPath $ver -Force).Count | Should -Be 0
        $script:State.Hits.Count | Should -Be 0
    }
    It 'refuses a <level> folder owned by someone else, however its ACL looks, unless that account is trusted' -ForEach @(@{ level = 'name' }, @{ level = 'version' }) {
        $root = New-Staging
        $nameDir = Join-Path $root 'strange'
        $verDir = Join-Path $nameDir '1.0.0'
        New-Item -ItemType Directory -Path $verDir -Force | Out-Null
        $target = if ($level -eq 'name') { $nameDir } else { $verDir }
        $stranger = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
        Mock Get-Acl -ModuleName AapArtifact -MockWith (New-MockAcl $script:GoodSddl)
        Mock Get-Acl -ModuleName AapArtifact -MockWith (New-MockAcl "O:${stranger}G:BAD:PAI(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)") -ParameterFilter (New-PathFilter $target)
        $e = New-Entry 'strange' 'a.bin' "$($script:Base)/ok.bin"
        $expected = [WildcardPattern]::Escape("AAP_StagingUntrusted: owner $stranger of $level folder $target is not SYSTEM, Administrators or TrustedInstaller")
        { Get-AapArtifact -Entry $e -StagingRoot $root -AllowLoopbackHttp -TrustedSid @() -SkipAncestorCheck } | Should -Throw $expected
        @(Get-ChildItem -LiteralPath $verDir -Force).Count | Should -Be 0
        $script:State.Hits.Count | Should -Be 0
        { Get-AapArtifact -Entry $e -StagingRoot $root -AllowLoopbackHttp -TrustedSid $stranger -SkipAncestorCheck } | Should -Not -Throw
    }
    It 'refuses a folder it just created when the ACL it inherited lets others write, and creates nothing below it' {
        $root = New-Staging
        Mock Get-Acl -ModuleName AapArtifact -MockWith (New-MockAcl ($script:GoodSddl + '(A;;0x2;;;WD)'))
        Mock Get-Acl -ModuleName AapArtifact -MockWith (New-MockAcl $script:GoodSddl) -ParameterFilter (New-PathFilter $root)
        $e = New-Entry 'inherit' 'a.bin' "$($script:Base)/ok.bin"
        { Get-AapArtifact -Entry $e -StagingRoot $root -AllowLoopbackHttp -TrustedSid @() -SkipAncestorCheck } | Should -Throw 'AAP_StagingUntrusted: name folder*inherit grants S-1-1-0*'
        Test-Path -LiteralPath (Join-Path $root 'inherit\1.0.0') | Should -BeFalse
        $script:State.Hits.Count | Should -Be 0
    }
    It 'accepts name and version folders that only administrators and the trusted account can use' {
        $root = New-Staging
        $name = Join-Path $root 'locked'
        $ver = Join-Path $name '1.0.0'
        New-Item -ItemType Directory -Path $ver -Force | Out-Null
        Lock-Dir $name
        Lock-Dir $ver
        $a = Invoke-Fetch (New-Entry 'locked' 'a.bin' "$($script:Base)/ok.bin") $root
        $a.Verified | Should -BeTrue
        $a.Path | Should -Exist
    }
    It 'rejects only the entry whose folder is untrusted and still fetches the rest' {
        $root = New-Staging
        $dir = Join-Path $root 'badfolder'
        New-Item -ItemType Directory -Path $dir | Out-Null
        Grant-Everyone $dir
        $m = [pscustomobject]@{ schema = 1; entries = @((New-Entry 'badfolder' 'a.bin' "$($script:Base)/ok.bin"), (New-Entry 'goodfolder' 'a.bin' "$($script:Base)/ok.bin")); not_reproducible = @() }
        $r = Invoke-AapManifest -Manifest $m -StagingRoot $root -AllowLoopbackHttp
        $r.Complete | Should -BeFalse
        @($r.Rejected).Count | Should -Be 1
        $r.Rejected | Should -Contain 'badfolder'
        ($r.Results | Where-Object Name -eq 'badfolder').Reason | Should -Be 'AAP_StagingUntrusted'
        ($r.Results | Where-Object Name -eq 'goodfolder').Verified | Should -BeTrue
        @(Get-ChildItem -LiteralPath $dir -Force).Count | Should -Be 0 -Because 'not even a rejection record is written into a folder that cannot be trusted'
    }

    # ---- the partial download is created, never opened ----
    It 'does not write through a hard link left at the partial download name' {
        $victim = New-Victim; $root = New-Staging
        $e = New-Entry 'jhard' 'a.bin' "$($script:Base)/ok.bin"
        $f = Get-AapStagedPath $root $e
        New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
        New-Item -ItemType HardLink -Path ($f + '.part') -Value $victim.Sentinel | Out-Null
        $a = Invoke-Fetch $e $root
        $a.Verified | Should -BeTrue
        [IO.File]::ReadAllText($victim.Sentinel) | Should -Be 'untouched'
        ($f + '.part') | Should -Not -Exist
    }
    It 'does not write through a hard link left at the partial download name of a file source either' {
        $victim = New-Victim; $root = New-Staging
        $src = Join-Path $TestDrive 'hl-src.bin'; [IO.File]::WriteAllBytes($src, $script:OkBytes)
        $e = New-Entry 'jhard2' 'a.bin' ([Uri]$src).AbsoluteUri
        $f = Get-AapStagedPath $root $e
        New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
        New-Item -ItemType HardLink -Path ($f + '.part') -Value $victim.Sentinel | Out-Null
        $a = Invoke-Fetch $e $root @{ AllowFileSource = $true }
        $a.Verified | Should -BeTrue
        [IO.File]::ReadAllText($victim.Sentinel) | Should -Be 'untouched'
    }

    # ---- the quarantine name ----
    It 'does not move a failing file into a junction planted at the quarantine name' {
        $victim = New-Victim; $root = New-Staging
        $e = New-Entry 'jquar' 'q.bin' "$($script:Base)/ok.bin"
        $a = Invoke-Fetch $e $root
        New-Junction ($a.Path + '.quarantined') $victim.Dir
        [IO.File]::WriteAllBytes($a.Path, (Get-Ascii 'tampered'))
        { Get-AapArtifact -Entry $e -StagingRoot $root -Offline -AllowLoopbackHttp } | Should -Throw 'AAP_HashMismatch*'
        Assert-Untouched $victim
        $a.Path | Should -Not -Exist
        (Get-Sha ([IO.File]::ReadAllBytes($a.Path + '.quarantined.1'))) | Should -Be (Get-Sha (Get-Ascii 'tampered'))
    }

    # ---- the files: whoever can write to a file can change it after it was checked, whatever its bytes are ----
    It 'refuses a folder that inherits an entry meant for subfolders, at the name folder' {
        $root = New-Staging
        & "$env:SystemRoot\System32\icacls.exe" $root /grant '*S-1-1-0:(CI)(IO)M' | Out-Null
        { Invoke-Fetch (New-Entry 'subonly' 'a.bin' "$($script:Base)/ok.bin") $root } | Should -Throw 'AAP_StagingUntrusted: name folder*grants S-1-1-0*'
        $script:State.Hits.Count | Should -Be 0
    }
    It 'refuses a file that inherits an entry meant for files only, which every folder check skips, and publishes nothing' {
        $root = New-Staging
        & "$env:SystemRoot\System32\icacls.exe" $root /grant '*S-1-1-0:(OI)(IO)M' | Out-Null
        @(Get-AapStagingProblems -Root $root -SkipAncestorCheck -TrustedSid $script:Me).Count | Should -Be 0 -Because 'an inherit-only entry does not apply to the folder itself'
        $e = New-Entry 'fileonly' 'a.bin' "$($script:Base)/ok.bin"
        $f = Get-AapStagedPath $root $e
        { Invoke-Fetch $e $root } | Should -Throw 'AAP_StagingUntrusted: downloaded file*grants S-1-1-0*'
        $f | Should -Not -Exist
        "$f.part" | Should -Not -Exist
        ($f + '.provenance.json') | Should -Not -Exist
        $script:State.Hits['/ok.bin'] | Should -Be 1 -Because 'a refusal is not retried'
        (Get-Rejected $root $e).reason | Should -Be 'AAP_StagingUntrusted'
    }
    It 'leaves no file with an untrusted ACL under the final name when its replacement is refused too' {
        $root = New-Staging
        $e = New-Entry 'nobadfile' 'a.bin' "$($script:Base)/ok.bin"
        $a = Invoke-Fetch $e $root
        Grant-EveryoneFile $a.Path
        & "$env:SystemRoot\System32\icacls.exe" $root /grant '*S-1-1-0:(OI)(IO)M' | Out-Null
        # the old file is removed first, then the new one is refused
        { Invoke-Fetch $e $root } | Should -Throw 'AAP_StagingUntrusted: downloaded file*'
        $a.Path | Should -Not -Exist
        ($a.Path + '.part') | Should -Not -Exist
    }
    It 'keeps a good first-fetch file when its replacement is refused for an entry meant for others' {
        $root = New-Staging
        $e = New-TofuEntry2 'keepgood'
        $a = Invoke-Fetch $e $root @{ RecordFirstFetch = $true }
        # A change to the ACL of the root reaches the files that already exist, unless they do not inherit; these two do not.
        Lock-File $a.Path
        Lock-File ($a.Path + '.first-fetch.json')
        & "$env:SystemRoot\System32\icacls.exe" $root /grant '*S-1-1-0:(OI)(IO)M' | Out-Null
        { Invoke-Fetch $e $root } | Should -Throw 'AAP_StagingUntrusted: downloaded file*'
        (Get-Sha ([IO.File]::ReadAllBytes($a.Path))) | Should -Be $script:OkSha -Because 'the new file is checked before it replaces anything'
        ($a.Path + '.part') | Should -Not -Exist
    }
    It 'checks a new file again where it stands, and removes it when it is not what the partial file was' {
        $root = New-Staging
        $e = New-Entry 'afterwards' 'a.bin' "$($script:Base)/ok.bin"
        $f = Get-AapStagedPath $root $e
        Mock Get-Acl -ModuleName AapArtifact -MockWith (New-MockAcl $script:GoodSddl)
        Mock Get-Acl -ModuleName AapArtifact -MockWith (New-MockAcl ($script:GoodSddl + '(A;;0x2;;;WD)')) -ParameterFilter (New-PathFilter $f)
        { Get-AapArtifact -Entry $e -StagingRoot $root -AllowLoopbackHttp -TrustedSid @() -SkipAncestorCheck } | Should -Throw 'AAP_StagingUntrusted: staged file*grants S-1-1-0*'
        $f | Should -Not -Exist
        ($f + '.provenance.json') | Should -Not -Exist
        (Get-Rejected $root $e).reason | Should -Be 'AAP_StagingUntrusted'
    }
    It 'removes a staged file that has an entry of its own for Everyone, and downloads it again online' {
        $root = New-Staging
        $e = New-Entry 'ownacl' 'a.bin' "$($script:Base)/ok.bin"
        $a = Invoke-Fetch $e $root
        Grant-EveryoneFile $a.Path
        Get-EveryoneEntries $a.Path | Should -BeGreaterThan 0
        $script:State.Hits.Clear()
        $b = Invoke-Fetch $e $root
        $b.Provenance.mode | Should -Be 'online' -Because 'a file that others can change is not reused'
        $b.Verified | Should -BeTrue
        $script:State.Hits['/ok.bin'] | Should -Be 1
        $b.Provenance.detail | Should -Match 'removed the staged file, which others can change'
        Get-EveryoneEntries $b.Path | Should -Be 0
    }
    It 'refuses a staged file that has an entry of its own for Everyone offline, and moves it away' {
        $root = New-Staging
        $e = New-Entry 'ownacl2' 'a.bin' "$($script:Base)/ok.bin"
        $a = Invoke-Fetch $e $root
        Grant-EveryoneFile $a.Path
        $script:State.Hits.Clear()
        { Get-AapArtifact -Entry $e -StagingRoot $root -Offline -AllowLoopbackHttp } | Should -Throw 'AAP_StagingUntrusted: staged file*grants S-1-1-0*'
        $a.Path | Should -Not -Exist
        ($a.Path + '.quarantined') | Should -Exist
        $a.ProvenancePath | Should -Not -Exist
        (Get-Rejected $root $e).detail | Should -Match 'moved the untrusted file to a\.bin\.quarantined'
        $script:State.Hits.Count | Should -Be 0
    }
    It 'refuses a staged file that someone else owns offline, however its ACL looks' {
        $root = New-Staging
        $e = New-Entry 'ownowner' 'a.bin' "$($script:Base)/ok.bin"
        $a = Invoke-Fetch $e $root
        $stranger = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
        Mock Get-Acl -ModuleName AapArtifact -MockWith (New-MockAcl $script:GoodSddl)
        Mock Get-Acl -ModuleName AapArtifact -MockWith (New-MockAcl "O:${stranger}G:BAD:PAI(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)") -ParameterFilter (New-PathFilter $a.Path)
        $expected = [WildcardPattern]::Escape("AAP_StagingUntrusted: owner $stranger of staged file $($a.Path) is not SYSTEM, Administrators or TrustedInstaller")
        { Get-AapArtifact -Entry $e -StagingRoot $root -Offline -AllowLoopbackHttp -TrustedSid @() -SkipAncestorCheck } | Should -Throw $expected
        $a.Path | Should -Not -Exist
    }
    It 'reuses a staged file that only the trusted accounts can write' {
        $root = New-Staging
        $e = New-Entry 'lockedfile' 'a.bin' "$($script:Base)/ok.bin"
        $a = Invoke-Fetch $e $root
        Lock-File $a.Path
        $script:State.Hits.Clear()
        $b = Invoke-Fetch $e $root
        $b.Provenance.mode | Should -Be 'reuse'
        $b.Verified | Should -BeTrue
        $script:State.Hits.Count | Should -Be 0
        $c = Get-AapArtifact -Entry $e -StagingRoot $root -Offline -AllowLoopbackHttp
        $c.Provenance.mode | Should -Be 'offline'
        $c.Verified | Should -BeTrue
    }
    It 'does not use a first-fetch record that others can change, and does not delete it' {
        $root = New-Staging
        $e = New-TofuEntry2 'badrecord'
        $a = Invoke-Fetch $e $root @{ RecordFirstFetch = $true }
        $record = $a.Path + '.first-fetch.json'
        Grant-EveryoneFile $record
        $before = Get-Content -Raw -LiteralPath $record
        $script:State.Hits.Clear()
        { Invoke-Fetch $e $root @{ RecordFirstFetch = $true } } | Should -Throw 'AAP_StagingUntrusted: first-fetch record*grants S-1-1-0*trust anchor*'
        { Get-AapArtifact -Entry $e -StagingRoot $root -Offline -AllowLoopbackHttp } | Should -Throw 'AAP_StagingUntrusted: first-fetch record*'
        $record | Should -Exist
        (Get-Content -Raw -LiteralPath $record) | Should -BeExactly $before
        $script:State.Hits.Count | Should -Be 0 -Because 'nothing is downloaded against an anchor that cannot be trusted'
        $a.ProvenancePath | Should -Not -Exist
    }
    It 'does not read an upstream hash file that others can change, and downloads it again first online' {
        $script:State.Sums = ('{0}  {1}' -f $script:OkSha, 'archive-a.bin') + "`n"
        $sums = New-Entry 'sumsfile' 'SUMS' "$($script:Base)/sums.txt" (Get-Sha (Get-Ascii $script:State.Sums)) -Over @{ content_types = @('text/plain') }
        $up = [ordered]@{ algorithm = 'sha256'; source = 'upstream-file'; value = $null; upstream_entry = 'sumsfile'; upstream_key = 'archive-a.bin' }
        $arc = New-Entry 'archivefile' 'archive-a.bin' "$($script:Base)/ok.bin" -Over @{ hash = $up }
        $m = [pscustomobject]@{ schema = 1; entries = @($sums, $arc); not_reproducible = @() }
        $root = New-Staging
        (Invoke-AapManifest -Manifest $m -StagingRoot $root -AllowLoopbackHttp).Complete | Should -BeTrue
        $sumsPath = Get-AapStagedPath $root $sums
        Grant-EveryoneFile $sumsPath
        { Get-AapArtifact -Entry $arc -StagingRoot $root -Manifest $m -Offline -AllowLoopbackHttp } | Should -Throw 'AAP_StagingUntrusted: upstream hash file*grants S-1-1-0*'
        $r = Invoke-AapManifest -Manifest $m -StagingRoot $root -AllowLoopbackHttp
        $r.Complete | Should -BeTrue -Because (($r.Results.Message) -join ';')
        Get-EveryoneEntries $sumsPath | Should -Be 0
    }
    It 'does not read an earlier provenance record that others can change, and writes the new one as a new file' {
        $root = New-Staging
        $e = New-Entry 'oldprov' 'a.bin' "$($script:Base)/ok.bin"
        $a = Invoke-Fetch $e $root
        Grant-EveryoneFile $a.ProvenancePath
        $b = Invoke-Fetch $e $root
        $b.Provenance.mode | Should -Be 'reuse'
        $b.Provenance.requested_url | Should -BeNullOrEmpty -Because 'where a file came from is taken from a record only when nobody else could have written it'
        $b.Provenance.detail | Should -Match 'ignored an earlier provenance record'
        Get-EveryoneEntries $b.ProvenancePath | Should -Be 0 -Because 'a record that is written over keeps the entries of the old one'
    }
    It 'writes the <kind> record as a new file and does not write through a hard link left at its name' -ForEach @(@{ kind = 'provenance' }, @{ kind = 'rejection' }) {
        $victim = New-Victim; $root = New-Staging
        $sha = if ($kind -eq 'rejection') { '0' * 64 } else { $script:OkSha }
        $e = New-Entry "jrec$kind" 'a.bin' "$($script:Base)/ok.bin" $sha
        $f = Get-AapStagedPath $root $e
        New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
        $record = $f + $(if ($kind -eq 'rejection') { '.rejected.json' } else { '.provenance.json' })
        New-Item -ItemType HardLink -Path $record -Value $victim.Sentinel | Out-Null
        if ($kind -eq 'rejection') { { Invoke-Fetch $e $root } | Should -Throw 'AAP_HashMismatch*' } else { (Invoke-Fetch $e $root).Verified | Should -BeTrue }
        [IO.File]::ReadAllText($victim.Sentinel) | Should -Be 'untouched'
        (Get-Content -Raw -LiteralPath $record | ConvertFrom-Json).schema | Should -Be 'aap-provenance/1'
    }
}

Describe 'verified results and first-fetch policy' {
    BeforeAll {
        function New-TofuEntry([string]$Name = 'tofu', [string]$Url = "$($script:Base)/ok.bin") {
            New-Entry $Name 't.bin' $Url -Over @{ hash = [ordered]@{ algorithm = 'sha256'; source = 'first-fetch'; value = $null; upstream_entry = $null; upstream_key = $null } }
        }
    }
    BeforeEach { $script:State.Hits.Clear() }

    It 'marks a hash-checked entry Verified and a first-fetch entry not' {
        (Invoke-Fetch (New-Entry 'ver1' 'v.bin' "$($script:Base)/ok.bin") (New-Staging)).Verified | Should -BeTrue
        (Invoke-Fetch (New-TofuEntry) (New-Staging) @{ RecordFirstFetch = $true }).Verified | Should -BeFalse
    }
    It 'is not Complete while an accepted entry is unverified, and names it' {
        $lit = New-Entry 'lit' 'l.bin' "$($script:Base)/ok.bin"
        $m = [pscustomobject]@{ schema = 1; entries = @($lit, (New-TofuEntry)); not_reproducible = @() }
        $st = New-Staging
        $r = Invoke-AapManifest -Manifest $m -StagingRoot $st -AllowLoopbackHttp -RecordFirstFetch
        $r.Complete | Should -BeFalse
        @($r.Rejected).Count | Should -Be 0
        @($r.Unverified).Count | Should -Be 1
        $r.Unverified | Should -Contain 'tofu'
        ($r.Results | Where-Object Name -eq 'lit').Verified | Should -BeTrue
        ($r.Results | Where-Object Name -eq 'tofu').Verified | Should -BeFalse
        (Invoke-AapManifest -Manifest $m -StagingRoot $st -AllowLoopbackHttp).Unverified | Should -Contain 'tofu'
        (Invoke-AapManifest -Manifest $m -StagingRoot $st -AllowLoopbackHttp -Name 'lit').Complete | Should -BeTrue
    }
    It 'never accepts a file planted under a first-fetch entry whose source is unreachable' {
        $st = New-Staging
        $e = New-TofuEntry 'planted' "$($script:ClosedBase)/ok.bin"
        $f = Get-AapStagedPath $st $e
        New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
        [IO.File]::WriteAllBytes($f, (Get-Ascii 'planted bytes'))
        { Get-AapArtifact -Entry $e -StagingRoot $st -Offline -AllowLoopbackHttp } | Should -Throw 'AAP_OfflineIncomplete*'
        $m = [pscustomobject]@{ schema = 1; entries = @($e); not_reproducible = @() }
        $r = Invoke-AapManifest -Manifest $m -StagingRoot $st -AllowLoopbackHttp -RecordFirstFetch
        $r.Complete | Should -BeFalse
        $r.Results[0].Status | Should -Be 'rejected'
        $r.Results[0].Reason | Should -Be 'AAP_SourceUnavailable'
        ($f + '.first-fetch.json') | Should -Not -Exist
        ($f + '.provenance.json') | Should -Not -Exist
    }
    It 'accepts a planted file with a planted record only as unverified, and the next online run exposes it' {
        $st = New-Staging
        $e = New-TofuEntry 'planted2'
        $f = Get-AapStagedPath $st $e
        New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
        $planted = Get-Ascii 'planted bytes'
        [IO.File]::WriteAllBytes($f, $planted)
        ([ordered]@{ schema = 'aap-first-fetch/1'; name = 'planted2'; version = '1.0.0'; file_name = 't.bin'; algorithm = 'sha256'; hash = (Get-Sha $planted) } | ConvertTo-Json) | Set-Content -LiteralPath ($f + '.first-fetch.json') -Encoding UTF8
        $off = Get-AapArtifact -Entry $e -StagingRoot $st -Offline -AllowLoopbackHttp
        $off.Verified | Should -BeFalse
        { Invoke-Fetch $e $st } | Should -Throw 'AAP_HashMismatch*first-fetch-recorded*'
    }
    It 'does not follow a redirect for a first-fetch entry' {
        $e = New-TofuEntry 'tofuredir' "$($script:Base)/redir-same"
        { Invoke-Fetch $e (New-Staging) @{ RecordFirstFetch = $true } } | Should -Throw 'AAP_RedirectRejected*never follows a redirect'
        $script:State.Hits.ContainsKey('/ok.bin') | Should -BeFalse
    }
    It 'does not let a first-fetch entry name redirect hosts' {
        $e = New-TofuEntry 'tofuhosts'
        $e.redirect_hosts = @('127.0.0.2')
        (@(Test-AapEntry -Entry $e -AllowTestSources) -join "`n") | Should -Match 'first-fetch entry may not allow redirect hosts'
    }
}

Describe 'command-line script exit codes' {
    BeforeAll {
        $tofuHash = [ordered]@{ algorithm = 'sha256'; source = 'first-fetch'; value = $null; upstream_entry = $null; upstream_key = $null }
        $script:CliLit = New-Entry 'clilit' 'l.bin' 'https://example.invalid/l.bin'
        $script:CliTofu = New-Entry 'clitofu' 't.bin' 'https://example.invalid/t.bin' -Over @{ hash = $tofuHash }
        $script:CliManifest = Join-Path $TestDrive 'cli-manifest.json'
        ([pscustomobject]@{ schema = 1; generated_from = 'fixture'; entries = @($script:CliLit, $script:CliTofu); not_reproducible = @() } | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $script:CliManifest -Encoding UTF8
        function Invoke-Cli([string[]]$ArgList) {
            $saved = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'   # Windows PowerShell 5.1 turns merged native stderr into a terminating error under 'Stop'
            try { $out = & $script:Exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $script:Common 'Get-AapArtifact.ps1') -Manifest $script:CliManifest @ArgList 2>&1 | Out-String }
            finally { $ErrorActionPreference = $saved }
            [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $out }
        }
        function Set-CliFile($Stage, $Entry, [byte[]]$Bytes) {
            $f = Get-AapStagedPath $Stage $Entry
            New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
            [IO.File]::WriteAllBytes($f, $Bytes)
            $f
        }
        $script:Relax = @('-TrustedSid', $script:Me, '-SkipAncestorCheck')
    }
    It 'exits 0 when every selected entry is accepted and verified' {
        $st = New-Staging
        [void](Set-CliFile $st $script:CliLit $script:OkBytes)
        $r = Invoke-Cli (@('-Staging', $st, '-Name', 'clilit', '-Offline') + $script:Relax)
        $r.Exit | Should -Be 0 -Because $r.Out
        $r.Out | Should -Match 'WARNING +staging trust checks relaxed'
    }
    It 'exits 3 when nothing is rejected but a first-fetch entry is accepted unverified' {
        $st = New-Staging
        $f = Set-CliFile $st $script:CliTofu $script:OkBytes
        ([ordered]@{ schema = 'aap-first-fetch/1'; name = 'clitofu'; version = '1.0.0'; file_name = 't.bin'; algorithm = 'sha256'; hash = $script:OkSha } | ConvertTo-Json) | Set-Content -LiteralPath ($f + '.first-fetch.json') -Encoding UTF8
        $r = Invoke-Cli (@('-Staging', $st, '-Name', 'clitofu', '-Offline') + $script:Relax)
        $r.Exit | Should -Be 3 -Because $r.Out
        $r.Out | Should -Match 'unverified'
    }
    It 'exits 1 when an entry is rejected' {
        $st = New-Staging
        $r = Invoke-Cli (@('-Staging', $st, '-Offline') + $script:Relax)
        $r.Exit | Should -Be 1 -Because $r.Out
        $r.Out | Should -Match 'rejected +clilit'
    }
    It 'exits 1 and writes nothing when the staging folder is not trusted' {
        if ($script:Me -in @('S-1-5-18', 'S-1-5-32-544')) { Set-ItResult -Skipped -Because 'the tests run as an account that is trusted by default'; return }
        $st = New-Staging
        $r = Invoke-Cli @('-Staging', $st, '-Offline')
        $r.Exit | Should -Be 1 -Because $r.Out
        $r.Out | Should -Match 'AAP_StagingUntrusted'
        @(Get-ChildItem -LiteralPath $st -Force).Count | Should -Be 0
    }
}

Describe 'quarantine and evidence re-hash' {
    BeforeAll {
        function Test-Evidence2([string]$Path) {
            if (-not $script:Py) { return [pscustomobject]@{ Exit = 0; Out = 'no python' } }
            $out = & $script:Py -B -I $script:Validator evidence-bundle $Path 2>&1
            [pscustomobject]@{ Exit = $LASTEXITCODE; Out = "$out" }
        }
    }
    BeforeEach { $script:State.Hits.Clear() }

    It 'moves a staged file that fails an offline check away from its final name' {
        $st = New-Staging; $e = New-Entry 'quar' 'q.bin' "$($script:Base)/ok.bin"
        $a = Invoke-Fetch $e $st
        [IO.File]::WriteAllBytes($a.Path, (Get-Ascii 'tampered'))
        { Get-AapArtifact -Entry $e -StagingRoot $st -Offline -AllowLoopbackHttp } | Should -Throw 'AAP_HashMismatch*'
        $a.Path | Should -Not -Exist
        ($a.Path + '.quarantined') | Should -Exist
        (Get-Sha ([IO.File]::ReadAllBytes($a.Path + '.quarantined'))) | Should -Be (Get-Sha (Get-Ascii 'tampered'))
        $a.ProvenancePath | Should -Not -Exist
        (Get-Rejected $st $e).detail | Should -Match 'moved the failing file to q\.bin\.quarantined'
        { Get-AapArtifact -Entry $e -StagingRoot $st -Offline -AllowLoopbackHttp } | Should -Throw 'AAP_OfflineIncomplete*'
    }
    It 'never moves a failing file into or over a <kind> that already has the quarantine name' -ForEach @(@{ kind = 'folder' }, @{ kind = 'file' }) {
        $st = New-Staging; $e = New-Entry 'quar2' 'q.bin' "$($script:Base)/ok.bin"
        $a = Invoke-Fetch $e $st
        $taken = $a.Path + '.quarantined'
        if ($kind -eq 'folder') {
            New-Item -ItemType Directory -Path $taken | Out-Null
            [IO.File]::WriteAllText((Join-Path $taken 'old.txt'), 'earlier')
        } else {
            [IO.File]::WriteAllText($taken, 'earlier quarantine')
        }
        [IO.File]::WriteAllBytes($a.Path, (Get-Ascii 'tampered'))
        { Get-AapArtifact -Entry $e -StagingRoot $st -Offline -AllowLoopbackHttp } | Should -Throw 'AAP_HashMismatch*'
        $a.Path | Should -Not -Exist
        if ($kind -eq 'folder') {
            (@(Get-ChildItem -LiteralPath $taken -Force | ForEach-Object Name) -join ',') | Should -Be 'old.txt'
            [IO.File]::ReadAllText((Join-Path $taken 'old.txt')) | Should -Be 'earlier'
        } else {
            [IO.File]::ReadAllText($taken) | Should -Be 'earlier quarantine'
        }
        (Get-Sha ([IO.File]::ReadAllBytes($a.Path + '.quarantined.1'))) | Should -Be (Get-Sha (Get-Ascii 'tampered'))
        (Get-Rejected $st $e).detail | Should -Match 'moved the failing file to q\.bin\.quarantined\.1'
    }
    It 'keeps every failing copy: each quarantine takes the next free name' {
        $st = New-Staging; $e = New-Entry 'quar3' 'q.bin' "$($script:Base)/ok.bin"
        foreach ($i in 1..3) {
            $a = Invoke-Fetch $e $st
            [IO.File]::WriteAllBytes($a.Path, (Get-Ascii "tampered $i"))
            { Get-AapArtifact -Entry $e -StagingRoot $st -Offline -AllowLoopbackHttp } | Should -Throw 'AAP_HashMismatch*'
        }
        $f = Get-AapStagedPath $st $e
        $names = @('.quarantined', '.quarantined.1', '.quarantined.2')
        foreach ($i in 0..2) { (Get-Sha ([IO.File]::ReadAllBytes($f + $names[$i]))) | Should -Be (Get-Sha (Get-Ascii "tampered $($i + 1)")) }
    }
    It 'leaves a file in place when the failure is not about the file (the hash source is missing)' {
        $sums = New-Entry 'sums' 'SUMS' "$($script:ClosedBase)/sums.txt" ('0' * 64) -Over @{ content_types = @('text/plain') }
        $arc = New-Entry 'arc' 'a.bin' "$($script:ClosedBase)/a.bin" -Over @{ hash = [ordered]@{ algorithm = 'sha256'; source = 'upstream-file'; value = $null; upstream_entry = 'sums'; upstream_key = 'a.bin' } }
        $m = [pscustomobject]@{ schema = 1; entries = @($sums, $arc); not_reproducible = @() }
        $st = New-Staging
        $f = Get-AapStagedPath $st $arc
        New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
        [IO.File]::WriteAllBytes($f, $script:OkBytes)
        $r = Invoke-AapManifest -Manifest $m -StagingRoot $st -Offline -AllowLoopbackHttp
        ($r.Results | Where-Object Name -eq 'arc').Reason | Should -Be 'AAP_HashSourceMissing'
        $f | Should -Exist
        ($f + '.quarantined') | Should -Not -Exist
    }
    It 'hashes the staged file again for the evidence record: a changed or missing file is a failure, never a pass' {
        Mock Get-Acl -ModuleName AapArtifact -MockWith (New-MockAcl $script:GoodSddl)
        $st = New-Staging; $e = New-Entry 'rehash' 'r.bin' "$($script:Base)/ok.bin"
        $a = Invoke-StrictFetch $e $st
        $ok = Join-Path $TestDrive 'rehash-ok.json'
        [void](New-AapEvidenceRecord -ProvenancePath $a.ProvenancePath -OutPath $ok -HeadSha $script:Head)
        (Get-Content -Raw -LiteralPath $ok | ConvertFrom-Json).result | Should -Be 'pass'
        [IO.File]::WriteAllBytes($a.Path, (Get-Ascii 'changed after acceptance'))
        $changed = Join-Path $TestDrive 'rehash-changed.json'
        [void](New-AapEvidenceRecord -ProvenancePath $a.ProvenancePath -OutPath $changed -HeadSha $script:Head)
        $r = Get-Content -Raw -LiteralPath $changed | ConvertFrom-Json
        $r.result | Should -Be 'fail'
        $r.oracle.observed | Should -Be 'failure'
        $r.command | Should -Match 'observed-reason=AAP_ArtifactChanged'
        $r.artifacts[0].sha256 | Should -Be (Get-Sha (Get-Ascii 'changed after acceptance'))
        (Test-Evidence2 $changed).Exit | Should -Be 0
        $other = Join-Path $TestDrive 'rehash-other.json'
        [void](New-AapEvidenceRecord -ProvenancePath $a.ProvenancePath -OutPath $other -HeadSha $script:Head -ExpectedReason 'AAP_HashMismatch')
        (Get-Content -Raw -LiteralPath $other | ConvertFrom-Json).result | Should -Be 'unknown'
        Remove-Item -LiteralPath $a.Path
        $gone = Join-Path $TestDrive 'rehash-gone.json'
        [void](New-AapEvidenceRecord -ProvenancePath $a.ProvenancePath -OutPath $gone -HeadSha $script:Head)
        $g = Get-Content -Raw -LiteralPath $gone | ConvertFrom-Json
        $g.result | Should -Be 'fail'
        $g.command | Should -Match 'observed-reason=AAP_ArtifactMissing'
        (Test-Evidence2 $gone).Exit | Should -Be 0
    }
    It 'does not report a pass from an old accepted record once the file was rejected' {
        $st = New-Staging; $e = New-Entry 'stale2' 's.bin' "$($script:Base)/ok.bin"
        $a = Invoke-Fetch $e $st
        $old = Get-Content -Raw -LiteralPath $a.ProvenancePath
        [IO.File]::WriteAllBytes($a.Path, (Get-Ascii 'tampered'))
        { Get-AapArtifact -Entry $e -StagingRoot $st -Offline -AllowLoopbackHttp } | Should -Throw 'AAP_HashMismatch*'
        $a.ProvenancePath | Should -Not -Exist
        { New-AapEvidenceRecord -ProvenancePath $a.ProvenancePath -OutPath (Join-Path $TestDrive 'stale-none.json') -HeadSha $script:Head } | Should -Throw
        # the old accepted record comes back (a restored backup, a copy): the file is gone from its final name, so it proves nothing
        [IO.File]::WriteAllText($a.ProvenancePath, $old)
        $out = Join-Path $TestDrive 'stale-back.json'
        [void](New-AapEvidenceRecord -ProvenancePath $a.ProvenancePath -OutPath $out -HeadSha $script:Head)
        $r = Get-Content -Raw -LiteralPath $out | ConvertFrom-Json
        $r.result | Should -Be 'fail'
        $r.command | Should -Match 'observed-reason=AAP_ArtifactMissing'
    }
}

Describe 'manifest guards' {
    BeforeAll {
        function New-UpEntry([string]$Name, [string]$Up, $Hash = $null) {
            $h = if ($Hash) { $Hash } else { [ordered]@{ algorithm = 'sha256'; source = 'upstream-file'; value = $null; upstream_entry = $Up; upstream_key = 'a.bin' } }
            New-Entry $Name 'a.bin' "$($script:Base)/ok.bin" -Over @{ hash = $h }
        }
        $script:Tofu = [ordered]@{ algorithm = 'sha256'; source = 'first-fetch'; value = $null; upstream_entry = $null; upstream_key = $null }
        $script:ViaUp = [ordered]@{ algorithm = 'sha256'; source = 'upstream-file'; value = $null; upstream_entry = 'other'; upstream_key = 'a.bin' }
    }
    It 'refuses an entry that lists itself as its upstream hash file' {
        $m = [pscustomobject]@{ schema = 1; entries = @((New-UpEntry 'selfref' 'selfref')); not_reproducible = @() }
        (@(Test-AapManifest -Manifest $m -AllowTestSources) -join "`n") | Should -Match 'lists itself as its upstream hash file'
        { Invoke-AapManifest -Manifest $m -StagingRoot (New-Staging) -AllowLoopbackHttp } | Should -Throw 'AAP_ManifestInvalid*lists itself*'
        { Resolve-AapExpectedHash -Entry $m.entries[0] -Manifest $m -StagingRoot (New-Staging) } | Should -Throw 'AAP_ManifestInvalid*lists itself*'
    }
    It 'refuses an upstream hash file that is itself first-fetch or taken from another file' -ForEach @(
        @{ kind = 'first-fetch'; hash = 'Tofu' }, @{ kind = 'upstream-file'; hash = 'ViaUp' }
    ) {
        $h = if ($hash -eq 'Tofu') { $script:Tofu } else { $script:ViaUp }
        $up = New-UpEntry 'other' 'x' $h
        $m = [pscustomobject]@{ schema = 1; entries = @((New-UpEntry 'arc' 'other'), $up); not_reproducible = @() }
        (@(Test-AapManifest -Manifest $m -AllowTestSources) -join "`n") | Should -Match 'upstream file must itself have a literal hash'
        { Invoke-AapManifest -Manifest $m -StagingRoot (New-Staging) -AllowLoopbackHttp } | Should -Throw 'AAP_ManifestInvalid*'
        { Resolve-AapExpectedHash -Entry $m.entries[0] -Manifest $m -StagingRoot (New-Staging) } | Should -Throw 'AAP_ManifestInvalid*literal sha256*'
    }
    It 'refuses an upstream name that matches more than one entry' {
        $s1 = New-Entry 'sums' 'SUMS' "$($script:Base)/sums.txt" -Over @{ content_types = @('text/plain') }
        $s2 = New-Entry 'sums' 'SUMS' "$($script:Base)/sums.txt" -Over @{ version = '2.0.0'; content_types = @('text/plain') }
        $m = [pscustomobject]@{ schema = 1; entries = @($s1, $s2, (New-UpEntry 'arc' 'sums')); not_reproducible = @() }
        (@(Test-AapManifest -Manifest $m -AllowTestSources) -join "`n") | Should -Match "upstream_entry 'sums' names more than one entry"
        { Resolve-AapExpectedHash -Entry $m.entries[2] -Manifest $m -StagingRoot (New-Staging) } | Should -Throw 'AAP_ManifestInvalid*more than one entry*'
    }
    It 'validates the whole manifest before it touches the staging folder' {
        $bad = New-Entry 'floaty2' 'f.bin' "$($script:Base)/ok.bin" -Over @{ version = 'latest' }
        $m = [pscustomobject]@{ schema = 1; entries = @($bad); not_reproducible = @() }
        $st = New-Staging
        { Invoke-AapManifest -Manifest $m -StagingRoot $st -AllowLoopbackHttp } | Should -Throw 'AAP_ManifestInvalid*AAP_VersionNotExact*'
        @(Get-ChildItem -LiteralPath $st -Force).Count | Should -Be 0
    }
}

Describe 'folder and file name rules' {
    It 'rejects <field> <value> as an unsafe Windows name' -ForEach @(
        @{ field = 'name'; value = 'nul' }, @{ field = 'name'; value = 'con' }, @{ field = 'name'; value = 'prn' }, @{ field = 'name'; value = 'aux' }
        @{ field = 'name'; value = 'com1' }, @{ field = 'name'; value = 'lpt9' }, @{ field = 'name'; value = 'nul.txt' }, @{ field = 'name'; value = 'foo.' }
        @{ field = 'version'; value = 'com1' }, @{ field = 'version'; value = '1.0.' }
        @{ field = 'file_name'; value = 'NUL' }, @{ field = 'file_name'; value = 'Aux.txt' }, @{ field = 'file_name'; value = 'a.' }, @{ field = 'file_name'; value = 'CON.tar.gz' }
    ) {
        $e = New-Entry 'okname' 'ok.bin' "$($script:Base)/ok.bin"
        $e.$field = $value
        @(Test-AapEntry -Entry $e -AllowTestSources).Count | Should -BeGreaterThan 0
        { Invoke-Fetch $e (New-Staging) } | Should -Throw 'AAP_ManifestInvalid*'
    }
    It 'accepts <value>, which only looks like a device name' -ForEach @(
        @{ value = 'console' }, @{ value = 'com10' }, @{ value = 'null' }, @{ value = 'a.b' }
    ) {
        @(Test-AapEntry -Entry (New-Entry $value 'ok.bin' "$($script:Base)/ok.bin") -AllowTestSources).Count | Should -Be 0
    }
    It 'the manifest schema rejects <field> <value> as well' -Skip:(-not $HasPython) -ForEach @(
        @{ field = 'name'; value = 'nul' }, @{ field = 'name'; value = 'foo.' }, @{ field = 'version'; value = 'lpt1' }, @{ field = 'version'; value = '1.0.' },
        @{ field = 'file_name'; value = 'COM1.txt' }, @{ field = 'file_name'; value = 'a.' }
    ) {
        $doc = Get-Content -Raw -LiteralPath $script:ManifestPath | ConvertFrom-Json
        $doc.entries[0].$field = $value
        $bad = Join-Path $TestDrive 'unsafe.json'
        $doc | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $bad
        $null = & $script:Py -B -I (Join-Path $PSScriptRoot 'validate_manifest.py') $script:Validator (Join-Path $script:Common 'artifacts.manifest.schema.json') $bad
        $LASTEXITCODE | Should -Be 1
    }
    It 'the manifest schema rejects redirect hosts on a first-fetch entry' -Skip:(-not $HasPython) {
        $doc = Get-Content -Raw -LiteralPath $script:ManifestPath | ConvertFrom-Json
        $e = $doc.entries | Where-Object { $_.hash.source -eq 'first-fetch' } | Select-Object -First 1
        $e.redirect_hosts = @('example.com')
        $bad = Join-Path $TestDrive 'ffhosts.json'
        $doc | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $bad
        $null = & $script:Py -B -I (Join-Path $PSScriptRoot 'validate_manifest.py') $script:Validator (Join-Path $script:Common 'artifacts.manifest.schema.json') $bad
        $LASTEXITCODE | Should -Be 1
    }
}

Describe 'smaller review items' {
    BeforeEach { $script:State.Hits.Clear() }

    It 'does not retry a local write failure and does not call it an unavailable source' {
        $st = New-Staging
        $e = New-Entry 'locked' 'l.bin' "$($script:Base)/ok.bin" -Over @{ retry = [ordered]@{ max_attempts = 3; backoff_seconds = 0; timeout_seconds = 5 } }
        $f = Get-AapStagedPath $st $e
        New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
        $hold = [IO.File]::Open("$f.part", [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $err = $null
        try { try { Invoke-Fetch $e $st } catch { $err = $_.Exception.Message } } finally { $hold.Dispose() }
        $err | Should -Not -BeNullOrEmpty
        $err | Should -Not -Match 'AAP_SourceUnavailable'
        $script:State.Hits['/ok.bin'] | Should -Be 1 -Because 'a local write failure is not retried'
        (Get-Rejected $st $e).reason | Should -Be 'AAP_Unexpected'
    }
    It 'does not narrow the process-wide TLS setting when the host follows the system default, and adds TLS 1.2 when it does not' {
        $probe = Join-Path $TestDrive 'tls-probe.ps1'
        Set-Content -LiteralPath $probe -Value 'param($Module, $Start); [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]$Start; Import-Module $Module -Force; [string][Net.ServicePointManager]::SecurityProtocol'
        $mod = Join-Path $script:Common 'AapArtifact.psm1'
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $default = (& $script:Exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probe $mod SystemDefault 2>&1 | Out-String).Trim()
            $old = (& $script:Exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probe $mod Tls 2>&1 | Out-String).Trim()
        } finally { $ErrorActionPreference = $saved }
        $default | Should -BeExactly 'SystemDefault'
        $old | Should -Match 'Tls12'
        $old | Should -Match '(^|, )Tls(,|$)'
    }
    It 'requires -HeadSha because the staging folder is not a git work tree' {
        $p = (Get-Command New-AapEvidenceRecord).Parameters['HeadSha']
        @($p.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } | ForEach-Object Mandatory) | Should -Contain $true
    }
    It 'refuses a file source on a network share (<u>)' -ForEach @(@{ u = 'file://server/share/a.bin' }, @{ u = 'file:////server/share/a.bin' }) {
        $e = New-Entry 'unc' 'a.bin' $u
        { Invoke-Fetch $e (New-Staging) @{ AllowFileSource = $true } } | Should -Throw 'AAP_SchemeRejected: a file source must be a local path*'
    }
}

Describe 'documentation' {
    It 'lists the zccache release files that are deliberately not acquired, each with a reason' {
        $readme = Get-Content -Raw -LiteralPath (Join-Path $script:Common 'README.md')
        foreach ($f in 'install.sh', 'install.ps1', 'manifest.json') {
            $readme | Should -Match ('(?m)^\|\s*`' + [regex]::Escape($f) + '`\s*\|.{20,}\|') -Because "$f needs a table row with a reason"
        }
        $man = Read-AapManifest -Path $script:ManifestPath
        foreach ($en in $man.entries) { $en.file_name | Should -Not -BeIn @('install.sh', 'install.ps1', 'manifest.json') }
    }
    It 'documents the exit codes and what the staging folder check needs' {
        $readme = Get-Content -Raw -LiteralPath (Join-Path $script:Common 'README.md')
        $readme | Should -Match 'D:\\aap-runner\\images'
        $readme | Should -Match 'P19'
        $readme | Should -Match '(?m)^\|\s*3\s*\|'
        $readme | Should -Match 'TrustedSid'
    }
    It 'documents the folders below the root, the drive type, the quarantine names, the relaxed-run evidence and that script coverage is self-declared' {
        $readme = Get-Content -Raw -LiteralPath (Join-Path $script:Common 'README.md')
        $readme | Should -Match 'name folder and the version folder below the root are held to the same owner and ACL rule'
        $readme | Should -Match 'fixed local disk'
        $readme | Should -Match 'CreateNew'
        $readme | Should -Match 'quarantined\.1'
        $readme | Should -Match 'staging_check=relaxed'
        $readme | Should -Match 'self-declared'
        $readme | Should -Match 'moby/moby'
    }
    It 'documents the file checks and says exactly how far the likeness to the supervisor walk goes' {
        $readme = Get-Content -Raw -LiteralPath (Join-Path $script:Common 'README.md')
        $readme | Should -Match 'The files get the same owner and ACL check'
        $readme | Should -Match 'object inherit without container inherit'
        $readme | Should -Match 'trust anchor'
        $readme | Should -Match 'Get-AapDataDirProblem'
        $readme | Should -Match 'does not walk the folders of other entries'
        $readme | Should -Match 'observed-reason=AAP_StagingUntrusted'
    }
}

Describe 'real download (integration)' -Tag Network {
    BeforeAll {
        # Probed here and not at discovery, so a run that leaves this tag out never contacts the network (and never waits
        # for a probe to time out). A host with no egress skips the two tests below.
        $script:NetGallery = Test-HttpsReachable 'https://www.powershellgallery.com/api/v2/package/Pester/5.9.0'
        $script:NetGitHub = Test-HttpsReachable 'https://github.com/zackees/zccache/releases/download/1.15.6/SHA256SUMS'
    }
    It 'fetches Pester 5.9.0 from the PowerShell Gallery and verifies its SHA-512' {
        if (-not $script:NetGallery) { Set-ItResult -Skipped -Because 'no HTTPS answer from the PowerShell Gallery'; return }
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
    It 'fetches the zccache 1.15.6 SHA256SUMS from GitHub and confirms every pinned archive hash against it' {
        if (-not $script:NetGitHub) { Set-ItResult -Skipped -Because 'no HTTPS answer from GitHub'; return }
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
            $x = Resolve-AapExpectedHash -Entry $e -Manifest $m -StagingRoot $st -TrustedSid $script:Me
            $x.Value | Should -Be $e.hash.value -Because $e.name
        }
    }
}
