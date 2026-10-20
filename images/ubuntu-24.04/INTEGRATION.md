# Ubuntu image builder: integration requests (ledger item P07)

P07 owns only `images/ubuntu-24.04/**` and `tests/images/ubuntu-24.04/**`. Nothing below is wired into the supervisor, the
helper, the providers or the catalog yet. Contracts: `parity/contracts/image-catalog.md` (revision 2),
`parity/contracts/backend-lifecycle.md` (revision 2, Storage tiers, budgets) and `parity/contracts/guest-transport.md`.

## What a build produces

| Output | Where | Shape |
|---|---|---|
| The sealed base disk | `<base_root>\ubuntu-24.04-x64\<image_version>-aap.<n>\base.vhdx` | Read-only file and folder: owner Administrators; SYSTEM, Administrators and `S-1-5-83-0` (Virtual Machines) read and execute; protected DACL; ReadOnly attribute |
| Generation entry | `<EvidenceRoot>\P07\<build id>\generation.json` | One image-catalog schema 2 `generations[]` item, `state` `candidate`, `built_by_item` `P07`, no overlays, no certificate |
| Budget | `...\budget.json` | backend-lifecycle schema 2 `budget` record, `profile` `linux`, `measured: true`, scratch 0 |
| Evidence | `...\build.json`, `secret-scan.json` | `plan_sha256`, `inputs_manifest_sha256`, `builder_commit`, waivers, media hash, the base deviation, phases with exec mode, script hashes and exit codes, the seal check, verification counts and facts, the inventory comparison (gate sections and recorded differences), measured bytes; the scan's findings, unreadable paths, large files with hashes |
| Guest-authored files | `...\software-report.md/.json`, `job-inventory.json` | Written by the build or verification guest; size-capped while received and hashed; `job-inventory.json` was also compared by P05's `certify.py` on the host |

`<build id>` is the generation id with `/` replaced by `_`. Build VMs are named `aap-lbuild-<8 hex>`, `aap-lscan-<8 hex>` and
`aap-lverify-<8 hex>` (SHA-256 of the build id), never the `aap-l-<slot>-...` pattern of runner clones, so reconcile can tell
them apart.

## What the sealed image holds, and what it does not

- The upstream provisioning result: `/imagegeneration` laid out as upstream (helpers, installers, SoftwareReport, tests,
  post-generation), the tool cache in `/opt/hostedtoolcache`, the action archive cache, services as upstream configured them,
  Docker, the `linux-azure` kernel, `walinuxagent` installed and masked, OpenSSH with password login off and no host keys
  (each clone generates its own at first boot).
- cloud-init cleaned and pointed at NoCloud only (`/etc/cloud/cloud.cfg.d/90-aap-nocloud.cfg`), so each clone takes its
  identity from its own `seed.iso`. `/etc/machine-id` is reset by `cloud-init clean --machine-id`.
- No install user, no job user, no password hash, no authorized key, no agent, no token, no runner, no zccache, no cache
  configuration and no registration material; those are overlays (P15/P21) or per-clone (P11). The seal check and the secret
  scan refuse an image with any of them. The build agent is removed at seal with its units, its `sockets.target.wants` link
  and its token; the seal check (`no-agent`) and the scan (`build-agent`, never allowlistable) both refuse any remnant, so a
  clone never carries a build agent.
- No per-machine secrets: the snakeoil TLS key and certificate and `/var/lib/systemd/random-seed` are deleted at seal (P15
  regenerates the key; systemd makes a new seed), and the journal is rotated and vacuumed.

## Dependency on P06 (`images/windows`)

The builder imports `images/windows/AapWinImage.psm1` by relative path and calls five of its functions:
`Read-AapStorageRecord`, `Get-AapPathKind`, `Assert-AapPlainPath`, `Remove-AapTree` and `Set-AapReadOnlyAcl`. They are shared,
not copied, so a fix in one place reaches both builders. A test pins each signature (names and order of its parameters) and
the module path; a P06 change that breaks P07 fails `tests/images/ubuntu-24.04` first. The builder's self-check refuses to
run unless `images/windows` passes the admin-only check like its own folder. P19 deploys `images/windows` and
`images/ubuntu-24.04` together, from the same commit, into the same admin-only tree.

