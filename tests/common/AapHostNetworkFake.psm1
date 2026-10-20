# Shared strict fake of the P10.0 host network module (parity/contracts/host-network-module.md) for the Pester suites of
# its consumers: the image builders (P06, P07) and the VM backends (P10, P11). Windows PowerShell 5.1 and PowerShell 7.
# New-AapFakeHostNetwork returns the module's interface (Attach, Detach, Verify) with the contract's semantics; the
# consumer's own provider fake reports the VM's adapter through Get-AapFakeHostNetworkAdapter, as Hyper-V would. State lives
# only under -Root, so a child process killed mid-step leaves the world its parent then recovers from:
#   records\<vm id>.json  the module's journal (host_network_record), written before anything is attached
#   knobs.json            tampers (changes to the simulated host, seen by Verify and the read-back alike) and faults
# The simulated adapter is derived from an attached record, never stored. Nothing here calls Hyper-V or the network.
# Lines tagged '# check:<name>' are the checks Invoke-AapHostNetworkFakeMutations.ps1 disables one at a time.

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# The fake host (contract, Shared fake): one internal switch per profile; gateway, DHCP and DNS at .1.
$script:Net = @{
    windows = @{ Switch = 'aap-guests-win'; Subnet = '172.31.250.0/24'; Gateway = '172.31.250.1' }
    linux = @{ Switch = 'aap-guests-linux'; Subnet = '172.31.251.0/24'; Gateway = '172.31.251.1' }
}
$script:HostAddresses = @('172.31.250.1', '172.31.251.1', '172.29.16.1', '2001:db8:5::1')   # the vEthernet adapters'
$script:LanPrefixes = @('2001:db8:1::/64')
$script:FixedDeny = @('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16', '100.64.0.0/10', '224.0.0.0/4', 'ff00::/8', 'fe80::/10', 'fc00::/7')
$script:DenyWeight = 10
$script:AllowWeight = 100
$script:GuidRe = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z'
$script:NameRe = '^aap-([wl]-[1-5]-[0-9]{1,9}-[0-9a-f]{8}|[wl]build-[0-9a-f]{8})\z'
$script:TamperNames = @('no-adapter', 'second-adapter', 'external-switch', 'other-switch', 'dhcp-guard-off', 'router-guard-off',
    'mac-spoofing-on', 'drop-fixed-deny', 'drop-host-deny', 'extra-allow', 'allow-weight')
$script:FailNames = @('Attach', 'AttachAfterIntent', 'Detach', 'Verify')
$script:Utf8 = New-Object Text.UTF8Encoding($false)

function New-AapFakeHostNetwork {
    <# The module's interface on the fake host. -VmExists answers whether Hyper-V has the VM id it is given: the consumer's
       own fake world owns the VMs. #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][scriptblock]$VmExists)
    [void][IO.Directory]::CreateDirectory((Join-Path $Root 'records'))
    # The closures call an exported function: a closure made here no longer sees this module's private ones.
    @{
        Attach = { param($a) Invoke-AapFakeHostNetwork -Root $Root -VmExists $VmExists -Op Attach -Request $a }.GetNewClosure()
        Detach = { param($a) Invoke-AapFakeHostNetwork -Root $Root -VmExists $VmExists -Op Detach -Request $a }.GetNewClosure()
        Verify = { param($a) Invoke-AapFakeHostNetwork -Root $Root -VmExists $VmExists -Op Verify -Request $a }.GetNewClosure()
    }
}

function Invoke-AapFakeHostNetwork {
    # One call of the interface; exported only for New-AapFakeHostNetwork's closures.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][scriptblock]$VmExists,
        [Parameter(Mandatory)][ValidateSet('Attach', 'Detach', 'Verify')][string]$Op, $Request)
    $q = ConvertTo-AapFakeNetRequest $Request
    $fail = @((Read-AapFakeNetKnobs $Root).fail)
    if ($fail -ccontains $Op) { throw "AAP_NetworkUntrusted: fake: $Op failed" }
    $exists = [bool](& $VmExists $q.VmId)
    switch ($Op) {
        'Attach' { Add-AapFakeNetAttachment $Root $q $exists ($fail -ccontains 'AttachAfterIntent') }
        'Detach' { Remove-AapFakeNetAttachment $Root $q $exists }
        'Verify' { Get-AapFakeNetProblem $Root $q $exists }
    }
}

