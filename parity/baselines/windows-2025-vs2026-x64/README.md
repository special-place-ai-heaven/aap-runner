# Windows Server 2025 with Visual Studio 2026, x64

Frozen hosted baseline for profile `windows-2025-vs2026-x64`. Facts were fetched on 2026-10-19.
Every fact cites a source ID from the legend at the end. Source IDs B1 to B3 point at the baseline build commit
`aee0669dd04510a11756664eb77f5630debabed3` (Readme, template, toolset). All other IDs point at the candidate commit
`ee1ff4569e381a9649b400338bdc8ceb7e18a80e` unless the legend says otherwise.
**Baseline commit (coordinator decision, 2026-10-19).** The baseline for this profile is `aee0669dd04510a11756664eb77f5630debabed3`, the commit that built the
observed image `win25-vs2026/20261007.264`. `ee1ff4569e381a9649b400338bdc8ceb7e18a80e` stays recorded as the planning candidate only.
The inventory, template and toolset under `sources/build-commit-aee0669/` are the baseline. `scripts/build` and `scripts/helpers` did not change between
the two commits (the compare lists no file there; only `scripts/docs-gen`, the report generator, changed), so script links at the candidate commit also describe the baseline.
Where this file says "the pin", it means the candidate `ee1ff45`.

Files in this directory: `inventory.json` (machine readable, every Readme entry), `inputs.md`
(installer inputs, blockers, drift), `sources/` (byte-exact upstream template and toolset copies with `SHA256SUMS`; the Readme is hashed but not stored).

## Image identity

| Item | Value | Source |
|---|---|---|
| Image label written by the image | `windows-2025-vs2026` | S6 |
| Workflow label to use | `windows-2025-vs2026` only. See `../hosted-reference.md` for why `windows-latest` and `windows-2025` are not usable. | H1 |
| Image version string | `20261007.264.1` | B1 line 8 |
| OS version | `10.0.26100 Build 33438` (Windows Server 2025) | B1 line 7 |
| runner-images pin | `ee1ff4569e381a9649b400338bdc8ceb7e18a80e` (2026-10-16, "Updating readme file for ubuntu22 version 20261012.322.1 (#14917)") | G1 |
| Image release | tag `win25-vs2026/20261007.264`, published 2026-10-14T10:41:28Z, targets commit `aee0669dd04510a11756664eb77f5630debabed3` | G2 |
| Newest release on 2026-10-19 | `win25-vs2026/20261018.275`, published 2026-10-19T16:55Z. The pin is already one release behind the fleet. | G2 |
| Azure source image (build input) | `MicrosoftWindowsServer:WindowsServer:2025-Datacenter-g2`, OS disk 150 GB, selected by the key `win25-vs2026`. The pipeline value for the key is not in the repository. | B2, S7 |
| Build VM size (build time, not hosted runtime) | `Standard_F8s_v2` | S7 |
| Runner application version | `2.337.0` (observed 2026-10-19) | R1 |
| Hosted capture of the "Set up job" lines | Captured. Image and version equal the frozen values. See "Observed on the hosted reference". | R1 |

### Pin drift, resolved by pinning to the build commit

The Readme at the pin is byte-identical to the Readme at the release commit `aee0669` (SHA-256
`1be74251a3224d797dd351ce4509c3576a5ad417bed3c923d05a39a5f770bad6`). The inventory is therefore a
true record of the 20261007.264.1 image. The **build definition at the pin is not the one that built it.**
The pin is 15 commits ahead of the merge base with the release commit (G3). Differences that affect a rebuild:

| File | At the release commit `aee0669` (built the Readme image) | At the pin `ee1ff45` |
|---|---|---|
| `toolsets/toolset-2025-vs2026.json`, Python cached versions | `3.10.*`, `3.11.*`, `3.12.*`, `3.13.*`, `3.14.*` (matches Readme: 3.10.11 to 3.14.8) | `3.11.*` to `3.15.*` (drops 3.10, adds 3.15) |
| `templates/build.windows-2025-vs2026.pkr.hcl`, `Install-LLVM.ps1` | runs in the elevated block, directly before `Install-PostgreSQL.ps1` | runs first in the big non-elevated block, before `Install-ActionsCache.ps1` |
| `scripts/docs-gen/SoftwareReport.CachedTools.psm1` | version sort `[Version]` | sort tolerant of non-version folder names (report only) |

`scripts/build/*` and `scripts/helpers/*` are unchanged between the two (the compare lists no file there).
Both versions of the template and toolset are stored under `sources/` (`pin/` and `build-commit-aee0669/`).
**Resolved:** the baseline is the build commit `aee0669`. A rebuild from `sources/build-commit-aee0669/` reproduces the Readme's Python set.

## Hardware class of the hosted reference

| Repository visibility | vCPU | RAM | SSD (documented) | Source |
|---|---:|---:|---:|---|
| Public (standard Windows x64) | 4 | 16 GB | 14 GB | H2 |
| Private (standard Windows x64) | 2 | 8 GB | 14 GB | H2 |

The AAP consumer is private (see `../consumers.md`). The 14 GB figure is the documented value. Observed on the public-repo
runner (R1): 4 logical processors, 16 GiB RAM, `C:` 33.0 GB free of about 160 GB, `D:` 157.9 GB free. The build image OS disk is 150 GB (S7).

## Default user, privileges and lifecycle

