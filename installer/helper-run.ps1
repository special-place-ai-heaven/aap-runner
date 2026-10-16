# Verify, repair, and identity for the elevated tray helper.
# Windows PowerShell 5.1 and PowerShell 7. Dot-source safe: no mandatory
# parameters, so tests can load the functions. A -File run checks the verb.
#
# -Fixture reads a ProgramData-shaped tree and changes nothing. It does not
# call wsl, schtasks, Set-Acl, or the install scripts. The elevated helper
# never passes -Fixture.
#
# Without -Fixture the only accepted -DataDir is C:\ProgramData\aap-runner.
# Every path below is a constant. The identity verb reads one request file,
# inbox\jobs\<Id>.json, named from the 16-hex -Id; every field in it is
# re-checked here. The request and the key are each opened once. The key's
# final path must be a plain file under the profile of the user who owns
# that request file.
[CmdletBinding()]
param(
    [string]$Verb,
    [string]$DataDir = 'C:\ProgramData\aap-runner',
    [switch]$Fixture,
    [string]$TrayExe,
    [string]$Id
)

$AapDataDir = 'C:\ProgramData\aap-runner'
$AapVhdx = 'C:\wsl\aap-runner-work.vhdx'
$AapSupervisorTask = 'AAP-CRRR-Supervisor'
$AapMountTask = 'AAP-CRRR-Mount-Work-Disk'
$AapPs = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$AapSchtasks = 'C:\Windows\System32\schtasks.exe'
$AapWsl = 'C:\Windows\System32\wsl.exe'

function Initialize-AapModulePath {
    $machine = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
    if ([string]::IsNullOrEmpty($machine)) {
        throw 'refusing: machine PSModulePath is empty'
    }
    $env:PSModulePath = $machine
}

function Test-AapHelperDataDir([string]$Path) {
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    if ($Path -match '\.\.') { return $false }
    return $Path -match '^[A-Za-z]:\\[A-Za-z0-9 _.\\-]+$'
}

function Test-AapHelperExe([string]$Path) {
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    if ($Path -match '\.\.') { return $false }
    if ($Path.Contains('"')) { return $false }
    return $Path -match '^[A-Za-z]:\\[A-Za-z0-9 _.\\-]+\.exe$'
}

function Test-AapReparsePoint([string]$Path) {
    $attr = [int](New-Object IO.FileInfo $Path).Attributes
    if ($attr -eq -1) { return $false }
    return (($attr -band [int][IO.FileAttributes]::ReparsePoint) -ne 0)
}

# Names reparse points and does not open them, so a planted junction is not followed.
function Get-AapReparseProblems([string]$Path) {
    $problems = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $Path)) { return $problems }
    $stack = New-Object System.Collections.Stack
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $p = [string]$stack.Pop()
        $attr = [int](New-Object IO.FileInfo $p).Attributes
        if ($attr -eq -1) { continue }
        if (($attr -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
            [void]$problems.Add($p)
            continue
        }
        if (($attr -band [int][IO.FileAttributes]::Directory) -ne 0) {
            foreach ($c in @(Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue)) {
                if ($null -ne $c) { $stack.Push($c.FullName) }
            }
        }
    }
    return $problems
}

function Read-AapJsonBounded([string]$Path, [int]$Max) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    if (Test-AapReparsePoint $Path) { return $null }
    $len = (Get-Item -LiteralPath $Path -Force).Length
    if ($len -gt $Max) { return $null }
    $text = [IO.File]::ReadAllText($Path)
    if ($text.Length -gt $Max) { return $null }
    try {
        $obj = $text | ConvertFrom-Json
    } catch {
        return $null
    }
    if ($obj -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    return $obj
}

