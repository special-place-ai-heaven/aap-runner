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
| `nftables.conf` | Best-effort egress drop for LAN, link-local, and CGNAT |
| `manager.conf.example` | Schema for `/etc/aap-runner/manager.conf`. No secrets |
| `Dockerfile` | Job image: inner dockerd 27.3.1, mysql-client, no sudo |
| `ephemeral-entry.sh` | Starts inner dockerd, registers ephemeral, runs one job |
| `record-c-free-gb.sh` | Root writer for the C: free-space file |
| `c-free-gb.ps1` | SYSTEM task: read C: and push the number into the distro |
| `c-free-gb-task.xml` | Task Scheduler definition for that script |

`bash bootstrap.sh --self-check` and `bash manager.sh --self-check` check the checksum and disk-floor parsers. They do not touch WSL.

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

1. Refuses to start unless `/run/aap-runner/c-free-gb` is root mode `0400`, fresh, and reports at least 40 GB free on `C:`. `df /` inside the distro is not that number.
2. Mints a short-lived registration token: App JWT, installation token, then `POST /orgs/{org}/actions/runners/registration-token`. The token stays in memory. It is passed to the container on stdin and unset before `run.sh`.
3. Starts a container with no `-v`, no `--privileged`, and no `/var/run/docker.sock`:

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

except the distro's DNS resolver, which bootstrap writes into the set from `/etc/resolv.conf`. Internet destinations are allowed. The packet's destination is filtered, not the bridge gateway, so normal outbound NAT still works.

This is best-effort LAN isolation. It covers bridge egress from this distro. It does not cover the WSL2 virtual switch on the Windows host, and a process inside the Sysbox container that can reconfigure its own network namespace is outside the host table. Do not open RFC1918 because a job cannot reach GitHub: GitHub's addresses are public, so a drop here is not the cause.

## Disk floor

`df /` inside `aap-runner` reports the VHD maximum, which on this PC is 1 TB. It does not report free bytes on `C:`. A job step that runs `df -BG --output=avail "$GITHUB_WORKSPACE"` passes while `C:` is already under 40 GB. That step is not in the workflow. It would be a second, false authority for the same fact.

The guard is the manager, and it reads a file Windows writes:

- Task Scheduler task `AAP-CRRR-C-Free-GB` runs as SYSTEM every minute and at boot.
- `c-free-gb.ps1` reads `Win32_LogicalDisk` for `C:` and calls `wsl.exe -d aap-runner -u root -- /usr/local/sbin/aap-record-c-free-gb <epoch> <free-gb>`.
- That script writes `/run/aap-runner/c-free-gb`, mode `0400`, owner root. The line is `<unix epoch> <free GB>`.
- The manager starts a job only when the file is root mode `0400`, the epoch is not more than 180 seconds old (and not more than 30 seconds in the future), and the free GB is at least 40. Missing, stale, or low fails closed. A dead task stops new jobs.

Interop is off, so the distro cannot ask Windows itself. Windows can still enter the distro, which is how the task delivers the number. The job container does not see the file: the manager bind-mounts nothing, and it refuses to start if any mount source is `/mnt` or under `/mnt`.

Bootstrap, running in the operator distro before lockdown, also refuses to import when `df` of `/mnt/c` is under 40 GB. That mount is the Windows volume. It is not the check the manager uses later.

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

Bootstrap registers the scheduled task `AAP-CRRR-C-Free-GB` as SYSTEM and then proves it wrote `/run/aap-runner/c-free-gb`. Registering that task needs an elevated shell. If Task Scheduler rejects it, the install stops.

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
- does not run `df` for the disk floor. Inside the distro that number is the 1 TB VHD, so it would pass while `C:` is already under 40 GB. The manager's reading of `/run/aap-runner/c-free-gb` is the guard
- pins every `uses:` to a 40-character commit SHA, with the version in a comment

Workflow permissions are `{}`. Each job sets `contents: read` plus `actions: write`, because `Swatinem/rust-cache` and `actions/setup-node` cache saves need the Actions cache API. No other permission is granted. No new secret and no new trigger. `secrets.SYMFORGE_TOKEN` was already the public-to-private fallback for the sibling checkout.

DB Integration (`timeout-minutes: 45`) runs two service containers on the inner dockerd:

- Oracle MySQL `8.4.11` on port 3306, database `aap`. The existing harness uses this and is not pointed at SingleStore.
- SingleStore dev image on port 3307, database `aap_singlestore`, health `start-period` 90s (the image's own check is 90s; the floor is 60s).

Image digests are **not** in the workflow. Both images are marked `TODO(MARGARET, CODD, §15b)`. Do not invent a digest to clear that TODO.

PR #39's known-failure inventory is the workspace, agents, and backend test commands (`--no-fail-fast`, every integration binary, the closing step that fails the job if either step failed) and the DB job's eight harnesses plus the `migration_v2_unit::` skip. Those commands are unchanged. A green DB job still does not count the three isolated migration proofs as passes.

## Pins in the workflow

| Action | Commit | Comment |
|---|---|---|
| `actions/checkout` | `11d5960a326750d5838078e36cf38b85af677262` | v4.4.0 |
| `actions/setup-node` | `49933ea5288caeca8642d1e84afbd3f7d6820020` | v4.4.0 |
| `Swatinem/rust-cache` | `6323deb102c322ba6fcbdcafc7e3dddab59af2b6` | v2.9.2 |
| `dtolnay/rust-toolchain` | `e2a55d2ffb04f378e9626c28d38b36d230d1e12f` | master 2026-10-09, `toolchain: stable` |

`dtolnay/rust-toolchain` selects the toolchain from the ref when you write `@stable`. A SHA pin does not, so every job sets `toolchain: stable` itself.
