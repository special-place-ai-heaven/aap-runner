# Allocator contract (version 2)

Owner: **P09** writes it. Readers: P10, P11, P12, P16, P20, P22. Schema:
[`allocator.schema.json`](allocator.schema.json). Fixtures: `fixtures/allocator/`.
Architecture: [ARCHITECTURE.md section 2](../../docs/parity/ARCHITECTURE.md#2-allocator-and-capacity-contract-allocatormd).

Revision 2 (P02.2, 2026-10-20): `allocator.json` schema 2 replaces the single image-root disk
budget with per-volume budgets for the storage tiers (`host.volumes`, reservation `clone_gib` and
`scratch_gib`); see backend-lifecycle.md, Storage tiers.

## File

`C:\ProgramData\aap-runner\capacity\allocator.json`. The capacity folder and every file in it are
**admin-only**: owner Administrators, SYSTEM and Administrators full control, a protected DACL
(inheritance off) and no other ACE, not even read for Users (backend-lifecycle.md, Trust checks). A
non-admin reader could otherwise open `allocator.lock` with no sharing and stall the allocator. Only
the supervisor writes `allocator.json`: whole-file atomic rename from a temp file in the same folder, `revision` + 1 on every write. A reader that already applied a higher revision ignores a
lower one. Every read-modify-write holds an exclusive lock file,
`C:\ProgramData\aap-runner\capacity\allocator.lock` (opened with no sharing, inside the
admin-only folder), with a bounded wait of 30 s; a timeout fails the operation visibly (status
`error`, nothing admitted). A named object in the global namespace is not used because any process
could squat it.

## Fields

| Field | Meaning |
|---|---|
| `max_slots` | always 5: every registered, warm, listening, busy or cleanup-uncertain runner of every backend counts |
| `host` | measured logical CPUs, GiB of RAM, the always-on WSL control VM's resident memory (`control_distro_mem_gib`, taken off the pool first), `volumes` (one entry per volume that holds a storage tier: `volume_guid`, `tiers`, `available_gib` = free space plus what live reservations already hold there, measured at each admission, `floor_gib` = the storage document's `volume_floor_gib`, `held_gib` = replacement and staging headroom while a build or replacement is planned there; written only for a storage layout that passed every trust check, empty otherwise) and `io_mbps` (measured throughput of the slowest volume holding the clone or scratch tier, 0 = not measured) |
| `host_reserve_percent` | 10..90, default 10; 10 is the owner-confirmed minimum (2026-10-19). Never allocated |
| `share_mode` | `even`: each runner gets `floor(pool / (linux + windows))` where `pool = floor(host * (100 - reserve) / 100)`, minus `control_distro_mem_gib` for memory (today's tray rule, with the control VM paid first). `per_profile`: profile cap `floor(host.cpu_cores * share / 100)` CPUs and `floor(pool_mem * share / (100 - reserve))` GiB (the memory pool after the control VM, so the two caps never sum over it), each runner `floor(cap / count)` |
| `profiles.linux/windows` | `count` 0..5, `share_percent` (null in `even`), `backend`, `active_generation`. The Linux `backend` mirrors settings `linux_backend` (default `wsl-legacy`, flipped only by P27) |
| `legacy_adopted` | true once every legacy pool slot has a reservation |
| `slot_generations` | five counters, index 0 = slot 1. The supervisor increments a slot's counter before it creates a reservation in that slot; the reservation's `lease_generation` is that value |
| `reservations[]` | one per slot in use, see below; `reconciled` entries may linger until pruned and do not count |

Reservation: `reservation_id` (`r-` + 16 hex, random), `slot` 1..5, `profile`, `backend`
(`wsl-legacy` or `hyperv-vm`), `image_generation` (`legacy-<manager version>` or a catalog id),
`lease_generation`, `state`, `idempotency_key` = `<reservation_id>/<lease_generation>`, times,
`heartbeat_at`, the reserved `cpus`, `mem_gib`, `mem_overhead_mib` (the generation's measured
`boot_mem_overhead_mib`, 0 for legacy), `clone_gib` and `scratch_gib` (the generation's
`clone_gib_max` and `scratch_gib_max`, 0 for legacy), `io_mbps`, `vm_id`, `runner_name` (for a VM:
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
   overhead), the disk budget of each volume and the IO budget (`floor(host.io_mbps * (100 - reserve) / 100)`;
   with `io_mbps` 0 no reservation may reserve IO, and P09 refuses VM admission until it is
   measured). Disk: on each volume that holds the clone or scratch tier, the sum over live
   reservations of `clone_gib` (if it holds the clone tier) and `scratch_gib` (if it holds the
   scratch tier) fits `available_gib - floor_gib - held_gib`. Free space that shrinks between
   admissions shows as tier state `low` in `status.v5.json`, which stops further VM admission.
   Admission of one profile therefore waits for the other profile's draining overhang.
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
11. Each volume is listed once and each tier is on at most one volume. A live `hyperv-vm`
    reservation needs the base, clone and scratch tiers in `host.volumes`, so VM admission requires
    a storage layout that passed its trust checks, and reserves at least 1 GiB of clone disk
    (`clone_gib` >= 1). Legacy reservations reserve no VM disk (`clone_gib` and `scratch_gib` 0);
    the legacy work disk keeps its own floor in the manager. A volume's `floor_gib` equals the
    storage document's `volume_floor_gib`; the two live in different files and no schema or
    `validate.py` rule cross-checks them, so the supervisor copies the value at every write.

## State machine and heartbeat

States: `creating`, `ready` (registered and listening), `busy`, `draining`, `collecting`,
`deleting`, `quarantined`, `reconciled`. Diagram: ARCHITECTURE.md section 2. Edges: `busy` and
`ready` can go to `draining`; `draining` always passes through `collecting` before `deleting`.
A legacy pool slot is a loop: `busy` returns to `ready` when the manager starts the slot's next
runner, and the reservation stays. A `hyperv-vm` reservation never takes that edge: one job per VM,
then `collecting`, `deleting` and `reconciled`.

- The reservation is persisted **before** the provider's `create` (and before a legacy slot is
  allowed to start), and before any broker lease.
