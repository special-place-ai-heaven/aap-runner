# Status and settings contract (settings schemas 3, 4 and 5, status schema 5, revision 7)

Owners: **P12** (supervisor side, `supervisor/README.md`, both-side tests) and **P20** (tray).
Readers: P19, P22. Schemas: [`settings-v3.schema.json`](settings-v3.schema.json), [`settings-v4.schema.json`](settings-v4.schema.json),
[`settings-v5.schema.json`](settings-v5.schema.json), [`status-v5.schema.json`](status-v5.schema.json),
[`tray-windows-choice.schema.json`](tray-windows-choice.schema.json).
P12 landed both (revision 3, 2026-10-21): the supervisor reads settings schema 3 and writes
`status.v5.json` when the capacity module is deployed beside it, and writes `status.v5.json` with
`settings_schemas` `[1,2]` without it; the tray reads `status.v5.json` and writes schema 3 under the
compatibility rules below. The versioned docs are `supervisor/README.md` (Contracts, Capacity) and
`crates/tray/README.md`. The window's controls for shares, reserve and a live Windows count are P20's.

Revision 2 (P02.2, 2026-10-20): `status.v5.json` reports the storage tiers; settings schema 3 is
unchanged and carries no path.

Revision 5 (R1 step 1, 2026-11-05; revision 4 is R2 slice 1, PR #103): the tiered Linux pool
(`docs/ROADMAP.md`, R1). Settings schema 4 replaces `runner_count` with two tier counts; status
schema 5 gains a slot `tier`, fixed tier slot numbers and the 17-slot maxima. See Tiers below.

Revision 4 (R2 slice 1, 2026-11-05): the Windows profile may report `backend: windows-host`, the
interim runner installed on this PC itself (`docs/ROADMAP.md`, R2); see Windows host below. Report
only: settings schema 3 is unchanged and nothing starts or stops it.

Revision 6 (P09.x, owner decision Q4 of 2026-10-22, re-cut onto R1 on 2026-11-07; first proposed in PR #82 as
settings schema 4): the VM lifetime cap is a hard cap. Settings schema 5 is schema 4 with `vm_lifetime_cap_hours`, a
ceiling of 6 hours, in place of `lease_wall_clock_hours`; schemas 3 and 4 are unchanged and stay readable;
`status.v5.json` stays schema 5, gains an optional per-slot `vm_lifetime_cap` object and may advertise settings schema
5. The supervisor and the tray still implement revision 5 until the follow-ups in the
[README](README.md#revision-follow-ups-p09x-owner-decision-q4-carried-by-other-owners) land.

Revision 7 (R2.2, 2026-11-13): the supervisor starts and stops the interim Windows runner through
`host-runner.json`, and the `windows-host` profile gains `host_control`; see Windows host control below.

## Before P12 (what an older supervisor or tray still does)

- `inbox\settings.json` schema 2: `runner_count` 1..5 (the Linux count), `job_cpus` 1..28,
  `job_memory_gib` 1..80, `paused`, optional `schema` 2, `io_percent`, `sharing`, and the
  reserved `windows_runner_count` 0..4 with `runner_count` + it at most 5, validated and never
  applied. The current tray never writes `windows_runner_count`.
- `status.json` schema 4 (supervisor/README.md table). The current tray (`crates/tray/src/state.rs`)
  reports any `status.json` with `schema` above 4 as an error ("newer schema").
- Tray-local `%LOCALAPPDATA%\aap-runner\windows-runners.json`, schema 1,
  `{"schema":1,"windows_runner_count":0..4}`; the tray treats anything else as 0.
- Install journals (`jobs\install\state.json`, `config.json`) schema 1: unchanged.

## Settings schema 3

Same keys as schema 2 with the same meaning, plus `linux_backend`, `host_reserve_percent` (10..90),
`share_mode` (`even` | `per_profile`), `linux_share_percent`, `windows_share_percent`
(null in `even`). Every key is required in schema 3. Changes in range:

- `runner_count` (Linux) 0..5 and `windows_runner_count` 0..5, sum 1..5 (owner rule; schema 2's
  Windows 0..4 and Linux >= 1 existed only because no Windows backend did).
- `per_profile`: shares + reserve = 100; a profile with count 0 has share 0.
- `job_cpus`/`job_memory_gib` stay the legacy WSL pool totals. Precedence: shares win; the
  supervisor caps them to the Linux profile cap when it writes `limits.conf` and reports the
  applied values in `legacy_pool`. They are ignored while Linux is 0 or `linux_backend` is
  `hyperv-vm`.
- `lease_wall_clock_hours` (1..72, default 6), host cap per VM lease. Through revision 5 it only flags: past it
  the slot is flagged in `status.v5.json` `detail` and never destroyed by the wall clock. The hard VM lifetime cap
  (revision 6) is settings schema 5's `vm_lifetime_cap_hours` ([below](#settings-schema-5-the-hard-vm-lifetime-cap-revision-6-decided-owner-q4);
  allocator.md, Hard VM lifetime cap); what a revision 6 supervisor enforces while a schema 3 or 4 file is applied
  is open ([README, Open decisions](README.md#open-decisions-2026-10-20), item 7).
- `linux_backend` (`wsl-legacy` default, or `hyperv-vm`) is supervisor-side: the tray offers no
  control for it and writes back the value `status.v5.json` reports. Only the cutover item (P27)
  flips it, and the supervisor refuses `hyperv-vm` (keeping the last valid settings) unless an
  Ubuntu generation is `active` in the catalog.

## Tiers: settings schema 4 and the tiered status (revision 5)

One Linux backend, two tiers, slice sharing kept (owner, 2026-11-04):

| Tier | Count | Labels (exact line) | Per slot | Slot numbers |
|---|---|---|---|---|
| heavy | `linux_heavy_count` 0..2 | `self-hosted,linux,x64,fresh,heavy` | reservation 8 CPU / 20 GiB, may burst to the pool, CPU weight 4x a light slot's | 1, 2 |
| light | `linux_light_count` 0..10 | `self-hosted,linux,x64,fresh,light` | reservation 1 CPU / 3 GiB, hard cap 4 CPU / 8 GiB | 3..12 |
| Windows | `windows_runner_count` 0..5 | unchanged | `job_cpus` / `job_memory_gib` as in schema 3 | 13..17 |

Labels are additive: `fresh` stays, so a job asking for `fresh` may take any slot and a job asking
for `heavy` only a heavy slot; no other repository's workflow changes. Reservations total
2 x 20 + 10 x 3 = 70 GiB of the 72 GiB pool. The manager refuses a Linux pool whose reservation
total (heavy x 20 + light x 3 GiB) exceeds the pool memory, so the supervisor must refuse settings
that break that rule; the JSON schema cannot express this cross-field rule.

**Settings schema 4** ([`settings-v4.schema.json`](settings-v4.schema.json)): every schema 3 key,
all required, except `runner_count`, which is replaced by `linux_light_count` and
`linux_heavy_count`; a file with `runner_count` is not schema 4. Rules (`validate.py`
`sem_settings_v4`): light + heavy + Windows at least 1, no other sum limit; the shares follow schema 3
with the Linux count = light + heavy (a profile has share 0 exactly when its count is 0). The Linux
per-slot limits come only from the tier table above, never from the file. `job_cpus` and
`job_memory_gib` keep their ranges and remain the legacy WSL pool totals exactly as in schema 3 (the
slice cap and the reservation check); the supervisor writes them to `limits.conf` unchanged and
refuses a file whose heavy x 20 + light x 3 exceeds `job_memory_gib` (`validate.py` checks the same
inequality; the manager refuses the same pool). The tray carries both values forward from the
stored file, so the live pool stays at its current total.

**Status schema 5 while settings schema 4 or 5 is applied** (`applied_settings_schema` 4 or 5, which needs
that number in `settings_schemas`; `validate.py` `_tiers`): `capacity.max_slots` is 17 (else 5), the Linux profile
`count` (light + heavy) is 0..12 and Windows 0..5, at least 1 together; every Linux slot carries
`tier` (`heavy` or `light`) and its slot number is fixed by tier (table above) whatever the counts, so
slot 3 is always the first light slot; Windows slots carry no tier (absent or null) and use 13..17.
Under any other applied schema no slot carries a tier and the five-slot rules hold. `tier` is optional
in the JSON schema so a supervisor before R1 step 3 stays valid. `legacy_pool.runner_count` and
`status.json` `runner_count` report light + heavy (0..12), and `status.json` `slots[]` use the same
fixed numbers; `status.json` itself gains no key, so an older tray still reads it (it draws at most
five cards).

**Who writes what:** the supervisor lists 4 in `settings_schemas` only when it can apply schema 4
(the manager runs the two tiers, R1 steps 2 and 3); it keeps accepting 1 and 2 (3 only with the
capacity module). R1 step 3 (supervisor): it finds out with a passive `grep` of the installed manager for
`AAP_LINUX_HEAVY_COUNT` (never `--version`), accepts schema 4 only without the capacity module (the allocator is built for five slots; with
the module schema 4 is refused as newer, until P16 lifts that) and writes `AAP_LINUX_HEAVY_COUNT` and
`AAP_LINUX_LIGHT_COUNT` to `limits.conf` instead of `AAP_RUNNER_COUNT`. Without the capacity module it
also needs at least one Linux runner, because no Windows VM runs under it. The tray writes
schema 4 only over a stored valid schema 4 file or while a fresh `status.v5.json` lists 4 (same
freshness as schema 3), never schema 3 or 2 over a stored schema 4 file, and otherwise writes exactly
what revision 3 says, with the light count as the schema 2/3 Linux count and the heavy count 0. The
manager (R1 step 2) numbers its slots by the table and registers each tier with its exact label line.

## Settings schema 5: the hard VM lifetime cap (revision 6, DECIDED, owner Q4)

Exactly the keys of schema 4, every one required, with `vm_lifetime_cap_hours` in place of
`lease_wall_clock_hours` ([`settings-v5.schema.json`](settings-v5.schema.json)). Every other key keeps its schema 4
range and meaning, the tier rules included (`validate.py` applies `sem_settings_v4` to schema 5 unchanged: light +
heavy + Windows at least 1, heavy x 20 + light x 3 at most `job_memory_gib`, the shares over light + heavy). The old
name said *lease* (the broker's JIT lease lasts 10 minutes) and *wall clock* (revision 2's flag-only rule, the legacy
manager's job clock); the new one says what is limited, a VM, and that it is a lifetime. A new name under a new schema
number also means that no file written for the old meaning is read with the new one unseen.

- `vm_lifetime_cap_hours`: a whole number **1..6**, default 6. No `hyperv-vm` reservation lives longer than that
  many hours from its `acquired_at`, whatever the job, the guest or GitHub says: the supervisor powers the VM off
  and reclaims it ([allocator.md, Hard VM lifetime cap](allocator.md#hard-vm-lifetime-cap-decided-owner-decision-q4-2026-10-22)).
  6 is a **ceiling**: lower is allowed (a lab, or an owner who wants shorter jobs), higher is refused.
- It applies at once to every live VM, running ones included: lowering it reclaims every VM already older than
  the new value at the next tick, so an owner who only wants running jobs to finish pauses instead. While no
  settings are in force (no file, or none valid since the supervisor started) the cap is 6, and a refused file
  leaves the settings in force as they were. It never touches the legacy pool. `inbox\settings.json` is
  user-writable, so a process of the operator account can shorten the cap and end running jobs; the same account
  can already stop the pool (`desired: off`) and reach the broker as root (broker.md, M1), so this adds no power it
  lacks, and a lowered value never lengthens a VM's life ([README, Open decisions](README.md#open-decisions-2026-10-20)).
- While a schema 3 or 4 file is applied, the cap a revision 6 supervisor enforces is not yet decided
  ([README, Open decisions](README.md#open-decisions-2026-10-20), item 7); their `lease_wall_clock_hours` keeps its
  1..72 range.
- The tray offers no control for it today (P20.1 may). It writes back the stored value, else 6.

Migration from schema 4 to 5: the same tier fields, the cap key renamed, its range 1..72 narrowed to 1..6. Nothing is
clamped, and no writer lowers a stored value by itself:

| Stored or written | Supervisor (revision 6) | Tray (revision 6) |
|---|---|---|
| no file, schema 1 or 2 | cap 6 | writes the newest schema `status.v5.json` lists (5, else 4, else 3, else 2); the cap is 6 |
| schema 3 or 4, `lease_wall_clock_hours` 1..6 | accepted as before (ranges unchanged); the cap in force is item 7 of the open decisions | keeps the other keys and writes schema 5 with the same number once the supervisor lists 5 (from schema 3, the tier counts as in the schema 4 compatibility row): a rename, never a change of value |
| schema 3 or 4, `lease_wall_clock_hours` 7..72 | accepted as before; the cap in force is item 7 of the open decisions | shows the stored value and, as its first action, offers the owner an explicit choice of 1..6; it writes no schema 5 file until then |
| schema 5, 1..6 | accepted | |
| schema 5, anything else (0, 7, 72, 5.5, `"6"`, the old key, both keys) | the whole file is refused, as any refused settings file is: the last valid settings stay, and after a supervisor restart none are in force (no override, not paused, no VM counts applied, cap 6) until the owner fixes the file; `detail` starts `vm_cap_refused:` at once and until a valid file arrives | checks what it writes against the schema it writes |

## Status schema 5: a new file, not a new `status.json`

`C:\ProgramData\aap-runner\status.v5.json`, written by the supervisor in the same tick and with
the same atomic rename and validation rules as `status.json`. `status.json` keeps schema 4 and
its legacy-pool meaning so every installed tray keeps working. Content: overall `state`,
`settings_schemas` the supervisor accepts, `applied_settings_schema`, `capacity` (max 5, used,
free, reserve, share mode, host), exactly two `profiles` (OS, backend, count, share, per-runner
and profile caps, image generation and its state, cache state, availability), up to five `slots`
(profile, OS, backend, allocator lifecycle state, generation, job, repo, run and job URLs under
the existing strict patterns, usage), and `legacy_pool` (the schema 4 pool numbers). Every value
is re-validated before it is written, as today.

`settings_schemas` and `applied_settings_schema` may carry 5 (revision 6); while 5 is applied the tier rules of 4
hold (Tiers above).

**VM lifetime cap per slot (revision 6).** A `hyperv-vm` slot carries `vm_lifetime_cap` once its supervisor
implements revision 6, except a slot held as an `unknown_vm` quarantine (no journal names that VM, allocator.md L1);
a `wsl-legacy` slot never does. The field is optional in the schema, which is why status stays schema 5: a revision 5
supervisor's file stays valid and a revision 5 tray ignores the field. The validator cannot tell an `unknown_vm`
slot from another, so whether every other VM slot carries the object is a conformance test of the supervisor (P12),
not a document rule. The object is the proof that the cap is running and, after it fires, that it fired, in times, a
number of hours and one fixed word, never a host name, a path or an id:

| Field | Meaning |
|---|---|
| `cap_hours` | the cap in force, 1..6 |
| `started_utc` | the reservation's `acquired_at` |
| `deadline_utc` | `started_utc` plus `cap_hours` hours, exactly |
| `reason` | `null` while the VM lives; `vm_lifetime_cap` from the decision until the slot is freed |

`validate.py` enforces what a reader may rely on for a slot that carries the object: only a VM slot has one; the
deadline is start plus hours; a slot whose `reason` is set is `creating` (no `vm_id` yet, allocator.md L4),
`deleting` or `quarantined`, never serving; in a state that runs the capacity pass (`idle`, `running`, `draining`,
`paused`) a slot more than 60 s past its `deadline_utc` has `reason` set, because the supervisor evaluates the cap
before it writes such a document (allocator.md L3), while a document written in `off`, `starting` or `error`
claims no enforcement (L9); a set `reason` leads the top-level `detail` with `vm_lifetime_cap:`. The tray may show
the countdown and must show a set `reason`.

`generation_state` per profile, from the catalog and allocator (null exactly when
`image_generation` is null, for example a VM profile with no active generation and no live slot;
the legacy pool reports the manager generation its slots were granted on, `legacy-manager` before
any grant, as `active`):

| Catalog / allocator situation | `generation_state` |
|---|---|
| the profile's admissions use the catalog `active` generation and every live slot runs it | `active` |
| a newer generation is `active` while some live slots still run a `retired` one | `draining_old` |
| the `active` generation is flagged by P25 drift detection or is within the warning window before its evaluation expiry; admissions continue until replaced | `stale` |
| the generation reached its evaluation expiry: the catalog moves it to `quarantined` (never `active`) and admissions stop | `quarantined` |
| the profile's last generation was `quarantined` and no `active` one exists; no admissions | `quarantined` |

## Storage in status schema 5 (revision 2)

`status.v5.json` has a `storage` object built from the admin-only storage document
(backend-lifecycle.md, Storage tiers): `state`, `detail`, `volume_floor_gib` and, per tier
(`base`, `clone`, `scratch`, `staging`), the root, the free GiB of the volume that holds it and the
tier state. `unconfigured` means there is no storage document: no tiers and no floor. Otherwise all
four tiers are listed (`staging` with its effective root) and the overall state is the worst tier
state, in the order `missing`, `untrusted`, `low`, `ok`:

| Tier state | Meaning | Effect |
|---|---|---|
| `ok` | trust checks pass; free space at or above the floor | none |
| `low` | trust checks pass; free space below the floor | no new VM admission; running VMs continue within their admitted caps |
| `untrusted` | an owner, ACL, reparse, ancestor, drive-type or volume check fails; free space is reported when it can be read, otherwise null | VM profiles disabled |
| `missing` | the root or its recorded volume is absent; free space is null | VM profiles disabled |

While `storage.state` is not `ok`, every `hyperv-vm` profile reports `available: false` with the
reason. The tray shows the roots and free space and never changes them: the roots change only
through the elevated helper (a P19 verb, offered by the tray in P20) with the existing UAC prompt.
**Settings schema 3 carries no path.** `inbox\settings.json` is user-writable and the supervisor
reads only validated numbers and fixed words from it (`supervisor/README.md`); a root there would
let any process of the operator steer where the elevated supervisor writes and deletes.

`storage.detail` is empty or lists one `<tier>: <code>` entry per failing tier, joined by `; `,
with the codes `owner`, `acl`, `reparse`, `ancestor`, `drive-type`, `volume`, `missing` and `low`
(schema-enforced). It never carries an ACE dump or a path; the full reason goes to
`logs\supervisor.log`. The tray reads at most 64 KiB of `status.v5.json`.

## Windows host in status schema 5 (revision 4)

The interim runner (`FRESH-win-interim`, group `aap-win-interim`) runs from its install folder on
this PC under the owner's limited, non-elevated logon task `\AAP-Win-Interim-Runner`, unisolated
(owner accepted 2026-10-20). While its install folder exists, no Windows VM backend is loaded and no
Windows VM reservation is live, the
supervisor reports the Windows profile as `backend: windows-host` with `host_runner`, which is present
exactly then:

| `host_runner` | Meaning | `available` |
|---|---|---|
| `online` | the logon task is running and `Runner.Listener.exe` from the install folder runs; no job | true |
| `busy` | as `online`, and `Runner.Worker.exe` from the install folder runs a job | true |
| `stopped` | the task is missing or not running, or no listener runs; `unavailable_reason` names the missing piece | false |

`count` and `share_percent` stay what the settings give: the interim runner is outside the five
pool slots, so it adds no slot and no count. With no install folder the Windows profile reports what
it did before revision 4. `windows-host` is never the Linux profile's backend.

## Windows host control (revision 7)

Revision 7 (R2.2, 2026-11-13): the supervisor starts and stops the interim runner; the tray controls
it through the controls it already has. No settings schema changes.

- **Wanted.** The runner is wanted exactly when `inbox/state.json` says `on`, the accepted settings are
  not paused, and the accepted settings' Windows count (`windows_runner_count` of schema 3 or 4
  settings) is at least 1. Schema 1 or 2 settings, or no accepted settings, count as 0. It is the
  accepted count, not the profile's reported `count`, which stays as revision 4 describes.
- **The control file.** The supervisor keeps `host-runner.json` beside `status.json`
  (`{"schema":1,"desired":"on"}` or `"off"`, written atomically, only when it differs), checked every
  cycle in every mode, Off included (no `wsl.exe` call). The start script reads it at start (off: exit 0
  before stopping or starting anything) and every 2 s while `run.cmd` runs. Exactly `schema` 1 with
  `desired` `"off"` is off; anything else, a missing file included, is on.
- **Start.** When wanted and the logon task is not running, the supervisor starts it, retrying a failed
  start with the shared backoff. It never stops the task or a process: stopping the task does not stop
  the runner.
- **Stop.** Off ends the runner only when no job is in progress: the start script exits and its job
  object ends `run.cmd` and the listener. A job in progress is never killed; the runner stops after it.
  A withdrawn request is forgotten.
- **Status.** Every `windows-host` profile carries `host_control: true` (a boolean, only on a
  `windows-host` profile; absent means an older supervisor that only reports). A `stopped` runner that
  is not wanted has exactly one `unavailable_reason`, the first that applies: `turned off: runners are
  off`, `turned off: paused`, `turned off: Windows count 0`. A wanted, stopped runner keeps the missing
  piece; after a failed task start it adds `; ` and the error. A busy runner that is no longer wanted
  stays `busy` until its job ends.

Limits: (a) a job in progress is never killed, so the runner stops after it; (b) with a listener
registered, GitHub may hand it the next queued job in the moment before it stops; that job is lost and
re-queued; (c) settings below schema 3 carry no Windows count, so the interim runner is off until a
schema 3 or 4 count of 1 or more is stored; (d) with the supervisor not running nobody updates the
control file, and the runner keeps its last instruction.

## Allocator reasons in status detail (DECIDED, P09 review 2026-10-20)

When the allocator holds back, the top-level `detail` of `status.v5.json` starts with a fixed
reason word followed by a short ASCII explanation: `resize_waits` (a smaller count waits for its
running jobs to drain), `pool_over_live` (a host measurement no longer holds the live
reservations; the stored host is clamped and nothing more is admitted) or `grant_waits` (raised
`job_cpus` or `job_memory_gib` reach a granted legacy slot only with its next grant). See
allocator.md, Resize and host measurement.

`vm_lifetime_cap:` leads while any slot is held for deadline or conservative clock-safety enforcement; its slot reason
remains `vm_lifetime_cap` until freed. It does not assert that execution stopped: only a host observation of Off does.
An unresolved failed E2 adds fixed `cap_breach:` immediately after that leading word, sets state `error`, holds capacity
and blocks new VM starts. Failed inventory/observation/persistence adds `enforcement_unavailable:` and likewise cannot
be displayed as successful termination. Network isolation alone clears neither condition (allocator.md L5/B5).
`vm_cap_refused:` reports a refused cap setting. `backstop_down:` reports a missing/invalid/stale/prior-boot watchdog
record or unresolved enforcement failure/breach; a fresh heartbeat alone never clears a breach (allocator.md B7).

## Supervisor states and control distro uptime (DECIDED, owner 2026-10-19)

The WSL control distro and its keep-alive child run whenever desired is on and
Linux + Windows >= 1, because the broker (and the App key) live there. With Linux at 0 and
Windows >= 1 the distro still runs, the legacy manager is drained and stopped, and VM slots use
the broker. The existing rule "while Off the supervisor makes no `wsl.exe` call, so Vmmem can
exit" holds only when desired is off or both counts are 0. P12 writes this into
`supervisor/README.md` and its Pester tests.

## Compatibility rules (DECIDED)

| Writer / reader | Rule |
|---|---|
| New tray, old supervisor | no `status.v5.json`, so the tray writes schema 2 and keeps the Windows count tray-local (P20.0 behaviour) |
| New tray, new supervisor | tray writes schema 3 when the stored `settings.json` is a valid schema 3 file (keeping its keys the window has no control for, whatever `status.v5.json` says: a supervisor restart or a long block makes it stale), or when `status.v5.json` is fresh (at most 180 s old, not in the future) and lists 3 in `settings_schemas`; it never writes schema 2 over a stored schema 3 file, and it checks what it writes against the schema it writes. With schema 3 stored it shows that file's two counts and stops reading its tray-local file (it may delete it) |
| New tray, supervisor with schema 4 (revision 5) | tray writes schema 4 over a stored valid schema 4 file, or while a fresh `status.v5.json` lists 4; from a stored schema 3 file it carries the kept keys over and the edited light count, heavy count and Windows count; never schema 3 or 2 over a stored schema 4 file |
| New tray, supervisor without schema 4 | as the two rows above: schema 2 or 3, `runner_count` = the light count (at most 5 with Windows), heavy 0; the Heavy control is greyed |
| Old tray, new supervisor | old tray reads schema 4 `status.json` and writes schema 2; supervisor keeps accepting 1 and 2 forever (`settings_schemas` must contain 2) |
| Downgrade of the supervisor | an old supervisor rejects schema 3 with one warning and keeps the last valid settings; the new tray keeps writing schema 3 over the stored schema 3 file, which that supervisor keeps rejecting, until the owner removes `settings.json` (then the tray writes schema 2 again) |
| Unknown future schema | supervisor: settings with `schema` above its maximum are rejected, last valid settings kept, one warning, status `detail` names it. Tray: `status.v5.json` with schema above 5 is ignored and the tray falls back to `status.json`; never shows readiness from a file it cannot read |
| Mixed state | schema 4 `status.json` describes the legacy pool only; Windows and VM slots appear only in `status.v5.json` |
| New tray, supervisor that lists 5 (revision 6) | tray writes schema 5 when the stored `settings.json` is a valid schema 5 file, or when `status.v5.json` is fresh (at most 180 s old, not in the future) and lists 5, carrying a stored valid schema 4 file's keys across (`lease_wall_clock_hours` 1..6 becomes `vm_lifetime_cap_hours`, same number; 7..72 as in the migration table); it never writes schema 4 or older over a stored schema 5 file while the supervisor lists 5, and it never rewrites a stored cap above 6 |
| Downgrade below revision 6 | an older supervisor rejects schema 5 as newer (one warning, last valid settings kept, `detail` names it) and enforces no cap: it still flags only, as in revision 5 ([README, Open decisions](README.md#open-decisions-2026-10-20)) |
| Tray before revision 6 (already shipped), stored schema 5 file | it cannot parse schema 5 (unknown key, schema it does not know), so its window shows defaults and its next write goes through its status branch: it writes the newest schema it knows that a fresh `status.v5.json` lists, with its own `lease_wall_clock_hours` (a lower cap stored in schema 5 is lost), else schema 2, which also resets the Windows count, the shares and the reserve to their defaults. The supervisor accepts these. Nothing can be done for a shipped tray; the revision 6 tray (P20.1) is the first that leaves a stored schema 5 file alone, so the two ship together (rollout below) |

## Coordinated rollout of revision 6 (tray and supervisor)

The installed tray predates revision 6 and is not changed without the owner's word. Revision 6 therefore ships in parts
that must land together on the owner's machine: the watchdog and its task (P10.7, P19.1), the supervisor (P12.3) and the
tray (P20.1).

| State | What happens | What the owner sees |
|---|---|---|
| New supervisor, installed tray | the tray keeps writing schema 4 or older (it never writes schema 5) and the supervisor accepts it; the cap in force while that file is applied is item 7 of the open decisions | nothing changes in the window |
| Revision 6 tray, old supervisor | no `status.v5.json` lists 5, so the tray writes the schema the supervisor lists (4, else 3, else 2) | that supervisor does not enforce the cap: it still flags only (compatibility rules above) |
| Both revision 6 | the tray writes schema 5 once advertised, carries the cap across unchanged, offers 1..6 and shows `vm_cap_refused:`, `backstop_down:` and a fired slot's `reason` | the cap is enforced by the supervisor and, independently, by the watchdog |

Order of installation: the watchdog first, then the supervisor, then the tray. Before enabling the VM profile, P19.1 must
reconcile every pre-existing managed VM to a valid B1 Notes record or verified teardown/absence; an unrecorded,
unmatched or unresolved VM blocks activation and remains held until resolved. No VM profile serves a public repository
before the watchdog is proved in the lab (owner decision Q4, P02.1).

## Negative fixtures

Settings: 3 + 3, 0 + 0, schema 4, a string count, reserve 5, shares summing to 95, a share for a
zero count. Status: six slots, a Windows slot labelled Linux, a non-GitHub run URL, schema 6, a
supervisor that stops accepting schema 2, a VM profile available while storage is untrusted, a tier
below the floor reported `ok`, a UNC root, unconfigured storage that lists tiers, a tier listed
twice or not at all, a `missing` tier with free space, a tier above the floor reported `low`, an
overall `ok` beside a `low` tier, and a storage detail carrying an ACE dump. Valid storage examples:
unconfigured (VM profile unavailable), and `missing` with an `untrusted` tier that reports free
space and one that cannot. Windows host (revision 4): `windows-host` on the Linux profile, `host_runner` beside another backend, a `stopped` runner reported available; valid: a busy interim runner. Tiers (revision 5): settings schema 4 with light 11, heavy 3, Windows 6, all zero, `runner_count` kept, the heavy count missing, schema 3, a Linux share with no Linux runner; status: a heavy tier on slot 3, a tier on a Windows slot, a Linux slot without a tier, a Windows slot in the light range, a tier while schema 3 is applied, `max_slots` 17 without schema 4, applied 4 that `settings_schemas` does not list, a Linux count of 13; six slots is now more slots than `max_slots`; valid: heavy and light slots under schema 4. Tray-local: count 5, schema 2, a string, a missing count.

Revision 6 negatives. Settings schema 5: a cap of 7, of 72 (schema 4's maximum), of 0, of 5.5 or of `"6"`, the old
key in place of the new one or beside it, schema 4 and schema 6, shares summing to 95, and the tier rules it shares
with schema 4 (light 11, heavy 3, all zero, `runner_count` kept, reservations over `job_memory_gib`). Status: a cap
whose deadline is not start plus hours, a cap of 7 hours, a fired cap on a busy slot, a cap on a legacy slot, a slot
61 s past its deadline whose cap has not fired, a fired cap the `detail` does not lead with, a start that is not a
real time (30 February), a reason word that is not `vm_lifetime_cap`, `settings_schemas` or
`applied_settings_schema` naming schema 6, and applied 5 with the five-slot shape. Valid: a live cap (6 h), a reclaim
(one slot `deleting`, one `quarantined`) and a lab cap of 1 h (these apply settings schema 3: the cap object is per
slot and does not depend on the tiers), heavy and light slots under schema 5; settings schema 5: the three schema 4 tier
payloads at 6 h and one at 1 h. Schemas 3 and 4 keep their `lease_wall_clock_hours` fixtures (1..72).
`settings-v3/invalid/future-schema-4.json` keeps its name: the schema 3 file refuses it, and it is a future schema
only for a supervisor that does not accept schema 4.
