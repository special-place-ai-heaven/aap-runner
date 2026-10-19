# Generates artifacts.manifest.json from the reviewed P01 inputs (parity/baselines/*/inputs.md, zccache.md) and from
# the pinned upstream scripts they point at (runner-images at the profile build commits), read as text on 2026-10-19.
# Nothing here fetches anything. A tool-name list in a blocker is for people; the `scripts` arrays are what the
# tests check against the script tables of both inputs.md files, so a sourced script cannot be silently dropped.
# Usage: pwsh -File New-AapManifest.ps1 [-OutPath <file>]   (default: artifacts.manifest.json beside this script)
param([string]$OutPath = (Join-Path $PSScriptRoot 'artifacts.manifest.json'))
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$win = 'windows-2025-vs2026-x64'
$ubu = 'ubuntu-24.04-x64'
$winInputs = 'parity/baselines/windows-2025-vs2026-x64/inputs.md, "Version- or hash-pinned values"'
$ubuInputs = 'parity/baselines/ubuntu-24.04-x64/inputs.md, "Version- or hash-pinned values"'
$zccRef = 'parity/baselines/zccache.md, "Release assets"'
$ghHosts = @('release-assets.githubusercontent.com', 'objects.githubusercontent.com')
$zcc = 'https://github.com/zackees/zccache/releases/download/1.15.6/'
$sfBase = 'https://download.microsoft.com/download/b/8/a/b8a2fb98-0ec1-41e5-be98-9d8b5abf7856/'
$octet = @('application/octet-stream')

function Lic($class, $redist, $note) { [ordered]@{ class = $class; redistribution = $redist; note = $note } }
function Entry {
    param($Name, $Version, $Profiles, $File, $Url, $Redirect = @(), $Algo = 'sha256', $Source, $Value = $null, $UpEntry = $null, $UpKey = $null,
        $Size = $null, $Max, $Types, $License, $Timeout, $Ref, $Note = $null, $Scripts = @())
    $e = [ordered]@{
        name = $Name; version = $Version; profiles = @($Profiles); file_name = $File; urls = @($Url); redirect_hosts = @($Redirect)
        hash = [ordered]@{ algorithm = $Algo; source = $Source; value = $(if ($Value) { $Value.ToLowerInvariant() } else { $null }); upstream_entry = $UpEntry; upstream_key = $UpKey }
        size_bytes = $Size; size_max_bytes = $Max; content_types = @($Types); license = $License
        retry = [ordered]@{ max_attempts = 3; backoff_seconds = 5; timeout_seconds = $Timeout }
        scripts = @($Scripts); evidence_ref = $Ref
    }
    if ($Note) { $e['note'] = $Note }
    $e
}
function Blocker($id, $name, $profiles, $kind, $reason, $action, $scripts, $ref) {
    [ordered]@{ id = $id; name = $name; profiles = @($profiles); blocker_kind = $kind; reason = $reason; owner_action = $action; scripts = @($scripts); evidence_ref = $ref }
}

# ---- licences: read from the upstream sources named in each note, not assumed ----------------------------------
$zccLic = Lic 'open-source' 'restricted' 'AGPL-3.0-only per Cargo.toml, README and LICENSE at commit 15ec953. Copyleft: redistribution carries source-offer duties (AGPL section 13 covers network use). Decide compliance before shipping the binary in an image.'
$composeLic = Lic 'open-source' 'allowed' 'Apache License 2.0 (LICENSE of docker/compose at tag v2.40.3, read 2026-10-19). Keep the notice when redistributing.'

function Zcc($file, $profile, $sha, $size) {
    Entry -Name ('zccache-' + ($file -replace '^zccache-v1\.15\.6-', '' -replace '\.(tar\.gz|zip)$', '')) -Version '1.15.6' -Profiles @($profile) -File $file -Url ($zcc + $file) -Redirect $ghHosts `
        -Source 'upstream-file' -Value $sha -UpEntry 'zccache-sha256sums' -UpKey $file -Size $size -Max 104857600 -Types $octet -License $zccLic -Timeout 900 -Ref $zccRef `
        -Note 'Pinned value cross-checked against the SHA256SUMS entry of the same release; both must agree.'
}

