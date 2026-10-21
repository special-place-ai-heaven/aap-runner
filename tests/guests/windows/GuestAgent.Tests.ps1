# P14 Windows guest agent and bootstrap, run against fakes: a temp folder stands in for C:\Windows, C:\, D:\ and
# C:\Program Files\aap-guest, and scriptblocks stand in for the registry, disks, the scheduled task, Runner.Listener and
# zccache. Every reply goes through the host's own check (Test-AapWinReply in supervisor\backends\windows). No VM, no
# Hyper-V, no network. Pester 5, Windows PowerShell 5.1 and 7. Tags name the '# check:' a test covers;
# Invoke-AapGuestMutations.ps1 runs only the tagged tests against a copy of guests\windows with that check broken
# (AAP_GUEST_SRC).

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
    $script:Src = $(if ($env:AAP_GUEST_SRC) { $env:AAP_GUEST_SRC } else { Join-Path $script:Repo 'guests\windows' })
    Import-Module (Join-Path $script:Src 'AapGuestAgent.psm1') -Force
    Import-Module (Join-Path $script:Repo 'supervisor\backends\windows\AapWinBackend.psm1') -Force
    $script:VmId = '6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b'
    # A synthetic JIT config: base64 text whose decoded form carries the lab marker; the encoded text is what must never
    # leave the runner root and the runner's environment.
    $script:Jit = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('SYNTHETIC-JIT-MARKER-' + [guid]::NewGuid().ToString('n') + '-padding-padding'))
    $script:JitBytes = [Text.Encoding]::ASCII.GetBytes($script:Jit)

    function New-Hex([int]$Bytes) { -join (1..$Bytes | ForEach-Object { '{0:x2}' -f (Get-Random -Maximum 256) }) }
    function Format-Time([datetime]$T) { $T.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture) }

    # One fresh guest: folders, the world the fakes read ($w) and the agent context over them.
    function New-Guest {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 8))
        $d = @{}
        foreach ($n in 'install\runner\bin', 'state', 'win\Panther', 'win\Panther\UnattendGC', 'win\System32\Sysprep', 'sys', 'scratch', 'toolcache\Python\3.12.10\x64', 'bin-clean', 'bin-msvc') {
            $d[$n] = Join-Path $root $n
            [void][IO.Directory]::CreateDirectory($d[$n])
        }
        [IO.File]::WriteAllText((Join-Path $d['install\runner\bin'] 'Runner.Listener.exe'), 'listener')
        [IO.File]::WriteAllText((Join-Path $root 'install\runner\config.cmd'), 'config')
        [IO.File]::WriteAllText((Join-Path $d['win\Panther'] 'unattend.xml'), '<Password>per-clone</Password>')
        [IO.File]::WriteAllText((Join-Path $d['win\Panther\UnattendGC'] 'setupact.log'), 'log')
        [IO.File]::WriteAllText((Join-Path $d['bin-clean'] 'link.exe'), 'git link')
        [IO.File]::WriteAllText((Join-Path $d['bin-msvc'] 'cl.exe'), 'cl')
        $w = @{
            Root = $root; Dirs = $d; VmId = $script:VmId; Setup = $true; Identity = @{ Name = 'WIN-AAP\runneradmin'; IsAdmin = $true }
            Machine = @{ ImageOS = 'win25-vs2026'; ImageVersion = '20261007.264.1'; AGENT_TOOLSDIRECTORY = (Join-Path $root 'toolcache'); Path = $d['bin-clean'] + ';%SystemRoot%\system32'
                PSModulePath = 'C:\Program Files\WindowsPowerShell\Modules;C:\Windows\system32\WindowsPowerShell\v1.0\Modules' }
            User = @{ Path = '' }; Volume = $null; Disks = @(@{ Number = 1; Style = 'RAW'; Data = 0 }); Formatted = 0; FormattedNumber = $null
            Launcher = 'run'; Started = $null; Alive = $true; Worker = $false; ExitCode = 0; Psi = $null
            CacheThrows = $false; CacheSawJit = $null; CacheSawEnv = $null; CacheEnv = "AAP_ZC_STATE=D:\aap-cache\state\config.json`nCMAKE_C_COMPILER_LAUNCHER=pwsh.exe;-File;zcshim.ps1`nACTIONS_RUNNER_INPUT_EVIL=1`nlower=1`n"
            Shutdowns = 0; LauncherStarts = 0; Now = $null; Seq = 0
        }
        $scratch = $d['scratch']
        $mod = Get-Module AapGuestAgent
        $ops = @{
            VmId = { $w.VmId }.GetNewClosure()
            SetupComplete = { $w.Setup }.GetNewClosure()
            Identity = { $w.Identity }.GetNewClosure()
            Env = { param($Scope) if ($Scope -eq 'Machine') { $w.Machine } else { $w.User } }.GetNewClosure()
            ScratchVolume = { $w.Volume }.GetNewClosure()
            ScratchDisks = { $w.Disks }.GetNewClosure()
            FormatScratch = { param($n) $w.Formatted++; $w.FormattedNumber = $n; $w.Volume = @{ FileSystem = 'NTFS'; DriveType = 'Fixed'; Boot = $false; Number = $n } }.GetNewClosure()
            StartLauncher = {
                param($Ctx)
                $w.LauncherStarts++
                if ($w.Launcher -eq 'stuck') {
                    # Took the registration material, then never got the runner going.
                    [IO.File]::Delete((Join-Path $scratch 'actions-runner/.aap-jit'))
                    [IO.File]::WriteAllText((Join-Path $Ctx.StateDir 'launch.json'), '{"phase":"starting"}')
                    return
                }
                if ($w.Launcher -eq 'late') { $w.Now = [DateTime]::UtcNow.AddMinutes(5) }
                if ($w.Launcher -eq 'fake-running') {
                    [IO.File]::WriteAllText((Join-Path $Ctx.StateDir 'launch.json'), '{"phase":"running","runner_pid":4242,"runner_start":99}')
                    return
                }
                $w.Started = & $mod { param($c) Start-AapGuestRunner -Ctx $c } $Ctx
            }.GetNewClosure()
            Process = { param($Id) if ($w.Alive -and $Id -eq 4242) { @{ Path = (Join-Path $scratch 'actions-runner\bin\Runner.Listener.exe'); StartTicks = 99 } } }.GetNewClosure()
            WorkerRunning = { param($Root) $w.Worker }.GetNewClosure()
            InitCache = {
                param($Ctx)
                $w.CacheSawJit = [IO.File]::Exists((Join-Path $scratch 'actions-runner\.aap-jit'))
                $w.CacheSawEnv = [Environment]::GetEnvironmentVariable('ACTIONS_RUNNER_INPUT_JITCONFIG')
                if ($w.CacheThrows) { throw 'cache broke' }
                [void][IO.Directory]::CreateDirectory((Join-Path $scratch 'aap-cache\state'))
                [IO.File]::WriteAllText((Join-Path $scratch 'aap-cache\state\runner.env'), $w.CacheEnv)
            }.GetNewClosure()
            CacheState = { param($Ctx) [pscustomobject]@{ state = 'qualified'; detail = '2 qualified pairs' } }
            StartRunner = {
                param($Psi)
                $envCopy = @{}
                foreach ($k in $Psi.EnvironmentVariables.Keys) { $envCopy[$k.ToUpperInvariant()] = $Psi.EnvironmentVariables[$k] }
                $w.Psi = @{ File = $Psi.FileName; Arguments = $Psi.Arguments; Dir = $Psi.WorkingDirectory; Shell = $Psi.UseShellExecute; NoWindow = $Psi.CreateNoWindow; Env = $envCopy
                    JitOnDisk = [IO.File]::Exists((Join-Path $scratch 'actions-runner\.aap-jit')) }
                @{ Pid = 4242; StartTicks = 99; Process = $null }
            }.GetNewClosure()
            WaitRunner = { param($Started) $w.ExitCode }.GetNewClosure()
            Shutdown = { $w.Shutdowns++ }.GetNewClosure()
            Now = { if ($w.Now) { $w.Now } else { [DateTime]::UtcNow } }.GetNewClosure()
        }
        $w.Ctx = @{ InstallDir = (Join-Path $root 'install'); StateDir = $d['state']; SystemRoot = (Join-Path $root 'win'); SystemDrive = $d['sys']; Scratch = $scratch
            JobUser = 'runneradmin'; CacheBudgetBytes = 1MB; StartWaitSeconds = 2; PollMilliseconds = 20; Ops = $ops
        }
        $w
    }

    # Sends one command the way psdirect-call.ps1's remote script does (envelope line, newline, payload) and checks the
    # reply with the host's own Test-AapWinReply. $Over replaces envelope fields; $Raw replaces the whole line.
    function Send-Guest($W, [string]$Cmd, [byte[]]$Payload = @(), [hashtable]$Over = @{}, [string]$Raw, [byte[]]$Prefix = @()) {
        $W.Seq++
        $c = [ordered]@{ vm_id = $script:VmId; reservation_id = 'r-00000000000000a1'; lease_generation = 1; seq = $W.Seq; nonce = (New-Hex 16); cmd = $Cmd
            payload_bytes = $Payload.Length; expires_at = (Format-Time ([DateTime]::UtcNow.AddSeconds(60)))
        }
        foreach ($k in $Over.Keys) { $c[$k] = $Over[$k] }
        $doc = [ordered]@{ schema = 1; kind = 'host_cmd' }
        foreach ($k in $c.Keys) { $doc[$k] = $c[$k] }
        $line = $(if ($PSBoundParameters.ContainsKey('Raw')) { $Raw } else { ConvertTo-Json -InputObject $doc -Compress })
        $in = New-Object IO.MemoryStream
        $in.Write($Prefix, 0, $Prefix.Length)
        $hb = [Text.Encoding]::ASCII.GetBytes($line + "`n")
        $in.Write($hb, 0, $hb.Length)
        $in.Write($Payload, 0, $Payload.Length)
        $in.Position = 0
        $out = New-Object IO.MemoryStream
        $code = Invoke-AapGuestAgent -Ctx $W.Ctx -In $in -Out $out
        $bytes = $out.ToArray()
        $v = & (Get-Module AapWinBackend) { param($r, $c) Test-AapWinReply $r $c } @{ ExitCode = 0; Stdout = $bytes; TimedOut = $false; Overflow = $false } $c
        [pscustomobject]@{ Code = $code; Text = [Text.Encoding]::ASCII.GetString($bytes); Kind = $v.Kind; HostCode = $v.Code; Reply = $v.Reply; Cmd = $c }
    }
    function Get-State($W) { ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $W.Ctx.StateDir 'state.json'))) }
    function Get-Root($W) { Join-Path $W.Ctx.Scratch 'actions-runner' }
    # A guest that answered ready, registered and (unless -NoStart) started its runner.
    function New-RunningGuest([switch]$NoStart, [switch]$NoDeliver) {
        $w = New-Guest
        (Send-Guest $w 'probe').Reply.guest_state | Should -Be 'ready'
        if (-not $NoDeliver) { (Send-Guest $w 'deliver_registration' $script:JitBytes).Reply.guest_state | Should -Be 'registered' }
        if (-not $NoStart -and -not $NoDeliver) { (Send-Guest $w 'start_runner').Reply.guest_state | Should -Be 'listening' }
        $w
    }
}

