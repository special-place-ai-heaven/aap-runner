# The supervisor's hvsocket relay (guest-transport.md, Linux candidate): ssh.exe runs it as ProxyCommand from the
# per-clone ssh_config AapLinBackend.psm1 writes:
#   "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "<this file>" <vm id>
# It connects one AF_HYPERV stream socket to that VM's partition and the runtime service (vsock port 5222, service id
# 00001466-facb-11e6-bd58-64006a7986d3) and copies bytes both ways between it and its own stdin and stdout until the guest
# closes: SSH traffic only, encrypted end to end between ssh.exe and the guest's sshd. It opens no listening socket, takes
# no data but the VM id, reads and writes no file, and parses nothing it relays. It runs as ssh.exe's child inside the call
# child's job object (memory, CPU-time and wall caps, kill on close). A VM id that is not a GUID, or extra arguments: exit 2
# before any socket exists. A connection that cannot be made: exit 3, which ssh.exe reports as its own failure (255), a
# failed guest. The SOCKADDR_HV endpoint is a PowerShell class (no compiler, no temporary files).
# NOT RUN against a VM by P11: the lab proof is P02.1 (guest-transport.md, step 4).

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# SOCKADDR_HV: family (34, AF_HYPERV) and a reserved word, then the VM id and the service id, 36 bytes in all.
class AapHvEndPoint : System.Net.EndPoint {
    hidden [byte[]]$Vm
    hidden [byte[]]$Service
    AapHvEndPoint([guid]$vm, [guid]$service) { $this.Vm = $vm.ToByteArray(); $this.Service = $service.ToByteArray() }
    [System.Net.Sockets.AddressFamily] get_AddressFamily() { return [System.Net.Sockets.AddressFamily]34 }
    [System.Net.SocketAddress] Serialize() {
        $sa = New-Object System.Net.SocketAddress ([System.Net.Sockets.AddressFamily]34, 36)
        for ($i = 0; $i -lt 16; $i++) { $sa[4 + $i] = $this.Vm[$i]; $sa[20 + $i] = $this.Service[$i] }
        return $sa
    }
    [System.Net.EndPoint] Create([System.Net.SocketAddress]$sa) { return $this }
}

$script:ServiceId = '00001466-facb-11e6-bd58-64006a7986d3'   # the VSOCK template with port 0x1466 (5222)

# Copies host to guest and guest to host at once. When ssh.exe closes its side (stdin ends), the socket's sending side is
# shut down so the guest sees the end of the request; the relay ends when the guest closes (or the job object ends it).
function Invoke-AapRelayPump([IO.Stream]$In, [IO.Stream]$Out, [IO.Stream]$Net, [scriptblock]$EndSend) {
    $up = $In.CopyToAsync($Net)
    $down = $Net.CopyToAsync($Out)
    while (-not $down.IsCompleted) {
        $tasks = [Threading.Tasks.Task[]]@(@($up, $down) | Where-Object { $null -ne $_ })
        [void][Threading.Tasks.Task]::WaitAny($tasks)
        if ($null -ne $up -and $up.IsCompleted) { try { & $EndSend } catch { $null = $_ }; $up = $null }
    }
    if ($down.IsFaulted) { return 3 }
    $Out.Flush()
    0
}

function Invoke-AapRelay([object[]]$Argv) {
    if (@($Argv).Count -ne 1 -or [string]$Argv[0] -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z') { return 2 }   # check:relay-args
    $sock = New-Object System.Net.Sockets.Socket ([System.Net.Sockets.AddressFamily]34, [System.Net.Sockets.SocketType]::Stream, [System.Net.Sockets.ProtocolType]1)
    try {
        try { $sock.Connect([AapHvEndPoint]::new([guid][string]$Argv[0], [guid]$script:ServiceId)) } catch { return 3 }
        $net = New-Object System.Net.Sockets.NetworkStream ($sock, $false)
        $endSend = { $sock.Shutdown([System.Net.Sockets.SocketShutdown]::Send) }.GetNewClosure()
        Invoke-AapRelayPump ([Console]::OpenStandardInput()) ([Console]::OpenStandardOutput()) $net $endSend
    } finally { $sock.Dispose() }
}

# Dot-sourced (the tests), it only defines the class and the functions.
if ($MyInvocation.InvocationName -ne '.') { exit (Invoke-AapRelay $args) }