- Windows hosted VMs run as administrators with UAC disabled (H2). The image build sets
  `ConsentPromptBehaviorAdmin` to 0 (S4, Configure-BaseImage.ps1).
- Every standard hosted runner is a new VM per job (H2).
- Build user `installer` (variable default) is created with administrator rights for provisioning and is
  deleted with its profile at the end of `Configure-User.ps1` on Windows Server 2025 (S7, S5).
- The runtime user is `runneradmin`, an administrator (observed, R1).
- The build script sets local execution policy `Unrestricted` (Configure-BaseImage.ps1) (S4). The hosted image reports `RemoteSigned` (R1). `$ErrorActionPreference="Stop"`
  is appended to the `AllUsersAllHosts` PowerShell profile (S4). Long paths are enabled (S4).
- Windows Defender real-time protection and related features are disabled, and Defender is set to
  passive mode when the policy key exists (Configure-WindowsDefender.ps1) (S8). The hosted `WinDefend` service is Running, Automatic (R1). Windows Update is disabled by policy
  (S4, S9).
- Telemetry and customer-experience policies are disabled by registry (Configure-System.ps1) (S9).
  `C:\Windows\Temp` is granted `Users:F` for MSI (S9). Dynamic port range is 49152, 16384 ports, for IPv4 and IPv6,
  TCP and UDP (Configure-DynamicPort.ps1). GDI process handle quota is 20000 (Configure-GDIProcessHandleQuota.ps1).
  Developer mode is enabled by `AllowDevelopmentWithoutDevLicense=1` (Configure-DeveloperMode.ps1).
- `bcdedit /set TESTSIGNING ON` runs in the build (template step 5) (B2). `hypervisorschedulertype` is set to
  `root` (Install-WindowsFeatures.ps1). Whether TESTSIGNING survives sysprep is not stated. Observe it.

## Shells and versions

| Shell | Target or version | Source |
|---|---|---|
| `gitbash.exe` | `C:\Program Files\Git\bin\bash.exe`, symlink in `C:\shells` | B1 Shells table, Configure-Shell.ps1 |
| `msys2bash.cmd` | `C:\msys64\usr\bin\bash.exe` via wrapper that sets `MSYS2_PATH_TYPE=strict`, `MSYSTEM=MINGW64`, `CHERE_INVOKING=1` and runs `bash -leo pipefail` | B1, Configure-Shell.ps1 |
| `wslbash.exe` | `C:\Windows\System32\bash.exe` | B1 |
| PowerShell (pwsh) | 7.6.6 | B1 |
| Bash (Language and Runtime) | 5.3.15(2)-release | B1 |
| Windows PowerShell 5.1 | built into Windows Server 2025, not listed in the Readme. Observe the version. | n/a |

## Environment variables and PATH facts

Values below are what the pinned scripts and Readme define. They are build-time facts, not a live capture.
Final ordering and values must be captured from the hosted job (`../hosted-reference.md`).