function Get-AapFakeHostNetworkAdapter {
    <# What Hyper-V would report for the VM's adapters, in the contract's provider shape (Consumer obligations, read-back):
       nothing before Attach finishes or after Detach, one adapter while attached, tampers applied. #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$VmId)
    $rec = Read-AapFakeNetRecord $Root $VmId
    if ($null -eq $rec -or $rec.state -cne 'attached') { return }
    $d = $rec.declaration
    $prof = [string]$d.profile
    $tamper = @((Read-AapFakeNetKnobs $Root).tamper)
    $count = $(if ($tamper -ccontains 'no-adapter') { 0 } elseif ($tamper -ccontains 'second-adapter') { 2 } else { 1 })
    for ($i = 0; $i -lt $count; $i++) {
        $acls = @(@($script:FixedDeny) + @(Get-AapFakeNetHostTarget $d) | ForEach-Object { New-AapFakeNetRule 'Deny' $_ $script:DenyWeight })
        $acls += @($d.endpoints | ForEach-Object { [string]$_.address } | Sort-Object -Unique | ForEach-Object { New-AapFakeNetRule 'Allow' $_ $script:AllowWeight })
        $n = @{ SwitchName = $script:Net[$prof].Switch; SwitchType = 'Internal'; DhcpGuard = $true; RouterGuard = $true; MacAddressSpoofing = $false; Acls = $acls }
        switch -CaseSensitive ($tamper) {
            'external-switch' { $n.SwitchType = 'External' }
            'other-switch' { $n.SwitchName = $script:Net[$(if ($prof -ceq 'windows') { 'linux' } else { 'windows' })].Switch }
            'dhcp-guard-off' { $n.DhcpGuard = $false }
            'router-guard-off' { $n.RouterGuard = $false }
            'mac-spoofing-on' { $n.MacAddressSpoofing = $true }
            'drop-fixed-deny' { $n.Acls = @($n.Acls | Where-Object { $_.RemoteAddress -cne '10.0.0.0/8' }) }
            'drop-host-deny' { $n.Acls = @($n.Acls | Where-Object { $_.RemoteAddress -cne $script:LanPrefixes[0] }) }
            'extra-allow' { $n.Acls = @($n.Acls) + @(New-AapFakeNetRule 'Allow' '192.168.1.1' $script:AllowWeight) }
            'allow-weight' { foreach ($r in $n.Acls) { if ($r.Action -ceq 'Allow') { $r.Weight = $script:DenyWeight } } }
        }
        $n
    }
}

function Set-AapFakeHostNetworkKnob {
    <# Tampers change the simulated host, so Verify and the read-back both see them; faults make an op throw
       (AttachAfterIntent: Attach stops after its intent record, as a crash would). Each call replaces both lists. #>
    param([Parameter(Mandatory)][string]$Root, [string[]]$Tamper = @(), [string[]]$Fail = @())
    $unknown = @(@($Tamper | Where-Object { $script:TamperNames -cnotcontains $_ }) + @($Fail | Where-Object { $script:FailNames -cnotcontains $_ }))
    if ($unknown.Count) { throw "fake: unknown tamper or fault: $($unknown -join ', ')" }   # check:knob-names
    [IO.File]::WriteAllText((Join-Path $Root 'knobs.json'), (@{ tamper = @($Tamper); fail = @($Fail) } | ConvertTo-Json), $script:Utf8)
}

