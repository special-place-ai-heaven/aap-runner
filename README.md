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
| `Dockerfile` | Job image: inner dockerd 27.3.1, mysql-client, no sudo |
| `ephemeral-entry.sh` | Starts inner dockerd, registers ephemeral, runs one job |
| `create-work-vhdx.ps1` | One-time 60 GiB fixed VHDX: `New-VHD -Fixed`, or diskpart if that cmdlet is absent |
| `mount-work-vhdx.ps1` | Boot task: `wsl --mount --vhd <path> --bare` and nothing else |
| `mount-work-vhdx-task.xml` | SYSTEM at startup, for that one command |
| `mount-work-disk.sh` | Inside the distro: mount the ext4 by UUID at `/var/lib/ghrunner` |
| `aap-workdisk.service` | Runs that mount before Docker and Sysbox |
| `daemon.json` | dockerd `data-root` `/var/lib/ghrunner/docker`, `ipv6` false |
| `docker-workdisk.conf` | docker.service drop-in: do not start unless that path is a mount |
| `evidence.sh` | Prints the lockdown observations. Installed as `/usr/local/sbin/aap-runner-evidence` |
| `lock-acl.ps1` | DACL for the boot-task folder, script, and VHDX: SYSTEM and Administrators only, owner Administrators |

`bash bootstrap.sh --self-check`, `bash manager.sh --self-check`, and `bash evidence.sh --self-check` check the checksum, disk-floor, limit, and route parsers, and the cases where a missing `wslinfo` or an unreadable `.wslconfig` must stop the install. They do not touch WSL.

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

`ghrunner` is the distro login, uid 1002. It is not in `sudo` or `docker`, and `sudo -l` for it must fail. The manager is a root systemd service. The in-container user `runner` is a different account. It is in the container's `docker` group so it can talk to the inner socket, and it has no sudo. `mysql-client`, `libdbus-1-dev`, and `pkg-config` are in the image because the job cannot `apt-get`.

## Registration

The manager reads `/etc/aap-runner/manager.conf` (mode `0400`, root) and the App private key at `/etc/aap-runner/app.pem` (mode `0400`, root). Both must stay mode `0400` or the manager exits. The key is held in the manager process only. It is not mounted into the job container and it is not placed in the job environment.

For each job the manager:

1. Refuses to start unless `/var/lib/ghrunner` is a mountpoint, `df` reports that filesystem as the 60 GiB work disk, and at least 35 GB is free.
2. Mints a short-lived registration token: App JWT, installation token, then `POST /orgs/{org}/actions/runners/registration-token`. The token stays in memory. It is passed to the container on stdin and unset before `run.sh`.
3. Starts a container with no `-v`, no `--privileged`, and no `/var/run/docker.sock`. `docker create` passes `--memory`, `--cpus`, and `--pids-limit` from `manager.conf`. The defaults are `12g`, `6`, and `4096`. A wall clock (`AAP_JOB_TIMEOUT_MINUTES`, default 120, maximum 1440) then stops and removes the container if it is still there. 120 is longer than the longest job `timeout-minutes` (90), so a job that finishes is not cut off by the clock. The clock process does not receive the registration token.

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

The work disk is a **60 GiB fixed VHDX** at `C:\wsl\aap-runner-work.vhdx`. Fixed means the file cannot grow, so job layers cannot grow into `C:`. `df` of that ext4 is the free space. `df /` on the distro root is still the distro VHD's maximum (1 TB on this PC) and is not a guard.

Bootstrap creates the file once, from an elevated shell:

```powershell
New-VHD -Path C:\wsl\aap-runner-work.vhdx -SizeBytes 60GB -Fixed
```

`New-VHD` is a Hyper-V cmdlet. When it is absent, the same script uses diskpart. `maximum=61440` is 61440 MiB, which is 60 GiB, the same size as PowerShell's `60GB`:

```text
create vdisk file="C:\wsl\aap-runner-work.vhdx" maximum=61440 type=fixed
```

It then attaches the disk with `wsl --mount --vhd C:\wsl\aap-runner-work.vhdx --bare` and formats the whole disk ext4. The UUID is stored at `/etc/aap-runner/work-disk.uuid`.

At every boot, task `AAP-CRRR-Mount-Work-Disk` runs as SYSTEM and runs only `wsl --mount --vhd <that path> --bare`. Inside `aap-runner`, `aap-mount-work-disk` mounts that UUID at `/var/lib/ghrunner`. `mountFsTab=false` stops WSL from processing fstab; the line is still there with `nofail` for systemd, and the service retries until the UUID appears. `mountpoint -q` failing exits the mount script, and docker.service has `ConditionPathIsMountPoint=/var/lib/ghrunner`, so dockerd does not start on the distro root.

`lock-acl.ps1` clears inheritance and leaves only `S-1-5-18` (SYSTEM) and `S-1-5-32-544` (Administrators), full control, on `C:\wsl`, `C:\wsl\mount-work-vhdx.ps1`, `C:\wsl\mount-work-vhdx-task.xml`, and `C:\wsl\aap-runner-work.vhdx`. It sets the owner of each of those paths to Administrators (`S-1-5-32-544`) and reads the owner back. Any other owner, or a non-admin ACE, fails the install. The directory ACEs inherit onto children. Bootstrap runs that script after it creates the VHDX and again after it writes the boot script. Check with `icacls C:\wsl`, `icacls C:\wsl\mount-work-vhdx.ps1`, and `icacls C:\wsl\aap-runner-work.vhdx`. Each list should name only SYSTEM and Administrators, and the owner should be `BUILTIN\Administrators`.

