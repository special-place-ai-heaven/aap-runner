# images/windows: the Windows Server 2025 / VS2026 golden image builder (P06)

Builds one immutable generation `win25-vs2026-x64/20261007.264.1-aap.<n>` of the native Windows runner image on a local
Hyper-V host, from the owner's Windows Server 2025 Evaluation media and the provisioning of `actions/runner-images` at the
P01 build commit `aee0669`. PowerShell 5.1 (the supervisor's host) and PowerShell 7.

**Status: authored and tested with fakes only.** No VM was created, no Hyper-V cmdlet ran, no media was read and nothing
was downloaded. The first real run is the D2 lab (see [What is not done](#what-is-not-done)). The committed plan is
deliberately not runnable yet: its upstream script hashes are not pinned, so the builder refuses with `AAP_ScriptUnpinned`.

| File | Role |
|---|---|
| `AapWinImage.psm1` | The builder: storage and trust checks, plan and blockers, answer files, the phase loop, secret scan, fresh-guest verification, publication, generation and budget records. Calls nothing on the host except through the provider |
| `AapWinImage.HyperV.psm1` | The production provider (`New-AapWinHyperVProvider`): every Hyper-V, Storage, DISM, PowerShell Direct, registry-hive and ACL call. Not run by P06 |
| `New-AapWinBuildPlan.ps1` | Generates `build-plan.json` from the pinned template; reads files only |
| `build-plan.json` | The phase table: one phase per upstream provisioner, in template order |
| `guest/AapGuestRunner.ps1` | Runs one phase inside the build guest and prints one JSON reply line |
| `guest/AapGuestVerify.ps1` | Runs in a fresh guest of the sealed image as the job user: upstream tests, P05 inventory probe, toolchain discovery |
| `INTEGRATION.md` | What P10, P14, P19, P12 and the catalog owners must do with this |

## Build flow

`Invoke-AapWinImageBuild -Config <hashtable> -Provider <hashtable>` returns `Ok`, `Status` (`built`, `unchanged`,
`refused`, `failed`), `Reason`, `Detail`, `GenerationId` and the record paths. A `refused` run changed nothing. A `failed`
run removed everything it made (VMs, build disks, a partly published generation, its records) and kept only failure
evidence such as `secret-scan.json`.

1. **Preflight** (refusals, nothing written): config, provider completeness, the storage document, trust of the storage
   document's folder, `base_root` and the staging root (admin-only, on the recorded volume), the plan (every script hash
   pinned), input blockers (each P03 Windows blocker and each plan blocker resolved or explicitly waived by id), the
   build lock, a partial build of the same id (cleaned), an existing generation (idempotent `unchanged`, or refused),
   free space above the floor on each volume, the media hash, and P03's offline verification of the upstream source
   archive and any other input.
2. **Disks**: a dynamic `os.vhdx` of the upstream OS disk size (150 GiB, `os_disk_size_gb` of `win25-vs2026` in the pinned
   locals) and a formatted `temp.vhdx` that becomes `D:` (hosted runners have `D:` as their temp disk, `TEMP_DIR` is
   `D:\temp`). The edition is applied from the ISO's `install.wim` (DISM, no Setup UI), with a build answer file and the
   guest runner written offline.
3. **Build VM**: generation 2, Secure Boot off (upstream sets `bcdedit TESTSIGNING ON`), nested virtualization exposed
   (upstream enables Hyper-V, Containers and WSL2), checkpoints off, Guest Service Interface off, files in the build folder.
4. **Phases** p01-p29 in upstream order (below). After each phase the build folder is measured against `StagingGibMax`.
5. **Seal**: the last phase deletes every answer file, gives the install user a fresh random password that never leaves the
   guest, removes `C:\aap-build`, runs `Sysprep /oobe /generalize /mode:vm /quiet /quit` and waits for
   `IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE`, as upstream does. The host shuts the VM down, removes it, deletes the temp disk,
   compacts and hashes `os.vhdx`.
6. **Secret scan** of the sealed disk, mounted read-only (rules below). Anything but `clean` fails the build.
7. **Fresh-guest verification**: a differencing child of the sealed disk, a new answer file that creates the job user
   `runneradmin` (local administrator, as on the hosted image), and `AapGuestVerify.ps1` as that user: the pinned upstream
   Pester tests (`RunAll-Tests.ps1`), the full P05 inventory probe (`job-inventory.json`, Docker included) and native
   discovery through `vswhere` and `VsDevCmd` (cl, link, clang-cl, lld-link, rc, msbuild, cmake, ninja, the Windows SDK
   headers, a C program built and run with MSVC and with clang-cl, a resource compiled with rc). It passes only with at
   least one upstream test, no failed test, every discovery item and an inventory whose hash matches what the guest
   reported. The clone and scratch peaks and the VM memory overhead are measured here. The sealed disk is hashed again
   afterwards and must be unchanged.
8. **Publish**: `<base_root>\win25-vs2026-x64\<image_version>-aap.<n>\base.vhdx`, copied, re-hashed against the sealed
   hash, then made read-only (owner Administrators; SYSTEM, Administrators and `NT VIRTUAL MACHINE\Virtual Machines` read;
   protected DACL; file ReadOnly attribute). An id is never reused: an existing folder with other bytes or no record is
   `AAP_GenerationExists`; a rebuild takes `aap.<n+1>`.
9. **Records** (written before the ACL is applied, removed again if publication fails), under `<EvidenceRoot>\P06\<build id>\`:
   `generation.json` (an image-catalog schema 2 generation entry, state `candidate`), `budget.json` (backend-lifecycle
   schema 2 `budget` record), `build.json` (evidence), `secret-scan.json`, `software-report.md/.json`, `job-inventory.json`.

## Configuration

Passed by the caller (P19 or P25), never read from the user-writable inbox. All keys are required unless marked.

| Key | Meaning |
|---|---|
| `StoragePath` | The storage document, `C:\ProgramData\aap-runner\capacity\storage.json` (backend-lifecycle.md, Storage tiers) |
| `EvidenceRoot` | The folder `evidence/` refers to; records go to `P06\<build id>\` below it |
| `AapBuild` | `<n>` of `aap.<n>` |
| `MediaFile`, `MediaSha256` | The ISO's file name under `<base_root>\media\` and its pinned SHA-256 |
| `Edition` | The exact `install.wim` image name, e.g. `Windows Server 2025 Datacenter Evaluation (Desktop Experience)` |
| `BuildCpus`, `BuildMemGib` | Build and verification VM size (owner's lab approval 2026-10-20: 4 vCPU, 10 GiB static) |
| `StagingGibMax` | Cap on the build folder; also the free space the staging volume must have above its floor |
| `BaseGibMax`, `JobDiskGibMax` | The approved budget the measured one must fit (2026-10-20: base at most 200 GB, about 186 GiB; clone plus scratch at most 60 GB per runner, about 55 GiB) |
| `BuilderCommit` | 40-hex commit of this builder, recorded in provenance |
| `SourceEntry` | The P03 manifest entry of the `actions/runner-images` archive at `aee0669` (not in the manifest yet) |
| `Inputs` (optional) | Further P03 entries to verify offline before the build |
| `Waivers` (optional) | Blocker ids accepted for this build; recorded in `build.json` |
| `SwitchName` (optional) | An existing Hyper-V switch for guest egress. P06 creates no switch, NAT or network rule |
| `PlanPath`, `ManifestPath`, `ProbeScript`, `HelloC` (optional) | Overrides for tests; default to the repository files |

## The phase table

`build-plan.json` is generated by `New-AapWinBuildPlan.ps1` from the build-commit template
`parity/baselines/windows-2025-vs2026-x64/sources/build-commit-aee0669/build.windows-2025-vs2026.pkr.hcl` (SHA-256
`f1057bf6...b35241`, checked before parsing) and the pinned locals. A test regenerates it and compares. Each phase records
its upstream provisioner number, type and the SHA-256 of the provisioner body. Script phases keep the upstream script list
(82 scripts: the 81 build scripts in the order of `inputs.md`, then `RunAll-Tests.ps1`), environment, `elevated_user`,
`execution_policy`, `valid_exit_codes` (0 and 3010 for Visual Studio only) and `pause_before`. Reboots keep their timeout and
checks (Containers feature, TiWorker idle, pending-reboot registry keys). Inline and file provisioners map to named actions;
an unknown inline block stops the generator.

| Phase | Upstream | AAP |
|---|---|---|
| p01 | create image and temp folders | `prepare-folders` (also checks the temp disk is `D:`) |
| p02-p03 | upload `assets`, `scripts`, `toolsets`, `software-report-base` | `upload-sources`, `upload-report-base` from the P03-verified archive |
| p04 | move helpers, tests, toolset into place | `layout-image-folder`, the same commands |
| p05-p06 | `net user installer` + WinRM basic auth; membership check | the build answer file creates `installer` with a per-build random password held in memory; PowerShell Direct, so no WinRM |
| p07 | `bcdedit /set TESTSIGNING ON` (elevated) | same |
| p08 | 10 configure/install scripts | same scripts, `unrestricted` |
| p09 | reboot, wait for Containers | reboot, wait for no pending reboot and Containers |
| p10 | `wlansvc` manual | same |
| p11-p27 | the upstream script blocks and reboots | same order, same flags |
| p22-p26 | test results check, software report, its checks, its download | same; the reports are copied to the evidence, size-bounded |
| p28 | reboot | same |
| p29 | remove `Sysprep\unattend.xml`, sysprep, wait | answer files removed, install user password scrambled, sysprep, wait |

Plan blockers (besides P03's): `p06-upstream-source-archive` (no P03 entry for the upstream tree yet) and
`p06-upstream-variables-unverified` (the `variables` defaults are from the upstream variables file, not stored by P01).

## Storage and sizing

Roots come only from the storage document; nothing in this folder names a drive. The build folder is
`<staging root>\build\<build id>\` (`os.vhdx`, `temp.vhdx`, `verify\`, `state.json`, the VM files), with
`<build id>.lock` beside it. Before a build: the staging volume needs `StagingGibMax` and `base_root`'s volume needs
`os_disk_gib + 1` (one published copy) above `volume_floor_gib`, summed when they share a volume. The budget record is
measured, never a default: `base_gib` and `replacement_gib` from the sealed disk, `clone_peak_gib`/`scratch_peak_gib`
from the verification guest's differencing and temp disks (caps are the peak x 1.25, rounded up), `staging_gib` from the
largest build-folder measurement, `boot_mem_overhead_mib` from the VM worker process, one retained rollback generation.
The 60 GiB Linux default appears nowhere; a test fails if it does. The hosted capture (C: 127,436,206,080 bytes used of
about 160 GB) is context; the record holds what this build measured, and it must fit `BaseGibMax` and `JobDiskGibMax`.

## Refusals and failures

`AAP_ProviderInvalid`, `AAP_ConfigInvalid`, `AAP_StorageMissing`, `AAP_StorageInvalid`, `AAP_StorageUntrusted`,
`AAP_StorageVolumeMismatch`, `AAP_PlanInvalid`, `AAP_ScriptUnpinned`, `AAP_Blocked`, `AAP_BuildBusy`,
`AAP_GenerationExists`, `AAP_DiskLow`, `AAP_MediaMismatch`, `AAP_InputsUnverified`, `AAP_HostileGuest`,
`AAP_PhaseFailed`, `AAP_ScriptHashMismatch`, `AAP_RebootTimeout`, `AAP_BudgetExceeded`, `AAP_BudgetUnmeasured`,
`AAP_SecretFound`, `AAP_VerifyFailed`, `AAP_BaseChanged`, `AAP_PublishMismatch`, `AAP_UnsafeDelete`; anything else is
`AAP_Unexpected`. Every guest reply is hostile input: at most 64 KiB, one printable-ASCII JSON object with known fields,
the expected phase, at most 64 script entries with a safe name, a 64-hex hash and integer exit code; reports and the
inventory are copied with a size limit and only hashed. Deletion never follows a junction or symbolic link and never leaves
its root.

## Secret scan

Name rules: runner `.credentials*` and `.runner`, `unattend*.xml`/`autounattend*.xml` anywhere (Panther included),
`ssh_host_*_key`, `authorized_keys`/`administrators_authorized_keys`, shell and PSReadLine history, `app.pem`, cloud-init
seed names. Content rules (files up to 32 MiB): PEM private keys, `ghp_`/`gho_`/`ghu_`/`ghs_`/`ghr_` tokens,
`github_pat_`, a JIT configuration assignment, the synthetic lab markers, and the build password in ASCII and UTF-16.
Registry: Winlogon `DefaultPassword` and `AutoAdminLogon`, and the LSA `DefaultPassword` secret. Findings carry a rule and
a path, never the value. Junctions are not followed. An unreadable file makes the result `incomplete`, which fails too.

## Evaluation media

The media is the owner's Windows Server 2025 Evaluation ISO (180 days), copied and verified into `<base_root>\media\`
(admin-only; P06 never reads it outside a build). `build.json` records `installed_at`, `expires_at` (installed + 180 days)
and `rebuild_by` (14 days earlier). The rule: P25 builds `aap.<n+1>` from fresh media before `rebuild_by`; a generation
past `expires_at` is quarantined (image-catalog.md, Evaluation media). Rearm is not used, because whether a clone of a
generalized evaluation image restarts the clock is not yet measured.

## Tests

`tests/images/windows/` (Pester 5, both hosts): `WinImage.Tests.ps1` (plan, storage, trust, preflight, full build, failure
at every guest phase, hostile replies, budget, secret scan, immutability, cleanup, source rules, validator),
`GuestRunner.Tests.ps1` (the guest runner as a hidden child process), `Invoke-AapWinMutations.ps1` (each `# check:` in
the builder disabled in turn must fail its tagged tests). The storage roots of the fake world must pass the contract's path
form, so it lives under `%LOCALAPPDATA%\aap-p06-tests` (or `AAP_P06_TESTROOT`) and is removed after each test.

## What is not done

- **No real build.** The provider is written against documented cmdlets and has never run. The D2 lab proves it: DISM
  apply and boot, PowerShell Direct with the answer-file user, reboots, nested features, `Optimize-VHD`, the read-only
  ACL with differencing children, offline hive reads.
- **Upstream scripts are not pinned.** The runner-images archive at `aee0669` is not a P03 manifest entry, so the plan's
  82 script hashes are null and every build is refused (`AAP_ScriptUnpinned`). Rerun the generator with `-ScriptsDir` once
  P03 stages the archive.
- **Inputs are blockers.** 11 P03 Windows blockers (media, Windows Updates level, Visual Studio channel, vendor feeds,
  Chocolatey, ...) plus the two plan blockers. A build needs each resolved or explicitly waived; this item decides no waiver.
- **Guest egress during the build** comes from an existing switch the caller names (P10.0); upstream scripts download
  from the internet themselves. P06 makes no network, switch or NAT change.
- **Elevated provisioners** run in the install user's PowerShell Direct session instead of Packer's scheduled-task
  elevation. Equivalence is unproven.
- **Host crash mid-build is not resumable**: the build password lives in memory only, so the next run cleans the partial
  build and starts again. A finished build is idempotent.
- **LSA secret check** reads the offline SECURITY hive, which Administrators normally cannot read; the provider then
  reports `AAP_ScanIncomplete` and the build fails. A real build may need a backup-privilege read.
- **Clone and scratch peaks** come from the verification workload, not real jobs (P22 re-measures).
- **Not in CI**: `.github/workflows/ci.yml` runs Pester only for `supervisor` and `tests/parity-work`.
