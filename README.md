# Ephemeral self-hosted runner (`aap-crrr`)

CI jobs in `.github/workflows/ci.yml` target a self-hosted runner instead of GitHub-hosted `ubuntu-latest`. GitHub-hosted minutes for the org are exhausted until 1 November. Nothing in this directory registers a runner or contacts the workstation. Rob runs the bootstrap on that PC after BRUCE accepts this design. Until the runner is online, the workflow is queued and does not run.

The acceptance gate is a parity run on this runner whose failure names are exactly PR #39's known registry: 0 new, 0 stale. The test commands that produce that inventory are unchanged.

## Layout

| File | Role |
|---|---|
| `wsl.conf` | Lockdown for the `aap-runner` distro, including `systemd=true` |
| `bootstrap.sh` | Import Ubuntu 24.04, install Docker Engine and Sysbox, stop if Sysbox fails |
| `manager.sh` | Root loop: one fresh container, one job, then remove it |
| `aap-runner-manager.service` | systemd unit for that loop |
| `nftables.conf` | Best-effort egress drop for LAN, link-local, CGNAT, and the other non-global ranges |
| `manager.conf.example` | Schema for `/etc/aap-runner/manager.conf`. No secrets |
| `Dockerfile` | Job image: inner dockerd 27.3.1, build-essential, mysql-client, no sudo |
| `ephemeral-entry.sh` | Starts inner dockerd, registers ephemeral, runs one job |
| `create-work-vhdx.ps1` | One-time 60 GiB fixed VHDX: `New-VHD -Fixed`, or diskpart if that cmdlet is absent |
| `mount-work-vhdx.ps1` | Operator logon task: `wsl --mount --vhd <path> --bare`, log appended under `C:\wsl` |
| `mount-work-vhdx-task.xml` | That operator's SID, `InteractiveToken`, `HighestAvailable`, logon trigger. Installed as UTF-16 LE |
| `mount-work-disk.sh` | Mount the ext4 at `/var/lib/ghrunner`, then bind containerd and sysbox onto it |
| `aap-workdisk.service` | Runs that mount before containerd, Docker, and Sysbox |
| `daemon.json` | Keys merged into the live daemon.json: `data-root` and `ipv6`. Runtimes are kept |
| `docker-workdisk.conf` | Drop-in for docker, containerd, and sysbox: start only after the work disk is mounted |
| `evidence.sh` | Prints the lockdown observations. Installed as `/usr/local/sbin/aap-runner-evidence` |
| `evidence-host.sh` | From the operator distro, passes `wsl --version` and `.wslconfig` into that script |
| `lock-acl.ps1` | DACL for the boot-task folder, script, and VHDX: SYSTEM and Administrators only, owner Administrators |

`bash bootstrap.sh --self-check`, `bash manager.sh --self-check`, `bash evidence.sh --self-check`, `bash mount-work-disk.sh --self-check`, and `bash evidence-host.sh --self-check` check the checksum, disk-floor, limit, route, sudo-listing, daemon.json merge, base-label, and bind-staging parsers, the cases where a missing `wslinfo` or an unreadable `.wslconfig` must stop the install, and that the mount task is rendered for a user SID as UTF-16 LE. They do not touch WSL.

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

Each job is a new container started with `--runtime=sysbox-runc`. That container has no host mount and no host docker socket. The inner dockerd is 27.3.1 (`docker-ce=5:27.3.1-1~ubuntu.24.04~noble`, containerd.io `1.7.29-1~ubuntu.24.04~noble`). Phase 1 ran MySQL 8.4, which is 8.4.11, on `127.0.0.1:3306` from that inner daemon and reached it from the job container. Service containers stay on that inner dockerd.

Service images are pulled by that inner dockerd on every job. A pre-seeded tarball does not stop the pull. `ci.yml` pins the multi-arch index digest (`image@sha256:…`). `docker save` / `docker load` keeps the platform image and drops the index digest, so the inner daemon still fetches the digest the workflow names. A host mount of a cache would break the no-host-mount rule. A registry on the host is behind the bridge filter, which drops the gateway and RFC1918 on purpose. The pull is network time and bandwidth. The unpacked layers live in the job container's writable layer, which is on the work disk, and `docker rm -f` deletes them with the container. They do not accumulate on the distro root.