$entries = @(
    (Entry -Name 'zccache-sha256sums' -Version '1.15.6' -Profiles @($win, $ubu) -File 'SHA256SUMS' -Url ($zcc + 'SHA256SUMS') -Redirect $ghHosts -Source 'literal' `
        -Value '6b5c2b96c99ab876814cedf3c6c1801d80dc2491fb823fcd8b58f3662c0231c3' -Size 1636 -Max 65536 -Types @('application/octet-stream', 'text/plain') -License $zccLic -Timeout 120 -Ref $zccRef `
        -Note 'Its first line hashes itself as the empty string; consumers skip that line. Transport integrity only, not a signature.')
    (Zcc 'zccache-v1.15.6-x86_64-unknown-linux-musl.tar.gz' $ubu '885a109c758808480ebda6b92ac0c55ae55ff2638f0ef850423bb185f28e59f7' 12389072)
    (Zcc 'zccache-v1.15.6-x86_64-unknown-linux-musl-debug.tar.gz' $ubu '6eccf0034b23df2fa9f6f523e43a5c2335847e6eb956de8b2e2a284651afaecd' 29806744)
    (Zcc 'zccache-v1.15.6-x86_64-pc-windows-msvc.zip' $win 'a9e2b079946d00757a56fea3dacd8a47f9cb4bcbfe8c427ffd719ced59fd949b' 10545387)
    (Zcc 'zccache-v1.15.6-x86_64-pc-windows-msvc-debug.zip' $win '619e41467ea832454c0a5fa8ab009497274279f8bbfe8ad4a39bc18784901ceb' 34900341)

    (Entry -Name 'android-commandlinetools-win' -Version '13114758' -Profiles @($win) -File 'commandlinetools-win-13114758_latest.zip' -Url 'https://dl.google.com/android/repository/commandlinetools-win-13114758_latest.zip' `
        -Source 'literal' -Value '98B565CB657B012DAE6794CEFC0F66AE1EFB4690C699B78A614B4A6A3505B003' -Max 268435456 -Types @('application/zip') `
        -License (Lic 'proprietary-eula' 'unknown' 'Android SDK terms; the terms were not read or recorded. The scripts also write the SDK licence acceptances, which the operator inherits.') -Timeout 1800 -Ref $winInputs `
        -Note 'The file name contains "latest" but the version is the build number 13114758 and the hash pins the content.' -Scripts @('Install-AndroidSDK.ps1'))
    (Entry -Name 'mysql-vcredist-x64' -Version 'h20e2645b7cd5' -Profiles @($win) -File 'vcredist_x64.exe' -Url 'https://download.microsoft.com/download/0/5/6/056dcda9-d667-4e27-8001-8a0c6971d6b1/vcredist_x64.exe' `
        -Source 'literal' -Value '20E2645B7CD5873B1FA3462B99A665AC8D6E14AAE83DED9D875FEA35FFDD7D7E' -Max 33554432 -Types $octet `
        -License (Lic 'vendor-redistributable' 'unknown' 'Microsoft Visual C++ redistributable; the Microsoft terms were not read or recorded. Record them before shipping inside an image.') -Timeout 300 -Ref $winInputs `
        -Note 'Helper for the MySQL CLI install; the literal SHA-256 is committed upstream in Install-MysqlCli.ps1. Upstream records no version, so the version label is the first 12 hex digits of the hash behind an h; the hash is the identity.' -Scripts @('Install-MysqlCli.ps1'))
    (Entry -Name 'docker-ce-install-helper' -Version '8ea2a92d8dfa7815abcf5cc44a756a0ac3d0f513' -Profiles @($win) -File 'install-docker-ce.ps1' `
        -Url 'https://raw.githubusercontent.com/microsoft/Windows-Containers/8ea2a92d8dfa7815abcf5cc44a756a0ac3d0f513/helpful_tools/Install-DockerCE/install-docker-ce.ps1' `
        -Source 'first-fetch' -Max 1048576 -Types @('text/plain') `
        -License (Lic 'open-source' 'allowed' 'MIT License, Copyright Microsoft Corporation (LICENSE of microsoft/Windows-Containers at the pinned commit 8ea2a92, read 2026-10-19). Keep the notice when redistributing.') -Timeout 120 -Ref $winInputs `
        -Note 'Pinned to a commit, no upstream hash. Download needs -RecordFirstFetch and is recorded unverified. Data only: never executed by this tooling.' -Scripts @('Install-Docker.ps1'))
    (Entry -Name 'docker-engine-windows-static' -Version '29.7.2' -Profiles @($win) -File 'docker-29.7.2.zip' -Url 'https://download.docker.com/win/static/stable/x86_64/docker-29.7.2.zip' `
        -Source 'first-fetch' -Max 134217728 -Types @('application/zip') `
        -License (Lic 'unknown' 'unknown' 'Static archive of Docker Engine and CLI binaries; the licences of the bundled components were not read.') -Timeout 600 -Ref $winInputs `
        -Note 'Version from the toolset (docker.components.docker). URL pattern docker-<version>.zip from Install-Docker.ps1 at aee0669; the server answered 200 application/zip on 2026-10-19. No upstream hash is published, so the download needs -RecordFirstFetch.' -Scripts @('Install-Docker.ps1'))
    (Entry -Name 'docker-compose-windows-sha256' -Version '2.40.3' -Profiles @($win) -File 'docker-compose-windows-x86_64.exe.sha256' `
        -Url 'https://github.com/docker/compose/releases/download/v2.40.3/docker-compose-windows-x86_64.exe.sha256' -Redirect $ghHosts -Source 'literal' `
        -Value '1be534e9e4ec6afee06babcfbd154cd4f1ce89f8c1c846f2b8036ee4c2af14fe' -Size 100 -Max 4096 -Types @('application/octet-stream', 'text/plain') -License $composeLic -Timeout 120 -Ref $winInputs `
        -Note 'Release checksum file of the same release; transport integrity only.' -Scripts @('Install-DockerCompose.ps1'))
    (Entry -Name 'docker-compose-windows' -Version '2.40.3' -Profiles @($win) -File 'docker-compose-windows-x86_64.exe' `
        -Url 'https://github.com/docker/compose/releases/download/v2.40.3/docker-compose-windows-x86_64.exe' -Redirect $ghHosts -Source 'upstream-file' `
        -Value '4c864dd7f879dd40366e087e68a8a02cbcf018be0128867b13369898e67e1532' -UpEntry 'docker-compose-windows-sha256' -UpKey 'docker-compose-windows-x86_64.exe' -Max 134217728 -Types $octet -License $composeLic -Timeout 900 -Ref $winInputs `
        -Note 'Version from the toolset (docker.components.compose). URL from Install-DockerCompose.ps1 at aee0669. Pinned value cross-checked against the release checksum file.' -Scripts @('Install-DockerCompose.ps1'))
    (Entry -Name 'servicefabric-runtime' -Version '11.7.157.1' -Profiles @($win) -File 'MicrosoftServiceFabric.11.7.157.1.exe' -Url ($sfBase + 'MicrosoftServiceFabric.11.7.157.1.exe') `
        -Source 'literal' -Value 'BBD4531D80ED5FA8D2704C9267F701684FC58306987184BE9CAF35153F358C7B' -Max 268435456 -Types $octet `
        -License (Lic 'proprietary-eula' 'unknown' 'Microsoft installer run with /accepteula by Install-ServiceFabricSDK.ps1; the terms were not read or recorded.') -Timeout 1800 -Ref $winInputs `
        -Note 'Hash from the toolset (serviceFabric.runtime.checksum); URL built by Install-ServiceFabricSDK.ps1 at aee0669. The server answered 200 on 2026-10-19.' -Scripts @('Install-ServiceFabricSDK.ps1'))
    (Entry -Name 'servicefabric-sdk' -Version '8.7.157' -Profiles @($win) -File 'MicrosoftServiceFabricSDK.8.7.157.msi' -Url ($sfBase + 'MicrosoftServiceFabricSDK.8.7.157.msi') `
        -Source 'literal' -Value '32ECB92CA3C9369A0BEA688737F9714E93EC1F8022D1708ABF5084E5B1F9EFBA' -Max 134217728 -Types $octet `
        -License (Lic 'proprietary-eula' 'unknown' 'Microsoft installer from the same Service Fabric download; the terms were not read or recorded.') -Timeout 900 -Ref $winInputs `
        -Note 'Hash from the toolset (serviceFabric.sdk.checksum); URL built by Install-ServiceFabricSDK.ps1 at aee0669. The server answered 200 on 2026-10-19.' -Scripts @('Install-ServiceFabricSDK.ps1'))
    (Entry -Name 'cobertura' -Version '2.1.1' -Profiles @($win) -File 'cobertura-2.1.1-bin.zip' -Url 'https://repo1.maven.org/maven2/net/sourceforge/cobertura/cobertura/2.1.1/cobertura-2.1.1-bin.zip' `
        -Source 'literal' -Value '79479DDE416B082F38ECD1F2F7C6DEBD4D0C2249AF80FD046D1CE05D628F2EC6' -Size 4387295 -Max 16777216 -Types @('application/zip') `
        -License (Lic 'open-source' 'restricted' 'GNU GPL v2: LICENSE.txt inside cobertura-2.1.1-bin.zip, read from the archive without extracting it (the Maven POM has no license element). Copyleft.') -Timeout 300 -Ref $winInputs `
        -Note 'Literal SHA-256 committed in Install-JavaTools.ps1 at aee0669. The downloaded file was hashed on 2026-10-19 and matches.' -Scripts @('Install-JavaTools.ps1'))
    (Entry -Name 'pester' -Version '5.9.0' -Profiles @($win, $ubu) -File 'pester.5.9.0.nupkg' -Url 'https://www.powershellgallery.com/api/v2/package/Pester/5.9.0' -Redirect @('cdn.powershellgallery.com') -Algo 'sha512' `
        -Source 'literal' -Value '0c87dde08b6fb1ee75f070b34bf76822ced9676220b4041e2abdb2dcc49c7b30de479aea2c1a105110a843f5cd7014f18aa14dc13d882dd2391a0dac23709d91' -Size 327975 -Max 4194304 -Types @('binary/octet-stream', 'application/octet-stream') `
        -License (Lic 'open-source' 'allowed' 'Apache-2.0 per the LicenseUrl in the PowerShell Gallery feed metadata, read 2026-10-19. Keep the notice when redistributing.') -Timeout 300 `
        -Ref 'parity/baselines/windows-2025-vs2026-x64/inputs.md and ubuntu-24.04-x64/inputs.md, "PowerShell modules with exact version"' `
        -Note 'Hash is the PackageHash (SHA-512, base64 decoded) from the PowerShell Gallery feed entry for Pester 5.9.0, read 2026-10-19; the downloaded nupkg was hashed and matches. Transport integrity only.' -Scripts @('Install-PowerShellModules.ps1'))

    (Entry -Name 'libicu70' -Version '70.1-2' -Profiles @($ubu) -File 'libicu70_70.1-2_amd64.deb' -Url 'https://archive.ubuntu.com/ubuntu/pool/main/i/icu/libicu70_70.1-2_amd64.deb' -Algo 'sha512' `
        -Source 'literal' -Value 'a6315482d93606e375c272718d2458870b95e4ed4b672ea8640cf7bc2d2c2f41aea13b798b1e417e1ffc472a90c6aad150d3d293aa9bddec48e39106e4042807' -Max 33554432 -Types @('application/vnd.debian.binary-package') `
        -License (Lic 'open-source' 'allowed' 'Upstream ICU files are under an MIT-style licence (Unicode, Inc.); the Debian packaging files are GPL-3 (Ubuntu copyright file of icu 70.1-2, read 2026-10-19).') -Timeout 300 -Ref $ubuInputs `
        -Note 'SHA-512 as committed in configure-dpkg.sh upstream.' -Scripts @('configure-dpkg.sh'))
    (Entry -Name 'containernetworking-plugins' -Version '1.1.1+ds1-3build1' -Profiles @($ubu) -File 'containernetworking-plugins_1.1.1+ds1-3build1_amd64.deb' `
        -Url 'https://archive.ubuntu.com/ubuntu/pool/universe/g/golang-github-containernetworking-plugins/containernetworking-plugins_1.1.1+ds1-3build1_amd64.deb' `
        -Source 'first-fetch' -Max 33554432 -Types @('application/vnd.debian.binary-package') `
        -License (Lic 'open-source' 'allowed' 'Apache-2.0 (Debian copyright file of golang-github-containernetworking-plugins 1.1.1+ds1-3, read 2026-10-19).') -Timeout 300 -Ref $ubuInputs `
        -Note 'No upstream hash seen. Needs -RecordFirstFetch; recorded unverified.' -Scripts @('install-container-tools.sh'))
    (Entry -Name 'android-commandlinetools-linux' -Version '11076708' -Profiles @($ubu) -File 'commandlinetools-linux-11076708_latest.zip' -Url 'https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip' `
        -Source 'first-fetch' -Max 268435456 -Types @('application/zip') `
        -License (Lic 'proprietary-eula' 'unknown' 'Android SDK terms; the terms were not read or recorded.') -Timeout 1800 -Ref $ubuInputs `
        -Note 'Toolset gives the file name without a hash. URL derived from the Windows pin path on the same host and answered with HTTP 200 on 2026-10-19 (headers only). Needs -RecordFirstFetch.' -Scripts @('install-android-sdk.sh'))
)

