# Backend lifecycle contract (version 3)

Owners: **P10** (Windows provider), **P11** (Linux provider); measured budgets come from P06/P07;
the storage document is written by the elevated helper (**P19**). Readers: P09, P12, P19, P20, P22,
P25. Schema: [`backend-lifecycle.schema.json`](backend-lifecycle.schema.json) (`op` journal record,
`budget` record or `storage` document, all `schema` 2). Fixtures: `fixtures/backend-lifecycle/`.

Revision 2 (P02.2, 2026-10-20): configurable storage tiers replace the single image root, journal
disk paths are relative to their tier root, and budgets carry per-tier caps
([README, revision log](README.md#revision-log)).

Revision 3 (P09.x, 2026-10-22, owner decision Q4): a hard VM lifetime cap, so the result code
`vm_lifetime_cap`, the `lifetime_cap` evidence on the destroy intent record and the destroy order for a cap
([Hard lifetime cap](#hard-lifetime-cap-decided-owner-q4-revision-3)). Records keep `schema` 2: both additions are
optional, so every older record stays valid.

## Provider interface (DECIDED)

A provider is a PowerShell module loaded by the supervisor (`supervisor/backends/windows`,
`supervisor/backends/linux`). Hyper-V cmdlets run only there, never in the tray or helper.

| Op | Input | Effect | Idempotent rule |
|---|---|---|---|
| `create` | reservation, catalog generation | verify base hash; create `<clone_root>\<reservation_id>\` and `<scratch_root>\<reservation_id>\`; differencing `os.avhdx` on the base; `scratch.vhdx` with a maximum size inside `scratch_gib_max`; inject per-clone credential; `New-VM -Path <clone_root>\<reservation_id>\` (checkpoints disabled, `AutomaticStopAction TurnOff`, `AutomaticStartAction Nothing`, enhanced session and Guest Service Interface off) named `aap-<w\|l>-<slot>-<lease_generation>-<first 8 hex of reservation_id>` (create precedes any lease, so the name cannot depend on one) with the reserved CPU/RAM | if a VM with that name exists and the journal names it, reuse its id; never create a second |
| `boot` | vm_id | `Start-VM` | running already counts as done |
| `ready` | vm_id | transport `probe` succeeds and returns `ready` | repeatable |
| `run_one` | vm_id, lease | broker `lease_request`, `deliver_registration`, `start_runner`; then heartbeats until `job_done` | a lease id is used once; a retry takes a new lease id |
| `drain` | vm_id | runner listening without a job: stop it; busy: wait for the job (at most until the lifetime cap); then `collect` | repeatable |
| `collect` | vm_id | fetch the agent's bounded JSON job summary only; never the runner root, `_diag`, credential files or crash dumps | repeatable |
| `reset` | vm_id | **forbidden** (security review M3): destroy is the only way to remove every copy of the runner credential | |
| `destroy` | vm_id | broker `release_request` for the lease, if one was issued (mandatory; `deregistered` or `already_gone` both count); `Stop-VM -TurnOff`, `Remove-VM`, delete `<clone_root>\<reservation_id>\` and `<scratch_root>\<reservation_id>\` through literal, reparse-checked paths; observe absence of the VM, its configuration, saved-state and checkpoint files, and both folders; for a reservation past its lifetime cap the `Stop-VM -TurnOff` comes first, before the release ([Hard lifetime cap](#hard-lifetime-cap-decided-owner-q4-revision-3)) | absent counts as done; release is idempotent per lease |
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
| runner busy | resume heartbeats; never cancel the job before its lifetime cap (a VM already past it is powered off on the first step after the restart) |
| `destroy` intent, partial | re-run destroy; absence is the only success |
| journal unreadable | quarantine the reservation; capacity held |

Provider rules for heartbeats, `JobRunning` and hostile-guest reasons: allocator.md, Provider
rules for P10 and P11.

## Hard lifetime cap (DECIDED, owner Q4, revision 3)

Every VM has a hard lifetime cap ([allocator.md, Hard VM lifetime cap](allocator.md#hard-vm-lifetime-cap-decided-owner-decision-q4-2026-10-22):
when it fires, the order, the clocks, the host backstop). It is the way the host ends a running VM by time, beside the
other host limits (a hostile guest, the clone cap, a paused VM, the guest network). One order, everywhere (allocator.md
L4): latch the decision in memory, power the VM off at the hypervisor, then persist and tear down. The journal side,
once per reservation, therefore **follows** the power-off:

| When | Record |
|---|---|
| the cap is reached and the power-off was issued | for every op whose last record is an `intent`, except `destroy` and `reconcile` (which close themselves): a `failed` record with result code `vm_lifetime_cap` and a fixed `detail` (no guest text); an open `run_one` is the job's failure, an open `create` or `boot` closes the same way |
| then | a `destroy` `intent` record carrying `lifetime_cap` (below), written as soon as the journal can be written and retried every tick until it is: the power-off never waits for it, and a crash before it loses only the reason, never the power-off (allocator.md, L4 and L6). A `destroy` already open (a teardown being retried when the cap was reached) gets a new `intent` record with the same idempotency key and the evidence attached. A provider that finds a `lifetime_cap` record already in the journal (a restart decides again) writes neither this record nor the closing ones again. A destroy record names the VM id, taken from the reservation or else from the provider's derived-name lookup made before its first journal write: when neither yields one there is no VM and no destroy intent to carry the evidence, and the `create` `failed` record with the code is the only trace |
| the power-off fails (a Hyper-V error, the VM not observed off) | an ordinary `destroy` `failed` record (`retryable`), once per distinct failure; the power-off repeats at every tick and the escalation ladder climbs (allocator.md, L5) |
| the VM is observed off and the rest of `destroy` is done | `destroy` `done` `absent`, then the teardown proof, as for any destroy |

**Journal replay never starts a capped VM.** A replayed `create`, `boot` or `ready` for a reservation that is latched, or
whose recovered age has reached the cap, issues no start: the open op is closed `failed` with the code, and a VM that is
not running at supervisor start is never started by recovery (allocator.md, L6).

**Deadline record and start gate.** At `create`, after the VM exists and before it is first started, the provider writes
the VM's Notes with the deadline record of allocator.md B1 ([vm-cap-notes.schema.json](vm-cap-notes.schema.json)) and
reads it back. `boot` starts the VM only when the read-back equals what was written and the host watchdog's record is
fresh (allocator.md, B7); otherwise the reservation stays `creating`, and the step waits and retries every tick. The
Linux provider writes the same record.

**Calls.** Every call a step makes is bounded and isolated, due power-offs come first, and a teardown call is held to the
nearest other live deadline (allocator.md, L3). Before the decision, a call into the guest, the broker or GitHub for a
reservation never starts at or after that reservation's deadline; after the decision no guest call is made.

`lifetime_cap` contains `cap_hours` (1..6), immutable `started_utc`, `deadline_utc` (start plus cap hours), `trigger`,
`elapsed_s`, `power_off_utc` and `reason: vm_lifetime_cap`. `trigger` is `deadline`, `host_reboot` or `clock_unavailable`.
Only `deadline` claims elapsed age reached the cap and requires a known `elapsed_s >= cap_hours * 3600`. The safety
triggers allow measured age below the cap or `null` if age is unknown; a reboot/clock failure never fabricates six hours.

**Ordering timestamps are high-water estimates, not raw wall samples.** For a cap destroy intent, both `power_off_utc`
and the journal's `at` use one per-reservation evidence clock. Before issuance, sample in memory with
`evidence_now = max(started_utc, previous_evidence_now, true_now, now_utc)`; advance from its boot-bound monotonic counter
when available. Capture `power_off_utc` from that clock at issuance. After the call returns/times out, sample it again
for `at`, with a floor of `power_off_utc`, then persist. A raw rollback before the reservation's wall time or between
issuance and persistence therefore cannot reverse these evidence timestamps. If clock history is unavailable, the
reservation-start floor establishes ordering only, not elapsed age: the explicit safety trigger and nullable elapsed
field say what is unknown. Never replace raw wall samples by claiming fabricated measured elapsed time.

The validator refuses wrong placement, deadline arithmetic, a `deadline` trigger without sufficient known elapsed time,
bad UTC timestamps, `power_off_utc < started_utc` or `at < power_off_utc` in this high-water domain, cap evidence on a
legacy backend, and `vm_lifetime_cap` on destroy/reconcile. Older records without a cap object remain valid. A failed
E2 attempt still running is ordinary destroy `failed`/`retryable` with fixed detail `cap_breach`; it is never `done` or
proof of termination. P10.6/P11.3 test both safety triggers, both rollback windows and the breach path.

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

Hard lifetime cap (revision 3): evidence with a deadline an hour off, a cap of 7 hours, an `elapsed_s` one second
under the cap, no `elapsed_s`, a reason that is not `vm_lifetime_cap`, a start that is not a real time; evidence on
a `run_one` record and on a `destroy` `done` record; the result code `vm_lifetime_cap` on a `destroy` and on a
`reconcile` record. Valid: the evidence on a `destroy` intent at the deadline and with the wall clock behind it, and
a `run_one` `failed` with the code.