`ghrunner` is the distro login, uid 1002. It is not in `sudo` or `docker`. `sudo -n -l -U ghrunner` must print `not allowed to run sudo`. sudo 1.9.15p5 exits 0 for that denial, so the exit status is not the check. The manager is a root systemd service. The in-container user `runner` is a different account. It is in the container's `docker` group so it can talk to the inner socket, and it has no sudo. The image includes `build-essential`, `pkg-config`, `libdbus-1-dev`, `mysql-client`, `tar`, `xz-utils`, and `unzip` because the job cannot `apt-get`. `scripts/check-workspace-lints.sh` is bash and awk, which the image already has.

## Registration

The manager reads `/etc/aap-runner/manager.conf` (mode `0400`, root) and the App private key at `/etc/aap-runner/app.pem` (mode `0400`, root). Both must stay mode `0400` or the manager exits. The key is held in the manager process only. It is not mounted into the job container and it is not placed in the job environment.

For each job the manager:

1. Refuses to start unless `/var/lib/ghrunner` is a mountpoint, its source device is not the device behind `/`, and its filesystem UUID equals `/etc/aap-runner/work-disk.uuid`. `df` size must also sit within `AAP_WORK_DISK_GIB` minus 10 GiB through plus 4 GiB. That size is an integer from 20 to 512 (default 60, so 50–64). Free space must be at least `AAP_DISK_FLOOR_GB`. That floor defaults to 35 GB on a 60 GiB disk. A configured floor below 55% of the disk size is raised (100 GiB becomes 55). 60 GiB stays at 35. A ~1000G distro VHD fails the UUID check and the 512 cap.
2. Mints a short-lived registration token: App JWT, installation token, then `POST /orgs/{org}/actions/runners/registration-token`. The token stays in memory. It is passed to the container on stdin and unset before `run.sh`.
3. Starts a container with no `-v`, no `--privileged`, and no `/var/run/docker.sock`. `docker create` passes `--memory`, `--memory-swap` equal to that memory, `--cpus`, `--cpu-shares 512`, and `--pids-limit` from this host's `manager.conf`. Swap equal to memory means the job gets no extra swap, so it cannot spill into swap and freeze the host. `--cpu-shares 512` is half the default weight. It only orders containers against each other inside this WSL VM. The `.wslconfig` `memory` and `processors` caps are what keep Windows responsive. CRRR65734 sets `12g` and `6`. A missing key uses those same values. A second host writes its own memory, cpu, and pid numbers in its own `manager.conf`. The same `docker create` passes `AAP_WORK_DISK_GIB` and `AAP_DISK_FLOOR_GB` into the container, and the entry script keeps those two names for `run.sh`, so the workflow's `df` uses this host's disk. A wall clock (`AAP_JOB_TIMEOUT_MINUTES`, default 120, maximum 1440) then stops and removes the container if it is still there. 120 is longer than the longest job `timeout-minutes` (90), so a job that finishes is not cut off by the clock. The clock process does not receive the registration token.

Labels passed to `config.sh` are `self-hosted,linux` plus `AAP_RUNNER_BASE_LABEL`, plus `AAP_RUNNER_EXTRA_LABELS` when that host sets it. The base is required and is `crrr` or `fresh`. An empty or missing base stops the manager, bootstrap, and evidence. CRRR sets `crrr` and registers `self-hosted,linux,crrr`. Fresh sets `fresh` and `heavy`, and registers `self-hosted,linux,fresh,heavy`. An extra label of `crrr`, `fresh`, `self-hosted`, or `linux` is refused. The manager logs `runner labels:` before it mints a registration token. `ci.yml` stays on `[self-hosted, linux, crrr]`, so Fresh does not take those jobs. A later heavy job will target `fresh`.

```text
config.sh --unattended --ephemeral --disableupdate=false \
  --labels self-hosted,linux,crrr --runnergroup aap-crrr
```

`--url` and `--token` are required for that command to register. `--disableupdate=false` leaves runner self-update on, as specified.
4. Waits for the ephemeral runner to exit after one job.
5. `docker rm -f` the container, deletes its network, and prunes volumes and networks labeled `aap-crrr-job=1`. The workspace lives only in the container, so removing the container wipes it. There is no host workspace directory.

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