Describe 'one job end to end' {
    It 'bootstraps on probe, holds the JIT config in the runner root, starts the runner with it in its environment only, and reports the job' {
        $w = New-Guest
        $p = Send-Guest $w 'probe'
        $p.Code | Should -Be 0
        $p.Kind | Should -Be 'ok'
        $p.Reply.guest_state | Should -Be 'ready'
        Test-Path (Join-Path $w.Dirs['win\Panther'] 'unattend.xml') | Should -BeFalse
        Test-Path (Join-Path $w.Dirs['win\Panther\UnattendGC'] 'setupact.log') | Should -BeTrue
        $w.Formatted | Should -Be 1
        Test-Path (Join-Path (Get-Root $w) 'bin\Runner.Listener.exe') | Should -BeTrue
        Test-Path (Join-Path (Get-Root $w) 'config.cmd') | Should -BeTrue
        Test-Path (Join-Path $w.Ctx.Scratch 'aap-cache') | Should -BeTrue

        $d = Send-Guest $w 'deliver_registration' $script:JitBytes
        $d.Kind | Should -Be 'ok'
        $d.Reply.guest_state | Should -Be 'registered'
        [IO.File]::ReadAllText((Join-Path (Get-Root $w) '.aap-jit')) | Should -BeExactly $script:Jit

        $s = Send-Guest $w 'start_runner'
        $s.Kind | Should -Be 'ok'
        $s.Reply.guest_state | Should -Be 'listening'
        $w.Psi.File | Should -Be (Join-Path (Get-Root $w) 'bin\Runner.Listener.exe')
        $w.Psi.Arguments | Should -BeExactly 'run'
        $w.Psi.Dir | Should -Be (Get-Root $w)
        $w.Psi.Shell | Should -BeFalse
        $w.Psi.NoWindow | Should -BeTrue
        $w.Psi.Env['ACTIONS_RUNNER_INPUT_JITCONFIG'] | Should -BeExactly $script:Jit
        $w.Psi.JitOnDisk | Should -BeFalse
        Test-Path (Join-Path (Get-Root $w) '.aap-jit') | Should -BeFalse
        # The cache started first, from an environment without the JIT config, while it was still only in the root.
        $w.CacheSawJit | Should -BeTrue
        $w.CacheSawEnv | Should -BeNullOrEmpty

        $st = Send-Guest $w 'status'
        $st.Kind | Should -Be 'ok'
        $st.Reply.guest_state | Should -Be 'listening'
        $w.Worker = $true
        (Send-Guest $w 'status').Reply.guest_state | Should -Be 'busy'
        $w.Worker = $false
        $w.ExitCode = 0
        $w.Alive = $false
        Wait-AapGuestRunner -Ctx $w.Ctx -Started $w.Started
        $done = Send-Guest $w 'status'
        $done.Reply.guest_state | Should -Be 'job_done'
        $done.Reply.runner_exit_code | Should -BeNullOrEmpty
        $c = Send-Guest $w 'collect'
        $c.Kind | Should -Be 'ok'
        $c.Reply.guest_state | Should -Be 'job_done'
        $c.Reply.diag | Should -Match 'cache qualified: 2 qualified pairs'
    }
    It 'resumes a probe while Windows setup runs, and leaves the answer file until setup is complete' -Tag 'setup-complete' {
        $w = New-Guest
        $w.Setup = $false
        $p = Send-Guest $w 'probe'
        $p.Kind | Should -Be 'ok'
        $p.Reply.guest_state | Should -Be 'booting'
        Test-Path (Join-Path $w.Dirs['win\Panther'] 'unattend.xml') | Should -BeTrue
        $w.Formatted | Should -Be 0
        $w.Setup = $true
        (Send-Guest $w 'probe').Reply.guest_state | Should -Be 'ready'
    }
    It 'answers a later probe with ready without redoing the bootstrap' {
        $w = New-RunningGuest -NoDeliver
        $w.Disks = @()
        $w.Volume = $null
        (Send-Guest $w 'probe').Reply.guest_state | Should -Be 'ready'
        $w.Formatted | Should -Be 1
    }
    It 'drops runner inputs and Windows PowerShell''s own variables the launcher inherited, and restores the logon module path' -Tag 'runner-env-strip' {
        $saved = $env:PSModulePath
        $env:ACTIONS_RUNNER_INPUT_URL = 'https://example.invalid'
        $env:PSExecutionPolicyPreference = 'Bypass'
        try {
            $env:PSModulePath = 'C:\launcher\rewritten;' + $saved
            $w = New-RunningGuest
        } finally { $env:PSModulePath = $saved; Remove-Item Env:\ACTIONS_RUNNER_INPUT_URL, Env:\PSExecutionPolicyPreference }
        $w.Psi.Env.ContainsKey('ACTIONS_RUNNER_INPUT_URL') | Should -BeFalse
        $w.Psi.Env.ContainsKey('PSEXECUTIONPOLICYPREFERENCE') | Should -BeFalse
        $w.Psi.Env['PSMODULEPATH'] | Should -BeExactly $w.Machine.PSModulePath
        @($w.Psi.Env.Keys | Where-Object { $_ -like 'ACTIONS_RUNNER_INPUT_*' }) | Should -Be @('ACTIONS_RUNNER_INPUT_JITCONFIG')
        # A user module path, when the job user has one, wins as at a fresh logon.
        $w = New-Guest
        $w.User.PSModulePath = 'C:\Users\runneradmin\Modules'
        $null = Send-Guest $w 'probe'; $null = Send-Guest $w 'deliver_registration' $script:JitBytes; $null = Send-Guest $w 'start_runner'
        $w.Psi.Env['PSMODULEPATH'] | Should -BeExactly 'C:\Users\runneradmin\Modules'
    }
    It 'merges only the cache variables it knows, with printable values' -Tag 'runner-env-allow', 'runner-env-value' {
        $w = New-Guest
        $w.CacheEnv = "AAP_ZC_STATE=D:\aap-cache\state\config.json`nCMAKE_C_COMPILER_LAUNCHER=pwsh.exe;-File;zcshim.ps1`nCMAKE_CXX_COMPILER_LAUNCHER=a`tb`nPATH=C:\evil`nNODE_OPTIONS=--require=x`nACTIONS_RUNNER_INPUT_EVIL=1`nlower=1`nno equals sign`n"
        $null = Send-Guest $w 'probe'; $null = Send-Guest $w 'deliver_registration' $script:JitBytes
        (Send-Guest $w 'start_runner').Reply.guest_state | Should -Be 'listening'
        $w.Psi.Env['AAP_ZC_STATE'] | Should -BeExactly 'D:\aap-cache\state\config.json'
        $w.Psi.Env['CMAKE_C_COMPILER_LAUNCHER'] | Should -BeExactly 'pwsh.exe;-File;zcshim.ps1'
        $w.Psi.Env.ContainsKey('CMAKE_CXX_COMPILER_LAUNCHER') | Should -BeFalse
        $w.Psi.Env['PATH'] | Should -Not -Be 'C:\evil'
        $w.Psi.Env.ContainsKey('NODE_OPTIONS') | Should -BeFalse
        $w.Psi.Env.ContainsKey('ACTIONS_RUNNER_INPUT_EVIL') | Should -BeFalse
        $w.Psi.Env.ContainsKey('LOWER') | Should -BeFalse
    }
    It 'starts the runner without a cache when the cache cannot start' {
        $w = New-Guest
        $w.CacheThrows = $true
        $null = Send-Guest $w 'probe'; $null = Send-Guest $w 'deliver_registration' $script:JitBytes
        (Send-Guest $w 'start_runner').Reply.guest_state | Should -Be 'listening'
        $w.Psi.Env.ContainsKey('AAP_ZC_STATE') | Should -BeFalse
        $w.Psi.Env['ACTIONS_RUNNER_INPUT_JITCONFIG'] | Should -BeExactly $script:Jit
    }
    It 'records a failed start and answers failed when the registration material is missing' {
        $w = New-RunningGuest -NoStart
        Remove-Item -LiteralPath (Join-Path (Get-Root $w) '.aap-jit')
        $s = Send-Guest $w 'start_runner'
        $s.Kind | Should -Be 'error'
        $s.Reply.guest_state | Should -Be 'failed'
        $w.Psi | Should -BeNullOrEmpty
        $st = Send-Guest $w 'status'
        $st.Kind | Should -Be 'ok'
        $st.Reply.guest_state | Should -Be 'failed'
    }
    It 'answers failed when the runner does not start in time' {
        $w = New-RunningGuest -NoStart
        $w.Launcher = 'stuck'
        $s = Send-Guest $w 'start_runner'
        $s.Kind | Should -Be 'error'
        $s.Reply.diag | Should -Match 'not started within 2 s'
    }
    It 'leaves a cancel mark whenever start_runner does not end with a listening runner' -Tag 'start-cancel' {
        $w = New-RunningGuest -NoStart
        $w.Launcher = 'stuck'
        (Send-Guest $w 'start_runner').Kind | Should -Be 'error'
        Test-Path (Join-Path $w.Ctx.StateDir 'cancel') | Should -BeTrue
        $ok = New-RunningGuest
        Test-Path (Join-Path $ok.Ctx.StateDir 'cancel') | Should -BeFalse
    }
    It 'starts no runner once start_runner gave up: past its deadline, after its cancel mark, or never asked' -Tag 'launch-cancel' {
        $w = New-RunningGuest -NoStart
        $w.Launcher = 'late'
        $s = Send-Guest $w 'start_runner'
        $s.Kind | Should -Be 'error'
        $w.Psi | Should -BeNullOrEmpty
        Test-Path (Join-Path (Get-Root $w) '.aap-jit') | Should -BeFalse
        $mod = Get-Module AapGuestAgent
        foreach ($case in 'cancel', 'unasked') {
            $w = New-RunningGuest -NoStart
            if ($case -eq 'cancel') {
                [IO.File]::WriteAllText((Join-Path $w.Ctx.StateDir 'launch.json'), ('{"phase":"requested","deadline":' + [DateTime]::UtcNow.AddMinutes(5).Ticks + '}'))
                [IO.File]::WriteAllText((Join-Path $w.Ctx.StateDir 'cancel'), 'cancelled')
            }
            & $mod { param($c) Start-AapGuestRunner -Ctx $c } $w.Ctx | Should -BeNullOrEmpty
            $w.Psi | Should -BeNullOrEmpty
            [IO.File]::ReadAllText((Join-Path $w.Ctx.StateDir 'launch.json')) | Should -Match 'cancelled'
            Test-Path (Join-Path (Get-Root $w) '.aap-jit') | Should -BeFalse
        }
    }
    It 'never answers listening while the JIT config is still on disk after the start' -Tag 'start-jit-gone', 'residue-jit' {
        $w = New-RunningGuest -NoStart
        $w.Launcher = 'fake-running'
        $s = Send-Guest $w 'start_runner'
        $s.Kind | Should -Be 'error'
        $s.Reply.guest_state | Should -Be 'failed'
        $s.Reply.diag | Should -Match 'registration material on disk'
    }
    It 'refuses to start the runner when bootstrap material is back' -Tag 'start-residue' {
        $w = New-RunningGuest -NoStart
        [IO.File]::WriteAllText((Join-Path $w.Dirs['win\System32\Sysprep'] 'unattend.xml'), 'again')
        $s = Send-Guest $w 'start_runner'
        $s.Kind | Should -Be 'error'
        $s.Reply.diag | Should -Match 'bootstrap file'
        $w.Psi | Should -BeNullOrEmpty
    }
    It 'does not believe an exit record while the recorded runner still runs' -Tag 'exited-alive' {
        $w = New-RunningGuest
        [IO.File]::WriteAllText((Join-Path $w.Ctx.StateDir 'launch.json'), '{"phase":"exited","runner_pid":4242,"runner_start":99,"exit_code":0}')
        $st = Send-Guest $w 'status'
        $st.Reply.guest_state | Should -Be 'listening'
        $st.Reply.runner_exit_code | Should -BeNullOrEmpty
        $w.Alive = $false
        $done = Send-Guest $w 'status'
        $done.Reply.guest_state | Should -Be 'job_done'
        $done.Reply.runner_exit_code | Should -BeNullOrEmpty
    }
    It 'never reports the exit code of an exit record, which anyone can forge with a pid that is gone' {
        $w = New-RunningGuest
        $w.Alive = $false
        [IO.File]::WriteAllText((Join-Path $w.Ctx.StateDir 'launch.json'), '{"phase":"exited","runner_pid":999999,"runner_start":1,"exit_code":0}')
        foreach ($cmd in 'status', 'collect') {
            $x = Send-Guest $w $cmd
            $x.Kind | Should -Be 'ok'
            $x.Reply.guest_state | Should -Be 'job_done'
            $x.Reply.runner_exit_code | Should -BeNullOrEmpty
        }
        $x.Reply.diag | Should -Match 'exit code unverified; exit unknown'
    }
    It 'reports a runner that is not the recorded process as done, never as listening' -Tag 'runner-identity' {
        $w = New-RunningGuest
        $w.Alive = $false
        $st = Send-Guest $w 'status'
        $st.Reply.guest_state | Should -Be 'job_done'
        $st.Reply.runner_exit_code | Should -BeNullOrEmpty
    }
    It 'keeps a tampered launch record to fixed words and printable, host-acceptable text' {
        $w = New-RunningGuest
        $evil = 'ghp_' + ('A' * 36) + '"\' + [char]7 + ('x' * 2000)
        [IO.File]::WriteAllText((Join-Path $w.Ctx.StateDir 'launch.json'), (ConvertTo-Json @{ phase = 'failed'; detail = $evil } -Compress))
        $st = Send-Guest $w 'status'
        $st.Kind | Should -Be 'ok'
        $st.Reply.guest_state | Should -Be 'failed'
        $st.Reply.diag | Should -Not -Match 'ghp_'
        [IO.File]::WriteAllText((Join-Path $w.Ctx.StateDir 'launch.json'), '{"phase":"exited","exit_code":"zero"}')
        $x = Send-Guest $w 'collect'
        $x.Kind | Should -Be 'ok'
        $x.Reply.runner_exit_code | Should -BeNullOrEmpty
        [IO.File]::WriteAllText((Join-Path $w.Ctx.StateDir 'launch.json'), ('{"phase":"running","pad":"' + ('y' * 70000) + '"}'))
        (Send-Guest $w 'status').Reply.guest_state | Should -Be 'failed'
    }
    It 'answers status before the start with an error, and shutdown once' {
        $w = New-RunningGuest -NoDeliver
        (Send-Guest $w 'status').Kind | Should -Be 'error'
        $s = Send-Guest $w 'shutdown'
        $s.Text | Should -Match '"guest_state":"shutting_down"'
        $w.Shutdowns | Should -Be 1
        (Send-Guest $w 'shutdown').Text | Should -Match '"status":"refused"'
        $w.Shutdowns | Should -Be 1
    }
}

