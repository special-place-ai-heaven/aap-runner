# Ephemeral self-hosted runner (`aap-crrr`)

CI jobs in `.github/workflows/ci.yml` target a self-hosted runner instead of GitHub-hosted `ubuntu-latest`. GitHub-hosted minutes for the org are exhausted until 1 November. Nothing in this directory registers a runner or contacts the workstation. Rob runs the bootstrap on that PC after BRUCE accepts this design. Until the runner is online, the workflow is queued and does not run.

The acceptance gate is a parity run on this runner whose failure names are exactly PR #39's known registry: 0 new, 0 stale. The test commands that produce that inventory are unchanged.

## Layout

| File | Role |
|---|---|
| `wsl.conf` | Lockdown for the `aap-runner` distro, including `systemd=true` |
| `bootstrap.sh` | Import Ubuntu 24.04, install Docker Engine and Sysbox, stop if Sysbox fails |
| `stage-into-distro.sh` | Positional stage path for `wsl --exec`. The distro shell does not expand it |
| `manager.sh` | Root loop: one fresh container, one job, then remove it |
| `aap-runner-manager.service` | systemd unit for that loop. Requires docker and `aap-workdisk.service`, wants sysbox. Exit 143 after SIGTERM is a clean stop |
| `nftables.conf` | Best-effort egress drop for LAN, link-local, CGNAT, and the other non-global ranges |
| `manager.conf.example` | Schema for `/etc/aap-runner/manager.conf`. No secrets |
| `Dockerfile` | Job image: inner dockerd 27.3.1, build-essential, mysql-client, no sudo |
| `ephemeral-entry.sh` | Starts inner dockerd, registers ephemeral, runs one job |
| `create-work-vhdx.ps1` | Fixed VHDX: `New-VHD -Fixed`, or diskpart when that cmdlet is absent or errors |
| `mount-work-vhdx.ps1` | Operator logon task: `wsl --mount --vhd <path> --bare`, log appended under `C:\wsl` |
| `mount-work-vhdx-task.xml` | That operator's SID, `InteractiveToken`, `HighestAvailable`, logon trigger. Installed as UTF-16 LE |
| `mount-work-disk.sh` | Mount the ext4 at `/var/lib/ghrunner`, then bind containerd and sysbox onto it |
| `aap-workdisk.service` | Runs that mount before containerd, Docker, and Sysbox |
| `daemon.json` | Keys merged into the live daemon.json: `data-root` and `ipv6`. Runtimes are kept |
| `docker-workdisk.conf` | Drop-in for docker, containerd, and sysbox: start only after the work disk is mounted |
| `sysbox-restart.conf` | Drop-in for sysbox, sysbox-mgr, and sysbox-fs: restart after a non-zero exit, 5 s apart, no start limit |
| `labels.sh` | Shared label checks. Sourced by the manager, bootstrap, and evidence |
| `evidence.sh` | Prints the lockdown observations. Installed as `/usr/local/sbin/aap-runner-evidence` |
| `evidence-host.sh` | From the operator distro, passes `wsl --version`, `.wslconfig`, and the GitHub runner list into that script |
| `lock-acl.ps1` | DACL for the boot-task folder, script, and VHDX: SYSTEM and Administrators only, owner Administrators. Windows PowerShell 5.1 or PowerShell 7 |

`bash labels.sh --self-check`, `bash bootstrap.sh --self-check`, `bash manager.sh --self-check`, `bash evidence.sh --self-check`, `bash mount-work-disk.sh --self-check`, and `bash evidence-host.sh --self-check` check the checksum, disk-floor, limit, route, sudo-listing, daemon.json merge, base-label, and bind-staging parsers, the cases where a missing `wslinfo` or an unreadable `.wslconfig` must stop the install, that a CP1252 comment, CRLF, and a commented `networkingMode` do not make `.wslconfig` unreadable, that an already-attached disk is accepted only when a live UUID probe matches `work-disk.uuid`, that `mkfs` runs only when `blkid -p -o export` exits 2, that an empty `/mnt/c` directory is not a Windows mount, and that the mount task is rendered for a user SID as UTF-16 LE. `pwsh -File install-host.Tests.ps1` checks `-DryRun`. They do not touch WSL.

## What runs where

The Windows 11 PC keeps the user's `Ubuntu` distro and `docker-desktop`. CI uses a third distro, `aap-runner`, imported from `ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz`. `noble/current` publishes that file and no separate rootfs, so the sha256 is the pin. The tarball is the 2024-04 snapshot; bootstrap runs `apt full-upgrade` after import. Docker Desktop's WSL integration is not enabled for `aap-runner`.

`/etc/wsl.conf` in that distro is the file in this directory:

```ini
[automount]
enabled=false
mountFsTab=false

[interop]
enabled=false
appendWindowsPath=false

[user]
default=ghrunner

[boot]
systemd=true
```

`automount` and `interop` remove `/mnt/c` and Windows exe launching. The distro cannot see the Windows profile, the browser, SSH keys, Grok Bot, or `C:\claude-obsidian`. `[boot] systemd=true` is what lets the root manager run; the three lockdown sections are the ones above it.

Inside the distro: Docker CE `5:29.9.0-1~ubuntu.24.04~noble` and containerd.io `2.4.1-2~ubuntu.24.04~noble`, installed from Docker's apt repository. The key is `https://download.docker.com/linux/ubuntu/gpg`, sha256 `1500c1f56fa9e26b9b8f42452a553675796ade0807cdce11975eb98170b3a570`, fingerprint `9DC858229FC7DD38854AE2D88D81803C0EBFCD88`. There is no `get.docker.com` script and no Ubuntu `docker.io` package. Sysbox CE 0.7.1 is the runtime. Phase 1 on this PC used kernel `6.18.35.2-microsoft-standard-WSL2` with idmapped mounts and no shiftfs. The preflight still has to pass; that kernel is the one that did, not a waiver.

