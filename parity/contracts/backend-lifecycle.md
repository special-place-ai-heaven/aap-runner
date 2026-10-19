# Backend lifecycle contract (version 2)

Owners: **P10** (Windows provider), **P11** (Linux provider); measured budgets come from P06/P07;
the storage document is written by the elevated helper (**P19**). Readers: P09, P12, P19, P20, P22,
P25. Schema: [`backend-lifecycle.schema.json`](backend-lifecycle.schema.json) (`op` journal record,
`budget` record or `storage` document, all `schema` 2). Fixtures: `fixtures/backend-lifecycle/`.

Revision 2 (P02.2, 2026-10-20): configurable storage tiers replace the single image root, journal
disk paths are relative to their tier root, and budgets carry per-tier caps
([README, revision log](README.md#revision-log)).

## Provider interface (DECIDED)

A provider is a PowerShell module loaded by the supervisor (`supervisor/backends/windows`,
`supervisor/backends/linux`). Hyper-V cmdlets run only there, never in the tray or helper.

| Op | Input | Effect | Idempotent rule |
|---|---|---|---|
| `create` | reservation, catalog generation | verify base hash; create `<clone_root>\<reservation_id>\` and `<scratch_root>\<reservation_id>\`; differencing `os.avhdx` on the base; `scratch.vhdx` with a maximum size inside `scratch_gib_max`; inject per-clone credential; `New-VM -Path <clone_root>\<reservation_id>\` (checkpoints disabled, `AutomaticStopAction TurnOff`, `AutomaticStartAction Nothing`, enhanced session and Guest Service Interface off) named `aap-<w\|l>-<slot>-<lease_generation>-<first 8 hex of reservation_id>` (create precedes any lease, so the name cannot depend on one) with the reserved CPU/RAM | if a VM with that name exists and the journal names it, reuse its id; never create a second |
| `boot` | vm_id | `Start-VM` | running already counts as done |
| `ready` | vm_id | transport `probe` succeeds and returns `ready` | repeatable |
| `run_one` | vm_id, lease | broker `lease_request`, `deliver_registration`, `start_runner`; then heartbeats until `job_done` | a lease id is used once; a retry takes a new lease id |
| `drain` | vm_id | runner listening without a job: stop it; busy: wait for the job; then `collect` | repeatable |
| `collect` | vm_id | fetch the agent's bounded JSON job summary only; never the runner root, `_diag`, credential files or crash dumps | repeatable |
| `reset` | vm_id | **forbidden** (security review M3): destroy is the only way to remove every copy of the runner credential | |
| `destroy` | vm_id | broker `release_request` for the lease, if one was issued (mandatory; `deregistered` or `already_gone` both count); `Stop-VM -TurnOff`, `Remove-VM`, delete `<clone_root>\<reservation_id>\` and `<scratch_root>\<reservation_id>\` through literal, reparse-checked paths; observe absence of the VM, its configuration, saved-state and checkpoint files, and both folders | absent counts as done; release is idempotent per lease |
| `reconcile` | none | see allocator.md, Reconcile | read-only until it acts through destroy |

Every op appends an `intent` record before it acts and a `done` or `failed` record after, to
`C:\ProgramData\aap-runner\capacity\journal\<reservation_id>.jsonl` (admin-only, one JSON
object per line, schema `op`). `idempotency_key` is `<reservation_id>/<lease_generation>/<op>`.

## Crash at every boundary (DECIDED expectations, P10/P11 test each)

| Crash after | Recovery |
|---|---|
| reservation persisted, no `create` intent | `reconciled` with a `vm` proof whose runner part is `never_registered`, only if no VM or folder carries the reservation id; else destroy |
| `create` intent, before VM exists | re-run `create`; it finds no VM and creates it once |
| VM created, `done` not written | re-run `create`; it finds the named VM and records its id |
| `boot`/`ready` in flight | re-probe; on timeout destroy |
| lease issued (or pending), not delivered | the lease id is spent; broker `release_request` with that lease id (the broker finds the runner in its ledger or by derived name); destroy; the slot's next reservation takes a new generation |
| runner busy | resume heartbeats; never cancel the job |
| `destroy` intent, partial | re-run destroy; absence is the only success |
| journal unreadable | quarantine the reservation; capacity held |

Provider rules for heartbeats, `JobRunning` and hostile-guest reasons: allocator.md, Provider
rules for P10 and P11.

## Storage tiers (DECIDED, owner 2026-10-20)

No VM file, image or staging byte has a hard-coded drive or folder. The owner chooses, through the
installer, three absolute roots and optionally a fourth for staging:

| Tier | Root | Holds |
|---|---|---|
| base | `base_root` | `catalog.json`; one folder per generation, `<profile>\<image_version>-aap.<n>\` (read-only after sealing, never moves); verified copies of installation media in `media\` |
| clone | `clone_root` | one folder per reservation, `<reservation_id>\`: the differencing `os.avhdx`, the Linux `seed.iso` and every VM file (`New-VM -Path`) |
| scratch | `scratch_root` | one folder per reservation, `<reservation_id>\scratch.vhdx` |
| staging | `staging_root`, or `<base_root>\staging` when it is null | P03 acquisition and P06/P07 build staging |

The roots may share one volume or use several. The pinned hash copy (`approved-images.json`), the
allocator, the journals and every other control file stay in the admin-only data folder, outside
all roots. No VM uses Hyper-V's default host folders for disks, configuration, runtime state or
smart paging.

**Configuration.** The `storage` document, `C:\ProgramData\aap-runner\capacity\storage.json`
(admin-only, see Trust checks; atomic rename; the supervisor reads at most 64 KiB of it), holds the
roots, each with its volume GUID, and `volume_floor_gib` (at least 10), the free space every volume
holding a tier keeps. Only the elevated helper writes it (P19): during setup, or through a helper
verb the tray offers (P20), approved with the existing UAC prompt and revalidated field by field
like the `identity` verb. Before writing `storage.json` the helper runs the full trust checks and
the existing-folder rule on every root, refuses while a VM reservation is live or a build runs, and
shows the roots it is about to write in its own elevated confirmation, so a job file cannot spoof
the prompt. The supervisor never takes a root from `inbox\settings.json`: the inbox is
user-writable, and the supervisor reads only validated numbers and fixed words from it. There are no
defaults: without a valid storage document the VM profiles stay disabled. Roots change only while no
VM reservation is live and no build runs; moving generations to a new `base_root` is a P25 operation
that re-verifies every hash.

**Valid roots** (schema and `validate.py`): an absolute folder at least one level below a
drive-letter volume root (`X:\folder`); no UNC or device path (`\\server\share`, `\\?\`, `\\.\`),
no relative path, no `.` or `..` component, no trailing dot or space, no `~` short name and no
reserved device name (`CON`, `PRN`, `AUX`, `NUL`, `COM0`-`COM9`, `LPT0`-`LPT9`, also before an
extension and with trailing spaces, as in `aux .d`); ASCII letters, digits, space and `._()-`
only. No root is equal to or inside another, compared case-insensitively, a separately configured
staging root included: an explicit `staging_root` equal to `<base_root>\staging` is refused as
inside `base_root`, and a null `staging_root` resolves to exactly that folder. Drive letters and
volume GUIDs map one to one (`validate.py`: "drive letters and volume GUIDs map one to one"): one
letter is one volume, and a volume is reached through one letter only, so per-volume accounting
and the ancestor checks see one path per volume. A `subst` drive has no volume GUID and is refused.
No root is equal to, inside, or contains `C:\ProgramData\aap-runner`, `%SystemRoot%` or `C:\wsl`;
`validate.py` checks the fixed data folder case-insensitively, and the other two are runtime
checks.

**Trust checks.** At install, at every supervisor start and before every `create`, each root
independently passes the rules `install-supervisor.ps1` applies to `C:\ProgramData\aap-runner`:

- the root is a plain folder (no reparse point) owned by SYSTEM, Administrators or
  TrustedInstaller, and no other principal may write, add files or folders, write attributes,
  delete, delete children, change permissions or take ownership (`Test-AapAdminDescriptor`);
- every ancestor up to the volume root is a plain folder with an admin owner that no other
  principal may delete, delete from, re-permission or take ownership of
  (`Get-AapAncestorProblem`; create rights on an ancestor are allowed, as there);
- the root's DACL is protected (inheritance off) and holds no inheritable ACE for a non-admin
  principal, because `Test-AapAdminDescriptor` skips inherit-only ACEs (`install-supervisor.ps1`);
- `clone_root` and `scratch_root` also grant a non-admin no read, because the per-clone credential
  is injected into the clone;
- the drive type is fixed (`Test-AapFixedLocalPath`) and the volume GUID is the recorded one.

**Admin-only** (here, in allocator.md and in ARCHITECTURE.md): owner Administrators, SYSTEM and
Administrators full control, a protected DACL (inheritance off) and no other ACE, not even read.
The capacity folder with `allocator.json`, `allocator.lock` and `storage.json`, the journals,
`clone_root` and `scratch_root` are admin-only.

P03's staging check (`Assert-AapStagingRoot`) applies the same rules. Any failure disables the VM
profiles and names the tier and reason in `status.v5.json`; the supervisor creates, repairs and
re-permissions nothing. The installer creates a missing root one level below a parent that passes
the ancestor checks. Creation is one `CreateDirectoryW` call with the final security descriptor.
`ERROR_ALREADY_EXISTS` sends the folder through the existing-folder rule (admin owner, no reparse
point, only this layout's entries). The installer never applies an ACL by name to a path it did
not just create.
No parity item creates, resizes, formats, relabels or re-letters a partition or volume, or changes
a volume root's ACL: those are owner actions.

## Disk paths and budgets

Journal disk paths are relative to the root of the disk role's tier and must be exactly
`<generation_id>/base.vhdx` (base_root: the read-only parent, which never moves; rollback is
catalog state only), `<reservation_id>/os.avhdx` or `<reservation_id>/seed.iso` (clone_root), or
`<reservation_id>/scratch.vhdx` (scratch_root); `validate.py` enforces the exact forms. No `..`,
no drive letter, no UNC and no backslash in the stored form; providers join them to the configured
root and reject reparse points on the way, as P00's deletion routine does. Every `create`
re-hashes the base against the hash pinned outside all roots.

`budget` records are **measured**, never defaults, each with an `evidence_ref`:

| Field | Tier | Meaning |
|---|---|---|
| `base_gib` | base | one generation's files |
| `clone_peak_gib`, `clone_gib_max` | clone | the measured peak per reservation, and the cap admission counts (at least the peak) |
| `scratch_peak_gib`, `scratch_gib_max` | scratch | the same for the scratch disk |
| `staging_gib` | staging | a build or replacement in progress |
| `replacement_gib` | base | a new generation landing beside the active one |
| `rollback_retained_generations` | base | 0..2, default 1 |
| `boot_mem_overhead_mib` | memory | VM memory beyond the reservation; copied into each reservation's `mem_overhead_mib` and paid from the profile share |

Caps are enforced, not only counted. The scratch VHDX is created with a maximum size that keeps
the file within `scratch_gib_max`. The provider samples the size of the reservation's clone folder
at least at every heartbeat and destroys the VM when it passes `clone_gib_max` (result `fatal`, detail
`clone over cap`); the overshoot is at most one heartbeat interval of writes, and the floor
absorbs it. A VM that Hyper-V pauses for lack of space is destroyed the same way. How close a full
VHDX file comes to its maximum size, and the overshoot at the measured write rate, are **to
measure in P02.1**.

Admission (allocator rule 5): each VM reservation reserves `clone_gib` = `clone_gib_max` on the
clone tier's volume and `scratch_gib` = `scratch_gib_max` on the scratch tier's volume. On each
volume that holds the clone or scratch tier, the caps of every live reservation must fit
`available_gib - floor_gib - held_gib`. `available_gib` is measured at each admission: the free
space plus what live reservations already hold there, so each cap counts once. `held_gib` is
`replacement_gib` plus `staging_gib` while a build or replacement is planned on that volume, so
jobs never take the space a planned build needs. Base generations already present are outside the
free space. Free space that shrinks between admissions (another writer on a shared volume) shows
as tier state `low`, which stops further admission; a build checks its own volume before it
starts.

Acceptance input for P11 (from P05): how the Linux provider attaches and mounts the job disks
(mount options, block read-ahead) must match the hosted Ubuntu reference or be justified by a
reviewed allowlist entry (image-catalog.md, Acceptance input for P07 and P11).

### Sizing evidence (context, not a budget)

The hosted Windows image at job start, run 39303666617
([baseline README](../baselines/windows-2025-vs2026-x64/README.md#observed-on-the-hosted-reference-run-39303666617)),
on 4 vCPU and 16 GiB RAM:

| Volume | Used bytes | Free bytes | Size |
|---|---:|---:|---|
| `C:` (OS) | 127,436,206,080 | 33,031,553,024 | about 160 GB (149.4 GiB) |
| `D:` (temp) | 3,191,169,024 | 157,868,003,328 | about 161 GB (150.0 GiB) |

Planning estimate (coordinator, 2026-10-20): 130-140 GB per base generation plus build headroom,
20-50 GB per running job for clone and scratch together, plus one retained rollback generation.
P06 and P07 measure the real budgets, and admission refuses a profile whose generation has no
measured budget. The 60 GiB Linux work-disk default is not a Windows budget. The owner approved
the lab budget on 2026-10-20 ([README, Resolved 2026-10-20](README.md#resolved-2026-10-20), item
4); the measured budgets must fit inside it.

## Negative fixtures

Op records: a mismatched idempotency key, a clone path with `..`, a scratch path with the revision-1
`scratch/` prefix, a base outside its generation folder, a differencing disk under another
reservation's folder, a VM name whose suffix is not the reservation's, an `exec` op, a `reset` op,
and a `done` record with a failure code. Budgets: unmeasured, and a clone or a scratch cap below its
measured peak. Storage: a relative root, a drive root, a UNC path, a device path, a `..` component,
a trailing newline, reserved device names (`CON`-style, `COM0`, `LPT0` and `aux .d`), two tiers in
one folder, a root inside another tier's root, a staging root inside the clone root, an explicit
staging root equal to `<base_root>\staging`, a missing tier, one drive letter on two volumes, two
drive letters on one volume, a floor under 10 GiB, a root inside the data folder, and root paths
with a trailing dot, a trailing space, a `~` short name, a `:stream` or `::$INDEX_ALLOCATION`
stream, forward slashes or a trailing backslash.