Describe 'bootstrap' {
    It 'refuses to serve as anyone but the job user, an administrator' -Tag 'identity' {
        $w = New-Guest
        $w.Identity = @{ Name = 'WIN-AAP\installer'; IsAdmin = $true }
        $p = Send-Guest $w 'probe'
        $p.Kind | Should -Be 'error'
        $p.Reply.guest_state | Should -Be 'failed'
        $w = New-Guest
        $w.Identity = @{ Name = 'WIN-AAP\runneradmin'; IsAdmin = $false }
        (Send-Guest $w 'probe').Kind | Should -Be 'error'
        # A failed bootstrap stays failed.
        (Send-Guest $w 'probe').Kind | Should -Be 'error'
    }
    It 'removes every answer file: Panther tree, Sysprep and the system drive root' {
        $w = New-Guest
        [void][IO.Directory]::CreateDirectory((Join-Path $w.Dirs['win\Panther'] 'Unattend'))
        foreach ($f in (Join-Path $w.Dirs['win\Panther'] 'Unattend\unattend.xml'), (Join-Path $w.Dirs['win\System32\Sysprep'] 'unattend.xml'), (Join-Path $w.Dirs['sys'] 'autounattend.xml')) {
            [IO.File]::WriteAllText($f, 'x')
        }
        (Send-Guest $w 'probe').Reply.guest_state | Should -Be 'ready'
        @(Get-ChildItem -LiteralPath $w.Root -Recurse -Filter '*unattend*.xml') | Should -HaveCount 0
    }
    It 'removes a link in the Panther tree as an entry, never following it' -Tag 'walk-link' {
        $w = New-Guest
        $victim = Join-Path $w.Root 'victim'
        [void][IO.Directory]::CreateDirectory($victim)
        [IO.File]::WriteAllText((Join-Path $victim 'unattend.xml'), 'not the guest''s')
        $link = Join-Path $w.Dirs['win\Panther'] 'Linked'
        $null = cmd /c mklink /J "$link" "$victim"
        Test-Path -LiteralPath $link | Should -BeTrue
        (Send-Guest $w 'probe').Reply.guest_state | Should -Be 'ready'
        Test-Path -LiteralPath (Join-Path $victim 'unattend.xml') | Should -BeTrue
    }
    It 'refuses an image without its machine defaults' -Tag 'env', 'env-image' {
        foreach ($n in 'ImageOS', 'ImageVersion', 'AGENT_TOOLSDIRECTORY') {
            $w = New-Guest
            $w.Machine.Remove($n)
            $p = Send-Guest $w 'probe'
            $p.Kind | Should -Be 'error'
            $p.Reply.diag | Should -Match $n
        }
    }
    It 'refuses an image whose tool cache folder is missing' -Tag 'env', 'env-toolcache' {
        $w = New-Guest
        $w.Machine.AGENT_TOOLSDIRECTORY = Join-Path $w.Root 'nowhere'
        $p = Send-Guest $w 'probe'
        $p.Kind | Should -Be 'error'
        $p.Reply.diag | Should -Match 'tool cache'
    }
    It 'refuses a compiler on the default PATH, machine or user, also through a variable' -Tag 'env', 'env-compiler' {
        $w = New-Guest
        $w.Machine.Path = $w.Dirs['bin-clean'] + ';' + $w.Dirs['bin-msvc']
        (Send-Guest $w 'probe').Reply.diag | Should -Match 'cl.exe on the default PATH'
        $w = New-Guest
        $env:AAP_P14_MSVC = $w.Dirs['bin-msvc']
        try {
            $w.User.Path = '%AAP_P14_MSVC%'
            $p = Send-Guest $w 'probe'
        } finally { Remove-Item Env:\AAP_P14_MSVC }
        $p.Kind | Should -Be 'error'
        $p.Reply.diag | Should -Match 'cl.exe'
        # Git's link.exe on PATH is the hosted default and is fine.
        $w = New-Guest
        (Send-Guest $w 'probe').Reply.guest_state | Should -Be 'ready'
    }
    It 'makes D: of exactly one disk besides the boot disk, and refuses none or several' -Tag 'scratch-one' {
        foreach ($disks in @(@(), @(@{ Number = 1; Style = 'RAW'; Data = 0 }, @{ Number = 2; Style = 'RAW'; Data = 0 }), @(@{ Number = 1; Style = 'GPT'; Data = 2 }))) {
            $w = New-Guest
            $w.Disks = $disks
            $p = Send-Guest $w 'probe'
            $p.Kind | Should -Be 'error'
            $p.Reply.diag | Should -Match 'one scratch disk'
            $w.Formatted | Should -Be 0
        }
        # Initialized by a probe that was killed before it made the partition: picked up again.
        $w = New-Guest
        $w.Disks = @(@{ Number = 4; Style = 'GPT'; Data = 0 })
        (Send-Guest $w 'probe').Reply.guest_state | Should -Be 'ready'
        $w.FormattedNumber | Should -Be 4
    }
    It 'formats a D: left unformatted by a killed probe, and leaves the NTFS D: P10 made alone' -Tag 'scratch-resume' {
        $w = New-Guest
        $w.Volume = @{ FileSystem = ''; DriveType = 'Fixed'; Boot = $false; Number = 3 }
        (Send-Guest $w 'probe').Reply.guest_state | Should -Be 'ready'
        $w.FormattedNumber | Should -Be 3
        $w = New-Guest
        $w.Volume = @{ FileSystem = 'NTFS'; DriveType = 'Fixed'; Boot = $false; Number = 1 }
        (Send-Guest $w 'probe').Reply.guest_state | Should -Be 'ready'
        $w.Formatted | Should -Be 0
    }
    It 'refuses a D: that is not an NTFS fixed volume of a data disk' -Tag 'scratch-volume' {
        foreach ($v in @{ FileSystem = 'FAT32'; DriveType = 'Fixed'; Boot = $false; Number = 1 }, @{ FileSystem = 'NTFS'; DriveType = 'Removable'; Boot = $false; Number = 1 }, @{ FileSystem = 'NTFS'; DriveType = 'Fixed'; Boot = $true; Number = 0 }, @{ FileSystem = ''; DriveType = 'Fixed'; Boot = $true; Number = 0 }) {
            $w = New-Guest
            $w.Volume = $v
            $p = Send-Guest $w 'probe'
            $p.Kind | Should -Be 'error'
            $p.Reply.diag | Should -Match 'scratch volume'
        }
    }
    It 'resumes a runner copy a killed probe left half-done' {
        $w = New-Guest
        $part = Join-Path $w.Ctx.Scratch 'actions-runner.partial'
        [void][IO.Directory]::CreateDirectory((Join-Path $part 'bin'))
        [IO.File]::WriteAllText((Join-Path $part 'config.cmd'), 'config')
        $before = [datetime]'2001-02-03'
        [IO.File]::SetLastWriteTimeUtc((Join-Path $part 'config.cmd'), $before)
        [IO.File]::WriteAllText((Join-Path $part 'bin\Runner.Listener.exe.part'), 'cut short')
        (Send-Guest $w 'probe').Reply.guest_state | Should -Be 'ready'
        [IO.File]::GetLastWriteTimeUtc((Join-Path (Get-Root $w) 'config.cmd')) | Should -Be $before
        [IO.File]::ReadAllText((Join-Path (Get-Root $w) 'bin\Runner.Listener.exe')) | Should -BeExactly 'listener'
        @(Get-ChildItem -LiteralPath (Get-Root $w) -Recurse -Filter '*.part') | Should -HaveCount 0
        Test-Path $part | Should -BeFalse
    }
    It 'refuses to resume a runner copy through a link, writing nothing through it' -Tag 'copy-link' {
        $w = New-Guest
        $victim = Join-Path $w.Root 'victim'
        [void][IO.Directory]::CreateDirectory($victim)
        $part = Join-Path $w.Ctx.Scratch 'actions-runner.partial'
        [void][IO.Directory]::CreateDirectory($part)
        $null = cmd /c mklink /J "$(Join-Path $part 'bin')" "$victim"
        $p = Send-Guest $w 'probe'
        $p.Kind | Should -Be 'error'
        $p.Reply.guest_state | Should -Be 'failed'
        $p.Reply.diag | Should -Match 'bin is a link'
        @(Get-ChildItem -LiteralPath $victim -Force) | Should -HaveCount 0
        Test-Path -LiteralPath (Join-Path $part 'bin') | Should -BeTrue
        (Send-Guest $w 'probe').Reply.guest_state | Should -Be 'failed'
    }
    It 'refuses to resume a runner copy holding a file that is not the image''s' -Tag 'copy-match' {
        $w = New-Guest
        $part = Join-Path $w.Ctx.Scratch 'actions-runner.partial'
        [void][IO.Directory]::CreateDirectory($part)
        [IO.File]::WriteAllText((Join-Path $part 'config.cmd'), 'substituted')
        $p = Send-Guest $w 'probe'
        $p.Kind | Should -Be 'error'
        $p.Reply.diag | Should -Match 'config.cmd is not the image'
        Test-Path -LiteralPath (Get-Root $w) | Should -BeFalse
        [IO.File]::ReadAllText((Join-Path $part 'config.cmd')) | Should -BeExactly 'substituted'
    }
    It 'refuses a runner root it did not make, removing nothing' -Tag 'root-left' {
        $w = New-Guest
        $victim = Join-Path $w.Root 'victim'
        [void][IO.Directory]::CreateDirectory($victim)
        [IO.File]::WriteAllText((Join-Path $victim 'keep.txt'), 'keep')
        $null = cmd /c mklink /J "$(Get-Root $w)" "$victim"
        $p = Send-Guest $w 'probe'
        $p.Kind | Should -Be 'error'
        $p.Reply.diag | Should -Match 'runner root exists without its listener'
        @(Get-ChildItem -LiteralPath $victim -Force).Name | Should -Be 'keep.txt'
    }
    It 'answers booting while an earlier probe still runs the bootstrap' -Tag 'bootstrap-lock' {
        $w = New-Guest
        $w.Setup = $false
        $null = Send-Guest $w 'probe'
        $w.Setup = $true
        $held = [IO.File]::Open((Join-Path $w.Ctx.StateDir 'bootstrap.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        try {
            $p = Send-Guest $w 'probe'
            $p.Kind | Should -Be 'ok'
            $p.Reply.guest_state | Should -Be 'booting'
            $p.Reply.diag | Should -Match 'bootstrap in progress'
            $w.Formatted | Should -Be 0
            Test-Path (Join-Path $w.Dirs['win\Panther'] 'unattend.xml') | Should -BeTrue
        } finally { $held.Dispose() }
        (Send-Guest $w 'probe').Reply.guest_state | Should -Be 'ready'
    }
    It 'answers without accepting anything while another agent holds the state' {
        $w = New-Guest
        $null = Send-Guest $w 'probe'
        $before = [IO.File]::ReadAllText((Join-Path $w.Ctx.StateDir 'state.json'))
        $held = [IO.File]::Open((Join-Path $w.Ctx.StateDir 'state.json'), 'Open', 'ReadWrite', 'None')
        try {
            $p = Send-Guest $w 'probe'
            $p.Kind | Should -Be 'ok'
            $p.Reply.guest_state | Should -Be 'booting'
            $p.Reply.diag | Should -Match 'agent busy'
            (Send-Guest $w 'status').Kind | Should -Be 'error'
        } finally { $held.Dispose() }
        [IO.File]::ReadAllText((Join-Path $w.Ctx.StateDir 'state.json')) | Should -BeExactly $before
    }
    It 'reads past a PATH entry on a drive the guest does not have' {
        $free = @([char[]](90..68) | Where-Object { -not (Test-Path -LiteralPath "${_}:\") })[0]
        $w = New-Guest
        $w.Machine.Path = "${free}:\no\such\dir;" + $w.Machine.Path
        (Send-Guest $w 'probe').Reply.guest_state | Should -Be 'ready'
    }
    It 'refuses an image without the actions-runner overlay' -Tag 'runner-overlay' {
        $w = New-Guest
        Remove-Item -LiteralPath (Join-Path $w.Ctx.InstallDir 'runner') -Recurse
        $p = Send-Guest $w 'probe'
        $p.Kind | Should -Be 'error'
        $p.Reply.diag | Should -Match 'overlay'
    }
    It 'gives the runner root, the cache root and the state folder SYSTEM, Administrators and the job user only' {
        $w = New-RunningGuest -NoDeliver
        foreach ($p in (Get-Root $w), (Join-Path $w.Ctx.Scratch 'aap-cache')) {
            $acl = Get-Acl -LiteralPath $p
            $acl.AreAccessRulesProtected | Should -BeTrue
            $sids = @($acl.Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } | Sort-Object -Unique)
            $want = @('S-1-5-18', 'S-1-5-32-544', [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) | Sort-Object -Unique
            $sids | Should -Be $want
        }
    }
}

Describe 'the wire' {
    It 'tolerates a leading UTF-8 BOM, and nothing else before the envelope' -Tag 'bom' {
        $w = New-Guest
        (Send-Guest $w 'probe' -Prefix ([byte[]](0xEF, 0xBB, 0xBF))).Kind | Should -Be 'ok'
        $x = Send-Guest $w 'probe' -Prefix ([byte[]](0xEF, 0x41, 0x42))
        $x.Code | Should -Be 2
        $x.Text | Should -BeNullOrEmpty
    }
    It 'stops reading at the first byte that is not printable, or at byte 1025 of a line' -Tag 'line-bytes' {
        $w = New-Guest
        foreach ($case in @(@{ Bytes = ([byte[]](@(65) * 20 + 9 + @(65) * 100 + 10)); Stop = 21 }, @{ Bytes = ([byte[]](@(65) * 2000 + 10)); Stop = 1025 }, @{ Bytes = ([byte[]](@(65) * 1024 + 10)); Stop = 1025 })) {
            $in = New-Object IO.MemoryStream (, $case.Bytes)
            $out = New-Object IO.MemoryStream
            Invoke-AapGuestAgent -Ctx $w.Ctx -In $in -Out $out | Should -Be 2
            $in.Position | Should -Be $case.Stop
            $out.Length | Should -Be 0
        }
    }
    It 'writes nothing for framing it cannot read' {
        $w = New-Guest
        $ok = ConvertTo-Json -Compress -InputObject ([ordered]@{ schema = 1; kind = 'host_cmd'; vm_id = $script:VmId; reservation_id = 'r-00000000000000a1'; lease_generation = 1; seq = 1
                nonce = (New-Hex 16); cmd = 'probe'; payload_bytes = 0; expires_at = (Format-Time ([DateTime]::UtcNow.AddSeconds(60)))
            })
        foreach ($raw in ($ok.Substring(0, 20) + "`t" + $ok.Substring(20)), ($ok.TrimEnd('}') + ',"pad":"' + ('p' * 1024) + '"}')) {
            $x = Send-Guest $w 'probe' -Raw $raw
            $x.Code | Should -Be 2
            $x.Text | Should -BeNullOrEmpty
        }
        # No newline, and a payload shorter than payload_bytes.
        $in = New-Object IO.MemoryStream (, [Text.Encoding]::ASCII.GetBytes($ok))
        $out = New-Object IO.MemoryStream
        Invoke-AapGuestAgent -Ctx $w.Ctx -In $in -Out $out | Should -Be 2
        $short = Send-Guest $w 'deliver_registration' $script:JitBytes -Over @{ payload_bytes = $script:JitBytes.Length + 1 }
        $short.Code | Should -Be 2
        $short.Text | Should -BeNullOrEmpty
        Test-Path (Join-Path $w.Ctx.StateDir 'state.json') | Should -BeFalse
    }
    It 'writes nothing for an envelope with text around or between its fields' -Tag 'envelope-shape' {
        $w = New-Guest
        $x = Send-Guest $w 'probe' -Raw ((ConvertTo-Json -Compress -InputObject ([ordered]@{ schema = 1; kind = 'host_cmd'; vm_id = $script:VmId; reservation_id = 'r-00000000000000a1'
                        lease_generation = 1; seq = 1; nonce = (New-Hex 16); cmd = 'probe'; payload_bytes = 0; expires_at = (Format-Time ([DateTime]::UtcNow.AddSeconds(60)))
                    })) + 'trailing')
        $x.Code | Should -Be 2
        $y = Send-Guest $w 'probe' -Raw ('{"schema":1,"kind":"host_cmd","vm_id":"' + $script:VmId + '","reservation_id":"r-00000000000000a1","lease_generation":1,"seq":2.5,"nonce":"' + (New-Hex 16) +
            '","cmd":"probe","payload_bytes":0,"expires_at":"' + (Format-Time ([DateTime]::UtcNow.AddSeconds(60))) + '"}')
        $y.Code | Should -Be 2
        $y.Text | Should -BeNullOrEmpty
    }
    It 'writes nothing for a duplicated key' -Tag 'envelope-duplicate' {
        $w = New-Guest
        $line = '{"schema":1,"kind":"host_cmd","vm_id":"' + $script:VmId + '","reservation_id":"r-00000000000000a1","lease_generation":1,"seq":1,"nonce":"' + (New-Hex 16) +
        '","nonce":"' + (New-Hex 16) + '","cmd":"probe","payload_bytes":0,"expires_at":"' + (Format-Time ([DateTime]::UtcNow.AddSeconds(60))) + '"}'
        $x = Send-Guest $w 'probe' -Raw $line
        $x.Code | Should -Be 2
        $x.Text | Should -BeNullOrEmpty
    }
    It 'writes nothing for a missing or an extra key' -Tag 'envelope-keys' {
        $w = New-Guest
        $x = Send-Guest $w 'probe' -Over @{ extra = 1 }
        $x.Code | Should -Be 2
        $x.Text | Should -BeNullOrEmpty
    }
    It 'writes nothing for a value out of its range' -Tag 'envelope-values' {
        $w = New-Guest
        foreach ($o in @{ kind = 'host_cmdx' }, @{ nonce = ('A' * 32) }, @{ seq = 0 }, @{ seq = 2147483648 }, @{ lease_generation = 1000000000 }, @{ payload_bytes = 16385 },
            @{ cmd = 'reset' }, @{ reservation_id = 'r-1' }, @{ vm_id = $script:VmId.ToUpperInvariant() }, @{ expires_at = '2026-13-40T99:00:00Z' }, @{ expires_at = 'soon' }, @{ schema = 2 }) {
            $x = Send-Guest $w 'probe' -Over $o
            $x.Code | Should -Be 2
            $x.Text | Should -BeNullOrEmpty
        }
    }
}

Describe 'refusals (guest-transport.md, Envelope)' {
    It 'refuses everything when the hypervisor gives no VM id, before touching the disk' -Tag 'vmid-source' {
        $w = New-Guest
        $w.VmId = ''
        $x = Send-Guest $w 'probe'
        $x.Kind | Should -Be 'refused'
        $x.Reply.diag | Should -Match 'own vm id unavailable'
        Test-Path (Join-Path $w.Ctx.StateDir 'state.json') | Should -BeFalse
        $w.VmId = '{' + $script:VmId.ToUpperInvariant() + '}'
        (Send-Guest $w 'probe').Kind | Should -Be 'ok'
    }
    It 'refuses a command for another VM' -Tag 'vmid' {
        $w = New-Guest
        $w.VmId = [guid]::NewGuid().ToString()
        $x = Send-Guest $w 'probe'
        $x.Kind | Should -Be 'refused'
        Test-Path (Join-Path $w.Ctx.StateDir 'state.json') | Should -BeFalse
    }
    It 'refuses a lease generation other than the first of the boot' -Tag 'refuse-generation' {
        $w = New-Guest
        (Send-Guest $w 'probe').Kind | Should -Be 'ok'
        (Send-Guest $w 'probe' -Over @{ lease_generation = 2 }).Kind | Should -Be 'refused'
        (Send-Guest $w 'probe').Kind | Should -Be 'ok'
    }
    It 'refuses a reservation_id other than the first of the boot' -Tag 'refuse-reservation' {
        $w = New-Guest
        (Send-Guest $w 'probe').Kind | Should -Be 'ok'
        $x = Send-Guest $w 'probe' -Over @{ reservation_id = 'r-00000000000000b2' }
        $x.Kind | Should -Be 'refused'
        $x.Reply.diag | Should -Match 'reservation_id'
        (Get-State $w).reservation_id | Should -BeExactly 'r-00000000000000a1'
    }
    It 'refuses an expiry further ahead than the contract allows (120 s, plus 5 s of slack)' -Tag 'refuse-expiry-ahead' {
        $w = New-Guest
        $x = Send-Guest $w 'probe' -Over @{ expires_at = (Format-Time ([DateTime]::UtcNow.AddSeconds(600))) }
        $x.Kind | Should -Be 'refused'
        $x.Reply.diag | Should -Match 'too far ahead'
        (Send-Guest $w 'probe' -Over @{ expires_at = (Format-Time ([DateTime]::UtcNow.AddSeconds(118))) }).Kind | Should -Be 'ok'
    }
    It 'refuses a seq equal to or below the last accepted one, and accepts a gap' -Tag 'refuse-seq' {
        $w = New-Guest
        (Send-Guest $w 'probe' -Over @{ seq = 5 }).Kind | Should -Be 'ok'
        (Send-Guest $w 'probe' -Over @{ seq = 5 }).Kind | Should -Be 'refused'
        (Send-Guest $w 'probe' -Over @{ seq = 4 }).Kind | Should -Be 'refused'
        (Send-Guest $w 'probe' -Over @{ seq = 9 }).Kind | Should -Be 'ok'
        (Get-State $w).seq | Should -Be 9
    }
    It 'refuses a nonce it has seen, and a refused command changes nothing' -Tag 'refuse-nonce' {
        $w = New-Guest
        $n = New-Hex 16
        (Send-Guest $w 'probe' -Over @{ nonce = $n }).Kind | Should -Be 'ok'
        $x = Send-Guest $w 'probe' -Over @{ nonce = $n }
        $x.Kind | Should -Be 'refused'
        $x.Reply.nonce | Should -Be $n
        (Get-State $w).seq | Should -Be 1
    }
    It 'refuses once the nonce store is full' -Tag 'refuse-nonce-full' {
        $w = New-Guest
        $doc = [ordered]@{ schema = 1; reservation_id = 'r-00000000000000a1'; lease_generation = 1; seq = 1; nonces = @(1..8192 | ForEach-Object { '{0:x32}' -f $_ }); shots = @(); phase = 'ready'; detail = '' }
        [IO.File]::WriteAllText((Join-Path $w.Ctx.StateDir 'state.json'), (ConvertTo-Json -InputObject $doc -Compress))
        $x = Send-Guest $w 'probe' -Over @{ seq = 2 }
        $x.Kind | Should -Be 'refused'
        $x.Reply.diag | Should -Match 'nonce store full'
    }
    It 'refuses a second one-shot command of a class' -Tag 'refuse-oneshot' {
        $w = New-RunningGuest -NoStart
        $x = Send-Guest $w 'deliver_registration' $script:JitBytes
        $x.Kind | Should -Be 'refused'
        $x.Reply.diag | Should -Match 'already ran'
    }
    It 'refuses an expired command, allowing 5 s of clock slack' -Tag 'refuse-expired' {
        $w = New-Guest
        (Send-Guest $w 'probe' -Over @{ expires_at = (Format-Time ([DateTime]::UtcNow.AddSeconds(-30))) }).Kind | Should -Be 'refused'
        (Send-Guest $w 'probe' -Over @{ expires_at = (Format-Time ([DateTime]::UtcNow.AddSeconds(-2))) }).Kind | Should -Be 'ok'
    }
    It 'refuses a payload on any command but deliver_registration, and deliver_registration without one' -Tag 'refuse-payload' {
        $w = New-Guest
        $x = Send-Guest $w 'probe' ([byte[]](65, 66))
        $x.Kind | Should -Be 'refused'
        (Send-Guest $w 'probe').Reply.guest_state | Should -Be 'ready'
        (Send-Guest $w 'deliver_registration').Kind | Should -Be 'refused'
    }
    It 'answers an error and accepts nothing while its state file is unreadable' -Tag 'state-bad', 'state-shape' {
        $w = New-Guest
        foreach ($bad in 'not json', '{"schema":1,"reservation_id":"","lease_generation":0,"seq":0,"nonces":[],"shots":[],"phase":"bogus","detail":""}', '{"schema":1,"reservation_id":"","lease_generation":0,"seq":"0","nonces":[],"shots":[],"phase":"booting","detail":""}', '{"schema":1,"reservation_id":7,"lease_generation":0,"seq":0,"nonces":[],"shots":[],"phase":"booting","detail":""}') {
            [IO.File]::WriteAllText((Join-Path $w.Ctx.StateDir 'state.json'), $bad)
            $x = Send-Guest $w 'probe'
            $x.Kind | Should -Be 'error'
            $x.Reply.diag | Should -Match 'state unreadable'
            [IO.File]::ReadAllText((Join-Path $w.Ctx.StateDir 'state.json')) | Should -BeExactly $bad
        }
    }
    It 'answers an error for an empty state file, which only a torn save leaves' -Tag 'state-shape' {
        $w = New-Guest
        $null = Send-Guest $w 'probe'
        [IO.File]::WriteAllText((Join-Path $w.Ctx.StateDir 'state.json'), '')
        $x = Send-Guest $w 'probe'
        $x.Kind | Should -Be 'error'
        $x.Reply.diag | Should -Match 'state unreadable'
    }
    It 'saves over a longer state without leaving its tail' {
        $w = New-Guest
        $doc = [ordered]@{ schema = 1; reservation_id = ''; lease_generation = 0; seq = 0; nonces = @(); shots = @(); phase = 'booting'; detail = ('d' * 3000) }
        [IO.File]::WriteAllText((Join-Path $w.Ctx.StateDir 'state.json'), (ConvertTo-Json -InputObject $doc -Compress))
        (Send-Guest $w 'probe').Kind | Should -Be 'ok'
        $t = [IO.File]::ReadAllText((Join-Path $w.Ctx.StateDir 'state.json'))
        $t.Length | Should -BeLessThan 3000
        (ConvertFrom-Json $t).seq | Should -Be 1
    }
    It 'answers an error for an oversized state file' -Tag 'state-size' {
        $w = New-Guest
        $doc = '{"schema":1,"reservation_id":"","lease_generation":0,"seq":0,"nonces":[],"shots":[],"phase":"booting","detail":""}' + (' ' * 600000)
        [IO.File]::WriteAllText((Join-Path $w.Ctx.StateDir 'state.json'), $doc)
        (Send-Guest $w 'probe').Kind | Should -Be 'error'
    }
    It 'refuses deliver_registration before ready, and a payload that is not a JIT config' -Tag 'deliver-phase', 'deliver-shape' {
        $w = New-Guest
        $w.Setup = $false
        $x = Send-Guest $w 'deliver_registration' $script:JitBytes
        $x.Kind | Should -Be 'error'
        Test-Path (Join-Path (Get-Root $w) '.aap-jit') | Should -BeFalse
        # A guest past ready (here: shutting down) with its runner root in place takes no registration either.
        $w = New-RunningGuest -NoDeliver
        $null = Send-Guest $w 'shutdown'
        (Send-Guest $w 'deliver_registration' $script:JitBytes).Kind | Should -Be 'error'
        Test-Path (Join-Path (Get-Root $w) '.aap-jit') | Should -BeFalse
        $w = New-RunningGuest -NoDeliver
        $x = Send-Guest $w 'deliver_registration' ([Text.Encoding]::ASCII.GetBytes('{"jit":"x"}'))
        $x.Kind | Should -Be 'error'
        $x.Reply.diag | Should -Match 'not a JIT config'
        Test-Path (Join-Path (Get-Root $w) '.aap-jit') | Should -BeFalse
    }
    It 'refuses start_runner before a registration' -Tag 'start-phase' {
        $w = New-RunningGuest -NoDeliver
        $x = Send-Guest $w 'start_runner'
        $x.Kind | Should -Be 'error'
        $w.LauncherStarts | Should -Be 0
        $w.Psi | Should -BeNullOrEmpty
    }
}

Describe 'hygiene' {
    It 'never hands secret bytes to a command, only to .NET calls' {
        foreach ($f in 'AapGuestAgent.psm1', 'agent.ps1', 'launch.ps1') {
            $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Src $f), [ref]$null, [ref]$null)
            $uses = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.VariableExpressionAst] -and @('payload', 'jit', 'jitText') -contains $n.VariablePath.UserPath }, $true)
            foreach ($u in $uses) {
                for ($p = $u.Parent; $null -ne $p; $p = $p.Parent) {
                    $p | Should -Not -BeOfType ([Management.Automation.Language.CommandAst]) -Because "$f line $($u.Extent.StartLineNumber)"
                    if ($p -is [Management.Automation.Language.StatementBlockAst]) { break }
                }
            }
        }
    }
    It 'leaves the JIT config in no file and no reply once the runner started' {
        $w = New-Guest
        $replies = New-Object Collections.Generic.List[string]
        foreach ($c in 'probe', 'deliver_registration', 'start_runner', 'status', 'collect') {
            $payload = [byte[]]@()
            if ($c -eq 'deliver_registration') { $payload = $script:JitBytes }
            $replies.Add((Send-Guest $w $c $payload).Text)
        }
        ($replies -join "`n") | Should -Not -Match ([regex]::Escape($script:Jit))
        foreach ($f in Get-ChildItem -LiteralPath $w.Root -Recurse -File) {
            [IO.File]::ReadAllText($f.FullName) | Should -Not -Match ([regex]::Escape($script:Jit)) -Because $f.FullName
        }
    }
    It 'installs the agent files into an Administrators-only folder' {
        $dir = Join-Path $TestDrive 'aap-guest'
        Install-AapGuestAgent -InstallDir $dir
        @(Get-ChildItem -LiteralPath $dir -Name | Sort-Object) | Should -Be @('AapGuestAgent.psm1', 'agent.ps1', 'launch.ps1')
        $acl = Get-Acl -LiteralPath $dir
        $acl.AreAccessRulesProtected | Should -BeTrue
        $sids = @($acl.Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } | Sort-Object -Unique)
        $self = [Security.Principal.WindowsIdentity]::GetCurrent()
        $admin = (New-Object Security.Principal.WindowsPrincipal $self).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $want = @('S-1-5-18', 'S-1-5-32-544') + $(if ($admin) { @() } else { @($self.User.Value) })
        $sids | Should -Be @($want | Sort-Object -Unique)
    }
}