- **Image variables (machine scope):** `ImageVersion`, `ImageOS`, `AGENT_TOOLSDIRECTORY`, `RUNNER_TOOL_CACHE`
  (the last two equal `C:\hostedtoolcache\windows`) (S10, S7). `ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE` is
  `C:\actionarchivecache\` (Install-ActionsCache.ps1).
- **Tool cache layout:** `C:\hostedtoolcache\windows\<Tool>\<version>\<arch>` (Configure-Toolset.ps1).
  For each cached Go version it sets `GOROOT_<major>_<minor>_X64` (for example `GOROOT_1_24_X64`).
- **Toolset defaults on PATH:** Python `3.12.*` adds `<path>` and `<path>\Scripts`. Go `1.24.*` adds `<path>\bin`.
  Install-Ruby.ps1 adds the default Ruby (3.3) `bin` directory. The toolset default for Node is `22.*` and is installed system-wide (B3).
- **Variables from the Readme tables (B1):** `VCPKG_INSTALLATION_ROOT=C:\vcpkg`, `CONDA=C:\Miniconda`,
  `CHROMEWEBDRIVER`, `EDGEWEBDRIVER`, `GECKOWEBDRIVER`, `SELENIUM_JAR_PATH`, `JAVA_HOME_8_X64` to `JAVA_HOME_25_X64`,
  `ANDROID_HOME`, `ANDROID_SDK_ROOT`, `ANDROID_NDK`, `ANDROID_NDK_HOME`, `ANDROID_NDK_ROOT`
  (NDK 27.3.13750724) and `ANDROID_NDK_LATEST_HOME` (NDK 30.0.16248370). `JAVA_HOME` is set to the default
  Java (17) and Java's `bin` is moved to the front of PATH (Install-JavaTools.ps1).
- **Other machine variables the scripts set (names only):** `DOTNET_MULTILEVEL_LOOKUP=0`, `DOTNET_NOLOGO=1`,
  `DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1`, `POWERSHELL_UPDATECHECK=Off`, `GCM_INTERACTIVE=Never`,
  `PIPX_BIN_DIR`, `PIPX_HOME`, `npm_config_prefix`, `M2`, `M2_REPO`, `MAVEN_OPTS`, `AZURE_CONFIG_DIR`,
  `AZURE_EXTENSION_DIR`, `AZ_DEVOPS_GLOBAL_CONFIG_DIR`, `AZURE_DEVOPS_CACHE_DIR`, `PSModulePath`,
  `PSModuleAnalysisCachePath`, `PHPROOT`, `GHCUP_INSTALL_BASE_PREFIX`, `GHCUP_MSYS2`, `CABAL_DIR`,
  `IEWebDriver`, `PGBIN`, `PGROOT`, `PGDATA`.
- **Credential-bearing variables:** `PGUSER` and `PGPASSWORD` are set machine-wide by Install-PostgreSQL.ps1 (S11).
  Values are not recorded here. The reference workflow reports `PGPASSWORD` as present or absent only. The
  Readme also documents a default PostgreSQL password; it is masked in `inventory.json`.
- **Visual Studio developer environment is not applied globally.** No provisioning script sets
  `VCINSTALLDIR` or `VSINSTALLDIR` or runs `vcvars*` or `VsDevCmd` (searched `windows/scripts` and
  `windows/assets` at the pin: no match). Visual Studio 2026 Enterprise 18.10.12224.181 is at
  `C:\Program Files\Microsoft Visual Studio\18\Enterprise` (B1). `VSWhere 3.1.7` is installed from Chocolatey
  (toolset `choco.common_packages`, B3). MSVC jobs must find the toolchain with `vswhere` and enter the
  developer environment themselves. The reference workflow prints `VCINSTALLDIR`, `VSINSTALLDIR`, `VSCMD_VER`,
  `INCLUDE`, `LIB` to prove their absence or presence.
- **PATH order mechanism.** `Add-MachinePathItem` **prepends** (`$PathItem + ';' + $currentPath`)
  (PathHelpers.ps1, S12). A script that runs later therefore appears earlier on PATH. Exceptions: Install-Wix
  appends `%WIX%\bin`, and Install-JavaTools removes existing `java` entries and prepends the default Java. Scripts that change machine PATH, in provisioning order:
  Chocolatey, Kubernetes tools, Wix (appends `%WIX%\bin`), Java, Kotlin, OpenSSL, LLVM, Ruby, toolset defaults
  (Python, Python\Scripts, Go\bin), Node.js, pipx, Git (`C:\Program Files\Git\bin`), GitHub CLI, sbt, Chrome
  driver, Edge driver, Gecko driver, R, MySQL CLI, .NET (`C:\Program Files\dotnet`), MinGW64
  (`C:\mingw64\bin`), Haskell (ghcup, cabal), Stack, zstd, vcpkg, MongoDB. Per-user default-profile PATH
  entries: `%USERPROFILE%\.cargo\bin`, `%USERPROFILE%\.dotnet\tools`.
- **Not on PATH:** Miniconda (`C:\Miniconda`) and MSYS2 (`C:\msys64`) are installed but not added to PATH (B1).

## Tool cache versions (default marked)

Source for versions: B1 "Cached Tools". Source for defaults: B3 `toolcache[].default`. The Readme itself
does not mark defaults, so the marks below are derived by matching the toolset rule.

| Tool | Cached versions | Default | Rule (B3) |
|---|---|---|---|
| Go | 1.24.13, 1.25.14, 1.26.8 | **1.24.13** | `go` default `1.24.*` |
| Node.js | 22.23.3, 24.21.0 | none in the tool cache; system Node 22.23.3 | toolcache has no default; `node.default` `22.*` |
| Python | 3.10.11, 3.11.9, 3.12.10, 3.13.16, 3.14.8 | **3.12.10** | `Python` default `3.12.*` |
| PyPy | 3.9.19 [PyPy 7.3.16], 3.10.16 [PyPy 7.3.19] | none | no default in toolset (arch `x86`, platform `win64`) |
| Ruby | 3.2.11, 3.3.12, 3.4.11, 4.0.7 | **3.3.12** | `Ruby` default `3.3` |

Java (B1 table): 8.0.504+1, 11.0.32+101, **17.0.20+101 (default)**, 21.0.12+101.0, 25.0.4+101.0.
.NET SDKs: 8.0.131, 8.0.206, 8.0.319, 8.0.425, 9.0.121, 9.0.205, 9.0.318, 10.0.112, 10.0.204, 10.0.303, 10.0.401
(B1). `inventory.json` carries every entry with `default` flags.

## Services and system state by default

| Item | Default state | Source |
|---|---|---|
| PostgreSQL `postgresql-x64-17` 17.11 | Stopped, start type Disabled | B1, Install-PostgreSQL.ps1 |
| MongoDB 7.0.43.0 | Stopped, Disabled | B1 |
| Apache 2.4.55 | Stopped (port 80); script sets Disabled | B1, Install-Apache.ps1 |
| Nginx 1.31.6 | Stopped (port 80); script sets Disabled | B1, Install-Nginx.ps1 |
| Windows Update `wuauserv`, `DiagTrack`, `dmwappushservice`, `SysMain`, `gupdate`, `gupdatem` | Build script: Stopped, Disabled. `PcaSvc` and `StorSvc` are left alone on Windows Server 2025. Observed: `wuauserv` Running, Manual; `DiagTrack` and `SysMain` Stopped, Disabled. | S9, R1 |
| Windows Update Medic (`WaaSMedicSvc`) | Start type 4 (disabled) | S4 |
| `wlansvc` | Manual, stopped if running | B2 template step 7 |
| Windows Defender | Build script: real-time protection and many features disabled, passive mode when the policy key exists. Observed: `WinDefend` Running, Automatic; preference values not read. | S8, R1 |
| Scheduled tasks | Many Windows, Visual Studio and Azure tasks disabled (list in Configure-System.ps1) | S9 |
| WSL | WSL1 enabled; default WSL2 version `3.0.1.0` | B1 |
| Windows features enabled | Containers, WSL, VirtualMachinePlatform, `NET-Framework-45-Features` and `NET-Framework-Features` (all sub-features), Client-ProjFS, Hyper-V (all sub-features), HypervisorPlatform, Hyper-V-PowerShell, Wireless-Networking | B3 `windowsFeatures` |
| Docker engine | Moby 29.7.2 from the static Docker CE build plus a pinned Install-DockerCE script. Observed: service `docker` Running, Automatic; client and server 29.7.2. | B1, Install-Docker.ps1, R1 |
| Cached Docker images | None. Image pulls are skipped on Windows Server 2025 and the toolset list is empty. | Install-Docker.ps1, B3 |

## What is explicitly not present

- No Visual Studio 2022. The only installed Visual Studio is 2026 Enterprise. The VC++ 2022 redistributables
  are present (inventory, "Microsoft Visual C++").
- No Windows 10 SDK 10.0.17763. It installs only on Windows Server 2022. The only Windows SDK is 10.0.26100.0
  (Install-VisualStudio.ps1, B1).
- No TortoiseSVN on Windows Server 2025 (comment in Configure-User.ps1).
- No cached Docker images (above). No Visual Studio developer environment in the global environment (above).
- Miniconda and MSYS2 are not on PATH (B1).
- Windows Update installs are disabled by policy (service Running, Manual). Defender real-time scanning is disabled by the build script; the observed service runs and the preference was not read.
- Not part of this profile: Windows Server 2022, Windows Server 2025 with Visual Studio 2022, Windows 11 Arm64,
  Ubuntu 26.04 and other architectures. They need their own baseline (PLAN).

## Provisioned by the template but not listed in the Readme

Records of things a build-parity job can touch that the Readme sections do not list:

- Action archive cache `C:\actionarchivecache\` populated from the latest `actions/action-versions` release
  (Install-ActionsCache.ps1), exposed through `ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE`.
- Root certificate installation (Install-RootCA.ps1), Web Platform Installer (Install-WebPlatformInstaller.ps1),
  native image generation (Install-NativeImages.ps1), Windows Updates before and after reboot, final cleanup.
- Choco packages from the toolset: `7zip.install`, `aria2`, `azcopy10`, `Bicep`, `innosetup`, `jq`, `NuGet.CommandLine`,
  `packer`, `pulumi`, `swig`, `vswhere`, `julia` (to `C:\Julia`), `cmake.install` (CMake on the system PATH),
  `strawberryperl` 5.42.0.1, `imagemagick`, `ninja` (B3).
- npm global packages from the toolset: `yarn`, `newman`, `lerna`, `gulp-cli`, `grunt-cli` (B3).
  The Readme lists Yarn and Newman but not Lerna, gulp or grunt for this profile. Observe them live.
- pipx package: `yamllint` (B3).
- Windows SDK 10.0.26100 installed separately from the Visual Studio component, with
  `OptionId.WindowsDesktopDebuggers` added on Windows Server 2025 (Install-VisualStudio.ps1).

## Provisioning order

Generated from `sources/build-commit-aee0669/build.windows-2025-vs2026.pkr.hcl` (the baseline) by `../tools/provisioning_order.py`.
Reboot boundaries are shown as **REBOOT**. The step numbers count provisioner blocks that run scripts or
inline commands. The block that downloads the software report and the final sysprep step are included.
At the candidate commit `ee1ff45`, `Install-LLVM.ps1` moves to the first script of step 12 (pin drift, not part of the baseline).
The template variables use `C:\image` as the image folder, `D:\temp` as the temp directory and `installer` as the install user (S7).

- Step 1 (powershell inline): New-Item -Path ${var.image_folder} -ItemType Directory -Force | New-Item -Path ${var.temp_dir} -ItemType Directory -Force
- Step 2 (powershell inline): Move-Item '${var.image_folder}\\assets\\post-gen' 'C:\\post-generation' | Remove-Item -Recurse '${var.image_folder}\\assets' | Move-Item '${var.image_folder}\\scripts\\docs-gen' '${var.image_folder}\\SoftwareReport' | ...
- Step 3 (windows-shell inline): net user ${var.install_user} ${var.install_password} /add /passwordchg:no /passwordreq:yes | net localgroup Administrators ${var.install_user} /add | winrm set winrm/config/service/auth @{Basic=\"true\"} | ...
- Step 4 (powershell inline): if (-not ((net localgroup Administrators) -contains '${var.install_user}')) { exit 1 }
- Step 5 (powershell inline) [elevated as install user]: bcdedit.exe /set TESTSIGNING ON
- Step 6 (powershell) [execution_policy=unrestricted]
  - `Configure-WindowsDefender.ps1`
  - `Configure-PowerShell.ps1`
  - `Install-PowerShellModules.ps1`
  - `Install-WSL2.ps1`
  - `Install-WindowsFeatures.ps1`
  - `Install-Chocolatey.ps1`
  - `Configure-BaseImage.ps1`
  - `Configure-ImageDataFile.ps1`
  - `Configure-SystemEnvironment.ps1`
  - `Configure-DotnetSecureChannel.ps1`
- **REBOOT** (windows-restart, timeout 10m, registry check)
- Step 7 (powershell inline): Set-Service -Name wlansvc -StartupType Manual | if ($(Get-Service -Name wlansvc).Status -eq 'Running') { Stop-Service -Name wlansvc}
- Step 8 (powershell)
  - `Install-Docker.ps1`
  - `Install-DockerWinCred.ps1`
  - `Install-DockerCompose.ps1`
  - `Install-PowershellCore.ps1`
  - `Install-WebPlatformInstaller.ps1`
- **REBOOT** (windows-restart, timeout 30m)
- Step 9 (powershell) [elevated as install user; exit 3010 (reboot pending) accepted]
  - `Install-VisualStudio.ps1`
  - `Install-KubernetesTools.ps1`
- **REBOOT** (windows-restart, timeout 10m, registry check)
- Step 10 (powershell) [pause_before 2m0s]
  - `Install-Wix.ps1`
  - `Install-VSExtensions.ps1`
  - `Install-AzureCli.ps1`
  - `Install-AzureDevOpsCli.ps1`
  - `Install-ChocolateyPackages.ps1`
  - `Install-JavaTools.ps1`
  - `Install-Kotlin.ps1`
  - `Install-OpenSSL.ps1`
- Step 11 (powershell) [execution_policy=remotesigned]
  - `Install-ServiceFabricSDK.ps1`
- **REBOOT** (windows-restart, timeout 10m)
- Step 12 (powershell)
  - `Install-ActionsCache.ps1`
  - `Install-Ruby.ps1`
  - `Install-PyPy.ps1`
  - `Install-Toolset.ps1`
  - `Configure-Toolset.ps1`
  - `Install-NodeJS.ps1`
  - `Install-AndroidSDK.ps1`
  - `Install-PowershellAzModules.ps1`
  - `Install-Pipx.ps1`
  - `Install-Git.ps1`
  - `Install-GitHub-CLI.ps1`
  - `Install-PHP.ps1`
  - `Install-Rust.ps1`
  - `Install-Sbt.ps1`
  - `Install-Chrome.ps1`
  - `Install-EdgeDriver.ps1`
  - `Install-Firefox.ps1`
  - `Install-Selenium.ps1`
  - `Install-IEWebDriver.ps1`
  - `Install-Apache.ps1`
  - `Install-Nginx.ps1`
  - `Install-Msys2.ps1`
  - `Install-WinAppDriver.ps1`
  - `Install-R.ps1`
  - `Install-AWSTools.ps1`
  - `Install-DACFx.ps1`
  - `Install-MysqlCli.ps1`
  - `Install-SQLPowerShellTools.ps1`
  - `Install-SQLOLEDBDriver.ps1`
  - `Install-DotnetSDK.ps1`
  - `Install-Mingw64.ps1`
  - `Install-Haskell.ps1`
  - `Install-Stack.ps1`
  - `Install-Miniconda.ps1`
  - `Install-AzureCosmosDbEmulator.ps1`
  - `Install-Zstd.ps1`
  - `Install-Vcpkg.ps1`
  - `Install-Bazel.ps1`
  - `Install-RootCA.ps1`
  - `Install-MongoDB.ps1`
  - `Install-CodeQLBundle.ps1`
  - `Configure-Diagnostics.ps1`
- Step 13 (powershell) [elevated as install user]
  - `Install-LLVM.ps1`
  - `Install-PostgreSQL.ps1`
  - `Install-WindowsUpdates.ps1`
  - `Configure-DynamicPort.ps1`
  - `Configure-GDIProcessHandleQuota.ps1`
  - `Configure-Shell.ps1`
  - `Configure-DeveloperMode.ps1`
- **REBOOT** (windows-restart, timeout 30m, registry check)
- Step 14 (powershell) [pause_before 2m0s]
  - `Install-WindowsUpdatesAfterReboot.ps1`
  - `Invoke-Cleanup.ps1`
  - `RunAll-Tests.ps1`
- Step 15 (powershell inline): if (-not (Test-Path ${var.image_folder}\\tests\\testResults.xml)) { throw '${var.image_fol
- Step 16 (powershell inline): pwsh -File '${var.image_folder}\\SoftwareReport\\Generate-SoftwareReport.ps1'
- Step 17 (powershell inline): if (-not (Test-Path C:\\software-report.md)) { throw 'C:\\software-report.md not found' } | if (-not (Test-Path C:\\software-report.json)) { throw 'C:\\software-report.json not found
- Step 18 (powershell) [skip_clean]
  - `Install-NativeImages.ps1`
  - `Configure-System.ps1`
  - `Configure-User.ps1`
  - `Post-Build-Validation.ps1`
- **REBOOT** (windows-restart, timeout 10m)
- Step 19 (powershell inline): if( Test-Path $env:SystemRoot\\System32\\Sysprep\\unattend.xml ){ rm $env:SystemRoot\\Syst | & $env:SystemRoot\\System32\\Sysprep\\Sysprep.exe /oobe /generalize /mode:vm /quiet /quit | while($true) { $imageState = Get-ItemProperty HKLM:\\SOFTWARE\\Microsoft\\Windows\\Current

### Reboot boundaries

Six reboots, all via Packer `windows-restart`: after step 6 (base configuration, waits for the Containers
feature), after step 8 (Docker and PowerShell Core, up to 30 minutes), after step 9 (Visual Studio, accepts exit
code 3010), after step 11 (Service Fabric SDK), after step 13 (Windows updates, waits for `TiWorker`), and after
step 18 (native images and final configuration) before sysprep. Counted from the generated list above.

## Inventory counts (source versus recorded)

Generated by `../tools/verify_inventory.py` against the Readme fetched from the pinned commit (not stored, see `sources/NOT-STORED.md`). The
verifier counts bullets, table data rows and fenced blocks independently of the parser and also proves that
every content line of the Readme is covered by an entry (`src_line` in `inventory.json`).
"Versions recorded" counts individual version strings, so list lines such as `.NET Core SDK: a, b, c`
and `<br>` table cells count once per version.

| Category | Source rows | Recorded entries | Notes (fenced blocks) | Versions recorded |
|---|---:|---:|---:|---:|
| Windows features | 2 | 2 | 0 | 2 |
| Language and Runtime | 10 | 10 | 0 | 10 |
| Package Management | 11 | 11 | 0 | 11 |
| Package Management/Environment variables | 2 | 2 | 0 | 0 |
| Project Management | 4 | 4 | 0 | 4 |
| Tools | 38 | 38 | 0 | 38 |
| CLI Tools | 6 | 6 | 0 | 6 |
| Rust Tools | 4 | 4 | 0 | 4 |
| Rust Tools/Packages | 2 | 2 | 0 | 2 |
| Browsers and Drivers | 8 | 8 | 0 | 8 |
| Browsers and Drivers/Environment variables | 4 | 4 | 0 | 0 |
| Java | 5 | 5 | 0 | 5 |
| Shells | 3 | 3 | 0 | 0 |
| MSYS2 | 1 | 1 | 0 | 1 |
| MSYS2/Notes | 0 | 0 | 1 | 0 |
| Cached Tools | 0 | 0 | 0 | 0 |
| Cached Tools/Go | 3 | 3 | 0 | 3 |
| Cached Tools/Node.js | 2 | 2 | 0 | 2 |
| Cached Tools/Python | 5 | 5 | 0 | 5 |
| Cached Tools/PyPy | 2 | 2 | 0 | 2 |
| Cached Tools/Ruby | 4 | 4 | 0 | 4 |
| Databases | 0 | 0 | 0 | 0 |
| Databases/PostgreSQL | 8 | 8 | 0 | 0 |
| Databases/MongoDB | 1 | 1 | 0 | 1 |
| Database tools | 7 | 7 | 0 | 7 |
| Web Servers | 2 | 2 | 0 | 2 |
| Visual Studio Enterprise 2026 | 1 | 1 | 0 | 1 |
| Visual Studio Enterprise 2026/Workloads, components and extensions | 204 | 204 | 0 | 204 |
| Visual Studio Enterprise 2026/Microsoft Visual C++ | 8 | 8 | 0 | 8 |
| Visual Studio Enterprise 2026/Installed Windows SDKs | 1 | 1 | 0 | 1 |
| .NET Core Tools | 6 | 6 | 0 | 38 |
| PowerShell Tools | 1 | 1 | 0 | 1 |
| PowerShell Tools/Powershell Modules | 11 | 11 | 0 | 13 |
| Android | 10 | 10 | 0 | 36 |
| Android/Environment variables | 6 | 6 | 0 | 0 |
| **Total** | 382 | 382 | 1 | 419 |


content lines in Readme: 401, covered by entries: 401
Result: OK, all counts and line coverage match (exit code 0).

## Observed on the hosted reference (run 39303666617)

Source R1: [https://github.com/special-place-ai-heaven/aap-runner/actions/runs/39303666617](https://github.com/special-place-ai-heaven/aap-runner/actions/runs/39303666617), workflow `hosted-reference-windows-2025-vs2026`, label `windows-2025-vs2026`,
dispatched 2026-10-19T18:34:47Z from commit `f682e03a4386fd52010fb9640c41c50fad67de75`, repository public, conclusion
success. Raw log: `sources/hosted-capture-39303666617.log` (nothing scrubbed; the workflow printed only the presence of
`PGPASSWORD`). Everything in this section is observed, not derived.

| Item | Observed |
|---|---|
| Image (Runner Image group) | `Image: windows-2025-vs2026`, `Version: 20261007.264.1`, Included Software `.../blob/win25-vs2026/20261007.264/images/windows/Windows2025-VS2026-Readme.md`, Image Release `.../releases/tag/win25-vs2026%2F20261007.264`. **Equals the frozen identity.** |
| Operating System group | Microsoft Windows Server 2025, 10.0.26100, Datacenter. `ImageOS=win25-vs2026`, `ImageVersion=20261007.264.1`. |
| Runner application | `Current runner version: '2.337.0'` |
| Runner Image Provisioner group | Hosted Compute Agent version `20261002.596`, commit `c3d12f3313a95f25162a1503be624f3b0617f8c0`, build date 2026-10-02T22:28:27Z, region `westcentralus`, cloud Azure |
| Environment | `RUNNER_OS=Windows`, `RUNNER_ARCH=X64`, `RUNNER_ENVIRONMENT=github-hosted` |
| Hardware | 4 logical processors, 17174360064 bytes RAM (16 GiB). `C:` 127436206080 used and 33031553024 free bytes (about 160 GB total, 33 GB free). `D:` 3191169024 used and 157868003328 free bytes. The documented 14 GB figure does not describe the real volumes. |
| Windows PowerShell | 5.1.26100.33438. pwsh 7.6.6. Bash (Git) 5.3.15(2)-release (x86_64-pc-cygwin). |
| User and privileges | `runnervm0xl3a\runneradmin`, administrator, `ConsentPromptBehaviorAdmin=0`. |
| Execution policy | LocalMachine `RemoteSigned`; all other scopes Undefined. The build script set `Unrestricted`, so the shipped image differs from the build script. |
| Visual Studio | Enterprise 2026, `18.10.12224.181` (`VisualStudio/18.10.3+12224.181`), `C:\Program Files\Microsoft Visual Studio\18\Enterprise`, channel `VisualStudio.18.Release`, installed 2026-10-07T22:18:56Z, channel URI `https://aka.ms/vs/18/stable/channel`. |
| VS developer environment | `VCINSTALLDIR`, `VSINSTALLDIR`, `VSCMD_VER`, `INCLUDE`, `LIB`, `LIBPATH`, `Platform` are all unset. `cl.exe` and `msbuild.exe` are not on PATH. `clang-cl.exe` is `C:\Program Files\LLVM\bin\clang-cl.exe`. `cmake.exe` and `ninja.exe` resolve. **`link.exe` resolves to `C:\Program Files\Git\usr\bin\link.exe` (the GNU coreutils tool), not the MSVC linker.** |
| Services | `docker` Running, Automatic. `wuauserv` Running, **Manual**. `WinDefend` Running, Automatic. `WSLService` Running, Automatic. `DiagTrack`, `SysMain`, `postgresql-x64-17`, `MongoDB`, `Apache`, `nginx` Stopped, Disabled. `wlansvc` Stopped, Manual. |
| Docker | client 29.7.2, server 29.7.2. The workflow listed no images (no cached images). |
| PATH | Process PATH has 73 entries, machine PATH 69. Order is in the raw log. First machine entries: MongoDB, `C:\vcpkg`, zstd, stack, cabal, ghcup, `C:\mingw64\bin`, dotnet, MySQL, R, driver folders, sbt, GitHub CLI, Git `bin`, pipx, npm prefix, Go `bin`, Python `Scripts` then Python 3.12.10, Ruby 3.3.12, OpenSSL, kotlinc, Java 17, ImageMagick, Azure CLI, kind, Chocolatey, then `C:\Windows\system32`. The job process PATH adds `C:\Program Files\PowerShell\7` first and the `runneradmin` `.dotnet\tools` and `.cargo\bin` entries last. |
| Variables | `AGENT_TOOLSDIRECTORY` and `RUNNER_TOOL_CACHE` are `C:\hostedtoolcache\windows`. `JAVA_HOME` and `JAVA_HOME_17_X64` point into the tool cache (`Java_Temurin-Hotspot_jdk\17.0.20-101\x64`). `GOROOT_1_24_X64`, `ANDROID_NDK_HOME` (27.3.13750724), `PGUSER=postgres`, `PGBIN`, `PGROOT`, `PGDATA`, `PIPX_*`, `DOTNET_*`, `POWERSHELL_UPDATECHECK=Off`, `GCM_INTERACTIVE=Never` match the scripts. `PGPASSWORD` is present (value not printed). |
| Tool cache layout | `C:\hostedtoolcache\windows`: CodeQL/2.27.1, go 1.24.13 1.25.14 1.26.8, Java_Temurin-Hotspot_jdk 8.0.504-1 11.0.32-101 17.0.20-101 21.0.12-101.0 25.0.4-101.0, node 22.23.3 24.21.0, PyPy 3.9.19 3.10.16, Python 3.10.11 3.11.9 3.12.10 3.13.16 3.14.8, Ruby 3.2.11 3.3.12 3.4.11 4.0.7, stack 3.11.1. Matches the Readme. CodeQL and stack are cached entries the Readme lists only as tools. |
| Shells | `C:\shells`: `gitbash.exe`, `msys2bash.cmd` (the target column is empty because it is a wrapper file, not a link), `wslbash.exe`. |