function ConvertFrom-AapRfc3339([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    # TryParseExact's string[] overload is easy to miss from PowerShell, and ConvertFrom-Json
    # may turn the same text into a DateTime. Callers pass the raw JSON string.
    $styles = [Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal'
    $dt = [datetime]::MinValue
    $ok = [datetime]::TryParse($Text, [cultureinfo]::InvariantCulture, $styles, [ref]$dt)
    if (-not $ok) { return $null }
    return $dt.ToUniversalTime()
}

# File checks only. Safe against a fixture tree: no wsl, schtasks, or ACL writes.
function Get-AapVerifyReport {
    param(
        [Parameter(Mandatory = $true)][string]$DataDir,
        [datetime]$Now = ([datetime]::UtcNow)
    )
    $lines = New-Object System.Collections.Generic.List[string]
    if (-not (Test-AapHelperDataDir $DataDir)) {
        [void]$lines.Add('FAIL data-dir refused')
        return [pscustomobject]@{ ExitCode = 1; Lines = $lines }
    }
    if (-not (Test-Path -LiteralPath $DataDir -PathType Container)) {
        [void]$lines.Add('FAIL data-dir missing')
        return [pscustomobject]@{ ExitCode = 1; Lines = $lines }
    }
    if (Test-AapReparsePoint $DataDir) {
        [void]$lines.Add("FAIL reparse $DataDir")
        return [pscustomobject]@{ ExitCode = 1; Lines = $lines }
    }
    [void]$lines.Add('PASS data-dir')
    $reparses = @(Get-AapReparseProblems $DataDir)
    if ($reparses.Count -gt 0) {
        [void]$lines.Add("FAIL reparse $($reparses[0])")
        return [pscustomobject]@{ ExitCode = 1; Lines = $lines }
    }
    [void]$lines.Add('PASS reparse none')
    $inbox = Join-Path $DataDir 'inbox'
    if ((Test-Path -LiteralPath $inbox -PathType Container) -and -not (Test-AapReparsePoint $inbox)) {
        [void]$lines.Add('PASS inbox')
    } else {
        [void]$lines.Add('FAIL inbox missing')
    }
    $state = Read-AapJsonBounded (Join-Path $inbox 'state.json') 4096
    if ($null -ne $state -and ($state.desired -eq 'on' -or $state.desired -eq 'off')) {
        [void]$lines.Add("PASS state $($state.desired)")
    } else {
        [void]$lines.Add('FAIL state missing or not on/off')
    }
    $settingsPath = Join-Path $inbox 'settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        [void]$lines.Add('PASS settings absent')
    } else {
        $settings = Read-AapJsonBounded $settingsPath 4096
        $count = $null
        if ($null -ne $settings) { $count = $settings.runner_count }
        if ($null -eq $settings) {
            [void]$lines.Add('FAIL settings unreadable')
        } elseif ($null -ne $count -and ($count -lt 1 -or $count -gt 5)) {
            [void]$lines.Add('FAIL settings runner_count')
        } else {
            [void]$lines.Add('PASS settings')
        }
    }
    $statusPath = Join-Path $DataDir 'status.json'
    $statusText = $null
    if ((Test-Path -LiteralPath $statusPath -PathType Leaf) -and -not (Test-AapReparsePoint $statusPath)) {
        $statusLen = (Get-Item -LiteralPath $statusPath -Force).Length
        if ($statusLen -le 65536) {
            $statusText = [IO.File]::ReadAllText($statusPath)
            if ($statusText.Length -gt 65536) { $statusText = $null }
        }
    }
    $status = $null
    if ($statusText) {
        try { $status = $statusText | ConvertFrom-Json } catch { $status = $null }
        if ($status -isnot [System.Management.Automation.PSCustomObject]) { $status = $null }
    }
    $known = @('off', 'starting', 'idle', 'running', 'draining', 'paused', 'error')
    if ($null -eq $status -or ($known -notcontains [string]$status.state)) {
        [void]$lines.Add('FAIL status missing or unknown state')
    } else {
        $schema = $status.schema
        if ($null -eq $schema -or $schema -eq 1 -or $schema -eq 2 -or $schema -eq 3 -or $schema -eq 4) {
            [void]$lines.Add("PASS status $($status.state)")
        } else {
            [void]$lines.Add("FAIL status schema $schema")
        }
    }
    $updated = $null
    if ($statusText -match '"updated"\s*:\s*"([^"]+)"') {
        $updated = ConvertFrom-AapRfc3339 $Matches[1]
    }
    if ($null -eq $updated) {
        [void]$lines.Add('FAIL supervisor-status missing updated')
    } else {
        $age = ($Now.ToUniversalTime() - $updated).TotalSeconds
        if ($age -ge 0 -and $age -le 180) {
            [void]$lines.Add('PASS supervisor-status fresh')
        } else {
            [void]$lines.Add("FAIL supervisor-status stale age=$([int]$age)s")
        }
    }
    $log = Join-Path (Join-Path $DataDir 'logs') 'supervisor.log'
    if ((Test-Path -LiteralPath $log -PathType Leaf) -and -not (Test-AapReparsePoint $log)) {
        [void]$lines.Add('PASS supervisor-log')
    } else {
        [void]$lines.Add('FAIL supervisor-log missing')
    }
    $code = 0
    foreach ($line in $lines) {
        if ($line.StartsWith('FAIL')) { $code = 1 }
    }
    return [pscustomobject]@{ ExitCode = $code; Lines = $lines }
}

# The repair actions and the only paths they use.
function Get-AapRepairPlan {
    return @(
        [pscustomobject]@{ Name = 'lock-acl'; Path = 'C:\wsl' }
        [pscustomobject]@{ Name = 'lock-acl'; Path = 'C:\wsl\aap-runner-work.vhdx' }
        [pscustomobject]@{ Name = 'lock-acl'; Path = 'C:\wsl\mount-work-vhdx.ps1' }
        [pscustomobject]@{ Name = 'lock-acl'; Path = 'C:\wsl\mount-work-vhdx-task.xml' }
        [pscustomobject]@{ Name = 'lock-acl'; Path = 'C:\wsl\aap-runner-supervisor' }
        [pscustomobject]@{ Name = 'install-supervisor'; Path = $AapDataDir }
        [pscustomobject]@{ Name = 'remount'; Path = $AapVhdx }
        [pscustomobject]@{ Name = 'restart-supervisor'; Path = $AapSupervisorTask }
    )
}

function Get-AapHelperLayout {
    $here = $PSScriptRoot
    if ([string]::IsNullOrEmpty($here)) { $here = (Get-Location).Path }
    $nested = Join-Path $here 'installer\install-host.ps1'
    if (Test-Path -LiteralPath $nested) {
        return [pscustomobject]@{
            Installer  = (Join-Path $here 'installer')
            Supervisor = (Join-Path $here 'supervisor')
        }
    }
    $parent = Split-Path -Parent $here
    return [pscustomobject]@{
        Installer  = $here
        Supervisor = (Join-Path $parent 'supervisor')
    }
}

function Format-AapProcessArg([string]$Arg) {
    if ($Arg.Contains('"')) { throw 'refusing: argument' }
    if ($Arg -match '\s') { return '"' + $Arg + '"' }
    return $Arg
}

# Streams stdout and stderr as the child runs. Returns the process exit code.
# The copy runs on CLR threads and writes to Console directly. A PowerShell
# scriptblock on those threads has no runspace, and pwsh 7 throws.
# Every child drops WSLENV. Identity streams stdin from the handle it checked.
function Initialize-AapStream {
    if (('AapStream' -as [type]) -and ('AapOpen' -as [type])) { return }
    if (('AapStream' -as [type]) -or ('AapOpen' -as [type])) {
        throw 'refusing: stale helper types in this process'
    }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

public static class AapOpen {
    const uint GenericRead = 0x80000000;
    const uint FileShareRead = 1;
    const uint FileShareDelete = 4;
    const uint OpenExisting = 3;
    // FILE_SHARE_READ | FILE_SHARE_DELETE, FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS
    const uint OpenFlags = 0x02200000;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetFinalPathNameByHandleW(SafeFileHandle file, StringBuilder path, uint cch, uint flags);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetFileInformationByHandleEx(SafeFileHandle file, int cls, out TagInfo info, uint cb);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetFileSizeEx(SafeFileHandle file, out long size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(SafeFileHandle file, byte[] buf, uint count, out uint read, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetFilePointerEx(SafeFileHandle file, long distance, out long neu, uint method);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern uint GetSecurityInfo(SafeFileHandle handle, int type, uint info, out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl, out IntPtr sd);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool ConvertSidToStringSid(IntPtr sid, out IntPtr str);
    [DllImport("kernel32.dll")]
    static extern IntPtr LocalFree(IntPtr mem);

    [StructLayout(LayoutKind.Sequential)]
    struct TagInfo {
        public uint FileAttributes;
        public uint ReparseTag;
    }

    public static SafeFileHandle Open(string path) {
        SafeFileHandle h = CreateFileW(path, GenericRead, FileShareRead | FileShareDelete, IntPtr.Zero, OpenExisting, OpenFlags, IntPtr.Zero);
        if (h == null || h.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        return h;
    }

    public static string FinalPath(SafeFileHandle h) {
        StringBuilder sb = new StringBuilder(1024);
        uint n = GetFinalPathNameByHandleW(h, sb, (uint)sb.Capacity, 0);
        if (n == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        if (n >= (uint)sb.Capacity) {
            sb = new StringBuilder((int)n + 1);
            n = GetFinalPathNameByHandleW(h, sb, (uint)sb.Capacity, 0);
            if (n == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        string p = sb.ToString(0, (int)n);
        if (p.StartsWith(@"\\?\")) p = p.Substring(4);
        return p;
    }

    public static int Attributes(SafeFileHandle h) {
        TagInfo info;
        int cb = Marshal.SizeOf(typeof(TagInfo));
        if (!GetFileInformationByHandleEx(h, 9, out info, (uint)cb)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return unchecked((int)info.FileAttributes);
    }

    public static long Size(SafeFileHandle h) {
        long n;
        if (!GetFileSizeEx(h, out n)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return n;
    }

    public static int Read(SafeFileHandle h, byte[] buf, int count) {
        if (count > buf.Length) count = buf.Length;
        if (count < 0) count = 0;
        uint n;
        if (!ReadFile(h, buf, (uint)count, out n, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return (int)n;
    }

    public static void SeekZero(SafeFileHandle h) {
        long neu;
        if (!SetFilePointerEx(h, 0, out neu, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    public static byte[] ReadAll(SafeFileHandle h) {
        SeekZero(h);
        long size = Size(h);
        if (size < 0 || size > 1024L * 1024L) throw new IOException("size");
        if (size == 0) return new byte[0];
        byte[] buf = new byte[size];
        int off = 0;
        while (off < buf.Length) {
            byte[] tmp = new byte[buf.Length - off];
            uint n;
            if (!ReadFile(h, tmp, (uint)tmp.Length, out n, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (n == 0) break;
            Buffer.BlockCopy(tmp, 0, buf, off, (int)n);
            Array.Clear(tmp, 0, tmp.Length);
            off += (int)n;
        }
        if (off == buf.Length) return buf;
        byte[] cut = new byte[off];
        Buffer.BlockCopy(buf, 0, cut, 0, off);
        Array.Clear(buf, 0, buf.Length);
        return cut;
    }

    [DllImport("kernel32.dll", EntryPoint = "GetFileInformationByHandleEx", SetLastError = true)]
    static extern bool GetStandard(SafeFileHandle file, int cls, out StandardInfo info, uint cb);
    [StructLayout(LayoutKind.Sequential)]
    struct StandardInfo {
        public long AllocationSize;
        public long EndOfFile;
        public uint NumberOfLinks;
        [MarshalAs(UnmanagedType.U1)] public bool DeletePending;
        [MarshalAs(UnmanagedType.U1)] public bool Directory;
    }
    public static uint Links(SafeFileHandle h) {
        StandardInfo info;
        if (!GetStandard(h, 1, out info, (uint)Marshal.SizeOf(typeof(StandardInfo))))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return info.NumberOfLinks;
    }

    public static string OwnerSid(SafeFileHandle h) {
        IntPtr owner, group, dacl, sacl, sd;
        uint err = GetSecurityInfo(h, 1, 1, out owner, out group, out dacl, out sacl, out sd);
        if (err != 0) throw new Win32Exception((int)err);
        try {
            IntPtr str;
            if (!ConvertSidToStringSid(owner, out str) || str == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            try { return Marshal.PtrToStringUni(str); }
            finally { LocalFree(str); }
        } finally {
            if (sd != IntPtr.Zero) LocalFree(sd);
        }
    }
}

public static class AapStream {
    public static bool SawKeyInstalled;
    public static string LastFail = "";

    public static int Run(string file, string args) {
        return RunCore(file, args, null);
    }

    public static int RunHandle(string file, string args, SafeFileHandle stdin) {
        return RunCore(file, args, stdin);
    }

    static int RunCore(string file, string args, SafeFileHandle stdin) {
        ProcessStartInfo psi = new ProcessStartInfo(file, args);
        psi.UseShellExecute = false;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.RedirectStandardInput = false;
        psi.CreateNoWindow = true;
        psi.EnvironmentVariables["WSL_UTF8"] = "1";
        psi.EnvironmentVariables.Remove("WSLENV");
        SawKeyInstalled = false;
        LastFail = "";
        if (stdin != null) return RunInherited(file, args, stdin);
        using (Process proc = Process.Start(psi)) {
            Thread outThread = new Thread(delegate() { Copy(proc.StandardOutput); });
            Thread errThread = new Thread(delegate() { Copy(proc.StandardError); });
            outThread.Start();
            errThread.Start();
            proc.WaitForExit();
            outThread.Join();
            errThread.Join();
            return proc.ExitCode;
        }
    }

    static int RunInherited(string file, string args, SafeFileHandle stdin) {
        SecurityAttrs sa = new SecurityAttrs();
        sa.nLength = Marshal.SizeOf(typeof(SecurityAttrs));
        sa.bInheritHandle = true;
        SafeFileHandle outRead, outWrite, errRead, errWrite;
        if (!CreatePipe(out outRead, out outWrite, ref sa, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
        if (!CreatePipe(out errRead, out errWrite, ref sa, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
        if (!SetHandleInformation(outRead, 1, 0) || !SetHandleInformation(errRead, 1, 0))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        IntPtr inDup;
        if (!DuplicateHandle(GetCurrentProcess(), stdin.DangerousGetHandle(), GetCurrentProcess(), out inDup, 0, true, 2))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        GC.KeepAlive(stdin);
        StartupInfo si = new StartupInfo();
        si.cb = Marshal.SizeOf(typeof(StartupInfo));
        si.dwFlags = 0x100 | 0x1;
        si.wShowWindow = 0;
        si.hStdInput = inDup;
        si.hStdOutput = outWrite.DangerousGetHandle();
        si.hStdError = errWrite.DangerousGetHandle();
        IntPtr env = EnvBlock();
        ProcessInfo pi;
        StringBuilder cmd = new StringBuilder(32768);
        cmd.Append('"').Append(file).Append('"');
        if (!string.IsNullOrEmpty(args)) { cmd.Append(' '); cmd.Append(args); }
        bool ok = CreateProcessW(file, cmd, IntPtr.Zero, IntPtr.Zero, true, 0x08000000 | 0x00000400, env, null, ref si, out pi);
        int err = Marshal.GetLastWin32Error();
        Marshal.FreeHGlobal(env);
        CloseHandle(inDup);
        outWrite.Dispose();
        errWrite.Dispose();
        if (!ok) { outRead.Dispose(); errRead.Dispose(); throw new Win32Exception(err); }
        Thread outThread = new Thread(delegate() { Copy(new StreamReader(new FileStream(outRead, FileAccess.Read))); });
        Thread errThread = new Thread(delegate() { Copy(new StreamReader(new FileStream(errRead, FileAccess.Read))); });
        outThread.Start();
        errThread.Start();
        WaitForSingleObject(pi.hProcess, 0xFFFFFFFF);
        uint code;
        if (!GetExitCodeProcess(pi.hProcess, out code)) code = 1;
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
        outThread.Join();
        errThread.Join();
        return unchecked((int)code);
    }

    static IntPtr EnvBlock() {
        StringBuilder sb = new StringBuilder();
        bool saw = false;
        foreach (System.Collections.DictionaryEntry e in Environment.GetEnvironmentVariables()) {
            string k = (string)e.Key;
            if (string.Equals(k, "WSLENV", StringComparison.OrdinalIgnoreCase)) continue;
            if (string.Equals(k, "WSL_UTF8", StringComparison.OrdinalIgnoreCase)) saw = true;
            sb.Append(k);
            sb.Append('=');
            sb.Append(e.Value ?? "");
            sb.Append('\0');
        }
        if (!saw) sb.Append("WSL_UTF8=1\0");
        sb.Append('\0');
        return Marshal.StringToHGlobalUni(sb.ToString());
    }

    static void Copy(StreamReader reader) {
        string line;
        while ((line = reader.ReadLine()) != null) {
            line = line.Replace("\0", "");
            if (line.Length > 2000) line = line.Substring(0, 2000);
            if (line.StartsWith("key installed:", StringComparison.Ordinal)) SawKeyInstalled = true;
            if (line.StartsWith("FAIL ", StringComparison.Ordinal)) LastFail = line;
            Console.Out.WriteLine(line);
        }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DuplicateHandle(IntPtr srcProc, IntPtr src, IntPtr dstProc, out IntPtr dst, uint access, bool inherit, uint options);
    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CreatePipe(out SafeFileHandle read, out SafeFileHandle write, ref SecurityAttrs sa, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetHandleInformation(SafeFileHandle h, uint mask, uint flags);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string dir, ref StartupInfo si, out ProcessInfo pi);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr h);

    [StructLayout(LayoutKind.Sequential)]
    struct SecurityAttrs { public int nLength; public IntPtr lpSecurityDescriptor; public bool bInheritHandle; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct StartupInfo {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow; public short cbReserved2; public IntPtr lpReserved2;
        public IntPtr hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct ProcessInfo { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
}
'@
}

function Invoke-AapStreaming([string]$File, [string[]]$Arguments) {
    Initialize-AapStream
    $quoted = @()
    foreach ($a in @($Arguments)) { $quoted += (Format-AapProcessArg $a) }
    return [int][AapStream]::Run($File, ($quoted -join ' '))
}

# The key handle is the one identity already checked. There is no by-name open.
function Invoke-AapStreamingStdin([string]$File, [string[]]$Arguments, $StdinHandle) {
    Initialize-AapStream
    $quoted = @()
    foreach ($a in @($Arguments)) { $quoted += (Format-AapProcessArg $a) }
    $code = [int][AapStream]::RunHandle($File, ($quoted -join ' '), $StdinHandle)
    $script:AapSawKeyLine = [bool][AapStream]::SawKeyInstalled
    return $code
}

# --- identity: the request is untrusted; every field is checked again here ---

function Test-AapIdentityId([string]$Value) {
    return ($Value -match '^[1-9][0-9]{0,18}\z')
}

# GitHub slug: 1..39 of [A-Za-z0-9-], no leading, trailing, or double hyphen.
function Test-AapIdentitySlug([string]$Value) {
    if ([string]::IsNullOrEmpty($Value) -or $Value.Length -gt 39) { return $false }
    if ($Value -notmatch '^[A-Za-z0-9-]+\z') { return $false }
    if ($Value.StartsWith('-') -or $Value.EndsWith('-') -or $Value.Contains('--')) { return $false }
    return $true
}

# Comma list of distinct [a-z0-9-]+ items, already normalised by the tray.
function Test-AapIdentityLabels([string]$Value) {
    if ([string]::IsNullOrEmpty($Value) -or $Value.Length -gt 256) { return $false }
    $parts = @($Value -split ',')
    $seen = @{}
    foreach ($part in $parts) {
        if ($part -cnotmatch '^[a-z0-9-]+\z') { return $false }
        if ($seen.ContainsKey($part)) { return $false }
        $seen[$part] = $true
    }
    return $parts.Count -ge 1
}

# $null when the key may be used. The file is opened once; every check uses
# that handle and the final path from it. The handle is left at offset 0 when
# the key may be streamed, and closed when it may not.
function Get-AapIdentityKeyView([string]$Path, [string]$ProfileDir) {
    Initialize-AapStream
    if ([string]::IsNullOrEmpty($Path) -or $Path.Length -gt 1024 -or $Path -match '\.\.' -or $Path -notmatch '^[A-Za-z]:\\') {
        return [pscustomobject]@{ Problem = 'key path'; Handle = $null }
    }
    if ([string]::IsNullOrEmpty($ProfileDir) -or $ProfileDir -notmatch '^[A-Za-z]:\\') {
        return [pscustomobject]@{ Problem = 'profile'; Handle = $null }
    }
    $root = [IO.Path]::GetFullPath($ProfileDir).TrimEnd('\')
    $h = $null
    $bytes = $null
    try {
        $h = [AapOpen]::Open($Path)
    } catch {
        return [pscustomobject]@{ Problem = 'key file was not found'; Handle = $null }
    }
    $why = $null
    try {
        $attr = [AapOpen]::Attributes($h)
        if (($attr -band 0x400) -ne 0) {
            $why = 'key file is a reparse point'
        } elseif (($attr -band 0x10) -ne 0) {
            $why = 'key file is not a regular file'
        } else {
            $links = [AapOpen]::Links($h)
            if ($links -gt 1) { $why = 'key file has more than one hard link' }
            $final = [AapOpen]::FinalPath($h)
            if ($why) {
            } elseif ($final -notmatch '^[A-Za-z]:\\' -or -not $final.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $why = "key file is not under $root"
            } else {
                $len = [AapOpen]::Size($h)
                if ($len -le 0) {
                    $why = 'key file is empty'
                } elseif ($len -ge 16384) {
                    $why = 'key file is larger than 16 KiB'
                } else {
                    $buf = New-Object byte[] 64
                    $n = 0
                    try {
                        $n = [AapOpen]::Read($h, $buf, $buf.Length)
                        $end = -1
                        if ($n -gt 0) { $end = [Array]::IndexOf($buf, [byte]10, 0, $n) }
                        if ($end -lt 0) { $end = $n }
                        if ($end -gt 0 -and $buf[$end - 1] -eq 13) { $end-- }
                        $line = [Text.Encoding]::ASCII.GetString($buf, 0, $end)
                    } finally {
                        [Array]::Clear($buf, 0, $buf.Length)
                    }
                    [AapOpen]::SeekZero($h)
                    if ($line -cne '-----BEGIN RSA PRIVATE KEY-----' -and $line -cne '-----BEGIN PRIVATE KEY-----') {
                        $why = 'key file is not a PEM private key'
                    }
                }
            }
        }
    } catch {
        $why = 'key file was not found'
    }
    if ($why) {
        $h.Dispose()
        return [pscustomobject]@{ Problem = $why; Handle = $null }
    }
    return [pscustomobject]@{ Problem = $null; Handle = $h }
}

function Get-AapIdentityKeyProblem([string]$Path, [string]$ProfileDir) {
    $view = Get-AapIdentityKeyView $Path $ProfileDir
    if ($null -ne $view.Handle) { $view.Handle.Dispose() }
    return $view.Problem
}

# ProfileImagePath for a user SID. The SID came from the request handle.
function Get-AapRequestOwnerProfile([string]$Sid) {
    if ($Sid -notmatch '^S-1-5-21(-\d+){4}\z') { throw "refusing: request owner $Sid" }
    $key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid"
    $dir = [string](Get-ItemProperty -LiteralPath $key -ErrorAction Stop).ProfileImagePath
    if ([string]::IsNullOrEmpty($dir) -or $dir -match '\.\.' -or $dir -notmatch '^[A-Za-z]:\\[^"<>|*?]+\z') {
        throw 'refusing: requester profile'
    }
    return $dir
}

# Exactly the nine fields of the schema 1 identity request, each re-checked.
# The file is opened once: the JSON (at most 4096 bytes) and the owner SID
# both come from that handle.
function Read-AapIdentityRequest([string]$Path, [string]$Id) {
    Initialize-AapStream
    $h = $null
    try {
        $h = [AapOpen]::Open($Path)
    } catch {
        throw 'refusing: request'
    }
    try {
        $size = [AapOpen]::Size($h)
        if ($size -le 0 -or $size -gt 4096) { throw 'refusing: request' }
        $bytes = [AapOpen]::ReadAll($h)
        if ($null -eq $bytes -or $bytes.Length -gt 4096) { throw 'refusing: request' }
        $sid = [AapOpen]::OwnerSid($h)
        $text = [Text.Encoding]::UTF8.GetString($bytes)
    } finally {
        if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
        if ($null -ne $h) { $h.Dispose() }
    }
    if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }
    try {
        $obj = $text | ConvertFrom-Json
    } catch {
        throw 'refusing: request'
    }
    if ($obj -isnot [System.Management.Automation.PSCustomObject]) { throw 'refusing: request' }
    $names = @($obj.PSObject.Properties.Name | Sort-Object)
    if (($names -join ',') -ne 'app_id,group,id,installation_id,key_path,labels,org,schema,verb') {
        throw 'refusing: request fields'
    }
    if ([string]$obj.schema -ne '1' -or [string]$obj.verb -ne 'identity' -or [string]$obj.id -ne $Id) {
        throw 'refusing: request header'
    }
    foreach ($num in @($obj.app_id, $obj.installation_id)) {
        if ($num -is [string] -or $num -is [bool] -or $null -eq $num) { throw 'refusing: request id type' }
    }
    $req = [pscustomobject]@{
        Org            = [string]$obj.org
        AppId          = [string]$obj.app_id
        InstallationId = [string]$obj.installation_id
        Group          = [string]$obj.group
        Labels         = [string]$obj.labels
        KeyPath        = [string]$obj.key_path
        Profile        = (Get-AapRequestOwnerProfile $sid)
    }
    if (-not (Test-AapIdentitySlug $req.Org)) { throw 'refusing: org' }
    if (-not (Test-AapIdentityId $req.AppId)) { throw 'refusing: app_id' }
    if (-not (Test-AapIdentityId $req.InstallationId)) { throw 'refusing: installation_id' }
    if (-not (Test-AapIdentitySlug $req.Group)) { throw 'refusing: group' }
    if (-not (Test-AapIdentityLabels $req.Labels)) { throw 'refusing: labels' }
    if ([string]::IsNullOrEmpty($req.KeyPath)) { throw 'refusing: key_path' }
    return $req
}

# Runs as root inside the distro. The key is on stdin. Arguments are the five
# fields and a start word (idle, running, off, or missing). Drain, when the start word
# allows it, happens before either file is replaced.
function Get-AapIdentityScript {
    $text = @'
#!/bin/bash
# aap-runner identity: key on stdin; args: org app_id installation_id group labels start
set -euo pipefail
conf=/etc/aap-runner/manager.conf
key=/etc/aap-runner/app.pem
manager=/usr/local/sbin/aap-runner-manager

# rewrite_conf IN OUT ORG APP INST GROUP LABELS. The private-key path is a
# constant here; the start token is not an argument.
rewrite_conf() {
  local in="$1" out="$2" line k seen=""
  local -A want=([AAP_GITHUB_ORG]="$3" [AAP_GITHUB_APP_ID]="$4" [AAP_GITHUB_APP_INSTALLATION_ID]="$5" [AAP_RUNNER_GROUP]="$6" [AAP_RUNNER_LABELS]="$7" [AAP_GITHUB_APP_PRIVATE_KEY_PATH]=/etc/aap-runner/app.pem)
  : > "$out"
  if [[ -f "$in" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      k=${line%%=*}
      if [[ "$line" == *=* && "$line" != \#* && -n "${want[$k]+x}" ]]; then
        printf "%s=%s\n" "$k" "${want[$k]}" >> "$out"
        seen="$seen $k"
      else
        printf "%s\n" "$line" >> "$out"
      fi
    done < "$in"
  fi
  for k in AAP_GITHUB_ORG AAP_GITHUB_APP_ID AAP_GITHUB_APP_INSTALLATION_ID AAP_RUNNER_GROUP AAP_RUNNER_LABELS AAP_GITHUB_APP_PRIVATE_KEY_PATH; do
    [[ " $seen " == *" $k "* ]] || printf "%s=%s\n" "$k" "${want[$k]}" >> "$out"
  done
}

main() {
  if [[ $# -ne 6 ]]; then
    echo "FAIL identity: expected 6 arguments" >&2
    exit 2
  fi
  local start="$6"
  case "$start" in
    idle|running|off|missing) ;;
    *)
      echo "FAIL identity: start" >&2
      exit 2
      ;;
  esac
  umask 077
  local tmpkey="$key.tmp" tmpconf="$conf.tmp" n first state i bak iters sleep_s had=0 drained=0
  trap "rm -f \"$tmpkey\" \"$tmpconf\"" EXIT
  head -c 16384 > "$tmpkey"
  n=$(stat -c %s "$tmpkey")
  if (( n == 0 || n >= 16384 )); then
    echo "FAIL identity: key size $n" >&2
    exit 1
  fi
  IFS= read -r first < "$tmpkey" || true
  first=${first%$'\r'}
  case "$first" in
    "-----BEGIN RSA PRIVATE KEY-----"|"-----BEGIN PRIVATE KEY-----") ;;
    *)
      echo "FAIL identity: key is not a PEM private key" >&2
      exit 1
      ;;
  esac
  chown root:root "$tmpkey"
  chmod 0400 "$tmpkey"
  rewrite_conf "$conf" "$tmpconf" "$1" "$2" "$3" "$4" "$5"
  chown root:root "$tmpconf"
  chmod 0400 "$tmpconf"
  if ! AAP_MANAGER_CONF="$tmpconf" "$manager" --check-limits > /dev/null; then
    echo "FAIL identity: the manager refused the new manager.conf" >&2
    exit 1
  fi
  if [[ "$start" == idle || "$start" == running ]]; then
    state=$(systemctl is-active aap-runner-manager || true)
    if [[ "$state" == active ]]; then
      echo "restarting pool: drain"
      "$manager" --drain
      iters=${AAP_DRAIN_ITERS:-120}
      sleep_s=${AAP_DRAIN_SLEEP:-5}
      for ((i = 0; i < iters; i++)); do
        state=$(systemctl is-active aap-runner-manager || true)
        [[ "$state" == active ]] || break
        sleep "$sleep_s"
      done
      if [[ "$state" == active ]]; then
        trap - EXIT
        "$manager" --undrain || true
        echo "FAIL pool did not drain in 10 min; retry when idle"
        exit 1
      fi
      drained=1
    fi
  fi
  if [[ "$start" == off || "$start" == missing ]]; then
    state=$(systemctl is-active aap-runner-manager || true)
    if [[ "$state" == active ]]; then
      echo "FAIL pool is active while status is $start; retry when idle"
      exit 1
    fi
  fi
  bak="${key}.bak"  # /etc/aap-runner/app.pem.bak
  if [[ -f "$key" ]]; then
    cp -a "$key" "$bak"
    chown root:root "$bak"
    chmod 0400 "$bak"
    had=1
  fi
  if ! mv -f "$tmpkey" "$key"; then
    echo "FAIL identity: app.pem was not replaced" >&2
    exit 1
  fi
  if ! mv -f "$tmpconf" "$conf"; then
    if [[ "$had" -eq 1 ]]; then
      mv -f "$bak" "$key"
    else
      rm -f "$key"
    fi
    echo "FAIL identity: manager.conf was not replaced" >&2
    exit 1
  fi
  rm -f "$bak"
  trap - EXIT
  echo "key installed: 1 file, $n bytes"
  echo "manager.conf updated: AAP_GITHUB_ORG AAP_GITHUB_APP_ID AAP_GITHUB_APP_INSTALLATION_ID AAP_RUNNER_GROUP AAP_RUNNER_LABELS AAP_GITHUB_APP_PRIVATE_KEY_PATH"
  if [[ "$drained" -eq 1 ]]; then
    "$manager" --undrain
    systemctl start aap-runner-manager
    echo "pool restarted: $(systemctl is-active aap-runner-manager || true)"
  else
    state=$(systemctl is-active aap-runner-manager || true)
    echo "pool is $state; the new identity applies at the next start"
  fi
}

if [[ "${AAP_IDENTITY_LIB:-}" != 1 ]]; then
  main "$@"
fi
'@
    return ($text -replace "`r`n", "`n")
}

# One wsl.exe call. The script travels base64 inside the -c argument so that
# argument holds no quote; the fields and the start word are plain tokens.
function Get-AapIdentityWslArgs($Req, [string]$PoolWord) {
    if ($PoolWord -ne 'idle' -and $PoolWord -ne 'running' -and $PoolWord -ne 'off' -and $PoolWord -ne 'missing') {
        throw 'refusing: pool'
    }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-AapIdentityScript)))
    $cmd = "bash <(echo $b64 | base64 -d) $($Req.Org) $($Req.AppId) $($Req.InstallationId) $($Req.Group) $($Req.Labels) $PoolWord"
    return @('-d', 'aap-runner', '-u', 'root', '--', '/bin/bash', '-c', $cmd)
}

# desired must be exactly "on". draining and paused refuse. Anything else is hold.
function Get-AapIdentityPool([string]$DataDir) {
    $desired = ''
    try {
        $obj = Read-AapJsonBounded (Join-Path (Join-Path $DataDir 'inbox') 'state.json') 4096
        if ($null -ne $obj) { $desired = [string]$obj.desired }
    } catch {
        $desired = ''
    }
    if ($desired -cne 'on') {
        return [pscustomobject]@{ Fail = 'pool is off; retry when idle or running'; Word = $null }
    }
    $state = ''
    try {
        $obj = Read-AapJsonBounded (Join-Path $DataDir 'status.json') 65536
        if ($null -ne $obj) { $state = [string]$obj.state }
    } catch {
        $state = ''
    }
    if ($state -ceq 'draining' -or $state -ceq 'paused' -or $state -ceq 'starting' -or $state -ceq 'error') {
        return [pscustomobject]@{ Fail = "pool is ${state}; retry when idle or running"; Word = $null }
    }
    if ($state -ceq 'idle' -or $state -ceq 'running' -or $state -ceq 'off') {
        return [pscustomobject]@{ Fail = $null; Word = $state }
    }
    if ($state -eq '') {
        return [pscustomobject]@{ Fail = $null; Word = 'missing' }
    }
    return [pscustomobject]@{ Fail = "pool is ${state}; retry when idle or running"; Word = $null }
}

function Invoke-AapIdentityLive([string]$DataDir, [string]$Id) {
    if ($Id -notmatch '^[0-9a-f]{16}\z') {
        [Console]::Out.WriteLine('FAIL identity id')
        return 2
    }
    $reqPath = Join-Path (Join-Path (Join-Path $DataDir 'inbox') 'jobs') "$Id.json"
    [Console]::Out.WriteLine('STEP identity request')
    try {
        $req = Read-AapIdentityRequest $reqPath $Id
    } catch {
        [Console]::Out.WriteLine("FAIL identity $($_.Exception.Message)")
        return 2
    }
    $pool = Get-AapIdentityPool $DataDir
    if ($pool.Fail) {
        [Console]::Out.WriteLine("FAIL identity $($pool.Fail)")
        return 2
    }
    $view = Get-AapIdentityKeyView $req.KeyPath $req.Profile
    if ($view.Problem) {
        if ($null -ne $view.Handle) { $view.Handle.Dispose() }
        [Console]::Out.WriteLine("FAIL identity $($view.Problem)")
        return 2
    }
    [Console]::Out.WriteLine("INFO identity org $($req.Org) app $($req.AppId) installation $($req.InstallationId) group $($req.Group) labels $($req.Labels)")
    [Console]::Out.WriteLine('STEP identity install')
    $script:AapSawKeyLine = $false
    [AapStream]::LastFail = ''
    try {
        $code = Invoke-AapStreamingStdin $AapWsl (Get-AapIdentityWslArgs $req $pool.Word) $view.Handle
    } finally {
        if ($null -ne $view.Handle) { $view.Handle.Dispose() }
    }
    if ($code -ne 0) {
        $last = [string][AapStream]::LastFail
        if ($last -like 'FAIL pool *') { return 1 }
        [Console]::Out.WriteLine("FAIL identity exit $code")
        return 1
    }
    if (-not $script:AapSawKeyLine) {
        [Console]::Out.WriteLine('FAIL identity key installed line missing')
        return 1
    }
    [Console]::Out.WriteLine('PASS identity')
    return 0
}
# /etc/aap-runner/manager.conf of the aap-runner distro, or $null when the
# distro is absent or wsl fails. One wsl call; the verify flow already enters
# the distro for the units check.
function Get-AapDistroManagerConf {
    if (-not (Test-Path -LiteralPath $AapWsl)) { return $null }
    # Windows PowerShell 5.1 turns merged native stderr into a terminating error under Stop.
    $ErrorActionPreference = 'Continue'
    try {
        $savedWslenv = $env:WSLENV
        Remove-Item Env:WSLENV -ErrorAction SilentlyContinue
        try {
            $out = & $AapWsl -d 'aap-runner' -u root -- /bin/cat /etc/aap-runner/manager.conf 2>&1 | ForEach-Object { "$_" } | Out-String
        } finally {
            if ($null -eq $savedWslenv) { Remove-Item Env:WSLENV -ErrorAction SilentlyContinue } else { $env:WSLENV = $savedWslenv }
        }
    } catch {
        return $null
    }
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($out -replace [char]0, '')
}

# Bytes of the fixed work VHDX, 0 when it is absent.
function Get-AapVhdxBytes {
    if (-not (Test-Path -LiteralPath $AapVhdx -PathType Leaf)) { return [long]0 }
    return [long](Get-Item -LiteralPath $AapVhdx -Force).Length
}

# AAP_WORK_DISK_GIB from the distro's manager.conf; without a distro the VHDX
# size rounded to GiB; 0 when neither is known (install-host keeps its default).
function Get-AapWorkDiskGiB {
    $conf = Get-AapDistroManagerConf
    if ($conf -and ($conf -match '(?m)^AAP_WORK_DISK_GIB=([0-9]+)\s*$')) { return [int]$Matches[1] }
    return [int][math]::Round((Get-AapVhdxBytes) / 1GB)
}

function Invoke-AapVerifyLive([string]$DataDir) {
    $layout = Get-AapHelperLayout
    $report = Get-AapVerifyReport -DataDir $DataDir
    foreach ($line in @($report.Lines)) { [Console]::Out.WriteLine([string]$line) }
    $failed = ($report.ExitCode -ne 0)
    [Console]::Out.WriteLine('STEP install-host -DryRun')
    $hostArgs = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $layout.Installer 'install-host.ps1'), '-DryRun')
    $gib = Get-AapWorkDiskGiB
    if ($gib -gt 0) {
        [Console]::Out.WriteLine("INFO work-disk $gib GiB")
        $hostArgs += @('-WorkDiskGiB', "$gib")
    }
    $code = Invoke-AapStreaming $AapPs $hostArgs
    if ($code -ne 0) {
        [Console]::Out.WriteLine("FAIL install-host exit $code")
        $failed = $true
    } else {
        [Console]::Out.WriteLine('PASS install-host exit 0')
    }
    [Console]::Out.WriteLine('STEP install-supervisor -DryRun')
    $code = Invoke-AapStreaming $AapPs @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $layout.Supervisor 'install-supervisor.ps1'), '-DryRun')
    if ($code -ne 0) {
        [Console]::Out.WriteLine("FAIL install-supervisor exit $code")
        $failed = $true
    } else {
        [Console]::Out.WriteLine('PASS install-supervisor exit 0')
    }
    foreach ($task in @($AapSupervisorTask, $AapMountTask)) {
        [Console]::Out.WriteLine("STEP task $task")
        $code = Invoke-AapStreaming $AapSchtasks @('/Query', '/TN', $task, '/FO', 'LIST')
        if ($code -eq 0) {
            [Console]::Out.WriteLine("PASS task $task")
        } else {
            [Console]::Out.WriteLine("FAIL task $task missing")
            $failed = $true
        }
    }
    # The supervisor health check: both units active. Read-only; it does not restart them.
    [Console]::Out.WriteLine('STEP units')
    $code = Invoke-AapStreaming $AapWsl @(
        '-d', 'aap-runner', '-u', 'root', '--',
        '/bin/systemctl', 'is-active', 'sysbox', 'aap-runner-manager')
    if ($code -eq 0) {
        [Console]::Out.WriteLine('PASS units sysbox and aap-runner-manager')
    } else {
        [Console]::Out.WriteLine("FAIL units exit $code")
        $failed = $true
    }
    # The manager mints an App token with the installed key. Pass or fail only; the
    # manager prints nothing secret and the token never leaves the distro.
    [Console]::Out.WriteLine('STEP app-token')
    $code = Invoke-AapStreaming $AapWsl @(
        '-d', 'aap-runner', '-u', 'root', '--',
        '/usr/local/sbin/aap-runner-manager', '--check-token')
    if ($code -eq 0) {
        [Console]::Out.WriteLine('PASS app-token obtainable')
    } else {
        [Console]::Out.WriteLine("FAIL app-token exit $code")
        $failed = $true
    }
    if ($failed) { return 1 }
    return 0
}

function Get-AapSupervisorTaskState {
    try {
        $task = Get-ScheduledTask -TaskName $AapSupervisorTask -ErrorAction Stop
    } catch {
        if ([string]$_.FullyQualifiedErrorId -match 'NotFound_TaskName') { return 'missing' }
        return 'unknown'
    }
    if ($null -eq $task) { return 'missing' }
    switch ([string]$task.State) {
        'Running' { return 'running' }
        'Queued' { return 'running' }
        'Ready' { return 'ready' }
        'Disabled' { return 'ready' }
        default { return 'unknown' }
    }
}

function Test-AapWslListHasDistro([string]$Text, [string]$Name) {
    $clean = $Text -replace [char]0, ''
    foreach ($line in ($clean -split "\r?\n")) {
        if ($line.Trim() -eq $Name) { return $true }
    }
    return $false
}

# 'running' when `wsl --list --running --quiet` names aap-runner. Listing only;
# this does not start the distro.
function Test-AapDistroListed {
    if (-not (Test-Path -LiteralPath $AapWsl)) { return 'unknown' }
    $savedWslenv = $env:WSLENV
    Remove-Item Env:WSLENV -ErrorAction SilentlyContinue
    try {
        $out = & $AapWsl --list --running --quiet 2>&1 | Out-String
    } finally {
        if ($null -eq $savedWslenv) { Remove-Item Env:WSLENV -ErrorAction SilentlyContinue } else { $env:WSLENV = $savedWslenv }
    }
    if ($LASTEXITCODE -ne 0) { return 'unknown' }
    if (Test-AapWslListHasDistro $out 'aap-runner') { return 'running' }
    return 'stopped'
}

# Missing, unreadable, or unparseable status refuses unless the supervisor task
# does not exist. A missing or older-than-180s "updated" is not trusted: the task
# state decides. starting, running, and draining refuse when the timestamp is fresh.
# A running aap-runner distro refuses even when the file says idle.
function Get-AapRepairRefusal([string]$DataDir, [datetime]$Now = ([datetime]::UtcNow)) {
    $busy = 'job running, repair refused; retry when idle or pause the runners first'
    $unread = 'status unreadable, repair refused; retry when idle or pause the runners first'
    if (-not (Test-AapHelperDataDir $DataDir)) { return $unread }
    $path = Join-Path $DataDir 'status.json'
    $text = $null
    try {
        if ((Test-Path -LiteralPath $path -PathType Leaf) -and -not (Test-AapReparsePoint $path)) {
            $len = (Get-Item -LiteralPath $path -Force).Length
            if ($len -le 65536) {
                $text = [IO.File]::ReadAllText($path)
                if ($text.Length -gt 65536) { $text = $null }
            }
        }
    } catch {
        $text = $null
    }
    $state = $null
    if ($text -and ($text -match '"state"\s*:\s*"([^"]+)"')) { $state = $Matches[1] }
    $distro = Test-AapDistroListed
    if ($distro -eq 'running') { return $busy }
    if ($distro -eq 'unknown') { return $unread }
    if ([string]::IsNullOrEmpty($state)) {
        if ((Get-AapSupervisorTaskState) -eq 'missing') { return $null }
        return $unread
    }
    $fresh = $false
    $sawUpdated = $false
    if ($text -match '"updated"\s*:\s*"([^"]+)"') {
        $sawUpdated = $true
        $updated = ConvertFrom-AapRfc3339 $Matches[1]
        if ($null -ne $updated) {
            $age = ($Now.ToUniversalTime() - $updated).TotalSeconds
            if ($age -ge 0 -and $age -le 180) { $fresh = $true }
        }
    }
    if (-not $sawUpdated -or -not $fresh) {
        switch (Get-AapSupervisorTaskState) {
            'missing' { return $null }
            'ready' { return $null }
            'running' { return $busy }
            default { return $unread }
        }
    }
    if ($state -eq 'running' -or $state -eq 'draining' -or $state -eq 'starting') { return $busy }
    return $null
}

function Write-AapRepairRefusal {
    $refusal = Get-AapRepairRefusal $AapDataDir
    if ($refusal) {
        [Console]::Out.WriteLine("FAIL $refusal")
        return $true
    }
    return $false
}

function Invoke-AapRepairLive([string]$TrayExe) {
    if (Write-AapRepairRefusal) { return 1 }
    $layout = Get-AapHelperLayout
    foreach ($step in @(Get-AapRepairPlan)) {
        if ($step.Name -ne 'lock-acl') { continue }
        [Console]::Out.WriteLine("STEP lock-acl $($step.Path)")
        if (-not (Test-Path -LiteralPath $step.Path)) {
            [Console]::Out.WriteLine("SKIP lock-acl $($step.Path) absent")
            continue
        }
        if (Test-AapReparsePoint $step.Path) {
            [Console]::Out.WriteLine("FAIL lock-acl reparse $($step.Path)")
            return 1
        }
        $code = Invoke-AapStreaming $AapPs @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
            (Join-Path $layout.Installer 'lock-acl.ps1'), '-LiteralPath', $step.Path)
        if ($code -ne 0) {
            [Console]::Out.WriteLine("FAIL lock-acl $($step.Path) exit $code")
            return 1
        }
        [Console]::Out.WriteLine("PASS lock-acl $($step.Path)")
    }
    [Console]::Out.WriteLine('STEP install-supervisor')
    $supArgs = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $layout.Supervisor 'install-supervisor.ps1'),
        '-DataDir', $AapDataDir)
    if ($TrayExe) { $supArgs += @('-TrayExe', $TrayExe) }
    $code = Invoke-AapStreaming $AapPs $supArgs
    if ($code -ne 0) {
        [Console]::Out.WriteLine("FAIL install-supervisor exit $code")
        return 1
    }
    [Console]::Out.WriteLine('PASS install-supervisor')
    if (Write-AapRepairRefusal) { return 1 }
    [Console]::Out.WriteLine('STEP remount')
    $installed = 'C:\wsl\mount-work-vhdx.ps1'
    $mountScript = $installed
    if (-not (Test-Path -LiteralPath $installed -PathType Leaf) -or (Test-AapReparsePoint $installed)) {
        $templatePath = Join-Path $layout.Installer 'mount-work-vhdx.ps1'
        $template = [IO.File]::ReadAllText($templatePath)
        if (-not $template.Contains('__AAP_VHDX__')) {
            [Console]::Out.WriteLine('FAIL remount template has no placeholder')
            return 1
        }
        $mountScript = Join-Path $layout.Installer 'mount-work-vhdx.running.ps1'
        $enc = New-Object System.Text.UTF8Encoding $false
        [IO.File]::WriteAllText($mountScript, $template.Replace('__AAP_VHDX__', $AapVhdx), $enc)
    }
    $code = Invoke-AapStreaming $AapPs @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $mountScript)
    if ($code -ne 0) {
        [Console]::Out.WriteLine("FAIL remount exit $code")
        return 1
    }
    [Console]::Out.WriteLine('PASS remount')
    if (Write-AapRepairRefusal) { return 1 }
    [Console]::Out.WriteLine("STEP restart $AapSupervisorTask")
    $end = Invoke-AapStreaming $AapSchtasks @('/End', '/TN', $AapSupervisorTask)
    if ($end -ne 0) {
        [Console]::Out.WriteLine("INFO restart end exit $end")
    }
    $code = Invoke-AapStreaming $AapSchtasks @('/Run', '/TN', $AapSupervisorTask)
    if ($code -ne 0) {
        [Console]::Out.WriteLine("FAIL restart exit $code")
        return 1
    }
    [Console]::Out.WriteLine("PASS restart $AapSupervisorTask")
    return 0
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    try {
        Initialize-AapModulePath
        if ($Verb -ne 'verify' -and $Verb -ne 'repair' -and $Verb -ne 'identity') {
            [Console]::Error.WriteLine('refusing: verb')
            exit 2
        }
        if ($Fixture) {
            if ($Verb -ne 'verify') {
                [Console]::Out.WriteLine("FAIL $Verb fixture mode does not change the machine")
                exit 2
            }
            if (-not (Test-AapHelperDataDir $DataDir)) {
                [Console]::Error.WriteLine('refusing: DataDir')
                exit 2
            }
            $report = Get-AapVerifyReport -DataDir $DataDir
            foreach ($line in @($report.Lines)) { [Console]::Out.WriteLine([string]$line) }
            exit ([int]$report.ExitCode)
        }
        if ($DataDir -ne $AapDataDir) {
            [Console]::Error.WriteLine('refusing: DataDir')
            exit 2
        }
        if ($TrayExe -and -not (Test-AapHelperExe $TrayExe)) {
            [Console]::Error.WriteLine('refusing: TrayExe')
            exit 2
        }
        if ($Verb -eq 'verify') {
            exit (Invoke-AapVerifyLive -DataDir $DataDir)
        }
        if ($Verb -eq 'identity') {
            if ($Id -notmatch '^[0-9a-f]{16}\z') {
                [Console]::Error.WriteLine('refusing: Id')
                exit 2
            }
            exit (Invoke-AapIdentityLive -DataDir $DataDir -Id $Id)
        }
        exit (Invoke-AapRepairLive -TrayExe $TrayExe)
    } catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 1
    }
}
