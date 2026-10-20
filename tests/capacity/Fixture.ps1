# Helpers for the capacity allocator tests. Pester 5, Windows PowerShell 5.1 and PowerShell 7.5+.
# Every capacity folder is a fresh folder under $TestDrive with inheritance cut and only SYSTEM,
# Administrators and the test user, so the relaxed trust mode (current user trusted) applies.

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:CapModule = Join-Path $script:RepoRoot 'supervisor\capacity\AapCapacity.psm1'
$script:FixtureDir = Join-Path $script:RepoRoot 'parity\contracts\fixtures\allocator'
$script:Validator = Join-Path $script:RepoRoot 'parity\contracts\validate.py'
$script:UserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$script:WinGen = 'win25-vs2026-x64/20261007.264.1-aap.1'
$script:Now = [DateTime]::SpecifyKind([datetime]'2026-10-20T10:00:00', [DateTimeKind]::Utc)

function ConvertFrom-CapJson([string]$Text) {
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { return , (ConvertFrom-Json -InputObject $Text -DateKind String) }
    return , (ConvertFrom-Json -InputObject $Text)
}

function Read-CapJson([string]$Path) { ConvertFrom-CapJson ([IO.File]::ReadAllText($Path)) }

function Write-CapText([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false))) }

function Write-CapJson([string]$Path, $Object) { Write-CapText $Path (ConvertTo-Json -InputObject $Object -Depth 20 -Compress) }

function Get-CapDoc([string]$Root) { Read-CapJson (Join-Path $Root 'allocator.json') }

function Get-CapLive($Doc) { @($Doc.reservations | Where-Object { $_.state -ne 'reconciled' }) }

function Get-CapRes($Doc, [string]$Id) { @($Doc.reservations | Where-Object { $_.reservation_id -eq $Id })[0] }

# A capacity folder: inheritance cut, SYSTEM, Administrators and the test user only (icacls, never
# Set-Acl: a second Set-Acl under Pester fails for want of SeSecurityPrivilege).
function New-CapRoot {
    $dir = Join-Path $TestDrive ('cap-' + [guid]::NewGuid().ToString('n').Substring(0, 10))
    [void](New-Item -ItemType Directory -Path $dir)
    $out = & icacls.exe $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' "*$($script:UserSid):(OI)(CI)F" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "icacls failed: $out" }
    $dir
}

