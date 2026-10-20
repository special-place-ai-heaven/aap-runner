# windows/python-wheel: a CPython extension built with MSVC against the job's default Python (headers and
# pythonXY.lib), packed as a wheel, installed with pip offline (--no-index) and imported.
# Sabotage no-python-lib drops the Python libs folder from the link, so pythonXY.lib is missing.
param([Parameter(Mandatory)][string]$Work, [Parameter(Mandatory)][string]$Id, [string]$Sabotage = '')
Import-Module (Join-Path $PSScriptRoot '..\Workload.psm1') -Force

Invoke-Workload -Id $Id -Work $Work -Sabotage $Sabotage -Body {
    $env:PIP_DISABLE_PIP_VERSION_CHECK = '1'
    $env:PIP_NO_CACHE_DIR = '1'
    $env:PYTHONDONTWRITEBYTECODE = '1'
    $py = Resolve-Exe 'python.exe'
    if (-not $py) { throw 'python.exe not found on PATH' }
    if (-not $Sabotage) { Add-Fact 'python.dir' (Split-Path -Parent $py) (Get-Oracle 'bare_path/python_dir') }
    Copy-Source $PSScriptRoot 'ext'
    Set-Location -LiteralPath (Join-Path $Work 'ext')
    $info = (Invoke-Tool $py @('-B', '-I', 'build_wheel.py', 'info')).Lines
    $pyd = 'parity_ext' + $info[2]
    Enter-DevEnv -Arch x64 | Out-Null
    $link = @('/link', "/LIBPATH:$($info[1])")
    if ($Sabotage -eq 'no-python-lib') { $link = @(); Write-Line 'sabotage no-python-lib applied' }
    Invoke-Tool cl.exe (@('/nologo', '/W3', '/LD', '/MD', '/O2', "/I$($info[0])", 'parity_ext.c', "/Fe$pyd") + $link) | Out-Null
    $whl = (Invoke-Tool $py @('-B', '-I', 'build_wheel.py', 'wheel', $pyd, 'dist')).Lines | Select-Object -Last 1
    Invoke-Tool $py @('-B', '-I', '-m', 'pip', 'install', '--no-index', '--no-deps', '--no-compile', '--target', 'site', $whl) | Out-Null
    $out = (Invoke-Tool $py @('-B', '-I', 'check.py', (Join-Path $Work 'ext\site'))).Lines -join ' '
    Add-Fact 'import.output' $out 'parity_ext.add(2, 3) = 5'
    $pe = Get-PeInfo $pyd
    Add-Fact 'pyd.machine' $pe.Machine 'x64'
    $entries = Get-ZipEntries $whl
    Write-Report (@("wheel=$(Split-Path -Leaf $whl)", "output=$out", "pyd.machine=$($pe.Machine)") + ($entries | ForEach-Object { "wheel.entry=$_" }))
}
