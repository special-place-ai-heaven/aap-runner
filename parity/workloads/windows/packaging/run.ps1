# windows/package-*: the packaging tools the baseline installs, found the way consumers find them, build and the
# result is inspected.
#   -Tool wix: WiX 3 candle/light from %WIX%\bin build an x64 MSI (ICE validation on); the MSI tables are read back.
#   -Tool innosetup: ISCC from the Inno Setup install location builds a setup.exe; its version resource is read back.
#   -Tool 7zip: 7z.exe from the 7-Zip install location creates and lists an archive.
# Sabotage hide-tool removes the locator (WIX unset, install location not found): a missing tool must fail.
param(
    [Parameter(Mandatory)][string]$Work, [Parameter(Mandatory)][string]$Id, [string]$Sabotage = '',
    [Parameter(Mandatory)][ValidateSet('wix', 'innosetup', '7zip')][string]$Tool
)
Import-Module (Join-Path $PSScriptRoot '..\Workload.psm1') -Force

function Get-MsiProperty([string]$Msi, [string]$Name) {
    $i = New-Object -ComObject WindowsInstaller.Installer
    $db = $i.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $i, @($Msi, 0))
    $v = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$Name'"))
    [void]$v.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $v, $null)
    $rec = $v.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $v, $null)
    $val = if ($rec) { $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, @(1)) } else { $null }
    [void]$v.GetType().InvokeMember('Close', 'InvokeMethod', $null, $v, $null)
    $val
}

Invoke-Workload -Id $Id -Work $Work -Sabotage $Sabotage -Body {
    $hide = $Sabotage -eq 'hide-tool'
    if ($hide) { Write-Line 'sabotage hide-tool applied' }
    Copy-Source $PSScriptRoot 'pkg'
    Set-Location -LiteralPath (Join-Path $Work 'pkg')
    $report = @("tool=$Tool")
    switch ($Tool) {
        'wix' {
            if ($hide) { Remove-Item Env:\WIX -ErrorAction SilentlyContinue }
            if (-not $env:WIX) { throw 'WIX is not set: WiX Toolset 3 not found' }
            $bin = Join-Path $env:WIX 'bin'
            Invoke-Tool (Join-Path $bin 'candle.exe') @('-nologo', '-arch', 'x64', 'product.wxs', '-out', 'product.wixobj') | Out-Null
            Invoke-Tool (Join-Path $bin 'light.exe') @('-nologo', '-spdb', 'product.wixobj', '-out', 'parity.msi') | Out-Null
            $msi = Join-Path (Get-Location) 'parity.msi'
            foreach ($p in 'ProductName', 'ProductVersion', 'Manufacturer') {
                $v = Get-MsiProperty $msi $p
                $report += "msi.$p=$v"
            }
            Add-Fact 'msi.ProductName' (Get-MsiProperty $msi 'ProductName') 'AAP Parity Fixture'
        }
        'innosetup' {
            $u = if ($hide) { $null } else { Find-Uninstall 'Inno Setup*' }
            if (-not $u) { throw 'Inno Setup install location not found' }
            Add-Observation 'innosetup.DisplayVersion' $u.DisplayVersion
            Invoke-Tool (Join-Path $u.InstallLocation 'ISCC.exe') @('/Q', 'setup.iss') | Out-Null
            $vi = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path (Get-Location) 'parity-setup.exe'))
            Add-Fact 'setup.ProductName' "$($vi.ProductName)".Trim() 'AAP Parity Fixture'  # Inno pads the strings
            $report += "setup.ProductName=$("$($vi.ProductName)".Trim())", "setup.ProductVersion=$("$($vi.ProductVersion)".Trim())"
        }
        '7zip' {
            $u = if ($hide) { $null } else { Find-Uninstall '7-Zip*' }
            if (-not $u) { throw '7-Zip install location not found' }
            Add-Observation '7zip.DisplayVersion' $u.DisplayVersion
            $7z = Join-Path $u.InstallLocation '7z.exe'
            Invoke-Tool $7z @('a', '-bd', 'parity.7z', 'payload.txt') | Out-Null
            $paths = @((Invoke-Tool $7z @('l', '-slt', 'parity.7z')).Lines | Where-Object { $_ -like 'Path = *' } | Select-Object -Skip 1)
            Add-Fact '7z.entries' ($paths -join ',') 'Path = payload.txt'
            $report += $paths | ForEach-Object { "7z.$_" }
        }
    }
    Write-Report $report
}