Describe 'agent.ps1 as the remote script starts it' {
    BeforeAll {
        $script:Ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        # Like psdirect-call.ps1's remote script: stdin written through BaseStream under a preamble-free InputEncoding.
        function Invoke-Agent([byte[]]$Stdin) {
            $psi = New-Object Diagnostics.ProcessStartInfo
            $psi.FileName = $script:Ps
            $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $script:Repo 'guests\windows\agent.ps1') + '"'
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.EnvironmentVariables['PSModulePath'] = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
            $saved = $null
            try { $saved = [Console]::InputEncoding; [Console]::InputEncoding = New-Object Text.UTF8Encoding($false) } catch { $saved = $null }
            try { $p = [Diagnostics.Process]::Start($psi) } finally { if ($null -ne $saved) { try { [Console]::InputEncoding = $saved } catch { $null = $_ } } }
            $p.StandardInput.BaseStream.Write($Stdin, 0, $Stdin.Length)
            $p.StandardInput.Close()
            $out = $p.StandardOutput.ReadToEnd()
            if (-not $p.WaitForExit(60000)) { $p.Kill(); throw 'agent.ps1 hung' }
            [pscustomobject]@{ Exit = $p.ExitCode; Out = $out }
        }
    }
    It 'writes nothing and exits 2 for garbage on stdin' {
        $r = Invoke-Agent ([Text.Encoding]::ASCII.GetBytes("hello`n"))
        $r.Exit | Should -Be 2
        $r.Out | Should -BeNullOrEmpty
    }
    It 'answers a well-formed command for a VM it is not with one refused line the host accepts' {
        $state = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'aap-guest'
        $existed = Test-Path -LiteralPath $state
        $c = [ordered]@{ schema = 1; kind = 'host_cmd'; vm_id = [guid]::NewGuid().ToString(); reservation_id = 'r-00000000000000a1'; lease_generation = 1; seq = 1
            nonce = (New-Hex 16); cmd = 'probe'; payload_bytes = 0; expires_at = (Format-Time ([DateTime]::UtcNow.AddSeconds(60)))
        }
        $r = Invoke-Agent ([Text.Encoding]::ASCII.GetBytes((ConvertTo-Json -InputObject $c -Compress) + "`n"))
        $r.Exit | Should -Be 0
        $bytes = [Text.Encoding]::ASCII.GetBytes($r.Out)
        $v = & (Get-Module AapWinBackend) { param($r, $c) Test-AapWinReply $r $c } @{ ExitCode = 0; Stdout = $bytes; TimedOut = $false; Overflow = $false } $c
        $v.Kind | Should -Be 'refused'
        ($r.Out -split "`n" | Where-Object { $_ }).Count | Should -Be 1
        if (-not $existed) { Test-Path -LiteralPath $state | Should -BeFalse }
    }
}

