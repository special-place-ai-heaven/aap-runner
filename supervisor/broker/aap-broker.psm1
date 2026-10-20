# Registration broker client for the hidden supervisor (contract:
# parity/contracts/broker.md, version 1). Windows PowerShell 5.1 and PowerShell 7.
#
# One call is one hidden wsl.exe child with a fixed command line:
#   C:\Windows\System32\wsl.exe -d aap-runner -u root --exec /usr/local/sbin/aap-runner-broker
# The only data is the request on its stdin: a compact JSON document built here
# from checked ids, numbers and enums. At most 20 KiB of stdout is read; stderr
# is drained and dropped. WSLENV is removed, so no Windows variable reaches the
# broker. The tray never loads this module.
#
# A reply is checked byte by byte before any text exists: printable ASCII, no
# backslash, at most one "jit_config" key in compact form. The JIT config bytes
# are copied out and blanked in the buffer, then the rest is parsed by a strict
# parser (not ConvertFrom-Json: pwsh 7 turns times into DateTime, duplicate keys
# are not refused, and parse errors can quote the input) and checked against
# the contract. The buffer is zeroed. Nothing the broker prints is logged,
# returned as text or written anywhere. The JIT config never becomes a string:
# callers get an object whose only property is its Length, write it with
# WriteTo(stream) and zero it with Clear(). Callers log Outcome, Reason and
# ExitCode only.

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$script:WslExe = 'C:\Windows\System32\wsl.exe'
$script:BrokerPath = '/usr/local/sbin/aap-runner-broker'
$script:MaxReplyBytes = 20480
$script:MaxRequestBytes = 4096
$script:MaxJitBytes = 16384
$script:Pattern = @{
    time           = '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z'
    lease_id       = '^l-[0-9a-f]{32}\z'
    nonce          = '^[0-9a-f]{32}\z'
    reservation_id = '^r-[0-9a-f]{16}\z'
    generation     = '^(win25-vs2026-x64|ubuntu-24\.04-x64)/[0-9]{8}\.[0-9]+\.[0-9]+-aap\.[0-9]+\z'
    runner_name    = '^aap-(w|l)-[1-5]-[0-9]{1,9}-[0-9a-f]{8}\z'
    jit            = '^[A-Za-z0-9+/=_-]+\z'
    distro         = '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z'
}
$script:Profiles = @('win25-vs2026-x64', 'ubuntu-24.04-x64')
$script:Refusals = @('replay', 'expired', 'clock_skew', 'stale_generation', 'malformed', 'unknown_profile',
    'lease_limit', 'github_error', 'rate_limited', 'not_found')
# validate.py's secret shapes: never valid in any broker document.
$script:SecretValue = 'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|SYNTHETIC-JIT-MARKER'
$script:Kinds = @('lease_request', 'release_request', 'status_request', 'lease_response', 'release_response',
    'status_response', 'audit')
