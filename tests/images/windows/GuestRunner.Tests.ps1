# guest/AapGuestRunner.ps1 run locally as a child process (Windows PowerShell 5.1, no window) against fake upstream
# scripts in a temp work root. Only the 'scripts' request kind, the inner half of an elevated request and request
# validation run here: the actions change the machine (bcdedit, services, sysprep) and the scheduled-task half of an
# elevated request registers a task, so those run only inside a build guest. Pester 5 on Windows PowerShell 5.1 and 7.

BeforeAll {
    . (Join-Path $PSScriptRoot 'WinImageTestHelpers.ps1')
    Import-Module (Get-TestModulePath) -Force
    $script:Runner = Join-Path (Get-TestRepo) 'images\windows\guest\AapGuestRunner.ps1'
    $script:Ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    function New-Work {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 8))
        $scripts = Join-Path $root 'src\images\windows\scripts\build'
        [void][IO.Directory]::CreateDirectory($scripts)
        return [pscustomobject]@{ Root = $root; Scripts = $scripts; Out = (Join-Path $root 'out.txt') }
    }
    function Add-Script($Work, [string]$Name, [string]$Body) {
        $p = Join-Path $Work.Scripts $Name
        [IO.File]::WriteAllText($p, $Body)
        return [ordered]@{ name = $Name; dir = 'build'; sha256 = (Get-FileSha $p) }
    }
    function Invoke-Runner($Work, $Request, [string]$Extra = '') {
        $req = Join-Path $Work.Root 'request.json'
        [IO.File]::WriteAllText($req, (ConvertTo-Json -InputObject $Request -Depth 6))
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $script:Ps
        $psi.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script:Runner`" -RequestPath `"$req`" -WorkRoot `"$($Work.Root)`" $Extra"
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        # A guest's Windows PowerShell sees the machine module path, not the one PowerShell 7 hands its children.
        $psi.EnvironmentVariables['PSModulePath'] = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd(); $null = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        return $out.Trim()
    }
    function New-Request([string]$Phase, $Scripts, [int[]]$Codes = @(0)) {
        [ordered]@{ schema = 1; phase = $Phase; kind = 'scripts'; scripts = @($Scripts); env = [ordered]@{ IMAGE_FOLDER = 'C:\image'; INSTALL_VS_2026 = 'true' }
            execution_policy = 'bypass'; valid_exit_codes = $Codes; pause_before_seconds = 0 }
    }
}