function Set-CapNow([string]$Time) { $script:Now = [DateTime]::ParseExact($Time, "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal') }

function Add-CapSeconds([int]$Seconds) { $script:Now = $script:Now.AddSeconds($Seconds) }

function Get-CapTime { $script:Now.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture) }

# One volume with every tier and a disk budget of Disk GiB (available Disk + floor 10, nothing
# held), unless -Volumes gives the layout or -NoStorage leaves it unconfigured.
function New-CapHostInfo([int]$Cpu = 32, [int]$Mem = 96, [int]$Disk = 2000, [int]$Io = 1000, [int]$Ctl = 1, [object[]]$Volumes = $null, [switch]$NoStorage) {
    if ($NoStorage) { $Volumes = @() }
    elseif ($null -eq $Volumes) { $Volumes = @(New-CapVolume 'e1' @('base', 'clone', 'scratch', 'staging') ($Disk + 10) 10 0) }
    @{ cpu_cores = $Cpu; mem_gib = $Mem; volumes = $Volumes; io_mbps = $Io; control_distro_mem_gib = $Ctl }
}

function New-CapVolume([string]$Tail, [string[]]$Tiers, [int]$Available, [int]$Floor = 10, [int]$Held = 0) {
    @{ volume_guid = '00000000-0000-4000-8000-0000000000' + $Tail; tiers = $Tiers; available_gib = $Available; floor_gib = $Floor; held_gib = $Held }
}

# status.json as the supervisor writes it (schema 4): the manager's applied limits and slots.
function New-CapStatus([int]$Count, [int]$Cpus, [int]$Mem, [string[]]$SlotStates, [string]$SampledAt = (Get-CapTime), [string]$State = 'running') {
    $slots = @()
    for ($i = 0; $i -lt $SlotStates.Count; $i++) { $slots += [pscustomobject]@{ slot = $i + 1; state = $SlotStates[$i]; job = '' } }
    [pscustomobject]@{ state = $State; schema = 4; runner_count = $Count; job_cpus = $Cpus; job_memory_gib = $Mem; sampled_at = $SampledAt; slots = $slots }
}

function New-CapProof([string]$Kind = 'vm', $Dereg = $true, [string]$At = (Get-CapTime)) {
    if ($Kind -eq 'legacy') { return [ordered]@{ kind = 'legacy'; observed_at = $At; manager_reports_slot_gone = $true; runner_deregistered = $Dereg } }
    [ordered]@{ kind = 'vm'; observed_at = $At; vm_absent = $true; disks_absent = $true; vm_files_absent = $true; runner_deregistered = $Dereg }
}

function New-CapVmId { [guid]::NewGuid().ToString() }

# Initialize, set the Windows generation, adopt the legacy pool (LegacySlots idle slots at the
# Linux per-runner share, or a stopped manager for 0).
function New-CapAllocator {
    param([string]$Mode = 'even', [int]$Linux = 3, [int]$Windows = 2, $LinuxShare = $null, $WindowsShare = $null,
        [hashtable]$HostInfo = (New-CapHostInfo), [int]$Reserve = 10, [int]$LegacySlots = 0)
    $root = New-CapRoot
    $r = Initialize-AapAllocator -Root $root -HostInfo $HostInfo -Linux $Linux -Windows $Windows -ShareMode $Mode -LinuxShare $LinuxShare -WindowsShare $WindowsShare -HostReservePercent $Reserve
    if (-not $r.Ok) { throw "initialize: $($r.Reason) $($r.Detail)" }
    $r = Set-AapProfileCounts -Root $root -Linux $Linux -Windows $Windows -WindowsGeneration $script:WinGen
    if (-not $r.Ok) { throw "generation: $($r.Reason) $($r.Detail)" }
    if ($LegacySlots -eq 0) {
        $r = Register-AapLegacySlots -Root $root -ManagerStopped
    } else {
        $l = (Get-AapAllocatorState -Root $root).Profiles.linux
        $r = Register-AapLegacySlots -Root $root -ManagerVersion 'manager-2' -ManagerStatus (New-CapStatus $LegacySlots ($l.EachCpus * $LegacySlots) ($l.EachMemGib * $LegacySlots) (@('idle') * $LegacySlots) -State 'idle')
    }
    if (-not $r.Ok) { throw "adopt: $($r.Reason) $($r.Detail)" }
    $root
}

# A Windows VM admitted and moved to ready (or busy) with a vm id.
function New-CapVm([string]$Root, [switch]$Busy, [int]$Overhead = 512, [int]$Clone = 150, [int]$Scratch = 40, [int]$Io = 100) {
    $r = Request-AapReservation -Root $Root -Profile windows -MemOverheadMib $Overhead -CloneGib $Clone -ScratchGib $Scratch -IoMbps $Io
    if (-not $r.Ok) { throw "request: $($r.Reason) $($r.Detail)" }
    $res = $r.Reservation
    $s = Set-AapSlotState -Root $Root -ReservationId $res.reservation_id -LeaseGeneration $res.lease_generation -State ready -VmId (New-CapVmId)
    if (-not $s.Ok) { throw "ready: $($s.Reason) $($s.Detail)" }
    if ($Busy) {
        $s = Set-AapSlotState -Root $Root -ReservationId $res.reservation_id -LeaseGeneration $res.lease_generation -State busy
        if (-not $s.Ok) { throw "busy: $($s.Reason) $($s.Detail)" }
    }
    $s.Reservation
}

# Moves a live VM reservation to reconciled through the legal edges with a vm proof.
function Remove-CapVm([string]$Root, $Res) {
    $path = @{ ready = @('draining', 'collecting', 'deleting'); busy = @('collecting', 'deleting'); draining = @('collecting', 'deleting')
        collecting = @('deleting'); quarantined = @('deleting'); deleting = @() }
    foreach ($to in $path[(Get-CapRes (Get-CapDoc $Root) $Res.reservation_id).state]) {
        $s = Set-AapSlotState -Root $Root -ReservationId $Res.reservation_id -LeaseGeneration $Res.lease_generation -State $to
        if (-not $s.Ok) { throw "$to`: $($s.Reason) $($s.Detail)" }
    }
    Complete-AapTeardown -Root $Root -ReservationId $Res.reservation_id -LeaseGeneration $Res.lease_generation -Proof (New-CapProof 'vm')
}

# validate.py in file mode over many files at once: path -> @{ Ok; Message }.
function Invoke-CapReference([string[]]$Paths) {
    $ErrorActionPreference = 'Continue'
    $out = @(& python -B -I $script:Validator allocator @Paths 2>&1 | ForEach-Object { "$_" })
    $map = @{}
    foreach ($p in $Paths) {
        $ok = @($out | Where-Object { $_ -ceq "ok    $p" })
        $bad = @($out | Where-Object { $_.StartsWith("FAIL  ${p}: ", [StringComparison]::Ordinal) })
        if ($ok.Count) { $map[$p] = @{ Ok = $true; Message = $null } }
        elseif ($bad.Count) { $map[$p] = @{ Ok = $false; Message = $bad[0].Substring(("FAIL  ${p}: ").Length) } }
        else { throw "validate.py gave no verdict for $p`: $($out -join ' | ')" }
    }
    $map
}

# The fixture's instance, extracted byte-exactly by Python (no PowerShell re-serialization).
function Export-CapInstance([string]$Fixture, [string]$Out) {
    $ErrorActionPreference = 'Continue'
    $code = 'import json,sys; d=json.load(open(sys.argv[1],encoding=''utf-8-sig'')); json.dump(d[''instance''],open(sys.argv[2],''w'',encoding=''utf-8''))'
    & python -B -I -c $code $Fixture $Out
    if ($LASTEXITCODE -ne 0) { throw "could not extract $Fixture" }
    (Read-CapJson $Fixture).expect
}

# A hidden child PowerShell of the same edition running Body (saved as a plain .ps1) against the module,
# optionally after a barrier file and with a fault point; stdout is the body's JSON result.
function Start-CapChild([string]$Root, [string]$Body, [string]$Fault = '', [string]$Go = '', [string]$Ready = '') {
    $script = Join-Path $TestDrive 'child.ps1'
    if (-not (Test-Path -LiteralPath $script)) {
        Write-CapText $script @'
param([string]$Module, [string]$Root, [string]$BodyFile, [string]$Fault, [string]$Go, [string]$Ready)
$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
Import-Module $Module
$PSDefaultParameterValues['*-Aap*:RelaxedTrustForTests'] = $true
if ($Fault) { & (Get-Module AapCapacity) { param($f) $script:Fault = $f } $Fault }
if ($Ready) { [IO.File]::WriteAllText($Ready, 'ready') }
if ($Go) { while (-not [IO.File]::Exists($Go)) { Start-Sleep -Milliseconds 2 } }
$result = & $BodyFile $Root
[Console]::Out.WriteLine((ConvertTo-Json -InputObject $result -Depth 10 -Compress))
'@
    }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Process -Id $PID).Path
    $bodyFile = Join-Path $TestDrive ('body-' + [guid]::NewGuid().ToString('N') + '.ps1')
    Write-CapText $bodyFile $Body
    $argv = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script, $script:CapModule, $Root, $bodyFile, $Fault, $Go, $Ready)
    $psi.Arguments = ($argv | ForEach-Object { if ($_ -eq '') { '""' } else { '"' + $_ + '"' } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi)
    [pscustomobject]@{ Process = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync() }
}

function Wait-CapChild($Child, [int]$TimeoutSeconds = 120) {
    if (-not $Child.Process.WaitForExit($TimeoutSeconds * 1000)) {
        $Child.Process.Kill()
        throw "child $($Child.Process.Id) did not exit in $TimeoutSeconds s"
    }
    $Child.Process.WaitForExit()
    $out = $Child.Out.Result.Trim()
    $result = $null
    if ($out) { $result = ConvertFrom-CapJson (($out -split "`r?`n")[-1]) }
    [pscustomobject]@{ ExitCode = $Child.Process.ExitCode; Result = $result; StdErr = $Child.Err.Result }
}