Each job is a new container started with `--runtime=sysbox-runc`. That container has one host mount, the compile cache (see [Runner pool and compile cache](#runner-pool-and-compile-cache)), and no host docker socket. The inner dockerd is 27.3.1 (`docker-ce=5:27.3.1-1~ubuntu.24.04~noble`, containerd.io `1.7.29-1~ubuntu.24.04~noble`). Phase 1 ran MySQL 8.4, which is 8.4.11, on `127.0.0.1:3306` from that inner daemon and reached it from the job container. Service containers stay on that inner dockerd.

Service images are pulled by that inner dockerd on every job. A pre-seeded tarball does not stop the pull. `ci.yml` pins the multi-arch index digest (`image@sha256:…`). `docker save` / `docker load` keeps the platform image and drops the index digest, so the inner daemon still fetches the digest the workflow names. A host mount of an image cache would add a second host mount; the compile cache is the only one. A registry on the host is behind the bridge filter, which drops the gateway and RFC1918 on purpose. The pull is network time and bandwidth. The unpacked layers live in the job container's writable layer, which is on the work disk, and `docker rm -f` deletes them with the container. They do not accumulate on the distro root.

`ghrunner` is the distro login, uid 1002. It is not in `sudo` or `docker`. `sudo -n -l -U ghrunner` must print `not allowed to run sudo`. sudo 1.9.15p5 exits 0 for that denial, so the exit status is not the check. The manager is a root systemd service. The in-container user `runner` is a different account. It is in the container's `docker` group so it can talk to the inner socket, and it has no sudo. The image includes `build-essential`, `pkg-config`, `libdbus-1-dev`, `mysql-client`, `tar`, `xz-utils`, and `unzip` because the job cannot `apt-get`. `scripts/check-workspace-lints.sh` is bash and awk, which the image already has.

## Registration

The manager reads `/etc/aap-runner/manager.conf` (mode `0400`, root) and the App private key at `/etc/aap-runner/app.pem` (mode `0400`, root). Both must stay mode `0400` or the manager exits. The key is held in the manager process only. It is not mounted into the job container and it is not placed in the job environment.

For each job the manager:

1. Refuses to start unless `/var/lib/ghrunner` is a mountpoint, its source device is not the device behind `/`, and its filesystem UUID equals `/etc/aap-runner/work-disk.uuid`. `df` size must also sit within `AAP_WORK_DISK_GIB` minus 10 GiB through plus 4 GiB. That size is an integer from 20 to 512 (default 60, so 50–64). Free space must be at least `AAP_DISK_FLOOR_GB`. That floor defaults to max(15 GB, 10% of the disk), rounded up. A configured floor below that is raised. A higher floor is kept. A ~1000G distro VHD fails the UUID check and the 512 cap.
2. Mints a short-lived registration token: App JWT, installation token, then `POST /orgs/{org}/actions/runners/registration-token`. The token stays in memory. It is passed to the container on stdin and unset before `run.sh`.
3. Starts a container with no `-v`, no `--privileged`, and no `/var/run/docker.sock`. `docker create` passes `--memory`, `--memory-swap` equal to that memory, `--cpus`, `--cpu-shares 512`, and `--pids-limit` from this host's `manager.conf`. Swap equal to memory means the job gets no extra swap, so it cannot spill into swap and freeze the host. `--cpu-shares 512` is half the default weight. It only orders containers against each other inside this WSL VM. The `.wslconfig` `memory` and `processors` caps are what keep Windows responsive. CRRR65734 sets `12g` and `6`. A missing key uses those same values. A second host writes its own memory, cpu, and pid numbers in its own `manager.conf`. The same `docker create` passes `AAP_WORK_DISK_GIB` and `AAP_DISK_FLOOR_GB` into the container, and the entry script keeps those two names for `run.sh`, so the workflow's `df` uses this host's disk. A wall clock (`AAP_JOB_TIMEOUT_MINUTES`, default 120, maximum 1440) then stops and removes the container if it is still there. 120 is longer than the longest job `timeout-minutes` (90), so a job that finishes is not cut off by the clock. The clock process does not receive the registration token.

Labels passed to `config.sh` are `self-hosted,linux` plus `AAP_RUNNER_BASE_LABEL`, plus `AAP_RUNNER_EXTRA_LABELS` when that host sets it. The base is required and is `crrr` or `fresh`. An empty or missing base stops the manager, bootstrap, and evidence. CRRR sets `crrr` and registers `self-hosted,linux,crrr`. Fresh sets `fresh` and `heavy`, and registers `self-hosted,linux,fresh,heavy`. GitHub compares labels without regard to case, so the base and every extra label must already match `^[a-z0-9][a-z0-9._-]*$`. That charset check runs before the reserved-label check (`crrr`, `fresh`, `self-hosted`, `linux`) and before the duplicate check. `CRRR`, `Crrr`, `FRESH`, `LINUX`, `Self-Hosted`, and `Heavy` are refused. The manager, bootstrap, and evidence all source `labels.sh` for this. `labels.sh` stamps `AAP_RUNNER_LABELS_VERSION`. Each of those three scripts requires that exact value and exits if the sourced file differs, so a partial copy of the scripts does not run. The manager logs `runner labels:` before it mints a registration token. `ci.yml` stays on `[self-hosted, linux, crrr]`, so Fresh does not take those jobs. A later heavy job will target `fresh`.

```text
config.sh --unattended --ephemeral --disableupdate=false \
  --labels self-hosted,linux,crrr --runnergroup aap-crrr
```

`--url` and `--token` are required for that command to register. `--disableupdate=false` leaves runner self-update on, as specified.
4. Waits for the ephemeral runner to exit after one job.
5. `docker rm -f` the container and deletes its network. The workspace lives only in the container, so removing the container wipes it. There is no host workspace directory. After the job the manager prunes dangling images, build cache, and stopped containers and networks labelled `aap-crrr-job` that are older than one hour. Once a day it runs `journalctl --vacuum-size=200M` and removes `/var/lib/ghrunner/sysbox` directories of containers Docker no longer has. If a start is under the free-space floor, that cleanup runs once and the free space is checked again before the job is refused.

A restart of the manager removes leftover containers with that label before it mints another token.

## Sysbox preflight

Bootstrap builds `aap-crrr-runner:local` and runs:

```text
docker create --runtime=sysbox-runc --name aap-sysbox-preflight \
  --entrypoint /opt/aap-runner/ephemeral-entry.sh \
  aap-crrr-runner:local --preflight
aap-runner-manager --assert-mounts aap-sysbox-preflight
docker start --attach aap-sysbox-preflight
```

`--assert-mounts` runs before the container starts. A mount source of `/mnt` or under `/mnt` (including `/mnt/wsl`) stops the install. The preflight then starts the inner dockerd and requires `docker info` to succeed. If it fails, bootstrap exits non-zero and does not enable a different runtime. There is no fallback to a privileged container or a host socket mount. Do not add one to make the install pass.

Phase 1 passed Sysbox on `6.18.35.2-microsoft-standard-WSL2` using idmapped mounts, not shiftfs. A kernel that fails the preflight still stops the install. There is no degraded mode.

## Network

Outbound only. The distro does not listen: the nftables input policy is drop, with loopback and established traffic allowed, plus IPv6 neighbor discovery so the WSL interface can stay configured. The manager publishes no host ports. The job does not publish SingleStore Studio (`8080`) or the SingleStore ops port (`9000`).

`nftables.conf` drops forwarded traffic from the Docker and Sysbox bridges to:

- RFC1918 (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`)
- link-local (`169.254.0.0/16`, IPv6 `fe80::/10`)
- CGNAT / Tailscale (`100.64.0.0/10`, plus IPv6 ULA `fc00::/7`)
- this-network and loopback (`0.0.0.0/8`, `127.0.0.0/8`)
- IETF protocol assignments (`192.0.0.0/24`) and benchmarking (`198.18.0.0/15`)
- multicast and reserved (`224.0.0.0/4`, `240.0.0.0/4`)
- IPv4-mapped IPv6 (`::ffff:0:0/96`), NAT64 (`64:ff9b::/96`), and IPv6 multicast (`ff00::/8`)

except the distro's DNS resolver, which bootstrap writes into the set from `/etc/resolv.conf`. Those accept rules are above the drops, so a resolver at `127.0.0.53` still answers. Internet destinations are allowed. The packet's destination is filtered, not the bridge gateway, so normal outbound NAT still works.

The operator distro proves networking before `aap-runner` is imported. `mountpoint -q /mnt/c` is the Windows-reachability test. An empty `/mnt/c` directory is not a mount: `aap-runner` keeps that directory after automount is turned off. The file is read as bytes from the Windows profile: CR is stripped, and a non-UTF-8 byte in a comment does not make it unreadable. A commented `networkingMode` line is not a setting. An empty `GetFolderPath("UserProfile")` falls back to `ProfileImagePath` for that Windows identity. It does not use `%USERPROFILE%`. If the file cannot be read, the refusal prints the path that was tried. An absent file is the NAT default and the proof literal is `absent`. An unset `networkingMode` is `nat`. `mirrored`, or any other value, is refused. `wslinfo --networking-mode` is checked there too. The literal (`nat` or `absent` only) is passed into `--inside-runtime`. Inside `aap-runner` that literal is checked against `wslinfo`. The distro does not read `.wslconfig` and does not call `powershell.exe`. A missing or empty `wslinfo` inside `aap-runner` refuses. A missing `autoMemoryReclaim` is a preflight warning. Mirrored mode puts this distro on the Windows LAN. This table does not see that traffic. Leave WSL on NAT.

The distro `daemon.json` sets `"ipv6": false`. After dockerd starts, bootstrap reads `docker network inspect bridge` and stops unless `EnableIPv6` is `false`. Each job's inner dockerd writes the same file before it listens, and the entry script stops that job if the inner bridge is not `false`.

This is best-effort LAN isolation. It covers bridge egress from this distro. It does not cover the WSL2 virtual switch on the Windows host, and a process inside the Sysbox container that can reconfigure its own network namespace is outside the host table. Do not open these prefixes because a job cannot reach GitHub: GitHub's addresses are public, so a drop here is not the cause.

## Disk floor

The work disk is a **fixed VHDX** at `C:\wsl\aap-runner-work.vhdx`. CRRR is 60 GiB (`AAP_WORK_DISK_GIB=60`). Fresh is 100 GiB. Fixed means the file cannot grow, so job layers cannot grow into `C:`. `df` of that ext4 is the free space. `df /` on the distro root is still the distro VHD's maximum (1 TB on this PC) and is not a guard.

Bootstrap creates the file once, from an elevated shell:

```powershell
New-VHD -Path C:\wsl\aap-runner-work.vhdx -SizeBytes 60GB -Fixed
```

`New-VHD` is a Hyper-V cmdlet. It is absent, or it errors, on Windows Home and on any host whose Hyper-V Virtual Machine Management service (VMMS) is not running. The script then uses diskpart and applies the same ACL. The diskpart script is written in `C:\wsl` after that directory is locked, and it is deleted when diskpart returns. It is not written under `%TEMP%`. A `-Path` that is not a drive-letter `.vhdx` path is refused before the directory is created. `C:\wsl` is locked as soon as it is created, before the install marker or the VHDX is written. `maximum=` is MiB (`AAP_WORK_DISK_GIB * 1024`). For the 60 GiB default that is `61440`, the same size as PowerShell's `60GB`. A 100 GiB disk is `102400` MiB. Bootstrap passes `-SizeGiB` from `AAP_WORK_DISK_GIB` (default 60):

```text
create vdisk file="C:\wsl\aap-runner-work.vhdx" maximum=61440 type=fixed
```

It then attaches the disk with `wsl --mount --vhd C:\wsl\aap-runner-work.vhdx --bare`. That mount does not require elevation. `mkfs.ext4` runs only when `blkid -p -o export` exits 2. A partition table (`PTTYPE`) or a filesystem other than ext4 refuses, and any other blkid status refuses. Any attached whole disk whose size is not this VHDX's exact byte count fails preflight, so another distro's disk is not formatted. The UUID is stored at `/etc/aap-runner/work-disk.uuid`. A mount error that contains `already` in any case, including `WSL_E_USER_VHD_ALREADY_ATTACHED`, means the VHDX is already attached. Bootstrap then checks `lsblk` for one disk of that VHDX's byte size. Once `work-disk.uuid` exists, the UUID is read with `blkid -p` after `udevadm settle`, so a cache entry from before `mkfs` is not treated as a missing filesystem. `lsblk -dn -o UUID` is the fallback. That probe runs as root inside the distro that sees the disk: this shell when it can read the superblock, otherwise `wsl -d aap-runner -u root`. A different UUID is still refused. `wsl.exe -l` is stripped of UTF-16 NULs before its output is stored.

When the installing operator logs on, task `AAP-CRRR-Mount-Work-Disk` runs as that operator, elevated (`HighestAvailable`), and runs only `wsl --mount --vhd <that path> --bare`. WSL is per Windows user. The same command running as SYSTEM attaches the disk to SYSTEM's WSL VM, and `aap-runner` is not in that VM, so the task is not SYSTEM. There is no boot trigger: `InteractiveToken` has no session until that operator logs on, and a boot task cannot see this user's WSL. The runner is available after the operator logs on, which is the same condition WSL itself needs. The script appends the command output to `C:\wsl\mount-work-vhdx.log`. Inside `aap-runner`, `aap-mount-work-disk` mounts that UUID at `/var/lib/ghrunner`. `mountFsTab=false` stops WSL from processing fstab; the line is still there with `nofail` for systemd, and the service retries until the UUID appears. systemd's `var-lib-ghrunner.mount` from that line can mount the disk first, at boot or when the device appears late. `aap-workdisk.service` runs after that unit and accepts a mount that is already there, or one made while its own `mount -U` ran, only when the UUID is `work-disk.uuid`, the device is not `/`, and the size fits. `mountpoint -q` failing exits the mount script, and docker.service has `ConditionPathIsMountPoint=/var/lib/ghrunner`, so dockerd does not start on the distro root.

`lock-acl.ps1` uses `Get-Acl` and `Set-Acl`, so the operator can run it with Windows PowerShell 5.1 (`powershell.exe`) or PowerShell 7 (`pwsh`). Bootstrap starts every `powershell.exe` with `PSModulePath` set to the machine value first (`[Environment]::GetEnvironmentVariable('PSModulePath','Machine')`), and `lock-acl.ps1`, `create-work-vhdx.ps1`, and `mount-work-vhdx.ps1` set it again before any cmdlet. The logon task's command does the same before it runs the script. A PowerShell 7 parent otherwise leaves its module path in the environment, and Windows PowerShell 5.1 cannot autoload `Microsoft.PowerShell.Security` (`Get-Acl` CouldNotAutoload). It clears inheritance and leaves only `S-1-5-18` (SYSTEM) and `S-1-5-32-544` (Administrators), full control, on `C:\wsl`, `C:\wsl\mount-work-vhdx.ps1`, `C:\wsl\mount-work-vhdx-task.xml`, and `C:\wsl\aap-runner-work.vhdx`. It sets the owner of each of those paths to Administrators (`S-1-5-32-544`) and reads the owner back. Any other owner, or a non-admin ACE, fails the install. The directory ACEs inherit onto children, including `C:\wsl\mount-work-vhdx.log`. The task principal is the installing operator, not SYSTEM. That account is not given its own ACE: the task runs elevated, so the Administrators ACE covers it. Bootstrap runs that script after it creates the VHDX and again after it writes the logon script. Check with `icacls C:\wsl`, `icacls C:\wsl\mount-work-vhdx.ps1`, and `icacls C:\wsl\aap-runner-work.vhdx`. Each list should name only SYSTEM and Administrators, and the owner should be `BUILTIN\Administrators`.

`/var/lib/ghrunner/docker` is dockerd's `data-root`. Docker 29 keeps images and container snapshots in containerd's root, `/var/lib/containerd`, and that path ignores `data-root`. The mount script bind-mounts `/var/lib/ghrunner/containerd` onto `/var/lib/containerd` and `/var/lib/ghrunner/containerd-state` onto `/run/containerd`, so the image store is on the work disk whichever snapshotter is active. A partial `/etc/containerd/config.toml` is not written: that file replaces containerd's compiled defaults. The bind covers the default path instead. Stale containerd sockets are removed only when containerd is not running.

Sysbox's host state is a bind of `/var/lib/ghrunner/sysbox` onto `/var/lib/sysbox`. A symlink does not survive: `sysbox-mgr`'s postinst recreates `/var/lib/sysbox` as a directory. The boot unit runs the bind before containerd, Docker, and Sysbox start, and bootstrap runs it again after the package install. The inner dockerd's data is inside the job container's writable layer, so it is on the same ext4. The distro root VHD still holds the OS packages. It does not hold images or job layers.

Bootstrap merges `daemon.json` into `/etc/docker/daemon.json` with jq. `data-root` and `ipv6` are set from the template. A `runtimes` object already in the file, including `sysbox-runc`, is kept. Replacing the file drops that runtime. After dockerd starts, bootstrap requires `sysbox-runc` in `docker info` runtimes and requires `df` of `/var/lib/containerd`, `/run/containerd`, `/var/lib/sysbox`, and the Docker root to be the work disk.

`AAP_WORK_DISK_GIB` is an integer from 20 to 512. `df -BG` of the ext4 is a few GiB under the VHDX, so the manager, the mount script, evidence, and each job accept size minus 10 through plus 4. 60 accepts 50–64. 100 accepts 90–104. 513 is refused, so a ~1000G filesystem cannot fall in the window. The size window is not the only guard: the manager, the mount script, and evidence require the source device of `/var/lib/ghrunner` to differ from `/` and its filesystem UUID to equal `/etc/aap-runner/work-disk.uuid`. The manager runs `df -BG --output=avail /var/lib/ghrunner` and refuses a job below `AAP_DISK_FLOOR_GB`. That floor is at least **max(15 GB, 10% of the disk)**, rounded up. 60 GiB and 100 GiB are **15 GB free**. 200 GiB is **20 GB free**. A configured floor below that minimum is raised. A higher explicit floor is kept. It also refuses when `mountpoint -q` fails. Each job's first step runs the same `df` on `$GITHUB_WORKSPACE`, using `AAP_WORK_DISK_GIB` and `AAP_DISK_FLOOR_GB` from the job environment. Absent values are 60 and 15, which is CRRR. That directory is on the container root, whose overlay upper dir is the docker data-root, so it is the same filesystem.

The free-space floor is max(15 GB, 10% of the disk). It is the point where a new job is refused, after one cleanup pass. Full debuginfo on a hosted runner failed at about 140 GB (`ld: No space left on device` in the workflow comment). This CI uses line-tables-only and `CARGO_INCREMENTAL=0`. Campaign `cargo clean` notes in the repo removed 15.9 GiB, 36.6 GiB, and 41.5 GiB of warm incremental trees. Those trees are larger than one fresh job. A job that needs more than what remains fills this disk and stops. It does not extend `C:`.

Creating the VHDX needs `AAP_WORK_DISK_GIB` gigabytes free on `C:` at that moment, measured from the operator distro's `/mnt/c`. The default is 60. That check allocates the file. It is not the per-job floor.

The hosted-runner toolchain-delete step is gone. `CARGO_INCREMENTAL=0` and line-tables-only debug stay.

## Fresh profile

Fresh has 93 GB of RAM and 32 threads. CRRR stays at the defaults in `manager.conf.example`: 60 GiB disk, 15 GB free, `12g`, 6 cpus, 4096 pids, and no extra labels. Fresh is a second `manager.conf`, not a change to those defaults. Both hosts still get `--memory-swap` equal to their own `--memory`, and `--cpu-shares 512`.

Install the work disk at 100 GiB from an elevated shell:

```powershell
powershell -File ops\self-hosted-runner\install-host.ps1 -WorkDiskGiB 100
```

That writes `AAP_WORK_DISK_GIB=100` into a new `/etc/aap-runner/manager.conf` and sets `AAP_DISK_FLOOR_GB` to at least 15. An existing conf is left as it is. `df` then accepts 90–104 GB.

After install, set the job limits and labels in that conf:

```text
AAP_WORK_DISK_GIB=100
AAP_DISK_FLOOR_GB=15
AAP_JOB_MEMORY=72g
AAP_JOB_CPUS=24
AAP_JOB_PIDS_LIMIT=8192
AAP_RUNNER_BASE_LABEL=fresh
AAP_RUNNER_LABELS=self-hosted,linux,fresh
AAP_RUNNER_EXTRA_LABELS=heavy
```

Those labels are `self-hosted,linux,fresh,heavy`. There is no `crrr` label, so `runs-on: [self-hosted, linux, crrr]` does not select this host. Fresh runs a job only when the workflow names `fresh`. Heavy jobs will later target `fresh`.

The manager starts each job with `--memory 72g --memory-swap 72g --cpus 24 --cpu-shares 512 --pids-limit 8192`. 72g leaves headroom inside the WSL VM for dockerd and sysbox. WSL on this PC may use 80 GB total, which leaves 16 GB for Windows. In the Windows user's `.wslconfig`:

```ini
[wsl2]
memory=80GB
processors=28
autoMemoryReclaim=gradual
```

Leave `networkingMode` unset, or set `nat`. `mirrored` is refused. `processors=28` leaves four threads for Windows on a 32-thread host. `autoMemoryReclaim=gradual` returns idle WSL memory to Windows. The manager runs `docker rm -f` when the job exits, so the container does not stay resident.

## Runner pool and compile cache

`AAP_RUNNER_COUNT` in `manager.conf` is the number of job containers that run at once, 1 to 5. Absent means 1. An empty value, `0`, `6`, or `2.0` is refused. Each slot is its own loop: disk floor check, a fresh registration token, one container, cleanup, repeat. A job that exits non-zero is normal; the slot takes the next job. Container names are `aap-crrr-<slot>-<epoch>-<manager pid>`.

`AAP_JOB_CPUS` and `AAP_JOB_MEMORY` are the pool total. Each container gets total / count, rounded down to whole cpus and whole MiB. A slot under 1 cpu or 1g is refused. `AAP_JOB_PIDS_LIMIT`, the wall clock, `--cpu-shares`, labels, and the runner group are per container and unchanged. Fresh at 24 cpus and `72g`:

| Count | Per container |
|---|---|
| 1 | 24 cpus, `72g` |
| 3 | 8 cpus, `24g` |
| 4 | 6 cpus, `18g` |

If a slot's loop dies, the manager removes that slot's job container (label `aap-crrr-slot=<N>`) and its network, then restarts that slot alone after 10 s per consecutive death, capped at 60 s. The other slots' jobs keep running. A slot that dies five times in a row, each within 120 s of starting, is retired and not restarted; the other slots and their jobs keep running. When every slot is retired the manager exits 1 and systemd restarts the pool. SIGTERM stops every slot, removes every `aap-crrr-job=1` container, and prunes job networks.

The disk floor is checked before each container starts, not while parallel jobs run. Two or more jobs together can go below it.

## Disk IO cap

The work disk is a VHDX on the host's C: drive. Parallel Rust builds can saturate it, and then Windows VSS drops shadow copies. The manager caps job IO at a share of what the disk measured, so the host keeps headroom.

`aap-runner-manager --measure-io` (root) benchmarks `/var/lib/ghrunner` with `dd` and direct IO: a 2 GiB write (`oflag=direct conv=fsync`), then a read of the same file (`iflag=direct`). It deletes the file, takes the lower of the two rates in MiB/s, writes it to `/etc/aap-runner/work-disk.mbps` (one integer, mode `0644`), prints `work-disk.mbps=<n>`, and exits 0. It refuses with exit 1 when `/var/lib/ghrunner` is not a mountpoint or has under 3 GiB free. It reads no config, starts no pool, and makes no docker call. Run it once after install, and again after the disk or host changes; the pool reads the file only at start. Run it while no job is running, or the jobs' IO lowers the result.

`AAP_JOB_IO_PERCENT` (`manager.conf` or `limits.conf`, 0 to 100, default 90) sets the pool budget: measured MiB/s times the percent / 100, rounded down. Each slot gets budget / `AAP_RUNNER_COUNT`, rounded down. A slot under 10 MiB/s is refused. `0` means no cap. A missing `work-disk.mbps`, or one that is not a positive integer, also means no cap, and the manager logs `io cap disabled: run aap-runner-manager --measure-io`; the pool still starts. A 1000 MiB/s disk at 90%:

| Count | Per container |
|---|---|
| 1 | 900 MiB/s |
| 2 | 450 MiB/s |
| 3 | 300 MiB/s |

In `fixed` sharing, `docker create` gets `--device-read-bps` and `--device-write-bps` `<dev>:<n>mb`, plus `--device-read-iops` and `--device-write-iops` `<dev>:<n * 8>` (`IO_IOPS_PER_MB` in `manager.sh`, a 128 KiB average request). docker reads `mb` as MiB. `<dev>` is the whole disk behind `/var/lib/ghrunner`, from `findmnt -n -o SOURCE`; a partition is replaced by its parent from `lsblk -no PKNAME`. Fresh mounts the bare disk, such as `/dev/sde`. The device is resolved once at pool start; if that fails the manager logs it and runs without the cap. Each slot has its own cap, so the slots together stay within the budget; one busy slot cannot borrow an idle slot's share. In `slice` sharing (the default) the whole budget is one cap on the pool slice instead; see Pool sharing.

> [!WARNING]
> Enforcement under `sysbox-runc` is not verified live yet. docker passes these flags to the runtime as cgroup v2 `io.max` limits; whether Sysbox applies them to the job's cgroup on this WSL kernel, and whether the VHDX's virtual disk honours them, has not been measured. Until a job is observed held at the cap (for example `cat /sys/fs/cgroup/io.max` inside the job, and `iostat` on the host during a build), treat the cap as configured, not proven.

## Pool sharing

`AAP_POOL_SHARING` (`manager.conf` or `limits.conf`) is `slice` (the default) or `fixed`. `fixed` is the split above: each container gets a hard 1/count share of cpus, memory, and IO, and an idle slot's share is unused.

`slice` caps the pool, not the slot. At pool start the manager runs `systemctl set-property --runtime aap-runner-pool.slice` with `CPUQuota=<AAP_JOB_CPUS * 100>%`, `MemoryMax=<AAP_JOB_MEMORY>`, empty `IOReadBandwidthMax=`, `IOWriteBandwidthMax=`, `IOReadIOPSMax=`, and `IOWriteIOPSMax=` (an empty value clears that list), and, when the disk is measured, `IOReadBandwidthMax`, `IOWriteBandwidthMax`, `IOReadIOPSMax`, and `IOWriteIOPSMax` on the work disk at the full pool IO budget (bandwidth in bytes, IOPS = MiB/s * 8). Every job container is created with `--cgroup-parent=aap-runner-pool.slice`, `--cpus` and `--memory` at the pool total as a safety cap, `--memory-reservation` at the 1/count share, the usual `--cpu-shares 512`, and no `--device-*` or `--blkio-weight` flags (`io.bfq.weight` exists only under BFQ; on the VHDX the container would fail at creation). A light job leaves its slack to the others, and one job alone can use the whole pool. Under memory pressure the kernel reclaims first from containers over their reservation. The slice's bandwidth cap is the IO limiter.

The slice is runtime-only (`/run/systemd/system.control/`), so a reboot drops it. The dashes nest it: its cgroup is `aap.slice/aap-runner.slice/aap-runner-pool.slice`. Drain and stop do not stop it; it empties with its jobs. `set-property` overwrites each property it names, and the empty IO values clear a cap from an earlier pool, so there is no `systemctl revert`. A revert drops the drop-ins and systemd re-realizes the slice; on Fresh (2026-10-14) job containers started in that window failed at `docker start` with `io.bfq.weight: no such file or directory`. `set-property` does not start an empty slice, and the slice's cgroup directory can outlive an inactive slice, so the manager always starts it with `systemd-run --collect --wait --slice=aap-runner-pool.slice --unit=aap-runner-pool-probe /bin/true`. It then waits up to 5 s for the slice cgroup to show `cpu.max`, and `io.max` with the cap when there is one, before any slot starts; a timeout is logged and the slots start anyway. A `docker start` that still fails with `io.bfq.weight` in its error is retried once after 2 s and logged as `slice start race, retrying`; any other start failure is not retried. Slice mode needs docker's systemd cgroup driver. The manager reads `docker info --format '{{.CgroupDriver}}'` at pool start; any other driver, or a failed `set-property`, is logged and the pool runs `fixed`. `status.json` `sharing` and the start log line say which mode is running.

Verified in Ubuntu-24.04 (systemd 259) with a throwaway slice: `set-property --runtime` on a slice that was never loaded creates its drop-ins with no unit file and no `daemon-reload`, and the values land in the slice's `cpu.max`, `memory.max`, and `io.max`. A second `set-property` updates a live slice, and `revert` removes the drop-ins. An empty IO value followed by a new one in the same call writes a drop-in that resets the list and then sets it. After `set-property` the slice is inactive; the probe unit starts it, and it stays active with its `cpu.max` and `memory.max` after the probe exits.

> [!WARNING]
> Not verified live: that `sysbox-runc` places a job under `--cgroup-parent=aap-runner-pool.slice` (docker would create `docker-<id>.scope` there), and that the slice's `io.max` holds a job's IO on the WSL VHDX. Until `systemd-cgls` shows the job scopes in the slice and a parallel build is seen held at the budget, treat slice mode as configured, not proven.

## Drain and status

A Windows-side supervisor drives the manager with `wsl -d aap-runner -u root -- <command>`. The manager creates `/run/aap-runner` (root, `0755`) at start.

`aap-runner-manager --drain` creates `/run/aap-runner/drain` and returns. While that file exists no slot starts another job. A running job finishes; then that ephemeral runner is removed by GitHub and its slot exits instead of starting another runner. A runner that is listening with no job is stopped within 5 s: its container is removed, then its registration is deleted. A container created after the drain began is removed before it starts, so it never registers. When every slot has exited the manager removes its status files and exits 0, so `Restart=on-failure` leaves it stopped. The drain file stays; `aap-runner-manager --undrain` removes it before the next start. If the drain file is removed while the manager is still draining, the slots that already stopped start again, so the pool is back to `AAP_RUNNER_COUNT`. SIGTERM still stops every slot at once. `aap-runner-manager --version` prints `aap-runner-manager 2`. Any argument other than none, `--version`, `--drain`, `--undrain`, `--check-limits`, `--reap`, `--measure-io`, `--self-check`, or `--assert-mounts` prints `unknown argument: <arg>` and exits 2 before any docker call; only no argument starts the pool, which first removes every job container.

A runner that is stopped without a job stays registered with GitHub: on SIGTERM the actions/runner listener deletes only its session, and GitHub removes an ephemeral runner only after its job. The manager therefore deletes that registration itself. It reads the runner name from the container's hostname (`aap-crrr-<hostname>`, set by `ephemeral-entry.sh`; it is not the container name), mints an installation token as for the registration token (every bearer token reaches curl on stdin, never in its argv; each call has `--connect-timeout 5` and a `--max-time`), finds the runner with `GET /orgs/<org>/actions/runners?name=<name>`, and sends `DELETE /orgs/<org>/actions/runners/<id>`. A runner that is not listed, or a 404, is already gone. Any other failure is retried once after 5 s, then logged; it never stops the manager, and the token is never logged. This runs on a drain, on SIGTERM or exit for each runner that had no job (all in parallel, at most 25 s, inside `TimeoutStopSec=90`), and when a runner's container ends without a job, for example at the wall clock. A runner killed mid-job by SIGTERM is left to GitHub, and then to the ghost reap.

A ghost runner is a registration with no listener behind it: earlier manager versions killed listeners without deregistering, and a runner killed mid-job leaves one too. The manager reaps them once at pool start, after the slots are launched, and then every 600 s (`REAP_INTERVAL_SECONDS`) from the status tick. The pass runs in the background, at most one at a time, and is stopped after 25 s, so a slow API never holds the tick. It lists `GET /orgs/<org>/actions/runners?per_page=100&page=<n>` until a page has fewer than 100 runners, at most 10 pages, with the same installation token, stdin header, and timeouts. A runner is deleted only when its name starts with `aap-crrr-`, its `labels` include this host's `AAP_RUNNER_BASE_LABEL`, its `status` is `offline`, `busy` is false, and no container on this host has that hostname: `docker ps -a` and the slot files are read after the list, so a runner that is registered but not yet listening is never deleted. If the list or `docker ps` fails, nothing is deleted. The DELETE treats 404 as gone and logs any other code. Each deleted runner gets a `deregistered runner` line, then one `reaped N ghost runners` summary. No pass starts while the drain file exists, a running pass is stopped when a drain starts, and SIGTERM stops a running pass without starting one. `aap-runner-manager --reap` runs one pass in the foreground and exits 0. It needs root, reads `manager.conf` and the key, and starts no pool and removes no container, so it is safe beside a running manager. The reaper is per host by base label: another host in the org registers `aap-crrr-*` runners too, under its own base label, and a runner without this host's base label, or with no labels, is never touched. With no base label loaded, nothing is reaped.

`/run/aap-runner/status.json` is one line, mode `0644`, replaced by rename on every change and every 5 s:

```json
{"state":"running","job":"build","repo":"special-place-ai-heaven/Agent_Army_Professionals","run_url":"https://github.com/special-place-ai-heaven/Agent_Army_Professionals/actions/runs/123456789","busy":1,"updated":1760302800,"runner_count":2,"job_cpus":24,"job_memory":"72g","job_io_mbps":450,"sharing":"slice","schema":4,"sampled_at":1760302790,"pool":{"cpu_cores":6.5,"mem_gib":9.5,"io_mbps":900},"slots":[{"slot":1,"state":"running","job":"build","repo":"special-place-ai-heaven/Agent_Army_Professionals","run_url":"https://github.com/special-place-ai-heaven/Agent_Army_Professionals/actions/runs/123456789","job_url":null,"started_at":1760302500,"cpu_cores":6.2,"mem_gib":9.1},{"slot":2,"state":"idle","job":"","repo":"","run_url":"","job_url":null,"started_at":null,"cpu_cores":0.3,"mem_gib":0.4}],"work_disk_gib":60,"work_disk_free_gb":22,"work_disk_floor_gb":15,"cleaning":false}
```

`state` is `draining` while the drain file exists, else `running` while a slot has a job, else `idle` once a runner listens, else `starting`. `job` is the most recently started running job, or empty. `repo` and `run_url` belong to that same job, or are empty. After the `Running job:` line the manager reads them from the job's own processes inside the container, with no GitHub token: `timeout 10 docker exec <container> sh -c '...'` collects `GITHUB_REPOSITORY`, `GITHUB_RUN_ID`, and `GITHUB_SERVER_URL` from every `/proc/<pid>/environ`. The Runner.Worker and step processes carry them; the Listener does not. It tries up to 6 times, 5 s apart, until `GITHUB_RUN_ID` appears, and never fails the slot. Both fields are published only when the server URL is exactly `https://github.com`, the repository matches `^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$` with no `.` or `..` part, the run id is digits, and no variable has two different values. Otherwise both stay empty. `run_url` is `https://github.com/<repo>/actions/runs/<run_id>`. A job's own steps can set these variables, so treat the fields as display only. They are cleared when the slot leaves `running`, and a result for an earlier job start is never published. `busy` is the number of slots with a job; `updated` is Unix seconds. `runner_count`, `job_cpus`, and `job_memory` are the limits the running manager loaded, after `limits.conf`; `job_memory` is the string as configured. `job_io_mbps` is the per-slot IO cap in MiB/s, or `0` for no cap (see Disk IO cap). `sharing` is `slice` or `fixed` as the pool runs, so `fixed` after a fallback (see Pool sharing). `job_cpus` is a JSON number and can be fractional (`2.5`) when `manager.conf` says so; the supervisor treats a non-integer as unknown. `--check-limits` prints it the same way. There is no `paused` state on this side; paused is a Windows-side state. The job name comes from the runner's own `Running job: <name>` line on `docker start --attach`, not from the GitHub API. A missing file, or an `updated` more than a minute old, means no manager is running.

`schema` is `4`. It adds `work_disk_gib`, `work_disk_free_gb` and `work_disk_floor_gb` from `df -BG` (null when the mount cannot be read) and `cleaning`, which is true while that cleanup runs. Schema 2 had a numeric `slots`, the slot count; `runner_count` carries that now, and `slots` is the per-slot list. It has one entry per configured slot, ordered by `slot`. A slot's `state` is `retired` after it died 5 times fast, else `draining` while the drain file exists, else `running`, `starting`, or `idle` (listening, between jobs, or not started). `job`, `repo`, and `run_url` are that slot's, under the same rules as the top-level fields, and empty unless it runs a job. `started_at` is the Unix second of its `Running job:` line, else `null`. `job_url` is always `null` for now: it needs an extra GitHub App permission. `cpu_cores` and `mem_gib` are the slot's container usage from the last sample, else `null`. Every 10 s (`SAMPLE_INTERVAL_SECONDS`) the status tick starts one `docker stats --no-stream` in the background, bounded by `timeout 20`, with at most one in flight. `CPUPerc` over 100 is cores (`123.45%` is `1.2`), `MemUsage` is the used side in GiB (`B`, `KiB`, `MiB`, `GiB`, `TiB`), both to one decimal; a value docker leaves as `--` is `null`. The manager maps container names to slots through the slot files, skips other containers, and writes `/run/aap-runner/usage`; a sample counts for a slot only while it names that slot's current container. `sampled_at` is that sample's Unix second, or `null` before the first. A failed `docker stats` keeps the previous sample, so an old `sampled_at` means stale usage; it is logged on the 1st, 11th, 21st failure. `pool.cpu_cores` and `pool.mem_gib` sum the slots' usage, `0` when nothing was sampled. `pool.io_mbps` is the IO cap in force: the slice's budget in `slice` sharing, the per-slot cap times the slots in `fixed`, and `null` with no cap or no device.

`/etc/aap-runner/limits.conf` is optional. The Windows supervisor writes it from the tray's settings. It may hold only `AAP_RUNNER_COUNT`, `AAP_JOB_CPUS`, `AAP_JOB_MEMORY`, `AAP_JOB_IO_PERCENT`, and `AAP_POOL_SHARING`, each with a value, and never App ids or any secret. The manager reads it after `manager.conf` with the same `key=value` parser; its values win, and then the usual checks run (count 1 to 5, at least 1 cpu and 1g per slot, the memory and cpu grammar, IO percent 0 to 100 and at least 10 MiB/s per slot, sharing `slice` or `fixed`). Another key, an empty value, a file not owned by root, or a group or world writable mode stops the manager with exit 1. The manager reads it only at start. `aap-runner-manager --check-limits` parses and checks both files, prints `AAP_RUNNER_COUNT=`, `AAP_JOB_CPUS=`, `AAP_JOB_MEMORY=`, `AAP_JOB_IO_PERCENT=`, `AAP_JOB_IO_MBPS=` (per slot, `0` for no cap), and `AAP_POOL_SHARING=` (as configured; the driver check runs only at pool start) lines, and exits 0, or prints the refusal and exits 1. It starts nothing and makes no docker call. The supervisor runs it before restarting the manager.

The compile cache is `/var/lib/ghrunner/sccache`, on the work disk. The manager creates it after the floor check, owned by the image's `runner` uid with mode 0700, and bind-mounts it at `/var/cache/aap-sccache`. The uid is read once at startup with `docker run --rm --network none --entrypoint id <image> -u runner`. Anything other than a plain non-zero integer, or a uid that a distro account already has (`getent passwd`), stops the manager. The Ubuntu 24.04 rootfs ships an `ubuntu` account at uid 1000, the image's `runner` uid, so `--inside-packages` removes it with `userdel -r ubuntu`. Any other account at uid 1000 stops the install. Sysbox mounts host binds ID-mapped, so that host uid is `runner` inside the job. That assumption is verified live after the next install: in a running job, `ls -ln /var/cache/aap-sccache` must show the runner uid and `sccache --show-stats` must report the per-repository cache location.

Each job gets `RUSTC_WRAPPER=sccache`, `SCCACHE_DIR=/var/cache/aap-sccache/default`, and `SCCACHE_CACHE_SIZE=10G`. `ci.yml` moves `SCCACHE_DIR` to `/var/cache/aap-sccache/<owner>_<repo>` before sccache starts. That subdirectory is a convention, not a boundary; see the threat model. Parallel jobs of one repository share that directory; sccache's disk cache takes concurrent writers. The 10G limit is per directory, and each directory counts against `AAP_DISK_FLOOR_GB`. Any job can create more directories, so before each job, and again in the post-job cleanup, the manager measures the tree with `du -sb`. Over 15% of `AAP_WORK_DISK_GIB` it deletes the oldest files until the tree is at or under 80% of that bound. The directory stays. Jobs already running can miss a file that was trimmed. Any repository that runs `cargo` on this runner must install `sccache` (`mozilla-actions/sccache-action`), because `RUSTC_WRAPPER` is set for every job. To clear the cache, stop the manager and remove the directory. To change the size, edit `SCCACHE_CACHE_SIZE` in `manager.sh`. The environment names are whitelisted in `ephemeral-entry.sh`, so this needs the image rebuild below.

## Threat model

| Actor | What we assume | What limits them |
|---|---|---|
| CI job code | Can run whatever the workflow runs, inside one container. Every job on this host shares one cache directory read-write as the runner uid. The per-repository `SCCACHE_DIR` is a convention, not a boundary: any job can write objects that a later job of any repository on this host, including main-branch builds, will link. Fork PRs never run here | One host mount (the compile cache on the work disk, never under `/mnt`), no host docker socket, inner dockerd only, container and its volumes deleted after the job, fork jobs are not scheduled |
| Fork PR | Must not get a runner | Job `if` skips foreign `pull_request` heads. No `pull_request_target`. Org setting keeps fork workflows off. The runner group disallows public repos |
| Stolen App private key | Attacker can mint registration tokens until the key is revoked | The App has org permission **Self-hosted runners: Read and write** and nothing else. It cannot change branch protection, collaborators, or repo settings. The runner group lists selected repos, so a registered runner is not offered to the rest of the org |
| `ghrunner` (uid 1002) | Can log in to the distro | No sudo, not in the `docker` group, no Windows filesystem, no Windows PATH |
| WSLInterop binfmt | Registered VM-wide, including inside this distro | With `interop` off, vsock accept fails, so the binfmt cannot launch a Windows exe. It is left registered because it is not per-distro. It is not a way out |
| `/mnt/wsl` | tmpfs shared by every distro; holds docker-desktop sockets | The manager never bind-mounts `/mnt` or `/mnt/wsl`. It inspects the container and refuses a mount source under `/mnt`. Phase 1's job container had an empty `/mnt` |
| Windows admin | Rob can `wsl -d aap-runner -u root` | That is the operator. The lockdown is for the distro and the job, not for a local admin who already owns the PC |
| Mount task | The only Windows-side component. The installing operator runs it at logon, elevated | WSL is per Windows user, so a SYSTEM task would mount into SYSTEM's WSL VM and miss `aap-runner`. The task runs `wsl --mount --vhd C:\wsl\aap-runner-work.vhdx --bare` and appends that output to `C:\wsl\mount-work-vhdx.log`. UserId is the operator SID resolved at install, `LogonType` is `InteractiveToken`, and `RunLevel` is `HighestAvailable`. There is no boot trigger, because that logon type has no session until the operator logs on. The runner needs that operator logged on, matching WSL. The script, its folder, the task xml, the log, and the VHDX stay writable by SYSTEM and Administrators only. It does not read `C:` free space, the user profile, or write into the distro |

No long-lived runner credential is stored. The registration token is one job. The runner credential file the Actions service writes lives in the container filesystem and is deleted with `docker rm -f`. The App key never enters the job.

Any future deploy secret goes in a GitHub Environment with required reviewers. It does not go on this runner, in the image, in the manager environment, or in a job-level Actions secret.

## Scope decision

The runner group is an **org** group named `aap-crrr`, restricted to the selected AAP private repositories. Public repositories are disallowed.

An org-scoped GitHub App needs only **Self-hosted runners: Read and write**. Repo-scoped ephemeral registration needs repo **Administration: Read and write**, which can change branch protection, collaborators, and settings. That is a strictly larger blast radius if the key leaks. Repo restriction is enforced by the group's selected-repos list. This is the more secure option, so it is the one we use.

`special-place-ai-heaven/symforge` is checked out as a public sibling. It is not a repository that should be selected in this group. Workflows run only on the AAP private repos in the list.

## Org settings checklist

Do this in the org that owns the private AAP repos before starting the manager. The App is created by a human. The private key is delivered out of band. It is not committed.

- [ ] Runner group `aap-crrr` exists.
- [ ] Group access is **Selected repositories**, and the list is the AAP private repos that should run this CI. Public repositories are not selected.
- [ ] "Allow public repositories" is off for the group.
- [ ] Fork pull request workflows from outside collaborators are off (not "require approval").
- [ ] GitHub App is org-owned. Organization permission is **Self-hosted runners: Read and write** only. No Administration, Contents, Secrets, or Actions write on the App.
- [ ] App is installed on the org. Installation id and App id go in `/etc/aap-runner/manager.conf`.
- [ ] Private key is `/etc/aap-runner/app.pem`, owner root, mode `0400`. `ls -l` is the check.
- [ ] `manager.conf` is owner root, mode `0400`.
- [ ] Docker Desktop → WSL integration does **not** include `aap-runner`.
- [ ] `ghrunner` is not in `sudo` or `docker`. `sudo -n -l -U ghrunner` prints `not allowed to run sudo`. An exit status of 0 is not a pass.
- [ ] Sysbox preflight printed `docker info` from inside `--runtime=sysbox-runc`. If it did not, the install stopped and stays stopped.
- [ ] On `special-place-ai-heaven/symforge`, Settings > Actions > General > Access allows `Agent_Army_Professionals`. Then delete the `SYMFORGE_TOKEN` secret from this repo and from the org. The workflow does not read it.
- [ ] `.wslconfig` has no uncommented `networkingMode=mirrored` under `[wsl2]`. The operator distro records the proof before import. Inside `aap-runner`, `wslinfo --networking-mode` matches that proof. A missing `wslinfo` there is a failed install. `HKLM\Software\Policies\WSL\AllowDiskMount` is not 0.
- [ ] `icacls` on `C:\wsl`, `C:\wsl\mount-work-vhdx.ps1`, and `C:\wsl\aap-runner-work.vhdx` lists only SYSTEM and Administrators, and the owner of each path is `BUILTIN\Administrators`.
- [ ] `df` of `/var/lib/containerd`, `/run/containerd`, `/var/lib/sysbox`, and `/var/lib/ghrunner/docker` is the 60 GiB work disk. `/var/lib/sysbox` is a bind mount, not a symlink. `docker info` lists the `sysbox-runc` runtime.
- [ ] Task `AAP-CRRR-Mount-Work-Disk` runs as the installing operator: UserId is that user's SID, `LogonType` is `InteractiveToken`, `RunLevel` is `HighestAvailable`, and the trigger is logon. It is not SYSTEM. The operator must be logged on before the disk is attached. `C:\wsl\mount-work-vhdx.log` contains the `wsl --mount` output.
- [ ] BRUCE has accepted this design. Do not `systemctl start aap-runner-manager` before that.

## Install

The install entry is `install-host.ps1`, from an elevated Windows PowerShell 5.1 or PowerShell 7. It resets `PSModulePath` to the machine value first. `wsl --import`, `wsl --unregister`, `wsl --unmount`, `wsl --shutdown`, and `wsl --mount --vhd --bare` do not need elevation. The same user SID shares one WSL VM either way. Elevation is required because the script locks `C:\wsl` and the VHDX to SYSTEM and Administrators, and the logon task is `HighestAvailable` so it can open that file.

```powershell
powershell -File ops\self-hosted-runner\install-host.ps1 -WorkDiskGiB 100
```

`-DryRun` calls the same preflight from a non-admin shell, prints each `WOULD` step and its `UNDO` command, writes nothing, and exits 0 when every check passed. Not being elevated is `INFO` on a dry run. `-DistroName` and `-WorkVhdx` override the distro and the VHDX path. `-TestMode` uses an unlocked VHDX under the user profile, skips the ACL lock and the boot task, and runs that same path without elevation. Group Policy `AllowDiskMount` is read from `HKLM\Software\Policies\WSL`. A DWORD of 0 fails preflight. Absent or 1 is allowed, which is how WSL reads it.

A re-run keeps going. A registered distro, a matching task XML hash, an already-locked ACL, or `/etc/aap-runner/install.done` is a skipped step. It does not unregister. `UNDO.md` next to the VHDX lists each change and the revert command. The manager unit is disabled and is not started. P0 evidence treats a missing `/etc/aap-runner/app.pem` as the only accepted FAIL. `-KeyPath` is copied to that path as root mode 0400 on stdin, the source file is deleted, and P1 runs. The manager stays disabled.

On the workstation the operator distro still needs `jq` (`sudo apt-get install jq`). Preflight checks for it before anything is written. `bootstrap.sh` with no arguments refuses and names `install-host.ps1`.

`install-host.ps1` runs `bootstrap.sh --preflight`, locks the staging copy after its sha256 check, then `--register-task`, `--format-work-disk`, `wsl --import`, and `--inside-runtime`. The first command inside the new distro is `wsl.exe -d aap-runner -u root --exec /bin/bash <stage>/stage-into-distro.sh <stage> <disk GiB>`. `--exec` passes those paths as arguments. Without it, `wsl.exe` joins the command and the distro shell expands it, which is how an empty `cp` path used to exit 0. A non-zero status from `wsl.exe`, `powershell.exe`, or `schtasks.exe` stops the install. After `--inside-runtime`, bootstrap checks that `/opt/aap-runner/bootstrap.sh` exists, `docker` and sysbox are active, task `AAP-CRRR-Mount-Work-Disk` is registered, and image `aap-crrr-runner:local` is built. The manager unit is disabled there and is not started.

The script downloads three pinned artifacts and checks sha256 before it uses them. Before each download it prints the URL and the expected size (`Content-Length`, or `expected size unknown` when the server does not send one), then shows `curl --progress-bar`. It does not pipe curl into a shell.

| Artifact | URL | sha256 |
|---|---|---|
| Ubuntu 24.04 WSL rootfs | `https://cloud-images.ubuntu.com/wsl/releases/noble/current/ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz` | `8251e27ffff381a4af5f41dcb94d867de3e0d9774a9241908ab34555d99315ea` |
| Sysbox CE 0.7.1 amd64 | `https://github.com/nestybox/sysbox/releases/download/v0.7.1/sysbox-ce_0.7.1.linux_amd64.deb` | `9d6d5484f980d0a17f86c492c1262015c2afb66280bdb97215b79fde6a0261c5` |
| actions-runner 2.338.0 linux-x64 | `https://github.com/actions/runner/releases/download/v2.338.0/actions-runner-linux-x64-2.338.0.tar.gz` | `af4b794c1bc41d73d40535e3fe092a39f9679cd8d965954c2aca25a05ca41d32` |

The rootfs tarball is downloaded into the staging directory beside the VHDX (`C:\wsl\staging` on a normal install). That directory is locked to SYSTEM and Administrators after `staging.sha256` matches, and the tarball sha256 is checked on that copy. `wsl --import` receives that `C:\` path. Importing from `\\wsl.localhost\<the operator distro>\...` stalls, so that path is refused. Staging stays in place so a re-run can hash it again. The import prints `importing aap-runner (this takes ~1-2 min)...` and is limited to 15 minutes; a timeout stops the install. The distro VHDX is created at `C:\aap-runner` (override with `-InstallDir`). That path is outside the Windows user profile. After import the distro cannot mount it back.

If `wsl -l` does not list the distro but `ext4.vhdx` is already in the install directory, preflight fails and does not delete that file.

The fixed VHDX is `AAP_WORK_DISK_GIB` (default 60; Fresh passes `-WorkDiskGiB 100`). `mkfs` runs only when `blkid -p -o export` exits 2. The task xml is written as UTF-16 LE with a BOM, because `schtasks /XML` rejects a UTF-8 file. Registering that task needs an elevated shell because the VHDX is ACL-locked. `-TestMode` does not register it. If Task Scheduler rejects it, the install stops. An earlier `AAP-CRRR-C-Free-GB` task is deleted if it is present. The task runs at the operator's next logon. This session is already mounted by the installer. After a reboot the disk stays unmounted until that operator logs on.

A re-run does not unregister. A registered distro, a task whose xml sha256 matches `mount-work-vhdx-task.xml.prev-hash`, an ACL that is already SYSTEM and Administrators, or `/etc/aap-runner/install.done` is skipped. On an installed distro, the installer compares the repo's `staging.sha256` with the copy `--inside-packages` wrote to `/etc/aap-runner/staging.sha256`. When they differ, or that copy is missing, the plan prints `WOULD upgrade staging.sha256 differs`. The upgrade stops and disables the manager, stages and copies the new files in, re-runs `stage-into-distro.sh` and `--inside-runtime`, and leaves the manager disabled. `manager.conf` and the work disk UUID are kept. There is no automatic undo; to go back, re-run `install-host.ps1` from the previous commit. `UNDO.md` lists `wsl.exe --unregister <distro>` for an import this run actually performed. That command does not unregister Ubuntu, docker-desktop, or any other distro.

After P0, `-KeyPath` installs the key. Fill the empty `AAP_GITHUB_APP_ID` and `AAP_GITHUB_APP_INSTALLATION_ID` in `/etc/aap-runner/manager.conf`. The installer does not start the manager. After BRUCE accepts the design, the operator runs:

```bash
wsl.exe -d aap-runner -u root -- systemctl start aap-runner-manager
```

The unit does not start while `app.pem` is absent.

## Workflow contract

Every job:

- `runs-on: [self-hosted, linux, crrr]`, which selects CRRR only. Fresh is `self-hosted,linux,fresh,heavy` and is not selected. Heavy jobs will later target `fresh`
- skips a `pull_request` whose head repo is not this repo
- starts by refusing unless `AAP_WORK_DISK_GIB` is an integer from 20 to 512 and `df` of the workspace is within that size minus 10 through plus 4 (default 60, so 50–64) with at least `AAP_DISK_FLOOR_GB` free (default max(15 GB, 10% of the disk); a lower configured floor is raised). On the distro, `/var/lib/ghrunner` must also be `work-disk.uuid` and not the device behind `/`
- pins every `uses:` to a 40-character commit SHA, with the version in a comment

Workflow permissions are `{}`. Each job sets `contents: read` and nothing else. No new secret and no new trigger. The SymForge checkout uses the job `GITHUB_TOKEN`. See below.

DB Integration (`timeout-minutes: 45`) runs two service containers on the inner dockerd:

- Oracle MySQL `8.4.11` on port 3306, database `aap`, digest `sha256:6ea90827b1100f8f2ae306a539f86d2c264a26ed435a2a9f75551dd5c3aeb242` (the `8.4.11` manifest list, resolved 2026-10-12). The existing harness uses this and is not pointed at SingleStore.
- SingleStore dev image on port 3307, database `aap_singlestore`, health `start-period` 90s (the image's own check is 90s; the floor is 60s). The tag `latest` resolved on 2026-10-12 to image version `0.2.85` (created 2026-09-22, revision `39175f0b42c96b726eccb9a3b11e2f18dd24305f`), digest `sha256:23c0c5fd0381dae403234437f89b0b5454bd78d385d6201359acfb98d109291f`.

Both `image:` lines carry the tag in a comment and the digest in the reference. A later bump replaces the digest on purpose. It does not float back to `:latest`.

PR #39's known-failure inventory is the workspace, agents, and backend test commands (`--no-fail-fast`, every integration binary, the closing step that fails the job if either step failed) and the DB job's eight harnesses plus the `migration_v2_unit::` skip. Those commands are unchanged. A green DB job still does not count the three isolated migration proofs as passes.

## Pins in the workflow

| Action | Commit | Comment |
|---|---|---|
| `actions/checkout` | `11d5960a326750d5838078e36cf38b85af677262` | v4.4.0 |
| `actions/setup-node` | `49933ea5288caeca8642d1e84afbd3f7d6820020` | v4.4.0 |
| `Swatinem/rust-cache` | `6323deb102c322ba6fcbdcafc7e3dddab59af2b6` | v2.9.2 |
| `dtolnay/rust-toolchain` | `e2a55d2ffb04f378e9626c28d38b36d230d1e12f` | master 2026-10-09, `toolchain: stable` |
| `mozilla-actions/sccache-action` | `fc920bf0ec8de6ee65d409111f7ec508035751ba` | v0.0.11 (annotated tag `fd02668681acd5f960e1372061bee5e3e987195c`), `version: v0.18.0` |

`dtolnay/rust-toolchain` selects the toolchain from the ref when you write `@stable`. A SHA pin does not, so every job sets `toolchain: stable` itself.

## SymForge checkout

`special-place-ai-heaven/symforge` is a public repository. An unauthenticated request for it returns HTTP 200. Every job that needs the sibling checks it out with `token: ${{ github.token }}`, the job `GITHUB_TOKEN`. The workflow does not reference `secrets.SYMFORGE_TOKEN`, so that secret is not sent to the runner.

Owner steps, in this order:

1. Open `special-place-ai-heaven/symforge` → Settings → Actions → General → Access, and allow `Agent_Army_Professionals` (the organization choice that includes that repository).
2. Delete the `SYMFORGE_TOKEN` secret from `Agent_Army_Professionals` and from the `special-place-ai-heaven` organization.

If symforge is made private and the job token still cannot read it after that Access change, stop. Do not put a PAT back into the workflow. `actions/checkout` documents that `github.token` is scoped to the calling repository; the Access setting is what GitHub documents for letting other repositories in the organization reach this repository's actions. A 404 after step 1 is the stop condition, not a reason to restore the secret.

## Actions cache

Jobs do not grant `actions: write`. `Swatinem/rust-cache` and `actions/setup-node` save and restore through the runner runtime token (`ACTIONS_RUNTIME_TOKEN` and `ACTIONS_CACHE_URL`), which the Actions service injects for the cache API. That is not the `GITHUB_TOKEN` `actions` scope and it is not a repository secret.

A job log proves a save in the post-step `Post Cache cargo artifacts` or `Post Setup Node.js`. A save prints `Cache saved with key:`. The next run that hits the same key prints a cache hit in the main step. A line `cache write denied` means the runtime token was read-only for that event. Adding `actions: write` is not the fix.

## Runner image rebuild

`aap-crrr-runner:local` is built once, during bootstrap. It does not rebuild itself. Rebuild it at least every 30 days, and again in the same week `Dockerfile`, `ephemeral-entry.sh`, the actions-runner pin, or the inner dockerd pin changes.

The locked distro cannot see the checkout. From the operator distro, copy the current files into the image context (the two tarballs are already there unless their pins changed), then build:

```bash
img=/var/lib/aap-runner/image
wsl.exe -d aap-runner -u root -- tee "${img}/Dockerfile" < distro/Dockerfile >/dev/null
wsl.exe -d aap-runner -u root -- tee "${img}/ephemeral-entry.sh" < distro/ephemeral-entry.sh >/dev/null
wsl.exe -d aap-runner -u root -- docker build -t aap-crrr-runner:local "${img}"
```

The build runs `apt full-upgrade` for the unpinned packages (`curl`, `git`, `openssl`, `mysql-client`, `ca-certificates`). `docker-ce` stays at the Dockerfile pin `5:27.3.1` until that pin is changed on purpose. The actions-runner tarball is pinned too; `--disableupdate=false` still lets the runner binary update when a job starts. After the build, run the Sysbox preflight above before the manager takes another job. Rebuilding the image does not recreate the VHDX and does not unregister the distro.

## Evidence

After the App key and `manager.conf` are in place:

`aap-runner` has automount off, so it cannot read the Windows profile or run `wsl.exe`. From the operator distro:

```bash
AAP_RUNNERS_READ_TOKEN="$(cat ~/.aap-runners-token)" bash distro/evidence-host.sh
```

That script runs `wsl.exe --version`, reads `%USERPROFILE%\.wslconfig` (or records that the file is absent), fetches the org's registered runners with `GET /orgs/special-place-ai-heaven/actions/runners`, copies those captures into the distro, and runs `aap-runner-evidence`. Evidence prints the wsl text under `HOST-REPORTED (operator-supplied, not verified)`. The distro did not read those files itself, so the printed text is not a verified pass. A missing `wsl --version` capture or a missing `.wslconfig` capture calls `bad` with `host P0 bundle is incomplete`. The rest of the evidence still prints, and the script exits non-zero. An operator-captured `absent` marker for `.wslconfig` is the Windows NAT default and is printed as `wslconfig: absent`. The registered-runner list (name, status, labels) is printed in that same bundle so it can be compared with `manager.conf`. A missing `gh` or a failed request is written into the list and does not by itself fail evidence. The App private key, the registration token, and the runners read token are not printed.

The runners fetch does not use `gh auth login` and does not use whatever account `gh` is already logged in as. It reads `AAP_RUNNERS_READ_TOKEN` and passes that value as `GH_TOKEN` for the one `gh api` call. If the variable is missing, the bundle records `runners fetch: skipped (no AAP_RUNNERS_READ_TOKEN)` and evidence continues.

Create that token as a fine-grained personal access token. Resource owner: `special-place-ai-heaven`. Organization permission: **Self-hosted runners: Read**. Every other organization permission, and every repository permission, stays at no access. Repository access can be public repositories only. If the organization requires approval of fine-grained tokens, an owner approves it before the fetch works. Set an expiry and rotate it. Save it as `~/.aap-runners-token` with mode 600 (`chmod 600 ~/.aap-runners-token`). Run evidence with that file for the one command:

```bash
AAP_RUNNERS_READ_TOKEN="$(cat ~/.aap-runners-token)" bash evidence-host.sh
```

Do not `export` the token into the shell. Do not put it in `manager.conf` or in the distro.

The script prints `uname -r`, then the host-reported `wsl --version` and `.wslconfig`. A missing capture fails, as above. It also prints the GitHub registered-runner list from that capture. It prints the final runner label line and refuses unless that line is `self-hosted,linux,<base>[,extras]` with base `crrr` or `fresh`. On the distro it checks that no `drvfs` or `9p` Windows drive is mounted (`/mnt/wsl` and `/mnt/wslg` are WSL tmpfs and are not a failure), whether `cmd.exe` can run, `nft list ruleset`, `wslinfo --networking-mode`, the bridge `EnableIPv6`, `id ghrunner`, the `ghrunner` sudo listing, `df` of the containerd root, containerd state, sysbox bind, and Docker root (all must be the work disk), `sysbox-runc` in `docker info`, and `stat` of `/etc/aap-runner/app.pem` and `/etc/aap-runner/manager.conf`. It then starts one Sysbox container with the job memory, cpu, and pids limits and no host mounts. From inside that container it prints the container gateway, `AAP_WINDOWS_HOST_IP` (the distro default route), whether `/mnt` is empty, and the result of connecting to that gateway, that Windows host IP, `192.168.1.1`, and `fd00:aaaa::1` (those four must fail) plus `https://github.com/` (that must succeed). It exits non-zero when any of those observations is missing or wrong. It does not mint a registration token and it does not print the App key.
