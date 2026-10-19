# Verified artifact acquisition (P03). Windows PowerShell 5.1 and PowerShell 7.
# Downloads only; nothing fetched here is ever executed, extracted or piped to a shell.
# Every rejection throws a message that starts with AAP_<Reason>: so callers and tests can match it.
# Reasons: ManifestInvalid VersionNotExact SchemeRejected RedirectRejected SourceUnavailable
#          SizeExceeded SizeMismatch ContentTypeRejected HashSourceMissing HashSourceConflict
#          HashMismatch OfflineIncomplete StagingLink StagingUntrusted
# An error that is none of these (a full disk, a permission error) is recorded as AAP_Unexpected and is never retried.
#
# Files next to a staged artifact <file>:
#   <file>.provenance.json   latest accepted result; removed when a later run rejects the file
#   <file>.rejected.json     latest rejection; removed when a later run accepts the file
#   <file>.first-fetch.json  trust anchor of a first-fetch entry (no upstream hash exists): the hash seen by the
#                            first accepted download. Later runs, online or offline, must match it. Rejections never
#                            remove it; delete it by hand only after reviewing why the upstream file changed.
#   <file>.quarantined       a staged file that failed an offline check, moved away from its final name; when that name is
#                            taken (a file, a folder, anything) the next free <file>.quarantined.<n> is used, and nothing
#                            already there is moved into, overwritten or lost

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 can start with SSL3 and TLS 1.0 only, so TLS 1.2 is added there. A host that already follows
# the system default is left alone: OR-ing TLS 1.2 onto "system default" would narrow the whole process to TLS 1.2.
try {
    $protocols = [Net.ServicePointManager]::SecurityProtocol
    if ($protocols -ne [Net.SecurityProtocolType]::SystemDefault) {
        [Net.ServicePointManager]::SecurityProtocol = $protocols -bor [Net.SecurityProtocolType]::Tls12
    }
} catch { Write-Verbose 'TLS 1.2 flag not settable on this host' }
Add-Type -AssemblyName System.Net.Http

$script:ToolVersion = '4'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:Placeholder = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' # SHA-256 of zero bytes; a sums file lists it for itself and it is never a pass
$script:ReparsePoint = [int][IO.FileAttributes]::ReparsePoint
$script:DirectoryAttr = [int][IO.FileAttributes]::Directory

function Get-AapProp($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } else { return $null } }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Format-AapTime($v) { if ($v -is [DateTime]) { $v.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { [string]$v } }

# Recorded urls drop the query and fragment: redirect targets carry short-lived signed tokens that must not reach disk.
function Format-AapUrl($u) { $x = [Uri]$u; $x.GetLeftPart([UriPartial]::Path) + $(if ($x.Query) { '?<query-stripped>' } else { '' }) }

# PowerShell cmdlets resolve a relative path against the current location, .NET file calls against the process
# directory. Those differ after Set-Location, so every path is made absolute once, at the entry points.
function Resolve-AapPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'AAP_ManifestInvalid: an empty path was given' }
    [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
}

function Get-AapRootMessage($ErrorRecord) {
    $ex = $ErrorRecord.Exception
    while ($ex.InnerException) { $ex = $ex.InnerException }
    $ex.Message
}

function Get-AapLowerHash([string]$Path, [string]$Algorithm) {
    (Get-FileHash -Algorithm $Algorithm -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Test-AapLoopback([string]$HostName) {
    if ($HostName -in @('localhost', '[::1]', '::1')) { return $true }
    $ip = $null
    return ([Net.IPAddress]::TryParse($HostName, [ref]$ip) -and [Net.IPAddress]::IsLoopback($ip))
}

# ---- staging trust ---------------------------------------------------------------------------
# The staging tree is where a verified file waits for a later step to use it, so whoever can write there can swap the
# file after it was verified, or point a folder at something else with a junction. Before anything is written the
# root must be a plain folder owned by SYSTEM, Administrators or TrustedInstaller that nobody else can write to or
# delete, and so must every folder above it and the name and version folders below it (an owner can always rewrite the
# ACL of what they own, so a folder somebody else owns is refused, not repaired). Links are refused at every level and
# nothing is written, replaced or deleted through one.
#
# The owner, ACL and ancestor rules are those of supervisor/install-supervisor.ps1 (Test-AapAdminDescriptor,
# Get-AapAncestorProblem, Get-AapDataDirProblem and Test-AapFixedLocalPath): the same three SIDs, the same access
# masks and the same drive-type rule. They are re-implemented here, not dot-sourced, because that file is an installer
# script and images/common must not depend on it or run it. The folders below the root are held to the root's rule.
# -TrustedSid (more SIDs that count as owners and writers) and -SkipAncestorCheck exist for tests and developer
# boxes; the provenance records staging_check = relaxed when either was used.
$script:AdminSids = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
# Root: write data, append data, write attributes, delete child, delete, write DAC, write owner, GENERIC_WRITE, GENERIC_ALL.
$script:RootBadMask = 0x2 -bor 0x4 -bor 0x100 -bor 0x40 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x40000000 -bor 0x10000000
# Ancestors: delete, delete child, write DAC, write owner, GENERIC_ALL. Create rights are absent on purpose: C:\ grants
# Authenticated Users "create folders" by default and that cannot replace an existing child. Write attributes on a
# parent does not replace the child either.
$script:AncestorBadMask = 0x10000 -bor 0x40 -bor 0x40000 -bor 0x80000 -bor 0x10000000
$script:ReservedNames = '^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)'

# Attributes of the item itself: a link is not followed, a missing path gives -1 and so does a path that cannot be
# read. Test-Path would call a dangling link missing.
function Get-AapAttributes([string]$Path) {
    try { return [int](New-Object IO.FileInfo $Path).Attributes } catch { return -1 }
}

function Test-AapLink([string]$Path) {
    $a = Get-AapAttributes $Path
    return (($a -ne -1) -and (($a -band $script:ReparsePoint) -ne 0))
}

function Assert-AapNotLink([string]$Path, [string]$What) {
    if (Test-AapLink $Path) { throw "AAP_StagingLink: $What $Path is a junction or symbolic link; nothing is written, replaced or deleted through it" }
}

# Windows resolves a trailing dot to the name without it and treats these names as devices, with or without an extension.
function Test-AapSafeSegment([string]$Segment) {
    return -not ($Segment.EndsWith('.') -or $Segment.EndsWith(' ') -or $Segment -match $script:ReservedNames)
}

function Write-AapJson($Object, [string]$Path) {
    $full = Resolve-AapPath $Path
    Assert-AapNotLink $full 'file'
    $text = (ConvertTo-Json -InputObject $Object -Depth 8) -replace "`r`n", "`n"
    [IO.File]::WriteAllText($full, $text + "`n", $script:Utf8NoBom)
}

function Read-AapJsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json) } catch { return $null }
}

# Deletes one staged file. A missing path is fine; a link or a folder is refused (a link would be deleted, not its target,
# but a link in a staging folder means the folder is not what it should be).
function Remove-AapStaged([string]$Path) {
    $a = Get-AapAttributes $Path
    if ($a -eq -1) { return }
    Assert-AapNotLink $Path 'staged file'
    if (($a -band $script:DirectoryAttr) -ne 0) { throw "AAP_StagingUntrusted: $Path is a folder where a file belongs" }
    Remove-Item -LiteralPath $Path -Force
}

# A staged file that failed an offline check leaves its final name, so nothing that looks for the file finds it.
# The target is a name nothing uses yet: Move-Item into an existing folder would put the file inside it (a junction there
# would take it anywhere) and onto an existing file would destroy an earlier quarantine. File.Move cannot do either.
function Move-AapAside([string]$Path) {
    Assert-AapNotLink $Path 'staged file'
    $to = $Path + '.quarantined'
    for ($n = 1; (Get-AapAttributes $to) -ne -1; $n++) {
        if ($n -gt 99) { throw "AAP_StagingUntrusted: 100 quarantined copies of $Path already exist; clear them out first" }
        $to = "$Path.quarantined.$n"
    }
    [IO.File]::Move($Path, $to)
    return $to
}

