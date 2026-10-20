# Host-wide runner slot allocator (ledger item P09). Windows PowerShell 5.1 and PowerShell 7.5+.
#
# Contract: parity/contracts/allocator.md, version 2 (allocator.json schema 2). The schema next to this module,
# allocator.schema.json, is a byte copy of parity/contracts/allocator.schema.json (a test checks it).
# Test-AapAllocatorState implements the same checks, in the same order and with the same messages,
# as parity/contracts/validate.py (schema subset, secret-value scan, sem_allocator).
#
# State: <Root>\allocator.json, written only here: whole-file atomic replace from
# <Root>\allocator.json.tmp, revision + 1 on every write, validated before every write. Every
# read-modify-write holds <Root>\allocator.lock, opened with no sharing, with a bounded wait (30 s
# default); a timeout returns Status 'error' and admits nothing. No named kernel object is used.
# Before anything else every call checks the folder like install-supervisor.ps1 checks its folders.
#
# Every exported function returns one object: Ok, Status ('ok' | 'unchanged' | 'ignored' |
# 'refused' | 'error'), Reason (a fixed code, or $null), Detail (one line), TrustRelaxed, plus the
# operation's own fields. INTEGRATION.md lists the reason codes and the callbacks.

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# SYSTEM, Administrators, TrustedInstaller: the same list as install-supervisor.ps1 ($AapAdminSids).
$script:AdminSids = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
$script:LiveStates = @('creating', 'ready', 'busy', 'draining', 'collecting', 'deleting', 'quarantined')
# ARCHITECTURE.md section 2. reconciled is reached only through Complete-AapTeardown (or the
# legacy release), quarantined -> ready/busy only through a validated heartbeat. busy -> deleting
# is not a plain edge: only a hostile reply (Set-AapSlotState -QuarantineKind hostile_guest, in one
# write) and reconcile, for a busy slot whose VM is gone (Move-AapDown), take it.
$script:Edges = @{
    creating    = @('ready', 'deleting', 'quarantined')
    ready       = @('busy', 'draining', 'quarantined')
    busy        = @('draining', 'collecting', 'quarantined')
    draining    = @('collecting', 'quarantined')
    collecting  = @('deleting', 'quarantined')
    deleting    = @('quarantined')
    quarantined = @('deleting')
}
# Which states may enter each quarantine kind. unknown_vm is only created by Invoke-AapReconcile.
$script:QuarantineFrom = @{
    heartbeat       = @('ready', 'busy')
    crash           = @('creating', 'ready', 'busy', 'draining', 'collecting')
    teardown_failed = @('deleting')
}
# hostile_guest (Set-AapSlotState) is immediate and final: from a guest state straight to deleting;
# from one of these quarantines the kind is rewritten first (rule 10 holds at every write).
$script:GuestStates = @('creating', 'ready', 'busy', 'draining', 'collecting')
$script:HostileOver = @('heartbeat', 'crash', 'hostile_guest')
# Legal edge paths down to deleting (draining always passes through collecting).
$script:ToDeleting = @{
    creating = @('deleting'); ready = @('draining', 'collecting', 'deleting'); busy = @('deleting')
    draining = @('collecting', 'deleting'); collecting = @('deleting'); quarantined = @('deleting'); deleting = @()
}
$script:TimeFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
$script:Inv = [Globalization.CultureInfo]::InvariantCulture
$script:MissedSeconds = 90       # three missed 30 s heartbeats
$script:HeartbeatSeconds = 30    # heartbeat_at is written at most this often
$script:StatusMaxAge = 90        # a legacy heartbeat counts only from a sample at most this old
$script:KeepReconciled = 5       # reconciled entries kept before pruning (schema allows 10 entries)
$script:SecretValue = '(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|SYNTHETIC-JIT-MARKER)'
$script:Known = @('$schema', '$id', '$defs', '$comment', 'title', 'description', 'x-contract-version', 'x-owner',
    'type', 'enum', 'const', 'properties', 'required', 'additionalProperties', 'items',
    'minItems', 'maxItems', 'uniqueItems', 'minimum', 'maximum', 'minLength', 'maxLength',
    'pattern', '$ref', 'oneOf', 'anyOf', 'allOf', 'not', 'if', 'then', 'else')
# ponytail: validate.py knows these too; allocator.schema.json uses none of them, so a schema
# revision that needs one fails closed here until it is implemented.
$script:NotImplemented = @('oneOf', 'allOf', 'not', 'if', 'then', 'else')
$script:Fault = $null            # test hook: a fault point name; the process kills itself there
$script:Seen = @{}               # highest revision applied per folder, in this process
$script:Warned = @{}
$script:Relaxed = $false         # the current call's relaxed-trust flag (one call at a time)
$script:Schema = $null
$script:DateKind = $null
# Every file this module keeps in the capacity folder (trust-checked on every call).
$script:StateFiles = @('allocator.json', 'allocator.json.tmp', 'allocator.json.bak', 'allocator.lock', 'allocator.log', 'allocator.log.1',
    'unresolved.json', 'unresolved.json.tmp', 'unresolved.json.bak', 'host.measured.json', 'host.measured.json.tmp', 'host.measured.json.bak')

# ---- small helpers ----------------------------------------------------------------------------

function Get-AapUtcNow { [DateTime]::UtcNow }

function Format-AapTime([datetime]$Time) {
    if ($Time.Kind -eq [DateTimeKind]::Unspecified) { $Time = [DateTime]::SpecifyKind($Time, [DateTimeKind]::Utc) }
    $Time.ToUniversalTime().ToString($script:TimeFormat, $script:Inv)
}

function ConvertFrom-AapTime([string]$Text) {
    [DateTime]::ParseExact($Text, $script:TimeFormat, $script:Inv, [Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal')
}

# An RFC 3339 time from status.json (a string, or a DateTime from a pwsh 7 reader) as UTC, else $null.
function ConvertFrom-AapRfc3339($Value) {
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { return $null }
        return $Value.ToUniversalTime()
    }
    if ($Value -is [string] -and $Value -cmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,7})?(Z|[+-]\d{2}:\d{2})\z') {
        return [DateTimeOffset]::Parse($Value, $script:Inv).UtcDateTime
    }
    return $null
}

function Invoke-AapFault([string]$Point) {
    if ($script:Fault -ceq $Point) {
        [Diagnostics.Process]::GetCurrentProcess().Kill()
        Start-Sleep -Seconds 30
    }
}

# One line of text: control and line-separator characters (an echoed id, a VM name, a broker
# status) become spaces.
function ConvertTo-AapLine([string]$Text) { $Text -replace '[\x00-\x1f\x7f\u0085\u2028\u2029]', ' ' }

function New-AapResult {
    param([string]$Status, $Reason = $null, [string]$Detail = '', [Collections.IDictionary]$Data = $null)
    $o = [ordered]@{ Ok = ($Status -eq 'ok' -or $Status -eq 'unchanged'); Status = $Status; Reason = $Reason; Detail = (ConvertTo-AapLine $Detail); TrustRelaxed = [bool]$script:Relaxed }
    if ($Data) { foreach ($k in $Data.Keys) { $o[$k] = $Data[$k] } }
    [pscustomobject]$o
}

function Test-AapInt($v) {
    $v -is [int] -or $v -is [long] -or $v -is [int16] -or $v -is [byte] -or $v -is [sbyte] -or
    $v -is [uint16] -or $v -is [uint32] -or $v -is [uint64] -or $v -is [Numerics.BigInteger]
}

function Test-AapNumber($v) {
    if (Test-AapInt $v) { return $true }
    if ($v -is [double] -or $v -is [single]) { return -not ([double]::IsNaN($v) -or [double]::IsInfinity($v)) }
    return $v -is [decimal]
}

# A property by exact (ordinal) name; PowerShell's own lookup ignores case, JSON does not.
function Get-AapProp($Object, [string]$Name) {
    foreach ($p in $Object.PSObject.Properties) { if ([string]::Equals($p.Name, $Name, [StringComparison]::Ordinal)) { return $p } }
    return $null
}

# A field of a hashtable or object, $null when absent. Arrays come back unrolled: wrap in @().
function Get-AapField($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $p = Get-AapProp $Object $Name
    if ($p) { return $p.Value }
    return $null
}

function Get-AapFloorDiv($A, $B) { [long][Math]::Floor([double]$A / [double]$B) }

function Get-AapMem($R) { [long]$R.mem_gib + [long][Math]::Ceiling([double]$R.mem_overhead_mib / 1024) }

# How an admitted reservation leaves admission: 0 ready -> draining, 1 creating -> deleting (no job
# yet; a VM needs its vm_id for that edge), 2 busy -> draining (the job keeps running), 3 cannot
# move now (a heartbeat quarantine, or a VM still creating without a vm_id).
function Get-AapLeaveRank($R) {
    if ($R.state -ceq 'ready') { return 0 }
    if ($R.state -ceq 'creating' -and ($R.backend -ceq 'wsl-legacy' -or $null -ne $R.vm_id)) { return 1 }
    if ($R.state -ceq 'busy') { return 2 }
    return 3
}

function Get-AapVmNameOf($R) { Get-AapVmName -Profile $R.profile -Slot $R.slot -LeaseGeneration $R.lease_generation -ReservationId $R.reservation_id }

function Test-AapAdmitted($R) {
    ($R.state -ceq 'creating' -or $R.state -ceq 'ready' -or $R.state -ceq 'busy' -or
    ($R.state -ceq 'quarantined' -and $R.quarantine_kind -ceq 'heartbeat'))
}

function Get-AapLive($Doc) { @($Doc.reservations | Where-Object { $script:LiveStates -ccontains $_.state }) }

function Get-AapSum($Items, [scriptblock]$Of) {
    $s = [long]0
    # foreach, not @(): @() over a List[object] throws "Argument types do not match" in PowerShell.
    foreach ($i in $Items) { if ($null -ne $i) { $s += [long](& $Of $i) } }
    $s
}

# Python's len(): code points, not UTF-16 units.
function Get-AapCodePoints([string]$Text) {
    $n = 0
    for ($i = 0; $i -lt $Text.Length; $i++) { if (-not [char]::IsLowSurrogate($Text[$i]) -or $i -eq 0 -or -not [char]::IsHighSurrogate($Text[$i - 1])) { $n++ } }
    $n
}

# ---- JSON --------------------------------------------------------------------------------------

# pwsh 7 turns ISO time strings into DateTime unless told not to (-DateKind, 7.5+). 5.1 keeps them.
function ConvertFrom-AapJson([string]$Text) {
    if ($null -eq $script:DateKind) { $script:DateKind = (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind') }
    if ($script:DateKind) { return , (ConvertFrom-Json -InputObject $Text -DateKind String) }
    if ($PSVersionTable.PSVersion.Major -ge 6) { throw 'PowerShell 6.0 to 7.4 turn ISO times into DateTime; use Windows PowerShell 5.1 or PowerShell 7.5+' }
    return , (ConvertFrom-Json -InputObject $Text)
}

function ConvertTo-AapJson($Object) { ConvertTo-Json -InputObject $Object -Depth 12 -Compress }

# At most Max bytes from one open (shared for read, write and delete, so the writer's replace
# never fails on a reader); strict UTF-8, BOM dropped. $null when the file is larger.
function Read-AapText([string]$Path, [int]$Max) {
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
    $buf = New-Object byte[] ($Max + 1)
    $n = 0
    try {
        while ($n -lt $buf.Length) {
            $got = $fs.Read($buf, $n, $buf.Length - $n)
            if ($got -le 0) { break }
            $n += $got
        }
    } finally { $fs.Dispose() }
    if ($n -gt $Max) { return $null }
    $text = (New-Object Text.UTF8Encoding($false, $true)).GetString($buf, 0, $n)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    $text
}

# Python's json.dumps for the values validate.py prints (ensure_ascii, ', ' and ': '); -SortKeys
# as json.dumps(sort_keys=True), which uniqueItems compares.
function ConvertTo-AapPyJson($Value, [switch]$SortKeys) {
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [string]) {
        $sb = New-Object Text.StringBuilder
        [void]$sb.Append('"')
        foreach ($ch in $Value.ToCharArray()) {
            $c = [int]$ch
            if ($c -eq 0x22) { [void]$sb.Append('\"') } elseif ($c -eq 0x5c) { [void]$sb.Append('\\') }
            elseif ($c -eq 0x0a) { [void]$sb.Append('\n') } elseif ($c -eq 0x0d) { [void]$sb.Append('\r') }
            elseif ($c -eq 0x09) { [void]$sb.Append('\t') } elseif ($c -eq 0x08) { [void]$sb.Append('\b') }
            elseif ($c -eq 0x0c) { [void]$sb.Append('\f') }
            elseif ($c -lt 0x20 -or $c -gt 0x7e) { [void]$sb.Append(('\u{0:x4}' -f $c)) }
            else { [void]$sb.Append($ch) }
        }
        [void]$sb.Append('"')
        return $sb.ToString()
    }
    if (Test-AapInt $Value) { return $Value.ToString($script:Inv) }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        $d = [double]$Value
        if ([Math]::Floor($d) -eq $d -and [Math]::Abs($d) -lt 1e16) { return $d.ToString('0.0', $script:Inv) }
        return ($d.ToString('R', $script:Inv) -creplace 'E', 'e')
    }
    if ($Value -is [array]) { return '[' + ((@($Value) | ForEach-Object { ConvertTo-AapPyJson $_ -SortKeys:$SortKeys }) -join ', ') + ']' }
    if ($Value -is [Management.Automation.PSCustomObject]) {
        $props = @($Value.PSObject.Properties)
        if ($SortKeys) {
            $names = [string[]]@($props | ForEach-Object { $_.Name })
            [Array]::Sort($names, [StringComparer]::Ordinal)
            $props = @($names | ForEach-Object { Get-AapProp $Value $_ })
        }
        return '{' + (($props | ForEach-Object { (ConvertTo-AapPyJson $_.Name) + ': ' + (ConvertTo-AapPyJson $_.Value -SortKeys:$SortKeys) }) -join ', ') + '}'
    }
    return [string]$Value
}

