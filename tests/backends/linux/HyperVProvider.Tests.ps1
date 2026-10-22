# The production provider's ssh-keygen start (AapLinBackend.HyperV.psm1, NewKeyPair), run against a harmless stand-in for
# ssh-keygen: it reads its stdin and records only how many bytes arrived, writes the two key files and exits. Every case runs
# the provider in a process of its own (Invoke-LinHosted) so the console is the case's own: Windows PowerShell 5.1 writes
# the console input encoding's preamble into a redirected stdin pipe at Process.Start, so ssh-keygen would read EF BB BF
# before the EOF of the empty stdin it is meant to get; the provider starts it under a preamble-free encoding, puts the
# caller's back whatever Start does, and serialises the swap with the other starters of the process. Pester 5, Windows
# PowerShell 5.1 and PowerShell 7.5+.

BeforeAll {
    . (Join-Path $PSScriptRoot 'LinBackendTestHelpers.ps1')
    $script:HvModule = Join-Path (Split-Path -Parent $script:BackendModule) 'AapLinBackend.HyperV.psm1'
    $script:Kg = Join-Path $TestDrive 'keygen'
    $null = New-Item -ItemType Directory -Path $script:Kg
    # The stand-in ssh-keygen: ssh-keygen's command line is fixed (-q -t ed25519 -N "" -C aap-management -f <path>), so it is
    # taken from the process command line as Windows splits it, the way fake-zccache.ps1 takes its arguments.
    [IO.File]::WriteAllText((Join-Path $script:Kg 'fake-ssh-keygen.cmd'),
        "@echo off`r`nset `"PSModulePath=`"`r`n`"$($script:Ps51)`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"%~dp0fake-ssh-keygen.ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n")
    [IO.File]::WriteAllText((Join-Path $script:Kg 'fake-ssh-keygen.ps1'), @'
$ErrorActionPreference = 'Stop'
$all = [Environment]::GetCommandLineArgs()
$i = 1
while ($i -lt $all.Count -and $all[$i] -ne '-File') { $i++ }
$argv = @($all | Select-Object -Skip ($i + 2))
$f = $argv[[array]::IndexOf([string[]]$argv, '-f') + 1]
$s = [Console]::OpenStandardInput()
$buf = New-Object byte[] 64
$total = 0
while (($n = $s.Read($buf, 0, $buf.Length)) -gt 0) { $total += $n }
[IO.File]::WriteAllText($f + '.stdin-bytes', [string]$total)
[IO.File]::WriteAllText($f, 'FAKE-PRIVATE-KEY')
[IO.File]::WriteAllText($f + '.pub', [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'public-line.txt')))
exit 0
'@, $script:Utf8)
    $script:FakeKeyGen = Join-Path $script:Kg 'fake-ssh-keygen.cmd'
    # An ed25519-shaped line built here, never written as one in a source file (the hygiene test refuses such a value).
    $script:PublicLine = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI' + ('B' * 43)
    [IO.File]::WriteAllText((Join-Path $script:Kg 'public-line.txt'), $script:PublicLine + ' aap-management')
    [IO.File]::WriteAllText((Join-Path $script:Kg 'notaprogram.exe'), 'this is not a program')
    $null = New-Item -ItemType Directory -Path (Join-Path $script:Kg 'adir.exe')
    $script:DriverDir = Join-Path $TestDrive 'drivers'
    # NewKeyPair against $KeyGen: what the console input encoding was, what came back or whether it threw, what it is now.
    $script:KeyDriver = Write-LinDriver $script:DriverDir 'newkeypair.ps1' @'
param([string]$Module, [string]$KeyGen, [string]$Dir)
$ErrorActionPreference = 'Stop'
Import-Module $Module
& (Get-Module AapLinBackend.HyperV) { param($k) $script:KeyGenExe = $k } $KeyGen
$p = New-AapLinHyperVProvider
$b = [Console]::InputEncoding
$key = ''; $threw = $false
try { $key = [string](& $p.NewKeyPair @{ Dir = $Dir }) } catch { $threw = $true }
$a = [Console]::InputEncoding
'before=cp{0}/pre{1} threw={2} key={3} after=cp{4}/pre{5}' -f $b.CodePage, $b.GetPreamble().Length, $threw, $key, $a.CodePage, $a.GetPreamble().Length
'@
    # The same with the console's own code page 437 and its encoding little-endian Unicode (1200, preamble FF FE): the
    # Framework setter leaves the console code page alone for Unicode, so nothing may leave it at UTF-8.
    $script:UnicodeDriver = Write-LinDriver $script:DriverDir 'newkeypair-unicode.ps1' @'
param([string]$Module, [string]$KeyGen, [string]$Dir)
$ErrorActionPreference = 'Stop'
Add-Type -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint GetConsoleCP();' -Name Cp -Namespace AapT
[Console]::InputEncoding = [Text.Encoding]::GetEncoding(437)
[Console]::InputEncoding = [Text.Encoding]::Unicode
Import-Module $Module
& (Get-Module AapLinBackend.HyperV) { param($k) $script:KeyGenExe = $k } $KeyGen
$p = New-AapLinHyperVProvider
$b = [Console]::InputEncoding
$os0 = [AapT.Cp]::GetConsoleCP()
$key = ''; $threw = $false
try { $key = [string](& $p.NewKeyPair @{ Dir = $Dir }) } catch { $threw = $true }
$a = [Console]::InputEncoding
'before=cp{0}/pre{1}/os{2} threw={3} key={4} after=cp{5}/pre{6}/os{7}' -f $b.CodePage, $b.GetPreamble().Length, $os0, $threw, $key, $a.CodePage, $a.GetPreamble().Length, [AapT.Cp]::GetConsoleCP()
'@
    # A poller reads [Console]::InputEncoding as fast as it can while NewKeyPair starts a (real, fast) child 20 times.
    $script:PollDriver = Write-LinDriver $script:DriverDir 'poll.ps1' @'
param([string]$Module, [string]$Dir)
$ErrorActionPreference = 'Stop'
Import-Module $Module
& (Get-Module AapLinBackend.HyperV) { param($k) $script:KeyGenExe = $k } (Join-Path $env:SystemRoot 'System32\find.exe')
$p = New-AapLinHyperVProvider
$state = [hashtable]::Synchronized(@{ Stop = $false; Temp = 0; Samples = 0 })
$poll = [powershell]::Create()
[void]$poll.AddScript({ param($s) while (-not $s.Stop) { $s.Samples++; if ([Console]::InputEncoding.GetPreamble().Length -eq 0) { $s.Temp++ } } }).AddArgument($state)
$h = $poll.BeginInvoke()
Start-Sleep -Milliseconds 500
foreach ($i in 1..20) { try { $null = & $p.NewKeyPair @{ Dir = $Dir } } catch { $null = $_ } }
$state.Stop = $true
[void]$poll.EndInvoke($h)
$poll.Dispose()
'polled={0} temporary={1}' -f $(if ($state.Samples -ge 1000) { 'enough' } else { 'too-few' }), $state.Temp
'@
    # This thread holds the mutex the starters of a process share while a second runspace calls NewKeyPair.
    $script:WaitDriver = Write-LinDriver $script:DriverDir 'wait.ps1' @'
param([string]$Module, [string]$Dir)
$ErrorActionPreference = 'Stop'
$state = [hashtable]::Synchronized(@{ Ready = $false; Started = 0L })
$lock = New-Object Threading.Mutex($false, ('Local\AapConsoleInputEncoding-' + $PID))
[void]$lock.WaitOne()
$ps = [powershell]::Create()
[void]$ps.AddScript({ param($Module, $State)
        Import-Module $Module
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = Join-Path $env:SystemRoot 'System32\find.exe'; $psi.Arguments = '/c /v ""'
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $State.Ready = $true   # imported: the next thing it does is start a child
        $p = & (Get-Module AapLinBackend.HyperV) { param($x) Start-AapLinHvProcess $x } $psi
        $State.Started = [DateTime]::UtcNow.Ticks   # the child is started: the critical section has been entered
        $p.StandardInput.Close(); $null = $p.StandardOutput.ReadToEnd(); [void]$p.WaitForExit(10000); $p.Dispose()
    }).AddArgument($Module).AddArgument($state)
$h = $ps.BeginInvoke()
$until = [DateTime]::UtcNow.AddSeconds(60)
while (-not $state.Ready -and -not $h.IsCompleted -and [DateTime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 50 }
Start-Sleep -Milliseconds 1500
$blocked = -not $h.IsCompleted
$released = [DateTime]::UtcNow.Ticks
$lock.ReleaseMutex()
$finished = $h.AsyncWaitHandle.WaitOne(30000)
$err = ''
if ($finished) { try { $null = $ps.EndInvoke($h) } catch { $err = $_.Exception.Message } }
"blocked=$blocked ordered=$($state.Started -ge $released) finished=$finished err=$err"
'@
    function New-KeyDir { $d = Join-Path $TestDrive ('k' + [guid]::NewGuid().ToString('n').Substring(0, 8)); $null = New-Item -ItemType Directory -Path $d; $d }
}

Describe 'the production provider starts ssh-keygen with an empty stdin and leaves the console input encoding as it found it (P13.5c)' {
    It 'NewKeyPair under <Shell> on the <Con> console: ssh-keygen reads zero stdin bytes, the key comes back, the encoding is as it was' -Tag 'keygen-stdin-bom' -ForEach @(
        @{ Shell = 'powershell'; Con = 'default' }, @{ Shell = 'powershell'; Con = 'utf8' }, @{ Shell = 'pwsh'; Con = 'default' }, @{ Shell = 'pwsh'; Con = 'utf8' }
    ) {
        $dir = New-KeyDir
        $r = Invoke-LinHosted $Shell @($script:KeyDriver, $script:HvModule, $script:FakeKeyGen, $dir) -Utf8Console:($Con -eq 'utf8')
        $r.TimedOut | Should -BeFalse
        $m = [regex]::Match($r.Out.Trim(), '^before=(cp\d+/pre\d) threw=False key=(.*) after=(cp\d+/pre\d)$')
        $m.Success | Should -BeTrue -Because ($r.Out + $r.Err)
        $m.Groups[2].Value | Should -BeExactly $script:PublicLine
        $m.Groups[3].Value | Should -BeExactly $m.Groups[1].Value -Because 'the caller''s encoding is as it was'
        if ($Con -eq 'utf8') { $m.Groups[1].Value | Should -BeExactly 'cp65001/pre3' -Because 'the hosted console is a UTF-8 one' }
        # What the stand-in received, counted by the stand-in: no byte, not even a preamble.
        [IO.File]::ReadAllText((Join-Path $dir 'id_ed25519.stdin-bytes')) | Should -BeExactly '0'
    }

    It 'NewKeyPair on a console whose input encoding is little-endian Unicode (code page 437): ssh-keygen reads zero stdin bytes, Unicode is put back and the console code page stays 437, even after a failed start' -Tag 'keygen-stdin-bom' {
        $dir = New-KeyDir
        $r = Invoke-LinHosted 'powershell' @($script:UnicodeDriver, $script:HvModule, $script:FakeKeyGen, $dir)
        $r.TimedOut | Should -BeFalse
        $r.Out.Trim() | Should -Be ('before=cp1200/pre2/os437 threw=False key=' + $script:PublicLine + ' after=cp1200/pre2/os437') -Because $r.Err
        [IO.File]::ReadAllText((Join-Path $dir 'id_ed25519.stdin-bytes')) | Should -BeExactly '0'
        $r = Invoke-LinHosted 'powershell' @($script:UnicodeDriver, $script:HvModule, (Join-Path $script:Kg 'missing.exe'), (New-KeyDir))
        $r.TimedOut | Should -BeFalse
        $r.Out.Trim() | Should -Be 'before=cp1200/pre2/os437 threw=True key= after=cp1200/pre2/os437' -Because $r.Err
    }

    It 'a start that fails (<Fail>) leaves the console input encoding a Windows PowerShell 5.1 host on a UTF-8 console had' -ForEach @(
        @{ Fail = 'missing.exe' }, @{ Fail = 'notaprogram.exe' }, @{ Fail = 'adir.exe' }
    ) {
        $dir = New-KeyDir
        $r = Invoke-LinHosted 'powershell' @($script:KeyDriver, $script:HvModule, (Join-Path $script:Kg $Fail), $dir) -Utf8Console
        $r.TimedOut | Should -BeFalse
        $r.Out.Trim() | Should -Be 'before=cp65001/pre3 threw=True key= after=cp65001/pre3' -Because $r.Err
    }

    It 'PowerShell 7 starts ssh-keygen without ever swapping the console input encoding' {
        $r = Invoke-LinHosted 'pwsh' @($script:PollDriver, $script:HvModule, (New-KeyDir)) -Utf8Console
        $r.TimedOut | Should -BeFalse
        $r.Out.Trim() | Should -Be 'polled=enough temporary=0' -Because $r.Err
    }

    It 'a start waits while another thread of the process holds the mutex every starter shares' {
        $r = Invoke-LinHosted 'powershell' @($script:WaitDriver, $script:HvModule, (New-KeyDir)) -Utf8Console
        $r.TimedOut | Should -BeFalse
        $r.Out.Trim() | Should -Be 'blocked=True ordered=True finished=True err=' -Because $r.Err
    }
}
