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
    # A peer MAC the check takes for no MAC (anything but twelve hex digits as dashed pairs, colon pairs or run together),
    # and whether the declared MAC 02-A0-98-00-00-01 still shows through it once the non-hex characters are dropped (then the
    # clash is reported too); First is the text as a problem shows it.
    $malformed = @(
        @{ Case = 'empty'; M = ''; Clash = $false; First = '' }
        @{ Case = 'not-a-mac'; M = 'not-a-mac'; Clash = $false; First = 'not-a-mac' }
        @{ Case = 'of eleven digits, dashed'; M = '02-A0-98-00-00-0'; Clash = $false; First = '02-A0-98-00-00-0' }
        @{ Case = 'of thirteen digits, dashed'; M = '02-A0-98-00-00-01-0'; Clash = $false; First = '02-A0-98-00-00-01-0' }
        @{ Case = 'of fourteen digits, dashed'; M = '02-A0-98-00-00-01-FF'; Clash = $false; First = '02-A0-98-00-00-01-FF' }
        @{ Case = 'of eleven digits, run together'; M = '02A09800000'; Clash = $false; First = '02A09800000' }
        @{ Case = 'of thirteen digits, run together'; M = '02A0980000010'; Clash = $false; First = '02A0980000010' }
        @{ Case = 'with a non-hex digit'; M = '02-A0-98-00-00-0G'; Clash = $false; First = '02-A0-98-00-00-0G' }
        @{ Case = 'with a non-hex digit in a pair'; M = '02-A0-98-00-00-G1'; Clash = $false; First = '02-A0-98-00-00-G1' }
        @{ Case = 'with mixed separators'; M = '02-A0:98-00-00-01'; Clash = $true; First = '02-A0:98-00-00-01' }
        @{ Case = 'with a separator before'; M = '-02-A0-98-00-00-01'; Clash = $true; First = '-02-A0-98-00-00-01' }
        @{ Case = 'with a separator after'; M = '02-A0-98-00-00-01-'; Clash = $true; First = '02-A0-98-00-00-01-' }
        @{ Case = 'with a colon before'; M = ':02:A0:98:00:00:01'; Clash = $true; First = ':02:A0:98:00:00:01' }
        @{ Case = 'with a space before'; M = ' 02-A0-98-00-00-01'; Clash = $true; First = ' 02-A0-98-00-00-01' }
        @{ Case = 'with a space after'; M = '02-A0-98-00-00-01 '; Clash = $true; First = '02-A0-98-00-00-01 ' }
        @{ Case = 'with spaces between groups'; M = '02A0 9800 0001'; Clash = $true; First = '02A0 9800 0001' }
        @{ Case = 'with dots'; M = '02.A0.98.00.00.01'; Clash = $true; First = '02.A0.98.00.00.01' }
        @{ Case = 'dotted in fours'; M = '02A0.9800.0001'; Clash = $true; First = '02A0.9800.0001' }
        @{ Case = 'with a newline after'; M = "02A098000001`n"; Clash = $true; First = '02A098000001?' }
        @{ Case = 'with a tab inside'; M = "02-A0-98-00`t00-01"; Clash = $true; First = '02-A0-98-00?00-01' }
        @{ Case = 'with a non-ASCII character'; M = "02-A0-98-00-00-0$([char]0x2603)"; Clash = $false; First = '02-A0-98-00-00-0?' }
        @{ Case = 'of 50 characters'; M = ('a' * 50); Clash = $false; First = ('a' * 40) + '...' }
    )
}

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:Module = $(if ($env:AAP_NETCHECK_MODULE) { $env:AAP_NETCHECK_MODULE } else { Join-Path $script:Repo 'supervisor\network\AapHostNetworkCheck.psm1' })
    $script:Imported = Import-Module $script:Module -Force -PassThru
    # The contract's fixed ranges, written out: the module's copy must equal them.
    $script:Fixed = @('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16', '100.64.0.0/10', '224.0.0.0/4', 'ff00::/8', 'fe80::/10', 'fc00::/7', '255.255.255.255/32', '0.0.0.0/8', '127.0.0.0/8', '240.0.0.0/4', '::/0')
    $script:Fixed4 = @($script:Fixed | Where-Object { -not $_.Contains(':') })
    $script:Id = '6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b'
    $script:Mac = '02-A0-98-00-00-01'   # of the module's range, as Attach allocates the lowest

    # A declaration as Attach returns it: the VM's static address .2 and the gateway .1 of its switch's subnet, and the one
    # kind of exception there is, a private resolver the owner chose (UDP and TCP 53), beside a public resolver.
    function New-Decl([string]$Name = 'aap-w-1-3-1a2b3c4d', [string]$Prof = 'windows', [string]$Net = '172.31.250') {
        [ordered]@{ schema = 2; kind = 'host_network_attach'; vm_id = $script:Id; vm_name = $Name; profile = $Prof; subnet = "$Net.0/24"
            gateway = "$Net.1"; address = "$Net.2"; mac = $script:Mac; resolvers = @('192.168.1.53', '192.0.2.53')
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
        @{ SwitchName = $Switch; SwitchType = 'Internal'; MacAddress = [string]$D.mac; DhcpGuard = 'On'; RouterGuard = 'On'; MacAddressSpoofing = 'Off'; PortMirroringMode = 'None'
            VlanMode = 'Untagged'; StormLimit = '100'; LegacyAcls = 0; Peers = $Peers; Acls = $acls.ToArray()
        }
    }
    # The read-back as a consumer runs it (no host targets) or, given -HostDeny, as the module's Verify does, with the host's
    # LAN address 192.168.1.10 discovered too.
    function Get-P($D, $A, [string[]]$HostDeny) {
        if ($PSBoundParameters.ContainsKey('HostDeny')) { @(Get-AapHostNetworkAdapterProblems -Declaration $D -Adapters @($A) -HostDeny (@($HostDeny) + '192.168.1.10') -HostLan '192.168.1.10') }
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
    # What makes the shared check impure: a command, method, type or New-Object argument outside its allowlist, a command or
    # member named by a value, the engine or host objects, or text naming a file, registry, network or Hyper-V API.
    function Get-PurityViolation([string]$Text) {
        $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
        $own = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
        $cmds = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true))
        $cmds | Where-Object { -not $_.GetCommandName() } | ForEach-Object { "command by a value: $($_.Extent.Text)" }
        $cmds | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -and $own -notcontains $_ -and @('ForEach-Object', 'Where-Object', 'Select-Object', 'Sort-Object', 'New-Object', 'Set-StrictMode', 'Export-ModuleMember') -notcontains $_ } | ForEach-Object { "command: $_" }
        $ast.FindAll({ param($n) $n -is [Management.Automation.Language.MemberExpressionAst] -and $n.Member -isnot [Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { "member by a value: $($_.Extent.Text)" }
        $methods = @('Add', 'Contains', 'ContainsKey', 'GetAddressBytes', 'Max', 'Split', 'Substring', 'ToArray', 'ToString', 'ToUpperInvariant', 'Trim', 'TryParse')
        $ast.FindAll({ param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member -is [Management.Automation.Language.StringConstantExpressionAst] }, $true) |
            Where-Object { $methods -notcontains $_.Member.Value } | ForEach-Object { "method: $($_.Member.Value)" }
        $ast.FindAll({ param($n) $n -is [Management.Automation.Language.VariableExpressionAst] -and @('ExecutionContext', 'Host') -contains $_.VariablePath.UserPath }, $true) | ForEach-Object { "variable: $($_.Extent.Text)" }
        $types = @('string', 'string[]', 'int', 'long', 'bool', 'ref', 'object[]', 'pscustomobject', 'Math', 'Net.IPAddress', 'Collections.IDictionary', 'Collections.IList')
        $ast.FindAll({ param($n) $n -is [Management.Automation.Language.TypeConstraintAst] -or $n -is [Management.Automation.Language.TypeExpressionAst] }, $true) |
            ForEach-Object { $_.TypeName.FullName } | Where-Object { $types -notcontains $_ } | ForEach-Object { "type: $_" }
        $cmds | Where-Object { $_.GetCommandName() -eq 'New-Object' } | ForEach-Object { @($_.CommandElements | Select-Object -Skip 1 | ForEach-Object { $_.Extent.Text }) -join ' ' } |
            Where-Object { @('Collections.Generic.List[string]', 'Collections.Generic.List[object]') -notcontains $_ } | ForEach-Object { "New-Object $_" }
        if ($Text -match 'hyper-v\\|\[(system\.)?io\.|microsoft\.win32|hk(lm|cu):|webclient|net\.http|net\.sockets|add-type|reflection|\[type\]') { "text: $($Matches[0])" }
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

        It 'reads every documented form of an unrestricted field, another case of a keyword and a /32' {
            Set-Rule $a Deny Inbound '10.0.0.0/8' @{ LocalAddress = ''; Protocol = '*'; LocalPort = 'any'; RemotePort = ' Any '; IsolationId = '' }
            Set-Rule $a Deny Outbound '10.0.0.0/8' @{ LocalAddress = '0.0.0.0/0'; Protocol = '' }
            Set-Rule $a Deny Inbound 'ff00::/8' @{ LocalAddress = '::/0' }
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

        It 'exports the six functions of the shared check and nothing else' {
            @($script:Imported.ExportedFunctions.Keys | Sort-Object) | Should -Be @('Get-AapHostNetworkAdapterProblems', 'Get-AapHostNetworkDeclarationProblems', 'Get-AapHostNetworkFixedDeny', 'Get-AapHostNetworkMacRange', 'Get-AapHostNetworkSwitchName', 'Get-AapHostNetworkSwitchProblems')
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
            @{ K = 'SwitchName' }, @{ K = 'SwitchType' }, @{ K = 'MacAddress' }, @{ K = 'DhcpGuard' }, @{ K = 'RouterGuard' }, @{ K = 'MacAddressSpoofing' }
            @{ K = 'PortMirroringMode' }, @{ K = 'VlanMode' }, @{ K = 'StormLimit' }, @{ K = 'LegacyAcls' }, @{ K = 'Peers' }, @{ K = 'Acls' }) {
            $a.Remove($K)
            Get-P $d $a | Should -Be @("the adapter read-back lacks $K")
        }

        It 'reports an empty adapter entry' -Tag adapter-keys {
            @(Get-AapHostNetworkAdapterProblems -Declaration $d -Adapters @($null)) | Should -Be @('the adapter read-back lacks SwitchName, SwitchType, MacAddress, DhcpGuard, RouterGuard, MacAddressSpoofing, PortMirroringMode, VlanMode, StormLimit, LegacyAcls, Peers, Acls')
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

        It 'reports the adapter MAC <V>' -Tag adapter-mac -TestCases @(
            @{ V = '02-A0-98-00-00-0A' }, @{ V = '02-a0-98-00-00-01' }, @{ V = '00-15-5D-8A-3B-7C' }, @{ V = '02-A0-98-FF-FF-FF' },
            @{ V = '02A09800000A' }, @{ V = '00155D8A3B7C' }, @{ V = '02-a0-98-00-00-1' }, @{ V = '' }, @{ V = $null }) {
            # Hyper-V's twelve-digit text is normalised before it is compared, so a wrong MAC in that form is still wrong.
            # Every problem shows the text as read.
            $a.MacAddress = $V
            $what = [string]$V
            Get-P $d $a | Should -Be @("the adapter's MAC address is '$what', not the declared $($script:Mac)")
        }

        It 'takes the adapter MAC as <Case>: only Hyper-V''s own text for the declared MAC is read as it' -Tag adapter-mac-form -TestCases @(
            @{ Case = 'the contract''s dashed form'; V = '02-A0-98-00-00-01'; Ok = $true }
            @{ Case = 'twelve uppercase hex digits, no separators'; V = '02A098000001'; Ok = $true }
            @{ Case = 'twelve lower-case hex digits'; V = '02a098000001'; Ok = $false }
            @{ Case = 'eleven hex digits'; V = '02A09800000'; Ok = $false }
            @{ Case = 'thirteen hex digits'; V = '02A0980000011'; Ok = $false }
            @{ Case = 'twelve hex digits and a newline'; V = "02A098000001`n"; Ok = $false }
            @{ Case = 'twelve hex digits and a space'; V = '02A098000001 '; Ok = $false }
            @{ Case = 'twelve characters that are not all hex digits'; V = '02A09800000G'; Ok = $false }
            @{ Case = 'colons'; V = '02:A0:98:00:00:01'; Ok = $false }) {
            # Normalised, never widened: after it the check compares exactly, so anything but twelve uppercase hex digits fails
            # closed as read (lower case too: what Hyper-V prints is a lab question, D2).
            $a.MacAddress = $V
            $want = $(if ($Ok) { '' } else { "the adapter's MAC address is '$($V -replace '[^ -~]', '?')', not the declared $($script:Mac)" })
            (Get-P $d $a) -join ' | ' | Should -Be $want
        }

        It 'reads <Name> back in a clean session, where the check is out of its module''s sight, and check 2 takes Hyper-V''s own MAC text' -Tag adapter-mac-form, provider-readback -TestCases @(
            @{ Name = 'the Windows image provider'; Kind = 'win-image'; VmName = 'aap-wbuild-1a2b3c4d'; Prof = 'windows'; Net = '172.31.252'; Sw = 'aap-build-win' }
            @{ Name = 'the Ubuntu image provider'; Kind = 'ubuntu-image'; VmName = 'aap-lbuild-1a2b3c4d'; Prof = 'linux'; Net = '172.31.253'; Sw = 'aap-build-linux' }
            @{ Name = 'the Windows backend provider'; Kind = 'win-backend'; VmName = 'aap-w-1-3-1a2b3c4d'; Prof = 'windows'; Net = '172.31.250'; Sw = 'aap-guests-win' }
            @{ Name = 'the Linux backend provider'; Kind = 'lin-backend'; VmName = 'aap-l-1-3-1a2b3c4d'; Prof = 'linux'; Net = '172.31.251'; Sw = 'aap-guests-linux' }) {
            # The production path, not a text match (P02.4 review r2, A): a provider module is a module of its own, the check
            # is imported into the consumer module's scope, so a provider that called one of its functions would throw
            # CommandNotFound. AapHostNetworkProviderReadBack.ps1 runs the real provider module in a fresh process beside a
            # consumer module that holds the check (the one under test), against a faked Hyper-V that shows the adapter's MAC
            # as twelve hex digits: the provider hands the text over as read, the check accepts it for the declared MAC and
            # fails closed for another one's, and the rest of the read-back (a conformant adapter) passes.
            $d = New-Decl $VmName $Prof $Net
            $d.resolvers = @('192.0.2.53'); $d.endpoints = @()
            $acls = @((New-Adapter $d $Sw).Acls | ForEach-Object {
                    [ordered]@{ Action = $_.Action; Direction = $_.Direction; RemoteIPAddress = $_.RemoteAddress; LocalIPAddress = $_.LocalAddress; Protocol = $_.Protocol
                        RemotePort = $_.RemotePort; LocalPort = $_.LocalPort; Weight = $_.Weight; Stateful = $false; IsolationID = 0 }
                })
            $state = Join-Path $TestDrive "state-$Kind.json"
            [IO.File]::WriteAllText($state, ([ordered]@{ declaration = $d; switchName = $Sw; acls = $acls; macRead = ($script:Mac -replace '-', ''); macOther = '00155D8A3B7C' } | ConvertTo-Json -Depth 8))
            # Windows PowerShell 5.1 turns a native command's stderr into a terminating error under 'Stop', which Pester sets:
            # the child's own words must reach the assertion below.
            $before = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try { $out = @(& (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'AapHostNetworkProviderReadBack.ps1') -Repo $script:Repo -Check $script:Module -Provider $Kind -StatePath $state 2>&1 | ForEach-Object { "$_" }) } finally { $ErrorActionPreference = $before }
            $LASTEXITCODE | Should -Be 0 -Because ($out -join ' | ')
            # Only the harness's own result lines count: a host may print another line around them (a notice, a warning).
            @($out | Where-Object { $_ -cmatch '^(ISOLATED|LEAKED|READ |GOOD|BAD)' }) | Should -Be @('ISOLATED', "READ $($script:Mac -replace '-', '')", 'GOOD ', 'READ 00155D8A3B7C', "BAD the adapter's MAC address is '00155D8A3B7C', not the declared $($script:Mac)")
        }
    }

    Context 'the permanent neighbour entry (the module''s Verify)' {

        BeforeAll {
            # What the module's Verify passes as -Neighbors (check 8): the host's entries for the guest's address, each as
            # Get-NetNeighbor shows it, and as -HostInterface the switch's management adapter it resolved by identity. A
            # consumer's read-back passes neither and no entry is checked.
            function New-Entry([string]$Address, [string]$Mac, [string]$State = 'Permanent', [string]$Alias = 'vEthernet (aap-guests-win)', $InterfaceIndex = 31) {
                @{ IPAddress = $Address; LinkLayerAddress = $Mac; State = $State; InterfaceAlias = $Alias; InterfaceIndex = $InterfaceIndex }
            }
            # The resolved adapter is index 31 'vEthernet (aap-guests-win)' unless a test hands another (even none, $null) or
            # leaves it out altogether.
            function Get-NP($D, $A, $Entries, $HostInterface, [switch]$NoHostInterface) {
                $given = @{ Declaration = $D; Adapters = @($A); Neighbors = $Entries }
                if ($PSBoundParameters.ContainsKey('HostInterface')) { $given.HostInterface = $HostInterface }
                elseif (-not $NoHostInterface) { $given.HostInterface = @{ InterfaceIndex = 31; InterfaceAlias = 'vEthernet (aap-guests-win)' } }
                @(Get-AapHostNetworkAdapterProblems @given)
            }
            # The problem for an entry on interface $Idx '$Alias' against the resolved adapter, its values as a problem text shows them.
            function Get-IfaceText($Idx, $Alias, $HostIdx = 31, $HostAlias = 'vEthernet (aap-guests-win)') {
                $t = { param($v) $s = [string]$v -replace '[^ -~]', '?'; if ($s.Length -gt 40) { $s.Substring(0, 40) + '...' } else { $s } }
                "the neighbour entry is on interface $(& $t $Idx) '$(& $t $Alias)', not the switch's management adapter $(& $t $HostIdx) '$(& $t $HostAlias)'"
            }
            $script:NotResolved = "the switch's management adapter was not resolved: the neighbour entry has no interface to be held against"
        }

        It 'passes the entry Attach adds, and the consumer read-back without one' -Tag neighbor-entries {
            $e = New-Entry "$('172.31.250').2" $script:Mac
            (Get-NP $d $a @($e)) -join ' | ' | Should -Be ''
            (Get-P $d $a) -join ' | ' | Should -Be ''
        }

        It 'reports <C> neighbour entries' -Tag neighbor-count, neighbor-given, neighbor-entries -TestCases @(@{ C = 0; N = @() }, @{ C = 2; N = @('x', 'y') }) {
            Get-NP $d $a @($N) | Should -Be @("the host holds $($C) neighbour entries for $('172.31.250').2, not 1")
        }

        It 'reports an entry that lacks <K>' -Tag neighbor-keys -TestCases @(
            @{ K = 'IPAddress' }, @{ K = 'LinkLayerAddress' }, @{ K = 'State' }, @{ K = 'InterfaceAlias' }, @{ K = 'InterfaceIndex' }) {
            $e = New-Entry "$('172.31.250').2" $script:Mac
            $e.Remove($K)
            Get-NP $d $a @($e) | Should -Be @("the neighbour entry read-back lacks $K")
        }

        It 'reports an entry that lacks several keys, in the order of the entry shape' -Tag neighbor-keys {
            $e = New-Entry "$('172.31.250').2" $script:Mac
            $e.Remove('InterfaceIndex'); $e.Remove('State')
            Get-NP $d $a @($e) | Should -Be @('the neighbour entry read-back lacks State, InterfaceIndex')
        }

        It 'reports an entry that is nothing' -Tag neighbor-keys {
            Get-NP $d $a @($null) | Should -Be @('the neighbour entry read-back lacks IPAddress, LinkLayerAddress, State, InterfaceAlias, InterfaceIndex')
        }

        It 'reports an entry for another address' -Tag neighbor-address {
            $e = New-Entry "$('172.31.250').3" $script:Mac
            Get-NP $d $a @($e) | Should -Be @("the neighbour entry is for '$('172.31.250').3', not the guest's $('172.31.250').2")
        }

        It 'reports an entry with the state <S>' -Tag neighbor-state -TestCases @(@{ S = 'Stale' }, @{ S = 'Reachable' }, @{ S = 'Permanent ' }, @{ S = 'permanent' }) {
            $e = New-Entry "$('172.31.250').2" $script:Mac $S
            Get-NP $d $a @($e) | Should -Be @("the neighbour entry's state is '$S', not Permanent")
        }

        It 'reports an entry with the link-layer address <M>' -Tag neighbor-mac -TestCases @(
            @{ M = '02-A0-98-FF-FF-FE' }, @{ M = '02-a0-98-00-00-01' }, @{ M = '00-15-5D-8A-3B-7C' }, @{ M = '' }) {
            $e = New-Entry "$('172.31.250').2" $M
            Get-NP $d $a @($e) | Should -Be @("the neighbour entry's link-layer address is '$M', not the declared $($script:Mac)")
        }

        It 'reports an entry on interface 99 that shows the right alias: an alias is only a name' -Tag neighbor-interface {
            $e = New-Entry "$('172.31.250').2" $script:Mac -InterfaceIndex 99
            Get-NP $d $a @($e) | Should -Be @("the neighbour entry is on interface 99 'vEthernet (aap-guests-win)', not the switch's management adapter 31 'vEthernet (aap-guests-win)'")
        }

        It 'reports an entry on interface 31 under the alias <Case>' -Tag neighbor-interface -TestCases @(
            @{ Case = 'of the Linux guest switch'; I = 'vEthernet (aap-guests-linux)' }, @{ Case = 'Ethernet'; I = 'Ethernet' }
            @{ Case = 'with a trailing space'; I = 'vEthernet (aap-guests-win) ' }, @{ Case = 'lower case'; I = 'vethernet (aap-guests-win)' }, @{ Case = 'empty'; I = '' }
            @{ Case = 'with a control character'; I = "vEthernet`t(aap-guests-win)" }, @{ Case = 'of 60 characters'; I = ('a' * 60) }) {
            $e = New-Entry "$('172.31.250').2" $script:Mac 'Permanent' $I
            Get-NP $d $a @($e) | Should -Be @(Get-IfaceText 31 $I)
        }

        It 'reports an entry on the wrong interface and under the wrong alias, once' -Tag neighbor-interface {
            $e = New-Entry "$('172.31.250').2" $script:Mac 'Permanent' 'Ethernet' 7
            Get-NP $d $a @($e) | Should -Be @("the neighbour entry is on interface 7 'Ethernet', not the switch's management adapter 31 'vEthernet (aap-guests-win)'")
        }

        It 'takes the entry''s interface index <Case>' -Tag neighbor-interface -TestCases @(
            @{ Case = 'as the number 31'; X = 31; Ok = $true }, @{ Case = 'as the text 31'; X = '31'; Ok = $true }, @{ Case = 'as the long 31'; X = [long]31; Ok = $true }
            @{ Case = 'as the text 031'; X = '031'; Ok = $false }, @{ Case = 'as the text " 31"'; X = ' 31'; Ok = $false }
            @{ Case = 'as the text "31 "'; X = '31 '; Ok = $false }, @{ Case = 'as nothing'; X = $null; Ok = $false }
            @{ Case = 'as 0'; X = 0; Ok = $false }, @{ Case = 'as -31'; X = -31; Ok = $false }, @{ Case = 'as 32'; X = 32; Ok = $false }
            @{ Case = 'as the text 3.1'; X = '3.1'; Ok = $false }) {
            $e = New-Entry "$('172.31.250').2" $script:Mac -InterfaceIndex $X
            $want = $(if ($Ok) { @() } else { @(Get-IfaceText $X 'vEthernet (aap-guests-win)') })
            @(Get-NP $d $a @($e)) | Should -Be $want
        }

        It 'holds the entry against the adapter as resolved, by index and by its own alias, not the guest switch''s name' -Tag neighbor-interface {
            $renamed = @{ InterfaceIndex = 31; InterfaceAlias = 'Ethernet 9' }
            $mine = New-Entry "$('172.31.250').2" $script:Mac 'Permanent' 'Ethernet 9' 31
            (Get-NP $d $a @($mine) $renamed) -join ' | ' | Should -Be ''
            $named = New-Entry "$('172.31.250').2" $script:Mac
            Get-NP $d $a @($named) $renamed | Should -Be @(Get-IfaceText 31 'vEthernet (aap-guests-win)' 31 'Ethernet 9')
            $moved = New-Entry "$('172.31.250').2" $script:Mac 'Permanent' 'Ethernet 9' 99
            Get-NP $d $a @($moved) $renamed | Should -Be @(Get-IfaceText 99 'Ethernet 9' 31 'Ethernet 9')
            $other = @{ InterfaceIndex = 7; InterfaceAlias = 'Ethernet 9' }
            Get-NP $d $a @($mine) $other | Should -Be @(Get-IfaceText 31 'Ethernet 9' 7 'Ethernet 9')
        }

        It 'takes the resolved adapter as <Case>' -Tag neighbor-interface, neighbor-interface-given -TestCases @(
            @{ Case = 'an index given as text'; H = @{ InterfaceIndex = '31'; InterfaceAlias = 'vEthernet (aap-guests-win)' } }
            @{ Case = 'an index given as a long'; H = @{ InterfaceIndex = [long]31; InterfaceAlias = 'vEthernet (aap-guests-win)' } }
            @{ Case = 'an object'; H = [pscustomobject]@{ InterfaceIndex = 31; InterfaceAlias = 'vEthernet (aap-guests-win)' } }
            @{ Case = 'an object that carries more'; H = [pscustomobject]@{ InterfaceIndex = 31; InterfaceAlias = 'vEthernet (aap-guests-win)'; Name = 'x' } }) {
            $e = New-Entry "$('172.31.250').2" $script:Mac
            (Get-NP $d $a @($e) $H) -join ' | ' | Should -Be ''
            $wrong = New-Entry "$('172.31.250').2" $script:Mac -InterfaceIndex 99
            Get-NP $d $a @($wrong) $H | Should -Be @(Get-IfaceText 99 'vEthernet (aap-guests-win)')
        }

        It 'cuts a long alias the same way on both sides of the problem' -Tag neighbor-interface {
            $long = 'A' * 50
            $h = @{ InterfaceIndex = 31; InterfaceAlias = $long }
            $e = New-Entry "$('172.31.250').2" $script:Mac 'Permanent' $long
            (Get-NP $d $a @($e) $h) -join ' | ' | Should -Be ''
            $e2 = New-Entry "$('172.31.250').2" $script:Mac 'Permanent' $long 99
            Get-NP $d $a @($e2) $h | Should -Be @("the neighbour entry is on interface 99 '$('A' * 40)...', not the switch's management adapter 31 '$('A' * 40)...'")
        }

        It 'reports no resolved management adapter, and only that, for an otherwise perfect entry: <Case>' -Tag neighbor-interface-given -TestCases @(
            @{ Case = 'nothing'; H = $null }
            @{ Case = 'an empty table'; H = @{} }
            @{ Case = 'index 0'; H = @{ InterfaceIndex = 0; InterfaceAlias = 'vEthernet (aap-guests-win)' } }
            @{ Case = 'index 0 as text'; H = @{ InterfaceIndex = '0'; InterfaceAlias = 'vEthernet (aap-guests-win)' } }
            @{ Case = 'index 031'; H = @{ InterfaceIndex = '031'; InterfaceAlias = 'vEthernet (aap-guests-win)' } }
            @{ Case = 'index -1'; H = @{ InterfaceIndex = -1; InterfaceAlias = 'vEthernet (aap-guests-win)' } }
            @{ Case = 'index +31'; H = @{ InterfaceIndex = '+31'; InterfaceAlias = 'vEthernet (aap-guests-win)' } }
            @{ Case = 'index of 11 digits'; H = @{ InterfaceIndex = '12345678901'; InterfaceAlias = 'vEthernet (aap-guests-win)' } }
            @{ Case = 'index with a space'; H = @{ InterfaceIndex = '31 '; InterfaceAlias = 'vEthernet (aap-guests-win)' } }
            @{ Case = 'index nothing'; H = @{ InterfaceIndex = $null; InterfaceAlias = 'vEthernet (aap-guests-win)' } }
            @{ Case = 'an empty alias'; H = @{ InterfaceIndex = 31; InterfaceAlias = '' } }
            @{ Case = 'no alias value'; H = @{ InterfaceIndex = 31; InterfaceAlias = $null } }
            @{ Case = 'an alias with a control character'; H = @{ InterfaceIndex = 31; InterfaceAlias = "vEthernet`t(aap-guests-win)" } }
            @{ Case = 'an alias with a non-ASCII character'; H = @{ InterfaceIndex = 31; InterfaceAlias = "vEthernet $([char]0x2603)" } }
            @{ Case = 'no index key'; H = @{ InterfaceAlias = 'vEthernet (aap-guests-win)' } }
            @{ Case = 'no alias key'; H = @{ InterfaceIndex = 31 } }
            @{ Case = 'an object without the pair'; H = [pscustomobject]@{ Name = 'vEthernet (aap-guests-win)' } }) {
            $e = New-Entry "$('172.31.250').2" $script:Mac
            Get-NP $d $a @($e) $H | Should -Be @($script:NotResolved)
        }

        It 'reports no resolved management adapter when none was passed at all' -Tag neighbor-interface-given {
            $e = New-Entry "$('172.31.250').2" $script:Mac
            Get-NP $d $a @($e) -NoHostInterface | Should -Be @($script:NotResolved)
        }

        It 'reports the unresolved adapter first, then what is wrong with the entries' -Tag neighbor-interface-given, neighbor-count {
            Get-NP $d $a @() -NoHostInterface | Should -Be @($script:NotResolved, "the host holds 0 neighbour entries for $('172.31.250').2, not 1")
            $e = New-Entry "$('172.31.250').3" $script:Mac 'Stale'
            Get-NP $d $a @($e) $null | Should -Be @($script:NotResolved, "the neighbour entry is for '$('172.31.250').3', not the guest's $('172.31.250').2", "the neighbour entry's state is 'Stale', not Permanent")
        }

        It 'ignores the management adapter without -Neighbors, as a consumer''s read-back has none' -Tag neighbor-entries {
            foreach ($h in @($null, @{}, @{ InterfaceIndex = 0; InterfaceAlias = '' }, @{ InterfaceIndex = 31; InterfaceAlias = 'vEthernet (aap-guests-win)' })) {
                @(Get-AapHostNetworkAdapterProblems -Declaration $d -Adapters @($a) -HostInterface $h) | Should -BeNullOrEmpty
            }
            $a.DhcpGuard = 'Off'
            @(Get-AapHostNetworkAdapterProblems -Declaration $d -Adapters @($a) -HostInterface @{ InterfaceIndex = 31; InterfaceAlias = 'vEthernet (aap-guests-win)' }) | Should -Be @("DHCP guard is 'Off', not On")
        }
    }

    Context 'no other adapter on the switch carries the declared MAC (the module''s Verify)' {

        BeforeAll {
            # What the module's Verify passes as -PeerMacs (check 2): the MAC of every other adapter on the VM's switch, other
            # VMs' and the host's own. A consumer's read-back passes none and nothing is compared.
            function Get-PM($D, $A, $Peers) { @(Get-AapHostNetworkAdapterProblems -Declaration $D -Adapters @($A) -PeerMacs $Peers) }
            $script:PeerEmpty = "no other adapter was listed on aap-guests-win, where the host's own is always one: the peer MACs were not read"
        }

        It 'compares nothing without -PeerMacs, which given as an empty list would be a problem' -Tag peer-given {
            (Get-P $d $a) -join ' | ' | Should -Be ''
            @(Get-AapHostNetworkAdapterProblems -Declaration $d -Adapters @($a) -PeerMacs @()).Count | Should -Be 1
        }

        It 'passes <Case>' -Tag peer-given -TestCases @(
            @{ Case = 'only the host''s own adapter'; P = @('00-15-5D-0F-A0-01') }
            @{ Case = 'another VM''s adapter'; P = @('02-A0-98-00-00-02') }
            @{ Case = 'the host''s and other VMs'' adapters'; P = @('00-15-5D-0F-A0-01', '02-A0-98-00-00-02', '02A098000003', '02:A0:98:00:00:04', '00155d0fa001') }) {
            (Get-PM $d $a $P) -join ' | ' | Should -Be ''
        }

        It 'reports another adapter with the declared MAC written as <Case>' -Tag peer-given, peer-mac-clash -TestCases @(
            @{ Case = 'dashed upper case'; M = '02-A0-98-00-00-01' }
            @{ Case = 'dashed lower case'; M = '02-a0-98-00-00-01' }
            @{ Case = 'twelve digits, upper case'; M = '02A098000001' }
            @{ Case = 'twelve digits, lower case'; M = '02a098000001' }
            @{ Case = 'colons, upper case'; M = '02:A0:98:00:00:01' }
            @{ Case = 'colons, lower case'; M = '02:a0:98:00:00:01' }) {
            Get-PM $d $a @($M) | Should -Be @("another adapter on aap-guests-win carries the declared MAC $($script:Mac)")
        }

        It 'reports the clash once, among several peers and with several clashing' -Tag peer-given, peer-mac-clash {
            $one = "another adapter on aap-guests-win carries the declared MAC $($script:Mac)"
            Get-PM $d $a @('00-15-5D-0F-A0-01', '02-A0-98-00-00-02', '02a098000001') | Should -Be @($one)
            Get-PM $d $a @('02a098000001', '00-15-5D-0F-A0-01', $script:Mac, '02:A0:98:00:00:01') | Should -Be @($one)
        }

        It 'names the build switch for a build VM' -Tag peer-given, peer-mac-clash {
            $b = New-Decl 'aap-wbuild-0badc0de' 'windows' '172.31.252'
            $ba = New-Adapter $b 'aap-build-win'
            Get-PM $b $ba @('00-15-5D-0F-A0-01', '02a098000001') | Should -Be @("another adapter on aap-build-win carries the declared MAC $($script:Mac)")
            (Get-PM $b $ba @('00-15-5D-0F-A0-01')) -join ' | ' | Should -Be ''
        }

        It 'does not count <Case> as the declared MAC, and takes it as a MAC' -Tag peer-given, peer-mac-clash, peer-malformed -TestCases @(
            @{ Case = 'one hex digit different'; M = '02-A0-98-00-00-00' }
            @{ Case = 'the first digit different'; M = '12-A0-98-00-00-01' }
            @{ Case = 'the same digits in another order'; M = '20-A0-89-00-00-10' }
            @{ Case = 'twelve digits run together, one different'; M = '02A098000010' }
            @{ Case = 'colon pairs, one different'; M = '02:A0:98:00:00:02' }
            @{ Case = 'dashed lower case, one different'; M = '02-a0-98-00-00-02' }) {
            (Get-PM $d $a @($M)) -join ' | ' | Should -Be ''
            (Get-PM $d $a @('00-15-5D-0F-A0-01', $M)) -join ' | ' | Should -Be ''
        }

        It 'lists the clash right after the adapter''s own MAC problem' -Tag peer-given, peer-mac-clash {
            $a.MacAddress = '02-A0-98-00-00-0A'
            $a.PortMirroringMode = 'Source'
            Get-PM $d $a @('02A098000001') | Should -Be @(
                "the adapter's MAC address is '02-A0-98-00-00-0A', not the declared $($script:Mac)"
                "another adapter on aap-guests-win carries the declared MAC $($script:Mac)"
                "port mirroring is 'Source', not None")
        }

        It 'reports a list that is empty or nothing, and only that: <Case>' -Tag peer-empty -TestCases @(
            @{ Case = 'an empty list'; P = @() }, @{ Case = 'nothing'; P = $null }) {
            Get-PM $d $a $P | Should -Be @($script:PeerEmpty)
        }

        It 'reports -PeerMacs given empty or as nothing, however it is written' -Tag peer-empty, peer-given {
            @(Get-AapHostNetworkAdapterProblems -Declaration $d -Adapters @($a) -PeerMacs @()) | Should -Be @($script:PeerEmpty)
            @(Get-AapHostNetworkAdapterProblems -Declaration $d -Adapters @($a) -PeerMacs $null) | Should -Be @($script:PeerEmpty)
            @(Get-AapHostNetworkAdapterProblems -Declaration $d -Adapters @($a) -PeerMacs ([string[]]@())) | Should -Be @($script:PeerEmpty)
            @(Get-AapHostNetworkAdapterProblems -Declaration $d -Adapters @($a) -PeerMacs ([string[]]$null)) | Should -Be @($script:PeerEmpty)
            (Get-P $d $a) -join ' | ' | Should -Be ''
        }

        It 'names the build switch in the empty-list problem' -Tag peer-empty {
            $b = New-Decl 'aap-wbuild-0badc0de' 'windows' '172.31.252'
            Get-PM $b (New-Adapter $b 'aap-build-win') @() | Should -Be @("no other adapter was listed on aap-build-win, where the host's own is always one: the peer MACs were not read")
        }

        It 'lists the empty-list problem right after the adapter''s own MAC problem' -Tag peer-empty {
            $a.MacAddress = '02-A0-98-00-00-0A'
            $a.PortMirroringMode = 'Source'
            Get-PM $d $a @() | Should -Be @(
                "the adapter's MAC address is '02-A0-98-00-00-0A', not the declared $($script:Mac)"
                $script:PeerEmpty
                "port mirroring is 'Source', not None")
        }

        It 'reports the peer MAC <Case> as not a MAC, beside the host''s own good one' -Tag peer-malformed -TestCases $malformed {
            $bad = "1 of the 1 peer MACs on aap-guests-win are not MACs, the first '$First'"
            $clashText = "another adapter on aap-guests-win carries the declared MAC $($script:Mac)"
            Get-PM $d $a @($M) | Should -Be @(if ($Clash) { $bad, $clashText } else { $bad })
            $bad2 = "1 of the 2 peer MACs on aap-guests-win are not MACs, the first '$First'"
            Get-PM $d $a @('00-15-5D-0F-A0-01', $M) | Should -Be @(if ($Clash) { $bad2, $clashText } else { $bad2 })
        }

        It 'reports a peer MAC that is a null element as not a MAC' -Tag peer-malformed {
            Get-PM $d $a @($null) | Should -Be @("1 of the 1 peer MACs on aap-guests-win are not MACs, the first ''")
        }

        It 'counts every malformed peer MAC in one problem and shows the first in list order' -Tag peer-malformed {
            Get-PM $d $a @('00-15-5D-0F-A0-01', 'bad-one', '02-A0-98-00-00-02', '', '02A09800000') | Should -Be @("3 of the 5 peer MACs on aap-guests-win are not MACs, the first 'bad-one'")
            Get-PM $d $a @('', '00-15-5D-0F-A0-01', 'bad-one') | Should -Be @("2 of the 3 peer MACs on aap-guests-win are not MACs, the first ''")
            Get-PM $d $a @('zz', 'zz', 'zz', 'zz') | Should -Be @("4 of the 4 peer MACs on aap-guests-win are not MACs, the first 'zz'")
        }

        It 'names the build switch in the malformed-list problem' -Tag peer-malformed {
            $b = New-Decl 'aap-wbuild-0badc0de' 'windows' '172.31.252'
            Get-PM $b (New-Adapter $b 'aap-build-win') @('00-15-5D-0F-A0-01', 'nope') | Should -Be @("1 of the 2 peer MACs on aap-build-win are not MACs, the first 'nope'")
        }

        It 'lists a malformed peer MAC and the clash beside it, the malformed one first, whatever their order in the list' -Tag peer-malformed, peer-mac-clash {
            $clash = "another adapter on aap-guests-win carries the declared MAC $($script:Mac)"
            Get-PM $d $a @('nonsense', '02a098000001') | Should -Be @("1 of the 2 peer MACs on aap-guests-win are not MACs, the first 'nonsense'", $clash)
            Get-PM $d $a @('02a098000001', 'nonsense') | Should -Be @("1 of the 2 peer MACs on aap-guests-win are not MACs, the first 'nonsense'", $clash)
        }

        It 'lists the malformed peer MAC right after the adapter''s own MAC problem' -Tag peer-malformed {
            $a.MacAddress = '02-A0-98-00-00-0A'
            $a.PortMirroringMode = 'Source'
            Get-PM $d $a @('00-15-5D-0F-A0-01', 'nope') | Should -Be @(
                "the adapter's MAC address is '02-A0-98-00-00-0A', not the declared $($script:Mac)"
                "1 of the 2 peer MACs on aap-guests-win are not MACs, the first 'nope'"
                "port mirroring is 'Source', not None")
        }
    }

    Context 'the switch (the module''s Verify, check 9)' {

        BeforeAll {
            $script:Sw = 'aap-guests-win'
            function Get-SP($Name, $Baseline, $Extensions, $Hns) { @(Get-AapHostNetworkSwitchProblems -SwitchName $Name -Baseline $Baseline -Extensions $Extensions -HnsNetworks $Hns) }
            $script:Wfp = 'Microsoft Windows Filtering Platform'
            $script:Ndis = 'Microsoft NDIS Capture'
        }

        It 'passes the extensions of the baseline and no HNS network, in any order' -Tag switch-baseline, switch-read, switch-extension-extra, switch-extension-missing, switch-hns {
            (Get-SP $script:Sw @($script:Wfp) @($script:Wfp) @()) -join ' | ' | Should -Be ''
            (Get-SP $script:Sw @($script:Wfp, $script:Ndis, 'X') @('X', $script:Wfp, $script:Ndis) @()) -join ' | ' | Should -Be ''
        }

        It 'passes an empty baseline with no extension and no HNS network: empty is not unread' -Tag switch-baseline, switch-read {
            (Get-SP $script:Sw @() @() @()) -join ' | ' | Should -Be ''
        }

        It 'reports no recorded baseline, and only that, whatever was read: <Case>' -Tag switch-baseline -TestCases @(
            @{ Case = 'extensions and networks read'; E = @('A'); H = @('net') }
            @{ Case = 'nothing enabled'; E = @(); H = @() }
            @{ Case = 'nothing read'; E = $null; H = $null }
            @{ Case = 'only the extensions read'; E = @('A'); H = $null }) {
            Get-SP $script:Sw $null $E $H | Should -Be @("no enabled-extension baseline is recorded for the switch $script:Sw")
        }

        It 'reports lists that were not read, and only that: <Case>' -Tag switch-read -TestCases @(
            @{ Case = 'both'; B = @('A'); E = $null; H = $null }
            @{ Case = 'the extensions'; B = @('A'); E = $null; H = @() }
            @{ Case = 'the HNS networks'; B = @('A'); E = @('A'); H = $null }
            @{ Case = 'the HNS networks, with an empty baseline and no extension'; B = @(); E = @(); H = $null }
            @{ Case = 'the extensions, with an empty baseline'; B = @(); E = $null; H = @() }
            @{ Case = 'the HNS networks, with extra extensions'; B = @('A'); E = @('A', 'B'); H = $null }) {
            Get-SP $script:Sw $B $E $H | Should -Be @("the extensions or the HNS networks of the switch $script:Sw were not read")
        }

        It 'reports an extension enabled beyond the baseline: <Case>' -Tag switch-extension-extra -TestCases @(
            @{ Case = 'one'; B = @('A'); E = @('A', 'B'); N = 'B' }
            @{ Case = 'two, in the order enabled'; B = @('A'); E = @('C', 'A', 'B'); N = 'C, B' }
            @{ Case = 'with an empty baseline'; B = @(); E = @('A'); N = 'A' }) {
            Get-SP $script:Sw $B $E @() | Should -Be @("the switch $script:Sw has an extension enabled beyond its baseline: $N")
        }

        It 'reports a baseline extension that is not enabled: <Case>' -Tag switch-extension-missing -TestCases @(
            @{ Case = 'one'; B = @('A', 'B'); E = @('A'); N = 'B' }
            @{ Case = 'two, in the order of the baseline'; B = @('C', 'A', 'B'); E = @('A'); N = 'C, B' }
            @{ Case = 'with nothing enabled'; B = @('A'); E = @(); N = 'A' }) {
            Get-SP $script:Sw $B $E @() | Should -Be @("the switch $script:Sw lacks the baseline extension $N")
        }

        It 'reports an HNS network on the switch: <Case>' -Tag switch-hns -TestCases @(
            @{ Case = 'one'; H = @('Default Switch'); N = 'Default Switch' }
            @{ Case = 'two'; H = @('net1', 'net2'); N = 'net1, net2' }) {
            Get-SP $script:Sw @('A') @('A') $H | Should -Be @("an HNS network uses the switch $($script:Sw): $N")
        }

        It 'compares names exactly: <Case>' -Tag switch-extension-extra, switch-extension-missing -TestCases @(
            @{ Case = 'another case'; B = @('Microsoft Windows Filtering Platform'); E = @('microsoft windows filtering platform'); X = 'microsoft windows filtering platform'; G = 'Microsoft Windows Filtering Platform' }
            @{ Case = 'a trailing space'; B = @('A'); E = @('A '); X = 'A '; G = 'A' }
            @{ Case = 'a name that holds the other'; B = @('A B'); E = @('A'); X = 'A'; G = 'A B' }) {
            Get-SP $script:Sw $B $E @() | Should -Be @(
                "the switch $script:Sw has an extension enabled beyond its baseline: $X"
                "the switch $script:Sw lacks the baseline extension $G")
        }

        It 'lists the extra extension, the missing one and the HNS network, in that order' -Tag switch-extension-extra, switch-extension-missing, switch-hns {
            Get-SP $script:Sw @($script:Wfp, 'A') @($script:Wfp, 'B') @('net1') | Should -Be @(
                "the switch $script:Sw has an extension enabled beyond its baseline: B"
                "the switch $script:Sw lacks the baseline extension A"
                "an HNS network uses the switch $($script:Sw): net1")
        }

        It 'takes the baseline, what is enabled and the networks as lists, whatever the host returns for them' -Tag switch-extension-extra, switch-extension-missing, switch-hns {
            # A one-element result is a single value in the pipeline: the check takes what the module reads either way.
            Get-SP $script:Sw 'A' 'A' @() | Should -BeNullOrEmpty
            Get-SP $script:Sw 'A' 'B' 'net1' | Should -Be @(
                "the switch $script:Sw has an extension enabled beyond its baseline: B"
                "the switch $script:Sw lacks the baseline extension A"
                "an HNS network uses the switch $($script:Sw): net1")
        }

        It 'keeps every line printable and short, whatever the names are' -Tag switch-baseline, switch-extension-extra, switch-extension-missing, switch-hns {
            $name = ('s' * 500) + "`t`n" + [char]0x2603
            $long = "`t" + ('x' * 500) + [char]0x2603
            $all = @(Get-SP $name @('base') @('base', $long) @("$([char]7)net"))
            $all.Count | Should -Be 2
            @($all | Where-Object { $_.Length -gt 200 -or $_ -cmatch '[^ -~]' }) | Should -BeNullOrEmpty
            $all[0] | Should -Be ("the switch $('s' * 40)... has an extension enabled beyond its baseline: ?$('x' * 79)...")
            $all[1] | Should -Be ("an HNS network uses the switch $('s' * 40)...: ?net")
            $gone = @(Get-SP $name @($long) @() @())
            $gone | Should -Be @("the switch $('s' * 40)... lacks the baseline extension ?$('x' * 79)...")
            Get-SP $name $null @() @() | Should -Be @("no enabled-extension baseline is recorded for the switch $('s' * 40)...")
            Get-SP $null $null @() @() | Should -Be @('no enabled-extension baseline is recorded for the switch ')
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
            @{ V = 'ANY' }, @{ V = '10.1.0.0/8' }, @{ V = '10.0.0.0/33' }, @{ V = '10.0.0.0/08' }, @{ V = '010.0.0.0/8' }, @{ V = '10/8' }, @{ V = '10.0.0.0/8 ' }, @{ V = '' }
            @{ V = 'FF00::/8' }, @{ V = 'fF00::/8' }) {
            $a.Acls[0].RemoteAddress = $V
            # The check never throws on what Hyper-V reports: a throw here is a failed assertion, not an error.
            $got = @{}
            { $got.P = Get-P $d $a } | Should -Not -Throw
            $got.P | Should -Be @("rule 1's remote address '$V' is not an address or a prefix", 'no unscoped Inbound deny for 10.0.0.0/8')
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
            @(Get-AapHostNetworkAdapterProblems -Declaration $d -Adapters @($a) -HostDeny @() -HostLan @()) | Should -Be @(
                'no host-specific targets: host discovery found nothing'
                'the host-specific targets hold no address of a host interface that is not a vEthernet adapter: host discovery is incomplete')
        }

        It 'reports a host discovery without a non-vEthernet address: <Case>' -Tag host-lan -TestCases @(
            @{ Case = 'none named'; L = $null }, @{ Case = 'an empty list'; L = @() }, @{ Case = 'one not among the targets'; L = @('192.168.1.11') }) {
            $args2 = @{ Declaration = $d; Adapters = @($a); HostDeny = @('172.31.250.1', '192.168.1.10') }
            if ($null -ne $L) { $args2.HostLan = $L }
            @(Get-AapHostNetworkAdapterProblems @args2) | Should -Be @('the host-specific targets hold no address of a host interface that is not a vEthernet adapter: host discovery is incomplete')
            $args2.HostLan = @('192.168.1.10')
            (@(Get-AapHostNetworkAdapterProblems @args2)) -join ' | ' | Should -Be ''
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
            Get-DeclP $x (Get-Req $d) | Should -Be @("the declaration's keys are not exactly schema, kind, vm_id, vm_name, profile, subnet, gateway, address, mac, resolvers, endpoints")
        }

        It 'reports <F> <V>' -Tag decl-keys -TestCases @(@{ F = 'schema'; V = 3 }, @{ F = 'schema'; V = 1 }, @{ F = 'schema'; V = '2' }, @{ F = 'kind'; V = 'host_network_record' }) {
            $d[$F] = $V
            Get-DeclP $d | Should -Be @('the declaration is not a host_network_attach of schema 2')
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

        It 'reports the mac <V>' -Tag decl-mac, mac-canonical, mac-range -TestCases @(
            @{ V = '02-a0-98-00-00-01' }, @{ V = '02:A0:98:00:00:01' }, @{ V = '02-A0-98-0-00-001' }, @{ V = '02-a0-98-00-00-1' }
            @{ V = '00-15-5D-8A-3B-7C' }, @{ V = '02-A0-97-FF-FF-FF' }, @{ V = '02-A0-98' }, @{ V = '' }, @{ V = $null }, @{ V = 1 }) {
            $d.mac = $V
            $what = [string]$V
            Get-DeclP $d | Should -Be @("the mac $what is not one static MAC of the module's range $(Get-AapHostNetworkMacRange)-xx-xx-xx")
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
            $d.schema = 3
            Get-P $d $a | Should -Be @('declaration: the declaration is not a host_network_attach of schema 2')
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
        It 'uses only allowed commands, methods, types and New-Object arguments, invokes nothing by a computed name, and touches no file, registry, network or Hyper-V' {
            Get-PurityViolation ([IO.File]::ReadAllText($script:Module)) | Should -BeNullOrEmpty
        }

        It 'catches an injected <Case>' -TestCases @(
            @{ Case = 'reflection through a method'; Probe = '$t = "".GetType().Assembly.GetType(''System.IO.File'')' }
            @{ Case = 'script invocation through the engine'; Probe = '$ExecutionContext.InvokeCommand.InvokeScript(''1'')' }
            @{ Case = 'host access'; Probe = '$Host.UI.WriteLine(''x'')' }
            @{ Case = 'command by a value'; Probe = '$c = ''Get-Date''; & $c' }
            @{ Case = 'member by a value'; Probe = '$m = ''Trim''; ''x''.$m()' }
            @{ Case = 'file type'; Probe = '[System.IO.File]::Exists(''x'')' }
            @{ Case = 'web client'; Probe = '$w = New-Object Net.WebClient' }
            @{ Case = 'cmdlet'; Probe = 'Get-Content -LiteralPath x' }) {
            @(Get-PurityViolation ([IO.File]::ReadAllText($script:Module) + "`nfunction Test-AapNetProbe { $Probe }`n")).Count | Should -BeGreaterThan 0
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