## P11: Linux VM backend

1. **Clone settings the image needs.** Generation 2, Secure Boot on with the `MicrosoftUEFICertificateAuthority` template,
   static memory, one SCSI disk (the differencing `os.avhdx`), the per-clone `seed.iso` as a DVD, Guest Service Interface and
   Key-Value Pair Exchange off unless P02.1 picks KVP for host-key pinning (guest-transport.md, Linux candidate). No scratch
   disk: the image has none and a hosted Ubuntu job writes to its root file system. Nested virtualization
   (`ExposeVirtualizationExtensions`, hosted runners offer `/dev/kvm`) is a **security decision**, not a parity detail: it
   hands an untrusted job a hypervisor interface on the host. Decide it with the security review and record it with the
   profile; P07 did not verify it.
2. **Per-clone seed.** A host-built NoCloud ISO labelled `CIDATA` (`user-data`, `meta-data` with a fresh `instance-id`), the
   same mechanism P07 uses (`New-AapUbuntuSeed` shows the shape; the production writer is the provider's `NewSeedImage`). It
   creates the job user `runner` (uid 1001; groups `adm`, `users`, `docker`, `systemd-journal`; `sudo: ALL=(ALL) NOPASSWD:ALL`;
   `lock_passwd: true`) and delivers the management credential (guest-transport.md: the public key for the forced-command
   `authorized_keys` entry). The seed holds **only that public key**: never a JIT config, registration token or other
   reusable material, which travel over the management channel. Eject the seed after first boot (cloud-init's copy in
   `/var/lib/cloud` stays inside the clone, which is destroyed). Never write into the clone's disk from the host.
   **No account may get uid 1000**: the build's install user had it, and files it created may still be owned by 1000; the job
   user is 1001 like the hosted image.
3. **Management channel.** The image has no agent. P15's agent listens where guest-transport.md says (SSH over vsock 5222).
   P07's build agent used vsock **5223** with its own service GUID (`00001467-facb-11e6-bd58-64006a7986d3`) and is removed at
   seal (the seal check and the scan refuse any remnant), so the two never meet; the builder's `AF_HYPERV` client in
   `AapUbuntuImage.HyperV.psm1` (`AapHvChannel`) is a reference for the relay, not the relay.
4. **Base hash.** Every `create` re-hashes `base.vhdx` against the pin outside the roots (`approved-images.json`, P24
   certificate). P07's `generation.json` hash is input to that pin, not a substitute.
5. **Disks and mounts.** Acceptance input from P05: how the provider attaches and mounts job disks must keep the hosted root
   mount options (`discard,journal_async_commit,nobarrier,commit=30,data=writeback`) and block read-ahead (128) that the
   upstream scripts configure in the image; the verification records both (`facts.root_mount_options`,
   `facts.read_ahead_kb_root`).
6. **Budgets.** Admission counts `clone_gib_max` from `budget.json` and `scratch_gib_max` 0. The clone peak comes from the
   verification guest only; re-measure with real jobs (P22).
7. **Switch.** Clones attach only to `aap-guests-linux` (P10.0). The build VM needs that switch with internet egress during
   the install and the phases; the scanner and verification VMs have no adapter (read back after create). **Shared-switch
   hazard**: guest-transport.md names no build-only switch, so the build VM, which runs internet-sourced installers as root,
   shares `aap-guests-linux` (one L2 segment) with runner clones. The per-adapter ACLs deny the guest subnet except its
   gateway and the guards stop DHCP, router and MAC spoofing, but a build and running clones are still neighbours. P07
   recommends a build-only internal switch in the contract (for example `aap-build-linux`, its own subnet and NAT, the same
   controls); until the contract names one, P07 builds only on `aap-guests-linux`, and P12 should not admit Linux clones
   while a build runs if the owner wants them apart.

## P15: Linux guest bootstrap

- Run the post-generation scripts as root after the job user exists and before the runner starts, the way hosted
  provisioning does: each `*.sh` directly in `/imagegeneration/post-generation` through `bash`, in `find`'s order (they
  rewrite `$HOME`-relative entries such as `XDG_CONFIG_HOME` and the `/home/runner/...` PATH entries for the job user).
  Hosted uses `find ... -exec bash {} \;`, which ignores a script's exit code; P07's verification runs the same scripts in the
  same order but fails on any non-zero exit (`run_verify` in `guest/aap-agent.sh`). Do the same and keep them in step.