function Get-AapFakeHostNetworkRecord {
    # The journal records under -Root (with -VmId, that VM's only), as the module keeps them.
    param([Parameter(Mandatory)][string]$Root, [string]$VmId)
    $ids = $(if ($VmId) { @($VmId) } else { @(Get-ChildItem -LiteralPath (Join-Path $Root 'records') -Filter '*.json' -File | ForEach-Object { $_.BaseName }) })
    foreach ($id in $ids) { $r = Read-AapFakeNetRecord $Root $id; if ($null -ne $r) { $r } }
}

# ---- the three operations -----------------------------------------------------------------------------------------------

function ConvertTo-AapFakeNetRequest($Request) {
    $ok = $Request -is [Collections.IDictionary] -and $Request.Count -eq 3 -and $Request.Contains('VmId') -and $Request.Contains('VmName') -and $Request.Contains('Profile')
    if ($ok) {
        $id = [string]$Request['VmId']; $name = [string]$Request['VmName']; $prof = [string]$Request['Profile']
        $ok = $id -cmatch $script:GuidRe -and $name -cmatch $script:NameRe -and @('windows', 'linux') -ccontains $prof -and $name[4] -ceq $prof[0]
    }
    if (-not $ok) { throw 'AAP_NetworkUntrusted: the request is not exactly @{ VmId; VmName; Profile } for an attachable VM' }   # check:request
    @{ VmId = $id; VmName = $name; Profile = $prof }
}

function Add-AapFakeNetAttachment([string]$Root, $q, [bool]$Exists, [bool]$StopAfterIntent) {
    if (-not $Exists) { throw "AAP_NetworkUntrusted: VM $($q.VmId) does not exist" }   # check:attach-vm
    $rec = Read-AapFakeNetRecord $Root $q.VmId
    if ($null -ne $rec -and ($rec.declaration.vm_name -cne $q.VmName -or $rec.declaration.profile -cne $q.Profile)) {   # check:attach-same-vm
        throw "AAP_NetworkUntrusted: VM $($q.VmId) is recorded as $($rec.declaration.vm_name) ($($rec.declaration.profile))"
    }
    if ($null -eq $rec) {
        # Intent before act: the record names the declaration and what Attach creates before anything changes.
        $n = $script:Net[$q.Profile]
        $decl = [ordered]@{ schema = 1; kind = 'host_network_attach'; vm_id = $q.VmId; vm_name = $q.VmName; profile = $q.Profile; subnet = $n.Subnet
            endpoints = @(foreach ($role in 'gateway', 'dhcp', 'dns') { [ordered]@{ role = $role; address = $n.Gateway } })
        }
        Write-AapFakeNetRecord $Root ([ordered]@{ schema = 1; kind = 'host_network_record'; state = 'attaching'; declaration = $decl; created = @([ordered]@{ kind = 'adapter'; name = 'aap-guest' }) })
        $rec = Read-AapFakeNetRecord $Root $q.VmId
    }
    if ($StopAfterIntent) { throw 'AAP_NetworkUntrusted: fake: Attach stopped after its intent record' }
    # From here the adapter, its guards and its port ACLs exist: the simulated host derives them from the attached record.
    if ($rec.state -cne 'attached') { $rec.state = 'attached'; Write-AapFakeNetRecord $Root $rec }
    $rec.declaration
}

function Remove-AapFakeNetAttachment([string]$Root, $q, [bool]$Exists) {
    if ($Exists) { throw "AAP_NetworkUntrusted: VM $($q.VmId) still exists; remove the VM before Detach" }   # check:detach-order
    $rec = Read-AapFakeNetRecord $Root $q.VmId
    if ($null -eq $rec) { return }   # never attached, or detached already
    if ($rec.declaration.vm_name -cne $q.VmName -or $rec.declaration.profile -cne $q.Profile) {   # check:detach-same-vm
        throw "AAP_NetworkUntrusted: VM $($q.VmId) is recorded as $($rec.declaration.vm_name) ($($rec.declaration.profile))"
    }
    # The adapter and its port ACLs went with the VM and the per-profile switch is not the VM's: only the record is left.
    $path = Get-AapFakeNetRecordPath $Root $q.VmId
    if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }   # check:detach-removes
}

