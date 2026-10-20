# No secret anywhere, and PowerShell that real-time antivirus does not take for obfuscation (tests/broker/README.md):
# after a full lifecycle no file holds a JIT config or the per-clone private key, the private key is never read by this
# code at all (ssh-keygen writes it, ssh.exe reads it), the JIT config reaches the transport only as a stream writer and is
# never a command's parameter value, and the sources hold no Invoke-Expression, encoded command, base64 blob or
# SecureString marshaling, and compile clean (AMSI scans every compiled block). Pester 5, Windows PowerShell 5.1 and
# PowerShell 7.5+.

BeforeDiscovery {
    $script:Sources = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..\..\..\supervisor\backends\linux'), $PSScriptRoot -File |
            Where-Object { $_.Extension -in '.ps1', '.psm1' -and $_.Name -ne 'Hygiene.Tests.ps1' })
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'LinBackendTestHelpers.ps1')
    Import-Module $script:CapModule -Force
    Import-Module $script:BackendModule -Force
    $script:Files = @(Get-ChildItem -LiteralPath (Join-Path $script:Repo 'supervisor\backends\linux'), $PSScriptRoot -File |
            Where-Object { $_.Extension -in '.ps1', '.psm1' -and $_.Name -ne 'Hygiene.Tests.ps1' })
    $script:Code = @('AapLinBackend.psm1', 'AapLinBackend.HyperV.psm1', 'hvsock-relay.ps1')
}

Describe 'no secret anywhere' {
    It 'after a full job no file holds a JIT config, the private key is gone with the clone, and the transport never sees the JIT as text' {
        $w = New-LinWorld
        $seen = New-Object Collections.Generic.List[string]
        $guest = New-LinGuest
        $spy = { param($Call) foreach ($k in @($Call.Keys)) { if ($Call[$k] -is [string]) { $seen.Add($Call[$k]) } }; & $guest $Call }.GetNewClosure()
        $B = New-AapLinBackend -Provider (New-LinProvider) -Network (New-LinNetwork) -Transport $spy -BrokerInvoker (New-LinBroker) -AllocatorRoot $w.Cap `
            -JournalRoot $w.Journal -StoragePath $w.StoragePath -LockTimeoutSeconds 5 -RelaxedTrustForTests -WarningAction SilentlyContinue -Sleep { param($s) }
        $r = New-LinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-LinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
        $key = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes((Join-Path $w.Clones "$rid\ssh\id_ed25519")))
        $key | Should -BeLike 'FAKE-PRIVATE-KEY-*'
        Find-LinSecret $w @($key) | Should -BeNullOrEmpty   # only in its own folder
        [void](Invoke-AapLinStep -Backend $B -Reservation (Get-LinRes $w $rid))
        Set-LinKnob $w @{ RunnerStatus = 'absent' }
        [void](Invoke-LinSteps $B $w $rid -Max 4)
        (Get-LinRes $w $rid).state | Should -Be 'reconciled'
        $B.Guests.ContainsKey($rid) | Should -BeFalse   # the channel died with the clone
        Find-LinSecret $w @($key, 'SYNTHETIC-JIT-MARKER') -All | Should -BeNullOrEmpty
        @($seen | Where-Object { $_ -like '*SYNTHETIC-JIT-MARKER*' -or $_ -like '*FAKE-PRIVATE-KEY*' }).Count | Should -Be 0
        @($seen | Where-Object { $_ -like '*"cmd":"deliver_registration"*' }).Count | Should -Be 1
        # The guest got exactly the issued JIT config's bytes.
        $g = @(Get-ChildItem -LiteralPath (Join-Path $w.Fake 'guests'))[0]
        (Read-LinJson $g.FullName $null).PayloadSha | Should -Be (@(Get-LinLeases $w))[0].jit_sha
    }

    It 'never reads the private key, and never gives the JIT config to a command as a parameter value but its Length-only object' {
        # Module logging (event 4103) records the parameter values of every command a module runs. The private key file is
        # named only to ssh-keygen (as the -f path) and in ssh_config, never opened here; the JIT config is the broker's
        # object whose only property is Length, written to a stream with WriteTo.
        $found = New-Object Collections.Generic.List[string]
        $total = 0
        foreach ($name in $script:Code) {
            $text = [IO.File]::ReadAllText((Join-Path $script:Repo "supervisor\backends\linux\$name"))
            foreach ($line in ($text -split "`n")) {
                if ($line -match 'id_ed25519' -and $line -notmatch 'id_ed25519\.pub' -and $line -match 'Read|Open|Get-Content|\[IO\.File\]::(?!Exists)') { $found.Add("$name reads the private key: $($line.Trim())") }
            }
            $ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null)
            $commands = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true))
            $total += $commands.Count
            foreach ($c in $commands) {
                foreach ($e in @($c.CommandElements | Select-Object -Skip 1)) {
                    $uses = @($e.FindAll({ param($n) $n -is [Management.Automation.Language.MemberExpressionAst] -and $n.Member.Extent.Text -eq 'JitConfig' }, $true))
                    if ($uses.Count) { $found.Add(('{0} line {1}: {2}' -f $name, $c.Extent.StartLineNumber, $c.Extent.Text)) }
                }
            }
            foreach ($p in @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.ParameterAst] }, $true))) {
                if ($p.Name.VariablePath.UserPath -match '^(Jit|Key|Secret|Password|Bytes)$' -and @($p.Attributes | Where-Object { $_.TypeName.Name -match '^(string|byte\[\])$' }).Count) {
                    $found.Add(('{0}: parameter {1} is typed {2}' -f $name, $p.Name, $p.StaticType))
                }
            }
        }
        $total | Should -BeGreaterThan 50
        $found.ToArray() | Should -BeNullOrEmpty
        # The one place the JIT object is handed on: Invoke-AapLinCommand's -Jit, written only inside the transport's stream writer.
        $mod = [IO.File]::ReadAllText((Join-Path $script:Repo 'supervisor\backends\linux\AapLinBackend.psm1'))
        @([regex]::Matches($mod, '\$Jit\.WriteTo\(')).Count | Should -Be 1
        $mod | Should -Match ([regex]::Escape('$call.WritePayload = { param([IO.Stream]$Stream) $Jit.WriteTo($Stream) }.GetNewClosure()'))
    }

    It 'no source holds a token-shaped or key-shaped value' {
        $script:Files.Count | Should -BeGreaterThan 8
        foreach ($f in $script:Files) {
            [IO.File]::ReadAllText($f.FullName) | Should -Not -Match 'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN [A-Z ]*PRIVATE KE[Y]-----|AAAAC3NzaC1lZDI1NTE5AAAAI[A-Za-z0-9+/]{43}' -Because $f.Name
        }
    }
}

