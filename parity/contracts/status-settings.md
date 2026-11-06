# Status and settings contract (settings schemas 3 and 4, status schema 5, revision 5)

Owners: **P12** (supervisor side, `supervisor/README.md`, both-side tests) and **P20** (tray).
Readers: P19, P22. Schemas: [`settings-v3.schema.json`](settings-v3.schema.json), [`settings-v4.schema.json`](settings-v4.schema.json),
[`status-v5.schema.json`](status-v5.schema.json), [`tray-windows-choice.schema.json`](tray-windows-choice.schema.json).
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
- `lease_wall_clock_hours` (1..72, default 6), host cap per VM lease. Wall-clock rule (same text
  in allocator.md):
  `lease_wall_clock_hours` (default 6) counts from the reservation's `acquired_at`. Past it the
  slot is only flagged: `status.v5.json` `detail` names it for the owner. The wall clock never
  destroys a slot: a heartbeat-quarantined slot is destroyed only when GitHub reports its runner
  `offline` (or `absent`) and not busy, or the job is known to have ended; a runner GitHub reports
  `busy` is never destroyed, and its slot stays held and `cleanup_uncertain`.
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
per-slot limits come only from the tier table above, never from the file; `job_cpus` and
`job_memory_gib` keep their ranges and apply to the Windows runners only.

**Status schema 5 while settings schema 4 is applied** (`applied_settings_schema` 4, which needs 4 in
`settings_schemas`; `validate.py` `_tiers`): `capacity.max_slots` is 17 (else 5), the Linux profile
`count` (light + heavy) is 0..12 and Windows 0..5, at least 1 together; every Linux slot carries
`tier` (`heavy` or `light`) and its slot number is fixed by tier (table above) whatever the counts, so
slot 3 is always the first light slot; Windows slots carry no tier (absent or null) and use 13..17.
Under any other applied schema no slot carries a tier and the five-slot rules hold. `tier` is optional
in the JSON schema so a supervisor before R1 step 3 stays valid. `legacy_pool.runner_count` and
`status.json` `runner_count` report light + heavy (0..12), and `status.json` `slots[]` use the same
fixed numbers; `status.json` itself gains no key, so an older tray still reads it (it draws at most
five cards).

**Who writes what:** the supervisor lists 4 in `settings_schemas` only when it can apply schema 4
(the manager runs the two tiers, R1 steps 2 and 3); it keeps accepting 1, 2 and 3. The tray writes
schema 4 only over a stored valid schema 4 file or while a fresh `status.v5.json` lists 4 (same
freshness as schema 3), never schema 3 or 2 over a stored schema 4 file, and otherwise writes exactly
what revision 3 says, with the light count as the schema 2/3 Linux count and the heavy count 0. The
manager (R1 step 2) numbers its slots by the table and registers each tier with its exact label line.

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

## Allocator reasons in status detail (DECIDED, P09 review 2026-10-20)

When the allocator holds back, the top-level `detail` of `status.v5.json` starts with a fixed
reason word followed by a short ASCII explanation: `resize_waits` (a smaller count waits for its
running jobs to drain), `pool_over_live` (a host measurement no longer holds the live
reservations; the stored host is clamped and nothing more is admitted) or `grant_waits` (raised
`job_cpus` or `job_memory_gib` reach a granted legacy slot only with its next grant). See
allocator.md, Resize and host measurement.

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

## Negative fixtures

Settings: 3 + 3, 0 + 0, schema 4, a string count, reserve 5, shares summing to 95, a share for a
zero count. Status: six slots, a Windows slot labelled Linux, a non-GitHub run URL, schema 6, a
supervisor that stops accepting schema 2, a VM profile available while storage is untrusted, a tier
below the floor reported `ok`, a UNC root, unconfigured storage that lists tiers, a tier listed
twice or not at all, a `missing` tier with free space, a tier above the floor reported `low`, an
overall `ok` beside a `low` tier, and a storage detail carrying an ACE dump. Valid storage examples:
unconfigured (VM profile unavailable), and `missing` with an `untrusted` tier that reports free
space and one that cannot. Windows host (revision 4): `windows-host` on the Linux profile, `host_runner` beside another backend, a `stopped` runner reported available; valid: a busy interim runner. Tiers (revision 5): settings schema 4 with light 11, heavy 3, Windows 6, all zero, `runner_count` kept, the heavy count missing, schema 3, a Linux share with no Linux runner; status: a heavy tier on slot 3, a tier on a Windows slot, a Linux slot without a tier, a Windows slot in the light range, a tier while schema 3 is applied, `max_slots` 17 without schema 4, applied 4 that `settings_schemas` does not list, a Linux count of 13; six slots is now more slots than `max_slots`; valid: heavy and light slots under schema 4. Tray-local: count 5, schema 2, a string, a missing count.
