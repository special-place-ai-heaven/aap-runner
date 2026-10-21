# Shared check of the P10.0 host network module's work (parity/contracts/host-network-module.md, Shared check): the
# declaration Attach returns, and Hyper-V's read-back of a VM's adapters against it. Pure: no Hyper-V, file, registry or
# network call. Each check returns problem lines (printable, at most 200 characters, at most 64); none means it holds. The
# one implementation for every consumer: the image builders (P06, P07), the VM backends (P10, P11), the module's own Verify
# and the shared fake (tests/common/AapHostNetworkFake.psm1). Windows PowerShell 5.1 and PowerShell 7.
# Lines tagged '# check:<name>' are the checks tests/common/Invoke-AapHostNetworkMutations.ps1 disables one at a time.

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# guest-transport.md's fixed deny ranges in canonical text: the only copy. The module writes them, every read-back checks
# them. Guests have and need no IPv6: '::/0' also covers every IPv6 form of an IPv4 address and the host's IPv6 prefixes.
$script:FixedDeny = @('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16', '100.64.0.0/10', '224.0.0.0/4', 'ff00::/8', 'fe80::/10', 'fc00::/7', '255.255.255.255/32', '0.0.0.0/8', '127.0.0.0/8', '240.0.0.0/4', '::/0')
# The fixed ranges a NAT routes unicast in: where a subnet and a private resolver may lie.
$script:PrivateRanges = @('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '100.64.0.0/10')
$script:StormLimit = '100'   # broadcast, multicast and unknown unicast packets per second (contract, Rules and weights; D2)
$script:Directions = @('Inbound', 'Outbound')   # an extended port ACL has no 'Both'
$script:AdapterKeys = @('SwitchName', 'SwitchType', 'DhcpGuard', 'RouterGuard', 'MacAddressSpoofing', 'PortMirroringMode', 'VlanMode', 'StormLimit', 'LegacyAcls', 'Peers', 'Acls')
$script:RuleKeys = @('Action', 'Direction', 'RemoteAddress', 'LocalAddress', 'Protocol', 'RemotePort', 'LocalPort', 'Weight', 'Stateful', 'IsolationId')
$script:DeclarationKeys = @('schema', 'kind', 'vm_id', 'vm_name', 'profile', 'subnet', 'gateway', 'address', 'resolvers', 'endpoints')
$script:EndpointKeys = @('address', 'protocol', 'port')
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
    @(Get-AapNetDeclarationProblem $Request $Declaration) | ForEach-Object { Format-AapNetText $_ 197 } | Select-Object -First 64
}