# Python's repr() of a str, for property names in messages.
function ConvertTo-AapPyRepr([string]$Text) {
    $q = "'"
    if ($Text.Contains("'") -and -not $Text.Contains('"')) { $q = '"' }
    $sb = New-Object Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        $c = [int]$ch
        if ($ch -eq '\') { [void]$sb.Append('\\') } elseif ($c -eq 0x0a) { [void]$sb.Append('\n') }
        elseif ($c -eq 0x0d) { [void]$sb.Append('\r') } elseif ($c -eq 0x09) { [void]$sb.Append('\t') }
        elseif ([string]$ch -ceq $q) { [void]$sb.Append('\' + $q) }
        elseif ($c -lt 0x20 -or $c -eq 0x7f) { [void]$sb.Append(('\x{0:x2}' -f $c)) }
        else { [void]$sb.Append($ch) }
    }
    $q + $sb.ToString() + $q
}

# ---- validation: the same checks, order and messages as parity/contracts/validate.py ----------

function Get-AapSchema {
    if ($null -eq $script:Schema) {
        $script:Schema = ConvertFrom-AapJson (Read-AapText (Join-Path $PSScriptRoot 'allocator.schema.json') 1048576)
    }
    $script:Schema
}

function Test-AapType($Value, [string]$Type) {
    switch -CaseSensitive ($Type) {
        'null' { return $null -eq $Value }
        'boolean' { return $Value -is [bool] }
        'integer' { return (Test-AapInt $Value) }
        'number' { return (Test-AapNumber $Value) }
        'string' { return $Value -is [string] }
        'array' { return $Value -is [array] }
        'object' { return $Value -is [Management.Automation.PSCustomObject] }
    }
    throw "schema uses unknown type '$Type'"
}

# validate.py _same(): booleans equal only booleans, numbers compare across int and float.
function Test-AapSame($A, $B) {
    if ($A -is [bool] -or $B -is [bool]) { return ($A -is [bool]) -and ($B -is [bool]) -and $A -eq $B }
    if ($null -eq $A -or $null -eq $B) { return ($null -eq $A) -and ($null -eq $B) }
    if ($A -is [string] -or $B -is [string]) { return ($A -is [string]) -and ($B -is [string]) -and [string]::Equals($A, $B, [StringComparison]::Ordinal) }
    if ((Test-AapNumber $A) -and (Test-AapNumber $B)) { return $A -eq $B }
    return $false
}

# validate.py check(): returns the first violation as text, or $null.
function Test-AapNode($Schema, $Value, $Root, [string]$Path) {
    if ($Schema -is [bool]) {
        if ($Schema) { return $null }
        return "${Path}: not allowed"
    }
    $names = @($Schema.PSObject.Properties | ForEach-Object { $_.Name })
    $unknown = @($names | Where-Object { $script:Known -cnotcontains $_ })
    if ($unknown.Count) {
        [Array]::Sort($unknown, [StringComparer]::Ordinal)
        return "schema at $Path uses unsupported keywords ['" + ($unknown -join "', '") + "']"
    }
    foreach ($n in $names) { if ($script:NotImplemented -ccontains $n) { return "schema at $Path uses $n, which AapCapacity does not implement" } }
    $p = Get-AapProp $Schema '$ref'
    if ($p) {
        $ref = [string]$p.Value
        if (-not $ref.StartsWith('#/$defs/', [StringComparison]::Ordinal)) { return "${Path}: only local `$defs refs are supported, got $ref" }
        $e = Test-AapNode (Get-AapProp (Get-AapProp $Root '$defs').Value $ref.Substring(8)).Value $Value $Root $Path
        if ($e) { return $e }
    }
    $p = Get-AapProp $Schema 'type'
    if ($p) {
        $types = @($p.Value)
        $ok = $false
        foreach ($t in $types) { if (Test-AapType $Value $t) { $ok = $true; break } }
        if (-not $ok) { return "${Path}: expected type $($types -join '|')" }
    }
    $p = Get-AapProp $Schema 'const'
    if ($p -and -not (Test-AapSame $Value $p.Value)) { return "${Path}: must be $(ConvertTo-AapPyJson $p.Value)" }
    $p = Get-AapProp $Schema 'enum'
    if ($p) {
        $hit = $false
        foreach ($e in @($p.Value)) { if (Test-AapSame $Value $e) { $hit = $true; break } }
        if (-not $hit) { return "${Path}: $(ConvertTo-AapPyJson $Value) not in enum" }
    }
    if ((Test-AapNumber $Value) -and -not ($Value -is [bool])) {
        $p = Get-AapProp $Schema 'minimum'
        if ($p -and $Value -lt $p.Value) { return "${Path}: below minimum $($p.Value)" }
        $p = Get-AapProp $Schema 'maximum'
        if ($p -and $Value -gt $p.Value) { return "${Path}: above maximum $($p.Value)" }
    }
    if ($Value -is [string]) {
        $p = Get-AapProp $Schema 'minLength'
        if ($p -and (Get-AapCodePoints $Value) -lt $p.Value) { return "${Path}: shorter than $($p.Value)" }
        $p = Get-AapProp $Schema 'maxLength'
        if ($p -and (Get-AapCodePoints $Value) -gt $p.Value) { return "${Path}: longer than $($p.Value)" }
        $p = Get-AapProp $Schema 'pattern'
        # validate.py _ecma(): a pattern's `$` is the end of input, as in ECMA-262 (.NET `$` would
        # also match before a final newline).
        if ($p -and -not [regex]::IsMatch($Value, [regex]::Replace([string]$p.Value, '(?<!\\)\$', '\z'))) { return "${Path}: does not match pattern $($p.Value)" }
    }
    if ($Value -is [array]) {
        $items = @($Value)
        $p = Get-AapProp $Schema 'minItems'
        if ($p -and $items.Count -lt $p.Value) { return "${Path}: fewer than $($p.Value) items" }
        $p = Get-AapProp $Schema 'maxItems'
        if ($p -and $items.Count -gt $p.Value) { return "${Path}: more than $($p.Value) items" }
        $p = Get-AapProp $Schema 'uniqueItems'
        if ($p -and $p.Value -is [bool] -and $p.Value) {
            $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
            foreach ($it in $items) { if (-not $seen.Add((ConvertTo-AapPyJson $it -SortKeys))) { return "${Path}: items not unique" } }
        }
        $p = Get-AapProp $Schema 'items'
        if ($p) {
            for ($i = 0; $i -lt $items.Count; $i++) {
                $e = Test-AapNode $p.Value $items[$i] $Root "$Path[$i]"
                if ($e) { return $e }
            }
        }
    }
    if ($Value -is [Management.Automation.PSCustomObject]) {
        $have = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
        $p = Get-AapProp $Schema 'required'
        if ($p) { foreach ($r in @($p.Value)) { if ($have -cnotcontains $r) { return "${Path}: missing required property $(ConvertTo-AapPyRepr $r)" } } }
        $props = Get-AapProp $Schema 'properties'
        $ap = Get-AapProp $Schema 'additionalProperties'
        foreach ($vp in @($Value.PSObject.Properties)) {
            $sub = $null
            if ($props) { $sub = Get-AapProp $props.Value $vp.Name }
            if ($sub) {
                $e = Test-AapNode $sub.Value $vp.Value $Root "$Path.$($vp.Name)"
                if ($e) { return $e }
            } elseif ($ap) {
                if ($ap.Value -is [bool] -and -not $ap.Value) { return "${Path}: unexpected property $(ConvertTo-AapPyRepr $vp.Name)" }
                $e = Test-AapNode $ap.Value $vp.Value $Root "$Path.$($vp.Name)"
                if ($e) { return $e }
            }
        }
    }
    $p = Get-AapProp $Schema 'anyOf'
    if ($p) {
        $errors = New-Object System.Collections.Generic.List[string]
        foreach ($sub in @($p.Value)) {
            $e = Test-AapNode $sub $Value $Root $Path
            if ($e) { $errors.Add($e) }
        }
        if ($errors.Count -eq @($p.Value).Count) { return "${Path}: matches no anyOf branch ($($errors -join '; '))" }
    }
    return $null
}

# validate.py _no_secret_values().
function Test-AapSecretValue($Value, [string]$Path) {
    if ($Value -is [Management.Automation.PSCustomObject]) {
        foreach ($vp in @($Value.PSObject.Properties)) {
            $e = Test-AapSecretValue $vp.Value "$Path.$($vp.Name)"
            if ($e) { return $e }
        }
    } elseif ($Value -is [array]) {
        $items = @($Value)
        for ($i = 0; $i -lt $items.Count; $i++) {
            $e = Test-AapSecretValue $items[$i] "$Path[$i]"
            if ($e) { return $e }
        }
    } elseif ($Value -is [string] -and [regex]::IsMatch($Value, $script:SecretValue)) {
        return "${Path}: value has a token or private-key shape"
    }
    return $null
}

# validate.py _profile_caps(): the pool and, per profile, each runner's share and the profile cap.
function Get-AapCaps($Doc) {
    $h = $Doc.host
    $reserve = [long]$Doc.host_reserve_percent
    $pool = @((Get-AapFloorDiv ([long]$h.cpu_cores * (100 - $reserve)) 100), ((Get-AapFloorDiv ([long]$h.mem_gib * (100 - $reserve)) 100) - [long]$h.control_distro_mem_gib))
    $total = [long]$Doc.profiles.linux.count + [long]$Doc.profiles.windows.count
    $caps = @{}
    foreach ($name in @('linux', 'windows')) {
        $prof = $Doc.profiles.$name
        $n = [long]$prof.count
        if ($Doc.share_mode -ceq 'even') {
            $each = @(0, 0)
            if ($total) { $each = @((Get-AapFloorDiv $pool[0] $total), (Get-AapFloorDiv $pool[1] $total)) }
            $cap = @(($each[0] * $n), ($each[1] * $n))
        } else {
            $cap = @((Get-AapFloorDiv ([long]$h.cpu_cores * [long]$prof.share_percent) 100), (Get-AapFloorDiv ([long]$h.mem_gib * [long]$prof.share_percent) 100))
            $each = @(0, 0)
            if ($n) { $each = @((Get-AapFloorDiv $cap[0] $n), (Get-AapFloorDiv $cap[1] $n)) }
        }
        $caps[$name] = @{ EachCpus = $each[0]; EachMemGib = $each[1]; CapCpus = $cap[0]; CapMemGib = $cap[1] }
    }
    @{ PoolCpus = $pool[0]; PoolMemGib = $pool[1]; IoBudget = (Get-AapFloorDiv ([long]$h.io_mbps * (100 - $reserve)) 100); linux = $caps.linux; windows = $caps.windows }
}

function Test-AapShares([string]$Mode, $Reserve, $Pairs) {
    if ($Mode -ceq 'even') {
        foreach ($pair in $Pairs) { if ($null -ne $pair[1]) { return 'share_mode even: share_percent must be null' } }
        return $null
    }
    foreach ($pair in $Pairs) { if ($null -eq $pair[1]) { return 'share_mode per_profile: every share_percent is required' } }
    $sum = [long]0
    foreach ($pair in $Pairs) { $sum += [long]$pair[1] }
    if ($sum + [long]$Reserve -ne 100) { return 'profile shares plus host_reserve_percent must equal 100' }
    foreach ($pair in $Pairs) { if (([long]$pair[0] -eq 0) -ne ([long]$pair[1] -eq 0)) { return 'a profile has share 0 exactly when its count is 0' } }
    return $null
}

# validate.py _volumes(): rule 5 for disk and rule 11. Every live reservation's clone and scratch
# caps count on the volume that holds that tier, within available - floor - held.
function Test-AapVolumes($Volumes, $Live, [switch]$LayoutOnly) {
    $vols = @($Volumes)
    $guids = [string[]]@($vols | ForEach-Object { $_.volume_guid })
    if ((New-Object 'System.Collections.Generic.HashSet[string]' (, $guids)).Count -ne $guids.Count) { return 'a volume is listed twice' }
    $tiers = New-Object System.Collections.Generic.List[string]
    foreach ($v in $vols) {
        foreach ($t in @($v.tiers)) {
            if ($tiers.Contains($t)) { return "tier $t is on more than one volume" }
            $tiers.Add($t)
        }
    }
    if (@($Live | Where-Object { $_.backend -ceq 'hyperv-vm' }).Count -and -not ($tiers.Contains('base') -and $tiers.Contains('clone') -and $tiers.Contains('scratch'))) {
        return 'a VM reservation needs the base, clone and scratch tiers in host.volumes'
    }
    if ($LayoutOnly) { return $null }
    foreach ($v in $vols) {
        $clone = @($v.tiers) -ccontains 'clone'
        $scratch = @($v.tiers) -ccontains 'scratch'
        if (-not ($clone -or $scratch)) { continue }
        if ((Get-AapVolumeNeed $v $Live) -gt [long]$v.available_gib - [long]$v.floor_gib - [long]$v.held_gib) {
            return "volume $($v.volume_guid): reservations exceed its disk budget (available minus floor minus held)"
        }
    }
    return $null
}

# What the live reservations hold on one volume: clone caps on the clone tier, scratch caps on the scratch tier.
function Get-AapVolumeNeed($Volume, $Live) {
    $clone = @($Volume.tiers) -ccontains 'clone'
    $scratch = @($Volume.tiers) -ccontains 'scratch'
    $need = [long]0
    foreach ($r in @($Live)) {
        if ($clone) { $need += [long]$r.clone_gib }
        if ($scratch) { $need += [long]$r.scratch_gib }
    }
    $need
}

# validate.py sem_allocator(), rule by rule.
function Test-AapSemantic($Doc) {
    $profiles = @($Doc.profiles.PSObject.Properties | ForEach-Object { $_.Value })
    $total = [long]$Doc.profiles.linux.count + [long]$Doc.profiles.windows.count
    if (-not (1 -le $total -and $total -le 5)) { return 'linux + windows runner counts must be 1..5' }
    $e = Test-AapShares $Doc.share_mode $Doc.host_reserve_percent @($profiles | ForEach-Object { , @($_.count, $_.share_percent) })
    if ($e) { return $e }
    if ($Doc.profiles.windows.backend -cne 'hyperv-vm') { return 'the windows profile backend is hyperv-vm' }
    $all = @($Doc.reservations)
    $live = @(Get-AapLive $Doc)
    if ($live.Count -gt [long]$Doc.max_slots) { return 'more live reservations than max_slots' }
    $slots = @($live | ForEach-Object { [long]$_.slot })
    if (@($slots | Sort-Object -Unique).Count -ne $slots.Count) { return 'two live reservations hold one slot' }
    $ids = @($all | ForEach-Object { $_.reservation_id })
    if ((New-Object 'System.Collections.Generic.HashSet[string]' (, [string[]]$ids)).Count -ne $ids.Count) { return 'duplicate reservation_id' }
    if (@($live | Where-Object { $_.backend -ceq 'hyperv-vm' }).Count -and -not $Doc.legacy_adopted) { return 'a VM reservation exists before legacy slots were adopted' }
    $caps = Get-AapCaps $Doc
    foreach ($name in @('linux', 'windows')) {
        $admitted = @($live | Where-Object { $_.profile -ceq $name -and (Test-AapAdmitted $_) })
        if ($admitted.Count -gt [long]$Doc.profiles.$name.count) { return "${name}: more admitted reservations than the profile count" }
        $c = $caps[$name]
        foreach ($r in $admitted) {
            if ($r.backend -cne $Doc.profiles.$name.backend) { return "$($r.reservation_id): admitted on a backend other than the profile's" }
            if ([long]$r.cpus -gt $c.EachCpus -or (Get-AapMem $r) -gt $c.EachMemGib) { return "$($r.reservation_id): exceeds the per-runner share of $name" }
        }
        if ((Get-AapSum $admitted { $args[0].cpus }) -gt $c.CapCpus -or (Get-AapSum $admitted { Get-AapMem $args[0] }) -gt $c.CapMemGib) { return "${name}: admitted reservations exceed the profile cap" }
    }
    if ((Get-AapSum $live { $args[0].cpus }) -gt $caps.PoolCpus -or (Get-AapSum $live { Get-AapMem $args[0] }) -gt $caps.PoolMemGib) { return 'reservations exceed the pool; the host reserve is never given away' }
    $e = Test-AapVolumes $Doc.host.volumes $live
    if ($e) { return $e }
    if ([long]$Doc.host.io_mbps -eq 0) {
        if (@($live | Where-Object { [long]$_.io_mbps -ne 0 }).Count) { return 'io_mbps reserved while host IO is unmeasured' }
    } elseif ((Get-AapSum $live { $args[0].io_mbps }) -gt $caps.IoBudget) { return 'reservations exceed the IO budget' }
    $gens = @($Doc.slot_generations)
    foreach ($r in $all) {
        $rid = $r.reservation_id
        $current = [long]$gens[[int]$r.slot - 1]
        if ($script:LiveStates -ccontains $r.state -and [long]$r.lease_generation -ne $current) { return "${rid}: lease_generation is not the slot's current generation" }
        if ([long]$r.lease_generation -gt $current) { return "${rid}: lease_generation ahead of the slot counter" }
        if ($r.backend -ceq 'wsl-legacy') {
            if ($r.profile -cne 'linux' -or $null -ne $r.vm_id -or -not $r.image_generation.StartsWith('legacy-', [StringComparison]::Ordinal)) { return "${rid}: legacy reservations are linux, vm_id null, generation legacy-*" }
            if ([long]$r.clone_gib -ne 0 -or [long]$r.scratch_gib -ne 0) { return "${rid}: legacy reservations reserve no VM disk" }
        } else {
            if ([long]$r.clone_gib -lt 1) { return "${rid}: a VM reservation reserves at least 1 GiB of clone disk" }
            if ($r.state -cne 'creating' -and $r.state -cne 'reconciled' -and $null -eq $r.vm_id) { return "${rid}: a VM reservation past creating names its vm_id" }
            if ($null -ne $r.runner_name -and $r.runner_name -cne (Get-AapVmNameOf $r)) { return "${rid}: runner_name must be the VM name aap-<w|l>-<slot>-<generation>-<reservation hex>" }
        }
        if ((($r.state -ceq 'quarantined') -ne ($null -ne $r.quarantine_kind)) -or (($null -eq $r.quarantine_kind) -ne ($null -eq $r.quarantine_reason))) { return "${rid}: quarantine_kind and quarantine_reason are set exactly when quarantined" }
        $proof = $r.teardown_proof
        if (($r.state -ceq 'reconciled') -ne ($null -ne $proof)) { return "${rid}: teardown_proof is present exactly when reconciled" }
        if ($null -ne $proof) {
            $want = 'vm'
            if ($r.backend -ceq 'wsl-legacy') { $want = 'legacy' }
            if ($proof.kind -cne $want) { return "${rid}: teardown_proof kind does not match the backend" }
        }
        if ($r.idempotency_key -cne "$rid/$($r.lease_generation)") { return "${rid}: idempotency_key must be <reservation_id>/<lease_generation>" }
    }
    return $null
}

# validate.py validate(): schema, secret values, semantic rules. $null when the document holds.
function Test-AapDoc($Doc) {
    $schema = Get-AapSchema
    $e = Test-AapNode $schema $Doc $schema '$'
    if ($e) { return $e }
    $e = Test-AapSecretValue $Doc '$'
    if ($e) { return $e }
    Test-AapSemantic $Doc
}

# ---- folder trust: install-supervisor.ps1's checks, applied to the capacity folder -------------

function Test-AapReparse([string]$Path) {
    # Attributes do not follow a link, so a dangling junction still shows ReparsePoint; -1 = missing.
    $attr = -1
    try { $attr = [int](New-Object IO.FileInfo $Path).Attributes } catch { $attr = -1 }
    return ($attr -ne -1 -and ($attr -band [int][IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-AapRawSd([string]$Path) {
    $acl = Get-Acl -LiteralPath $Path
    New-Object System.Security.AccessControl.RawSecurityDescriptor($acl.GetSecurityDescriptorBinaryForm(), 0)
}

# Test-AapAdminDescriptor in install-supervisor.ps1: an admin owner, a DACL, plain allow/deny ACEs,
# and no other SID with write, append, write-attributes, delete, delete-child, write-DAC,
# write-owner or generic write/all. Unlike there, inherit-only ACEs count too: the files this
# module writes inherit them. Read data, execute and generic read/execute are refused as well: a
# reader could open allocator.lock or allocator.json with no sharing and stall every call or the
# replace.
function Get-AapLeafProblem([string]$Path, [string[]]$Trusted) {
    if (Test-AapReparse $Path) { return "reparse point $Path" }
    try { $raw = Get-AapRawSd $Path } catch { return "cannot read the ACL of $Path" }
    if ($null -eq $raw.Owner -or $Trusted -notcontains $raw.Owner.Value) { return "owner $($raw.Owner) of $Path is not an admin" }
    if ($null -eq $raw.DiscretionaryAcl) { return "$Path has no DACL (everyone has full control)" }
    $bad = 0x2 -bor 0x4 -bor 0x100 -bor 0x40 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x40000000 -bor 0x10000000
    $bad = $bad -bor 0x1 -bor 0x20 -bor 0x20000000 -bor [int]::MinValue
    foreach ($ace in $raw.DiscretionaryAcl) {
        $type = [int]$ace.AceType
        if ($type -ne 0 -and $type -ne 1) { return "$Path has an ACE that is not a plain allow or deny" }
        if ($type -ne 0) { continue }
        $sid = $ace.SecurityIdentifier.Value
        if ($Trusted -contains $sid) { continue }
        if (([int]$ace.AccessMask -band $bad) -ne 0) { return "$Path grants $sid read or write access (0x$('{0:x}' -f [int]$ace.AccessMask))" }
    }
    return $null
}

# Get-AapAncestorProblem in install-supervisor.ps1: every folder above, up to the drive root, is
# not a reparse point, has an admin owner and a DACL, and lets no other SID delete, delete
# children, change the DACL, take ownership or hold generic all. Relaxed mode keeps the reparse
# check and skips the rest (a test folder's ancestors are user folders).
function Get-AapAncestorProblem([string]$Path, [bool]$AclToo) {
    $problems = New-Object System.Collections.Generic.List[string]
    $bad = [int]([Security.AccessControl.FileSystemRights]'Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership') -bor 0x10000000
    $dir = Split-Path -Parent $Path
    while ($dir) {
        if (Test-AapReparse $dir) {
            $problems.Add("reparse point $dir")
        } elseif ($AclToo) {
            $raw = $null
            try { $raw = Get-AapRawSd $dir } catch { $problems.Add("cannot read the ACL of $dir") }
            if ($raw) {
                if ($null -eq $raw.Owner -or $script:AdminSids -notcontains $raw.Owner.Value) { $problems.Add("owner $($raw.Owner) on $dir is not an admin") }
                if ($null -eq $raw.DiscretionaryAcl) {
                    $problems.Add("$dir has no DACL (everyone has full control)")
                } else {
                    foreach ($ace in $raw.DiscretionaryAcl) {
                        $type = [int]$ace.AceType
                        if ($type -ne 0 -and $type -ne 1) { $problems.Add("$dir has an ACE that is not a plain allow or deny"); continue }
                        if ($type -ne 0 -or ([int]$ace.AceFlags -band 8) -ne 0) { continue }
                        $sid = $ace.SecurityIdentifier.Value
                        if ($script:AdminSids -contains $sid) { continue }
                        if (([int]$ace.AccessMask -band $bad) -ne 0) { $problems.Add("$dir grants $sid $([int]$ace.AccessMask)") }
                    }
                }
            }
        }
        $dir = Split-Path -Parent $dir
    }
    , $problems
}

function Get-AapProcessRole {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($id.User.Value -ceq 'S-1-5-18') { return 'system' }
    if ((New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { return 'elevated' }
    'user'
}

# -RelaxedTrustForTests is refused for SYSTEM, below ProgramData, Program Files or Windows, and in
# an elevated process outside the temp folder (hosted CI runs tests elevated under TEMP).
function Get-AapRelaxedProblem([string]$Root) {
    $under = { param($dir) $dir -and $Root.StartsWith($dir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) }
    foreach ($d in @($env:ProgramData, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:SystemRoot)) {
        if (& $under $d) { return "relaxed trust is for test folders only, never below $d" }
    }
    $role = Get-AapProcessRole
    if ($role -eq 'system') { return 'relaxed trust is refused for SYSTEM' }
    $temp = [IO.Path]::GetTempPath()
    if ($role -eq 'elevated' -and -not (& $under $temp)) { return "relaxed trust is refused in an elevated process outside $temp" }
    return $null
}

function Get-AapTrustProblem([string]$Root, [bool]$Relaxed, [bool]$MayBeMissing) {
    $problems = New-Object System.Collections.Generic.List[string]
    if ($Relaxed) {
        $p = Get-AapRelaxedProblem $Root
        if ($p) { $problems.Add($p); return , $problems }
    }
    if ($Root -notmatch '^[A-Za-z]:\\.+' -or $Root.EndsWith('\') -or [IO.Path]::GetFullPath($Root) -cne $Root) {
        $problems.Add("$Root is not a normalized absolute path on a drive")
        return , $problems
    }
    try {
        if ((New-Object IO.DriveInfo($Root.Substring(0, 1))).DriveType -ne [IO.DriveType]::Fixed) { $problems.Add("$Root is not on a fixed local drive") }
    } catch { $problems.Add("$Root is not on a fixed local drive") }
    $trusted = $script:AdminSids
    if ($Relaxed) { $trusted = $script:AdminSids + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
    foreach ($p in (Get-AapAncestorProblem $Root (-not $Relaxed))) { $problems.Add($p) }
    if ($problems.Count) { return , $problems }
    if (-not [IO.Directory]::Exists($Root)) {
        if (Test-AapReparse $Root) { $problems.Add("reparse point $Root") }
        elseif (-not $MayBeMissing) { $problems.Add("$Root does not exist") }
        return , $problems
    }
    $p = Get-AapLeafProblem $Root $trusted
    if ($p) { $problems.Add($p); return , $problems }
    foreach ($name in $script:StateFiles) {
        $f = Join-Path $Root $name
        if (Test-AapReparse $f) { $problems.Add("reparse point $f"); continue }
        if ([IO.File]::Exists($f)) {
            $p = Get-AapLeafProblem $f $trusted
            # Another process may swap its temp file in or rotate the log between the two looks.
            if ($p -and [IO.File]::Exists($f)) { $problems.Add($p) }
        } elseif ([IO.Directory]::Exists($f)) { $problems.Add("$f is a folder") }
    }
    , $problems
}

# ---- lock, state file, log -------------------------------------------------------------------

function Enter-AapLock([string]$Root, [int]$TimeoutSeconds) {
    $path = Join-Path $Root 'allocator.lock'
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        try {
            return [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        } catch {
            $inner = $_.Exception
            while ($inner.InnerException) { $inner = $inner.InnerException }
            if (-not ($inner -is [IO.IOException])) { throw }
            if ([DateTime]::UtcNow -ge $deadline) { return $null }
            Start-Sleep -Milliseconds 50
        }
    }
}

function Write-AapAtomic([string]$Root, [string]$Name, [string]$Text) {
    $path = Join-Path $Root $Name
    $tmp = "$path.tmp"
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Text)
    $fs = [IO.File]::Open($tmp, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $fs.Write($bytes, 0, $bytes.Length); $fs.Flush($true) } finally { $fs.Dispose() }
    Invoke-AapFault "after-temp $Name"
    if ([IO.File]::Exists($path)) { [IO.File]::Replace($tmp, $path, "$path.bak") } else { [IO.File]::Move($tmp, $path) }
}

function Write-AapCapLog([string]$Root, [string]$Text) {
    try {
        $log = Join-Path $Root 'allocator.log'
        if ([IO.File]::Exists($log) -and (New-Object IO.FileInfo $log).Length -ge 1MB) {
            [IO.File]::Copy($log, "$log.1", $true)
            [IO.File]::Delete($log)
        }
        $line = (Format-AapTime (Get-AapUtcNow)) + ' ' + (ConvertTo-AapLine $Text).Trim() + "`n"
        [IO.File]::AppendAllText($log, $line, (New-Object Text.UTF8Encoding($false)))
    } catch {
        Write-Warning "allocator log write failed: $($_.Exception.Message)"
    }
}

function Get-AapKey([string]$Root) { $Root.ToLowerInvariant() }

# A new capacity folder gets a protected DACL: SYSTEM and Administrators full control, nothing
# inherited (the data folder above grants the installing user read). Relaxed mode adds the current
# user, or an unelevated test could not write. The owner is the creator's default owner
# (Administrators for an elevated process); the strict check that follows refuses any other.
function New-AapFolder([string]$Root) {
    $sddl = 'D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)'
    if ($script:Relaxed) { $sddl += "(A;OICI;FA;;;$([Security.Principal.WindowsIdentity]::GetCurrent().User.Value))" }
    $sec = New-Object Security.AccessControl.DirectorySecurity
    $sec.SetSecurityDescriptorSddlForm($sddl)
    $ext = 'System.IO.FileSystemAclExtensions' -as [type]
    if ($ext -and $ext.GetMethod('Create', [type[]]@([IO.DirectoryInfo], [Security.AccessControl.DirectorySecurity]))) {
        $ext::Create([IO.DirectoryInfo]$Root, $sec)
    } else {
        [void][IO.Directory]::CreateDirectory($Root, $sec)
    }
}

# Files that show allocator.json once existed. A temp file counts unless it is an interrupted first
# initialize (revision 1: nothing admitted, no generation spent).
function Get-AapLostEvidence([string]$Root) {
    $found = @($script:StateFiles | Where-Object { $_ -cne 'allocator.json' -and $_ -cne 'allocator.json.tmp' -and $_ -cne 'allocator.lock' -and [IO.File]::Exists((Join-Path $Root $_)) })
    $tmp = Join-Path $Root 'allocator.json.tmp'
    if ([IO.File]::Exists($tmp)) {
        $first = $false
        try {
            $d = ConvertFrom-AapJson (Read-AapText $tmp 65536)
            $first = ($null -eq (Test-AapDoc $d)) -and [long]$d.revision -eq 1
        } catch { $first = $false }
        if (-not $first) { $found += 'allocator.json.tmp' }
    }
    , $found
}

function Read-AapDoc([string]$Root) {
    $path = Join-Path $Root 'allocator.json'
    if (-not [IO.File]::Exists($path)) { return (New-AapResult 'error' 'not_initialized' "no $path; run Initialize-AapAllocator") }
    try { $text = Read-AapText $path 65536 } catch { return (New-AapResult 'error' 'invalid_state' "cannot read ${path}: $($_.Exception.Message)") }
    if ($null -eq $text) { return (New-AapResult 'error' 'invalid_state' "$path is larger than 64 KiB") }
    try { $doc = ConvertFrom-AapJson $text } catch { return (New-AapResult 'error' 'invalid_state' "$path is not JSON") }
    $e = Test-AapDoc $doc
    if ($e) { return (New-AapResult 'error' 'invalid_state' "${path}: $e") }
    $key = Get-AapKey $Root
    if ($script:Seen.ContainsKey($key) -and [long]$doc.revision -lt $script:Seen[$key]) {
        return (New-AapResult 'error' 'invalid_state' "$path revision $($doc.revision) is lower than revision $($script:Seen[$key]) already applied")
    }
    $script:Seen[$key] = [long]$doc.revision
    New-AapResult 'ok' $null '' ([ordered]@{ Doc = $doc })
}

# Keeps every live entry and the newest reconciled ones.
function Limit-AapReconciled($Doc) {
    $done = @($Doc.reservations | Where-Object { $_.state -ceq 'reconciled' })
    if ($done.Count -le $script:KeepReconciled) { return }
    $drop = @($done | Sort-Object -Property @{ Expression = { $_.state_changed_at } } | Select-Object -First ($done.Count - $script:KeepReconciled) | ForEach-Object { $_.reservation_id })
    $Doc.reservations = @($Doc.reservations | Where-Object { $drop -cnotcontains $_.reservation_id })
}

# revision + 1, prune, validate the exact bytes, then temp file + atomic replace.
function Save-AapDoc([string]$Root, $Doc, [string]$Note) {
    $rev = [long]$Doc.revision + 1
    if ($rev -gt 2147483647) { throw 'allocator revision would exceed 2147483647' }
    $Doc.revision = $rev
    $Doc.written_at = Format-AapTime (Get-AapUtcNow)
    Limit-AapReconciled $Doc
    $json = ConvertTo-AapJson $Doc
    $e = Test-AapDoc (ConvertFrom-AapJson $json)
    if ($e) { throw "refusing to write an allocator state that fails the contract: $e" }
    Invoke-AapFault 'before-temp'
    Write-AapAtomic $Root 'allocator.json' $json
    $script:Seen[(Get-AapKey $Root)] = $rev
    if ($Note) { Write-AapCapLog $Root "rev $rev $Note" }
    Invoke-AapFault 'after-replace'
}

# The common frame: folder trust, lock with a bounded wait, a validated read, the body. The body
# gets the document and returns a result; any exception becomes Status 'error'.
function Invoke-AapLocked {
    param([string]$Root, [bool]$RelaxedTrust, [int]$LockTimeoutSeconds, [scriptblock]$Body)
    $script:Relaxed = $RelaxedTrust
    $__problems = Get-AapTrustProblem $Root $RelaxedTrust $true
    if ($__problems.Count) { return (New-AapResult 'error' 'untrusted_folder' ($__problems -join '; ')) }
    if (-not [IO.Directory]::Exists($Root)) { return (New-AapResult 'error' 'not_initialized' "no $Root; run Initialize-AapAllocator") }
    if ($RelaxedTrust -and -not $script:Warned.ContainsKey((Get-AapKey $Root))) {
        Write-Warning "AapCapacity: folder trust checks are RELAXED FOR TESTS on $Root (current user trusted, ancestor ACLs not checked)"
    }
    $__lock = $null
    try { $__lock = Enter-AapLock $Root $LockTimeoutSeconds } catch { return (New-AapResult 'error' 'lock_failed' "cannot open the allocator lock: $($_.Exception.Message)") }
    if ($null -eq $__lock) { return (New-AapResult 'error' 'lock_timeout' "allocator lock busy for $LockTimeoutSeconds s: $(Join-Path $Root 'allocator.lock'); nothing admitted") }
    try {
        $__read = Read-AapDoc $Root
        if (-not $__read.Ok) { return $__read }
        # Only after allocator.json was read: a log without it would count as lost state.
        if ($RelaxedTrust -and -not $script:Warned.ContainsKey((Get-AapKey $Root))) {
            $script:Warned[(Get-AapKey $Root)] = $true
            Write-AapCapLog $Root 'WARNING folder trust checks relaxed for tests'
        }
        & $Body $__read.Doc
    } catch {
        return (New-AapResult 'error' 'failed' $_.Exception.Message)
    } finally {
        $__lock.Dispose()
    }
}

function Find-AapReservation($Doc, [string]$ReservationId, $LeaseGeneration) {
    $r = @($Doc.reservations | Where-Object { $_.reservation_id -ceq $ReservationId })
    if (-not $r.Count) { return @{ Result = (New-AapResult 'refused' 'not_found' "no reservation $ReservationId") } }
    $r = $r[0]
    $current = [long]@($Doc.slot_generations)[[int]$r.slot - 1]
    if ($r.state -ceq 'reconciled' -or [long]$r.lease_generation -ne [long]$LeaseGeneration -or $current -ne [long]$LeaseGeneration) {
        return @{ Result = (New-AapResult 'ignored' 'stale_generation' "$ReservationId generation $LeaseGeneration is not the live lease of slot $($r.slot) (slot generation $current, state $($r.state))"); Stale = $true }
    }
    @{ Reservation = $r }
}

# One edge: state and time; the quarantine fields follow the state (contract rule 10).
function Set-AapEdge($R, [string]$To, [string]$Now) {
    $R.state = $To
    $R.state_changed_at = $Now
    if ($To -cne 'quarantined') {
        $R.quarantine_kind = $null
        $R.quarantine_reason = $null
    }
}

# Walks the legal edges down to deleting (and on to reconciled with a proof).
function Move-AapDown($R, [string]$Now, $Proof) {
    foreach ($s in $script:ToDeleting[$R.state]) { Set-AapEdge $R $s $Now }
    if ($null -ne $Proof) {
        Set-AapEdge $R 'reconciled' $Now
        $R.teardown_proof = $Proof
        $R.cleanup_uncertain = $false
    }
}

function New-AapId {
    $bytes = New-Object byte[] 8
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    'r-' + (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function New-AapReservationObject {
    param($Id, $Slot, $ProfileName, $Backend, $Generation, $Lease, $State, $Now, $Cpus, $MemGib, $OverheadMib, $CloneGib, $ScratchGib, $IoMbps)
    [pscustomobject][ordered]@{
        reservation_id = $Id; slot = $Slot; profile = $ProfileName; backend = $Backend; image_generation = $Generation
        lease_generation = $Lease; state = $State; idempotency_key = "$Id/$Lease"
        acquired_at = $Now; state_changed_at = $Now; heartbeat_at = $null
        cpus = $Cpus; mem_gib = $MemGib; mem_overhead_mib = $OverheadMib; clone_gib = $CloneGib; scratch_gib = $ScratchGib; io_mbps = $IoMbps
        vm_id = $null; runner_name = $null; cleanup_uncertain = $false
        quarantine_kind = $null; quarantine_reason = $null; teardown_proof = $null
    }
}

# A new reservation in the lowest free slot; the slot counter is incremented first (rule 8).
function Add-AapReservation($Doc, [hashtable]$Spec, [string]$Now) {
    $used = @(Get-AapLive $Doc | ForEach-Object { [int]$_.slot })
    $slot = @(1..5 | Where-Object { $used -notcontains $_ })[0]
    $ids = @($Doc.reservations | ForEach-Object { $_.reservation_id })
    do { $id = New-AapId } while ($ids -ccontains $id)
    $gens = @($Doc.slot_generations | ForEach-Object { [long]$_ })
    $gens[$slot - 1] = $gens[$slot - 1] + 1
    $Doc.slot_generations = $gens
    $r = New-AapReservationObject -Id $id -Slot $slot -ProfileName $Spec.Profile -Backend $Spec.Backend -Generation $Spec.Generation `
        -Lease $gens[$slot - 1] -State $Spec.State -Now $Now -Cpus $Spec.Cpus -MemGib $Spec.MemGib -OverheadMib $Spec.OverheadMib -CloneGib $Spec.CloneGib -ScratchGib $Spec.ScratchGib -IoMbps $Spec.IoMbps
    $Doc.reservations = @($Doc.reservations) + @($r)
    $r
}

# Fixed admission refusals for one more reservation of Spec.Profile: count, ceiling, share, pool,
# memory, disk, io. $null when it fits.
function Test-AapAdmission($Doc, [hashtable]$Spec) {
    $name = $Spec.Profile
    $live = @(Get-AapLive $Doc)
    $admitted = @($live | Where-Object { $_.profile -ceq $name -and (Test-AapAdmitted $_) })
    if ($admitted.Count -ge [long]$Doc.profiles.$name.count) { return @('count', "$name has $($admitted.Count) of $($Doc.profiles.$name.count) runners admitted") }
    if ($live.Count -ge 5) { return @('ceiling', "all 5 runner slots are held ($(@($live | ForEach-Object { "$($_.slot):$($_.state)" }) -join ', '))") }
    $caps = Get-AapCaps $Doc
    $c = $caps[$name]
    $mem = [long]$Spec.MemGib + [long][Math]::Ceiling([double]$Spec.OverheadMib / 1024)
    if ([long]$Spec.Cpus -gt $c.EachCpus -or $mem -gt $c.EachMemGib) { return @('share', "$($Spec.Cpus) CPUs and $mem GiB (with VM overhead) exceed the $name per-runner share of $($c.EachCpus) CPUs and $($c.EachMemGib) GiB") }
    if ((Get-AapSum $admitted { $args[0].cpus }) + [long]$Spec.Cpus -gt $c.CapCpus -or (Get-AapSum $admitted { Get-AapMem $args[0] }) + $mem -gt $c.CapMemGib) { return @('share', "$name cap of $($c.CapCpus) CPUs and $($c.CapMemGib) GiB is used") }
    if ((Get-AapSum $live { $args[0].cpus }) + [long]$Spec.Cpus -gt $caps.PoolCpus) { return @('pool', "the pool of $($caps.PoolCpus) CPUs is held by live reservations, draining ones included") }
    if ((Get-AapSum $live { Get-AapMem $args[0] }) + $mem -gt $caps.PoolMemGib) { return @('memory', "the pool of $($caps.PoolMemGib) GiB (control VM paid first) is held by live reservations, VM overhead and draining ones included") }
    $with = @($live) + @([pscustomobject]@{ backend = $Spec.Backend; clone_gib = [long]$Spec.CloneGib; scratch_gib = [long]$Spec.ScratchGib })
    $e = Test-AapVolumes $Doc.host.volumes $with
    if ($e -and $e.StartsWith('a VM reservation needs', [StringComparison]::Ordinal)) { return @('storage', 'no trusted storage layout: host.volumes lacks the base, clone or scratch tier, so no VM is admitted') }
    if ($e) { return @('disk', "$e; the new reservation's clone and scratch caps do not fit") }
    if ([long]$Doc.host.io_mbps -eq 0) {
        if ([long]$Spec.IoMbps -ne 0) { return @('io', 'host IO is not measured, so no reservation may reserve IO') }
    } elseif ((Get-AapSum $live { $args[0].io_mbps }) + [long]$Spec.IoMbps -gt $caps.IoBudget) { return @('io', "the IO budget of $($caps.IoBudget) MB/s is held") }
    return $null
}

# HostInfo: cpu_cores, mem_gib, io_mbps, control_distro_mem_gib and volumes (a list of volume_guid,
# tiers, available_gib, floor_gib, held_gib; empty while storage is unconfigured or failing).
function ConvertTo-AapHost($HostInfo, [string]$Now) {
    $volumes = @(foreach ($v in @(Get-AapField $HostInfo 'volumes')) {
            if ($null -ne $v) {
                [pscustomobject][ordered]@{
                    volume_guid = Get-AapField $v 'volume_guid'; tiers = @(Get-AapField $v 'tiers'); available_gib = Get-AapField $v 'available_gib'
                    floor_gib = Get-AapField $v 'floor_gib'; held_gib = Get-AapField $v 'held_gib'
                }
            }
        })
    [pscustomobject][ordered]@{
        cpu_cores = Get-AapField $HostInfo 'cpu_cores'; mem_gib = Get-AapField $HostInfo 'mem_gib'
        volumes = $volumes; io_mbps = Get-AapField $HostInfo 'io_mbps'
        control_distro_mem_gib = Get-AapField $HostInfo 'control_distro_mem_gib'; measured_at = $Now
    }
}

# The common settings parameters of Initialize-AapAllocator and Set-AapProfileCounts, applied to
# a document. Returns $null or a bad_request text. The windows backend is always hyperv-vm.
function Set-AapSettings($Doc, [hashtable]$Bound) {
    $p = $Doc.profiles
    foreach ($k in @('Linux', 'Windows')) {
        if ($Bound.ContainsKey($k)) {
            $v = $Bound[$k]
            if (-not (Test-AapInt $v) -or $v -lt 0 -or $v -gt 5) { return "$k count must be a whole number 0..5" }
            $p.($k.ToLowerInvariant()).count = [long]$v
        }
    }
    if ($Bound.ContainsKey('ShareMode')) { $Doc.share_mode = [string]$Bound.ShareMode }
    if ($Bound.ContainsKey('HostReservePercent')) { $Doc.host_reserve_percent = [long]$Bound.HostReservePercent }
    if ($Bound.ContainsKey('LinuxBackend')) { $p.linux.backend = [string]$Bound.LinuxBackend }
    foreach ($k in @('LinuxShare', 'WindowsShare')) {
        if ($Bound.ContainsKey($k)) {
            $v = $Bound[$k]
            if ($null -ne $v -and (-not (Test-AapInt $v) -or $v -lt 0 -or $v -gt 90)) { return "$k must be a whole number 0..90 or null" }
            if ($null -ne $v) { $v = [long]$v }
            $p.($k.Substring(0, $k.Length - 5).ToLowerInvariant()).share_percent = $v
        }
    }
    if ($Doc.share_mode -ceq 'even') { $p.linux.share_percent = $null; $p.windows.share_percent = $null }
    foreach ($k in @('LinuxGeneration', 'WindowsGeneration')) {
        if ($Bound.ContainsKey($k)) {
            $v = $Bound[$k]
            if ([string]::IsNullOrEmpty($v)) { $v = $null }
            $p.($k.Substring(0, $k.Length - 10).ToLowerInvariant()).active_generation = $v
        }
    }
    $total = [long]$p.linux.count + [long]$p.windows.count
    if ($total -lt 1 -or $total -gt 5) { return 'linux + windows runner counts must be 1..5' }
    $reserve = [long]$Doc.host_reserve_percent
    if ($reserve -lt 10 -or $reserve -gt 90) { return 'host reserve must be 10..90 percent' }
    $e = Test-AapShares $Doc.share_mode $reserve @(@($p.linux.count, $p.linux.share_percent), @($p.windows.count, $p.windows.share_percent))
    if ($e) { return $e }
    return $null
}

# ---- exported --------------------------------------------------------------------------------

function Get-AapVmName {
    param([Parameter(Mandatory)][ValidateSet('linux', 'windows', IgnoreCase = $false)][string]$Profile,
        [Parameter(Mandatory)][ValidateRange(1, 5)][int]$Slot,
        [Parameter(Mandatory)][ValidateRange(1, 999999999)][long]$LeaseGeneration,
        [Parameter(Mandatory)][ValidatePattern('^r-[0-9a-f]{16}\z', Options = 'None')][string]$ReservationId)
    $letter = 'l'
    if ($Profile -ceq 'windows') { $letter = 'w' }
    "aap-$letter-$Slot-$LeaseGeneration-$($ReservationId.Substring(2, 8))"
}

function Test-AapAllocatorState {
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param([Parameter(Mandatory, ParameterSetName = 'Path')][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Json')][string]$Json,
        [Parameter(Mandatory, ParameterSetName = 'State')]$State)
    try {
        if ($PSCmdlet.ParameterSetName -eq 'Path') {
            $Json = Read-AapText $Path 262144
            if ($null -eq $Json) { return [pscustomobject]@{ Valid = $false; Error = "$(Split-Path -Leaf $Path): document over 256 KiB" } }
        }
        if ($PSCmdlet.ParameterSetName -ne 'State') { $State = ConvertFrom-AapJson $Json }
    } catch {
        return [pscustomobject]@{ Valid = $false; Error = "not readable JSON: $($_.Exception.Message)" }
    }
    $e = Test-AapDoc $State
    [pscustomobject]@{ Valid = ($null -eq $e); Error = $e }
}

function Initialize-AapAllocator {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)]$HostInfo,
        [int]$Linux = 1, [int]$Windows = 0,
        [ValidateSet('even', 'per_profile', IgnoreCase = $false)][string]$ShareMode = 'even',
        $LinuxShare = $null, $WindowsShare = $null,
        [int]$HostReservePercent = 10,
        [ValidateSet('wsl-legacy', 'hyperv-vm', IgnoreCase = $false)][string]$LinuxBackend = 'wsl-legacy',
        [int]$LockTimeoutSeconds = 30,
        [switch]$RelaxedTrustForTests)
    $script:Relaxed = [bool]$RelaxedTrustForTests
    $problems = Get-AapTrustProblem $Root $script:Relaxed $true
    if ($problems.Count) { return (New-AapResult 'error' 'untrusted_folder' ($problems -join '; ')) }
    if (-not [IO.Directory]::Exists($Root)) {
        try { New-AapFolder $Root } catch { return (New-AapResult 'error' 'failed' "cannot create ${Root}: $($_.Exception.Message)") }
    }
    if ([IO.File]::Exists((Join-Path $Root 'allocator.json'))) {
        return (Invoke-AapLocked $Root $script:Relaxed $LockTimeoutSeconds { param($doc) New-AapResult 'unchanged' 'already_initialized' 'allocator.json exists; settings and host left as they are' ([ordered]@{ State = $doc }) })
    }
    $problems = Get-AapTrustProblem $Root $script:Relaxed $false
    if ($problems.Count) { return (New-AapResult 'error' 'untrusted_folder' ($problems -join '; ')) }
    $lock = Enter-AapLock $Root $LockTimeoutSeconds
    if ($null -eq $lock) { return (New-AapResult 'error' 'lock_timeout' "allocator lock busy for $LockTimeoutSeconds s; nothing written") }
    try {
        if ([IO.File]::Exists((Join-Path $Root 'allocator.json'))) { return (New-AapResult 'unchanged' 'already_initialized' 'initialized by another process') }
        $lost = Get-AapLostEvidence $Root
        if ($lost.Count) {
            return (New-AapResult 'error' 'invalid_state' "allocator.json is missing but $($lost -join ', ') exist in ${Root}: the state was lost while slots may be running; restore allocator.json (allocator.json.bak is the previous revision) instead of starting at revision 1 with generation 0")
        }
        $now = Format-AapTime (Get-AapUtcNow)
        $doc = [pscustomobject][ordered]@{
            schema = 2; revision = 0; written_at = $now; max_slots = 5
            host = ConvertTo-AapHost $HostInfo $now
            host_reserve_percent = 10; share_mode = 'even'
            profiles = [pscustomobject][ordered]@{
                linux = [pscustomobject][ordered]@{ count = 1; share_percent = $null; backend = 'wsl-legacy'; active_generation = $null }
                windows = [pscustomobject][ordered]@{ count = 0; share_percent = $null; backend = 'hyperv-vm'; active_generation = $null }
            }
            legacy_adopted = $false; slot_generations = @(0, 0, 0, 0, 0); reservations = @()
        }
        $bound = @{ Linux = $Linux; Windows = $Windows; ShareMode = $ShareMode; LinuxShare = $LinuxShare; WindowsShare = $WindowsShare; HostReservePercent = $HostReservePercent; LinuxBackend = $LinuxBackend }
        $e = Set-AapSettings $doc $bound
        if ($e) { return (New-AapResult 'refused' 'bad_request' $e) }
        $e = Test-AapDoc (ConvertFrom-AapJson (ConvertTo-AapJson $doc))
        if ($e) { return (New-AapResult 'refused' 'bad_request' $e) }
        # The log is written only after allocator.json exists: a log without it means lost state.
        Save-AapDoc $Root $doc 'initialized'
        if ($script:Relaxed) {
            Write-Warning "AapCapacity: folder trust checks are RELAXED FOR TESTS on $Root (current user trusted, ancestor ACLs not checked)"
            Write-AapCapLog $Root 'WARNING folder trust checks relaxed for tests'
            $script:Warned[(Get-AapKey $Root)] = $true
        }
        New-AapResult 'ok' $null 'initialized' ([ordered]@{ State = $doc })
    } catch {
        New-AapResult 'error' 'failed' $_.Exception.Message
    } finally { $lock.Dispose() }
}

function Get-AapAllocatorState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [switch]$RelaxedTrustForTests)
    $script:Relaxed = [bool]$RelaxedTrustForTests
    $problems = Get-AapTrustProblem $Root $script:Relaxed $true
    if ($problems.Count) { return (New-AapResult 'error' 'untrusted_folder' ($problems -join '; ')) }
    if (-not [IO.Directory]::Exists($Root)) { return (New-AapResult 'error' 'not_initialized' "no $Root; run Initialize-AapAllocator") }
    $read = Read-AapDoc $Root
    if (-not $read.Ok) { return $read }
    $doc = $read.Doc
    $caps = Get-AapCaps $doc
    $live = @(Get-AapLive $doc)
    $profiles = [ordered]@{}
    foreach ($name in @('linux', 'windows')) {
        $mine = @($live | Where-Object { $_.profile -ceq $name })
        $profiles[$name] = [pscustomobject][ordered]@{
            Count = [long]$doc.profiles.$name.count; Admitted = @($mine | Where-Object { Test-AapAdmitted $_ }).Count; Live = $mine.Count
            EachCpus = $caps[$name].EachCpus; EachMemGib = $caps[$name].EachMemGib; CapCpus = $caps[$name].CapCpus; CapMemGib = $caps[$name].CapMemGib
        }
    }
    New-AapResult 'ok' $null '' ([ordered]@{
            State = $doc; Revision = [long]$doc.revision; UsedSlots = $live.Count; FreeSlots = 5 - $live.Count
            PoolCpus = $caps.PoolCpus; PoolMemGib = $caps.PoolMemGib; UsedCpus = (Get-AapSum $live { $args[0].cpus }); UsedMemGib = (Get-AapSum $live { Get-AapMem $args[0] })
            Profiles = [pscustomobject]$profiles; MeasurementClamped = [IO.File]::Exists((Join-Path $Root 'host.measured.json'))
        })
}

# The last measurement Set-AapHostMeasurement had to clamp (host.measured.json), without its
# volumes: @{ Host = ... }, @{ Host = $null } when there is none, or @{ Error = result }.
function Read-AapRawHost([string]$Root) {
    $path = Join-Path $Root 'host.measured.json'
    if (-not [IO.File]::Exists($path)) { return @{ Host = $null } }
    $why = $null
    try {
        $text = Read-AapText $path 65536
        if ($null -eq $text) { $why = 'over 64 KiB' }
        else {
            $raw = ConvertFrom-AapJson $text
            $schema = Get-AapSchema
            $why = Test-AapNode (Get-AapProp (Get-AapProp $schema 'properties').Value 'host').Value $raw $schema '$.host'
        }
    } catch { $why = 'not JSON' }
    if ($why) { return @{ Error = (New-AapResult 'error' 'invalid_state' "$path is unreadable ($why); no admission until a new host measurement replaces it") } }
    @{ Host = $raw }
}

# unresolved.json, written only by reconcile: @{ Items = ... } or @{ Error = result }.
function Read-AapUnresolved([string]$Root) {
    $path = Join-Path $Root 'unresolved.json'
    if (-not [IO.File]::Exists($path)) { return @{ Items = @() } }
    $items = $null
    try {
        $text = Read-AapText $path 65536
        if ($null -ne $text) {
            $p = Get-AapProp (ConvertFrom-AapJson $text) 'items'
            if ($null -ne $p -and $p.Value -is [array]) { $items = @($p.Value) }
        }
    } catch { $items = $null }
    if ($null -eq $items) { return @{ Error = (New-AapResult 'error' 'invalid_state' "$path is unreadable or not an items list; the owner removes it, and the next reconcile writes it again") } }
    @{ Items = $items }
}

# Smallest v in Lo..Hi for which Holds is true; Holds(Hi) is true and Holds only grows with v.
function Find-AapLeast([long]$Lo, [long]$Hi, [scriptblock]$Holds) {
    while ($Lo -lt $Hi) {
        $mid = $Lo + [long][Math]::Floor(($Hi - $Lo) / 2)
        if (& $Holds $mid) { $Hi = $mid } else { $Lo = $mid + 1 }
    }
    $Lo
}

# Doc.host is a measurement the live reservations no longer fit; Old is the stored host they fit.
# Each measured value moves the least that holds them again: disk and IO up to the live sums,
# CPUs up, the control VM's memory down (then RAM up). Disk, IO and the memory pool are then
# exactly full. Raised CPUs or RAM can still leave room on paper (in even mode each admitted
# runner keeps its share), so Request-AapReservation also checks every admission against the raw
# measurement kept in host.measured.json. Returns the clamped field names.
function Limit-AapHost($Doc, $Old) {
    $h = $Doc.host
    $clamped = New-Object System.Collections.Generic.List[string]
    $live = @(Get-AapLive $Doc)
    $keep = 100 - [long]$Doc.host_reserve_percent
    $fits = { $null -eq (Test-AapSemantic $Doc) }
    # Disk: a VM admitted on a layout keeps it; a measurement without the base, clone or scratch
    # tier keeps the old layout. Every clone or scratch volume gets at least what its live
    # reservations hold, and a kept old layout exactly that.
    $tiers = @(@($h.volumes) | ForEach-Object { @($_.tiers) })
    $keepOld = @($live | Where-Object { $_.backend -ceq 'hyperv-vm' }).Count -and -not (($tiers -ccontains 'base') -and ($tiers -ccontains 'clone') -and ($tiers -ccontains 'scratch'))
    if ($keepOld) { $h.volumes = (ConvertFrom-AapJson (ConvertTo-AapJson $Old)).volumes }
    $moved = $keepOld
    foreach ($v in @($h.volumes)) {
        if (-not ((@($v.tiers) -ccontains 'clone') -or (@($v.tiers) -ccontains 'scratch'))) { continue }
        $fit = (Get-AapVolumeNeed $v $live) + [long]$v.floor_gib + [long]$v.held_gib
        if ([long]$v.available_gib -lt $fit -or ($keepOld -and [long]$v.available_gib -gt $fit)) { $v.available_gib = $fit; $moved = $true }
    }
    if ($moved) { $clamped.Add('volumes') }
    $io = Get-AapSum $live { $args[0].io_mbps }
    if ($io -gt 0 -and (Get-AapFloorDiv ([long]$h.io_mbps * $keep) 100) -lt $io) {
        $h.io_mbps = Find-AapLeast ([long]$h.io_mbps) ([long]$Old.io_mbps) { param($v) (Get-AapFloorDiv ($v * $keep) 100) -ge $io }
        $clamped.Add('io_mbps')
    }
    # CPU checks do not read memory: settle CPUs with the old (holding) memory values in place.
    $mem = [long]$h.mem_gib
    $ctl = [long]$h.control_distro_mem_gib
    $h.mem_gib = [long]$Old.mem_gib
    $h.control_distro_mem_gib = [long]$Old.control_distro_mem_gib
    if (-not (& $fits)) {
        $h.cpu_cores = Find-AapLeast ([long]$h.cpu_cores) ([long]$Old.cpu_cores) { param($v) $h.cpu_cores = $v; & $fits }
        $clamped.Add('cpu_cores')
    }
    $h.mem_gib = $mem
    $h.control_distro_mem_gib = $ctl
    if (-not (& $fits)) {
        $h.control_distro_mem_gib = 0
        if (& $fits) {
            $cut = Find-AapLeast 0 $ctl { param($v) $h.control_distro_mem_gib = $ctl - $v; & $fits }
            $h.control_distro_mem_gib = $ctl - $cut
        } else {
            $h.mem_gib = Find-AapLeast $mem ([long]$Old.mem_gib) { param($v) $h.mem_gib = $v; & $fits }
            $clamped.Add('mem_gib')
        }
        if ([long]$h.control_distro_mem_gib -ne $ctl) { $clamped.Add('control_distro_mem_gib') }
    }
    , $clamped.ToArray()
}

# A measurement the live reservations still fit is stored as is (and host.measured.json goes). One
# they no longer fit is kept raw in host.measured.json, stored clamped to them (Limit-AapHost) and
# refused: admission then has to fit both, never the older, larger host. 'storage_low' when only a
# volume with nothing live on it fell below its floor plus held space, else 'pool_over_live'.
function Set-AapHostMeasurement {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$HostInfo, [int]$LockTimeoutSeconds = 30, [switch]$RelaxedTrustForTests)
    Invoke-AapLocked $Root ([bool]$RelaxedTrustForTests) $LockTimeoutSeconds {
        param($doc)
        $old = $doc.host
        $doc.host = ConvertTo-AapHost $HostInfo (Format-AapTime (Get-AapUtcNow))
        $e = Test-AapDoc (ConvertFrom-AapJson (ConvertTo-AapJson $doc))
        if ($e -and $e.StartsWith('$.host', [StringComparison]::Ordinal)) { return (New-AapResult 'refused' 'bad_request' $e) }
        $layout = Test-AapVolumes $doc.host.volumes @() -LayoutOnly
        if ($layout) { return (New-AapResult 'refused' 'bad_request' "host.volumes: $layout") }
        if (-not $e) {
            Save-AapDoc $Root $doc "host $(ConvertTo-AapJson $doc.host)"
            foreach ($n in @('host.measured.json', 'host.measured.json.bak')) { $f = Join-Path $Root $n; if ([IO.File]::Exists($f)) { [IO.File]::Delete($f) } }
            return (New-AapResult 'ok' $null 'host measurement stored')
        }
        $measured = ConvertTo-AapJson $doc.host
        # Kept before the clamped host is stored: a crash in between only refuses more.
        Write-AapAtomic $Root 'host.measured.json' $measured
        $live = @(Get-AapLive $doc)
        $clamped = Limit-AapHost $doc $old
        $reason = 'pool_over_live'
        if ($clamped.Count -eq 1 -and $clamped[0] -ceq 'volumes' -and -not @($doc.host.volumes | Where-Object { (Get-AapVolumeNeed $_ $live) -gt 0 }).Count) { $reason = 'storage_low' }
        Save-AapDoc $Root $doc "host measured $measured does not hold the live reservations ($e); stored clamped $(ConvertTo-AapJson $doc.host)"
        $why = "the new measurement does not hold the live reservations ($e); stored with $($clamped -join ', ') clamped to them, and every admission must also fit the measurement, so nothing more is admitted until they leave"
        if ($reason -ceq 'storage_low') { $why = "a volume holding the clone or scratch tier is below its floor plus held space ($e); no VM is admitted until free space returns" }
        New-AapResult 'refused' $reason $why ([ordered]@{ Clamped = $clamped; Host = $doc.host })
    }
}

# Two live controls. Resizing down cancels nothing: an admitted reservation that no longer fits
# (count, per-runner share, profile cap or backend) moves to draining (ready, busy) or deleting
# (creating that holds no job). A heartbeat quarantine, or a VM still creating without a vm_id,
# cannot move; while one of those would have to leave, the change is refused ('resize_waits') and
# nothing changes. A change the live reservations cannot hold (a larger reserve) is refused
# ('pool_over_live').
function Set-AapProfileCounts {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][int]$Linux, [Parameter(Mandatory)][int]$Windows,
        [ValidateSet('even', 'per_profile', IgnoreCase = $false)][string]$ShareMode,
        $LinuxShare, $WindowsShare,
        [int]$HostReservePercent,
        [ValidateSet('wsl-legacy', 'hyperv-vm', IgnoreCase = $false)][string]$LinuxBackend,
        $LinuxGeneration, $WindowsGeneration,
        [int]$LockTimeoutSeconds = 30, [switch]$RelaxedTrustForTests)
    $bound = @{}
    foreach ($k in @('Linux', 'Windows', 'ShareMode', 'LinuxShare', 'WindowsShare', 'HostReservePercent', 'LinuxBackend', 'LinuxGeneration', 'WindowsGeneration')) {
        if ($PSBoundParameters.ContainsKey($k)) { $bound[$k] = $PSBoundParameters[$k] }
    }
    Invoke-AapLocked $Root ([bool]$RelaxedTrustForTests) $LockTimeoutSeconds {
        param($doc)
        $before = ConvertTo-AapJson $doc
        $e = Set-AapSettings $doc $bound
        if ($e) { return (New-AapResult 'refused' 'bad_request' $e) }
        $now = Format-AapTime (Get-AapUtcNow)
        $caps = Get-AapCaps $doc
        $moved = New-Object System.Collections.Generic.List[object]
        $stuck = New-Object System.Collections.Generic.List[string]
        foreach ($name in @('linux', 'windows')) {
            $c = $caps[$name]
            $leave = New-Object System.Collections.Generic.List[object]
            $keep = New-Object System.Collections.Generic.List[object]
            foreach ($r in @(Get-AapLive $doc | Where-Object { $_.profile -ceq $name -and (Test-AapAdmitted $_) })) {
                if ($r.backend -cne $doc.profiles.$name.backend -or [long]$r.cpus -gt $c.EachCpus -or (Get-AapMem $r) -gt $c.EachMemGib) { $leave.Add($r) } else { $keep.Add($r) }
            }
            # Idle runners leave first, then creating ones (no job yet), then busy ones (the job keeps
            # running while they drain); what cannot move goes last.
            $order = @($keep | Sort-Object -Property @{ Expression = { Get-AapLeaveRank $_ } }, @{ Expression = { [int]$_.slot }; Descending = $true })
            $i = 0
            while ($i -lt $order.Count -and ($keep.Count -gt [long]$doc.profiles.$name.count -or (Get-AapSum $keep { $args[0].cpus }) -gt $c.CapCpus -or (Get-AapSum $keep { Get-AapMem $args[0] }) -gt $c.CapMemGib)) {
                [void]$keep.Remove($order[$i])
                $leave.Add($order[$i])
                $i++
            }
            foreach ($r in $leave) {
                switch (Get-AapLeaveRank $r) {
                    0 { $moved.Add(@($r, 'draining')) }
                    2 { $moved.Add(@($r, 'draining')) }
                    1 { $moved.Add(@($r, 'deleting')) }
                    default { $stuck.Add("$($r.reservation_id) (slot $($r.slot), $($r.state))") }
                }
            }
        }
        if ($stuck.Count) { return (New-AapResult 'refused' 'resize_waits' "these must leave admission first and cannot be moved yet: $($stuck -join ', ')") }
        foreach ($m in $moved) { Set-AapEdge $m[0] $m[1] $now }
        $e = Test-AapDoc (ConvertFrom-AapJson (ConvertTo-AapJson $doc))
        if ($e) { return (New-AapResult 'refused' 'pool_over_live' "the live reservations do not fit the new settings: $e") }
        $draining = @($moved | Where-Object { $_[1] -ceq 'draining' } | ForEach-Object { $_[0].reservation_id })
        $cancelled = @($moved | Where-Object { $_[1] -ceq 'deleting' } | ForEach-Object { $_[0].reservation_id })
        if ((ConvertTo-AapJson $doc) -ceq $before) { return (New-AapResult 'unchanged' $null 'settings already applied' ([ordered]@{ Drained = @(); Cancelled = @() })) }
        Save-AapDoc $Root $doc "profiles linux=$($doc.profiles.linux.count) windows=$($doc.profiles.windows.count) mode=$($doc.share_mode) reserve=$($doc.host_reserve_percent) draining=[$($draining -join ',')] cancelled=[$($cancelled -join ',')]"
        New-AapResult 'ok' $null 'settings applied' ([ordered]@{ Drained = $draining; Cancelled = $cancelled })
    }
}

# Admission. Persisted before the provider's create (or before a legacy slot may start) and before
# any broker lease; returns the reservation and the derived VM and runner name. Sizes default to
# the profile's per-runner share (memory minus the VM overhead). VM reservations take their
# measured budget explicitly: -MemOverheadMib, -CloneGib (clone_gib_max, at least 1), -ScratchGib
# (scratch_gib_max) and -IoMbps.
function Request-AapReservation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][ValidateSet('linux', 'windows', IgnoreCase = $false)][string]$Profile,
        $Cpus = $null, $MemGib = $null, $MemOverheadMib = $null, $CloneGib = $null, $ScratchGib = $null, $IoMbps = $null,
        [string]$ImageGeneration = '',
        [int]$LockTimeoutSeconds = 30, [switch]$RelaxedTrustForTests)
    Invoke-AapLocked $Root ([bool]$RelaxedTrustForTests) $LockTimeoutSeconds {
        param($doc)
        $u = Read-AapUnresolved $Root
        if ($u.ContainsKey('Error')) { return $u.Error }
        if ($u.Items.Count) { return (New-AapResult 'refused' 'unresolved_unknown' "unknown VMs or folders wait for resolution: $((@($u.Items) | ForEach-Object { Get-AapField $_ 'name' }) -join ', ')") }
        if (-not $doc.legacy_adopted) { return (New-AapResult 'refused' 'legacy_not_adopted' 'the legacy pool is not adopted yet (Register-AapLegacySlots)') }
        $backend = $doc.profiles.$Profile.backend
        foreach ($pair in @(@('Cpus', $Cpus), @('MemGib', $MemGib), @('MemOverheadMib', $MemOverheadMib), @('CloneGib', $CloneGib), @('ScratchGib', $ScratchGib), @('IoMbps', $IoMbps))) {
            if ($null -ne $pair[1] -and (-not (Test-AapInt $pair[1]) -or $pair[1] -lt 0)) { return (New-AapResult 'refused' 'bad_request' "$($pair[0]) must be a whole number") }
        }
        if ($backend -ceq 'hyperv-vm') {
            if ($null -eq $MemOverheadMib -or $null -eq $CloneGib -or $null -eq $ScratchGib -or $null -eq $IoMbps) { return (New-AapResult 'refused' 'bad_request' 'a VM reservation needs the measured -MemOverheadMib, -CloneGib, -ScratchGib and -IoMbps') }
            if ($CloneGib -lt 1) { return (New-AapResult 'refused' 'bad_request' 'a VM reservation reserves at least 1 GiB of clone disk (-CloneGib)') }
            $generation = $ImageGeneration
            if (-not $generation) { $generation = $doc.profiles.$Profile.active_generation }
            if (-not $generation -or $generation -cne $doc.profiles.$Profile.active_generation) { return (New-AapResult 'refused' 'generation' "the $Profile profile admits only its active generation ($($doc.profiles.$Profile.active_generation))") }
            if ([long]$doc.host.io_mbps -eq 0) { return (New-AapResult 'refused' 'io_unmeasured' 'image-root IO is not measured; VM admission waits for it') }
        } else {
            if (($null -ne $MemOverheadMib -and $MemOverheadMib -ne 0) -or ($null -ne $CloneGib -and $CloneGib -ne 0) -or ($null -ne $ScratchGib -and $ScratchGib -ne 0) -or ($null -ne $IoMbps -and $IoMbps -ne 0)) { return (New-AapResult 'refused' 'bad_request' 'legacy reservations have no VM overhead, VM disk or IO') }
            $generation = $ImageGeneration
            if (-not $generation) {
                $newest = @($doc.reservations | Where-Object { $_.backend -ceq 'wsl-legacy' } | Sort-Object -Property @{ Expression = { $_.acquired_at } } | Select-Object -Last 1)
                if ($newest.Count) { $generation = $newest[0].image_generation }
            }
            if (-not $generation -or -not $generation.StartsWith('legacy-', [StringComparison]::Ordinal)) { return (New-AapResult 'refused' 'bad_request' 'a legacy reservation needs -ImageGeneration legacy-<manager version>') }
        }
        $caps = Get-AapCaps $doc
        $c = $caps[$Profile]
        $ovh = 0
        if ($null -ne $MemOverheadMib) { $ovh = [long]$MemOverheadMib }
        if ($null -eq $Cpus) { $Cpus = $c.EachCpus }
        if ($null -eq $MemGib) { $MemGib = $c.EachMemGib - [long][Math]::Ceiling([double]$ovh / 1024) }
        $spec = @{ Profile = $Profile; Backend = $backend; Generation = $generation; State = 'creating'; Cpus = [long]$Cpus; MemGib = [long]$MemGib; OverheadMib = $ovh
            CloneGib = [long]$(if ($null -ne $CloneGib) { $CloneGib } else { 0 }); ScratchGib = [long]$(if ($null -ne $ScratchGib) { $ScratchGib } else { 0 }); IoMbps = [long]$(if ($null -ne $IoMbps) { $IoMbps } else { 0 }) }
        $refusal = Test-AapAdmission $doc $spec
        if ($refusal) { return (New-AapResult 'refused' $refusal[0] $refusal[1]) }
        # A clamped host can hold more than the host measured: the admission has to fit both.
        $raw = Read-AapRawHost $Root
        if ($raw.ContainsKey('Error')) { return $raw.Error }
        if ($null -ne $raw.Host) {
            $copy = ConvertFrom-AapJson (ConvertTo-AapJson $doc)
            $raw.Host.volumes = $copy.host.volumes
            $copy.host = $raw.Host
            $refusal = Test-AapAdmission $copy $spec
            if ($refusal) { return (New-AapResult 'refused' 'pool_over_live' "the last host measurement was stored clamped to the live reservations and cannot hold one more ($($refusal[0]): $($refusal[1]))") }
        }
        if ($spec.Cpus -lt 1 -or $spec.MemGib -lt 1) { return (New-AapResult 'refused' 'share' "the $Profile per-runner share ($($c.EachCpus) CPUs, $($c.EachMemGib) GiB) is too small for one runner") }
        $r = Add-AapReservation $doc $spec (Format-AapTime (Get-AapUtcNow))
        Save-AapDoc $Root $doc "reserve $($r.reservation_id) slot $($r.slot) generation $($r.lease_generation) $Profile $backend cpus=$($r.cpus) mem=$($r.mem_gib) overhead=$($r.mem_overhead_mib) clone=$($r.clone_gib) scratch=$($r.scratch_gib) io=$($r.io_mbps)"
        $vm = Get-AapVmNameOf $r
        New-AapResult 'ok' $null "slot $($r.slot) reserved" ([ordered]@{ Reservation = $r; VmName = $vm; RunnerName = $vm; IdempotencyKey = $r.idempotency_key })
    }
}

# Adoption of the legacy WSL pool, before any VM: one wsl-legacy reservation per slot the manager
# runs, sized at the limits it was given (rounded up, so the pool check never sees less), from a
# status.json sample at most 90 s old. Refused, with the limits.conf target, while the legacy
# pool is bigger than the Linux profile allows. -ManagerStopped adopts a stopped pool (no slots).
function Register-AapLegacySlots {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root,
        $ManagerStatus = $null,
        [ValidatePattern('^[a-z0-9.-]{1,40}\z', Options = 'None')][string]$ManagerVersion = 'manager',
        [switch]$ManagerStopped,
        [int]$LockTimeoutSeconds = 30, [switch]$RelaxedTrustForTests)
    Invoke-AapLocked $Root ([bool]$RelaxedTrustForTests) $LockTimeoutSeconds {
        param($doc)
        if ($doc.legacy_adopted) { return (New-AapResult 'unchanged' 'already_adopted' 'the legacy pool is already adopted') }
        $nowDt = Get-AapUtcNow
        $now = Format-AapTime $nowDt
        if ($ManagerStopped) {
            $doc.legacy_adopted = $true
            Save-AapDoc $Root $doc 'legacy adopted: manager stopped, no legacy slots'
            return (New-AapResult 'ok' $null 'adopted a stopped legacy pool' ([ordered]@{ Reservations = @() }))
        }
        $caps = Get-AapCaps $doc
        $c = $caps.linux
        $target = [ordered]@{ RunnerCount = [long]$doc.profiles.linux.count; JobCpus = $c.EachCpus * [long]$doc.profiles.linux.count; JobMemoryGib = $c.EachMemGib * [long]$doc.profiles.linux.count }
        $sample = ConvertFrom-AapRfc3339 (Get-AapField $ManagerStatus 'sampled_at')
        $state = Get-AapField $ManagerStatus 'state'
        $n = Get-AapField $ManagerStatus 'runner_count'
        $cpus = Get-AapField $ManagerStatus 'job_cpus'
        $mem = Get-AapField $ManagerStatus 'job_memory_gib'
        if ($null -eq $sample -or ($nowDt - $sample).TotalSeconds -gt $script:StatusMaxAge -or ($sample - $nowDt).TotalSeconds -gt 30 -or
            @('idle', 'running', 'draining') -cnotcontains $state -or -not (Test-AapInt $n) -or $n -lt 1 -or $n -gt 5 -or
            -not (Test-AapInt $cpus) -or $cpus -lt 1 -or -not (Test-AapInt $mem) -or $mem -lt 1) {
            return (New-AapResult 'refused' 'legacy_status_stale' 'adoption needs a status.json sample at most 90 s old from a running manager with its applied limits' ([ordered]@{ Target = $target }))
        }
        if ($doc.profiles.linux.backend -cne 'wsl-legacy' -or $n -gt [long]$doc.profiles.linux.count -or $n -gt 5 - @(Get-AapLive $doc).Count) {
            return (New-AapResult 'refused' 'legacy_over_count' "the manager runs $n legacy slots; the Linux profile allows $($doc.profiles.linux.count) on $($doc.profiles.linux.backend)" ([ordered]@{ Target = $target }))
        }
        $each = @([long][Math]::Ceiling([double]$cpus / $n), [long][Math]::Ceiling([double]$mem / $n))
        if ($each[0] -gt $c.EachCpus -or $each[1] -gt $c.EachMemGib) {
            return (New-AapResult 'refused' 'legacy_over_share' "each legacy slot gets $($each[0]) CPUs and $($each[1]) GiB; the Linux per-runner share is $($c.EachCpus) CPUs and $($c.EachMemGib) GiB" ([ordered]@{ Target = $target }))
        }
        $slots = @(Get-AapField $ManagerStatus 'slots')
        $added = New-Object System.Collections.Generic.List[object]
        for ($i = 1; $i -le $n; $i++) {
            $entry = @($slots | Where-Object { (Get-AapField $_ 'slot') -eq $i }) | Select-Object -First 1
            $st = Get-AapField $entry 'state'
            if (-not ($st -is [string])) { $st = '' }
            # A retired or unreported slot gets no heartbeat, so reconcile quarantines it (held).
            $to = 'ready'
            if ($st -ceq 'running' -or $st -ceq 'draining') { $to = 'busy' } elseif ($st -ceq 'starting') { $to = 'creating' }
            $r = Add-AapReservation $doc @{ Profile = 'linux'; Backend = 'wsl-legacy'; Generation = "legacy-$ManagerVersion"; State = $to; Cpus = $each[0]; MemGib = $each[1]; OverheadMib = 0; CloneGib = 0; ScratchGib = 0; IoMbps = 0 } $now
            if (@('idle', 'running', 'draining', 'starting') -ccontains $st) { $r.heartbeat_at = Format-AapTime $(if ($sample -lt $nowDt) { $sample } else { $nowDt }) }
            $added.Add($r)
        }
        $doc.legacy_adopted = $true
        $e = Test-AapDoc (ConvertFrom-AapJson (ConvertTo-AapJson $doc))
        if ($e) { return (New-AapResult 'refused' 'legacy_over_pool' "the legacy pool does not fit: $e" ([ordered]@{ Target = $target })) }
        Save-AapDoc $Root $doc "legacy adopted: $n slots of $($each[0]) CPUs and $($each[1]) GiB ($(@($added | ForEach-Object { "$($_.slot):$($_.state)" }) -join ', '))"
        New-AapResult 'ok' $null "adopted $n legacy slots" ([ordered]@{ Reservations = $added.ToArray() })
    }
}

# What limits.conf must say: one legacy slot per granted legacy reservation (creating, ready, busy
# or heartbeat-quarantined), and exactly their CPUs and memory, so the manager's even split never
# exceeds what the allocator counts. Stop when none is granted (the manager accepts only 1..5).
# Before adoption: the most the Linux profile allows. NextSlot*: the size for the next legacy
# grant given the settings' pool totals (the minimum of the setting and the Linux cap).
function Get-AapLegacyLimits {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, $JobCpus = $null, $JobMemoryGib = $null, [switch]$RelaxedTrustForTests)
    $state = Get-AapAllocatorState -Root $Root -RelaxedTrustForTests:$RelaxedTrustForTests
    if (-not $state.Ok) { return $state }
    $doc = $state.State
    $caps = Get-AapCaps $doc
    $c = $caps.linux
    $count = [long]$doc.profiles.linux.count
    $capCpus = $c.CapCpus
    $capMem = $c.CapMemGib
    if ($null -ne $JobCpus) { $capCpus = [Math]::Min($capCpus, [long]$JobCpus) }
    if ($null -ne $JobMemoryGib) { $capMem = [Math]::Min($capMem, [long]$JobMemoryGib) }
    $next = @(0, 0)
    if ($count) { $next = @([Math]::Min($c.EachCpus, (Get-AapFloorDiv $capCpus $count)), [Math]::Min($c.EachMemGib, (Get-AapFloorDiv $capMem $count))) }
    if (-not $doc.legacy_adopted) {
        $stop = ($count -eq 0 -or $doc.profiles.linux.backend -cne 'wsl-legacy')
        return (New-AapResult 'ok' $null 'not adopted: the most the Linux profile allows' ([ordered]@{ Adopted = $false; Stop = $stop; RunnerCount = $count; JobCpus = $next[0] * $count; JobMemoryGib = $next[1] * $count; NextSlotCpus = $next[0]; NextSlotMemGib = $next[1] }))
    }
    $granted = @(Get-AapLive $doc | Where-Object { $_.backend -ceq 'wsl-legacy' -and (Test-AapAdmitted $_) })
    New-AapResult 'ok' $null '' ([ordered]@{
            Adopted = $true; Stop = ($granted.Count -eq 0); RunnerCount = $granted.Count
            JobCpus = (Get-AapSum $granted { $args[0].cpus }); JobMemoryGib = (Get-AapSum $granted { $args[0].mem_gib })
            NextSlotCpus = $next[0]; NextSlotMemGib = $next[1]
        })
}

# Heartbeats. VM: a validated guest status reply for one reservation (generation-bound). Legacy:
# the manager's slot entries in a status.json sample at most 90 s old; granted legacy
# reservations, oldest first, are manager slots 1..n. heartbeat_at moves at most every 30 s.
# A heartbeat quarantine returns to busy (job running) or ready. The legacy pass also releases
# legacy reservations that left admission once the manager reports a configuration they no longer
# belong to (its applied runner count and limits fit the granted ones), or with -ManagerStopped.
function Update-AapHeartbeat {
    [CmdletBinding(DefaultParameterSetName = 'Vm')]
    param([Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory, ParameterSetName = 'Vm')][string]$ReservationId,
        [Parameter(Mandatory, ParameterSetName = 'Vm')][long]$LeaseGeneration,
        [Parameter(ParameterSetName = 'Vm')][switch]$JobRunning,
        [Parameter(ParameterSetName = 'Legacy')]$ManagerStatus = $null,
        [Parameter(ParameterSetName = 'Legacy')][switch]$ManagerStopped,
        [int]$LockTimeoutSeconds = 30, [switch]$RelaxedTrustForTests)
    $set = $PSCmdlet.ParameterSetName
    Invoke-AapLocked $Root ([bool]$RelaxedTrustForTests) $LockTimeoutSeconds {
        param($doc)
        $before = ConvertTo-AapJson $doc
        $nowDt = Get-AapUtcNow
        $now = Format-AapTime $nowDt
        if ($set -eq 'Vm') {
            $f = Find-AapReservation $doc $ReservationId $LeaseGeneration
            if ($f.ContainsKey('Result')) {
                if ($f.ContainsKey('Stale')) { Write-AapCapLog $Root "ignored late heartbeat: $($f.Result.Detail)" }
                return $f.Result
            }
            $r = $f.Reservation
            if ($r.backend -cne 'hyperv-vm') { return (New-AapResult 'refused' 'bad_request' 'legacy heartbeats come from the manager status (-ManagerStatus)') }
            $old = "$($r.state)/$($r.heartbeat_at)"
            if ($r.state -ceq 'quarantined') {
                if ($r.quarantine_kind -cne 'heartbeat') {
                    Write-AapCapLog $Root "ignored heartbeat for $($r.reservation_id): quarantine $($r.quarantine_kind) is final"
                    return (New-AapResult 'ignored' 'quarantine_final' "quarantine $($r.quarantine_kind) never returns to service")
                }
                Set-AapEdge $r $(if ($JobRunning) { 'busy' } else { 'ready' }) $now
                $r.cleanup_uncertain = $false
                $r.heartbeat_at = $now
            } elseif (@('ready', 'busy', 'draining', 'collecting') -ccontains $r.state) {
                if ($JobRunning -and $r.state -ceq 'ready') { Set-AapEdge $r 'busy' $now }
                if ($null -eq $r.heartbeat_at -or ($nowDt - (ConvertFrom-AapTime $r.heartbeat_at)).TotalSeconds -ge $script:HeartbeatSeconds) { $r.heartbeat_at = $now }
            } else {
                return (New-AapResult 'ignored' 'not_listening' "a $($r.state) reservation has no heartbeat")
            }
            if ("$($r.state)/$($r.heartbeat_at)" -ceq $old) { return (New-AapResult 'unchanged' $null 'heartbeat recorded less than 30 s ago') }
            Save-AapDoc $Root $doc "heartbeat $($r.reservation_id) $($old.Split('/')[0])->$($r.state)"
            return (New-AapResult 'ok' $null "heartbeat $($r.state)" ([ordered]@{ Reservation = $r }))
        }
        $changes = New-Object System.Collections.Generic.List[string]
        $legacy = @(Get-AapLive $doc | Where-Object { $_.backend -ceq 'wsl-legacy' })
        $granted = @($legacy | Where-Object { Test-AapAdmitted $_ } | Sort-Object -Property @{ Expression = { $_.acquired_at } }, @{ Expression = { [int]$_.slot } })
        $leaving = @($legacy | Where-Object { -not (Test-AapAdmitted $_) })
        $proof = [pscustomobject][ordered]@{ kind = 'legacy'; observed_at = $now; manager_reports_slot_gone = $true; runner_deregistered = $true }
        if ($ManagerStopped) {
            foreach ($r in $leaving) { Move-AapDown $r $now $proof; $changes.Add("released $($r.reservation_id) (manager stopped)") }
        } else {
            $sample = ConvertFrom-AapRfc3339 (Get-AapField $ManagerStatus 'sampled_at')
            $state = Get-AapField $ManagerStatus 'state'
            if ($null -eq $sample -or ($nowDt - $sample).TotalSeconds -gt $script:StatusMaxAge -or ($sample - $nowDt).TotalSeconds -gt 30 -or @('idle', 'running', 'draining') -cnotcontains $state) {
                return (New-AapResult 'ignored' 'legacy_status_stale' 'no legacy heartbeat from a sample older than 90 s or a stopped manager')
            }
            if ($sample -gt $nowDt) { $sample = $nowDt }
            $at = Format-AapTime $sample
            $slots = @(Get-AapField $ManagerStatus 'slots')
            for ($i = 0; $i -lt $granted.Count; $i++) {
                $r = $granted[$i]
                $entry = @($slots | Where-Object { (Get-AapField $_ 'slot') -eq ($i + 1) }) | Select-Object -First 1
                $st = Get-AapField $entry 'state'
                if (@('idle', 'running', 'draining', 'starting') -cnotcontains $st) { continue }
                $was = $r.state
                if ($r.state -ceq 'quarantined') {
                    Set-AapEdge $r $(if ($st -ceq 'running' -or $st -ceq 'draining') { 'busy' } else { 'ready' }) $now
                    $r.cleanup_uncertain = $false
                    $r.heartbeat_at = $at
                } else {
                    if ($r.state -ceq 'creating' -and ($st -ceq 'idle' -or $st -ceq 'running')) { Set-AapEdge $r 'ready' $now }
                    # Legacy only: a pool slot runs one ephemeral runner after another, so busy goes
                    # back to ready when the manager reports the slot listening again.
                    if ($st -ceq 'running' -and $r.state -ceq 'ready') { Set-AapEdge $r 'busy' $now }
                    elseif ($st -ceq 'idle' -and $r.state -ceq 'busy') { Set-AapEdge $r 'ready' $now }
                    if ($r.state -cne 'creating' -and ($null -eq $r.heartbeat_at -or ($sample - (ConvertFrom-AapTime $r.heartbeat_at)).TotalSeconds -ge $script:HeartbeatSeconds)) { $r.heartbeat_at = $at }
                }
                if ($r.state -cne $was) { $changes.Add("$($r.reservation_id) $was->$($r.state)") }
            }
            $n = Get-AapField $ManagerStatus 'runner_count'
            $cpus = Get-AapField $ManagerStatus 'job_cpus'
            $mem = Get-AapField $ManagerStatus 'job_memory_gib'
            if ($leaving.Count -and ($state -ceq 'idle' -or $state -ceq 'running') -and (Test-AapInt $n) -and $n -eq $granted.Count -and
                (Test-AapInt $cpus) -and $cpus -le (Get-AapSum $granted { $args[0].cpus }) -and (Test-AapInt $mem) -and $mem -le (Get-AapSum $granted { $args[0].mem_gib })) {
                foreach ($r in $leaving) { Move-AapDown $r $now $proof; $changes.Add("released $($r.reservation_id) (manager runs $n slots)") }
            }
        }
        if ((ConvertTo-AapJson $doc) -ceq $before) { return (New-AapResult 'unchanged' $null 'no legacy change') }
        Save-AapDoc $Root $doc "legacy heartbeat $($changes -join '; ')"
        New-AapResult 'ok' $null ($changes -join '; ') ([ordered]@{ Changes = $changes.ToArray() })
    }
}

# One edge of the state machine for one live lease (reservation id and its generation). An older
# generation (a late job_done after the slot was reset) is ignored for state and logged.
function Set-AapSlotState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ReservationId,
        [Parameter(Mandatory)][long]$LeaseGeneration,
        [Parameter(Mandatory)][ValidateSet('ready', 'busy', 'draining', 'collecting', 'deleting', 'quarantined', IgnoreCase = $false)][string]$State,
        [ValidateSet('heartbeat', 'hostile_guest', 'teardown_failed', 'crash', IgnoreCase = $false)][string]$QuarantineKind,
        [string]$Reason = '',
        [string]$VmId = '',
        [int]$LockTimeoutSeconds = 30, [switch]$RelaxedTrustForTests)
    Invoke-AapLocked $Root ([bool]$RelaxedTrustForTests) $LockTimeoutSeconds {
        param($doc)
        $f = Find-AapReservation $doc $ReservationId $LeaseGeneration
        if ($f.ContainsKey('Result')) {
            if ($f.ContainsKey('Stale')) { Write-AapCapLog $Root "ignored late $State`: $($f.Result.Detail)" }
            return $f.Result
        }
        $r = $f.Reservation
        $from = $r.state
        $withheld = ''
        $hostile = $State -ceq 'quarantined' -and $QuarantineKind -ceq 'hostile_guest'
        if (-not $hostile -and $from -ceq $State -and ($State -cne 'quarantined' -or $r.quarantine_kind -ceq $QuarantineKind)) { return (New-AapResult 'unchanged' $null "already $State") }
        if ($hostile) {
            if ($r.backend -cne 'hyperv-vm') { return (New-AapResult 'refused' 'bad_request' 'hostile_guest applies to a VM guest') }
            if ($from -ceq 'deleting') { return (New-AapResult 'unchanged' $null 'already deleting (hostile_guest is final)') }
            if ($script:GuestStates -cnotcontains $from -and -not ($from -ceq 'quarantined' -and $script:HostileOver -ccontains $r.quarantine_kind)) {
                return (New-AapResult 'refused' 'illegal_edge' "$from -> deleting (hostile_guest) is not allowed")
            }
        } elseif ($script:Edges[$from] -cnotcontains $State) { return (New-AapResult 'refused' 'illegal_edge' "$from -> $State is not an edge of the slot state machine") }
        if ($State -ceq 'quarantined') {
            if (-not $QuarantineKind -or (-not $hostile -and $script:QuarantineFrom[$QuarantineKind] -cnotcontains $from)) { return (New-AapResult 'refused' 'illegal_edge' "$from -> quarantined ($QuarantineKind) is not allowed") }
            if (-not $Reason -or $Reason -match '[\x00-\x1f\x7f\u0085\u2028\u2029]' -or $Reason.Length -gt 200) { return (New-AapResult 'refused' 'bad_request' 'a quarantine needs a one-line -Reason of at most 200 characters') }
            # A credential-shaped reason would make the whole write fail the contract; the quarantine
            # matters more than its text.
            if ($Reason -cmatch $script:SecretValue) { $Reason = 'reason withheld: it looked like a credential'; $withheld = ' (reason withheld: it looked like a credential)' }
        }
        if ($from -ceq 'quarantined' -and $State -ceq 'deleting' -and $r.quarantine_kind -ceq 'heartbeat') {
            return (New-AapResult 'refused' 'illegal_edge' 'a heartbeat quarantine goes to deleting only through Invoke-AapReconcile, on the broker status')
        }
        if ($from -ceq 'quarantined' -and $State -ceq 'deleting' -and $r.quarantine_kind -ceq 'unknown_vm') {
            return (New-AapResult 'refused' 'illegal_edge' 'an unknown VM goes to deleting only through Invoke-AapReconcile, when a journal entry names its reservation')
        }
        if ($VmId) {
            if ($r.backend -cne 'hyperv-vm' -or $VmId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z' -or ($null -ne $r.vm_id -and $r.vm_id -cne $VmId)) {
                return (New-AapResult 'refused' 'bad_request' "vm id $VmId does not fit $($r.reservation_id)")
            }
            $r.vm_id = $VmId
        }
        if ($r.backend -ceq 'hyperv-vm' -and $null -eq $r.vm_id) { return (New-AapResult 'refused' 'bad_request' 'a VM reservation leaves creating only with its -VmId (or is reconciled with a never_registered proof)') }
        $now = Format-AapTime (Get-AapUtcNow)
        if ($hostile) {
            # From a heartbeat or crash quarantine, first the kind (quarantined -> quarantined), then
            # deleting: two writes, so rule 10 holds at each, and a crash between them leaves a final
            # hostile quarantine that the provider's retry moves on.
            if ($from -ceq 'quarantined' -and $r.quarantine_kind -cne 'hostile_guest') {
                $r.quarantine_kind = 'hostile_guest'
                $r.quarantine_reason = $Reason
                $r.state_changed_at = $now
                $r.cleanup_uncertain = $true
                Save-AapDoc $Root $doc "$($r.reservation_id) slot $($r.slot) quarantined->quarantined hostile_guest $Reason"
            }
            Set-AapEdge $r 'deleting' $now
            $r.cleanup_uncertain = $true
            Save-AapDoc $Root $doc "$($r.reservation_id) slot $($r.slot) $from->deleting hostile_guest $Reason"
            return (New-AapResult 'ok' $null "$from -> deleting (hostile_guest, final)$withheld" ([ordered]@{ Reservation = $r }))
        }
        Set-AapEdge $r $State $now
        if ($State -ceq 'ready') {
            $r.heartbeat_at = $now
            if ($r.backend -ceq 'hyperv-vm') { $r.runner_name = Get-AapVmNameOf $r }
        }
        if ($State -ceq 'quarantined') {
            $r.quarantine_kind = $QuarantineKind
            $r.quarantine_reason = $Reason
            $r.cleanup_uncertain = $true
        }
        Save-AapDoc $Root $doc "$($r.reservation_id) slot $($r.slot) $from->$State $QuarantineKind $Reason"
        New-AapResult 'ok' $null "$from -> $State$withheld" ([ordered]@{ Reservation = $r })
    }
}

function ConvertTo-AapProof($Proof, $R) {
    $kind = Get-AapField $Proof 'kind'
    $want = 'vm'
    if ($R.backend -ceq 'wsl-legacy') { $want = 'legacy' }
    if (-not ($kind -is [string]) -or $kind -cne $want) { return "a $($R.backend) reservation needs a '$want' proof" }
    $keys = @('kind', 'observed_at', 'vm_absent', 'disks_absent', 'vm_files_absent', 'runner_deregistered')
    if ($want -ceq 'legacy') { $keys = @('kind', 'observed_at', 'manager_reports_slot_gone', 'runner_deregistered') }
    $names = @(if ($Proof -is [Collections.IDictionary]) { $Proof.Keys } else { $Proof.PSObject.Properties | ForEach-Object { $_.Name } })
    if (@($names | Where-Object { $keys -cnotcontains $_ }).Count -or @($keys | Where-Object { $names -cnotcontains $_ }).Count) { return "the proof must have exactly $($keys -join ', ')" }
    foreach ($k in $keys) {
        if (@('kind', 'observed_at', 'runner_deregistered') -ccontains $k) { continue }
        $v = Get-AapField $Proof $k
        if (-not ($v -is [bool] -and $v)) { return "$k is not observed true" }
    }
    $dereg = Get-AapField $Proof 'runner_deregistered'
    if (-not (($dereg -is [bool] -and $dereg) -or ($dereg -is [string] -and ($dereg -ceq 'github-removed' -or $dereg -ceq 'never_registered')))) { return 'runner_deregistered must be true, github-removed or never_registered' }
    $at = Get-AapField $Proof 'observed_at'
    if (-not ($at -is [string]) -or $at -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z') { return 'observed_at must be YYYY-MM-DDTHH:MM:SSZ' }
    $atDt = ConvertFrom-AapTime $at
    if ($atDt -lt (ConvertFrom-AapTime $R.acquired_at) -or $atDt -gt (Get-AapUtcNow).AddSeconds(60)) { return 'observed_at is not between the reservation and now' }
    $o = [ordered]@{}
    foreach ($k in $keys) { $o[$k] = Get-AapField $Proof $k }
    [pscustomobject]$o
}

# Frees a slot: only an observed teardown proof moves deleting or quarantined to reconciled. A VM
# reservation that never got a VM (vm_id null) may go from creating straight to reconciled with a
# never_registered proof; a legacy reservation still creating may be released with its proof.
function Complete-AapTeardown {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ReservationId,
        [Parameter(Mandatory)][long]$LeaseGeneration,
        [Parameter(Mandatory)][AllowNull()]$Proof,
        [int]$LockTimeoutSeconds = 30, [switch]$RelaxedTrustForTests)
    Invoke-AapLocked $Root ([bool]$RelaxedTrustForTests) $LockTimeoutSeconds {
        param($doc)
        $f = Find-AapReservation $doc $ReservationId $LeaseGeneration
        if ($f.ContainsKey('Result')) {
            $hit = @($doc.reservations | Where-Object { $_.reservation_id -ceq $ReservationId -and $_.state -ceq 'reconciled' -and [long]$_.lease_generation -eq $LeaseGeneration })
            if ($hit.Count) { return (New-AapResult 'unchanged' $null 'already reconciled') }
            if ($f.ContainsKey('Stale')) { Write-AapCapLog $Root "ignored late teardown: $($f.Result.Detail)" }
            return $f.Result
        }
        $r = $f.Reservation
        $p = ConvertTo-AapProof $Proof $r
        if ($p -is [string]) { return (New-AapResult 'refused' 'invalid_proof' $p) }
        $early = $r.state -ceq 'creating' -and ($r.backend -ceq 'wsl-legacy' -or ($null -eq $r.vm_id -and $p.runner_deregistered -is [string] -and $p.runner_deregistered -ceq 'never_registered'))
        if ($r.state -cne 'deleting' -and $r.state -cne 'quarantined' -and -not $early) {
            return (New-AapResult 'refused' 'illegal_edge' "a $($r.state) reservation is freed only from deleting or quarantined")
        }
        $now = Format-AapTime (Get-AapUtcNow)
        if ($r.state -ceq 'creating' -and $r.backend -ceq 'hyperv-vm') { Set-AapEdge $r 'reconciled' $now; $r.teardown_proof = $p; $r.cleanup_uncertain = $false }
        else { Move-AapDown $r $now $p }
        Save-AapDoc $Root $doc "$($r.reservation_id) slot $($r.slot) reconciled ($($p.kind), runner $($p.runner_deregistered))"
        New-AapResult 'ok' $null "slot $($r.slot) free" ([ordered]@{ Reservation = $r })
    }
}

# At supervisor start and every 10 minutes. Quarantines ready/busy after 90 s without a heartbeat
# (capacity held); destroys a heartbeat quarantine only when the broker reports its runner offline
# or absent and not busy, or the job ended (a busy runner is never destroyed, only flagged past
# the wall clock); joins the provider inventory with the reservations and repairs crashed
# transitions; quarantines unknown VMs in a free slot, otherwise blocks admission until resolved.
#   -Inventory     { @{ vms = @(@{ name; vm_id; cpus; mem_gib }); folders = @('r-...'); journaled = @('r-...') } }
#   -BrokerStatus  { param($Reservation) @{ status = 'online'|'offline'|'absent'; busy = $bool; job_ended = $bool } or $null }
# $null when Inv is one hashtable or object with the lists vms, folders and journaled.
function Test-AapInventory($Inv) {
    if ($null -eq $Inv -or $Inv -is [array] -or $Inv -is [string] -or $Inv -is [ValueType]) { return 'the callback did not return one hashtable or object' }
    $lists = @{}
    foreach ($k in @('vms', 'folders', 'journaled')) {
        if ($Inv -is [Collections.IDictionary]) {
            if (-not $Inv.Contains($k)) { return "no '$k' list" }
            $v = $Inv[$k]
        } else {
            $p = Get-AapProp $Inv $k
            if ($null -eq $p) { return "no '$k' list" }
            $v = $p.Value
        }
        if (-not ($v -is [Collections.IList])) { return "'$k' is not a list" }
        $lists[$k] = $v
    }
    # Every element, or a busy VM missing from a mangled list would count as gone.
    $i = 0
    foreach ($vm in $lists.vms) {
        if (-not ($vm -is [Collections.IDictionary] -or $vm -is [Management.Automation.PSCustomObject])) { return "vms[$i] is not a hashtable or object" }
        $n = Get-AapField $vm 'name'
        $id = Get-AapField $vm 'vm_id'
        if (-not ($n -is [string]) -or $n -cnotmatch '^aap-(w|l)-[1-5]-') { return "vms[$i] has no name aap-(w|l)-<slot>-..." }
        if (-not ($id -is [string]) -or $id -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z') { return "vms[$i] has no lower-case vm_id GUID" }
        $i++
    }
    foreach ($k in @('folders', 'journaled')) {
        $i = 0
        foreach ($x in $lists[$k]) {
            if (-not ($x -is [string]) -or $x -cnotmatch '^r-[0-9a-f]{16}\z') { return "$k[$i] is not a reservation id" }
            $i++
        }
    }
    return $null
}

function Invoke-AapReconcile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root,
        [scriptblock]$Inventory = $null,
        [scriptblock]$BrokerStatus = $null,
        [ValidateRange(1, 72)][int]$LeaseWallClockHours = 6,
        [int]$LockTimeoutSeconds = 30, [switch]$RelaxedTrustForTests)
    Invoke-AapLocked $Root ([bool]$RelaxedTrustForTests) $LockTimeoutSeconds {
        param($doc)
        $nowDt = Get-AapUtcNow
        $now = Format-AapTime $nowDt
        $before = ConvertTo-AapJson $doc
        $changes = New-Object System.Collections.Generic.List[string]
        $actions = New-Object System.Collections.Generic.List[object]
        $flags = New-Object System.Collections.Generic.List[string]
        $unresolved = New-Object System.Collections.Generic.List[object]
        $broker = @{}
        # The inventory first: a partial or malformed one would free running slots, so it changes nothing.
        $inv = $null
        if ($Inventory) {
            $inv = & $Inventory
            $bad = Test-AapInventory $inv
            if ($bad) { return (New-AapResult 'error' 'invalid_inventory' "inventory refused, nothing changed: $bad") }
            $prior = Read-AapUnresolved $Root
            if ($prior.ContainsKey('Error')) { return $prior.Error }
        }
        $tmp = Join-Path $Root 'allocator.json.tmp'
        if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp); $changes.Add('removed a temp file left by an interrupted write') }
        # 1. Missed heartbeats: capacity held, never freed.
        foreach ($r in @(Get-AapLive $doc | Where-Object { $_.state -ceq 'ready' -or $_.state -ceq 'busy' })) {
            if ($null -eq $r.heartbeat_at -or ($nowDt - (ConvertFrom-AapTime $r.heartbeat_at)).TotalSeconds -ge $script:MissedSeconds) {
                $was = $r.state
                Set-AapEdge $r 'quarantined' $now
                $r.quarantine_kind = 'heartbeat'
                $r.quarantine_reason = "3 heartbeats missed (last $($r.heartbeat_at)); capacity held"
                $r.cleanup_uncertain = $true
                $changes.Add("$($r.reservation_id) slot $($r.slot) $was->quarantined (heartbeat)")
            }
        }
        # 2. Heartbeat quarantines of VMs: destroy only per the broker's read-only status.
        foreach ($r in @(Get-AapLive $doc | Where-Object { $_.state -ceq 'quarantined' -and $_.quarantine_kind -ceq 'heartbeat' -and $_.backend -ceq 'hyperv-vm' })) {
            $s = $null
            if ($BrokerStatus) { try { $s = & $BrokerStatus $r } catch { $s = $null } }
            $status = Get-AapField $s 'status'
            $busy = Get-AapField $s 'busy'
            $ended = Get-AapField $s 'job_ended'
            $broker[$r.reservation_id] = 'unknown'
            if ($null -ne $s) { $broker[$r.reservation_id] = ConvertTo-AapLine "$status, busy $busy" }
            if ($null -ne $s -and (($ended -is [bool] -and $ended) -or ($status -is [string] -and ($status -ceq 'offline' -or $status -ceq 'absent') -and $busy -is [bool] -and -not $busy))) {
                Move-AapDown $r $now $null
                $changes.Add("$($r.reservation_id) slot $($r.slot) quarantined->deleting (runner $status, busy $busy, job ended $ended)")
                $actions.Add([pscustomobject][ordered]@{ action = 'destroy'; reservation_id = $r.reservation_id; lease_generation = [long]$r.lease_generation; vm_name = (Get-AapVmNameOf $r); vm_id = $r.vm_id })
            }
        }
        # 2b. A hostile quarantine is left only by a crash between Set-AapSlotState's two writes:
        # hostile is immediate and final, so finish it, with one destroy.
        foreach ($r in @(Get-AapLive $doc | Where-Object { $_.state -ceq 'quarantined' -and $_.quarantine_kind -ceq 'hostile_guest' -and $_.backend -ceq 'hyperv-vm' })) {
            Move-AapDown $r $now $null
            $r.cleanup_uncertain = $true
            $changes.Add("$($r.reservation_id) slot $($r.slot) quarantined->deleting (hostile_guest, finished after an interrupted write)")
            $actions.Add([pscustomobject][ordered]@{ action = 'destroy'; reservation_id = $r.reservation_id; lease_generation = [long]$r.lease_generation; vm_name = (Get-AapVmNameOf $r); vm_id = $r.vm_id })
        }
        # 3. Inventory join (VMs named aap-(w|l)-<slot>-..., clones\ and scratch\ folders, journals).
        if ($Inventory) {
            $vms = @(Get-AapField $inv 'vms' | Where-Object { $null -ne $_ })
            $folders = @(Get-AapField $inv 'folders' | Where-Object { $_ })
            $journaled = @(Get-AapField $inv 'journaled' | Where-Object { $_ })
            $matched = New-Object System.Collections.Generic.List[object]
            foreach ($r in @(Get-AapLive $doc | Where-Object { $_.backend -ceq 'hyperv-vm' })) {
                $name = Get-AapVmNameOf $r
                $vm = @($vms | Where-Object { ($null -ne $r.vm_id -and (Get-AapField $_ 'vm_id') -ceq $r.vm_id) -or ($null -eq $r.vm_id -and (Get-AapField $_ 'name') -ceq $name) }) | Select-Object -First 1
                if ($null -ne $vm) { $matched.Add($vm) }
                if ($r.state -ceq 'creating') {
                    if ($null -eq $vm -and $folders -cnotcontains $r.reservation_id -and $journaled -cnotcontains $r.reservation_id -and $null -eq $r.vm_id) {
                        Set-AapEdge $r 'reconciled' $now
                        $r.teardown_proof = [pscustomobject][ordered]@{ kind = 'vm'; observed_at = $now; vm_absent = $true; disks_absent = $true; vm_files_absent = $true; runner_deregistered = 'never_registered' }
                        $changes.Add("$($r.reservation_id) slot $($r.slot) creating->reconciled (no VM, folder or journal: never registered)")
                    } else {
                        $actions.Add([pscustomobject][ordered]@{ action = 'replay'; reservation_id = $r.reservation_id; lease_generation = [long]$r.lease_generation; vm_name = $name; vm_id = $r.vm_id })
                    }
                } elseif ($null -ne $vm -and $r.state -ceq 'quarantined' -and $r.quarantine_kind -ceq 'unknown_vm' -and $journaled -ccontains $r.reservation_id) {
                    Move-AapDown $r $now $null
                    $changes.Add("$($r.reservation_id) slot $($r.slot) quarantined->deleting (unknown VM named by a journal entry)")
                    $actions.Add([pscustomobject][ordered]@{ action = 'destroy'; reservation_id = $r.reservation_id; lease_generation = [long]$r.lease_generation; vm_name = (Get-AapField $vm 'name'); vm_id = $r.vm_id })
                } elseif ($null -eq $vm -and $r.state -cne 'deleting') {
                    $was = $r.state
                    Move-AapDown $r $now $null
                    $changes.Add("$($r.reservation_id) slot $($r.slot) $was->deleting (its VM is gone)")
                    $actions.Add([pscustomobject][ordered]@{ action = 'destroy'; reservation_id = $r.reservation_id; lease_generation = [long]$r.lease_generation; vm_name = $name; vm_id = $r.vm_id })
                } elseif ($r.state -ceq 'deleting' -and @($actions | Where-Object { $_.reservation_id -ceq $r.reservation_id }).Count -eq 0) {
                    $actions.Add([pscustomobject][ordered]@{ action = 'destroy'; reservation_id = $r.reservation_id; lease_generation = [long]$r.lease_generation; vm_name = $name; vm_id = $r.vm_id })
                }
            }
            $liveIds = @(Get-AapLive $doc | ForEach-Object { $_.reservation_id })
            foreach ($fid in $folders) {
                if ($liveIds -cnotcontains $fid) { $unresolved.Add([pscustomobject][ordered]@{ kind = 'folder'; name = [string]$fid; reason = 'clone or scratch folder without a live reservation' }) }
            }
            foreach ($vm in $vms) {
                if ($matched.Contains($vm)) { continue }
                $name = ConvertTo-AapLine ([string](Get-AapField $vm 'name'))
                $vmId = Get-AapField $vm 'vm_id'
                $cpus = Get-AapField $vm 'cpus'
                $mem = Get-AapField $vm 'mem_gib'
                $profileName = $null
                if ($name -cmatch '^aap-w-[1-5]-') { $profileName = 'windows' } elseif ($name -cmatch '^aap-l-[1-5]-') { $profileName = 'linux' }
                $why = $null
                if (-not $profileName -or -not ($vmId -is [string]) -or $vmId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z' -or -not (Test-AapInt $cpus) -or $cpus -lt 1 -or -not (Test-AapInt $mem) -or $mem -lt 1) { $why = 'inventory entry is incomplete' }
                elseif (-not $doc.legacy_adopted) { $why = 'legacy pool not adopted yet' }
                elseif (-not $doc.profiles.$profileName.active_generation) { $why = "no active $profileName generation to record it under" }
                elseif (@(Get-AapLive $doc).Count -ge 5) { $why = 'no free slot' }
                if (-not $why) {
                    # Tried on a copy: the unknown VM's CPUs and memory must fit the pool too.
                    $copy = ConvertFrom-AapJson (ConvertTo-AapJson $doc)
                    $q = Add-AapReservation $copy @{ Profile = $profileName; Backend = 'hyperv-vm'; Generation = $doc.profiles.$profileName.active_generation; State = 'quarantined'; Cpus = [long]$cpus; MemGib = [long]$mem; OverheadMib = 0; CloneGib = 1; ScratchGib = 0; IoMbps = 0 } $now
                    $q.vm_id = $vmId
                    $q.quarantine_kind = 'unknown_vm'
                    $q.quarantine_reason = "unknown VM $name; never adopted, deleted only with a journal entry naming it"
                    $q.cleanup_uncertain = $true
                    $e = Test-AapDoc (ConvertFrom-AapJson (ConvertTo-AapJson $copy))
                    if ($e) { $why = "it does not fit: $e" }
                    else {
                        $doc = $copy
                        $changes.Add("unknown VM $name quarantined in slot $($q.slot) as $($q.reservation_id)")
                    }
                }
                if ($why) { $unresolved.Add([pscustomobject][ordered]@{ kind = 'vm'; name = $name; reason = $why }) }
            }
            $u = [pscustomobject][ordered]@{ schema = 1; written_at = $now; items = $unresolved.ToArray() }
            if ((ConvertTo-AapJson @($prior.Items)) -cne (ConvertTo-AapJson $unresolved.ToArray()) -or -not [IO.File]::Exists((Join-Path $Root 'unresolved.json'))) {
                Write-AapAtomic $Root 'unresolved.json' (ConvertTo-AapJson $u)
                Write-AapCapLog $Root "unresolved: $(@($unresolved | ForEach-Object { "$($_.kind) $($_.name): $($_.reason)" }) -join '; ')"
            }
        }
        # 4. Every live VM past the per-lease wall clock is flagged for the owner, never destroyed for it.
        $destroying = @($actions | Where-Object { $_.action -ceq 'destroy' } | ForEach-Object { $_.reservation_id })
        foreach ($r in @(Get-AapLive $doc | Where-Object { $_.backend -ceq 'hyperv-vm' -and $destroying -cnotcontains $_.reservation_id })) {
            if (($nowDt - (ConvertFrom-AapTime $r.acquired_at)).TotalHours -ge $LeaseWallClockHours) {
                $gh = 'status not read'
                if ($broker.ContainsKey($r.reservation_id)) { $gh = $broker[$r.reservation_id] }
                $flags.Add("slot $($r.slot) ($($r.reservation_id)) is past the $LeaseWallClockHours h lease wall clock in state $($r.state); GitHub reports its runner $gh; held, never destroyed for the wall clock")
            }
        }
        $data = [ordered]@{ Changes = $changes.ToArray(); Actions = $actions.ToArray(); Flags = $flags.ToArray(); Unresolved = $unresolved.ToArray() }
        if ((ConvertTo-AapJson $doc) -ceq $before) {
            if ($changes.Count) { return (New-AapResult 'ok' $null ($changes -join '; ') $data) }
            return (New-AapResult 'unchanged' $null 'nothing to repair' $data)
        }
        Save-AapDoc $Root $doc "reconcile: $($changes -join '; ')"
        New-AapResult 'ok' $null ($changes -join '; ') $data
    }
}

Export-ModuleMember -Function Get-AapVmName, Test-AapAllocatorState, Initialize-AapAllocator, Get-AapAllocatorState,
Set-AapHostMeasurement, Set-AapProfileCounts, Request-AapReservation, Register-AapLegacySlots, Get-AapLegacyLimits,
Update-AapHeartbeat, Set-AapSlotState, Complete-AapTeardown, Invoke-AapReconcile