Still NOT VERIFIED on this profile: TESTSIGNING after sysprep, Defender real-time preference values (only the service
state was read), the scheduled-task states, and the full registry settings from the build scripts. The hosted job
reported the pinned image `20261007.264.1` on 2026-10-19 even though a newer release was published that day, so the
rollout lags the release date. Do not rely on that staying true.

## Upstream image tests (part of the baseline)

The image build runs `scripts/tests/RunAll-Tests.ps1` (template step 14) and requires `testResults.xml` (step 15).
At the pin the folder `images/windows/scripts/tests/` holds 34 files: `ActionArchiveCache`, `Android`, `Apache`, `Browsers`,
`CLI.Tools`, `ChocoPackages`, `Databases`, `Docker`, `DotnetSDK`, `Git`, `Haskell`, `Java`, `LLVM`, `MSYS2`, `Miniconda`,
`Nginx`, `Node`, `PHP`, `PipxPackages`, `PowerShellAzModules`, `PowerShellModules`, `Rust`, `SSDTExtensions`, `Shell`,
`Tools`, `Toolset`, `VisualStudio`, `Vsix`, `WDK`, `WinAppDriver`, `WindowsFeatures` and `Wix` (each `*.Tests.ps1`), plus
`Helpers.psm1` and `RunAll-Tests.ps1`. They were **not downloaded** by P01. Fetch them from the pinned commit when
P06/P07 reconcile each test with a probe (S13).