function Get-AapHostNetworkAdapterProblems {
    <# Hyper-V's read-back of a VM's adapters (the provider shape, contract Read-back) against the declaration Attach returned.
       HostDeny: the host's addresses and prefixes (Verify check 5), which the host-specific denies must cover and no
       endpoint may lie in; only the module knows the host, so its Verify passes them and consumers do not. Given, it must
       hold the declaration's gateway and, as HostLan, at least one address of a host interface that is not a vEthernet
       adapter (an empty or partial discovery cannot pass). Any line: AAP_NetworkUntrusted. #>
    param([Parameter(Mandatory)][AllowNull()]$Declaration, [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Adapters,
        [AllowEmptyCollection()][string[]]$HostDeny, [AllowEmptyCollection()][string[]]$HostLan)
    $targets = $null
    if ($PSBoundParameters.ContainsKey('HostDeny') -or $PSBoundParameters.ContainsKey('HostLan')) { $targets = [string[]]@($HostDeny) }
    @(Get-AapNetAdapterProblem $Declaration $Adapters $targets ([string[]]@($HostLan))) | ForEach-Object { Format-AapNetText $_ 197 } | Select-Object -First 64
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
    if (-not (Test-AapNetPrivate $net)) { $p.Add("the subnet $($net.Text) is not inside a private fixed range"); return $p.ToArray() }   # check:decl-subnet-private
    # The guest's static addressing: no DHCP serves it (contract, Attach).
    $gw = [string](Get-AapNetField $d 'gateway')
    if (-not (Test-AapNetHost $net (Split-AapNetAddress $gw))) { $p.Add("the gateway $(Format-AapNetText $gw) is not a host address of $($net.Text)") }   # check:decl-gateway
    $addr = [string](Get-AapNetField $d 'address')
    if (-not (Test-AapNetHost $net (Split-AapNetAddress $addr)) -or $addr -ceq $gw) { $p.Add("the address $(Format-AapNetText $addr) is not a host address of $($net.Text) other than the gateway") }   # check:decl-address
    # The narrowed exceptions, none by default: one private resolver the owner chose, outside the subnet, as up to two
    # endpoints, UDP and TCP to port 53.
    $ends = Get-AapNetList $d 'endpoints'
    if ($null -eq $ends -or $ends.Count -gt 2) { $p.Add('the endpoints are not a list of at most 2') }   # check:decl-endpoints
    $dns = New-Object Collections.Generic.List[string]
    $seen = New-Object Collections.Generic.List[string]
    foreach ($e in $ends) {
        if ((@(Get-AapNetNames $e | Sort-Object) -join ',') -cne (@($script:EndpointKeys | Sort-Object) -join ',')) { $p.Add('an endpoint is not exactly address, protocol and port'); continue }   # check:decl-endpoint
        $text = [string](Get-AapNetField $e 'address'); $proto = [string](Get-AapNetField $e 'protocol'); $port = Get-AapNetField $e 'port'
        $ip = Split-AapNetAddress $text
        if ($null -eq $ip -or -not (Test-AapNetPrivate $ip) -or (Test-AapNetCover $net $ip)) { $p.Add("the endpoint $(Format-AapNetText $text) is not one private IPv4 address outside $($net.Text)"); continue }   # check:decl-endpoint-address
        if (@('TCP', 'UDP') -cnotcontains $proto -or -not ((Test-AapNetInt $port) -and $port -eq 53)) { $p.Add("the endpoint $text is not narrowed to TCP or UDP and port 53"); continue }   # check:decl-endpoint-narrow
        $key = "$text $proto $port"
        if ($seen -ccontains $key) { $p.Add("the endpoint $key is declared twice") }   # check:decl-endpoints
        $seen.Add($key)
        if ($dns -cnotcontains $text) { $dns.Add($text) }
    }
    if ($dns.Count -gt 1) { $p.Add("the endpoints name $($dns.Count) addresses, not one resolver") }   # check:decl-endpoint-one
    # The resolvers the guest is given: public ones (global unicast) need no Allow; the private one only as the endpoints.
    $res = Get-AapNetList $d 'resolvers'
    if ($null -eq $res -or $res.Count -lt 1 -or $res.Count -gt 2) { $p.Add('the resolvers are not a list of one or two addresses'); return $p.ToArray() }   # check:decl-resolvers
    $listed = New-Object Collections.Generic.List[string]
    foreach ($r in $res) {
        $text = [string]$r
        $ip = Split-AapNetAddress $text
        if ($null -eq $ip -or $listed -ccontains $text) { $p.Add("the resolver $(Format-AapNetText $text) is not one IPv4 address, listed once"); continue }   # check:decl-resolver
        $listed.Add($text)
        if ((Test-AapNetFixed $ip) -and $dns -cnotcontains $text) { $p.Add("the resolver $text is neither public nor a declared endpoint on port 53") }   # check:decl-resolver-private
    }
    # No exception for an address the guest is not told to use.
    foreach ($x in $dns) { if ($listed -cnotcontains $x) { $p.Add("the endpoint $x is not one of the resolvers") } }   # check:decl-endpoint-resolver
    $p.ToArray()
}

# ---- the read-back -------------------------------------------------------------------------------------------------------

function Get-AapNetAdapterProblem($d, $Adapters, $HostDeny, [string[]]$HostLan) {
    $echo = @{ VmId = (Get-AapNetField $d 'vm_id'); VmName = (Get-AapNetField $d 'vm_name'); Profile = (Get-AapNetField $d 'profile') }
    $bad = @(Get-AapNetDeclarationProblem $echo $d)
    if ($bad.Count) { return @($bad | ForEach-Object { "declaration: $_" }) }   # check:adapter-declaration
    if ($null -eq $Adapters) { $Adapters = @() }
    if ($Adapters.Count -ne 1) { return "the VM has $($Adapters.Count) network adapters, not 1" }   # check:adapter-count
    $n = $Adapters[0]
    $missing = @($script:AdapterKeys | Where-Object { -not (Test-AapNetField $n $_) })
    if ($missing.Count) { return "the adapter read-back lacks $($missing -join ', ')" }   # check:adapter-keys
    $v = @{}
    foreach ($k in 'SwitchName', 'SwitchType', 'DhcpGuard', 'RouterGuard', 'MacAddressSpoofing', 'PortMirroringMode', 'VlanMode', 'StormLimit', 'LegacyAcls') { $v[$k] = Format-AapNetText (Get-AapNetField $n $k) }
    $p = New-Object Collections.Generic.List[string]
    $sw = Get-AapHostNetworkSwitchName ([string](Get-AapNetField $d 'vm_name'))
    $addr = [string](Get-AapNetField $d 'address')
    $gw = [string](Get-AapNetField $d 'gateway')
    if ([string](Get-AapNetField $n 'SwitchName') -cne $sw -or [string](Get-AapNetField $n 'SwitchType') -cne 'Internal') { $p.Add("the adapter is on '$($v.SwitchName)' ($($v.SwitchType)), not on the internal switch $sw") }   # check:switch
    if ([string](Get-AapNetField $n 'DhcpGuard') -cne 'On') { $p.Add("DHCP guard is '$($v.DhcpGuard)', not On") }   # check:dhcp-guard
    if ([string](Get-AapNetField $n 'RouterGuard') -cne 'On') { $p.Add("router guard is '$($v.RouterGuard)', not On") }   # check:router-guard
    if ([string](Get-AapNetField $n 'MacAddressSpoofing') -cne 'Off') { $p.Add("MAC address spoofing is '$($v.MacAddressSpoofing)', not Off") }   # check:mac-spoofing
    if ([string](Get-AapNetField $n 'PortMirroringMode') -cne 'None') { $p.Add("port mirroring is '$($v.PortMirroringMode)', not None") }   # check:mirroring
    if (@('Untagged', 'Access') -cnotcontains [string](Get-AapNetField $n 'VlanMode')) { $p.Add("the VLAN mode is '$($v.VlanMode)', not Untagged or Access") }   # check:vlan
    if ([string](Get-AapNetField $n 'StormLimit') -cne $script:StormLimit) { $p.Add("the storm limit is '$($v.StormLimit)', not $($script:StormLimit)") }   # check:storm-limit
    $legacy = Get-AapNetField $n 'LegacyAcls'
    if (-not (Test-AapNetInt $legacy) -or $legacy -ne 0) { $p.Add("the adapter has '$($v.LegacyAcls)' legacy port ACLs, not 0") }   # check:legacy-acls
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
        $extra = @(Get-AapNetNames $r | Where-Object { $script:RuleKeys -cnotcontains $_ })
        if ($extra.Count) { $p.Add("rule $i has unknown $(Format-AapNetText ($extra -join ', '))"); continue }   # check:rule-extra
        $act = [string](Get-AapNetField $r 'Action'); $dir = [string](Get-AapNetField $r 'Direction')
        if (@('Allow', 'Deny') -cnotcontains $act -or $script:Directions -cnotcontains $dir) { $p.Add("rule $i is '$(Format-AapNetText $act)' '$(Format-AapNetText $dir)', not Allow or Deny, Inbound or Outbound"); continue }   # check:rule-kind
        # Every rule stateless and in no isolation network: either would let traffic past what the rule list shows.
        if ([string](Get-AapNetField $r 'Stateful') -cne 'False') { $p.Add("rule $i is stateful '$(Format-AapNetText (Get-AapNetField $r 'Stateful'))', not False"); continue }   # check:rule-stateful
        if (@('0', '') -cnotcontains [string](Get-AapNetField $r 'IsolationId')) { $p.Add("rule $i has isolation id '$(Format-AapNetText (Get-AapNetField $r 'IsolationId'))', not 0"); continue }   # check:rule-isolation
        $w = Get-AapNetField $r 'Weight'
        if (-not (Test-AapNetInt $w) -or $w -lt [int]::MinValue -or $w -gt [int]::MaxValue) { $p.Add("rule $i has no Int32 weight"); continue }   # check:rule-weight
        $remote = Split-AapNetPrefix ([string](Get-AapNetField $r 'RemoteAddress'))
        if ($null -eq $remote) { $p.Add("rule $i's remote address '$(Format-AapNetText (Get-AapNetField $r 'RemoteAddress'))' is not an address or a prefix"); continue }   # check:rule-remote
        # What narrows the rule below its remote address: a deny narrowed by anything does not deny the range.
        $scope = New-Object Collections.Generic.List[string]
        $localText = [string](Get-AapNetField $r 'LocalAddress')
        $local = $null
        if (-not (Test-AapNetAnyAddress $localText $remote.Width)) { $scope.Add('local address'); $local = Split-AapNetPrefix $localText }   # check:scope-local-address
        if (-not (Test-AapNetAny ([string](Get-AapNetField $r 'Protocol')))) { $scope.Add('protocol') }   # check:scope-protocol
        if (-not (Test-AapNetAny ([string](Get-AapNetField $r 'LocalPort')))) { $scope.Add('local port') }   # check:scope-local-port
        if (-not (Test-AapNetAny ([string](Get-AapNetField $r 'RemotePort')))) { $scope.Add('remote port') }   # check:scope-remote-port
        $rules.Add([pscustomobject]@{ N = $i; Action = $act; Direction = $dir; Remote = $remote; Local = $local; Weight = [long]$w; Scope = $scope.ToArray()
                Protocol = (ConvertTo-AapNetProtocol ([string](Get-AapNetField $r 'Protocol'))); RemotePort = ([string](Get-AapNetField $r 'RemotePort')).Trim() })
    }
    # The source pin: the one outbound Allow of every IPv4 destination from the guest's own address, above the catch-all deny
    # and below every deny it must not lift (contract, Rules and weights).
    $pins = @($rules | Where-Object { $_.Action -ceq 'Allow' -and (Test-AapNetPinRule $_ $addr) })

    # Rule (i): every fixed range denied in both directions, unscoped and above the source pin; the host-specific targets
    # covered the same way, none of them an endpoint, and none a public IPv4 address, which the decided shape does not cover
    # (contract, Limitations).
    foreach ($range in $script:FixedDeny) {
        $rp = Split-AapNetPrefix $range
        foreach ($dir in $script:Directions) {
            $floor = Get-AapNetFloor $pins $dir $rp
            if (-not @($rules | Where-Object { $_.Remote.Text -ceq $range -and (Test-AapNetFullDeny $_ $dir $floor) }).Count) { $p.Add("no unscoped $dir deny for $range") }   # check:fixed-deny
        }
    }
    $ends = @(Get-AapNetField $d 'endpoints' | ForEach-Object { ConvertTo-AapNetEndpoint $_ })
    if ($null -ne $HostDeny -and $HostDeny.Count -eq 0) { $p.Add('no host-specific targets: host discovery found nothing') }   # check:host-empty
    if ($null -ne $HostDeny -and $HostDeny.Count -and -not @($HostDeny | Where-Object { $g = Split-AapNetPrefix $_; $null -ne $g -and $g.Text -ceq "$gw/32" }).Count) { $p.Add("the host-specific targets lack the gateway $($gw): host discovery is incomplete") }   # check:host-gateway
    if ($null -ne $HostDeny -and -not @($HostLan | Where-Object { $_ -and $HostDeny -ccontains $_ }).Count) { $p.Add('the host-specific targets hold no address of a host interface that is not a vEthernet adapter: host discovery is incomplete') }   # check:host-lan
    foreach ($t in $HostDeny) {
        $tp = Split-AapNetPrefix $t
        if ($null -eq $tp) { $p.Add("the host-specific target '$(Format-AapNetText $t)' is not an address or a prefix"); continue }   # check:host-deny
        if ($tp.Width -eq 32 -and -not (Test-AapNetFixed $tp)) { $p.Add("the host's $($tp.Text) is public IPv4, outside the enforcement shape: not certified (contract, Limitations)"); continue }   # check:host-public
        foreach ($dir in $script:Directions) {
            $floor = Get-AapNetFloor $pins $dir $tp
            if (-not @($rules | Where-Object { (Test-AapNetFullDeny $_ $dir $floor) -and (Test-AapNetCover $_.Remote $tp) }).Count) { $p.Add("no unscoped $dir deny covers the host's $($tp.Text)") }   # check:host-deny
        }
        foreach ($e in $ends) {
            if (Test-AapNetCover $tp $e.Ip) { $p.Add("the endpoint $($e.Text) lies in the host's $($tp.Text)") }   # check:host-endpoint
        }
    }

    # Rule (ii): every allow is the source pin or exactly a declared endpoint; an endpoint's allow outweighs every deny of its
    # direction that covers it; every endpoint has an allow in both directions. With no endpoint declared (the default) the
    # source pin is the only allow.
    if ($pins.Count -ne 1) { $p.Add("there are $($pins.Count) source pins, not 1") }   # check:pin-count
    if ($pins.Count -eq 1 -and -not @($rules | Where-Object { $_.Remote.Text -ceq '0.0.0.0/0' -and (Test-AapNetFullDeny $_ 'Outbound' ([long]::MinValue)) -and $_.Weight -lt $pins[0].Weight }).Count) {   # check:pin-catch-all
        $p.Add("no unscoped Outbound deny for 0.0.0.0/0 below the source pin (weight $($pins[0].Weight))")
    }
    foreach ($dir in $script:Directions) {
        $allows = @($rules | Where-Object { $_.Action -ceq 'Allow' -and $_.Direction -ceq $dir })
        foreach ($a in $allows) {
            if (@($pins | Where-Object { $_.N -eq $a.N }).Count) { continue }
            $what = "rule $($a.N): the $dir allow $($a.Remote.Text)"
            if (-not @($ends | Where-Object { Test-AapNetEndpointRule $a $_ $addr }).Count) { $p.Add("$what$(if ($a.Scope.Count) { " [$($a.Scope -join ', ')]" }) is not exactly a declared endpoint"); continue }   # check:allow-declared
            foreach ($x in @($rules | Where-Object { $_.Action -ceq 'Deny' -and $_.Direction -ceq $dir -and (Test-AapNetCover $_.Remote $a.Remote) })) {
                if ($x.Weight -ge $a.Weight) { $p.Add("$what (weight $($a.Weight)) does not outweigh the deny $($x.Remote.Text) (weight $($x.Weight))") }   # check:allow-weight
            }
        }
        foreach ($e in $ends) {
            if (-not @($allows | Where-Object { Test-AapNetEndpointRule $_ $e $addr }).Count) { $p.Add("the endpoint $($e.Text) has no $dir allow") }   # check:endpoint-allow
        }
    }
    $p.ToArray()
}