function New-AapProblem([string]$Code, [string]$Text) { [pscustomobject]@{ Code = $Code; Text = $Text } }

function Format-AapProblems($Problems) {
    $list = @($Problems)
    $texts = @($list | ForEach-Object { $_.Text })
    $shown = @($texts | Select-Object -First 5)
    return "$($list[0].Code): $($shown -join '; ')" + $(if ($texts.Count -gt 5) { "; and $($texts.Count - 5) more" } else { '' })
}

function Get-AapDescriptor([string]$Path) {
    $acl = Get-Acl -LiteralPath $Path
    return (New-Object System.Security.AccessControl.RawSecurityDescriptor($acl.GetSecurityDescriptorBinaryForm(), 0))
}

# Owner and DACL problems of one folder, as text. Only plain allow and deny entries are understood; deny entries and
# inherit-only entries (they do not apply to the folder itself) are skipped; any other principal with a bad right is a problem.
function Get-AapAclProblems($Raw, [string]$Where, [int]$Mask, [string[]]$Trusted) {
    $p = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Raw.Owner -or $Trusted -notcontains $Raw.Owner.Value) {
        $p.Add("owner $(if ($null -eq $Raw.Owner) { 'none' } else { $Raw.Owner.Value }) of $Where is not SYSTEM, Administrators or TrustedInstaller")
    }
    if ($null -eq $Raw.DiscretionaryAcl) {
        $p.Add("$Where has no DACL, so everyone has full control")
        return $p.ToArray()
    }
    foreach ($ace in $Raw.DiscretionaryAcl) {
        $type = [int]$ace.AceType
        if ($type -ne 0 -and $type -ne 1) { $p.Add("$Where has an ACE that is not a plain allow or deny"); continue }
        if ($type -ne 0) { continue }
        if (([int]$ace.AceFlags -band 8) -ne 0) { continue }
        $sid = $ace.SecurityIdentifier.Value
        if ($Trusted -contains $sid) { continue }
        if (([int]$ace.AccessMask -band $Mask) -ne 0) { $p.Add("$Where grants $sid access $($ace.AccessMask)") }
    }
    return $p.ToArray()
}

function Get-AapAncestorProblems([string]$Path, [string[]]$Trusted) {
    $found = New-Object System.Collections.Generic.List[object]
    $dir = Split-Path -Parent $Path
    while ($dir) {
        # A link ancestor is refused before its target's ACL is read.
        if (Test-AapLink $dir) {
            $found.Add((New-AapProblem 'AAP_StagingLink' "ancestor $dir is a junction or symbolic link"))
        } else {
            try {
                foreach ($t in @(Get-AapAclProblems (Get-AapDescriptor $dir) "ancestor $dir" $script:AncestorBadMask $Trusted)) { $found.Add((New-AapProblem 'AAP_StagingUntrusted' $t)) }
            } catch { $found.Add((New-AapProblem 'AAP_StagingUntrusted' "cannot read the ACL of ancestor ${dir}: $(Get-AapRootMessage $_)")) }
        }
        $dir = Split-Path -Parent $dir
    }
    return $found.ToArray()
}

# DriveInfo.DriveType is GetDriveType of the drive root. A function of its own so a test can say what a drive is.
function Get-AapDriveType([string]$DriveRoot) {
    try { return [string](New-Object IO.DriveInfo $DriveRoot).DriveType } catch { return 'Unknown' }
}

# Why a path cannot be a staging root by its form alone, or $null. This is the rule of Test-AapFixedLocalPath in
# supervisor/install-supervisor.ps1: a drive-letter path whose drive is a fixed local disk (GetDriveType 3). A share,
# a device path, and a mapped network, removable, optical or RAM drive are refused. A drive created with SUBST still reports
# Fixed, as it does there. No I/O besides GetDriveType.
function Get-AapRootFormProblem([string]$Root) {
    if ($Root -notmatch '^[A-Za-z]:\\') { return "staging root $Root is not a local drive path" }
    $type = Get-AapDriveType $Root.Substring(0, 3)
    if ($type -ne 'Fixed') { return "staging root $Root is on a drive of type $type; only a fixed local disk is accepted" }
    return $null
}

function Get-AapStagingProblems {
    <# Everything that makes an existing staging root unfit to hold verified files, as @{ Code; Text } pairs; empty when fit.
       Reads attributes and ACLs only. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [string[]]$TrustedSid = @(), [switch]$SkipAncestorCheck)
    $trusted = @($script:AdminSids) + @($TrustedSid | Where-Object { $_ })
    $found = New-Object System.Collections.Generic.List[object]
    $form = Get-AapRootFormProblem $Root
    if ($form) {
        $found.Add((New-AapProblem 'AAP_StagingUntrusted' $form))
        return $found.ToArray()
    }
    $attr = Get-AapAttributes $Root
    if ($attr -eq -1) {
        $found.Add((New-AapProblem 'AAP_StagingUntrusted' "staging root $Root does not exist or cannot be read"))
        return $found.ToArray()
    }
    if (($attr -band $script:ReparsePoint) -ne 0) {
        $found.Add((New-AapProblem 'AAP_StagingLink' "staging root $Root is a junction or symbolic link"))
        return $found.ToArray()
    }
    if (($attr -band $script:DirectoryAttr) -eq 0) {
        $found.Add((New-AapProblem 'AAP_StagingUntrusted' "staging root $Root is a file, not a folder"))
        return $found.ToArray()
    }
    try {
        foreach ($t in @(Get-AapAclProblems (Get-AapDescriptor $Root) "staging root $Root" $script:RootBadMask $trusted)) { $found.Add((New-AapProblem 'AAP_StagingUntrusted' $t)) }
    } catch { $found.Add((New-AapProblem 'AAP_StagingUntrusted' "cannot read the ACL of staging root ${Root}: $(Get-AapRootMessage $_)")) }
    if (-not $SkipAncestorCheck) { foreach ($p in @(Get-AapAncestorProblems $Root $trusted)) { $found.Add($p) } }
    return $found.ToArray()
}

function Assert-AapStagingRoot {
    <# Throws AAP_StagingLink or AAP_StagingUntrusted unless the staging root may hold verified files. A missing root is
       created (one level, below an existing parent that passes the ancestor checks) and then checked like any other. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [string[]]$TrustedSid = @(), [switch]$SkipAncestorCheck)
    # Before any I/O: a share or device path would be probed over the network, and its ACLs are not ours to trust.
    $form = Get-AapRootFormProblem $Root
    if ($form) { throw "AAP_StagingUntrusted: $form" }
    if ((Get-AapAttributes $Root) -eq -1) {
        $parent = Split-Path -Parent $Root
        if (-not $parent -or (Get-AapAttributes $parent) -eq -1) { throw "AAP_StagingUntrusted: the parent of staging root $Root does not exist; create and lock it first" }
        if (-not $SkipAncestorCheck) {
            $trusted = @($script:AdminSids) + @($TrustedSid | Where-Object { $_ })
            $up = @(Get-AapAncestorProblems $Root $trusted)
            if ($up.Count) { throw (Format-AapProblems $up) }
        }
        [void][IO.Directory]::CreateDirectory($Root)
    }
    $problems = @(Get-AapStagingProblems -Root $Root -TrustedSid $TrustedSid -SkipAncestorCheck:$SkipAncestorCheck)
    if ($problems.Count) { throw (Format-AapProblems $problems) }
}

