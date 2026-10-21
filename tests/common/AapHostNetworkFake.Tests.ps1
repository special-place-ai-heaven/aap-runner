# The shared strict fake of the P10.0 host network module (AapHostNetworkFake.psm1) against
# parity/contracts/host-network-module.md. Pester 5 on Windows PowerShell 5.1 and PowerShell 7; python 3 on PATH (the
# fake's documents must pass parity/contracts/validate.py). Tags name the fake's check each test guards;
# Invoke-AapHostNetworkMutations.ps1 disables each check in turn and requires its tagged tests to fail.

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:Module = $(if ($env:AAP_NETFAKE_MODULE) { $env:AAP_NETFAKE_MODULE } else { Join-Path $PSScriptRoot 'AapHostNetworkFake.psm1' })
    Import-Module $script:Module -Force
    Import-Module (Join-Path $script:Repo 'supervisor\network\AapHostNetworkCheck.psm1') -Force
    $script:Validator = Join-Path $script:Repo 'parity\contracts\validate.py'
    $script:WinId = '6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b'
    $script:LinId = '0b7e5d4c-3a2f-4e1d-9c8b-7a6f5e4d3c2b'
    $script:WinId2 = '5e0c1b2a-3948-4d5e-9f6a-7b8c9d0e1f2a'
    $script:WinId3 = '7a8b9c0d-1e2f-4a3b-8c4d-5e6f7a8b9c0d'

    # A fresh fake host under TEMP. Vms is what Hyper-V has (VM id to @{ State; Adapters }); the hook reads the same
    # hashtable the test changes, and cannot look while it holds the key 'cannot-look'.
    function New-TestNet {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('aap-netfake-' + [guid]::NewGuid().ToString('n').Substring(0, 10))
        $vms = @{}
        $net = New-AapFakeHostNetwork -Root $root -Vm { param($id) if ($vms.ContainsKey('cannot-look')) { throw 'fake Hyper-V: the VM service does not answer' }; $vms[$id] }.GetNewClosure()
        [pscustomobject]@{ Root = $root; Vms = $vms; Net = $net }
    }
    function Off { @{ State = 'Off'; Adapters = 0 } }
    function Win([string]$Name = 'aap-w-1-3-1a2b3c4d', [string]$Id = $script:WinId) { @{ VmId = $Id; VmName = $Name; Profile = 'windows' } }
    function Lin([string]$Name = 'aap-lbuild-9f8e7d6c', [string]$Id = $script:LinId) { @{ VmId = $Id; VmName = $Name; Profile = 'linux' } }
    function Get-TestJson($o) { ConvertTo-Json -InputObject $o -Depth 8 -Compress }
    # The journal as it is on disk: each record file with its hash.
    function Get-TestState($t) {
        @(Get-ChildItem -LiteralPath (Join-Path $t.Root 'records') -File | Sort-Object Name | ForEach-Object { "$($_.Name)=$((Get-FileHash -LiteralPath $_.FullName).Hash)" }) -join ';'
    }
    # A record written straight into the journal, as another process of the module would have left it.
    function Write-TestRecord($t, [string]$Id, [string]$Name, [string]$Address, [string]$State = 'attached') {
        $d = [ordered]@{ schema = 1; kind = 'host_network_attach'; vm_id = $Id; vm_name = $Name; profile = 'windows'; subnet = '172.31.250.0/24'
            gateway = '172.31.250.1'; address = $Address; resolvers = @('192.0.2.53', '198.51.100.53'); endpoints = @()
        }
        $r = [ordered]@{ schema = 1; kind = 'host_network_record'; state = $State; declaration = $d; created = @([ordered]@{ kind = 'adapter'; name = "aap-guest-$Id" }) }
        [IO.File]::WriteAllText((Join-Path $t.Root "records\$Id.json"), (ConvertTo-Json -InputObject $r -Depth 6))
    }
    # A consumer's read-back of the simulated adapter: the shared check without the host-specific targets.
    function Get-TestReadback($t, $Declaration, [string]$VmId) {
        @(Get-AapHostNetworkAdapterProblems -Declaration $Declaration -Adapters @(Get-AapFakeHostNetworkAdapter -Root $t.Root -VmId $VmId))
    }
    # parity/contracts/validate.py in file mode, one document per file; returns 'ok' or 'FAIL' per document, in order.
    function Test-Contract($t, [object[]]$Docs) {
        $dir = Join-Path $t.Root 'docs'
        [void][IO.Directory]::CreateDirectory($dir)
        $files = @(for ($i = 0; $i -lt $Docs.Count; $i++) {
                $f = Join-Path $dir "$i.json"
                [IO.File]::WriteAllText($f, (ConvertTo-Json -InputObject $Docs[$i] -Depth 8), (New-Object Text.UTF8Encoding($false)))
                $f
            })
        $out = @(& python -B -I $script:Validator 'host-network-module' @files 2>&1 | ForEach-Object { "$_" })
        @($out | ForEach-Object { ($_ -split '\s+')[0] })
    }
}