# Whether $r denies everything to and from its remote range in $Dir: a Deny in that direction that nothing else narrows,
# heavier than $Floor (the source pin's weight where the pin covers the range, so the pin does not lift it).
function Test-AapNetFullDeny($r, [string]$Dir, [long]$Floor) {
    if ($r.Action -cne 'Deny') { return $false }   # check:deny-action
    if ($r.Direction -cne $Dir) { return $false }   # check:deny-direction
    if ($r.Scope.Count) { return $false }   # check:deny-unscoped
    if ($r.Weight -le $Floor) { return $false }   # check:deny-floor
    $true
}

# The heaviest source pin of direction $Dir that covers $T; the lowest Int64 when none does.
function Get-AapNetFloor($Pins, [string]$Dir, $T) {
    $f = [long]::MinValue
    foreach ($x in @($Pins | Where-Object { $_.Direction -ceq $Dir -and (Test-AapNetCover $_.Remote $T) })) { $f = [Math]::Max($f, $x.Weight) }
    $f
}

# Whether allow $r is the source pin: outbound, every IPv4 destination, narrowed only to the guest's own address.
function Test-AapNetPinRule($r, [string]$Address) {
    if ($r.Direction -cne 'Outbound' -or $r.Remote.Text -cne '0.0.0.0/0' -or ($r.Scope -join ',') -cne 'local address') { return $false }   # check:pin-shape
    if ($null -eq $r.Local -or $r.Local.Text -cne "$Address/32") { return $false }   # check:pin-local
    $true
}

