# windows/rust-*: cargo test, release build and run of an offline crate (no crates.io dependencies).
#   -Crate plain: plain job environment. rustc must find the MSVC linker and SDK libraries itself even though the
#                 link.exe first on PATH is Git's coreutils link.
#   -Crate native: developer environment; build.rs compiles C with cl.exe and lib.exe and links it statically.
# Sabotage git-link claims a developer environment without entering one, so the toolchain takes link.exe from PATH
# (Git's). Sabotage no-sdk-lib strips the SDK libraries from the developer environment.
param(
    [Parameter(Mandatory)][string]$Work, [Parameter(Mandatory)][string]$Id, [string]$Sabotage = '',
    [Parameter(Mandatory)][ValidateSet('plain', 'native')][string]$Crate
)
Import-Module (Join-Path $PSScriptRoot '..\Workload.psm1') -Force

Invoke-Workload -Id $Id -Work $Work -Sabotage $Sabotage -Body {
    $env:CARGO_HOME = Join-Path $Work 'cargo-home'  # cargo's caches and locks stay in the work folder
    $env:CARGO_TERM_COLOR = 'never'
    $cargo = Resolve-Exe 'cargo.exe'
    if (-not $cargo) { throw 'cargo.exe not found on PATH' }
    $rustc = Resolve-Exe 'rustc.exe'
    $host_ = (Invoke-Tool $rustc @('-vV') -Quiet).Lines | Where-Object { $_ -like 'host:*' } | Select-Object -First 1
    Add-Fact 'rustc.host' $host_ 'host: x86_64-pc-windows-msvc'
    if ($Crate -eq 'native') {
        Enter-DevEnv -Arch x64 | Out-Null
        Set-DevEnvSabotage $Sabotage
    }
    elseif ($Sabotage -eq 'git-link') {
        $env:VCINSTALLDIR = Join-Path $Work 'no-vs\VC\'
        $env:VSINSTALLDIR = Join-Path $Work 'no-vs\'
        $env:VSCMD_ARG_TGT_ARCH = 'x64'
        Write-Line ('sabotage git-link applied; link.exe on PATH is ' + (Resolve-Exe 'link.exe'))
    }
    $name = "parity_$Crate"
    Copy-Source (Join-Path $PSScriptRoot $Crate) 'crate'
    Set-Location -LiteralPath (Join-Path $Work 'crate')
    $t = Invoke-Tool $cargo @('test', '--offline')
    $sum = @($t.Lines | Where-Object { $_ -match '^test result: ok\. (\d+) passed; (\d+) failed' } | ForEach-Object { "$($Matches[1]) passed, $($Matches[2]) failed" })
    Add-Fact 'cargo.test' ($sum -join '; ') '2 passed, 0 failed'
    Invoke-Tool $cargo @('build', '--release', '--offline') | Out-Null
    $exe = "target\release\$name.exe"
    $out = (Invoke-Tool $exe).Lines -join ' '
    $want = if ($Crate -eq 'plain') { 'hello from rust msvc bits=64 twice=42 threads=ok' } else { 'hello from rust native add=5 cpus=ok' }
    Add-Fact "$name.output" $out $want
    $pe = Get-PeInfo $exe
    Add-Fact "$name.machine" $pe.Machine 'x64'
    Write-Report @("crate=$Crate", "output=$out", "machine=$($pe.Machine)", "subsystem=$($pe.Subsystem)", "tests=$($sum -join '; ')")
}
