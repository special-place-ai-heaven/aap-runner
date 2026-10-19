# Helpers for AapArtifact.Tests.ps1. Dot-sourced in BeforeDiscovery (to decide skips) and again in BeforeAll, because
# Pester 5 does not carry discovery variables or functions into the run phase.
Add-Type -AssemblyName System.Net.Http

function Test-PythonRuns([string]$Path) {
    try {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $Path
        $psi.Arguments = '-I --version'
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $p = [Diagnostics.Process]::Start($psi)
        if (-not $p.WaitForExit(10000)) { try { $p.Kill() } catch { $null = $_ }; return $false }
        $text = $p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd()
        return ($p.ExitCode -eq 0 -and $text -match 'Python 3\.')
    } catch { return $false }
}

# The first python 3 on PATH that really runs. The Microsoft Store stub in WindowsApps answers --version with an error
# and a non-zero exit code (or opens the Store), so it never counts; neither does a python 2.
function Find-RealPython {
    $tried = @{}
    foreach ($name in 'python', 'python3') {
        foreach ($c in @(Get-Command $name -All -ErrorAction SilentlyContinue)) {
            $path = $c.Source
            if (-not $path -or $tried.ContainsKey($path)) { continue }
            $tried[$path] = $true
            if (Test-PythonRuns $path) { return $path }
        }
    }
    return $null
}

# True only when an HTTPS request to each url gets an answer below 400 within the timeout. A name that resolves but whose
# connection is dropped, or a proxy that answers with a block page, does not count as egress.
function Test-HttpsReachable([string[]]$Url, [int]$TimeoutSeconds = 8) {
    foreach ($u in $Url) {
        $client = $null
        $resp = $null
        try {
            $client = New-Object System.Net.Http.HttpClient
            $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
            $resp = $client.GetAsync($u, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            if ([int]$resp.StatusCode -ge 400) { return $false }
        } catch { return $false } finally {
            if ($resp) { $resp.Dispose() }
            if ($client) { $client.Dispose() }
        }
    }
    return $true
}