# Creates <root>\<name>\<version> one level at a time. Each level, one that was there already and one created a moment
# ago, must be a plain folder (not a link, not a file) and pass the owner and ACL rule of the root: an owner outside
# SYSTEM, Administrators and TrustedInstaller, or another principal that can write to it, delete it or its children,
# change its permissions or take ownership, is refused before anything is created below it.
function Initialize-AapStagedDir {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Version, [string[]]$TrustedSid = @())
    $trusted = @($script:AdminSids) + @($TrustedSid | Where-Object { $_ })
    $cur = $Root
    $levels = @(@('name folder', $Name), @('version folder', $Version))
    foreach ($level in $levels) {
        $cur = Join-Path $cur $level[1]
        $a = Get-AapAttributes $cur
        if ($a -eq -1) { [void][IO.Directory]::CreateDirectory($cur); $a = Get-AapAttributes $cur }
        if (($a -band $script:ReparsePoint) -ne 0) { throw "AAP_StagingLink: $($level[0]) $cur is a junction or symbolic link; nothing is written, replaced or deleted through it" }
        if (($a -band $script:DirectoryAttr) -eq 0) { throw "AAP_StagingUntrusted: $($level[0]) $cur is a file, not a folder" }
        $found = New-Object System.Collections.Generic.List[object]
        try {
            foreach ($t in @(Get-AapAclProblems (Get-AapDescriptor $cur) "$($level[0]) $cur" $script:RootBadMask $trusted)) { $found.Add((New-AapProblem 'AAP_StagingUntrusted' $t)) }
        } catch { $found.Add((New-AapProblem 'AAP_StagingUntrusted' "cannot read the ACL of $($level[0]) ${cur}: $(Get-AapRootMessage $_)")) }
        if ($found.Count) { throw (Format-AapProblems $found.ToArray()) }
    }
    return $cur
}

# ---- manifest validation ---------------------------------------------------------------------

function Test-AapEntry {
    <# Returns the list of problems (empty when the entry is acceptable). #>
    param([Parameter(Mandatory)]$Entry, [switch]$AllowTestSources)
    $e = New-Object System.Collections.Generic.List[string]
    $name = Get-AapProp $Entry 'name'
    if ($name -isnot [string] -or $name -cnotmatch '^[a-z0-9][a-z0-9._-]{0,79}$' -or -not (Test-AapSafeSegment $name)) {
        $e.Add('AAP_ManifestInvalid: name must match ^[a-z0-9][a-z0-9._-]{0,79}$, must not end with a dot and must not be a reserved Windows device name')
    }
    $v = Get-AapProp $Entry 'version'
    if ($v -isnot [string] -or $v -cnotmatch '^[0-9A-Za-z][0-9A-Za-z._+-]{0,79}$' -or $v -match '(?i)latest|stable|nightly|current|^(head|main|master|lts|newest)$') {
        $e.Add("AAP_VersionNotExact: version '$v' is not an exact pinned version")
    } elseif (-not (Test-AapSafeSegment $v)) {
        $e.Add("AAP_ManifestInvalid: version '$v' ends with a dot or is a reserved Windows device name")
    }
    $fn = Get-AapProp $Entry 'file_name'
    if ($fn -isnot [string] -or $fn -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._+~-]{0,199}$' -or -not (Test-AapSafeSegment $fn)) {
        $e.Add('AAP_ManifestInvalid: file_name must be a plain file name that does not end with a dot and is not a reserved Windows device name')
    }
    $urls = @(Get-AapProp $Entry 'urls')
    if ($urls.Count -lt 1 -or $urls.Count -gt 8) { $e.Add('AAP_ManifestInvalid: urls needs 1 to 8 entries') }
    foreach ($u in $urls) {
        $uri = $null
        if ($u -isnot [string] -or -not [Uri]::TryCreate($u, [UriKind]::Absolute, [ref]$uri)) { $e.Add("AAP_ManifestInvalid: url is not absolute: $u"); continue }
        if ($uri.UserInfo) { $e.Add('AAP_ManifestInvalid: url carries credentials') }
        if ($uri.Scheme -eq 'file' -and ($uri.Host -or $uri.IsUnc -or $uri.LocalPath.StartsWith('\\'))) {
            $e.Add("AAP_SchemeRejected: a file source must be a local path, not a network share: $u")
            continue
        }
        $ok = ($uri.Scheme -eq 'https') -or ($AllowTestSources -and (($uri.Scheme -eq 'file') -or ($uri.Scheme -eq 'http' -and (Test-AapLoopback $uri.Host))))
        if (-not $ok) { $e.Add("AAP_SchemeRejected: only https sources are allowed: $($uri.Scheme)://$($uri.Host)") }
    }
    $h = Get-AapProp $Entry 'hash'
    $algo = Get-AapProp $h 'algorithm'
    $src = Get-AapProp $h 'source'
    $val = Get-AapProp $h 'value'
    if ($algo -notin @('sha256', 'sha512')) { $e.Add('AAP_ManifestInvalid: hash.algorithm is sha256 or sha512') }
    if ($src -notin @('literal', 'upstream-file', 'first-fetch')) { $e.Add('AAP_ManifestInvalid: hash.source is literal, upstream-file or first-fetch') }
    $len = if ($algo -eq 'sha512') { 128 } else { 64 }
    if ($null -ne $val -and ($val -isnot [string] -or $val -cnotmatch "^[0-9a-f]{$len}$")) { $e.Add("AAP_ManifestInvalid: hash.value must be $len lowercase hex digits") }
    if ($src -eq 'literal' -and $null -eq $val) { $e.Add('AAP_HashSourceMissing: literal hash source needs hash.value') }
    if ($src -eq 'first-fetch' -and $null -ne $val) { $e.Add('AAP_ManifestInvalid: first-fetch carries no hash.value') }
    if ($src -eq 'first-fetch' -and @(Get-AapProp $Entry 'redirect_hosts' | Where-Object { $_ }).Count) {
        # With no hash to bind the content to a source, the host allowlist (which ignores the path) is all there is: a
        # redirect to another path on an allowlisted host could be someone else's file.
        $e.Add('AAP_ManifestInvalid: a first-fetch entry may not allow redirect hosts; it never follows a redirect')
    }
    if ($src -eq 'upstream-file') {
        if (-not (Get-AapProp $h 'upstream_entry') -or -not (Get-AapProp $h 'upstream_key')) { $e.Add('AAP_HashSourceMissing: upstream-file needs upstream_entry and upstream_key') }
        if ($algo -ne 'sha256') { $e.Add('AAP_ManifestInvalid: upstream sums files are read as sha256') }
    }
    $max = Get-AapProp $Entry 'size_max_bytes'
    if ($max -isnot [ValueType] -or $max -lt 1 -or $max -gt 10737418240) { $e.Add('AAP_ManifestInvalid: size_max_bytes must be 1..10737418240') }
    $exact = Get-AapProp $Entry 'size_bytes'
    if ($null -ne $exact -and ($exact -isnot [ValueType] -or $exact -lt 0 -or ($max -is [ValueType] -and $exact -gt $max))) { $e.Add('AAP_ManifestInvalid: size_bytes must be within size_max_bytes') }
    $ct = @(Get-AapProp $Entry 'content_types' | Where-Object { $_ })
    if ($ct.Count -lt 1) { $e.Add('AAP_ManifestInvalid: content_types needs at least one media type') }
    $lic = Get-AapProp $Entry 'license'
    if ((Get-AapProp $lic 'class') -notin @('open-source', 'vendor-redistributable', 'proprietary-eula', 'unknown')) { $e.Add('AAP_ManifestInvalid: license.class') }
    if ((Get-AapProp $lic 'redistribution') -notin @('allowed', 'restricted', 'forbidden', 'unknown')) { $e.Add('AAP_ManifestInvalid: license.redistribution') }
    $r = Get-AapProp $Entry 'retry'
    $ma = Get-AapProp $r 'max_attempts'; $bs = Get-AapProp $r 'backoff_seconds'; $ts = Get-AapProp $r 'timeout_seconds'
    if ($ma -isnot [ValueType] -or $ma -lt 1 -or $ma -gt 10) { $e.Add('AAP_ManifestInvalid: retry.max_attempts 1..10') }
    if ($bs -isnot [ValueType] -or $bs -lt 0 -or $bs -gt 60) { $e.Add('AAP_ManifestInvalid: retry.backoff_seconds 0..60') }
    if ($ts -isnot [ValueType] -or $ts -lt 1 -or $ts -gt 3600) { $e.Add('AAP_ManifestInvalid: retry.timeout_seconds 1..3600') }
    if ((Get-AapProp $Entry 'evidence_ref') -isnot [string] -or -not (Get-AapProp $Entry 'evidence_ref')) { $e.Add('AAP_ManifestInvalid: evidence_ref is required') }
    return $e.ToArray()
}