# broker.schema.json, one entry per kind: field -> rule. A leading ? allows null.
$script:Shapes = @{
    lease_request    = [ordered]@{ schema = 'one'; kind = 'kind'; lease_id = 'lease_id'; reservation_id = 'reservation_id'
        lease_generation = 'int:999999999'; slot = 'int:5'; profile = 'profile'; image_generation = 'generation'
        nonce = 'nonce'; issued_at = 'time' }
    release_request  = [ordered]@{ schema = 'one'; kind = 'kind'; lease_id = 'lease_id'; nonce = 'nonce'; issued_at = 'time' }
    status_request   = [ordered]@{ schema = 'one'; kind = 'kind'; lease_id = 'lease_id'; nonce = 'nonce'; issued_at = 'time' }
    lease_response   = [ordered]@{ schema = 'one'; kind = 'kind'; lease_id = 'lease_id'; result = 'enum:issued|refused'
        reason = 'reason'; runner_id = '?int:9007199254740991'; runner_name = '?runner_name'; expires_at = '?time'
        jit_config = '?jit' }
    release_response = [ordered]@{ schema = 'one'; kind = 'kind'; lease_id = 'lease_id'
        result = 'enum:deregistered|already_gone|refused|retry'; reason = 'reason' }
    status_response  = [ordered]@{ schema = 'one'; kind = 'kind'; lease_id = 'lease_id'; result = 'enum:ok|refused'
        reason = 'reason'; runner = '?runner' }
    audit            = [ordered]@{ schema = 'one'; kind = 'kind'; at = 'time'; op = 'enum:lease|release|status|expire'
        lease_id = 'lease_id'; reservation_id = '?reservation_id'; lease_generation = '?int:999999999'
        profile = '?profile'; image_generation = '?generation'
        outcome = 'enum:issued|refused|deregistered|already_gone|retry|online|offline|absent'; reason = 'reason'
        runner_id = '?int:9007199254740991'; runner_name = '?runner_name' }
}
$script:NumberRe = [regex]'\G-?(?:0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?'
$script:QuoteOrSlash = [char[]]@('"', '\')
$script:JitKey = [Text.Encoding]::ASCII.GetBytes('"jit_config"')

# ---- strict JSON -----------------------------------------------------------

function Skip-AapJsonSpace($St) {
    while ($St.I -lt $St.T.Length) {
        $c = $St.T[$St.I]
        if ($c -ne ' ' -and $c -ne "`t" -and $c -ne "`n" -and $c -ne "`r") { return }
        $St.I++
    }
}

function Read-AapJsonString($St) {
    $St.I++
    $sb = New-Object Text.StringBuilder
    while ($true) {
        $j = $St.T.IndexOfAny($script:QuoteOrSlash, $St.I)
        if ($j -lt 0) { throw 'unterminated string' }
        $chunk = $St.T.Substring($St.I, $j - $St.I)
        if ($chunk -match '[\x00-\x1f]') { throw 'control character in a string' }
        [void]$sb.Append($chunk)
        $St.I = $j + 1
        if ($St.T[$j] -eq '"') { return $sb.ToString() }
        if ($St.I -ge $St.T.Length) { throw 'bad escape' }
        $e = [string]$St.T[$St.I]
        $St.I++
        # \uXXXX is refused: no broker document needs one.
        switch -CaseSensitive ($e) {
            '"' { [void]$sb.Append('"') }
            '\' { [void]$sb.Append('\') }
            '/' { [void]$sb.Append('/') }
            'b' { [void]$sb.Append("`b") }
            'f' { [void]$sb.Append("`f") }
            'n' { [void]$sb.Append("`n") }
            'r' { [void]$sb.Append("`r") }
            't' { [void]$sb.Append("`t") }
            default { throw 'unsupported escape' }
        }
    }
}

function Read-AapJsonObject($St, [int]$Depth) {
    if ($Depth -ge 4) { throw 'nested too deep' }
    $St.I++
    $o = New-Object Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
    Skip-AapJsonSpace $St
    if ($St.I -lt $St.T.Length -and $St.T[$St.I] -eq '}') {
        $St.I++
        return $o
    }
    while ($true) {
        Skip-AapJsonSpace $St
        if ($St.I -ge $St.T.Length -or $St.T[$St.I] -ne '"') { throw 'expected a key' }
        $k = Read-AapJsonString $St
        if ($o.Contains($k)) { throw 'duplicate key' }
        Skip-AapJsonSpace $St
        if ($St.I -ge $St.T.Length -or $St.T[$St.I] -ne ':') { throw 'expected a colon' }
        $St.I++
        $o.Add($k, (Read-AapJsonValue $St ($Depth + 1)))
        Skip-AapJsonSpace $St
        if ($St.I -ge $St.T.Length) { throw 'end of input' }
        $c = $St.T[$St.I]
        $St.I++
        if ($c -eq '}') { return $o }
        if ($c -ne ',') { throw 'expected a comma' }
    }
}

function Read-AapJsonValue($St, [int]$Depth) {
    Skip-AapJsonSpace $St
    if ($St.I -ge $St.T.Length) { throw 'end of input' }
    $c = $St.T[$St.I]
    if ($c -eq '{') { return (Read-AapJsonObject $St $Depth) }
    if ($c -eq '"') { return (Read-AapJsonString $St) }
    foreach ($word in @('true', 'false', 'null')) {
        if ($St.I + $word.Length -le $St.T.Length -and [string]::CompareOrdinal($St.T, $St.I, $word, 0, $word.Length) -eq 0) {
            $St.I += $word.Length
            if ($word -ceq 'true') { return $true }
            if ($word -ceq 'false') { return $false }
            return $null
        }
    }
    $m = $script:NumberRe.Match($St.T, $St.I)
    if (-not $m.Success) { throw 'unexpected character' }
    $St.I += $m.Length
    $n = 0L
    if (-not $m.Groups[1].Success -and -not $m.Groups[2].Success -and
        [long]::TryParse($m.Value, [Globalization.NumberStyles]::AllowLeadingSign, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) {
        return $n
    }
    # A fraction, an exponent or more than 64 bits: a number no integer field accepts.
    return [double]::Parse($m.Value, [Globalization.CultureInfo]::InvariantCulture)
}

# Strict JSON for broker documents: objects (nested at most 4 deep), strings,
# integers (as [long]), other numbers (as [double]), true, false, null. Arrays,
# NaN, a duplicate key, a raw control character and trailing text are refused.
# Keys are case-sensitive. Returns an ordered dictionary or $null; never throws,
# never echoes the input.
function ConvertFrom-AapBrokerJson {
    param([string]$Text)
    $st = @{ T = $Text; I = 0 }
    try {
        $v = Read-AapJsonValue $st 0
        Skip-AapJsonSpace $st
        if ($st.I -ne $st.T.Length -or -not ($v -is [Collections.Specialized.OrderedDictionary])) { return $null }
        return $v
    } catch {
        return $null
    }
}

# Compact JSON of a request built here (or a document whose values were
# already checked): strings must need no escaping.
function ConvertTo-AapBrokerJson($Map) {
    $parts = foreach ($k in $Map.Keys) {
        $v = $Map[$k]
        if ($null -eq $v) {
            $json = 'null'
        } elseif ($v -is [bool]) {
            $json = if ($v) { 'true' } else { 'false' }
        } elseif ($v -is [string]) {
            if ($v -cmatch '[^\x20-\x21\x23-\x5b\x5d-\x7e]') { throw 'a broker string needs escaping' }
            $json = '"' + $v + '"'
        } elseif ($v -is [int] -or $v -is [long]) {
            $json = $v.ToString([Globalization.CultureInfo]::InvariantCulture)
        } elseif ($v -is [double]) {
            # Python writes 1.0, not 1: keep the size check the same as validate.py.
            $json = $v.ToString('R', [Globalization.CultureInfo]::InvariantCulture)
            if ($json -notmatch '[.Ee]') { $json += '.0' }
        } elseif ($v -is [Collections.IDictionary]) {
            $json = ConvertTo-AapBrokerJson $v
        } else {
            throw 'unsupported broker value type'
        }
        '"' + $k + '":' + $json
    }
    return '{' + (@($parts) -join ',') + '}'
}

# ---- contract checks -------------------------------------------------------

function Test-AapBrokerValue($Value, [string]$Rule, [string]$Kind) {
    if ($Rule.StartsWith('?')) {
        if ($null -eq $Value) { return $true }
        $Rule = $Rule.Substring(1)
    }
    if ($null -eq $Value) { return $false }
    $integer = ($Value -is [int]) -or ($Value -is [long])
    if ($Rule -ceq 'one') { return ($integer -or ($Value -is [double])) -and $Value -eq 1 }
    if ($Rule -ceq 'kind') { return ($Value -is [string]) -and $Value -ceq $Kind }
    if ($Rule -ceq 'reason') { return ($Value -is [string]) -and ($Value -ceq 'ok' -or $script:Refusals -ccontains $Value) }
    if ($Rule -ceq 'profile') { return ($Value -is [string]) -and $script:Profiles -ccontains $Value }
    if ($Rule -ceq 'jit') {
        return ($Value -is [string]) -and $Value.Length -ge 1 -and $Value.Length -le $script:MaxJitBytes -and $Value -cmatch $script:Pattern.jit
    }
    if ($Rule -ceq 'runner') {
        if (-not ($Value -is [Collections.Specialized.OrderedDictionary]) -or $Value.Count -ne 2 -or
            -not $Value.Contains('status') -or -not $Value.Contains('busy')) { return $false }
        return ($Value['status'] -is [string]) -and (@('online', 'offline', 'absent') -ccontains $Value['status']) -and ($Value['busy'] -is [bool])
    }
    if ($Rule.StartsWith('int:')) { return $integer -and $Value -ge 1 -and $Value -le [long]$Rule.Substring(4) }
    if ($Rule.StartsWith('enum:')) { return ($Value -is [string]) -and ($Rule.Substring(5).Split('|') -ccontains $Value) }
    return ($Value -is [string]) -and $Value -cmatch $script:Pattern[$Rule]
}

function Test-AapBrokerSecretShape($Value) {
    if ($Value -is [string]) { return $Value -cmatch $script:SecretValue }
    if ($Value -is [Collections.IDictionary]) {
        foreach ($v in $Value.Values) {
            if (Test-AapBrokerSecretShape $v) { return $true }
        }
    }
    return $false
}

# One parsed broker document against broker.schema.json and the contract's
# cross-field rules, as parity/contracts/validate.py checks it. Returns $null
# when it holds, else the first error (field names only, never a value).
function Test-AapBrokerDocument {
    param($Document)
    if (-not ($Document -is [Collections.Specialized.OrderedDictionary])) { return '$: expected an object' }
    $kind = $null
    if ($Document.Contains('kind')) { $kind = $Document['kind'] }
    if (-not ($kind -is [string]) -or -not ($script:Kinds -ccontains $kind)) { return '$: matches no broker document kind' }
    $shape = $script:Shapes[$kind]
    $names = @($shape.Keys)
    foreach ($name in $names) {
        if (-not $Document.Contains($name)) { return "`$: missing required property '$name'" }
    }
    foreach ($name in $Document.Keys) {
        if (-not ($names -ccontains $name)) { return "`$: unexpected property '$name'" }
    }
    foreach ($name in $names) {
        if (-not (Test-AapBrokerValue $Document[$name] $shape[$name] $kind)) { return "`$.$($name): invalid value" }
    }
    if (Test-AapBrokerSecretShape $Document) { return '$: a value has a token or private-key shape' }
    if ($kind.EndsWith('_request') -and (ConvertTo-AapBrokerJson $Document).Length -gt $script:MaxRequestBytes) {
        return 'request larger than 4096 bytes'
    }
    if ($kind -ceq 'lease_response') {
        $missing = $false
        $present = $false
        foreach ($f in @('jit_config', 'runner_id', 'runner_name', 'expires_at')) {
            if ($null -eq $Document[$f]) { $missing = $true } else { $present = $true }
        }
        if ($Document['result'] -ceq 'issued') {
            if ($Document['reason'] -cne 'ok' -or $missing) {
                return 'an issued lease carries reason ok, jit_config, runner_id, runner_name and expires_at'
            }
        } elseif ($Document['reason'] -ceq 'ok' -or $present) {
            return 'a refused lease carries a refusal reason and no registration material'
        }
    }
    if ($kind -ceq 'status_response') {
        if (($Document['result'] -ceq 'ok') -ne ($Document['reason'] -ceq 'ok')) { return 'status result ok exactly when reason ok' }
        if ($Document['result'] -cne 'ok' -and $null -ne $Document['runner']) { return 'a refused status carries no runner state' }
    }
    # The audit record's secret-key rule is implied: it allows no other field.
    return $null
}

# ---- transport -------------------------------------------------------------

# Starts FileName hidden with Arguments, writes StdIn and closes it, then reads
# at most MaxStdoutBytes of stdout and drains stderr (dropped) until both end
# or the deadline passes. Returns ExitCode, Stdout (bytes), TimedOut, Overflow;
# on a timeout or overflow Stdout is $null and the process is killed.
function Invoke-AapBrokerProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [byte[]]$StdIn = @(),
        [int]$TimeoutSeconds = 60,
        [int]$MaxStdoutBytes = 20480
    )
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['WSL_UTF8'] = '1'
    $psi.EnvironmentVariables.Remove('WSLENV')
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $buf = New-Object byte[] ($MaxStdoutBytes + 1)
    $n = 0
    $p = [Diagnostics.Process]::Start($psi)
    try {
        try {
            $p.StandardInput.BaseStream.Write($StdIn, 0, $StdIn.Length)
            $p.StandardInput.BaseStream.Flush()
        } catch {
            $null = $_   # it exited without reading; its exit code tells why
        }
        try { $p.StandardInput.Close() } catch { $null = $_ }
        $out = $p.StandardOutput.BaseStream
        $err = $p.StandardError.BaseStream
        $scratch = New-Object byte[] 4096
        $outTask = $out.ReadAsync($buf, 0, $buf.Length)
        $errTask = $err.ReadAsync($scratch, 0, $scratch.Length)
        $stopped = $null
        while ($null -eq $stopped -and ($null -ne $outTask -or $null -ne $errTask)) {
            $left = [int][Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            $tasks = [Threading.Tasks.Task[]]@(@($outTask, $errTask) | Where-Object { $null -ne $_ })
            if ($left -le 0 -or [Threading.Tasks.Task]::WaitAny($tasks, $left) -lt 0) {
                $stopped = 'timeout'
                break
            }
            if ($null -ne $outTask -and $outTask.IsCompleted) {
                $got = $outTask.Result
                if ($got -le 0) {
                    $outTask = $null
                } else {
                    $n += $got
                    if ($n -gt $MaxStdoutBytes) {
                        $stopped = 'overflow'
                        break
                    }
                    $outTask = $out.ReadAsync($buf, $n, $buf.Length - $n)
                }
            }
            if ($null -ne $errTask -and $errTask.IsCompleted) {
                if ($errTask.Result -le 0) { $errTask = $null } else { $errTask = $err.ReadAsync($scratch, 0, $scratch.Length) }
            }
        }
        if ($null -eq $stopped) {
            $left = [int][Math]::Max(0, [Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalMilliseconds))
            if (-not $p.WaitForExit($left)) { $stopped = 'timeout' }
        }
        if ($null -ne $stopped) {
            try { $p.Kill() } catch { $null = $_ }
            return [pscustomobject]@{ ExitCode = $null; Stdout = $null; TimedOut = ($stopped -ceq 'timeout'); Overflow = ($stopped -ceq 'overflow') }
        }
        $p.WaitForExit()
        $stdout = New-Object byte[] $n
        [Array]::Copy($buf, $stdout, $n)
        return [pscustomobject]@{ ExitCode = $p.ExitCode; Stdout = $stdout; TimedOut = $false; Overflow = $false }
    } finally {
        [Array]::Clear($buf, 0, $buf.Length)
        try {
            if (-not $p.HasExited) { $p.Kill() }
        } catch {
            $null = $_
        }
        $p.Dispose()
    }
}

# The default invoker: the fixed wsl.exe command line, nothing from the caller
# but the request bytes, the timeout and the checked distro name.
function Invoke-AapBrokerWsl {
    param([byte[]]$StdIn, [int]$TimeoutSeconds, [string]$Distro)
    return Invoke-AapBrokerProcess -FileName $script:WslExe -Arguments ('-d {0} -u root --exec {1}' -f $Distro, $script:BrokerPath) `
        -StdIn $StdIn -TimeoutSeconds $TimeoutSeconds -MaxStdoutBytes $script:MaxReplyBytes
}

# Sends one request, returns @{ Outcome = reply|unavailable|bad_reply; ExitCode; Doc; Jit }.
# The reply bytes, and the JIT config cut out of them, are never a command's
# parameter value (module logging records those): they are read inline here,
# from the invoker's result, and the JIT bytes leave only as the return value.
# The reply buffer is zeroed on every path; on anything but a reply no JIT
# byte survives.
function Invoke-AapBrokerCall($Request, [string]$Reply, [scriptblock]$Invoker, [string]$Distro, [int]$TimeoutSeconds) {
    $json = ConvertTo-AapBrokerJson $Request
    $why = Test-AapBrokerDocument (ConvertFrom-AapBrokerJson $json)
    if ($null -ne $why) { throw "refusing to send a request the broker contract rejects: $why" }
    $bytes = [Text.Encoding]::ASCII.GetBytes($json)
    try {
        if ($null -ne $Invoker) {
            $r = & $Invoker $bytes $TimeoutSeconds
        } else {
            $r = Invoke-AapBrokerWsl -StdIn $bytes -TimeoutSeconds $TimeoutSeconds -Distro $Distro
        }
    } catch {
        return @{ Outcome = 'unavailable'; ExitCode = $null; Doc = $null; Jit = $null }
    }
    $code = $null
    $out = $null
    $timedOut = $false
    $overflow = $false
    if ($null -ne $r) {
        $props = $r.PSObject.Properties
        if ($null -ne $props['ExitCode']) { $code = $props['ExitCode'].Value }
        if ($null -ne $props['Stdout']) { $out = $props['Stdout'].Value }
        if ($null -ne $props['TimedOut']) { $timedOut = [bool]$props['TimedOut'].Value }
        if ($null -ne $props['Overflow']) { $overflow = [bool]$props['Overflow'].Value }
    }
    $jit = $null
    try {
        # More than 20 KiB is a reply that broke the contract, whatever the exit code.
        if ($overflow) { return @{ Outcome = 'bad_reply'; ExitCode = $code; Doc = $null; Jit = $null } }
        if ($timedOut -or -not ($code -is [int]) -or $code -ne 0) {
            return @{ Outcome = 'unavailable'; ExitCode = $code; Doc = $null; Jit = $null }
        }
        $bad = @{ Outcome = 'bad_reply'; ExitCode = 0; Doc = $null; Jit = $null }
        if (-not ($out -is [byte[]])) { return $bad }
        $n = $out.Length
        while ($n -gt 0 -and ($out[$n - 1] -eq 10 -or $out[$n - 1] -eq 13)) { $n-- }
        if ($n -eq 0 -or $n -gt $script:MaxReplyBytes) { return $bad }
        $keys = New-Object Collections.Generic.List[int]
        $key = $script:JitKey
        for ($i = 0; $i -lt $n; $i++) {
            $b = $out[$i]
            if ($b -lt 0x20 -or $b -gt 0x7e -or $b -eq 0x5c) { return $bad }
            if ($b -eq 0x22 -and $i + $key.Length -le $n) {
                $k = 1
                while ($k -lt $key.Length -and $out[$i + $k] -eq $key[$k]) { $k++ }
                if ($k -eq $key.Length) { $keys.Add($i) }
            }
        }
        if ($keys.Count -ne [int]($Reply -ceq 'lease_response')) { return $bad }
        if ($keys.Count -eq 1) {
            $at = $keys[0] + $key.Length
            if ($at -ge $n -or $out[$at] -ne 0x3a) { return $bad }
            $at++
            if ($at -lt $n -and $out[$at] -eq 0x22) {
                $start = $at + 1
                $end = $start
                # A-Z a-z 0-9 + / = _ - (the schema's jit_config pattern).
                while ($end -lt $n) {
                    $b = $out[$end]
                    if (-not (($b -ge 0x41 -and $b -le 0x5a) -or ($b -ge 0x61 -and $b -le 0x7a) -or ($b -ge 0x30 -and $b -le 0x39) -or
                            $b -eq 0x2b -or $b -eq 0x2f -or $b -eq 0x3d -or $b -eq 0x5f -or $b -eq 0x2d)) { break }
                    $end++
                }
                if ($end -ge $n -or $out[$end] -ne 0x22 -or $end -eq $start -or ($end - $start) -gt $script:MaxJitBytes) { return $bad }
                $jit = New-Object byte[] ($end - $start)
                [Array]::Copy($out, $start, $jit, 0, $jit.Length)
                for ($i = $start; $i -lt $end; $i++) { $out[$i] = 0x41 }
            } elseif ($at + 4 -gt $n -or [Text.Encoding]::ASCII.GetString($out, $at, 4) -cne 'null') {
                return $bad
            }
        }
        # The text holds a run of A in place of the JIT config.
        $text = [Text.Encoding]::ASCII.GetString($out, 0, $n)
        $doc = ConvertFrom-AapBrokerJson $text
        if ($null -eq $doc -or $null -ne (Test-AapBrokerDocument $doc) -or $doc['kind'] -cne $Reply) { return $bad }
        $parsed = @{ Outcome = 'reply'; ExitCode = 0; Doc = $doc; Jit = $jit }
        $jit = $null
        return $parsed
    } finally {
        if ($out -is [byte[]]) { [Array]::Clear($out, 0, $out.Length) }
        if ($null -ne $jit) { [Array]::Clear($jit, 0, $jit.Length) }
    }
}

# ---- public ----------------------------------------------------------------

function Get-AapBrokerTime {
    return [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
}

function New-AapBrokerHex([int]$Bytes) {
    $b = New-Object byte[] $Bytes
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    return (($b | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Assert-AapBrokerArgument([bool]$Ok, [string]$Name) {
    if (-not $Ok) { throw "invalid broker argument: $Name" }
}

function Assert-AapBrokerCommon([string]$LeaseId, [string]$Distro, [int]$TimeoutSeconds) {
    Assert-AapBrokerArgument ($LeaseId -cmatch $script:Pattern.lease_id) 'LeaseId'
    Assert-AapBrokerArgument ($Distro -cmatch $script:Pattern.distro) 'Distro'
    Assert-AapBrokerArgument ($TimeoutSeconds -ge 1 -and $TimeoutSeconds -le 600) 'TimeoutSeconds'
}

function New-AapBrokerResult([string]$LeaseId, [string]$Outcome, $Reason, $ExitCode) {
    return [pscustomobject]@{
        LeaseId      = $LeaseId
        Outcome      = $Outcome
        Reason       = $Reason
        ExitCode     = $ExitCode
        RunnerId     = $null
        RunnerName   = $null
        ExpiresAt    = $null
        RunnerStatus = $null
        RunnerBusy   = $null
        JitConfig    = $null
    }
}

# A new lease id from the CSPRNG. Persist it (journal) before the lease call:
# every teardown must release it, whatever the lease call returned.
function New-AapBrokerLeaseId {
    return 'l-' + (New-AapBrokerHex 16)
}

# Leases one runner registration. Outcome: issued (JitConfig: WriteTo(stream)
# it into the guest transport before ExpiresAt, then Clear() it), refused
# (Reason is the broker's), unavailable (wsl.exe failed, timed out or exited
# non-zero; ExitCode), bad_reply (exit 0 but the reply broke the contract).
# Anything but issued means no registration; the slot goes to deleting and its
# teardown still sends Invoke-AapBrokerRelease with this lease id.
function Invoke-AapBrokerLease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LeaseId,
        [Parameter(Mandatory = $true)][string]$ReservationId,
        [Parameter(Mandatory = $true)][long]$LeaseGeneration,
        [Parameter(Mandatory = $true)][int]$Slot,
        [Parameter(Mandatory = $true)][string]$RunnerProfile,
        [Parameter(Mandatory = $true)][string]$ImageGeneration,
        [scriptblock]$Invoker = $null,
        [string]$Distro = 'aap-runner',
        [int]$TimeoutSeconds = 60
    )
    Assert-AapBrokerCommon $LeaseId $Distro $TimeoutSeconds
    Assert-AapBrokerArgument ($ReservationId -cmatch $script:Pattern.reservation_id) 'ReservationId'
    Assert-AapBrokerArgument ($LeaseGeneration -ge 1 -and $LeaseGeneration -le 999999999) 'LeaseGeneration'
    Assert-AapBrokerArgument ($Slot -ge 1 -and $Slot -le 5) 'Slot'
    Assert-AapBrokerArgument ($script:Profiles -ccontains $RunnerProfile) 'RunnerProfile'
    Assert-AapBrokerArgument ($ImageGeneration -cmatch $script:Pattern.generation -and
        $ImageGeneration.StartsWith($RunnerProfile + '/', [StringComparison]::Ordinal)) 'ImageGeneration'
    $letter = if ($RunnerProfile -ceq 'win25-vs2026-x64') { 'w' } else { 'l' }
    $name = 'aap-{0}-{1}-{2}-{3}' -f $letter, $Slot, $LeaseGeneration, $ReservationId.Substring(2, 8)
    $request = [ordered]@{
        schema = 1; kind = 'lease_request'; lease_id = $LeaseId; reservation_id = $ReservationId
        lease_generation = $LeaseGeneration; slot = $Slot; profile = $RunnerProfile; image_generation = $ImageGeneration
        nonce = (New-AapBrokerHex 16); issued_at = (Get-AapBrokerTime)
    }
    $call = Invoke-AapBrokerCall $request 'lease_response' $Invoker $Distro $TimeoutSeconds
    $jit = $call.Jit
    $call.Jit = $null
    $handed = $false
    try {
        if ($call.Outcome -cne 'reply') { return (New-AapBrokerResult $LeaseId $call.Outcome $null $call.ExitCode) }
        $doc = $call.Doc
        $issued = $doc['result'] -ceq 'issued'
        if ($doc['lease_id'] -cne $LeaseId -or ($issued -and $doc['runner_name'] -cne $name)) {
            return (New-AapBrokerResult $LeaseId 'bad_reply' $null 0)
        }
        $result = New-AapBrokerResult $LeaseId $doc['result'] $doc['reason'] 0
        if ($issued) {
            $result.RunnerId = $doc['runner_id']
            $result.RunnerName = $doc['runner_name']
            $result.ExpiresAt = $doc['expires_at']
            # The JIT config as an object whose only property is Length, so it
            # formats, serializes and logs as nothing else. WriteTo(stream)
            # writes the bytes; Clear() zeroes them. Built here, with .NET
            # calls only, so the bytes are never a command's parameter value.
            $secret = [pscustomobject]@{ Length = $jit.Length }
            $writeTo = { param([IO.Stream]$Stream) $Stream.Write($jit, 0, $jit.Length) }.GetNewClosure()
            $clear = { [Array]::Clear($jit, 0, $jit.Length) }.GetNewClosure()
            $secret.PSObject.Methods.Add([Management.Automation.PSScriptMethod]::new('WriteTo', $writeTo))
            $secret.PSObject.Methods.Add([Management.Automation.PSScriptMethod]::new('Clear', $clear))
            $result.JitConfig = $secret
            $handed = $true
        }
        return $result
    } finally {
        if (-not $handed -and $null -ne $jit) { [Array]::Clear($jit, 0, $jit.Length) }
    }
}

# Mandatory at every teardown, with the lease id only. Outcome deregistered or
# already_gone closes the lease (the teardown proof's runner part); retry means
# GitHub failed and the slot stays deleting; refused, unavailable and
# bad_reply as for a lease.
function Invoke-AapBrokerRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LeaseId,
        [scriptblock]$Invoker = $null,
        [string]$Distro = 'aap-runner',
        [int]$TimeoutSeconds = 60
    )
    Assert-AapBrokerCommon $LeaseId $Distro $TimeoutSeconds
    $request = [ordered]@{ schema = 1; kind = 'release_request'; lease_id = $LeaseId; nonce = (New-AapBrokerHex 16); issued_at = (Get-AapBrokerTime) }
    $call = Invoke-AapBrokerCall $request 'release_response' $Invoker $Distro $TimeoutSeconds
    if ($call.Outcome -cne 'reply') { return (New-AapBrokerResult $LeaseId $call.Outcome $null $call.ExitCode) }
    $doc = $call.Doc
    $closed = @('deregistered', 'already_gone') -ccontains $doc['result']
    if ($doc['lease_id'] -cne $LeaseId -or $closed -ne ($doc['reason'] -ceq 'ok')) { return (New-AapBrokerResult $LeaseId 'bad_reply' $null 0) }
    return (New-AapBrokerResult $LeaseId $doc['result'] $doc['reason'] 0)
}

# Read-only. Outcome ok with RunnerStatus (online, offline, absent) and
# RunnerBusy, for the allocator's heartbeat-quarantine decision; refused,
# unavailable and bad_reply as for a lease.
function Invoke-AapBrokerStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LeaseId,
        [scriptblock]$Invoker = $null,
        [string]$Distro = 'aap-runner',
        [int]$TimeoutSeconds = 60
    )
    Assert-AapBrokerCommon $LeaseId $Distro $TimeoutSeconds
    $request = [ordered]@{ schema = 1; kind = 'status_request'; lease_id = $LeaseId; nonce = (New-AapBrokerHex 16); issued_at = (Get-AapBrokerTime) }
    $call = Invoke-AapBrokerCall $request 'status_response' $Invoker $Distro $TimeoutSeconds
    if ($call.Outcome -cne 'reply') { return (New-AapBrokerResult $LeaseId $call.Outcome $null $call.ExitCode) }
    $doc = $call.Doc
    if ($doc['lease_id'] -cne $LeaseId -or ($doc['result'] -ceq 'ok' -and $null -eq $doc['runner'])) {
        return (New-AapBrokerResult $LeaseId 'bad_reply' $null 0)
    }
    $result = New-AapBrokerResult $LeaseId $doc['result'] $doc['reason'] 0
    if ($doc['result'] -ceq 'ok') {
        $result.RunnerStatus = $doc['runner']['status']
        $result.RunnerBusy = $doc['runner']['busy']
    }
    return $result
}

Export-ModuleMember -Function New-AapBrokerLeaseId, Invoke-AapBrokerLease, Invoke-AapBrokerRelease, Invoke-AapBrokerStatus,
    Test-AapBrokerDocument, ConvertFrom-AapBrokerJson
