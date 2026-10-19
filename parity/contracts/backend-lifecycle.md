# Backend lifecycle contract (version 1)

Owners: **P10** (Windows provider), **P11** (Linux provider); measured budgets come from P06/P07.
Readers: P09, P12, P19, P22, P25. Schema: [`backend-lifecycle.schema.json`](backend-lifecycle.schema.json)
(`op` journal record or `budget` record). Fixtures: `fixtures/backend-lifecycle/`.

## Provider interface (DECIDED)

A provider is a PowerShell module loaded by the supervisor (`supervisor/backends/windows`,
`supervisor/backends/linux`). Hyper-V cmdlets run only there, never in the tray or helper.

| Op | Input | Effect | Idempotent rule |
|---|---|---|---|
| `create` | reservation, catalog generation | verify base hash; create `clones\<reservation_id>\` and `scratch\<reservation_id>\`; differencing `os.avhdx` on the base; `scratch.vhdx`; inject per-clone credential; `New-VM -Path clones\<reservation_id>\` (checkpoints disabled, `AutomaticStopAction TurnOff`, `AutomaticStartAction Nothing`, enhanced session and Guest Service Interface off) named `aap-<w\|l>-<slot>-<lease_generation>-<first 8 hex of reservation_id>` (create precedes any lease, so the name cannot depend on one) with the reserved CPU/RAM | if a VM with that name exists and the journal names it, reuse its id; never create a second |
| `boot` | vm_id | `Start-VM` | running already counts as done |
| `ready` | vm_id | transport `probe` succeeds and returns `ready` | repeatable |
| `run_one` | vm_id, lease | broker `lease_request`, `deliver_registration`, `start_runner`; then heartbeats until `job_done` | a lease id is used once; a retry takes a new lease id |
| `drain` | vm_id | runner listening without a job: stop it; busy: wait for the job; then `collect` | repeatable |
| `collect` | vm_id | fetch the agent's bounded JSON job summary only; never the runner root, `_diag`, credential files or crash dumps | repeatable |
| `reset` | vm_id | **forbidden** (security review M3): destroy is the only way to remove every copy of the runner credential | |
| `destroy` | vm_id | broker `release_request` for the lease, if one was issued (mandatory; `deregistered` or `already_gone` both count); `Stop-VM -TurnOff`, `Remove-VM`, delete the clone and scratch folders through literal, reparse-checked paths; observe absence of the VM, its configuration, saved-state and checkpoint files, and both folders | absent counts as done; release is idempotent per lease |
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

## Disk layout and budgets

`<image_root>` is `D:\aap-runner\images` (owner decision 2026-10-19, about 2.3 TB free then).
Layout: ARCHITECTURE.md section 3. Journal disk paths are relative to `<image_root>` and must
be exactly `base/<generation_id>/base.vhdx` (the read-only parent, which never moves; rollback
is catalog state only), `clones/<reservation_id>/os.avhdx`, `clones/<reservation_id>/seed.iso` or
`scratch/<reservation_id>/scratch.vhdx`; `validate.py` enforces the exact forms.

Image root protection: the provider refuses every op while the image-root checks of
ARCHITECTURE.md section 3 (owner, ACL, reparse points, ancestors of `D:\aap-runner\images`) fail,
and re-hashes the base against the hash pinned outside the image root before each `create`. No `..`, no drive letter,
no UNC, no backslash in the stored form; providers resolve them against the configured root and
reject reparse points on the way, as P00's deletion routine does.

`budget` records are **measured**, never defaults: `base_gib`, `clone_peak_gib`,
`scratch_peak_gib`, `staging_gib` (image build/replacement staging), `replacement_gib` (a new
generation landing beside the active one), `rollback_retained_generations` (0..2, default 1),
`boot_mem_overhead_mib` (VM memory beyond the reservation; copied into each reservation's
`mem_overhead_mib` and paid from the profile share), each with an `evidence_ref`.
Admission: each VM reservation reserves `disk_gib = clone_peak_gib + scratch_peak_gib`; the
allocator's `host.disk_gib` is the measured free space minus one `replacement_gib` and, while a
build runs, `staging_gib`; the sum over live reservations must fit it (allocator rule 5).
The P01 hosted capture is context, not a budget: Windows `C:` about 160 GB total with 33 GB free,
`D:` 158 GB free; the upstream OS disk is 150 GB.

## Negative fixtures

Mismatched idempotency key, a clone path with `..`, a scratch disk outside `scratch/`, a base in a `rollback/` folder, a differencing disk under another reservation's folder, a VM name whose suffix is not the reservation's, an unmeasured budget, an `exec` op, a `reset` op, and a
`done` record with a failure code.