Describe 'guest provisioning runner' {
    It 'runs the planned scripts in order with the phase environment and reports a reply the host accepts' {
        $wk = New-Work
        $a = Add-Script $wk 'Install-A.ps1' "Add-Content -LiteralPath '$($wk.Out)' -Value ('A ' + `$env:IMAGE_FOLDER + ' ' + `$env:INSTALL_VS_2026)"
        $b = Add-Script $wk 'Install-B.ps1' "Add-Content -LiteralPath '$($wk.Out)' -Value 'B'; exit 3010"
        $text = Invoke-Runner $wk (New-Request 'p13' @($a, $b) @(0, 3010))
        $r = ConvertFrom-AapGuestReply -Text $text -Phase 'p13'
        $r.status | Should -Be 'ok'
        @($r.scripts.name) | Should -Be @('Install-A.ps1', 'Install-B.ps1')
        @($r.scripts.exit_code) | Should -Be @(0, 3010)
        $r.scripts[0].sha256 | Should -Be $a.sha256
        Get-Content $wk.Out | Should -Be @('A C:\image true', 'B')
        Test-Path (Join-Path $wk.Root 'logs\p13-Install-A.ps1.log') | Should -BeTrue
    }
    It 'refuses a script whose bytes differ from the pinned hash, and does not run it' {
        $wk = New-Work
        $a = Add-Script $wk 'Install-A.ps1' "Set-Content -LiteralPath '$($wk.Out)' -Value 'ran'"
        $a.sha256 = 'e' * 64
        $r = ConvertFrom-AapGuestReply -Text (Invoke-Runner $wk (New-Request 'p08' @($a))) -Phase 'p08'
        $r.status | Should -Be 'failed'
        $r.message | Should -Match 'SHA-256 differs'
        Test-Path $wk.Out | Should -BeFalse
    }
    It 'stops at the first exit code upstream does not accept' {
        $wk = New-Work
        $a = Add-Script $wk 'Install-A.ps1' 'exit 3010'
        $b = Add-Script $wk 'Install-B.ps1' "Set-Content -LiteralPath '$($wk.Out)' -Value 'ran'"
        $r = ConvertFrom-AapGuestReply -Text (Invoke-Runner $wk (New-Request 'p08' @($a, $b))) -Phase 'p08'
        $r.status | Should -Be 'failed'
        @($r.scripts).Count | Should -Be 1
        Test-Path $wk.Out | Should -BeFalse
    }
    It 'reports a script that throws as its non-zero exit code' {
        $wk = New-Work
        $a = Add-Script $wk 'Install-A.ps1' "throw 'upstream failure'"
        $r = ConvertFrom-AapGuestReply -Text (Invoke-Runner $wk (New-Request 'p08' @($a))) -Phase 'p08'
        $r.status | Should -Be 'failed'
        $r.scripts[0].exit_code | Should -Not -Be 0
    }
    It 'refuses a script name that leaves the scripts folder' {
        $wk = New-Work
        $r = ConvertFrom-AapGuestReply -Text (Invoke-Runner $wk (New-Request 'p08' @([ordered]@{ name = '..\..\evil.ps1'; dir = 'build'; sha256 = ('a' * 64) }))) -Phase 'p08'
        $r.status | Should -Be 'failed'
        $r.message | Should -Match 'script name'
    }
    It 'runs each script through the Packer wrapper: <Case>' -TestCases @(
        @{ Case = 'a script that ends without a native command exits 0'; Body = "Write-Output 'done'"; Code = 0 }
        @{ Case = 'the last native exit code is the script exit code'; Body = "& (Join-Path `$env:SystemRoot 'System32\cmd.exe') /c exit 5"; Code = 5 }
        @{ Case = 'a script that throws exits 1'; Body = "throw 'upstream failure'"; Code = 1 }) {
        $wk = New-Work
        $a = Add-Script $wk 'Install-A.ps1' $Body
        $r = ConvertFrom-AapGuestReply -Text (Invoke-Runner $wk (New-Request 'p08' @($a) @(0, 1, 5))) -Phase 'p08'
        $r.scripts[0].exit_code | Should -Be $Code
        Test-Path (Join-Path $wk.Root 'logs\p08-Install-A.ps1.log.wrapper.ps1') | Should -BeTrue
    }
    It 'passes environment values literally, quotes and dollar signs included' {
        $wk = New-Work
        $a = Add-Script $wk 'Install-A.ps1' "Set-Content -LiteralPath '$($wk.Out)' -Value `$env:AAP_Q"
        $req = New-Request 'p08' @($a)
        $req.env = [ordered]@{ AAP_Q = 'O''Brien $HOME `n' }
        (ConvertFrom-AapGuestReply -Text (Invoke-Runner $wk $req) -Phase 'p08').status | Should -Be 'ok'
        Get-Content $wk.Out | Should -BeExactly 'O''Brien $HOME `n'
    }
    It 'refuses an environment value that is not printable ASCII' {
        $wk = New-Work
        $a = Add-Script $wk 'Install-A.ps1' "Set-Content -LiteralPath '$($wk.Out)' -Value 'ran'"
        $req = New-Request 'p08' @($a)
        $req.env = [ordered]@{ AAP_Q = [regex]::Unescape('caf\u00e9') }
        $r = ConvertFrom-AapGuestReply -Text (Invoke-Runner $wk $req) -Phase 'p08'
        $r.status | Should -Be 'failed'
        $r.message | Should -Match 'environment entry AAP_Q'
        Test-Path $wk.Out | Should -BeFalse
    }
    It 'as the inner half of an elevated request, writes its reply to the reply file' {
        $wk = New-Work
        $a = Add-Script $wk 'Install-A.ps1' "Set-Content -LiteralPath '$($wk.Out)' -Value 'ran'"
        $req = New-Request 'p13' @($a)
        $req.elevated = $true
        $reply = Join-Path $wk.Root 'reply-p13.json'
        Invoke-Runner $wk $req "-Inner -ReplyPath `"$reply`"" | Should -BeNullOrEmpty
        $r = ConvertFrom-AapGuestReply -Text ([IO.File]::ReadAllText($reply)) -Phase 'p13'
        $r.status | Should -Be 'ok'
        Get-Content $wk.Out | Should -Be 'ran'
    }
    It 'refuses an unknown action and a malformed request with a failed reply' {
        $wk = New-Work
        $r = ConvertFrom-AapGuestReply -Text (Invoke-Runner $wk ([ordered]@{ schema = 1; phase = 'p05'; kind = 'action'; action = 'format-c'; vars = @{ image_folder = 'C:\image' } })) -Phase 'p05'
        $r.status | Should -Be 'failed'
        $r = ConvertFrom-AapGuestReply -Text (Invoke-Runner $wk ([ordered]@{ schema = 1; phase = '../x'; kind = 'scripts' })) -Phase 'unknown'
        $r.status | Should -Be 'failed'
    }
}