# Verify (contract checks 1 to 6), from the record, the simulated adapter and the fake host; never from a knob directly.
function Get-AapFakeNetProblem([string]$Root, $q, [bool]$Exists) {
    $id = $q.VmId
    if (-not $Exists) { return "VM $id does not exist" }   # check:verify-vm
    $rec = Read-AapFakeNetRecord $Root $id
    if ($null -eq $rec -or $rec.state -cne 'attached') { return "VM $id is not attached" }   # check:verify-record
    $d = $rec.declaration
    if ($d.vm_name -cne $q.VmName -or $d.profile -cne $q.Profile) { return "VM $id is recorded as $($d.vm_name) ($($d.profile))" }   # check:verify-record
    $nics = @(Get-AapFakeHostNetworkAdapter -Root $Root -VmId $id)
    if ($nics.Count -ne 1) { return "VM $id has $($nics.Count) network adapters, not 1" }   # check:verify-adapter
    $n = $nics[0]
    $p = New-Object Collections.Generic.List[string]
    $sw = $script:Net[[string]$d.profile].Switch
    if ($n.SwitchName -cne $sw -or $n.SwitchType -cne 'Internal') { $p.Add("the adapter is not on the internal switch $sw") }   # check:verify-switch
    if ($n.DhcpGuard -ne $true -or $n.RouterGuard -ne $true -or $n.MacAddressSpoofing -ne $false) { $p.Add('DHCP guard or router guard is off, or MAC address spoofing is on') }   # check:verify-guards
    $deny = @($n.Acls | Where-Object { $_.Action -ceq 'Deny' -and $_.Direction -ceq 'Outbound' -and $_.Scoped -eq $false })
    foreach ($r in $script:FixedDeny) { if (-not @($deny | Where-Object { $_.RemoteAddress -ceq $r }).Count) { $p.Add("no unscoped outbound deny for $r") } }   # check:verify-fixed
    foreach ($t in @(Get-AapFakeNetHostTarget $d)) { if (-not @($deny | Where-Object { Test-AapFakeNetCover $_.RemoteAddress $t }).Count) { $p.Add("no deny covers the host's $t") } }   # check:verify-host
    # An allow that is not outbound or names more than one address shows in brackets, so it never matches a declaration.
    $allow = @($n.Acls | Where-Object { $_.Action -ceq 'Allow' })
    $got = @($allow | ForEach-Object { $one = ConvertTo-AapFakeNetAddress $_.RemoteAddress; if ($_.Direction -cne 'Outbound' -or -not $one) { "($($_.RemoteAddress))" } else { $one } } | Sort-Object -Unique)
    $want = @($d.endpoints | ForEach-Object { [string]$_.address } | Sort-Object -Unique)
    if (($got -join ', ') -cne ($want -join ', ')) { $p.Add("allowed $($got -join ', '); declared $($want -join ', ')") }   # check:verify-allow
    $aw = @($allow | ForEach-Object { [int]$_.Weight })
    $dw = @($n.Acls | Where-Object { $_.Action -ceq 'Deny' } | ForEach-Object { [int]$_.Weight })
    if ($aw.Count -and $dw.Count -and ($aw | Measure-Object -Minimum).Minimum -le ($dw | Measure-Object -Maximum).Maximum) { $p.Add('an allow rule does not outrank every deny rule') }   # check:verify-weight
    $p.ToArray()
}

# ---- records, knobs and addresses ---------------------------------------------------------------------------------------

function Get-AapFakeNetRecordPath([string]$Root, [string]$VmId) { Join-Path $Root "records\$VmId.json" }