- Heartbeat source: VM slots, a validated guest `status` reply (guest-transport.md); legacy
  slots, the slot's entry in the manager status the supervisor already mirrors into `status.json`,
  counted only while that sample is at most 90 s old. `heartbeat_at` is updated at most every 30 s.
  Legacy status comes from the control distro, so it is only as trustworthy as root in the distro
  (informational: the legacy pool already trusts that root).
- Three missed intervals (90 s) move `ready` or `busy` to `quarantined`, kind `heartbeat`,
  `cleanup_uncertain: true`, capacity and resources held.
- A validated heartbeat returns a heartbeat-quarantined slot to `busy` (job running) or `ready`.
- A heartbeat-quarantined slot is destroyed only when the broker's read-only `status_request`
  (runner looked up by the ledger's runner id) reports it `offline` or `absent` and not busy, or
  the job is known to have ended.
- Wall-clock rule (same text in status-settings.md): `lease_wall_clock_hours` (default 6) counts
  from the reservation's `acquired_at`. Past it the slot is only flagged: `status.v5.json` `detail` names it for the owner. The wall clock never
  destroys a slot: a heartbeat-quarantined slot is destroyed only when GitHub reports its runner
  `offline` (or `absent`) and not busy, or the job is known to have ended; a runner GitHub reports
  `busy` is never destroyed, and its slot stays held and `cleanup_uncertain`.
  A running job is never cancelled by the allocator.
- `hostile_guest` is immediate and final from every state in which the guest runs (`creating`,
  `ready`, `busy`, `draining`, `collecting`) and from a `heartbeat` or `crash` quarantine: the slot
  goes straight to `deleting` and the VM is never trusted again. From a quarantine the allocator
  first rewrites the kind to `hostile_guest` (`quarantined` to `quarantined`, so rule 10 holds at
  every write), then moves to `deleting`. `busy` goes directly to `deleting` only on a hostile
  reply; a finished job passes through `collecting`.
- Only `reconciled` frees a slot. A late `job_done` for an older `lease_generation` is ignored for
  state and logged.

## Provider rules for P10 and P11 (DECIDED, P09 security review 2026-10-20)

Contract notes for the providers; no change to `allocator.json` or `validate.py`.

- A provider derives `JobRunning` from the broker's record of the job GitHub assigned to the runner,
  never from the guest.
- A heartbeat is bound to its reservation by the host-side channel it arrived on (that VM's
  PowerShell Direct session or hvsocket connection), never by an id in the guest's payload.
- A VM in `busy`, `draining` or `collecting` past `lease_wall_clock_hours` (from `acquired_at`) is
  flagged, never destroyed.
- The `quarantine_reason` of a `hostile_guest` quarantine is a fixed code chosen by the host from
  the hostile cases in guest-transport.md (oversized reply, extra fields, wrong echo, non-printable
  byte, child exit); it never carries guest text. P10 defines the code list.
- Heartbeat quarantine covers `ready` and `busy` today. Whether `draining` and `collecting` also get
  it is an open decision ([README, Open decisions](README.md#open-decisions-2026-10-20)).

## Resize and host measurement (DECIDED, P09 review 2026-10-20)

Nothing admitted is ever evicted.

- A smaller count moves the excess to `draining` (rule 3); the resize waits for those jobs, and
  `status.v5.json` `detail` gives the reason `resize_waits`.
- A new host measurement (CPUs, memory, a volume's `available_gib`, `io_mbps`) that no longer holds
  the live reservations does not evict them either. The allocator refuses to store it as measured
  and stores a clamped `host`: each value lowered toward the measurement but never below what the
  live reservations need under rules 4 and 5. `allocator.json` stays valid, nothing more is
  admitted until live reservations end, and `detail` gives the reason `pool_over_live`.
- In `even` mode each runner's share is `floor(pool / (linux + windows))`, so a count increase
  (for example Linux 2 to 3 beside Windows 1) lowers every runner's share and every admitted
  runner drains, Windows VMs and the legacy pool alike. The supervisor sends the legacy manager a
  stop request (`Stop=true`) while the Linux count stays above 0 and restarts it with the new
  `limits.conf` once its slots are gone: every count increase in `even` mode is a full legacy stop
  and start. In `per_profile` mode a count change touches only that profile's runners while the
  shares stay the same. Flagged for the owner ([README, Open decisions](README.md#open-decisions-2026-10-20)).

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
`^aap-(w|l)-[1-5]-` and the reservation folders under `clone_root` and `scratch_root`, join them
with reservations and journals. Unknown VM: quarantine it (kind `unknown_vm`) against a free slot
if one exists, otherwise refuse new admissions until it is resolved. Unknown folder (a folder under
`clone_root` or `scratch_root` that no reservation or journal names): refuse every new admission
until it is resolved, because its bytes sit outside every reservation cap. Never adopt either as
healthy and never delete either without a journal entry that names it. A reservation without its
VM: `deleting` then `reconciled` once disks and runner are confirmed gone.

Inventory (P10, P11): a provider's inventory callback returns the complete list or throws. Any
listing error (access denied, a timeout, an enumeration cut short) throws; it never returns a
partial list. Reconcile treats a list that was returned as complete, so a reservation whose VM is
not in it has no VM, and treats a thrown listing as unknown: that pass changes no reservation and
deletes nothing.

## Fixtures

Valid: Linux 2 / Windows 2 with slot 5 heartbeat-quarantined, and the same after slot 5 recovers to
`busy`; the owner example (2 Windows 30 %, 3 Linux 60 %, 10 %), legacy-only even shares after
adoption with a reconciled legacy slot, a heartbeat quarantine holding its slot beside a VM
reconciled as `never_registered`, Windows 2 -> 0 with slot 4's job still running (draining), and
even 3L+2W -> 4L+1W while a Windows VM drains (the fourth Linux slot waits), and the owner example
with base and staging, clones and scratch on three volumes.

Invalid: a Windows admission in slot 3 beside the heartbeat-quarantined slot 5, sixth live reservation, duplicate slot, VM before legacy adoption, shares that give away
the reserve, reserve under 10, Linux 5 plus Windows 2, a runner over its share, VM memory overhead
over the share, Linux taking its new share before Windows finished draining, disk budget exceeded,
IO reserved while unmeasured, the control VM's memory pushing the pool over, stale lease generation, a runner name that is not the VM name, a
quarantine without kind, an admission on the wrong backend, reconciled without proof, a legacy
proof on a VM, the clone volume of three over its budget, a VM without storage tiers, a tier on two
volumes, a volume listed twice, a legacy reservation that reserves VM disk, and a VM reservation
with no clone disk.
