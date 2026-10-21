# images/ubuntu-24.04: the Ubuntu 24.04 golden image builder (P07)

Builds one immutable generation `ubuntu-24.04-x64/20261012.334.1-aap.<n>` of the native Ubuntu runner image on a local
Hyper-V host, from the official Ubuntu 24.04 live-server ISO and the provisioning of `actions/runner-images` at the P01 build
commit `7e7dc1b`. PowerShell 5.1 (the supervisor's host) and PowerShell 7 on the host; bash in the guests.

**Status: authored and tested with fakes only.** No VM was created, no Hyper-V cmdlet ran, no media was read and nothing was
downloaded. The first real run is the D2 lab (see [What is not done](#what-is-not-done)). The committed plan is deliberately
not runnable yet: its upstream script hashes are not pinned (`AAP_ScriptUnpinned`), and neither are the upstream source
archive and the ISO, whose blockers cannot be waived (`AAP_Blocked`).

The Windows twin is `images/windows` (P06). This builder imports five of its helpers (the path walk, safe deletion, read-only
ACL and storage record, from `images/windows/AapWinImage.psm1`) and carries verbatim copies of 19 smaller ones (listed in
INTEGRATION.md, Dependency on P06), and it follows P06's rules; what differs is everything a Linux guest needs.

| File | Role |
|---|---|
| `AapUbuntuImage.psm1` | The builder: storage and trust checks, plan, blockers and waivers, seed images and guest requests, the install, the phase loop, the in-guest secret scan, fresh-guest verification and the inventory comparison, publication, generation and budget records. Calls nothing on the host except through the provider |
| `AapUbuntuImage.HyperV.psm1` | The production provider (`New-AapUbuntuHyperVProvider -PythonPath <python.exe>`): every Hyper-V, IMAPI (seed ISO), synthetic-keyboard, hvsocket, ACL and comparison call. Not run by P07 |
| `New-AapUbuntuBuildPlan.ps1` | Generates `build-plan.json` from the pinned template; reads files only; pwsh 7 for the committed plan |
| `build-plan.json` | The phase table (one phase per upstream provisioner, in template order), the base install settings, the guest channel, the job user and the verification gate |
| `reference-inventory.json` | The hosted reference job inventory: P05's `certify.py parse-hosted-log` of the pinned hosted capture (run 39305649952); a test regenerates it |
| `secret-allowlist.json` | Reviewed secret-scan exceptions, exact path plus SHA-256 pairs; empty |
| `guest/aap-agent.sh` | The guest agent: one request per hvsocket connection (vsock port 5223), fixed verbs, token-checked; runs the phases, the seal, the verification and the scan |
| `guest/aap-verify.sh` | Runs in a fresh guest of the sealed image as the job user `runner`: upstream tests, P05 inventory probe, discovery |
| `guest/aap-scan.sh` | Runs in the scanner guest: the secret scan of the sealed disk, mounted read-only by the scanner's own kernel |
| `INTEGRATION.md` | What P10.0, P11, P15, P19, P12, P21, P24 and P03 must do with this |

## Hostile guests

The build guest runs internet-sourced installers, so nothing a guest says or writes is trusted, from the first phase on.

- **The host never mounts a guest file system.** Windows cannot read ext4, and parsing guest-authored metadata on the host is
  exactly what the hostile-guest rule forbids, so there is no offline write into, and no offline read from, any guest disk.
  The host attaches no guest disk to itself at all: the OS disk is created empty and the guest's own installer partitions
  it; after sealing, the guest trims its free space and the host compacts the file with `Optimize-VHD -Mode Pretrimmed`,
  which needs no attach.
- **Files go in on host-built seed images.** Each guest boots with a new ISO 9660 + Joliet image labelled `CIDATA` (the
  cloud-init NoCloud seed) that the host writes from scratch: `user-data` and `meta-data`. The build seed holds the
  unattended install (autoinstall); every seed installs the agent, its systemd socket units and a per-guest 64-hex token;
  the scanner's seed also holds the build guest's token to look for. The build seed is deleted as soon as the install has
  finished; the others go with the build folder. A token is an `AapToken` object from the moment the seed builder makes it:
  it prints as `[aap token]`, is never a command parameter or an interpolated string (PowerShell module logging, event 4103,
  records parameters), and reaches text only where the seed is assembled and as bytes in the channel header (a test pins
  this on the parse tree).
- **Results come back only over the capped channel.** The agent listens on an hvsocket (`AF_VSOCK` port 5223, host service
  GUID `00001467-facb-11e6-bd58-64006a7986d3`). One connection carries one request: a header line
  `aap1 <token> <verb> <name> <length>` and the payload; the verbs are `ready`, `bootid`, `put`, `get`, `run`, `reboot` and
  nothing else. The host reads each reply into memory or a new file with a byte cap counted while it arrives (64 KiB for a
  reply, 16 MiB for a software report, 4 MiB for the inventory and the scan report); more is `AAP_HostileGuest`, a broken
  connection `AAP_GuestUnreachable`, a slow one `AAP_GuestTimeout`, and a reply must be one printable-ASCII JSON object of
  known fields. Nothing a guest returns is evaluated, imported or used as a path. Received files land in the build folder
  first, are size-checked and only then moved to the evidence folder.
- **The secret scan runs in a disposable scanner guest**, booted from the same pinned installation ISO with no network
  adapter and **no disk**, so firmware can only boot the media; the sealed disk, as a differencing child, is hot-added on SCSI
  once the live system answers. The scanner's own (trusted, pinned) kernel checks the partition layout the build made (GPT:
  FAT EFI, then an ext4 root, numbers 1 and 2; a decoy partition is refused), refuses a root whose journal still needs
  recovery (every clone would replay it, `ro,noload` would not; a `dumpe2fs` that reports no features is not taken as a
  clean journal, the scan is then incomplete), mounts the root read-only without journal replay and the EFI partition
  read-only at a mount point of its own, never over the root's `/boot/efi`, so the root's own files there are scanned too
  (that folder must still be a plain folder: each clone mounts the EFI partition on it, and mount follows links).
  **Accepted residual**: a crafted ext4 or FAT image could attack the scanner's file system drivers; that is contained in a
  guest with no network and no host channel but the capped reply, and the sealed disk's hash is checked again afterwards.
- No guest gets a password, an SSH key, a host share, Guest Service Interface or Key-Value Pair Exchange. `NewVm` makes
  every VM with no network adapter, no automatic start and no checkpoints (read back). Only the build VM gets one, from the
  P10.0 host network module (`parity/contracts/host-network-module.md`, taken as `-Network`): on its own switch
  `aap-build-linux`, never beside another VM, statically addressed from the module's declaration (no DHCP). The builder
  follows the contract's consumer obligations: `Attach` while the VM is Off and the shared declaration check
  (`AAP_NetworkInvalid`), the declaration written into the build seed's autoinstall `network` section, then before every
  start `Attach` again, `Verify` (every object and every error it writes is a problem, `AAP_NetworkUntrusted`) and the builder's own
  read-back of Hyper-V through the shared check (`supervisor/network/AapHostNetworkCheck.psm1`: guards, mirroring, VLAN,
  storm limit, legacy ACLs, peers, both directions of every fixed deny, the source pin, weights, stateless rules); `Verify`
  again before a phase while the VM runs, once a minute has passed since the last check; after the VM is removed,
  `Detach`. The scanner and verification VMs are never attached and read back with no adapter before they start. The seal
  removes the build address (the installer's netplan file and network configuration; seal rule `no-build-network`), so a
  clone takes its addressing only from its own seed.

## Trust in the builder's own files

The builder runs elevated. Before anything else it asks the provider's `TestRootTrust` (P03's ProgramData rules plus the
admin-only rule) about every folder it loads code from or sends files from: its own folder, `guest`, `images/windows` (the
P06 helpers it imports), `images/common`, `tools/parity-certify` with `probe` and `workloads/fixtures`, `supervisor/network`
(the shared network check, imported only after this check passed), and the folders whose code the provider runs
(`ExecFolders`: python's install folder). Any finding is `AAP_BuilderUntrusted`. What this protects:
a deployment that anyone but the administrators can change is refused before it touches a disk or a VM, so a later change by
an unprivileged process cannot reach an elevated build. What it does not protect: the check runs after `AapUbuntuImage.psm1`,
`images/windows/AapWinImage.psm1` and (inside the provider's check) `images/common/AapArtifact.psm1` were loaded, so code that
was already changed when it loaded is not undone by it. P19's admin-only deployment of these folders is the protection; the
self-check detects when that deployment is not in place. Files are not checked one by one: a folder passes only with a
protected DACL and no access entry, inheritable ones included, for anyone but SYSTEM, Administrators and TrustedInstaller.
The provider also refuses a `PythonPath` that is a reparse point (the Store's `python.exe` app execution alias), and compiles
its C# types with `TEMP` and `TMP` pointing into the admin-only build folder.

## Build flow

`Invoke-AapUbuntuImageBuild -Config <hashtable> -Provider <hashtable> -Network <the P10.0 host network module>` returns `Ok`, `Status` (`built`, `unchanged`, `refused`,
`failed`), `Reason`, `Detail`, `GenerationId` and the record paths. A `refused` run changed nothing. A `failed` run removed
everything it made (VMs, build disks, a partly published generation, the evidence files it wrote) and kept only
`secret-scan.json` when the scan ran, as the record of why it failed.

1. **Preflight** (refusals, nothing written): provider completeness; the host network module (`Attach`, `Detach`, `Verify`;
   none is `AAP_NetworkUnavailable`, an incomplete one `AAP_NetworkInvalid`); the builder's own folder, `guest`, the P06
   helpers it loads (`images/windows`), `images/common`, `supervisor/network` and `tools/parity-certify` (the probe, the
   comparison and its allowlist) must pass
   the admin-only trust check, and so must python's install folder; config, with the owner's lab ceilings (at most 4 vCPU,
   10 GiB, `BaseGibMax` 186, `JobDiskGibMax` 55); the storage document; trust of the storage document's folder, `base_root`,
   the staging root and the evidence root; the build switch `aap-build-linux`, Internal (P19 creates it; never a fallback
   to a guest switch); the plan (every script hash pinned, every
   variable in `[A-Za-z0-9_./:+-]`, the comparison reference matching its pin, the source archive and the media each pinned by
   P03 entry and SHA-256 or blocked unwaivably); input blockers (each resolved, or waived by a chair approval record for this
   plan; the source and media blockers cannot be waived); no reparse point on the way to the evidence, build and generation
   folders; the build lock (one image build at a time); a partial build of the same id (cleaned); an existing generation
   (idempotent `unchanged`, or refused); existing evidence for the id (refused); free space; P03's offline verification of the
   source archive, the media and any other input, then each staged file's SHA-256 against the plan and the ISO's name (Ubuntu
   24.04 live-server amd64 only).
2. **Install**: an empty dynamic `os.vhdx` of 150 GiB (the hosted job sees a 150G `sda`; upstream builds on 75 GB and Azure
   grows it), a generation 2 VM with Secure Boot (Microsoft UEFI CA template), static memory, checkpoints off, no automatic
   start, no network adapter, the ISO and an empty seed drive (first boot from DVD); then `Attach` and the declaration
   check, the build seed with the declaration's static address, prefix length, gateway and resolvers (`dhcp4: false`, the
   `hv_netvsc` adapter matched by driver) put into the seed drive while the VM is Off, and `Attach` again, `Verify` and the
   read-back before the VM starts. The host types Packer's
   boot command (`linux /casper/vmlinuz --- autoinstall ds=nocloud`, `initrd`, `boot`) into GRUB through the synthetic
   keyboard; the installer partitions the disk (GPT: EFI 512M, ext4 root), installs `linux-azure` and `walinuxagent` (masked),
   OpenSSH without passwords and no swap file, and powers off. The host removes both DVDs, deletes the seed, attaches again
   (the same declaration from the module's journal), verifies and reads back, boots from disk and waits for the agent, then
   sends the P03-verified `runner-images.tar.gz`.
3. **Phases** p01-p30 in upstream order (below). Scripts run the way Packer's `execute_command` ran them:
   `sudo sh -c "VAR='value' ... <script>"`, the same through `pwsh -f`, or as the unprivileged build user for Homebrew. Packer
   ran them over SSH as the build user; the agent runs as root under systemd, so it puts back what a provisioner saw: the
   system locale (`LANG=C.UTF-8`, the agent's own `LC_ALL=C` removed), `SUDO_USER`, `SUDO_UID` and `SUDO_GID` of the build
   user for root, and `/etc/environment` for the build user (PAM loaded it for the SSH session). Remaining deviations, for the
   D2 lab to confirm harmless: no SSH session variables (`SSH_CONNECTION`, `SSH_CLIENT`), no logind session for the build user
   (`XDG_RUNTIME_DIR`), `SUDO_COMMAND` names `sh` rather than Packer's command line, and the umask is the agent's 022. The
   agent copies each script from the unpacked archive, checks its SHA-256 against the pin before it runs it, stops at the
   first non-zero exit and keeps output in log files, never in the reply. The one reboot is upstream's own (`sudo reboot`
   from inside the guest); it counts only when the guest answers again with another boot id. Before a phase, once a minute
   has passed since the last check, the running build VM's network is verified again (`Verify`: a host whose addresses
   changed stops the build); after each phase the build folder is measured against `StagingGibMax`.
4. **Seal**: the last phase runs `waagent -force -deprovision`, removes the install user, the agent with its units and
   enablement link and its token (overwritten, then deleted), cloud-init and installer state (`/var/log/installer` holds a
   copy of the autoinstall answers), the build VM's static network configuration (`/etc/netplan/*.yaml`, the installer's
   `90-installer-network.cfg`), host keys, the snakeoil TLS key and certificate, `/var/lib/systemd/random-seed` and
   root's history, rotates and vacuums the journal, points cloud-init at the NoCloud seed each clone will get
   (`datasource_list: [ NoCloud, None ]`), trims free space and runs the **seal check** as root (`no-agent` covers the
   agent's state folder, program, both units and the `sockets.target.wants` link, a dangling one included): `install-user-absent`, `no-password-hash`, `no-authorized-keys`,
   `no-ssh-host-keys`, `no-agent`, `no-cloud-state`, `no-build-sudoers`, `no-build-network`. A finding is `AAP_SecretFound`,
   a rule not checked `AAP_ScanIncomplete`. The host shuts the VM down, removes it, then detaches its network (`Detach`; one
   that throws fails the build once the rest of the cleanup is done: the network is not proven detached, and the module's
   reconcile removes the record), compacts and hashes `os.vhdx`. `Remove-AapUbuntuBuild` refuses
   (`AAP_NetworkUnavailable`) a build folder whose `state.json` names a build VM unless it is given the module (`-Network`).
5. **Secret scan** in the scanner guest (rules below). Anything but `clean` fails the build.
6. **Fresh-guest verification**: a differencing child of the sealed disk, a seed that creates the job user `runner` (uid
   1001; `adm`, `users`, `docker`, `systemd-journal`; passwordless sudo, as on the hosted image), **no network adapter** and no
   media. The agent runs the post-generation scripts as root the way hosted provisioning does (one `bash` per script, in
   `find`'s order; unlike `find -exec`, any script that fails fails `post_generation`), then `aap-verify.sh` as
   `runner` with `/etc/environment` loaded as the Actions runner loads it: the pinned upstream Pester tests
   (`RunAll-Tests.ps1`), the full P05 inventory probe (`job-inventory.json`, Docker and sudo included) and discovery (gcc, g++,
   clang, cmake, ninja, make, pkg-config, a C program built and run with gcc and clang, pwsh, python3, the Docker daemon,
   passwordless sudo, systemd as PID 1, the Azure kernel flavour, the job user, the post-generation scripts, the first
   boot's snakeoil TLS pair). It passes only with at least one upstream test, no failed test, every discovery item and an
   inventory whose hash matches what the guest reported. Then P05's `certify.py compare` runs on the host against `reference-inventory.json` with P05's
   `allowlist.json`: **any difference in a gate section** (`coverage`, `tool_cache`, `services`, `path.process`,
   `path.machine`, `action_archive_cache`, `user`) and **anything the reference requires that the image lacks in a section
   the image owns** (`missing-required` in the plan's explicit `verify.required_sections`: `tools`, `shells`, `docker`,
   `env`, `limits`, `limits.sysctl`, `hardware`, `tool_cache`, `action_archive_cache`, `services`, `path.process`,
   `path.machine`) fail the build. `image`, `infra`, `run_identity` and `credential_env` are not the image's: they describe
   the runner (a verification guest has none, so `image.runner_version`, `runner_os` and `runner_arch` are null), the job's
   identity and the Azure fabric, and the plan is refused if it names them, or names a section P05's comparison never
   reports (`certify.py`'s own section names: a misspelt one would gate nothing). `docker.images` is not gated either:
   the six cached images are `:latest` pulls inside `install-docker.sh` (P03 blocker `ubuntu-floating-container-images`;
   the pinned toolset lists none), so no pinned input says which names a build gets; P24 decides them. Their
   differences and every other one (kernel build, read-ahead, mount options, tool versions from floating feeds, hardware)
   are recorded in `build.json` for P24, and so are the count and the first 200 of what the image has beyond the reference
   (`extra`). `tool_cache.defaults` is not gated: the hosted capture records no defaults. Before the agent answers, the
   verification seed runs the first-boot step every clone gets (P15): `make-ssl-cert generate-default-snakeoil
   --force-overwrite`, because the seal deleted the image's snakeoil TLS pair and PostgreSQL (`ssl = on` with that pair) does
   not start without it; the upstream tests start PostgreSQL. cloud-init does not stop on a failed `runcmd`, so the agent
   checks the pair as root and a missing one fails the discovery item `tls_snakeoil` by name. The clone peak and the VM
   memory overhead are measured here (an overhead outside 1 to 1024 MiB is refused, not recorded: the worker grows with
   what the guest does); the sealed disk is hashed again and must be unchanged.
7. **Publish**: as P06. The generation folder is created new, `base.vhdx` copied in, re-hashed, made read-only (owner
   Administrators; SYSTEM, Administrators and `NT VIRTUAL MACHINE\Virtual Machines` read; protected DACL; ReadOnly
   attribute). An id is never reused: other bytes or no record is `AAP_GenerationExists`; a rebuild takes `aap.<n+1>`.
8. **Records** under `<EvidenceRoot>\P07\<build id>\`, created new by this run: `generation.json` (image-catalog schema 2,
   state `candidate`, `built_by_item` `P07`), `budget.json` (backend-lifecycle schema 2), `build.json` (`plan_sha256`,
   `inputs_manifest_sha256`, `builder_commit`, waiver records, media hash, the base deviation, phases with their exec mode,
   script hashes and exit codes, the seal check, verification counts and facts, the inventory comparison, measurements,
   the build VM's network declaration), `secret-scan.json`, and the guest-authored `software-report.md/.json` and
   `job-inventory.json`. The declaration holds no secret but names the private build subnet, the resolvers and the VM's
   GUID: `build.json` stays out of the public repository.

## Configuration

Passed by the caller (P19 or P25), never read from the user-writable inbox. All keys are required unless marked. The plan,
the P03 manifest, the allowlist, the guest scripts, the probe and the comparison reference are files in the repository; no
key redirects them. The network is not configuration either: the caller passes the P10.0 host network module itself as
`-Network` (P12 builds it once), and the build VM's switch follows from its name (`aap-build-linux`, P19 creates it).

| Key | Meaning |
|---|---|
| `StoragePath` | The storage document, `C:\ProgramData\aap-runner\capacity\storage.json` (backend-lifecycle.md, Storage tiers) |
| `EvidenceRoot` | Admin-only and trust-checked like the storage roots; records go to `P07\<build id>\` below it |
| `AapBuild` | `<n>` of `aap.<n>` |
| `BuildCpus`, `BuildMemGib` | Build, scanner and verification VM size; at most the owner's lab approval of 2026-10-20 (4 vCPU, 10 GiB static) |
| `StagingGibMax` | Cap on the build folder; also the free space the staging volume must have above its floor |
| `BaseGibMax`, `JobDiskGibMax` | The approved budget the measured one must fit; at most the owner's ceilings (2026-10-20: base at most 200 GB, about 186 GiB; clone plus scratch at most 60 GB per runner, about 55 GiB) |
| `BuilderCommit` | 40-hex commit of this builder, recorded in provenance |
| `Inputs` (optional) | Further P03 entries to verify offline before the build |
| `Waivers` (optional) | Chair approval records, one per waived blocker: exactly `id`, `rationale`, `plan_sha256` and `approver`. A bare id, a missing field, another plan's hash or a blocker the plan marks unwaivable is `AAP_ConfigInvalid`. Recorded in `build.json`; P21 takes them only from a committed, reviewed file |

The upstream source archive and the ISO are not configuration: the plan pins each by P03 manifest entry and SHA-256
(`inputs.source`, `inputs.media`), so `plan_sha256` covers them; P03 verifies the staged files offline and the builder
re-hashes them.

## The phase table

`build-plan.json` is generated by `New-AapUbuntuBuildPlan.ps1` from the build-commit template
`parity/baselines/ubuntu-24.04-x64/sources/build-commit-7e7dc1b/build.ubuntu-24_04.pkr.hcl` (SHA-256 `5b8a5f29...1adf`, checked
before parsing), the pinned locals (`ubuntu24` only), the toolset and the hosted capture. A test regenerates it and compares.
Each phase records its upstream provisioner number, type and the SHA-256 of the provisioner body. Script phases keep the
upstream script list (72 scripts, the order of `inputs.md`), environment, exec mode, pause and start retry. File and inline
provisioners map to named actions; an unknown one stops the generator.

| Phase | Upstream | AAP |
|---|---|---|
| p01 | `mkdir` and `chmod 777` the image folder | `make-image-folder`, the same commands as root |
| p02, p06-p09 | upload helpers, build scripts, post-gen/tests/docs-gen, software-report-base, toolset | `upload-*` from the P03-verified archive, as the build user, following Packer's rule (a folder uploaded to an existing destination lands inside it, to a missing one it becomes it) |
| p03-p05, p11-p22 | the script blocks (p15 and p18 through `pwsh -f`, p20 Homebrew as the build user) | same order, same environment and exec mode |
| p10 | `mv docs-gen SoftwareReport`, `mv post-gen post-generation` | `layout-image-folder`, the same commands |
| p23 | `sudo reboot`, expect disconnect | the agent reboots; counted when the boot id changes |
| p24 | `cleanup.sh`, pause 5 min | same |
| p25 | software report, then `RunAll-Tests.ps1` (build user) | `software-report-and-tests`, same order, stops at the first failure |
| p26-p27 | download the software report | received capped into the evidence |
| p28-p29 | `configure-system.sh`, `post-build-validation.sh` | same |
| p30 | `sleep 30`, `waagent -force -deprovision+user`, `sync` | `deprovision`: `waagent -force -deprovision` (waagent provisioned no user here), then the AAP seal and the seal check |

Plan blockers (besides P03's 14 for this profile): `p07-upstream-source-archive` (no P03 entry for the upstream tree;
**unwaivable**), `p07-upstream-variables-unverified` (the `variables` defaults are from the upstream variables file, not
stored by P01) and `p07-ubuntu-server-media` (the ISO is not a P03 entry tied to Canonical's signed `SHA256SUMS`;
**unwaivable**). An unwaivable blocker goes only when the generator is rerun with the entry and its SHA-256
(`-SourceEntry`/`-SourceSha256`, `-MediaEntry`/`-MediaSha256`); a plan with neither a pin nor the blocker is
`AAP_PlanInvalid`.

## Storage and sizing

Roots come only from the storage document; nothing in this folder names a drive. The build folder is
`<staging root>\build\<build id>\` (`os.vhdx`, the build seed until the install ends, `scan\` and `verify\` with their
differencing disks and seeds, `state.json`, received `.part` files, `scan.json`, `inventory-report.json`, the VM files),
with `aap-image-build.lock` beside it: one image build at a time per staging root (P06.1 is asked to take the same lock). Before a build the staging volume needs `StagingGibMax` and `base_root`'s volume needs
`os_disk_gib + 1` above `volume_floor_gib`, summed when they share a volume.

The budget record is measured, never a default: `base_gib` and `replacement_gib` from the sealed disk; `clone_peak_gib` from
the verification guest's differencing disk (cap: peak x 1.25, rounded up); **no scratch disk** (`scratch_peak_gib` and
`scratch_gib_max` 0: a hosted Ubuntu job writes to its root file system, here the clone); `staging_gib` from the largest
build-folder measurement; `boot_mem_overhead_mib` from the VM worker process; one retained rollback generation. Context, not a
budget: the hosted job sees `/` 145G with 59G used and 86G free (run 39305649952). The 60 GiB Linux work-disk default appears
nowhere; a test fails if it does. The measured budget must fit `BaseGibMax` and `JobDiskGibMax`.

## Refusals and failures

`AAP_ProviderInvalid`, `AAP_BuilderUntrusted`, `AAP_ConfigInvalid`, `AAP_StorageMissing`, `AAP_StorageInvalid`,
`AAP_StorageUntrusted`, `AAP_StorageVolumeMismatch`, `AAP_NetworkUnavailable`, `AAP_NetworkInvalid`, `AAP_NetworkUntrusted`, `AAP_PlanInvalid`, `AAP_ScriptUnpinned`,
`AAP_SeedInvalid`, `AAP_Blocked`, `AAP_BuildBusy`, `AAP_GenerationExists`, `AAP_DiskLow`, `AAP_InputsUnverified`, `AAP_InstallTimeout`, `AAP_HostileGuest`, `AAP_GuestTimeout`, `AAP_GuestUnreachable`,
`AAP_PhaseFailed`, `AAP_ScriptHashMismatch`, `AAP_RebootTimeout`, `AAP_BudgetExceeded`, `AAP_BudgetUnmeasured`,
`AAP_SecretFound`, `AAP_ScanIncomplete`, `AAP_AllowlistInvalid`, `AAP_VerifyFailed`, `AAP_BaseChanged`, `AAP_PublishMismatch`,
`AAP_UnsafeDelete`; anything else is `AAP_Unexpected`.

## Secret scan

Run by `guest/aap-scan.sh` in the scanner guest over every regular file and link of the sealed root file system and its EFI
partition (each from a mount point of its own; EFI paths are reported under `boot/efi/`), without following any link. Name
rules: runner `.credentials*` and `.runner`, `ssh_host_*_key`, `authorized_keys`,
shell histories (PSReadLine's `ConsoleHost_history.txt` included), `app.pem`, cloud-init seed and instance data names
(`user-data`, `meta-data`, `network-config`, `vendor-data`), the installer's saved answers (`autoinstall-user-data`),
`ovf-env.xml`, and any password hash in `etc/shadow`. Path rules: anything left of the build agent
(`var/lib/aap-build/*`, `usr/local/libexec/aap-build/*`, `etc/systemd/*aap-agent*`, links included; `build-agent`) and a
non-comment `NOPASSWD` line in `etc/sudoers.d` (`build-sudoers`). Content rules, over every regular file whatever its size
and over every `.gz` decompressed in a stream: PEM private keys, `ghp_`/`gho_`/`ghu_`/`ghs_`/`ghr_` tokens, `github_pat_`, a
JIT configuration assignment, the synthetic lab markers, and the build guest's token in ASCII and UTF-16. Two passes over
all files (every text rule and the token at once, then the token in UTF-16) pick the candidates; each rule then runs over the
candidates only. Findings carry a rule, a path and the file's SHA-256 (a link's: of its target text, never followed), never
the value. The seal check result is recorded in `secret-scan.json` under `seal`.

- **Large files**: files over 32 MiB are content-scanned like the rest and also listed with path, size and SHA-256 for the
  P24 audit (up to 10,000; more makes the result `incomplete`). Journal files are the usual large ones; the seal rotates and
  vacuums the journal so few remain.
- **Unreadable**: any path the scanner could not read is listed and makes the result `incomplete` (`AAP_ScanIncomplete`).
  As root on a read-only mount there should be none. A `.gz` counts as read only when `grep` read its whole decompressed
  stream and `zcat` ended cleanly: a truncated or corrupt stream, or a `grep` that fails (a single line too long for its
  memory: a gzip bomb), is never clean: it is reported as an `unreadable-stream` finding with the file's SHA-256, and
  makes the result `incomplete` unless an allowlist entry covers exactly that rule, path and bytes (the route for a file
  the image legitimately ships damaged, a test fixture for example, after review). A match stands whatever `zcat` reports
  after `grep` stopped reading: a broken pipe, which under systemd's default `IgnoreSIGPIPE=yes` (the agent's unit keeps
  it) is an error message, not a signal.
- **What the scan does not read**: only `.gz` is decompressed. `.xz`, `.zst`, `.bz2`, `zip`, `jar`, `whl`, squashfs images
  (snaps) and journald's zstd-compressed fields are scanned as stored bytes, so a secret inside them is not found; the
  freed blocks of either file system are not read at all.
- **Invariant: no reusable secret may ever enter the build guest.** Not a token, a key, a registry or feed credential,
  not even for a moment: a deleted file's data can survive in `base.vhdx` (the guest's trim and `Optimize-VHD` reclaim
  only whole 32 MiB VHDX blocks), and any job that is root in a clone, as every hosted-parity job is, can read the raw disk.
  The only secret the build guest ever holds is its own per-build channel token, which dies with the build and which the
  scan looks for. The scan detects leaks; it is not an integrity or backdoor control: a hostile installer that wants to
  leave something behind is not stopped by it.
- **Allowlist**: `secret-allowlist.json` (`schema` 1, `entries` of exactly `rule` (one of the scan rules), `path`
  (relative, `/`-separated, no wildcard), `sha256` and `justification`), each rule and path at most once. An entry
  suppresses only a finding of its rule (an `unreadable-stream` included) for that exact path with those exact bytes, never
  a `build-credential` or `build-agent` finding: an entry for a damaged `.gz` does not cover a key or token found in the
  same bytes. An entry that matches no finding exactly is itself a finding (`allowlist-mismatch`). It is empty. Per-machine material is deleted at seal rather than allowlisted (the snakeoil
  TLS key, the random seed; each clone makes its own, P15). Expect the first real build to name other files the upstream
  image legitimately carries; each needs a reviewed decision, not a rule change.

## Tests

`tests/images/ubuntu-24.04/` on both PowerShell hosts and real Linux:

- `UbuntuImage.Tests.ps1` (Pester 5; Windows PowerShell 5.1 and PowerShell 7): plan, storage, trust, preflight, network,
  waivers, the full build, failure at every guest phase, hostile replies, reboots, the seal check, the inventory gate, budget,
  scan reports and allowlist, seeds and requests, real read-only ACLs, evidence ownership, immutability, cleanup, the
  production provider's static rules and adapter post-condition, the token's parse-tree rule, the P06 helper signatures,
  source rules. The fake world lives under `%LOCALAPPDATA%\aap-p07-tests` (or `AAP_P07_TESTROOT`) and is removed after each
  test. The fake provider makes published files really read-only with P06's `Set-AapReadOnlyAcl`, the current user as owner
  and only reader. Setting the owner and DACL needs `WRITE_OWNER` and `WRITE_DAC` on the new files, which the default root
  grants through its inherited Full Control; a test root that grants the user only Modify (a volume root where Authenticated
  Users have Modify, for example) fails those tests, and a root where an `OWNER RIGHTS` entry or an inherited deny takes the
  owner's implicit `WRITE_DAC` away leaves read-only files the cleanup cannot delete.
- `Invoke-AapUbuntuMutations.ps1`: each `# check:` in the builder disabled in turn must fail its tagged tests; a control run of
  the same tests against an unmutated copy must pass first.
- `guest_test.sh` (bash, WSL Ubuntu or CI; python3 and coreutils only): the agent's wire format, token, header, put, get and
  request checks, pinned-hash script runs, the upload rule, deprovision and the seal check, verification as the job user, and
  the scan over a planted tree and a separate EFI tree with SIGPIPE ignored as under systemd, plus a truncated `.gz` and a
  gzip bomb under a memory limit. Every system command is a stub and every system path sits under a temporary root.
- `guest_mutations.sh`: each `# check:` guard in the guest scripts disabled in turn must fail `guest_test.sh`.

## What is not done

- **The build VM's network is authored against the shared fake** (`tests/common/AapHostNetworkFake.psm1`). The D2 lab
  proves that the live installer and the installed system take their address, gateway and resolvers from the autoinstall
  `network` section with no DHCP server on `aap-build-linux` (the live environment's own DHCP attempt only times out), that
  the installer's netplan file and `90-installer-network.cfg` are what the seal removes, and the contract's own lab points.
  A running build VM is verified again before the next phase once a minute has passed; a phase runs up to hours, so a host
  address change inside one is seen at the next phase (Consumer obligations 3 asks for at most 60 seconds: a watcher
  beside the guest call is P12's or the lab's to add).
- **Disk-only scan paths are unproven.** `guest_test.sh` scans folders (`--target`, `--esp-target`); what only a real
  disk exercises waits for the D2 lab: the hot-added disk appears as `/dev/sda` within 120 s, the live system's
  `multipathd`, `probert` and `os-prober` neither claim nor mount it, `dumpe2fs` and `grep -P` are present on the pinned
  ISO, the partition checks and both read-only mounts, and the `.gz` handling under the agent's systemd unit
  (`IgnoreSIGPIPE=yes`; the test reproduces it with `trap '' PIPE`).
- **No real build.** The provider is written against documented cmdlets and APIs and has never run. The D2 lab proves it:
  the boot command typed through `Msvm_Keyboard`, the autoinstall from a `CIDATA` ISO written with IMAPI2, Secure Boot with
  `linux-azure`, the systemd `vsock::5223` socket, the host's `AF_HYPERV` client and the service GUID registration (P19),
  cloud-init in the live-server environment applying the scanner's `write_files` and `runcmd`, `fstrim` plus
  `Optimize-VHD -Mode Pretrimmed`, and the read-only ACL with differencing children. The upstream test runner was not
  downloaded: `aap-verify.sh` expects its NUnit results at `<OutputDirectory>/testResults.xml`, as the Windows twin does;
  if the Ubuntu runner writes them elsewhere, verification fails closed (no results counts as a failed test) until the
  path is corrected.
- **Upstream scripts are not pinned.** The runner-images archive at `7e7dc1b` is not a P03 manifest entry (P03.1 adds it), so
  the plan's 72 script hashes are null and every build is refused (`AAP_ScriptUnpinned`). Rerun the generator with
  `-ScriptsDir` once P03 stages the archive.
- **Inputs are blockers.** 14 P03 Ubuntu blockers (the Azure base image, superseded apt versions, vendor repositories,
  proprietary components, release feeds, install scripts, floating container images, tool-cache manifests, ...) plus the
  plan's 3. A build needs each resolved or waived by a chair approval record, except the source archive and the media, which
  only pinning resolves; P07 decides none.
- **The base is not the hosted base.** Hosted runners start from the Azure Marketplace image `canonical:ubuntu-24_04-lts:server`;
  this build installs the live-server ISO instead (the `azure-base-image-ubuntu-24.04` blocker must be waived for it). Known
  differences: partition layout (EFI + root here, the cloud image's BIOS-boot + EFI + root there), `walinuxagent` masked
  (no Azure fabric), cloud-init's datasource NoCloud instead of Azure, no swap file (hosted shows 3 GiB; P05 allowlists
  `hardware.swap_bytes`), and the exact kernel build floats with the archive (the hosted `6.17.0-1022-azure` is a superseded
  version). The upstream scripts were written for the Azure image: a file they edit that a server-ISO install lacks will show
  as a phase failure in the D2 lab, and its fix is a reviewed plan action recorded as a deviation, not a silent patch.
- **Sysbox is not full VM equivalence.** The legacy WSL/Sysbox backend stays a separately named compatibility backend;
  nothing here certifies it, and adding packages to it does not make it this profile.
- **Kernel, read-ahead and mount options** come from the upstream scripts and the `linux-azure` package; the build records
  them and the comparison's differences but does not gate on them. A generation is approved only when they match the hosted
  reference or a reviewed P05 allowlist entry justifies each difference (image-catalog.md, Acceptance input for P07 and P11).
- **Nested virtualization** (`/dev/kvm`, which hosted Linux runners offer) is not exposed to the build or verification VMs and
  not verified; P11 decides it for clones.
- **The verification guest has no network.** An upstream test that needs the network fails by name; it is waived by an
  approval record bound to `plan_sha256` or decided in the D2 lab. A cached tool version that drifted because the
  tool-cache manifests float fails the inventory gate; the fix is P03 retaining the inputs, not relaxing the gate.
- **Post-generation scripts**: hosted provisioning runs `/imagegeneration/post-generation/*.sh` when it creates a runner VM;
  how exactly is in upstream documentation, not in the pinned sources. The verification runs them as root, one `bash` per
  script in `find`'s order, and fails on any non-zero exit; the lab confirms the folder survives `configure-system.sh`.
- **Clone peak** comes from the verification workload, not real jobs (P22 re-measures). A hosted job sees about 86 GiB free;
  the clone cap here is the measured peak x 1.25 inside the owner's 60 GB per-runner lab budget, so a job that writes more is
  destroyed. If jobs need the hosted free space, that is an owner budget decision.
- **Host crash mid-build is not resumable**: the guest tokens live in memory only, so the next run cleans the partial build.
- **shellcheck** 0.11.0 at `-S warning` is clean on all five scripts (run in WSL Ubuntu-24.04); CI runs it once wired.
- **Not in CI**: `tests/images/ubuntu-24.04` is not in `.github/workflows/ci.yml` yet (the coordinator wires it).
