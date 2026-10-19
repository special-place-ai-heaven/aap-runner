# Ubuntu 24.04, x64

Frozen hosted baseline for profile `ubuntu-24.04-x64`. Facts were fetched on 2026-10-19.
Every fact cites a source ID from the legend at the end. Source IDs point at the pinned commit
`ee1ff4569e381a9649b400338bdc8ceb7e18a80e` unless the legend says otherwise.
**Baseline commit (coordinator decision, 2026-10-19).** The baseline for this profile is `7e7dc1bcc0ef464e5e315a2b4c33609590c6cffe`, the commit that built the
observed image `ubuntu24/20261012.334`. `ee1ff4569e381a9649b400338bdc8ceb7e18a80e` stays recorded as the planning candidate only.
The inventory, template and toolset under `sources/build-commit-7e7dc1b/` are the baseline. The scripts under `scripts/` did not change between
the two commits (the compare lists no file there), so script links at the candidate commit also describe the baseline.
Where this file says "the pin", it means the candidate `ee1ff45`.

Files in this directory: `inventory.json` (machine readable, every Readme entry), `inputs.md`
(installer inputs, blockers, drift), `sources/` (byte-exact upstream template and toolset copies with `SHA256SUMS`; the Readme is hashed but not stored).

## Image identity

| Item | Value | Source |
|---|---|---|
| Image label written by the image | `ubuntu-24.04` | U13 |
| Workflow label to use | `ubuntu-24.04` only. `ubuntu-latest` is announced to move to Ubuntu 26.04 in November 2026. | H1, U1 |
| Image version string | `20261012.334.1` | U1 line 11 |
| OS version | `24.04.5 LTS` | U1 line 9 |
| Kernel | `6.17.0-1022-azure` | U1 line 10 |
| systemd | `255.4-1ubuntu8.17` | U1 line 12 |
| runner-images pin | `ee1ff4569e381a9649b400338bdc8ceb7e18a80e` (2026-10-16) | G1 |
| Image release | tag `ubuntu24/20261012.334`, published 2026-10-13T10:25:13Z, targets commit `7e7dc1bcc0ef464e5e315a2b4c33609590c6cffe` | G2 |
| Newest release on 2026-10-19 | `ubuntu24/20261018.339`, published 2026-10-19T11:58Z. The pin is already one release behind the fleet. | G2 |
| Azure source image (build input) | `canonical:ubuntu-24_04-lts:server`, OS disk 75 GB, selected by the key `ubuntu24`. The pipeline value for the key is not in the repository. | U14 |
| Build VM size (build time, not hosted runtime) | `Standard_D4s_v4` | U14 |
| Runner application version | `2.337.0` (observed 2026-10-19) | R1 |
| Hosted capture of the "Set up job" lines | Captured (run partial). Image and version equal the frozen values. See "Observed on the hosted reference". | R1 |

### Pin drift, resolved by pinning to the build commit

The Readme at the pin is byte-identical to the Readme at the release commit `7e7dc1b` (SHA-256
`3911b4bc1aa423be7b7469a75f3093f51306c02f2638f2a8b4f5ed31f3ffe791`). The build template
`build.ubuntu-24_04.pkr.hcl` is byte-identical too (SHA-256 `5b8a5f29c33d9c98a0368c0e3109eba9dc566ce8091aa412de56fc93518d1adf`).
The pin is 17 commits ahead of the merge base with the release commit (G3). The only build-relevant difference:

| File | At the release commit `7e7dc1b` (built the Readme image) | At the pin `ee1ff45` |
|---|---|---|
| `toolsets/toolset-2404.json`, Python cached versions | `3.10.*`, `3.11.*`, `3.12.*`, `3.13.*`, `3.14.*` (matches Readme: 3.10.22 to 3.14.8) | `3.11.*` to `3.15.*` (drops 3.10, adds 3.15) |
| `scripts/docs-gen/SoftwareReport.CachedTools.psm1` | version sort `[Version]` | tolerant sort (report only) |

