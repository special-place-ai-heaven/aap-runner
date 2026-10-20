# actions/windows/shell-semantics: run step bodies through the exact command lines the Actions runner uses for
# shell: pwsh, powershell, cmd, bash and python (oracle shell_templates), with the runner's pwsh/powershell fixups, and
# compare exit codes with GitHub's documented semantics. Also: which binary each shell name resolves to, and C:\shells.
# bash must be Git's bash: System32\bash.exe is the WSL launcher and is never started here.
# Sabotage no-git-bash removes Git from PATH, so bash no longer resolves to a build shell.
param([Parameter(Mandatory)][string]$Work, [Parameter(Mandatory)][string]$Id, [string]$Sabotage = '')
Import-Module (Join-Path $PSScriptRoot '..\..\..\windows\Workload.psm1') -Force

function Invoke-Template([string]$File, [string]$Arguments) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = $Arguments
    $psi.WorkingDirectory = (Get-Location).ProviderPath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi)
    $err = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    foreach ($l in (($out + $err.Result) -split "`r?`n" | Where-Object { $_ })) { Write-Line ('  | ' + (Format-Norm $l)) }
    $p.ExitCode
}

function Get-BuildBash {
    $bash = Resolve-Exe 'bash.exe'
    if (-not $bash) { throw 'bash.exe is not on PATH: not a build shell' }
    if ($bash -like "$env:SystemRoot\*" -or $bash -like '*\WindowsApps\*') { throw 'bash.exe on PATH is the WSL launcher: not a build shell' }
    $bash
}

Invoke-Workload -Id $Id -Work $Work -Sabotage $Sabotage -Body {
    if ($Sabotage -eq 'no-git-bash') {
        Remove-PathEntries 'PATH' '*\Git\*'
        Write-Line 'sabotage no-git-bash applied'
        Get-BuildBash | Out-Null
    }
    $tpl = Get-Oracle 'shell_templates'
    $want = @{}
    foreach ($o in (Get-Oracle 'shell_semantics'), (Get-Oracle 'shell_semantics_exit_codes')) {
        foreach ($p in $o.PSObject.Properties) { $want[$p.Name] = $p.Value }
    }
    $exe = [ordered]@{
        pwsh = Resolve-Exe 'pwsh.exe'; powershell = Resolve-Exe 'powershell.exe'; cmd = $env:ComSpec
        bash = Get-BuildBash; python = Resolve-Exe 'python.exe'
    }
    Add-Fact 'bare_path.pwsh.exe' $exe.pwsh (Get-Oracle 'bare_path/pwsh.exe')
    Add-Fact 'bare_path.bash.exe' $exe.bash (Get-Oracle 'bare_path/bash.exe')
    Add-Fact 'bare_path.python_dir' (Split-Path -Parent $exe.python) (Get-Oracle 'bare_path/python_dir')
    Add-Observation 'ComSpec' $env:ComSpec
    foreach ($s in (Get-Oracle 'shells_dir')) { Add-Fact "shells_dir.$s" (Test-Path -LiteralPath (Join-Path 'C:\shells' $s)) $true }

    # the runner wraps pwsh and powershell bodies like this (documented fail-fast behaviour)
    $pre = "`$ErrorActionPreference = 'stop'"
    $post = 'if ((Test-Path -LiteralPath variable:\LASTEXITCODE)) { exit $LASTEXITCODE }'
    $ps = [ordered]@{
        native_last = 'cmd.exe /c exit 3'; native_then_ok = "cmd.exe /c exit 3`ncmd.exe /c exit 0"
        cmdlet_error = "Write-Error 'parity cmdlet error'"; exit = 'exit 7'
    }
    $cases = [ordered]@{}
    foreach ($sh in 'pwsh', 'powershell') { foreach ($k in $ps.Keys) { $cases["$sh.$k"] = @($sh, 'ps1', "$pre`n$($ps[$k])`n$post") } }
    $cases['cmd.exit_b'] = @('cmd', 'cmd', '@exit /b 4')
    $cases['cmd.ok'] = @('cmd', 'cmd', '@echo ok')
    $cases['bash.errexit'] = @('bash', 'sh', "false`necho after")
    $cases['bash.pipefail'] = @('bash', 'sh', 'false | true')
    $cases['bash.exit'] = @('bash', 'sh', 'exit 5')
    $cases['bash.ok'] = @('bash', 'sh', 'true')
    $cases['python.exit'] = @('python', 'py', 'import sys; sys.exit(6)')

    $report = @()
    $n = 0
    foreach ($k in $cases.Keys) {
        $sh, $ext, $body = $cases[$k]
        $file = Join-Path (Get-Location).ProviderPath ("step{0}.{1}" -f $n++, $ext)
        $nl = if ($ext -eq 'sh') { "`n" } else { "`r`n" }
        [IO.File]::WriteAllText($file, ($body -replace "`n", $nl) + $nl, (New-Object Text.UTF8Encoding($false)))
        $arguments = $tpl.$sh.Replace('{0}', $file)
        Write-Line ("> {0} {1}" -f $sh, (Format-Norm $arguments))
        $code = Invoke-Template $exe[$sh] $arguments
        Add-Fact "exit.$k" $code $want[$k]
        $report += "$k=$code"
    }
    Write-Report $report
}
