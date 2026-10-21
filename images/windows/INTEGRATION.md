# Windows image builder: integration requests (ledger item P06)

P06 owns only `images/windows/**` and `tests/images/windows/**`. Nothing below is wired into the supervisor, the helper,
the providers or the catalog yet. Contracts: `parity/contracts/image-catalog.md` (revision 2) and
`parity/contracts/backend-lifecycle.md` (revision 2, Storage tiers, budgets).

## What a build produces

| Output | Where | Shape |
|---|---|---|
| The sealed base disk | `<base_root>\win25-vs2026-x64\<image_version>-aap.<n>\base.vhdx` | Read-only file and folder: owner Administrators; SYSTEM, Administrators and `S-1-5-83-0` (Virtual Machines) read and execute; protected DACL; ReadOnly attribute |
| Generation entry | `<EvidenceRoot>\P06\<build id>\generation.json` | One image-catalog schema 2 `generations[]` item, `state` `candidate`, `built_by_item` `P06`, no overlays, no certificate |
| Budget | `...\budget.json` | backend-lifecycle schema 2 `budget` record, `measured: true` |
| Evidence | `...\build.json`, `secret-scan.json` | `plan_sha256`, `inputs_manifest_sha256`, `builder_commit`, phase-by-phase script hashes, exit codes and elevation, media hash and edition, waiver approval records, the guest registry check, evaluation dates, verification counts, measured bytes; the scan's findings, unreadable and skipped paths, large files with hashes |
| Guest-authored files | `...\software-report.md/.json`, `job-inventory.json` | Written by the build or verification guest; size-capped while received, hashed in `build.json`, otherwise unchecked |

`<build id>` is the generation id with `/` replaced by `_`. Build VMs are named `aap-wbuild-<8 hex>` and
`aap-wverify-<8 hex>` (SHA-256 of the build id), never the `aap-w-<slot>-...` pattern of runner clones, so reconcile can
tell them apart.

## P10: Windows VM backend

1. **Clone settings the image needs.** Generation 2; Secure Boot off (upstream sets `TESTSIGNING ON`); nested
   virtualization exposed (`ExposeVirtualizationExtensions`, the image enables Hyper-V, Containers and WSL2); the scratch
   disk as the second disk, which becomes `D:` (hosted `D:` is the temp disk; `TEMP_DIR` was `D:\temp`). Secure Boot off,
   `TESTSIGNING` on and nested virtualization in a guest that runs untrusted jobs are a chair-accepted risk for parity with
   the hosted image; record that acceptance with the profile. Decide for clones whether Key-Value Pair Exchange stays off,
   as it is for the build and verification VMs, or is the credential channel (guest-transport.md sub-candidate b).
2. **Per-clone answer file.** Use the exported `New-AapWinUnattend -UserName runneradmin -Password <per-clone>` and write it
   offline to `Windows\Panther\unattend.xml` in `os.avhdx` before the first boot, never into the base. It sets
   `SanPolicy` 1 in specialize: without it a generalized Server image leaves the scratch disk offline. It never enables
   autologon. First boot runs specialize and OOBE; budget minutes, not seconds, for the first `ready`. Write it only before
   first boot, through a path walk that refuses any reparse point from the partition root to the file
   (`Write-AapGuestFile`, partition chosen by `Select-AapWindowsPartition`); never mount a clone's disk after a job ran.
3. **Base hash.** Every `create` re-hashes `base.vhdx` against the pin outside the roots
   (`approved-images.json`, P24 certificate). P06's `generation.json` hash is input to that pin, not a substitute.
4. **Differencing children of a read-only parent.** Prove in the lab that Hyper-V attaches `os.avhdx` without needing
   write or ACL changes on `base.vhdx`; P06's ACL already grants the Virtual Machines group read.
5. **Budgets.** Admission counts `clone_gib_max` and `scratch_gib_max` from `budget.json`. The scratch disk is 150 GiB
   like the hosted `D:` (`temp_disk_gib`); the scratch peak comes from the verification guest only, so re-measure with
   real jobs (P22).