`scripts/build/*` is unchanged. A rebuild from the pin would cache Python 3.11 to 3.15, not 3.10 to 3.14, and the
latest-at-build tools would move too. The Readme inventory is the authority for what a hosted VM contains.
Both toolsets are under `sources/`. Same coordinator decision as for Windows: keep the pin or move it to the
release commit.

## Hardware class of the hosted reference

| Repository visibility | vCPU | RAM | SSD (documented) | Source |
|---|---:|---:|---:|---|
| Public (standard Linux x64) | 4 | 16 GB | 14 GB | H2 |
| Private (standard Linux x64) | 2 | 8 GB | 14 GB | H2 |

The AAP consumer is private (see `../consumers.md`). The image configures a 4096 MB swap file on the Azure
resource disk (`/mnt`) through `waagent` settings (U4). Observed (R1): 4 vCPU, 16 GiB RAM, 3 GiB swap, `/` 145G with 86G free.

## Default user, privileges and lifecycle

- Linux hosted VMs run with passwordless `sudo` (H2). Every standard hosted runner is a new VM per job (H2).
- The runtime user name, UID and groups are not in the pinned sources. The build deprovisions with
  `waagent -force -deprovision+user` (U2). Observed user: `runner`, uid 1001 (R1). The current rig image
  rejects sudo for its runner user, which is a known difference (see `../consumers.md`).
- `loginctl enable-linger` is applied to the last user in `/etc/passwd` after generation (U15), so the user
  session exists from boot.
- Open file limit is 65536 soft and hard for all users; stack size is 16384 KB soft and hard; systemd defaults
  `DefaultLimitNOFILE=65536` and `DefaultLimitSTACK=16M:infinity` (U5).
- Kernel and storage tuning from the image (U4): `vm.max_map_count=262144`, `fs.inotify.max_user_watches=655360`,
  `fs.inotify.max_user_instances=1280`, `vm.mmap_rnd_bits=28`, `nf_conntrack_tcp_be_liberal=1` through a udev
  rule, `read_ahead_kb=128` udev rule, and the root filesystem mounted with
  `rootflags=nobarrier,data=writeback,journal_async_commit,commit=30` (ext4 only; the build fails otherwise).
- `/usr/share` and `/opt` are `chmod -R 777` after the build (U9). `/etc/hosts` maps `localhost` to `::1`
  and hosted runners block mining pools in `etc/hosts` (`../hosted-reference.md`, D4).
- Automatic updates are off: `apt-daily` and `apt-daily-upgrade` timers disabled, `unattended-upgrades` purged,
  MOTD news disabled, `fwupd-refresh.timer` masked, `man-db` auto-update off (U6, U4). `snapd` auto refresh is held
  for 60 days from build date (U12).
- Microsoft Defender for Endpoint is validated as absent (U18).

## Shells and versions

| Shell or runtime | Version | Source |
|---|---|---|
| Bash | 5.2.21(1)-release | U1 |
| Dash | 0.5.12-6ubuntu5 | U1 |
| PowerShell (`pwsh`) | 7.6.6 | U1 |
| Python (system) | 3.12.3 | U1 |
| Node.js (system, installed with `n`) | 22.23.3, default from toolset `node.default` `22` | U1, U3 |

## Environment variables and PATH facts

Everything below is what the pinned scripts define through `/etc/environment`. The Actions runner reads
`/etc/environment` itself; `/etc/profile.d` is ignored under `--norc` shells (comment in U12). Values are build-time
facts. Capture the live job environment before certifying (`../hosted-reference.md`).