- Start the runner as `runner` with `/etc/environment` as the runner reads it; do not prepend tool paths machine-wide.
- `loginctl enable-linger` for the job user (upstream applies it to the last user in `/etc/passwd` after generation).
- Swap: the hosted runner shows 3 GiB (waagent's resource-disk swap on Azure); the image has none. Decide whether the clone
  creates a 3 GiB swap file at first boot (it then counts against the clone cap) or the difference stays allowlisted
  (`hardware.swap_bytes` is already in P05's allowlist).
- The image's `walinuxagent` is masked; leave it masked (there is no Azure fabric), and keep cloud-init on NoCloud.
- **Order matters**: run the post-generation scripts as root before the runner or any job starts, and never again in that
  clone. `/imagegeneration` is mode 777 (upstream's own `chmod 777`), so after a job has run anyone could have planted a
  script there.
- Regenerate the per-clone TLS test key at first boot (`make-ssl-cert generate-default-snakeoil --force-overwrite`, which the
  `ssl-cert` package uses); the image has none. `/var/lib/systemd/random-seed` is recreated by systemd.

## P10.0: guest network module

- `aap-guests-linux` must exist as an **Internal** switch before a build; the builder refuses otherwise and creates nothing.
- The build guest uses DHCP (autoinstall `network`: `dhcp4: true` on the `hv_netvsc` adapter) and needs DNS and internet
  egress to the Ubuntu archive, GitHub and the vendor feeds the upstream scripts use. Provide DHCP and DNS on the switch, or
  tell P07 the static addressing to put in the seed.
- **Adapter step interface.** `New-AapUbuntuHyperVProvider -GuestNetwork <scriptblock>` takes the module's per-adapter step.
  P07 calls it once per build VM, after connecting the adapter and setting DHCP guard on, router guard on and MAC spoofing
  off, with `@{ VmId = '<guid>'; SwitchName = 'aap-guests-linux' }`. It must add guest-transport.md's full extended port ACL
  set to that VM's adapter: deny the host's vEthernet addresses (except the DHCP and DNS endpoints the design uses), RFC 1918,
  169.254.0.0/16, 100.64.0.0/10, multicast (224.0.0.0/4, ff00::/8), fe80::/10, fc00::/7, the LAN's IPv6 prefix and the guest
  subnet except its gateway; allow internet egress. It throws on failure. P07 then reads the adapter back
  (`Get-VMNetworkAdapter`, `Get-VMNetworkAdapterExtendedAcl`) and refuses (`AAP_NetworkUntrusted`) unless the guards are set
  and every fixed range has an outbound Deny entry. **Open item for P10.0**: the host-specific entries (vEthernet addresses,
  LAN prefix, subnet) depend on the module's design; P07 cannot verify them and P10.0 must prove them in the lab (negative
  cases of guest-transport.md). Until the module exists there is no `-GuestNetwork` to pass and no build.
- The shared-switch hazard above (P11 item 7) is a request for a build-only switch.

## P19: installer, helper, storage

- The builder needs a valid storage document with admin-only `base_root` and staging root on their recorded volumes, and an
  admin-only `EvidenceRoot`; it refuses otherwise.
- Register the build channel's hvsocket service GUID `00001467-facb-11e6-bd58-64006a7986d3` (vsock port 5223) under
  `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\GuestCommunicationServices`, through the existing
  elevated helper, **only for the duration of a build** (register before, remove after, also after a failed build), beside
  the runtime GUID guest-transport.md names. Nothing else on the host may listen on or connect to that GUID.
- Deploy `images/ubuntu-24.04`, `images/windows` (the shared helpers; same commit, see Dependency on P06), `images/common`
  and `tools/parity-certify` (probe, comparison, allowlist, `workloads/fixtures/hello.c`) to an Administrators-only folder
  and run the builder from there; it refuses (`AAP_BuilderUntrusted`) unless each of those folders passes the admin-only
  check. The check runs after the modules loaded (README, Trust in the builder's own files): the admin-only deployment is
  the protection, the check proves it is in place.
- Deploy a python 3 for the comparison into an Administrators-only folder (or have the installer vendor a pinned embeddable
  python there) and pass its absolute path to `New-AapUbuntuHyperVProvider -PythonPath`. `-I` keeps user site-packages and
  environment variables out but not a writable standard library, so the install folder itself must pass the admin-only
  check, which the builder runs on it (`ExecFolders`). The Store alias in `%LOCALAPPDATA%\Microsoft\WindowsApps` is refused.
  The comparison is stdlib-only and runs hidden.
- The ISO is no longer copied by P19: it is the P03 entry the plan pins (`inputs.media`), staged and verified by P03.
- Pass the owner-approved values: `BuildCpus` 4, `BuildMemGib` 10, `BaseGibMax` 186 and `JobDiskGibMax` 55 (the builder
  refuses more), `StagingGibMax` within what the staging volume holds above its floor.
- A build runs for hours, elevated, with no console. Run it from the hidden supervisor context or a helper verb that starts
  it hidden; never hand the owner a script.

## P12: supervisor and status

- Surface a running build (generation id, phase id) and a failed build's `Reason` in `status.v5.json`; never its `Detail`
  unfiltered.
- Never render `software-report.md` (guest-authored Markdown); show its hash at most.
- Admission refuses the Ubuntu profile until a generation has a measured `budget.json`.
- Admission counts a running build VM: 4 vCPU and 10 GiB static memory (plus its worker overhead), the build folder up to
  `StagingGibMax` on the staging volume, and one `os_disk_gib` copy on the base volume while it publishes. One image build at
  a time (the builder's `aap-image-build.lock`).
- The build channel has no sequence number or nonce, unlike guest-transport.md's runtime envelope: every connection is
  initiated by the host, carries the per-guest token and one request, and the agent with its token is removed at seal. That is
  acceptable only because no clone ever runs it.

## P21, P24, P25: catalog, certificate, operations

- P21 inserts `generation.json` into `catalog.json` (scope `lab` until D5) after checking `build.json`: `plan_sha256` against
  the reviewed `build-plan.json`, `inputs_manifest_sha256` against the P03 manifest, `builder_commit` against the deployed
  builder, every waiver as a chair approval record for that plan. Waivers come only from a committed, reviewed file in the
  repository, never from the inbox or a hand-made config.
- P24 certifies the candidate. The build-time verification (upstream tests, discovery, the gated comparison) is evidence,
  not the certificate. Re-run the comparison on the final overlaid image, reconcile the full Readme inventory
  (`parity/baselines/ubuntu-24.04-x64/inventory.json`, which P05's probe does not cover), and decide every difference
  `build.json` recorded: the kernel build, read-ahead and mount options need a match or a reviewed allowlist entry before
  approval. Audit `secret-scan.json` `large_files`.
- P25 rebuilds `aap.<n+1>` when a P03 blocker, a waiver or the upstream pin changes.

## P03: inputs

- P03.1 (chair) adds a literal-pinned entry for the `actions/runner-images` archive at
  `7e7dc1bcc0ef464e5e315a2b4c33609590c6cffe` as `.tar.gz` (images/ubuntu scripts, assets, toolsets, and
  helpers/software-report-base; the agent requires exactly one top-level folder). Then rerun
  `New-AapUbuntuBuildPlan.ps1 -ScriptsDir <extracted images\ubuntu\scripts> -SourceEntry <entry> -SourceSha256 <hex>` with
  pwsh 7: it pins the 72 script hashes and the archive and drops `p07-upstream-source-archive`.
- Add the Ubuntu 24.04 live-server ISO with Canonical's signed `SHA256SUMS` as its hash source, then rerun the generator with
  `-MediaEntry <entry> -MediaSha256 <hex>` (drops `p07-ubuntu-server-media`).
- Both of those blockers are **unwaivable**: a waiver for either is `AAP_ConfigInvalid`. The 14 P03 Ubuntu blockers and
  `p07-upstream-variables-unverified` stay waivable: each resolved, or waived by id with a chair approval record (`id`,
  `rationale`, `plan_sha256`, `approver`) passed in `Waivers` and recorded in `build.json`.

## P06.1 (opened by the coordinator for the Windows twin)

- The same per-adapter controls and post-condition the Ubuntu provider now has (DHCP guard, router guard, MAC spoofing,
  the P10.0 ACL step, read back before start; zero adapters on VMs without a switch).
- One image build at a time across both builders: take `<staging root>\build\aap-image-build.lock`, the lock P07 takes.

## guest-transport.md: open item (for the coordinator to amend)

The build channel is not in the contract: vsock port **5223**, service GUID `00001467-facb-11e6-bd58-64006a7986d3`, a P07
build-time agent (`aap1 <token> <verb> <name> <length>`, verbs `ready`, `bootid`, `put`, `get`, `run`, `reboot`), host
initiated, per-guest token from a host-built seed, replies capped while received, no sequence number or nonce, removed at
seal. It must never be reachable on a runner clone and never share the runtime GUID or port 5222. The contract should name
it, its registration window (P19) and the rule that no clone image may contain it.

## CI (the coordinator adds)

- shellcheck 0.11.0 at `-S warning` over `images/ubuntu-24.04/guest/*.sh`, `tests/images/ubuntu-24.04/guest_test.sh` and
  `tests/images/ubuntu-24.04/guest_mutations.sh`. Neither this host nor WSL Ubuntu-24.04 has shellcheck, and downloads are
  forbidden here, so P07 has not run it.
- Pester `Run.Path` += `tests/images/ubuntu-24.04` (Windows PowerShell 5.1 and pwsh 7).
- A bash step on hosted ubuntu: `bash tests/images/ubuntu-24.04/guest_test.sh` (python3, coreutils, gzip only).

## Decisions taken here (for review)

1. **No host mount of a guest file system, ever.** Files in: host-built seed ISOs. Files out: the capped hvsocket channel.
   Secret scan: in a scanner guest from the pinned ISO. This replaces P06's offline writes and read-only host mount, which
   cannot apply to ext4 and would make the host parse guest metadata.
2. **Base**: the live-server ISO with `linux-azure` and a masked `walinuxagent`, as the closest local base to the Azure image;
   the Azure-base blocker still needs a chair waiver.
3. **OS disk 150 GiB** from the hosted capture, not the 75 GB build disk, so a job sees the hosted free space.
4. **Inventory gate**: the build fails on differences in cached tool versions, services, PATH order, the action archive
   cache, the job user and probe coverage, and on anything the reference requires that the image lacks in any section; it
   records the rest, extras included, for P24.
5. **Verification network**: none, as in P06.
6. **Inputs are pinned in the plan, not passed in config**: the source archive and the ISO by P03 entry and SHA-256.
7. **Scanner boots without a disk**; the sealed disk is hot-added after the live system answers.