Bootstrap refuses the install when `wslinfo --networking-mode` prints `mirrored`, and when the Windows user's `.wslconfig` contains `networkingMode=mirrored`. Inside `aap-runner` it also refuses when `wslinfo` is missing or prints nothing. On the operator distro it refuses when `.wslconfig` exists but cannot be read. An absent `.wslconfig` is the Windows NAT default. Mirrored mode puts this distro on the Windows LAN. This table does not see that traffic. Leave WSL on NAT.

The distro `daemon.json` sets `"ipv6": false`. After dockerd starts, bootstrap reads `docker network inspect bridge` and stops unless `EnableIPv6` is `false`. Each job's inner dockerd writes the same file before it listens, and the entry script stops that job if the inner bridge is not `false`.

This is best-effort LAN isolation. It covers bridge egress from this distro. It does not cover the WSL2 virtual switch on the Windows host, and a process inside the Sysbox container that can reconfigure its own network namespace is outside the host table. Do not open these prefixes because a job cannot reach GitHub: GitHub's addresses are public, so a drop here is not the cause.

## Disk floor

The work disk is a **fixed VHDX** at `C:\wsl\aap-runner-work.vhdx`. CRRR is 60 GiB (`AAP_WORK_DISK_GIB=60`). Fresh is 100 GiB. Fixed means the file cannot grow, so job layers cannot grow into `C:`. `df` of that ext4 is the free space. `df /` on the distro root is still the distro VHD's maximum (1 TB on this PC) and is not a guard.

Bootstrap creates the file once, from an elevated shell:

```powershell
New-VHD -Path C:\wsl\aap-runner-work.vhdx -SizeBytes 60GB -Fixed
```

`New-VHD` is a Hyper-V cmdlet. When it is absent, the same script uses diskpart. `maximum=` is MiB (`AAP_WORK_DISK_GIB * 1024`). For the 60 GiB default that is `61440`, the same size as PowerShell's `60GB`. A 100 GiB disk is `102400` MiB. Bootstrap passes `-SizeGiB` from `AAP_WORK_DISK_GIB` (default 60):

```text
create vdisk file="C:\wsl\aap-runner-work.vhdx" maximum=61440 type=fixed
```

It then attaches the disk with `wsl --mount --vhd C:\wsl\aap-runner-work.vhdx --bare` and formats the whole disk ext4. The UUID is stored at `/etc/aap-runner/work-disk.uuid`.

When the installing operator logs on, task `AAP-CRRR-Mount-Work-Disk` runs as that operator, elevated (`HighestAvailable`), and runs only `wsl --mount --vhd <that path> --bare`. WSL is per Windows user. The same command running as SYSTEM attaches the disk to SYSTEM's WSL VM, and `aap-runner` is not in that VM, so the task is not SYSTEM. There is no boot trigger: `InteractiveToken` has no session until that operator logs on, and a boot task cannot see this user's WSL. The runner is available after the operator logs on, which is the same condition WSL itself needs. The script appends the command output to `C:\wsl\mount-work-vhdx.log`. Inside `aap-runner`, `aap-mount-work-disk` mounts that UUID at `/var/lib/ghrunner`. `mountFsTab=false` stops WSL from processing fstab; the line is still there with `nofail` for systemd, and the service retries until the UUID appears. `mountpoint -q` failing exits the mount script, and docker.service has `ConditionPathIsMountPoint=/var/lib/ghrunner`, so dockerd does not start on the distro root.

`lock-acl.ps1` clears inheritance and leaves only `S-1-5-18` (SYSTEM) and `S-1-5-32-544` (Administrators), full control, on `C:\wsl`, `C:\wsl\mount-work-vhdx.ps1`, `C:\wsl\mount-work-vhdx-task.xml`, and `C:\wsl\aap-runner-work.vhdx`. It sets the owner of each of those paths to Administrators (`S-1-5-32-544`) and reads the owner back. Any other owner, or a non-admin ACE, fails the install. The directory ACEs inherit onto children, including `C:\wsl\mount-work-vhdx.log`. The task principal is the installing operator, not SYSTEM. That account is not given its own ACE: the task runs elevated, so the Administrators ACE covers it. Bootstrap runs that script after it creates the VHDX and again after it writes the logon script. Check with `icacls C:\wsl`, `icacls C:\wsl\mount-work-vhdx.ps1`, and `icacls C:\wsl\aap-runner-work.vhdx`. Each list should name only SYSTEM and Administrators, and the owner should be `BUILTIN\Administrators`.

