# Shared setup for the broker client tests (supervisor/broker/aap-broker.psm1).
# Dot-sourced from each *.Tests.ps1 BeforeAll. No test starts wsl.exe: replies
# come from a fake invoker. Broker replies are built as dictionaries and
# written by the module's own serializer.

$script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:ModulePath = Join-Path $script:Repo 'supervisor\broker\aap-broker.psm1'
Import-Module $script:ModulePath -Force
$script:Module = Get-Module aap-broker
$script:Fixtures = Join-Path $script:Repo 'parity\contracts\fixtures\broker'
$script:System32 = 'C:\Windows\System32'
# The synthetic JIT config: a marker within the schema's jit_config charset.
$script:Jit = 'SYNTHETIC-JIT-MARKER-' + [guid]::NewGuid().ToString('n')
$script:LeaseId = 'l-55555555555555555555555555555555'
$script:OtherLeaseId = 'l-66666666666666666666666666666666'
$script:RunnerName = 'aap-w-4-3-1a2b3c4d'
$script:LeaseArgs = @{
    LeaseId         = $script:LeaseId
    ReservationId   = 'r-1a2b3c4d000000b1'
    LeaseGeneration = 3
    Slot            = 4
    RunnerProfile   = 'win25-vs2026-x64'
    ImageGeneration = 'win25-vs2026-x64/20261007.264.1-aap.1'
}
$script:Sent = New-Object 'System.Collections.Generic.List[string]'
$script:Timeouts = New-Object 'System.Collections.Generic.List[int]'
$script:Reply = $null
$script:LastStdout = $null

# Compact JSON exactly as the module writes requests.
function ConvertTo-Wire($Map) {
    return & $script:Module { param($m) ConvertTo-AapBrokerJson $m } $Map
}

function New-LeaseReply {
    param([string]$LeaseId = $script:LeaseId, [string]$Result = 'issued', [string]$Reason = 'ok', $RunnerId = 23,
        $RunnerName = $script:RunnerName, $ExpiresAt = '2026-10-19T18:10:00Z', $Jit = $script:Jit)
    return [ordered]@{
        schema = 1; kind = 'lease_response'; lease_id = $LeaseId; result = $Result; reason = $Reason
        runner_id = $RunnerId; runner_name = $RunnerName; expires_at = $ExpiresAt; jit_config = $Jit
    }
}

function New-RefusedReply([string]$Reason) {
    return New-LeaseReply -Result 'refused' -Reason $Reason -RunnerId $null -RunnerName $null -ExpiresAt $null -Jit $null
}

function New-ReleaseReply([string]$Result, [string]$Reason, [string]$LeaseId = $script:LeaseId) {
    return [ordered]@{ schema = 1; kind = 'release_response'; lease_id = $LeaseId; result = $Result; reason = $Reason }
}

function New-StatusReply([string]$Result, [string]$Reason, $Runner) {
    return [ordered]@{ schema = 1; kind = 'status_response'; lease_id = $script:LeaseId; result = $Result; reason = $Reason; runner = $Runner }
}

function New-Result([string]$Text, [int]$ExitCode = 0) {
    return [pscustomobject]@{ ExitCode = $ExitCode; Stdout = [Text.Encoding]::UTF8.GetBytes($Text); TimedOut = $false; Overflow = $false }
}

# The fake wsl.exe: records the request and the timeout, answers $script:Reply
# (a dictionary, a text, a result object, or a script block that throws).
$script:Fake = {
    param([byte[]]$StdIn, [int]$TimeoutSeconds)
    $script:Sent.Add([Text.Encoding]::ASCII.GetString($StdIn))
    $script:Timeouts.Add($TimeoutSeconds)
    $answer = $script:Reply
    if ($answer -is [scriptblock]) { $answer = & $answer }
    if ($answer -is [Collections.IDictionary]) { $answer = ConvertTo-Wire $answer }
    if ($answer -is [string]) { $answer = New-Result $answer }
    $script:LastStdout = $answer.Stdout
    return $answer
}

function Invoke-Lease {
    $a = $script:LeaseArgs
    return Invoke-AapBrokerLease @a -Invoker $script:Fake
}

function Invoke-Release {
    return Invoke-AapBrokerRelease -LeaseId $script:LeaseId -Invoker $script:Fake
}

function Invoke-Status {
    return Invoke-AapBrokerStatus -LeaseId $script:LeaseId -Invoker $script:Fake
}

# What JitConfig.WriteTo writes, as text (tests only).
function Get-Secret($Secret) {
    $ms = New-Object IO.MemoryStream
    $Secret.WriteTo($ms)
    return [Text.Encoding]::ASCII.GetString($ms.ToArray())
}

function Test-Zeroed($Bytes) {
    return @($Bytes | Where-Object { $_ -ne 0 }).Count -eq 0
}

function Copy-Document($Document) {
    $copy = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
    foreach ($k in $Document.Keys) { $copy[$k] = $Document[$k] }
    return $copy
}

# The module's own process runner, started on a System32 tool.
function Invoke-Child([string]$Tool, [string]$Arguments, [byte[]]$StdIn = @(), [int]$TimeoutSeconds = 60) {
    $exe = Join-Path $script:System32 $Tool
    return & $script:Module {
        param($File, $ArgumentLine, $In, $Timeout)
        Invoke-AapBrokerProcess -FileName $File -Arguments $ArgumentLine -StdIn $In -TimeoutSeconds $Timeout -MaxStdoutBytes 20480
    } $exe $Arguments $StdIn $TimeoutSeconds
}

function Get-Text([byte[]]$Bytes) {
    return [Text.Encoding]::ASCII.GetString($Bytes).TrimEnd("`r", "`n")
}

function Reset-Fake {
    $script:Sent.Clear()
    $script:Timeouts.Clear()
    $script:LastStdout = $null
    $script:Reply = New-LeaseReply
}
