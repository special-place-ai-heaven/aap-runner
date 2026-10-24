# Status and settings contract (settings schemas 3 and 4, status schema 5, revision 4)

Owners: **P12** (supervisor side, `supervisor/README.md`, both-side tests) and **P20** (tray).
Readers: P19, P22. Schemas: [`settings-v3.schema.json`](settings-v3.schema.json),
[`settings-v4.schema.json`](settings-v4.schema.json), [`status-v5.schema.json`](status-v5.schema.json),
[`tray-windows-choice.schema.json`](tray-windows-choice.schema.json).
P12 landed both (revision 3, 2026-10-21): the supervisor reads settings schema 3 and writes
`status.v5.json` when the capacity module is deployed beside it, and writes `status.v5.json` with
`settings_schemas` `[1,2]` without it; the tray reads `status.v5.json` and writes schema 3 under the
compatibility rules below. The versioned docs are `supervisor/README.md` (Contracts, Capacity) and
`crates/tray/README.md`. The window's controls for shares, reserve and a live Windows count are P20's.

Revision 2 (P02.2, 2026-10-20): `status.v5.json` reports the storage tiers; settings schema 3 is
unchanged and carries no path.

Revision 4 (P09.x, 2026-10-22, owner decision Q4): the VM lifetime cap is a hard cap. Settings schema 4
replaces `lease_wall_clock_hours` with `vm_lifetime_cap_hours`, a ceiling of 6 hours; schema 3 stays readable
with its key narrowed to 1..6; `status.v5.json` stays schema 5, gains an optional per-slot `vm_lifetime_cap`
object and may advertise settings schema 4. The supervisor and the tray still implement revision 3 until the
follow-ups in the [README](README.md#revision-follow-ups-p09x-owner-decision-q4-carried-by-other-owners) land.

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
- `lease_wall_clock_hours` (**1..6**, default 6; revision 3 allowed 1..72): the hard VM lifetime cap under its
  schema 3 name, in force since revision 4 ([schema 4, below](#settings-schema-4-the-hard-vm-lifetime-cap-revision-4-decided-owner-q4);
  allocator.md, Hard VM lifetime cap). Revision 3's flag-only rule is gone. A value above 6 is refused whole,
  never clamped.
- `linux_backend` (`wsl-legacy` default, or `hyperv-vm`) is supervisor-side: the tray offers no
  control for it and writes back the value `status.v5.json` reports. Only the cutover item (P27)
  flips it, and the supervisor refuses `hyperv-vm` (keeping the last valid settings) unless an
  Ubuntu generation is `active` in the catalog.

## Settings schema 4: the hard VM lifetime cap (revision 4, DECIDED, owner Q4)

Exactly the keys of schema 3, every one required, with `vm_lifetime_cap_hours` in place of
`lease_wall_clock_hours`. The old name said *lease* (the broker's JIT lease lasts 10 minutes) and *wall clock*
(revision 2's flag-only rule, the legacy manager's job clock); the new one says what is limited, a VM, and that it
is a lifetime. A new name under a new schema number also means that no file written for the old meaning is read
with the new one unseen.

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
- The tray offers no control for it today (P20.1 may). It writes back the stored value, else 6.

Migration. Nothing is clamped, and no writer lowers a stored value by itself:

| Stored or written | Supervisor (revision 4) | Tray (revision 4) |
|---|---|---|
| no file, schema 1 or 2 | cap 6 | writes the newest schema `status.v5.json` lists (4, else 3, else 2); the cap is 6 |
| schema 3, `lease_wall_clock_hours` 1..6 | accepted; the value is now the hard cap (it was a flag threshold, so a stored 2 reclaims at 2 h) | keeps the other keys and writes schema 4 with the same number once the supervisor lists 4: a rename, never a change of value |
| schema 3, 7..72 | the whole file is refused, as any refused settings file is: the last valid settings stay, and after a supervisor restart none are in force (no override, not paused, no VM counts applied, cap 6) until the owner fixes the file; `detail` starts `vm_cap_refused:` at once and until a valid file arrives | shows the refusal and, as its first action, offers the owner an explicit choice of 1..6; it writes nothing over the file until then (a revision 3 tray still rewrites the stored value with every change, and the supervisor keeps refusing it) |
| schema 4, 1..6 | accepted | |
| schema 4, anything else (0, 7, 72, 5.5, `"6"`, the old key, both keys) | refused, as above | checks what it writes against the schema it writes |

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

`settings_schemas` and `applied_settings_schema` may carry 4 (revision 4).

**VM lifetime cap per slot (revision 4).** A `hyperv-vm` slot carries `vm_lifetime_cap` once its supervisor
implements revision 4, except a slot held as an `unknown_vm` quarantine (no journal names that VM, allocator.md L1);
a `wsl-legacy` slot never does. The field is optional in the schema, which is why status stays schema 5: a revision 3
supervisor's file stays valid and a revision 3 tray ignores the field. The validator cannot tell an `unknown_vm`
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
| Old tray, new supervisor | old tray reads schema 4 `status.json` and writes schema 2; supervisor keeps accepting 1 and 2 forever (`settings_schemas` must contain 2) |
| Downgrade of the supervisor | an old supervisor rejects schema 3 with one warning and keeps the last valid settings; the new tray keeps writing schema 3 over the stored schema 3 file, which that supervisor keeps rejecting, until the owner removes `settings.json` (then the tray writes schema 2 again) |
| Unknown future schema | supervisor: settings with `schema` above its maximum are rejected, last valid settings kept, one warning, status `detail` names it. Tray: `status.v5.json` with schema above 5 is ignored and the tray falls back to `status.json`; never shows readiness from a file it cannot read |
| Mixed state | schema 4 `status.json` describes the legacy pool only; Windows and VM slots appear only in `status.v5.json` |
| New tray, supervisor that lists 4 (revision 4) | tray writes schema 4 when the stored `settings.json` is a valid schema 4 file, or when `status.v5.json` is fresh (at most 180 s old, not in the future) and lists 4, carrying a stored valid schema 3 file's keys across (`lease_wall_clock_hours` 1..6 becomes `vm_lifetime_cap_hours`, same number); it never writes schema 3 over a stored schema 4 file while the supervisor lists 4, and it never rewrites a stored cap above 6 (migration table) |
| Downgrade below revision 4 | an older supervisor rejects schema 4 as newer (one warning, last valid settings kept, `detail` names it) and enforces no cap: it still flags only, as in revision 3 ([README, Open decisions](README.md#open-decisions-2026-10-20)) |
| Revision 3 tray (already shipped), stored schema 4 file | it cannot parse schema 4 (unknown key, schema other than 3), so its window shows defaults and its next write goes through its status branch: while a fresh `status.v5.json` lists 3 it writes schema 3 with `lease_wall_clock_hours` 6 and what status reports (a lower cap stored in schema 4 is lost and reads 6 again, never above the ceiling); with a stale or missing status it writes schema 2, which also resets the Windows count, the shares and the reserve to their defaults. The supervisor accepts both. Nothing can be done for a shipped tray; the revision 4 tray (P20.1) is the first that leaves a stored schema 4 file alone, so the two ship together (rollout below) |

## Coordinated rollout of revision 4 (tray and supervisor)

The installed tray is revision 3 and is not changed without the owner's word. Revision 4 therefore ships in parts that must
land together on the owner's machine: the watchdog and its task (P10.7, P19.1), the supervisor (P12.3) and the tray
(P20.1).

| State | What happens | What the owner sees |
|---|---|---|
| New supervisor, installed (revision 3) tray, stored `lease_wall_clock_hours` 1..6 | the supervisor accepts the file and the value is the hard cap; the tray keeps rewriting the stored value as schema 3 (it never writes schema 4) | nothing changes |
| New supervisor, installed tray, stored 7..72 (the revision 3 tray allows 1..=72 and writes the stored value back with every change) | the supervisor refuses the whole file, every time: the last valid settings stay, after a restart none are in force (no override, not paused, no VM counts applied, cap 6), it logs `vm_cap_refused` and `detail` starts `vm_cap_refused:` until a valid file arrives | the tray shows the status detail; ordinary tray edits stay refused, because the tray rewrites the same stored value, until the owner sets the value to 1..6 in `inbox\settings.json` by hand or installs the revision 4 tray |
| Revision 4 tray, old supervisor | no `status.v5.json` lists 4, so the tray writes the schema the supervisor lists (3, else 2) | that supervisor does not enforce the cap: it still flags only (compatibility rules above) |
| Both revision 4 | the tray writes schema 4 once advertised, carries the cap across unchanged, offers 1..6 and shows `vm_cap_refused:`, `backstop_down:` and a fired slot's `reason` | the cap is enforced by the supervisor and, independently, by the watchdog |

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
space and one that cannot. Tray-local: count 5, schema 2, a string, a missing count.

Revision 4 negatives. Settings schema 4: a cap of 7, of 72 (revision 3's maximum), of 0, of 5.5 or of `"6"`, the old
key in place of the new one or beside it, schema 5, and the count and share rules it shares with schema 3 (3 + 3,
shares summing to 95); schema 3: a lease of 7 and of 72. Status: a cap whose deadline is not start plus hours, a cap
of 7 hours, a fired cap on a busy slot, a cap on a legacy slot, a slot 61 s past its deadline whose cap has not
fired, a fired cap the `detail` does not lead with, a start that is not a real time (30 February), a reason word
that is not `vm_lifetime_cap`, and `settings_schemas` or `applied_settings_schema` naming schema 5. Valid: a live
cap (6 h), a reclaim (one slot `deleting`, one `quarantined`) and a lab cap of 1 h; settings schema 4 at 6 h and at
1 h.
`settings-v3/invalid/future-schema-4.json` keeps its name: the schema 3 file refuses it, and it is a future schema
only for a supervisor that does not accept schema 4.
