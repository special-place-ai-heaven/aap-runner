# Backend lifecycle contract (version 1)

Owners: **P10** (Windows provider), **P11** (Linux provider); measured budgets come from P06/P07.
Readers: P09, P12, P19, P22, P25. Schema: [`backend-lifecycle.schema.json`](backend-lifecycle.schema.json)
(`op` journal record or `budget` record). Fixtures: `fixtures/backend-lifecycle/`.

## Provider interface (DECIDED)

A provider is a PowerShell module loaded by the supervisor (`supervisor/backends/windows`,
`supervisor/backends/linux`). Hyper-V cmdlets run only there, never in the tray or helper.

| Op | Input | Effect | Idempotent rule |
|---|---|---|---|
| `create` | reservation, catalog generation | verify base hash; create `clones\<reservation_id>\`; differencing `os.avhdx` on the base; `scratch.vhdx`; inject per-clone credential; `New-VM` named `aap-<w\|l>-<slot>-<lease_generation>-<8 hex>` with the reserved CPU/RAM | if a VM with that name exists and the journal names it, reuse its id; never create a second |
| `boot` | vm_id | `Start-VM` | running already counts as done |
| `ready` | vm_id | transport `probe` succeeds and returns `ready` | repeatable |
| `run_one` | vm_id, lease | broker `lease_request`, `deliver_registration`, `start_runner`; then heartbeats until `job_done` | a lease id is used once; a retry takes a new lease id |
| `drain` | vm_id | runner listening without a job: stop it, broker `release_request`; busy: wait | repeatable |
| `collect` | vm_id | fetch the bounded job summary and sanitized diagnostics | repeatable |
| `reset` | vm_id | not used until a lab proves equivalence to destroy-and-recreate (P10/P11 evidence) | |
| `destroy` | vm_id | `Stop-VM -TurnOff`, `Remove-VM`, delete the clone folder through a literal, reparse-checked path; observe absence | absent counts as done |
| `reconcile` | none | see allocator.md, Reconcile | read-only until it acts through destroy |

Every op appends an `intent` record before it acts and a `done` or `failed` record after, to
`C:\ProgramData\aap-runner\capacity\journal\<reservation_id>.jsonl` (admin-only, one JSON
object per line, schema `op`). `idempotency_key` is `<reservation_id>/<lease_generation>/<op>`.

## Crash at every boundary (DECIDED expectations, P10/P11 test each)

| Crash after | Recovery |
|---|---|
| reservation persisted, no `create` intent | release to `reconciled` with an empty teardown proof only if no VM or folder carries the reservation id; else destroy |
| `create` intent, before VM exists | re-run `create`; it finds no VM and creates it once |
| VM created, `done` not written | re-run `create`; it finds the named VM and records its id |
| `boot`/`ready` in flight | re-probe; on timeout destroy |
| lease issued, not delivered | the lease id is spent; broker `release_request` for its runner id; destroy; new reservation generation |
| runner busy | resume heartbeats; never cancel the job |
| `destroy` intent, partial | re-run destroy; absence is the only success |
| journal unreadable | quarantine the reservation; capacity held |

## Disk layout and budgets

Layout: ARCHITECTURE.md section 3. Journal disk paths are relative to `<image_root>` and must
match `images/...` (base, read-only) or `clones/...` (per reservation). No `..`, no drive letter,
no UNC, no backslash in the stored form; providers resolve them against the configured root and
reject reparse points on the way, as P00's deletion routine does.

`budget` records are **measured**, never defaults: `base_gib`, `clone_peak_gib`,
`scratch_peak_gib`, `staging_gib` (image build/replacement staging), `replacement_gib` (a new
generation landing beside the active one), `rollback_retained_generations` (0..2, default 1),
`boot_mem_overhead_mib` (VM memory beyond the reservation), each with an `evidence_ref`.
Admission needs: free space on `<image_root>` >= sum over live reservations of
`clone_peak_gib + scratch_peak_gib` + one `replacement_gib` + `staging_gib` while a build runs.
The P01 hosted capture is context, not a budget: Windows `C:` about 160 GB total with 33 GB free,
`D:` 158 GB free; the upstream OS disk is 150 GB.

## Negative fixtures

Mismatched idempotency key, a clone path with `..`, an unmeasured budget, an `exec` op, and a
`done` record with a failure code.
