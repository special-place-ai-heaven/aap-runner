# Allocator contract (version 1)

Owner: **P09** writes it. Readers: P10, P11, P12, P16, P20, P22. Schema:
[`allocator.schema.json`](allocator.schema.json). Fixtures: `fixtures/allocator/`.
Architecture: [ARCHITECTURE.md section 2](../../docs/parity/ARCHITECTURE.md#2-allocator-and-capacity-contract-allocatormd).

## File

`C:\ProgramData\aap-runner\capacity\allocator.json`. Folder and file are owned by
Administrators with SYSTEM and Administrators full control and no user write, like the data
folder root. Only the supervisor writes it: whole-file atomic rename from a temp file in the same
folder, `revision` + 1 on every write. A reader that already applied a higher revision ignores a
lower one. The supervisor holds the named mutex `Global\aap-runner-allocator` for every
read-modify-write, so a second supervisor instance or a helper probe cannot interleave.

## Fields

| Field | Meaning |
|---|---|
| `max_slots` | always 5: every registered, warm, listening, busy or cleanup-uncertain runner of every backend counts |
| `host` | measured logical CPUs and GiB of the host |
| `host_reserve_percent` | 10..90, default 10. Never allocated |
| `share_mode` | `even`: each runner gets `floor(pool / (linux + windows))` where `pool = floor(host * (100 - reserve) / 100)` (today's tray rule). `per_profile`: profile cap `floor(host * share / 100)`, each runner `floor(cap / count)` |
| `profiles.linux/windows` | `count` 0..5, `share_percent` (null in `even`), `backend`, `active_generation` |
| `legacy_adopted` | true once every legacy pool slot has a reservation |
| `reservations[]` | one per slot in use, see below; `reconciled` entries may linger until pruned and do not count |

Reservation: `reservation_id` (`r-` + 16 hex, random), `slot` 1..5, `profile`, `backend`
(`wsl-legacy` or `hyperv-vm`), `image_generation` (`legacy-<manager version>` or a catalog id),
`lease_generation` (increases every time the slot is re-reserved), `state`,
`idempotency_key` = `<reservation_id>/<lease_generation>`, times, `heartbeat_at`, the reserved
`cpus`/`mem_gib`/`disk_gib`/`io_mbps`, `vm_id`, `runner_name`, `cleanup_uncertain`,
`quarantine_reason`, `teardown_proof`.

## Rules (schema plus semantic checks in `validate.py`)

1. `linux.count + windows.count` is 1..5. Each control's maximum is `5 - other`; 0 is valid for
   either (3 Linux gives Windows max 2; 5 Windows gives Linux 0).
2. At most `max_slots` live reservations (every state but `reconciled`); one live reservation per slot.
3. Admission (`creating`) never pushes a profile's admitted reservations (`creating`, `ready`,
   `busy`) above its count. Resizing down does not cancel anything: excess reservations drain.
4. Every reservation's `cpus` and `mem_gib` fit the per-runner share of its profile; the profile
   sum fits the profile cap; the live sum fits the pool. The reserve is never handed out.
5. `per_profile`: `linux_share + windows_share + reserve = 100`, and a profile has share 0 exactly
   when its count is 0. `even`: shares are null.
6. A `hyperv-vm` reservation exists only when `legacy_adopted` is true. Windows is always `hyperv-vm`.
7. `wsl-legacy` reservations are Linux, `vm_id` null, generation `legacy-*`.
8. A VM reservation past `creating` names its `vm_id`.
9. `quarantined` exactly when `quarantine_reason` is set; `reconciled` only with a `teardown_proof`.

## State machine and heartbeat

States: `creating`, `ready` (registered and listening), `busy`, `draining`, `collecting`,
`deleting`, `quarantined`, `reconciled`. Diagram and transitions: ARCHITECTURE.md section 2.

- The reservation is persisted **before** the provider's `create` (and before a legacy slot is
  allowed to start), and before any broker lease.
- Heartbeat: the provider updates `heartbeat_at` from a validated guest `status` reply at most
  every 30 s. A missing heartbeat **never** releases capacity. After 3 missed intervals the slot
  becomes `quarantined` with `cleanup_uncertain: true`; it keeps its resources.
- Only `reconciled` frees a slot, and only with a `teardown_proof` whose `vm_absent` and
  `disks_absent` were observed (not inferred from a delete exit code) and whose runner was
  deregistered or removed by GitHub after its job.
- Late completion: a `job_done` reply for an older `lease_generation` is ignored for state and logged.

## Legacy adoption

Before the first VM reservation the allocator writes one `wsl-legacy` reservation per configured
legacy slot (`AAP_RUNNER_COUNT` as the manager reports it in `status.json`), sets
`legacy_adopted: true`, and from then on derives `AAP_RUNNER_COUNT` in `limits.conf` from the
Linux legacy reservations it grants. The legacy pool keeps its own `fixed`/`slice` sharing
inside the Linux share. A legacy slot is released only when the manager reports it gone (drained
and exited); a `retired` manager slot is `quarantined` until the manager restarts or drains.

## Reconcile

At supervisor start and every 10 minutes: list Hyper-V VMs whose name matches
`^aap-(w|l)-[1-5]-` and clone folders under `<image_root>\clones`, join them with reservations
and journals. Unknown VM or folder: quarantine it against a free slot if one exists, otherwise
refuse new admissions until it is resolved; never adopt it as healthy and never delete it without
a journal entry that names it. A reservation without its VM: `deleting` then `reconciled` once
disks and runner are confirmed gone.

## Negative fixtures

Sixth live reservation, duplicate slot, VM before legacy adoption, shares that give away the
reserve, reserve under 10, Linux 5 plus Windows 2, a runner over its share, reconciled without
proof. `validate.py` asserts each is rejected for that reason.