Describe 'the shared host network fake' {
    BeforeEach { $t = New-TestNet }
    AfterEach { if (Test-Path -LiteralPath $t.Root) { Remove-Item -LiteralPath $t.Root -Recurse -Force } }

    Describe 'Attach' {
        It 'returns the declaration and leaves one adapter exactly as the contract requires' -Tag alloc-lru {
            $t.Vms[$script:WinId] = Off
            # A fresh host always has an address: a throw here is a failed assertion, not an error.
            $got = @{}
            { $got.D = & $t.Net.Attach (Win) } | Should -Not -Throw
            $d = $got.D
            $d.vm_id | Should -Be $script:WinId
            $d.vm_name | Should -Be 'aap-w-1-3-1a2b3c4d'
            $d.profile | Should -Be 'windows'
            @($d.subnet, $d.gateway, $d.address) | Should -Be @('172.31.250.0/24', '172.31.250.1', '172.31.250.2')
            @($d.resolvers) | Should -Be @('192.0.2.53', '198.51.100.53')
            @($d.endpoints).Count | Should -Be 0
            $nics = @(Get-AapFakeHostNetworkAdapter -Root $t.Root -VmId $script:WinId)
            $nics.Count | Should -Be 1
            $n = $nics[0]
            @($n.SwitchName, $n.SwitchType, $n.DhcpGuard, $n.RouterGuard, $n.MacAddressSpoofing, $n.PortMirroringMode, $n.VlanMode, $n.StormLimit, $n.LegacyAcls) |
                Should -Be @('aap-guests-win', 'Internal', 'On', 'On', 'Off', 'None', 'Untagged', '100', 0)
            @($n.Peers).Count | Should -Be 0
            @($n.Acls | Where-Object { $_.Stateful -ne 'False' -or $_.IsolationId -ne '0' }).Count | Should -Be 0
            @($n.Acls | Where-Object { $_.Action -eq 'Allow' } | ForEach-Object { "$($_.Direction) $($_.LocalAddress) $($_.RemoteAddress) $($_.Weight)" }) | Should -Be @('Outbound 172.31.250.2/32 0.0.0.0/0 5')
            $deny = @($n.Acls | Where-Object { $_.Action -eq 'Deny' })
            $deny.Count | Should -Be 29
            @($deny | Where-Object { "$($_.LocalAddress)$($_.Protocol)$($_.LocalPort)$($_.RemotePort)" -ne 'ANYANYANYANY' }).Count | Should -Be 0
            @($deny | Where-Object { $_.RemoteAddress -eq '0.0.0.0/0' } | ForEach-Object { "$($_.Direction) $($_.Weight)" }) | Should -Be @('Outbound 1')
            @($deny | Where-Object { $_.RemoteAddress -ne '0.0.0.0/0' -and $_.Weight -ne 10 }).Count | Should -Be 0
            @($deny | Where-Object { $_.Direction -eq 'Inbound' }).Count | Should -Be 14
            Get-TestReadback $t $d $script:WinId | Should -BeNullOrEmpty
            @(& $t.Net.Verify (Win)).Count | Should -Be 0
            @(Get-AapFakeHostNetworkRecord -Root $t.Root | ForEach-Object { $_.state }) | Should -Be @('attached')
            @((Get-AapFakeHostNetworkRecord -Root $t.Root).created | ForEach-Object { "$($_.kind) $($_.name)" }) | Should -Be @("adapter aap-guest-$($script:WinId)")
        }

        It 'gives validate.py a declaration and a record, and the shared check a read-back, that they accept, for both profiles' -Tag contract {
            $t.Vms[$script:WinId] = Off; $t.Vms[$script:LinId] = Off
            $w = & $t.Net.Attach (Win)
            $l = & $t.Net.Attach (Lin)
            Test-Contract $t @($w, $l, (Get-AapFakeHostNetworkRecord -Root $t.Root -VmId $script:WinId), (Get-AapFakeHostNetworkRecord -Root $t.Root -VmId $script:LinId)) | Should -Be @('ok', 'ok', 'ok', 'ok')
            @(Get-TestReadback $t $w $script:WinId) + @(Get-TestReadback $t $l $script:LinId) | Should -BeNullOrEmpty
        }

        It 'puts a build VM alone on its profile''s build switch' {
            $t.Vms[$script:LinId] = Off
            $d = & $t.Net.Attach (Lin)
            @($d.subnet, $d.gateway, $d.address) | Should -Be @('172.31.253.0/24', '172.31.253.1', '172.31.253.2')
            $n = @(Get-AapFakeHostNetworkAdapter -Root $t.Root -VmId $script:LinId)[0]
            $n.SwitchName | Should -Be 'aap-build-linux'
            @(& $t.Net.Verify (Lin)).Count | Should -Be 0
        }

        It 'refuses a second VM on a build switch and records nothing for it' -Tag attach-peers {
            $t.Vms[$script:LinId] = Off; $t.Vms[$script:WinId2] = Off
            $null = & $t.Net.Attach (Lin)
            $before = Get-TestState $t
            { & $t.Net.Attach (Lin 'aap-lbuild-0badc0de' $script:WinId2) } | Should -Throw 'AAP_NetworkUntrusted: aap-build-linux already carries aap-lbuild-9f8e7d6c'
            Get-TestState $t | Should -Be $before
        }

        It 'shows runner clones of a profile to each other as peers, which the shared check accepts' {
            $t.Vms[$script:WinId] = Off; $t.Vms[$script:WinId2] = Off
            $a = & $t.Net.Attach (Win)
            $null = & $t.Net.Attach (Win 'aap-w-2-4-0f0e0d0c' $script:WinId2)
            @(Get-AapFakeHostNetworkAdapter -Root $t.Root -VmId $script:WinId)[0].Peers | Should -Be @('aap-w-2-4-0f0e0d0c')
            Get-TestReadback $t $a $script:WinId | Should -BeNullOrEmpty
            @(& $t.Net.Verify (Win)).Count | Should -Be 0
        }

        It 'gives each VM on a switch its own address, held from the intent record until Detach, and reuses the least recently used last' -Tag alloc-lru {
            $t.Vms[$script:WinId] = Off; $t.Vms[$script:WinId2] = Off; $t.Vms[$script:WinId3] = Off; $t.Vms[$script:LinId] = Off
            Set-AapFakeHostNetworkKnob -Root $t.Root -Fail AttachAfterIntent
            { & $t.Net.Attach (Win) } | Should -Throw
            Set-AapFakeHostNetworkKnob -Root $t.Root
            (& $t.Net.Attach (Win 'aap-w-2-4-0f0e0d0c' $script:WinId2)).address | Should -Be '172.31.250.3'
            (& $t.Net.Attach (Win)).address | Should -Be '172.31.250.2'
            (& $t.Net.Attach (Lin 'aap-l-1-1-0a0b0c0d')).address | Should -Be '172.31.251.2'
            $t.Vms.Remove($script:WinId)
            & $t.Net.Detach (Win)
            (& $t.Net.Attach (Win 'aap-w-3-1-01020304' $script:WinId3)).address | Should -Be '172.31.250.4' -Because 'an address never used goes before one just released'
        }

        It 'once every address was used, takes the one released longest ago' -Tag alloc-lru {
            $t.Vms[$script:WinId] = Off
            $order = @(9, 2) + @(3..254 | Where-Object { $_ -ne 9 })
            [IO.File]::WriteAllText((Join-Path $t.Root 'released.json'), (ConvertTo-Json -InputObject @($order | ForEach-Object { "172.31.250.$_" })))
            Write-TestRecord $t $script:WinId2 'aap-w-2-4-0f0e0d0c' '172.31.250.9'
            (& $t.Net.Attach (Win)).address | Should -Be '172.31.250.2'
        }

        It 'refuses when every address of the subnet is held, and records nothing' -Tag attach-exhausted {
            $t.Vms[$script:WinId] = Off
            foreach ($i in 2..254) { Write-TestRecord $t ([guid]::NewGuid().ToString()) "aap-w-1-$i-0a0b0c0d" "172.31.250.$i" }
            $before = Get-TestState $t
            { & $t.Net.Attach (Win) } | Should -Throw 'AAP_NetworkUntrusted: no free address on aap-guests-win'
            Get-TestState $t | Should -Be $before
        }

        It 'gives VMs attached by concurrent processes distinct addresses' {
            $child = Join-Path $t.Root 'child.ps1'
            [IO.File]::WriteAllText($child, @'
param($Module, $Root, $Id, $Name)
$ErrorActionPreference = 'Stop'
Import-Module $Module
$n = New-AapFakeHostNetwork -Root $Root -Vm { param($id) @{ State = 'Off'; Adapters = 0 } }
while (-not (Test-Path -LiteralPath (Join-Path $Root 'go'))) { Start-Sleep -Milliseconds 5 }
(& $n.Attach @{ VmId = $Id; VmName = $Name; Profile = 'windows' }).address
'@)
            $procs = @(for ($i = 1; $i -le 6; $i++) {
                    $psi = New-Object Diagnostics.ProcessStartInfo((Get-Process -Id $PID).Path)
                    $psi.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$child`" `"$script:Module`" `"$($t.Root)`" $([guid]::NewGuid()) aap-w-1-$i-0a0b0c0d"
                    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
                    [Diagnostics.Process]::Start($psi)
                })
            Start-Sleep -Milliseconds 1500
            [IO.File]::WriteAllText((Join-Path $t.Root 'go'), '')
            $got = @(foreach ($p in $procs) { $o = $p.StandardOutput.ReadToEnd(); $e = $p.StandardError.ReadToEnd(); $p.WaitForExit(); $p.ExitCode | Should -Be 0 -Because $e; $o.Trim() })
            @($got | Sort-Object -Unique).Count | Should -Be 6 -Because "the children printed: $($got -join ', ')"
            @(Get-AapFakeHostNetworkRecord -Root $t.Root | ForEach-Object { $_.declaration.address } | Sort-Object -Unique).Count | Should -Be 6
        }

        It 'returns the same declaration on a repeated Attach (before every start) and keeps one record and one adapter' {
            $t.Vms[$script:WinId] = Off
            $first = Get-TestJson (& $t.Net.Attach (Win))
            Get-TestJson (& $t.Net.Attach (Win)) | Should -Be $first
            @(Get-AapFakeHostNetworkRecord -Root $t.Root).Count | Should -Be 1
            @(Get-AapFakeHostNetworkAdapter -Root $t.Root -VmId $script:WinId).Count | Should -Be 1
        }

        It 'records its intent before it attaches, and a retry after that crash finishes with the planned declaration' {
            $t.Vms[$script:WinId] = Off
            Set-AapFakeHostNetworkKnob -Root $t.Root -Fail AttachAfterIntent
            { & $t.Net.Attach (Win) } | Should -Throw '*Attach stopped after its intent record*'
            $rec = Get-AapFakeHostNetworkRecord -Root $t.Root -VmId $script:WinId
            $rec.state | Should -Be 'attaching'
            @(Get-AapFakeHostNetworkAdapter -Root $t.Root -VmId $script:WinId).Count | Should -Be 0
            @(& $t.Net.Verify (Win)) | Should -Be @("VM $($script:WinId) is not attached")
            Set-AapFakeHostNetworkKnob -Root $t.Root
            Get-TestJson (& $t.Net.Attach (Win)) | Should -Be (Get-TestJson $rec.declaration)
            @(& $t.Net.Verify (Win)).Count | Should -Be 0
        }

        It 'leaves an adapter its record does not yet call attached when it stops after the act; a retry or Detach recovers' {
            $t.Vms[$script:WinId] = Off
            Set-AapFakeHostNetworkKnob -Root $t.Root -Fail AttachAfterAct
            { & $t.Net.Attach (Win) } | Should -Throw '*Attach stopped after its act*'
            $rec = Get-AapFakeHostNetworkRecord -Root $t.Root -VmId $script:WinId
            $rec.state | Should -Be 'attaching'
            @(Get-AapFakeHostNetworkAdapter -Root $t.Root -VmId $script:WinId).Count | Should -Be 1
            @(& $t.Net.Verify (Win)) | Should -Be @("VM $($script:WinId) is not attached")
            Set-AapFakeHostNetworkKnob -Root $t.Root
            Get-TestJson (& $t.Net.Attach (Win)) | Should -Be (Get-TestJson $rec.declaration)
            @(& $t.Net.Verify (Win)).Count | Should -Be 0
            Set-AapFakeHostNetworkKnob -Root $t.Root -Fail AttachAfterAct
            $t.Vms[$script:WinId2] = Off
            { & $t.Net.Attach (Win 'aap-w-2-4-0f0e0d0c' $script:WinId2) } | Should -Throw
            $t.Vms.Remove($script:WinId2)
            & $t.Net.Detach (Win 'aap-w-2-4-0f0e0d0c' $script:WinId2)
            @(Get-AapFakeHostNetworkRecord -Root $t.Root -VmId $script:WinId2).Count | Should -Be 0
            @(Get-AapFakeHostNetworkAdapter -Root $t.Root -VmId $script:WinId2).Count | Should -Be 0
        }

        It 'refuses a VM Hyper-V does not have and records nothing' -Tag attach-vm {
            { & $t.Net.Attach (Win) } | Should -Throw "AAP_NetworkUntrusted: VM $($script:WinId) does not exist"
            @(Get-AapFakeHostNetworkRecord -Root $t.Root).Count | Should -Be 0
        }

        It 'refuses a VM that is <State> and records nothing' -Tag attach-off -TestCases @(@{ State = 'Running' }, @{ State = 'Saved' }, @{ State = '' }) {
            $t.Vms[$script:WinId] = @{ State = $State; Adapters = 0 }
            { & $t.Net.Attach (Win) } | Should -Throw "AAP_NetworkUntrusted: VM $($script:WinId) is $State, not Off"
            @(Get-AapFakeHostNetworkRecord -Root $t.Root).Count | Should -Be 0
        }

        It 'refuses a VM with an adapter it did not make and records nothing' -Tag attach-foreign-adapter {
            $t.Vms[$script:WinId] = @{ State = 'Off'; Adapters = 1 }
            { & $t.Net.Attach (Win) } | Should -Throw "AAP_NetworkUntrusted: VM $($script:WinId) has a network adapter Attach did not make"
            @(Get-AapFakeHostNetworkRecord -Root $t.Root).Count | Should -Be 0
        }

        It 'refuses a VM id recorded under another name or profile and keeps the record' -Tag attach-same-vm {
            $t.Vms[$script:WinId] = Off
            $null = & $t.Net.Attach (Win)
            $before = Get-TestState $t
            { & $t.Net.Attach (Win 'aap-wbuild-0123abcd') } | Should -Throw '*is recorded as aap-w-1-3-1a2b3c4d (windows)*'
            Get-TestState $t | Should -Be $before
        }
    }

    Describe 'the request' {
        It 'is refused by Attach, Verify and Detach unless it is exactly the contract''s: <Case>' -Tag request -TestCases @(
            @{ Case = 'an extra key'; R = @{ VmId = '6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b'; VmName = 'aap-w-1-3-1a2b3c4d'; Profile = 'windows'; Extra = 1 } }
            @{ Case = 'a missing key'; R = @{ VmId = '6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b'; VmName = 'aap-w-1-3-1a2b3c4d' } }
            @{ Case = 'an uppercase id'; R = @{ VmId = '6F1D2C3B-4A59-4E6F-8A7B-9C0D1E2F3A4B'; VmName = 'aap-w-1-3-1a2b3c4d'; Profile = 'windows' } }
            @{ Case = 'a verification VM'; R = @{ VmId = '6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b'; VmName = 'aap-wverify-1a2b3c4d'; Profile = 'windows' } }
            @{ Case = 'the other profile'; R = @{ VmId = '6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b'; VmName = 'aap-w-1-3-1a2b3c4d'; Profile = 'linux' } }
            @{ Case = 'a profile in capitals'; R = @{ VmId = '6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b'; VmName = 'aap-w-1-3-1a2b3c4d'; Profile = 'Windows' } }
            @{ Case = 'an object, not a hashtable'; R = [pscustomobject]@{ VmId = '6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b'; VmName = 'aap-w-1-3-1a2b3c4d'; Profile = 'windows' } }) {
            $t.Vms[$script:WinId] = Off
            foreach ($op in 'Attach', 'Verify') { { & $t.Net[$op] $R } | Should -Throw 'AAP_NetworkUntrusted: the request is not exactly*' -Because $op }
            $t.Vms.Remove($script:WinId)
            { & $t.Net.Detach $R } | Should -Throw 'AAP_NetworkUntrusted: the request is not exactly*'
            @(Get-AapFakeHostNetworkRecord -Root $t.Root).Count | Should -Be 0
        }
    }

    Describe 'Detach' {
        It 'is refused while the VM exists and changes nothing' -Tag detach-order {
            $t.Vms[$script:WinId] = Off
            $null = & $t.Net.Attach (Win)
            $before = Get-TestState $t
            { & $t.Net.Detach (Win) } | Should -Throw '*still exists; remove the VM before Detach'
            Get-TestState $t | Should -Be $before
            @(Get-AapFakeHostNetworkAdapter -Root $t.Root -VmId $script:WinId).Count | Should -Be 1
        }

        It 'throws and frees nothing while Hyper-V cannot say whether the VM exists; Attach and Verify throw too' {
            $t.Vms[$script:WinId] = Off
            $null = & $t.Net.Attach (Win)
            $t.Vms.Remove($script:WinId); $t.Vms['cannot-look'] = $true
            $before = Get-TestState $t
            foreach ($op in 'Detach', 'Verify', 'Attach') { { & $t.Net[$op] (Win) } | Should -Throw 'fake Hyper-V: the VM service does not answer' -Because $op }
            Get-TestState $t | Should -Be $before
        }

        It 'after the VM is removed deletes the record, and nothing is reported for the VM any more' -Tag detach-removes {
            $t.Vms[$script:WinId] = Off
            $null = & $t.Net.Attach (Win)
            $t.Vms.Remove($script:WinId)
            $out = @(& $t.Net.Detach (Win))
            $out.Count | Should -Be 0
            @(Get-AapFakeHostNetworkRecord -Root $t.Root).Count | Should -Be 0
            @(Get-AapFakeHostNetworkAdapter -Root $t.Root -VmId $script:WinId).Count | Should -Be 0
        }

        It 'succeeds and does nothing for a VM never attached, and on a second call' {
            { & $t.Net.Detach (Win) } | Should -Not -Throw
            $t.Vms[$script:WinId] = Off
            $null = & $t.Net.Attach (Win)
            $t.Vms.Remove($script:WinId)
            & $t.Net.Detach (Win)
            { & $t.Net.Detach (Win) } | Should -Not -Throw
            @(Get-AapFakeHostNetworkRecord -Root $t.Root).Count | Should -Be 0
        }

        It 'removes the record an interrupted Attach left' -Tag detach-removes {
            $t.Vms[$script:WinId] = Off
            Set-AapFakeHostNetworkKnob -Root $t.Root -Fail AttachAfterIntent
            { & $t.Net.Attach (Win) } | Should -Throw
            Set-AapFakeHostNetworkKnob -Root $t.Root
            $t.Vms.Remove($script:WinId)
            & $t.Net.Detach (Win)
            @(Get-AapFakeHostNetworkRecord -Root $t.Root).Count | Should -Be 0
        }

        It 'never frees or reuses a live VM''s address in a crash window: Attach after its intent record, Detach after the released list' -Tag attach-exhausted {
            # Every address but .2 and .3 held, so the next Attach takes whatever is not held: only the record keeps .2 back.
            foreach ($i in 4..254) { Write-TestRecord $t ([guid]::NewGuid().ToString()) "aap-w-1-$i-0a0b0c0d" "172.31.250.$i" }
            $t.Vms[$script:WinId] = Off; $t.Vms[$script:WinId2] = Off; $t.Vms[$script:WinId3] = Off
            $w2 = Win 'aap-w-2-4-0f0e0d0c' $script:WinId2; $w3 = Win 'aap-w-3-1-01020304' $script:WinId3
            Set-AapFakeHostNetworkKnob -Root $t.Root -Fail AttachAfterIntent
            { & $t.Net.Attach (Win) } | Should -Throw '*Attach stopped after its intent record*'
            Set-AapFakeHostNetworkKnob -Root $t.Root
            (Get-AapFakeHostNetworkRecord -Root $t.Root -VmId $script:WinId).declaration.address | Should -Be '172.31.250.2'
            (& $t.Net.Attach $w2).address | Should -Be '172.31.250.3'
            { & $t.Net.Attach $w3 } | Should -Throw 'AAP_NetworkUntrusted: no free address on aap-guests-win' -Because 'the intent record holds .2 before any adapter exists'
            $null = & $t.Net.Attach (Win)
            $t.Vms.Remove($script:WinId)
            Set-AapFakeHostNetworkKnob -Root $t.Root -Fail DetachAfterReleased
            { & $t.Net.Detach (Win) } | Should -Throw '*Detach stopped after the released list*'
            Set-AapFakeHostNetworkKnob -Root $t.Root
            @([IO.File]::ReadAllText((Join-Path $t.Root 'released.json')) | ConvertFrom-Json | ForEach-Object { $_ }) | Should -Be @('172.31.250.2')
            (Get-AapFakeHostNetworkRecord -Root $t.Root -VmId $script:WinId).declaration.address | Should -Be '172.31.250.2'
            { & $t.Net.Attach $w3 } | Should -Throw 'AAP_NetworkUntrusted: no free address on aap-guests-win' -Because 'the record still holds .2 though the released list names it'
            & $t.Net.Detach (Win)
            @(Get-AapFakeHostNetworkRecord -Root $t.Root -VmId $script:WinId).Count | Should -Be 0
            (& $t.Net.Attach $w3).address | Should -Be '172.31.250.2'
        }

        It 'refuses a VM id recorded under another name or profile and keeps the record' -Tag detach-same-vm {
            $t.Vms[$script:WinId] = Off
            $null = & $t.Net.Attach (Win)
            $t.Vms.Remove($script:WinId)
            $before = Get-TestState $t
            { & $t.Net.Detach (Win 'aap-wbuild-0123abcd') } | Should -Throw '*is recorded as aap-w-1-3-1a2b3c4d (windows)*'
            Get-TestState $t | Should -Be $before
        }
    }

    Describe 'Verify' {
        BeforeEach {
            $t.Vms[$script:WinId] = Off
            $decl = & $t.Net.Attach (Win)
        }

        It 'reports the tamper <Tamper>' -TestCases @(
            @{ Tamper = 'no-adapter'; Want = @('the VM has 0 network adapters, not 1') }
            @{ Tamper = 'second-adapter'; Want = @('the VM has 2 network adapters, not 1') }
            @{ Tamper = 'external-switch'; Want = @("the adapter is on 'aap-guests-win' (External), not on the internal switch aap-guests-win") }
            @{ Tamper = 'other-switch'; Want = @("the adapter is on 'aap-guests-linux' (Internal), not on the internal switch aap-guests-win") }
            @{ Tamper = 'dhcp-guard-off'; Want = @("DHCP guard is 'Off', not On") }
            @{ Tamper = 'router-guard-off'; Want = @("router guard is 'Off', not On") }
            @{ Tamper = 'mac-spoofing-on'; Want = @("MAC address spoofing is 'On', not Off") }
            @{ Tamper = 'port-mirroring'; Want = @("port mirroring is 'Destination', not None") }
            @{ Tamper = 'vlan-trunk'; Want = @("the VLAN mode is 'Trunk', not Untagged or Access") }
            @{ Tamper = 'storm-limit-off'; Want = @("the storm limit is '0', not 100") }
            @{ Tamper = 'legacy-acl'; Want = @("the adapter has '1' legacy port ACLs, not 0") }
            @{ Tamper = 'foreign-peer'; Want = @('the runner clone shares aap-guests-win with aap-wbuild-0badc0de, not only runner clones of its profile') }
            @{ Tamper = 'drop-fixed-deny'; Want = @('no unscoped Outbound deny for 10.0.0.0/8') }
            @{ Tamper = 'drop-inbound-deny'; Want = @('no unscoped Inbound deny for 10.0.0.0/8') }
            @{ Tamper = 'scoped-deny'; Want = @('no unscoped Inbound deny for 192.168.0.0/16', "no unscoped Inbound deny covers the host's 192.168.1.10/32") }
            @{ Tamper = 'stateful-rule'; Want = @("rule 1 is stateful 'True', not False", 'no unscoped Inbound deny for 10.0.0.0/8') }
            @{ Tamper = 'isolated-rule'; Want = @("rule 1 has isolation id '7', not 0", 'no unscoped Inbound deny for 10.0.0.0/8') }
            @{ Tamper = 'no-source-pin'; Want = @('there are 0 source pins, not 1') }
            @{ Tamper = 'extra-allow'; Want = @('rule 31: the Outbound allow 172.31.250.1/32 is not exactly a declared endpoint') }
            @{ Tamper = 'public-host'; Want = @("the host's 203.0.113.7/32 is public IPv4, outside the enforcement shape: not certified (contract, Limitations)") }) {
            Set-AapFakeHostNetworkKnob -Root $t.Root -Tamper $Tamper
            @(& $t.Net.Verify (Win)) | Should -Be $Want
        }

        It 'reports a source pin that lifts the IPv4 denies' {
            Set-AapFakeHostNetworkKnob -Root $t.Root -Tamper pin-above-deny
            $p = @(& $t.Net.Verify (Win))
            $p | Should -Contain 'no unscoped Outbound deny for 192.168.0.0/16'
            $p | Should -Contain "no unscoped Outbound deny covers the host's 172.31.250.1/32"
        }

        It 'cannot look when host discovery finds <Tamper>' -Tag verify-discovery -TestCases @(@{ Tamper = 'host-empty' }, @{ Tamper = 'host-no-gateway' }, @{ Tamper = 'host-no-lan' }) {
            Set-AapFakeHostNetworkKnob -Root $t.Root -Tamper $Tamper
            { & $t.Net.Verify (Win) } | Should -Throw '*not the gateway 172.31.250.1 and a LAN address: cannot look'
        }

        It 'reports nothing again once a tamper is gone, and never changes the journal' {
            $before = Get-TestState $t
            Set-AapFakeHostNetworkKnob -Root $t.Root -Tamper extra-allow, dhcp-guard-off, public-host
            @(& $t.Net.Verify (Win)).Count | Should -Be 3
            Set-AapFakeHostNetworkKnob -Root $t.Root
            @(& $t.Net.Verify (Win)).Count | Should -Be 0
            Get-TestState $t | Should -Be $before
        }

        It 'reports a VM that is not attached: <Case>' -Tag verify-record -TestCases @(@{ Case = 'never attached' }, @{ Case = 'detached' }) {
            if ($Case -eq 'detached') {
                $t.Vms.Remove($script:WinId)
                & $t.Net.Detach (Win)
                $t.Vms[$script:WinId] = Off
            } else {
                $t.Vms[$script:LinId] = Off
            }
            $q = $(if ($Case -eq 'detached') { Win } else { Lin })
            @(& $t.Net.Verify $q) | Should -Be @("VM $($q.VmId) is not attached")
        }

        It 'reports a VM recorded under another name' -Tag verify-record {
            @(& $t.Net.Verify (Win 'aap-wbuild-0123abcd')) | Should -Be @("VM $($script:WinId) is recorded as aap-w-1-3-1a2b3c4d (windows)")
        }

        It 'cannot look while an adapter of an existing VM has no record (an owner deleted it); removing that VM clears it' -Tag verify-orphan {
            $w2 = Win 'aap-w-2-4-0f0e0d0c' $script:WinId2
            $t.Vms[$script:WinId2] = Off
            $null = & $t.Net.Attach $w2
            Remove-Item -LiteralPath (Join-Path $t.Root "records\$($script:WinId2).json")
            foreach ($w in (Win), $w2) { { & $t.Net.Verify $w } | Should -Throw "AAP_NetworkUntrusted: the adapter aap-guest-$($script:WinId2) of an existing VM has no record*" }
            $t.Vms.Remove($script:WinId2)
            @(& $t.Net.Verify (Win)).Count | Should -Be 0
        }

        It 'reports a VM Hyper-V no longer has' -Tag verify-vm {
            $t.Vms.Remove($script:WinId)
            @(& $t.Net.Verify (Win)) | Should -Be @("VM $($script:WinId) does not exist")
        }

        It 'reports an address another record on the switch holds too' -Tag verify-address {
            Write-TestRecord $t $script:WinId2 'aap-w-2-4-0f0e0d0c' '172.31.250.2'
            @(& $t.Net.Verify (Win)) | Should -Be @('the address 172.31.250.2 is also held by aap-w-2-4-0f0e0d0c')
        }

        It 'gives a consumer''s read-back every tamper but the host''s to reject; Verify reports all of them' -Tag contract {
            foreach ($x in @('no-adapter', 'second-adapter', 'external-switch', 'other-switch', 'dhcp-guard-off', 'router-guard-off', 'mac-spoofing-on', 'port-mirroring',
                    'vlan-trunk', 'storm-limit-off', 'legacy-acl', 'foreign-peer', 'drop-fixed-deny', 'drop-inbound-deny', 'scoped-deny', 'stateful-rule', 'isolated-rule',
                    'no-source-pin', 'pin-above-deny', 'extra-allow')) {
                Set-AapFakeHostNetworkKnob -Root $t.Root -Tamper $x
                @(& $t.Net.Verify (Win)).Count | Should -BeGreaterThan 0 -Because $x
                @(Get-TestReadback $t $decl $script:WinId).Count | Should -BeGreaterThan 0 -Because $x
            }
            Set-AapFakeHostNetworkKnob -Root $t.Root -Tamper public-host
            @(& $t.Net.Verify (Win)).Count | Should -BeGreaterThan 0
            foreach ($x in 'public-host', 'host-empty', 'host-no-gateway', 'host-no-lan') {
                Set-AapFakeHostNetworkKnob -Root $t.Root -Tamper $x
                Get-TestReadback $t $decl $script:WinId | Should -BeNullOrEmpty -Because $x
            }
        }
    }

    Describe 'records, knobs and state' {
        It 'an unreadable record makes all three calls for its VM throw, and it stays: <Case>' -Tag record-readable -TestCases @(
            @{ Case = 'not JSON'; Text = 'not json' }
            @{ Case = 'an unknown state'; Text = '{"schema":1,"kind":"host_network_record","state":"detaching","declaration":{"schema":1,"kind":"host_network_attach","vm_id":"6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b","vm_name":"aap-w-1-3-1a2b3c4d","profile":"windows","subnet":"172.31.250.0/24","gateway":"172.31.250.1","address":"172.31.250.2","resolvers":["192.0.2.53"],"endpoints":[]},"created":[{"kind":"adapter","name":"aap-guest"}]}' }
            @{ Case = 'a switch P19 owns'; Text = '{"schema":1,"kind":"host_network_record","state":"attached","declaration":{"schema":1,"kind":"host_network_attach","vm_id":"6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b","vm_name":"aap-w-1-3-1a2b3c4d","profile":"windows","subnet":"172.31.250.0/24","gateway":"172.31.250.1","address":"172.31.250.2","resolvers":["192.0.2.53"],"endpoints":[]},"created":[{"kind":"adapter","name":"aap-guest-6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b"},{"kind":"switch","name":"aap-guests-win"}]}' }
            @{ Case = 'another VM''s rule'; Text = '{"schema":1,"kind":"host_network_record","state":"attached","declaration":{"schema":1,"kind":"host_network_attach","vm_id":"6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b","vm_name":"aap-w-1-3-1a2b3c4d","profile":"windows","subnet":"172.31.250.0/24","gateway":"172.31.250.1","address":"172.31.250.2","resolvers":["192.0.2.53"],"endpoints":[]},"created":[{"kind":"adapter","name":"aap-guest-6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b"},{"kind":"firewall_rule","name":"aap-guest-block-0b7e5d4c-3a2f-4e1d-9c8b-7a6f5e4d3c2b"}]}' }
            @{ Case = 'a host rule'; Text = '{"schema":1,"kind":"host_network_record","state":"attached","declaration":{"schema":1,"kind":"host_network_attach","vm_id":"6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b","vm_name":"aap-w-1-3-1a2b3c4d","profile":"windows","subnet":"172.31.250.0/24","gateway":"172.31.250.1","address":"172.31.250.2","resolvers":["192.0.2.53"],"endpoints":[]},"created":[{"kind":"adapter","name":"aap-guest-6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b"},{"kind":"firewall_rule","name":"FPS-SMB-In-TCP"}]}' }
            @{ Case = 'a host rule ending in its own id'; Text = '{"schema":1,"kind":"host_network_record","state":"attached","declaration":{"schema":1,"kind":"host_network_attach","vm_id":"6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b","vm_name":"aap-w-1-3-1a2b3c4d","profile":"windows","subnet":"172.31.250.0/24","gateway":"172.31.250.1","address":"172.31.250.2","resolvers":["192.0.2.53"],"endpoints":[]},"created":[{"kind":"adapter","name":"aap-guest-6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b"},{"kind":"firewall_rule","name":"FPS-SMB-In-TCP-6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b"}]}' }
            @{ Case = 'a name a culture compare would match (soft hyphen)'; Text = '{"schema":1,"kind":"host_network_record","state":"attached","declaration":{"schema":1,"kind":"host_network_attach","vm_id":"6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b","vm_name":"aap-w-1-3-1a2b3c4d","profile":"windows","subnet":"172.31.250.0/24","gateway":"172.31.250.1","address":"172.31.250.2","resolvers":["192.0.2.53"],"endpoints":[]},"created":[{"kind":"adapter","name":"aap-guest-6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b\u00ad"}]}' }) {
            $path = Join-Path $t.Root "records\$($script:WinId).json"
            [IO.File]::WriteAllText($path, $Text)
            $t.Vms[$script:WinId] = Off
            foreach ($op in 'Attach', 'Verify') { { & $t.Net[$op] (Win) } | Should -Throw '*the record of VM * is unreadable; it stays for an owner' -Because $op }
            $t.Vms.Remove($script:WinId)
            { & $t.Net.Detach (Win) } | Should -Throw '*is unreadable*'
            [IO.File]::ReadAllText($path) | Should -Be $Text
        }

        It 'an unreadable record of another VM stops every Attach and Verify, not that VM''s Detach' -Tag record-readable {
            $t.Vms[$script:WinId] = Off; $t.Vms[$script:WinId2] = Off
            $null = & $t.Net.Attach (Win)
            [IO.File]::WriteAllText((Join-Path $t.Root "records\$($script:LinId).json"), 'not json')
            { & $t.Net.Attach (Win 'aap-w-2-4-0f0e0d0c' $script:WinId2) } | Should -Throw '*is unreadable*'
            { & $t.Net.Verify (Win) } | Should -Throw '*is unreadable*'
            @(Get-ChildItem -LiteralPath (Join-Path $t.Root 'records') -File).Count | Should -Be 2
            $t.Vms.Remove($script:WinId)
            & $t.Net.Detach (Win)
            @(Get-ChildItem -LiteralPath (Join-Path $t.Root 'records') -File | ForEach-Object { $_.BaseName }) | Should -Be @($script:LinId)
        }

        It 'stops Attach and Detach on an unreadable released.json until the recovery op rebuilds it: <Case>' -Tag released-readable -TestCases @(
            @{ Case = 'torn'; Text = '["172.31.250.2", "172.31' }, @{ Case = 'not a list of addresses'; Text = '[{"address":"172.31.250.2"}]' }, @{ Case = 'a name'; Text = '["gateway"]' }) {
            $t.Vms[$script:WinId] = Off; $t.Vms[$script:WinId2] = Off
            $null = & $t.Net.Attach (Win)
            $path = Join-Path $t.Root 'released.json'
            [IO.File]::WriteAllText($path, $Text)
            { & $t.Net.Attach (Win 'aap-w-2-4-0f0e0d0c' $script:WinId2) } | Should -Throw 'AAP_NetworkUntrusted: released.json is unreadable*'
            @(Get-AapFakeHostNetworkRecord -Root $t.Root -VmId $script:WinId2).Count | Should -Be 0
            { & $t.Net.Attach (Win) } | Should -Throw 'AAP_NetworkUntrusted: released.json is unreadable*' -Because 'a repeated Attach reads it first too'
            { & $t.Net.Detach (Win 'aap-w-3-1-01020304' $script:WinId3) } | Should -Throw 'AAP_NetworkUntrusted: released.json is unreadable*' -Because 'so does a Detach with no record'
            $t.Vms.Remove($script:WinId)
            $before = Get-TestState $t
            { & $t.Net.Detach (Win) } | Should -Throw 'AAP_NetworkUntrusted: released.json is unreadable*'
            Get-TestState $t | Should -Be $before
            @(Get-AapFakeHostNetworkAdapter -Root $t.Root -VmId $script:WinId).Count | Should -Be 1
            [IO.File]::ReadAllText($path) | Should -Be $Text -Because 'nothing rebuilds it but the recovery op'
            Repair-AapFakeHostNetworkReleased -Root $t.Root
            & $t.Net.Detach (Win)
            (& $t.Net.Attach (Win 'aap-w-2-4-0f0e0d0c' $script:WinId2)).address | Should -Be '172.31.250.3'
            @(Get-ChildItem -LiteralPath $t.Root -Filter '*.tmp' -File -Recurse).Count | Should -Be 0
        }

        It 'refuses an unknown tamper or fault name' -Tag knob-names -TestCases @(@{ K = @{ Tamper = 'extra-alow' } }, @{ K = @{ Fail = 'attach' } }) {
            { Set-AapFakeHostNetworkKnob -Root $t.Root @K } | Should -Throw 'fake: unknown tamper or fault:*'
        }

        It 'makes a faulted <Op> throw and change nothing' -TestCases @(@{ Op = 'Attach' }, @{ Op = 'Detach' }, @{ Op = 'Verify' }) {
            $t.Vms[$script:WinId] = Off
            if ($Op -ne 'Attach') { $null = & $t.Net.Attach (Win) }
            if ($Op -eq 'Detach') { $t.Vms.Remove($script:WinId) }
            Set-AapFakeHostNetworkKnob -Root $t.Root -Fail $Op
            $before = Get-TestState $t
            { & $t.Net[$Op] (Win) } | Should -Throw "AAP_NetworkUntrusted: fake: $Op failed"
            Get-TestState $t | Should -Be $before
        }

        It 'keeps all state under -Root: another fake and another process see the same world' {
            $t.Vms[$script:WinId] = Off
            $d = Get-TestJson (& $t.Net.Attach (Win))
            $other = New-AapFakeHostNetwork -Root $t.Root -Vm { param($id) @{ State = 'Off'; Adapters = 0 } }
            Get-TestJson (& $other.Attach (Win)) | Should -Be $d
            $child = Join-Path $t.Root 'child.ps1'
            [IO.File]::WriteAllText($child, @'
param($Module, $Root)
$ErrorActionPreference = 'Stop'
Import-Module $Module
$n = New-AapFakeHostNetwork -Root $Root -Vm { param($id) @{ State = 'Off'; Adapters = 0 } }
$null = & $n.Attach @{ VmId = '0b7e5d4c-3a2f-4e1d-9c8b-7a6f5e4d3c2b'; VmName = 'aap-lbuild-9f8e7d6c'; Profile = 'linux' }
'@)
            & (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $child $script:Module $t.Root
            $LASTEXITCODE | Should -Be 0
            $t.Vms[$script:LinId] = Off
            @(& $t.Net.Verify (Lin)).Count | Should -Be 0
            @(Get-AapFakeHostNetworkRecord -Root $t.Root).Count | Should -Be 2
        }
    }

    Describe 'antivirus hygiene' {
        It '<_.Name> compiles and holds no expression invocation, encoded command, base64 blob or SecureString marshaling' -ForEach @(
            Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object { $_.Extension -in '.ps1', '.psm1' }) {
            $text = [IO.File]::ReadAllText($_.FullName)
            $text | Should -Not -Match 'Invoke-Expressio[n]|\bie[x]\b|-EncodedComman[d]|FromBase64Strin[g]|SecureStringToBST[R]|PtrToStringBST[R]|PtrToStringAut[o]'
            $text | Should -Not -Match '[A-Za-z0-9+/]{120,}={0,2}'
            { [void][scriptblock]::Create($text) } | Should -Not -Throw
        }
    }
}
