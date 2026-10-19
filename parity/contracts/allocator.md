# Allocator contract (version 1)

Owner: **P09** writes it. Readers: P10, P11, P12, P16, P20, P22. Schema:
[`allocator.schema.json`](allocator.schema.json). Fixtures: `fixtures/allocator/`.
Architecture: [ARCHITECTURE.md section 2](../../docs/parity/ARCHITECTURE.md#2-allocator-and-capacity-contract-allocatormd).

## File

`C:\ProgramData\aap-runner\capacity\allocator.json`. Folder and file are owned by
Administrators with SYSTEM and Administrators full control and no user write, like the data
folder root. Only the supervisor writes it: whole-file atomic rename from a temp file in the same
folder, `revision` + 1 on every write. A reader that already applied a higher revision ignores a
lower one. Every read-modify-write holds an exclusive lock file,
`C:\ProgramData\aap-runner\capacity\allocator.lock` (opened with no sharing, inside the
admin-only folder), with a bounded wait of 30 s; a timeout fails the operation visibly (status
`error`, nothing admitted). A named object in the global namespace is not used because any process
could squat it.

## Fields

| Field | Meaning |
|---|---|
| `max_slots` | always 5: every registered, warm, listening, busy or cleanup-uncertain runner of every backend counts |
| `host` | measured logical CPUs, GiB of RAM, the always-on WSL control VM's resident memory (`control_distro_mem_gib`, taken off the pool first), the image-root disk admission budget (`disk_gib`: free space on `D:\aap-runner\images` minus replacement and staging headroom from the budget records) and image-root throughput (`io_mbps`, 0 = not measured) |
| `host_reserve_percent` | 10..90, default 10; 10 is the owner-confirmed minimum (2026-10-19). Never allocated |
| `share_mode` | `even`: each runner gets `floor(pool / (linux + windows))` where `pool = floor(host * (100 - reserve) / 100)`, minus `control_distro_mem_gib` for memory (today's tray rule, with the control VM paid first). `per_profile`: profile cap `floor(host * share / 100)`, each runner `floor(cap / count)` |
| `profiles.linux/windows` | `count` 0..5, `share_percent` (null in `even`), `backend`, `active_generation`. The Linux `backend` mirrors settings `linux_backend` (default `wsl-legacy`, flipped only by P27) |
| `legacy_adopted` | true once every legacy pool slot has a reservation |
| `slot_generations` | five counters, index 0 = slot 1. The supervisor increments a slot's counter before it creates a reservation in that slot; the reservation's `lease_generation` is that value |
| `reservations[]` | one per slot in use, see below; `reconciled` entries may linger until pruned and do not count |

Reservation: `reservation_id` (`r-` + 16 hex, random), `slot` 1..5, `profile`, `backend`
(`wsl-legacy` or `hyperv-vm`), `image_generation` (`legacy-<manager version>` or a catalog id),
`lease_generation`, `state`, `idempotency_key` = `<reservation_id>/<lease_generation>`, times,
`heartbeat_at`, the reserved `cpus`, `mem_gib`, `mem_overhead_mib` (the generation's measured
`boot_mem_overhead_mib`, 0 for legacy), `disk_gib`, `io_mbps`, `vm_id`, `runner_name` (for a VM:
exactly the VM name `aap-<w|l>-<slot>-<lease_generation>-<first 8 hex of reservation_id>`),
`cleanup_uncertain`, `quarantine_kind` (`heartbeat`, `hostile_guest`, `teardown_failed`,
`unknown_vm`, `crash`), `quarantine_reason`, `teardown_proof`.

## Rules (schema plus semantic checks in `validate.py`)

1. `linux.count + windows.count` is 1..5. Each control's maximum is `5 - other`; 0 is valid for
   either (3 Linux gives Windows max 2; 5 Windows gives Linux 0).
2. At most `max_slots` live reservations (every state but `reconciled`); one live reservation per slot.
3. Admitted states are `creating`, `ready`, `busy`, and `quarantined` with kind `heartbeat`
   (it holds capacity and may still be running its job, so its recovery to `busy` can never push the
   profile over its count). A profile never has more admitted reservations
   than its count, and every admitted reservation uses the profile's configured backend. Resizing
   down cancels nothing: the excess moves to `draining` (a busy job keeps running) and counts only
   in rule 5.
4. Every admitted reservation fits the per-runner share of its profile, counting
   `mem_gib + ceil(mem_overhead_mib / 1024)` as its memory: VM overhead is paid from the profile
   share, never from the host reserve. The admitted sum fits the profile cap.
5. Every live reservation, admitted or not, counts against the pool (CPU and memory with
   overhead), the image-root disk budget and the IO budget (`floor(host.io_mbps * (100 - reserve) / 100)`;
   with `io_mbps` 0 no reservation may reserve IO, and P09 refuses VM admission until it is
   measured). Admission of one profile therefore waits for the other profile's draining overhang.
6. `per_profile`: `linux_share + windows_share + reserve = 100`, and a profile has share 0 exactly
   when its count is 0. `even`: shares are null.
7. A `hyperv-vm` reservation exists only when `legacy_adopted` is true. Windows is always `hyperv-vm`.
8. A live reservation's `lease_generation` equals its slot's counter; no reservation is ahead of it.
9. `wsl-legacy` reservations are Linux, `vm_id` null, generation `legacy-*`. A VM reservation past
   `creating` names its `vm_id`.
10. `quarantine_kind` and `quarantine_reason` are set exactly when `quarantined`. `teardown_proof`
    is present exactly when `reconciled`, and its kind matches the backend: `vm` (VM, its
    configuration/saved-state/checkpoint files and disks observed absent) or `legacy` (the manager reports the slot gone). `runner_deregistered` is
    `true` (broker release), `github-removed` (ephemeral runner removed after its job, confirmed by
    `release_request` answering `already_gone`) or `never_registered` (create or boot failed before
    any lease).

## State machine and heartbeat

States: `creating`, `ready` (registered and listening), `busy`, `draining`, `collecting`,
`deleting`, `quarantined`, `reconciled`. Diagram: ARCHITECTURE.md section 2. Edges: `busy` and
`ready` can go to `draining`; `draining` always passes through `collecting` before `deleting`.

- The reservation is persisted **before** the provider's `create` (and before a legacy slot is
  allowed to start), and before any broker lease.
- Heartbeat source: VM slots, a validated guest `status` reply (guest-transport.md); legacy
  slots, the slot's entry in the manager status the supervisor already mirrors into `status.json`,
  counted only while that sample is at most 90 s old. `heartbeat_at` is updated at most every 30 s.
- Three missed intervals (90 s) move `ready` or `busy` to `quarantined`, kind `heartbeat`,
  `cleanup_uncertain: true`, capacity and resources held.
- A validated heartbeat returns a heartbeat-quarantined slot to `busy` (job running) or `ready`.
- A heartbeat-quarantined slot is destroyed only when the broker's read-only `status_request`
  (runner looked up by the ledger's runner id) reports it `offline` or `absent` and not busy, or
  the job is known to have ended. A VM whose runner GitHub reports `busy` is never destroyed: past
  the per-lease host wall clock (`lease_wall_clock_hours` in settings, default 6) the slot stays
  held, `cleanup_uncertain`, and status flags it for the owner. A running job is never cancelled
  by the allocator.
- `hostile_guest` is immediate and final: the slot goes straight to `deleting` and the VM is never
  trusted again.
- Only `reconciled` frees a slot. A late `job_done` for an older `lease_generation` is ignored for
  state and logged.

## Legacy adoption and Linux 0

Before the first VM reservation the allocator writes one `wsl-legacy` reservation per configured
legacy slot (`AAP_RUNNER_COUNT` as the manager reports it in `status.json`), sets
`legacy_adopted: true`, and from then on derives `AAP_RUNNER_COUNT` in `limits.conf` from the
Linux legacy reservations it grants, and `AAP_JOB_CPUS`/`AAP_JOB_MEMORY` as the minimum of the
setting and the Linux cap (shares win). Each legacy reservation records the per-slot `cpus` and
`mem_gib` that `limits.conf` actually grants, so the pool check sees the real footprint. The legacy pool keeps its own `fixed`/`slice` sharing inside
the Linux share. A legacy slot is released only when the manager reports it gone; a `retired`
manager slot is `quarantined` until the manager restarts or drains.

Linux count 0 means the legacy pool is drained and stopped: the manager accepts only 1..5, so the
supervisor drains it, stops the manager unit and writes no `limits.conf` with 0. The distro and
its keep-alive stay up while Windows >= 1 because the broker lives there (status-settings.md,
Supervisor states).

## Reconcile

At supervisor start and every 10 minutes: list Hyper-V VMs whose name matches
`^aap-(w|l)-[1-5]-` and the folders under `D:\aap-runner\images\clones` and `\scratch`, join them
with reservations and journals. Unknown VM or folder: quarantine it (kind `unknown_vm`) against a
free slot if one exists, otherwise refuse new admissions until it is resolved; never adopt it as
healthy and never delete it without a journal entry that names it. A reservation without its VM:
`deleting` then `reconciled` once disks and runner are confirmed gone.

## Fixtures

Valid: Linux 2 / Windows 2 with slot 5 heartbeat-quarantined, and the same after slot 5 recovers to
`busy`; the owner example (2 Windows 30 %, 3 Linux 60 %, 10 %), legacy-only even shares after
adoption with a reconciled legacy slot, a heartbeat quarantine holding its slot beside a VM
reconciled as `never_registered`, Windows 2 -> 0 with slot 4's job still running (draining), and
even 3L+2W -> 4L+1W while a Windows VM drains (the fourth Linux slot waits).

Invalid: a Windows admission in slot 3 beside the heartbeat-quarantined slot 5, sixth live reservation, duplicate slot, VM before legacy adoption, shares that give away
the reserve, reserve under 10, Linux 5 plus Windows 2, a runner over its share, VM memory overhead
over the share, Linux taking its new share before Windows finished draining, disk budget exceeded,
IO reserved while unmeasured, the control VM's memory pushing the pool over, stale lease generation, a runner name that is not the VM name, a
quarantine without kind, an admission on the wrong backend, reconciled without proof, a legacy
proof on a VM.