6. **Guest transport.** The build and verification guests run internet-sourced installers and are treated as hostile:
   replies are size-capped while received, files received from the guest land in the build folder first, and no host path
   is ever resolved through guest-authored file system metadata (reparse points refused). The builder reaches them over
   PowerShell Direct by VM id with capped receives (`Receive-AapCappedJob`); runner clones use P10's hardened transport
   (guest-transport.md, wire framing). The image does not contain `C:\Program Files\aap-guest`.
7. **Switch.** The build VM is on its own switch, `aap-build-win`, never a guest switch and never shared: no runner clone is
   ever admitted beside a build VM (host-network-module.md, Switches). The verification VM has no network adapter, read
   back from Hyper-V before it boots.

## P10.0: host network module

The builder conforms to `parity/contracts/host-network-module.md` (version 1) as its row in Conformance of the consumers
says, and takes the module as `-Network` (`Attach`, `Detach`, `Verify`, each called with exactly
`@{ VmId; VmName; Profile = 'windows' }` for the build VM `aap-wbuild-<8 hex>`). The VM arrives Off, with no adapter,
automatic start `Nothing` and checkpoints off. Before its first start and before each start after a reboot (a reboot is a
shutdown and a start): `Attach`, `Get-AapHostNetworkDeclarationProblems`, before the first start the answer file with the
declaration's static addressing, `Verify` (every object it writes is a problem) and `Get-AapHostNetworkAdapterProblems` on
the provider's `GetVmNetwork`; a later `Attach` must declare the addressing the answer file carries. While it runs, the
wait for a shutdown included: `Verify` and the read-back at most every 30 seconds. Teardown: `RemoveVm`, then `Detach`, on
every failed run too, by the VM id `state.json` records at `NewVm`, so the next run of a crashed build id detaches it.
Stopping `aap-wbuild-*` VMs whose build lock nobody holds is the P12/P19 reconcile (ledger), not the builder's. The check is imported from `supervisor\network` only after that folder passes the admin-only check.

## P14: Windows guest bootstrap

- The base image holds the upstream provisioning result: `C:\image` laid out as upstream, the TestsHelpers and ImageHelpers
  modules, the tool cache, services as upstream configured them, the software report at `C:\software-report.*`.
- It does **not** hold the Actions runner, the guest agent, zccache, cache configuration or any registration material:
  those are overlays (`overlays[]`, P14/P21), and the secret scan refuses an image with runner credential files.
- The local user `installer` exists (upstream's install user; `Configure-User.ps1` copied its profile settings to the
  default user), disabled, with a random password nobody knows.
- The job user is created per clone by P10's answer file (`runneradmin`, local administrator), the same name P06 verified
  with. Configure the runner as that user. Developer environments are entered per job (`VsDevCmd`), as on hosted runners;
  do not prepend compiler paths machine-wide.
- Upstream sets `PGUSER`/`PGPASSWORD` machine-wide with the public default from the upstream Readme; P06 does not change
  that (parity), and the secret scan does not look for it.

## P19: installer, helper, storage

- The builder needs a valid storage document (`storage.json`) with admin-only `base_root` and staging root on their
  recorded volumes; it refuses otherwise and creates, repairs or re-permissions nothing above its own build and generation
  folders.
- `EvidenceRoot` must be admin-only (protected DACL, Administrators and SYSTEM only, no reparse point on it or its
  ancestors); the builder trust-checks it like the storage roots.
- Create the build switch `aap-build-win` (internal, its own subnet, NAT, the host firewall rules, no DHCP or DNS service;
  host-network-module.md, Switches) before the first build, and pass the P10.0 module as `-Network`.
- Deploy `images/windows`, `images/common`, `supervisor/network` and the verification payload it sends (`tools/parity-certify/probe/windows.ps1`,
  `tools/parity-certify/workloads/fixtures/hello.c`) to an Administrators-only folder and run the builder from there. Never
  run the elevated builder from a user-writable checkout: it refuses (`AAP_BuilderUntrusted`) unless its own folder,
  `guest`, `images/common`, `supervisor/network` and both payload folders pass the admin-only check.
- Copy the owner's evaluation ISO into `<base_root>\media\` (admin-only) and pin its SHA-256 in an admin-only record the
  caller passes as `MediaSha256`; the full hash is not in this repository.
