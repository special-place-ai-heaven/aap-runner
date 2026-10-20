# No secret anywhere, and PowerShell that real-time antivirus does not take for obfuscation (tests/broker/README.md):
# after a full lifecycle no file holds the per-clone password or any JIT config, the JIT config reaches the transport
# only as a stream writer, and the sources hold no Invoke-Expression, encoded command, base64 blob or SecureString
# marshaling, and compile clean (AMSI scans every compiled block). Pester 5, Windows PowerShell 5.1 and PowerShell 7.5+.

BeforeDiscovery {
    $script:Sources = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..\..\..\supervisor\backends\windows'), $PSScriptRoot -File |
            Where-Object { $_.Extension -in '.ps1', '.psm1' -and $_.Name -ne 'Hygiene.Tests.ps1' })
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'WinBackendTestHelpers.ps1')
    Import-Module $script:CapModule -Force
    Import-Module $script:BackendModule -Force
    $script:Files = @(Get-ChildItem -LiteralPath (Join-Path $script:Repo 'supervisor\backends\windows'), $PSScriptRoot -File |
            Where-Object { $_.Extension -in '.ps1', '.psm1' -and $_.Name -ne 'Hygiene.Tests.ps1' })
}

Describe 'no secret anywhere' {
    It 'after a full job no file holds the password or a JIT config, and the transport never sees the JIT as text' {
        $w = New-WinWorld
        $seen = New-Object Collections.Generic.List[string]
        $guest = New-WinGuest
        $spy = { param($Call) foreach ($k in @($Call.Keys)) { if ($Call[$k] -is [string]) { $seen.Add($Call[$k]) } }; & $guest $Call }.GetNewClosure()
        $B = New-AapWinBackend -Provider (New-WinProvider) -Network (New-WinNetwork) -Transport $spy -BrokerInvoker (New-WinBroker) -AllocatorRoot $w.Cap `
            -JournalRoot $w.Journal -StoragePath $w.StoragePath -LockTimeoutSeconds 5 -RelaxedTrustForTests -WarningAction SilentlyContinue -Sleep { param($s) }
        $r = New-WinReservation $w
        $rid = $r.reservation_id
        [void](Invoke-WinSteps $B $w $rid -Max 5 -Until { param($x) $x.state -eq 'ready' })
        $secret = $B.Guests[$rid].Password
        $secret.Length | Should -Be 32
        "$secret" | Should -Be '@{Length=32}'
        $pw = [Text.Encoding]::ASCII.GetString((Get-WinSecretBytes $secret))
        [void](Invoke-AapWinStep -Backend $B -Reservation (Get-WinRes $w $rid))
        Set-WinKnob $w @{ RunnerStatus = 'absent' }
        [void](Invoke-WinSteps $B $w $rid -Max 4)
        (Get-WinRes $w $rid).state | Should -Be 'reconciled'
        $B.Guests.ContainsKey($rid) | Should -BeFalse   # the credential died with the clone
        Find-WinSecret $w @($pw, 'SYNTHETIC-JIT-MARKER') | Should -BeNullOrEmpty
        @($seen | Where-Object { $_ -like '*SYNTHETIC-JIT-MARKER*' }).Count | Should -Be 0
        @($seen | Where-Object { $_ -like '*"cmd":"deliver_registration"*' }).Count | Should -Be 1
        # The guest got exactly the issued JIT config's bytes.
        $g = @(Get-ChildItem -LiteralPath (Join-Path $w.Fake 'guests'))[0]
        (Read-WinJson $g.FullName $null).PayloadSha | Should -Be (@(Get-WinLeases $w))[0].jit_sha
    }

    It 'never gives the password, the answer file or their bytes to a command as a parameter value' {
        # Module logging (event 4103) records the parameter values of every command a module runs. The variables that
        # hold password text or answer-file bytes are read by .NET calls only; the password itself travels as an object
        # whose only property is Length.
        $held = @('pwBytes', 'pwText', 'password', 'xml', 'xmlBytes', 'buf')
        $found = New-Object Collections.Generic.List[string]
        $total = 0
        foreach ($name in 'AapWinBackend.psm1', 'AapWinBackend.HyperV.psm1', 'psdirect-call.ps1') {
            $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Repo "supervisor\backends\windows\$name"), [ref]$null, [ref]$null)
            $commands = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true))
            $total += $commands.Count
            foreach ($c in $commands) {
                foreach ($e in @($c.CommandElements | Select-Object -Skip 1)) {
                    $uses = @($e.FindAll({ param($n) $n -is [Management.Automation.Language.VariableExpressionAst] -and $held -contains $n.VariablePath.UserPath }, $true))
                    if ($uses.Count) { $found.Add(('{0} line {1}: {2}' -f $name, $c.Extent.StartLineNumber, $c.Extent.Text)) }
                }
            }
            foreach ($p in @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.ParameterAst] }, $true))) {
                if ($p.Name.VariablePath.UserPath -match '^(Password|Bytes)$' -and @($p.Attributes | Where-Object { $_.TypeName.Name -match '^(string|byte\[\])$' }).Count) {
                    $found.Add(('{0}: parameter {1} is typed {2}' -f $name, $p.Name, $p.StaticType))
                }
            }
        }
        $total | Should -BeGreaterThan 50
        $found.ToArray() | Should -BeNullOrEmpty
    }

    It 'no source holds a token-shaped or key-shaped value' {
        $script:Files.Count | Should -BeGreaterThan 8
        foreach ($f in $script:Files) {
            [IO.File]::ReadAllText($f.FullName) | Should -Not -Match 'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN [A-Z ]*PRIVATE KE[Y]-----' -Because $f.Name
        }
    }
}

Describe 'antivirus hygiene' {
    It '<_.Name> uses no Invoke-Expression, encoded command, base64 or SecureString marshaling' -ForEach $script:Sources {
        $t = [IO.File]::ReadAllText($_.FullName)
        $t | Should -Not -Match 'Invoke-Expressio[n]|\bie[x]\b|-EncodedComman[d]|FromBase64Strin[g]|SecureStringToBST[R]|PtrToStringBST[R]|PtrToStringAut[o]'
        $t | Should -Not -Match '[A-Za-z0-9+/]{120,}={0,2}'
    }

    It '<_.Name> and each of its functions compile (AMSI scans every compiled block)' -ForEach $script:Sources {
        $t = [IO.File]::ReadAllText($_.FullName)
        { [void][scriptblock]::Create($t) } | Should -Not -Throw
        $ast = [Management.Automation.Language.Parser]::ParseInput($t, [ref]$null, [ref]$null)
        foreach ($fn in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            { [void][scriptblock]::Create($fn.Extent.Text) } | Should -Not -Throw -Because $fn.Name
        }
    }

    It 'every child the backend starts is hidden and gets no data on its command line' {
        $t = [IO.File]::ReadAllText((Join-Path $script:Repo 'supervisor\backends\windows\AapWinBackend.psm1'))
        $t | Should -Match '\$psi\.CreateNoWindow = \$true'
        $t | Should -Match ([regex]::Escape("`$psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"{0}`"' -f `$script:ChildScript"))
        $t | Should -Not -Match 'Invoke-Command'
        [IO.File]::ReadAllText((Join-Path $script:Repo 'supervisor\backends\windows\psdirect-call.ps1')) | Should -Not -Match 'ArgumentList|Invoke-Command'
    }
}
