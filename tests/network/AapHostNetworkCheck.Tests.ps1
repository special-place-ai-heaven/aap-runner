# The shared host network check (supervisor/network/AapHostNetworkCheck.psm1) against parity/contracts/host-network-module.md:
# the declaration check and the read-back rules (i) to (iv). Pester 5 on Windows PowerShell 5.1 and PowerShell 7; python 3
# on PATH for the parity test with parity/contracts/validate.py. Tags name the check each test guards;
# tests/common/Invoke-AapHostNetworkMutations.ps1 disables each check in turn and requires its tagged tests to fail.

BeforeDiscovery {
    $fixed = @('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16', '100.64.0.0/10', '224.0.0.0/4', 'ff00::/8', 'fe80::/10', 'fc00::/7', '255.255.255.255/32', '0.0.0.0/8', '127.0.0.0/8', '240.0.0.0/4', '::/0')
    $dropCases = @(foreach ($r in $fixed) { foreach ($dir in 'Inbound', 'Outbound') { @{ Range = $r; Dir = $dir } } })
    $fixtures = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..\..\parity\contracts\fixtures\host-network-module') -Recurse -Filter 'attach-*.json' |
            ForEach-Object {
                $valid = $_.Directory.Name -eq 'valid'
                @{ Name = "$($_.Directory.Name)/$($_.Name)"; Path = $_.FullName; Valid = $valid
                    Expect = $(if ($valid) { '' } else { [string](Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json).expect })
                }
            })
}

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:Module = $(if ($env:AAP_NETCHECK_MODULE) { $env:AAP_NETCHECK_MODULE } else { Join-Path $script:Repo 'supervisor\network\AapHostNetworkCheck.psm1' })
    Import-Module $script:Module -Force
    # The contract's fixed ranges, written out: the module's copy must equal them.
    $script:Fixed = @('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16', '100.64.0.0/10', '224.0.0.0/4', 'ff00::/8', 'fe80::/10', 'fc00::/7', '255.255.255.255/32', '0.0.0.0/8', '127.0.0.0/8', '240.0.0.0/4', '::/0')
    $script:Fixed4 = @($script:Fixed | Where-Object { -not $_.Contains(':') })
    $script:Id = '6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b'

    # A declaration as Attach returns it: the VM's static address .2 and the gateway .1 of its switch's subnet, and the one
    # kind of exception there is, a private resolver the owner chose (UDP and TCP 53), beside a public resolver.
    function New-Decl([string]$Name = 'aap-w-1-3-1a2b3c4d', [string]$Prof = 'windows', [string]$Net = '172.31.250') {
        [ordered]@{ schema = 1; kind = 'host_network_attach'; vm_id = $script:Id; vm_name = $Name; profile = $Prof; subnet = "$Net.0/24"
            gateway = "$Net.1"; address = "$Net.2"; resolvers = @('192.168.1.53', '192.0.2.53')
            endpoints = @([ordered]@{ address = '192.168.1.53'; protocol = 'UDP'; port = 53 }, [ordered]@{ address = '192.168.1.53'; protocol = 'TCP'; port = 53 })
        }
    }
    function Get-Req($D) { @{ VmId = $D.vm_id; VmName = $D.vm_name; Profile = $D.profile } }
    function Get-DeclP($D, $Req = (Get-Req $D)) { @(Get-AapHostNetworkDeclarationProblems -Request $Req -Declaration $D) }
    function New-Rule([string]$Action, [string]$Dir, [string]$Remote, [int]$Weight, [string]$Protocol = 'ANY', [string]$RemotePort = 'ANY', [string]$Local = 'ANY') {
        @{ Action = $Action; Direction = $Dir; RemoteAddress = $Remote; LocalAddress = $Local; Protocol = $Protocol; RemotePort = $RemotePort; LocalPort = 'ANY'; Weight = $Weight
            Stateful = 'False'; IsolationId = '0'
        }
    }
    # What a conformant module leaves, a weight per class: each fixed range denied both ways at 10 (rules 1-14 inbound,
    # 19-32 outbound); outbound, the catch-all deny of 0.0.0.0/0 at 1 (17) and the source pin at 5 (18); each endpoint
    # allowed both ways at 20, narrowed to the guest's address, its protocol and port (15-16 inbound, 33-34 outbound).
    function New-Adapter($D, [string]$Switch = 'aap-guests-win', [object[]]$Peers = @()) {
        $acls = New-Object Collections.Generic.List[object]
        foreach ($dir in 'Inbound', 'Outbound') {
            if ($dir -eq 'Outbound') { $acls.Add((New-Rule Deny Outbound '0.0.0.0/0' 1)); $acls.Add((New-Rule Allow Outbound '0.0.0.0/0' 5 -Local "$($D.address)/32")) }
            foreach ($r in $script:Fixed) { $acls.Add((New-Rule Deny $dir $r 10)) }
            foreach ($e in $D.endpoints) { $acls.Add((New-Rule Allow $dir $e.address 20 $e.protocol ([string]$e.port) "$($D.address)/32")) }
        }
        @{ SwitchName = $Switch; SwitchType = 'Internal'; DhcpGuard = 'On'; RouterGuard = 'On'; MacAddressSpoofing = 'Off'; PortMirroringMode = 'None'
            VlanMode = 'Untagged'; StormLimit = '100'; LegacyAcls = 0; Peers = $Peers; Acls = $acls.ToArray()
        }
    }
    # The read-back as a consumer runs it (no host targets) or, given -HostDeny, as the module's Verify does.
    function Get-P($D, $A, [string[]]$HostDeny) {
        if ($PSBoundParameters.ContainsKey('HostDeny')) { @(Get-AapHostNetworkAdapterProblems -Declaration $D -Adapters @($A) -HostDeny $HostDeny) }
        else { @(Get-AapHostNetworkAdapterProblems -Declaration $D -Adapters @($A)) }
    }
    function Find-Rule($A, [string]$Action, [string]$Dir, [string]$Remote, [string]$Protocol) {
        @($A.Acls | Where-Object { $_.Action -eq $Action -and $_.Direction -eq $Dir -and $_.RemoteAddress -eq $Remote -and (-not $Protocol -or $_.Protocol -eq $Protocol) })
    }
    function Set-Rule($A, [string]$Action, [string]$Dir, [string]$Remote, [hashtable]$Values, [string]$Protocol) {
        $hit = @(Find-Rule $A $Action $Dir $Remote $Protocol)
        if ($hit.Count -ne 1) { throw "test setup: $($hit.Count) rules match" }
        foreach ($k in @($Values.Keys)) { $hit[0][$k] = $Values[$k] }
    }
    function Remove-Rule($A, [string]$Action, [string]$Dir, [string]$Remote, [string]$Protocol) {
        $gone = @(Find-Rule $A $Action $Dir $Remote $Protocol)
        if (-not $gone.Count) { throw 'test setup: no rule matches' }
        $A.Acls = @($A.Acls | Where-Object { $gone -notcontains $_ })
    }
}