Describe 'mutation accounting (Invoke-AapGuestMutations.ps1)' {
    It 'counts a test as a kill only when every error is exactly a failed Should' -Tag 'kill-exact' {
        $runner = Join-Path $PSScriptRoot 'Invoke-AapGuestMutations.ps1'
        $fn = [Management.Automation.Language.Parser]::ParseFile($runner, [ref]$null, [ref]$null).Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-AapKill' }, $true).Extent.Text
        $judge = {
            param([string]$Text)
            . ([scriptblock]::Create($Text))
            $cases = 'PesterAssertionFailed', 'PesterAssertionFailed|PesterAssertionFailed', 'PesterAssertionFailedX', 'PesterAssertionFailed,Foo', 'RuntimeException', 'PesterAssertionFailed|RuntimeException', ''
            @($cases | ForEach-Object { Test-AapKill @($_ -split '\|' | Where-Object { $_ }) }) -join ','
        }
        & $judge $fn | Should -BeExactly 'True,True,False,False,False,False,False'
        # The prefix match this replaced counted an id that only starts like an assertion as a kill.
        $prefix = $fn.Replace("-cne 'PesterAssertionFailed'", "-notlike 'PesterAssertionFailed*'")
        $prefix | Should -Not -BeExactly $fn
        & $judge $prefix | Should -Not -BeExactly 'True,True,False,False,False,False,False'
    }
}