function Test-AapManifest {
    <# Returns every problem in the manifest; an empty list means it is acceptable. #>
    param([Parameter(Mandatory)]$Manifest, [switch]$AllowTestSources)
    $e = New-Object System.Collections.Generic.List[string]
    if ((Get-AapProp $Manifest 'schema') -ne 1) { $e.Add('AAP_ManifestInvalid: schema must be 1') }
    $entries = @(Get-AapProp $Manifest 'entries')
    $seen = @{}
    foreach ($en in $entries) {
        $id = "$(Get-AapProp $en 'name')@$(Get-AapProp $en 'version')"
        foreach ($p in @(Test-AapEntry -Entry $en -AllowTestSources:$AllowTestSources)) { $e.Add("$id -> $p") }
        if ($seen.ContainsKey($id)) { $e.Add("AAP_ManifestInvalid: duplicate entry $id") }
        $seen[$id] = $true
        $h = Get-AapProp $en 'hash'
        if ((Get-AapProp $h 'source') -eq 'upstream-file') {
            $upName = Get-AapProp $h 'upstream_entry'
            $ups = @($entries | Where-Object { (Get-AapProp $_ 'name') -eq $upName })
            if ($ups.Count -eq 0) { $e.Add("AAP_ManifestInvalid: $id upstream_entry not in manifest") }
            elseif ($ups.Count -gt 1) { $e.Add("AAP_ManifestInvalid: $id upstream_entry '$upName' names more than one entry") }
            elseif ((Get-AapProp $en 'name') -eq $upName) { $e.Add("AAP_ManifestInvalid: $id lists itself as its upstream hash file") }
            elseif ((Get-AapProp (Get-AapProp $ups[0] 'hash') 'source') -ne 'literal') { $e.Add("AAP_ManifestInvalid: $id upstream file must itself have a literal hash") }
        }
    }
    $nr = @(Get-AapProp $Manifest 'not_reproducible')
    foreach ($b in $nr) {
        foreach ($f in 'id', 'profiles', 'name', 'blocker_kind', 'reason', 'owner_action', 'evidence_ref') {
            if (-not (Get-AapProp $b $f)) { $e.Add("AAP_ManifestInvalid: not_reproducible '$(Get-AapProp $b 'id')' lacks $f") }
        }
        if ($entries | Where-Object { (Get-AapProp $_ 'name') -eq (Get-AapProp $b 'id') }) { $e.Add("AAP_ManifestInvalid: '$(Get-AapProp $b 'id')' is both an entry and a blocker") }
    }
    return $e.ToArray()
}

function Read-AapManifest {
    param([Parameter(Mandatory)][string]$Path, [switch]$AllowTestSources)
    $m = [IO.File]::ReadAllText((Resolve-AapPath $Path)) | ConvertFrom-Json
    $errs = @(Test-AapManifest -Manifest $m -AllowTestSources:$AllowTestSources)
    if ($errs.Count) { throw ($errs -join "`n") }
    return $m
}

# ---- hash resolution and file verification ----------------------------------------------------

function Get-AapStagedPath([string]$StagingRoot, $Entry) {
    Join-Path (Join-Path (Join-Path (Resolve-AapPath $StagingRoot) (Get-AapProp $Entry 'name')) (Get-AapProp $Entry 'version')) (Get-AapProp $Entry 'file_name')
}

function Get-AapHexDigest([byte[]]$Bytes, [string]$Algorithm) {
    $h = if ($Algorithm -eq 'sha512') { [Security.Cryptography.SHA512]::Create() } else { [Security.Cryptography.SHA256]::Create() }
    try { return ([BitConverter]::ToString($h.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant() } finally { $h.Dispose() }
}

function Resolve-AapExpectedHash {
    <# Returns @{ Value; Source } or $null when no hash is known yet (a first-fetch entry with no record).
       A first-fetch entry with a record resolves to the recorded hash. Throws on a missing or conflicting source.
       Does not assume a validated manifest: an upstream hash file must be exactly one other entry and must itself
       carry a literal hash, which also rules out any chain or cycle. #>
    param([Parameter(Mandatory)]$Entry, $Manifest, [Parameter(Mandatory)][string]$StagingRoot)
    $StagingRoot = Resolve-AapPath $StagingRoot
    $h = Get-AapProp $Entry 'hash'
    $source = Get-AapProp $h 'source'
    $value = Get-AapProp $h 'value'
    if ($source -eq 'literal') { return @{ Value = $value; Source = 'literal' } }
    if ($source -eq 'first-fetch') {
        $recordPath = (Get-AapStagedPath $StagingRoot $Entry) + '.first-fetch.json'
        if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) { return $null }
        Assert-AapNotLink $recordPath 'first-fetch record'
        $rec = Read-AapJsonFile $recordPath
        $algo = Get-AapProp $h 'algorithm'
        $len = if ($algo -eq 'sha512') { 128 } else { 64 }
        $recorded = Get-AapProp $rec 'hash'
        if ((Get-AapProp $rec 'schema') -ne 'aap-first-fetch/1' -or (Get-AapProp $rec 'name') -ne (Get-AapProp $Entry 'name') -or
            (Get-AapProp $rec 'version') -ne (Get-AapProp $Entry 'version') -or (Get-AapProp $rec 'file_name') -ne (Get-AapProp $Entry 'file_name') -or
            (Get-AapProp $rec 'algorithm') -ne $algo -or $recorded -isnot [string] -or $recorded -cnotmatch "^[0-9a-f]{$len}$") {
            throw "AAP_HashSourceMissing: the first-fetch record $recordPath is not valid for this entry"
        }
        return @{ Value = $recorded; Source = 'first-fetch-recorded' }
    }
    if ($source -ne 'upstream-file') { throw "AAP_ManifestInvalid: unknown hash source '$source'" }
    $upName = Get-AapProp $h 'upstream_entry'
    $key = Get-AapProp $h 'upstream_key'
    $ups = @()
    if ($Manifest) { $ups = @(@(Get-AapProp $Manifest 'entries') | Where-Object { (Get-AapProp $_ 'name') -eq $upName }) }
    if ($ups.Count -eq 0) { throw "AAP_HashSourceMissing: upstream hash file entry '$upName' is not in the manifest" }
    if ($ups.Count -gt 1) { throw "AAP_ManifestInvalid: upstream hash file entry '$upName' names more than one entry" }
    $up = $ups[0]
    if ((Get-AapProp $up 'name') -eq (Get-AapProp $Entry 'name')) { throw "AAP_ManifestInvalid: '$upName' lists itself as its upstream hash file" }
    $upHash = Get-AapProp $up 'hash'
    $upValue = Get-AapProp $upHash 'value'
    if ((Get-AapProp $upHash 'source') -ne 'literal' -or $upValue -isnot [string] -or $upValue -cnotmatch '^[0-9a-f]{64}$' -or (Get-AapProp $upHash 'algorithm') -ne 'sha256') {
        throw "AAP_ManifestInvalid: upstream hash file '$upName' must carry a literal sha256 hash"
    }
    $upPath = Get-AapStagedPath $StagingRoot $up
    $folder = $StagingRoot
    foreach ($seg in @((Get-AapProp $up 'name'), (Get-AapProp $up 'version'))) { $folder = Join-Path $folder $seg; Assert-AapNotLink $folder 'folder of the upstream hash file' }
    if (-not (Test-Path -LiteralPath $upPath -PathType Leaf)) { throw "AAP_HashSourceMissing: upstream hash file '$upName' is not staged at $upPath" }
    Assert-AapNotLink $upPath 'upstream hash file'
    # The file is read once; the size bound, the hash and the lines come from the same bytes.
    $max = [long](Get-AapProp $up 'size_max_bytes')
    $exact = Get-AapProp $up 'size_bytes'
    if ((Get-Item -LiteralPath $upPath).Length -gt $max) { throw "AAP_SizeExceeded: upstream hash file '$upName' is larger than its bound of $max" }
    $bytes = [IO.File]::ReadAllBytes($upPath)
    if ($bytes.Length -gt $max) { throw "AAP_SizeExceeded: upstream hash file '$upName' is larger than its bound of $max" }
    if ($null -ne $exact -and $bytes.Length -ne [long]$exact) { throw "AAP_SizeMismatch: upstream hash file '$upName' has $($bytes.Length) bytes, manifest says $exact" }
    $actual = Get-AapHexDigest $bytes 'sha256'
    if ($actual -ne $upValue) { throw "AAP_HashMismatch: upstream hash file '$upName' is $actual, expected $upValue (literal)" }
    $found = @()
    foreach ($line in ([Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF) -split "`r?`n")) {
        if ($line -match '^([0-9A-Fa-f]{64})[ \t]+\*?(.+?)\s*$' -and ($Matches[2] -replace '^\./', '') -eq $key -and $Matches[1].ToLowerInvariant() -ne $script:Placeholder) { $found += $Matches[1].ToLowerInvariant() }
    }
    if ($found.Count -ne 1) { throw "AAP_HashSourceMissing: '$key' appears $($found.Count) times in upstream file '$upName'" }
    if ($null -ne $value -and $value -ne $found[0]) { throw "AAP_HashSourceConflict: pinned value for '$(Get-AapProp $Entry 'name')' differs from upstream file '$upName'" }
    return @{ Value = $found[0]; Source = "upstream-file:$upName" + $(if ($null -ne $value) { '+literal' } else { '' }) }
}

# One pass over the file: SHA-256 always, SHA-512 when asked, and the number of bytes those digests cover.
function Get-AapDigest {
    param([Parameter(Mandatory)][string]$Path, [switch]$Sha512)
    $a = [Security.Cryptography.SHA256]::Create()
    $b = if ($Sha512) { [Security.Cryptography.SHA512]::Create() } else { $null }
    $total = 0L
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $buf = New-Object byte[] 1048576
        while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
            $total += $n
            [void]$a.TransformBlock($buf, 0, $n, $null, 0)
            if ($b) { [void]$b.TransformBlock($buf, 0, $n, $null, 0) }
        }
        [void]$a.TransformFinalBlock($buf, 0, 0)
        if ($b) { [void]$b.TransformFinalBlock($buf, 0, 0) }
    } finally { $fs.Dispose() }
    $hex = { param($alg) ([BitConverter]::ToString($alg.Hash) -replace '-', '').ToLowerInvariant() }
    return @{ Bytes = $total; Sha256 = (& $hex $a); Sha512 = $(if ($b) { & $hex $b } else { $null }) }
}