# Whether allow $r is exactly endpoint $e: its one address, its protocol and its remote port, the guest's own address as
# the local one, and nothing else narrowed.
function Test-AapNetEndpointRule($r, $e, [string]$Address) {
    if ($r.Remote.Bits -ne $r.Remote.Width -or $r.Remote.Address -cne $e.Address) { return $false }   # check:allow-address
    if (($r.Scope -join ',') -cne 'local address,protocol,remote port' -or $r.Protocol -cne $e.Protocol -or $r.RemotePort -cne [string]$e.Port) { return $false }   # check:allow-port
    if ($null -eq $r.Local -or $r.Local.Text -cne "$Address/32") { return $false }   # check:allow-local
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
# A field that must be a list, as the list itself (empty or not); nothing when it is missing or not a list.
function Get-AapNetList($o, [string]$Name) {
    if (-not (Test-AapNetField $o $Name)) { return }
    $v = $(if ($o -is [Collections.IDictionary]) { , $o[$Name] } else { , $o.PSObject.Properties[$Name].Value })
    if ($v -is [Collections.IList]) { , $v }   # check:list-type
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

# A declared endpoint, already checked, as @{ Address; Ip; Protocol; Port; Text }.
function ConvertTo-AapNetEndpoint($e) {
    $addr = [string](Get-AapNetField $e 'address'); $proto = [string](Get-AapNetField $e 'protocol'); $port = [int](Get-AapNetField $e 'port')
    @{ Address = $addr; Ip = (Split-AapNetPrefix $addr); Protocol = $proto; Port = $port; Text = "$addr $proto $port" }
}

# An address ('172.31.250.1', an address alone is a /32 or /128) or a prefix ('10.0.0.0/8') in canonical text, as
# @{ Text; Address; Bytes; Bits; Width }; $null for anything else: another spelling (upper-case IPv6 and a zero-padded prefix
# length too), host bits under the prefix, a wildcard.
function Split-AapNetPrefix([string]$Text) {
    $parts = $Text.Split('/')
    $ip = $null
    if ($parts.Count -gt 2 -or -not [Net.IPAddress]::TryParse($parts[0], [ref]$ip) -or $ip.ToString() -cne $parts[0]) { return $null }   # check:addr-canonical
    $bytes = $ip.GetAddressBytes()
    $width = $bytes.Length * 8
    $bits = $width
    if ($parts.Count -eq 2) {
        if ($parts[1] -cnotmatch '^(0|[1-9][0-9]{0,2})\z' -or [int]$parts[1] -gt $width) { return $null }   # check:addr-prefix-length
        $bits = [int]$parts[1]
    }
    for ($i = $bits; $i -lt $width; $i++) { if ($bytes[$i -shr 3] -band (0x80 -shr ($i % 8))) { return $null } }   # check:addr-host-bits
    @{ Text = "$($ip.ToString())/$bits"; Address = $ip.ToString(); Bytes = $bytes; Bits = $bits; Width = $width }
}

# One IPv4 address in canonical text ('172.31.250.1', no prefix), as Split-AapNetPrefix gives it; $null for anything else.
function Split-AapNetAddress([string]$Text) {
    $ip = Split-AapNetPrefix $Text
    if ($null -ne $ip -and $ip.Width -eq 32 -and $Text -ceq $ip.Address) { $ip }   # check:addr-single
}

# Whether address or prefix $P lies inside a fixed range.
function Test-AapNetFixed($P) { @($script:FixedDeny | Where-Object { Test-AapNetCover (Split-AapNetPrefix $_) $P }).Count -gt 0 }

# Whether IPv4 address or prefix $P is private: inside a fixed range a NAT routes unicast in, 10.0.0.0/8, 172.16.0.0/12,
# 192.168.0.0/16 or 100.64.0.0/10.
function Test-AapNetPrivate($P) { $P.Width -eq 32 -and @($script:PrivateRanges | Where-Object { Test-AapNetCover (Split-AapNetPrefix $_) $P }).Count -gt 0 }

# Whether prefix $P contains $T, an address or a prefix of the same family.
function Test-AapNetCover($P, $T) {
    if ($P.Width -ne $T.Width -or $T.Bits -lt $P.Bits) { return $false }   # check:cover-width
    for ($i = 0; $i -lt $P.Bits; $i++) {
        $m = 0x80 -shr ($i % 8)
        if (($P.Bytes[$i -shr 3] -band $m) -ne ($T.Bytes[$i -shr 3] -band $m)) { return $false }   # check:cover-bits
    }
    $true
}

# Whether $Ip is a host address of the IPv4 network $Net: inside it, neither its network nor its broadcast address.
function Test-AapNetHost($Net, $Ip) {
    if ($null -eq $Ip -or -not (Test-AapNetCover $Net $Ip)) { return $false }   # check:host-address
    $hb = @(for ($i = $Net.Bits; $i -lt 32; $i++) { [int][bool]($Ip.Bytes[$i -shr 3] -band (0x80 -shr ($i % 8))) })
    ($hb -contains 0) -and ($hb -contains 1)
}

# A value as one short printable line for a problem text.
function Format-AapNetText($Value, [int]$Max = 40) {
    $s = [string]$Value -replace '[^ -~]', '?'
    if ($s.Length -gt $Max) { $s.Substring(0, $Max) + '...' } else { $s }
}

Export-ModuleMember -Function Get-AapHostNetworkFixedDeny, Get-AapHostNetworkSwitchName, Get-AapHostNetworkDeclarationProblems, Get-AapHostNetworkAdapterProblems
