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
  scan refuse an image with any of them.

## P11: Linux VM backend

1. **Clone settings the image needs.** Generation 2, Secure Boot on with the `MicrosoftUEFICertificateAuthority` template,
   static memory, one SCSI disk (the differencing `os.avhdx`), the per-clone `seed.iso` as a DVD, Guest Service Interface and
   Key-Value Pair Exchange off unless P02.1 picks KVP for host-key pinning (guest-transport.md, Linux candidate). No scratch
   disk: the image has none and a hosted Ubuntu job writes to its root file system. Decide nested virtualization
   (`ExposeVirtualizationExtensions`, hosted runners offer `/dev/kvm`) and record it with the profile; P07 did not verify it.
2. **Per-clone seed.** A host-built NoCloud ISO labelled `CIDATA` (`user-data`, `meta-data` with a fresh `instance-id`), the
   same mechanism P07 uses (`New-AapUbuntuSeed` shows the shape; the production writer is the provider's `NewSeedImage`). It
   creates the job user `runner` (uid 1001; groups `adm`, `users`, `docker`, `systemd-journal`; `sudo: ALL=(ALL) NOPASSWD:ALL`;
   `lock_passwd: true`) and delivers the management credential (guest-transport.md: the public key for the forced-command
   `authorized_keys` entry). Never write into the clone's disk from the host.
3. **Management channel.** The image has no agent. P15's agent listens where guest-transport.md says (SSH over vsock 5222).
   P07's build agent used vsock **5223** with its own service GUID (`00001467-facb-11e6-bd58-64006a7986d3`) and is deleted at
   seal, so the two never meet; the builder's `AF_HYPERV` client in `AapUbuntuImage.HyperV.psm1` (`AapHvChannel`) is a
   reference for the relay, not the relay.
4. **Base hash.** Every `create` re-hashes `base.vhdx` against the pin outside the roots (`approved-images.json`, P24
   certificate). P07's `generation.json` hash is input to that pin, not a substitute.
5. **Disks and mounts.** Acceptance input from P05: how the provider attaches and mounts job disks must keep the hosted root
   mount options (`discard,journal_async_commit,nobarrier,commit=30,data=writeback`) and block read-ahead (128) that the
   upstream scripts configure in the image; the verification records both (`facts.root_mount_options`,
   `facts.read_ahead_kb_root`).
6. **Budgets.** Admission counts `clone_gib_max` from `budget.json` and `scratch_gib_max` 0. The clone peak comes from the
   verification guest only; re-measure with real jobs (P22).
7. **Switch.** Clones attach only to `aap-guests-linux` (P10.0). The build VM needs that switch with internet egress during
   the install and the phases; the scanner and verification VMs have no adapter.

## P15: Linux guest bootstrap

- Run the post-generation scripts as root after the job user exists and before the runner starts, the way hosted
  provisioning does: `find /imagegeneration/post-generation -mindepth 1 -maxdepth 1 -type f -name '*.sh' -exec bash {} \;`
  (they rewrite `$HOME`-relative entries such as `XDG_CONFIG_HOME` and the `/home/runner/...` PATH entries for the job user).
  P07's verification does exactly this; keep them in step.
- Start the runner as `runner` with `/etc/environment` as the runner reads it; do not prepend tool paths machine-wide.
- `loginctl enable-linger` for the job user (upstream applies it to the last user in `/etc/passwd` after generation).
- Swap: the hosted runner shows 3 GiB (waagent's resource-disk swap on Azure); the image has none. Decide whether the clone
  creates a 3 GiB swap file at first boot (it then counts against the clone cap) or the difference stays allowlisted
  (`hardware.swap_bytes` is already in P05's allowlist).
- The image's `walinuxagent` is masked; leave it masked (there is no Azure fabric), and keep cloud-init on NoCloud.

## P10.0: guest network module

- `aap-guests-linux` must exist as an **Internal** switch before a build; the builder refuses otherwise and creates nothing.
- The build guest uses DHCP (autoinstall `network`: `dhcp4: true` on the `hv_netvsc` adapter) and needs DNS and internet
  egress to the Ubuntu archive, GitHub and the vendor feeds the upstream scripts use. Provide DHCP and DNS on the switch, or
  tell P07 the static addressing to put in the seed.

## P19: installer, helper, storage

- The builder needs a valid storage document with admin-only `base_root` and staging root on their recorded volumes, and an
  admin-only `EvidenceRoot`; it refuses otherwise.
- Register the build channel's hvsocket service GUID `00001467-facb-11e6-bd58-64006a7986d3` (vsock port 5223) under
  `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\GuestCommunicationServices`, through the existing
  elevated helper, beside the runtime GUID guest-transport.md names.
- Deploy `images/ubuntu-24.04`, `images/windows` (the shared helpers), `images/common` and `tools/parity-certify` (probe,
  comparison, allowlist, `workloads/fixtures/hello.c`) to an Administrators-only folder and run the builder from there; it
  refuses (`AAP_BuilderUntrusted`) unless each of those folders passes the admin-only check.
- Deploy a python 3 for the comparison into an Administrators-only folder and pass its absolute path to
  `New-AapUbuntuHyperVProvider -PythonPath`. The comparison is stdlib-only and runs hidden.
- Copy the official Ubuntu 24.04 live-server ISO (the hosted image reports 24.04.5) into `<base_root>\media\` and pin its
  SHA-256 in an admin-only record the caller passes as `MediaSha256`.
- Pass the owner-approved values: `BuildCpus` 4, `BuildMemGib` 10, `BaseGibMax` 186 and `JobDiskGibMax` 55, `StagingGibMax`
  within what the staging volume holds above its floor.
- A build runs for hours, elevated, with no console. Run it from the hidden supervisor context or a helper verb that starts
  it hidden; never hand the owner a script.

## P12: supervisor and status

- Surface a running build (generation id, phase id) and a failed build's `Reason` in `status.v5.json`; never its `Detail`
  unfiltered.
- Never render `software-report.md` (guest-authored Markdown); show its hash at most.
- Admission refuses the Ubuntu profile until a generation has a measured `budget.json`.

## P21, P24, P25: catalog, certificate, operations

- P21 inserts `generation.json` into `catalog.json` (scope `lab` until D5) after checking `build.json`: `plan_sha256` against
  the reviewed `build-plan.json`, `inputs_manifest_sha256` against the P03 manifest, `builder_commit` against the deployed
  builder, every waiver as a chair approval record for that plan.
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
  `New-AapUbuntuBuildPlan.ps1 -ScriptsDir <extracted images\ubuntu\scripts>` with pwsh 7 to pin the 72 script hashes, and drop
  the plan blockers it resolves.
- Add the Ubuntu 24.04 live-server ISO with Canonical's signed `SHA256SUMS` as its hash source (resolves
  `p07-ubuntu-server-media`).
- The 14 Ubuntu blockers stay blockers. A build needs each resolved, or waived by id with a chair approval record (`id`,
  `rationale`, `plan_sha256`, `approver`) passed in `Waivers` and recorded in `build.json`.

## Decisions taken here (for review)

1. **No host mount of a guest file system, ever.** Files in: host-built seed ISOs. Files out: the capped hvsocket channel.
   Secret scan: in a scanner guest from the pinned ISO. This replaces P06's offline writes and read-only host mount, which
   cannot apply to ext4 and would make the host parse guest metadata.
2. **Base**: the live-server ISO with `linux-azure` and a masked `walinuxagent`, as the closest local base to the Azure image;
   the Azure-base blocker still needs a chair waiver.
3. **OS disk 150 GiB** from the hosted capture, not the 75 GB build disk, so a job sees the hosted free space.
4. **Inventory gate**: the build fails on differences in cached tool versions and defaults, services, PATH order, the action
   archive cache, the job user and probe coverage; it records the rest for P24.
5. **Verification network**: none, as in P06.