Describe 'antivirus hygiene' {
    It '<_.Name> uses no Invoke-Expression, encoded command, base64 decoding or SecureString marshaling' -ForEach $script:Sources {
        $t = [IO.File]::ReadAllText($_.FullName)
        $t | Should -Not -Match 'Invoke-Expressio[n]|\bie[x]\b|-EncodedComman[d]|FromBase64Strin[g]|SecureStringToBST[R]|PtrToStringBST[R]|PtrToStringAut[o]|AsPlainTex[t]|\[char\]\s*\d|-join\s*\(\s*\d+\s*,'
        $t | Should -Not -Match '[A-Za-z0-9+/]{120,}={0,2}'
    }

    It '<_.Name> and each of its functions compile (AMSI scans every compiled block)' -ForEach $script:Sources {
        $t = [IO.File]::ReadAllText($_.FullName)
        { [void][scriptblock]::Create($t) } | Should -Not -Throw
        $ast = [Management.Automation.Language.Parser]::ParseInput($t, [ref]$null, [ref]$null)
        # Functions only; class methods compile with their class, in the whole-file block above.
        $fns = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and -not ($n.Parent -is [Management.Automation.Language.FunctionMemberAst]) }, $true)
        foreach ($fn in $fns) {
            { [void][scriptblock]::Create($fn.Extent.Text) } | Should -Not -Throw -Because $fn.Name
        }
    }

    It 'every child the backend starts is hidden and gets no data on its command line' {
        $t = [IO.File]::ReadAllText((Join-Path $script:Repo 'supervisor\backends\linux\AapLinBackend.psm1'))
        $t | Should -Match '\$psi\.CreateNoWindow = \$true'
        $t | Should -Match ([regex]::Escape("`$script:ChildArgs = '-F `"{0}`" -T aap-guest'"))
        $t | Should -Match ([regex]::Escape('$psi.Arguments = $script:ChildArgs -f $Call.Config'))
        $t | Should -Not -Match 'Invoke-Command|Start-Process'
        $p = [IO.File]::ReadAllText((Join-Path $script:Repo 'supervisor\backends\linux\AapLinBackend.HyperV.psm1'))
        $p | Should -Match '\$psi\.CreateNoWindow = \$true'
        $p | Should -Not -Match 'Invoke-Command|Start-Process'
    }

    It 'Add-Type compiles only in New-AapLinBackend, with %TMP% at the admin-only compile folder' {
        foreach ($name in $script:Code) {
            $t = [IO.File]::ReadAllText((Join-Path $script:Repo "supervisor\backends\linux\$name"))
            $ast = [Management.Automation.Language.Parser]::ParseInput($t, [ref]$null, [ref]$null)
            $n = @($ast.FindAll({ param($x) $x -is [Management.Automation.Language.CommandAst] -and $x.GetCommandName() -eq 'Add-Type' }, $true)).Count
            if ($name -eq 'AapLinBackend.psm1') { $n | Should -Be 1 } else { $n | Should -Be 0 -Because $name }
        }
        $t = [IO.File]::ReadAllText((Join-Path $script:Repo 'supervisor\backends\linux\AapLinBackend.psm1'))
        $t | Should -Match ([regex]::Escape('try { $env:TMP = $compile; $env:TEMP = $compile; Add-Type -TypeDefinition $script:TypeSource }'))
    }
}