function Confirm-AapFile {
    <# Size bound, exact size and hash. Returns bytes and both digests, or throws. $Expected $null means first-fetch (record only). #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Entry, $Expected)
    $Path = Resolve-AapPath $Path
    $max = [long](Get-AapProp $Entry 'size_max_bytes')
    $exact = Get-AapProp $Entry 'size_bytes'
    $length = (Get-Item -LiteralPath $Path).Length
    if ($length -gt $max) { throw "AAP_SizeExceeded: $length bytes exceeds the bound of $max" }
    $algo = Get-AapProp (Get-AapProp $Entry 'hash') 'algorithm'
    $d = Get-AapDigest -Path $Path -Sha512:($algo -eq 'sha512')
    if ($d.Bytes -gt $max) { throw "AAP_SizeExceeded: $($d.Bytes) bytes exceeds the bound of $max" }
    if ($null -ne $exact -and $d.Bytes -ne [long]$exact) { throw "AAP_SizeMismatch: $($d.Bytes) bytes, manifest says $exact" }
    $actual = if ($algo -eq 'sha512') { $d.Sha512 } else { $d.Sha256 }
    if ($null -ne $Expected -and $actual -ne $Expected.Value) { throw "AAP_HashMismatch: $algo is $actual, expected $($Expected.Value) ($($Expected.Source))" }
    return @{ Bytes = $d.Bytes; Sha256 = $d.Sha256; Actual = $actual; Algorithm = $algo }
}

# ---- download --------------------------------------------------------------------------------

function Assert-AapSource {
    param([Uri]$Uri, [string[]]$Hosts, [bool]$Loopback, [string]$Code)
    $okScheme = ($Uri.Scheme -eq 'https') -or ($Loopback -and $Uri.Scheme -eq 'http' -and (Test-AapLoopback $Uri.Host))
    if (-not $okScheme) { throw "AAP_SchemeRejected: $($Uri.Scheme)://$($Uri.Host) is not an allowed source" }
    if ($Uri.UserInfo) { throw "AAP_SchemeRejected: credentials in url" }
    if ($Uri.Host.ToLowerInvariant() -notin $Hosts) { throw "${Code}: host '$($Uri.Host)' is not allowlisted for this artifact" }
}

