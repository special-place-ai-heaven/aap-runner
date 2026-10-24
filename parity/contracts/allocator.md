# Allocator contract (version 2)

Owner: **P09** writes it. Readers: P10, P11, P12, P16, P20, P22. Schema:
[`allocator.schema.json`](allocator.schema.json). Fixtures: `fixtures/allocator/`.
Architecture: [ARCHITECTURE.md section 2](../../docs/parity/ARCHITECTURE.md#2-allocator-and-capacity-contract-allocatormd).

Revision 2 (P02.2, 2026-10-20): `allocator.json` schema 2 replaces the single image-root disk
budget with per-volume budgets for the storage tiers (`host.volumes`, reservation `clone_gib` and
`scratch_gib`); see backend-lifecycle.md, Storage tiers.

Revision note (P09.x, 2026-10-22, owner decision Q4): revision 2's wall-clock rule, which only flagged, is
replaced by a hard VM lifetime cap ([below](#hard-vm-lifetime-cap-decided-owner-decision-q4-2026-10-22)).
The text changes and `allocator.json` stays schema 2, byte for byte: `acquired_at` already persists the
cap's start, so no field is added (the supervisor's capacity module keeps a byte copy of the schema).

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
`lease_generation`, `state`, `idempotency_key` = `<reservation_id>/<lease_generation>`, times (`acquired_at`
is also the start of the hard lifetime cap and is never rewritten),
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
`ready` can go to `draining`; `draining` always passes through `collecting` before `deleting`,
except at the lifetime cap, which goes to `deleting` directly from every live state that has a `vm_id` (L4; a
`creating` reservation without one stays `creating`).
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
  the job is known to have ended, or its lifetime cap is reached (below), whatever GitHub reports.
- Lifetime cap: revision 2's wall-clock rule (a flag at `lease_wall_clock_hours`, never a destroy) is
  replaced by the hard VM lifetime cap ([below](#hard-vm-lifetime-cap-decided-owner-decision-q4-2026-10-22),
  owner decision Q4): at the deadline the VM is powered off and torn down whatever GitHub reports, and a
  running job ends with it. The allocator ends a running job only for a hostile guest reply or the lifetime cap;
  the providers' own limits (backend-lifecycle.md) are theirs.
- `hostile_guest` is immediate and final from every state in which the guest runs (`creating`,
  `ready`, `busy`, `draining`, `collecting`) and from a `heartbeat` or `crash` quarantine: the slot
  goes straight to `deleting` and the VM is never trusted again. From a quarantine the allocator
  first rewrites the kind to `hostile_guest` (`quarantined` to `quarantined`, so rule 10 holds at
  every write), then moves to `deleting`. `busy` goes directly to `deleting` only on a hostile
  reply or at the lifetime cap; a finished job passes through `collecting`.
- Only `reconciled` frees a slot. A late `job_done` for an older `lease_generation` is ignored for
  state and logged.

## Provider rules for P10 and P11 (DECIDED, P09 security review 2026-10-20)

Contract notes for the providers; no change to `allocator.json` or `validate.py`.

- A provider derives `JobRunning` from the broker's record of the job GitHub assigned to the runner,
  never from the guest.
- A heartbeat is bound to its reservation by the host-side channel it arrived on (that VM's
  PowerShell Direct session or hvsocket connection), never by an id in the guest's payload.
- A VM in any live state past its lifetime cap is powered off and torn down (Hard VM lifetime cap, L1-L9).
  The provider evaluates the cap on every step before any guest, broker or GitHub call; a drained VM kept
  for a pending release is no exception.
- The `quarantine_reason` of a `hostile_guest` quarantine is a fixed code chosen by the host from
  the hostile cases in guest-transport.md (oversized reply, extra fields, wrong echo, non-printable
  byte, child exit); it never carries guest text. P10 defines the code list.
- Heartbeat quarantine covers `ready` and `busy` today. Whether `draining` and `collecting` also get
  it is an open decision ([README, Open decisions](README.md#open-decisions-2026-10-20)).

## Hard VM lifetime cap (DECIDED, owner decision Q4, 2026-10-22)

Every VM has a hard lifetime cap, for every repository (owner decision session 2026-10-21/22, Q4), enforced by the host
independent of the job and of the guest. It replaces revision 2's wall-clock rule, which only flagged. It binds the
`hyperv-vm` backend of both profiles; the legacy pool's containers are outside it (their clock is the manager's
`AAP_JOB_TIMEOUT_MINUTES`). Two enforcers, neither depending on the other:

- the **supervisor path** (L1 to L10): the configured cap, `vm_lifetime_cap_hours` 1..6, through the allocator, the
  journal and the verified teardown;
- the **host backstop** (B1 to B9): a separate host watchdog that powers off any managed VM past the 6-hour ceiling from
  a deadline record the VM itself carries, needing none of the supervisor, the allocator, the journal or the backend
  modules.

Tests cite L1 to L10 and B1 to B9. The bounded outcome is **observed Off or an explicit unresolved cap breach**, never
an unconditional claim that failed host mechanisms stopped execution. A healthy E1 path observes Off within 90 s (L3);
the watchdog completes E1/E2 and observation within 300 s (B5). If stopping fails, L5 records `cap_breach`, blocks starts
and continues enforcement; network isolation alone is never reported as termination.

| Term | Meaning |
|---|---|
| `started_utc` | the reservation's `acquired_at`: the UTC time the supervisor persisted the reservation, before the provider's `create` and before any lease. No write changes it (a state change, a heartbeat, a quarantine, a recovery, a restart, a journal replay); a new reservation has a new clock |
| `cap_hours` | the effective `vm_lifetime_cap_hours` ([status-settings.md](status-settings.md#settings-schema-4-the-hard-vm-lifetime-cap-revision-4-decided-owner-q4)): a whole number 1..6 from the settings in force, **6** while none is (no file, or none valid since the supervisor started); a refused file leaves the settings in force as they were |
| `deadline_utc` | `started_utc` plus `cap_hours` hours; computed, never stored in `allocator.json` |
| `true_now`, `age` | `true_now` is the estimate of real UTC the supervisor keeps (L7), never behind the wall clock and never moved backwards by a clock step, a restart or a crash; `age` is `true_now - started_utc` |
| `boot_id` | an opaque string of 8 to 64 characters of `[0-9a-f-]` that the host changes at every boot and no wall-clock change can alter; the provider and the watchdog each document and prove their source (candidates: `/proc/sys/kernel/random/boot_id`, an OS boot counter or GUID) |

**L1 Scope.** Every live `hyperv-vm` reservation, in every state and in every quarantine kind except `unknown_vm`.
Its VM is found by `vm_id`, or by the VM name derived from the reservation while `vm_id` is still null (a `create`
that never recorded an id). An `unknown_vm` quarantine is a VM no reservation or journal names, so the supervisor path
does not touch it (Reconcile holds it until the owner resolves it); the backstop does (B6). `reconciled` has no VM;
`wsl-legacy` is outside.

**L2 Decision.** The cap is reached when `age` reaches `cap_hours` hours; exactly `cap_hours` counts. The decision reads
`acquired_at`, the setting and the host clocks and nothing else: a guest reply, a heartbeat or a missed one, the job's
state, the runner's GitHub status (`online`, `offline`, `busy`, `absent`), a broker answer and the guest's own clock can
neither postpone nor reset it. A settings change applies at once to every live reservation: lowering the cap reclaims
every VM already older than the new value at the next tick, raising it (never above 6) moves deadlines out. A refused
settings file leaves the settings in force as they were, so the cap in force is never above 6.

**L3 Cadence, bounded calls, lateness.** The cap is evaluated for every live reservation at supervisor start (before it
replays a journal or admits anything), at the start of every tick (`PollSeconds`, drain loops included), between any two
steps, between any two calls inside a step, and before every status document written in `idle`, `running`, `draining`
or `paused` (a document written in `off`, `starting` or `error` claims no enforcement, L9; `validate.py` refuses a slot
more than 60 s past its deadline without `reason` in the states that evaluate). Three rules keep the lateness finite:

1. **Due power-offs first.** At every evaluation point the provider starts a bounded power-off for every reservation that
   is due before it makes any other call: a release, a removal, a folder deletion, a measurement, a create or boot of
   another VM, a guest, broker or GitHub call. When several reservations are due, dispatch their power-offs concurrently
   (at most the five admitted VMs); no due VM waits for another VM's power-off to return.
2. **Every call is bounded and isolated.** A call that can block (Hyper-V, CIM, file measurement, copy or removal, disk
   create, guest, broker, GitHub) runs where the supervisor can kill it (a child process or job) under a finite hard
   limit: 30 s for a power-off or a state read, no other call's own limit may exceed 30 s, and never longer than the time
   left to the nearest deadline of any live reservation other than the one it serves (a call that serves a reservation
   before its own decision is held to that reservation's deadline too). A due power-off always starts with its 30 s hard
   limit, in parallel with other due power-offs. Any other call whose limit would fall below 1 s is not started. A
   teardown call that would outlive another reservation's deadline fails `retryable` instead: a late release costs a
   retry, a late power-off costs the cap. Only due power-offs run concurrently; at most one other blocking call may be
   in flight across the pool, and the cap is evaluated after it completes or is killed.
3. **No guest call after the decision.** The broker's release belongs to the teardown.

The supervisor completes its first power-off attempt within **90 s** past the deadline (5 s tick, at most one 30 s
non-power-off call in flight, a concurrent 30 s E1 batch, and margin). This is a termination bound only when Off is
observed; otherwise L5 escalation and breach reporting apply. P10.6/P11.3 assert both outcomes against hanging fakes.



**L4 Effect: one order.** For a reservation past its cap, from any state, in this order. Nothing in steps 3 and 4 may
delay step 2, or the power-off of any other VM.

1. **Latch** the decision in memory, no I/O. Once latched the reservation is capped for the life of the process and no
   later clock reading un-caps it.
2. **Power off** at the hypervisor, bounded (L3): `Stop-VM -TurnOff`, or what is equivalent and needs nothing from the
   guest; never a guest shutdown, never the `shutdown` command of guest-transport.md. From here the reservation is
   fenced (L6).
3. **Persist**, each attempt made after step 2 returns or times out, each retried every tick until it holds, none able
   to delay a power-off: (a) the durable latch, an entry in `lifetime-clock.json` (L7); (b) the allocator state in the
   table below, with `cleanup_uncertain: true`; (c) the journal: a `failed` record with result code `vm_lifetime_cap`
   for every op still open except `destroy` and `reconcile`, then the `destroy` `intent` carrying `lifetime_cap`, whose
   `power_off_utc` and `at` show the evidence follows the power-off
   ([backend-lifecycle.md, Hard lifetime cap](backend-lifecycle.md#hard-lifetime-cap-decided-owner-q4-revision-3)).
4. **Teardown**, the ordinary verified one: release, remove the VM, delete both reservation folders, observe absence,
   `Complete-AapTeardown`; every call bounded by L3, none started while another reservation is due.

| State at the decision | Allocator state change (step 3b) |
|---|---|
| `ready`, `busy`, `draining`, `collecting` | to `deleting`, one direct edge |
| `creating` with a `vm_id` | to `deleting` |
| `creating` without one | stays `creating` (rule 9 forbids `deleting` without a `vm_id`); the teardown goes by the derived VM name and ends in `Complete-AapTeardown` with the `never_registered` proof |
| `quarantined`, kind `heartbeat`, `crash` or `hostile_guest` | to `deleting` (kind and reason cleared, so rule 10 holds at the write) |
| `deleting`, or `quarantined` with kind `teardown_failed` | unchanged: its teardown retry rules stand and only the power-off repeats (L5) |
| `quarantined`, kind `unknown_vm` | outside the supervisor path (L1); the backstop acts (B6) |

A job still running is not drained or collected, and no guest call of any kind follows the decision. Steps 1 and 2 need
only the reservation's `vm_id` (or the derived name): neither the allocator write, nor the journal, nor the guest
channel, nor the broker.

**L5 Failed power-off, durable escalation and breach.** No stage asks the guest. E1 issues `Stop-VM -TurnOff`, hard
limit 30 s; after it returns or times out, persist `enforcement_stage: power_off_attempted` in the clock latch (L7).
If the VM is not observed Off, the next enforcement pass uses E2: terminate only that VM's verified worker process
(`vmwp.exe` bound to its VM GUID), hard limit 30 s, then persist `worker_stop_attempted`. A restart resumes from that
stage instead of restarting E1; all due VMs get one stage concurrently before any teardown work (B5 for watchdog runs).
Observing Off persists `off`. If E2 completes or times out and Off is still not observed, persist `cap_breach`: execution
may still be running, the lifetime cap is unresolved, and there is **no bounded-termination claim**. Report `error`,
audit `cap_breach`, append `cap_breach:` after the leading `vm_lifetime_cap:` in status detail, block new VM starts,
and keep the slot/capacity held. Repeat E2 with bounded observations on later passes until Off is observed. Network
detachment may mitigate exposure but never clears the breach or substitutes for stopping execution; the watchdog does
not import the network module. Failed inventory, observation or persistence is `enforcement_unavailable`, not successful
termination; report it immediately and treat a known due VM not proved Off by B5's bound as a cap breach. The supervisor
may still attempt release in the same tick after a failed power-off, but never before another due enforcement action.

**L6 No reuse, no resurrection.** Only `reconciled` frees a slot, and it needs the teardown proof (rule 10); the cap
shortens none of it. A runner GitHub still shows `busy` once its VM is off keeps the slot `deleting` while the release
repeats (`retry` until GitHub lets go); `deregistered` or `already_gone` is the runner part of the proof, as before. A
VM powered off for the cap is never started again, and operations are fenced so that nothing can start it: (a) no
`create`, `boot`, `ready` or journal replay step issues a start for a latched reservation or one whose recovered age
has reached the cap, and an open `create` or `boot` op is closed `failed` with the code; (b) before every start the
provider re-reads the VM's deadline record (B1) and the clock record and refuses when the deadline has passed by
`true_now`; (c) after a start returns it evaluates the cap once more and powers off if it is reached; (d) a VM that is
not running at supervisor start is never started by recovery, whatever the journal says; (e) an interrupted start
cannot satisfy the teardown proof, which needs the VM observed absent. A crash between step 2 and step 3 is therefore
safe: the VM stays off, nothing restarts it, the slot is reclaimed through the crash or heartbeat path, and at most the
reason is lost.

**L7 Clocks: true time, never behind.** `age = true_now - started_utc`, and `true_now` is kept so that no clock step,
restart or crash makes a VM younger. The supervisor keeps `lifetime-clock.json` next to `allocator.json`
([lifetime-clock.schema.json](lifetime-clock.schema.json); admin-only, atomic replace, validated before every write):
`boot_id`, `mono_ms` (whole milliseconds of a host counter wall-clock changes cannot move, for example
`Stopwatch.GetTimestamp()` scaled by its frequency), `written_utc`, `high_water_utc` and `latched` (L4 step 3a).

- Every tick: compute `true_now = max(now_utc, high_water_utc + (mono_now - mono_ms) / 1000)` from the previous
  write and update the in-memory high-water mark. It advances with the counter even while the wall clock is stepped back,
  and never goes backwards. Persist the clock at the end of the tick; when a cap fires, step 1 and 2 of L4 happen before
  the high-water mark and durable latch are written as step 3. The clock read and computation before power-off do no I/O.
- Supervisor restart in the same boot (`boot_id` equals the record's): the same formula, so the time before the restart
  is not lost whatever the wall clock did meanwhile. Real age 5 h and UTC stepped back to 2 h before a restart gives age
  5 h plus the downtime, and the cap fires at 6 h real.
- Restart after a host boot (`boot_id` differs): the counter cannot be compared, so `true_now = max(now_utc,
  high_water_utc)`, and time that passed across the reboot with the wall clock stepped back cannot be recovered.
  Conservatively, every live reservation whose VM is found running at the first tick after a boot-id change is capped
  at once; a VM found off is a crash and is never started (L6).
- If `lifetime-clock.json` is missing, unreadable or invalid at start, elapsed time cannot be recovered. Every live VM
  found running is therefore capped at once, rather than assuming the wall clock or uptime proves it is young; a VM
  found off is never started (L6). The file is recreated with `true_now = now_utc`, and uptime remains an independent
  measure when it is available.
- A forward step (a clock fix, an NTP correction, a resume with a corrected clock) of J seconds ages every VM by J: every
  VM whose age then reaches its cap is powered off, which can end every running job at once. That is the policy: the
  host clock is trusted going forward, the cap is a ceiling, and an early end is preferred to a late one. The supervisor
  logs `clock_step` (the size, nothing else) when the wall delta between two ticks is more than 5 s smaller than the
  counter's (a backward step); a forward step looks like a host sleep and is not logged.
- Residual, stated: exact elapsed time across a reboot or lost clock record cannot be reconstructed. The conservative
  rules above cap every managed VM still found running and never restart one found off; the watchdog applies the same
  handling from its independent clock record.

Each latch carries `trigger` (`deadline`, `host_reboot` or `clock_unavailable`), `elapsed_s` and `enforcement_stage`.
Only `deadline` asserts that a measured elapsed time reached `cap_hours`; it requires a non-null elapsed value at least
that large. The two conservative safety triggers allow an actual measured value below the cap, or `null` when unknown;
never invent six hours of evidence. `decided_utc` is a high-water timestamp. After a clock reset its floor includes every
known reservation start, but that timestamp floor is not an elapsed-age measurement. The latch keeps its original trigger
and evidence while its enforcement stage advances; reconciliation alone removes it.

**L8 Reports.** The failed job is reported with the machine-readable reason `vm_lifetime_cap` in three places, none
carrying a host name, a path or guest text: the journal records of L4; the slot's `vm_lifetime_cap` object in
`status.v5.json` ([status-settings.md](status-settings.md)), whose `reason` is `vm_lifetime_cap` from the decision until
the slot is freed, with the top-level `detail` starting `vm_lifetime_cap:`; and one supervisor log line per decision
(reservation id, slot, the three times). GitHub fails the job through its own lost-runner path: the host sets no
conclusion there and records nothing about GitHub's side. An unhealthy backstop is reported by B7.

**L9 What the supervisor path does not cover, and what does.** The supervisor path does not run while the supervisor is
down or `off` (the capacity pass does not run), while a backend module cannot be loaded (the supervisor has no Hyper-V
call of its own: it holds the slot and reports `error`), while `allocator.json` is unreadable or invalid, its lock times
out or capacity initialisation fails (no VM step runs and status says `error`), and it never covers an `unknown_vm` VM
or a VM no reservation names (a lost `allocator.json` turns every VM into one). None disables the independent watchdog:
an admitted VM's B1 Notes record survives allocator/journal loss. B8 makes missing Notes a pre-activation blocker.
Stopping mechanisms, inventory or observation may themselves fail: L5/B5 then require an explicit unresolved breach,
not a claim that the VM stopped. Host/Hyper-V outage or simultaneous loss of both enforcers remains an availability
failure; these conditions never authorize slot release or new starts.

**L10 Introduction.** A reservation older than its cap when the first supervisor that implements this section starts is
reclaimed on its first tick. Until P10.6 (Windows), P11.3 (Linux), P10.7 (watchdog), P12.3 (supervisor) and P19.1
(installer, including the mandatory legacy-VM gate) implement and prove it, this section is a contract and not behaviour
([README, Revision follow-ups](README.md#revision-follow-ups-p09x-owner-decision-q4-carried-by-other-owners)), and the
owner's precondition for a VM profile serving public repositories (Q4) is not met.

### Host power-off backstop (DECIDED, owner decision Q4 review, B1 to B9)

The supervisor path depends on the supervisor, `allocator.json`, the journal and the backend modules, so it cannot be the
only enforcer of a cap that has no exemptions. The backstop is host-owned, separate and minimal.

**B1 Deadline on the VM.** The provider writes the VM's `Notes` (Hyper-V `Set-VM -Notes`) after `New-VM` and before the VM
is first started, reads it back, and starts the VM only when the read-back equals what it wrote. The record is one compact
ASCII JSON object under 1 KiB, no secrets and no paths ([vm-cap-notes.schema.json](vm-cap-notes.schema.json)): `schema` 1,
`kind` `aap-vm-cap`, `vm_id` (the VM's own GUID), `vm_name` (the derived name), `reservation_id`, `started_utc` (the
reservation's `acquired_at`), `deadline_utc` (`started_utc` plus 6 hours exactly: the ceiling, never the configured cap,
so a settings change never rewrites it) and `check` (the first 32 hex of the SHA-256 of `aap-vm-cap:1|` and `vm_id`,
`vm_name`, `reservation_id`, `started_utc`, `deadline_utc` joined by `|`). `check` detects truncation and hand edits; it
is no secret, because whoever can write Notes can already stop the VM. The Linux profile writes the same record, and
`validate.py vm-cap-notes` is the one check of it.

**B2 The watchdog.** A separate host process: a scheduled task (SYSTEM, every 60 s, one instance at a time, restarted on
failure) running a small script from the admin-owned program folder. It imports no supervisor, allocator, journal, broker
or backend module, reads neither `allocator.json` nor any journal, and uses only the Hyper-V cmdlets or CIM and its own
state file, a `lifetime-clock.json` with role `watchdog` in its own admin-only folder, written every run.

**B3 Identity.** It acts on a VM only when all hold: the name matches `^aap-(w|l)-[1-5]-[0-9]+-[0-9a-f]{8}$`; the Notes
parse as a B1 record that passes `validate.py vm-cap-notes` (schema, deadline arithmetic, the name's last 8 hex, `check`);
`vm_id` equals the VM's real GUID and `vm_name` its real name. Anything else (a foreign VM, a copied or exported VM with
another GUID, a VM with no or damaged Notes) is never touched; the run logs `identity_mismatch` (the GUID only), once per
VM per hour.

**B4 Action and recovery.** Each run discovers and verifies B3 identities under B5's inventory budget, computes true
time from its own clock record and reads uptime. A missing/invalid/prior-boot clock record selects the explicit
`clock_unavailable`/`host_reboot` trigger for every already-running identified VM, without fabricating elapsed time.
Otherwise a reached Notes deadline or six-hour uptime selects `deadline`. Latch in memory, then execute one L5 stage per
due VM concurrently (at most five), perform a bounded state observation (Off or not), then persist the resulting stage.
Resume it on the next run; never reset progress because a run ended. A failed write is an enforcement failure.
The watchdog deletes nothing and never releases capacity. Known VMs use the supervisor's verified teardown; unknown
VMs remain held until the owner resolves them. Its ceiling is six hours, never the configured lower cap.

**B5 Fair scheduling and bounds.** Runs start every 60 s, never overlap, and have a hard 50 s total budget: inventory,
identity/clock reads at most 10 s total; one stage for **every** due VM in parallel at most 30 s; all resulting state
observations in parallel at most 5 s; persistence and audit at most 5 s. Each budget is isolated/cancellable; none is an
unbounded Hyper-V call. Inventory must return the complete managed set or fail explicitly. At most five admitted VMs
means every due VM is serviced each run; an early VM cannot consume another VM's stage budget. E1 and E2 are separate
runs, with durable progress and restart recovery as L5 requires. Worst supported outcome: 60 s to the first run + 50 s
for E1 + 60 s to the E2 run + 50 s for E2/observation/reporting = 220 s, with 80 s margin: **300 s** to observed Off or
explicit `cap_breach`, including enumeration and observation. A failed inventory/clock write/observation is reported
`enforcement_unavailable` immediately; it voids any termination claim, blocks starts, and a known due VM not proved Off
by 300 s is an unresolved breach. P10.7 tests five hanging VMs, failed reads/writes, mid-stage kills, recovered stages,
and lack of starvation; P02.1 measures the bound. A run never restarts E1 indefinitely or silently drops unfinished VMs.

**B6 No supervisor exemption.** An `unknown_vm`, lost/unreadable/invalid allocator, lock timeout, unloadable backend,
or supervisor down/off/error does not disable the watchdog. The independent attempt/observation/breach outcome of B5
still applies; failure to stop execution is reported honestly under L5, never treated as a successful cap.

**B7 Health and the start gate.** No VM starts unless the watchdog record is valid, has the current host `boot_id`, is
no older than 180 s and no more than 60 s in the future, and has no unresolved `cap_breach` or enforcement failure.
Otherwise the reservation stays `creating` and status reports `backstop_down:` (after `vm_lifetime_cap:` if both apply).
A fresh timestamp alone never clears a breach: only observation of Off followed by verified teardown/reconciliation
does. The supervisor keeps enforcing while the watchdog is unhealthy, without claiming unavailable termination.

**B8 Install and migration.** The installer (P19.1) registers/removes the task and its admin-only folders; neither the
supervisor nor providers create or change them. Before enabling a VM profile under this revision, it must reconcile all
pre-existing managed VMs: each must either carry a valid B1 Notes record bound to its actual GUID/name, or be powered off
and removed through the ordinary verified teardown with absence proved. Any unmatched, unrecorded or unresolved VM blocks
profile activation; it remains quarantined/held until the owner resolves it. The watchdog is installed and its B7
heartbeat is fresh before any VM starts. This gate is mandatory, not an owner option; its absence is reported by B7.

**B9 Boundaries.** The watchdog never touches legacy containers, foreign VMs or invalid Notes; it never starts a VM.
It enforces deadlines or explicit conservative clock-safety decisions. Only observed Off means stopped execution.

## Resize and host measurement (DECIDED, P09 review 2026-10-20)

Nothing admitted is ever evicted by a resize or a host measurement (the lifetime cap ends work by time, not by
capacity).

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

Cap fixtures: none here. The cap adds no `allocator.json` field (`acquired_at` already carries the start), so
its fixtures validate the documents it makes the supervisor and the providers write: `fixtures/settings-v4/`,
`fixtures/status-v5/` (`vm-lifetime-cap-*`, `cap-*`) and `fixtures/backend-lifecycle/` (`*-vm-lifetime-cap*`,
`cap-*`); `tests/parity/contracts/test_lifetime_cap.py` holds the rules at their boundaries.
