# Pester 5, Windows PowerShell 5.1 and PowerShell 7. The JIT config never surfaces as text anywhere.

BeforeAll { . (Join-Path $PSScriptRoot 'BrokerTestHelpers.ps1') }

Describe 'secret marker' {
    BeforeEach { Reset-Fake }

    It 'never surfaces the JIT config in output, streams, errors, a transcript or serialized results' {
        $transcript = Join-Path $TestDrive 'transcript.txt'
        $results = New-Object 'System.Collections.Generic.List[object]'
        $good = ConvertTo-Wire (New-LeaseReply)
        $replies = @(
            (New-LeaseReply -LeaseId $script:OtherLeaseId),
            ($good + ' x'),
            $good.Replace('"jit_config":', '"jit_config" :'),
            ($good + (' ' * 20480)),
            ($good.Substring(0, $good.IndexOf('"jit_config"')) + '"jit_config":"' + $script:Jit + '"'),
            (New-Result $good 3)
        )
        $replies.Count | Should -Be 6
        $errorsBefore = $Error.Count
        Start-Transcript -LiteralPath $transcript | Out-Null
        try {
            $VerbosePreference = 'Continue'
            $DebugPreference = 'Continue'
            $InformationPreference = 'Continue'
            $streams = & {
                $script:Reply = New-LeaseReply
                $results.Add((Invoke-Lease))
                foreach ($reply in $replies) {
                    $script:Reply = $reply
                    $results.Add((Invoke-Lease))
                }
            } *>&1 | Out-String
        } finally {
            $VerbosePreference = 'SilentlyContinue'
            $DebugPreference = 'SilentlyContinue'
            $InformationPreference = 'SilentlyContinue'
            Stop-Transcript | Out-Null
        }
        $results[0].Outcome | Should -Be 'issued'
        @($results | Select-Object -Skip 1 | ForEach-Object { $_.Outcome }) -join ',' | Should -Be 'bad_reply,bad_reply,bad_reply,bad_reply,bad_reply,unavailable'
        $newErrors = @($Error | Select-Object -First ($Error.Count - $errorsBefore))
        $texts = @(
            $streams,
            [IO.File]::ReadAllText($transcript),
            ($newErrors | Out-String),
            ($results | Format-List * | Out-String),
            (($results | ForEach-Object { "$_" }) -join "`n"),
            (ConvertTo-Json -InputObject $results.ToArray() -Depth 5 -Compress),
            (ConvertTo-Json -InputObject @{ state = 'running'; detail = ('lease ' + $results[0].Outcome); slots = $results.ToArray() } -Depth 5)
        )
        foreach ($t in $texts) {
            $t.Contains($script:Jit) | Should -BeFalse
            $t.Contains('SYNTHETIC-JIT-MARKER') | Should -BeFalse
        }
        # Status- and log-shaped files written from the result the way the supervisor writes them.
        [IO.File]::WriteAllText((Join-Path $TestDrive 'status.json'), (ConvertTo-Json -InputObject @{ lease = $results[0] } -Compress -Depth 5))
        $results[0] | Export-Clixml -LiteralPath (Join-Path $TestDrive 'result.clixml')
        Add-Content -LiteralPath (Join-Path $TestDrive 'supervisor.log') -Value ('lease {0} {1} {2}' -f $results[0].LeaseId, $results[0].Outcome, $results[0])
        foreach ($f in Get-ChildItem -LiteralPath $TestDrive -File) {
            [IO.File]::ReadAllText($f.FullName).Contains($script:Jit) | Should -BeFalse -Because $f.Name
        }
        Get-Secret $results[0].JitConfig | Should -BeExactly $script:Jit
    }

    It 'has no code that logs, writes files or prints' {
        $source = [IO.File]::ReadAllText($script:ModulePath)
        $words = @('Write-Host', 'Write-Output', 'Write-Verbose', 'Write-Warning', 'Write-Information', 'Write-Debug', 'Write-Error',
            'Out-File', 'Out-Host', 'Set-Content', 'Add-Content', 'Export-Clixml', 'Export-Csv', 'Start-Transcript', 'New-Item',
            'WriteAll', 'AppendAll', 'FileStream', 'Tee-Object')
        foreach ($word in $words) {
            $source.Contains($word) | Should -BeFalse -Because $word
        }
    }

    It 'never gives the reply or the JIT config to a command as a parameter value' {
        # Module logging (event 4103) records the parameter values of every
        # command a module runs. The variables that hold reply or JIT bytes are
        # read by .NET calls and returned, never bound to a command.
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:ModulePath, [ref]$null, [ref]$null)
        $held = @('jit', 'out', 'r', 'stdout', 'buf', 'secret', 'writeTo', 'clear')
        $members = @('Jit', 'Stdout')
        $commands = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true))
        $commands.Count | Should -BeGreaterThan 10
        $found = New-Object 'System.Collections.Generic.List[string]'
        foreach ($c in $commands) {
            foreach ($e in @($c.CommandElements | Select-Object -Skip 1)) {
                $uses = @($e.FindAll({
                            param($n)
                            ($n -is [Management.Automation.Language.VariableExpressionAst] -and $held -contains $n.VariablePath.UserPath) -or
                            ($n -is [Management.Automation.Language.MemberExpressionAst] -and $members -contains $n.Member.Extent.Text)
                        }, $true))
                if ($uses.Count -gt 0) { $found.Add(('line {0}: {1}' -f $c.Extent.StartLineNumber, $c.Extent.Text)) }
            }
        }
        $found.ToArray() | Should -BeNullOrEmpty
    }
}