function Invoke-AapHttpAttempt {
    param($Entry, [string]$Url, [string]$Part, [string[]]$Hosts, [bool]$Loopback, [bool]$NoRedirect)
    $max = [long](Get-AapProp $Entry 'size_max_bytes')
    $timeout = [int](Get-AapProp (Get-AapProp $Entry 'retry') 'timeout_seconds')
    $types = @(Get-AapProp $Entry 'content_types' | ForEach-Object { $_.ToLowerInvariant() })
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($timeout)   # bounds the wait for response headers
    $chain = New-Object System.Collections.ArrayList
    $resp = $null
    try {
        $uri = [Uri]$Url
        $hop = 0
        while ($true) {
            Assert-AapSource -Uri $uri -Hosts $Hosts -Loopback $Loopback -Code $(if ($hop -eq 0) { 'AAP_SchemeRejected' } else { 'AAP_RedirectRejected' })
            try { $resp = $client.GetAsync($uri, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult() }
            catch { throw "AAP_Transient: request failed: $(Get-AapRootMessage $_)" }
            $code = [int]$resp.StatusCode
            [void]$chain.Add([ordered]@{ url = (Format-AapUrl $uri); status = $code })
            if ($code -ge 300 -and $code -lt 400) {
                if ($NoRedirect) { throw "AAP_RedirectRejected: HTTP $code from $($uri.Host); an entry with no published hash never follows a redirect" }
                $loc = $resp.Headers.Location
                if (-not $loc) { throw 'AAP_SourceUnavailable: redirect without a Location header' }
                $hop++
                if ($hop -gt 5) { throw 'AAP_RedirectRejected: more than 5 redirects' }
                $uri = if ($loc.IsAbsoluteUri) { $loc } else { New-Object Uri($uri, $loc) }
                $resp.Dispose(); $resp = $null
                continue
            }
            break
        }
        if ($code -eq 408 -or $code -eq 429 -or $code -ge 500) { throw "AAP_Transient: HTTP $code" }
        if ($code -ne 200) { throw "AAP_SourceUnavailable: HTTP $code from $($uri.Host)" }
        $mt = $resp.Content.Headers.ContentType
        $media = if ($mt) { $mt.MediaType.ToLowerInvariant() } else { '' }
        if ($media -notin $types) { throw "AAP_ContentTypeRejected: '$media' is not one of $($types -join ', ')" }
        $cl = $resp.Content.Headers.ContentLength
        if ($null -ne $cl -and $cl -gt $max) { throw "AAP_SizeExceeded: server announces $cl bytes, bound is $max" }
        # The body must finish within timeout_seconds of the headers. A read cancellation token is not honoured by
        # .NET Framework (Windows PowerShell 5.1), so wait on each read task against the deadline; the finally
        # blocks below then dispose the stream, response and client, which aborts a stalled read.
        $deadline = [DateTime]::UtcNow.AddSeconds($timeout)
        $in = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        Assert-AapNotLink $Part 'partial download'
        # A stale partial file is deleted, never opened: an old one may be a hard link to another file (a hard link is not
        # a reparse point) and truncating it would truncate that file. CreateNew fails if anything is there again.
        Remove-AapStaged $Part
        $out = [IO.File]::Open($Part, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $total = 0L
        try {
            $buf = New-Object byte[] 81920
            while ($true) {
                $task = $in.ReadAsync($buf, 0, $buf.Length)
                $left = $deadline - [DateTime]::UtcNow
                $done = $false
                if ($left -gt [TimeSpan]::Zero) {
                    try { $done = $task.Wait($left) }
                    catch { throw "AAP_Transient: read failed: $(Get-AapRootMessage $_)" }
                }
                if (-not $done) { throw "AAP_Transient: body read timed out after ${timeout}s" }
                $n = $task.Result
                if ($n -le 0) { break }
                $total += $n
                if ($total -gt $max) { throw "AAP_SizeExceeded: body passed the bound of $max bytes" }
                $out.Write($buf, 0, $n)
            }
        } finally { $out.Dispose(); $in.Dispose() }
        if ($null -ne $cl -and $total -ne $cl) { throw "AAP_Transient: partial body, $total of $cl bytes" }
        return @{ Chain = $chain; FinalUrl = (Format-AapUrl $uri); ContentType = $media }
    } finally {
        if ($resp) { $resp.Dispose() }
        $client.Dispose()
    }
}

function Copy-AapFileSource {
    param($Entry, [string]$Url, [string]$Part)
    $uri = [Uri]$Url
    if ($uri.Host -or $uri.IsUnc -or $uri.LocalPath.StartsWith('\\')) { throw "AAP_SchemeRejected: a file source must be a local path, not a network share: $Url" }
    $src = $uri.LocalPath
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw "AAP_Transient: file source missing: $src" }
    if ((Get-Item -LiteralPath $src).Length -gt [long](Get-AapProp $Entry 'size_max_bytes')) { throw 'AAP_SizeExceeded: file source is larger than the bound' }
    Assert-AapNotLink $Part 'partial download'
    Remove-AapStaged $Part
    [IO.File]::Copy($src, $Part, $false)   # fails if anything is there again, like CreateNew
    return @{ Chain = @([ordered]@{ url = $Url; status = 200 }); FinalUrl = $Url; ContentType = 'file' }
}

# ---- acquisition -----------------------------------------------------------------------------

function Get-AapArtifact {
    <#
    .SYNOPSIS
      Fetch (or, with -Offline, verify) one manifest entry into <StagingRoot>/<name>/<version>/<file_name>.
    .DESCRIPTION
      The staging root must pass the trust checks first (see "staging trust" above), and so must the name and version
      folders below it; a root or folder that does not, a link at any level, or a link in place of a file stops the run
      before anything is written.
      The file is published into staging only after size and hash verification; a partial or rejected
      download never appears under its final name. A provenance record is written beside it
      (<file>.provenance.json on acceptance, <file>.rejected.json on rejection; the other one is removed)
      and also returned. A first-fetch entry (no upstream hash) is never reused: every online run downloads it again,
      and the first accepted download is recorded once in <file>.first-fetch.json; every later run, online or
      offline, must match that record. The staged file of such an entry is replaced only after the new download has
      passed the record, so a failed download costs nothing. Such an entry is accepted but never verified: the result
      says Verified = $false.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$StagingRoot,
        $Manifest,
        [switch]$Offline,
        [switch]$RecordFirstFetch,
        [switch]$AllowLoopbackHttp,
        [switch]$AllowFileSource,
        [string[]]$TrustedSid = @(),
        [switch]$SkipAncestorCheck
    )
    $StagingRoot = Resolve-AapPath $StagingRoot
    $started = [DateTime]::UtcNow
    $name = [string](Get-AapProp $Entry 'name')
    $version = [string](Get-AapProp $Entry 'version')
    $lic = Get-AapProp $Entry 'license'
    $isFirstFetch = ((Get-AapProp (Get-AapProp $Entry 'hash') 'source') -eq 'first-fetch')
    $prov = [ordered]@{
        schema = 'aap-provenance/1'; name = $name; version = $version; file_name = Get-AapProp $Entry 'file_name'
        outcome = 'rejected'; reason = $null; detail = $null; mode = $(if ($Offline) { 'offline' } else { 'online' })
        staging_check = $(if (@($TrustedSid | Where-Object { $_ }).Count -or $SkipAncestorCheck) { 'relaxed' } else { 'strict' })
        requested_url = $null; url_chain = @(); final_url = $null; content_type = $null; attempts = 0
        acquired_at = $null; started_at = $started.ToString('yyyy-MM-ddTHH:mm:ssZ'); ended_at = $null; bytes = $null; sha256 = $null
        hash = [ordered]@{ algorithm = Get-AapProp (Get-AapProp $Entry 'hash') 'algorithm'; expected = $null; source = $null; verified = $false }
        license = [ordered]@{ class = Get-AapProp $lic 'class'; redistribution = Get-AapProp $lic 'redistribution'; note = Get-AapProp $lic 'note' }
        evidence_ref = Get-AapProp $Entry 'evidence_ref'
        tool = [ordered]@{ name = 'Get-AapArtifact'; version = $script:ToolVersion }
    }
    $notes = New-Object System.Collections.Generic.List[string]
    $final = $null
    $part = $null
    try {
        $errs = @(Test-AapEntry -Entry $Entry -AllowTestSources:($AllowLoopbackHttp -or $AllowFileSource))
        if ($errs.Count) { throw $errs[0] }
        # Nothing is written, and no rejection record either, until the root and every level below it are known to be plain folders.
        Assert-AapStagingRoot -Root $StagingRoot -TrustedSid $TrustedSid -SkipAncestorCheck:$SkipAncestorCheck
        $dir = Initialize-AapStagedDir -Root $StagingRoot -Name $name -Version $version -TrustedSid $TrustedSid
        $final = Join-Path $dir (Get-AapProp $Entry 'file_name')
        $part = $final + '.part'
        $recordPath = $final + '.first-fetch.json'
        $expected = Resolve-AapExpectedHash -Entry $Entry -Manifest $Manifest -StagingRoot $StagingRoot
        if ($expected) { $prov.hash.expected = $expected.Value; $prov.hash.source = $expected.Source } else { $prov.hash.source = 'first-fetch' }
        if (-not $expected) {
            if ($Offline) { throw "AAP_OfflineIncomplete: '$name' has no first-fetch record ($recordPath), so it is not staged" }
            if (-not $RecordFirstFetch) { throw "AAP_HashSourceMissing: '$name' has no published hash and no first-fetch record; pass -RecordFirstFetch to record one unverified" }
        }

        $verified = $null
        $replaced = $null   # said once a verified download has taken the place of a staged file
        $existing = Get-AapAttributes $final
        if ($existing -ne -1) {
            Assert-AapNotLink $final 'staged file'
            if (($existing -band $script:DirectoryAttr) -ne 0) { throw "AAP_StagingUntrusted: $final is a folder where a file belongs" }
            if (-not $expected) {
                # Nobody vouches for this file, and it stays where it is until a download has been checked and replaces it.
                $replaced = 'replaced a staged file that has no first-fetch record'
            } elseif ($isFirstFetch -and -not $Offline) {
                # Nothing but a recorded guess vouches for such a file, so it is never reused: it is downloaded again and compared.
                # It stays until the new download has passed, so a network error does not cost a good file. One that already
                # fails the record is removed now, so that a rejected run never leaves a bad file under its final name.
                $replaced = 'replaced an existing staged file: a first-fetch entry is downloaded again on every online run'
                try { [void](Confirm-AapFile -Path $final -Entry $Entry -Expected $expected) }
                catch {
                    $notes.Add("removed the existing staged file, which no longer matches its first-fetch record: $($_.Exception.Message)")
                    Remove-AapStaged $final
                }
            } else {
                try { $verified = Confirm-AapFile -Path $final -Entry $Entry -Expected $expected }
                catch {
                    $orig = $_
                    $why = $orig.Exception.Message
                    if ($Offline) {
                        if ($why -match '^AAP_(HashMismatch|SizeExceeded|SizeMismatch):') { $notes.Add("moved the failing file to $(Split-Path -Leaf (Move-AapAside $final))") }
                        throw $orig
                    }
                    $notes.Add("replaced an existing staged file that failed verification: $why")
                    Remove-AapStaged $final
                }
            }
        } elseif ($Offline) { throw "AAP_OfflineIncomplete: $final is not staged" }

        if ($verified) {
            # No download: keep where the file came from, taken from the earlier accepted record when it describes this very file.
            $prov.mode = $(if ($Offline) { 'offline' } else { 'reuse' })
            $old = Read-AapJsonFile ($final + '.provenance.json')
            if ($old -and (Get-AapProp $old 'outcome') -eq 'accepted' -and (Get-AapProp $old 'sha256') -eq $verified.Sha256) {
                $prov.requested_url = Get-AapProp $old 'requested_url'
                $prov.url_chain = @(Get-AapProp $old 'url_chain' | Where-Object { $_ })
                $prov.final_url = Get-AapProp $old 'final_url'
                $prov.content_type = Get-AapProp $old 'content_type'
                $prov.attempts = [int](Get-AapProp $old 'attempts')
                $first = Get-AapProp $old 'acquired_at'
                if (-not $first) { $first = Get-AapProp $old 'started_at' }
                $prov.acquired_at = Format-AapTime $first
            }
        } else {
            $urls = @(Get-AapProp $Entry 'urls')
            $hosts = @($urls | ForEach-Object { ([Uri]$_).Host.ToLowerInvariant() }) + @(Get-AapProp $Entry 'redirect_hosts' | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
            $retry = Get-AapProp $Entry 'retry'
            $max = [int](Get-AapProp $retry 'max_attempts')
            $got = $null
            $last = $null
            for ($i = 1; $i -le $max -and -not $got; $i++) {
                $prov.attempts = $i
                $url = $urls[($i - 1) % $urls.Count]
                if ($i -eq 1) { $prov.requested_url = (Format-AapUrl $url) }
                try {
                    if (([Uri]$url).Scheme -eq 'file') {
                        if (-not $AllowFileSource) { throw "AAP_SchemeRejected: file sources need -AllowFileSource" }
                        $got = Copy-AapFileSource -Entry $Entry -Url $url -Part $part
                    } else {
                        $got = Invoke-AapHttpAttempt -Entry $Entry -Url $url -Part $part -Hosts $hosts -Loopback ([bool]$AllowLoopbackHttp) -NoRedirect $isFirstFetch
                    }
                } catch {
                    $orig = $_
                    try { Remove-AapStaged $part } catch { $null = $_ }
                    # Only a failure tagged as transient is retried. A refusal, a full disk or a permission error ends
                    # the run at once and is not reported as an unavailable source.
                    if ($orig.Exception.Message -notlike 'AAP_Transient:*') { throw $orig }
                    $last = $orig.Exception.Message -replace '^AAP_Transient: ', ''
                    if ($i -lt $max) { Start-Sleep -Seconds ([int](Get-AapProp $retry 'backoff_seconds') * $i) }
                }
            }
            if (-not $got) { throw "AAP_SourceUnavailable: $max attempt(s) failed, last: $last" }
            if ($isFirstFetch -and @($got.Chain).Count -eq 0) { throw 'AAP_HashSourceMissing: no download is on record for this first-fetch entry, so its hash is not recorded' }
            $prov.url_chain = @($got.Chain); $prov.final_url = $got.FinalUrl; $prov.content_type = $got.ContentType
            try { $verified = Confirm-AapFile -Path $part -Entry $Entry -Expected $expected }
            catch { $orig = $_; try { Remove-AapStaged $part } catch { $null = $_ }; throw $orig }
            Assert-AapNotLink $final 'staged file'
            Move-Item -LiteralPath $part -Destination $final -Force
            if ($replaced) { $notes.Add($replaced) }
            $prov.acquired_at = $prov.started_at
            if (-not $expected) {
                Write-AapJson ([ordered]@{
                        schema = 'aap-first-fetch/1'; name = $name; version = $version; file_name = Get-AapProp $Entry 'file_name'
                        algorithm = Get-AapProp (Get-AapProp $Entry 'hash') 'algorithm'; hash = $verified.Actual; sha256 = $verified.Sha256
                        bytes = $verified.Bytes; recorded_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
                        requested_url = $prov.requested_url; final_url = $prov.final_url
                    }) $recordPath
            }
        }
        $prov.bytes = $verified.Bytes; $prov.sha256 = $verified.Sha256
        $prov.hash.verified = [bool]($expected -and $expected.Source -ne 'first-fetch-recorded')
        if (-not $expected) { $prov.hash.expected = $verified.Actual; $notes.Add('first fetch: hash recorded, not verified against an upstream source') }
        elseif ($expected.Source -eq 'first-fetch-recorded') { $notes.Add('matches the hash recorded at first fetch; no upstream source has verified it') }
        $prov.detail = $(if ($notes.Count) { $notes -join '; ' } else { $null })
        $prov.outcome = 'accepted'
    } catch {
        $orig = $_
        $m = $orig.Exception.Message
        $prov.reason = if ($m -match '^(AAP_[A-Za-z]+):') { $Matches[1] } else { 'AAP_Unexpected' }
        $prov.detail = $m + $(if ($notes.Count) { ' [' + ($notes -join '; ') + ']' } else { '' })
        $prov.ended_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        if ($final) {
            # An accepted record must not outlive a rejection of the same file. A failure to write the record (a link,
            # a full disk) must not hide the error that is being reported.
            try {
                Remove-AapStaged ($final + '.provenance.json')
                Write-AapJson $prov ($final + '.rejected.json')
            } catch { $null = $_ }
        }
        throw $orig
    }
    $prov.ended_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    Remove-AapStaged ($final + '.rejected.json')
    $provPath = $final + '.provenance.json'
    Write-AapJson $prov $provPath
    return [pscustomobject]@{ Path = $final; ProvenancePath = $provPath; Provenance = $prov; Verified = [bool]$prov.hash.verified }
}

function Invoke-AapManifest {
    <# Acquire (or with -Offline verify) every entry, or only -Name. Never stops at the first rejection.
       The manifest is validated first, and the staging root is checked once before any entry is touched; either failing
       is an error, not a list of rejections. A -Name that is not an entry of the manifest is an error.
       Unreproducible inputs are returned as blockers. Complete is true only when nothing was rejected and nothing was
       accepted without verification (a first-fetch entry); Rejected and Unverified name the entries. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$StagingRoot,
        [string[]]$Name,
        [switch]$Offline, [switch]$RecordFirstFetch, [switch]$AllowLoopbackHttp, [switch]$AllowFileSource,
        [string[]]$TrustedSid = @(), [switch]$SkipAncestorCheck
    )
    $StagingRoot = Resolve-AapPath $StagingRoot
    $problems = @(Test-AapManifest -Manifest $Manifest -AllowTestSources:($AllowLoopbackHttp -or $AllowFileSource))
    if ($problems.Count) { throw "AAP_ManifestInvalid: $($problems.Count) problem(s)`n$($problems -join "`n")" }
    $all = @(Get-AapProp $Manifest 'entries')
    $entries = $all
    if ($Name) {
        $known = @($all | ForEach-Object { Get-AapProp $_ 'name' })
        $blockers = @(@(Get-AapProp $Manifest 'not_reproducible') | ForEach-Object { Get-AapProp $_ 'id' })
        $bad = @($Name | Where-Object { $_ -notin $known })
        if ($bad.Count) {
            $why = @($bad | ForEach-Object { if ($_ -in $blockers) { "'$_' is a documented blocker, not an acquirable entry" } else { "'$_' is not in the manifest" } })
            throw "AAP_ManifestInvalid: $($why -join '; ')"
        }
        $entries = @($all | Where-Object { (Get-AapProp $_ 'name') -in $Name })
    }
    if ($entries.Count -eq 0) { throw 'AAP_ManifestInvalid: the manifest has no entries to acquire' }
    Assert-AapStagingRoot -Root $StagingRoot -TrustedSid $TrustedSid -SkipAncestorCheck:$SkipAncestorCheck
    $ordered = @($entries | Where-Object { (Get-AapProp (Get-AapProp $_ 'hash') 'source') -ne 'upstream-file' }) + @($entries | Where-Object { (Get-AapProp (Get-AapProp $_ 'hash') 'source') -eq 'upstream-file' })
    $results = foreach ($en in $ordered) {
        try {
            $a = Get-AapArtifact -Entry $en -StagingRoot $StagingRoot -Manifest $Manifest -Offline:$Offline -RecordFirstFetch:$RecordFirstFetch -AllowLoopbackHttp:$AllowLoopbackHttp -AllowFileSource:$AllowFileSource -TrustedSid $TrustedSid -SkipAncestorCheck:$SkipAncestorCheck
            [pscustomobject]@{ Name = Get-AapProp $en 'name'; Status = 'accepted'; Verified = [bool]$a.Verified; Reason = $null; Path = $a.Path; Message = $null }
        } catch {
            $m = $_.Exception.Message
            [pscustomobject]@{ Name = Get-AapProp $en 'name'; Status = 'rejected'; Verified = $false; Reason = $(if ($m -match '^(AAP_[A-Za-z]+):') { $Matches[1] } else { 'AAP_Unexpected' }); Path = $null; Message = $m }
        }
    }
    $results = @($results)
    $rejected = @($results | Where-Object Status -eq 'rejected' | ForEach-Object Name)
    $unverified = @($results | Where-Object { $_.Status -eq 'accepted' -and -not $_.Verified } | ForEach-Object Name)
    [pscustomobject]@{
        Complete = ($rejected.Count -eq 0 -and $unverified.Count -eq 0)
        Rejected = $rejected
        Unverified = $unverified
        Results = $results
        Blockers = @(Get-AapProp $Manifest 'not_reproducible')
    }
}

# ---- evidence --------------------------------------------------------------------------------

function New-AapEvidenceRecord {
    <# Writes an evidence-bundle record (parity/contracts/evidence-bundle.schema.json) for one provenance file.
       The provenance file itself is listed as an artifact by hash, so URL chain and license class stay retrievable.
       For an accepted record the staged file is hashed again now and compared with the recorded sha256: a provenance
       file alone proves nothing, and a file that changed or went missing is a failure (AAP_ArtifactChanged,
       AAP_ArtifactMissing), never a pass.
       -ExpectedReason AAP_<Reason> records a deliberate negative test: the record passes only when the candidate was
       rejected for exactly that reason; a rejection for any other reason is reported as unknown.
       A run that relaxed the staging trust checks (-TrustedSid, -SkipAncestorCheck; the provenance says
       staging_check = relaxed) proves nothing about who could change the staged file. What such a run accepted is
       reported as unknown, never as a pass, and the command string of every record from it says staging_check=relaxed.
       A record from a strict run is unchanged.
       -HeadSha is required: the staging folder is not a git work tree, so there is nothing to infer it from. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProvenancePath,
        [Parameter(Mandatory)][string]$OutPath,
        [Parameter(Mandatory)][string]$HeadSha,
        [string]$ManifestPath,
        [string]$Item = 'P03',
        [string]$Verifier = 'pending-independent-verifier',
        [ValidatePattern('^AAP_[A-Za-z]+$')][string]$ExpectedReason
    )
    $ProvenancePath = Resolve-AapPath $ProvenancePath
    $OutPath = Resolve-AapPath $OutPath
    if ($ManifestPath) { $ManifestPath = Resolve-AapPath $ManifestPath }
    $p = [IO.File]::ReadAllText($ProvenancePath) | ConvertFrom-Json
    if ($HeadSha -cnotmatch '^[0-9a-f]{40}$') { throw 'New-AapEvidenceRecord: pass -HeadSha, a full 40-hex commit' }
    $san = { param($s) ($s -replace '[^A-Za-z0-9._-]', '_') }
    $accepted = $p.outcome -eq 'accepted'
    $verified = $accepted -and $p.hash.verified
    # Anything but a recorded strict run counts as relaxed, including a provenance file that does not say.
    $relaxed = (Get-AapProp $p 'staging_check') -ne 'strict'
    $seen = if ($verified -and -not $relaxed) { 'success' } elseif ($accepted) { 'unknown' } else { 'failure' }
    $observedReason = if ($accepted) { 'none' } else { [string]$p.reason }
    $fileName = [string]$p.file_name
    $fileBytes = if ($accepted) { [long]$p.bytes } else { 0L }
    $fileSha = if ($accepted) { [string]$p.sha256 } else { $null }
    if ($accepted) {
        if ($ProvenancePath -notmatch '\.provenance\.json$') { throw 'New-AapEvidenceRecord: an accepted record must be named <file>.provenance.json so the file can be hashed again' }
        $artifact = $ProvenancePath -replace '\.provenance\.json$', ''
        if (-not (Test-Path -LiteralPath $artifact -PathType Leaf)) {
            $seen = 'failure'; $observedReason = 'AAP_ArtifactMissing'; $fileSha = $null
        } else {
            $nowSha = Get-AapLowerHash $artifact 'SHA256'
            if ($nowSha -ne $fileSha) { $seen = 'failure'; $observedReason = 'AAP_ArtifactChanged'; $fileSha = $nowSha; $fileBytes = (Get-Item -LiteralPath $artifact).Length }
        }
    }
    if ($ExpectedReason) {
        $expected = 'failure'
        $observed = if ($seen -eq 'failure' -and $observedReason -ne $ExpectedReason) { 'unknown' } else { $seen }
    } else {
        $expected = 'success'
        $observed = $seen
    }
    $result = if ($observed -eq 'unknown') { 'unknown' } elseif ($observed -eq $expected) { 'pass' } else { 'fail' }
    $exit = if ($observed -eq 'success') { 0 } elseif ($observed -eq 'failure') { 1 } else { $null }
    $artifacts = @([ordered]@{ name = (& $san ([IO.Path]::GetFileName($ProvenancePath))); bytes = (Get-Item -LiteralPath $ProvenancePath).Length; sha256 = Get-AapLowerHash $ProvenancePath 'SHA256' })
    if ($accepted -and $fileSha) { $artifacts = @([ordered]@{ name = (& $san $fileName); bytes = $fileBytes; sha256 = $fileSha }) + $artifacts }
    $manifestHash = if ($ManifestPath) { Get-AapLowerHash $ManifestPath 'SHA256' } else { $null }
    $fixture = ("images/common/$($p.name)-$($p.version)").ToLowerInvariant() -replace '[^a-z0-9._/-]', '.'
    $command = "Get-AapArtifact $($p.name) $($p.version) mode=$($p.mode)"
    if ($ExpectedReason) { $command += " expected-reason=$ExpectedReason observed-reason=$observedReason" }
    elseif ($observedReason -in @('AAP_ArtifactMissing', 'AAP_ArtifactChanged')) { $command += " observed-reason=$observedReason" }
    if ($relaxed) { $command += ' staging_check=relaxed' }
    $rec = [ordered]@{
        schema = 1; item = $Item; contract_revision = 'evidence-bundle@1'; head_sha = $HeadSha; action_shas = @()
        reference_image = $null; candidate_image = $null; inputs_manifest_sha256 = $manifestHash; fixture_id = $fixture
        os_version = ([Environment]::OSVersion.VersionString -replace '[^ -~]', '?')
        tool_versions = [ordered]@{ powershell = $PSVersionTable.PSVersion.ToString(); 'get-aap-artifact' = $script:ToolVersion }
        command = $command
        started_at = (Format-AapTime $p.started_at); ended_at = (Format-AapTime $p.ended_at); exit_status = $exit
        oracle = [ordered]@{ expected = $expected; observed = $observed }
        result = $result; artifacts = $artifacts; verifier = $Verifier
    }
    Write-AapJson $rec $OutPath
    return $OutPath
}

Export-ModuleMember -Function Test-AapEntry, Test-AapManifest, Read-AapManifest, Resolve-AapExpectedHash, Confirm-AapFile, Get-AapArtifact, Invoke-AapManifest, New-AapEvidenceRecord, Get-AapStagedPath, Get-AapStagingProblems, Assert-AapStagingRoot
