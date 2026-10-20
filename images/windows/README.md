# images/windows: the Windows Server 2025 / VS2026 golden image builder (P06)

Builds one immutable generation `win25-vs2026-x64/20261007.264.1-aap.<n>` of the native Windows runner image on a local
Hyper-V host, from the owner's Windows Server 2025 Evaluation media and the provisioning of `actions/runner-images` at the
P01 build commit `aee0669`. PowerShell 5.1 (the supervisor's host) and PowerShell 7.

**Status: authored and tested with fakes only.** No VM was created, no Hyper-V cmdlet ran, no media was read and nothing
was downloaded. The first real run is the D2 lab (see [What is not done](#what-is-not-done)). The committed plan is
deliberately not runnable yet: its upstream script hashes are not pinned, so the builder refuses with `AAP_ScriptUnpinned`.

| File | Role |
|---|---|
| `AapWinImage.psm1` | The builder: storage and trust checks, plan, blockers and waivers, answer files, the phase loop, secret scan, fresh-guest verification, publication, generation and budget records, and the path, ACL and capped-receive helpers the provider uses. Calls nothing on the host except through the provider |
| `AapWinImage.HyperV.psm1` | The production provider (`New-AapWinHyperVProvider`, load `AapWinImage.psm1` first): every Hyper-V, Storage, DISM, PowerShell Direct and ACL call. Not run by P06 |
| `New-AapWinBuildPlan.ps1` | Generates `build-plan.json` from the pinned template; reads files only; pwsh 7 for the committed plan |
| `build-plan.json` | The phase table: one phase per upstream provisioner, in template order |
| `secret-allowlist.json` | Reviewed secret-scan exceptions, exact path plus SHA-256 pairs; empty |
| `guest/AapGuestRunner.ps1` | Runs one phase inside the build guest and prints one JSON reply line |
| `guest/AapGuestVerify.ps1` | Runs in a fresh guest of the sealed image as the job user: upstream tests, P05 inventory probe, toolchain discovery |
| `INTEGRATION.md` | What P10, P14, P19, P12 and the catalog owners must do with this |

## Hostile guests

The build and verification guests run internet-sourced installers and are treated as hostile: replies are size-capped
while received, files received from the guest land in the build folder first, and no host path is ever resolved through
guest-authored file system metadata (reparse points refused). In detail:

- Only the runner-images archive goes through P03. The 81 build scripts it holds then download and run hundreds of
  installers from the internet, so nothing a guest says or writes is trusted, from the first phase on.
- Every call into a guest (PowerShell Direct, addressed by VM id), file transfers in both directions included, runs as a
  job that is checked while it arrives and stopped at the first violation: an output item that is not text or bytes, more
  than 16 error, warning, verbose, debug, information or progress records (their size cannot be measured; honest calls emit
  none), or more bytes than the cap: 64 KiB for a reply, 16 MiB for a software report, 4 MiB for the inventory. Residual:
  before a poll trips a cap, the host may hold one 5-second poll of output and up to 16 records, each up to the PowerShell
  remoting per-object limit. A call that fails is `AAP_GuestUnreachable`, never an empty answer. Files go to the guest in
  1 MiB chunks, one capped call each. Received files are written to `<build folder>\recv-<name>.part` with create-new
  semantics, size-checked, then moved into the evidence folder; a partial or oversized file is deleted.
- Offline writes into a guest disk (the verification answer file) go through `Write-AapGuestFile`: every folder from the
  partition root down must be a plain folder, an existing plain file is deleted, and the new one is created with
  `CreateNew`. The Windows partition is chosen by the layout the builder made (EFI, MSR, one basic data partition), never by
  searching for `\Windows`, so a decoy partition is refused.
- The host reads no guest registry hive. The registry checks run inside the guest as SYSTEM just before sysprep and come
  back in the capped reply; the host-side scan of the sealed disk reads files only.
- **Accepted risk** (chair, 2026-10-20): mounting a guest-built disk (`Mount-VHD`, read-only for the scan, read-write
  only before the verification child's first boot) makes the host kernel parse guest-authored NTFS metadata. Keep the
  Hyper-V host on current Windows security updates; P19 records the host patch level with each build.

## Build flow

`Invoke-AapWinImageBuild -Config <hashtable> -Provider <hashtable>` returns `Ok`, `Status` (`built`, `unchanged`,
`refused`, `failed`), `Reason`, `Detail`, `GenerationId` and the record paths. A `refused` run changed nothing. A `failed`
run removed everything it made (VMs, build disks, a partly published generation, the evidence files it wrote) and kept
only `secret-scan.json` when the scan ran, as the record of why it failed.

1. **Preflight** (refusals, nothing written): provider completeness; the builder's own folder, `guest`, `images\common`
   and the folders of the verification payload (`tools\parity-certify\probe`, `tools\parity-certify\workloads\fixtures`)
   must pass the same admin-only trust check as the roots (folders, not each file); config; the storage document; trust of the storage document's
   folder, `base_root`, the staging root (admin-only, on the recorded volume) and the evidence root; the internal switch
   `aap-guests-win`; the plan (every script hash pinned, `image_version` of the form `yyyymmdd.n.n`); input blockers (each
   P03 Windows blocker and each plan blocker resolved, or waived by a chair approval record for this plan); no reparse
   point on the way to the evidence, build and generation folders; the build lock; a partial build of the same id
   (cleaned); an existing generation (idempotent `unchanged`, or refused); existing evidence for the id (refused); free
   space above the floor on each volume; the media hash; and P03's offline verification of the upstream source archive and
   any other input.
2. **Disks**: a dynamic `os.vhdx` of the upstream OS disk size (150 GiB, `os_disk_size_gb` of `win25-vs2026` in the pinned
   locals) and a formatted `temp.vhdx` that becomes `D:` (hosted runners have `D:` as their temp disk, `TEMP_DIR` is
   `D:\temp`). The edition is applied from the ISO's `install.wim` (DISM, no Setup UI), with a build answer file and the
   guest runner written offline before the first boot.
3. **Build VM**: generation 2, Secure Boot off (upstream sets `bcdedit TESTSIGNING ON`), nested virtualization exposed
   (upstream enables Hyper-V, Containers and WSL2), checkpoints off, Guest Service Interface and Key-Value Pair Exchange
   off, one network adapter on the internal switch `aap-guests-win` (refused unless it exists with type Internal; never an
   External switch or the Default Switch), files in the build folder. Enhanced Session is never enabled by the builder; it
   opens no console to the VM.
4. **Phases** p01-p29 in upstream order (below). Each upstream script runs through Packer's wrapper
   (`& { $ProgressPreference='SilentlyContinue'; <env>; &'<script>'; exit $LastExitCode }`, written to a file and run with
   `-File`), so exit codes match upstream. Phases upstream marks `elevated_user` (p07 bcdedit, p13 Visual Studio, p19 LLVM
   and Windows Updates) run as a scheduled task of the install user with `RunLevel Highest`, as Packer does, with logon
   type S4U so no password is stored in the task. A reboot counts only when the guest answers again with a later boot time
   than before `Restart-VM`; a guest that does not answer meanwhile is waited for until the phase timeout. After each phase the build folder is measured against `StagingGibMax`.
5. **Seal**: the last phase deletes every answer file, gives the install user a fresh random password that never leaves the
   guest and disables it, runs the registry check as SYSTEM (Winlogon `DefaultPassword` and `AutoAdminLogon`, the LSA
   `DefaultPassword` secret; any finding or unreadable value stops here, before sysprep), removes `C:\aap-build`, runs
   `Sysprep /oobe /generalize /mode:vm /quiet /quit` and waits for `IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE`, as upstream
   does. The host shuts the VM down, removes it, deletes the temp disk, compacts and hashes `os.vhdx`.
6. **Secret scan** of the sealed disk, mounted read-only, files only (rules below). Anything but `clean` fails the build.
7. **Fresh-guest verification**: a differencing child of the sealed disk, a new answer file that creates the job user
   `runneradmin` (local administrator, as on the hosted image), **no network adapter**, and `AapGuestVerify.ps1` as that
   user: the pinned upstream Pester tests (`RunAll-Tests.ps1`), the full P05 inventory probe (`job-inventory.json`, Docker
   included) and native discovery through `vswhere` and `VsDevCmd` (cl, link, clang-cl, lld-link, rc, msbuild, cmake,
   ninja, the Windows SDK headers, a C program built and run with MSVC and with clang-cl, a resource compiled with rc). It
   passes only with at least one upstream test, no failed test, every discovery item and an inventory whose hash matches
   what the guest reported. The clone and scratch peaks, the VM memory overhead and the build folder with the verification
   disks still in it are measured here. The sealed disk is hashed again afterwards and must be unchanged.
8. **Publish**: the generation folder is created new (it must not exist), and only then is publication recorded as this
   run's, so a cleanup never removes a folder someone else made. `base.vhdx` is copied in, re-hashed against the sealed
   hash, then made read-only (owner Administrators; SYSTEM, Administrators and `NT VIRTUAL MACHINE\Virtual Machines` read;
   protected DACL; file ReadOnly attribute). Setting the same ACL again is a no-op, so a rerun reports `unchanged`. An id
   is never reused: an existing folder with other bytes or no record is `AAP_GenerationExists`; a rebuild takes `aap.<n+1>`.
9. **Records** under `<EvidenceRoot>\P06\<build id>\`, created new by this run: `generation.json` (an image-catalog schema
   2 generation entry, state `candidate`), `budget.json` (backend-lifecycle schema 2 `budget` record), `build.json`
   (evidence: `plan_sha256`, `inputs_manifest_sha256`, `builder_commit`, waiver records, phases with their elevation,
   the guest registry check, measurements), `secret-scan.json`, and the guest-authored `software-report.md/.json` and
   `job-inventory.json`. `state.json` in the build folder lists every evidence file the run wrote; a failure, or the
   cleanup of a crashed run, deletes exactly those (except `secret-scan.json`) and the evidence folder if the run made it
   and it is then empty.

## Configuration

Passed by the caller (P19 or P25), never read from the user-writable inbox. All keys are required unless marked. The
plan, the P03 manifest, the allowlist and the verification payload are the files beside the module; no key redirects them.

| Key | Meaning |
|---|---|
| `StoragePath` | The storage document, `C:\ProgramData\aap-runner\capacity\storage.json` (backend-lifecycle.md, Storage tiers) |
| `EvidenceRoot` | The folder `evidence/` refers to; admin-only and trust-checked like the storage roots; records go to `P06\<build id>\` below it |
| `AapBuild` | `<n>` of `aap.<n>` |
| `MediaFile`, `MediaSha256` | The ISO's file name under `<base_root>\media\` and its pinned SHA-256 |
| `Edition` | The exact `install.wim` image name, e.g. `Windows Server 2025 Datacenter Evaluation (Desktop Experience)` |
| `BuildCpus`, `BuildMemGib` | Build and verification VM size (owner's lab approval 2026-10-20: 4 vCPU, 10 GiB static) |
| `StagingGibMax` | Cap on the build folder; also the free space the staging volume must have above its floor |
| `BaseGibMax`, `JobDiskGibMax` | The approved budget the measured one must fit (2026-10-20: base at most 200 GB, about 186 GiB; clone plus scratch at most 60 GB per runner, about 55 GiB) |
| `BuilderCommit` | 40-hex commit of this builder, recorded in provenance |
| `SourceEntry` | The P03 manifest entry of the `actions/runner-images` archive at `aee0669` (P03.1 adds it) |
| `SwitchName` | Must be `aap-guests-win`, the P10.0 internal switch; anything else is `AAP_NetworkUntrusted`. P06 creates no switch, NAT or network rule |
| `Inputs` (optional) | Further P03 entries to verify offline before the build |
| `Waivers` (optional) | Chair approval records, one per waived blocker: exactly `id`, `rationale`, `plan_sha256` (of the `build-plan.json` it was approved for) and `approver`. A bare id, a missing field or another plan's hash is `AAP_ConfigInvalid`. Recorded in `build.json` |

## The phase table

`build-plan.json` is generated by `New-AapWinBuildPlan.ps1` from the build-commit template
`parity/baselines/windows-2025-vs2026-x64/sources/build-commit-aee0669/build.windows-2025-vs2026.pkr.hcl` (SHA-256
`f1057bf6...b35241`, checked before parsing) and the pinned locals. A test regenerates it and compares. Each phase records
its upstream provisioner number, type and the SHA-256 of the provisioner body. Script phases keep the upstream script list
(82 scripts: the 81 build scripts in the order of `inputs.md`, then `RunAll-Tests.ps1`), environment, `elevated_user`,
`execution_policy`, `valid_exit_codes` (0 and 3010 for Visual Studio only) and `pause_before`. Action phases keep
`elevated_user` too. Reboots keep their timeout and checks (Containers feature, TiWorker idle, pending-reboot registry
keys). Inline and file provisioners map to named actions; an unknown inline block stops the generator.

| Phase | Upstream | AAP |
|---|---|---|
| p01 | create image and temp folders | `prepare-folders` (also checks the temp disk is `D:`) |
| p02-p03 | upload `assets`, `scripts`, `toolsets`, `software-report-base` | `upload-sources`, `upload-report-base` from the P03-verified archive |
| p04 | move helpers, tests, toolset into place | `layout-image-folder`, the same commands |
| p05-p06 | `net user installer` + WinRM basic auth; membership check | the build answer file creates `installer` with a per-build random password held in memory; PowerShell Direct, so no WinRM |
| p07 | `bcdedit /set TESTSIGNING ON` (elevated) | same, elevated |
| p08 | 10 configure/install scripts | same scripts, `unrestricted` |
| p09 | reboot, wait for Containers | reboot, wait for no pending reboot and Containers |
| p10 | `wlansvc` manual | same |
| p11-p27 | the upstream script blocks and reboots (p13 and p19 elevated) | same order, same flags |
| p22-p26 | test results check, software report, its checks, its download | same; the reports are copied to the evidence, size-capped while received |
| p28 | reboot | same |
| p29 | remove `Sysprep\unattend.xml`, sysprep, wait | answer files removed, install user password scrambled and user disabled, registry check as SYSTEM, sysprep, wait |

Plan blockers (besides P03's): `p06-upstream-source-archive` (no P03 entry for the upstream tree yet) and
`p06-upstream-variables-unverified` (the `variables` defaults are from the upstream variables file, not stored by P01).

## Storage and sizing

Roots come only from the storage document; nothing in this folder names a drive. The build folder is
`<staging root>\build\<build id>\` (`os.vhdx`, `temp.vhdx`, `verify\`, `state.json`, received `.part` files, the VM
files), with `<build id>.lock` beside it. Before a build: the staging volume needs `StagingGibMax` and `base_root`'s
volume needs `os_disk_gib + 1` (one published copy) above `volume_floor_gib`, summed when they share a volume. The budget
record is measured, never a default: `base_gib` and `replacement_gib` from the sealed disk, `clone_peak_gib`/`scratch_peak_gib`
from the verification guest's differencing and temp disks (caps are the peak x 1.25, rounded up), `staging_gib` from the
largest build-folder measurement, the verification disks included, `boot_mem_overhead_mib` from the VM worker process, one
retained rollback generation. The scratch disk is 150 GiB like the hosted `D:` (`temp_disk_gib`). The 60 GiB Linux
default appears nowhere; a test fails if it does. The hosted capture (C: 127,436,206,080 bytes used of about 160 GB) is
context; the record holds what this build measured, and it must fit `BaseGibMax` and `JobDiskGibMax`.

## Refusals and failures

`AAP_ProviderInvalid`, `AAP_BuilderUntrusted`, `AAP_ConfigInvalid`, `AAP_StorageMissing`, `AAP_StorageInvalid`,
`AAP_StorageUntrusted` (also a reparse point on the way to the evidence, build or generation folder),
`AAP_StorageVolumeMismatch`, `AAP_NetworkUntrusted`, `AAP_PlanInvalid`, `AAP_ScriptUnpinned`, `AAP_Blocked`,
`AAP_BuildBusy`, `AAP_GenerationExists`, `AAP_DiskLow`, `AAP_MediaMismatch`, `AAP_InputsUnverified`, `AAP_HostileGuest`,
`AAP_GuestTimeout`, `AAP_GuestUnreachable`, `AAP_PhaseFailed`, `AAP_ScriptHashMismatch`, `AAP_RebootTimeout`, `AAP_BudgetExceeded`,
`AAP_BudgetUnmeasured`, `AAP_SecretFound`, `AAP_ScanIncomplete`, `AAP_AllowlistInvalid`, `AAP_VerifyFailed`,
`AAP_BaseChanged`, `AAP_PublishMismatch`, `AAP_UnsafeDelete`; anything else is `AAP_Unexpected`. Every guest reply is
hostile input: capped while received, at most 64 KiB, one printable-ASCII JSON object with known fields, the expected
phase, at most 64 script entries with a safe name, a 64-hex hash and integer exit code; the sysprep reply must carry a
well-formed registry check; a boot time must be a tick count. Reports and the inventory are received with a cap and only
hashed. Deletion never follows a junction or symbolic link and never leaves its root; an entry whose own read-only ACL
forbids the delete gets its DACL reset by its owner first.

## Secret scan

Files only, on the sealed disk mounted read-only; junctions and links are not followed. Name rules: runner
`.credentials*` and `.runner`, `unattend*.xml`/`autounattend*.xml` anywhere (Panther included), `ssh_host_*_key`,
`authorized_keys`/`administrators_authorized_keys`, shell and PSReadLine history (any `*_history.txt`, `.bash_history`,
`.zsh_history`, `.python_history`), `app.pem`, cloud-init seed names. Content rules: PEM private keys,
`ghp_`/`gho_`/`ghu_`/`ghs_`/`ghr_` tokens, `github_pat_`, a JIT configuration assignment, the synthetic lab markers, and the
build password in ASCII and UTF-16. Findings carry a rule and a path, never the value. The registry checks ran in the guest
before sysprep (Seal) and their result is recorded in `secret-scan.json` under `registry`.

Limits and how they show in the record:

- **Large files**: files over 32 MiB are not content-scanned. Each is listed in `large_files` with its path, size and
  SHA-256 (up to 10,000; more makes the result `incomplete`), so P24 can audit them; name rules still apply.
- **Unreadable paths**: `System Volume Information` at the volume root, ACL-locked to SYSTEM, is skipped and listed in
  `skipped`; that list is reviewed and extended only through review. Any other folder or file the scan cannot read (access
  denied is told apart from absent) is listed in `unreadable` and makes the result `incomplete`, which fails the build with
  `AAP_ScanIncomplete`. Expect the first real build to name more SYSTEM-only folders for review.
- **Allowlist**: `secret-allowlist.json` (`schema` 1, `entries` of exactly `path`, `sha256` and `justification`, a
  relative path with no wildcard). An entry suppresses a finding only for that exact path with those exact bytes, never
  the build credential; an entry that matches no finding exactly is itself a finding (`allowlist-mismatch`). Each entry is
  a reviewed change to this file. It is empty.

## Evaluation media

The media is the owner's Windows Server 2025 Evaluation ISO (180 days), copied and verified into `<base_root>\media\`
(admin-only; P06 never reads it outside a build). `build.json` records `installed_at`, `expires_at` (installed + 180 days)
and `rebuild_by` (14 days earlier). The rule: P25 builds `aap.<n+1>` from fresh media before `rebuild_by`; a generation
past `expires_at` is quarantined (image-catalog.md, Evaluation media). Rearm is not used, because whether a clone of a
generalized evaluation image restarts the clock is not yet measured.

## Tests

`tests/images/windows/` (Pester 5, both hosts): `WinImage.Tests.ps1` (plan, storage, trust, preflight, network, waivers,
full build, failure at every guest phase, hostile replies, hostile disks and junctions, capped receives, reboots, the guest
registry check, budget, secret scan and allowlist, real read-only ACLs, evidence ownership, immutability, cleanup, source
rules, validator), `GuestRunner.Tests.ps1` (the guest runner as a hidden child process: scripts through the Packer
wrapper, the inner half of an elevated request, request validation), `Invoke-AapWinMutations.ps1` (each `# check:` in the
builder disabled in turn must fail its tagged tests). The storage roots of the fake world must pass the contract's path
form, so it lives under `%LOCALAPPDATA%\aap-p06-tests` (or `AAP_P06_TESTROOT`) and is removed after each test. The fake
provider writes the guest disk through the production `Write-AapGuestFile` and sets real read-only ACLs (with the test
user in the place of Administrators).

## What is not done

- **No real build.** The provider is written against documented cmdlets and has never run. The D2 lab proves it: DISM
  apply and boot, PowerShell Direct by VM id with the answer-file user, S4U elevation, reboots, nested features,
  `Optimize-VHD`, the read-only ACL with differencing children.
- **Upstream scripts are not pinned.** The runner-images archive at `aee0669` is not a P03 manifest entry (P03.1 adds it),
  so the plan's 82 script hashes are null and every build is refused (`AAP_ScriptUnpinned`). Rerun the generator with
  `-ScriptsDir` once P03 stages the archive.
- **Inputs are blockers.** 14 P03 Windows blockers (media, Windows Updates level, Visual Studio channel, vendor feeds,
  Chocolatey, ...) plus the plan's 2. A build needs each resolved or waived by a chair approval record; P06 decides none.
- **Guest egress during the build** comes from P10.0's internal switch `aap-guests-win` and its NAT, which P06 neither
  creates nor checks beyond name and type; upstream scripts download from the internet themselves.
- **Elevated provisioners** run as an S4U scheduled task of the install user; Packer uses a password logon for its task.
  Whether any upstream script needs the user's network credentials or DPAPI keys under S4U is unproven.
- **The verification guest has no network** (chair decision). An upstream test that needs the network fails
  verification; it is waived by name in an approval record bound to `plan_sha256`, or decided in the D2 lab. The builder
  has no per-test waiver yet: the verify reply reports counts, not failed test names.
- **Guest-side code that changes the machine** (scheduled tasks, the SYSTEM registry check, sysprep) runs only inside a
  build guest; the tests cover its request handling, its wrapper and the host's checks of its replies.
- **Host crash mid-build is not resumable**: the build password lives in memory only, so the next run cleans the partial
  build; if the crashed run had created evidence for the id, the rebuild takes `aap.<n+1>`. A finished build is idempotent.
- **Clone and scratch peaks** come from the verification workload, not real jobs (P22 re-measures).
- **Not in CI**: `tests/images/windows` is not in `.github/workflows/ci.yml` yet (the coordinator wires it).
