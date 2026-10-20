# One guest management command over PowerShell Direct (guest-transport.md, Wire framing; security review H2), run by
# AapWinBackend.psm1 as a short-lived hidden child inside a job object (memory, CPU-time and wall caps, kill on close):
#   C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File <this file>
# Nothing travels on its command line. Stdin: four lines (VM id, guest user, per-clone password, host_cmd envelope), then
# exactly payload_bytes bytes (the JIT config for deliver_registration, nothing otherwise). Stdout: the agent's one reply
# line, nothing else. Exit 0 with no output: the guest could not be reached (a failed guest, not a hostile one). Any other
# exit: the remote side broke the contract, and the supervisor journals hostile_guest (code child_exit). A connection
# that drops mid-call (the guest rebooting, the VM stopping) is a failed guest too: exit 0 with no output.
# Guest output is deserialized here, never in the supervisor: anything but exactly one string, a remote host-UI call
# (refused: this host is non-interactive) or a flood that trips the job's caps ends this process. The envelope and the
# payload reach the remote runspace as pipeline input through the PowerShell API, never as script text, an argument
# list or a cmdlet parameter (event 4103 records those); the remote script writes them to the agent's stdin.
# NOT RUN against a VM by P10: the lab proof is P02.1.

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
# Windows PowerShell prepends the user's own module folder at start; before any module loads, only the machine module
# path is left, so nothing from the operator's folders runs here.
$env:PSModulePath = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
$stdout = [Console]::OpenStandardOutput()
[Console]::SetOut([IO.TextWriter]::Null)
[Console]::SetError([IO.TextWriter]::Null)
$stdin = [Console]::OpenStandardInput()

function Read-AapCallLine([IO.Stream]$Stream) {
    $b = New-Object Collections.Generic.List[byte]
    while ($true) {
        $c = $Stream.ReadByte()
        if ($c -lt 0) { exit 2 }
        if ($c -eq 10) { break }
        if ($c -lt 0x20 -or $c -gt 0x7e -or $b.Count -ge 1024) { exit 2 }
        $b.Add([byte]$c)
    }
    [Text.Encoding]::ASCII.GetString($b.ToArray())
}

$vmId = Read-AapCallLine $stdin
$user = Read-AapCallLine $stdin
$pwText = Read-AapCallLine $stdin
$envelope = Read-AapCallLine $stdin
$m = [regex]::Match($envelope, '"payload_bytes":([0-9]{1,5})[,}]')
if ($vmId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z' -or $user -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{0,19}\z' -or
    $pwText.Length -lt 16 -or -not $m.Success -or [int]$m.Groups[1].Value -gt 16384) { exit 2 }
$payload = New-Object byte[] ([int]$m.Groups[1].Value)
$got = 0
while ($got -lt $payload.Length) {
    $n = $stdin.Read($payload, $got, $payload.Length - $got)
    if ($n -le 0) { exit 2 }
    $got += $n
}
$secure = New-Object Security.SecureString
foreach ($ch in $pwText.ToCharArray()) { $secure.AppendChar($ch) }
$secure.MakeReadOnly()
$pwText = $null
$credential = New-Object Management.Automation.PSCredential (".\$user", $secure)

# The one fixed script that runs in the guest. Its input is the envelope line and the payload bytes.
$remote = @'
$items = @($input)
$line = [string]$items[0]
$data = [byte[]]$items[1]
$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\Program Files\aap-guest\agent.ps1"'
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$saved = $null
try { $saved = [Console]::InputEncoding; [Console]::InputEncoding = New-Object Text.UTF8Encoding($false) } catch { $saved = $null }
try { $p = [Diagnostics.Process]::Start($psi) } finally { if ($null -ne $saved) { try { [Console]::InputEncoding = $saved } catch { $null = $_ } } }
$head = [Text.Encoding]::ASCII.GetBytes($line + "`n")
$p.StandardInput.BaseStream.Write($head, 0, $head.Length)
if ($data.Length) { $p.StandardInput.BaseStream.Write($data, 0, $data.Length) }
$p.StandardInput.Close()
[Array]::Clear($data, 0, $data.Length)
[string]$p.StandardOutput.ReadLine()
'@

# The exit code for an exception from the remote call: 0 (no reply, a failed guest) when the PowerShell Direct transport
# dropped or the session is no longer open, 3 (the remote side broke the contract) for anything else.
function Get-AapCallExit($ErrorRecord, $Session) {
    for ($e = $ErrorRecord.Exception; $null -ne $e; $e = $e.InnerException) {
        if ($e -is [Management.Automation.Remoting.PSRemotingTransportException]) { return 0 }   # check:transport-drop
    }
    if ($null -ne $Session -and [string]$Session.Runspace.RunspaceStateInfo.State -cne 'Opened') { return 0 }   # check:transport-drop
    3
}

$session = $null
$ps = $null
try {
    try { $session = New-PSSession -VMId $vmId -Credential $credential -ErrorAction Stop } catch { exit 0 }
    $ps = [powershell]::Create()
    $ps.Runspace = $session.Runspace
    [void]$ps.AddScript($remote)
    $feed = New-Object 'Management.Automation.PSDataCollection[object]'
    $feed.Add($envelope)
    $feed.Add($payload)
    $feed.Complete()
    try { $result = $ps.Invoke($feed) } catch { exit (Get-AapCallExit $_ $session) }
    if ($ps.InvocationStateInfo.State -ne 'Completed' -or $result.Count -ne 1 -or $null -eq $result[0] -or -not ($result[0].BaseObject -is [string])) { exit 4 }
    $text = [string]$result[0].BaseObject
    if ($text.Length -gt 8192) { exit 5 }
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($text)
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
    exit 0
} finally {
    [Array]::Clear($payload, 0, $payload.Length)
    if ($null -ne $ps) { $ps.Dispose() }
    if ($null -ne $session) { Remove-PSSession -Session $session }
}
