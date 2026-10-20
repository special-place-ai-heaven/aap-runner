# Shared check of the P10.0 host network module's work (parity/contracts/host-network-module.md, Shared check): the
# declaration Attach returns, and Hyper-V's read-back of a VM's adapters against it. Pure: no Hyper-V, file, registry or
# network call. Each check returns problem lines (printable, at most 200 characters, at most 64); none means it holds. The
# one implementation for every consumer: the image builders (P06, P07), the VM backends (P10, P11), the module's own Verify
# and the shared fake (tests/common/AapHostNetworkFake.psm1). Windows PowerShell 5.1 and PowerShell 7.
# Lines tagged '# check:<name>' are the checks tests/common/Invoke-AapHostNetworkMutations.ps1 disables one at a time.

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# guest-transport.md's fixed deny ranges in canonical text: the only copy. The module writes them, every read-back checks them.
$script:FixedDeny = @('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16', '100.64.0.0/10', '224.0.0.0/4', 'ff00::/8', 'fe80::/10', 'fc00::/7')
$script:Directions = @('Inbound', 'Outbound')   # an extended port ACL has no 'Both'
$script:AdapterKeys = @('SwitchName', 'SwitchType', 'DhcpGuard', 'RouterGuard', 'MacAddressSpoofing', 'PortMirroringMode', 'VlanMode', 'Peers', 'Acls')
$script:RuleKeys = @('Action', 'Direction', 'RemoteAddress', 'LocalAddress', 'Protocol', 'RemotePort', 'LocalPort', 'Weight')
$script:DeclarationKeys = @('schema', 'kind', 'vm_id', 'vm_name', 'profile', 'subnet', 'endpoints')
$script:GuidRe = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z'
$script:NameRe = '^aap-([wl])(-[1-5]-[0-9]{1,9}-|build-)[0-9a-f]{8}\z'

function Get-AapHostNetworkFixedDeny {
    # The ranges every guest adapter denies, inbound and outbound, unscoped.
    $script:FixedDeny
}

function Get-AapHostNetworkSwitchName {
    <# The switch a VM's one adapter belongs on (contract, Switches): a runner clone on its profile's guest switch, a build VM
       on its profile's build switch; '' for any other name (verification and scanner VMs have no adapter). #>
    param([AllowNull()][AllowEmptyString()][string]$VmName)
    if ($VmName -cmatch $script:NameRe) {
        $p = $(if ($Matches[1] -ceq 'w') { 'win' } else { 'linux' })
        $(if ($Matches[2] -ceq 'build-') { "aap-build-$p" } else { "aap-guests-$p" })
    } else { '' }
}

function Get-AapHostNetworkDeclarationProblems {
    <# Attach's return value against the request it answered (contract, Declaration check). Any line: AAP_NetworkInvalid. #>
    param([Parameter(Mandatory)][AllowNull()]$Request, [Parameter(Mandatory)][AllowNull()]$Declaration)
    @(Get-AapNetDeclarationProblem $Request $Declaration) | Select-Object -First 64
}