function Read-AapFakeNetRecord([string]$Root, [string]$VmId) {
    $path = Get-AapFakeNetRecordPath $Root $VmId
    if (-not [IO.File]::Exists($path)) { return $null }
    $ok = $false
    try {
        $rec = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        $ok = $rec.kind -ceq 'host_network_record' -and @('attaching', 'attached') -ccontains $rec.state -and $rec.declaration.vm_id -ceq $VmId
    } catch { $ok = $false }
    if (-not $ok) { throw "AAP_NetworkUntrusted: the record of VM $VmId is unreadable; it stays for an owner" }   # check:record-readable
    $rec
}

function Write-AapFakeNetRecord([string]$Root, $Record) {
    [IO.File]::WriteAllText((Get-AapFakeNetRecordPath $Root ([string]$Record.declaration.vm_id)), ($Record | ConvertTo-Json -Depth 6), $script:Utf8)
}

function Read-AapFakeNetKnobs([string]$Root) {
    $path = Join-Path $Root 'knobs.json'
    if (-not [IO.File]::Exists($path)) { return @{ tamper = @(); fail = @() } }
    $k = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    @{ tamper = @($k.tamper | Where-Object { $_ }); fail = @($k.fail | Where-Object { $_ }) }
}

function New-AapFakeNetRule([string]$Action, [string]$Remote, [int]$Weight) {
    @{ Action = $Action; Direction = 'Outbound'; RemoteAddress = $Remote; Scoped = $false; Weight = $Weight }
}

# What the host-specific denies must cover now (contract, Verify check 4): the host's vEthernet addresses that are not
# declared endpoints, the LAN IPv6 prefixes and the clone subnet. The fake writes exactly these as its host-specific denies.
function Get-AapFakeNetHostTarget($d) {
    $ends = @($d.endpoints | ForEach-Object { [string]$_.address })
    @($script:HostAddresses | Where-Object { $ends -notcontains $_ } | ForEach-Object { if ($_.Contains(':')) { "$_/128" } else { "$_/32" } }) + $script:LanPrefixes + @([string]$d.subnet)
}

# An address or prefix as its bytes and prefix length (an address alone is a /32 or /128); $null when it is neither.
function Split-AapFakeNetPrefix([string]$Text) {
    $parts = $Text.Split('/')
    $ip = $null
    $bits = 0
    if ($parts.Count -gt 2 -or -not [Net.IPAddress]::TryParse($parts[0], [ref]$ip)) { return $null }
    $bytes = $ip.GetAddressBytes()
    if ($parts.Count -eq 1) { $bits = $bytes.Length * 8 } elseif (-not [int]::TryParse($parts[1], [ref]$bits) -or $bits -lt 0 -or $bits -gt $bytes.Length * 8) { return $null }
    @{ Bytes = $bytes; Bits = $bits }
}

# Whether the deny's prefix contains the target address or prefix.
function Test-AapFakeNetCover([string]$Prefix, [string]$Target) {
    $p = Split-AapFakeNetPrefix $Prefix
    $t = Split-AapFakeNetPrefix $Target
    if ($null -eq $p -or $null -eq $t -or $p.Bytes.Length -ne $t.Bytes.Length -or $t.Bits -lt $p.Bits) { return $false }
    for ($i = 0; $i -lt $p.Bits; $i++) {
        $mask = 0x80 -shr ($i % 8)
        if (($p.Bytes[$i -shr 3] -band $mask) -ne ($t.Bytes[$i -shr 3] -band $mask)) { return $false }
    }
    $true
}

# The one address a rule names (alone, /32 or /128), normalized; $null for anything wider or unreadable.
function ConvertTo-AapFakeNetAddress([string]$Text) {
    $p = Split-AapFakeNetPrefix $Text
    if ($null -eq $p -or $p.Bits -ne $p.Bytes.Length * 8) { return $null }
    (New-Object Net.IPAddress (, $p.Bytes)).ToString()
}

Export-ModuleMember -Function New-AapFakeHostNetwork, Invoke-AapFakeHostNetwork, Get-AapFakeHostNetworkAdapter, Set-AapFakeHostNetworkKnob,
    Get-AapFakeHostNetworkRecord
