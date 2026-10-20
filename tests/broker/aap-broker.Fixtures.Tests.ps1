# Pester 5, Windows PowerShell 5.1 and PowerShell 7. Contract fixtures: the client validator agrees with validate.py.

BeforeAll { . (Join-Path $PSScriptRoot 'BrokerTestHelpers.ps1') }

Describe 'contract fixtures' {
    BeforeEach { Reset-Fake }

    It 'accepts every valid fixture and refuses every invalid one, as validate.py does' {
        $valid = @(Get-ChildItem -LiteralPath (Join-Path $script:Fixtures 'valid') -Filter *.json)
        $invalid = @(Get-ChildItem -LiteralPath (Join-Path $script:Fixtures 'invalid') -Filter *.json)
        $valid.Count | Should -BeGreaterThan 0
        $invalid.Count | Should -BeGreaterThan 2
        foreach ($f in $valid) {
            $doc = ConvertFrom-AapBrokerJson ([IO.File]::ReadAllText($f.FullName))
            $doc | Should -Not -BeNullOrEmpty -Because $f.Name
            Test-AapBrokerDocument $doc | Should -BeNullOrEmpty -Because $f.Name
        }
        foreach ($f in $invalid) {
            $case = ConvertFrom-AapBrokerJson ([IO.File]::ReadAllText($f.FullName))
            $case | Should -Not -BeNullOrEmpty -Because $f.Name
            $why = Test-AapBrokerDocument $case['instance']
            $why | Should -Not -BeNullOrEmpty -Because $f.Name
            # The same reason as validate.py. The client's errors name fields and
            # never quote a value, so the one fixture whose message quotes the
            # value it refuses is matched on the field it names.
            if ($f.Name -ceq 'unknown-profile.json') {
                $case['expect'] | Should -BeExactly 'windows-latest" not in enum'
                $why | Should -BeExactly '$.profile: invalid value' -Because $f.Name
            } else {
                $why | Should -BeLike ('*' + $case['expect'] + '*') -Because $f.Name
            }
        }
    }

    It 'agrees with validate.py itself on the same fixtures' {
        $py = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $py) {
            Set-ItResult -Skipped -Because 'python is not installed'
            return
        }
        $out = & $py.Source -B -I (Join-Path $script:Repo 'parity\contracts\validate.py') 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($out | Out-String)
    }

    It 'refuses what the strict parser must refuse' {
        $deep = '1'
        foreach ($i in 1..5) { $deep = '{"a":' + $deep + '}' }
        $texts = @('', 'null', '[]', '{"a":[1]}', '{"a":1,"a":1}', '{"a":1} x', '{"a":1}{"b":2}', '{"a":NaN}',
            "{`"a`":`"x`ty`"}", '{"a":1,}', '{a:1}', '{"a":01}', $deep, '{"a":"\x"}', '{"a":"\u0041"}')
        foreach ($text in $texts) {
            ConvertFrom-AapBrokerJson $text | Should -BeNullOrEmpty -Because $text
        }
        $d = ConvertFrom-AapBrokerJson '{ "n" : 3 , "f" : 3.0 , "s" : "a\/b\n" , "t" : true , "z" : null , "o" : { "k" : false } }'
        $d['n'] | Should -BeOfType [long]
        $d['f'] | Should -BeOfType [double]
        $d['s'] | Should -BeExactly "a/b`n"
        $d['t'] | Should -BeTrue
        $d['z'] | Should -BeNullOrEmpty
        $d['o']['k'] | Should -BeFalse
        $d.Contains('N') | Should -BeFalse
    }

    It 'refuses wrong case, a trailing newline, a float generation and a request over 4096 bytes' {
        $base = ConvertFrom-AapBrokerJson ([IO.File]::ReadAllText((Join-Path $script:Fixtures 'valid\lease-request.json')))
        Test-AapBrokerDocument $base | Should -BeNullOrEmpty
        $cases = New-Object System.Collections.Generic.List[object]
        $d = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
        foreach ($k in $base.Keys) { if ($k -ceq 'kind') { $d['Kind'] = $base[$k] } else { $d[$k] = $base[$k] } }
        $cases.Add($d)
        $d = Copy-Document $base; $d['lease_id'] = $base['lease_id'] + "`n"; $cases.Add($d)
        $d = Copy-Document $base; $d['lease_id'] = $base['lease_id'].ToUpperInvariant(); $cases.Add($d)
        $d = Copy-Document $base; $d['lease_generation'] = 3.0; $cases.Add($d)
        $d = Copy-Document $base; $d['profile'] = 'WIN25-VS2026-X64'; $cases.Add($d)
        $d = Copy-Document $base; $d['slot'] = $true; $cases.Add($d)
        $d = Copy-Document $base; $d['image_generation'] = $base['image_generation'] + ('9' * 4000); $cases.Add($d)
        $d = Copy-Document $base; $d['image_generation'] = 'ubuntu-24.04-x64/20261007.264.1-aap.1'; $d['profile'] = 'ubuntu-24.04-x64'; $d['issued_at'] = '2026-10-19T18:00:00z'; $cases.Add($d)
        foreach ($c in $cases) {
            Test-AapBrokerDocument $c | Should -Not -BeNullOrEmpty
        }
    }
}