function Get-AapHostNetworkAdapterProblems {
    <# Hyper-V's read-back of a VM's adapters (the provider shape, contract Read-back) against the declaration Attach returned.
       HostDeny: addresses and prefixes the module's host-specific denies must cover; only the module knows the host, so its
       Verify passes them and consumers do not. Any line: AAP_NetworkUntrusted. #>
    param([Parameter(Mandatory)][AllowNull()]$Declaration, [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Adapters,
        [string[]]$HostDeny = @())
    @(Get-AapNetAdapterProblem $Declaration $Adapters $HostDeny) | Select-Object -First 64
}

# ---- the declaration -----------------------------------------------------------------------------------------------------

function Get-AapNetDeclarationProblem($Request, $d) {
    if ((@(Get-AapNetNames $d | Sort-Object) -join ',') -cne (@($script:DeclarationKeys | Sort-Object) -join ',')) { return "the declaration's keys are not exactly $($script:DeclarationKeys -join ', ')" }   # check:decl-keys
    $schema = Get-AapNetField $d 'schema'
    if (-not (Test-AapNetInt $schema) -or $schema -ne 1 -or [string](Get-AapNetField $d 'kind') -cne 'host_network_attach') { return 'the declaration is not a host_network_attach of schema 1' }   # check:decl-keys
    $p = New-Object Collections.Generic.List[string]
    $id = [string](Get-AapNetField $d 'vm_id'); $name = [string](Get-AapNetField $d 'vm_name'); $prof = [string](Get-AapNetField $d 'profile')
    if ($id -cne [string](Get-AapNetField $Request 'VmId') -or $name -cne [string](Get-AapNetField $Request 'VmName') -or $prof -cne [string](Get-AapNetField $Request 'Profile')) {   # check:decl-echo
        $p.Add("the declaration is for $(Format-AapNetText $name) ($(Format-AapNetText $prof), $(Format-AapNetText $id)), not the VM Attach was asked for")
    }
    $sw = Get-AapHostNetworkSwitchName $name
    if ($id -cnotmatch $script:GuidRe -or -not (($prof -ceq 'windows' -and $sw -cmatch '-win\z') -or ($prof -ceq 'linux' -and $sw -cmatch '-linux\z'))) {   # check:decl-vm
        $p.Add("the declaration's VM $(Format-AapNetText $name) ($(Format-AapNetText $prof), $(Format-AapNetText $id)) is not a runner clone or build VM of that profile")
    }
    $net = Split-AapNetPrefix ([string](Get-AapNetField $d 'subnet'))
    if ($null -eq $net -or $net.Width -ne 32 -or $net.Bits -lt 16 -or $net.Bits -gt 30) { $p.Add("the subnet $(Format-AapNetText (Get-AapNetField $d 'subnet')) is not an IPv4 network of /16 to /30"); return $p.ToArray() }   # check:decl-subnet
    $ends = @(Get-AapNetField $d 'endpoints')
    if ($ends.Count -lt 1 -or $ends.Count -gt 4) { $p.Add("the declaration has $($ends.Count) endpoints, not 1 to 4") }   # check:decl-endpoints
    $roles = @($ends | ForEach-Object { [string](Get-AapNetField $_ 'role') })
    if (@($roles -ceq 'gateway').Count -ne 1 -or @($roles -ceq 'dhcp').Count -gt 1 -or @($roles -ceq 'dns').Count -gt 2) { $p.Add('the endpoints are not one gateway, at most one dhcp and at most two dns') }   # check:decl-roles
    $seen = New-Object Collections.Generic.List[string]
    foreach ($e in $ends) {
        $role = [string](Get-AapNetField $e 'role')
        $extra = @(Get-AapNetNames $e | Where-Object { @('role', 'address', 'port') -cnotcontains $_ })
        if ($extra.Count -or @('gateway', 'dhcp', 'dns') -cnotcontains $role -or -not (Test-AapNetField $e 'address')) { $p.Add("an endpoint ($(Format-AapNetText $role)) is not exactly role gateway, dhcp or dns, address and an optional port"); continue }   # check:decl-endpoint
        $text = [string](Get-AapNetField $e 'address')
        $ip = Split-AapNetPrefix $text
        if ($null -eq $ip -or $ip.Width -ne 32 -or $text -cne $ip.Address -or -not (Test-AapNetHost $net $ip)) { $p.Add("the $role endpoint $(Format-AapNetText $text) is not a host address of $($net.Text)"); continue }   # check:decl-address
        $port = Get-AapNetField $e 'port'
        if ((Test-AapNetField $e 'port') -and -not ((Test-AapNetInt $port) -and $port -ge 1 -and $port -le 65535)) { $p.Add("the $role endpoint $text has a port that is not 1 to 65535"); continue }   # check:decl-port
        $key = "$role $text $port"
        if ($seen -ccontains $key) { $p.Add("the $role endpoint $text is declared twice") }   # check:decl-endpoints
        $seen.Add($key)
    }
    $p.ToArray()
}

# ---- the read-back -------------------------------------------------------------------------------------------------------

function Get-AapNetAdapterProblem($d, $Adapters, [string[]]$HostDeny) {
    $echo = @{ VmId = (Get-AapNetField $d 'vm_id'); VmName = (Get-AapNetField $d 'vm_name'); Profile = (Get-AapNetField $d 'profile') }
    $bad = @(Get-AapNetDeclarationProblem $echo $d)
    if ($bad.Count) { return @($bad | ForEach-Object { "declaration: $_" }) }   # check:adapter-declaration
    if ($null -eq $Adapters) { $Adapters = @() }
    if ($Adapters.Count -ne 1) { return "the VM has $($Adapters.Count) network adapters, not 1" }   # check:adapter-count
    $n = $Adapters[0]
    $missing = @($script:AdapterKeys | Where-Object { -not (Test-AapNetField $n $_) })
    if ($missing.Count) { return "the adapter read-back lacks $($missing -join ', ')" }   # check:adapter-keys
    $v = @{}
    foreach ($k in 'SwitchName', 'SwitchType', 'DhcpGuard', 'RouterGuard', 'MacAddressSpoofing', 'PortMirroringMode', 'VlanMode') { $v[$k] = Format-AapNetText (Get-AapNetField $n $k) }
    $p = New-Object Collections.Generic.List[string]
    $sw = Get-AapHostNetworkSwitchName ([string](Get-AapNetField $d 'vm_name'))
    if ([string](Get-AapNetField $n 'SwitchName') -cne $sw -or [string](Get-AapNetField $n 'SwitchType') -cne 'Internal') { $p.Add("the adapter is on '$($v.SwitchName)' ($($v.SwitchType)), not on the internal switch $sw") }   # check:switch
    if ([string](Get-AapNetField $n 'DhcpGuard') -cne 'On') { $p.Add("DHCP guard is '$($v.DhcpGuard)', not On") }   # check:dhcp-guard
    if ([string](Get-AapNetField $n 'RouterGuard') -cne 'On') { $p.Add("router guard is '$($v.RouterGuard)', not On") }   # check:router-guard
    if ([string](Get-AapNetField $n 'MacAddressSpoofing') -cne 'Off') { $p.Add("MAC address spoofing is '$($v.MacAddressSpoofing)', not Off") }   # check:mac-spoofing
    if ([string](Get-AapNetField $n 'PortMirroringMode') -cne 'None') { $p.Add("port mirroring is '$($v.PortMirroringMode)', not None") }   # check:mirroring
    if (@('Untagged', 'Access') -cnotcontains [string](Get-AapNetField $n 'VlanMode')) { $p.Add("the VLAN mode is '$($v.VlanMode)', not Untagged or Access") }   # check:vlan
    # The switch's other VMs: none beside a build VM; beside a runner clone, only runner clones of its profile (contract, Switches).
    $build = $sw -clike 'aap-build-*'
    $odd = @(@(Get-AapNetField $n 'Peers') | Where-Object { $build -or (Get-AapHostNetworkSwitchName ([string]$_)) -cne $sw } | ForEach-Object { [string]$_ })
    if ($odd.Count) { $p.Add("$(if ($build) { 'the build VM' } else { 'the runner clone' }) shares $sw with $(Format-AapNetText ($odd -join ', ') 80)$(if (-not $build) { ', not only runner clones of its profile' })") }   # check:peers

    $rules = New-Object Collections.Generic.List[object]
    $i = 0
    foreach ($r in @(Get-AapNetField $n 'Acls')) {
        $i++
        $missing = @($script:RuleKeys | Where-Object { -not (Test-AapNetField $r $_) })
        if ($missing.Count) { $p.Add("rule $i lacks $($missing -join ', ')"); continue }   # check:rule-keys
        $act = [string](Get-AapNetField $r 'Action'); $dir = [string](Get-AapNetField $r 'Direction')
        if (@('Allow', 'Deny') -cnotcontains $act -or $script:Directions -cnotcontains $dir) { $p.Add("rule $i is '$(Format-AapNetText $act)' '$(Format-AapNetText $dir)', not Allow or Deny, Inbound or Outbound"); continue }   # check:rule-kind
        $w = Get-AapNetField $r 'Weight'
        if (-not (Test-AapNetInt $w) -or $w -lt [int]::MinValue -or $w -gt [int]::MaxValue) { $p.Add("rule $i has no Int32 weight"); continue }   # check:rule-weight
        $remote = Split-AapNetPrefix ([string](Get-AapNetField $r 'RemoteAddress'))
        if ($null -eq $remote) { $p.Add("rule $i's remote address '$(Format-AapNetText (Get-AapNetField $r 'RemoteAddress'))' is not an address or a prefix"); continue }   # check:rule-remote
        # What narrows the rule below its remote address: a deny narrowed by anything does not deny the range.
        $scope = New-Object Collections.Generic.List[string]
        if (-not (Test-AapNetAnyAddress ([string](Get-AapNetField $r 'LocalAddress')) $remote.Width)) { $scope.Add('local address') }   # check:scope-local-address
        if (-not (Test-AapNetAny ([string](Get-AapNetField $r 'Protocol')))) { $scope.Add('protocol') }   # check:scope-protocol
        if (-not (Test-AapNetAny ([string](Get-AapNetField $r 'LocalPort')))) { $scope.Add('local port') }   # check:scope-local-port
        if (-not (Test-AapNetAny ([string](Get-AapNetField $r 'RemotePort')))) { $scope.Add('remote port') }   # check:scope-remote-port
        $rules.Add([pscustomobject]@{ N = $i; Action = $act; Direction = $dir; Remote = $remote; Weight = [long]$w; Scope = $scope.ToArray()
                Protocol = (ConvertTo-AapNetProtocol ([string](Get-AapNetField $r 'Protocol'))); RemotePort = ([string](Get-AapNetField $r 'RemotePort')).Trim() })
    }

    # Rule (i): every fixed range denied in both directions, unscoped; the host-specific targets covered the same way.
    foreach ($range in $script:FixedDeny) {
        foreach ($dir in $script:Directions) {
            if (-not @($rules | Where-Object { $_.Remote.Text -ceq $range -and (Test-AapNetFullDeny $_ $dir) }).Count) { $p.Add("no unscoped $dir deny for $range") }   # check:fixed-deny
        }
    }
    foreach ($t in @($HostDeny)) {
        $tp = Split-AapNetPrefix $t
        if ($null -eq $tp) { $p.Add("the host-specific target '$(Format-AapNetText $t)' is not an address or a prefix"); continue }   # check:host-deny
        foreach ($dir in $script:Directions) {
            if (-not @($rules | Where-Object { (Test-AapNetFullDeny $_ $dir) -and (Test-AapNetCover $_.Remote $tp) }).Count) { $p.Add("no unscoped $dir deny covers the host's $($tp.Text)") }   # check:host-deny
        }
    }

    # Rule (ii): every allow is exactly a declared endpoint and outweighs every deny of its direction that covers it; every
    # endpoint has an allow in both directions.
    $ends = @(Get-AapNetField $d 'endpoints' | ForEach-Object { ConvertTo-AapNetEndpoint $_ })
    foreach ($dir in $script:Directions) {
        $allows = @($rules | Where-Object { $_.Action -ceq 'Allow' -and $_.Direction -ceq $dir })
        foreach ($a in $allows) {
            $what = "rule $($a.N): the $dir allow $($a.Remote.Text)"
            if (-not @($ends | Where-Object { Test-AapNetEndpointRule $a $_ }).Count) { $p.Add("$what$(if ($a.Scope.Count) { " [$($a.Scope -join ', ')]" }) is not exactly a declared endpoint"); continue }   # check:allow-declared
            foreach ($x in @($rules | Where-Object { $_.Action -ceq 'Deny' -and $_.Direction -ceq $dir -and (Test-AapNetCover $_.Remote $a.Remote) })) {
                if ($x.Weight -ge $a.Weight) { $p.Add("$what (weight $($a.Weight)) does not outweigh the deny $($x.Remote.Text) (weight $($x.Weight))") }   # check:allow-weight
            }
        }
        foreach ($e in $ends) {
            if (-not @($allows | Where-Object { Test-AapNetEndpointRule $_ $e }).Count) { $p.Add("the $($e.Role) endpoint $($e.Text) has no $dir allow") }   # check:endpoint-allow
        }
    }
    $p.ToArray()
}

# Whether $r denies everything to and from its remote range in $Dir: a Deny in that direction that nothing else narrows.
function Test-AapNetFullDeny($r, [string]$Dir) {
    if ($r.Action -cne 'Deny') { return $false }   # check:deny-action
    if ($r.Direction -cne $Dir) { return $false }   # check:deny-direction
    if ($r.Scope.Count) { return $false }   # check:deny-unscoped
    $true
}

# Whether allow $r is exactly endpoint $e: its one address; with the endpoint's port, TCP or UDP to that port and nothing
# else narrowed; without a port, nothing narrowed at all.
function Test-AapNetEndpointRule($r, $e) {
    if ($r.Remote.Bits -ne $r.Remote.Width -or $r.Remote.Address -cne $e.Address) { return $false }   # check:allow-address
    if ($null -eq $e.Port) {
        if ($r.Scope.Count) { return $false }   # check:allow-scope
        return $true
    }
    if (($r.Scope -join ',') -cne 'protocol,remote port' -or @('TCP', 'UDP') -cnotcontains $r.Protocol -or $r.RemotePort -cne [string]$e.Port) { return $false }   # check:allow-port
    $true
}

# ---- fields, addresses and text ------------------------------------------------------------------------------------------

# A field of a hashtable or an object, whether it is there at all (a missing field is never read as a value), and the names.
function Test-AapNetField($o, [string]$Name) {
    if ($o -is [Collections.IDictionary]) { return $o.Contains($Name) }
    $null -ne $o -and $null -ne $o.PSObject.Properties[$Name]
}
function Get-AapNetField($o, [string]$Name) {
    if (-not (Test-AapNetField $o $Name)) { return }
    if ($o -is [Collections.IDictionary]) { $o[$Name] } else { $o.PSObject.Properties[$Name].Value }
}
function Get-AapNetNames($o) {
    if ($o -is [Collections.IDictionary]) { @($o.Keys | ForEach-Object { [string]$_ }) } elseif ($null -ne $o) { @($o.PSObject.Properties | ForEach-Object { $_.Name }) }
}
function Test-AapNetInt($v) { $v -is [int] -or $v -is [long] }

# A field that leaves a rule unrestricted: '', '*' or ANY (D2: which one Hyper-V shows for an unset field). For a local
# address the wildcard of the remote address's family counts too (0.0.0.0/0, ::/0).
function Test-AapNetAny([string]$Text) { @('', '*', 'any') -contains $Text.Trim() }
function Test-AapNetAnyAddress([string]$Text, [int]$Width) { (Test-AapNetAny $Text) -or $Text.Trim() -ceq $(if ($Width -eq 32) { '0.0.0.0/0' } else { '::/0' }) }

function ConvertTo-AapNetProtocol([string]$Text) {
    $t = $Text.Trim().ToUpperInvariant()
    if ($t -ceq '6') { 'TCP' } elseif ($t -ceq '17') { 'UDP' } else { $t }
}

# A declared endpoint, already checked, as @{ Role; Address; Port; Text }.
function ConvertTo-AapNetEndpoint($e) {
    $addr = [string](Get-AapNetField $e 'address')
    $port = $(if (Test-AapNetField $e 'port') { [int](Get-AapNetField $e 'port') } else { $null })
    @{ Role = [string](Get-AapNetField $e 'role'); Address = $addr; Port = $port; Text = $(if ($null -ne $port) { "${addr}:$port" } else { $addr }) }
}

# An address ('172.31.250.1', an address alone is a /32 or /128) or a prefix ('10.0.0.0/8') in canonical text, as
# @{ Text; Address; Bytes; Bits; Width }; $null for anything else: another spelling, host bits under the prefix, a wildcard.
function Split-AapNetPrefix([string]$Text) {
    $parts = $Text.Split('/')
    $ip = $null
    if ($parts.Count -gt 2 -or -not [Net.IPAddress]::TryParse($parts[0], [ref]$ip) -or $ip.ToString() -ne $parts[0]) { return $null }
    $bytes = $ip.GetAddressBytes()
    $width = $bytes.Length * 8
    $bits = $width
    if ($parts.Count -eq 2) {
        if ($parts[1] -cnotmatch '^[0-9]{1,3}\z' -or [int]$parts[1] -gt $width) { return $null }
        $bits = [int]$parts[1]
    }
    for ($i = $bits; $i -lt $width; $i++) { if ($bytes[$i -shr 3] -band (0x80 -shr ($i % 8))) { return $null } }
    @{ Text = "$($ip.ToString())/$bits"; Address = $ip.ToString(); Bytes = $bytes; Bits = $bits; Width = $width }
}

# Whether prefix $P contains $T, an address or a prefix of the same family.
function Test-AapNetCover($P, $T) {
    if ($P.Width -ne $T.Width -or $T.Bits -lt $P.Bits) { return $false }
    for ($i = 0; $i -lt $P.Bits; $i++) {
        $m = 0x80 -shr ($i % 8)
        if (($P.Bytes[$i -shr 3] -band $m) -ne ($T.Bytes[$i -shr 3] -band $m)) { return $false }
    }
    $true
}

# Whether $Ip is a host address of the IPv4 network $Net: inside it, neither its network nor its broadcast address.
function Test-AapNetHost($Net, $Ip) {
    if (-not (Test-AapNetCover $Net $Ip)) { return $false }
    $hb = @(for ($i = $Net.Bits; $i -lt 32; $i++) { [int][bool]($Ip.Bytes[$i -shr 3] -band (0x80 -shr ($i % 8))) })
    ($hb -contains 0) -and ($hb -contains 1)
}

# A value as one short printable line for a problem text.
function Format-AapNetText($Value, [int]$Max = 40) {
    $s = [string]$Value -replace '[^ -~]', '?'
    if ($s.Length -gt $Max) { $s.Substring(0, $Max) + '...' } else { $s }
}

Export-ModuleMember -Function Get-AapHostNetworkFixedDeny, Get-AapHostNetworkSwitchName, Get-AapHostNetworkDeclarationProblems, Get-AapHostNetworkAdapterProblems