- Pass the owner-approved values: `BuildCpus` 4, `BuildMemGib` 10, `BaseGibMax` 186 and `JobDiskGibMax` 55 (GiB, from the
  200 GB and 60 GB of the 2026-10-20 approval), `StagingGibMax` within what the staging volume holds above its floor.
- Record the host's Windows build and update level with each build: mounting a guest-built disk makes the host kernel
  parse guest-authored NTFS (chair-accepted risk), so the host stays on current security updates.
- A build runs for hours, elevated, with no console. Run it from the hidden supervisor context or a helper verb that
  starts it hidden; never hand the owner a script.
- Import `AapWinImage.psm1` before `New-AapWinHyperVProvider`; the provider imports `images/common/AapArtifact.psm1` and
  its manifest by relative path, and only after `images/common` passes its admin-only check (README, What the builder's
  self-check protects).

## P12: supervisor and status

- Surface a running build (generation id, phase id) and a failed build's `Reason` in `status.v5.json`; never its `Detail`
  unfiltered (it is printable ASCII and bounded, but it can name paths).
- Never render `software-report.md` (guest-authored Markdown); show its hash at most.
- Read `build.json` `evaluation.rebuild_by` and `expires_at` for the `stale` and quarantine rules of image-catalog.md.
- Admission refuses the Windows profile until a generation has a measured `budget.json` (backend-lifecycle.md).

## P21, P24, P25: catalog, certificate, operations

- P21 inserts `generation.json` into `catalog.json` (scope `lab` until D5), adds overlays and, if it reseals, a new
  generation id. Before that, check `build.json`: `plan_sha256` against the reviewed `build-plan.json`,
  `inputs_manifest_sha256` against the P03 manifest, `builder_commit` against the deployed builder, and every waiver as a
  chair approval record (`id`, `rationale`, `plan_sha256`, `approver`) for that same plan.
- `software-report.md/.json` and `job-inventory.json` are guest-authored: P06 only caps their size and records their
  hashes. P24 schema-checks them (and caps them again) before comparing anything.
- P24 certifies the candidate: the verification here (upstream tests, inventory, discovery) is build-time evidence, not the
  certificate; compare `job-inventory.json` against the hosted baseline with `tools/parity-certify`. Audit
  `secret-scan.json` `large_files` and `skipped`.
- P25 schedules `aap.<n+1>` before `rebuild_by`, and builds when a P03 blocker or waiver changes.

## P03: inputs

- P03.1 (chair) adds a literal-pinned entry for the `actions/runner-images` archive at
  `aee0669dd04510a11756664eb77f5630debabed3` (images/windows scripts, assets, toolsets, helpers/software-report-base). Then
  rerun `New-AapWinBuildPlan.ps1 -ScriptsDir <extracted images\windows\scripts> -SourceSha256 <the entry's SHA-256>`
  (and `-SourceEntry <name>` if the entry is not `runner-images-aee0669`) with pwsh 7 to pin the 82 script hashes and the
  archive; that drops `p06-upstream-source-archive`, which no waiver clears.
- The 14 Windows blockers stay blockers. A build needs each resolved, or waived by id with a chair approval record
  (`id`, `rationale`, `plan_sha256`, `approver`) passed in `Waivers` and recorded in `build.json`; a bare id is refused.
  `windows-server-2025-media` is never waivable: the builder's media check against the pinned `MediaSha256` clears it.

## Decisions recorded (chair, 2026-10-20)

1. **Secret-scan allowlist**: exact path plus SHA-256 pairs only, in the reviewed `secret-allowlist.json`, each with a
   justification; any mismatch fails. Empty now.
2. **Waivers**: by id, each with a chair approval record bound to the plan hash.
3. **Registry checks**: in the guest as SYSTEM just before sysprep, returned in the capped reply; the host scans files only
   and loads no guest hive. Host parsing of guest NTFS on mount is an accepted risk with a host patch-level requirement.
4. **Scratch disk**: 150 GiB like the hosted `D:`; not a gap.
5. **runner-images archive entry**: P03.1.
6. **Verification network**: the verification VM stays without network. An upstream test that needs the network fails by
   name and is handled by a waiver (approval record bound to `plan_sha256`) or decided in the D2 lab; the verify VM never
   gets the switch.