`/var/lib/ghrunner/docker` is dockerd's `data-root`. Docker 29 keeps images and container snapshots in containerd's root, `/var/lib/containerd`, and that path ignores `data-root`. The mount script bind-mounts `/var/lib/ghrunner/containerd` onto `/var/lib/containerd` and `/var/lib/ghrunner/containerd-state` onto `/run/containerd`, so the image store is on the work disk whichever snapshotter is active. A partial `/etc/containerd/config.toml` is not written: that file replaces containerd's compiled defaults. The bind covers the default path instead. Stale containerd sockets are removed only when containerd is not running.

Sysbox's host state is a bind of `/var/lib/ghrunner/sysbox` onto `/var/lib/sysbox`. A symlink does not survive: `sysbox-mgr`'s postinst recreates `/var/lib/sysbox` as a directory. The boot unit runs the bind before containerd, Docker, and Sysbox start, and bootstrap runs it again after the package install. The inner dockerd's data is inside the job container's writable layer, so it is on the same ext4. The distro root VHD still holds the OS packages. It does not hold images or job layers.

Bootstrap merges `daemon.json` into `/etc/docker/daemon.json` with jq. `data-root` and `ipv6` are set from the template. A `runtimes` object already in the file, including `sysbox-runc`, is kept. Replacing the file drops that runtime. After dockerd starts, bootstrap requires `sysbox-runc` in `docker info` runtimes and requires `df` of `/var/lib/containerd`, `/run/containerd`, `/var/lib/sysbox`, and the Docker root to be the work disk.

`AAP_WORK_DISK_GIB` is an integer from 20 to 512. `df -BG` of the ext4 is a few GiB under the VHDX, so the manager, the mount script, evidence, and each job accept size minus 10 through plus 4. 60 accepts 50–64. 100 accepts 90–104. 513 is refused, so a ~1000G filesystem cannot fall in the window. The size window is not the only guard: the manager, the mount script, and evidence require the source device of `/var/lib/ghrunner` to differ from `/` and its filesystem UUID to equal `/etc/aap-runner/work-disk.uuid`. The manager runs `df -BG --output=avail /var/lib/ghrunner` and refuses a job below `AAP_DISK_FLOOR_GB`. That floor is at least 55% of the disk, rounded up. 60 GiB stays at **35 GB free**, because 55% of 60 is 33 and the CRRR budget is already 35. 100 GiB is **55 GB free**. A configured floor below that minimum is raised (a copied `35` on a 100 GiB disk becomes 55). A higher explicit floor is kept. It also refuses when `mountpoint -q` fails. Each job's first step runs the same `df` on `$GITHUB_WORKSPACE`, using `AAP_WORK_DISK_GIB` and `AAP_DISK_FLOOR_GB` from the job environment. Absent values are 60 and 35, which is CRRR. That directory is on the container root, whose overlay upper dir is the docker data-root, so it is the same filesystem.

35 GB is the free-space budget for one job on the 60 GiB disk after the runner image and Sysbox state are on the disk. Full debuginfo on a hosted runner failed at about 140 GB (`ld: No space left on device` in the workflow comment). This CI uses line-tables-only and `CARGO_INCREMENTAL=0`. Campaign `cargo clean` notes in the repo removed 15.9 GiB, 36.6 GiB, and 41.5 GiB of warm incremental trees. Those trees are larger than one fresh job. 35 GB free is enough for the smaller trees on CRRR and is the point where a new job is refused. A job that needs more than what remains fills this disk and stops. It does not extend `C:`.

Creating the VHDX needs `AAP_WORK_DISK_GIB` gigabytes free on `C:` at that moment, measured from the operator distro's `/mnt/c`. The default is 60. That check allocates the file. It is not the per-job floor.

The hosted-runner toolchain-delete step is gone. `CARGO_INCREMENTAL=0` and line-tables-only debug stay.

## Fresh profile