$bothTools = 'parity/baselines/*/inputs.md, "Tool cache manifests" and "Drift since the pin"'
$winNeed = 'parity/baselines/windows-2025-vs2026-x64/inputs.md, NEEDS EXTERNAL AUTHORIZATION'
$ubuNeed = 'parity/baselines/ubuntu-24.04-x64/inputs.md, NEEDS EXTERNAL AUTHORIZATION'
$winTable = 'parity/baselines/windows-2025-vs2026-x64/inputs.md, "All provisioning scripts in template order"'
$ubuTable = 'parity/baselines/ubuntu-24.04-x64/inputs.md, "All provisioning scripts in template order"'

$blockers = @(
    (Blocker 'tool-cache-manifests' 'Tool cache version manifests (Python, PyPy, Node.js, Go, Ruby, CodeQL)' @($win, $ubu) 'moving-layout' `
        'Versions come from the main-branch manifests of actions/python-versions, node-versions, go-versions and ruby-builder, from the PyPy versions.json and from CodeQL bundle releases, all of which move. Windows sets: Ruby 3.2 to 4.0, Python 3.11 to 3.15 (pin) or 3.10 to 3.14 (build commit), PyPy 3.9 and 3.10, Node.js 22 and 24, Go 1.24 to 1.26. Ubuntu adds PyPy up to 3.11 and CodeQL. Newer versions already exist upstream.' `
        'Snapshot each manifest at a recorded commit, then pin the tool archives it lists by hash.' `
        @('Install-PyPy.ps1', 'Install-Ruby.ps1', 'Install-NodeJS.ps1', 'Install-Toolset.ps1', 'Configure-Toolset.ps1', 'install-pypy.sh', 'install-python.sh', 'install-ruby.sh', 'install-codeql-bundle.sh') $bothTools)
    (Blocker 'powershell-gallery-modules' 'PowerShell Gallery modules other than Pester 5.9.0 (Az 15.6.1, Microsoft.Graph, PSScriptAnalyzer, unpinned modules)' @($win, $ubu) 'resolve-before-use' `
        'The toolset pins Az 15.6.1 exactly. Its nupkg is a meta-module (39570 bytes, SHA-512 in the PowerShell Gallery feed, read 2026-10-19) that depends on separate Az.* modules whose exact versions are not resolved here, so Az cannot yet be installed from retained files. Every other module is unpinned and installs the latest at build (Microsoft.Graph and PSScriptAnalyzer on Ubuntu). Pester 5.9.0 is an entry.' `
        'Resolve the Az 15.6.1 dependency closure from the nuspec, retain every nupkg with its feed hash, and pin or drop the unpinned modules.' `
        @('Configure-PowerShell.ps1', 'Install-PowerShellModules.ps1', 'Install-PowershellAzModules.ps1', 'Install-PowerShellAzModules.ps1') 'parity/baselines/*/inputs.md, "PowerShell modules with exact version"')

    (Blocker 'azure-base-image-windows-server-2025' 'Azure Marketplace image MicrosoftWindowsServer:WindowsServer:2025-Datacenter-g2' @($win) 'cloud-base-image' `
        'Exists only in Azure with the Azure agent and drivers. A local Hyper-V guest built from other media is a different base.' `
        'Decide the accepted deviation for the local base; the reference image stays the hosted runner.' @() "$winNeed 1")
    (Blocker 'windows-server-2025-media' 'Windows Server 2025 installation media and activation' @($win) 'licensed-media' `
        'Lawful media, edition, key or volume activation and the lab licence are owner decisions. The tooling never downloads, stores or redistributes it.' `
        'Owner supplies the Windows Server 2025 Evaluation ISO manually, records its SHA-256, edition and the evaluation licence terms, and places it outside the staging tree.' @() "$winNeed 2")
    (Blocker 'windows-updates-level' 'Windows Updates level of image build 10.0.26100.33438' @($win) 'moving-layout' `
        'Microsoft supersedes updates; the KB list is not recorded upstream.' `
        'Record the catalog state at the first lawful fetch or accept a documented update-level deviation.' @('Install-WindowsUpdates.ps1', 'Install-WindowsUpdatesAfterReboot.ps1') "$winNeed 3")
    (Blocker 'visual-studio-2026-bootstrapper' 'Visual Studio 2026 Enterprise bootstrapper and stable channel (aka.ms/vs/postGRO-stable/vs_Enterprise.exe)' @($win) 'moving-layout' `
        'Channel stable has no pinned layout and serves the current build, not 18.10.12224.181. Entitlement for a non-GitHub host is not established.' `
        'Owner decides the entitlement, then a layout is created once and retained with a recorded hash; a layout creation is a separate approved step.' @('Install-VisualStudio.ps1') "$winNeed 4")
    (Blocker 'visual-studio-marketplace-extensions' 'Visual Studio Marketplace extensions (SSIS, Analysis Services, Reports, Installer Projects, Service Fabric, WiX)' @($win) 'proprietary-license' `
        'Downloaded by marketplace item name with no hash and their own terms.' `
        'Record licence terms and retain the VSIX files with hashes at the first lawful fetch.' @('Install-VSExtensions.ps1') "$winNeed 4")
    (Blocker 'windows-sdk-and-wdk' 'Windows 11 SDK 10.0.26100 (go.microsoft.com/fwlink linkid 2349110) and Windows Driver Kit' @($win) 'vendor-latest-no-hash' `
        'Fetched through a vendor redirect with an Authenticode check only, no hash; Microsoft-licensed. The other link in the script (LinkID 2033908, Windows 10 SDK 10.0.17763) is used only on Windows Server 2022 and does not apply to this profile.' `
        'Resolve the redirect once, retain the installer and record hash and licence.' @('Install-VisualStudio.ps1') "$winNeed 5")
    (Blocker 'windows-github-release-feeds' 'GitHub releases resolved as latest or by toolset rule at build time (Windows)' @($win) 'vendor-latest-no-hash' `
        'These scripts query GitHub releases for the latest or rule-matched version and verify at most against a hash fetched from the same release. Nothing archives the versions installed on 2026-10-07. The tools are WSL, docker-credential-helpers, PowerShell 7.6, kind, Kotlin, actions/action-versions, RubyInstaller2, Git for Windows, GitHub CLI, geckodriver, Selenium and the IE driver, MSYS2, WinAppDriver, AWS SAM CLI, mingw-builds, Stack, zstd, mongosh, the CodeQL bundle and Node.js.' `
        'Retain the exact release files at the first lawful fetch with hash, URL chain and licence, or accept a documented drift.' `
        @('Install-WSL2.ps1', 'Install-DockerWinCred.ps1', 'Install-PowershellCore.ps1', 'Install-KubernetesTools.ps1', 'Install-Kotlin.ps1', 'Install-ActionsCache.ps1', 'Install-Ruby.ps1', 'Install-Git.ps1', 'Install-GitHub-CLI.ps1', 'Install-Firefox.ps1', 'Install-Selenium.ps1', 'Install-IEWebDriver.ps1', 'Install-Msys2.ps1', 'Install-WinAppDriver.ps1', 'Install-AWSTools.ps1', 'Install-Mingw64.ps1', 'Install-Stack.ps1', 'Install-Zstd.ps1', 'Install-MongoDB.ps1', 'Install-CodeQLBundle.ps1', 'Install-NodeJS.ps1') "$winNeed 6")
    (Blocker 'windows-vendor-installer-feeds' 'Vendor installers and feeds without a hash source (Windows)' @($win) 'vendor-latest-no-hash' `
        'Latest or redirect-based vendor downloads, checked at most by Authenticode subject or by a hash from the same vendor: Web Platform Installer, Azure CLI, Adoptium JDK, OpenSSL (slproweb), Node.js, rustup-init, Chrome, Edge driver, Firefox, AWS Session Manager plugin, DacFx, MySQL archives, SQL PowerShell tools, SQL OLE DB, the .NET SDK release feed, ghcup, Miniconda, Cosmos DB emulator, MongoDB, PostgreSQL (EnterpriseDB), PyPy and the Android SDK packages fetched by sdkmanager. The installed versions are recorded only in the upstream Readme.' `
        'Retain the exact installer files at the first lawful fetch with hash, URL chain and licence.' `
        @('Install-WebPlatformInstaller.ps1', 'Install-AzureCli.ps1', 'Install-JavaTools.ps1', 'Install-OpenSSL.ps1', 'Install-NodeJS.ps1', 'Install-PyPy.ps1', 'Install-Rust.ps1', 'Install-Chrome.ps1', 'Install-EdgeDriver.ps1', 'Install-Firefox.ps1', 'Install-AWSTools.ps1', 'Install-DACFx.ps1', 'Install-MysqlCli.ps1', 'Install-SQLPowerShellTools.ps1', 'Install-SQLOLEDBDriver.ps1', 'Install-DotnetSDK.ps1', 'Install-Haskell.ps1', 'Install-Miniconda.ps1', 'Install-AzureCosmosDbEmulator.ps1', 'Install-MongoDB.ps1', 'Install-PostgreSQL.ps1', 'Install-AndroidSDK.ps1') "$winNeed 6")
    (Blocker 'windows-remote-install-scripts' 'Remote install scripts and git clones that the upstream scripts run (Chocolatey install.ps1, dotnet-install.ps1, vcpkg)' @($win) 'remote-install-script' `
        'Upstream downloads and runs these. They move, carry no hash and are code. This tooling never fetches one into an execution path and never runs one.' `
        'Replace each with a retained, reviewed copy or with the package archive it installs; vcpkg needs a pinned commit.' @('Install-Chocolatey.ps1', 'Install-DotnetSDK.ps1', 'Install-Vcpkg.ps1') $winTable)
    (Blocker 'windows-chocolatey-community-feed' 'Chocolatey community feed packages (Windows)' @($win) 'package-manager-install' `
        'Package versions resolve at build time from a moving feed: Wix, Apache, Nginx, R, sbt, PHP 8.5, LLVM 20, Bazel, the kubernetes, Java and AWS tools, and the packages listed in the toolset. Nothing is archived.' `
        'Pin exact package versions and retain the nupkg files with hashes.' `
        @('Install-KubernetesTools.ps1', 'Install-Wix.ps1', 'Install-ChocolateyPackages.ps1', 'Install-JavaTools.ps1', 'Install-PHP.ps1', 'Install-Sbt.ps1', 'Install-Apache.ps1', 'Install-Nginx.ps1', 'Install-R.ps1', 'Install-AWSTools.ps1', 'Install-Bazel.ps1', 'Install-LLVM.ps1') $winTable)
    (Blocker 'windows-package-manager-installs' 'pip, pipx, npm and Azure CLI extension installs (Windows)' @($win) 'package-manager-install' `
        'Resolved from PyPI, the npm registry and the Azure CLI extension index at build time without lock files.' `
        'Record exact versions and retain the artifacts with hashes.' @('Install-AzureDevOpsCli.ps1', 'Install-Pipx.ps1', 'Install-Bazel.ps1', 'Install-NodeJS.ps1', 'Install-PyPy.ps1') $winTable)
    (Blocker 'windows-toolset-version-rules' 'Toolset version rules that name a range or major, not an exact version (Windows)' @($win) 'version-rule' `
        'Maven 3.9, MySQL 8.0, MongoDB 7.0, PHP 8.5, PostgreSQL 17, PowerShell 7.6, OpenSSL 3.*, Kotlin latest, mingw 15 ucrt, Perl 5.42.0.1 and LLVM 20 select whatever matches at build time.' `
        'Resolve each rule to an exact version and add an entry with a hash.' `
        @('Install-JavaTools.ps1', 'Install-MysqlCli.ps1', 'Install-MongoDB.ps1', 'Install-PHP.ps1', 'Install-PostgreSQL.ps1', 'Install-PowershellCore.ps1', 'Install-OpenSSL.ps1', 'Install-Kotlin.ps1', 'Install-Mingw64.ps1', 'Install-LLVM.ps1') 'parity/baselines/windows-2025-vs2026-x64/inputs.md, "Version- or hash-pinned values", other toolset version rules')

    (Blocker 'azure-base-image-ubuntu-24.04' 'Azure Marketplace image canonical:ubuntu-24_04-lts:server (version latest at build)' @($ubu) 'cloud-base-image' `
        'Moves with every build and carries an Azure kernel and the Azure Linux agent. The base build date is not recorded.' `
        'Decide the accepted deviation for the local base image.' @() "$ubuNeed 1")
    (Blocker 'ubuntu-superseded-apt-versions' 'Exact apt package versions listed in the upstream Readme' @($ubu) 'superseded-versions' `
        'The live archive keeps only current versions; availability of a snapshot service for these dates is not verified.' `
        'Retain the .deb files or an archive snapshot at the first lawful fetch.' `
        @('install-apt-vital.sh', 'install-apt-common.sh', 'install-powershell.sh', 'install-apache.sh', 'install-clang.sh', 'install-container-tools.sh', 'install-gcc-compilers.sh', 'install-firefox.sh', 'install-gfortran.sh', 'install-git.sh', 'install-git-lfs.sh', 'install-github-cli.sh', 'install-mysql.sh', 'install-nginx.sh', 'install-php.sh', 'install-postgresql.sh', 'install-ruby.sh', 'install-python.sh', 'install-zstd.sh', 'install-dotnetcore-sdk.sh', 'configure-dpkg.sh', 'install-docker.sh', 'configure-apt.sh') "$ubuNeed 2")
    (Blocker 'ubuntu-vendor-apt-repositories' 'Vendor package repositories added during the build (Microsoft, Docker, PostgreSQL, Google Cloud, Adoptium, Kubernetes, git-lfs)' @($ubu) 'vendor-repository' `
        'Configuration is removed after the build, versions are not archived and signing keys are fetched at build time.' `
        'Pin repository snapshots or retain packages with hashes and record the key fingerprints.' `
        @('install-ms-repos.sh', 'configure-apt-sources.sh', 'install-azure-cli.sh', 'install-microsoft-edge.sh', 'install-git-lfs.sh', 'install-google-cloud-cli.sh', 'install-java-tools.sh', 'install-kubernetes-tools.sh', 'install-postgresql.sh', 'install-docker.sh', 'install-powershell.sh') "$ubuNeed 3")
    (Blocker 'ubuntu-proprietary-components' 'Proprietary or separately licensed components (Google Chrome, Edge, Microsoft packages, Android SDK, Docker Engine, MySQL)' @($ubu) 'proprietary-license' `
        'Licence terms and redistribution limits are not recorded; the scripts export ACCEPT_EULA globally.' `
        'Record licence terms and redistribution class per component before any acquisition.' `
        @('install-google-chrome.sh', 'install-microsoft-edge.sh', 'install-android-sdk.sh', 'install-docker.sh', 'install-mysql.sh', 'install-azure-cli.sh', 'install-powershell.sh', 'install-dotnetcore-sdk.sh', 'install-ms-repos.sh') "$ubuNeed 4")
    (Blocker 'ubuntu-github-release-feeds' 'GitHub releases resolved as latest or by toolset rule at build time (Ubuntu)' @($ubu) 'vendor-latest-no-hash' `
        'These scripts query GitHub releases for the latest or rule-matched version. The versions installed on 2026-10-12 are recorded only in the upstream Readme. The tools are PowerShell, actions/action-versions, Bicep, Swift, the CodeQL bundle, AWF, geckodriver, GitHub CLI, Kotlin, Copilot CLI, ruby-builder, Selenium, yq, zstd, ninja, the ECR credential helper and Kitware CMake.' `
        'Retain the exact release files at the first lawful fetch with hash, URL chain and licence.' `
        @('install-powershell.sh', 'install-actions-cache.sh', 'install-bicep.sh', 'install-swift.sh', 'install-codeql-bundle.sh', 'install-awf.sh', 'install-firefox.sh', 'install-github-cli.sh', 'install-kotlin.sh', 'install-copilot-cli.sh', 'install-ruby.sh', 'install-selenium.sh', 'install-yq.sh', 'install-zstd.sh', 'install-ninja.sh', 'install-docker.sh', 'install-cmake.sh') "$ubuNeed 5")
    (Blocker 'ubuntu-vendor-installer-feeds' 'Vendor latest feeds without a hash source (Ubuntu)' @($ubu) 'vendor-latest-no-hash' `
        'AWS CLI zip and Session Manager plugin, azcopy, kubectl stable.txt, minikube, Kustomize, Helm, Pulumi latest-version, Packer latest, Swift releases, Miniconda latest, Google Cloud CLI, Chrome and the Chromium snapshot, Edge driver, Julia versions.json, Gradle versions, Maven metadata, PHPUnit phar, the .NET release feed, PyPy and the Android SDK packages. The versions installed on 2026-10-12 are recorded only in the upstream Readme.' `
        'Retain the exact files at the first lawful fetch with hash, URL chain and licence.' `
        @('install-azcopy.sh', 'install-azure-cli.sh', 'install-aws-tools.sh', 'install-dotnetcore-sdk.sh', 'install-google-chrome.sh', 'install-google-cloud-cli.sh', 'install-java-tools.sh', 'install-kubernetes-tools.sh', 'install-miniconda.sh', 'install-php.sh', 'install-pulumi.sh', 'install-julia.sh', 'install-packer.sh', 'install-pypy.sh', 'install-android-sdk.sh', 'install-microsoft-edge.sh', 'install-swift.sh') "$ubuNeed 5")
    (Blocker 'ubuntu-remote-install-scripts' 'Remote install scripts that the upstream scripts run (nvm, n, Homebrew, rustup, ghcup, Stack, Composer, apt-fast, packagecloud, Azure CLI, dotnet-install)' @($ubu) 'remote-install-script' `
        'Upstream downloads and runs these. They move, carry no hash and are code. This tooling never fetches one into an execution path and never runs one.' `
        'Replace each with a retained, reviewed copy or with the package archive it installs.' `
        @('configure-apt.sh', 'install-azure-cli.sh', 'install-dotnetcore-sdk.sh', 'install-git-lfs.sh', 'install-haskell.sh', 'install-nvm.sh', 'install-nodejs.sh', 'install-php.sh', 'install-rust.sh', 'install-homebrew.sh') $ubuTable)
    (Blocker 'ubuntu-package-manager-installs' 'pip, pipx, npm, gem and Azure CLI extension installs (Ubuntu)' @($ubu) 'package-manager-install' `
        'Resolved from PyPI, the npm registry, RubyGems and the Azure CLI extension index at build time without lock files.' `
        'Record exact versions and retain the artifacts with hashes.' @('install-azure-devops-cli.sh', 'install-bazel.sh', 'install-nodejs.sh', 'install-ruby.sh', 'install-python.sh', 'install-pipx-packages.sh') $ubuTable)
    (Blocker 'ubuntu-floating-container-images' 'Six ghcr.io images pulled as :latest' @($ubu) 'floating-container' `
        'No digests were recorded upstream and the tags move.' `
        'Resolve each tag to a digest once and pin the digest.' @('install-docker.sh') "$ubuNeed 6")
    (Blocker 'ubuntu-docker-cmake-toolset-pins' 'Docker 28.0.4, containerd.io, Docker Compose 2.38.2, Buildx and CMake 3.31.6 (Ubuntu)' @($ubu) 'resolve-before-use' `
        'Exact versions are pinned in the toolset for docker-ce-cli, docker-ce (28.0.4), Compose (2.38.2) and CMake (3.31.6, review date 2026-12-01); containerd.io and Buildx are latest. File URLs and hashes are not stored by P01.' `
        'Resolve the exact release files at the pinned build commit and add entries with a recorded hash.' @('install-docker.sh', 'install-cmake.sh') $ubuInputs)
    (Blocker 'ubuntu-android-sdk-packages' 'Android SDK packages fetched by sdkmanager (platform 34, build-tools 34.0.0, NDK 27 29 30, CMake 3.31.5 and 4.1.2)' @($ubu) 'resolve-before-use' `
        'The toolset gives minimum versions and NDK majors, not exact package revisions; the packages come from the Google repository index (repository2-1.xml) at build time.' `
        'Resolve exact package revisions, retain the archives with hashes and record the Google licence terms.' @('install-android-sdk.sh') $ubuInputs)
    (Blocker 'ubuntu-toolset-version-rules' 'Toolset version rules that name a range or major, not an exact version (Ubuntu)' @($ubu) 'version-rule' `
        'Clang 16, 17 and 18, g++ and gfortran 12, 13 and 14, PHP 8.3, PostgreSQL 16, PowerShell 7.6, Node.js 22, Java 8, 11, 17, 21 and 25 (17 default), Maven 3 and .NET 8.0, 9.0 and 10.0 select whatever matches at build time.' `
        'Resolve each rule to an exact version and add an entry with a hash or an archived package.' `
        @('install-clang.sh', 'install-gcc-compilers.sh', 'install-gfortran.sh', 'install-php.sh', 'install-postgresql.sh', 'install-powershell.sh', 'install-nodejs.sh', 'install-java-tools.sh', 'install-dotnetcore-sdk.sh', 'Install-Toolset.ps1') $ubuInputs)
)

$manifest = [ordered]@{
    schema = 1
    generated_from = 'parity/baselines/windows-2025-vs2026-x64/inputs.md, parity/baselines/ubuntu-24.04-x64/inputs.md, parity/baselines/zccache.md (P01, checked 2026-10-19) and the pinned runner-images scripts they name'
    entries = $entries
    not_reproducible = $blockers
}
$text = (ConvertTo-Json -InputObject $manifest -Depth 8) -replace "`r`n", "`n"
[IO.File]::WriteAllText($OutPath, $text + "`n", (New-Object System.Text.UTF8Encoding($false)))