`/var/lib/ghrunner/docker` is dockerd's `data-root`. Job container layers, including the Actions workspace, live there. Sysbox's host state is `/var/lib/sysbox`, replaced with a symlink onto `/var/lib/ghrunner/sysbox` before Sysbox is started. The inner dockerd's data is inside the job container's writable layer, so it is on the same ext4. The distro root VHD still holds the OS packages. It does not hold images or job layers.

The floor is **35 GB free** (`AAP_DISK_FLOOR_GB=35`). The manager runs `df -BG --output=avail /var/lib/ghrunner` and refuses a job below that. It also refuses when `mountpoint -q` fails, or when `df` size is outside 50–64 GB, which is how a glance at the 1 TB distro VHD fails closed. Each job's first step runs the same `df` on `$GITHUB_WORKSPACE`. That directory is on the container root, whose overlay upper dir is the docker data-root, so it is the same filesystem.

35 GB is the free-space budget for one job after the runner image and Sysbox state are on the disk. Full debuginfo on a hosted runner failed at about 140 GB (`ld: No space left on device` in the workflow comment). This CI uses line-tables-only and `CARGO_INCREMENTAL=0`. Campaign `cargo clean` notes in the repo removed 15.9 GiB, 36.6 GiB, and 41.5 GiB of warm incremental trees. Those trees are larger than one fresh job. 35 GB free is enough for the smaller trees and is the point where a new job is refused. A job that needs more than what remains fills this disk and stops. It does not extend `C:`.

Creating the VHDX needs 60 GB free on `C:` at that moment, measured from the operator distro's `/mnt/c`. That check allocates the file. It is not the per-job floor.

The hosted-runner toolchain-delete step is gone. `CARGO_INCREMENTAL=0` and line-tables-only debug stay.

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
| Boot mount task | The only Windows-side component. SYSTEM runs it at startup | It runs `wsl --mount --vhd C:\wsl\aap-runner-work.vhdx --bare` and touches only that VHDX path. The script, its folder, and the VHDX are writable by SYSTEM and Administrators only. It does not read `C:` free space, the user profile, or write into the distro |

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
- [ ] `ghrunner` is not in `sudo` or `docker`. Bootstrap checks this and exits if it is.
- [ ] Sysbox preflight printed `docker info` from inside `--runtime=sysbox-runc`. If it did not, the install stopped and stays stopped.
- [ ] On `special-place-ai-heaven/symforge`, Settings > Actions > General > Access allows `Agent_Army_Professionals`. Then delete the `SYMFORGE_TOKEN` secret from this repo and from the org. The workflow does not read it.
- [ ] `.wslconfig` does not set `networkingMode=mirrored`. `wslinfo --networking-mode` is not `mirrored`. Inside `aap-runner`, a missing `wslinfo` is a failed install, and an unreadable `.wslconfig` is a failed install.
- [ ] `icacls` on `C:\wsl`, `C:\wsl\mount-work-vhdx.ps1`, and `C:\wsl\aap-runner-work.vhdx` lists only SYSTEM and Administrators, and the owner of each path is `BUILTIN\Administrators`.
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

Bootstrap creates the 60 GiB fixed VHDX, formats it, and registers `AAP-CRRR-Mount-Work-Disk`. Registering that task needs an elevated shell. If Task Scheduler rejects it, the install stops. An earlier `AAP-CRRR-C-Free-GB` task is deleted if it is present.

Bootstrap will refuse to start if `aap-runner` already exists. Unregister is a human decision: `wsl.exe --unregister aap-runner`.

After a successful preflight, place the key and fill the empty `AAP_GITHUB_APP_ID` and `AAP_GITHUB_APP_INSTALLATION_ID` in `/etc/aap-runner/manager.conf`. Then:

```bash
wsl.exe -d aap-runner -u root -- systemctl start aap-runner-manager
```

The unit does not start while `app.pem` is absent.

## Workflow contract

Every job:

- `runs-on: [self-hosted, linux, crrr]`
- skips a `pull_request` whose head repo is not this repo
- starts by refusing unless `df` of the workspace shows the 60 GiB work disk with at least 35 GB free. That is the same filesystem the manager checks with `df -BG --output=avail /var/lib/ghrunner`
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

```bash
wsl.exe -d aap-runner -u root -- bash /usr/local/sbin/aap-runner-evidence
```

The script prints `uname -r` and a line telling the operator to paste `wsl --version` from Windows alongside the log. Then: whether `/mnt` is empty, whether `cmd.exe` can run, `nft list ruleset`, `wslinfo --networking-mode`, the bridge `EnableIPv6`, `id ghrunner`, and `stat` of `/etc/aap-runner/app.pem` and `/etc/aap-runner/manager.conf`. It then starts one Sysbox container with the job memory, cpu, and pids limits and, from inside that container, prints the container gateway, `AAP_WINDOWS_HOST_IP` (the distro default route), and the result of connecting to that gateway, that Windows host IP, `192.168.1.1`, and `fd00:aaaa::1` (those four must fail) plus `https://github.com/` (that must succeed). It exits non-zero when any of those observations is missing or wrong. It does not mint a registration token and it does not print the App key.
