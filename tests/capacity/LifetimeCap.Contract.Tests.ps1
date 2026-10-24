# The hard VM lifetime cap's contract rules (owner decision Q4; parity/contracts allocator.md, status-settings.md,
# backend-lifecycle.md), through the reference validator. The rules and the fixtures are tested in Python, standard
# library only (tests/parity/contracts/test_lifetime_cap.py); this file runs them where the Pester job runs, on both
# PowerShell hosts, beside validate.py over every fixture. Pester 5, Windows PowerShell 5.1 and PowerShell 7.5+.

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

    # python in isolated mode, as CI runs the validator; stderr is output here, not an error.
    function Invoke-CapPython([string[]]$Arguments) {
        $ErrorActionPreference = 'Continue'
        $out = @(& python -B -I @Arguments 2>&1 | ForEach-Object { "$_" })
        [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n") }
    }
}

Describe 'the VM lifetime cap contract' {
    It 'validate.py passes on every fixture, the cap fixtures included' {
        $r = Invoke-CapPython @((Join-Path $script:Repo 'parity\contracts\validate.py'))
        $r.Code | Should -Be 0 -Because $r.Text
    }

    It 'the cap rules hold at their boundaries and every cap invalid fixture is its valid base plus one defect' {
        $r = Invoke-CapPython @('-m', 'unittest', 'discover', '-s', (Join-Path $script:Repo 'tests\parity\contracts'), '-p', 'test_*.py')
        $r.Code | Should -Be 0 -Because $r.Text
    }
}