## Open items for the coordinator

1. Pin drift is resolved by pinning to the build commit (above). Nothing open.
2. Hosted "Set up job" identity captured (R1). Re-capture before certification.
3. TESTSIGNING after sysprep and the Defender preference values remain NOT VERIFIED.
4. Licensed and unreproducible inputs are listed in `inputs.md` (Windows Server 2025 media and activation, the Visual
   Studio 2026 channel, Azure Marketplace image).

## Sources

- B1: [Windows2025-VS2026-Readme.md](https://github.com/actions/runner-images/blob/aee0669dd04510a11756664eb77f5630debabed3/images/windows/Windows2025-VS2026-Readme.md) at the build commit `aee0669`. Not stored (default credential). URL and SHA-256 `1be74251a3224d797dd351ce4509c3576a5ad417bed3c923d05a39a5f770bad6` in `sources/NOT-STORED.md`; the Readme is byte-identical at the candidate commit.
- B2: [build.windows-2025-vs2026.pkr.hcl](https://github.com/actions/runner-images/blob/aee0669dd04510a11756664eb77f5630debabed3/images/windows/templates/build.windows-2025-vs2026.pkr.hcl) at the build commit `aee0669`. Copy in `sources/build-commit-aee0669/`, SHA-256 `f1057bf63d180ff8392acb2bd0604523fa701a10397dcac5579de52009b35241`.
- B3: [toolset-2025-vs2026.json](https://github.com/actions/runner-images/blob/aee0669dd04510a11756664eb77f5630debabed3/images/windows/toolsets/toolset-2025-vs2026.json) at the build commit `aee0669`. Copy in `sources/build-commit-aee0669/`, SHA-256 `74afa20f0f390cd230f98900d034c1ad297a071820e5b45c55c5cd7abf2caa8f`.
- S1 (candidate `ee1ff45`, planning only): [Windows2025-VS2026-Readme.md](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/windows/Windows2025-VS2026-Readme.md).  Not stored (default credential), hash in `sources/NOT-STORED.md`.
- S2 (candidate `ee1ff45`, planning only): [build.windows-2025-vs2026.pkr.hcl](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/windows/templates/build.windows-2025-vs2026.pkr.hcl). Copy in `sources/pin/`.
- S3 (candidate `ee1ff45`, planning only): [toolset-2025-vs2026.json](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/windows/toolsets/toolset-2025-vs2026.json). Copy in `sources/pin/`.
- S4: [Configure-BaseImage.ps1](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/windows/scripts/build/Configure-BaseImage.ps1).
- S5: [Configure-User.ps1](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/windows/scripts/build/Configure-User.ps1).
- S6: [Configure-ImageDataFile.ps1](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/windows/scripts/build/Configure-ImageDataFile.ps1).
- S7: [locals.windows.pkr.hcl](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/windows/templates/locals.windows.pkr.hcl) (copy in `sources/pin/`) and [variable.windows.pkr.hcl](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/windows/templates/variable.windows.pkr.hcl).
- S8: [Configure-WindowsDefender.ps1](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/windows/scripts/build/Configure-WindowsDefender.ps1).
- S9: [Configure-System.ps1](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/windows/scripts/build/Configure-System.ps1).
- S10: [Configure-SystemEnvironment.ps1](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/windows/scripts/build/Configure-SystemEnvironment.ps1).
- S11: [Install-PostgreSQL.ps1](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/windows/scripts/build/Install-PostgreSQL.ps1).
- S12: [PathHelpers.ps1](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/windows/scripts/helpers/PathHelpers.ps1).
- S13: [scripts/tests](https://github.com/actions/runner-images/tree/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/windows/scripts/tests).
- Other scripts named in the text (`Install-*.ps1`, `Configure-*.ps1`): `https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/windows/scripts/build/<name>`, copies not stored.
- G1: [pin commit](https://api.github.com/repos/actions/runner-images/commits/ee1ff4569e381a9649b400338bdc8ceb7e18a80e).
- G2: [release win25-vs2026/20261007.264](https://github.com/actions/runner-images/releases/tag/win25-vs2026%2F20261007.264) and the releases list, read through the API on 2026-10-19.
- G3: [compare aee0669...ee1ff45](https://github.com/actions/runner-images/compare/aee0669dd04510a11756664eb77f5630debabed3...ee1ff4569e381a9649b400338bdc8ceb7e18a80e) (histories diverge; merge base `573fa3ad959907712ce8bf6a5f91ab82b03e7f2d`, pin is 15 commits ahead, release commit 1 commit ahead).
- R1: [https://github.com/special-place-ai-heaven/aap-runner/actions/runs/39303666617](https://github.com/special-place-ai-heaven/aap-runner/actions/runs/39303666617), log `sources/hosted-capture-39303666617.log`.
- H1: `../hosted-reference.md`. H2: GitHub docs `github/docs` commit `497671ebee089b38c8dc13ee9d09422405556ef3`, `content/actions/reference/runners/github-hosted-runners.md` and `data/reusables/actions/supported-github-runners.md`.