Describe 'the shared host network check' {
    BeforeEach {
        $d = New-Decl
        $a = New-Adapter $d
    }

    Context 'what conforms' {
        It 'passes a runner clone beside runner clones of its profile' -Tag addr-single, cover-width, cover-bits {
            $a.Peers = @('aap-w-2-7-0a0b0c0d', 'aap-w-5-12-deadbeef')
            (Get-P $d $a) -join ' | ' | Should -Be ''
        }

        It 'passes a build VM alone on its build switch' {
            $b = New-Decl 'aap-lbuild-9f8e7d6c' 'linux' '172.31.253'
            (Get-P $b (New-Adapter $b 'aap-build-linux')) -join ' | ' | Should -Be ''
        }

        It 'passes the default: public resolvers, no endpoint, the source pin the only allow, after JSON' {
            $d.resolvers = @('192.0.2.53'); $d.endpoints = @()
            $j = $d | ConvertTo-Json -Depth 6 | ConvertFrom-Json
            $r = New-Adapter $d | ConvertTo-Json -Depth 6 | ConvertFrom-Json
            @($r.Acls | Where-Object { $_.Action -eq 'Allow' } | ForEach-Object { "$($_.LocalAddress) $($_.RemoteAddress)" }) | Should -Be @('172.31.250.2/32 0.0.0.0/0')
            (Get-DeclP $j (Get-Req $d)) -join ' | ' | Should -Be ''
            (Get-P $j $r) -join ' | ' | Should -Be ''
        }

        It 'passes a declaration and a read-back that went through JSON' {
            $j = $d | ConvertTo-Json -Depth 6 | ConvertFrom-Json
            $r = $a | ConvertTo-Json -Depth 6 | ConvertFrom-Json
            (Get-DeclP $j (Get-Req $d)) -join ' | ' | Should -Be ''
            (Get-P $j $r) -join ' | ' | Should -Be ''
        }

        It 'reads every documented form of an unrestricted field, another case and a /32' {
            Set-Rule $a Deny Inbound '10.0.0.0/8' @{ LocalAddress = ''; Protocol = '*'; LocalPort = 'any'; RemotePort = ' Any '; IsolationId = '' }
            Set-Rule $a Deny Outbound '10.0.0.0/8' @{ LocalAddress = '0.0.0.0/0'; Protocol = '' }
            Set-Rule $a Deny Inbound 'ff00::/8' @{ LocalAddress = '::/0'; RemoteAddress = 'FF00::/8' }
            Set-Rule $a Allow Outbound '0.0.0.0/0' @{ LocalAddress = '172.31.250.2' }
            Set-Rule $a Allow Outbound '192.168.1.53' @{ RemoteAddress = '192.168.1.53/32'; LocalAddress = '172.31.250.2' } -Protocol UDP
            Set-Rule $a Allow Inbound '192.168.1.53' @{ Protocol = '6' } -Protocol TCP
            Set-Rule $a Allow Inbound '192.168.1.53' @{ Protocol = 'udp' } -Protocol UDP
            $a.VlanMode = 'Access'
            (Get-P $d $a) -join ' | ' | Should -Be ''
        }

        It 'passes other weights that keep the classes in order' {
            foreach ($r in $a.Acls) { $r.Weight = $(if ($r.Action -eq 'Allow' -and $r.RemoteAddress -ne '0.0.0.0/0') { 4000 } elseif ($r.Action -eq 'Allow') { 300 } elseif ($r.RemoteAddress -eq '0.0.0.0/0') { -5 } else { 1000 }) }
            (Get-P $d $a) -join ' | ' | Should -Be ''
        }

        It 'tolerates an extra deny that covers no endpoint, whatever its weight' {
            $a.Acls += New-Rule Deny Outbound '8.8.8.8/32' 500
            (Get-P $d $a) -join ' | ' | Should -Be ''
        }

        It 'keeps the contract''s fixed ranges' {
            @(Get-AapHostNetworkFixedDeny) | Should -Be $script:Fixed
        }

        It 'names the switch of <N>' -TestCases @(
            @{ N = 'aap-w-1-3-1a2b3c4d'; S = 'aap-guests-win' }, @{ N = 'aap-l-5-123456789-0f0e0d0c'; S = 'aap-guests-linux' }
            @{ N = 'aap-wbuild-1a2b3c4d'; S = 'aap-build-win' }, @{ N = 'aap-lbuild-9f8e7d6c'; S = 'aap-build-linux' }
            @{ N = 'aap-wverify-1a2b3c4d'; S = '' }, @{ N = 'aap-lscan-9f8e7d6c'; S = '' }, @{ N = 'aap-w-6-3-1a2b3c4d'; S = '' }
            @{ N = 'AAP-W-1-3-1A2B3C4D'; S = '' }, @{ N = 'aap-w-1-3-1a2b3c4d '; S = '' }, @{ N = ''; S = '' }) {
            Get-AapHostNetworkSwitchName $N | Should -BeExactly $S
        }
    }

    Context 'the adapter' {
        It 'reports <C> network adapters' -Tag adapter-count -TestCases @(@{ C = 0 }, @{ C = 2 }) {
            $list = @(for ($i = 0; $i -lt $C; $i++) { New-Adapter $d })
            @(Get-AapHostNetworkAdapterProblems -Declaration $d -Adapters $list) | Should -Be @("the VM has $C network adapters, not 1")
        }

        It 'reports no adapter list at all' -Tag adapter-count {
            @(Get-AapHostNetworkAdapterProblems -Declaration $d -Adapters $null) | Should -Be @('the VM has 0 network adapters, not 1')
        }

        It 'reports a read-back without <K>' -Tag adapter-keys -TestCases @(
            @{ K = 'SwitchName' }, @{ K = 'SwitchType' }, @{ K = 'DhcpGuard' }, @{ K = 'RouterGuard' }, @{ K = 'MacAddressSpoofing' }
            @{ K = 'PortMirroringMode' }, @{ K = 'VlanMode' }, @{ K = 'StormLimit' }, @{ K = 'LegacyAcls' }, @{ K = 'Peers' }, @{ K = 'Acls' }) {
            $a.Remove($K)
            Get-P $d $a | Should -Be @("the adapter read-back lacks $K")
        }

        It 'reports an empty adapter entry' -Tag adapter-keys {
            @(Get-AapHostNetworkAdapterProblems -Declaration $d -Adapters @($null)) | Should -Be @('the adapter read-back lacks SwitchName, SwitchType, DhcpGuard, RouterGuard, MacAddressSpoofing, PortMirroringMode, VlanMode, StormLimit, LegacyAcls, Peers, Acls')
        }

        It 'reports a runner clone on <S> (<T>)' -Tag switch -TestCases @(
            @{ S = 'aap-build-win'; T = 'Internal' }, @{ S = 'aap-guests-linux'; T = 'Internal' }, @{ S = 'Default Switch'; T = 'Internal' }
            @{ S = 'aap-guests-win'; T = 'External' }, @{ S = 'aap-guests-win'; T = 'Private' }, @{ S = ''; T = '' }) {
            $a.SwitchName = $S; $a.SwitchType = $T
            Get-P $d $a | Should -Be @("the adapter is on '$S' ($T), not on the internal switch aap-guests-win")
        }

        It 'reports a build VM on the guest switch of its profile' -Tag switch {
            $b = New-Decl 'aap-wbuild-1a2b3c4d'
            Get-P $b (New-Adapter $b 'aap-guests-win') | Should -Be @("the adapter is on 'aap-guests-win' (Internal), not on the internal switch aap-build-win")
        }

        It 'reports DHCP guard <V>' -Tag dhcp-guard -TestCases @(@{ V = 'Off' }, @{ V = $true }, @{ V = 'on' }, @{ V = '' }) {
            $a.DhcpGuard = $V
            Get-P $d $a | Should -Be @("DHCP guard is '$V', not On")
        }

        It 'reports router guard <V>' -Tag router-guard -TestCases @(@{ V = 'Off' }, @{ V = $true }) {
            $a.RouterGuard = $V
            Get-P $d $a | Should -Be @("router guard is '$V', not On")
        }

        It 'reports MAC address spoofing <V>' -Tag mac-spoofing -TestCases @(@{ V = 'On' }, @{ V = $false }, @{ V = '' }) {
            $a.MacAddressSpoofing = $V
            Get-P $d $a | Should -Be @("MAC address spoofing is '$V', not Off")
        }

        It 'reports port mirroring <V>' -Tag mirroring -TestCases @(@{ V = 'Destination' }, @{ V = 'Source' }, @{ V = '' }) {
            $a.PortMirroringMode = $V
            Get-P $d $a | Should -Be @("port mirroring is '$V', not None")
        }

        It 'reports VLAN mode <V>' -Tag vlan -TestCases @(@{ V = 'Trunk' }, @{ V = 'Private' }, @{ V = '' }) {
            $a.VlanMode = $V
            Get-P $d $a | Should -Be @("the VLAN mode is '$V', not Untagged or Access")
        }

        It 'reports the storm limit <V>' -Tag storm-limit -TestCases @(@{ V = '0' }, @{ V = '1000' }, @{ V = '' }, @{ V = ' 100' }) {
            $a.StormLimit = $V
            Get-P $d $a | Should -Be @("the storm limit is '$V', not 100")
        }

        It 'reports <W> legacy port ACLs' -Tag legacy-acls -TestCases @(@{ V = 1; W = '1' }, @{ V = '0'; W = '0' }, @{ V = $null; W = '' }, @{ V = 0.0; W = '0' }) {
            $a.LegacyAcls = $V
            Get-P $d $a | Should -Be @("the adapter has '$W' legacy port ACLs, not 0")
        }

        It 'reports a runner clone beside <P>' -Tag peers -TestCases @(
            @{ P = 'aap-wbuild-0badc0de' }, @{ P = 'aap-l-1-1-0a0b0c0d' }, @{ P = 'web01' }, @{ P = '' }) {
            $a.Peers = @('aap-w-2-7-0a0b0c0d', $P)
            Get-P $d $a | Should -Be @("the runner clone shares aap-guests-win with $P, not only runner clones of its profile")
        }

        It 'reports a runner clone beside an unnamed VM' -Tag peers {
            $a.Peers = @($null)
            Get-P $d $a | Should -Be @('the runner clone shares aap-guests-win with , not only runner clones of its profile')
        }

        It 'reports a build VM beside <P>' -Tag peers -TestCases @(@{ P = 'aap-l-1-1-0a0b0c0d' }, @{ P = 'aap-lbuild-0badc0de' }) {
            $b = New-Decl 'aap-lbuild-9f8e7d6c' 'linux' '172.31.253'
            Get-P $b (New-Adapter $b 'aap-build-linux' @($P)) | Should -Be @("the build VM shares aap-build-linux with $P")
        }
    }

    Context 'the rules' {
        It 'reports a rule without <K>' -Tag rule-keys -TestCases @(
            @{ K = 'Action' }, @{ K = 'Direction' }, @{ K = 'RemoteAddress' }, @{ K = 'LocalAddress' }, @{ K = 'Protocol' }, @{ K = 'RemotePort' }
            @{ K = 'LocalPort' }, @{ K = 'Weight' }, @{ K = 'Stateful' }, @{ K = 'IsolationId' }) {
            $a.Acls[0].Remove($K)
            Get-P $d $a | Should -Be @("rule 1 lacks $K", 'no unscoped Inbound deny for 10.0.0.0/8')
        }

        It 'reports an empty rule' -Tag rule-keys {
            $a.Acls = @($null) + @($a.Acls | Select-Object -Skip 1)
            Get-P $d $a | Should -Be @('rule 1 lacks Action, Direction, RemoteAddress, LocalAddress, Protocol, RemotePort, LocalPort, Weight, Stateful, IsolationId', 'no unscoped Inbound deny for 10.0.0.0/8')
        }

        It 'reports a rule with the unknown field <K>' -Tag rule-extra -TestCases @(@{ K = 'IdleSessionTimeout' }, @{ K = 'Extra' }) {
            $a.Acls[0][$K] = 0
            Get-P $d $a | Should -Be @("rule 1 has unknown $K", 'no unscoped Inbound deny for 10.0.0.0/8')
        }

        It 'reports a rule <F> <V>' -Tag rule-kind -TestCases @(
            @{ F = 'Action'; V = 'Meter' }, @{ F = 'Action'; V = 'deny' }, @{ F = 'Direction'; V = 'Both' }, @{ F = 'Direction'; V = 'inbound' }) {
            $a.Acls[0][$F] = $V
            $want = $(if ($F -eq 'Action') { "rule 1 is '$V' 'Inbound', not Allow or Deny, Inbound or Outbound" } else { "rule 1 is 'Deny' '$V', not Allow or Deny, Inbound or Outbound" })
            Get-P $d $a | Should -Be @($want, 'no unscoped Inbound deny for 10.0.0.0/8')
        }

        It 'reports a rule that is stateful <V>' -Tag rule-stateful -TestCases @(@{ V = 'True' }, @{ V = $true }, @{ V = '' }, @{ V = 'false' }) {
            $a.Acls[0].Stateful = $V
            Get-P $d $a | Should -Be @("rule 1 is stateful '$V', not False", 'no unscoped Inbound deny for 10.0.0.0/8')
        }

        It 'reports a rule with isolation id <V>' -Tag rule-isolation -TestCases @(@{ V = '7' }, @{ V = 7 }, @{ V = '-1' }, @{ V = ' 0' }) {
            $a.Acls[0].IsolationId = $V
            Get-P $d $a | Should -Be @("rule 1 has isolation id '$V', not 0", 'no unscoped Inbound deny for 10.0.0.0/8')
        }

        It 'reports a weight of <V>' -Tag rule-weight -TestCases @(@{ V = '10' }, @{ V = 10.0 }, @{ V = $null }, @{ V = 3000000000 }) {
            $a.Acls[0].Weight = $V
            Get-P $d $a | Should -Be @('rule 1 has no Int32 weight', 'no unscoped Inbound deny for 10.0.0.0/8')
        }

        It 'reports the remote address <V>' -Tag rule-remote, addr-canonical, addr-prefix-length, addr-host-bits -TestCases @(
            @{ V = 'ANY' }, @{ V = '10.1.0.0/8' }, @{ V = '10.0.0.0/33' }, @{ V = '10.0.0.0/08' }, @{ V = '010.0.0.0/8' }, @{ V = '10/8' }, @{ V = '10.0.0.0/8 ' }, @{ V = '' }) {
            $a.Acls[0].RemoteAddress = $V
            Get-P $d $a | Should -Be @("rule 1's remote address '$V' is not an address or a prefix", 'no unscoped Inbound deny for 10.0.0.0/8')
        }
    }

    Context 'rule (i): each fixed range denied inbound and outbound, unscoped, above the source pin' {
        It 'reports the <Dir> deny of <Range> missing' -Tag fixed-deny, deny-direction -ForEach $dropCases {
            Remove-Rule $a Deny $Dir $Range
            Get-P $d $a | Should -Be @("no unscoped $Dir deny for $Range")
        }

        It 'does not count a deny narrowed by its <F>' -Tag deny-unscoped -TestCases @(
            @{ F = 'LocalAddress'; V = '172.31.250.5' }, @{ F = 'LocalAddress'; V = '::/0' }, @{ F = 'Protocol'; V = 'TCP' }, @{ F = 'LocalPort'; V = '1' }
            @{ F = 'RemotePort'; V = '1' }) {
            Set-Rule $a Deny Inbound '10.0.0.0/8' @{ $F = $V }
            Get-P $d $a | Should -Be @('no unscoped Inbound deny for 10.0.0.0/8')
        }

        It 'does not count a local address narrowed to one address' -Tag scope-local-address {
            Set-Rule $a Deny Outbound '192.168.0.0/16' @{ LocalAddress = '172.31.250.7/32' }
            Get-P $d $a | Should -Be @('no unscoped Outbound deny for 192.168.0.0/16')
        }

        It 'does not count a deny narrowed to TCP' -Tag scope-protocol {
            Set-Rule $a Deny Outbound 'fc00::/7' @{ Protocol = '6' }
            Get-P $d $a | Should -Be @('no unscoped Outbound deny for fc00::/7')
        }

        It 'does not count a deny narrowed to local port 1' -Tag scope-local-port {
            Set-Rule $a Deny Inbound '224.0.0.0/4' @{ LocalPort = '1' }
            Get-P $d $a | Should -Be @('no unscoped Inbound deny for 224.0.0.0/4')
        }

        It 'does not count a deny narrowed to remote ports 1-65535' -Tag scope-remote-port {
            Set-Rule $a Deny Inbound '169.254.0.0/16' @{ RemotePort = '1-65535' }
            Get-P $d $a | Should -Be @('no unscoped Inbound deny for 169.254.0.0/16')
        }

        It 'does not count an allow of a fixed range as its deny' -Tag deny-action, fixed-deny {
            Set-Rule $a Deny Inbound '10.0.0.0/8' @{ Action = 'Allow' }
            Get-P $d $a | Should -Be @('no unscoped Inbound deny for 10.0.0.0/8', 'rule 1: the Inbound allow 10.0.0.0/8 is not exactly a declared endpoint')
        }

        It 'does not count an IPv4 outbound deny the source pin outweighs or ties: pin weight <W>' -Tag deny-floor, fixed-deny -TestCases @(@{ W = 10 }, @{ W = 15 }) {
            Set-Rule $a Allow Outbound '0.0.0.0/0' @{ Weight = $W }
            Get-P $d $a | Should -Be @($script:Fixed4 | ForEach-Object { "no unscoped Outbound deny for $_" })
            Get-P $d $a @('172.31.250.1') | Should -Contain "no unscoped Outbound deny covers the host's 172.31.250.1/32"
        }
    }

    Context 'host-specific targets (the module''s Verify)' {
        It 'needs no rule of its own for a target a fixed range covers' {
            (Get-P $d $a @('172.29.16.1', '172.31.250.1', '100.100.100.100', 'fd00:aaaa::1', '2001:db8:1::/64', '172.31.251.0/24')) -join ' | ' | Should -Be ''
        }

        It 'reports an empty host discovery' -Tag host-empty {
            Get-P $d $a @() | Should -Be @('no host-specific targets: host discovery found nothing')
        }

        It 'reports a host discovery without the gateway' -Tag host-gateway {
            Get-P $d $a @('172.29.16.1', '172.31.250.0/24') | Should -Be @('the host-specific targets lack the gateway 172.31.250.1: host discovery is incomplete')
            (Get-P $d $a @('172.31.250.1/32')) -join ' | ' | Should -Be ''
        }

        It 'reports a target no unscoped deny covers, per direction' -Tag host-deny {
            Remove-Rule $a Deny Inbound '::/0'; Remove-Rule $a Deny Outbound '::/0'
            $base = @('no unscoped Inbound deny for ::/0', 'no unscoped Outbound deny for ::/0')
            Get-P $d $a @('172.31.250.1', '2001:db8:1::/64') | Should -Be ($base + @("no unscoped Inbound deny covers the host's 2001:db8:1::/64", "no unscoped Outbound deny covers the host's 2001:db8:1::/64"))
            $a.Acls += New-Rule Deny Outbound '2001:db8::/32' 10
            Get-P $d $a @('172.31.250.1', '2001:db8:1::/64') | Should -Be ($base + @("no unscoped Inbound deny covers the host's 2001:db8:1::/64"))
        }

        It 'counts only an unscoped deny of the same direction that covers the target' -Tag host-deny {
            Remove-Rule $a Deny Inbound '::/0'; Remove-Rule $a Deny Outbound '::/0'
            $a.Acls += New-Rule Deny Inbound '2001:db8:1::/64' 10 TCP
            $a.Acls += New-Rule Deny Inbound '2001:db8:1::/48' 10
            $a.Acls += New-Rule Deny Outbound '2001:db8:1::/64' 10 -RemotePort 22
            $a.Acls += New-Rule Allow Outbound '2001:db8:1::/64' 5
            $p = Get-P $d $a @('172.31.250.1', '2001:db8:1::/64')
            $p | Should -Contain "no unscoped Outbound deny covers the host's 2001:db8:1::/64"
            $p | Should -Not -Contain "no unscoped Inbound deny covers the host's 2001:db8:1::/64"
        }

        It 'reports a target that is not an address or a prefix' -Tag host-deny {
            Get-P $d $a @('172.31.250.1', 'the LAN') | Should -Be @("the host-specific target 'the LAN' is not an address or a prefix")
        }

        It 'does not certify a host with the public IPv4 <T>, denied or not' -Tag host-public -TestCases @(
            @{ T = '203.0.113.7'; W = '203.0.113.7/32' }, @{ T = '198.51.100.0/24'; W = '198.51.100.0/24' }) {
            $want = @("the host's $W is public IPv4, outside the enforcement shape: not certified (contract, Limitations)")
            Get-P $d $a @('172.31.250.1', $T) | Should -Be $want
            foreach ($dir in 'Inbound', 'Outbound') { $a.Acls += New-Rule Deny $dir $W 10 }
            Get-P $d $a @('172.31.250.1', $T) | Should -Be $want
        }

        It 'reports an endpoint in the host''s <T>' -Tag host-endpoint -TestCases @(
            @{ T = '192.168.1.53'; E = '192.168.1.53'; W = '192.168.1.53/32' }, @{ T = '172.31.251.0/24'; E = '172.31.251.53'; W = '172.31.251.0/24' }) {
            $d.resolvers = @($E); foreach ($x in $d.endpoints) { $x.address = $E }
            $a = New-Adapter $d
            Get-P $d $a @('172.31.250.1', $T) | Should -Be @("the endpoint $E UDP 53 lies in the host's $W", "the endpoint $E TCP 53 lies in the host's $W")
        }
    }

    Context 'rule (ii): the source pin and every other allow exactly a declared endpoint, above every deny that covers it' {
        It 'reports an allow of <R> <Pr> <Po>' -Tag allow-declared, allow-address -TestCases @(
            @{ R = '172.31.250.1'; Pr = 'ANY'; Po = 'ANY'; T = '172.31.250.1/32'; S = '' }
            @{ R = '172.31.250.1'; Pr = 'UDP'; Po = '53'; T = '172.31.250.1/32'; S = ' [protocol, remote port]' }
            @{ R = '192.168.1.53'; Pr = 'ANY'; Po = 'ANY'; T = '192.168.1.53/32'; S = '' }
            @{ R = '192.168.1.54'; Pr = 'UDP'; Po = '53'; T = '192.168.1.54/32'; S = ' [protocol, remote port]' }
            @{ R = '192.168.1.0/24'; Pr = 'UDP'; Po = '53'; T = '192.168.1.0/24'; S = ' [protocol, remote port]' }
            @{ R = '0.0.0.0/0'; Pr = 'ANY'; Po = 'ANY'; T = '0.0.0.0/0'; S = '' }
            @{ R = 'fd00::1/128'; Pr = 'UDP'; Po = '53'; T = 'fd00::1/128'; S = ' [protocol, remote port]' }) {
            $a.Acls += New-Rule Allow Outbound $R 100 $Pr $Po
            Get-P $d $a | Should -Be @("rule 35: the Outbound allow $T$S is not exactly a declared endpoint")
        }

        It 'reports the endpoint''s outbound UDP allow <Case>' -Tag allow-port, allow-declared, allow-address, allow-local -TestCases @(
            @{ Case = 'to another port'; V = @{ RemotePort = '54' }; T = '192.168.1.53/32'; S = ' [local address, protocol, remote port]' }
            @{ Case = 'to a port range'; V = @{ RemotePort = '53-53' }; T = '192.168.1.53/32'; S = ' [local address, protocol, remote port]' }
            @{ Case = 'to every UDP port'; V = @{ RemotePort = 'ANY' }; T = '192.168.1.53/32'; S = ' [local address, protocol]' }
            @{ Case = 'over ICMP'; V = @{ Protocol = '1' }; T = '192.168.1.53/32'; S = ' [local address, protocol, remote port]' }
            @{ Case = 'over every protocol'; V = @{ Protocol = 'ANY' }; T = '192.168.1.53/32'; S = ' [local address, remote port]' }
            @{ Case = 'from one local port'; V = @{ LocalPort = '5353' }; T = '192.168.1.53/32'; S = ' [local address, protocol, local port, remote port]' }
            @{ Case = 'from another local address'; V = @{ LocalAddress = '172.31.250.3/32' }; T = '192.168.1.53/32'; S = ' [local address, protocol, remote port]' }
            @{ Case = 'from the subnet'; V = @{ LocalAddress = '172.31.250.0/24' }; T = '192.168.1.53/32'; S = ' [local address, protocol, remote port]' }
            @{ Case = 'from every local address'; V = @{ LocalAddress = 'ANY' }; T = '192.168.1.53/32'; S = ' [protocol, remote port]' }
            @{ Case = 'to a /31'; V = @{ RemoteAddress = '192.168.1.52/31' }; T = '192.168.1.52/31'; S = ' [local address, protocol, remote port]' }
            @{ Case = 'to every port and protocol'; V = @{ Protocol = 'ANY'; RemotePort = 'ANY' }; T = '192.168.1.53/32'; S = ' [local address]' }) {
            Set-Rule $a Allow Outbound '192.168.1.53' $V -Protocol UDP
            Get-P $d $a | Should -Be @("rule 33: the Outbound allow $T$S is not exactly a declared endpoint", 'the endpoint 192.168.1.53 UDP 53 has no Outbound allow')
        }

        It 'counts an allow of the other protocol for no endpoint of that protocol' -Tag allow-port {
            Set-Rule $a Allow Inbound '192.168.1.53' @{ Protocol = 'TCP' } -Protocol UDP
            Get-P $d $a | Should -Be @('the endpoint 192.168.1.53 UDP 53 has no Inbound allow')
        }

        It 'reports an allow that does not outweigh the deny covering it: weight <W>' -Tag allow-weight -TestCases @(@{ W = 10 }, @{ W = 9 }) {
            Set-Rule $a Allow Outbound '192.168.1.53' @{ Weight = $W } -Protocol UDP
            Get-P $d $a | Should -Be @("rule 33: the Outbound allow 192.168.1.53/32 (weight $W) does not outweigh the deny 192.168.0.0/16 (weight 10)")
        }

        It 'reports every allow a heavier deny of its direction covers, and only those' -Tag allow-weight {
            $a.Acls += New-Rule Deny Outbound '192.168.1.0/24' 500
            Get-P $d $a | Should -Be @(
                'rule 33: the Outbound allow 192.168.1.53/32 (weight 20) does not outweigh the deny 192.168.1.0/24 (weight 500)'
                'rule 34: the Outbound allow 192.168.1.53/32 (weight 20) does not outweigh the deny 192.168.1.0/24 (weight 500)')
        }

        It 'reports the <Dir> allow of an endpoint missing' -Tag endpoint-allow -TestCases @(@{ Dir = 'Inbound' }, @{ Dir = 'Outbound' }) {
            Remove-Rule $a Allow $Dir '192.168.1.53' -Protocol TCP
            Get-P $d $a | Should -Be @("the endpoint 192.168.1.53 TCP 53 has no $Dir allow")
        }

        It 'reports no source pin' -Tag pin-count {
            Remove-Rule $a Allow Outbound '0.0.0.0/0'
            Get-P $d $a | Should -Be @('there are 0 source pins, not 1')
        }

        It 'reports a second source pin' -Tag pin-count {
            $a.Acls += New-Rule Allow Outbound '0.0.0.0/0' 6 -Local '172.31.250.2'
            Get-P $d $a | Should -Be @('there are 2 source pins, not 1')
        }

        It 'reports a source pin <Case>' -Tag pin-shape, pin-local -TestCases @(
            @{ Case = 'from another address'; V = @{ LocalAddress = '172.31.250.3/32' }; Dir = 'Outbound'; T = '0.0.0.0/0'; S = ' [local address]' }
            @{ Case = 'from the subnet'; V = @{ LocalAddress = '172.31.250.0/24' }; Dir = 'Outbound'; T = '0.0.0.0/0'; S = ' [local address]' }
            @{ Case = 'from every address'; V = @{ LocalAddress = 'ANY' }; Dir = 'Outbound'; T = '0.0.0.0/0'; S = '' }
            @{ Case = 'narrowed to TCP'; V = @{ Protocol = 'TCP' }; Dir = 'Outbound'; T = '0.0.0.0/0'; S = ' [local address, protocol]' }
            @{ Case = 'to half the addresses'; V = @{ RemoteAddress = '0.0.0.0/1' }; Dir = 'Outbound'; T = '0.0.0.0/1'; S = ' [local address]' }
            @{ Case = 'inbound'; V = @{ Direction = 'Inbound' }; Dir = 'Inbound'; T = '0.0.0.0/0'; S = ' [local address]' }) {
            Set-Rule $a Allow Outbound '0.0.0.0/0' $V
            Get-P $d $a | Should -Be @('there are 0 source pins, not 1', "rule 18: the $Dir allow $T$S is not exactly a declared endpoint")
        }

        It 'reports the catch-all deny <Case>' -Tag pin-catch-all -TestCases @(
            @{ Case = 'missing'; V = $null }, @{ Case = 'as heavy as the pin'; V = @{ Weight = 5 } }, @{ Case = 'above the pin'; V = @{ Weight = 9 } }
            @{ Case = 'narrowed to TCP'; V = @{ Protocol = 'TCP' } }) {
            if ($V) { Set-Rule $a Deny Outbound '0.0.0.0/0' $V } else { Remove-Rule $a Deny Outbound '0.0.0.0/0' }
            Get-P $d $a | Should -Be @('no unscoped Outbound deny for 0.0.0.0/0 below the source pin (weight 5)')
        }
    }

    Context 'the declaration' {
        It 'reports the keys: <Case>' -Tag decl-keys -TestCases @(
            @{ Case = 'an extra key'; Edit = { param($x) $x.extra = 1 } }, @{ Case = 'no gateway'; Edit = { param($x) $x.Remove('gateway') } }
            @{ Case = 'nothing'; Edit = $null }) {
            $x = $(if ($Edit) { & $Edit $d; $d } else { $null })
            Get-DeclP $x (Get-Req $d) | Should -Be @("the declaration's keys are not exactly schema, kind, vm_id, vm_name, profile, subnet, gateway, address, resolvers, endpoints")
        }

        It 'reports <F> <V>' -Tag decl-keys -TestCases @(@{ F = 'schema'; V = 2 }, @{ F = 'schema'; V = '1' }, @{ F = 'kind'; V = 'host_network_record' }) {
            $d[$F] = $V
            Get-DeclP $d | Should -Be @('the declaration is not a host_network_attach of schema 1')
        }

        It 'reports a declaration for another VM: <F>' -Tag decl-echo -TestCases @(
            @{ F = 'VmId'; V = '0b7e5d4c-3a2f-4e1d-9c8b-7a6f5e4d3c2b' }, @{ F = 'VmName'; V = 'aap-w-1-4-1a2b3c4d' }, @{ F = 'Profile'; V = 'linux' }) {
            $q = Get-Req $d
            $q[$F] = $V
            Get-DeclP $d $q | Should -Be @("the declaration is for aap-w-1-3-1a2b3c4d (windows, $($script:Id)), not the VM Attach was asked for")
        }

        It 'reports VM <Name> (<P>, <Id>)' -Tag decl-vm -TestCases @(
            @{ Name = 'aap-w-1-3-1a2b3c4d'; P = 'windows'; Id = '6F1D2C3B-4A59-4E6F-8A7B-9C0D1E2F3A4B' }, @{ Name = 'aap-wverify-1a2b3c4d'; P = 'windows'; Id = '6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b' }
            @{ Name = 'aap-w-1-3-1a2b3c4d'; P = 'linux'; Id = '6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b' }, @{ Name = 'aap-wbuild-1a2b3c4d'; P = 'Windows'; Id = '6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b' }) {
            $d.vm_name = $Name; $d.profile = $P; $d.vm_id = $Id
            Get-DeclP $d | Should -Be @("the declaration's VM $Name ($P, $Id) is not a runner clone or build VM of that profile")
        }

        It 'reports the subnet <V>' -Tag decl-subnet, addr-host-bits, addr-prefix-length -TestCases @(
            @{ V = '172.31.250.1/24' }, @{ V = '172.31.250.0/31' }, @{ V = '172.0.0.0/8' }, @{ V = 'fd00::/64' }, @{ V = '172.31.250.0' }, @{ V = '172.31.250.0/024' }, @{ V = '' }) {
            $d.subnet = $V
            Get-DeclP $d | Should -Be @("the subnet $V is not an IPv4 network of /16 to /30")
        }

        It 'reports the subnet <V>, which is not private' -Tag decl-subnet-private -TestCases @(
            @{ V = '203.0.113.0/24' }, @{ V = '172.32.0.0/16' }, @{ V = '169.254.10.0/24' }, @{ V = '224.1.0.0/16' }, @{ V = '127.0.0.0/16' }, @{ V = '240.1.0.0/16' }) {
            $d.subnet = $V
            Get-DeclP $d | Should -Be @("the subnet $V is not inside a private fixed range")
        }

        It 'reports the gateway <V>' -Tag decl-gateway, host-address, addr-canonical -TestCases @(
            @{ V = '172.31.251.1' }, @{ V = '172.31.250.0' }, @{ V = '172.31.250.255' }, @{ V = '172.31.250.1/32' }, @{ V = '172.031.250.1' }, @{ V = '' }) {
            $d.gateway = $V
            Get-DeclP $d | Should -Be @("the gateway $V is not a host address of 172.31.250.0/24")
        }

        It 'reports the address <V>' -Tag decl-address -TestCases @(
            @{ V = '172.31.250.1' }, @{ V = '172.31.251.2' }, @{ V = '172.31.250.255' }, @{ V = '172.31.250.2/32' }, @{ V = 'fd00::2' }, @{ V = '' }) {
            $d.address = $V
            Get-DeclP $d | Should -Be @("the address $V is not a host address of 172.31.250.0/24 other than the gateway")
        }

        It 'reports the endpoints <Case>' -Tag decl-endpoints, list-type -TestCases @(
            @{ Case = 'as three'; E = @([ordered]@{ address = '192.168.1.53'; protocol = 'UDP'; port = 53 }, [ordered]@{ address = '192.168.1.53'; protocol = 'TCP'; port = 53 }, [ordered]@{ address = '10.0.0.53'; protocol = 'UDP'; port = 53 }) }
            @{ Case = 'as one object, not a list'; E = [ordered]@{ address = '192.168.1.53'; protocol = 'UDP'; port = 53 } }
            @{ Case = 'as nothing'; E = $null }) {
            $d.endpoints = $E
            Get-DeclP $d | Should -Contain 'the endpoints are not a list of at most 2'
        }

        It 'reports an endpoint declared twice' -Tag decl-endpoints {
            $d.endpoints = @($d.endpoints[0], [ordered]@{ address = '192.168.1.53'; protocol = 'UDP'; port = 53 })
            Get-DeclP $d | Should -Be @('the endpoint 192.168.1.53 UDP 53 is declared twice')
        }

        It 'reports an endpoint <Case>' -Tag decl-endpoint -TestCases @(
            @{ Case = 'with an extra key'; E = [ordered]@{ address = '192.168.1.53'; protocol = 'TCP'; port = 53; weight = 1 } }
            @{ Case = 'without a protocol'; E = [ordered]@{ address = '192.168.1.53'; port = 53 } }
            @{ Case = 'without a port'; E = [ordered]@{ address = '192.168.1.53'; protocol = 'TCP' } }
            @{ Case = 'in the old shape'; E = [ordered]@{ role = 'gateway'; address = '172.31.250.1' } }
            @{ Case = 'that is nothing'; E = $null }) {
            $d.endpoints = @($d.endpoints[0], $E)
            Get-DeclP $d | Should -Be @('an endpoint is not exactly address, protocol and port')
        }

        It 'reports the endpoint address <V>' -Tag decl-endpoint-address -TestCases @(
            @{ V = '172.31.250.1' }, @{ V = '172.31.250.9' }, @{ V = '192.0.2.53' }, @{ V = '224.0.0.251' }, @{ V = '169.254.169.254' }, @{ V = '127.0.0.53' }
            @{ V = '255.255.255.255' }, @{ V = '192.168.1.0/24' }, @{ V = '192.168.001.53' }, @{ V = 'fd00::53' }, @{ V = '' }) {
            $d.endpoints[1].address = $V
            Get-DeclP $d | Should -Be @("the endpoint $V is not one private IPv4 address outside 172.31.250.0/24")
        }

        It 'reports the endpoint <F> <V>' -Tag decl-endpoint-narrow -TestCases @(
            @{ F = 'protocol'; V = 'ICMP' }, @{ F = 'protocol'; V = 'tcp' }, @{ F = 'protocol'; V = 'ANY' }, @{ F = 'protocol'; V = '' }
            @{ F = 'port'; V = 0 }, @{ F = 'port'; V = 54 }, @{ F = 'port'; V = 853 }, @{ F = 'port'; V = '53' }, @{ F = 'port'; V = $null }, @{ F = 'port'; V = 53.5 }) {
            $d.endpoints[1][$F] = $V
            Get-DeclP $d | Should -Be @('the endpoint 192.168.1.53 is not narrowed to TCP or UDP and port 53')
        }

        It 'reports endpoints for a second resolver' -Tag decl-endpoint-one {
            $d.resolvers = @('192.168.1.53', '10.0.0.53')
            $d.endpoints[1].address = '10.0.0.53'
            Get-DeclP $d | Should -Be @('the endpoints name 2 addresses, not one resolver')
        }

        It 'reports an endpoint the guest is not told to use' -Tag decl-endpoint-resolver {
            $d.resolvers = @('192.0.2.53')
            Get-DeclP $d | Should -Be @('the endpoint 192.168.1.53 is not one of the resolvers')
        }

        It 'reports the resolvers <Case>' -Tag decl-resolvers, list-type -TestCases @(
            @{ Case = 'as none'; R = @() }, @{ Case = 'as three'; R = @('192.0.2.53', '198.51.100.53', '203.0.113.53') }
            @{ Case = 'as text, not a list'; R = '192.0.2.53' }, @{ Case = 'as nothing'; R = $null }) {
            $d.resolvers = $R; $d.endpoints = @()
            Get-DeclP $d | Should -Be @('the resolvers are not a list of one or two addresses')
        }

        It 'reports the resolver <V>' -Tag decl-resolver -TestCases @(@{ V = '192.0.2.53/32' }, @{ V = '192.0.2.053' }, @{ V = 'fd00::53' }, @{ V = '' }) {
            $d.resolvers = @('192.168.1.53', $V)
            Get-DeclP $d | Should -Be @("the resolver $V is not one IPv4 address, listed once")
        }

        It 'reports a resolver listed twice' -Tag decl-resolver {
            $d.resolvers = @('192.0.2.53', '192.0.2.53'); $d.endpoints = @()
            Get-DeclP $d | Should -Be @('the resolver 192.0.2.53 is not one IPv4 address, listed once')
        }

        It 'reports the resolver <V>, neither public nor a declared endpoint' -Tag decl-resolver-private -TestCases @(
            @{ V = '172.31.250.1' }, @{ V = '10.0.0.53' }, @{ V = '192.168.1.54' }, @{ V = '100.100.100.100' }, @{ V = '255.255.255.255' }
            @{ V = '127.0.0.53' }, @{ V = '0.1.2.3' }, @{ V = '240.0.0.1' }) {
            $d.resolvers = @($V); $d.endpoints = @()
            Get-DeclP $d | Should -Be @("the resolver $V is neither public nor a declared endpoint on port 53")
        }

        It 'stops the read-back at a declaration it refuses' -Tag adapter-declaration {
            $d.schema = 2
            Get-P $d $a | Should -Be @('declaration: the declaration is not a host_network_attach of schema 1')
        }
    }

    Context 'parity with parity/contracts/validate.py, the Python reference predicate' {
        BeforeAll {
            # validate.py's own fixture run prints 'ok' for each fixture it judges as its folder says: a valid one passes, an
            # invalid one fails for its stated reason.
            $out = @(& python -B -I (Join-Path $script:Repo 'parity\contracts\validate.py') 2>&1 | ForEach-Object { "$_" })
            $script:PyOk = @($out | Where-Object { $_ -cmatch '^ok +host-network-module/' } | ForEach-Object { ($_ -split '\s+')[1] })
        }

        It 'judges <Name> as validate.py does' -Tag contract -ForEach $fixtures {
            $doc = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
            $x = $(if ($Valid) { $doc } else { $doc.instance })
            $p = @(Get-DeclP $x @{ VmId = $x.vm_id; VmName = $x.vm_name; Profile = $x.profile })
            "host-network-module/$Name" | Should -BeIn $script:PyOk -Because 'validate.py judges it as its folder says'
            if ($Valid) { $p -join ' | ' | Should -Be '' } else { $p.Count | Should -BeGreaterThan 0 }
            # A semantic reason (not the schema's): the check refuses the same field, named first in validate.py's message.
            if (-not $Valid -and $Expect -cnotmatch '^(\$|missing |unexpected )') {
                $word = ($Expect -split ' ')[0]
                $want = $(if ($word -ceq 'vm_name') { "the declaration's VM " } else { "the $word " })
                @($p | Where-Object { $_.StartsWith($want) }).Count | Should -BeGreaterThan 0 -Because "validate.py's reason: $Expect; the check's: $($p -join ' | ')"
            }
        }
    }

    Context 'output' {
        It 'stays within 64 printable lines of at most 200 characters' {
            $a.SwitchName = ('x' * 500) + "`t`n" + [char]0x2603
            $a.Peers = @('y' * 300)
            $a.Acls = @(for ($i = 0; $i -lt 300; $i++) { New-Rule Deny Inbound ("bad$([char]7)" * 40) 10 })
            $p = @(Get-P $d $a @('z' * 300))
            $p.Count | Should -Be 64
            @($p | Where-Object { $_.Length -gt 200 -or $_ -cmatch '[^ -~]' }) | Should -BeNullOrEmpty
        }

        It 'caps the declaration''s lines too, alone and inside the read-back' {
            $d.vm_name = 'n' * 300; $d.profile = 'p' * 300; $d.vm_id = 'i' * 300
            $p = @(Get-DeclP $d) + @(Get-P $d $a)
            @($p | Where-Object { $_.Length -eq 200 }).Count | Should -BeGreaterThan 0 -Because 'the uncapped lines are 205 and 218 characters'
            @($p | Where-Object { $_.Length -gt 200 }) | Should -BeNullOrEmpty
        }
    }

    Context 'purity and hygiene' {
        It 'uses only allowed commands, types and New-Object arguments, invokes nothing by a computed name, and touches no file, registry, network or Hyper-V' {
            $ast = [Management.Automation.Language.Parser]::ParseFile($script:Module, [ref]$null, [ref]$null)
            $own = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
            $cmds = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true))
            @($cmds | Where-Object { -not $_.GetCommandName() } | ForEach-Object { $_.Extent.Text }) | Should -BeNullOrEmpty -Because 'a command the parser cannot name is a dynamic invocation'
            @($cmds | ForEach-Object { $_.GetCommandName() } | Sort-Object -Unique | Where-Object { $own -notcontains $_ -and @('ForEach-Object', 'Where-Object', 'Select-Object', 'Sort-Object', 'New-Object', 'Set-StrictMode', 'Export-ModuleMember') -notcontains $_ }) | Should -BeNullOrEmpty
            @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.MemberExpressionAst] -and $n.Member -isnot [Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Extent.Text }) | Should -BeNullOrEmpty -Because 'a member named by a value is a dynamic invocation'
            $types = @('string', 'string[]', 'int', 'long', 'bool', 'ref', 'object[]', 'pscustomobject', 'Math', 'Net.IPAddress', 'Collections.IDictionary', 'Collections.IList')
            @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.TypeConstraintAst] -or $n -is [Management.Automation.Language.TypeExpressionAst] }, $true) |
                    ForEach-Object { $_.TypeName.FullName } | Sort-Object -Unique | Where-Object { $types -notcontains $_ }) | Should -BeNullOrEmpty
            @($cmds | Where-Object { $_.GetCommandName() -eq 'New-Object' } | ForEach-Object { @($_.CommandElements | Select-Object -Skip 1 | ForEach-Object { $_.Extent.Text }) -join ' ' } |
                    Where-Object { @('Collections.Generic.List[string]', 'Collections.Generic.List[object]') -notcontains $_ }) | Should -BeNullOrEmpty
            [IO.File]::ReadAllText($script:Module) | Should -Not -Match 'hyper-v\\|\[(system\.)?io\.|microsoft\.win32|hk(lm|cu):|webclient|net\.http|net\.sockets|add-type|reflection|\[type\]'
        }

        It '<_.Name> compiles and holds no expression invocation, encoded command, base64 blob or SecureString marshaling' -ForEach @(
            Get-Item -LiteralPath (Join-Path $PSScriptRoot '..\..\supervisor\network\AapHostNetworkCheck.psm1')
            Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object { $_.Extension -in '.ps1', '.psm1' }) {
            $text = [IO.File]::ReadAllText($_.FullName)
            $text | Should -Not -Match 'Invoke-Expressio[n]|\bie[x]\b|-EncodedComman[d]|FromBase64Strin[g]|SecureStringToBST[R]|PtrToStringBST[R]|PtrToStringAut[o]'
            $text | Should -Not -Match '[A-Za-z0-9+/]{120,}={0,2}'
            { [void][scriptblock]::Create($text) } | Should -Not -Throw
        }
    }
}
