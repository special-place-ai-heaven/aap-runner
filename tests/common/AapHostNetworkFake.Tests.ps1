# The shared strict fake of the P10.0 host network module (AapHostNetworkFake.psm1) against
# parity/contracts/host-network-module.md. Pester 5 on Windows PowerShell 5.1 and PowerShell 7; python 3 on PATH (the
# fake's documents must pass parity/contracts/validate.py). Tags name the fake's check each test guards;
# Invoke-AapHostNetworkFakeMutations.ps1 disables each check in turn and requires its tagged tests to fail.

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:Module = $(if ($env:AAP_NETFAKE_MODULE) { $env:AAP_NETFAKE_MODULE } else { Join-Path $PSScriptRoot 'AapHostNetworkFake.psm1' })
    Import-Module $script:Module -Force
    $script:Validator = Join-Path $script:Repo 'parity\contracts\validate.py'
    $script:WinId = '6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b'
    $script:LinId = '0b7e5d4c-3a2f-4e1d-9c8b-7a6f5e4d3c2b'

    # A fresh fake host under TEMP. Vms is what Hyper-V has; the hook reads the same hashtable the test changes.
    function New-TestNet {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('aap-netfake-' + [guid]::NewGuid().ToString('n').Substring(0, 10))
        $vms = @{}
        $net = New-AapFakeHostNetwork -Root $root -VmExists { param($id) $vms.ContainsKey($id) }.GetNewClosure()
        [pscustomobject]@{ Root = $root; Vms = $vms; Net = $net }
    }
    function Win([string]$Name = 'aap-w-1-3-1a2b3c4d') { @{ VmId = $script:WinId; VmName = $Name; Profile = 'windows' } }
    function Lin { @{ VmId = $script:LinId; VmName = 'aap-lbuild-9f8e7d6c'; Profile = 'linux' } }
    function Get-TestJson($o) { ConvertTo-Json -InputObject $o -Depth 8 -Compress }
    # The journal as it is on disk: each record file with its hash.
    function Get-TestState($t) {
        @(Get-ChildItem -LiteralPath (Join-Path $t.Root 'records') -File | Sort-Object Name | ForEach-Object { "$($_.Name)=$((Get-FileHash -LiteralPath $_.FullName).Hash)" }) -join ';'
    }
    function Get-TestReadback($t, $Declaration, [string]$VmId) {
        @{ schema = 1; kind = 'host_network_readback'; declaration = $Declaration; adapters = @(Get-AapFakeHostNetworkAdapter -Root $t.Root -VmId $VmId) }
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
        It 'returns the declaration and leaves one adapter exactly as the contract requires' {
            $t.Vms[$script:WinId] = $true
            $d = & $t.Net.Attach (Win)
            $d.vm_id | Should -Be $script:WinId
            $d.vm_name | Should -Be 'aap-w-1-3-1a2b3c4d'
            $d.profile | Should -Be 'windows'
            $d.subnet | Should -Be '172.31.250.0/24'
            @($d.endpoints | ForEach-Object { "$($_.role)=$($_.address)" }) | Should -Be @('gateway=172.31.250.1', 'dhcp=172.31.250.1', 'dns=172.31.250.1')
            $nics = @(Get-AapFakeHostNetworkAdapter -Root $t.Root -VmId $script:WinId)
            $nics.Count | Should -Be 1
            $nics[0].SwitchName | Should -Be 'aap-guests-win'
            $nics[0].SwitchType | Should -Be 'Internal'
            @($nics[0].DhcpGuard, $nics[0].RouterGuard, $nics[0].MacAddressSpoofing) | Should -Be @($true, $true, $false)
            @($nics[0].Acls | Where-Object { $_.Action -eq 'Allow' } | ForEach-Object { "$($_.RemoteAddress)@$($_.Weight)" }) | Should -Be @('172.31.250.1@100')
            @($nics[0].Acls | Where-Object { $_.Action -eq 'Deny' -and ($_.Weight -ne 10 -or $_.Scoped -or $_.Direction -ne 'Outbound') }).Count | Should -Be 0
            @(& $t.Net.Verify (Win)).Count | Should -Be 0
            @(Get-AapFakeHostNetworkRecord -Root $t.Root | ForEach-Object { $_.state }) | Should -Be @('attached')
        }

        It 'gives the contract validator a declaration, a record and a read-back it accepts, for both profiles' -Tag contract {
            $t.Vms[$script:WinId] = $true; $t.Vms[$script:LinId] = $true
            $w = & $t.Net.Attach (Win)
            $l = & $t.Net.Attach (Lin)
            $docs = @($w, $l, (Get-AapFakeHostNetworkRecord -Root $t.Root -VmId $script:WinId), (Get-TestReadback $t $w $script:WinId), (Get-TestReadback $t $l $script:LinId))
            Test-Contract $t $docs | Should -Be @('ok', 'ok', 'ok', 'ok', 'ok')
        }

        It 'returns the same declaration on a repeated Attach and keeps one record and one adapter' {
            $t.Vms[$script:WinId] = $true
            $first = Get-TestJson (& $t.Net.Attach (Win))
            Get-TestJson (& $t.Net.Attach (Win)) | Should -Be $first
            @(Get-AapFakeHostNetworkRecord -Root $t.Root).Count | Should -Be 1
            @(Get-AapFakeHostNetworkAdapter -Root $t.Root -VmId $script:WinId).Count | Should -Be 1
        }

        It 'records its intent before it attaches, and a retry after that crash finishes with the planned declaration' {
            $t.Vms[$script:WinId] = $true
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

        It 'refuses a VM Hyper-V does not have and records nothing' -Tag attach-vm {
            { & $t.Net.Attach (Win) } | Should -Throw "AAP_NetworkUntrusted: VM $($script:WinId) does not exist"
            @(Get-AapFakeHostNetworkRecord -Root $t.Root).Count | Should -Be 0
        }

        It 'refuses a VM id recorded under another name or profile and keeps the record' -Tag attach-same-vm {
            $t.Vms[$script:WinId] = $true
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
            $t.Vms[$script:WinId] = $true
            foreach ($op in 'Attach', 'Verify') { { & $t.Net[$op] $R } | Should -Throw 'AAP_NetworkUntrusted: the request is not exactly*' -Because $op }
            $t.Vms.Remove($script:WinId)
            { & $t.Net.Detach $R } | Should -Throw 'AAP_NetworkUntrusted: the request is not exactly*'
            @(Get-AapFakeHostNetworkRecord -Root $t.Root).Count | Should -Be 0
        }
    }

    Describe 'Detach' {
        It 'is refused while the VM exists and changes nothing' -Tag detach-order {
            $t.Vms[$script:WinId] = $true
            $null = & $t.Net.Attach (Win)
            $before = Get-TestState $t
            { & $t.Net.Detach (Win) } | Should -Throw '*still exists; remove the VM before Detach'
            Get-TestState $t | Should -Be $before
            @(Get-AapFakeHostNetworkAdapter -Root $t.Root -VmId $script:WinId).Count | Should -Be 1
        }

        It 'after the VM is removed deletes the record, and nothing is reported for the VM any more' -Tag detach-removes {
            $t.Vms[$script:WinId] = $true
            $null = & $t.Net.Attach (Win)
            $t.Vms.Remove($script:WinId)
            $out = @(& $t.Net.Detach (Win))
            $out.Count | Should -Be 0
            @(Get-AapFakeHostNetworkRecord -Root $t.Root).Count | Should -Be 0
            @(Get-AapFakeHostNetworkAdapter -Root $t.Root -VmId $script:WinId).Count | Should -Be 0
        }

        It 'succeeds and does nothing for a VM never attached, and on a second call' {
            { & $t.Net.Detach (Win) } | Should -Not -Throw
            $t.Vms[$script:WinId] = $true
            $null = & $t.Net.Attach (Win)
            $t.Vms.Remove($script:WinId)
            & $t.Net.Detach (Win)
            { & $t.Net.Detach (Win) } | Should -Not -Throw
            @(Get-AapFakeHostNetworkRecord -Root $t.Root).Count | Should -Be 0
        }

        It 'removes the record an interrupted Attach left' -Tag detach-removes {
            $t.Vms[$script:WinId] = $true
            Set-AapFakeHostNetworkKnob -Root $t.Root -Fail AttachAfterIntent
            { & $t.Net.Attach (Win) } | Should -Throw
            Set-AapFakeHostNetworkKnob -Root $t.Root
            $t.Vms.Remove($script:WinId)
            & $t.Net.Detach (Win)
            @(Get-AapFakeHostNetworkRecord -Root $t.Root).Count | Should -Be 0
        }

        It 'refuses a VM id recorded under another name or profile and keeps the record' -Tag detach-same-vm {
            $t.Vms[$script:WinId] = $true
            $null = & $t.Net.Attach (Win)
            $t.Vms.Remove($script:WinId)
            $before = Get-TestState $t
            { & $t.Net.Detach (Win 'aap-wbuild-0123abcd') } | Should -Throw '*is recorded as aap-w-1-3-1a2b3c4d (windows)*'
            Get-TestState $t | Should -Be $before
        }
    }

    Describe 'Verify' {
        BeforeEach {
            $t.Vms[$script:WinId] = $true
            $decl = & $t.Net.Attach (Win)
        }

        It 'reports <Tamper>' -Tag verify-adapter -TestCases @(
            @{ Tamper = 'no-adapter'; Want = 'has 0 network adapters, not 1' }, @{ Tamper = 'second-adapter'; Want = 'has 2 network adapters, not 1' }) {
            Set-AapFakeHostNetworkKnob -Root $t.Root -Tamper $Tamper
            @(& $t.Net.Verify (Win)) | Should -Be @("VM $($script:WinId) $Want")
        }

        It 'reports <Tamper>' -Tag verify-switch -TestCases @(@{ Tamper = 'external-switch' }, @{ Tamper = 'other-switch' }) {
            Set-AapFakeHostNetworkKnob -Root $t.Root -Tamper $Tamper
            @(& $t.Net.Verify (Win)) | Should -Be @('the adapter is not on the internal switch aap-guests-win')
        }

        It 'reports <Tamper>' -Tag verify-guards -TestCases @(@{ Tamper = 'dhcp-guard-off' }, @{ Tamper = 'router-guard-off' }, @{ Tamper = 'mac-spoofing-on' }) {
            Set-AapFakeHostNetworkKnob -Root $t.Root -Tamper $Tamper
            @(& $t.Net.Verify (Win)) | Should -Be @('DHCP guard or router guard is off, or MAC address spoofing is on')
        }

        It 'reports a missing fixed deny' -Tag verify-fixed {
            Set-AapFakeHostNetworkKnob -Root $t.Root -Tamper drop-fixed-deny
            @(& $t.Net.Verify (Win)) | Should -Be @('no unscoped outbound deny for 10.0.0.0/8')
        }

        It 'reports a missing host-specific deny, which only Verify can see' -Tag verify-host {
            Set-AapFakeHostNetworkKnob -Root $t.Root -Tamper drop-host-deny
            @(& $t.Net.Verify (Win)) | Should -Be @("no deny covers the host's 2001:db8:1::/64")
        }

        It 'reports an allow for an address nobody declared' -Tag verify-allow {
            Set-AapFakeHostNetworkKnob -Root $t.Root -Tamper extra-allow
            @(& $t.Net.Verify (Win)) | Should -Be @('allowed 172.31.250.1, 192.168.1.1; declared 172.31.250.1')
        }

        It 'reports an allow that does not outrank every deny' -Tag verify-weight {
            Set-AapFakeHostNetworkKnob -Root $t.Root -Tamper allow-weight
            @(& $t.Net.Verify (Win)) | Should -Be @('an allow rule does not outrank every deny rule')
        }

        It 'reports nothing again once a tamper is gone, and never changes the journal' {
            $before = Get-TestState $t
            Set-AapFakeHostNetworkKnob -Root $t.Root -Tamper extra-allow, dhcp-guard-off, drop-host-deny
            @(& $t.Net.Verify (Win)).Count | Should -Be 3
            Set-AapFakeHostNetworkKnob -Root $t.Root
            @(& $t.Net.Verify (Win)).Count | Should -Be 0
            Get-TestState $t | Should -Be $before
        }

        It 'reports a VM that is not attached: <Case>' -Tag verify-record -TestCases @(@{ Case = 'never attached' }, @{ Case = 'detached' }) {
            if ($Case -eq 'detached') {
                $t.Vms.Remove($script:WinId)
                & $t.Net.Detach (Win)
                $t.Vms[$script:WinId] = $true
            } else {
                $t.Vms[$script:LinId] = $true
            }
            $q = $(if ($Case -eq 'detached') { Win } else { Lin })
            @(& $t.Net.Verify $q) | Should -Be @("VM $($q.VmId) is not attached")
        }

        It 'reports a VM recorded under another name' -Tag verify-record {
            @(& $t.Net.Verify (Win 'aap-wbuild-0123abcd')) | Should -Be @("VM $($script:WinId) is recorded as aap-w-1-3-1a2b3c4d (windows)")
        }

        It 'reports a VM Hyper-V no longer has' -Tag verify-vm {
            $t.Vms.Remove($script:WinId)
            @(& $t.Net.Verify (Win)) | Should -Be @("VM $($script:WinId) does not exist")
        }

        It 'gives the contract''s read-back every tamper but the host-specific deny to reject; Verify reports all of them' -Tag contract {
            $tampers = @('no-adapter', 'second-adapter', 'external-switch', 'other-switch', 'dhcp-guard-off', 'router-guard-off', 'mac-spoofing-on',
                'drop-fixed-deny', 'extra-allow', 'allow-weight', 'drop-host-deny')
            $docs = foreach ($x in $tampers) {
                Set-AapFakeHostNetworkKnob -Root $t.Root -Tamper $x
                @(& $t.Net.Verify (Win)).Count | Should -BeGreaterThan 0 -Because $x
                Get-TestReadback $t $decl $script:WinId
            }
            Test-Contract $t @($docs) | Should -Be @(@('FAIL') * 10 + @('ok'))
        }
    }

    Describe 'records, knobs and state' {
        It 'an unreadable record makes all three calls throw, and it stays: <Case>' -Tag record-readable -TestCases @(
            @{ Case = 'not JSON'; Text = 'not json' }
            @{ Case = 'an unknown state'; Text = '{"schema":1,"kind":"host_network_record","state":"detaching","declaration":{"schema":1,"kind":"host_network_attach","vm_id":"6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b","vm_name":"aap-w-1-3-1a2b3c4d","profile":"windows","subnet":"172.31.250.0/24","endpoints":[{"role":"gateway","address":"172.31.250.1"}]},"created":[{"kind":"adapter","name":"aap-guest"}]}' }) {
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $t.Root 'records')
            $path = Join-Path $t.Root "records\$($script:WinId).json"
            [IO.File]::WriteAllText($path, $Text)
            $t.Vms[$script:WinId] = $true
            foreach ($op in 'Attach', 'Verify') { { & $t.Net[$op] (Win) } | Should -Throw '*the record of VM * is unreadable; it stays for an owner' -Because $op }
            $t.Vms.Remove($script:WinId)
            { & $t.Net.Detach (Win) } | Should -Throw '*is unreadable*'
            [IO.File]::ReadAllText($path) | Should -Be $Text
        }

        It 'refuses an unknown tamper or fault name' -Tag knob-names -TestCases @(@{ K = @{ Tamper = 'extra-alow' } }, @{ K = @{ Fail = 'attach' } }) {
            { Set-AapFakeHostNetworkKnob -Root $t.Root @K } | Should -Throw 'fake: unknown tamper or fault:*'
        }

        It 'makes a faulted <Op> throw and change nothing' -TestCases @(@{ Op = 'Attach' }, @{ Op = 'Detach' }, @{ Op = 'Verify' }) {
            $t.Vms[$script:WinId] = $true
            if ($Op -ne 'Attach') { $null = & $t.Net.Attach (Win) }
            if ($Op -eq 'Detach') { $t.Vms.Remove($script:WinId) }
            Set-AapFakeHostNetworkKnob -Root $t.Root -Fail $Op
            $before = Get-TestState $t
            { & $t.Net[$Op] (Win) } | Should -Throw "AAP_NetworkUntrusted: fake: $Op failed"
            Get-TestState $t | Should -Be $before
        }

        It 'keeps all state under -Root: another fake and another process see the same world' {
            $t.Vms[$script:WinId] = $true
            $d = Get-TestJson (& $t.Net.Attach (Win))
            $other = New-AapFakeHostNetwork -Root $t.Root -VmExists { param($id) $true }
            Get-TestJson (& $other.Attach (Win)) | Should -Be $d
            $child = Join-Path $t.Root 'child.ps1'
            [IO.File]::WriteAllText($child, @'
param($Module, $Root)
$ErrorActionPreference = 'Stop'
Import-Module $Module
$n = New-AapFakeHostNetwork -Root $Root -VmExists { param($id) $true }
$null = & $n.Attach @{ VmId = '0b7e5d4c-3a2f-4e1d-9c8b-7a6f5e4d3c2b'; VmName = 'aap-lbuild-9f8e7d6c'; Profile = 'linux' }
'@)
            & (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $child $script:Module $t.Root
            $LASTEXITCODE | Should -Be 0
            $t.Vms[$script:LinId] = $true
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
