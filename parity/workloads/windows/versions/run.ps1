# windows/toolchain-versions: the version the job actually gets for each build tool (PATH resolution, JAVA_HOME,
# install records) equals the frozen baseline inventory. Sabotage no-llvm-on-path removes LLVM from PATH.
param([Parameter(Mandatory)][string]$Work, [Parameter(Mandatory)][string]$Id, [string]$Sabotage = '')
Import-Module (Join-Path $PSScriptRoot '..\Workload.psm1') -Force

function Get-ToolVersion([string]$Exe, [string[]]$Arguments, [string]$Pattern) {
    $p = if (Test-Path -LiteralPath $Exe -PathType Leaf) { $Exe } else { Resolve-Exe $Exe }
    if (-not $p) { return $null }
    $r = Invoke-Tool $p $Arguments -AllowFail -Quiet
    if ($r.Text -match $Pattern) { $Matches[1] } else { "unparsed: $(($r.Lines | Select-Object -First 1))" }
}

Invoke-Workload -Id $Id -Work $Work -Sabotage $Sabotage -Body {
    $env:NPM_CONFIG_UPDATE_NOTIFIER = 'false'
    $env:GOTOOLCHAIN = 'local'
    if ($Sabotage -eq 'no-llvm-on-path') { Remove-PathEntries 'PATH' '*\LLVM\*'; Write-Line 'sabotage no-llvm-on-path applied' }
    $v = [ordered]@{
        llvm   = Get-ToolVersion 'clang-cl.exe' @('--version') 'clang version (\S+)'
        cmake  = Get-ToolVersion 'cmake.exe' @('--version') 'cmake version (\S+)'
        ninja  = Get-ToolVersion 'ninja.exe' @('--version') '^(\S+)'
        rustc  = Get-ToolVersion 'rustc.exe' @('-V') 'rustc (\S+)'
        cargo  = Get-ToolVersion 'cargo.exe' @('-V') 'cargo (\S+)'
        rustup = Get-ToolVersion 'rustup.exe' @('--version') 'rustup (\S+)'
        node   = Get-ToolVersion 'node.exe' @('-v') 'v(\S+)'
        npm    = Get-ToolVersion 'npm.cmd' @('-v') '^(\S+)'
        python = Get-ToolVersion 'python.exe' @('--version') 'Python (\S+)'
        pip    = Get-ToolVersion 'python.exe' @('-B', '-I', '-m', 'pip', '--version') 'pip (\S+)'
        go     = Get-ToolVersion 'go.exe' @('version') 'go version go(\S+)'
        pwsh   = Get-ToolVersion 'pwsh.exe' @('--version') 'PowerShell (\S+)'
        git    = Get-ToolVersion 'git.exe' @('--version') 'git version (\S+)'
    }
    $v['windows_powershell'] = $PSVersionTable.PSVersion.ToString()
    $v['java'] = if ($env:JAVA_HOME) { Get-ToolVersion (Join-Path $env:JAVA_HOME 'bin\java.exe') @('-version') '\(build (\S+)\)' } else { $null }
    $bash = Resolve-Exe 'bash.exe'
    # never start the WSL launcher (System32\bash.exe or a WindowsApps alias): it is not a build shell
    $v['bash'] = if ($bash -and ($bash -like "$env:SystemRoot\*" -or $bash -like '*\WindowsApps\*')) { "<not-run:wsl-launcher $bash>" }
                 else { Get-ToolVersion 'bash.exe' @('--version') 'version (\S+)' }
    $v['wix'] = if ($env:WIX) { Get-ToolVersion (Join-Path $env:WIX 'bin\candle.exe') @('-?') 'version (\S+)' } else { $null }
    $v['vswhere'] = Get-ToolVersion (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe') @('-?') 'version (\d+\.\d+\.\d+)'
    foreach ($p in @(@('innosetup', 'Inno Setup*'), @('7zip', '7-Zip*'))) {
        $u = Find-Uninstall $p[1]
        $v[$p[0]] = if ($u) { $u.DisplayVersion } else { $null }
    }
    foreach ($k in $v.Keys) { Add-Fact "version.$k" $v[$k] (Get-Oracle "versions/$k") }
    $sdks = @((Invoke-Tool 'dotnet.exe' @('--list-sdks') -Quiet -AllowFail).Lines | ForEach-Object { ($_ -split ' ')[0] } | Where-Object { $_ })
    Add-Fact 'version.dotnet_sdks' ($sdks -join ',') ((Get-Oracle 'versions/dotnet_sdks') -join ',')
}