Fresh has 93 GB of RAM and 32 threads. CRRR stays at the defaults in `manager.conf.example`: 60 GiB disk, 35 GB free, `12g`, 6 cpus, 4096 pids, and no extra labels. Fresh is a second `manager.conf`, not a change to those defaults. Both hosts still get `--memory-swap` equal to their own `--memory`, and `--cpu-shares 512`.

Install the work disk at 100 GiB from the operator distro:

```bash
AAP_WORK_DISK_GIB=100 bash ops/self-hosted-runner/bootstrap.sh
```

That writes `AAP_WORK_DISK_GIB=100` into a new `/etc/aap-runner/manager.conf` and raises `AAP_DISK_FLOOR_GB` from 35 to 55. An existing conf is left as it is. `df` then accepts 90–104 GB.

After install, set the job limits and labels in that conf:

```text
AAP_WORK_DISK_GIB=100
AAP_DISK_FLOOR_GB=55
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

## Threat model

| Actor | What we assume | What limits them |
|---|---|---|
| CI job code | Can run whatever the workflow runs, inside one container | No host mount, no host docker socket, inner dockerd only, container and its volumes deleted after the job, fork jobs are not scheduled |
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
- [ ] `.wslconfig` does not set `networkingMode=mirrored`. `wslinfo --networking-mode` is not `mirrored`. Inside `aap-runner`, a missing `wslinfo` is a failed install, and an unreadable `.wslconfig` is a failed install.
- [ ] `icacls` on `C:\wsl`, `C:\wsl\mount-work-vhdx.ps1`, and `C:\wsl\aap-runner-work.vhdx` lists only SYSTEM and Administrators, and the owner of each path is `BUILTIN\Administrators`.
- [ ] `df` of `/var/lib/containerd`, `/run/containerd`, `/var/lib/sysbox`, and `/var/lib/ghrunner/docker` is the 60 GiB work disk. `/var/lib/sysbox` is a bind mount, not a symlink. `docker info` lists the `sysbox-runc` runtime.
- [ ] Task `AAP-CRRR-Mount-Work-Disk` runs as the installing operator: UserId is that user's SID, `LogonType` is `InteractiveToken`, `RunLevel` is `HighestAvailable`, and the trigger is logon. It is not SYSTEM. The operator must be logged on before the disk is attached. `C:\wsl\mount-work-vhdx.log` contains the `wsl --mount` output.
- [ ] BRUCE has accepted this design. Do not `systemctl start aap-runner-manager` before that.

## Install

On the workstation, from the existing Ubuntu distro (the one that still has `/mnt/c`), with the repo checked out:

```bash
bash ops/self-hosted-runner/bootstrap.sh
```

The script downloads three pinned artifacts and checks sha256 before it uses them. It does not pipe curl into a shell.

| Artifact | URL | sha256 |
|---|---|---|
| Ubuntu 24.04 WSL rootfs | `https://cloud-images.ubuntu.com/wsl/releases/noble/current/ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz` | `8251e27ffff381a4af5f41dcb94d867de3e0d9774a9241908ab34555d99315ea` |
| Sysbox CE 0.7.1 amd64 | `https://github.com/nestybox/sysbox/releases/download/v0.7.1/sysbox-ce_0.7.1.linux_amd64.deb` | `9d6d5484f980d0a17f86c492c1262015c2afb66280bdb97215b79fde6a0261c5` |
| actions-runner 2.338.0 linux-x64 | `https://github.com/actions/runner/releases/download/v2.338.0/actions-runner-linux-x64-2.338.0.tar.gz` | `af4b794c1bc41d73d40535e3fe092a39f9679cd8d965954c2aca25a05ca41d32` |

The VHDX is imported at `C:\aap-runner` (override with `AAP_RUNNER_INSTALL_DIR`). That path is outside the Windows user profile. After import the distro cannot mount it back.

Bootstrap creates the fixed VHDX at `AAP_WORK_DISK_GIB` (default 60), formats it, and registers `AAP-CRRR-Mount-Work-Disk` for the installing operator. The task xml is written as UTF-16 LE with a BOM, because `schtasks /XML` rejects a UTF-8 file. Registering that task needs an elevated shell. If Task Scheduler rejects it, the install stops. An earlier `AAP-CRRR-C-Free-GB` task is deleted if it is present. The task runs at the operator's next logon. This session is already mounted by bootstrap itself. After a reboot the disk stays unmounted until that operator logs on.