- **Image variables:** `ImageVersion`, `ImageOS`, `ACCEPT_EULA=Y`, `XDG_CONFIG_HOME=$HOME/.config` (rewritten to the
  default user's home by a post-generation script, U15), `DEBIAN_FRONTEND=noninteractive` (U8),
  `AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache` and `RUNNER_TOOL_CACHE` (U4),
  `ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE=/opt/actionarchivecache` (U17).
- **Tool cache layout:** `/opt/hostedtoolcache/<Tool>/<version>/<arch>`. It is mode 777 (U4).
  Ruby directories get the sticky bit (U9). For each cached Go version `GOROOT_<major>_<minor>_X64` is appended to
  `/etc/environment`, and the default Go's `bin/*` is symlinked into `/usr/bin` (Configure-Toolset.ps1, S-toolset).
- **Variables from the Readme tables (U1):** `CONDA=/usr/share/miniconda`, `VCPKG_INSTALLATION_ROOT=/usr/local/share/vcpkg`,
  `CHROMEWEBDRIVER`, `EDGEWEBDRIVER`, `GECKOWEBDRIVER`, `SELENIUM_JAR_PATH`, `JAVA_HOME_8_X64` to `JAVA_HOME_25_X64`,
  `ANDROID_HOME`, `ANDROID_SDK_ROOT`, `ANDROID_NDK*` (default NDK 27.3.13750724, latest 30.0.16248370).
  `JAVA_HOME` is the default Java 17.
- **Other variables the scripts set (names only):** `DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1`, `DOTNET_NOLOGO=1`,
  `DOTNET_MULTILEVEL_LOOKUP=0`, `CHROME_BIN=/usr/bin/google-chrome`, `PIPX_BIN_DIR`, `PIPX_HOME`, `NVM_DIR`,
  `GRADLE_HOME`, `ANT_HOME`, `USE_BAZEL_FALLBACK_VERSION`, `HOMEBREW_NO_AUTO_UPDATE`,
  `HOMEBREW_CLEANUP_PERIODIC_FULL_DAYS`, `SWIFT_PATH`, `BOOTSTRAP_HASKELL_NONINTERACTIVE`, `GHCUP_INSTALL_BASE_PREFIX`,
  `VCPKG_FORCE_SYSTEM_BINARIES`, `AZURE_EXTENSION_DIR`.
- **PATH.** The helper `prepend_etc_environment_path` puts new entries first (U16). Scripts that change PATH, in
  provisioning order: .NET (`$HOME/.dotnet/tools`), Haskell (ghcup `bin`), PHP (`$HOME/.config/composer/vendor/bin`),
  Rust (`$HOME/.cargo/bin`), Python (pipx `bin`, then `$HOME/.local/bin`), snap (`/snap/bin`, added last, so first on
  PATH). `configure-system.sh` then strips the quotes around the `PATH` value (U9). Node is installed to
  `/usr/local/bin` with `n`. Final order must be captured live.
- **Not on PATH:** Homebrew (pre-installed, needs `eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"`)
  (U1 note). Miniconda is exposed through `CONDA`, not PATH (U1).

## Tool cache versions (default marked)

Versions come from U1 "Cached Tools". Defaults come from U3 `toolcache[].default`. The Readme does not mark defaults.

| Tool | Cached versions | Default | Rule (U3) |
|---|---|---|---|
| Go | 1.24.13, 1.25.14, 1.26.9 | **1.24.13** (symlinked into `/usr/bin`) | `go` default `1.24.*` |
| Node.js | 22.23.3, 24.21.0 | none in the tool cache; system Node 22.23.3 | `node.default` `22` |
| Python | 3.10.22, 3.11.17, 3.12.15, 3.13.16, 3.14.8 | none; system Python is 3.12.3 | no default in toolset |
| PyPy | 3.9.19 [PyPy 7.3.16], 3.10.16 [PyPy 7.3.19], 3.11.16 [PyPy 8.0.0] | none | no default in toolset |
| Ruby | 3.2.11, 3.3.12, 3.4.11, 4.0.7 | none; system Ruby 3.2.3 | no default in toolset |

The toolset also lists CodeQL (`*`) in the tool cache. The Readme has no CodeQL cached-tools section, only
"CodeQL Action Bundle 2.27.2" under Tools.

Java (U1 table): 8.0.504+1, 11.0.32+1, **17.0.20+1 (default)**, 21.0.12+1, 25.0.4+1. Android NDK default
**27.3.13750724**, others 29.0.14206865 and 30.0.16248370 (U1). .NET SDKs: 8.0.131, 8.0.206, 8.0.319, 8.0.425,
9.0.121, 9.0.205, 9.0.318, 10.0.112, 10.0.204, 10.0.303, 10.0.401. Clang 16.0.6, 17.0.6, 18.1.3 with default
version 18 (U3 `clang.default_version`). `inventory.json` carries every entry with `default` flags.
CMake is deliberately pinned at 3.31.6: the toolset records "Pinned to avoid CMake 4.0 compatibility issues",
review date 2026-12-01 (U3 `cmake.pinnedDetails`).

## Services and system state by default

| Item | Default state | Source |
|---|---|---|
| Docker (`docker.service`) | enabled and started; Docker Client and Server 28.0.4, Compose 2.38.2, Buildx 0.38.0, `containerd.io` latest at build; socket `/run/docker.sock` is `root:docker 0770` via tmpfiles | U1, U10, U3 |
| PostgreSQL 16.15 | disabled, stopped. Start with `sudo systemctl start postgresql.service`. | U1, U11 |
| MySQL 8.0.46 | disabled, stopped. Root password is set to the upstream-documented value (masked in `inventory.json`). | U1, U11 |
| Apache 2.4.58, Nginx 1.24.0 | disabled, inactive, port 80 when started | U1, U11 |
| `apt-daily`, `apt-daily-upgrade` | timers and services disabled | U6 |
| `snapd` | running; auto refresh held 60 days from build | U12 |
| `fwupd-refresh.timer` | masked when present | U4 |
| `haveged` | installed (Tools). Start state NOT IN PINNED SOURCES. | U1 |
| Cached Docker images | **Six `:latest` images are pulled in the build and are not listed in the Readme**: `ghcr.io/dependabot/dependabot-updater-core`, `ghcr.io/github/gh-aw-mcpg`, `ghcr.io/github/gh-aw-firewall/agent`, `.../api-proxy`, `.../squid`, `ghcr.io/github/github-mcp-server`. Pulled on 24.04, not on 22.04. The toolset `docker.images` list is empty. | U10, U3 |

## What is explicitly not present

- No `unattended-upgrades` (purged) and no Microsoft Defender for Endpoint (validated absent) (U6, U18).
- No Homebrew on PATH (U1). No apt-fast (installed on Ubuntu 22.04 only) (U6).
- No Ubuntu 26.04 content and no Arm64 content. Both need their own baseline (PLAN).
- The Readme lists no cached Docker images section even though images are pulled (above). Do not treat the
  Readme as the full image list. Observe `docker images`.
- No Windows or macOS items. Tools such as the Android emulator are absent from this Readme (the Windows Readme
  lists an emulator, the Ubuntu Readme does not).

## Provisioned by the template but not listed in the Readme

- Action archive cache `/opt/actionarchivecache` from the latest `actions/action-versions` release (U17).
- Agent Workflow Firewall JS bundle, latest three stable releases, checksum verified, in
  `$AGENT_TOOLSDIRECTORY/agentic-workflow-firewall-js/<version>/x64` (U17).
- GitHub Copilot CLI in `$AGENT_TOOLSDIRECTORY/copilot-cli/<version>/x64`, pinned to the gh-aw compatibility
  matrix and checksum verified (U17).
- npm globals from the toolset: `grunt`, `gulp`, `n`, `parcel`, `typescript`, `newman`, `webpack`, `webpack-cli`,
  `lerna`, `yarn` (U3). Ruby gems `multi_json`, `fastlane`. pipx packages `yamllint`, `ansible-core`.
- libicu70 for Ubuntu 24.04, installed from a pinned `.deb` with a hard-coded SHA-512 (U8).
- Microsoft package repository configuration (`packages-microsoft-prod.deb`) at the start of the build.
- Apt mirror list `azure.archive.ubuntu.com` then `archive.ubuntu.com` then `security.ubuntu.com`, with
  `Acquire::Retries 1` and 15 s timeouts on x64 (U7, U6).

## Provisioning order

Generated from `sources/pin/build.ubuntu-24_04.pkr.hcl` by `../tools/provisioning_order.py`. There is one
reboot, immediately before cleanup. Scripts run under `sudo`, except `install-homebrew.sh`, which runs as the
unprivileged build user. PowerShell scripts run through `pwsh -f`. The build ends with `waagent -force
-deprovision+user`. The image folder is `/imagegeneration` (U14).

- Step 1 (shell inline): mkdir ${var.image_folder} | chmod 777 ${var.image_folder}
- Step 2 (shell)
  - `configure-apt-mock.sh`
- Step 3 (shell)
  - `install-ms-repos.sh`
  - `configure-apt-sources.sh`
  - `configure-apt.sh`
- Step 4 (shell)
  - `configure-limits.sh`
- Step 5 (shell inline): mv ${var.image_folder}/docs-gen ${var.image_folder}/SoftwareReport | mv ${var.image_folder}/post-gen ${var.image_folder}/post-generation
- Step 6 (shell)
  - `configure-image-data.sh`
- Step 7 (shell)
  - `configure-environment.sh`
- Step 8 (shell)
  - `install-apt-vital.sh`
- Step 9 (shell)
  - `install-powershell.sh`
- Step 10 (shell)
  - `Install-PowerShellModules.ps1`
  - `Install-PowerShellAzModules.ps1`
- Step 11 (shell)
  - `install-actions-cache.sh`
  - `install-apt-common.sh`
  - `install-azcopy.sh`
  - `install-azure-cli.sh`
  - `install-azure-devops-cli.sh`
  - `install-bicep.sh`
  - `install-apache.sh`
  - `install-aws-tools.sh`
  - `install-clang.sh`
  - `install-swift.sh`
  - `install-cmake.sh`
  - `install-codeql-bundle.sh`
  - `install-awf.sh`
  - `install-container-tools.sh`
  - `install-dotnetcore-sdk.sh`
  - `install-microsoft-edge.sh`
  - `install-gcc-compilers.sh`
  - `install-firefox.sh`
  - `install-gfortran.sh`
  - `install-git.sh`
  - `install-git-lfs.sh`
  - `install-github-cli.sh`
  - `install-google-chrome.sh`
  - `install-google-cloud-cli.sh`
  - `install-haskell.sh`
  - `install-java-tools.sh`
  - `install-kubernetes-tools.sh`
  - `install-miniconda.sh`
  - `install-kotlin.sh`
  - `install-mysql.sh`
  - `install-nginx.sh`
  - `install-nvm.sh`
  - `install-nodejs.sh`
  - `install-copilot-cli.sh`
  - `install-bazel.sh`
  - `install-php.sh`
  - `install-postgresql.sh`
  - `install-pulumi.sh`
  - `install-ruby.sh`
  - `install-rust.sh`
  - `install-julia.sh`
  - `install-selenium.sh`
  - `install-packer.sh`
  - `install-vcpkg.sh`
  - `configure-dpkg.sh`
  - `install-yq.sh`
  - `install-android-sdk.sh`
  - `install-pypy.sh`
  - `install-python.sh`
  - `install-zstd.sh`
  - `install-ninja.sh`
- Step 12 (shell)
  - `install-docker.sh`
- Step 13 (shell)
  - `Install-Toolset.ps1`
  - `Configure-Toolset.ps1`
- Step 14 (shell)
  - `install-pipx-packages.sh`
- Step 15 (shell)
  - `install-homebrew.sh`
- Step 16 (shell)
  - `configure-snap.sh`
- Step 17 (shell)
  - `list-dpkg.sh`
- **REBOOT** (`sudo reboot`, expect_disconnect; next step pauses 5m)
- Step 18 (shell) [pause_before 5m0s]
  - `cleanup.sh`
- Step 19 (shell inline): pwsh -File ${var.image_folder}/SoftwareReport/Generate-SoftwareReport.ps1 -OutputDirectory | pwsh -File ${var.image_folder}/tests/RunAll-Tests.ps1 -OutputDirectory ${var.image_folder}
- Step 20 (shell)
  - `configure-system.sh`
- Step 21 (shell)
  - `post-build-validation.sh`
- Step 22 (shell inline): sleep 30 | /usr/sbin/waagent -force -deprovision+user && export HISTSIZE=0 && sync

The Ubuntu template is a single sequence with one reboot (before step 18, which pauses five minutes and
runs `cleanup.sh`). Upstream tests run in step 19 (`RunAll-Tests.ps1`, `Generate-SoftwareReport.ps1`).

## Inventory counts (source versus recorded)

Generated by `../tools/verify_inventory.py` against the Readme fetched from the pinned commit (not stored, see `sources/NOT-STORED.md`). The verifier counts
bullets, table data rows and fenced blocks independently of the parser and also proves that every content line of
the Readme is covered by an entry (`src_line` in `inventory.json`). "Versions recorded" counts individual
version strings, so list lines such as `Clang: a, b, c` and `<br>` table cells count once per version.
This Readme has no sections named Microsoft SDKs, Windows SDKs, Cached Docker images, Visual Studio or
Windows features. They exist only in the Windows Readme.

| Category | Source rows | Recorded entries | Notes (fenced blocks) | Versions recorded |
|---|---:|---:|---:|---:|
| Language and Runtime | 14 | 14 | 0 | 24 |
| Package Management | 11 | 11 | 0 | 11 |
| Package Management/Environment variables | 2 | 2 | 0 | 0 |
| Package Management/Homebrew note | 0 | 0 | 1 | 0 |
| Project Management | 4 | 4 | 0 | 4 |
| Tools | 39 | 39 | 0 | 39 |
| CLI Tools | 7 | 7 | 0 | 7 |
| Java | 5 | 5 | 0 | 5 |
| PHP Tools | 3 | 3 | 1 | 3 |
| Haskell Tools | 4 | 4 | 0 | 4 |
| Rust Tools | 4 | 4 | 0 | 4 |
| Rust Tools/Packages | 1 | 1 | 0 | 1 |
| Browsers and Drivers | 8 | 8 | 0 | 8 |
| Browsers and Drivers/Environment variables | 4 | 4 | 0 | 0 |
| .NET Tools | 2 | 2 | 0 | 12 |
| Databases | 1 | 1 | 0 | 1 |
| Databases/PostgreSQL | 1 | 1 | 1 | 1 |
| Databases/MySQL | 1 | 1 | 1 | 1 |
| Cached Tools | 0 | 0 | 0 | 0 |
| Cached Tools/Go | 3 | 3 | 0 | 3 |
| Cached Tools/Node.js | 2 | 2 | 0 | 2 |
| Cached Tools/Python | 5 | 5 | 0 | 5 |
| Cached Tools/PyPy | 3 | 3 | 0 | 3 |
| Cached Tools/Ruby | 4 | 4 | 0 | 4 |
| PowerShell Tools | 1 | 1 | 0 | 1 |
| PowerShell Tools/PowerShell Modules | 4 | 4 | 0 | 4 |
| Web Servers | 2 | 2 | 0 | 2 |
| Android | 9 | 9 | 0 | 34 |
| Android/Environment variables | 6 | 6 | 0 | 0 |
| Installed apt packages | 74 | 74 | 0 | 74 |
| **Total** | 224 | 224 | 4 | 257 |


content lines in Readme: 255, covered by entries: 255
Result: OK, all counts and line coverage match (exit code 0).

## Observed on the hosted reference (run 39303673044, partial)

Source R1: [https://github.com/special-place-ai-heaven/aap-runner/actions/runs/39303673044](https://github.com/special-place-ai-heaven/aap-runner/actions/runs/39303673044), workflow `hosted-reference-ubuntu-24.04`, label `ubuntu-24.04`, dispatched
2026-10-19T18:34:50Z from commit `f682e03a4386fd52010fb9640c41c50fad67de75`, repository public. **Conclusion: failure.** The
step "User, privileges, limits" exited 1 because `sysctl vm.mmap_rnd_bits` is denied for the unprivileged user, and the six
later steps were skipped. The inert copy of the workflow under `reference-workflows/` now ends that command with `|| true`.
The copy in `.github/workflows` still needs the same one-line fix and a second run. Raw log:
`sources/hosted-capture-39303673044.log`. Nothing scrubbed.

| Item | Observed |
|---|---|
| Image (Runner Image group) | `Image: ubuntu-24.04`, `Version: 20261012.334.1`, Included Software `.../blob/ubuntu24/20261012.334/images/ubuntu/Ubuntu2404-Readme.md`, Image Release `.../releases/tag/ubuntu24%2F20261012.334`. **Equals the frozen identity.** |
| Operating System group | Ubuntu 24.04.5 LTS; kernel `6.17.0-1022-azure`; systemd 255 (255.4-1ubuntu8.17). `ImageOS=ubuntu24`, `ImageVersion=20261012.334.1`. |
| Runner application | `Current runner version: '2.337.0'` |
| Runner Image Provisioner group | Hosted Compute Agent version `20261012.601`, commit `f3dc54e1fb89da6852db922499a0233137369e1d`, build date 2026-10-12T17:48:21Z, region `northcentralus`, cloud Azure |
| Environment | `RUNNER_OS=Linux`, `RUNNER_ARCH=X64`, `RUNNER_ENVIRONMENT=github-hosted` |
| Hardware | `nproc` 4, MemTotal 16373452 kB, **SwapTotal 3145724 kB (3 GiB, not the 4096 MB the build script configures)**. `/` is `/dev/root` 145G, 59G used, 86G available. Disk `sda` 150G, rotational flag 1. `/mnt` was not mounted separately. |
| User and privileges | `uid=1001(runner) gid=1001(runner) groups=1001(runner),4(adm),100(users),118(docker),999(systemd-journal)`. Passwordless sudo: yes. |
| Limits and sysctls | `ulimit -n` 65536, `ulimit -s` 16384. `vm.max_map_count=262144`, `fs.inotify.max_user_watches=655360`, `fs.inotify.max_user_instances=1280`. `vm.mmap_rnd_bits` unreadable without privilege. |

NOT FETCHED (steps skipped by the failure): allow-listed environment, PATH order, shell versions, service states,
Docker state and image list, tool cache layout, `read_ahead_kb`, root mount options. Keep these NOT VERIFIED until the
fixed workflow is re-run.

## Upstream image tests (part of the baseline)

The build runs `scripts/tests/RunAll-Tests.ps1`. At the pin the folder `images/ubuntu/scripts/tests/` holds 18 files:
`ActionArchiveCache`, `Android`, `Apt`, `Browsers`, `CLI.Tools`, `Common`, `Databases`, `DotnetSDK`, `Haskell`, `Java`,
`Node`, `PowerShellModules`, `System`, `Tools`, `Toolset` and `WebServers` (each `*.Tests.ps1`), plus `Helpers.psm1`
and `RunAll-Tests.ps1`. They were **not downloaded** by P01. Fetch them from the pinned commit when P06/P07 reconcile
each test with a probe (U19). The scripts also call `invoke_tests "<Group>" "<Name>"` per install, so the test set is
larger than the file list suggests.

## Open items for the coordinator

1. Pin drift is resolved by pinning to the build commit (above). Nothing open.
2. Hosted "Set up job" identity captured (R1). The run failed after the privilege step; fix the workflow and re-run for the rest.
3. `haveged` state, PATH, environment, services, `docker images` and tool cache layout remain NOT VERIFIED until the re-run.
4. Licensed and unreproducible inputs are listed in `inputs.md`. The Ubuntu profile has fewer licensed components than
   Windows, but it depends on the Azure Marketplace Canonical image, many `latest` vendor feeds and six floating
   `:latest` container images.

## Sources

- U1: [Ubuntu2404-Readme.md](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/ubuntu/Ubuntu2404-Readme.md).  Not stored (default credential), hash in `sources/NOT-STORED.md`.
- U2: [build.ubuntu-24_04.pkr.hcl](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/ubuntu/templates/build.ubuntu-24_04.pkr.hcl). Copy in `sources/pin/`.
- U3: [toolset-2404.json](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/ubuntu/toolsets/toolset-2404.json). Copy in `sources/pin/`.
- U4: [configure-environment.sh](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/ubuntu/scripts/build/configure-environment.sh).
- U5: [configure-limits.sh](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/ubuntu/scripts/build/configure-limits.sh).
- U6: [configure-apt.sh](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/ubuntu/scripts/build/configure-apt.sh).
- U7: [configure-apt-sources.sh](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/ubuntu/scripts/build/configure-apt-sources.sh).
- U8: [configure-dpkg.sh](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/ubuntu/scripts/build/configure-dpkg.sh).
- U9: [configure-system.sh](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/ubuntu/scripts/build/configure-system.sh).
- U10: [install-docker.sh](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/ubuntu/scripts/build/install-docker.sh).
- U11: `install-postgresql.sh`, `install-mysql.sh`, `install-nginx.sh`, `install-apache.sh` in the same folder.
- U12: [configure-snap.sh](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/ubuntu/scripts/build/configure-snap.sh).
- U13: [configure-image-data.sh](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/ubuntu/scripts/build/configure-image-data.sh).
- U14: [locals.ubuntu.pkr.hcl](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/ubuntu/templates/locals.ubuntu.pkr.hcl) (copy in `sources/pin/`) and [variable.ubuntu.pkr.hcl](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/ubuntu/templates/variable.ubuntu.pkr.hcl).
- U15: [assets/post-gen](https://github.com/actions/runner-images/tree/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/ubuntu/assets/post-gen) (`environment-variables.sh`, `systemd-linger.sh`).
- U16: [scripts/helpers/etc-environment.sh](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/ubuntu/scripts/helpers/etc-environment.sh).
- U17: `install-actions-cache.sh`, `install-awf.sh`, `install-copilot-cli.sh` in the build folder.
- U18: [post-build-validation.sh](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/ubuntu/scripts/build/post-build-validation.sh).
- U19: [scripts/tests](https://github.com/actions/runner-images/tree/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/ubuntu/scripts/tests).
- Configure-Toolset.ps1 (cited above as "S-toolset"): [Configure-Toolset.ps1](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/ubuntu/scripts/build/Configure-Toolset.ps1).
- G1: [pin commit](https://api.github.com/repos/actions/runner-images/commits/ee1ff4569e381a9649b400338bdc8ceb7e18a80e).
- G2: [release ubuntu24/20261012.334](https://github.com/actions/runner-images/releases/tag/ubuntu24%2F20261012.334) and the releases list, read through the API on 2026-10-19.
- G3: [compare 7e7dc1b...ee1ff45](https://github.com/actions/runner-images/compare/7e7dc1bcc0ef464e5e315a2b4c33609590c6cffe...ee1ff4569e381a9649b400338bdc8ceb7e18a80e) (histories diverge; merge base `2c421200c9e6873283a7b1d63bb122bc906139a1`, pin is 17 commits ahead, release commit 1 commit ahead).
- R1: [https://github.com/special-place-ai-heaven/aap-runner/actions/runs/39303673044](https://github.com/special-place-ai-heaven/aap-runner/actions/runs/39303673044), log `sources/hosted-capture-39303673044.log`.
- H1: `../hosted-reference.md`. H2: GitHub docs `github/docs` commit `497671ebee089b38c8dc13ee9d09422405556ef3`, `content/actions/reference/runners/github-hosted-runners.md` and `data/reusables/actions/supported-github-runners.md`.
