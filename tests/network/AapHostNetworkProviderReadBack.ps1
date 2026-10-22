# The child session of the provider read-back test in AapHostNetworkCheck.Tests.ps1 (host-network-module.md, Read-back): one
# of the four production providers reads a VM's adapter back from a faked Hyper-V, and the shared check judges what it read.
# Run as `-File` in a fresh process, so nothing is global but what production makes global:
#   - the builder or backend module and its provider module, imported globally as a supervisor or a build session imports them;
#   - a fake Hyper-V module, named Hyper-V because the providers call Hyper-V\<cmdlet>;
#   - a consumer module that imports the check into its own scope and exports only its own function, as every builder and
#     backend does (a script run with -File has no scope of its own: a plain Import-Module here would be global).
# A provider module is a module of its own, so it cannot see the check's functions. One that called one would throw
# CommandNotFound here, exactly as it does in production.
# Prints one line per result and exits 0:
#   ISOLATED           a module of its own cannot see the check's functions (the harness itself holds)
#   READ <text>        the MacAddress the provider returned, as Hyper-V showed it (the provider passes it through)
#   GOOD <problems>    the check's problems for the declared MAC, joined by ' | ' (empty: check 2 and the rest pass)
#   BAD <problems>     the same for an adapter whose MAC is another one's, in the same twelve-digit form
param(
    [Parameter(Mandatory)][string]$Repo,
    [Parameter(Mandatory)][string]$Check,
    [Parameter(Mandatory)][ValidateSet('win-image', 'ubuntu-image', 'win-backend', 'lin-backend')][string]$Provider,
    [Parameter(Mandatory)][string]$StatePath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# What the test gives the faked Hyper-V: the declaration (as the module's Attach would return it), the conformant extended
# port ACLs in Hyper-V's own property names, and the MAC text Hyper-V shows for the declared MAC and for another one.
$state = [IO.File]::ReadAllText($StatePath) | ConvertFrom-Json
$decl = $state.declaration

# The consumer: the check is imported into this module's scope only, and only Get-ConsumerProblems leaves it.
New-Module -Name 'AapConsumer' -ArgumentList $Check -ScriptBlock {
    param($CheckPath)
    Import-Module $CheckPath
    function Get-ConsumerProblems { param($Declaration, $Adapters) @(Get-AapHostNetworkAdapterProblems -Declaration $Declaration -Adapters $Adapters) }
    Export-ModuleMember -Function Get-ConsumerProblems
} | Import-Module -Global

# One VM with one adapter on the declared VM's switch, and the host's own adapter on that switch (not a VM); every cmdlet a
# provider's read-back calls, with the values as Hyper-V shows them (text for the enums, the MAC as twelve hex digits).
$vm = [pscustomobject]@{ Id = [string]$decl.vm_id; Name = [string]$decl.vm_name; State = 'Off'; Generation = 2; CheckpointType = 'Disabled'
    AutomaticStopAction = 'TurnOff'; AutomaticStartAction = 'Nothing'; ConfigurationLocation = 'C:\vm'; SnapshotFileLocation = 'C:\vm'
    SmartPagingFilePath = 'C:\vm'; ProcessorCount = 2; MemoryStartup = [long]4GB; DynamicMemoryEnabled = $false }
$switchId = [guid]::NewGuid().ToString()
$switch = [pscustomobject]@{ Id = $switchId; Name = [string]$state.switchName; SwitchType = 'Internal' }
$nic = [pscustomobject]@{ Name = "aap-guest-$($decl.vm_id)"; VMId = [string]$decl.vm_id; VMName = [string]$decl.vm_name; IsManagementOs = $false
    SwitchId = $switchId; SwitchName = [string]$state.switchName; MacAddress = [string]$state.macRead; DhcpGuard = 'On'; RouterGuard = 'On'
    MacAddressSpoofing = 'Off'; PortMirroringMode = 'None'; VlanSetting = [pscustomobject]@{ OperationMode = 'Untagged' }; StormLimit = 100 }
$hostNic = [pscustomobject]@{ Name = "vEthernet ($($state.switchName))"; VMId = '00000000-0000-0000-0000-000000000000'; VMName = ''; IsManagementOs = $true
    SwitchId = $switchId; SwitchName = [string]$state.switchName; MacAddress = '00155D010203' }
$world = @{ Vm = $vm; Switch = $switch; Nic = $nic; All = @($nic, $hostNic); Acls = @($state.acls) }
New-Module -Name 'Hyper-V' -ArgumentList $world -ScriptBlock {
    param($World)
    function Get-VM { [CmdletBinding()] param([string]$Id) $World.Vm }
    function Get-VMNetworkAdapter { [CmdletBinding()] param($VM, [switch]$All) if ($All) { $World.All } else { $World.Nic } }
    function Get-VMSwitch { [CmdletBinding()] param([string]$Id) $World.Switch }
    function Get-VMNetworkAdapterAcl { [CmdletBinding()] param($VMNetworkAdapter) }
    function Get-VMNetworkAdapterExtendedAcl { [CmdletBinding()] param($VMNetworkAdapter) $World.Acls }
    function Get-VMIntegrationService { [CmdletBinding()] param($VM) }
    function Get-VMFirmware { [CmdletBinding()] param($VM) [pscustomobject]@{ SecureBoot = 'On'; SecureBootTemplate = 'MicrosoftUEFICertificateAuthority' } }
    function Get-VMProcessor { [CmdletBinding()] param($VM) [pscustomobject]@{ ExposeVirtualizationExtensions = $true } }
    function Get-VMHardDiskDrive { [CmdletBinding()] param($VM) }
    function Get-VMDvdDrive { [CmdletBinding()] param($VM) }
    function Get-VMComPort { [CmdletBinding()] param($VM) }
    function Get-VMGpuPartitionAdapter { [CmdletBinding()] param($VM) }
    function Get-VMAssignableDevice { [CmdletBinding()] param($VM) }
    Export-ModuleMember -Function Get-VM*
} | Import-Module -Global

# The builder or backend, then its provider, as a supervisor or a build session loads them (the provider's own check for the
# builder's helpers needs the builder's exports global).
switch ($Provider) {
    'win-image' { $modules = 'images\windows\AapWinImage.psm1', 'images\windows\AapWinImage.HyperV.psm1' }
    'ubuntu-image' { $modules = 'images\ubuntu-24.04\AapUbuntuImage.psm1', 'images\ubuntu-24.04\AapUbuntuImage.HyperV.psm1' }
    'win-backend' { $modules = 'supervisor\backends\windows\AapWinBackend.psm1', 'supervisor\backends\windows\AapWinBackend.HyperV.psm1' }
    'lin-backend' { $modules = 'supervisor\backends\linux\AapLinBackend.psm1', 'supervisor\backends\linux\AapLinBackend.HyperV.psm1' }
}
foreach ($m in $modules) { Import-Module (Join-Path $Repo $m) -Global }
# Only the fake answers as Hyper-V here: the real module, which a host may have, is never loaded (nothing reaches a real VM).
# A dynamic module's path is made up (a folder and a guid) and is no file; a real module's is.
$hyperV = @(Get-Module -Name 'Hyper-V')
if ($hyperV.Count -ne 1 -or $hyperV[0].ModuleType -ne 'Script' -or (Test-Path -LiteralPath $hyperV[0].Path)) { throw 'the fake is not the only Hyper-V module in this session' }

# The harness holds only if a module of its own cannot call the check; the provider's module is one.
New-Module -Name 'AapProviderCanary' -ScriptBlock {
    function Test-AapCanary { try { [void](Get-AapHostNetworkMacRange); 'LEAKED' } catch [Management.Automation.CommandNotFoundException] { 'ISOLATED' } }
    Export-ModuleMember -Function Test-AapCanary
} | Import-Module
Write-Output (Test-AapCanary)

# The provider's read-back: the op that returns the VM's adapters, in the contract's provider shape.
$arg = @{ VmId = [string]$decl.vm_id }
switch ($Provider) {
    'win-image' { $p = New-AapWinHyperVProvider; $read = { @(& $p.GetVmNetwork $arg) } }
    'ubuntu-image' { $p = New-AapUbuntuHyperVProvider -PythonPath (Join-Path $env:SystemRoot 'System32\cmd.exe'); $read = { @(& $p.GetVmNetwork $arg) } }
    'win-backend' { $p = New-AapWinHyperVProvider; $read = { @((& $p.GetVmConfig $arg).Adapters) } }
    'lin-backend' { $p = New-AapLinHyperVProvider; $read = { @((& $p.GetVmConfig $arg).Adapters) } }
}

function Write-Judged([string]$Label) {
    $adapters = @(& $read)
    Write-Output "READ $($adapters[0].MacAddress)"
    Write-Output "$Label $(@(Get-ConsumerProblems -Declaration $decl -Adapters $adapters) -join ' | ')"
}
Write-Judged 'GOOD'
$nic.MacAddress = [string]$state.macOther
Write-Judged 'BAD'