Bootstrap will refuse to start if `aap-runner` already exists. Unregister is a human decision: `wsl.exe --unregister aap-runner`.

After a successful preflight, place the key and fill the empty `AAP_GITHUB_APP_ID` and `AAP_GITHUB_APP_INSTALLATION_ID` in `/etc/aap-runner/manager.conf`. Then:

```bash
wsl.exe -d aap-runner -u root -- systemctl start aap-runner-manager
```

The unit does not start while `app.pem` is absent.

## Workflow contract

Every job:

- `runs-on: [self-hosted, linux, crrr]`, which selects CRRR only. Fresh is `self-hosted,linux,fresh,heavy` and is not selected. Heavy jobs will later target `fresh`
- skips a `pull_request` whose head repo is not this repo
- starts by refusing unless `AAP_WORK_DISK_GIB` is an integer from 20 to 512 and `df` of the workspace is within that size minus 10 through plus 4 (default 60, so 50–64) with at least `AAP_DISK_FLOOR_GB` free (default 35; raised to 55% of a larger disk). On the distro, `/var/lib/ghrunner` must also be `work-disk.uuid` and not the device behind `/`
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
wsl.exe -d aap-runner -u root -- tee "${img}/Dockerfile" < ops/self-hosted-runner/Dockerfile >/dev/null
wsl.exe -d aap-runner -u root -- tee "${img}/ephemeral-entry.sh" < ops/self-hosted-runner/ephemeral-entry.sh >/dev/null
wsl.exe -d aap-runner -u root -- docker build -t aap-crrr-runner:local "${img}"
```

The build runs `apt full-upgrade` for the unpinned packages (`curl`, `git`, `openssl`, `mysql-client`, `ca-certificates`). `docker-ce` stays at the Dockerfile pin `5:27.3.1` until that pin is changed on purpose. The actions-runner tarball is pinned too; `--disableupdate=false` still lets the runner binary update when a job starts. After the build, run the Sysbox preflight above before the manager takes another job. Rebuilding the image does not recreate the VHDX and does not unregister the distro.

## Evidence

After the App key and `manager.conf` are in place:

`aap-runner` has automount off, so it cannot read the Windows profile or run `wsl.exe`. From the operator distro:

```bash
bash ops/self-hosted-runner/evidence-host.sh
```

That script runs `wsl.exe --version`, reads `%USERPROFILE%\.wslconfig` (or records that the file is absent), copies both into the distro, and runs `aap-runner-evidence`. Evidence prints that text under `HOST-REPORTED (operator-supplied, not verified)`. The distro did not read those files itself, so the section is not a pass and a missing file does not fail evidence. An absent `.wslconfig` is the Windows NAT default and is printed as `wslconfig: absent`.

The script prints `uname -r`, then the host-reported `wsl --version` and `.wslconfig` when they were supplied. It prints the final runner label line and refuses unless that line is `self-hosted,linux,<base>[,extras]` with base `crrr` or `fresh`. On the distro it checks that no `drvfs` or `9p` Windows drive is mounted (`/mnt/wsl` and `/mnt/wslg` are WSL tmpfs and are not a failure), whether `cmd.exe` can run, `nft list ruleset`, `wslinfo --networking-mode`, the bridge `EnableIPv6`, `id ghrunner`, the `ghrunner` sudo listing, `df` of the containerd root, containerd state, sysbox bind, and Docker root (all must be the work disk), `sysbox-runc` in `docker info`, and `stat` of `/etc/aap-runner/app.pem` and `/etc/aap-runner/manager.conf`. It then starts one Sysbox container with the job memory, cpu, and pids limits and no host mounts. From inside that container it prints the container gateway, `AAP_WINDOWS_HOST_IP` (the distro default route), whether `/mnt` is empty, and the result of connecting to that gateway, that Windows host IP, `192.168.1.1`, and `fd00:aaaa::1` (those four must fail) plus `https://github.com/` (that must succeed). It exits non-zero when any of those observations is missing or wrong. It does not mint a registration token and it does not print the App key.
